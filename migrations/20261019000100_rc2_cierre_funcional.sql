-- OK DESPACHO ONLINE — RC2 (incremental): grants de service_role, borradores visibles, historial, configuración real
-- (transportistas, plantillas, vehículos, reglas financieras, emails, ubicaciones, parámetros), dashboard y emails de hojas.

-- =====================================================================
-- 1. GRANTS de service_role (formaliza lo que en staging se hizo a mano). anon NO recibe nada.
-- =====================================================================
grant usage on schema public to service_role;
grant all on all tables in schema public to service_role;
grant all on all sequences in schema public to service_role;
grant execute on all functions in schema public to service_role;
alter default privileges in schema public grant all on tables to service_role;
alter default privileges in schema public grant all on sequences to service_role;
alter default privileges in schema public grant execute on functions to service_role;
revoke all on all tables in schema public from anon;

-- =====================================================================
-- 2. BORRADORES visibles (contenido en el servidor, abrir desde cualquier equipo, eliminar liberando pedidos)
-- =====================================================================
alter table public.route_drafts add column if not exists name text;
alter table public.route_drafts add column if not exists carrier_name text;
alter table public.route_drafts add column if not exists delivery_count int not null default 0;
alter table public.route_drafts add column if not exists orders text[] not null default '{}';
alter table public.route_drafts add column if not exists content jsonb;
create index if not exists route_drafts_owner_idx on public.route_drafts(owner_id, status);

-- Guarda el estado del borrador (solo el dueño o con permiso global; nunca una hoja publicada)
create or replace function public.touch_draft(p_sheet_key text, p_name text, p_carrier text, p_count int, p_orders text[], p_content jsonb)
returns public.route_drafts language plpgsql security definer set search_path = public as $$
declare d public.route_drafts;
begin
  if not public.auth_has_perm('routes.create') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  d := public._draft(p_sheet_key, true);
  update public.route_drafts set name = coalesce(nullif(trim(p_name), ''), name), carrier_name = p_carrier, delivery_count = coalesce(p_count, 0),
         orders = coalesce(p_orders, '{}'), content = p_content, updated_at = now() where id = d.id returning * into d;
  return d;
end; $$;

-- Lista de borradores activos (propios; todos con routes.manage_all_drafts) con sus reservas
create or replace function public.list_drafts() returns table (id uuid, client_sheet_key text, name text, carrier_name text, delivery_count int, orders text[],
  owner_id uuid, owner_name text, status text, created_at timestamptz, updated_at timestamptz, reserved text[]) language sql stable security definer set search_path = public as $$
  select d.id, d.client_sheet_key, d.name, d.carrier_name, d.delivery_count, d.orders, d.owner_id, p.full_name, d.status, d.created_at, d.updated_at,
         coalesce((select array_agg(r.order_id order by r.order_id) from public.order_reservations r where r.sheet_key = d.client_sheet_key and r.status = 'BORRADOR'), '{}')
  from public.route_drafts d left join public.profiles p on p.id = d.owner_id
  where d.status = 'BORRADOR' and public.auth_has_perm('routes.create') and (d.owner_id = auth.uid() or public.auth_has_perm('routes.manage_all_drafts'))
  order by d.updated_at desc;
$$;
create or replace function public.draft_content(p_sheet_key text) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d public.route_drafts;
begin
  if not public.auth_has_perm('routes.create') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into d from public.route_drafts where client_sheet_key = p_sheet_key;
  if not found then return null; end if;
  if d.owner_id <> auth.uid() and not public.auth_has_perm('routes.manage_all_drafts') then raise exception 'FORBIDDEN_DRAFT' using errcode = '42501'; end if;
  return jsonb_build_object('name', d.name, 'status', d.status, 'content', d.content);
end; $$;

-- Eliminar borrador: libera reservas y confirmaciones temporales; nunca toca hojas publicadas, historial ni correlativos
create or replace function public.delete_draft(p_sheet_key text) returns int language plpgsql security definer set search_path = public as $$
declare d public.route_drafts; n int;
begin
  if not public.auth_has_perm('routes.create') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  d := public._draft(p_sheet_key, false);   -- FORBIDDEN_DRAFT si es ajeno sin permiso; DRAFT_PUBLISHED si ya se publicó
  if d.id is null then return 0; end if;
  delete from public.order_reservations where sheet_key = p_sheet_key and status = 'BORRADOR';
  get diagnostics n = row_count;
  delete from public.shipping_amount_confirmations where sheet_key = p_sheet_key and route_id is null;
  update public.route_drafts set status = 'CANCELADA', content = null, orders = '{}', updated_at = now() where id = d.id;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'DRAFT_DELETED', 'draft', p_sheet_key, jsonb_build_object('released', n, 'owner', d.owner_id, 'name', d.name));
  return n;
