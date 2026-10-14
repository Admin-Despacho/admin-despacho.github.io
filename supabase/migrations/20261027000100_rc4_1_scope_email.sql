-- OK DESPACHO ONLINE — RC4.1 (0.8.1-rc4.1, incremental, forward-only): alcance REAL de hojas (propias / equipo / todas)
-- y email del receptor + Recibido Conforme sobre el perfil de identidad existente. No borra datos.

-- =====================================================================
-- A · Alcance de hojas: routes.view_all / routes.view_team / routes.view_own aplicados en RLS (no solo en la pantalla)
-- =====================================================================
-- Una hoja "pertenece" a quien la publicó y a quien preparó su borrador (el Operario arma, el Superior publica)
create or replace function public._route_belongs_to(p_route uuid, p_published_by uuid, p_user uuid) returns boolean language sql stable security definer set search_path = public as $$
  select p_published_by = p_user or exists (select 1 from public.route_drafts d where d.route_id = p_route and d.owner_id = p_user);
$$;
create or replace function public.can_view_route_row(p_route uuid, p_published_by uuid, p_responsable uuid) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(
       public.auth_has_perm('routes.view_all')
    or (p_responsable = auth.uid() and public.auth_has_perm('routes.view_assigned'))                                   -- transportistas: igual que antes
    or ((public.auth_has_perm('routes.view_own') or public.auth_has_perm('routes.view_team')) and public._route_belongs_to(p_route, p_published_by, auth.uid()))
    or (public.auth_has_perm('routes.view_team') and exists (select 1 from public.team_of(auth.uid()) t where public._route_belongs_to(p_route, p_published_by, t)))
  , false);
$$;
create or replace function public.can_view_route(p_route uuid) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select public.can_view_route_row(r.id, r.published_by, r.responsable_id) from public.routes r where r.id = p_route), false);
$$;
revoke execute on function public._route_belongs_to(uuid, uuid, uuid) from public, anon;
grant execute on function public.can_view_route_row(uuid, uuid, uuid), public.can_view_route(uuid) to authenticated;

drop policy if exists routes_read on public.routes;
create policy routes_read on public.routes for select to authenticated using (public.can_view_route_row(id, published_by, responsable_id));
drop policy if exists route_stops_read on public.route_stops;
create policy route_stops_read on public.route_stops for select to authenticated using (public.can_view_route(route_id));
drop policy if exists route_pdfs_read on public.route_pdfs;
create policy route_pdfs_read on public.route_pdfs for select to authenticated using (public.can_view_route(route_id));
drop policy if exists route_pdfs_read on storage.objects;
create policy route_pdfs_read on storage.objects for select to authenticated
  using (bucket_id = 'route-pdfs' and public.can_view_route(nullif(split_part(name, '/', 1), '')::uuid));
drop policy if exists route_change_events_read on public.route_change_events;
create policy route_change_events_read on public.route_change_events for select to authenticated
  using (public.can_view_route(route_id) or public.auth_has_perm('can_approve_internal_route_changes'));
drop policy if exists rrr_read on public.route_return_requests;
create policy rrr_read on public.route_return_requests for select to authenticated using (requested_by = auth.uid() or public.can_view_route(route_id));
drop policy if exists cej_read on public.customer_email_jobs;
create policy cej_read on public.customer_email_jobs for select to authenticated using (public.auth_has_perm('settings.manage') or public.can_view_route(route_id));
drop policy if exists fin_snap_read on public.route_financing_snapshots;
drop policy if exists route_financing_snapshots_read2 on public.route_financing_snapshots;
create policy fin_snap_read on public.route_financing_snapshots for select to authenticated using (public.can_view_route(route_id));
drop policy if exists evidence_read on public.stop_evidence;
create policy evidence_read on public.stop_evidence for select to authenticated
  using (public.auth_has_perm('signatures.view') and public.can_view_route((select s.route_id from public.route_stops s where s.id = stop_id)));
