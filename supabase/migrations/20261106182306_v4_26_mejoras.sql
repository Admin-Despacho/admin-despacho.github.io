-- =====================================================================================================================
-- PROPUESTA V4.26 · NO APLICADA · Mejoras aprobadas: padrón de correos de clientes · «Tu pedido está en camino» · BUSCAR ENTREGA
-- DEPENDE de V4.23 (client_emails, _cuit_valid, _is_general_admin) y de las tablas base de entregas. Aditiva: NO modifica funciones existentes
-- (la sugerencia de correo de V4.23 queda igual; se agrega delivery_email_suggestion2). Una transacción; si ya está aplicada, se detiene.
-- =====================================================================================================================
BEGIN;
DO $guard$ BEGIN
  IF to_regclass('public.client_email_aliases') IS NOT NULL OR to_regprocedure('public.search_deliveries(text)') IS NOT NULL THEN
    RAISE EXCEPTION 'YA_APLICADA: la V4.26 ya existe. No se modificó nada.'; END IF;
  IF to_regclass('public.client_emails') IS NULL OR to_regprocedure('public._cuit_valid(text)') IS NULL OR to_regprocedure('public._is_general_admin()') IS NULL THEN
    RAISE EXCEPTION 'DEPENDENCIA_FALTANTE: falta la V4.23 (client_emails / _cuit_valid / _is_general_admin). No se modificó nada.'; END IF;
  IF to_regprocedure('okd_delivery_security.may_read(uuid)') IS NULL THEN RAISE EXCEPTION 'DEPENDENCIA_FALTANTE: protección vigente de firmas por equipo';END IF;
  IF (select md5(prosrc) from pg_proc where oid='public.finalize_route(uuid,numeric)'::regprocedure)<>'5bdf85adab176a36ec9b55ceb1af3179' THEN RAISE EXCEPTION 'PRECONDITION_FAILED: finalize_route';END IF;
  IF current_setting('server_encoding') <> 'UTF8' THEN RAISE EXCEPTION 'CODIFICACION: la base no está en UTF8; la normalización de nombres del padrón lo requiere. No se modificó nada.'; END IF;
  IF to_regclass('public.customer_email_jobs') IS NULL OR to_regclass('public.stop_evidence') IS NULL OR to_regprocedure('public.can_view_route_row(uuid,uuid,uuid)') IS NULL OR to_regprocedure('public.auth_has_perm(text)') IS NULL THEN
    RAISE EXCEPTION 'DEPENDENCIA_FALTANTE: tablas o funciones base de entregas. No se modificó nada.'; END IF;
END $guard$;

-- El nuevo circuito queda apagado. La autorización de publicación no autoriza envíos reales.
alter table public.notification_settings add column departure_notice_enabled boolean not null default false;
alter table public.notification_settings add column departure_notice_active_since timestamptz;

-- ---------- 1) PADRÓN: claves alternativas (DNI y NOMBRE exacto) ----------
-- Normalización IDÉNTICA a Normalizer.name del constructor: sin acentos, MAYÚSCULAS, solo A-Z0-9 separados por un espacio.
create or replace function public._okd_norm_name(s text) returns text language sql immutable set search_path = public as $$
  select btrim(regexp_replace(upper(translate(coalesce(s, ''),
    'áàäâãåÁÀÄÂÃÅéèëêÉÈËÊíìïîÍÌÏÎóòöôõÓÒÖÔÕúùüûÚÙÜÛñÑçÇ', 'aaaaaaAAAAAAeeeeEEEEiiiiIIIIoooooOOOOOuuuuUUUUnNcC')), '[^A-Z0-9]+', ' ', 'g')) $$;
create table public.client_email_aliases (
  key_type text not null check (key_type in ('DNI','NOMBRE')),
  key_value text not null check ((key_type = 'DNI' and key_value ~ '^[0-9]{7,8}$') or (key_type = 'NOMBRE' and key_value ~ '^[A-Z0-9]+( [A-Z0-9]+)+$')),
  email text not null check (public.is_valid_email(email)), client_name text,
  source text not null default 'PADRON' check (source in ('PADRON','MANUAL')), import_id bigint, updated_at timestamptz not null default now(), updated_by uuid,
  primary key (key_type, key_value));
