-- OK DESPACHO ONLINE — FASE 2B.1 CORE (incremental): publicar → recibir → ver → iniciar → resultados → finalizar.

-- ---------- Hojas: datos de publicación y recorrido ----------
alter table public.routes add column if not exists sheet_key text;
alter table public.routes add column if not exists published_at timestamptz;
alter table public.routes add column if not exists published_by uuid;
alter table public.routes add column if not exists notified_at timestamptz;
alter table public.routes add column if not exists viewed_at timestamptz;
alter table public.routes add column if not exists started_at timestamptz;
alter table public.routes add column if not exists started_by uuid;
alter table public.routes add column if not exists sheet_snapshot jsonb;
alter table public.routes add column if not exists final_summary jsonb;
create unique index if not exists routes_sheet_key_uniq on public.routes(sheet_key) where sheet_key is not null; -- una publicación por hoja

-- ---------- Paradas: resultado con actor y motivo ----------
alter table public.route_stops alter column zone drop not null;  -- solo Cristian usa zona para el informe
alter table public.route_stops add column if not exists bultos int;
alter table public.route_stops add column if not exists address text;
alter table public.route_stops add column if not exists outcome_by uuid;
alter table public.route_stops add column if not exists outcome_note text;
alter table public.route_stops add column if not exists outcome_reason text;
create table if not exists public.stop_outcome_ops (op_id text primary key, stop_id uuid not null references public.route_stops(id), at timestamptz not null default now());

-- ---------- Correlativo atómico por día (sin MAX+1) ----------
create table if not exists public.route_number_counters (day date primary key, last int not null);
create or replace function public.next_route_number(p_day date)
returns text language sql security definer set search_path = public as $$
  insert into public.route_number_counters(day, last) values (p_day, 1)
  on conflict (day) do update set last = public.route_number_counters.last + 1
  returning to_char(p_day, 'DD') || '-' || lpad(last::text, 2, '0');
$$;

-- ---------- Notificaciones persistentes ----------
create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id),
  route_id uuid references public.routes(id), route_version int not null default 1,
  type text not null, title text not null, body text,
  created_at timestamptz not null default now(), delivered_at timestamptz, read_at timestamptz,
  unique (user_id, route_id, route_version, type)   -- retry / reconnect no duplican
);

-- ---------- Publicar (validación server-side + correlativo + snapshot + notificación) ----------
create or replace function public.publish_route(p jsonb)
returns public.routes language plpgsql security definer set search_path = public as $$
declare r public.routes; resp uuid := (p->>'responsable_id')::uuid; car text := p->>'carrier_id'; s jsonb; i int := 0; ships text[];
begin
  if not public.auth_has_perm('routes.publish') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into r from public.routes where sheet_key = p->>'sheet_key';
  if found then return r; end if;                                  -- reintento: misma hoja, no se publica dos veces
  if car is null or not exists (select 1 from public.carriers where id = car and active) then raise exception 'BAD_CARRIER: elegí el transportista' using errcode = '23514'; end if;
  if resp is null or not public.can_be_responsable(resp, car) then raise exception 'RESPONSABLE_INCOMPATIBLE' using errcode = '23514'; end if;
  if jsonb_array_length(coalesce(p->'stops', '[]')) = 0 then raise exception 'EMPTY_SHEET: la hoja no tiene pedidos' using errcode = '23514'; end if;
  select array_agg(x->>'ship_order') into ships from jsonb_array_elements(p->'stops') x where x->>'ship_fee_status' = 'PROVISIONAL';
  if ships is not null then perform public.assert_sheet_shipping_ready(p->>'sheet_key', ships); end if;
  if exists (select 1 from jsonb_array_elements(p->'stops') x where coalesce((x->>'ready')::boolean, false) = false) then
    raise exception 'NOT_READY: hay pedidos con revisión pendiente o sin monto' using errcode = '23514';
  end if;
  insert into public.routes(number, carrier_id, responsable_id, status, operational_status, created_by, sheet_key, published_at, published_by, sheet_snapshot)
  values (public.next_route_number((now() at time zone 'America/Argentina/Mendoza')::date), car, resp, 'PUBLICADA', 'PUBLICADA', auth.uid(), p->>'sheet_key', now(), auth.uid(), p)
  returning * into r;
  for s in select * from jsonb_array_elements(p->'stops') loop
    i := i + 1;
    insert into public.route_stops(route_id, seq, client_name, client_key, zone, order_numbers, merchandise_amount, shipping_fee, shipping_fee_source, bultos, address)
    values (r.id, i, s->>'client_name', s->>'client_key', nullif(s->>'zone',''), coalesce((select array_agg(v) from jsonb_array_elements_text(s->'order_numbers') v), '{}'),
            coalesce((s->>'merchandise_amount')::numeric, 0), coalesce((s->>'shipping_fee')::numeric, 0),
            case when s->>'ship_fee_status' = 'PROVISIONAL' then 'CONFIRMED_FALLBACK' else 'SALDO' end, nullif(s->>'bultos','')::int, s->>'address');
  end loop;
  insert into public.notifications(user_id, route_id, route_version, type, title, body)
  values (resp, r.id, 1, 'NUEVA_HOJA_PUBLICADA', 'NUEVA HOJA PUBLICADA', 'Hoja ' || r.number || ' · ' || i || ' entregas')
  on conflict do nothing;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'ROUTE_PUBLISHED', 'route', r.id::text, jsonb_build_object('number', r.number, 'carrier', car, 'responsable', resp, 'stops', i));
  return r;
