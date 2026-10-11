-- OK DESPACHO ONLINE — FASE 2B.3 CIERRE OPERATIVO (incremental)
-- Recepción + firma + DNI/CUIL · ubicación puntual · cobranzas · emails al cliente · vehículo/km/service ·
-- devolución de hoja · cancelación · ajustes de aprobación.

insert into public.permissions(code) values ('identity_docs.view'), ('collections.manage'), ('vehicles.manage') on conflict do nothing;
insert into public.role_permissions(role_code, permission_code) values ('ADMIN','identity_docs.view'), ('ADMIN','collections.manage'), ('ADMIN','vehicles.manage') on conflict do nothing;

-- ---------- Paradas: tarea, cobranza, ubicación, email del cliente ----------
alter table public.route_stops add column if not exists task text not null default 'ENTREGA' check (task in ('ENTREGA','COBRANZA','AMBAS'));
alter table public.route_stops add column if not exists expected_amount numeric(14,2);
alter table public.route_stops add column if not exists collected_amount numeric(14,2);
alter table public.route_stops add column if not exists payment_mode text;
alter table public.route_stops add column if not exists collection_status text not null default 'PENDIENTE' check (collection_status in ('PENDIENTE','COBRADO','COBRO_PARCIAL','NO_COBRADO'));
alter table public.route_stops add column if not exists collection_note text;
alter table public.route_stops add column if not exists customer_email text;
alter table public.route_stops add column if not exists arrived_at timestamptz;
alter table public.route_stops add column if not exists arrive_location jsonb;   -- {lat, lon, accuracy, at} o {missing_reason, at}
alter table public.route_stops add column if not exists finish_location jsonb;
alter table public.route_stops add column if not exists location_warning text;

-- ---------- Evidencia privada (firma) y documento (DNI) ----------
create table if not exists public.stop_evidence (
  stop_id uuid primary key references public.route_stops(id),
  receiver_name text not null, signature_png bytea not null, signature_sha256 text not null,
  receiver_cuil text check (receiver_cuil ~ '^[0-9]{11}$'),
  created_by uuid not null, created_at timestamptz not null default now()
);
create table if not exists public.customer_identity_docs (
  cuil text primary key check (cuil ~ '^[0-9]{11}$'), dni_photo bytea not null, mime text not null default 'image/jpeg',
  registered_by uuid not null, registered_at timestamptz not null default now()
);
alter table public.stop_evidence enable row level security;
alter table public.customer_identity_docs enable row level security;
create policy evidence_read on public.stop_evidence for select to authenticated using (public.auth_has_perm('signatures.view'));
create policy identity_read on public.customer_identity_docs for select to authenticated using (public.auth_has_perm('identity_docs.view'));
grant select on public.stop_evidence, public.customer_identity_docs to authenticated;
-- El chofer solo sabe si el CUIL ya tiene DNI (no ve la foto)
create or replace function public.cuil_has_dni(p_cuil text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.customer_identity_docs where cuil = regexp_replace(coalesce(p_cuil,''), '\D', '', 'g'));
$$;
grant execute on function public.cuil_has_dni(text) to authenticated;

-- ---------- Ubicación maestra (radio permitido) ----------
create table if not exists public.client_locations (client_key text primary key, lat double precision not null, lon double precision not null, radius_m int not null default 200);
alter table public.client_locations enable row level security;
create policy client_locations_read on public.client_locations for select to authenticated using (public.auth_has_perm('routes.view_all') or public.auth_has_perm('routes.create'));
grant select on public.client_locations to authenticated;
create or replace function public._dist_m(a_lat double precision, a_lon double precision, b_lat double precision, b_lon double precision) returns double precision language sql immutable as $$
  select 2 * 6371000 * asin(sqrt(power(sin(radians(b_lat - a_lat) / 2), 2) + cos(radians(a_lat)) * cos(radians(b_lat)) * power(sin(radians(b_lon - a_lon) / 2), 2)));
