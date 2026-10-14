-- OK DESPACHO ONLINE — RC4 (0.8.0-rc4, incremental, forward-only): roles jerárquicos de Despacho, permisos granulares por usuario,
-- superior asignado, solicitudes operativas sobre el motor de aprobaciones existente, columnas y kilometraje por permiso.
-- Nada se borra. DESPACHO sigue existiendo (compatibilidad); sus usuarios pasan a Superior Despacho conservando lo que hacían.

-- =====================================================================
-- 1 · Roles y permisos
-- =====================================================================
insert into public.roles(code, name) values ('SUPERVISOR_DESPACHO', 'Superior Despacho'), ('OPERARIO_DEPOSITO', 'Operario Depósito') on conflict (code) do update set name = excluded.name;
update public.roles set name = 'Admin General' where code = 'ADMIN';
insert into public.permissions(code) values
 ('vehicle_mileage.view'),('vehicle_mileage.enter'),('vehicle_mileage.edit'),('vehicle_mileage.rules_manage'),('vehicle_mileage.resolve_alerts'),
 ('columns.view'),('columns.manage_defaults'),('columns.manage_templates'),('columns.apply_global'),
 ('routes.edit'),('routes.cancel'),('routes.reassign'),('routes.view_team'),('routes.view_own'),
 ('drafts.create'),('drafts.view_own'),('drafts.view_team'),('drafts.manage_team'),
 ('requests.create'),('requests.view_team'),('requests.approve_team'),('requests.reject_team'),('requests.observe_team'),('requests.reassign'),
 ('users.assign_supervisor'),('users.manage_permissions'),('vehicles.view'),('vehicles.service_manage'),('backup.manage')
on conflict do nothing;
-- ADMIN: todo
insert into public.role_permissions(role_code, permission_code) select 'ADMIN', code from public.permissions on conflict do nothing;
-- Superior Despacho: flujo completo de hoja + equipo + aprobaciones del equipo; sin usuarios, NOC, backup, auditoría ni configuración sensible
insert into public.role_permissions(role_code, permission_code) select 'SUPERVISOR_DESPACHO', x from unnest(array[
 'routes.create','routes.edit','routes.publish','routes.cancel','routes.assign','routes.reassign','routes.view_all','routes.view_team','routes.view_own',
 'internal_routes.manage','locations.view','signatures.view','collections.manage',
 'drafts.create','drafts.view_own','drafts.view_team','drafts.manage_team',
 'requests.create','requests.view_team','requests.approve_team','requests.reject_team','requests.observe_team',
 'columns.view','vehicle_mileage.view','vehicle_mileage.enter','vehicle_mileage.resolve_alerts','vehicles.view']) x on conflict do nothing;
-- Operario Depósito: preparar hojas y trabajar sus borradores; ver columnas y kilometraje; cargar km; pedir autorización
insert into public.role_permissions(role_code, permission_code) select 'OPERARIO_DEPOSITO', x from unnest(array[
 'routes.create','routes.view_own','locations.view','drafts.create','drafts.view_own','requests.create',
 'columns.view','vehicle_mileage.view','vehicle_mileage.enter','vehicles.view']) x on conflict do nothing;
-- DESPACHO (compatibilidad): mismos permisos que tenía + visibilidad de columnas y kilometraje
insert into public.role_permissions(role_code, permission_code) select 'DESPACHO', x from unnest(array['columns.view','vehicle_mileage.view','vehicles.view','drafts.create','drafts.view_own','requests.create']) x on conflict do nothing;
-- Módulos (las restricciones por usuario siguen funcionando igual)
insert into public.module_permissions(module, permission_code) values
 ('DESPACHO','routes.edit'),('DESPACHO','routes.cancel'),('DESPACHO','routes.reassign'),('DESPACHO','routes.view_team'),('DESPACHO','routes.view_own'),
 ('DESPACHO','drafts.create'),('DESPACHO','drafts.view_own'),('DESPACHO','drafts.view_team'),('DESPACHO','drafts.manage_team'),
 ('DESPACHO','columns.view'),('DESPACHO','vehicle_mileage.view'),('DESPACHO','vehicle_mileage.enter'),('DESPACHO','vehicles.view'),
 ('DESPACHO','requests.create'),('APROBACIONES','requests.view_team'),('APROBACIONES','requests.approve_team'),('APROBACIONES','requests.reject_team'),
 ('APROBACIONES','requests.observe_team'),('APROBACIONES','requests.reassign'),
 ('USUARIOS','users.assign_supervisor'),('USUARIOS','users.manage_permissions'),
 ('CONFIGURACION','columns.manage_defaults'),('CONFIGURACION','columns.manage_templates'),('CONFIGURACION','columns.apply_global'),
 ('CONFIGURACION','vehicle_mileage.edit'),('CONFIGURACION','vehicle_mileage.rules_manage'),('CONFIGURACION','vehicle_mileage.resolve_alerts'),
 ('CONFIGURACION','vehicles.service_manage'),('CONFIGURACION','backup.manage')
on conflict do nothing;

-- =====================================================================
-- 2 · Permisos individuales (Admin tilda / destilda por usuario). Efectivo = (rol + otorgados) − quitados − módulos restringidos.
-- =====================================================================
create table if not exists public.user_permission_overrides (
  user_id uuid not null references public.profiles(id), permission_code text not null references public.permissions(code),
  granted boolean not null, set_by uuid, set_at timestamptz not null default now(), reason text, primary key (user_id, permission_code));
alter table public.user_permission_overrides enable row level security;
create policy upo_read on public.user_permission_overrides for select to authenticated using (user_id = auth.uid() or public.auth_has_perm('users.view'));
grant select on public.user_permission_overrides to authenticated;
revoke insert, update, delete on public.user_permission_overrides from authenticated, anon;

create or replace function public.user_has_perm(p_user uuid, p_perm text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles p where p.id = p_user and p.status = 'ACTIVO'
      and ((exists (select 1 from public.role_permissions rp where rp.role_code = p.role and rp.permission_code = p_perm)
            and not exists (select 1 from public.user_permission_overrides o where o.user_id = p.id and o.permission_code = p_perm and not o.granted))
           or exists (select 1 from public.user_permission_overrides o where o.user_id = p.id and o.permission_code = p_perm and o.granted))
      and not exists (select 1 from public.module_permissions mp where mp.permission_code = p_perm and mp.module = any(p.disabled_modules)));
