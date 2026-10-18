-- OK DESPACHO ONLINE — Parche G2 (incremental sobre 20261108000100, forward-only, sin borrar datos):
-- 1) el Transportista Interno puede agregar durante el recorrido una UBICACIÓN INTERNA G2 existente (incluida una SEGUNDA visita);
-- 2) la unicidad de ubicación interna por hoja aplica SOLO a las paradas administrativas (constructor), no a las agregadas por el chofer;
-- 3) los avisos de hojas internas cuentan PARADAS, no entregas.

-- =====================================================================
-- 1 · Unicidad compatible con la segunda visita del chofer
--   ANTES: unique (route_id, internal_location_key) where stop_type='UBICACION_INTERNA'  → impedía volver a Montecaseros.
--   AHORA: la misma unicidad, pero solo para paradas que NO agregó el chofer (constructor / publicación / revisión).
--          Las del chofer pueden repetir la ubicación (visita explícita); el doble toque lo frena la idempotencia
--          (route_change_events.client_op_id UNIQUE + id de parada enviado por el celular).
-- =====================================================================
drop index if exists public.route_stops_one_internal_location_per_route;
create unique index if not exists route_stops_one_admin_internal_location_per_route on public.route_stops(route_id, internal_location_key)
  where stop_type = 'UBICACION_INTERNA' and provenance is distinct from 'DRIVER';

-- =====================================================================
-- 2 · El chofer elige una G2: lista de solo lectura (sin coordenadas: el GPS se valida en el servidor con el snapshot)
-- =====================================================================
create or replace function public.driver_internal_locations() returns table(location_key text, name text, address text, radius_m int)
language sql stable security definer set search_path = public as $$
  select l.location_key, l.name, l.address, l.radius_m from public.internal_locations l
   where l.active and (public.auth_has_perm('internal_routes.use') or public.auth_has_perm('routes.create') or public.auth_has_perm('locations.view'))
   order by l.name;
$$;
revoke execute on function public.driver_internal_locations() from public, anon;
grant execute on function public.driver_internal_locations() to authenticated;

-- =====================================================================
-- 3 · + AGREGAR PARADA: TAREA o UBICACIÓN INTERNA (con snapshot GPS tomado al agregarla), siempre futura, sin pedidos, auditada e idempotente
-- =====================================================================
create or replace function public.add_internal_stop(p_route uuid, p_stop jsonb, p_version int, p_op_id text, p_offline boolean default false)
returns public.routes language plpgsql security definer set search_path = public as $$
declare r public.routes; nid uuid; nseq int; v_type text; v_key text;
begin
  r := public._my_route(p_route);
  if exists (select 1 from public.route_change_events where client_op_id = p_op_id) then return r; end if;   -- reintento offline
  if not exists (select 1 from public.carriers c where c.id = r.carrier_id and c.kind = 'INTERNO') then raise exception 'NOT_INTERNAL' using errcode = '23514'; end if;
  if r.operational_status <> 'EN_CURSO' then raise exception 'BAD_STATE' using errcode = '23514'; end if;
  if p_version <> r.version then raise exception 'VERSION_CONFLICT: la hoja cambió (versión %)', r.version using errcode = '40001'; end if;
  -- Tipo elegido por el chofer: TAREA libre o UBICACIÓN INTERNA G2 existente (segunda visita incluida). Nunca pedidos ni montos.
  v_type := case when p_stop->>'stop_type' = 'UBICACION_INTERNA' then 'UBICACION_INTERNA' else 'TAREA' end;
  v_key := case when v_type = 'UBICACION_INTERNA' then nullif(upper(trim(p_stop->>'internal_location_key')), '') end;
  if v_type = 'UBICACION_INTERNA' then
    if v_key is null then raise exception 'INTERNAL_LOCATION_REQUIRED: elegí la ubicación interna' using errcode = '23514'; end if;
    if not exists (select 1 from public.internal_locations where location_key = v_key and active) then
      raise exception 'INTERNAL_LOCATION_INACTIVE: % no existe o está desactivada en G2', v_key using errcode = '23514'; end if;
  elsif coalesce(trim(p_stop->>'client_name'), '') = '' then raise exception 'NAME_REQUIRED' using errcode = '23514'; end if;
  select coalesce(max(seq), 0) + 1 into nseq from public.route_stops where route_id = p_route;
  -- el celular puede enviar el id (UUID) de la parada nueva: así un reordenamiento hecho offline ya la referencia
  -- nombre, domicilio y snapshot GPS de una G2 los completa el trigger _stop_type_rules desde el maestro (el chofer no los edita)
  insert into public.route_stops(id, route_id, seq, sequence_number, provenance, client_name, address, action, bultos, added_by, added_at, stop_type, instructions, contact_name, contact_phone, internal_location_key, order_numbers)
  values (coalesce(nullif(p_stop->>'id', '')::uuid, gen_random_uuid()), p_route, nseq, (select coalesce(max(sequence_number), 0) + 1 from public.route_stops where route_id = p_route), 'DRIVER',
          coalesce(nullif(trim(p_stop->>'client_name'), ''), v_key), p_stop->>'address',
          coalesce(nullif(p_stop->>'action', ''), 'ENTREGA'), nullif(p_stop->>'bultos', '')::int, auth.uid(), now(),
          v_type, nullif(trim(p_stop->>'instructions'), ''), nullif(trim(p_stop->>'contact_name'), ''), nullif(trim(p_stop->>'contact_phone'), ''), v_key, '{}')
  returning id into nid;
  update public.routes set version = version + 1, has_driver_modifications = true, modification_count = modification_count + 1 where id = p_route returning * into r;
  insert into public.route_change_events(route_id, route_version, stop_id, event_type, after, user_id, client_op_id, offline)
  values (p_route, r.version, nid::text, 'INTERNAL_STOP_ADDED', p_stop, auth.uid(), p_op_id, p_offline);
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'INTERNAL_STOP_ADDED', 'route', p_route::text, p_stop);
  return r;
end; $$;

-- =====================================================================
-- 4 · Avisos de hojas internas: "N paradas" (mezcla de traslados, tareas y entregas). Externos sin cambios ("entregas").
-- =====================================================================
create or replace function public.trg_notification_internal_wording() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.type in ('NUEVA_HOJA_PUBLICADA','HOJA_CORREGIDA') and new.route_id is not null and new.body is not null
     and exists (select 1 from public.routes r join public.carriers c on c.id = r.carrier_id where r.id = new.route_id and c.kind = 'INTERNO') then
    new.body := regexp_replace(new.body, '(\d+) entregas', '\1 paradas', 'g');
  end if;
  return new;
end $$;
revoke execute on function public.trg_notification_internal_wording() from public, anon, authenticated;
drop trigger if exists trg_notification_internal_wording on public.notifications;
create trigger trg_notification_internal_wording before insert on public.notifications for each row execute function public.trg_notification_internal_wording();