end; $$;

-- Reserva con detalle del conflicto (borrador, operador, hoja) para ofrecer IR AL BORRADOR / ELIMINAR Y LIBERAR
create or replace function public.reserve_orders(p_sheet_key text, p_orders text[])
returns void language plpgsql security definer set search_path = public as $$
declare msg text; det jsonb;
begin
  if not public.auth_has_perm('routes.create') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  perform public._draft(p_sheet_key, true);
  insert into public.order_reservations(order_id, sheet_key, reserved_by)
  select distinct o, p_sheet_key, auth.uid() from unnest(p_orders) o where coalesce(o, '') <> ''
  on conflict (order_id) do nothing;
  select string_agg(r.order_id || ' (' || coalesce('hoja ' || rt.number, 'borrador' || coalesce(' "' || d.name || '"', '') || coalesce(' de ' || p.full_name, '')) || ')', ', '),
         jsonb_agg(jsonb_build_object('order', r.order_id, 'sheet_key', r.sheet_key, 'draft_name', d.name, 'owner_id', r.reserved_by, 'owner', p.full_name, 'route_number', rt.number, 'published', rt.id is not null))
    into msg, det
    from public.order_reservations r left join public.routes rt on rt.id = r.route_id left join public.profiles p on p.id = r.reserved_by
    left join public.route_drafts d on d.client_sheet_key = r.sheet_key
   where r.order_id = any(p_orders) and r.sheet_key <> p_sheet_key;
  if msg is not null then raise exception 'PEDIDO_YA_EN_OTRA_HOJA: %', msg using errcode = '23505', detail = det::text; end if;
end; $$;

grant execute on function public.touch_draft(text, text, text, int, text[], jsonb), public.list_drafts(), public.draft_content(text), public.delete_draft(text) to authenticated;

-- =====================================================================
-- 3. HISTORIAL de hojas (búsqueda paginada con RLS del usuario) e índices
-- =====================================================================
create index if not exists routes_published_idx on public.routes(published_at desc);
create index if not exists routes_carrier_idx on public.routes(carrier_id);
create index if not exists routes_resp_idx on public.routes(responsable_id);
create index if not exists route_stops_client_idx on public.route_stops(lower(client_name));
create index if not exists route_stops_orders_idx on public.route_stops using gin(order_numbers);
create or replace function public.search_routes(p jsonb) returns table (id uuid, number text, carrier_id text, carrier_name text, responsable_name text, operational_status text,
  approval_status text, published_at timestamptz, completed_at timestamptz, stops int, bultos int, zones text[], total_count bigint)
language sql stable security invoker set search_path = public as $$
  select r.id, r.number, r.carrier_id, c.name, pr.full_name, r.operational_status, r.approval_status, r.published_at, r.completed_at,
         (select count(*) from public.route_stops s where s.route_id = r.id)::int,
         (select coalesce(sum(s.bultos), 0) from public.route_stops s where s.route_id = r.id)::int,
         (select array_agg(distinct s.zone) from public.route_stops s where s.route_id = r.id and s.zone is not null),
         count(*) over ()
  from public.routes r join public.carriers c on c.id = r.carrier_id left join public.profiles pr on pr.id = r.responsable_id
  where r.operational_status <> 'BORRADOR'
    and (coalesce(p->>'number', '') = '' or r.number ilike '%' || (p->>'number') || '%')
    and (coalesce(p->>'carrier', '') = '' or r.carrier_id = p->>'carrier')
    and (coalesce(p->>'status', '') = '' or r.operational_status = p->>'status')
    and (coalesce(p->>'approval', '') = '' or r.approval_status = p->>'approval')
    and (coalesce(p->>'responsable', '') = '' or pr.full_name ilike '%' || (p->>'responsable') || '%')
    and (coalesce(p->>'from', '') = '' or r.published_at >= (p->>'from')::date)
    and (coalesce(p->>'to', '') = '' or r.published_at < (p->>'to')::date + 1)
    and (coalesce(p->>'order', '') = '' or exists (select 1 from public.route_stops s where s.route_id = r.id and (p->>'order') = any(s.order_numbers)))
    and (coalesce(p->>'client', '') = '' or exists (select 1 from public.route_stops s where s.route_id = r.id and lower(s.client_name) like '%' || lower(p->>'client') || '%'))
    and (coalesce(p->>'zone', '') = '' or exists (select 1 from public.route_stops s where s.route_id = r.id and s.zone = p->>'zone'))
  order by r.published_at desc nulls last
  limit least(coalesce((p->>'limit')::int, 25), 100) offset coalesce((p->>'offset')::int, 0);