$$;
create or replace function public.auth_has_perm(p_perm text) returns boolean language sql stable security definer set search_path = public as $$
  select public.user_has_perm(auth.uid(), p_perm) and exists (select 1 from public.profiles p where p.id = auth.uid()
      and (p.sessions_revoked_at is null or coalesce((auth.jwt() ->> 'iat')::numeric, 0) > extract(epoch from p.sessions_revoked_at)));
$$;
-- Permisos efectivos de un usuario (para la pantalla; el servidor valida cada acción igual)
create or replace function public.user_effective_permissions(p_user uuid) returns text[] language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(c.code order by c.code), '{}') from public.permissions c
  where (p_user = auth.uid() or public.auth_has_perm('users.view')) and public.user_has_perm(p_user, c.code);
$$;
grant execute on function public.user_effective_permissions(uuid) to authenticated;
-- Sensibles: solo un Admin General puede otorgarlos
create or replace function public.is_sensitive_permission(p text) returns boolean language sql immutable as $$
  select p in ('users.manage','users.manage_permissions','users.assign_supervisor','settings.manage','credit_notes.manage','audit.view','backup.manage',
               'identity_docs.view','can_manage_commercial_transport_reports','routes.manage_all_drafts','columns.apply_global');
$$;
create or replace function public.auth_is_admin() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'ADMIN' and status = 'ACTIVO');
$$;
create or replace function public.set_user_permission(p_user uuid, p_perm text, p_state text, p_reason text default null) returns jsonb language plpgsql security definer set search_path = public as $$
declare prev text;
begin
  if not public.auth_has_perm('users.manage_permissions') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_user = auth.uid() then raise exception 'SELF_PERMISSION: nadie modifica sus propios permisos' using errcode = '42501'; end if;
  if not exists (select 1 from public.permissions where code = p_perm) then raise exception 'BAD_PERMISSION' using errcode = '22023'; end if;
  if p_state not in ('GRANT','REVOKE','ROLE') then raise exception 'BAD_STATE' using errcode = '22023'; end if;
  if p_state = 'GRANT' and public.is_sensitive_permission(p_perm) and not public.auth_is_admin() then
    raise exception 'SENSITIVE_PERMISSION: solo Admin General otorga este permiso' using errcode = '42501'; end if;
  select case when granted then 'GRANT' else 'REVOKE' end into prev from public.user_permission_overrides where user_id = p_user and permission_code = p_perm;
  if p_state = 'ROLE' then delete from public.user_permission_overrides where user_id = p_user and permission_code = p_perm;
  else insert into public.user_permission_overrides(user_id, permission_code, granted, set_by, reason) values (p_user, p_perm, p_state = 'GRANT', auth.uid(), p_reason)
       on conflict (user_id, permission_code) do update set granted = excluded.granted, set_by = excluded.set_by, set_at = now(), reason = excluded.reason; end if;
  insert into public.audit_log(actor_id, action, target_type, target_id, before, after)
  values (auth.uid(), 'USER_PERMISSION_SET', 'profile', p_user::text, jsonb_build_object('permission', p_perm, 'state', coalesce(prev, 'ROLE')), jsonb_build_object('permission', p_perm, 'state', p_state, 'reason', p_reason));
  return jsonb_build_object('user', p_user, 'permission', p_perm, 'state', p_state, 'effective', public.user_has_perm(p_user, p_perm));
end; $$;
grant execute on function public.set_user_permission(uuid, text, text, text) to authenticated;

-- =====================================================================
-- 3 · Jerarquía: superior asignado (Despacho en general + Transportista Interno), sin ciclos ni uno mismo, superior activo
-- =====================================================================
create or replace function public._check_supervisor(p_user uuid, p_role text, p_sup uuid) returns void language plpgsql stable security definer set search_path = public as $$
declare sup public.profiles; cur uuid; hops int := 0;
begin
  if p_sup is null then return; end if;
  if p_sup = p_user then raise exception 'BAD_SUPERVISOR: un usuario no puede ser su propio superior' using errcode = '23514'; end if;
  select * into sup from public.profiles where id = p_sup;
  if not found or sup.status <> 'ACTIVO' then raise exception 'BAD_SUPERVISOR: el superior debe existir y estar activo' using errcode = '23514'; end if;
  -- sin ciclos: subir desde el superior propuesto no puede volver al usuario
  cur := sup.supervisor_user_id;
  while cur is not null and hops < 50 loop
    if cur = p_user then raise exception 'BAD_SUPERVISOR: la asignación generaría un ciclo de supervisión' using errcode = '23514'; end if;
    select supervisor_user_id into cur from public.profiles where id = cur; hops := hops + 1;
  end loop;
  if p_role = 'OPERARIO_DEPOSITO' and sup.role not in ('SUPERVISOR_DESPACHO','ADMIN','DESPACHO') then
    raise exception 'BAD_SUPERVISOR: el superior de un Operario Depósito debe ser Superior Despacho o Admin General' using errcode = '23514'; end if;
  if p_role in ('SUPERVISOR_DESPACHO','DESPACHO') and sup.role <> 'ADMIN' then
    raise exception 'BAD_SUPERVISOR: el superior de un Superior Despacho debe ser Admin General' using errcode = '23514'; end if;
  if p_role = 'TRANSPORTISTA_INTERNO' and not public.user_has_perm(p_sup, 'can_approve_internal_route_changes') then
    raise exception 'BAD_SUPERVISOR: el superior debe estar activo y tener permiso de aprobación' using errcode = '23514'; end if;
end; $$;
create or replace function public.trg_profiles_protect()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  is_service boolean := coalesce(auth.role(), '') = 'service_role' or current_setting('okd.sync', true) = 'on';
  active_admins int;
