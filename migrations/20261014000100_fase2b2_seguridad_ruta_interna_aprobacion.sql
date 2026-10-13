-- OK DESPACHO ONLINE — FASE 2B.2 (incremental)
-- 1) Borradores con dueño (FORBIDDEN_DRAFT)  2) Passkeys  3) Ruta interna dinámica  4) Aprobación + emails

-- =====================================================================
-- 1. BORRADORES CON DUEÑO
-- =====================================================================
insert into public.permissions(code) values ('routes.manage_all_drafts') on conflict do nothing;
insert into public.role_permissions(role_code, permission_code) values ('ADMIN','routes.manage_all_drafts') on conflict do nothing;

create table if not exists public.route_drafts (
  id uuid primary key default gen_random_uuid(),
  client_sheet_key text not null unique,
  owner_id uuid not null references public.profiles(id),
  status text not null default 'BORRADOR' check (status in ('BORRADOR','PUBLICADA','CANCELADA')),
  route_id uuid references public.routes(id),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
alter table public.route_drafts enable row level security;
create policy route_drafts_read on public.route_drafts for select to authenticated using (owner_id = auth.uid() or public.auth_has_perm('routes.manage_all_drafts'));
grant select on public.route_drafts to authenticated;

-- El borrador es del usuario que lo creó. Otro operador → FORBIDDEN_DRAFT (salvo permiso global explícito).
create or replace function public._draft(p_sheet_key text, p_create boolean, p_need_draft boolean default true)
returns public.route_drafts language plpgsql security definer set search_path = public as $$
declare d public.route_drafts;
begin
  if coalesce(p_sheet_key, '') = '' then raise exception 'BAD_SHEET' using errcode = '22023'; end if;
  select * into d from public.route_drafts where client_sheet_key = p_sheet_key for update;
  if not found then
    if not p_create then return null; end if;
    insert into public.route_drafts(client_sheet_key, owner_id) values (p_sheet_key, auth.uid())
    on conflict (client_sheet_key) do nothing returning * into d;
    if d.id is null then select * into d from public.route_drafts where client_sheet_key = p_sheet_key for update; end if;
  end if;
  if d.owner_id <> auth.uid() and not public.auth_has_perm('routes.manage_all_drafts') then
    raise exception 'FORBIDDEN_DRAFT: el borrador pertenece a otro operador' using errcode = '42501';
  end if;
  if p_need_draft and d.status <> 'BORRADOR' then raise exception 'DRAFT_PUBLISHED: la hoja ya fue publicada; no se modifica como borrador' using errcode = '23514'; end if;
  return d;
end; $$;
revoke execute on function public._draft(text, boolean, boolean) from public, anon, authenticated;

create or replace function public.reserve_orders(p_sheet_key text, p_orders text[])
returns void language plpgsql security definer set search_path = public as $$
declare msg text;
begin
  if not public.auth_has_perm('routes.create') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  perform public._draft(p_sheet_key, true);
  insert into public.order_reservations(order_id, sheet_key, reserved_by)
  select distinct o, p_sheet_key, auth.uid() from unnest(p_orders) o where coalesce(o, '') <> ''
  on conflict (order_id) do nothing;
  select string_agg(r.order_id || ' (' || coalesce('hoja ' || rt.number, 'otra hoja borrador' || coalesce(' de ' || p.full_name, '')) || ')', ', ') into msg
    from public.order_reservations r left join public.routes rt on rt.id = r.route_id left join public.profiles p on p.id = r.reserved_by
   where r.order_id = any(p_orders) and r.sheet_key <> p_sheet_key;
  if msg is not null then raise exception 'PEDIDO_YA_EN_OTRA_HOJA: %', msg using errcode = '23505'; end if;
end; $$;

create or replace function public.release_orders(p_sheet_key text, p_orders text[])
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.auth_has_perm('routes.create') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if public._draft(p_sheet_key, false) is null then return 0; end if;   -- también rechaza borrador ajeno o publicado
  delete from public.order_reservations where sheet_key = p_sheet_key and status = 'BORRADOR' and (p_orders is null or order_id = any(p_orders));
  get diagnostics n = row_count; return n;
end; $$;

-- confirm / invalidate: mismas reglas de 2A.1 + dueño del borrador
create or replace function public.confirm_shipping_amount(p jsonb)
returns public.shipping_amount_confirmations language plpgsql security definer set search_path = public as $$
declare cur public.shipping_amount_confirmations; det numeric := (p->>'detected_amount')::numeric; amt numeric := (p->>'confirmed_amount')::numeric;
        changed boolean; res public.shipping_amount_confirmations;
begin
  if not public.auth_has_perm('routes.create') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  perform public._draft(p->>'sheet_key', true);
  if amt is null or amt <= 0 or det is null or det <= 0 then raise exception 'BAD_AMOUNT' using errcode = '22023'; end if;
  changed := abs(amt - det) > 0.004;
  if changed and coalesce(trim(p->>'reason'), '') = '' then raise exception 'REASON_REQUIRED: para cambiar el importe hay que indicar el motivo' using errcode = '23514'; end if;
  select * into cur from public.shipping_amount_confirmations where sheet_key = p->>'sheet_key' and ship_order = p->>'ship_order' and status <> 'INVALIDATED' for update;
  if found and cur.fingerprint = p->>'fingerprint' and cur.confirmed_amount = amt and cur.status in ('CONFIRMED','MODIFIED_CONFIRMED') then return cur; end if;
  if found then update public.shipping_amount_confirmations set status = 'INVALIDATED' where id = cur.id; end if;
  insert into public.shipping_amount_confirmations(sheet_key, route_id, route_version, ship_order, ship_doc, main_order, carrier_id, source_import_id, fingerprint,
    detected_amount, confirmed_amount, status, confirmed_by, confirmed_at, reason, note)
  values (p->>'sheet_key', nullif(p->>'route_id','')::uuid, nullif(p->>'route_version','')::int, p->>'ship_order', p->>'ship_doc', p->>'main_order', p->>'carrier_id',
    p->>'source_import_id', p->>'fingerprint', det, amt, case when changed then 'MODIFIED_CONFIRMED' else 'CONFIRMED' end, auth.uid(), now(),
    case when changed then p->>'reason' end, p->>'note')
  returning * into res;
  insert into public.audit_log(actor_id, action, target_type, target_id, before, after)
  values (auth.uid(), case when changed then 'SHIPPING_AMOUNT_MODIFIED' else 'SHIPPING_AMOUNT_CONFIRMED' end, 'shipping', res.id::text,
    jsonb_build_object('amount', det), jsonb_build_object('amount', amt, 'reason', p->>'reason', 'ship_order', p->>'ship_order'));
  return res;
end; $$;

create or replace function public.invalidate_shipping_confirmation(p_sheet_key text, p_ship_order text, p_fingerprint text)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.auth_has_perm('routes.create') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if public._draft(p_sheet_key, false) is null then return 0; end if;
  update public.shipping_amount_confirmations set status = 'INVALIDATED'
   where sheet_key = p_sheet_key and ship_order = p_ship_order and status <> 'INVALIDATED' and fingerprint <> p_fingerprint;
  get diagnostics n = row_count; return n;
end; $$;

create or replace function public.publish_route(p jsonb)
returns public.routes language plpgsql security definer set search_path = public as $$
declare r public.routes; d public.route_drafts; resp uuid := (p->>'responsable_id')::uuid; car text := p->>'carrier_id'; s jsonb; i int := 0; ships text[]; ords text[];
begin
  if not public.auth_has_perm('routes.publish') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  d := public._draft(p->>'sheet_key', true, false);                   -- dueño (o permiso global) aunque ya esté publicada
  if d.status = 'PUBLICADA' then select * into r from public.routes where id = d.route_id; return r; end if;   -- reintento
  if d.status <> 'BORRADOR' then raise exception 'DRAFT_CANCELLED' using errcode = '23514'; end if;
  if car is null or not exists (select 1 from public.carriers where id = car and active) then raise exception 'BAD_CARRIER: elegí el transportista' using errcode = '23514'; end if;
  if resp is null or not public.can_be_responsable(resp, car) then raise exception 'RESPONSABLE_INCOMPATIBLE' using errcode = '23514'; end if;
  if jsonb_array_length(coalesce(p->'stops', '[]')) = 0 then raise exception 'EMPTY_SHEET: la hoja no tiene pedidos' using errcode = '23514'; end if;
  select array_agg(x->>'ship_order') into ships from jsonb_array_elements(p->'stops') x where x->>'ship_fee_status' = 'PROVISIONAL';
  if ships is not null then perform public.assert_sheet_shipping_ready(p->>'sheet_key', ships); end if;
  if exists (select 1 from jsonb_array_elements(p->'stops') x where coalesce((x->>'ready')::boolean, false) = false) then
    raise exception 'NOT_READY: hay pedidos con revisión pendiente o sin monto' using errcode = '23514';
  end if;
  select array_agg(distinct v) into ords from jsonb_array_elements(p->'stops') x, jsonb_array_elements_text(x->'order_numbers') v;
  perform public.reserve_orders(p->>'sheet_key', ords);
  insert into public.routes(number, carrier_id, responsable_id, status, operational_status, created_by, sheet_key, published_at, published_by, sheet_snapshot)
  values (public.next_route_number_for(car), car, resp, 'PUBLICADA', 'PUBLICADA', auth.uid(), p->>'sheet_key', now(), auth.uid(), p)
  returning * into r;
  update public.order_reservations set status = 'PUBLICADA', route_id = r.id where sheet_key = p->>'sheet_key';
  update public.route_drafts set status = 'PUBLICADA', route_id = r.id, updated_at = now() where id = d.id;
  for s in select * from jsonb_array_elements(p->'stops') loop
    i := i + 1;
    insert into public.route_stops(route_id, seq, sequence_number, provenance, client_name, client_key, zone, order_numbers, merchandise_amount, shipping_fee, shipping_fee_source, bultos, address, action)
    values (r.id, i, i, 'PUBLISHED', s->>'client_name', s->>'client_key', nullif(s->>'zone',''), coalesce((select array_agg(v) from jsonb_array_elements_text(s->'order_numbers') v), '{}'),
            coalesce((s->>'merchandise_amount')::numeric, 0), coalesce((s->>'shipping_fee')::numeric, 0),
            case when s->>'ship_fee_status' = 'PROVISIONAL' then 'CONFIRMED_FALLBACK' else 'SALDO' end, nullif(s->>'bultos','')::int, s->>'address', coalesce(s->>'action', 'ENTREGA'));
  end loop;
  insert into public.notifications(user_id, route_id, route_version, type, title, body)
  values (resp, r.id, 1, 'NUEVA_HOJA_PUBLICADA', 'NUEVA HOJA PUBLICADA', 'Hoja ' || r.number || ' · ' || i || ' entregas')
  on conflict do nothing;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'ROUTE_PUBLISHED', 'route', r.id::text, jsonb_build_object('number', r.number, 'carrier', car, 'responsable', resp, 'stops', i));
  return r;
