-- OK DESPACHO ONLINE — RC1 (incremental): foto de DNI en Supabase Storage PRIVADO.
-- En la base queda solo: cuil, storage_path, mime, registered_by, registered_at.
-- Compatibilidad: los registros viejos con dni_photo (bytea) se conservan tal cual (columna legacy, nula para los nuevos);
-- no se inventan rutas. Para moverlos (proyecto real, con service role): subir cada foto a identity-docs/<cuil>/<uuid>.jpg,
-- poner storage_path y luego dni_photo = null. Hasta entonces siguen siendo visibles solo con identity_docs.view.

-- ---------- Bucket privado (5 MB, JPEG/PNG) ----------
insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('identity-docs', 'identity-docs', false, 5242880, array['image/jpeg','image/png'])
on conflict (id) do update set public = false, file_size_limit = 5242880, allowed_mime_types = array['image/jpeg','image/png'];

-- ---------- Tabla: ruta en Storage en vez de la foto ----------
alter table public.customer_identity_docs add column if not exists storage_path text;
alter table public.customer_identity_docs alter column dni_photo drop not null;
alter table public.customer_identity_docs drop constraint if exists identity_doc_source;
alter table public.customer_identity_docs add constraint identity_doc_source check (storage_path is not null or dni_photo is not null);
alter table public.customer_identity_docs drop constraint if exists identity_doc_mime;
alter table public.customer_identity_docs add constraint identity_doc_mime check (mime in ('image/jpeg','image/png'));
comment on column public.customer_identity_docs.dni_photo is 'LEGACY (RC1): solo registros anteriores. Los nuevos usan storage_path en el bucket privado identity-docs.';

-- ---------- Políticas de Storage ----------
-- Subir: solo quien captura evidencia (chofer en su recorrido) y dentro de la carpeta del CUIL. Nunca descargar.
drop policy if exists identity_docs_upload on storage.objects;
create policy identity_docs_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'identity-docs' and public.auth_has_perm('deliveries.capture_signature') and name ~ '^[0-9]{11}/[0-9a-f-]{36}\.(jpg|png)$');
-- Ver / URL firmada temporal: solo identity_docs.view
drop policy if exists identity_docs_read on storage.objects;
create policy identity_docs_read on storage.objects for select to authenticated
  using (bucket_id = 'identity-docs' and public.auth_has_perm('identity_docs.view'));

-- Valida que el archivo subido exista, sea del usuario, del CUIL, JPEG/PNG y ≤ 5 MB
create or replace function public._identity_upload_ok(p_cuil text, p_path text) returns text language plpgsql stable security definer set search_path = public, storage as $$
declare o record; sz bigint; mt text;
begin
  if p_path !~ ('^' || p_cuil || '/[0-9a-f-]{36}\.(jpg|png)$') then return 'BAD_PATH'; end if;
  select * into o from storage.objects where bucket_id = 'identity-docs' and name = p_path;
  if not found then return 'NOT_UPLOADED'; end if;
  if o.owner is distinct from auth.uid() then return 'NOT_OWNER'; end if;
  mt := coalesce(o.metadata->>'mimetype', '');
  sz := coalesce((o.metadata->>'size')::bigint, 0);
  if mt not in ('image/jpeg','image/png') then return 'BAD_TYPE'; end if;
  if sz <= 0 or sz > 5242880 then return 'BAD_SIZE'; end if;
  return null;
end; $$;

-- set_stop_outcome: misma lógica 2B.3; la foto del DNI ahora llega como ruta de Storage (dni_storage_path)
create or replace function public._register_identity(p_cuil text, ev jsonb) returns void language plpgsql security definer set search_path = public as $$
declare chk text;
begin
  if coalesce(ev->>'dni_photo_b64', '') <> '' then raise exception 'DNI_STORAGE_REQUIRED: la foto del DNI se sube a Storage privado' using errcode = '23514'; end if;
  if coalesce(ev->>'dni_storage_path', '') = '' or exists (select 1 from public.customer_identity_docs d where d.cuil = p_cuil) then return; end if;
  chk := public._identity_upload_ok(p_cuil, ev->>'dni_storage_path');
  if chk is not null then raise exception 'DNI_UPLOAD_INVALID: %', chk using errcode = '23514'; end if;
  insert into public.customer_identity_docs(cuil, storage_path, mime, registered_by)
  values (p_cuil, ev->>'dni_storage_path', (select metadata->>'mimetype' from storage.objects where bucket_id = 'identity-docs' and name = ev->>'dni_storage_path'), auth.uid())
  on conflict (cuil) do nothing;
end; $$;
revoke execute on function public._identity_upload_ok(text, text), public._register_identity(text, jsonb) from public, anon, authenticated;