$$;
grant execute on function public.search_routes(jsonb) to authenticated;
-- Reenviar la notificación de una hoja al responsable
create or replace function public.resend_route_notification(p_route uuid) returns void language plpgsql security definer set search_path = public as $$
declare r public.routes;
begin
  if not public.auth_has_perm('routes.publish') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into r from public.routes where id = p_route and operational_status in ('PUBLICADA','EN_CURSO');
  if not found then raise exception 'BAD_STATE: solo hojas publicadas o en curso' using errcode = '23514'; end if;
  insert into public.notifications(user_id, route_id, route_version, type, title, body) values (r.responsable_id, r.id, r.version, 'RECORDATORIO_HOJA', 'HOJA ' || r.number || ' PUBLICADA', 'Recordatorio de Despacho')
  on conflict (user_id, route_id, route_version, type) do update set created_at = now(), read_at = null, delivered_at = null;
  insert into public.audit_log(actor_id, action, target_type, target_id) values (auth.uid(), 'ROUTE_NOTIFICATION_RESENT', 'route', p_route::text);
end; $$;
grant execute on function public.resend_route_notification(uuid) to authenticated;

-- =====================================================================
-- 4. CONFIGURACIÓN → TRANSPORTISTAS y PLANTILLAS DE HOJA (versionadas)
-- =====================================================================
alter table public.carriers add column if not exists emails text[] not null default '{}';
alter table public.carriers add column if not exists notes text;
insert into public.carriers(id, name, kind, sequence_code) values ('INTERNO', 'TRANSPORTE INTERNO', 'INTERNO', '03') on conflict (id) do nothing;
create or replace function public.upsert_carrier(p jsonb) returns public.carriers language plpgsql security definer set search_path = public as $$
declare c public.carriers;
begin
  if not public.auth_has_perm('settings.manage') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if coalesce(p->>'id', '') = '' or coalesce(p->>'name', '') = '' then raise exception 'BAD_CARRIER: id y nombre obligatorios' using errcode = '23514'; end if;
  if coalesce(p->>'sequence_code', '') !~ '^[0-9]{2}$' then raise exception 'BAD_CODE: el código de correlativo son 2 dígitos' using errcode = '23514'; end if;
  insert into public.carriers(id, name, kind, active, sequence_code, report_group, emails, notes)
  values (upper(p->>'id'), upper(p->>'name'), coalesce(p->>'kind', 'EXTERNO'), coalesce((p->>'active')::boolean, true), p->>'sequence_code', nullif(p->>'report_group', ''),
          coalesce((select array_agg(x) from jsonb_array_elements_text(p->'emails') x), '{}'), p->>'notes')
  on conflict (id) do update set name = excluded.name, kind = excluded.kind, active = excluded.active, sequence_code = excluded.sequence_code,
    report_group = excluded.report_group, emails = excluded.emails, notes = excluded.notes
  returning * into c;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'CARRIER_SAVED', 'carrier', c.id, to_jsonb(c));
  return c;
