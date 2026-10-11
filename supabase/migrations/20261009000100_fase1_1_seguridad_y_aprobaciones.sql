-- =====================================================================
-- OK DESPACHO ONLINE — FASE 1.1 (migración INCREMENTAL, no reescribe la Fase 1)
-- · Último acceso real (sincronizado desde Auth)
-- · Email de Auth y de profiles siempre iguales
-- · Cierre de sesiones abiertas (server-side)
-- · Rol TRANSPORTISTA siempre con carrier; cambios de carriers atómicos
-- · Alta de usuario atómica (profile + carriers)
-- · Protección de hojas activas al deshabilitar/archivar + reasignación
-- · Base para aprobación de cambios en rutas internas (estado operativo ≠ estado de aprobación)
-- =====================================================================

-- ---------- Nuevos datos de usuario ----------
alter table public.profiles add column if not exists sessions_revoked_at timestamptz;
alter table public.profiles add column if not exists supervisor_user_id uuid references public.profiles(id);

-- ---------- Nuevo permiso ----------
insert into public.permissions(code) values ('can_approve_internal_route_changes') on conflict do nothing;
insert into public.role_permissions(role_code, permission_code) values ('ADMIN','can_approve_internal_route_changes') on conflict do nothing;

-- ---------- Permisos: un token emitido antes de "cerrar sesiones" ya no tiene permisos ----------
create or replace function public.auth_has_perm(p_perm text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.profiles p
    join public.role_permissions rp on rp.role_code = p.role
    where p.id = auth.uid() and p.status = 'ACTIVO' and rp.permission_code = p_perm
      and (p.sessions_revoked_at is null
           or coalesce((auth.jwt() ->> 'iat')::numeric, 0) > extract(epoch from p.sessions_revoked_at))
  );
$$;

