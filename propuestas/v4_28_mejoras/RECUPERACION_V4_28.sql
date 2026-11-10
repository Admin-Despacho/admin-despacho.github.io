-- ======================================================================================================================
-- RECUPERACIÓN V4.28 · NO APLICAR AUTOMÁTICAMENTE (advertencia de la auditoría de Work).
-- Este script: restaura set_stop_outcome (V4.21), delivery_identity_lookup (rc4_1) y search_deliveries (V4.26) y RETIRA las funciones
-- nuevas (gestiones, historial, incidencias y corrección). Consecuencias: un documento inválido VUELVE a bloquear la entrega, y la pantalla
-- V4.28 queda sin las funciones que usa. Solo con revisión de impacto y AUTORIZACIÓN ESPECÍFICA, y con la pantalla vuelta a 91d76ed.
-- CONSERVA los datos (gestiones, incidencias, correcciones, evidencias, columnas nuevas): el historial es inalterable.
-- ======================================================================================================================
BEGIN;
CREATE OR REPLACE FUNCTION public.set_stop_outcome(p_stop uuid, p_outcome text, p_note text, p_reason text, p_op_id text, p_extra jsonb DEFAULT NULL::jsonb)
 RETURNS route_stops
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare st public.route_stops; r public.routes; cristian boolean; v_commercial boolean; v_task boolean; v_cuil text; v_email text; v_dni text; v_receipt boolean := false; ev jsonb := coalesce(p_extra->'evidence', '{}'); col jsonb := p_extra->'collection'; loc jsonb; sig bytea;
begin
  select * into st from public.route_stops where id = p_stop;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  r := public._my_route(st.route_id);
  -- Comportamiento por tipo de parada: solo PEDIDO es entrega comercial al cliente (email, Recibido Conforme, cobranza, identidad).
  v_commercial := coalesce(st.stop_type, 'PEDIDO') = 'PEDIDO';
  v_task := st.stop_type = 'TAREA';
  if p_op_id is not null and exists (select 1 from public.stop_outcome_ops where op_id = p_op_id) then return st; end if;
  if r.operational_status <> 'EN_CURSO' then raise exception 'BAD_STATE: iniciá el recorrido o la hoja ya está cerrada' using errcode = '23514'; end if;
  if p_outcome not in ('ENTREGADO','ENTREGA_PARCIAL','NO_ENTREGADO','REPROGRAMAR') then raise exception 'BAD_OUTCOME' using errcode = '22023'; end if;
  if p_outcome = 'ENTREGA_PARCIAL' and coalesce(trim(p_note), '') = '' then raise exception 'NOTE_REQUIRED: entrega parcial exige observación' using errcode = '23514'; end if;
  if p_outcome in ('NO_ENTREGADO','REPROGRAMAR') and coalesce(trim(p_reason), '') = '' then raise exception 'REASON_REQUIRED: indicá el motivo' using errcode = '23514'; end if;
  cristian := exists (select 1 from public.carriers where id = r.carrier_id and report_group = 'CRISTIAN_TORRES');
  if p_outcome in ('ENTREGADO','ENTREGA_PARCIAL') then
    -- TAREA: no se exige firma ni receptor como en una entrega comercial (alcanza GPS u observación). El resto, igual que antes.
    if not v_task and (coalesce(trim(ev->>'receiver_name'), '') = '' or coalesce(ev->>'signature_png_b64', '') = '') then raise exception 'EVIDENCE_REQUIRED: nombre del receptor y firma obligatorios' using errcode = '23514'; end if;
    sig := case when coalesce(ev->>'signature_png_b64', '') <> '' then decode(ev->>'signature_png_b64', 'base64') end;
    -- V4.17: entrega COMERCIAL de AMBOS perfiles (transportista externo e interno): CUIL + identidad con DNI registrado
    -- (antes: solo Cristian). _register_identity vincula la foto nueva o reutiliza una identidad ya registrada.
    if v_commercial then
      v_cuil := regexp_replace(coalesce(ev->>'cuil', ''), '\D', '', 'g');
      if length(v_cuil) <> 11 then raise exception 'CUIL_INVALID: el CUIL debe tener 11 dígitos' using errcode = '23514'; end if;
      perform public._register_identity(v_cuil, ev);   -- V4.21: solo VINCULA una foto si llega (entregas viejas en cola); la foto del DNI ya no se exige
    else
      v_cuil := nullif(regexp_replace(coalesce(ev->>'cuil', ''), '\D', '', 'g'), '');   -- Transportista Interno: CUIL opcional
      if v_cuil is not null and length(v_cuil) <> 11 then raise exception 'CUIL_INVALID: el CUIL debe tener 11 dígitos' using errcode = '23514'; end if;
    end if;
    -- RC4.1: email del receptor (segunda pantalla). Opcional; si viene, debe ser válido.
    v_email := nullif(lower(trim(coalesce(ev->>'email', ''))), '');
    -- V4.21: el email del receptor es OPCIONAL (ambos transportistas). Si viene, se valida el formato (abajo) y se genera el Recibido
    -- Conforme; si no viene, la entrega se confirma igual y NO se intenta enviar el Recibido Conforme.
    if v_email is not null and not public.is_valid_email(v_email) then raise exception 'EMAIL_INVALID: el email no es válido' using errcode = '23514'; end if;
    v_dni := nullif(regexp_replace(coalesce(ev->>'dni', ''), '\D', '', 'g'), '');
    if v_dni is null and v_cuil is not null then v_dni := substr(v_cuil, 3, 8); end if;
    if v_dni is not null and length(v_dni) not between 7 and 8 then raise exception 'DNI_INVALID: el DNI debe tener 7 u 8 dígitos' using errcode = '23514'; end if;
  end if;
  -- cobranza (Cristian): el chofer no cambia el importe esperado
  -- V4.17: la cobranza es OPCIONAL (el chofer ya no la registra). Si se informa, se valida igual que antes; si no, no se registra
  -- ningún cobro y los datos de cobranza existentes de la parada se CONSERVAN (no se inventan ni se borran).
  if v_commercial and st.task in ('COBRANZA','AMBAS') and col is not null and coalesce(col->>'status', 'PENDIENTE') <> 'PENDIENTE' then
    if col->>'status' not in ('COBRADO','COBRO_PARCIAL','NO_COBRADO') then raise exception 'BAD_COLLECTION' using errcode = '22023'; end if;
    if col->>'status' in ('COBRO_PARCIAL','NO_COBRADO') and coalesce(trim(col->>'note'), '') = '' then raise exception 'COLLECTION_NOTE_REQUIRED: cobro parcial exige observación y no cobrado exige motivo' using errcode = '23514'; end if;
    if col->>'status' in ('COBRADO','COBRO_PARCIAL') and coalesce((col->>'amount')::numeric, 0) <= 0 then raise exception 'COLLECTION_AMOUNT_REQUIRED' using errcode = '23514'; end if;
  end if;
  loc := public._loc(p_extra->'location', st);
  update public.route_stops set outcome = p_outcome, outcome_at = now(), outcome_by = auth.uid(), outcome_note = nullif(trim(p_note),''), outcome_reason = nullif(trim(p_reason),''),
    finish_location = loc, location_warning = coalesce(case when loc->>'outside_m' is not null then 'FUERA DEL RADIO (' || (loc->>'outside_m') || ' m)' end, location_warning),
    collection_status = case when st.task in ('COBRANZA','AMBAS') and coalesce(col->>'status','PENDIENTE') <> 'PENDIENTE' then col->>'status' else collection_status end,
    collected_amount = case when st.task in ('COBRANZA','AMBAS') and coalesce(col->>'status','PENDIENTE') <> 'PENDIENTE' then nullif(col->>'amount','')::numeric else collected_amount end,
    payment_mode = case when st.task in ('COBRANZA','AMBAS') and coalesce(col->>'status','PENDIENTE') <> 'PENDIENTE' then col->>'mode' else payment_mode end,
    collection_note = case when st.task in ('COBRANZA','AMBAS') and coalesce(col->>'status','PENDIENTE') <> 'PENDIENTE' then nullif(trim(col->>'note'),'') else collection_note end
  where id = p_stop returning * into st;
  if p_outcome in ('ENTREGADO','ENTREGA_PARCIAL') then
    -- La entrega guarda el email USADO (inmutable aunque el perfil cambie después)
    if sig is not null then
      insert into public.stop_evidence(stop_id, receiver_name, signature_png, signature_sha256, receiver_cuil, created_by, receiver_email, receiver_dni, evidence_kind)
      values (p_stop, coalesce(nullif(trim(ev->>'receiver_name'), ''), 'Sin receptor (tarea)'), sig, encode(sha256(sig), 'hex'), v_cuil, auth.uid(), case when v_commercial then v_email end, v_dni,
              case when st.stop_type = 'UBICACION_INTERNA' then 'RECEPCION_INTERNA' when v_task then 'TAREA' else 'ENTREGA_CLIENTE' end)
      on conflict (stop_id) do nothing;
    end if;
    -- RECEPCIÓN INTERNA DE TRASLADO: queda trazado qué pedidos llegaron a qué sucursal, quién recibió, quién trasladó, cuándo y dónde
    if st.stop_type = 'UBICACION_INTERNA' then
      insert into public.audit_log(actor_id, action, target_type, target_id, after)
      values (auth.uid(), 'INTERNAL_TRANSFER_RECEIVED', 'route_stop', p_stop::text, jsonb_build_object(
        'route_id', st.route_id, 'route_number', r.number, 'internal_location_key', st.internal_location_key, 'location_name', st.client_name, 'address', st.address,
        'order_numbers', to_jsonb(st.order_numbers), 'outcome', p_outcome, 'receiver_name', trim(ev->>'receiver_name'), 'signature_sha256', encode(sha256(sig), 'hex'),
        'transported_by', auth.uid(), 'at', now(), 'gps', loc));
    end if;
    -- Perfil reutilizable (misma capa de identidad que el DNI): nombre, DNI y email para próximas entregas
    if v_commercial and v_cuil is not null then perform public._upsert_identity_profile(v_cuil, trim(ev->>'receiver_name'), v_dni, v_email, st.client_key); end if;
    -- Recibido Conforme: entrega TOTAL confirmada + email válido → comprobante único + envío automático (la falla del email nunca revierte la entrega)
    if v_commercial and p_outcome = 'ENTREGADO' and v_email is not null then perform public._create_delivery_receipt(st, r, trim(ev->>'receiver_name'), v_email); v_receipt := true; end if;
    if v_commercial and coalesce(trim(st.customer_email), '') <> '' and not v_receipt then
      insert into public.customer_email_jobs(route_id, stop_id, kind, recipient, idempotency_key)
      values (st.route_id, st.id, case when p_outcome = 'ENTREGADO' then 'DELIVERED' else 'PARTIAL' end, lower(trim(st.customer_email)), st.route_id || '|' || st.id || '|' || case when p_outcome = 'ENTREGADO' then 'DELIVERED' else 'PARTIAL' end)
      on conflict (idempotency_key) do nothing;
    end if;
  end if;
  if p_op_id is not null then insert into public.stop_outcome_ops(op_id, stop_id) values (p_op_id, p_stop); end if;
  perform public._queue_on_the_way(st.route_id);
  return st;