end; $$;
create table if not exists public.sheet_templates (
  id uuid primary key default gen_random_uuid(), carrier_id text not null references public.carriers(id), version int not null,
  columns jsonb not null, created_by uuid, created_at timestamptz not null default now(), unique (carrier_id, version)
);
alter table public.sheet_templates enable row level security;
create policy sheet_templates_read on public.sheet_templates for select to authenticated using (public.auth_has_perm('routes.create') or public.auth_has_perm('settings.manage'));
grant select on public.sheet_templates to authenticated;
-- Cada guardado crea una versión nueva (las hojas publicadas conservan la suya en el snapshot)
create or replace function public.save_sheet_template(p_carrier text, p_columns jsonb) returns public.sheet_templates language plpgsql security definer set search_path = public as $$
declare t public.sheet_templates;
begin
  if not public.auth_has_perm('settings.manage') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if jsonb_typeof(p_columns) <> 'array' or jsonb_array_length(p_columns) = 0 then raise exception 'BAD_TEMPLATE' using errcode = '22023'; end if;
  if exists (select 1 from jsonb_array_elements(p_columns) c where coalesce((c->>'required')::boolean, false) and not coalesce((c->>'visible')::boolean, true)) then
    raise exception 'REQUIRED_HIDDEN: una columna obligatoria no se puede ocultar' using errcode = '23514'; end if;
  insert into public.sheet_templates(carrier_id, version, columns, created_by)
  values (p_carrier, coalesce((select max(version) from public.sheet_templates where carrier_id = p_carrier), 0) + 1, p_columns, auth.uid()) returning * into t;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'TEMPLATE_SAVED', 'template', p_carrier, jsonb_build_object('version', t.version));
  return t;
end; $$;
grant execute on function public.upsert_carrier(jsonb), public.save_sheet_template(text, jsonb) to authenticated;

-- =====================================================================
-- 5. VEHÍCULOS Y MANTENIMIENTO (odómetro real, ciclo de service, alerta única por ciclo)
-- =====================================================================
alter table public.vehicles add column if not exists habitual_driver_id uuid references public.profiles(id);
create table if not exists public.vehicle_services (id bigserial primary key, vehicle_id uuid not null references public.vehicles(id), service_date date not null,
  km numeric(10,1) not null, note text, created_by uuid, created_at timestamptz not null default now());
create table if not exists public.vehicle_service_alerts (vehicle_id uuid not null references public.vehicles(id), cycle_base_km numeric(10,1) not null, created_at timestamptz not null default now(), primary key (vehicle_id, cycle_base_km));
alter table public.vehicle_services enable row level security; alter table public.vehicle_service_alerts enable row level security;
create policy vs_read on public.vehicle_services for select to authenticated using (public.auth_has_perm('vehicles.manage'));
create policy vsa_read on public.vehicle_service_alerts for select to authenticated using (public.auth_has_perm('vehicles.manage'));
grant select on public.vehicle_services, public.vehicle_service_alerts to authenticated;
alter table public.routes add column if not exists vehicle_plate text;
alter table public.routes add column if not exists vehicle_name text;
alter table public.routes add column if not exists km_started_at timestamptz;
alter table public.routes add column if not exists km_ended_at timestamptz;
drop view if exists public.vehicle_service_status;
create view public.vehicle_service_status with (security_invoker = true) as
  select v.*, v.last_service_km + v.service_interval_km as next_service_km, (v.last_service_km + v.service_interval_km) - v.current_km as km_to_service,
         v.current_km >= v.last_service_km + v.service_interval_km as service_due, v.current_km - v.last_service_km as km_since_service,
         (select full_name from public.profiles p where p.id = v.habitual_driver_id) as habitual_driver_name
  from public.vehicles v;
grant select on public.vehicle_service_status to authenticated;
-- Alerta una sola vez por ciclo (al llegar al próximo service) + aviso a Administración
create or replace function public._vehicle_service_check(p_vehicle uuid) returns void language plpgsql security definer set search_path = public as $$
declare v public.vehicles;
begin
  select * into v from public.vehicles where id = p_vehicle;
  if v.current_km >= v.last_service_km + v.service_interval_km then
    insert into public.vehicle_service_alerts(vehicle_id, cycle_base_km) values (v.id, v.last_service_km) on conflict do nothing;
    if found then
      insert into public.notifications(user_id, type, title, body)
      select p.id, 'SERVICE_REQUERIDO:' || v.id || ':' || v.last_service_km, '⚠ SERVICE REQUERIDO · ' || v.name || ' · ' || v.plate, 'KM actual ' || v.current_km || ' · próximo service ' || (v.last_service_km + v.service_interval_km)
      from public.profiles p where p.role = 'ADMIN' and p.status = 'ACTIVO' on conflict do nothing;
    end if;
  end if;