begin
  if tg_op = 'UPDATE' then
    if not is_service then
      if new.role is distinct from old.role or new.status is distinct from old.status
         or new.email is distinct from old.email or new.id is distinct from old.id
         or new.supervisor_user_id is distinct from old.supervisor_user_id
         or new.sessions_revoked_at is distinct from old.sessions_revoked_at then
        raise exception 'FORBIDDEN: rol, estado, email y supervisor solo se cambian desde Administración (servidor)' using errcode = '42501';
      end if;
    end if;
    if old.role = 'ADMIN' and old.status = 'ACTIVO' and (new.role <> 'ADMIN' or new.status <> 'ACTIVO') then
      select count(*) into active_admins from public.profiles where role = 'ADMIN' and status = 'ACTIVO';
      if active_admins <= 1 then raise exception 'LAST_ADMIN: es el último administrador activo' using errcode = '23514'; end if;
    end if;
    -- No dejar hojas activas asignadas a alguien sin acceso
    if new.status in ('DESHABILITADO','ARCHIVADO') and old.status not in ('DESHABILITADO','ARCHIVADO')
       and exists (select 1 from public.routes r where r.responsable_id = new.id and r.operational_status in ('BORRADOR','PUBLICADA','EN_CURSO')) then
      raise exception 'ACTIVE_ROUTES: el usuario tiene hojas activas; reasignalas o resolvelas antes' using errcode = '23514';
    end if;
    -- Supervisor: activo, con permiso de aprobación y distinto del propio usuario
    if new.supervisor_user_id is distinct from old.supervisor_user_id and new.supervisor_user_id is not null then
      -- RC4: jerarquía de Despacho (Operario → Superior/Admin; Superior → Admin) y Transportista Interno (regla anterior). Nunca uno mismo ni ciclos.
      perform public._check_supervisor(new.id, new.role, new.supervisor_user_id);
    end if;
    new.updated_at := now();
  elsif tg_op = 'DELETE' then
    if old.role = 'ADMIN' and old.status = 'ACTIVO' then
      select count(*) into active_admins from public.profiles where role = 'ADMIN' and status = 'ACTIVO';
      if active_admins <= 1 then raise exception 'LAST_ADMIN: es el último administrador activo' using errcode = '23514'; end if;
    end if;
    if public.user_has_history(old.id) then
      raise exception 'HAS_HISTORY: el usuario tiene historial; se archiva, no se elimina' using errcode = '23514';
    end if;
    return old;
  end if;
  return new;
end;
$$;
-- Asignar superior: solo users.assign_supervisor (Admin), nunca a uno mismo; auditado
create or replace function public.set_user_supervisor(p_user uuid, p_sup uuid) returns public.profiles language plpgsql security definer set search_path = public as $$
declare p public.profiles; prev uuid;
begin
  if not public.auth_has_perm('users.assign_supervisor') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_user = auth.uid() then raise exception 'SELF_SUPERVISOR: nadie cambia su propio superior' using errcode = '42501'; end if;
  select supervisor_user_id into prev from public.profiles where id = p_user for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  perform set_config('okd.sync', 'on', true);       -- cambio autorizado por el servidor (el trigger de perfiles lo exige)
  update public.profiles set supervisor_user_id = p_sup where id = p_user returning * into p;
  perform set_config('okd.sync', '', true);
  insert into public.audit_log(actor_id, action, target_type, target_id, before, after) values (auth.uid(), 'USER_SUPERVISOR_SET', 'profile', p_user::text, jsonb_build_object('supervisor', prev), jsonb_build_object('supervisor', p_sup));
  return p;
end; $$;
grant execute on function public.set_user_supervisor(uuid, uuid) to authenticated;
-- Equipo: subordinados directos e indirectos
create or replace function public.team_of(p_user uuid) returns setof uuid language sql stable security definer set search_path = public as $$
  with recursive t(id, d) as (select id, 1 from public.profiles where supervisor_user_id = p_user
    union all select p.id, t.d + 1 from public.profiles p join t on p.supervisor_user_id = t.id where t.d < 20)
  select distinct id from t;
$$;
create or replace function public.in_my_team(p_user uuid) returns boolean language sql stable security definer set search_path = public as $$
  select p_user in (select public.team_of(auth.uid()));
$$;
grant execute on function public.team_of(uuid), public.in_my_team(uuid) to authenticated;

-- Migración segura de DESPACHO → SUPERVISOR_DESPACHO: los permisos de Superior incluyen TODOS los que tenía DESPACHO
-- (routes.create/publish/assign/view_all, internal_routes.manage, locations.view, signatures.view); no hace falta ningún permiso extra.
do $$ begin
  perform set_config('okd.sync', 'on', true);
  update public.profiles set role = 'SUPERVISOR_DESPACHO' where role = 'DESPACHO';
  perform set_config('okd.sync', '', true);
end $$;
insert into public.audit_log(action, target_type, target_id, after) values ('ROLE_MIGRATION_RC4', 'roles', 'DESPACHO', jsonb_build_object('to', 'SUPERVISOR_DESPACHO'));

-- =====================================================================
-- 4 · Borradores por alcance: propios / del equipo / todos
-- =====================================================================
create or replace function public.can_manage_draft_of(p_owner uuid) returns boolean language sql stable security definer set search_path = public as $$
  select p_owner = auth.uid() or public.auth_has_perm('routes.manage_all_drafts') or (public.auth_has_perm('drafts.manage_team') and public.in_my_team(p_owner));
$$;
create or replace function public.can_view_draft_of(p_owner uuid) returns boolean language sql stable security definer set search_path = public as $$
  select public.can_manage_draft_of(p_owner) or (public.auth_has_perm('drafts.view_team') and public.in_my_team(p_owner));
$$;
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
  if not public.can_manage_draft_of(d.owner_id) then
    raise exception 'FORBIDDEN_DRAFT: el borrador pertenece a otro operador' using errcode = '42501';
  end if;
  if p_need_draft and d.status <> 'BORRADOR' then raise exception 'DRAFT_PUBLISHED: la hoja ya fue publicada; no se modifica como borrador' using errcode = '23514'; end if;
  return d;
end; $$;
revoke execute on function public._draft(text, boolean, boolean) from public, anon, authenticated;
create or replace function public.list_drafts() returns table (id uuid, client_sheet_key text, name text, carrier_name text, delivery_count int, orders text[],
  owner_id uuid, owner_name text, status text, created_at timestamptz, updated_at timestamptz, reserved text[]) language sql stable security definer set search_path = public as $$
  select d.id, d.client_sheet_key, d.name, d.carrier_name, d.delivery_count, d.orders, d.owner_id, p.full_name, d.status, d.created_at, d.updated_at,
         coalesce((select array_agg(r.order_id order by r.order_id) from public.order_reservations r where r.sheet_key = d.client_sheet_key and r.status = 'BORRADOR'), '{}')
  from public.route_drafts d left join public.profiles p on p.id = d.owner_id
  where d.status = 'BORRADOR' and public.auth_has_perm('routes.create') and public.can_view_draft_of(d.owner_id)
  order by d.updated_at desc;