end; $function$;
create or replace function public.delivery_identity_lookup(p_stop uuid, p_cuil text default null, p_dni text default null) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare st public.route_stops; r public.routes; p public.customer_identity_docs; c text := nullif(regexp_replace(coalesce(p_cuil,''), '\D', '', 'g'), ''); d text := nullif(regexp_replace(coalesce(p_dni,''), '\D', '', 'g'), ''); ev record;
begin
  select * into st from public.route_stops where id = p_stop;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  select * into r from public.routes where id = st.route_id;
  if not (r.responsable_id = auth.uid() or public.auth_is_admin()) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if c is not null then select * into p from public.customer_identity_docs where cuil = c; end if;
  if p.cuil is null and d is not null then select * into p from public.customer_identity_docs where dni = d order by updated_at desc nulls last limit 1; end if;
  if p.cuil is not null then
    return jsonb_build_object('source', case when c is not null and p.cuil = c then 'CUIL' else 'DNI' end, 'cuil', p.cuil, 'dni', p.dni, 'full_name', p.full_name, 'email', p.email,
      'has_dni_photo', p.storage_path is not null or p.dni_photo is not null);
  end if;
  if coalesce(st.client_key, '') <> '' then
    select e.receiver_name, e.receiver_email, e.receiver_cuil, e.receiver_dni into ev from public.stop_evidence e join public.route_stops s2 on s2.id = e.stop_id
      where s2.client_key = st.client_key and e.receiver_email is not null order by e.created_at desc limit 1;
    if ev.receiver_email is not null then
      return jsonb_build_object('source', 'CLIENTE', 'cuil', ev.receiver_cuil, 'dni', ev.receiver_dni, 'full_name', ev.receiver_name, 'email', ev.receiver_email,
        'has_dni_photo', ev.receiver_cuil is not null and exists (select 1 from public.customer_identity_docs x where x.cuil = ev.receiver_cuil and (x.storage_path is not null or x.dni_photo is not null)));
    end if;
  end if;
  return null;
