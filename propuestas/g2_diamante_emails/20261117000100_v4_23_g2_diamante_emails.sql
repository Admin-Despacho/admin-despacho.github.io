-- =====================================================================================================================
-- PROPUESTA V4.23 · NO APLICADA · G2 (TERMINÉ EN la ubicación) + regreso obligatorio a DEPÓSITO DIAMANTE + padrón de EMAILS DE CLIENTES
-- DEPENDE de la V4.21 (set_stop_outcome 5d26e5af27a068596cc6875bd6ee8bbf): aplicar DESPUÉS de la V4.21. Verificar antes con VERIFICAR_PRODUCCION_SOLO_LECTURA.sql.
-- Cambia UNA función existente: finalize_route (base exacta c5bc9e2f98853281bebfeb6151b7d119) → agrega SOLO la exigencia de LLEGUÉ A DIAMANTE para hojas del
--   Transportista Interno INICIADAS desde que se aplica (las hojas en curso no se bloquean). Todo lo demás de finalize_route queda igual.
-- Agrega: columnas de fin de visita y de llegada al depósito, finish_internal_location, arrive_depot, configuración del depósito (sin clave
--   inventada: elegido por un administrador o la ÚNICA ubicación activa "DIAMANTE"), y el padrón de emails por CUIT validado con RLS.
-- No borra ni modifica datos existentes. Todo en UNA transacción, con verificación previa y final de huellas.
-- =====================================================================================================================
BEGIN;
DO $guard$ BEGIN
  IF (SELECT md5(prosrc) FROM pg_proc WHERE proname = 'set_stop_outcome' AND pronamespace = 'public'::regnamespace) IS DISTINCT FROM '5d26e5af27a068596cc6875bd6ee8bbf' THEN
    RAISE EXCEPTION 'HUELLA_INESPERADA: set_stop_outcome no es la V4.21: aplicá primero la V4.21. No se modificó nada.'; END IF;
  IF (SELECT md5(prosrc) FROM pg_proc WHERE proname = 'finalize_route' AND pronamespace = 'public'::regnamespace) IS DISTINCT FROM 'c5bc9e2f98853281bebfeb6151b7d119' THEN
    RAISE EXCEPTION 'HUELLA_INESPERADA: finalize_route no es la versión esperada (c5bc9e2f98853281bebfeb6151b7d119); es %. No se modificó nada.', (SELECT md5(prosrc) FROM pg_proc WHERE proname = 'finalize_route' AND pronamespace = 'public'::regnamespace); END IF;
  IF to_regprocedure('public._loc(jsonb, public.route_stops)') IS NULL THEN RAISE EXCEPTION 'DEPENDENCIA_FALTANTE: public._loc. No se modificó nada.'; END IF;
END $guard$;

-- ---------- 1) Montecaseros / San Juan: fin de la visita a una ubicación interna (no cierra la hoja ni cambia resultados) ----------
alter table public.route_stops add column if not exists location_finished_at timestamptz;
alter table public.route_stops add column if not exists location_finished_location jsonb;
alter table public.route_stops add column if not exists location_finished_by uuid;
create or replace function public.finish_internal_location(p_stop uuid, p_location jsonb, p_op_id text) returns public.route_stops
language plpgsql security definer set search_path = public as $$
declare st public.route_stops; r public.routes; loc jsonb;
begin
  select * into st from public.route_stops where id = p_stop; if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  r := public._my_route(st.route_id);
  if r.operational_status <> 'EN_CURSO' then raise exception 'BAD_STATE' using errcode = '23514'; end if;
  if coalesce(st.stop_type, 'PEDIDO') <> 'UBICACION_INTERNA' then raise exception 'NOT_INTERNAL_LOCATION: solo para ubicaciones internas' using errcode = '23514'; end if;
  if st.location_finished_at is not null then return st; end if;   -- idempotente (reintento sin conexión, doble toque)
  if st.arrived_at is null then raise exception 'ARRIVE_FIRST: registrá primero la llegada a la ubicación' using errcode = '23514'; end if;
  if st.outcome = 'PENDIENTE' then raise exception 'RESOLVE_FIRST: resolvé la recepción antes de terminar en la ubicación' using errcode = '23514'; end if;
  loc := public._loc(p_location, st);
  update public.route_stops set location_finished_at = now(), location_finished_location = loc, location_finished_by = auth.uid() where id = p_stop returning * into st;
  return st;
end; $$;