end; $$;

-- =====================================================================
-- 2. PASSKEYS (WebAuthn). Solo clave pública + contador: nunca biometría.
-- =====================================================================
create table if not exists public.user_passkeys (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  credential_id text not null unique, public_key text not null, sign_count bigint not null default 0,
  device_name text, transports text[], created_at timestamptz not null default now(), last_used_at timestamptz, revoked_at timestamptz
);
create table if not exists public.webauthn_challenges (
  id uuid primary key default gen_random_uuid(), user_id uuid, challenge text not null unique, kind text not null check (kind in ('REGISTER','LOGIN')),
  created_at timestamptz not null default now(), used_at timestamptz
);
alter table public.user_passkeys enable row level security;
alter table public.webauthn_challenges enable row level security;
create policy passkeys_own on public.user_passkeys for select to authenticated using (user_id = auth.uid() or public.auth_has_perm('users.manage'));
grant select (id, user_id, device_name, created_at, last_used_at, revoked_at) on public.user_passkeys to authenticated;
create or replace function public.revoke_passkey(p_id uuid) returns void language plpgsql security definer set search_path = public as $$
begin
  update public.user_passkeys set revoked_at = coalesce(revoked_at, now()) where id = p_id and (user_id = auth.uid() or public.auth_has_perm('users.manage'));
  if not found then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  insert into public.audit_log(actor_id, action, target_type, target_id) values (auth.uid(), 'PASSKEY_REVOKED', 'passkey', p_id::text);