end; $$;
create or replace function public.upsert_vehicle(p jsonb) returns public.vehicles language plpgsql security definer set search_path = public as $$
declare v public.vehicles; isnew boolean := coalesce(p->>'id', '') = '' or not exists (select 1 from public.vehicles where id = (p->>'id')::uuid);
begin
  if not public.auth_has_perm('vehicles.manage') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if coalesce(trim(p->>'name'), '') = '' or coalesce(trim(p->>'plate'), '') = '' then raise exception 'BAD_VEHICLE: modelo y patente obligatorios' using errcode = '23514'; end if;
  if isnew then
    insert into public.vehicles(name, plate, active, brand, model, type, year, notes, current_km, last_service_km, service_interval_km, habitual_driver_id)
    values (p->>'name', upper(p->>'plate'), true, p->>'brand', p->>'model', p->>'type', nullif(p->>'year','')::int, p->>'notes', coalesce((p->>'current_km')::numeric, 0),
            coalesce(nullif(p->>'last_service_km', '')::numeric, coalesce((p->>'current_km')::numeric, 0)), coalesce(nullif(p->>'service_interval_km', '')::int, 10000), nullif(p->>'habitual_driver_id', '')::uuid)
    returning * into v;
  else
    update public.vehicles set name = p->>'name', plate = upper(p->>'plate'), active = coalesce((p->>'active')::boolean, active), notes = coalesce(p->>'notes', notes),
           service_interval_km = coalesce(nullif(p->>'service_interval_km', '')::int, service_interval_km), habitual_driver_id = nullif(p->>'habitual_driver_id', '')::uuid
     where id = (p->>'id')::uuid returning * into v;
  end if;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'VEHICLE_SAVED', 'vehicle', v.id::text, to_jsonb(v));
  perform public._vehicle_service_check(v.id);
  return v;
end; $$;
drop function if exists public.register_vehicle_service(uuid, numeric, date);
create or replace function public.register_vehicle_service(p_vehicle uuid, p_km numeric, p_date date, p_note text default null) returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.auth_has_perm('vehicles.manage') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_km is null or p_km <= 0 then raise exception 'BAD_KM' using errcode = '22023'; end if;
  insert into public.vehicle_services(vehicle_id, service_date, km, note, created_by) values (p_vehicle, coalesce(p_date, current_date), p_km, p_note, auth.uid());
  update public.vehicles set last_service_km = p_km, last_service_date = coalesce(p_date, current_date), current_km = greatest(current_km, p_km) where id = p_vehicle;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'VEHICLE_SERVICE_REGISTERED', 'vehicle', p_vehicle::text, jsonb_build_object('km', p_km, 'date', p_date, 'note', p_note));
end; $$;
grant execute on function public.upsert_vehicle(jsonb), public.register_vehicle_service(uuid, numeric, date, text) to authenticated;
-- Al publicar se congela vehículo/patente
create or replace function public.trg_route_vehicle_from_snapshot() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.sheet_snapshot ? 'vehicle_id' and coalesce(new.sheet_snapshot->>'vehicle_id', '') <> '' and exists (select 1 from public.carriers where id = new.carrier_id and kind = 'INTERNO') then
    new.vehicle_id := (new.sheet_snapshot->>'vehicle_id')::uuid;
    select plate, name into new.vehicle_plate, new.vehicle_name from public.vehicles where id = new.vehicle_id and active;
    if new.vehicle_plate is null then raise exception 'BAD_VEHICLE: vehículo inexistente o inactivo' using errcode = '23514'; end if;
  end if;
  return new;
end; $$;
-- Iniciar: KM INICIAL obligatorio si hay vehículo (odómetro real, no puede ser menor al último)
drop function if exists public.start_route(uuid);
create or replace function public.start_route(p_route uuid, p_km_start numeric default null) returns public.routes language plpgsql security definer set search_path = public as $$
declare r public.routes; v public.vehicles;
begin
  r := public._my_route(p_route);
  if r.operational_status = 'EN_CURSO' then return r; end if;
  if r.operational_status <> 'PUBLICADA' then raise exception 'BAD_STATE: la hoja no se puede iniciar (%)', r.operational_status using errcode = '23514'; end if;
  if r.vehicle_id is not null then
    select * into v from public.vehicles where id = r.vehicle_id for update;
    if p_km_start is null then raise exception 'KM_START_REQUIRED: cargá el kilometraje inicial' using errcode = '23514'; end if;
    if p_km_start < v.current_km then raise exception 'KM_LOWER: el kilometraje no puede ser menor al último registrado (%)', v.current_km using errcode = '23514'; end if;
    update public.vehicles set current_km = p_km_start where id = v.id;
  end if;
  update public.routes set operational_status = 'EN_CURSO', status = 'EN_CURSO', started_at = now(), started_by = auth.uid(), viewed_at = coalesce(viewed_at, now()),
         km_start = coalesce(p_km_start, km_start), km_started_at = case when p_km_start is not null then now() end where id = p_route returning * into r;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'ROUTE_STARTED', 'route', p_route::text, jsonb_build_object('km_start', p_km_start));
  perform public._queue_on_the_way(p_route);
  return r;