-- ---------- 2) DEPÓSITO DIAMANTE: llegada obligatoria antes de finalizar la hoja del Transportista Interno ----------
alter table public.routes add column if not exists depot_arrived_at timestamptz;
alter table public.routes add column if not exists depot_location jsonb;
alter table public.routes add column if not exists depot_location_key text;
-- Qué ubicación EXISTENTE es el depósito de regreso (sin clave inventada) y desde cuándo rige la regla (las hojas ya iniciadas no se bloquean)
create table if not exists public.return_depot_settings (
  id text primary key default 'DEFAULT' check (id = 'DEFAULT'),
  location_key text references public.internal_locations(location_key),
  required_since timestamptz not null default now(),
  updated_at timestamptz not null default now(), updated_by uuid);
insert into public.return_depot_settings(id) values ('DEFAULT') on conflict (id) do nothing;
alter table public.return_depot_settings enable row level security;
-- Elegida por un administrador; si no, la ÚNICA ubicación activa cuyo nombre o clave contiene DIAMANTE. Varias o ninguna → null (no se adivina).
create or replace function public._return_depot() returns public.internal_locations language plpgsql stable security definer set search_path = public as $$
declare d public.internal_locations; k text; n int;
begin
  select location_key into k from public.return_depot_settings where id = 'DEFAULT';
  if k is not null then select * into d from public.internal_locations where location_key = k and active; return d; end if;
  select count(*) into n from public.internal_locations where active and (name ilike '%diamante%' or location_key ilike '%diamante%');
  if n = 1 then select * into d from public.internal_locations where active and (name ilike '%diamante%' or location_key ilike '%diamante%'); end if;
  return d;
end; $$;
create or replace function public.return_depot_status() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d public.internal_locations; s public.return_depot_settings;
begin
  if not public.auth_has_perm('settings.manage') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into s from public.return_depot_settings where id = 'DEFAULT'; d := public._return_depot();
  return jsonb_build_object('selected_key', s.location_key, 'required_since', s.required_since,
    'resolved', case when d.location_key is null then null else jsonb_build_object('location_key', d.location_key, 'name', d.name, 'lat', d.lat, 'lon', d.lon, 'radius_m', d.radius_m) end,
    'candidates', coalesce((select jsonb_agg(jsonb_build_object('location_key', l.location_key, 'name', l.name, 'radius_m', l.radius_m, 'active', l.active) order by l.name)
                            from public.internal_locations l where l.name ilike '%diamante%' or l.location_key ilike '%diamante%'), '[]'::jsonb));
end; $$;
create or replace function public.set_return_depot(p_location_key text) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.auth_has_perm('settings.manage') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_location_key is not null and not exists (select 1 from public.internal_locations where location_key = p_location_key and active) then
    raise exception 'LOCATION_NOT_FOUND: la ubicación no existe o está inactiva' using errcode = '23514'; end if;
  update public.return_depot_settings set location_key = p_location_key, updated_at = now(), updated_by = auth.uid() where id = 'DEFAULT';
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'RETURN_DEPOT_SET', 'settings', 'return_depot', jsonb_build_object('location_key', p_location_key));
  return public.return_depot_status();
end; $$;
create or replace function public.arrive_depot(p_route uuid, p_location jsonb, p_op_id text) returns public.routes
language plpgsql security definer set search_path = public as $$
declare r public.routes; d public.internal_locations; ref public.route_stops; loc jsonb; pend int;
begin
  r := public._my_route(p_route);
  if r.operational_status <> 'EN_CURSO' then raise exception 'BAD_STATE' using errcode = '23514'; end if;
  if not exists (select 1 from public.carriers c where c.id = r.carrier_id and c.kind = 'INTERNO') then raise exception 'NOT_INTERNAL: solo el Transportista Interno registra el regreso al depósito' using errcode = '23514'; end if;
  if r.depot_arrived_at is not null then return r; end if;   -- idempotente (reintento sin conexión, doble toque)
  select count(*) into pend from public.route_stops where route_id = p_route and outcome = 'PENDIENTE';
  if pend > 0 then raise exception 'PENDING_STOPS: faltan % paradas por resolver antes de volver al depósito', pend using errcode = '23514'; end if;
  d := public._return_depot();
  if d.location_key is null then raise exception 'DEPOT_NOT_CONFIGURED: falta elegir la ubicación del depósito de regreso en Configuración' using errcode = '23514'; end if;
  ref.expected_lat := d.lat; ref.expected_lon := d.lon; ref.expected_radius_m := d.radius_m;   -- mismo control de radio y advertencias que las paradas
  loc := public._loc(p_location, ref);
  update public.routes set depot_arrived_at = now(), depot_location = loc, depot_location_key = d.location_key where id = p_route returning * into r;
  return r;