end; $$;
grant execute on function public.revoke_passkey(uuid) to authenticated;

-- =====================================================================
-- 3. RUTA INTERNA DINÁMICA
-- =====================================================================
alter table public.route_stops add column if not exists sequence_number int;
alter table public.route_stops add column if not exists provenance text not null default 'PUBLISHED' check (provenance in ('PUBLISHED','DRIVER'));
alter table public.route_stops add column if not exists action text not null default 'ENTREGA';
alter table public.route_stops add column if not exists added_by uuid;
alter table public.route_stops add column if not exists added_at timestamptz;
update public.route_stops set sequence_number = seq where sequence_number is null;
alter table public.route_change_events add column if not exists client_op_id text unique;
alter table public.route_change_events add column if not exists offline boolean not null default false;

-- Parada "actual" = la primera pendiente según el orden vigente; las anteriores y completadas quedan fijas.
create or replace function public.add_internal_stop(p_route uuid, p_stop jsonb, p_version int, p_op_id text, p_offline boolean default false)
returns public.routes language plpgsql security definer set search_path = public as $$
declare r public.routes; nid uuid; nseq int;
begin
  r := public._my_route(p_route);
  if exists (select 1 from public.route_change_events where client_op_id = p_op_id) then return r; end if;   -- reintento offline
  if not exists (select 1 from public.carriers c where c.id = r.carrier_id and c.kind = 'INTERNO') then raise exception 'NOT_INTERNAL' using errcode = '23514'; end if;
  if r.operational_status <> 'EN_CURSO' then raise exception 'BAD_STATE' using errcode = '23514'; end if;
  if p_version <> r.version then raise exception 'VERSION_CONFLICT: la hoja cambió (versión %)', r.version using errcode = '40001'; end if;
  if coalesce(trim(p_stop->>'client_name'), '') = '' then raise exception 'NAME_REQUIRED' using errcode = '23514'; end if;
  select coalesce(max(seq), 0) + 1 into nseq from public.route_stops where route_id = p_route;
  -- el celular puede enviar el id (UUID) de la parada nueva: así un reordenamiento hecho offline ya la referencia
  insert into public.route_stops(id, route_id, seq, sequence_number, provenance, client_name, address, action, bultos, added_by, added_at)
  values (coalesce(nullif(p_stop->>'id', '')::uuid, gen_random_uuid()), p_route, nseq, (select coalesce(max(sequence_number), 0) + 1 from public.route_stops where route_id = p_route), 'DRIVER', p_stop->>'client_name', p_stop->>'address',
          coalesce(nullif(p_stop->>'action', ''), 'ENTREGA'), nullif(p_stop->>'bultos', '')::int, auth.uid(), now())
  returning id into nid;
  update public.routes set version = version + 1, has_driver_modifications = true, modification_count = modification_count + 1 where id = p_route returning * into r;
  insert into public.route_change_events(route_id, route_version, stop_id, event_type, after, user_id, client_op_id, offline)
  values (p_route, r.version, nid::text, 'INTERNAL_STOP_ADDED', p_stop, auth.uid(), p_op_id, p_offline);
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'INTERNAL_STOP_ADDED', 'route', p_route::text, p_stop);
  return r;