$$;
create or replace function public.draft_content(p_sheet_key text) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d public.route_drafts;
begin
  if not public.auth_has_perm('routes.create') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into d from public.route_drafts where client_sheet_key = p_sheet_key;
  if not found then return null; end if;
  if not public.can_view_draft_of(d.owner_id) then raise exception 'FORBIDDEN_DRAFT' using errcode = '42501'; end if;
  return jsonb_build_object('name', d.name, 'status', d.status, 'content', d.content);
end; $$;

-- =====================================================================
-- 5 · Columnas, cancelación y corrección de km por permiso granular (lógica intacta)
-- =====================================================================
create or replace function public.save_sheet_template(p_carrier text, p_columns jsonb) returns public.sheet_templates language plpgsql security definer set search_path = public as $$
declare t public.sheet_templates;
begin
  if not (public.auth_has_perm('settings.manage') or public.auth_has_perm('columns.manage_defaults') or public.auth_has_perm('columns.manage_templates')) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if jsonb_typeof(p_columns) <> 'array' or jsonb_array_length(p_columns) = 0 then raise exception 'BAD_TEMPLATE' using errcode = '22023'; end if;
  if exists (select 1 from jsonb_array_elements(p_columns) c where coalesce((c->>'required')::boolean, false) and not coalesce((c->>'visible')::boolean, true)) then
    raise exception 'REQUIRED_HIDDEN: una columna obligatoria no se puede ocultar' using errcode = '23514'; end if;
  insert into public.sheet_templates(carrier_id, version, columns, created_by)
  values (p_carrier, coalesce((select max(version) from public.sheet_templates where carrier_id = p_carrier), 0) + 1, p_columns, auth.uid()) returning * into t;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'TEMPLATE_SAVED', 'template', p_carrier, jsonb_build_object('version', t.version));
  return t;
end; $$;
create or replace function public.cancel_route(p_route uuid, p_reason text) returns public.routes language plpgsql security definer set search_path = public as $$
declare r public.routes; a record;
begin
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
create or replace function public.correct_vehicle_km(p_vehicle uuid, p_km numeric, p_reason text) returns void language plpgsql security definer set search_path = public as $$
declare v public.vehicles;
begin
  if not (public.auth_has_perm('vehicles.manage') or public.auth_has_perm('vehicle_mileage.edit')) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'REASON_REQUIRED' using errcode = '23514'; end if;
  select * into v from public.vehicles where id = p_vehicle for update;
  update public.vehicles set current_km = p_km where id = p_vehicle;
  insert into public.audit_log(actor_id, action, target_type, target_id, before, after) values (auth.uid(), 'VEHICLE_KM_CORRECTED', 'vehicle', p_vehicle::text, jsonb_build_object('km', v.current_km), jsonb_build_object('km', p_km, 'reason', p_reason));
end; $$;

-- =====================================================================
-- 6 · Kilometraje: reglas, carga de lectura, alertas
-- =====================================================================
create table if not exists public.mileage_settings (
  id text primary key default 'DEFAULT' check (id = 'DEFAULT'),
  require_km_start boolean not null default true, require_km_end boolean not null default true,
  tolerance_km numeric(10,1) not null default 0 check (tolerance_km >= 0), max_trip_km numeric(10,1) not null default 1000 check (max_trip_km > 0),
  alert_lower_than_last boolean not null default true, updated_by uuid, updated_at timestamptz not null default now());
insert into public.mileage_settings(id) values ('DEFAULT') on conflict do nothing;
alter table public.mileage_settings enable row level security;
create policy mileage_settings_read on public.mileage_settings for select to authenticated using (public.auth_has_perm('vehicle_mileage.view') or public.auth_has_perm('vehicle_mileage.rules_manage'));
grant select on public.mileage_settings to authenticated;
revoke insert, update, delete on public.mileage_settings from authenticated, anon;
create or replace function public.set_mileage_settings(p jsonb) returns public.mileage_settings language plpgsql security definer set search_path = public as $$
declare s public.mileage_settings; prev jsonb;
begin
  if not (public.auth_has_perm('vehicle_mileage.rules_manage') or public.auth_has_perm('settings.manage')) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select to_jsonb(m) into prev from public.mileage_settings m where id = 'DEFAULT';
  update public.mileage_settings set require_km_start = coalesce((p->>'require_km_start')::boolean, require_km_start), require_km_end = coalesce((p->>'require_km_end')::boolean, require_km_end),
    tolerance_km = coalesce((p->>'tolerance_km')::numeric, tolerance_km), max_trip_km = coalesce((p->>'max_trip_km')::numeric, max_trip_km),
    alert_lower_than_last = coalesce((p->>'alert_lower_than_last')::boolean, alert_lower_than_last), updated_by = auth.uid(), updated_at = now() where id = 'DEFAULT' returning * into s;
  insert into public.audit_log(actor_id, action, target_type, target_id, before, after) values (auth.uid(), 'MILEAGE_SETTINGS_CHANGED', 'settings', 'mileage', prev, to_jsonb(s));
  return s;
end; $$;
create table if not exists public.vehicle_mileage_alerts (
  id uuid primary key default gen_random_uuid(), vehicle_id uuid references public.vehicles(id), route_id uuid references public.routes(id),
  kind text not null check (kind in ('TRIP_OUT_OF_RANGE','LOWER_THAN_LAST','INCONSISTENT')), km_from numeric, km_to numeric, detail jsonb,
  status text not null default 'OPEN' check (status in ('OPEN','RESOLVED')), created_at timestamptz not null default now(), created_by uuid,
  resolved_by uuid, resolved_at timestamptz, resolution_note text);