end; $$;

-- ---------- 3) Padrón de EMAILS DE CLIENTES por CUIT validado (no hay código de cliente en los Excel de origen) ----------
create or replace function public._cuit_valid(p text) returns boolean language plpgsql immutable as $$
declare d int[]; w int[] := array[5,4,3,2,7,6,5,4,3,2]; s int := 0; v int; i int;
begin
  if p is null or p !~ '^\d{11}$' then return false; end if;
  for i in 1..11 loop d[i] := substr(p, i, 1)::int; end loop;
  for i in 1..10 loop s := s + d[i] * w[i]; end loop;
  v := 11 - (s % 11); if v = 11 then v := 0; elsif v = 10 then return false; end if;
  return d[11] = v;
end; $$;
create table if not exists public.client_emails (
  cuit text primary key check (public._cuit_valid(cuit)),
  client_name text, email text not null check (public.is_valid_email(email)),
  source text not null default 'MANUAL' check (source in ('MANUAL','EXCEL')),
  updated_at timestamptz not null default now(), updated_by uuid);
create table if not exists public.client_email_imports (
  id bigint generated always as identity primary key, imported_at timestamptz not null default now(), imported_by uuid,
  file_name text, mode text not null check (mode in ('CONSERVAR','REEMPLAZAR')), summary jsonb not null);
alter table public.client_emails enable row level security; alter table public.client_email_imports enable row level security;
create or replace function public._is_general_admin() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'ADMIN' and status = 'ACTIVO'); $$;
drop policy if exists client_emails_admin_read on public.client_emails;
create policy client_emails_admin_read on public.client_emails for select to authenticated using (public._is_general_admin());
drop policy if exists client_email_imports_admin_read on public.client_email_imports;
create policy client_email_imports_admin_read on public.client_email_imports for select to authenticated using (public._is_general_admin());
-- Analiza filas del Excel SIN escribir: CUIT válido, email válido, duplicados, desconocidos (CUIT que nunca figuró en una hoja), nuevos y a actualizar
create or replace function public.client_emails_preview(p_rows jsonb) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare out jsonb := '[]'::jsonb; x jsonb; c text; e text; st text; seen text[] := '{}'; dup text[] := '{}'; cur text;
begin
  if not public._is_general_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  for x in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    c := regexp_replace(coalesce(x->>'cuit', ''), '\D', '', 'g'); if c = any(seen) then dup := dup || c; end if; seen := seen || c; end loop;
  for x in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    c := regexp_replace(coalesce(x->>'cuit', ''), '\D', '', 'g'); e := nullif(lower(trim(coalesce(x->>'email', ''))), '');
    select email into cur from public.client_emails where cuit = c;
    st := case when not public._cuit_valid(c) then 'CUIT_INVALIDO' when c = any(dup) then 'DUPLICADO' when e is null then 'SIN_EMAIL'
               when not public.is_valid_email(e) then 'EMAIL_INVALIDO'
               when not exists (select 1 from public.route_stops s where s.client_key = c) and cur is null then 'DESCONOCIDO'
               when cur is null then 'NUEVO' when cur = e then 'SIN_CAMBIOS' else 'ACTUALIZAR' end;
    out := out || jsonb_build_array(jsonb_build_object('cuit', c, 'name', x->>'name', 'email', e, 'actual', cur, 'estado', st));
  end loop;
  return jsonb_build_object('filas', out, 'resumen', (select jsonb_object_agg(k, n) from (select f->>'estado' k, count(*) n from jsonb_array_elements(out) f group by 1) z));