end; $$;

create or replace function public.reorder_internal_stops(p_route uuid, p_order uuid[], p_version int, p_op_id text, p_offline boolean default false)
returns public.routes language plpgsql security definer set search_path = public as $$
declare r public.routes; fixed int; cur uuid; future uuid[]; before jsonb; i int;
begin
  r := public._my_route(p_route);
  if exists (select 1 from public.route_change_events where client_op_id = p_op_id) then return r; end if;
  if not exists (select 1 from public.carriers c where c.id = r.carrier_id and c.kind = 'INTERNO') then raise exception 'NOT_INTERNAL' using errcode = '23514'; end if;
  if r.operational_status <> 'EN_CURSO' then raise exception 'BAD_STATE' using errcode = '23514'; end if;
  if p_version <> r.version then raise exception 'VERSION_CONFLICT: la hoja cambió (versión %)', r.version using errcode = '40001'; end if;
  select id into cur from public.route_stops where route_id = p_route and outcome = 'PENDIENTE' order by sequence_number limit 1;
  select array_agg(id order by sequence_number) into future from public.route_stops where route_id = p_route and outcome = 'PENDIENTE' and id <> cur;
  -- solo se pueden ordenar las paradas futuras (pendientes, sin la actual), y todas ellas
  if p_order is null or cur = any(p_order) then raise exception 'CURRENT_STOP_FIXED: la parada actual no se mueve' using errcode = '23514'; end if;
  if exists (select 1 from public.route_stops where route_id = p_route and id = any(p_order) and outcome <> 'PENDIENTE') then raise exception 'COMPLETED_STOP_FIXED: una parada resuelta no se mueve' using errcode = '23514'; end if;
  if (select array_agg(x order by x) from unnest(p_order) x) is distinct from (select array_agg(x order by x) from unnest(future) x) then raise exception 'BAD_ORDER: hay que enviar todas las paradas futuras' using errcode = '22023'; end if;
  select jsonb_agg(id order by sequence_number) into before from public.route_stops where route_id = p_route and id = any(future);
  select coalesce(max(sequence_number), 0) into fixed from public.route_stops where route_id = p_route and (outcome <> 'PENDIENTE' or id = cur);
  for i in 1..array_length(p_order, 1) loop
    update public.route_stops set sequence_number = fixed + i where id = p_order[i];
  end loop;
  update public.routes set version = version + 1, has_driver_modifications = true, modification_count = modification_count + 1 where id = p_route returning * into r;
  insert into public.route_change_events(route_id, route_version, event_type, before, after, user_id, client_op_id, offline)
  values (p_route, r.version, 'INTERNAL_STOP_REORDERED', before, to_jsonb(p_order), auth.uid(), p_op_id, p_offline);
  insert into public.audit_log(actor_id, action, target_type, target_id, before, after) values (auth.uid(), 'INTERNAL_STOP_REORDERED', 'route', p_route::text, before, to_jsonb(p_order));
  return r;