-- Las RPC que reciben una hoja por ID respetan el mismo alcance (acceso directo por ID fuera de alcance → FORBIDDEN_ROUTE)
-- cancel_route (versión vigente: 20261026000100_rc4_roles_jerarquia_permisos.sql) + control de alcance
create or replace function public.cancel_route(p_route uuid, p_reason text) returns public.routes language plpgsql security definer set search_path = public as $$
declare r public.routes; a record;
begin
  -- RC4.1: alcance real (propias / equipo / todas). Llamadas técnicas del servidor (service_role) no se filtran.
  if coalesce(auth.role(), '') <> 'service_role' and not public.can_view_route(p_route) then raise exception 'FORBIDDEN_ROUTE: la hoja está fuera de tu alcance' using errcode = '42501'; end if;
  if not (public.auth_has_perm('routes.manage_all_drafts') or public.auth_has_perm('routes.cancel')) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'REASON_REQUIRED' using errcode = '23514'; end if;
  update public.routes set operational_status = 'CANCELADA', status = 'CANCELADA' where id = p_route and operational_status in ('PUBLICADA','EN_CURSO') returning * into r;
  if not found then raise exception 'BAD_STATE: solo hojas publicadas o en curso' using errcode = '23514'; end if;
  update public.route_drafts set status = 'CANCELADA', updated_at = now() where route_id = p_route;
  delete from public.order_reservations where route_id = p_route;   -- la hoja cancelada ya no retiene los pedidos
  insert into public.notifications(user_id, route_id, route_version, type, title, body) values (r.responsable_id, r.id, r.version, 'ROUTE_CANCELLED', 'HOJA ' || r.number || ' CANCELADA', p_reason) on conflict do nothing;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'ROUTE_CANCELLED', 'route', p_route::text, jsonb_build_object('reason', p_reason, 'number', r.number));
  -- RC3: cancelar ≠ revertir NOC. consumed_amount y saldo quedan IGUALES; la aplicación queda pendiente de conciliación administrativa.
  for a in select * from public.credit_note_applications where route_id = p_route and status = 'CONSUMED' for update loop
    update public.credit_note_applications set reconciliation_status = 'CANCELLED_ROUTE_REVIEW', cancelled_route_id = p_route, cancelled_by = auth.uid(), cancelled_at = now(),
      cancel_reason = p_reason, resolution = null where id = a.id;
    perform public._noc_event(a.fingerprint, 'HOJA_CANCELADA_REVISION', a.amount, a.sheet_key, p_route, a.destination, 'hoja ' || r.number,
      jsonb_build_object('reason', p_reason, 'order_numbers', a.order_numbers, 'application', a.id));
    perform public._noc_recon_aggregate(a.fingerprint);
    update public.credit_notes set recon_version = recon_version + 1 where fingerprint = a.fingerprint;
  end loop;
  return r;
end; $$;
-- resend_route_notification (versión vigente: 20261019000100_rc2_cierre_funcional.sql) + control de alcance
create or replace function public.resend_route_notification(p_route uuid) returns void language plpgsql security definer set search_path = public as $$
declare r public.routes;
begin
  -- RC4.1: alcance real (propias / equipo / todas). Llamadas técnicas del servidor (service_role) no se filtran.
  if coalesce(auth.role(), '') <> 'service_role' and not public.can_view_route(p_route) then raise exception 'FORBIDDEN_ROUTE: la hoja está fuera de tu alcance' using errcode = '42501'; end if;
  if not public.auth_has_perm('routes.publish') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into r from public.routes where id = p_route and operational_status in ('PUBLICADA','EN_CURSO');
  if not found then raise exception 'BAD_STATE: solo hojas publicadas o en curso' using errcode = '23514'; end if;
  insert into public.notifications(user_id, route_id, route_version, type, title, body) values (r.responsable_id, r.id, r.version, 'RECORDATORIO_HOJA', 'HOJA ' || r.number || ' PUBLICADA', 'Recordatorio de Despacho')
  on conflict (user_id, route_id, route_version, type) do update set created_at = now(), read_at = null, delivered_at = null;
  insert into public.audit_log(actor_id, action, target_type, target_id) values (auth.uid(), 'ROUTE_NOTIFICATION_RESENT', 'route', p_route::text);