$$;
-- Valida y registra una ubicación puntual (nunca la inventa). Devuelve el jsonb guardado.
create or replace function public._loc(p jsonb, st public.route_stops) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare m public.client_locations; d double precision;
begin
  if p is null then raise exception 'LOCATION_REQUIRED: registrá la ubicación o indicá por qué no se pudo' using errcode = '23514'; end if;
  if p ? 'lat' and p ? 'lon' then
    select * into m from public.client_locations where client_key = st.client_key;
    if found then d := public._dist_m(m.lat, m.lon, (p->>'lat')::float8, (p->>'lon')::float8); end if;
    return jsonb_build_object('lat', (p->>'lat')::float8, 'lon', (p->>'lon')::float8, 'accuracy', (p->>'accuracy')::float8, 'at', now(),
      'outside_m', case when d is not null and d > m.radius_m then round(d) end);
  end if;
  if coalesce(trim(p->>'missing_reason'), '') = '' then raise exception 'LOCATION_REASON_REQUIRED: sin ubicación hay que indicar el motivo' using errcode = '23514'; end if;
  return jsonb_build_object('missing_reason', trim(p->>'missing_reason'), 'at', now());
end; $$;

-- ---------- Emails al cliente (cola idempotente) ----------
create table if not exists public.customer_email_jobs (
  id uuid primary key default gen_random_uuid(), route_id uuid not null references public.routes(id), stop_id uuid not null references public.route_stops(id),
  kind text not null check (kind in ('ON_THE_WAY','DELIVERED','PARTIAL')), recipient text not null,
  idempotency_key text not null unique,          -- route|stop|kind
  status text not null default 'QUEUED' check (status in ('QUEUED','SENT','ERROR')), queued_at timestamptz not null default now(), sent_at timestamptz, provider_id text, error text, retry_count int not null default 0
);
alter table public.customer_email_jobs enable row level security;
create policy cej_read on public.customer_email_jobs for select to authenticated using (public.auth_has_perm('settings.manage') or public.auth_has_perm('routes.view_all'));
grant select on public.customer_email_jobs to authenticated;
-- "Va en camino" cuando ESA parada pasa a ser la actual (no al iniciar toda la ruta). Sin email: no bloquea.
create or replace function public._queue_on_the_way(p_route uuid) returns void language plpgsql security definer set search_path = public as $$
declare s public.route_stops;
begin
  select * into s from public.route_stops where route_id = p_route and outcome = 'PENDIENTE' order by sequence_number limit 1;
  if found and coalesce(trim(s.customer_email), '') <> '' then
    insert into public.customer_email_jobs(route_id, stop_id, kind, recipient, idempotency_key)
    values (p_route, s.id, 'ON_THE_WAY', lower(trim(s.customer_email)), p_route || '|' || s.id || '|ON_THE_WAY') on conflict (idempotency_key) do nothing;
  end if;
end; $$;

-- ---------- Vehículos ----------
create table if not exists public.vehicles (
  id uuid primary key default gen_random_uuid(), name text not null, plate text not null unique, active boolean not null default true,
  brand text, model text, type text, year int, notes text,
  current_km numeric(10,1) not null default 0, last_service_km numeric(10,1) not null default 0, last_service_date date, service_interval_km int not null default 10000
);
alter table public.vehicles enable row level security;
create policy vehicles_read on public.vehicles for select to authenticated using (true);
grant select on public.vehicles to authenticated;
alter table public.routes add column if not exists vehicle_id uuid references public.vehicles(id);
alter table public.routes add column if not exists km_start numeric(10,1);
alter table public.routes add column if not exists km_end numeric(10,1);
create or replace function public.upsert_vehicle(p jsonb) returns public.vehicles language plpgsql security definer set search_path = public as $$
declare v public.vehicles;
begin
  if not public.auth_has_perm('vehicles.manage') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  insert into public.vehicles(id, name, plate, active, brand, model, type, year, notes, current_km, last_service_km, service_interval_km)
  values (coalesce(nullif(p->>'id','')::uuid, gen_random_uuid()), p->>'name', upper(p->>'plate'), coalesce((p->>'active')::boolean, true), p->>'brand', p->>'model', p->>'type', nullif(p->>'year','')::int, p->>'notes',
          coalesce((p->>'current_km')::numeric, 0), coalesce((p->>'last_service_km')::numeric, coalesce((p->>'current_km')::numeric, 0)), coalesce((p->>'service_interval_km')::int, 10000))
  on conflict (id) do update set name = excluded.name, plate = excluded.plate, active = excluded.active, brand = excluded.brand, model = excluded.model, type = excluded.type, year = excluded.year, notes = excluded.notes, service_interval_km = excluded.service_interval_km
  returning * into v;
  return v;