end; $$;
-- Aplica: NUEVO siempre; ACTUALIZAR solo con REEMPLAZAR; nunca borra (celdas vacías no eliminan); no crea clientes; registra la importación
create or replace function public.client_emails_apply(p_rows jsonb, p_mode text, p_file text) returns jsonb language plpgsql security definer set search_path = public as $$
declare pv jsonb; f jsonb; ins int := 0; upd int := 0;
begin
  if not public._is_general_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_mode not in ('CONSERVAR','REEMPLAZAR') then raise exception 'MODO_INVALIDO' using errcode = '22023'; end if;
  pv := public.client_emails_preview(p_rows);
  for f in select * from jsonb_array_elements(pv->'filas') loop
    if f->>'estado' = 'NUEVO' then
      insert into public.client_emails(cuit, client_name, email, source, updated_by) values (f->>'cuit', nullif(f->>'name', ''), f->>'email', 'EXCEL', auth.uid()); ins := ins + 1;
    elsif f->>'estado' = 'ACTUALIZAR' and p_mode = 'REEMPLAZAR' then
      update public.client_emails set email = f->>'email', client_name = coalesce(nullif(f->>'name', ''), client_name), source = 'EXCEL', updated_at = now(), updated_by = auth.uid() where cuit = f->>'cuit'; upd := upd + 1;
    end if;
  end loop;
  insert into public.client_email_imports(imported_by, file_name, mode, summary) values (auth.uid(), p_file, p_mode, (pv->'resumen') || jsonb_build_object('insertados', ins, 'actualizados', upd));
  return (pv->'resumen') || jsonb_build_object('insertados', ins, 'actualizados', upd);
end; $$;
create or replace function public.client_email_upsert(p_cuit text, p_name text, p_email text) returns public.client_emails language plpgsql security definer set search_path = public as $$
declare c text := regexp_replace(coalesce(p_cuit, ''), '\D', '', 'g'); e text := nullif(lower(trim(coalesce(p_email, ''))), ''); r public.client_emails;
begin
  if not public._is_general_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if not public._cuit_valid(c) then raise exception 'CUIT_INVALIDO: el CUIT no es válido' using errcode = '23514'; end if;
  if e is null or not public.is_valid_email(e) then raise exception 'EMAIL_INVALID: el email no es válido' using errcode = '23514'; end if;
  insert into public.client_emails(cuit, client_name, email, source, updated_by) values (c, nullif(trim(p_name), ''), e, 'MANUAL', auth.uid())
  on conflict (cuit) do update set email = excluded.email, client_name = coalesce(excluded.client_name, public.client_emails.client_name), source = 'MANUAL', updated_at = now(), updated_by = auth.uid()
  returning * into r;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'CLIENT_EMAIL_SET', 'client_email', c, to_jsonb(r));
  return r;
end; $$;
-- Para el TRANSPORTISTA: SOLO el email sugerido de SU parada (nunca el padrón). Prioridad: el de la hoja; si no, el del padrón por CUIT.
create or replace function public.delivery_email_suggestion(p_stop uuid) returns text language plpgsql stable security definer set search_path = public as $$
declare st public.route_stops; r public.routes;
begin
  select * into st from public.route_stops where id = p_stop; if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  r := public._my_route(st.route_id);
  if coalesce(st.stop_type, 'PEDIDO') <> 'PEDIDO' then return null; end if;
  return coalesce(nullif(trim(st.customer_email), ''), (select email from public.client_emails where cuit = st.client_key));
end; $$;