end; $$;
-- register_route_pdf (versión vigente: 20261018000100_rc1_2_pdf_publicacion.sql) + control de alcance
create or replace function public.register_route_pdf(p_route uuid, p_version int, p_path text, p_error text) returns public.route_pdfs language plpgsql security definer set search_path = public, storage as $$
declare r public.routes; x public.route_pdfs; fname text;
begin
  -- RC4.1: alcance real (propias / equipo / todas). Llamadas técnicas del servidor (service_role) no se filtran.
  if coalesce(auth.role(), '') <> 'service_role' and not public.can_view_route(p_route) then raise exception 'FORBIDDEN_ROUTE: la hoja está fuera de tu alcance' using errcode = '42501'; end if;
  if not public.auth_has_perm('routes.publish') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into r from public.routes where id = p_route;
  if not found or r.operational_status = 'BORRADOR' then raise exception 'NOT_PUBLISHED: solo hojas publicadas' using errcode = '23514'; end if;
  fname := 'Hoja_' || r.number || '_v' || p_version || '.pdf';
  if p_path is not null then
    if p_path <> p_route || '/v' || p_version || '/' || fname then raise exception 'BAD_PATH' using errcode = '23514'; end if;
    if not exists (select 1 from storage.objects o where o.bucket_id = 'route-pdfs' and o.name = p_path) then raise exception 'NOT_UPLOADED' using errcode = '23514'; end if;
  end if;
  insert into public.route_pdfs(route_id, route_version, route_number, file_name, storage_path, status, error, attempts, generated_at, generated_by)
  values (p_route, p_version, r.number, fname, p_path, case when p_path is not null then 'OK' else 'PDF_ERROR' end, p_error, 1, case when p_path is not null then now() end, auth.uid())
  on conflict (route_id, route_version) do update set
    storage_path = case when route_pdfs.status = 'OK' then route_pdfs.storage_path else excluded.storage_path end,
    status = case when route_pdfs.status = 'OK' then 'OK' else excluded.status end,
    error = case when route_pdfs.status = 'OK' then null else excluded.error end,
    generated_at = case when route_pdfs.status = 'OK' then route_pdfs.generated_at else excluded.generated_at end,
    generated_by = case when route_pdfs.status = 'OK' then route_pdfs.generated_by else excluded.generated_by end,
    attempts = route_pdfs.attempts + 1
  returning * into x;
  return x;
end; $$;
-- route_pdf_snapshot (versión vigente: 20261018000100_rc1_2_pdf_publicacion.sql) + control de alcance
create or replace function public.route_pdf_snapshot(p_route uuid) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r public.routes;
begin
  -- RC4.1: alcance real (propias / equipo / todas). Llamadas técnicas del servidor (service_role) no se filtran.
  if coalesce(auth.role(), '') <> 'service_role' and not public.can_view_route(p_route) then raise exception 'FORBIDDEN_ROUTE: la hoja está fuera de tu alcance' using errcode = '42501'; end if;
  if not public.auth_has_perm('routes.publish') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into r from public.routes where id = p_route;
  return jsonb_build_object('number', r.number, 'version', r.version, 'pdf_model', r.sheet_snapshot->'pdf_model');
end; $$;
-- route_noc_summary (versión vigente: 20261025000100_rc3_noc_conciliacion.sql) + control de alcance
create or replace function public.route_noc_summary(p_route uuid) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  -- RC4.1: alcance real (propias / equipo / todas). Llamadas técnicas del servidor (service_role) no se filtran.
  if coalesce(auth.role(), '') <> 'service_role' and not public.can_view_route(p_route) then raise exception 'FORBIDDEN_ROUTE: la hoja está fuera de tu alcance' using errcode = '42501'; end if;
  if not (public.auth_has_perm('routes.manage_all_drafts') or public.auth_has_perm('credit_notes.manage')) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return (select jsonb_build_object('count', count(*), 'amount', coalesce(sum(amount), 0)) from public.credit_note_applications where route_id = p_route and status = 'CONSUMED');