end; $$;
create or replace function public.set_route_vehicle(p_route uuid, p_vehicle uuid) returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.auth_has_perm('routes.publish') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if not exists (select 1 from public.routes r join public.carriers c on c.id = r.carrier_id where r.id = p_route and c.kind = 'INTERNO' and r.operational_status in ('PUBLICADA','EN_CURSO')) then raise exception 'NOT_INTERNAL_ACTIVE' using errcode = '23514'; end if;
  update public.routes set vehicle_id = p_vehicle, km_start = (select current_km from public.vehicles where id = p_vehicle and active) where id = p_route;
  if not found or (select km_start from public.routes where id = p_route) is null then raise exception 'BAD_VEHICLE: vehículo inexistente o inactivo' using errcode = '23514'; end if;
end; $$;
create or replace function public.correct_vehicle_km(p_vehicle uuid, p_km numeric, p_reason text) returns void language plpgsql security definer set search_path = public as $$
declare v public.vehicles;
begin
  if not public.auth_has_perm('vehicles.manage') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'REASON_REQUIRED' using errcode = '23514'; end if;
  select * into v from public.vehicles where id = p_vehicle for update;
  update public.vehicles set current_km = p_km where id = p_vehicle;
  insert into public.audit_log(actor_id, action, target_type, target_id, before, after) values (auth.uid(), 'VEHICLE_KM_CORRECTED', 'vehicle', p_vehicle::text, jsonb_build_object('km', v.current_km), jsonb_build_object('km', p_km, 'reason', p_reason));
end; $$;
create or replace function public.register_vehicle_service(p_vehicle uuid, p_km numeric, p_date date) returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.auth_has_perm('vehicles.manage') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  update public.vehicles set last_service_km = p_km, last_service_date = p_date, current_km = greatest(current_km, p_km) where id = p_vehicle;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'VEHICLE_SERVICE_REGISTERED', 'vehicle', p_vehicle::text, jsonb_build_object('km', p_km, 'date', p_date));
end; $$;
create or replace view public.vehicle_service_status with (security_invoker = true) as
  select v.*, v.current_km - v.last_service_km as km_since_service, (v.current_km - v.last_service_km) >= v.service_interval_km as service_due from public.vehicles v;
grant select on public.vehicle_service_status to authenticated;

-- ---------- Llegar a la parada (ubicación puntual) ----------
create or replace function public.arrive_stop(p_stop uuid, p_location jsonb, p_op_id text) returns public.route_stops language plpgsql security definer set search_path = public as $$
declare st public.route_stops; r public.routes; loc jsonb;
begin
  select * into st from public.route_stops where id = p_stop; if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  r := public._my_route(st.route_id);
  if r.operational_status <> 'EN_CURSO' then raise exception 'BAD_STATE' using errcode = '23514'; end if;
  if st.arrived_at is not null then return st; end if;
  loc := public._loc(p_location, st);
  update public.route_stops set arrived_at = now(), arrive_location = loc, location_warning = case when loc ? 'outside_m' and loc->>'outside_m' is not null then 'FUERA DEL RADIO (' || (loc->>'outside_m') || ' m)' end where id = p_stop returning * into st;
  return st;
end; $$;

-- ---------- Resolver parada: resultado + recepción/firma + DNI/CUIL + ubicación + cobranza ----------
drop function if exists public.set_stop_outcome(uuid, text, text, text, text);
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
      if coalesce(ev->>'dni_photo_b64', '') <> '' and not exists (select 1 from public.customer_identity_docs d where d.cuil = v_cuil) then
        insert into public.customer_identity_docs(cuil, dni_photo, mime, registered_by) values (v_cuil, decode(ev->>'dni_photo_b64', 'base64'), coalesce(ev->>'dni_mime', 'image/jpeg'), auth.uid());
      end if;
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
grant execute on function public.set_stop_outcome(uuid, text, text, text, text, jsonb), public.arrive_stop(uuid, jsonb, text) to authenticated, service_role;

-- start_route: además "va en camino" para la primera parada
create or replace function public.start_route(p_route uuid) returns public.routes language plpgsql security definer set search_path = public as $$
declare r public.routes;
begin
  r := public._my_route(p_route);
  if r.operational_status = 'EN_CURSO' then return r; end if;
  if r.operational_status <> 'PUBLICADA' then raise exception 'BAD_STATE: la hoja no se puede iniciar (%)', r.operational_status using errcode = '23514'; end if;
  update public.routes set operational_status = 'EN_CURSO', status = 'EN_CURSO', started_at = now(), started_by = auth.uid(), viewed_at = coalesce(viewed_at, now()) where id = p_route returning * into r;
  insert into public.audit_log(actor_id, action, target_type, target_id) values (auth.uid(), 'ROUTE_STARTED', 'route', p_route::text);
  perform public._queue_on_the_way(p_route);
  return r;