create table public.client_padron_imports (
  id bigint generated always as identity primary key, at timestamptz not null default now(), by_user uuid not null, file_name text,
  counts jsonb not null, rejected jsonb not null default '[]');

-- correo del padrón para una parada: CUIT (V4.23, manuales incluidos) → DNI → NOMBRE exacto (clave del constructor o nombre del cliente)
create or replace function public._client_email_for(p_client_key text, p_client_name text) returns text language sql stable security definer set search_path = public as $$
  select coalesce(
    (select email from public.client_emails where cuit = p_client_key),
    (select email from public.client_email_aliases where key_type = 'DNI' and key_value = p_client_key and p_client_key ~ '^[0-9]{7,8}$'),
    (select email from public.client_email_aliases where key_type = 'NOMBRE' and key_value = public._okd_norm_name(p_client_key)),
    (select email from public.client_email_aliases where key_type = 'NOMBRE' and key_value = public._okd_norm_name(p_client_name))) $$;

-- sugerencia durante la entrega (la de V4.23 no se toca): mismo control de acceso (_my_route) y mismo orden: el correo de la hoja manda
create or replace function public.delivery_email_suggestion2(p_stop uuid) returns text language plpgsql stable security definer set search_path = public as $$
declare st public.route_stops; r public.routes;
begin
  select * into st from public.route_stops where id = p_stop; if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  r := public._my_route(st.route_id);
  if coalesce(st.stop_type, 'PEDIDO') <> 'PEDIDO' then return null; end if;
  return coalesce(nullif(trim(st.customer_email), ''), public._client_email_for(st.client_key, st.client_name));
end; $$;

-- importación del padrón (Administrador General ACTIVO). El servidor RE-VALIDA cada fila; modo CONSERVAR: nunca pisa un correo existente
-- (manuales ni importados). Un mismo NOMBRE o DNI que llegue con correos distintos se considera AMBIGUO y no se asocia.
create or replace function public.client_padron_import(p jsonb, p_apply boolean) returns jsonb language plpgsql security definer set search_path = public as $$
declare x jsonb; t text; k text; e text; n text; ins int := 0; kept int := 0; rej jsonb := '[]'; amb text[]; imp bigint; c jsonb; seen text[]:='{}';
begin
  if not public._is_general_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if jsonb_typeof(p->'rows') <> 'array' then raise exception 'ROWS_REQUIRED' using errcode = '22023'; end if;
  -- claves que llegan con más de un correo distinto: ambiguas
  select coalesce(array_agg(tk), '{}') into amb from (
    select upper(r->>'tipo') || '|' || (case when upper(r->>'tipo') = 'NOMBRE' then public._okd_norm_name(r->>'clave') else regexp_replace(coalesce(r->>'clave',''),'\D','','g') end) tk
      from jsonb_array_elements(p->'rows') r group by 1 having count(distinct lower(trim(r->>'email'))) > 1) a;
  if p_apply then insert into public.client_padron_imports(by_user, file_name, counts) values (auth.uid(), p->>'file_name', '{}') returning id into imp; end if;
  for x in select * from jsonb_array_elements(p->'rows') loop
    t := upper(coalesce(x->>'tipo', '')); e := lower(trim(coalesce(x->>'email', ''))); n := nullif(trim(coalesce(x->>'nombre', '')), '');
    k := case when t = 'NOMBRE' then public._okd_norm_name(x->>'clave') else regexp_replace(coalesce(x->>'clave', ''), '\D', '', 'g') end;
    if not public.is_valid_email(e) then rej := rej || jsonb_build_object('fila', x->'fila', 'motivo', 'correo inválido'); continue; end if;
    if (t || '|' || k) = any(amb) then rej := rej || jsonb_build_object('fila', x->'fila', 'motivo', 'clave con correos distintos (ambigua)'); continue; end if;
    if (t||'|'||k)=any(seen) then kept:=kept+1;continue;end if;seen:=seen||(t||'|'||k);
    if t = 'CUIT' then
      if not public._cuit_valid(k) then rej := rej || jsonb_build_object('fila', x->'fila', 'motivo', 'CUIT/CUIL inválido'); continue; end if;
      if exists (select 1 from public.client_emails where cuit = k) then kept := kept + 1; continue; end if;
      if p_apply then insert into public.client_emails(cuit, client_name, email, source, updated_by) values (k, n, e, 'EXCEL', auth.uid()); end if; ins := ins + 1;
    elsif t = 'DNI' or t = 'NOMBRE' then
      if (t = 'DNI' and k !~ '^[0-9]{7,8}$') or (t = 'NOMBRE' and k !~ '^[A-Z0-9]+( [A-Z0-9]+)+$') then rej := rej || jsonb_build_object('fila', x->'fila', 'motivo', t || ' con formato inválido'); continue; end if;
      if exists (select 1 from public.client_email_aliases where key_type = t and key_value = k) then kept := kept + 1; continue; end if;
      if p_apply then insert into public.client_email_aliases(key_type, key_value, email, client_name, import_id, updated_by) values (t, k, e, n, imp, auth.uid()); end if; ins := ins + 1;
    else rej := rej || jsonb_build_object('fila', x->'fila', 'motivo', 'tipo de clave desconocido'); end if;
  end loop;
  c := jsonb_build_object('nuevos', ins, 'conservados_existentes', kept, 'rechazados', jsonb_array_length(rej));
  if p_apply then update public.client_padron_imports set counts = c, rejected = rej where id = imp;
    insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'CLIENT_PADRON_IMPORT', 'client_padron_imports', imp::text, c); end if;
  return c || jsonb_build_object('rechazos', rej, 'aplicado', p_apply);