end; $$;
-- set_route_vehicle (versión vigente: 20261015000100_fase2b3_cierre_operativo.sql) + control de alcance
create or replace function public.set_route_vehicle(p_route uuid, p_vehicle uuid) returns void language plpgsql security definer set search_path = public as $$
begin
  -- RC4.1: alcance real (propias / equipo / todas). Llamadas técnicas del servidor (service_role) no se filtran.
  if coalesce(auth.role(), '') <> 'service_role' and not public.can_view_route(p_route) then raise exception 'FORBIDDEN_ROUTE: la hoja está fuera de tu alcance' using errcode = '42501'; end if;
  if not public.auth_has_perm('routes.publish') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if not exists (select 1 from public.routes r join public.carriers c on c.id = r.carrier_id where r.id = p_route and c.kind = 'INTERNO' and r.operational_status in ('PUBLICADA','EN_CURSO')) then raise exception 'NOT_INTERNAL_ACTIVE' using errcode = '23514'; end if;
  update public.routes set vehicle_id = p_vehicle, km_start = (select current_km from public.vehicles where id = p_vehicle and active) where id = p_route;
  if not found or (select km_start from public.routes where id = p_route) is null then raise exception 'BAD_VEHICLE: vehículo inexistente o inactivo' using errcode = '23514'; end if;
end; $$;
-- queue_route_emails (versión vigente: 20261014000100_fase2b2_seguridad_ruta_interna_aprobacion.sql) + control de alcance
create or replace function public.queue_route_emails(p_route uuid, p_version int, p_kind text, p_driver_email text default null)
returns int language plpgsql security definer set search_path = public as $$
declare st public.internal_route_notification_settings; r public.routes; sup uuid; n int;
begin
  -- RC4.1: alcance real (propias / equipo / todas). Llamadas técnicas del servidor (service_role) no se filtran.
  if coalesce(auth.role(), '') <> 'service_role' and not public.can_view_route(p_route) then raise exception 'FORBIDDEN_ROUTE: la hoja está fuera de tu alcance' using errcode = '42501'; end if;
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
-- request_route_return (versión vigente: 20261015000100_fase2b3_cierre_operativo.sql) + control de alcance
create or replace function public.request_route_return(p_route uuid, p_reason text) returns public.route_return_requests language plpgsql security definer set search_path = public as $$
declare r public.routes; q public.route_return_requests;
begin
  -- RC4.1: alcance real (propias / equipo / todas). Llamadas técnicas del servidor (service_role) no se filtran.
  if coalesce(auth.role(), '') <> 'service_role' and not public.can_view_route(p_route) then raise exception 'FORBIDDEN_ROUTE: la hoja está fuera de tu alcance' using errcode = '42501'; end if;
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
-- Superior Despacho ve SU EQUIPO por defecto; "todas las hojas" solo con permiso individual otorgado por Admin
delete from public.role_permissions where role_code = 'SUPERVISOR_DESPACHO' and permission_code = 'routes.view_all';
insert into public.audit_log(action, target_type, target_id, after) values ('ROLE_SCOPE_RC4_1', 'roles', 'SUPERVISOR_DESPACHO', jsonb_build_object('removed', 'routes.view_all', 'scope', 'routes.view_team'));

-- =====================================================================
-- B · Email del receptor + Recibido Conforme (misma capa de identidad: customer_identity_docs)
-- =====================================================================
create or replace function public.is_valid_email(p text) returns boolean language sql immutable as $$
  select coalesce(p ~* '^[a-z0-9._%%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}$' and length(p) <= 254, false);