end; $$;

-- Reordenar/agregar en ruta interna puede cambiar la parada actual → aviso "va en camino" de la nueva actual
create or replace function public.trg_on_the_way_after_change() returns trigger language plpgsql security definer set search_path = public as $$
begin perform public._queue_on_the_way(new.route_id); return null; end; $$;
drop trigger if exists route_change_on_the_way on public.route_change_events;
create trigger route_change_on_the_way after insert on public.route_change_events for each row execute function public.trg_on_the_way_after_change();

-- ---------- Finalizar: km final obligatorio en ruta interna con vehículo (no puede bajar) ----------
drop function if exists public.finalize_route(uuid);
create or replace function public.finalize_route(p_route uuid, p_km_end numeric default null) returns public.routes language plpgsql security definer set search_path = public as $$
declare r public.routes; pend int; summ jsonb; mods int; sup uuid; v public.vehicles;
begin
  r := public._my_route(p_route);
  if r.operational_status = 'COMPLETADA' then return r; end if;
  if r.operational_status <> 'EN_CURSO' then raise exception 'BAD_STATE' using errcode = '23514'; end if;
  select count(*) filter (where outcome = 'PENDIENTE') into pend from public.route_stops where route_id = p_route;
  if pend > 0 then raise exception 'PENDING_STOPS: faltan % entregas por resolver', pend using errcode = '23514'; end if;
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
grant execute on function public.finalize_route(uuid, numeric) to authenticated, service_role;

-- ---------- Aprobar: además avisa al chofer "HOJA APROBADA" ----------
create or replace function public.trg_notify_driver_approved() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'APPROVED' and old.status = 'PENDING' then
    insert into public.notifications(user_id, route_id, route_version, type, title, body)
    select r.responsable_id, r.id, new.route_version, 'INTERNAL_ROUTE_APPROVED', 'HOJA APROBADA · ' || r.number, 'Tu hoja fue aprobada.' from public.routes r where r.id = new.route_id on conflict do nothing;
  end if;
  return new;
end; $$;
drop trigger if exists approval_notify_driver on public.route_approval_requests;
create trigger approval_notify_driver after update on public.route_approval_requests for each row execute function public.trg_notify_driver_approved();

-- ---------- Devolver hoja (solicitud; hasta 2 días calendario, hora de Mendoza) ----------
create table if not exists public.route_return_requests (
  id uuid primary key default gen_random_uuid(), route_id uuid not null references public.routes(id), requested_by uuid not null, reason text not null,
  status text not null default 'PENDING' check (status in ('PENDING','RESOLVED','REJECTED')), created_at timestamptz not null default now(),
  resolved_by uuid, resolved_at timestamptz, resolution_note text
);
create unique index if not exists route_return_one_pending on public.route_return_requests(route_id) where status = 'PENDING';
alter table public.route_return_requests enable row level security;
create policy rrr_read on public.route_return_requests for select to authenticated using (requested_by = auth.uid() or public.auth_has_perm('routes.view_all'));
grant select on public.route_return_requests to authenticated;
create or replace function public.request_route_return(p_route uuid, p_reason text) returns public.route_return_requests language plpgsql security definer set search_path = public as $$
declare r public.routes; q public.route_return_requests;
begin
  r := public._my_route(p_route);
  if r.operational_status <> 'COMPLETADA' then raise exception 'BAD_STATE: solo hojas finalizadas' using errcode = '23514'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'REASON_REQUIRED' using errcode = '23514'; end if;
  if (now() at time zone 'America/Argentina/Mendoza')::date - (r.completed_at at time zone 'America/Argentina/Mendoza')::date > 2 then raise exception 'RETURN_EXPIRED: pasaron más de 2 días desde el cierre' using errcode = '23514'; end if;
  select * into q from public.route_return_requests where route_id = p_route and status = 'PENDING';
  if found then return q; end if;
  insert into public.route_return_requests(route_id, requested_by, reason) values (p_route, auth.uid(), trim(p_reason)) returning * into q;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'ROUTE_RETURN_REQUESTED', 'route', p_route::text, jsonb_build_object('reason', p_reason));
  return q;