end; $$;
grant execute on function public.start_route(uuid, numeric) to authenticated, service_role;
-- Al finalizar: km final >= inicial; el odómetro queda en el km final; alerta de service si corresponde
create or replace function public.trg_route_km_after_finalize() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.operational_status = 'COMPLETADA' and old.operational_status <> 'COMPLETADA' and new.vehicle_id is not null then
    if new.km_start is not null and new.km_end < new.km_start then raise exception 'KM_LOWER: el km final no puede ser menor al inicial (%)', new.km_start using errcode = '23514'; end if;
    new.km_ended_at := now();
    perform public._vehicle_service_check(new.vehicle_id);
  end if;
  return new;
end; $$;
drop trigger if exists route_km_after_finalize on public.routes;
create trigger route_km_after_finalize before update on public.routes for each row execute function public.trg_route_km_after_finalize();

-- =====================================================================
-- 6. REGLAS FINANCIERAS (versionadas, auditadas; las usa el panel y quedan en el snapshot de cada hoja)
-- =====================================================================
create table if not exists public.financial_rules (version int primary key, rules jsonb not null, created_by uuid, created_at timestamptz not null default now());
insert into public.financial_rules(version, rules) values (1, '{"pay":{"FAC":"ICBC","NDP":"SIMPLY"},"shipCosts":{"ESTE":[13000],"ALREDEDORES":[2000,4000,10000]},"creditMonths":6,"creditTypes":["NOC","REC","REP"],"tolerance":1}')
on conflict do nothing;
alter table public.financial_rules enable row level security;
create policy financial_rules_read on public.financial_rules for select to authenticated using (public.auth_has_perm('routes.create') or public.auth_has_perm('settings.manage'));
grant select on public.financial_rules to authenticated;
create or replace function public.set_financial_rules(p_rules jsonb) returns public.financial_rules language plpgsql security definer set search_path = public as $$
declare f public.financial_rules; prev jsonb;
begin
  if not public.auth_has_perm('settings.manage') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if (p_rules->>'tolerance')::numeric < 0 or (p_rules->>'creditMonths')::int < 0 then raise exception 'BAD_RULES' using errcode = '22023'; end if;
  select rules into prev from public.financial_rules order by version desc limit 1;
  insert into public.financial_rules(version, rules, created_by) values ((select max(version) from public.financial_rules) + 1, p_rules, auth.uid()) returning * into f;
  insert into public.audit_log(actor_id, action, target_type, target_id, before, after) values (auth.uid(), 'FINANCIAL_RULES_CHANGED', 'settings', 'v' || f.version, prev, p_rules);
  return f;
end; $$;
grant execute on function public.set_financial_rules(jsonb) to authenticated;