$$;
-- Perfil reutilizable: el mismo registro del DNI (por CUIL) suma nombre, DNI, email y el último cliente; la foto sigue siendo opcional
alter table public.customer_identity_docs add column if not exists full_name text;
alter table public.customer_identity_docs add column if not exists dni text check (dni is null or dni ~ '^[0-9]{7,8}$');
alter table public.customer_identity_docs add column if not exists email text;
alter table public.customer_identity_docs add column if not exists email_updated_at timestamptz;
alter table public.customer_identity_docs add column if not exists email_updated_by uuid;
alter table public.customer_identity_docs add column if not exists client_key text;
alter table public.customer_identity_docs add column if not exists updated_at timestamptz;
alter table public.customer_identity_docs drop constraint if exists identity_doc_source;
alter table public.customer_identity_docs add constraint identity_doc_source check (storage_path is not null or dni_photo is not null or email is not null or full_name is not null);
create index if not exists customer_identity_docs_dni on public.customer_identity_docs(dni);
create index if not exists customer_identity_docs_client on public.customer_identity_docs(client_key);
-- Cada entrega conserva el email y DNI realmente usados (no cambian aunque el perfil se actualice)
alter table public.stop_evidence add column if not exists receiver_email text;
alter table public.stop_evidence add column if not exists receiver_dni text;
create or replace function public._upsert_identity_profile(p_cuil text, p_name text, p_dni text, p_email text, p_client text) returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.customer_identity_docs(cuil, full_name, dni, email, email_updated_at, email_updated_by, client_key, registered_by, updated_at)
  values (p_cuil, p_name, p_dni, p_email, case when p_email is not null then now() end, case when p_email is not null then auth.uid() end, p_client, auth.uid(), now())
  on conflict (cuil) do update set full_name = coalesce(excluded.full_name, customer_identity_docs.full_name), dni = coalesce(excluded.dni, customer_identity_docs.dni),
    email = coalesce(excluded.email, customer_identity_docs.email),
    email_updated_at = case when excluded.email is not null and excluded.email is distinct from customer_identity_docs.email then now() else customer_identity_docs.email_updated_at end,
    email_updated_by = case when excluded.email is not null and excluded.email is distinct from customer_identity_docs.email then auth.uid() else customer_identity_docs.email_updated_by end,
    client_key = coalesce(excluded.client_key, customer_identity_docs.client_key), updated_at = now();
end; $$;
revoke execute on function public._upsert_identity_profile(text, text, text, text, text) from public, anon, authenticated;
-- El perfil puede existir sin foto (creado por email/nombre): la foto del DNI se guarda igual y el chofer la sigue viendo como pendiente
create or replace function public.cuil_has_dni(p_cuil text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.customer_identity_docs where cuil = regexp_replace(coalesce(p_cuil,''), '\D', '', 'g') and (storage_path is not null or dni_photo is not null));
$$;
create or replace function public._register_identity(p_cuil text, ev jsonb) returns void language plpgsql security definer set search_path = public as $$
declare chk text; mime text;
begin
  if coalesce(ev->>'dni_photo_b64', '') <> '' then raise exception 'DNI_STORAGE_REQUIRED: la foto del DNI se sube a Storage privado' using errcode = '23514'; end if;
  if coalesce(ev->>'dni_storage_path', '') = '' or exists (select 1 from public.customer_identity_docs d where d.cuil = p_cuil and (d.storage_path is not null or d.dni_photo is not null)) then return; end if;
  chk := public._identity_upload_ok(p_cuil, ev->>'dni_storage_path');
  if chk is not null then raise exception 'DNI_UPLOAD_INVALID: %', chk using errcode = '23514'; end if;
  select metadata->>'mimetype' into mime from storage.objects where bucket_id = 'identity-docs' and name = ev->>'dni_storage_path';
  insert into public.customer_identity_docs(cuil, storage_path, mime, registered_by) values (p_cuil, ev->>'dni_storage_path', mime, auth.uid())
  on conflict (cuil) do update set storage_path = excluded.storage_path, mime = excluded.mime, updated_at = now()
    where customer_identity_docs.storage_path is null and customer_identity_docs.dni_photo is null;   -- nunca pisa una foto ya registrada