alter table public.vehicle_mileage_alerts enable row level security;
create policy mileage_alerts_read on public.vehicle_mileage_alerts for select to authenticated using (public.auth_has_perm('vehicle_mileage.view'));
grant select on public.vehicle_mileage_alerts to authenticated;
revoke insert, update, delete on public.vehicle_mileage_alerts from authenticated, anon;
create or replace function public._mileage_alert(p_vehicle uuid, p_route uuid, p_kind text, p_from numeric, p_to numeric, p_detail jsonb) returns void language plpgsql security definer set search_path = public as $$
declare a uuid; v public.vehicles; u uuid;
begin
  insert into public.vehicle_mileage_alerts(vehicle_id, route_id, kind, km_from, km_to, detail, created_by) values (p_vehicle, p_route, p_kind, p_from, p_to, p_detail, auth.uid()) returning id into a;
  select * into v from public.vehicles where id = p_vehicle;
  for u in select id from public.profiles where status = 'ACTIVO' and (role = 'ADMIN' or public.user_has_perm(id, 'vehicle_mileage.resolve_alerts')) loop
    insert into public.notifications(user_id, route_id, type, title, body) values (u, p_route, 'KM_ALERT', 'KILOMETRAJE FUERA DE RANGO · ' || coalesce(v.plate, ''),
      case p_kind when 'TRIP_OUT_OF_RANGE' then 'Recorrido de ' || (p_to - p_from) || ' km' when 'LOWER_THAN_LAST' then 'Km menor al último registrado' else 'Diferencia inconsistente' end)
    on conflict do nothing;
  end loop;
end; $$;
revoke execute on function public._mileage_alert(uuid, uuid, text, numeric, numeric, jsonb) from public, anon, authenticated;
-- Recorrido fuera de rango al cerrar una hoja (alerta; no bloquea la operación aprobada)
create or replace function public.trg_route_mileage_range() returns trigger language plpgsql security definer set search_path = public as $$
declare s public.mileage_settings;
begin
  if new.km_end is not null and old.km_end is null and new.km_start is not null then
    select * into s from public.mileage_settings where id = 'DEFAULT';
    if new.km_end - new.km_start > s.max_trip_km + s.tolerance_km then
      perform public._mileage_alert(new.vehicle_id, new.id, 'TRIP_OUT_OF_RANGE', new.km_start, new.km_end, jsonb_build_object('max', s.max_trip_km, 'tolerance', s.tolerance_km));
    end if;
  end if;
  return new;
end; $$;
drop trigger if exists route_mileage_range on public.routes;
create trigger route_mileage_range after update of km_end on public.routes for each row execute function public.trg_route_mileage_range();
-- Cargar una lectura de odómetro (Operario con vehicle_mileage.enter). Un valor menor al último NO se carga: requiere corrección (permiso o solicitud).
-- El rechazo se DEVUELVE ({ok:false, code}) en vez de abortar, para que la alerta quede registrada.
create or replace function public.record_vehicle_km(p_vehicle uuid, p_km numeric, p_note text default null) returns jsonb language plpgsql security definer set search_path = public as $$
declare v public.vehicles; s public.mileage_settings;
begin
  if not public.auth_has_perm('vehicle_mileage.enter') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into v from public.vehicles where id = p_vehicle for update;
  if not found or not v.active then raise exception 'BAD_VEHICLE' using errcode = '23514'; end if;
  select * into s from public.mileage_settings where id = 'DEFAULT';
  if p_km is null or p_km < 0 then raise exception 'BAD_KM' using errcode = '22023'; end if;
  if p_km < v.current_km then
    if s.alert_lower_than_last then perform public._mileage_alert(p_vehicle, null, 'LOWER_THAN_LAST', v.current_km, p_km, jsonb_build_object('note', p_note)); end if;
    return jsonb_build_object('ok', false, 'code', 'KM_LOWER', 'message', 'El kilometraje no puede ser menor al último registrado (' || v.current_km || '). Pedí una corrección.', 'current_km', v.current_km); end if;
  if p_km - v.current_km > s.max_trip_km + s.tolerance_km then perform public._mileage_alert(p_vehicle, null, 'INCONSISTENT', v.current_km, p_km, jsonb_build_object('note', p_note)); end if;
  update public.vehicles set current_km = p_km where id = p_vehicle returning * into v;
  perform public._vehicle_service_check(p_vehicle);
  insert into public.audit_log(actor_id, action, target_type, target_id, before, after) values (auth.uid(), 'VEHICLE_KM_RECORDED', 'vehicle', p_vehicle::text, null, jsonb_build_object('km', p_km, 'note', p_note));
  return jsonb_build_object('ok', true, 'current_km', v.current_km, 'vehicle', v.id);
end; $$;
create or replace function public.resolve_mileage_alert(p_alert uuid, p_note text) returns public.vehicle_mileage_alerts language plpgsql security definer set search_path = public as $$
declare a public.vehicle_mileage_alerts;
begin
  if not public.auth_has_perm('vehicle_mileage.resolve_alerts') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if coalesce(trim(p_note), '') = '' then raise exception 'REASON_REQUIRED' using errcode = '23514'; end if;
  update public.vehicle_mileage_alerts set status = 'RESOLVED', resolved_by = auth.uid(), resolved_at = now(), resolution_note = p_note where id = p_alert and status = 'OPEN' returning * into a;
  if not found then raise exception 'ALREADY_RESOLVED' using errcode = '23514'; end if;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'MILEAGE_ALERT_RESOLVED', 'vehicle', a.vehicle_id::text, jsonb_build_object('alert', p_alert, 'note', p_note));
  return a;
end; $$;
grant execute on function public.set_mileage_settings(jsonb), public.record_vehicle_km(uuid, numeric, text), public.resolve_mileage_alert(uuid, text) to authenticated;

-- =====================================================================
-- 7 · Solicitudes operativas sobre el MISMO motor de aprobaciones (route_approval_requests)
-- =====================================================================
alter table public.route_approval_requests alter column route_id drop not null;
alter table public.route_approval_requests alter column route_version drop not null;
alter table public.route_approval_requests add column if not exists request_type text not null default 'INTERNAL_ROUTE_CHANGE';
alter table public.route_approval_requests add column if not exists payload jsonb;
alter table public.route_approval_requests add column if not exists reason text;
alter table public.route_approval_requests add column if not exists escalated boolean not null default false;
alter table public.route_approval_requests add column if not exists op_id text unique;
alter table public.route_approval_requests add column if not exists applied boolean not null default false;
alter table public.route_approval_requests drop constraint if exists route_approval_requests_status_check;
alter table public.route_approval_requests add constraint route_approval_requests_status_check check (status in ('PENDING','APPROVED','OBSERVED','REJECTED','CANCELLED'));
alter table public.route_approval_requests drop constraint if exists route_approval_requests_type_check;
alter table public.route_approval_requests add constraint route_approval_requests_type_check check (request_type in ('INTERNAL_ROUTE_CHANGE','CAMBIO_TRANSPORTISTA','REASIGNACION','CAMBIO_RESPONSABLE',
  'MODIFICAR_BULTOS','CAMBIO_VEHICULO','CORRECCION_KM','CANCELACION','CAMBIO_POST_PUBLICACION','OTRO'));