end; $$;

create or replace function public._my_route(p_route uuid) returns public.routes language plpgsql security definer set search_path = public as $$
declare r public.routes;
begin
  select * into r from public.routes where id = p_route for update;
  if not found or r.responsable_id is distinct from auth.uid() or not public.auth_has_perm('routes.view_assigned') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return r;
end; $$;

create or replace function public.mark_notification_delivered(p_route uuid) returns void language plpgsql security definer set search_path = public as $$
begin
  update public.notifications set delivered_at = coalesce(delivered_at, now()) where route_id = p_route and user_id = auth.uid();
  update public.routes set notified_at = coalesce(notified_at, now()) where id = p_route and responsable_id = auth.uid();
end; $$;

-- Abrir la hoja registra VISTA (no inicia el recorrido)
create or replace function public.mark_route_viewed(p_route uuid) returns public.routes language plpgsql security definer set search_path = public as $$
declare r public.routes;
begin
  r := public._my_route(p_route);
  update public.routes set viewed_at = coalesce(viewed_at, now()), notified_at = coalesce(notified_at, now()) where id = p_route returning * into r;
  update public.notifications set read_at = coalesce(read_at, now()), delivered_at = coalesce(delivered_at, now()) where route_id = p_route and user_id = auth.uid();
  return r;
end; $$;

create or replace function public.start_route(p_route uuid) returns public.routes language plpgsql security definer set search_path = public as $$
declare r public.routes;
begin
  r := public._my_route(p_route);
  if r.operational_status = 'EN_CURSO' then return r; end if;
  if r.operational_status <> 'PUBLICADA' then raise exception 'BAD_STATE: la hoja no se puede iniciar (%)', r.operational_status using errcode = '23514'; end if;
  update public.routes set operational_status = 'EN_CURSO', status = 'EN_CURSO', started_at = now(), started_by = auth.uid(), viewed_at = coalesce(viewed_at, now()) where id = p_route returning * into r;
  insert into public.audit_log(actor_id, action, target_type, target_id) values (auth.uid(), 'ROUTE_STARTED', 'route', p_route::text);
  return r;
end; $$;