end; $$;
revoke execute on function public._register_identity(text, jsonb) from public, anon, authenticated;
-- Autocompletar en la segunda pantalla: solo el chofer de ESA parada (o Admin). Devuelve lo necesario para completar la entrega (nunca la foto del DNI).
-- Orden: CUIL → DNI → identificador interno del cliente (última entrega registrada del mismo cliente)
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
grant execute on function public.delivery_identity_lookup(uuid, text, text), public.is_valid_email(text) to authenticated;

-- Recibido Conforme: un comprobante por parada (idempotente), con instantánea inmutable; el email es un job aparte
create table if not exists public.delivery_receipts (
  id uuid primary key default gen_random_uuid(), stop_id uuid not null unique references public.route_stops(id), route_id uuid not null references public.routes(id),
  receipt_number text not null unique, recipient_email text not null, snapshot jsonb not null, sha256 text not null, generated_by uuid, generated_at timestamptz not null default now());
alter table public.delivery_receipts enable row level security;
create policy delivery_receipts_read on public.delivery_receipts for select to authenticated using (public.auth_has_perm('settings.manage') or (public.auth_has_perm('signatures.view') and public.can_view_route(route_id)));
grant select on public.delivery_receipts to authenticated;
revoke insert, update, delete on public.delivery_receipts from authenticated, anon;
alter table public.customer_email_jobs drop constraint if exists customer_email_jobs_kind_check;
alter table public.customer_email_jobs add constraint customer_email_jobs_kind_check check (kind in ('ON_THE_WAY','DELIVERED','PARTIAL','RECIBIDO_CONFORME'));
alter table public.customer_email_jobs add column if not exists last_attempt_at timestamptz;
alter table public.customer_email_jobs add column if not exists attempts jsonb not null default '[]';
create or replace function public._create_delivery_receipt(st public.route_stops, r public.routes, p_receiver text, p_email text) returns void language plpgsql security definer set search_path = public as $$
declare snap jsonb; num text;
begin
  if exists (select 1 from public.delivery_receipts where stop_id = st.id) then return; end if;   -- nunca dos comprobantes para la misma entrega
  num := 'RC-' || r.number || '-' || lpad(coalesce(st.seq, 0)::text, 3, '0');
  snap := jsonb_build_object('receipt_number', num, 'route_number', r.number, 'client_name', st.client_name, 'order_numbers', st.order_numbers, 'receiver_name', p_receiver,
    'delivered_at', now(), 'carrier_id', r.carrier_id);
  insert into public.delivery_receipts(stop_id, route_id, receipt_number, recipient_email, snapshot, sha256, generated_by)
  values (st.id, r.id, num, p_email, snap, encode(sha256(convert_to(snap::text, 'UTF8')), 'hex'), auth.uid()) on conflict (stop_id) do nothing;
  insert into public.customer_email_jobs(route_id, stop_id, kind, recipient, idempotency_key)
  values (r.id, st.id, 'RECIBIDO_CONFORME', p_email, r.id || '|' || st.id || '|RECIBIDO_CONFORME') on conflict (idempotency_key) do nothing;
end; $$;
revoke execute on function public._create_delivery_receipt(public.route_stops, public.routes, text, text) from public, anon, authenticated;
-- Historial de intentos del email (servidor): cada cambio de estado deja fecha, estado, proveedor y error
create or replace function public.trg_customer_email_attempts() returns trigger language plpgsql as $$
begin
  if new.status is distinct from old.status or new.retry_count is distinct from old.retry_count or new.provider_id is distinct from old.provider_id then
    new.last_attempt_at := now();
    new.attempts := coalesce(old.attempts, '[]'::jsonb) || jsonb_build_array(jsonb_build_object('at', now(), 'status', new.status, 'provider_id', new.provider_id, 'error', new.error, 'retry', new.retry_count));
  end if;
  return new;