-- Nueva versión de set_stop_outcome (idéntica a 2B.3 salvo el registro del DNI)
create or replace function public.set_stop_outcome(p_stop uuid, p_outcome text, p_note text, p_reason text, p_op_id text, p_extra jsonb default null)
returns public.route_stops language plpgsql security definer set search_path = public as $$
declare st public.route_stops; r public.routes; cristian boolean; v_cuil text; ev jsonb := coalesce(p_extra->'evidence', '{}'); col jsonb := p_extra->'collection'; loc jsonb; sig bytea;
begin
  select * into st from public.route_stops where id = p_stop;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  r := public._my_route(st.route_id);
  if p_op_id is not null and exists (select 1 from public.stop_outcome_ops where op_id = p_op_id) then return st; end if;
  if r.operational_status <> 'EN_CURSO' then raise exception 'BAD_STATE: iniciá el recorrido o la hoja ya está cerrada' using errcode = '23514'; end if;
  if p_outcome not in ('ENTREGADO','ENTREGA_PARCIAL','NO_ENTREGADO','REPROGRAMAR') then raise exception 'BAD_OUTCOME' using errcode = '22023'; end if;
  if p_outcome = 'ENTREGA_PARCIAL' and coalesce(trim(p_note), '') = '' then raise exception 'NOTE_REQUIRED: entrega parcial exige observación' using errcode = '23514'; end if;
  if p_outcome in ('NO_ENTREGADO','REPROGRAMAR') and coalesce(trim(p_reason), '') = '' then raise exception 'REASON_REQUIRED: indicá el motivo' using errcode = '23514'; end if;
  cristian := exists (select 1 from public.carriers where id = r.carrier_id and report_group = 'CRISTIAN_TORRES');
  if p_outcome in ('ENTREGADO','ENTREGA_PARCIAL') then
    if coalesce(trim(ev->>'receiver_name'), '') = '' or coalesce(ev->>'signature_png_b64', '') = '' then raise exception 'EVIDENCE_REQUIRED: nombre del receptor y firma obligatorios' using errcode = '23514'; end if;
    sig := decode(ev->>'signature_png_b64', 'base64');
    if cristian then
      v_cuil := regexp_replace(coalesce(ev->>'cuil', ''), '\D', '', 'g');
      if length(v_cuil) <> 11 then raise exception 'CUIL_INVALID: el CUIL debe tener 11 dígitos' using errcode = '23514'; end if;
      perform public._register_identity(v_cuil, ev);   -- RC1: DNI en Storage privado
    end if;
  end if;
  -- cobranza (Cristian): el chofer no cambia el importe esperado
  if st.task in ('COBRANZA','AMBAS') then
    if col is null or coalesce(col->>'status', 'PENDIENTE') = 'PENDIENTE' then raise exception 'COLLECTION_REQUIRED: indicá el resultado de la cobranza' using errcode = '23514'; end if;
    if col->>'status' not in ('COBRADO','COBRO_PARCIAL','NO_COBRADO') then raise exception 'BAD_COLLECTION' using errcode = '22023'; end if;
    if col->>'status' in ('COBRO_PARCIAL','NO_COBRADO') and coalesce(trim(col->>'note'), '') = '' then raise exception 'COLLECTION_NOTE_REQUIRED: cobro parcial exige observación y no cobrado exige motivo' using errcode = '23514'; end if;
    if col->>'status' in ('COBRADO','COBRO_PARCIAL') and coalesce((col->>'amount')::numeric, 0) <= 0 then raise exception 'COLLECTION_AMOUNT_REQUIRED' using errcode = '23514'; end if;
  end if;
  loc := public._loc(p_extra->'location', st);
  update public.route_stops set outcome = p_outcome, outcome_at = now(), outcome_by = auth.uid(), outcome_note = nullif(trim(p_note),''), outcome_reason = nullif(trim(p_reason),''),
    finish_location = loc, location_warning = coalesce(case when loc->>'outside_m' is not null then 'FUERA DEL RADIO (' || (loc->>'outside_m') || ' m)' end, location_warning),
    collection_status = case when st.task in ('COBRANZA','AMBAS') then col->>'status' else collection_status end,
    collected_amount = case when st.task in ('COBRANZA','AMBAS') then nullif(col->>'amount','')::numeric else collected_amount end,
    payment_mode = case when st.task in ('COBRANZA','AMBAS') then col->>'mode' else payment_mode end,
    collection_note = case when st.task in ('COBRANZA','AMBAS') then nullif(trim(col->>'note'),'') else collection_note end
  where id = p_stop returning * into st;
  if p_outcome in ('ENTREGADO','ENTREGA_PARCIAL') then
    insert into public.stop_evidence(stop_id, receiver_name, signature_png, signature_sha256, receiver_cuil, created_by)
    values (p_stop, trim(ev->>'receiver_name'), sig, encode(sha256(sig), 'hex'), case when cristian then v_cuil end, auth.uid())
    on conflict (stop_id) do nothing;
    if coalesce(trim(st.customer_email), '') <> '' then
      insert into public.customer_email_jobs(route_id, stop_id, kind, recipient, idempotency_key)
      values (st.route_id, st.id, case when p_outcome = 'ENTREGADO' then 'DELIVERED' else 'PARTIAL' end, lower(trim(st.customer_email)), st.route_id || '|' || st.id || '|' || case when p_outcome = 'ENTREGADO' then 'DELIVERED' else 'PARTIAL' end)
      on conflict (idempotency_key) do nothing;
    end if;
  end if;
  if p_op_id is not null then insert into public.stop_outcome_ops(op_id, stop_id) values (p_op_id, p_stop); end if;
  perform public._queue_on_the_way(st.route_id);
  return st;
end; $$;