end; $$;
grant execute on function public.add_internal_stop(uuid, jsonb, int, text, boolean), public.reorder_internal_stops(uuid, uuid[], int, text, boolean) to authenticated, service_role;

-- =====================================================================
-- 4. APROBACIÓN + EMAILS
-- =====================================================================
create table if not exists public.internal_route_notification_settings (
  id text primary key default 'DEFAULT', supervisor_user_id uuid references public.profiles(id),
  copy_admin boolean not null default true, extra_emails text[] not null default '{}',
  email_enabled boolean not null default true, push_enabled boolean not null default false
);
insert into public.internal_route_notification_settings(id) values ('DEFAULT') on conflict do nothing;
alter table public.internal_route_notification_settings enable row level security;
create policy irns_read on public.internal_route_notification_settings for select to authenticated using (public.auth_has_perm('settings.manage'));
grant select on public.internal_route_notification_settings to authenticated;

create table if not exists public.approval_email_jobs (
  id uuid primary key default gen_random_uuid(),
  route_id uuid not null references public.routes(id), route_version int not null,
  kind text not null check (kind in ('INTERNAL_ROUTE_APPROVAL_REQUEST','INTERNAL_ROUTE_OBSERVED')),
  recipient text not null,
  idempotency_key text not null unique,   -- route_id|version|kind|recipient
  status text not null default 'QUEUED' check (status in ('QUEUED','SENT','ERROR')),
  queued_at timestamptz not null default now(), sent_at timestamptz, provider_id text, error text, retry_count int not null default 0
);
alter table public.approval_email_jobs enable row level security;
create policy aej_read on public.approval_email_jobs for select to authenticated using (public.auth_has_perm('can_approve_internal_route_changes') or public.auth_has_perm('settings.manage'));
grant select on public.approval_email_jobs to authenticated;