end; $$;
drop trigger if exists customer_email_attempts on public.customer_email_jobs;
create trigger customer_email_attempts before update on public.customer_email_jobs for each row execute function public.trg_customer_email_attempts();

-- set_stop_outcome: misma lógica RC1 + email/DNI del receptor, perfil reutilizable y Recibido Conforme
create or replace function public.set_stop_outcome(p_stop uuid, p_outcome text, p_note text, p_reason text, p_op_id text, p_extra jsonb default null)
returns public.route_stops language plpgsql security definer set search_path = public as $$
declare st public.route_stops; r public.routes; cristian boolean; v_cuil text; v_email text; v_dni text; v_receipt boolean := false; ev jsonb := coalesce(p_extra->'evidence', '{}'); col jsonb := p_extra->'collection'; loc jsonb; sig bytea;
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
      perform public._register_identity(v_cuil, ev);   -- RC1: DNI en Storage privado
    else
      v_cuil := nullif(regexp_replace(coalesce(ev->>'cuil', ''), '\D', '', 'g'), '');   -- Transportista Interno: CUIL opcional
      if v_cuil is not null and length(v_cuil) <> 11 then raise exception 'CUIL_INVALID: el CUIL debe tener 11 dígitos' using errcode = '23514'; end if;
    end if;
    -- RC4.1: email del receptor (segunda pantalla). Opcional; si viene, debe ser válido.
    v_email := nullif(lower(trim(coalesce(ev->>'email', ''))), '');
    if v_email is not null and not public.is_valid_email(v_email) then raise exception 'EMAIL_INVALID: el email no es válido' using errcode = '23514'; end if;
    v_dni := nullif(regexp_replace(coalesce(ev->>'dni', ''), '\D', '', 'g'), '');
    if v_dni is null and v_cuil is not null then v_dni := substr(v_cuil, 3, 8); end if;
    if v_dni is not null and length(v_dni) not between 7 and 8 then raise exception 'DNI_INVALID: el DNI debe tener 7 u 8 dígitos' using errcode = '23514'; end if;
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
    -- La entrega guarda el email USADO (inmutable aunque el perfil cambie después)
    insert into public.stop_evidence(stop_id, receiver_name, signature_png, signature_sha256, receiver_cuil, created_by, receiver_email, receiver_dni)
    values (p_stop, trim(ev->>'receiver_name'), sig, encode(sha256(sig), 'hex'), v_cuil, auth.uid(), v_email, v_dni)
    on conflict (stop_id) do nothing;
    -- Perfil reutilizable (misma capa de identidad que el DNI): nombre, DNI y email para próximas entregas
    if v_cuil is not null then perform public._upsert_identity_profile(v_cuil, trim(ev->>'receiver_name'), v_dni, v_email, st.client_key); end if;
    -- Recibido Conforme: entrega TOTAL confirmada + email válido → comprobante único + envío automático (la falla del email nunca revierte la entrega)
    if p_outcome = 'ENTREGADO' and v_email is not null then perform public._create_delivery_receipt(st, r, trim(ev->>'receiver_name'), v_email); v_receipt := true; end if;
    if coalesce(trim(st.customer_email), '') <> '' and not v_receipt then
      insert into public.customer_email_jobs(route_id, stop_id, kind, recipient, idempotency_key)
      values (st.route_id, st.id, case when p_outcome = 'ENTREGADO' then 'DELIVERED' else 'PARTIAL' end, lower(trim(st.customer_email)), st.route_id || '|' || st.id || '|' || case when p_outcome = 'ENTREGADO' then 'DELIVERED' else 'PARTIAL' end)
      on conflict (idempotency_key) do nothing;
    end if;
  end if;
  if p_op_id is not null then insert into public.stop_outcome_ops(op_id, stop_id) values (p_op_id, p_stop); end if;
  perform public._queue_on_the_way(st.route_id);
  return st;
end; $$;