end; $$;

-- ---------- 2) «TU PEDIDO ESTÁ EN CAMINO»: al confirmarse la SALIDA REAL (started_at), para cada cliente/parada pendiente con correo y todos sus pedidos ----------
-- Reutiliza la cola existente (customer_email_jobs) y la MISMA clave idempotente que el aviso de próxima parada (ruta|parada|ON_THE_WAY):
-- como máximo UN aviso por cliente/parada y hoja, incluyendo todos sus pedidos. Solo en la transición (no reenvía hojas ya iniciadas). Sin correo → no se encola.
create or replace function public.trg_route_departure_notice() returns trigger language plpgsql security definer set search_path = public as $$
declare s public.route_stops; e text;
begin
  if old.started_at is null and new.started_at is not null and exists(select 1 from public.notification_settings where id='DEFAULT' and departure_notice_enabled and on_the_way_enabled and departure_notice_active_since is not null and new.started_at>=departure_notice_active_since) then
    for s in select * from public.route_stops where route_id = new.id and outcome = 'PENDIENTE' and coalesce(stop_type, 'PEDIDO') = 'PEDIDO' loop
      e := lower(trim(coalesce(nullif(trim(s.customer_email), ''), public._client_email_for(s.client_key, s.client_name), '')));
      if public.is_valid_email(e) then
        insert into public.customer_email_jobs(route_id, stop_id, kind, recipient, idempotency_key)
        values (new.id, s.id, 'ON_THE_WAY', e, new.id || '|' || s.id || '|ON_THE_WAY') on conflict (idempotency_key) do nothing;
      end if;
    end loop;
  end if;
  return new;
end; $$;
create trigger routes_zz_departure_notice after update of started_at on public.routes for each row execute function public.trg_route_departure_notice();

-- ---------- 3) BUSCAR ENTREGA: por pedido web, factura/NDP (snapshot publicado) o número de hoja; MISMA visibilidad que las hojas ----------
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

-- ---------- 4) Privilegios ----------
alter table public.client_email_aliases enable row level security; alter table public.client_padron_imports enable row level security;
do $$ declare t text; f text; begin
  foreach t in array array['client_email_aliases','client_padron_imports'] loop execute format('revoke all on table public.%I from public, anon, authenticated', t); end loop;
  foreach f in array array['delivery_email_suggestion2(uuid)','client_padron_import(jsonb,boolean)','search_deliveries(text)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon'; execute 'grant execute on function public.' || f || ' to authenticated'; end loop;
  foreach f in array array['_client_email_for(text,text)','trg_route_departure_notice()'] loop execute 'revoke all on function public.' || f || ' from public, anon, authenticated'; end loop;
end $$;
DO $post$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'routes_zz_departure_notice') THEN RAISE EXCEPTION 'HUELLA_FINAL_INESPERADA'; END IF;
END $post$;
COMMIT;
