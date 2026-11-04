-- =====================================================================================================================
-- PROPUESTA V4.24 · NO APLICADA · SALIDAS del Transportista Interno: GPS de la salida del DEPÓSITO y SALÍ DE <SUCURSAL> (opción B)
-- El inicio del recorrido YA existe (start_route: hora real, km inicial, usuario, vehículo, hoja) y se REUTILIZA sin duplicarlo.
-- Esta migración agrega SOLO lo que faltaba: la ubicación GPS de la salida (con precisión y control de radio del depósito configurado).
-- DEPENDE de la V4.23b (arrive_depot, trigger routes_zz_depot_required, return_depot_settings, _return_depot): aplicar DESPUÉS de V4.21 y V4.23.
-- Agrega SALÍ DE <SUCURSAL> (Montecaseros / San Juan): evento PROPIO, solo DESPUÉS de TERMINÉ EN; no cambia la recepción ni cierra la hoja.
-- No hay SALÍ DE DIAMANTE al final: el cierre sigue siendo LLEGUÉ A DIAMANTE → KM FINAL → FINALIZAR.
-- No cambia ninguna función existente. No borra ni modifica datos. Una transacción con verificación previa.
-- =====================================================================================================================
BEGIN;
DO $guard$ BEGIN
  IF to_regprocedure('public.arrive_depot(uuid, jsonb, text)') IS NULL OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'routes_zz_depot_required') THEN
    RAISE EXCEPTION 'HUELLA_INESPERADA: falta la V4.23b (arrive_depot + trigger de Diamante). Aplicá primero V4.21 y V4.23b. No se modificó nada.'; END IF;
  IF to_regprocedure('public._return_depot()') IS NULL OR to_regprocedure('public._loc(jsonb, public.route_stops)') IS NULL THEN
    RAISE EXCEPTION 'DEPENDENCIA_FALTANTE: _return_depot / _loc. No se modificó nada.'; END IF;
  IF to_regprocedure('public.record_route_departure(uuid, jsonb, text)') IS NOT NULL OR to_regprocedure('public.depart_internal_location(uuid, jsonb, text)') IS NOT NULL THEN
    RAISE EXCEPTION 'YA_APLICADA: la V4.24 ya existe. No se modificó nada.'; END IF;
END $guard$;

alter table public.routes add column if not exists start_location jsonb;
alter table public.routes add column if not exists start_location_key text;

create or replace function public.record_route_departure(p_route uuid, p_location jsonb, p_op_id text) returns public.routes
language plpgsql security definer set search_path = public as $$
declare r public.routes; d public.internal_locations; ref public.route_stops; loc jsonb;
begin
  r := public._my_route(p_route);
  if r.operational_status <> 'EN_CURSO' or r.started_at is null then raise exception 'START_FIRST: iniciá el recorrido antes de registrar la salida' using errcode = '23514'; end if;
  if not exists (select 1 from public.carriers c where c.id = r.carrier_id and c.kind = 'INTERNO') then raise exception 'NOT_INTERNAL: solo el Transportista Interno registra la salida del depósito' using errcode = '23514'; end if;
  if r.start_location is not null then return r; end if;   -- idempotente (reintento sin conexión, doble toque)
  d := public._return_depot();                             -- el depósito YA configurado (sin clave inventada); si no hay, se guarda el GPS sin control de radio
  if d.location_key is not null then ref.expected_lat := d.lat; ref.expected_lon := d.lon; ref.expected_radius_m := d.radius_m; end if;
  loc := public._loc(p_location, ref);
  update public.routes set start_location = loc, start_location_key = d.location_key where id = p_route returning * into r;
  return r;
end; $$;
revoke all on function public.record_route_departure(uuid, jsonb, text) from public, anon;
grant execute on function public.record_route_departure(uuid, jsonb, text) to authenticated;

-- ---------- SALÍ DE <SUCURSAL> (opción B): después de TERMINÉ EN, con hora y GPS propios ----------
alter table public.route_stops add column if not exists location_departed_at timestamptz;
alter table public.route_stops add column if not exists location_departed_location jsonb;
alter table public.route_stops add column if not exists location_departed_by uuid;
create or replace function public.depart_internal_location(p_stop uuid, p_location jsonb, p_op_id text) returns public.route_stops
language plpgsql security definer set search_path = public as $$
declare st public.route_stops; r public.routes; loc jsonb;
begin
  select * into st from public.route_stops where id = p_stop; if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  r := public._my_route(st.route_id);
  if r.operational_status <> 'EN_CURSO' then raise exception 'BAD_STATE' using errcode = '23514'; end if;
  if coalesce(st.stop_type, 'PEDIDO') <> 'UBICACION_INTERNA' then raise exception 'NOT_INTERNAL_LOCATION: solo para ubicaciones internas' using errcode = '23514'; end if;
  if st.location_departed_at is not null then return st; end if;   -- idempotente (reintento sin conexión, doble toque)
  if st.location_finished_at is null then raise exception 'FINISH_FIRST: registrá TERMINÉ EN la ubicación antes de la salida' using errcode = '23514'; end if;
  loc := public._loc(p_location, st);
  update public.route_stops set location_departed_at = now(), location_departed_location = loc, location_departed_by = auth.uid() where id = p_stop returning * into st;
  return st;
end; $$;
revoke all on function public.depart_internal_location(uuid, jsonb, text) from public, anon;
grant execute on function public.depart_internal_location(uuid, jsonb, text) to authenticated;

DO $post$ BEGIN
  IF to_regprocedure('public.record_route_departure(uuid, jsonb, text)') IS NULL OR to_regprocedure('public.depart_internal_location(uuid, jsonb, text)') IS NULL THEN RAISE EXCEPTION 'HUELLA_FINAL_INESPERADA'; END IF;
END $post$;
COMMIT;