-- Quién resuelve: el superior asignado (activo, con permiso de aprobación, distinto del solicitante); si no hay, Admin General
create or replace function public._request_approver(p_user uuid) returns uuid language plpgsql stable security definer set search_path = public as $$
declare sup uuid;
begin
  select supervisor_user_id into sup from public.profiles where id = p_user;
  if sup is null or sup = p_user or not exists (select 1 from public.profiles where id = sup and status = 'ACTIVO')
     or not (public.user_has_perm(sup, 'requests.approve_team') or exists (select 1 from public.profiles where id = sup and role = 'ADMIN')) then return null; end if;
  return sup;
end; $$;
create or replace function public.create_operational_request(p jsonb) returns public.route_approval_requests language plpgsql security definer set search_path = public as $$
declare q public.route_approval_requests; sup uuid; me public.profiles; r public.routes; u uuid;
begin
  if not public.auth_has_perm('requests.create') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into q from public.route_approval_requests where op_id = p->>'op_id';
  if found then return q; end if;                                       -- idempotente
  if coalesce(p->>'request_type', '') not in ('CAMBIO_TRANSPORTISTA','REASIGNACION','CAMBIO_RESPONSABLE','MODIFICAR_BULTOS','CAMBIO_VEHICULO','CORRECCION_KM','CANCELACION','CAMBIO_POST_PUBLICACION','OTRO') then
    raise exception 'BAD_REQUEST_TYPE' using errcode = '22023'; end if;
  if coalesce(trim(p->>'reason'), '') = '' then raise exception 'REASON_REQUIRED: indicá el motivo' using errcode = '23514'; end if;
  if coalesce(p->>'route_id', '') <> '' then select * into r from public.routes where id = (p->>'route_id')::uuid; end if;
  select * into me from public.profiles where id = auth.uid();
  sup := public._request_approver(auth.uid());
  insert into public.route_approval_requests(route_id, route_version, requested_by, supervisor_user_id, supervisor_missing, request_type, payload, reason, escalated, op_id)
  values (r.id, r.version, auth.uid(), sup, sup is null, p->>'request_type', coalesce(p->'payload', '{}'), p->>'reason', sup is null, p->>'op_id') returning * into q;
  for u in select id from public.profiles where status = 'ACTIVO' and ((sup is not null and id = sup) or (sup is null and role = 'ADMIN')) loop
    insert into public.notifications(user_id, route_id, route_version, type, title, body) values (u, r.id, coalesce(r.version, 1), 'REQUEST_CREATED', 'SOLICITUD · ' || replace(q.request_type, '_', ' '),
      coalesce(me.full_name, '') || ': ' || q.reason) on conflict do nothing;
  end loop;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'REQUEST_CREATED', 'request', q.id::text,
    jsonb_build_object('type', q.request_type, 'approver', sup, 'escalated', q.escalated, 'route', r.id, 'payload', q.payload));
  return q;
end; $$;
-- Resolver: nunca uno mismo, solo el superior asignado (con el permiso de esa decisión) o Admin General; doble resolución protegida
create or replace function public.resolve_operational_request(p_request uuid, p_decision text, p_note text, p_op_id text default null) returns public.route_approval_requests
language plpgsql security definer set search_path = public as $$
declare q public.route_approval_requests; perm text; ok boolean;
begin
  if p_decision not in ('APPROVED','REJECTED','OBSERVED') then raise exception 'BAD_DECISION' using errcode = '22023'; end if;
  select * into q from public.route_approval_requests where id = p_request for update;
  if not found or q.request_type = 'INTERNAL_ROUTE_CHANGE' then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  if q.status <> 'PENDING' and q.status <> 'OBSERVED' then
    if p_op_id is not null and q.payload->>'resolution_op_id' = p_op_id then return q; end if;   -- reintento idempotente
    raise exception 'REQUEST_ALREADY_RESOLVED: la solicitud ya fue resuelta (%)', q.status using errcode = '40001'; end if;
  if q.requested_by = auth.uid() then raise exception 'SELF_APPROVAL: no podés resolver tu propia solicitud' using errcode = '42501'; end if;
  perm := case p_decision when 'APPROVED' then 'requests.approve_team' when 'REJECTED' then 'requests.reject_team' else 'requests.observe_team' end;
  ok := coalesce(public.auth_is_admin(), false) or coalesce(q.supervisor_user_id = auth.uid() and public.auth_has_perm(perm), false);
  if not ok then raise exception 'FORBIDDEN: solo el superior asignado o Admin General' using errcode = '42501'; end if;
  if p_decision in ('REJECTED','OBSERVED') and coalesce(trim(p_note), '') = '' then raise exception 'REASON_REQUIRED: indicá el motivo' using errcode = '23514'; end if;
  update public.route_approval_requests set status = p_decision, reviewed_by = auth.uid(), reviewed_at = now(), review_note = p_note, updated_at = now(),
    payload = coalesce(payload, '{}') || jsonb_build_object('resolution_op_id', p_op_id) where id = q.id returning * into q;
  -- Corrección de km aprobada: se aplica en el servidor (auditada)
  if p_decision = 'APPROVED' and q.request_type = 'CORRECCION_KM' and q.payload ? 'vehicle_id' and q.payload ? 'km' then
    update public.vehicles set current_km = (q.payload->>'km')::numeric where id = (q.payload->>'vehicle_id')::uuid;
    update public.route_approval_requests set applied = true where id = q.id returning * into q;
    insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'VEHICLE_KM_CORRECTED', 'vehicle', q.payload->>'vehicle_id',
      jsonb_build_object('km', q.payload->>'km', 'reason', q.reason, 'request', q.id, 'requested_by', q.requested_by));
  end if;
  insert into public.notifications(user_id, route_id, route_version, type, title, body) values (q.requested_by, q.route_id, coalesce(q.route_version, 1),
    'REQUEST_' || p_decision, 'SOLICITUD ' || case p_decision when 'APPROVED' then 'APROBADA' when 'REJECTED' then 'RECHAZADA' else 'OBSERVADA' end, coalesce(p_note, '')) on conflict do nothing;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'REQUEST_' || p_decision, 'request', q.id::text, jsonb_build_object('note', p_note, 'type', q.request_type));
  return q;