end; $$;
create or replace function public.search_deliveries(p_query text) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me public.profiles; q text := btrim(coalesce(p_query, '')); dg text; qpv text; qnum text; sig boolean; out jsonb := '[]'; rec record;
begin
  select * into me from public.profiles where id = auth.uid() and status = 'ACTIVO';
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  dg := regexp_replace(q, '\D', '', 'g');
  if length(dg) < 3 and q !~ '^[0-9]{2}-[0-9]{6}$' then raise exception 'QUERY_TOO_SHORT: ingresá al menos 3 dígitos' using errcode = '22023'; end if;
  qnum := ltrim(case when q ~ '-' then split_part(regexp_replace(q, '[^0-9-]', '', 'g'), '-', 2) else dg end, '0');
  qpv := case when q ~ '-' then ltrim(split_part(regexp_replace(q, '[^0-9-]', '', 'g'), '-', 1), '0') end;
  sig := false; -- Se verifica por hoja con la MISMA protección de las políticas RLS vigentes.
  for rec in
    select r.id rid, r.number, r.operational_status, r.published_at, r.started_at, r.completed_at, r.carrier_id, c.name carrier_name, rp.full_name responsable_name,
           s.id sid, s.client_name, s.address, s.order_numbers, s.outcome, s.outcome_note, s.arrived_at, s.stop_type,
           (select x->'r'->>'fecha' from jsonb_array_elements(coalesce(r.sheet_snapshot->'pdf_model'->'data', '[]')) x where x->'r' ? 'fecha' limit 1) sheet_date,
           (select string_agg(distinct d, ' · ') from jsonb_array_elements(coalesce(r.sheet_snapshot->'pdf_model'->'data', '[]')) x, lateral (values (x->'r'->>'mainDoc'), (x->'r'->>'shipDoc')) v(d)
              where d is not null and d <> '' and (x->'r'->>'mainOrder' = any(s.order_numbers) or x->'r'->>'shipOrder' = any(s.order_numbers))) docs,
           ev.receiver_name, ev.receiver_cuil, ev.created_at received_at, (ev.stop_id is not null) has_signature, dr.receipt_number, dr.generated_at receipt_at
      from public.route_stops s join public.routes r on r.id = s.route_id left join public.carriers c on c.id = r.carrier_id left join public.profiles rp on rp.id = r.responsable_id
      left join public.stop_evidence ev on ev.stop_id = s.id left join public.delivery_receipts dr on dr.stop_id = s.id
     where r.operational_status <> 'BORRADOR' and coalesce(s.stop_type, 'PEDIDO') = 'PEDIDO'
       and (public._is_general_admin() or public.can_view_route_row(r.id, r.published_by, r.responsable_id))   -- SOLO hojas que el usuario puede ver (equipo / propias / todas)
       and ( dg = any(s.order_numbers) or r.number = q
          or exists (select 1 from jsonb_array_elements(coalesce(r.sheet_snapshot->'pdf_model'->'data', '[]')) x, lateral (values (x->'r'->>'mainDoc', x->'r'->>'mainOrder'), (x->'r'->>'shipDoc', x->'r'->>'shipOrder')) v(d, o)
                      where o = any(s.order_numbers) and d is not null and qnum <> ''
                        and ltrim(split_part(regexp_replace(d, '[^0-9-]', '', 'g'), '-', 2), '0') = qnum
                        and (qpv is null or ltrim(split_part(regexp_replace(d, '[^0-9-]', '', 'g'), '-', 1), '0') = qpv)) )
     order by r.published_at desc limit 30
  loop
    sig:=okd_delivery_security.may_read(rec.rid) and (public._is_general_admin() or public.can_view_route(rec.rid));
    out := out || jsonb_build_object('route_id', rec.rid, 'route_number', rec.number, 'route_status', rec.operational_status, 'carrier', coalesce(rec.carrier_name, rec.carrier_id), 'responsable', rec.responsable_name,
      'published_at', rec.published_at, 'started_at', rec.started_at, 'completed_at', rec.completed_at, 'sheet_date', rec.sheet_date,
      'stop_id', rec.sid, 'client_name', rec.client_name, 'address', rec.address, 'order_numbers', to_jsonb(rec.order_numbers), 'docs', rec.docs,
      'outcome', rec.outcome, 'outcome_note', rec.outcome_note, 'arrived_at', rec.arrived_at, 'received_at', rec.received_at,
      'has_receipt', rec.receipt_number is not null, 'signatures_visible', sig,
      -- datos personales y constancia SOLO con signatures.view (los demás ven el estado, no quién firmó)
      'receiver_name', case when sig then rec.receiver_name end, 'receiver_cuil', case when sig then rec.receiver_cuil end,
      'has_signature', case when sig then rec.has_signature end, 'receipt_number', case when sig then rec.receipt_number end, 'receipt_at', case when sig then rec.receipt_at end);
  end loop;
  return out;
end; $$;
drop function if exists public.add_stop_followup(uuid,text,text,uuid,text);
drop function if exists public.route_change_history(uuid);
drop function if exists public.list_receiver_doc_reviews(text);
drop function if exists public.correct_receiver_doc(uuid,text,text,text,boolean);
COMMIT;
