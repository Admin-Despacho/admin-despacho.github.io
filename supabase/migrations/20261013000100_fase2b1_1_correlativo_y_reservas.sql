-- OK DESPACHO ONLINE — CORRECCIÓN 2B.1.1 (incremental)
-- 1) Correlativo por transportista/base: CODIGO-SECUENCIA (01-000001), continuo, sin reinicio diario, atómico.
-- 2) Reserva server-side de pedidos: un pedido activo pertenece a una sola hoja.

-- ---------- 1. Correlativo ----------
alter table public.carriers add column if not exists sequence_code text check (sequence_code ~ '^[0-9]{2}$');
update public.carriers set sequence_code = case id when 'CT-ESTE' then '01' when 'CT-ALR' then '01' when 'UCO' then '02' when 'INTERNO' then '03'
  when 'VASCA' then '04' when 'ANDESMAR' then '05' when 'MARCHETTI' then '06' end where sequence_code is null;
create table if not exists public.route_sequences (code text primary key check (code ~ '^[0-9]{2}$'), last bigint not null);
alter table public.route_sequences enable row level security;

-- Un número consumido no se reutiliza nunca (aunque la hoja se cancele). CT Este y Alrededores comparten el código 01.
create or replace function public.next_route_number_for(p_carrier text)
returns text language plpgsql security definer set search_path = public as $$
declare v_code text; n bigint;
begin
  select sequence_code into v_code from public.carriers where id = p_carrier;
  if v_code is null then raise exception 'NO_SEQUENCE_CODE: el transportista % no tiene código de correlativo', p_carrier using errcode = '23514'; end if;
  insert into public.route_sequences(code, last) values (v_code, 1)
  on conflict (code) do update set last = public.route_sequences.last + 1
  returning last into n;
  return v_code || '-' || lpad(n::text, 6, '0');
end; $$;
revoke execute on function public.next_route_number_for(text) from public, anon, authenticated;
grant execute on function public.next_route_number_for(text) to service_role;

-- ---------- 2. Reserva de pedidos ----------
create table if not exists public.order_reservations (
  order_id text primary key,                 -- Pedido Nº (mercadería o envío)
  sheet_key text not null,
  route_id uuid references public.routes(id),
  status text not null default 'BORRADOR' check (status in ('BORRADOR','PUBLICADA')),
  reserved_by uuid, reserved_at timestamptz not null default now()
);
alter table public.order_reservations enable row level security;
create policy order_reservations_read on public.order_reservations for select to authenticated using (public.auth_has_perm('routes.create') or public.auth_has_perm('routes.view_all'));
grant select on public.order_reservations to authenticated;

-- Reserva atómica: o reserva todos los pedidos para esta hoja o falla con PEDIDO_YA_EN_OTRA_HOJA (sin reservar ninguno).
-- Idempotente para la misma hoja (reintento).
create or replace function public.reserve_orders(p_sheet_key text, p_orders text[])
returns void language plpgsql security definer set search_path = public as $$
declare c record; msg text;
begin
  if not public.auth_has_perm('routes.create') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  insert into public.order_reservations(order_id, sheet_key, reserved_by)
  select distinct o, p_sheet_key, auth.uid() from unnest(p_orders) o where coalesce(o, '') <> ''
  on conflict (order_id) do nothing;            -- si otra sesión lo reservó en paralelo, espera su commit y no pisa
  select string_agg(r.order_id || ' (' || coalesce('hoja ' || rt.number, 'otra hoja borrador' || coalesce(' de ' || p.full_name, '')) || ')', ', ') into msg
    from public.order_reservations r left join public.routes rt on rt.id = r.route_id left join public.profiles p on p.id = r.reserved_by
   where r.order_id = any(p_orders) and r.sheet_key <> p_sheet_key;
  if msg is not null then raise exception 'PEDIDO_YA_EN_OTRA_HOJA: %', msg using errcode = '23505'; end if;
end; $$;

-- Liberar: solo pedidos de un BORRADOR de esta hoja (una hoja publicada no libera para duplicar)
create or replace function public.release_orders(p_sheet_key text, p_orders text[])
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.auth_has_perm('routes.create') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  delete from public.order_reservations where sheet_key = p_sheet_key and status = 'BORRADOR' and (p_orders is null or order_id = any(p_orders));
  get diagnostics n = row_count; return n;
end; $$;

grant execute on function public.reserve_orders(text, text[]), public.release_orders(text, text[]) to authenticated, service_role;
revoke execute on function public.reserve_orders(text, text[]), public.release_orders(text, text[]) from public, anon;

-- ---------- publish_route: correlativo por transportista + reserva de pedidos ----------
create or replace function public.publish_route(p jsonb)
returns public.routes language plpgsql security definer set search_path = public as $$
declare r public.routes; resp uuid := (p->>'responsable_id')::uuid; car text := p->>'carrier_id'; s jsonb; i int := 0; ships text[]; ords text[];
begin
  if not public.auth_has_perm('routes.publish') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into r from public.routes where sheet_key = p->>'sheet_key';
  if found then return r; end if;
  if car is null or not exists (select 1 from public.carriers where id = car and active) then raise exception 'BAD_CARRIER: elegí el transportista' using errcode = '23514'; end if;
  if resp is null or not public.can_be_responsable(resp, car) then raise exception 'RESPONSABLE_INCOMPATIBLE' using errcode = '23514'; end if;
  if jsonb_array_length(coalesce(p->'stops', '[]')) = 0 then raise exception 'EMPTY_SHEET: la hoja no tiene pedidos' using errcode = '23514'; end if;
  select array_agg(x->>'ship_order') into ships from jsonb_array_elements(p->'stops') x where x->>'ship_fee_status' = 'PROVISIONAL';
  if ships is not null then perform public.assert_sheet_shipping_ready(p->>'sheet_key', ships); end if;
  if exists (select 1 from jsonb_array_elements(p->'stops') x where coalesce((x->>'ready')::boolean, false) = false) then
    raise exception 'NOT_READY: hay pedidos con revisión pendiente o sin monto' using errcode = '23514';
  end if;
  select array_agg(distinct v) into ords from jsonb_array_elements(p->'stops') x, jsonb_array_elements_text(x->'order_numbers') v;
  perform public.reserve_orders(p->>'sheet_key', ords);   -- falla si algún pedido está en otra hoja
  insert into public.routes(number, carrier_id, responsable_id, status, operational_status, created_by, sheet_key, published_at, published_by, sheet_snapshot)
  values (public.next_route_number_for(car), car, resp, 'PUBLICADA', 'PUBLICADA', auth.uid(), p->>'sheet_key', now(), auth.uid(), p)
  returning * into r;
  update public.order_reservations set status = 'PUBLICADA', route_id = r.id where sheet_key = p->>'sheet_key';
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