-- Permiso de un usuario cualquiera (para validar supervisores)
create or replace function public.user_has_perm(p_user uuid, p_perm text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (select 1 from public.profiles p join public.role_permissions rp on rp.role_code = p.role
                 where p.id = p_user and p.status = 'ACTIVO' and rp.permission_code = p_perm);
$$;

-- ---------- Hojas: estados separados ----------
alter table public.routes add column if not exists operational_status text not null default 'BORRADOR'
  check (operational_status in ('BORRADOR','PUBLICADA','EN_CURSO','COMPLETADA','CANCELADA'));
alter table public.routes add column if not exists approval_status text not null default 'NO_REQUERIDA'
  check (approval_status in ('NO_REQUERIDA','PENDIENTE','APROBADA','OBSERVADA'));
alter table public.routes add column if not exists version int not null default 1;
alter table public.routes add column if not exists completed_at timestamptz;
alter table public.routes add column if not exists completed_by uuid references public.profiles(id);
alter table public.routes add column if not exists has_driver_modifications boolean not null default false;
alter table public.routes add column if not exists modification_count int not null default 0;
update public.routes set operational_status = case upper(status)
  when 'PUBLICADA' then 'PUBLICADA' when 'EN CURSO' then 'EN_CURSO' when 'EN_CURSO' then 'EN_CURSO'
  when 'COMPLETADA' then 'COMPLETADA' when 'CANCELADA' then 'CANCELADA' else 'BORRADOR' end;
comment on column public.routes.status is 'OBSOLETO desde Fase 1.1: usar operational_status y approval_status.';

-- Hojas activas (no finalizadas) de un usuario
create or replace function public.user_active_routes(p_user uuid)
returns table (id uuid, number text, carrier_id text, operational_status text)
language plpgsql stable security definer set search_path = public
as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' and not (public.auth_has_perm('users.view') or public.auth_has_perm('routes.view_all')) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return query select r.id, r.number, r.carrier_id, r.operational_status from public.routes r
    where r.responsable_id = p_user and r.operational_status in ('BORRADOR','PUBLICADA','EN_CURSO') order by r.created_at;
end;
$$;

-- ---------- Eventos de cambios del transportista interno (se usan en Fase 2) ----------
create table if not exists public.route_change_events (
  id bigserial primary key,
  route_id uuid not null references public.routes(id),
  route_version int not null,
  stop_id text,
  event_type text not null check (event_type in ('INTERNAL_STOP_ADDED','INTERNAL_STOP_REORDERED','INTERNAL_STOP_UPDATED','INTERNAL_STOP_CANCELLED')),
  before jsonb, after jsonb, note text,
  user_id uuid references public.profiles(id),
  at timestamptz not null default now()
);

-- ---------- Solicitudes de aprobación (una por hoja y versión) ----------
create table if not exists public.route_approval_requests (
  id uuid primary key default gen_random_uuid(),
  route_id uuid not null references public.routes(id),
  route_version int not null,
  requested_by uuid references public.profiles(id),
  requested_at timestamptz not null default now(),
  supervisor_user_id uuid references public.profiles(id),
  supervisor_missing boolean not null default false,
  modification_count int not null default 0,
  status text not null default 'PENDING' check (status in ('PENDING','APPROVED','OBSERVED','CANCELLED')),
  reviewed_by uuid references public.profiles(id),
  reviewed_at timestamptz,
  review_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint route_approval_unique_version unique (route_id, route_version)
);

-- =====================================================================
-- Triggers
-- =====================================================================

-- Último acceso real: lo escribe Supabase Auth en auth.users al iniciar sesión
create or replace function public.trg_auth_users_sync()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  perform set_config('okd.sync', 'on', true);
  if new.last_sign_in_at is distinct from old.last_sign_in_at then
    update public.profiles set last_sign_in_at = new.last_sign_in_at where id = new.id;
  end if;
  if new.email is distinct from old.email then
    update public.profiles set email = lower(new.email) where id = new.id;
  end if;
  perform set_config('okd.sync', '', true);
  return new;
end;
$$;
drop trigger if exists auth_users_sync on auth.users;
create trigger auth_users_sync after update of last_sign_in_at, email on auth.users
  for each row execute function public.trg_auth_users_sync();

-- Protección de perfiles (reemplaza la de Fase 1 agregando: hojas activas, supervisor y sincronización)
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
      if new.supervisor_user_id = new.id or not public.user_has_perm(new.supervisor_user_id, 'can_approve_internal_route_changes') then
        raise exception 'BAD_SUPERVISOR: el superior debe estar activo y tener permiso de aprobación' using errcode = '23514';
      end if;
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

-- Invariante: un TRANSPORTISTA siempre tiene al menos un carrier externo (se verifica al confirmar la transacción)
create or replace function public.trg_transportista_has_carrier()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare uid uuid;
begin
  if tg_table_name = 'profiles' then uid := new.id;
  elsif tg_op = 'DELETE' then uid := old.user_id;
  else uid := new.user_id; end if;
  if exists (select 1 from public.profiles p where p.id = uid and p.role = 'TRANSPORTISTA')
     and not exists (select 1 from public.user_carriers uc join public.carriers c on c.id = uc.carrier_id and c.kind = 'EXTERNO' where uc.user_id = uid) then
    raise exception 'CARRIER_REQUIRED: un TRANSPORTISTA debe tener al menos un carrier externo' using errcode = '23514';
  end if;
  return null;
end;
$$;
drop trigger if exists profiles_transportista_carrier on public.profiles;
create constraint trigger profiles_transportista_carrier after insert or update of role on public.profiles
  deferrable initially deferred for each row execute function public.trg_transportista_has_carrier();
drop trigger if exists user_carriers_transportista_carrier on public.user_carriers;
create constraint trigger user_carriers_transportista_carrier after delete or update on public.user_carriers
  deferrable initially deferred for each row execute function public.trg_transportista_has_carrier();

-- =====================================================================
-- Funciones del servidor (las llama la Edge Function con service_role). Cada una es UNA transacción.
-- =====================================================================
create or replace function public._valid_carriers(p_carriers text[])
returns void language plpgsql stable security definer set search_path = public as $$
begin
  if exists (select 1 from unnest(coalesce(p_carriers, '{}')) x(c) left join public.carriers k on k.id = x.c
             where k.id is null or k.kind <> 'EXTERNO' or not k.active) then
    raise exception 'BAD_CARRIER: carrier inexistente, interno o inactivo' using errcode = '23514';
  end if;
end; $$;

-- Reemplaza los carriers de un usuario de forma atómica: si algo falla, quedan los anteriores
create or replace function public.set_user_carriers(p_user uuid, p_carriers text[])
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public._valid_carriers(p_carriers);
  delete from public.user_carriers where user_id = p_user;
  insert into public.user_carriers(user_id, carrier_id) select p_user, c from unnest(coalesce(p_carriers, '{}')) c;
  set constraints all immediate; -- verifica la regla del TRANSPORTISTA dentro de la misma operación
end; $$;

-- Alta atómica: perfil + carriers
create or replace function public.admin_create_profile(p_id uuid, p_full_name text, p_email text, p_phone text, p_role text, p_status text, p_carriers text[], p_created_by uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles(id, full_name, email, phone, role, status, created_by)
  values (p_id, p_full_name, lower(p_email), p_phone, p_role, p_status, p_created_by);
  if p_role <> 'TRANSPORTISTA_INTERNO' and coalesce(array_length(p_carriers, 1), 0) > 0 then
    perform public._valid_carriers(p_carriers);
    insert into public.user_carriers(user_id, carrier_id) select p_id, c from unnest(p_carriers) c;
  end if;
  set constraints all immediate;
end; $$;

-- Edición atómica: datos, rol, carriers y superior en una sola operación
create or replace function public.admin_update_profile(p_user uuid, p_full_name text, p_phone text, p_email text, p_role text,
                                                       p_carriers text[], p_set_supervisor boolean, p_supervisor uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.profiles set
    full_name = coalesce(nullif(trim(p_full_name), ''), full_name),
    phone = p_phone,
    email = coalesce(lower(nullif(trim(p_email), '')), email),
    role = coalesce(p_role, role),
    supervisor_user_id = case when p_set_supervisor then p_supervisor else supervisor_user_id end
  where id = p_user;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  if coalesce(p_role, '') = 'TRANSPORTISTA_INTERNO' then
    delete from public.user_carriers where user_id = p_user;
  elsif p_carriers is not null then
    perform public._valid_carriers(p_carriers);
    delete from public.user_carriers where user_id = p_user;
    insert into public.user_carriers(user_id, carrier_id) select p_user, c from unnest(p_carriers) c;
  end if;
  set constraints all immediate;
end; $$;

-- Reasigna TODAS las hojas activas de un usuario a otro (el trigger de compatibilidad valida cada una)
create or replace function public.reassign_active_routes(p_from uuid, p_to uuid)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if p_from = p_to then raise exception 'SAME_USER' using errcode = '23514'; end if;
  update public.routes set responsable_id = p_to
   where responsable_id = p_from and operational_status in ('BORRADOR','PUBLICADA','EN_CURSO');
  get diagnostics n = row_count;
  return n;
end; $$;

-- Cierre de sesiones: borra sesiones/refresh tokens en Auth y deja sin permisos a los tokens ya emitidos
create or replace function public.revoke_user_sessions(p_user uuid)
returns timestamptz language plpgsql security definer set search_path = public, auth as $$
declare t timestamptz := now();
begin
  update public.profiles set sessions_revoked_at = t where id = p_user;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  delete from auth.sessions where user_id = p_user;
  return t;
end; $$;

-- ---------- Aprobación de cambios en rutas internas (base para Fase 2) ----------
-- Lo llama el cierre de la hoja. Idempotente: una sola solicitud por hoja y versión.
create or replace function public.request_route_approval(p_route uuid, p_version int, p_modification_count int)
returns uuid language plpgsql security definer set search_path = public as $$
declare r public.routes; sup uuid; req uuid;
begin
  select * into r from public.routes where id = p_route for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  if coalesce(auth.role(), '') <> 'service_role' and r.responsable_id is distinct from auth.uid() then
    raise exception 'FORBIDDEN: solo el responsable de la hoja la cierra' using errcode = '42501';
  end if;
  if not exists (select 1 from public.carriers c where c.id = r.carrier_id and c.kind = 'INTERNO') then
    raise exception 'NOT_INTERNAL: la aprobación de cambios aplica a rutas internas' using errcode = '23514';
  end if;
  update public.routes set operational_status = 'COMPLETADA', completed_at = coalesce(completed_at, now()),
         completed_by = coalesce(completed_by, r.responsable_id), version = p_version,
         has_driver_modifications = p_modification_count > 0, modification_count = greatest(p_modification_count, 0),
         approval_status = case when p_modification_count > 0 then
                             case when approval_status in ('APROBADA','OBSERVADA') then approval_status else 'PENDIENTE' end
                           else 'NO_REQUERIDA' end
   where id = p_route;
  if p_modification_count <= 0 then return null; end if; -- sin cambios: auto-cierre
  select p.supervisor_user_id into sup from public.profiles p where p.id = r.responsable_id;
  insert into public.route_approval_requests(route_id, route_version, requested_by, supervisor_user_id, supervisor_missing, modification_count)
  values (p_route, p_version, r.responsable_id, sup,
          sup is null or not public.user_has_perm(sup, 'can_approve_internal_route_changes'), p_modification_count)
  on conflict (route_id, route_version) do nothing
  returning id into req;
  if req is null then select id into req from public.route_approval_requests where route_id = p_route and route_version = p_version; end if;
  return req;
end; $$;

-- Aprobar u observar. Solo usuarios activos con can_approve_internal_route_changes. No toca evidencia.
create or replace function public.review_route_approval(p_request uuid, p_decision text, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare q public.route_approval_requests;
begin
  if not public.auth_has_perm('can_approve_internal_route_changes') then
    raise exception 'FORBIDDEN: falta permiso can_approve_internal_route_changes' using errcode = '42501';
  end if;
  select * into q from public.route_approval_requests where id = p_request for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  if q.status <> 'PENDING' then raise exception 'NOT_PENDING: la solicitud ya fue resuelta' using errcode = '23514'; end if;
  if q.supervisor_user_id is not null and q.supervisor_user_id <> auth.uid() and not public.auth_has_perm('users.manage') then
    raise exception 'FORBIDDEN: la revisa el superior asignado o Administración' using errcode = '42501';
  end if;
  if p_decision not in ('APPROVED','OBSERVED') then raise exception 'BAD_DECISION' using errcode = '22023'; end if;
  if p_decision = 'OBSERVED' and coalesce(trim(p_note), '') = '' then
    raise exception 'NOTE_REQUIRED: para solicitar aclaración hay que indicar el motivo' using errcode = '23514';
  end if;
  update public.route_approval_requests set status = p_decision, reviewed_by = auth.uid(), reviewed_at = now(), review_note = p_note, updated_at = now()
   where id = p_request;
  update public.routes set approval_status = case p_decision when 'APPROVED' then 'APROBADA' else 'OBSERVADA' end where id = q.route_id;
  insert into public.audit_log(actor_id, action, target_type, target_id, before, after)
  values (auth.uid(), case p_decision when 'APPROVED' then 'INTERNAL_ROUTE_APPROVED' else 'INTERNAL_ROUTE_OBSERVED' end, 'route', q.route_id::text,
          jsonb_build_object('status', q.status), jsonb_build_object('status', p_decision, 'note', p_note));
end; $$;

-- =====================================================================
-- RLS de las tablas nuevas
-- =====================================================================
alter table public.route_change_events enable row level security;
alter table public.route_approval_requests enable row level security;

create policy route_change_events_read on public.route_change_events for select to authenticated
  using (public.auth_has_perm('routes.view_all') or public.auth_has_perm('can_approve_internal_route_changes')
         or exists (select 1 from public.routes r where r.id = route_id and r.responsable_id = auth.uid()));
create policy route_approval_read on public.route_approval_requests for select to authenticated
  using (requested_by = auth.uid() or supervisor_user_id = auth.uid()
         or public.auth_has_perm('can_approve_internal_route_changes') or public.auth_has_perm('routes.view_all'));

grant select on public.route_change_events, public.route_approval_requests to authenticated;

-- Funciones solo para el servidor (service_role)
revoke execute on function public.set_user_carriers(uuid, text[]) from public, authenticated, anon;
revoke execute on function public.admin_create_profile(uuid, text, text, text, text, text, text[], uuid) from public, authenticated, anon;
revoke execute on function public.admin_update_profile(uuid, text, text, text, text, text[], boolean, uuid) from public, authenticated, anon;
revoke execute on function public.reassign_active_routes(uuid, uuid) from public, authenticated, anon;
revoke execute on function public.revoke_user_sessions(uuid) from public, authenticated, anon;
revoke execute on function public._valid_carriers(text[]) from public, authenticated, anon;
grant execute on function public.set_user_carriers(uuid, text[]), public.admin_create_profile(uuid, text, text, text, text, text, text[], uuid),
  public.admin_update_profile(uuid, text, text, text, text, text[], boolean, uuid), public.reassign_active_routes(uuid, uuid),
  public.revoke_user_sessions(uuid), public._valid_carriers(text[]), public.user_has_perm(uuid, text) to service_role;
-- Funciones que validan permisos por dentro
grant execute on function public.user_active_routes(uuid), public.request_route_approval(uuid, int, int), public.review_route_approval(uuid, text, text) to authenticated, service_role;
revoke execute on function public.user_has_perm(uuid, text) from public, anon;