end; $$;
create or replace function public.resolve_route_return(p_id uuid, p_decision text, p_note text) returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.auth_has_perm('routes.manage_all_drafts') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_decision not in ('RESOLVED','REJECTED') or coalesce(trim(p_note), '') = '' then raise exception 'NOTE_REQUIRED' using errcode = '23514'; end if;
  update public.route_return_requests set status = p_decision, resolved_by = auth.uid(), resolved_at = now(), resolution_note = p_note where id = p_id and status = 'PENDING';
  if not found then raise exception 'NOT_PENDING' using errcode = '23514'; end if;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'ROUTE_RETURN_' || p_decision, 'route_return', p_id::text, jsonb_build_object('note', p_note));
end; $$;

-- ---------- Cancelar hoja activa (Administración): libera reservas; el correlativo nunca se reutiliza ----------
create or replace function public.cancel_route(p_route uuid, p_reason text) returns public.routes language plpgsql security definer set search_path = public as $$
declare r public.routes;
begin
  if not public.auth_has_perm('routes.manage_all_drafts') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'REASON_REQUIRED' using errcode = '23514'; end if;
  update public.routes set operational_status = 'CANCELADA', status = 'CANCELADA' where id = p_route and operational_status in ('PUBLICADA','EN_CURSO') returning * into r;
  if not found then raise exception 'BAD_STATE: solo hojas publicadas o en curso' using errcode = '23514'; end if;
  update public.route_drafts set status = 'CANCELADA', updated_at = now() where route_id = p_route;
  delete from public.order_reservations where route_id = p_route;   -- la hoja cancelada ya no retiene los pedidos
  insert into public.notifications(user_id, route_id, route_version, type, title, body) values (r.responsable_id, r.id, r.version, 'ROUTE_CANCELLED', 'HOJA ' || r.number || ' CANCELADA', p_reason) on conflict do nothing;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'ROUTE_CANCELLED', 'route', p_route::text, jsonb_build_object('reason', p_reason, 'number', r.number));
  return r;
end; $$;
grant execute on function public.request_route_return(uuid, text), public.resolve_route_return(uuid, text, text), public.cancel_route(uuid, text),
  public.upsert_vehicle(jsonb), public.set_route_vehicle(uuid, uuid), public.correct_vehicle_km(uuid, numeric, text), public.register_vehicle_service(uuid, numeric, date) to authenticated, service_role;

-- publish_route: tarea, importe esperado y email del cliente por parada; vehículo de la ruta interna (si viene en la hoja)
create or replace function public.trg_stop_from_snapshot() returns trigger language plpgsql security definer set search_path = public as $$
declare s jsonb;
begin
  if new.provenance = 'PUBLISHED' then
    select r.sheet_snapshot->'stops'->(new.seq - 1) into s from public.routes r where r.id = new.route_id;
    if s is not null then
      new.task := coalesce(nullif(s->>'task', ''), 'ENTREGA');
      new.expected_amount := nullif(s->>'expected_amount', '')::numeric;
      new.customer_email := nullif(trim(s->>'customer_email'), '');
    end if;
  end if;
  return new;
end; $$;
drop trigger if exists stop_from_snapshot on public.route_stops;
create trigger stop_from_snapshot before insert on public.route_stops for each row execute function public.trg_stop_from_snapshot();
create or replace function public.trg_route_vehicle_from_snapshot() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.sheet_snapshot ? 'vehicle_id' and coalesce(new.sheet_snapshot->>'vehicle_id', '') <> ''
     and exists (select 1 from public.carriers where id = new.carrier_id and kind = 'INTERNO') then
    new.vehicle_id := (new.sheet_snapshot->>'vehicle_id')::uuid;
    select current_km into new.km_start from public.vehicles where id = new.vehicle_id and active;
    if new.km_start is null then raise exception 'BAD_VEHICLE: vehículo inexistente o inactivo' using errcode = '23514'; end if;
  end if;
  return new;
end; $$;
drop trigger if exists route_vehicle_from_snapshot on public.routes;
create trigger route_vehicle_from_snapshot before insert on public.routes for each row execute function public.trg_route_vehicle_from_snapshot();
-- El chofer no modifica el importe esperado (solo con permiso)
create or replace function public.set_expected_amount(p_stop uuid, p_amount numeric, p_reason text) returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.auth_has_perm('collections.manage') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  update public.route_stops set expected_amount = p_amount where id = p_stop;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'EXPECTED_AMOUNT_CHANGED', 'stop', p_stop::text, jsonb_build_object('amount', p_amount, 'reason', p_reason));
end; $$;
grant execute on function public.set_expected_amount(uuid, numeric, text) to authenticated;