-- =====================================================================
-- 7. EMAILS Y NOTIFICACIONES · PDF Y ENVÍOS · UBICACIONES · PARÁMETROS
-- =====================================================================
create table if not exists public.notification_settings (
  id text primary key default 'DEFAULT', on_the_way_enabled boolean not null default true, delivered_enabled boolean not null default true,
  sheet_email_enabled boolean not null default false, sheet_email_time text not null default '18:00' check (sheet_email_time ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'),
  sheet_email_recipients text[] not null default '{}', provider text not null default 'RESEND', max_retries int not null default 5
);
insert into public.notification_settings(id) values ('DEFAULT') on conflict do nothing;
alter table public.notification_settings enable row level security;
create policy notification_settings_read on public.notification_settings for select to authenticated using (public.auth_has_perm('settings.manage') or public.auth_has_perm('routes.create'));
grant select on public.notification_settings to authenticated;
create or replace function public.set_notification_settings(p jsonb) returns public.notification_settings language plpgsql security definer set search_path = public as $$
declare s public.notification_settings;
begin
  if not public.auth_has_perm('settings.manage') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  update public.notification_settings set on_the_way_enabled = coalesce((p->>'on_the_way_enabled')::boolean, on_the_way_enabled), delivered_enabled = coalesce((p->>'delivered_enabled')::boolean, delivered_enabled),
    sheet_email_enabled = coalesce((p->>'sheet_email_enabled')::boolean, sheet_email_enabled), sheet_email_time = coalesce(p->>'sheet_email_time', sheet_email_time),
    sheet_email_recipients = coalesce((select array_agg(lower(x)) from jsonb_array_elements_text(p->'sheet_email_recipients') x), sheet_email_recipients),
    provider = coalesce(p->>'provider', provider), max_retries = coalesce((p->>'max_retries')::int, max_retries)
  where id = 'DEFAULT' returning * into s;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'NOTIFICATION_SETTINGS_CHANGED', 'settings', 'DEFAULT', to_jsonb(s));
  return s;
end; $$;
grant execute on function public.set_notification_settings(jsonb) to authenticated;
-- Los emails al cliente respetan la configuración (va en camino / entrega)
create or replace function public.trg_customer_email_settings() returns trigger language plpgsql security definer set search_path = public as $$
declare s public.notification_settings;
begin
  select * into s from public.notification_settings where id = 'DEFAULT';
  if new.kind = 'ON_THE_WAY' and not coalesce(s.on_the_way_enabled, true) then return null; end if;
  if new.kind in ('DELIVERED','PARTIAL') and not coalesce(s.delivered_enabled, true) then return null; end if;
  return new;
end; $$;
drop trigger if exists customer_email_settings on public.customer_email_jobs;
create trigger customer_email_settings before insert on public.customer_email_jobs for each row execute function public.trg_customer_email_settings();
-- Email diario de PDFs de hojas (default 18:00 Mendoza): idempotente por hoja+versión+destinatario; una v2 sale aparte
create table if not exists public.sheet_email_jobs (
  id uuid primary key default gen_random_uuid(), route_id uuid not null references public.routes(id), route_version int not null, recipient text not null,
  idempotency_key text not null unique, status text not null default 'QUEUED' check (status in ('QUEUED','SENT','ERROR')),
  queued_at timestamptz not null default now(), sent_at timestamptz, provider_id text, error text, retry_count int not null default 0
);
alter table public.sheet_email_jobs enable row level security;
create policy sej_read on public.sheet_email_jobs for select to authenticated using (public.auth_has_perm('settings.manage'));
grant select on public.sheet_email_jobs to authenticated;
create or replace function public.queue_sheet_emails(p_day date) returns int language plpgsql security definer set search_path = public as $$
declare s public.notification_settings; n int;
begin
  select * into s from public.notification_settings where id = 'DEFAULT';
  if not s.sheet_email_enabled then return 0; end if;
  -- el envío del día sale a partir del horario configurado (hora de Mendoza)
  if p_day = (now() at time zone 'America/Argentina/Mendoza')::date and to_char(now() at time zone 'America/Argentina/Mendoza', 'HH24:MI') < s.sheet_email_time then return 0; end if;
  insert into public.sheet_email_jobs(route_id, route_version, recipient, idempotency_key)
  select p.route_id, p.route_version, e, p.route_id || '|' || p.route_version || '|' || e
  from public.route_pdfs p cross join unnest(s.sheet_email_recipients) e
  where p.status = 'OK' and (p.generated_at at time zone 'America/Argentina/Mendoza')::date = p_day
  on conflict (idempotency_key) do nothing;
  get diagnostics n = row_count; return n;
end; $$;
revoke execute on function public.queue_sheet_emails(date) from public, anon, authenticated;