end; $$;
create or replace function public.cancel_operational_request(p_request uuid) returns public.route_approval_requests language plpgsql security definer set search_path = public as $$
declare q public.route_approval_requests;
begin
  update public.route_approval_requests set status = 'CANCELLED', updated_at = now() where id = p_request and requested_by = auth.uid() and status in ('PENDING','OBSERVED') and request_type <> 'INTERNAL_ROUTE_CHANGE' returning * into q;
  if not found then raise exception 'BAD_STATE' using errcode = '23514'; end if;
  insert into public.audit_log(actor_id, action, target_type, target_id) values (auth.uid(), 'REQUEST_CANCELLED', 'request', q.id::text);
  return q;
end; $$;
create or replace function public.reassign_operational_request(p_request uuid, p_to uuid) returns public.route_approval_requests language plpgsql security definer set search_path = public as $$
declare q public.route_approval_requests;
begin
  if not public.auth_has_perm('requests.reassign') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into q from public.route_approval_requests where id = p_request for update;
  if q.status <> 'PENDING' then raise exception 'REQUEST_ALREADY_RESOLVED' using errcode = '40001'; end if;
  if p_to = q.requested_by then raise exception 'SELF_APPROVAL: no se asigna al solicitante' using errcode = '42501'; end if;
  if not (public.user_has_perm(p_to, 'requests.approve_team') or exists (select 1 from public.profiles where id = p_to and role = 'ADMIN' and status = 'ACTIVO')) then raise exception 'BAD_APPROVER' using errcode = '23514'; end if;
  update public.route_approval_requests set supervisor_user_id = p_to, escalated = false, updated_at = now() where id = q.id returning * into q;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'REQUEST_REASSIGNED', 'request', q.id::text, jsonb_build_object('to', p_to));
  return q;
end; $$;
grant execute on function public.create_operational_request(jsonb), public.resolve_operational_request(uuid, text, text, text), public.cancel_operational_request(uuid),
  public.reassign_operational_request(uuid, uuid) to authenticated;
-- Visibilidad de solicitudes: propias, asignadas, del equipo (requests.view_team) o Admin
-- La lectura amplia anterior (aprobadores de ruta interna / routes.view_all) queda SOLO para las aprobaciones de ruta interna (comportamiento intacto);
-- las solicitudes operativas nuevas se ven por alcance (propias, asignadas, equipo o Admin)
drop policy if exists route_approval_read on public.route_approval_requests;
create policy route_approval_read on public.route_approval_requests for select to authenticated
  using (requested_by = auth.uid() or supervisor_user_id = auth.uid()
         or (request_type = 'INTERNAL_ROUTE_CHANGE' and (public.auth_has_perm('can_approve_internal_route_changes') or public.auth_has_perm('routes.view_all'))));
drop policy if exists rar_team_read on public.route_approval_requests;
create policy rar_team_read on public.route_approval_requests for select to authenticated
  using (requested_by = auth.uid() or supervisor_user_id = auth.uid() or public.auth_is_admin() or (public.auth_has_perm('requests.view_team') and public.in_my_team(requested_by)));

-- =====================================================================
-- 8 · Notificaciones: propias; el Superior ve las de su equipo; Admin ve todas (transportistas: igual que antes, solo propias)
-- =====================================================================
drop policy if exists notifications_scope on public.notifications;
create policy notifications_scope on public.notifications for select to authenticated using (public.auth_is_admin() or (public.auth_has_perm('requests.view_team') and public.in_my_team(user_id)));
create or replace function public.mark_notification_read(p_id uuid) returns void language sql security definer set search_path = public as $$
  update public.notifications set read_at = coalesce(read_at, now()) where id = p_id and user_id = auth.uid();
$$;
grant execute on function public.mark_notification_read(uuid) to authenticated;

-- =====================================================================
-- 9 · Datos de los dashboards por rol (solo lectura; cada uno valida su alcance)
-- =====================================================================
create or replace function public.dashboard_admin() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare today date := (now() at time zone 'America/Argentina/Mendoza')::date; res jsonb;
begin
  if not public.auth_is_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  with r as (select r.*, c.kind, c.id cid from public.routes r join public.carriers c on c.id = r.carrier_id where r.operational_status <> 'CANCELADA'),
  g as (select case when cid like 'CT-%' then 'CRISTIAN' when kind = 'INTERNO' then 'INTERNO' else 'OTROS' end grp, r.* from r)
  select jsonb_build_object(
    'kpis', jsonb_build_object(
      'hojas_hoy', (select count(*) from r where (published_at at time zone 'America/Argentina/Mendoza')::date = today),
      'en_curso', (select count(*) from r where operational_status = 'EN_CURSO'),
      'finalizadas', (select count(*) from r where operational_status = 'FINALIZADA' and (completed_at at time zone 'America/Argentina/Mendoza')::date = today),
      'incidencias', (select count(*) from public.route_stops s join r on r.id = s.route_id where s.outcome in ('NO_ENTREGADO','REPROGRAMAR','ENTREGA_PARCIAL') and r.operational_status in ('PUBLICADA','EN_CURSO','FINALIZADA') and coalesce((r.completed_at at time zone 'America/Argentina/Mendoza')::date, today) = today)),
    'carriers', (select coalesce(jsonb_agg(x order by x->>'grp'), '[]') from (select jsonb_build_object('grp', grp,
        'publicadas', count(*) filter (where operational_status in ('PUBLICADA','EN_CURSO','FINALIZADA')),
        'activas', count(*) filter (where operational_status in ('PUBLICADA','EN_CURSO')),
        'finalizadas', count(*) filter (where operational_status = 'FINALIZADA'),
        'incidencias', (select count(*) from public.route_stops s where s.route_id = any(array_agg(g.id)) and s.outcome in ('NO_ENTREGADO','REPROGRAMAR','ENTREGA_PARCIAL')),
        'devoluciones', (select count(*) from public.route_return_requests rr where rr.route_id = any(array_agg(g.id)) and rr.status = 'PENDING'),
        'km', coalesce(sum(km_end - km_start) filter (where km_end is not null and km_start is not null), 0)) x from g group by grp) t),
    'alerts', jsonb_build_object(
      'solicitudes', (select count(*) from public.route_approval_requests where status = 'PENDING'),
      'incidencias', (select count(*) from public.route_return_requests where status = 'PENDING'),
      'service', (select count(*) from public.vehicle_service_status where service_due),
      'emails_error', (select count(*) from public.customer_email_jobs where status = 'ERROR') + (select count(*) from public.sheet_email_jobs where status = 'ERROR'),
      'noc', (select count(*) from public.credit_notes where reconciliation_status in ('CANCELLED_ROUTE_REVIEW','CIANBOX_DIFFERENCE')),
      'km', (select count(*) from public.vehicle_mileage_alerts where status = 'OPEN')),
    'users', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'full_name', p.full_name, 'role', p.role, 'status', p.status, 'supervisor', s.full_name,
        'columns', public.user_has_perm(p.id, 'columns.manage_defaults'), 'km', public.user_has_perm(p.id, 'vehicle_mileage.rules_manage'),
        'approve', public.user_has_perm(p.id, 'requests.approve_team')) order by p.role, p.full_name), '[]')
      from public.profiles p left join public.profiles s on s.id = p.supervisor_user_id where p.role in ('ADMIN','SUPERVISOR_DESPACHO','OPERARIO_DEPOSITO','DESPACHO') and p.status <> 'ARCHIVADO')
  ) into res;
  return res;