-- Destinatarios: superior del chofer (o el configurado) + Administración (si se copia) + adicionales, sin duplicados
create or replace function public.queue_route_emails(p_route uuid, p_version int, p_kind text, p_driver_email text default null)
returns int language plpgsql security definer set search_path = public as $$
declare st public.internal_route_notification_settings; r public.routes; sup uuid; n int;
begin
  select * into st from public.internal_route_notification_settings where id = 'DEFAULT';
  if not coalesce(st.email_enabled, true) then return 0; end if;
  select * into r from public.routes where id = p_route;
  select coalesce(p.supervisor_user_id, st.supervisor_user_id) into sup from public.profiles p where p.id = r.responsable_id;
  insert into public.approval_email_jobs(route_id, route_version, kind, recipient, idempotency_key)
  select p_route, p_version, p_kind, e, p_route || '|' || p_version || '|' || p_kind || '|' || e
  from (select distinct lower(trim(x)) e from (
          select email x from public.profiles where p_kind = 'INTERNAL_ROUTE_APPROVAL_REQUEST' and id = sup and status = 'ACTIVO'
          union all select email from public.profiles where p_kind = 'INTERNAL_ROUTE_APPROVAL_REQUEST' and coalesce(st.copy_admin, true) and role = 'ADMIN' and status = 'ACTIVO'
          union all select unnest(st.extra_emails) where p_kind = 'INTERNAL_ROUTE_APPROVAL_REQUEST'
          union all select p_driver_email where p_kind = 'INTERNAL_ROUTE_OBSERVED') y where coalesce(trim(x), '') <> '') z
  on conflict (idempotency_key) do nothing;
  get diagnostics n = row_count; return n;
end; $$;
revoke execute on function public.queue_route_emails(uuid, int, text, text) from public, anon, authenticated;

-- Finalizar: interna con cambios → COMPLETADA · PENDIENTE DE APROBACIÓN (una sola solicitud, avisos y emails en cola)
create or replace function public.finalize_route(p_route uuid) returns public.routes language plpgsql security definer set search_path = public as $$
declare r public.routes; pend int; summ jsonb; mods int; sup uuid; st public.internal_route_notification_settings;
begin
  r := public._my_route(p_route);
  if r.operational_status = 'COMPLETADA' then return r; end if;
  if r.operational_status <> 'EN_CURSO' then raise exception 'BAD_STATE' using errcode = '23514'; end if;
  select count(*) filter (where outcome = 'PENDIENTE') into pend from public.route_stops where route_id = p_route;
  if pend > 0 then raise exception 'PENDING_STOPS: faltan % entregas por resolver', pend using errcode = '23514'; end if;
  select jsonb_object_agg(outcome, n) into summ from (select outcome, count(*) n from public.route_stops where route_id = p_route group by outcome) x;
  select count(*) into mods from public.route_change_events where route_id = p_route and event_type in ('INTERNAL_STOP_ADDED','INTERNAL_STOP_REORDERED');
  update public.routes set operational_status = 'COMPLETADA', status = 'COMPLETADA', completed_at = now(), completed_by = auth.uid(), final_summary = summ,
         approval_status = case when mods > 0 then 'PENDIENTE' else 'NO_REQUERIDA' end where id = p_route returning * into r;
  if mods > 0 then
    select * into st from public.internal_route_notification_settings where id = 'DEFAULT';
    select coalesce(p.supervisor_user_id, st.supervisor_user_id) into sup from public.profiles p where p.id = r.responsable_id;
    if sup is not null and not public.user_has_perm(sup, 'can_approve_internal_route_changes') then sup := null; end if;
    insert into public.route_approval_requests(route_id, route_version, requested_by, supervisor_user_id, supervisor_missing, modification_count)
    values (p_route, r.version, auth.uid(), sup, sup is null, mods) on conflict (route_id, route_version) do nothing;
    insert into public.notifications(user_id, route_id, route_version, type, title, body)
    select u, p_route, r.version, case when sup is null then 'INTERNAL_ROUTE_NO_SUPERVISOR' else 'INTERNAL_ROUTE_APPROVAL_REQUEST' end,
           'HOJA ' || r.number || ' PENDIENTE DE APROBACIÓN', mods || ' cambio(s) del chofer' || case when sup is null then ' · sin superior configurado' else '' end
    from (select sup u where sup is not null union select id from public.profiles where sup is null and role = 'ADMIN' and status = 'ACTIVO') x
    on conflict do nothing;
    perform public.queue_route_emails(p_route, r.version, 'INTERNAL_ROUTE_APPROVAL_REQUEST');
  end if;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'ROUTE_FINALIZED', 'route', p_route::text, summ || jsonb_build_object('modifications', mods));
  return r;