-- ---------- 4) Privilegios: solo lo necesario (revocando lo heredado sobre los objetos NUEVOS) ----------
do $$ declare t text; f text; begin
  foreach t in array array['return_depot_settings','client_emails','client_email_imports'] loop execute format('revoke all on table public.%I from public, anon, authenticated', t); end loop;
  grant select on table public.client_emails, public.client_email_imports to authenticated;   -- filtrado por RLS: solo el Administrador General
  execute 'revoke all on sequence public.client_email_imports_id_seq from public, anon, authenticated';
  foreach f in array array['finish_internal_location(uuid,jsonb,text)','arrive_depot(uuid,jsonb,text)','return_depot_status()','set_return_depot(text)',
    'client_emails_preview(jsonb)','client_emails_apply(jsonb,text,text)','client_email_upsert(text,text,text)','delivery_email_suggestion(uuid)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon'; execute 'grant execute on function public.' || f || ' to authenticated'; end loop;
  foreach f in array array['_return_depot()','_cuit_valid(text)'] loop execute 'revoke all on function public.' || f || ' from public, anon, authenticated'; end loop;
  -- la política RLS del padrón la evalúa CON el usuario que consulta: debe poder ejecutarla (solo responde si ÉL es Administrador General)
  execute 'revoke all on function public._is_general_admin() from public, anon'; execute 'grant execute on function public._is_general_admin() to authenticated';
end $$;

-- ---------- 5) finalize_route: misma función + LLEGUÉ A DIAMANTE obligatorio (hojas internas iniciadas desde que rige) ----------
create or replace function public.finalize_route(p_route uuid, p_km_end numeric default null) returns public.routes language plpgsql security definer set search_path = public as $$
declare r public.routes; pend int; summ jsonb; mods int; sup uuid; v public.vehicles;
begin
  r := public._my_route(p_route);
  if r.operational_status = 'COMPLETADA' then return r; end if;
  if r.operational_status <> 'EN_CURSO' then raise exception 'BAD_STATE' using errcode = '23514'; end if;
  select count(*) filter (where outcome = 'PENDIENTE') into pend from public.route_stops where route_id = p_route;
  if pend > 0 then raise exception 'PENDING_STOPS: faltan % entregas por resolver', pend using errcode = '23514'; end if;
  -- V4.23: hoja del TRANSPORTISTA INTERNO iniciada desde que rige la regla → exige LLEGUÉ A DIAMANTE antes de finalizar
  if r.depot_arrived_at is null and exists (select 1 from public.carriers c where c.id = r.carrier_id and c.kind = 'INTERNO')
     and r.started_at >= coalesce((select required_since from public.return_depot_settings where id = 'DEFAULT'), 'infinity'::timestamptz) then
    raise exception 'DEPOT_ARRIVAL_REQUIRED: registrá LLEGUÉ A DIAMANTE antes de finalizar la hoja' using errcode = '23514';
  end if;
  if r.vehicle_id is not null then
    select * into v from public.vehicles where id = r.vehicle_id for update;
    if p_km_end is null then raise exception 'KM_REQUIRED: cargá el kilometraje final' using errcode = '23514'; end if;
    if p_km_end < v.current_km then raise exception 'KM_LOWER: el kilometraje no puede bajar (último %)', v.current_km using errcode = '23514'; end if;
    update public.vehicles set current_km = p_km_end where id = v.id;
  end if;
  select jsonb_object_agg(outcome, n) into summ from (select outcome, count(*) n from public.route_stops where route_id = p_route group by outcome) x;
  select count(*) into mods from public.route_change_events where route_id = p_route and event_type in ('INTERNAL_STOP_ADDED','INTERNAL_STOP_REORDERED');
  update public.routes set operational_status = 'COMPLETADA', status = 'COMPLETADA', completed_at = now(), completed_by = auth.uid(), final_summary = summ, km_end = p_km_end,
         approval_status = case when mods > 0 then 'PENDIENTE' else 'NO_REQUERIDA' end where id = p_route returning * into r;
  if mods > 0 then
    select coalesce(p.supervisor_user_id, s.supervisor_user_id) into sup from public.profiles p, public.internal_route_notification_settings s where p.id = r.responsable_id and s.id = 'DEFAULT';
    if sup is not null and not public.user_has_perm(sup, 'can_approve_internal_route_changes') then sup := null; end if;
    insert into public.route_approval_requests(route_id, route_version, requested_by, supervisor_user_id, supervisor_missing, modification_count)
    values (p_route, r.version, auth.uid(), sup, sup is null, mods) on conflict (route_id, route_version) do nothing;
    insert into public.notifications(user_id, route_id, route_version, type, title, body)
    select u, p_route, r.version, case when sup is null then 'INTERNAL_ROUTE_NO_SUPERVISOR' else 'INTERNAL_ROUTE_APPROVAL_REQUEST' end,
           'HOJA ' || r.number || ' PENDIENTE DE APROBACIÓN', mods || ' cambio(s) del chofer' || case when sup is null then ' · sin superior configurado' else '' end
    from (select sup u where sup is not null union select id from public.profiles where sup is null and role = 'ADMIN' and status = 'ACTIVO') x on conflict do nothing;
    perform public.queue_route_emails(p_route, r.version, 'INTERNAL_ROUTE_APPROVAL_REQUEST');
  end if;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'ROUTE_FINALIZED', 'route', p_route::text, summ || jsonb_build_object('modifications', mods, 'km_end', p_km_end));
  return r;
end; $$;

DO $post$ BEGIN
  IF (SELECT md5(prosrc) FROM pg_proc WHERE proname = 'finalize_route' AND pronamespace = 'public'::regnamespace) <> '779f1959bf9f5084088fa3c817f3ab1c' THEN RAISE EXCEPTION 'HUELLA_FINAL_INESPERADA: finalize_route no quedó como se esperaba. Se deshace todo.'; END IF;
END $post$;
COMMIT;