end; $$;
create or replace function public.dashboard_supervisor() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid(); today date := (now() at time zone 'America/Argentina/Mendoza')::date;
begin
  if not (public.auth_has_perm('requests.view_team') or public.auth_has_perm('drafts.view_team')) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return jsonb_build_object(
    'kpis', jsonb_build_object(
      'borradores', (select count(*) from public.route_drafts d where d.status = 'BORRADOR' and (d.owner_id = me or d.owner_id in (select public.team_of(me)))),
      'borradores_equipo', (select count(*) from public.route_drafts d where d.status = 'BORRADOR' and d.owner_id in (select public.team_of(me))),
      'pendientes', (select count(*) from public.route_approval_requests q where q.status = 'PENDING' and q.supervisor_user_id = me),
      'activas', (select count(*) from public.routes r where r.operational_status in ('PUBLICADA','EN_CURSO') and (r.published_by = me or r.published_by in (select public.team_of(me)))),
      'operarios', (select count(*) from public.team_of(me))),
    'team', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'full_name', p.full_name, 'role', p.role, 'status', p.status,
        'borradores', (select count(*) from public.route_drafts d where d.owner_id = p.id and d.status = 'BORRADOR'),
        'publicadas_hoy', (select count(*) from public.routes r where r.published_by = p.id and (r.published_at at time zone 'America/Argentina/Mendoza')::date = today),
        'solicitudes', (select count(*) from public.route_approval_requests q where q.requested_by = p.id and q.status = 'PENDING')) order by p.full_name), '[]')
      from public.profiles p where p.id in (select public.team_of(me))),
    'requests', (select coalesce(jsonb_agg(jsonb_build_object('id', q.id, 'type', q.request_type, 'reason', q.reason, 'requested_by', p.full_name, 'at', q.requested_at, 'route', r.number) order by q.requested_at), '[]')
      from public.route_approval_requests q join public.profiles p on p.id = q.requested_by left join public.routes r on r.id = q.route_id
      where q.status = 'PENDING' and q.supervisor_user_id = me),
    'active', (select coalesce(jsonb_agg(jsonb_build_object('number', r.number, 'carrier', c.name, 'responsable', p.full_name, 'status', r.operational_status,
        'incidencia', exists (select 1 from public.route_stops s where s.route_id = r.id and s.outcome in ('NO_ENTREGADO','REPROGRAMAR','ENTREGA_PARCIAL'))) order by r.published_at desc), '[]')
      from public.routes r join public.carriers c on c.id = r.carrier_id left join public.profiles p on p.id = r.responsable_id
      where r.operational_status in ('PUBLICADA','EN_CURSO') and (r.published_by = me or r.published_by in (select public.team_of(me)))),
    'notifications', (select coalesce(jsonb_agg(jsonb_build_object('title', n.title, 'body', n.body, 'at', n.created_at, 'type', n.type) order by n.created_at desc), '[]')
      from (select * from public.notifications where user_id = me or user_id in (select public.team_of(me)) order by created_at desc limit 12) n),
    'perms', jsonb_build_object('columns', public.auth_has_perm('columns.manage_defaults') or public.auth_has_perm('columns.manage_templates'),
      'km', public.auth_has_perm('vehicle_mileage.rules_manage'), 'approve', public.auth_has_perm('requests.approve_team')));
end; $$;
create or replace function public.dashboard_operario() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if not public.auth_has_perm('routes.create') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return jsonb_build_object(
    'borradores', (select count(*) from public.route_drafts where owner_id = me and status = 'BORRADOR'),
    'requests', (select coalesce(jsonb_agg(jsonb_build_object('id', q.id, 'type', q.request_type, 'status', q.status, 'reason', q.reason, 'note', q.review_note, 'at', q.requested_at) order by q.requested_at desc), '[]')
      from public.route_approval_requests q where q.requested_by = me and q.request_type <> 'INTERNAL_ROUTE_CHANGE'),
    'notifications', (select coalesce(jsonb_agg(jsonb_build_object('title', n.title, 'body', n.body, 'at', n.created_at, 'type', n.type) order by n.created_at desc), '[]')
      from (select * from public.notifications where user_id = me order by created_at desc limit 12) n),
    'vehicles', case when public.auth_has_perm('vehicle_mileage.view') then (select coalesce(jsonb_agg(jsonb_build_object('id', v.id, 'name', v.name, 'plate', v.plate, 'current_km', v.current_km,
        'assigned', v.habitual_driver_id = me) order by (v.habitual_driver_id = me) desc, v.name), '[]') from public.vehicles v where v.active) else '[]'::jsonb end,
    'mileage', case when public.auth_has_perm('vehicle_mileage.view') then (select to_jsonb(m) from public.mileage_settings m where id = 'DEFAULT') end,
    'km_alerts', case when public.auth_has_perm('vehicle_mileage.view') then (select count(*) from public.vehicle_mileage_alerts where status = 'OPEN') else 0 end,
    'supervisor', (select s.full_name from public.profiles p join public.profiles s on s.id = p.supervisor_user_id where p.id = me));
end; $$;
grant execute on function public.dashboard_admin(), public.dashboard_supervisor(), public.dashboard_operario() to authenticated;