end; $$;

-- Revisión: aprobar u observar (motivo obligatorio). Observar avisa al chofer (in-app + email en cola). No vuelve a EN CURSO.
create or replace function public.review_route_approval(p_request uuid, p_decision text, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare q public.route_approval_requests; r public.routes; drv_email text;
begin
  if not public.auth_has_perm('can_approve_internal_route_changes') then raise exception 'FORBIDDEN: falta permiso can_approve_internal_route_changes' using errcode = '42501'; end if;
  select * into q from public.route_approval_requests where id = p_request for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  if q.status <> 'PENDING' then raise exception 'NOT_PENDING: la solicitud ya fue resuelta' using errcode = '23514'; end if;
  if q.supervisor_user_id is not null and q.supervisor_user_id <> auth.uid() and not public.auth_has_perm('users.manage') then
    raise exception 'FORBIDDEN: la revisa el superior asignado o Administración' using errcode = '42501';
  end if;
  if p_decision not in ('APPROVED','OBSERVED') then raise exception 'BAD_DECISION' using errcode = '22023'; end if;
  if p_decision = 'OBSERVED' and coalesce(trim(p_note), '') = '' then raise exception 'NOTE_REQUIRED: para solicitar aclaración hay que indicar el motivo' using errcode = '23514'; end if;
  update public.route_approval_requests set status = p_decision, reviewed_by = auth.uid(), reviewed_at = now(), review_note = p_note, updated_at = now() where id = p_request;
  update public.routes set approval_status = case p_decision when 'APPROVED' then 'APROBADA' else 'OBSERVADA' end where id = q.route_id returning * into r;
  insert into public.audit_log(actor_id, action, target_type, target_id, before, after)
  values (auth.uid(), case p_decision when 'APPROVED' then 'INTERNAL_ROUTE_APPROVED' else 'INTERNAL_ROUTE_OBSERVED' end, 'route', q.route_id::text,
          jsonb_build_object('status', q.status), jsonb_build_object('status', p_decision, 'note', p_note));
  if p_decision = 'OBSERVED' then
    insert into public.notifications(user_id, route_id, route_version, type, title, body)
    values (r.responsable_id, r.id, q.route_version, 'INTERNAL_ROUTE_OBSERVED', 'ACLARACIÓN SOLICITADA · HOJA ' || r.number, p_note) on conflict do nothing;
    select email into drv_email from public.profiles where id = r.responsable_id;
    perform public.queue_route_emails(r.id, q.route_version, 'INTERNAL_ROUTE_OBSERVED', drv_email);
  end if;
end; $$;