create or replace function public.set_stop_outcome(p_stop uuid, p_outcome text, p_note text, p_reason text, p_op_id text) returns public.route_stops language plpgsql security definer set search_path = public as $$
declare st public.route_stops; r public.routes;
begin
  select * into st from public.route_stops where id = p_stop;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  r := public._my_route(st.route_id);
  if p_op_id is not null and exists (select 1 from public.stop_outcome_ops where op_id = p_op_id) then return st; end if;  -- reintento offline
  if r.operational_status <> 'EN_CURSO' then raise exception 'BAD_STATE: iniciá el recorrido o la hoja ya está cerrada' using errcode = '23514'; end if;
  if p_outcome not in ('ENTREGADO','ENTREGA_PARCIAL','NO_ENTREGADO','REPROGRAMAR') then raise exception 'BAD_OUTCOME' using errcode = '22023'; end if;
  if p_outcome = 'ENTREGA_PARCIAL' and coalesce(trim(p_note), '') = '' then raise exception 'NOTE_REQUIRED: entrega parcial exige observación' using errcode = '23514'; end if;
  if p_outcome in ('NO_ENTREGADO','REPROGRAMAR') and coalesce(trim(p_reason), '') = '' then raise exception 'REASON_REQUIRED: indicá el motivo' using errcode = '23514'; end if;
  update public.route_stops set outcome = p_outcome, outcome_at = now(), outcome_by = auth.uid(), outcome_note = nullif(trim(p_note),''), outcome_reason = nullif(trim(p_reason),'') where id = p_stop returning * into st;
  if p_op_id is not null then insert into public.stop_outcome_ops(op_id, stop_id) values (p_op_id, p_stop); end if;
  return st;
end; $$;

create or replace function public.finalize_route(p_route uuid) returns public.routes language plpgsql security definer set search_path = public as $$
declare r public.routes; pend int; summ jsonb;
begin
  r := public._my_route(p_route);
  if r.operational_status = 'COMPLETADA' then return r; end if;   -- doble toque
  if r.operational_status <> 'EN_CURSO' then raise exception 'BAD_STATE' using errcode = '23514'; end if;
  select count(*) filter (where outcome = 'PENDIENTE') into pend from public.route_stops where route_id = p_route;
  if pend > 0 then raise exception 'PENDING_STOPS: faltan % entregas por resolver', pend using errcode = '23514'; end if;
  select jsonb_object_agg(outcome, n) into summ from (select outcome, count(*) n from public.route_stops where route_id = p_route group by outcome) x;
  update public.routes set operational_status = 'COMPLETADA', status = 'COMPLETADA', completed_at = now(), completed_by = auth.uid(), final_summary = summ where id = p_route returning * into r;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'ROUTE_FINALIZED', 'route', p_route::text, summ);
  return r;
end; $$;

-- Hoja finalizada: solo lectura (salvo servidor)
create or replace function public.trg_stops_readonly_when_closed() returns trigger language plpgsql as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' and exists (select 1 from public.routes r where r.id = old.route_id and r.operational_status = 'COMPLETADA') then
    raise exception 'READ_ONLY: la hoja ya está finalizada' using errcode = '23514';
  end if;
  return new;
end; $$;
drop trigger if exists stops_readonly_when_closed on public.route_stops;
create trigger stops_readonly_when_closed before update on public.route_stops for each row execute function public.trg_stops_readonly_when_closed();

-- ---------- RLS ----------
alter table public.notifications enable row level security;
alter table public.stop_outcome_ops enable row level security;
alter table public.route_number_counters enable row level security;
create policy notifications_own on public.notifications for select to authenticated using (user_id = auth.uid());
grant select on public.notifications to authenticated;
revoke execute on function public.next_route_number(date), public._my_route(uuid) from public, anon, authenticated;
grant execute on function public.publish_route(jsonb), public.mark_notification_delivered(uuid), public.mark_route_viewed(uuid), public.start_route(uuid),
  public.set_stop_outcome(uuid, text, text, text, text), public.finalize_route(uuid) to authenticated, service_role;
grant execute on function public.next_route_number(date) to service_role;

-- Realtime (Supabase): hojas y notificaciones en vivo
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.notifications, public.routes;
  end if;
end $$;