alter table public.client_locations add column if not exists client_name text;
alter table public.client_locations add column if not exists address text;
alter table public.client_locations add column if not exists active boolean not null default true;
alter table public.client_locations add column if not exists note text;
create or replace function public.upsert_client_location(p jsonb) returns public.client_locations language plpgsql security definer set search_path = public as $$
declare l public.client_locations;
begin
  if not (public.auth_has_perm('settings.manage') or public.auth_has_perm('locations.manage')) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if coalesce(p->>'client_key', '') = '' or (p->>'lat') is null or (p->>'lon') is null then raise exception 'BAD_LOCATION' using errcode = '23514'; end if;
  if abs((p->>'lat')::float8) > 90 or abs((p->>'lon')::float8) > 180 then raise exception 'BAD_LOCATION: coordenadas inválidas' using errcode = '23514'; end if;
  insert into public.client_locations(client_key, client_name, address, lat, lon, radius_m, active, note)
  values (p->>'client_key', p->>'client_name', p->>'address', (p->>'lat')::float8, (p->>'lon')::float8, coalesce((p->>'radius_m')::int, 200), coalesce((p->>'active')::boolean, true), p->>'note')
  on conflict (client_key) do update set client_name = excluded.client_name, address = excluded.address, lat = excluded.lat, lon = excluded.lon, radius_m = excluded.radius_m, active = excluded.active, note = excluded.note
  returning * into l;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'LOCATION_SAVED', 'location', l.client_key, to_jsonb(l));
  return l;
end; $$;
grant execute on function public.upsert_client_location(jsonb) to authenticated;
create table if not exists public.app_settings (key text primary key, value jsonb not null, updated_by uuid, updated_at timestamptz not null default now());
insert into public.app_settings(key, value) values ('general', '{"company":"OK Accesorios","timezone":"America/Argentina/Mendoza","draft_stale_days":2,"return_days":2}') on conflict do nothing;
alter table public.app_settings enable row level security;
create policy app_settings_read on public.app_settings for select to authenticated using (true);
grant select on public.app_settings to authenticated;
create or replace function public.set_app_setting(p_key text, p_value jsonb) returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.auth_has_perm('settings.manage') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  insert into public.app_settings(key, value, updated_by) values (p_key, p_value, auth.uid()) on conflict (key) do update set value = excluded.value, updated_by = auth.uid(), updated_at = now();
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'APP_SETTING_CHANGED', 'settings', p_key, p_value);
end; $$;
grant execute on function public.set_app_setting(text, jsonb) to authenticated;

-- =====================================================================
-- 8. DASHBOARD (contadores según permisos del usuario)
-- =====================================================================
create or replace function public.dashboard_summary() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare stale int := coalesce((select (value->>'draft_stale_days')::int from public.app_settings where key = 'general'), 2);
begin
  if not (public.auth_has_perm('routes.create') or public.auth_has_perm('users.view') or public.auth_has_perm('settings.manage')) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return jsonb_build_object(
    'drafts', (select count(*) from public.route_drafts where status = 'BORRADOR' and (owner_id = auth.uid() or public.auth_has_perm('routes.manage_all_drafts'))),
    'drafts_stale', (select count(*) from public.route_drafts where status = 'BORRADOR' and updated_at < now() - make_interval(days => stale) and (owner_id = auth.uid() or public.auth_has_perm('routes.manage_all_drafts'))),
    'reserved_orders', (select count(*) from public.order_reservations where status = 'BORRADOR'),
    'approvals', case when public.auth_has_perm('can_approve_internal_route_changes') then (select count(*) from public.route_approval_requests where status = 'PENDING') else 0 end,
    'returns', (select count(*) from public.route_return_requests where status = 'PENDING'),
    'service_due', case when public.auth_has_perm('vehicles.manage') then (select count(*) from public.vehicle_service_status where active and service_due) else 0 end,
    'email_errors', case when public.auth_has_perm('settings.manage') then (select count(*) from public.approval_email_jobs where status = 'ERROR') + (select count(*) from public.customer_email_jobs where status = 'ERROR') + (select count(*) from public.report_emails where status in ('ERROR','PDF_ERROR')) + (select count(*) from public.sheet_email_jobs where status = 'ERROR') else 0 end,
    'pdf_errors', (select count(*) from public.route_pdfs where status = 'PDF_ERROR'),
    'incidents_today', (select count(*) from public.route_stops where outcome in ('NO_ENTREGADO','REPROGRAMAR') and (outcome_at at time zone 'America/Argentina/Mendoza')::date = (now() at time zone 'America/Argentina/Mendoza')::date),
    'active_routes', (select count(*) from public.routes where operational_status in ('PUBLICADA','EN_CURSO')));
end; $$;
grant execute on function public.dashboard_summary() to authenticated;
