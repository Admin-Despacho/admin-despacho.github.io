DO $work_local_only$ BEGIN IF current_setting('port') NOT IN ('55447','55449') THEN RAISE EXCEPTION 'SOLO_QA_LOCAL'; END IF; END $work_local_only$;
-- Simulación mínima del entorno de Supabase para probar la migración y las políticas RLS
-- en un PostgreSQL local. NO reemplaza la prueba en un proyecto Supabase real.
do $$ begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role nologin bypassrls; end if;
end $$;
create schema if not exists auth;
create table if not exists auth.users (id uuid primary key, email text);
create or replace function auth.uid() returns uuid language sql stable as
$$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
create or replace function auth.role() returns text language sql stable as
$$ select nullif(current_setting('request.jwt.claim.role', true), '') $$;
grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.role() to anon, authenticated, service_role;
grant select, insert, update, delete on auth.users to service_role;

-- ===== Agregados para Fase 1.1 (equivalentes a lo que Supabase ya tiene) =====
alter table auth.users add column if not exists last_sign_in_at timestamptz;
create table if not exists auth.sessions (id uuid primary key default gen_random_uuid(), user_id uuid references auth.users(id) on delete cascade, created_at timestamptz default now());
-- auth.jwt(): claims del token (en Supabase lo arma PostgREST a partir del JWT)
create or replace function auth.jwt() returns jsonb language sql stable as
$$ select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb,
                    jsonb_build_object('sub', current_setting('request.jwt.claim.sub', true), 'role', current_setting('request.jwt.claim.role', true))) $$;
grant execute on function auth.jwt() to anon, authenticated, service_role;
grant select, insert, update, delete on auth.sessions to service_role;

-- ===== RC1: esquema mínimo de Supabase Storage (en Supabase ya existe) =====
create schema if not exists storage;
create table if not exists storage.buckets (id text primary key, name text, public boolean default false, file_size_limit bigint, allowed_mime_types text[]);
create table if not exists storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text references storage.buckets(id), name text, owner uuid default auth.uid(), metadata jsonb, created_at timestamptz default now(), unique (bucket_id, name));
alter table storage.objects enable row level security;
grant usage on schema storage to authenticated, service_role, anon;
grant select, insert, update, delete on storage.objects to authenticated, service_role;
grant select on storage.buckets to authenticated, service_role;

-- Comunicaciones: Vault simulado, exclusivamente en el PostgreSQL temporal de pruebas.
-- SOLO PARA PRUEBAS LOCALES. En Supabase, Vault ya está instalado (extensión supabase_vault) y cifra los secretos.
-- Esta simulación reproduce su API (create_secret / update_secret / decrypted_secrets) y su aislamiento (sin acceso para usuarios).
create schema if not exists vault;
create table if not exists vault.secrets (id uuid primary key default gen_random_uuid(), name text unique, description text, secret text not null);
create or replace function vault.create_secret(new_secret text, new_name text default null, new_description text default '') returns uuid language sql as $$
  insert into vault.secrets(name, description, secret) values (new_name, new_description, new_secret) returning id $$;
create or replace function vault.update_secret(secret_id uuid, new_secret text default null, new_name text default null, new_description text default null) returns void language sql as $$
  update vault.secrets set secret = coalesce(new_secret, secret) where id = secret_id $$;
create or replace view vault.decrypted_secrets as select id, name, description, secret as decrypted_secret from vault.secrets;
revoke all on schema vault from public, anon, authenticated;


;
-- SOLO PARA EL ARNÉS LOCAL. Objetos que existen en el proyecto Supabase real pero que NO crea ninguna migración del repo
-- (drift detectado al aplicar desde cero). No se despliega. Cada entrada debería resolverse con una migración que lo cree/documente.
-- 1) public.rls_auto_enable(): la referencia 20261030000100_rc4_1_2_revoke_internal_function_execute.sql (REVOKE EXECUTE).
create or replace function public.rls_auto_enable() returns event_trigger language plpgsql as $$ begin null; end $$;


;
-- =====================================================================
-- OK DESPACHO ONLINE — FASE 1
-- Usuarios, roles, permisos granulares, carriers, auditoría y
-- regla de RESPONSABLE compatible (validada en el servidor).
-- Proyecto Supabase PROPIO de OK Despacho (independiente de MAGIC).
-- =====================================================================

-- ---------- Catálogos ----------
create table if not exists public.roles (
  code text primary key,
  name text not null
);

create table if not exists public.permissions (
  code text primary key
);

create table if not exists public.role_permissions (
  role_code text not null references public.roles(code) on delete cascade,
  permission_code text not null references public.permissions(code) on delete cascade,
  primary key (role_code, permission_code)
);

create table if not exists public.carriers (
  id text primary key,
  name text not null,
  kind text not null check (kind in ('INTERNO','EXTERNO')),
  active boolean not null default true
);

-- ---------- Usuarios ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  email text not null unique,
  phone text,
  role text not null references public.roles(code),
  status text not null default 'INVITACION_PENDIENTE'
    check (status in ('ACTIVO','DESHABILITADO','ARCHIVADO','INVITACION_PENDIENTE')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_sign_in_at timestamptz,
  archived_at timestamptz,
  created_by uuid
);

create table if not exists public.user_carriers (
  user_id uuid not null references public.profiles(id) on delete cascade,
  carrier_id text not null references public.carriers(id),
  primary key (user_id, carrier_id)
);

create table if not exists public.audit_log (
  id bigserial primary key,
  at timestamptz not null default now(),
  actor_id uuid,
  action text not null,
  target_type text not null,
  target_id text,
  before jsonb,
  after jsonb
);

-- ---------- Hojas (mínimo de Fase 1; la Fase 2 agrega publicación, versiones, etc.) ----------
create table if not exists public.routes (
  id uuid primary key default gen_random_uuid(),
  number text,
  carrier_id text not null references public.carriers(id),
  responsable_id uuid references public.profiles(id),
  status text not null default 'BORRADOR',
  created_by uuid,
  created_at timestamptz not null default now()
);

-- =====================================================================
-- Funciones de seguridad
-- =====================================================================

-- ¿El usuario que llama está ACTIVO y tiene este permiso?
create or replace function public.auth_has_perm(p_perm text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.profiles p
    join public.role_permissions rp on rp.role_code = p.role
    where p.id = auth.uid() and p.status = 'ACTIVO' and rp.permission_code = p_perm
  );
$$;

-- ¿Puede este usuario ser responsable de una hoja de este carrier?
--  · INTERNO → usuario ACTIVO con rol TRANSPORTISTA_INTERNO
--  · EXTERNO → usuario ACTIVO vinculado a ese carrier
create or replace function public.can_be_responsable(p_user uuid, p_carrier text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1
    from public.profiles p
    join public.carriers c on c.id = p_carrier and c.active
    where p.id = p_user
      and p.status = 'ACTIVO'
      and (
        (c.kind = 'INTERNO' and p.role = 'TRANSPORTISTA_INTERNO')
        or (c.kind = 'EXTERNO' and p.role in ('TRANSPORTISTA','TRANSPORTISTA_INTERNO')
            and exists (select 1 from public.user_carriers uc where uc.user_id = p.id and uc.carrier_id = c.id))
      )
  );
$$;

-- Lista para el selector de RESPONSABLE: el servidor decide quién es compatible.
create or replace function public.responsables_disponibles(p_carrier text)
returns table (id uuid, full_name text, role text)
language plpgsql stable security definer set search_path = public
as $$
begin
  if not public.auth_has_perm('routes.assign') then
    raise exception 'FORBIDDEN: falta permiso routes.assign' using errcode = '42501';
  end if;
  return query
    select p.id, p.full_name, p.role
    from public.profiles p
    where public.can_be_responsable(p.id, p_carrier)
    order by p.full_name;
end;
$$;

-- ¿Tiene historial operativo? (decide ELIMINAR DEFINITIVAMENTE vs ARCHIVAR)
create or replace function public.user_has_history(p_user uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (select 1 from public.routes r where r.responsable_id = p_user or r.created_by = p_user)
      or exists (select 1 from public.audit_log a where a.actor_id = p_user);
$$;

-- =====================================================================
-- Triggers de protección (corren también cuando escribe la Edge Function)
-- =====================================================================

-- Hojas: el responsable debe ser compatible con el carrier. No depende de la pantalla.
create or replace function public.trg_routes_responsable_compatible()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if new.responsable_id is not null and not public.can_be_responsable(new.responsable_id, new.carrier_id) then
    raise exception 'RESPONSABLE_INCOMPATIBLE: el usuario no puede recibir hojas de %', new.carrier_id using errcode = '23514';
  end if;
  return new;
end;
$$;
drop trigger if exists routes_responsable_compatible on public.routes;
create trigger routes_responsable_compatible
  before insert or update of responsable_id, carrier_id on public.routes
  for each row execute function public.trg_routes_responsable_compatible();

-- Perfiles: nadie cambia su propio rol/estado/email; el último ADMIN activo no se pierde.
create or replace function public.trg_profiles_protect()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  is_service boolean := coalesce(auth.role(), '') = 'service_role';
  active_admins int;
begin
  if tg_op = 'UPDATE' then
    if not is_service then
      -- Desde la app, un usuario solo puede editar su nombre y teléfono.
      if new.role is distinct from old.role or new.status is distinct from old.status
         or new.email is distinct from old.email or new.id is distinct from old.id then
        raise exception 'FORBIDDEN: rol, estado y email solo se cambian desde Administración (servidor)' using errcode = '42501';
      end if;
    end if;
    if old.role = 'ADMIN' and old.status = 'ACTIVO'
       and (new.role <> 'ADMIN' or new.status <> 'ACTIVO') then
      select count(*) into active_admins from public.profiles where role = 'ADMIN' and status = 'ACTIVO';
      if active_admins <= 1 then
        raise exception 'LAST_ADMIN: es el último administrador activo' using errcode = '23514';
      end if;
    end if;
    new.updated_at := now();
  elsif tg_op = 'DELETE' then
    if old.role = 'ADMIN' and old.status = 'ACTIVO' then
      select count(*) into active_admins from public.profiles where role = 'ADMIN' and status = 'ACTIVO';
      if active_admins <= 1 then
        raise exception 'LAST_ADMIN: es el último administrador activo' using errcode = '23514';
      end if;
    end if;
    if public.user_has_history(old.id) then
      raise exception 'HAS_HISTORY: el usuario tiene historial; se archiva, no se elimina' using errcode = '23514';
    end if;
    return old;
  end if;
  return new;
end;
$$;
drop trigger if exists profiles_protect on public.profiles;
create trigger profiles_protect
  before update or delete on public.profiles
  for each row execute function public.trg_profiles_protect();

-- =====================================================================
-- RLS
-- =====================================================================
alter table public.roles enable row level security;
alter table public.permissions enable row level security;
alter table public.role_permissions enable row level security;
alter table public.carriers enable row level security;
alter table public.profiles enable row level security;
alter table public.user_carriers enable row level security;
alter table public.audit_log enable row level security;
alter table public.routes enable row level security;

-- Catálogos: lectura para usuarios autenticados.
create policy roles_read on public.roles for select to authenticated using (true);
create policy permissions_read on public.permissions for select to authenticated using (true);
create policy role_permissions_read on public.role_permissions for select to authenticated using (true);
create policy carriers_read on public.carriers for select to authenticated using (true);
create policy carriers_write on public.carriers for all to authenticated
  using (public.auth_has_perm('settings.manage')) with check (public.auth_has_perm('settings.manage'));

-- Perfiles: cada uno ve el suyo; users.view ve todos. Alta/baja SOLO por la Edge Function (service_role).
create policy profiles_read on public.profiles for select to authenticated
  using (id = auth.uid() or public.auth_has_perm('users.view'));
create policy profiles_update_self on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- Carriers de cada usuario: el propio o users.view. Escritura solo servidor.
create policy user_carriers_read on public.user_carriers for select to authenticated
  using (user_id = auth.uid() or public.auth_has_perm('users.view'));

-- Auditoría: solo lectura con audit.view. Se escribe desde el servidor.
create policy audit_read on public.audit_log for select to authenticated
  using (public.auth_has_perm('audit.view'));

-- Hojas: quien tiene routes.view_all ve todas; el responsable ve las suyas.
create policy routes_read on public.routes for select to authenticated
  using (public.auth_has_perm('routes.view_all') or (responsable_id = auth.uid() and public.auth_has_perm('routes.view_assigned')));
create policy routes_insert on public.routes for insert to authenticated
  with check (public.auth_has_perm('routes.create'));
create policy routes_update on public.routes for update to authenticated
  using (public.auth_has_perm('routes.assign')) with check (public.auth_has_perm('routes.assign'));

grant usage on schema public to authenticated;
grant select on public.roles, public.permissions, public.role_permissions, public.carriers, public.profiles, public.user_carriers, public.audit_log, public.routes to authenticated;
grant update (full_name, phone) on public.profiles to authenticated;
grant insert, update on public.routes to authenticated;
grant insert, update, delete on public.carriers to authenticated;
grant execute on function public.auth_has_perm(text), public.can_be_responsable(uuid, text), public.responsables_disponibles(text) to authenticated;
revoke execute on function public.user_has_history(uuid) from public;

-- =====================================================================
-- Datos iniciales
-- =====================================================================
insert into public.roles(code, name) values
  ('ADMIN','Administración'), ('DESPACHO','Despacho'), ('TRANSPORTISTA','Transportista'),
  ('TRANSPORTISTA_INTERNO','Transportista interno'), ('SOLO_LECTURA','Solo lectura')
on conflict (code) do nothing;

insert into public.permissions(code) values
  ('users.view'),('users.manage'),('routes.create'),('routes.publish'),('routes.assign'),('routes.view_all'),('routes.view_assigned'),
  ('deliveries.update'),('deliveries.capture_signature'),('internal_routes.use'),('internal_routes.manage'),
  ('locations.view'),('locations.manage'),('signatures.view'),('audit.view'),('settings.manage')
on conflict (code) do nothing;

insert into public.role_permissions(role_code, permission_code)
  select 'ADMIN', code from public.permissions
on conflict do nothing;
insert into public.role_permissions(role_code, permission_code) values
  ('DESPACHO','routes.create'),('DESPACHO','routes.publish'),('DESPACHO','routes.assign'),('DESPACHO','routes.view_all'),
  ('DESPACHO','internal_routes.manage'),('DESPACHO','locations.view'),('DESPACHO','signatures.view'),
  ('TRANSPORTISTA','routes.view_assigned'),('TRANSPORTISTA','deliveries.update'),('TRANSPORTISTA','deliveries.capture_signature'),
  ('TRANSPORTISTA_INTERNO','routes.view_assigned'),('TRANSPORTISTA_INTERNO','internal_routes.use'),
  ('TRANSPORTISTA_INTERNO','deliveries.update'),('TRANSPORTISTA_INTERNO','deliveries.capture_signature'),
  ('SOLO_LECTURA','routes.view_all')
on conflict do nothing;

insert into public.carriers(id, name, kind) values
  ('INTERNO','TRANSPORTE INTERNO','INTERNO'),
  ('CT-ESTE','CRISTIAN TORRES - ESTE','EXTERNO'),
  ('CT-ALR','CRISTIAN TORRES - ALREDEDORES','EXTERNO'),
  ('UCO','UCO','EXTERNO'), ('VASCA','VASCA','EXTERNO'), ('ANDESMAR','ANDESMAR','EXTERNO'), ('MARCHETTI','MARCHETTI','EXTERNO')
on conflict (id) do nothing;

;
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

;
-- =====================================================================
-- OK DESPACHO ONLINE — FASE 2A (incremental): INFORME COMERCIAL CRISTIAN TORRES
-- · Paradas de hoja con resultado (ENTREGADO / ENTREGA_PARCIAL / NO_ENTREGADO / REPROGRAMAR) y tarifa congelada
-- · Costo mensual con vigencias · Configuración de envío · Informes con snapshot inmutable · Emails idempotentes
-- · Permisos y RLS. No modifica migraciones anteriores.
-- =====================================================================

-- ---------- Permisos ----------
insert into public.permissions(code) values ('can_view_commercial_transport_reports'), ('can_manage_commercial_transport_reports') on conflict do nothing;
insert into public.role_permissions(role_code, permission_code) values
  ('ADMIN','can_view_commercial_transport_reports'), ('ADMIN','can_manage_commercial_transport_reports') on conflict do nothing;

-- ---------- Carriers que forman "Cristian Torres" ----------
alter table public.carriers add column if not exists report_group text;
update public.carriers set report_group = 'CRISTIAN_TORRES' where id in ('CT-ESTE','CT-ALR');

-- ---------- Paradas de la hoja (las completa el recorrido en Fase 2B) ----------
create table if not exists public.route_stops (
  id uuid primary key default gen_random_uuid(),
  route_id uuid not null references public.routes(id) on delete restrict,
  seq int not null,
  client_name text not null,
  client_key text,
  zone text not null check (zone in ('ESTE','ALREDEDORES','CENTRO')),
  order_numbers text[] not null default '{}',
  merchandise_amount numeric(14,2) not null default 0,     -- mercadería: NUNCA es ingreso de transporte
  merchandise_collected numeric(14,2) not null default 0,  -- cobranza: NUNCA es ingreso de transporte
  shipping_fee numeric(14,2) not null default 0,           -- tarifa de envío CONGELADA al publicar
  outcome text not null default 'PENDIENTE' check (outcome in ('PENDIENTE','ENTREGADO','ENTREGA_PARCIAL','NO_ENTREGADO','REPROGRAMAR')),
  outcome_at timestamptz,
  created_at timestamptz not null default now(),
  unique (route_id, seq)
);
create index if not exists route_stops_route_idx on public.route_stops(route_id);
create index if not exists routes_completed_idx on public.routes(operational_status, completed_at);

-- ---------- Costo mensual con vigencia histórica ----------
create table if not exists public.transport_cost_settings (
  id bigserial primary key,
  carrier_group text not null,
  monthly_cost numeric(14,2) not null check (monthly_cost > 0),
  valid_from date not null,
  valid_to date,
  created_by uuid,
  created_at timestamptz not null default now(),
  unique (carrier_group, valid_from)
);
insert into public.transport_cost_settings(carrier_group, monthly_cost, valid_from) values ('CRISTIAN_TORRES', 1600000, '2026-01-01')
on conflict do nothing;

-- Nueva vigencia: cierra la anterior el día previo; nunca reescribe períodos pasados ya informados.
create or replace function public.set_transport_cost(p_group text, p_monthly_cost numeric, p_valid_from date, p_by uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' and not public.auth_has_perm('can_manage_commercial_transport_reports') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_monthly_cost <= 0 then raise exception 'BAD_COST' using errcode = '22023'; end if;
  update public.transport_cost_settings set valid_to = p_valid_from - 1
   where carrier_group = p_group and valid_from < p_valid_from and (valid_to is null or valid_to >= p_valid_from);
  insert into public.transport_cost_settings(carrier_group, monthly_cost, valid_from, created_by)
  values (p_group, p_monthly_cost, p_valid_from, p_by)
  on conflict (carrier_group, valid_from) do update set monthly_cost = excluded.monthly_cost, created_by = excluded.created_by;
end; $$;

-- ---------- Configuración de envío del informe ----------
create table if not exists public.report_settings (
  id text primary key,
  recipients text[] not null default '{}',
  weekly_day int not null default 6,          -- sábado
  weekly_time text not null default '15:00',  -- America/Argentina/Mendoza
  monthly_time text not null default '23:30', -- último día del mes calendario
  require_pdf boolean not null default true,
  timezone text not null default 'America/Argentina/Mendoza'
);
insert into public.report_settings(id) values ('CRISTIAN_TORRES') on conflict do nothing;

-- ---------- Informes (snapshot inmutable) ----------
create table if not exists public.commercial_reports (
  id uuid primary key default gen_random_uuid(),
  report_type text not null check (report_type in ('WEEKLY','MONTHLY','MANUAL')),
  period_start date not null,
  period_end date not null,
  version int not null default 1,
  generated_at timestamptz not null default now(),
  generated_by uuid,
  snapshot jsonb not null,
  pdf_status text not null default 'PENDING' check (pdf_status in ('PENDING','OK','PDF_ERROR')),
  pdf_path text,
  pdf_error text,
  unique (report_type, period_start, period_end, version)
);
-- El snapshot no se modifica nunca (histórico fiel aunque cambien costos o tarifas)
create or replace function public.trg_report_snapshot_immutable()
returns trigger language plpgsql as $$
begin
  if new.snapshot is distinct from old.snapshot or new.period_start is distinct from old.period_start
     or new.period_end is distinct from old.period_end or new.report_type is distinct from old.report_type or new.version is distinct from old.version then
    raise exception 'SNAPSHOT_INMUTABLE: un informe generado no se recalcula; generá una versión nueva' using errcode = '23514';
  end if;
  return new;
end; $$;
drop trigger if exists report_snapshot_immutable on public.commercial_reports;
create trigger report_snapshot_immutable before update on public.commercial_reports for each row execute function public.trg_report_snapshot_immutable();

-- ---------- Emails (idempotentes) ----------
create table if not exists public.report_emails (
  id uuid primary key default gen_random_uuid(),
  report_id uuid not null references public.commercial_reports(id) on delete restrict,
  recipient text not null,
  idempotency_key text not null unique,  -- report_type|period_start|period_end|recipient|vN[|reenvio-n]
  is_resend boolean not null default false,
  status text not null default 'QUEUED' check (status in ('QUEUED','SENT','ERROR','PDF_ERROR')),
  queued_at timestamptz not null default now(),
  sent_at timestamptz,
  provider_id text,
  error text,
  retry_count int not null default 0
);

-- =====================================================================
-- RLS: solo quien tiene permiso ve costos, informes y emails
-- =====================================================================
alter table public.route_stops enable row level security;
alter table public.transport_cost_settings enable row level security;
alter table public.report_settings enable row level security;
alter table public.commercial_reports enable row level security;
alter table public.report_emails enable row level security;

create policy route_stops_read on public.route_stops for select to authenticated
  using (exists (select 1 from public.routes r where r.id = route_id and (public.auth_has_perm('routes.view_all') or (r.responsable_id = auth.uid() and public.auth_has_perm('routes.view_assigned')))));
create policy cost_read on public.transport_cost_settings for select to authenticated
  using (public.auth_has_perm('can_view_commercial_transport_reports') or public.auth_has_perm('can_manage_commercial_transport_reports'));
create policy report_settings_read on public.report_settings for select to authenticated
  using (public.auth_has_perm('can_manage_commercial_transport_reports'));
create policy reports_read on public.commercial_reports for select to authenticated
  using (public.auth_has_perm('can_view_commercial_transport_reports') or public.auth_has_perm('can_manage_commercial_transport_reports'));
create policy report_emails_read on public.report_emails for select to authenticated
  using (public.auth_has_perm('can_manage_commercial_transport_reports'));

grant select on public.route_stops, public.transport_cost_settings, public.report_settings, public.commercial_reports, public.report_emails to authenticated;
revoke execute on function public.set_transport_cost(text, numeric, date, uuid) from public, anon;
grant execute on function public.set_transport_cost(text, numeric, date, uuid) to authenticated, service_role;
-- Escritura de informes, emails y paradas: solo el servidor (service_role / Edge Functions)

;
-- OK DESPACHO ONLINE — FASE 2A.1 (incremental): financiación propia, envío provisorio y confirmación server-side.

-- ---------- Importaciones fuente ----------
create table if not exists public.source_imports (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('PEDIDOS','SALDO_COMPROBANTE','CUENTA_CORRIENTE')),
  file_name text not null, file_hash text, rows int, imported_by uuid, imported_at timestamptz not null default now()
);

-- ---------- Financiación propia: grupos y partes (por comprobante + cliente + importación) ----------
create table if not exists public.financial_document_groups (
  id uuid primary key default gen_random_uuid(),
  source_import_id uuid not null references public.source_imports(id),
  comp_normalized text not null, client_key text not null, client_name text, client_cuit text,
  classification text not null check (classification in ('NORMAL','FINANCIACION_PROPIA_VIGENTE','FINANCIACION_PROPIA_SALDADA','POSIBLE_FINANCIACION_REVISAR')),
  parts_count int not null, pending_count int, settled_count int, duplicates int not null default 0,
  total_pending numeric(14,2), resolver_version text not null,
  created_at timestamptz not null default now(),
  unique (source_import_id, comp_normalized, client_key)
);
create table if not exists public.financial_document_parts (
  id bigserial primary key,
  group_id uuid not null references public.financial_document_groups(id) on delete cascade,
  due_date date, installment text, issue_date date, original_amount numeric(14,2), pending_amount numeric(14,2)
);
-- Suma de saldos pendientes de partes válidas; REVISAR no suma (NULL)
create or replace function public.trg_fin_group_check() returns trigger language plpgsql as $$
begin
  if new.classification = 'POSIBLE_FINANCIACION_REVISAR' and new.total_pending is not null then
    raise exception 'FIN_REVISAR_NO_SUMA: una posible financiación sin distinguir no se suma' using errcode = '23514';
  end if;
  if new.classification = 'FINANCIACION_PROPIA_SALDADA' and coalesce(new.total_pending, 0) > 0 then
    raise exception 'FIN_SALDADA_CON_SALDO' using errcode = '23514';
  end if;
  return new;
end; $$;
drop trigger if exists fin_group_check on public.financial_document_groups;
create trigger fin_group_check before insert or update on public.financial_document_groups for each row execute function public.trg_fin_group_check();

-- ---------- Snapshot del grupo financiero al publicar (una hoja histórica no cambia con un Excel posterior) ----------
create table if not exists public.route_financing_snapshots (
  id bigserial primary key,
  route_id uuid not null references public.routes(id),
  route_version int not null,
  comp text not null, client_name text, client_cuit text,
  parts_count int, parts jsonb not null, total numeric(14,2), classification text not null,
  source_import_id uuid, resolver_version text not null,
  created_at timestamptz not null default now(),
  unique (route_id, route_version, comp)
);
create or replace function public.trg_snapshot_immutable_generic() returns trigger language plpgsql as $$
begin raise exception 'SNAPSHOT_INMUTABLE' using errcode = '23514'; end; $$;
drop trigger if exists route_financing_snapshot_immutable on public.route_financing_snapshots;
create trigger route_financing_snapshot_immutable before update on public.route_financing_snapshots for each row execute function public.trg_snapshot_immutable_generic();

-- ---------- Confirmación de costo de envío provisorio ----------
create table if not exists public.shipping_amount_confirmations (
  id uuid primary key default gen_random_uuid(),
  sheet_key text not null,                 -- hoja (borrador) hasta que se publique
  route_id uuid references public.routes(id), route_version int,
  ship_order text not null, ship_doc text, main_order text, carrier_id text,
  source_import_id text, fingerprint text not null,
  detected_amount numeric(14,2) not null check (detected_amount > 0),
  confirmed_amount numeric(14,2),
  source text not null default 'INFORME_PEDIDOS',
  status text not null default 'PENDING_CONFIRMATION'
    check (status in ('PENDING_CONFIRMATION','CONFIRMED','MODIFIED_CONFIRMED','INVALIDATED','RESOLVED_BY_SALDO','DIFFERENCE_REVIEW')),
  confirmed_by uuid, confirmed_at timestamptz, reason text, note text,
  created_at timestamptz not null default now()
);
-- Una sola confirmación activa por hoja y pedido de envío
create unique index if not exists shipping_conf_active on public.shipping_amount_confirmations(sheet_key, ship_order) where status <> 'INVALIDATED';

create or replace function public.confirm_shipping_amount(p jsonb)
returns public.shipping_amount_confirmations language plpgsql security definer set search_path = public as $$
declare cur public.shipping_amount_confirmations; det numeric := (p->>'detected_amount')::numeric; amt numeric := (p->>'confirmed_amount')::numeric;
        changed boolean; res public.shipping_amount_confirmations;
begin
  if not public.auth_has_perm('routes.create') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if amt is null or amt <= 0 or det is null or det <= 0 then raise exception 'BAD_AMOUNT' using errcode = '22023'; end if;
  changed := abs(amt - det) > 0.004;
  if changed and coalesce(trim(p->>'reason'), '') = '' then raise exception 'REASON_REQUIRED: para cambiar el importe hay que indicar el motivo' using errcode = '23514'; end if;
  select * into cur from public.shipping_amount_confirmations where sheet_key = p->>'sheet_key' and ship_order = p->>'ship_order' and status <> 'INVALIDATED' for update;
  -- Doble clic / reintento: misma confirmación → no se duplica
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

-- Si cambia NDP, pedido, costo, asociación, transportista o importación: la confirmación deja de valer
create or replace function public.invalidate_shipping_confirmation(p_sheet_key text, p_ship_order text, p_fingerprint text)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.auth_has_perm('routes.create') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  update public.shipping_amount_confirmations set status = 'INVALIDATED'
   where sheet_key = p_sheet_key and ship_order = p_ship_order and status <> 'INVALIDATED' and fingerprint <> p_fingerprint;
  get diagnostics n = row_count; return n;
end; $$;

-- La NDP real apareció: si coincide se resuelve; si difiere queda para revisar (no se pisa)
create or replace function public.reconcile_shipping_with_saldo(p_id uuid, p_saldo numeric, p_tolerance numeric default 1)
returns text language plpgsql security definer set search_path = public as $$
declare cur public.shipping_amount_confirmations; ref numeric;
begin
  if not public.auth_has_perm('routes.create') and coalesce(auth.role(),'') <> 'service_role' then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into cur from public.shipping_amount_confirmations where id = p_id for update;
  ref := coalesce(cur.confirmed_amount, cur.detected_amount);
  update public.shipping_amount_confirmations set status = case when abs(p_saldo - ref) <= p_tolerance then 'RESOLVED_BY_SALDO' else 'DIFFERENCE_REVIEW' end
   where id = p_id;
  return case when abs(p_saldo - ref) <= p_tolerance then 'RESOLVED_BY_SALDO' else 'DIFFERENCE_REVIEW' end;
end; $$;

-- Puerta para PUBLICAR (Fase 2B): no se publica con envíos pendientes o en diferencia
create or replace function public.assert_sheet_shipping_ready(p_sheet_key text, p_ship_orders text[])
returns void language plpgsql stable security definer set search_path = public as $$
declare missing text;
begin
  select string_agg(o, ', ') into missing from unnest(p_ship_orders) o
   where not exists (select 1 from public.shipping_amount_confirmations c where c.sheet_key = p_sheet_key and c.ship_order = o and c.status in ('CONFIRMED','MODIFIED_CONFIRMED','RESOLVED_BY_SALDO'));
  if missing is not null then raise exception 'SHIPPING_PENDING: envíos sin confirmar: %', missing using errcode = '23514'; end if;
end; $$;

-- ---------- Informe: la tarifa congelada nunca puede ser un provisorio sin confirmar ----------
alter table public.route_stops add column if not exists shipping_fee_source text not null default 'SALDO'
  check (shipping_fee_source in ('SALDO','CONFIRMED_FALLBACK'));

-- ---------- RLS ----------
alter table public.source_imports enable row level security;
alter table public.financial_document_groups enable row level security;
alter table public.financial_document_parts enable row level security;
alter table public.route_financing_snapshots enable row level security;
alter table public.shipping_amount_confirmations enable row level security;
create policy source_imports_read on public.source_imports for select to authenticated using (public.auth_has_perm('routes.create') or public.auth_has_perm('routes.view_all'));
create policy fin_groups_read on public.financial_document_groups for select to authenticated using (public.auth_has_perm('routes.create') or public.auth_has_perm('routes.view_all'));
create policy fin_parts_read on public.financial_document_parts for select to authenticated using (public.auth_has_perm('routes.create') or public.auth_has_perm('routes.view_all'));
create policy fin_snap_read on public.route_financing_snapshots for select to authenticated using (public.auth_has_perm('routes.view_all'));
create policy ship_conf_read on public.shipping_amount_confirmations for select to authenticated using (public.auth_has_perm('routes.create') or public.auth_has_perm('routes.view_all'));
grant select on public.source_imports, public.financial_document_groups, public.financial_document_parts, public.route_financing_snapshots, public.shipping_amount_confirmations to authenticated;
revoke execute on function public.confirm_shipping_amount(jsonb), public.invalidate_shipping_confirmation(text, text, text), public.reconcile_shipping_with_saldo(uuid, numeric, numeric), public.assert_sheet_shipping_ready(text, text[]) from public, anon;
grant execute on function public.confirm_shipping_amount(jsonb), public.invalidate_shipping_confirmation(text, text, text), public.reconcile_shipping_with_saldo(uuid, numeric, numeric), public.assert_sheet_shipping_ready(text, text[]) to authenticated, service_role;

;
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

;
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

;
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

;
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

;
-- OK DESPACHO ONLINE — RC1 (incremental): foto de DNI en Supabase Storage PRIVADO.
-- En la base queda solo: cuil, storage_path, mime, registered_by, registered_at.
-- Compatibilidad: los registros viejos con dni_photo (bytea) se conservan tal cual (columna legacy, nula para los nuevos);
-- no se inventan rutas. Para moverlos (proyecto real, con service role): subir cada foto a identity-docs/<cuil>/<uuid>.jpg,
-- poner storage_path y luego dni_photo = null. Hasta entonces siguen siendo visibles solo con identity_docs.view.

-- ---------- Bucket privado (5 MB, JPEG/PNG) ----------
insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('identity-docs', 'identity-docs', false, 5242880, array['image/jpeg','image/png'])
on conflict (id) do update set public = false, file_size_limit = 5242880, allowed_mime_types = array['image/jpeg','image/png'];

-- ---------- Tabla: ruta en Storage en vez de la foto ----------
alter table public.customer_identity_docs add column if not exists storage_path text;
alter table public.customer_identity_docs alter column dni_photo drop not null;
alter table public.customer_identity_docs drop constraint if exists identity_doc_source;
alter table public.customer_identity_docs add constraint identity_doc_source check (storage_path is not null or dni_photo is not null);
alter table public.customer_identity_docs drop constraint if exists identity_doc_mime;
alter table public.customer_identity_docs add constraint identity_doc_mime check (mime in ('image/jpeg','image/png'));
comment on column public.customer_identity_docs.dni_photo is 'LEGACY (RC1): solo registros anteriores. Los nuevos usan storage_path en el bucket privado identity-docs.';

-- ---------- Políticas de Storage ----------
-- Subir: solo quien captura evidencia (chofer en su recorrido) y dentro de la carpeta del CUIL. Nunca descargar.
drop policy if exists identity_docs_upload on storage.objects;
create policy identity_docs_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'identity-docs' and public.auth_has_perm('deliveries.capture_signature') and name ~ '^[0-9]{11}/[0-9a-f-]{36}\.(jpg|png)$');
-- Ver / URL firmada temporal: solo identity_docs.view
drop policy if exists identity_docs_read on storage.objects;
create policy identity_docs_read on storage.objects for select to authenticated
  using (bucket_id = 'identity-docs' and public.auth_has_perm('identity_docs.view'));

-- Valida que el archivo subido exista, sea del usuario, del CUIL, JPEG/PNG y ≤ 5 MB
create or replace function public._identity_upload_ok(p_cuil text, p_path text) returns text language plpgsql stable security definer set search_path = public, storage as $$
declare o record; sz bigint; mt text;
begin
  if p_path !~ ('^' || p_cuil || '/[0-9a-f-]{36}\.(jpg|png)$') then return 'BAD_PATH'; end if;
  select * into o from storage.objects where bucket_id = 'identity-docs' and name = p_path;
  if not found then return 'NOT_UPLOADED'; end if;
  if o.owner is distinct from auth.uid() then return 'NOT_OWNER'; end if;
  mt := coalesce(o.metadata->>'mimetype', '');
  sz := coalesce((o.metadata->>'size')::bigint, 0);
  if mt not in ('image/jpeg','image/png') then return 'BAD_TYPE'; end if;
  if sz <= 0 or sz > 5242880 then return 'BAD_SIZE'; end if;
  return null;
end; $$;

-- set_stop_outcome: misma lógica 2B.3; la foto del DNI ahora llega como ruta de Storage (dni_storage_path)
create or replace function public._register_identity(p_cuil text, ev jsonb) returns void language plpgsql security definer set search_path = public as $$
declare chk text;
begin
  if coalesce(ev->>'dni_photo_b64', '') <> '' then raise exception 'DNI_STORAGE_REQUIRED: la foto del DNI se sube a Storage privado' using errcode = '23514'; end if;
  if coalesce(ev->>'dni_storage_path', '') = '' or exists (select 1 from public.customer_identity_docs d where d.cuil = p_cuil) then return; end if;
  chk := public._identity_upload_ok(p_cuil, ev->>'dni_storage_path');
  if chk is not null then raise exception 'DNI_UPLOAD_INVALID: %', chk using errcode = '23514'; end if;
  insert into public.customer_identity_docs(cuil, storage_path, mime, registered_by)
  values (p_cuil, ev->>'dni_storage_path', (select metadata->>'mimetype' from storage.objects where bucket_id = 'identity-docs' and name = ev->>'dni_storage_path'), auth.uid())
  on conflict (cuil) do nothing;
end; $$;
revoke execute on function public._identity_upload_ok(text, text), public._register_identity(text, jsonb) from public, anon, authenticated;

-- Nueva versión de set_stop_outcome (idéntica a 2B.3 salvo el registro del DNI)
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
      perform public._register_identity(v_cuil, ev);   -- RC1: DNI en Storage privado
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

;
-- OK DESPACHO ONLINE — RC1.1 (incremental): módulos por usuario (restricción server-side), historial real y borrado completo.

-- ---------- Módulos: cada permiso pertenece a un módulo ----------
create table if not exists public.module_permissions (module text not null, permission_code text not null references public.permissions(code), primary key (module, permission_code));
insert into public.module_permissions(module, permission_code) values
 ('DESPACHO','routes.create'),('DESPACHO','routes.publish'),('DESPACHO','routes.assign'),('DESPACHO','routes.view_all'),('DESPACHO','internal_routes.manage'),
 ('DESPACHO','locations.view'),('DESPACHO','signatures.view'),('DESPACHO','routes.manage_all_drafts'),('DESPACHO','collections.manage'),
 ('MIS_HOJAS','routes.view_assigned'),('MIS_HOJAS','deliveries.update'),('MIS_HOJAS','deliveries.capture_signature'),('MIS_HOJAS','internal_routes.use'),
 ('USUARIOS','users.view'),('USUARIOS','users.manage'),
 ('INFORMES','can_view_commercial_transport_reports'),('INFORMES','can_manage_commercial_transport_reports'),
 ('APROBACIONES','can_approve_internal_route_changes'),
 ('CONFIGURACION','settings.manage'),('CONFIGURACION','vehicles.manage'),('CONFIGURACION','locations.manage'),
 ('AUDITORIA','audit.view'),('AUDITORIA','identity_docs.view')
on conflict do nothing;
alter table public.module_permissions enable row level security;
create policy module_permissions_read on public.module_permissions for select to authenticated using (true);
grant select on public.module_permissions to authenticated;

-- Restricción por usuario: SOLO resta módulos al rol (nunca agrega permisos)
alter table public.profiles add column if not exists disabled_modules text[] not null default '{}';
alter table public.profiles drop constraint if exists profiles_disabled_modules_valid;
alter table public.profiles add constraint profiles_disabled_modules_valid check (disabled_modules <@ array['DESPACHO','MIS_HOJAS','USUARIOS','INFORMES','APROBACIONES','CONFIGURACION','AUDITORIA']);

-- Permiso efectivo = rol − módulos restringidos (y sesión vigente). Lo usan TODAS las RPC y políticas RLS.
create or replace function public.auth_has_perm(p_perm text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.profiles p
    join public.role_permissions rp on rp.role_code = p.role
    where p.id = auth.uid() and p.status = 'ACTIVO' and rp.permission_code = p_perm
      and (p.sessions_revoked_at is null or coalesce((auth.jwt() ->> 'iat')::numeric, 0) > extract(epoch from p.sessions_revoked_at))
      and not exists (select 1 from public.module_permissions mp where mp.permission_code = p_perm and mp.module = any(p.disabled_modules))
  );
$$;
create or replace function public.user_has_perm(p_user uuid, p_perm text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles p join public.role_permissions rp on rp.role_code = p.role
                 where p.id = p_user and p.status = 'ACTIVO' and rp.permission_code = p_perm
                   and not exists (select 1 from public.module_permissions mp where mp.permission_code = p_perm and mp.module = any(p.disabled_modules)));
$$;
-- Módulos efectivos del usuario actual (para el menú; el servidor igual valida cada acción)
create or replace function public.my_modules() returns text[] language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(distinct mp.module order by mp.module), '{}') from public.module_permissions mp where public.auth_has_perm(mp.permission_code);
$$;
grant execute on function public.my_modules() to authenticated;
-- Lo cambia solo Administración (Edge Function); no permite que un admin se bloquee USUARIOS a sí mismo
create or replace function public.admin_set_disabled_modules(p_user uuid, p_modules text[]) returns void language plpgsql security definer set search_path = public as $$
begin
  update public.profiles set disabled_modules = coalesce(p_modules, '{}') where id = p_user;
end; $$;
revoke execute on function public.admin_set_disabled_modules(uuid, text[]) from public, anon, authenticated;
grant execute on function public.admin_set_disabled_modules(uuid, text[]) to service_role;
-- disabled_modules solo lo cambia el servidor
create or replace function public.trg_profiles_modules_guard() returns trigger language plpgsql as $$
begin
  if new.disabled_modules is distinct from old.disabled_modules and coalesce(auth.role(), '') <> 'service_role' and current_user not in ('postgres','supabase_admin') then
    raise exception 'FORBIDDEN: los módulos los cambia Administración' using errcode = '42501';
  end if;
  return new;
end; $$;
drop trigger if exists profiles_modules_guard on public.profiles;
create trigger profiles_modules_guard before update of disabled_modules on public.profiles for each row execute function public.trg_profiles_modules_guard();

-- ---------- Historial operativo real (decide ELIMINAR vs ARCHIVAR) ----------
-- Aceptar la invitación, cambiar la contraseña o usar passkeys NO es historial operativo.
create or replace function public.user_has_history(p_user uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.routes r where p_user in (r.responsable_id, r.created_by, r.published_by, r.started_by, r.completed_by))
      or exists (select 1 from public.route_stops s where p_user in (s.outcome_by, s.added_by))
      or exists (select 1 from public.route_change_events e where e.user_id = p_user)
      or exists (select 1 from public.route_approval_requests q where p_user in (q.reviewed_by, q.requested_by))
      or exists (select 1 from public.shipping_amount_confirmations c where c.confirmed_by = p_user)
      or exists (select 1 from public.stop_evidence ev where ev.created_by = p_user)
      or exists (select 1 from public.commercial_reports cr where cr.generated_by = p_user)
      or exists (select 1 from public.audit_log a where a.actor_id = p_user and a.action not in
           ('INVITE_ACCEPTED','OWN_PASSWORD_CHANGED','PASSKEY_REGISTERED','PASSKEY_LOGIN','PASSKEY_REVOKED','PASSWORD_RESET_REQUESTED','SESSIONS_REVOKED'));
$$;

-- Borrado completo de un usuario SIN historial: datos auxiliares (borradores sin publicar, reservas, notificaciones, desafíos, passkeys)
create or replace function public.trg_profiles_purge_aux() returns trigger language plpgsql security definer set search_path = public as $$
begin
  delete from public.order_reservations where sheet_key in (select client_sheet_key from public.route_drafts where owner_id = old.id and route_id is null);
  delete from public.shipping_amount_confirmations where sheet_key in (select client_sheet_key from public.route_drafts where owner_id = old.id and route_id is null) and confirmed_by is null;
  delete from public.route_drafts where owner_id = old.id and route_id is null;
  delete from public.notifications where user_id = old.id;
  delete from public.webauthn_challenges where user_id = old.id;
  delete from public.user_passkeys where user_id = old.id;
  return old;
end; $$;
drop trigger if exists profiles_purge_aux on public.profiles;
-- corre después de las validaciones de profiles_protect (orden alfabético de triggers: profiles_protect < profiles_purge_aux)
create trigger profiles_purge_aux before delete on public.profiles for each row execute function public.trg_profiles_purge_aux();

;
-- OK DESPACHO ONLINE — RC1.2 (incremental): PDF automático al publicar, versionado y privado.

-- ---------- Configuración CONFIGURACIÓN → DESPACHO → PDF ----------
create table if not exists public.dispatch_settings (
  id text primary key default 'DEFAULT',
  pdf_auto_generate boolean not null default true,
  pdf_auto_download boolean not null default true
);
insert into public.dispatch_settings(id) values ('DEFAULT') on conflict do nothing;
alter table public.dispatch_settings enable row level security;
create policy dispatch_settings_read on public.dispatch_settings for select to authenticated using (public.auth_has_perm('routes.create') or public.auth_has_perm('settings.manage'));
grant select on public.dispatch_settings to authenticated;
create or replace function public.set_dispatch_settings(p_auto_generate boolean, p_auto_download boolean) returns public.dispatch_settings language plpgsql security definer set search_path = public as $$
declare s public.dispatch_settings;
begin
  if not public.auth_has_perm('settings.manage') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  update public.dispatch_settings set pdf_auto_generate = coalesce(p_auto_generate, pdf_auto_generate), pdf_auto_download = coalesce(p_auto_download, pdf_auto_download) where id = 'DEFAULT' returning * into s;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'DISPATCH_PDF_SETTINGS', 'settings', 'DEFAULT', to_jsonb(s));
  return s;
end; $$;
grant execute on function public.set_dispatch_settings(boolean, boolean) to authenticated;

-- ---------- PDF de cada versión publicada (uno lógico por hoja + versión; nunca se sobrescribe un OK) ----------
create table if not exists public.route_pdfs (
  id uuid primary key default gen_random_uuid(),
  route_id uuid not null references public.routes(id), route_version int not null, route_number text not null,
  file_name text not null, storage_path text,
  status text not null default 'PENDING' check (status in ('PENDING','OK','PDF_ERROR')), error text, attempts int not null default 0,
  generated_at timestamptz, generated_by uuid,
  unique (route_id, route_version)
);
alter table public.route_pdfs enable row level security;
create policy route_pdfs_read on public.route_pdfs for select to authenticated
  using (public.auth_has_perm('routes.view_all') or exists (select 1 from public.routes r where r.id = route_id and r.responsable_id = auth.uid()));
grant select on public.route_pdfs to authenticated;

-- Registra el resultado (OK con la ruta en Storage, o PDF_ERROR). Idempotente: reintentos no crean otro PDF lógico.
create or replace function public.register_route_pdf(p_route uuid, p_version int, p_path text, p_error text) returns public.route_pdfs language plpgsql security definer set search_path = public, storage as $$
declare r public.routes; x public.route_pdfs; fname text;
begin
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
grant execute on function public.register_route_pdf(uuid, int, text, text) to authenticated;
-- Snapshot publicado (para regenerar SIEMPRE desde lo publicado, nunca desde datos vivos)
create or replace function public.route_pdf_snapshot(p_route uuid) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r public.routes;
begin
  if not public.auth_has_perm('routes.publish') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into r from public.routes where id = p_route;
  return jsonb_build_object('number', r.number, 'version', r.version, 'pdf_model', r.sheet_snapshot->'pdf_model');
end; $$;
grant execute on function public.route_pdf_snapshot(uuid) to authenticated;

-- ---------- Storage privado route-pdfs ----------
insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('route-pdfs', 'route-pdfs', false, 10485760, array['application/pdf'])
on conflict (id) do update set public = false, file_size_limit = 10485760, allowed_mime_types = array['application/pdf'];
-- Subir: quien publica, en <route_id>/v<n>/Hoja_<correlativo>_v<n>.pdf (sin sobrescribir: no hay política de update/delete)
drop policy if exists route_pdfs_upload on storage.objects;
create policy route_pdfs_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'route-pdfs' and public.auth_has_perm('routes.publish') and name ~ '^[0-9a-f-]{36}/v[0-9]+/Hoja_[0-9]{2}-[0-9]{6}_v[0-9]+\.pdf$');
-- Descargar (URL firmada temporal): Despacho/lectura con routes.view_all o el responsable de la hoja
drop policy if exists route_pdfs_read on storage.objects;
create policy route_pdfs_read on storage.objects for select to authenticated
  using (bucket_id = 'route-pdfs' and (public.auth_has_perm('routes.view_all')
    or exists (select 1 from public.routes r where r.id::text = split_part(name, '/', 1) and r.responsable_id = auth.uid())));

;
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

;
-- OK DESPACHO ONLINE — RC2 (incremental): NOC con consumo único server-side + reglas financieras vigentes obligatorias al publicar.
-- No modifica Cianbox: solo registra el uso de las NOC dentro de OK Despacho.

insert into public.permissions(code) values ('credit_notes.manage') on conflict do nothing;
insert into public.role_permissions(role_code, permission_code) values ('ADMIN','credit_notes.manage') on conflict do nothing;
insert into public.module_permissions(module, permission_code) values ('CONFIGURACION','credit_notes.manage') on conflict do nothing;

-- Huella estable: cliente + comprobante + fecha de emisión (normalizados). No incluye el saldo: aunque el saldo de la NOC
-- cambie entre un Excel y otro, sigue siendo la MISMA NOC (así no se puede volver a usar como si fuera nueva).
create or replace function public.noc_fingerprint(p_client text, p_comp text, p_date text) returns text language sql immutable as $$
  select encode(sha256(convert_to(upper(regexp_replace(coalesce(p_client,''), '\s+', '', 'g')) || '|' || upper(regexp_replace(coalesce(p_comp,''), '\s+', '', 'g')) || '|' || coalesce(p_date,''), 'UTF8')), 'hex');
$$;

create table if not exists public.credit_notes (
  fingerprint text primary key, client_key text not null, comp text not null, issued_date text, original_amount numeric(14,2) not null check (original_amount > 0),
  remaining_amount numeric(14,2) not null check (remaining_amount >= 0),
  status text not null default 'DISPONIBLE' check (status in ('DISPONIBLE','PARCIAL','CONSUMIDA','IGNORADA','RECHAZADA')),
  reason text, decided_by uuid, decided_at timestamptz, created_by uuid, created_at timestamptz not null default now()
);
create table if not exists public.credit_note_applications (
  id uuid primary key default gen_random_uuid(), fingerprint text not null references public.credit_notes(fingerprint), sheet_key text not null, route_id uuid references public.routes(id),
  amount numeric(14,2) not null check (amount > 0), status text not null default 'RESERVED' check (status in ('RESERVED','CONSUMED','RELEASED')),
  op_id text unique, created_by uuid, created_at timestamptz not null default now()
);
create table if not exists public.credit_note_events (
  id bigserial primary key, fingerprint text not null, event text not null check (event in ('ACCEPTED','CONSUMED','RELEASED','IGNORED','REJECTED')),
  amount numeric(14,2), sheet_key text, route_id uuid, actor uuid, at timestamptz not null default now(), detail jsonb
);
alter table public.credit_notes enable row level security; alter table public.credit_note_applications enable row level security; alter table public.credit_note_events enable row level security;
create policy cn_read on public.credit_notes for select to authenticated using (public.auth_has_perm('routes.create') or public.auth_has_perm('credit_notes.manage'));
create policy cna_read on public.credit_note_applications for select to authenticated using (public.auth_has_perm('routes.create') or public.auth_has_perm('credit_notes.manage'));
create policy cne_read on public.credit_note_events for select to authenticated using (public.auth_has_perm('credit_notes.manage') or public.auth_has_perm('audit.view'));
grant select on public.credit_notes, public.credit_note_applications, public.credit_note_events to authenticated;

create or replace function public._noc_status(rem numeric, orig numeric, cur text) returns text language sql immutable as $$
  select case when cur in ('IGNORADA','RECHAZADA') then cur when rem <= 0.004 then 'CONSUMIDA' when rem < orig - 0.004 then 'PARCIAL' else 'DISPONIBLE' end;
$$;

-- Aceptación EXPLÍCITA del operador para una hoja borrador suya. Saldo CC = piso: el cobro nunca queda por debajo del saldo de la CC.
-- Consumo único: la fila de la NOC se bloquea (FOR UPDATE) y el remanente se descuenta al reservar; un reintento (op_id) no descuenta dos veces.
create or replace function public.apply_credit_note(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare fp text; n public.credit_notes; d public.route_drafts; a public.credit_note_applications; allowed numeric; applied numeric;
        req numeric := (p->>'amount')::numeric; ord numeric := (p->>'order_amount')::numeric; cc numeric := coalesce((p->>'cc_saldo')::numeric, 0);
begin
  if not public.auth_has_perm('routes.create') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if coalesce((p->>'accept')::boolean, false) is not true then raise exception 'NOC_NOT_ACCEPTED: la NOC se aplica solo con aceptación explícita' using errcode = '23514'; end if;
  d := public._draft(p->>'sheet_key', true);
  select * into a from public.credit_note_applications where op_id = p->>'op_id';
  if found then select * into n from public.credit_notes where fingerprint = a.fingerprint;
    return jsonb_build_object('fingerprint', a.fingerprint, 'applied', a.amount, 'remaining', n.remaining_amount, 'status', n.status, 'repeated', true); end if;
  if req is null or req <= 0 or ord is null or ord < 0 then raise exception 'BAD_AMOUNT' using errcode = '22023'; end if;
  fp := public.noc_fingerprint(p->>'client_key', p->>'comp', p->>'issued_date');
  insert into public.credit_notes(fingerprint, client_key, comp, issued_date, original_amount, remaining_amount, created_by)
  values (fp, p->>'client_key', p->>'comp', p->>'issued_date', (p->>'original_amount')::numeric, (p->>'original_amount')::numeric, auth.uid()) on conflict (fingerprint) do nothing;
  select * into n from public.credit_notes where fingerprint = fp for update;
  if n.status in ('IGNORADA','RECHAZADA') then raise exception 'NOC_BLOCKED: Administración marcó esta NOC como %', n.status using errcode = '23514'; end if;
  if n.remaining_amount <= 0.004 then raise exception 'NOC_CONSUMED: la NOC ya fue utilizada' using errcode = '23514'; end if;
  allowed := least(n.remaining_amount, greatest(0, ord - greatest(cc, 0)));
  if allowed <= 0.004 then raise exception 'NOC_FLOOR: el saldo de la cuenta corriente (%) es el piso del cobro', cc using errcode = '23514'; end if;
  applied := round(least(req, allowed), 2);
  insert into public.credit_note_applications(fingerprint, sheet_key, amount, op_id, created_by) values (fp, p->>'sheet_key', applied, p->>'op_id', auth.uid());
  update public.credit_notes set remaining_amount = remaining_amount - applied, status = public._noc_status(remaining_amount - applied, original_amount, status) where fingerprint = fp returning * into n;
  insert into public.credit_note_events(fingerprint, event, amount, sheet_key, actor, detail) values (fp, 'ACCEPTED', applied, p->>'sheet_key', auth.uid(), jsonb_build_object('requested', req, 'order_amount', ord, 'cc_saldo', cc));
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'NOC_ACCEPTED', 'credit_note', fp, jsonb_build_object('comp', n.comp, 'applied', applied, 'remaining', n.remaining_amount, 'sheet', p->>'sheet_key'));
  return jsonb_build_object('fingerprint', fp, 'applied', applied, 'remaining', n.remaining_amount, 'status', n.status, 'repeated', false);
end; $$;

-- Libera aplicaciones reservadas (deshacer, borrador eliminado, hoja cancelada o NOC bloqueada por Admin): el remanente vuelve
create or replace function public._release_noc(p_where text, p_value text, p_reason text) returns int language plpgsql security definer set search_path = public as $$
declare a record; n int := 0;
begin
  for a in execute format('select * from public.credit_note_applications where status in (''RESERVED'',''CONSUMED'') and %I = $1 for update', p_where) using p_value loop
    update public.credit_note_applications set status = 'RELEASED' where id = a.id;
    update public.credit_notes set remaining_amount = least(original_amount, remaining_amount + a.amount), status = public._noc_status(least(original_amount, remaining_amount + a.amount), original_amount, status) where fingerprint = a.fingerprint;
    insert into public.credit_note_events(fingerprint, event, amount, sheet_key, route_id, actor, detail) values (a.fingerprint, 'RELEASED', a.amount, a.sheet_key, a.route_id, auth.uid(), jsonb_build_object('reason', p_reason));
    n := n + 1;
  end loop;
  return n;
end; $$;
revoke execute on function public._release_noc(text, text, text) from public, anon, authenticated;
create or replace function public.release_credit_note(p_sheet_key text, p_fingerprint text) returns int language plpgsql security definer set search_path = public as $$
declare a record; n int := 0;
begin
  if not public.auth_has_perm('routes.create') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  perform public._draft(p_sheet_key, false);
  for a in select * from public.credit_note_applications where sheet_key = p_sheet_key and fingerprint = p_fingerprint and status = 'RESERVED' for update loop
    update public.credit_note_applications set status = 'RELEASED' where id = a.id;
    update public.credit_notes set remaining_amount = least(original_amount, remaining_amount + a.amount), status = public._noc_status(least(original_amount, remaining_amount + a.amount), original_amount, status) where fingerprint = a.fingerprint;
    insert into public.credit_note_events(fingerprint, event, amount, sheet_key, actor, detail) values (a.fingerprint, 'RELEASED', a.amount, a.sheet_key, auth.uid(), '{"reason":"deshacer"}');
    n := n + 1;
  end loop;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'NOC_RELEASED', 'credit_note', p_fingerprint, jsonb_build_object('sheet', p_sheet_key, 'n', n));
  return n;
end; $$;
-- Administración: ignorar o rechazar una NOC (con motivo). Libera lo reservado en borradores; lo consumido en hojas publicadas queda como historial.
create or replace function public.decide_credit_note(p_fingerprint text, p_decision text, p_reason text) returns public.credit_notes language plpgsql security definer set search_path = public as $$
declare n public.credit_notes; a record;
begin
  if not public.auth_has_perm('credit_notes.manage') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_decision not in ('IGNORADA','RECHAZADA') or coalesce(trim(p_reason), '') = '' then raise exception 'REASON_REQUIRED: indicá la decisión y el motivo' using errcode = '23514'; end if;
  select * into n from public.credit_notes where fingerprint = p_fingerprint for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  for a in select * from public.credit_note_applications where fingerprint = p_fingerprint and status = 'RESERVED' for update loop
    update public.credit_note_applications set status = 'RELEASED' where id = a.id;
    update public.credit_notes set remaining_amount = least(original_amount, remaining_amount + a.amount) where fingerprint = p_fingerprint;
    insert into public.credit_note_events(fingerprint, event, amount, sheet_key, actor, detail) values (p_fingerprint, 'RELEASED', a.amount, a.sheet_key, auth.uid(), jsonb_build_object('reason', 'NOC ' || p_decision));
  end loop;
  update public.credit_notes set status = p_decision, reason = p_reason, decided_by = auth.uid(), decided_at = now() where fingerprint = p_fingerprint returning * into n;
  insert into public.credit_note_events(fingerprint, event, actor, detail) values (p_fingerprint, case p_decision when 'IGNORADA' then 'IGNORED' else 'REJECTED' end, auth.uid(), jsonb_build_object('reason', p_reason));
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'NOC_' || p_decision, 'credit_note', p_fingerprint, jsonb_build_object('reason', p_reason));
  return n;
end; $$;
grant execute on function public.apply_credit_note(jsonb), public.release_credit_note(text, text), public.decide_credit_note(text, text, text), public.noc_fingerprint(text, text, text) to authenticated;

-- Al publicar: lo reservado en el borrador queda CONSUMIDO por la hoja. Al cancelar la hoja: se libera.
create or replace function public.trg_noc_on_draft_status() returns trigger language plpgsql security definer set search_path = public as $$
declare a record;
begin
  if new.status = 'PUBLICADA' and old.status = 'BORRADOR' then
    for a in update public.credit_note_applications set status = 'CONSUMED', route_id = new.route_id where sheet_key = new.client_sheet_key and status = 'RESERVED' returning * loop
      insert into public.credit_note_events(fingerprint, event, amount, sheet_key, route_id, actor) values (a.fingerprint, 'CONSUMED', a.amount, a.sheet_key, new.route_id, auth.uid());
    end loop;
  elsif new.status = 'CANCELADA' and old.status in ('BORRADOR','PUBLICADA') then
    perform public._release_noc('sheet_key', new.client_sheet_key, case when old.status = 'PUBLICADA' then 'hoja cancelada' else 'borrador eliminado' end);
  end if;
  return new;
end; $$;
drop trigger if exists noc_on_draft_status on public.route_drafts;
create trigger noc_on_draft_status after update of status on public.route_drafts for each row execute function public.trg_noc_on_draft_status();

-- Reglas financieras: una hoja calculada con una versión vieja de las reglas no se publica (hay que recalcular)
create or replace function public.trg_routes_rules_version() returns trigger language plpgsql as $$
declare cur int;
begin
  if new.sheet_snapshot ? 'rules_version' and new.sheet_snapshot->>'rules_version' is not null then
    select max(version) into cur from public.financial_rules;
    if (new.sheet_snapshot->>'rules_version')::int < cur then raise exception 'RULES_OUTDATED: las reglas financieras cambiaron (v%); recalculá la hoja antes de publicar', cur using errcode = '23514'; end if;
  end if;
  return new;
end; $$;
drop trigger if exists routes_rules_version on public.routes;
create trigger routes_rules_version before insert on public.routes for each row execute function public.trg_routes_rules_version();

;
-- OK DESPACHO ONLINE — RC2.1 (incremental): correcciones de auditoría.
-- P0-01 NOC: la NOC aceptada REDUCE el piso de Saldo CC.  P0-02 huella NOC completa.
-- P1-04 rules_version obligatorio y exacto.  P1-05 sin escritura directa en routes/carriers.  P1-10 ruta interna exige vehículo activo.

-- =====================================================================
-- P0-02 · Comprobante parseado de forma determinística + huella completa
-- Formatos aceptados (mayúsculas/espacios/ceros a la izquierda indistintos):  "NOC [X] 0020-00001340", "NOC X 20-1340", "noc[x]0020-00001340".
-- Si el comprobante no se puede separar en tipo/letra/punto de venta/número → se rechaza (no se inventa).
-- =====================================================================
create or replace function public.parse_comprobante(p text) returns table (tipo text, letra text, pv int, numero bigint) language plpgsql immutable as $$
declare m text[];
begin
  -- tipo de 3 letras; la letra va entre corchetes o separada por espacio (así "NOC 0020-…" sin letra NO se confunde con tipo "NO" + letra "C")
  m := regexp_match(upper(coalesce(p, '')), '^\s*([A-Z]{3})\s*(?:\[\s*([A-Z])\s*\]|\s([A-Z]))\s*0*(\d{1,5})\s*-\s*0*(\d{1,8})\s*$');
  if m is null then return; end if;
  tipo := m[1]; letra := coalesce(m[2], m[3]); pv := m[4]::int; numero := m[5]::bigint; return next;
end; $$;
drop function if exists public.noc_fingerprint(text, text, text);
-- tipo + letra + punto_de_venta + número + CUIT + fecha de emisión + importe original
create or replace function public.noc_fingerprint(p_tipo text, p_letra text, p_pv int, p_numero bigint, p_cuit text, p_fecha date, p_importe numeric) returns text language sql immutable as $$
  select encode(sha256(convert_to(upper(trim(p_tipo)) || '|' || upper(trim(p_letra)) || '|' || p_pv || '|' || p_numero || '|' || regexp_replace(coalesce(p_cuit, ''), '\D', '', 'g')
    || '|' || to_char(p_fecha, 'YYYY-MM-DD') || '|' || to_char(round(abs(p_importe), 2), 'FM999999999990.00'), 'UTF8')), 'hex');
$$;
grant execute on function public.parse_comprobante(text), public.noc_fingerprint(text, text, int, bigint, text, date, numeric) to authenticated, service_role;
alter table public.credit_notes add column if not exists tipo text;
alter table public.credit_notes add column if not exists letra text;
alter table public.credit_notes add column if not exists pv int;
alter table public.credit_notes add column if not exists numero bigint;
alter table public.credit_notes add column if not exists cuit text;

-- =====================================================================
-- P0-01 · NOC: Saldo CC es el piso POR DEFECTO; si el operador ACEPTA la NOC, el importe aceptado REDUCE ese piso.
-- Ejemplo: cobro 150.000, Saldo CC 150.000, NOC aceptada 30.000 → cobro efectivo 120.000.
-- Si no la acepta, no se llama a esta función y el piso sigue siendo el Saldo CC.
-- =====================================================================
create or replace function public.apply_credit_note(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare c record; fp text; n public.credit_notes; a public.credit_note_applications; applied numeric; prev numeric; v_cuit text := regexp_replace(coalesce(p->>'cuit', ''), '\D', '', 'g');
        req numeric := (p->>'amount')::numeric; ord numeric := (p->>'order_amount')::numeric; cc numeric := coalesce((p->>'cc_saldo')::numeric, 0); fecha date; orig numeric := abs((p->>'original_amount')::numeric);
begin
  if not public.auth_has_perm('routes.create') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if coalesce((p->>'accept')::boolean, false) is not true then raise exception 'NOC_NOT_ACCEPTED: la NOC se aplica solo con aceptación explícita' using errcode = '23514'; end if;
  perform public._draft(p->>'sheet_key', true);
  select * into a from public.credit_note_applications where op_id = p->>'op_id';
  if found then select * into n from public.credit_notes where fingerprint = a.fingerprint;
    return jsonb_build_object('fingerprint', a.fingerprint, 'applied', a.amount, 'remaining', n.remaining_amount, 'status', n.status, 'repeated', true); end if;
  select * into c from public.parse_comprobante(p->>'comp');
  if c.tipo is null then raise exception 'NOC_BAD_COMP: no se puede identificar tipo/letra/punto de venta/número de "%"', p->>'comp' using errcode = '22023'; end if;
  if c.tipo <> 'NOC' then raise exception 'NOC_BAD_COMP: el comprobante no es una NOC' using errcode = '22023'; end if;
  -- Identificación fiscal tal como figura en la columna CUIT del Saldo Comprobante: CUIT (11 dígitos) o, en consumidores finales, DNI (7–8 dígitos).
  -- No se completa ni se inventa: si falta o tiene otro largo, se rechaza.
  if length(v_cuit) not in (7, 8, 11) then raise exception 'NOC_MISSING_DATA: falta el CUIT/DNI del cliente (columna CUIT del Saldo Comprobante)' using errcode = '23514'; end if;
  begin fecha := (p->>'issued_date')::date; exception when others then fecha := null; end;
  if fecha is null then raise exception 'NOC_MISSING_DATA: falta la fecha de emisión de la NOC' using errcode = '23514'; end if;
  if orig is null or orig <= 0 then raise exception 'NOC_MISSING_DATA: falta el importe original de la NOC' using errcode = '23514'; end if;
  if req is null or req <= 0 or ord is null then raise exception 'BAD_AMOUNT' using errcode = '22023'; end if;
  if ord <= 0.004 then raise exception 'NOC_NOTHING_TO_COLLECT: no hay importe a cobrar para reducir' using errcode = '23514'; end if;
  fp := public.noc_fingerprint(c.tipo, c.letra, c.pv, c.numero, v_cuit, fecha, orig);
  insert into public.credit_notes(fingerprint, client_key, comp, issued_date, original_amount, remaining_amount, created_by, tipo, letra, pv, numero, cuit)
  values (fp, v_cuit, p->>'comp', to_char(fecha, 'YYYY-MM-DD'), orig, coalesce(nullif((p->>'available_amount'), '')::numeric, orig), auth.uid(), c.tipo, c.letra, c.pv, c.numero, v_cuit)
  on conflict (fingerprint) do nothing;
  select * into n from public.credit_notes where fingerprint = fp for update;
  if n.status in ('IGNORADA','RECHAZADA') then raise exception 'NOC_BLOCKED: Administración marcó esta NOC como %', n.status using errcode = '23514'; end if;
  if n.remaining_amount <= 0.004 then raise exception 'NOC_CONSUMED: la NOC ya fue utilizada' using errcode = '23514'; end if;
  applied := round(least(req, n.remaining_amount, ord), 2);   -- parcial: lo que queda de la NOC o lo que hay para cobrar
  select coalesce(sum(x.amount), 0) into prev from public.credit_note_applications x join public.credit_notes y on y.fingerprint = x.fingerprint
   where x.sheet_key = p->>'sheet_key' and x.status = 'RESERVED' and y.cuit = v_cuit;
  insert into public.credit_note_applications(fingerprint, sheet_key, amount, op_id, created_by) values (fp, p->>'sheet_key', applied, p->>'op_id', auth.uid());
  update public.credit_notes set remaining_amount = remaining_amount - applied, status = public._noc_status(remaining_amount - applied, original_amount, status) where fingerprint = fp returning * into n;
  insert into public.credit_note_events(fingerprint, event, amount, sheet_key, actor, detail)
  values (fp, 'ACCEPTED', applied, p->>'sheet_key', auth.uid(), jsonb_build_object('requested', req, 'order_amount', ord, 'cc_saldo', cc, 'floor_after', greatest(0, cc - prev - applied)));
  insert into public.audit_log(actor_id, action, target_type, target_id, after)
  values (auth.uid(), 'NOC_ACCEPTED', 'credit_note', fp, jsonb_build_object('comp', n.comp, 'applied', applied, 'remaining', n.remaining_amount, 'sheet', p->>'sheet_key', 'floor_before', cc - prev, 'floor_after', greatest(0, cc - prev - applied)));
  return jsonb_build_object('fingerprint', fp, 'applied', applied, 'remaining', n.remaining_amount, 'status', n.status, 'repeated', false,
    'floor_before', greatest(0, cc - prev), 'floor_after', greatest(0, cc - prev - applied), 'collect_after', round(ord - applied, 2));
end; $$;

-- =====================================================================
-- P1-04 · rules_version OBLIGATORIO y EXACTO (no depende del frontend)
-- =====================================================================
create or replace function public.trg_routes_rules_version() returns trigger language plpgsql as $$
declare cur int; v int;
begin
  if coalesce(auth.role(), '') <> 'authenticated' then return new; end if;  -- restauración/cargas técnicas: el histórico conserva su versión
  select max(version) into cur from public.financial_rules;
  if new.sheet_snapshot is null or not (new.sheet_snapshot ? 'rules_version') or new.sheet_snapshot->>'rules_version' is null then
    raise exception 'RULES_REQUIRED: la hoja debe calcularse con la versión vigente de las reglas financieras (v%)', cur using errcode = '23514'; end if;
  begin v := (new.sheet_snapshot->>'rules_version')::int; exception when others then raise exception 'RULES_UNKNOWN: versión de reglas inválida' using errcode = '23514'; end;
  if v < cur then raise exception 'RULES_OUTDATED: las reglas financieras cambiaron (v%); recalculá la hoja antes de publicar', cur using errcode = '23514'; end if;
  if v > cur then raise exception 'RULES_UNKNOWN: la versión de reglas v% no existe (vigente v%)', v, cur using errcode = '23514'; end if;
  return new;
end; $$;

-- =====================================================================
-- P1-05 · Sin escritura directa en routes ni carriers: solo RPCs controladas y auditadas
-- =====================================================================
drop policy if exists routes_insert on public.routes;
drop policy if exists routes_update on public.routes;
drop policy if exists carriers_write on public.carriers;
revoke insert, update, delete on public.routes from authenticated, anon;
revoke insert, update, delete on public.carriers from authenticated, anon;

-- =====================================================================
-- P1-10 · Ruta INTERNA: vehículo activo obligatorio (al publicar y, para hojas viejas, al iniciar)
-- =====================================================================
create or replace function public.trg_route_vehicle_from_snapshot() returns trigger language plpgsql security definer set search_path = public as $$
declare internal boolean;
begin
  if coalesce(auth.role(), '') <> 'authenticated' then return new; end if;  -- restauración/cargas técnicas
  internal := exists (select 1 from public.carriers where id = new.carrier_id and kind = 'INTERNO');
  if internal then
    if new.sheet_snapshot is null or coalesce(new.sheet_snapshot->>'vehicle_id', '') = '' then raise exception 'VEHICLE_REQUIRED: la ruta interna necesita un vehículo activo' using errcode = '23514'; end if;
    new.vehicle_id := (new.sheet_snapshot->>'vehicle_id')::uuid;
    select plate, name into new.vehicle_plate, new.vehicle_name from public.vehicles where id = new.vehicle_id and active;
    if new.vehicle_plate is null then raise exception 'BAD_VEHICLE: vehículo inexistente o inactivo' using errcode = '23514'; end if;
  end if;
  return new;
end; $$;
create or replace function public.trg_route_start_needs_vehicle() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce(auth.role(), '') <> 'authenticated' then return new; end if;
  if new.operational_status = 'EN_CURSO' and old.operational_status = 'PUBLICADA' and new.vehicle_id is null
     and exists (select 1 from public.carriers where id = new.carrier_id and kind = 'INTERNO') then
    raise exception 'VEHICLE_REQUIRED: la ruta interna necesita un vehículo activo para iniciar' using errcode = '23514'; end if;
  return new;
end; $$;
drop trigger if exists route_start_needs_vehicle on public.routes;
create trigger route_start_needs_vehicle before update on public.routes for each row execute function public.trg_route_start_needs_vehicle();

-- =====================================================================
-- ADDENDUM RC2.1 · NOC YA UTILIZADA / NO REUTILIZABLE
-- Importes explícitos (original, reservado, consumido, disponible), estados funcionales, destino (pedido / financiación),
-- detección server-side, reserva exclusiva por borrador, consumo definitivo al publicar, re-importación sin revivir saldo,
-- intentos duplicados registrados (la función devuelve el rechazo en vez de abortar, para que el evento quede guardado).
-- =====================================================================
alter table public.credit_notes add column if not exists reserved_amount numeric(14,2) not null default 0 check (reserved_amount >= 0);
alter table public.credit_notes add column if not exists consumed_amount numeric(14,2) not null default 0 check (consumed_amount >= 0);
alter table public.credit_notes add column if not exists destination text check (destination in ('PEDIDO_ACTUAL','FINANCIACION_PROPIA'));
alter table public.credit_notes drop constraint if exists credit_notes_status_check;
update public.credit_notes set status = case status when 'PARCIAL' then 'PARCIALMENTE_UTILIZADA' when 'CONSUMIDA' then 'UTILIZADA' else status end;
alter table public.credit_notes add constraint credit_notes_status_check check (status in ('DISPONIBLE','RESERVADA','PARCIALMENTE_UTILIZADA','UTILIZADA','IGNORADA','RECHAZADA'));
alter table public.credit_note_applications add column if not exists destination text not null default 'PEDIDO_ACTUAL' check (destination in ('PEDIDO_ACTUAL','FINANCIACION_PROPIA'));
alter table public.credit_note_applications add column if not exists reference text;
alter table public.credit_note_events drop constraint if exists credit_note_events_event_check;
update public.credit_note_events set event = case event when 'ACCEPTED' then 'RESERVADA' when 'CONSUMED' then 'APLICADA_PARCIAL' when 'RELEASED' then 'RESERVA_LIBERADA' when 'IGNORED' then 'IGNORADA' when 'REJECTED' then 'RECHAZADA' else event end;
alter table public.credit_note_events add constraint credit_note_events_event_check check (event in ('DETECTADA','RESERVADA','RESERVA_LIBERADA','APLICADA_PARCIAL','APLICADA_TOTAL','INTENTO_DUPLICADO_BLOQUEADO','IGNORADA','RECHAZADA'));
alter table public.credit_note_events add column if not exists remaining numeric(14,2);
alter table public.credit_note_events add column if not exists destination text;
alter table public.credit_note_events add column if not exists reference text;

-- Estado SIEMPRE derivado de los importes (salvo decisión de Administración)
create or replace function public.trg_credit_note_state() returns trigger language plpgsql as $$
begin
  if new.status in ('IGNORADA','RECHAZADA') then return new; end if;
  new.status := case when new.reserved_amount > 0.004 then 'RESERVADA'
                     when new.remaining_amount <= 0.004 and new.consumed_amount > 0.004 then 'UTILIZADA'
                     when new.consumed_amount > 0.004 then 'PARCIALMENTE_UTILIZADA'
                     else 'DISPONIBLE' end;
  return new;
end; $$;
drop trigger if exists credit_note_state on public.credit_notes;
create trigger credit_note_state before insert or update on public.credit_notes for each row execute function public.trg_credit_note_state();

create or replace function public._noc_event(p_fp text, p_event text, p_amount numeric, p_sheet text, p_route uuid, p_dest text, p_ref text, p_detail jsonb) returns void language plpgsql security definer set search_path = public as $$
declare n public.credit_notes;
begin
  select * into n from public.credit_notes where fingerprint = p_fp;
  insert into public.credit_note_events(fingerprint, event, amount, sheet_key, route_id, actor, detail, remaining, destination, reference)
  values (p_fp, p_event, p_amount, p_sheet, p_route, auth.uid(), p_detail, n.remaining_amount, p_dest, p_ref);
  insert into public.audit_log(actor_id, action, target_type, target_id, after)
  values (auth.uid(), 'NOC_' || p_event, 'credit_note', p_fp, coalesce(p_detail, '{}'::jsonb) || jsonb_build_object('amount', p_amount, 'remaining', n.remaining_amount, 'destination', p_dest, 'reference', p_ref, 'sheet', p_sheet));
end; $$;
revoke execute on function public._noc_event(text, text, numeric, text, uuid, text, text, jsonb) from public, anon, authenticated;

-- Identidad de una NOC a partir de los datos de la fuente (mismas reglas que apply_credit_note)
create or replace function public._noc_identity(p jsonb) returns jsonb language plpgsql immutable as $$
declare c record; v_cuit text := regexp_replace(coalesce(p->>'cuit', ''), '\D', '', 'g'); f date; o numeric := abs((p->>'original_amount')::numeric);
begin
  select * into c from public.parse_comprobante(p->>'comp');
  if c.tipo is null or c.tipo <> 'NOC' then return jsonb_build_object('error', 'NOC_BAD_COMP'); end if;
  if length(v_cuit) not in (7, 8, 11) then return jsonb_build_object('error', 'NOC_MISSING_DATA'); end if;
  begin f := (p->>'issued_date')::date; exception when others then f := null; end;
  if f is null or o is null or o <= 0 then return jsonb_build_object('error', 'NOC_MISSING_DATA'); end if;
  return jsonb_build_object('fingerprint', public.noc_fingerprint(c.tipo, c.letra, c.pv, c.numero, v_cuit, f, o), 'tipo', c.tipo, 'letra', c.letra, 'pv', c.pv, 'numero', c.numero, 'cuit', v_cuit, 'fecha', to_char(f, 'YYYY-MM-DD'), 'original', o);
end; $$;

-- DETECCIÓN: registra (o reconoce) cada NOC del archivo y devuelve su estado REAL. Re-importar NUNCA revive saldo (insert ... on conflict do nothing).
create or replace function public.detect_credit_notes(p_sheet_key text, p_items jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare it jsonb; idn jsonb; n public.credit_notes; out jsonb := '[]'; last record; other record; ins boolean;
begin
  if not public.auth_has_perm('routes.create') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  for it in select * from jsonb_array_elements(coalesce(p_items, '[]')) loop
    idn := public._noc_identity(it);
    if idn ? 'error' then out := out || jsonb_build_array(jsonb_build_object('comp', it->>'comp', 'error', idn->>'error')); continue; end if;
    insert into public.credit_notes(fingerprint, client_key, comp, issued_date, original_amount, remaining_amount, created_by, tipo, letra, pv, numero, cuit)
    values (idn->>'fingerprint', idn->>'cuit', it->>'comp', idn->>'fecha', (idn->>'original')::numeric,
            least((idn->>'original')::numeric, coalesce(nullif(it->>'available_amount', '')::numeric, (idn->>'original')::numeric)), auth.uid(),
            idn->>'tipo', idn->>'letra', (idn->>'pv')::int, (idn->>'numero')::bigint, idn->>'cuit')
    on conflict (fingerprint) do nothing returning true into ins;
    if ins then perform public._noc_event(idn->>'fingerprint', 'DETECTADA', null, p_sheet_key, null, null, null, jsonb_build_object('comp', it->>'comp')); end if;
    select * into n from public.credit_notes where fingerprint = idn->>'fingerprint';
    select a.created_at, a.destination, a.reference, r.number into last from public.credit_note_applications a left join public.routes r on r.id = a.route_id
      where a.fingerprint = n.fingerprint and a.status = 'CONSUMED' order by a.created_at desc limit 1;
    select a.sheet_key, d.name, p.full_name into other from public.credit_note_applications a left join public.route_drafts d on d.client_sheet_key = a.sheet_key left join public.profiles p on p.id = a.created_by
      where a.fingerprint = n.fingerprint and a.status = 'RESERVED' and a.sheet_key <> p_sheet_key limit 1;
    out := out || jsonb_build_array(jsonb_build_object('comp', it->>'comp', 'fingerprint', n.fingerprint, 'status', n.status, 'original', n.original_amount, 'reserved', n.reserved_amount,
      'consumed', n.consumed_amount, 'available', n.remaining_amount, 'destination', n.destination,
      'mine', (select coalesce(sum(amount), 0) from public.credit_note_applications where fingerprint = n.fingerprint and sheet_key = p_sheet_key and status = 'RESERVED'),
      'reserved_elsewhere', other.sheet_key is not null,
      'reserved_by', case when other.sheet_key is not null then coalesce('borrador "' || other.name || '"', 'otro borrador') || coalesce(' · ' || other.full_name, '') end,
      'used_at', last.created_at, 'used_destination', last.destination, 'used_reference', coalesce('hoja ' || last.number, last.reference)));
  end loop;
  return out;
end; $$;

-- RESERVA (aceptación explícita). Exclusiva por borrador; consumo único; destino fijo. Los intentos inválidos por uso previo
-- devuelven { ok:false, code } y quedan registrados (INTENTO_DUPLICADO_BLOQUEADO).
create or replace function public.apply_credit_note(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare idn jsonb; fp text; n public.credit_notes; a public.credit_note_applications; applied numeric; prev numeric; dest text := coalesce(nullif(p->>'destination', ''), 'PEDIDO_ACTUAL');
        req numeric := (p->>'amount')::numeric; ord numeric := (p->>'order_amount')::numeric; cc numeric := coalesce((p->>'cc_saldo')::numeric, 0); other text; code text; msg text;
begin
  if not public.auth_has_perm('routes.create') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if coalesce((p->>'accept')::boolean, false) is not true then raise exception 'NOC_NOT_ACCEPTED: la NOC se aplica solo con aceptación explícita' using errcode = '23514'; end if;
  if dest not in ('PEDIDO_ACTUAL','FINANCIACION_PROPIA') then raise exception 'BAD_DESTINATION' using errcode = '22023'; end if;
  if dest = 'PEDIDO_ACTUAL' then perform public._draft(p->>'sheet_key', true); end if;
  select * into a from public.credit_note_applications where op_id = p->>'op_id';
  if found then select * into n from public.credit_notes where fingerprint = a.fingerprint;
    return jsonb_build_object('ok', true, 'fingerprint', a.fingerprint, 'applied', a.amount, 'remaining', n.remaining_amount, 'status', n.status, 'repeated', true); end if;
  idn := public._noc_identity(p);
  if idn->>'error' = 'NOC_BAD_COMP' then raise exception 'NOC_BAD_COMP: no se puede identificar tipo/letra/punto de venta/número de "%"', p->>'comp' using errcode = '22023'; end if;
  if idn->>'error' = 'NOC_MISSING_DATA' then raise exception 'NOC_MISSING_DATA: faltan CUIT/DNI, fecha de emisión o importe original de la NOC' using errcode = '23514'; end if;
  if req is null or req <= 0 or ord is null then raise exception 'BAD_AMOUNT' using errcode = '22023'; end if;
  if ord <= 0.004 then raise exception 'NOC_NOTHING_TO_COLLECT: no hay importe a cobrar para reducir' using errcode = '23514'; end if;
  fp := idn->>'fingerprint';
  insert into public.credit_notes(fingerprint, client_key, comp, issued_date, original_amount, remaining_amount, created_by, tipo, letra, pv, numero, cuit)
  values (fp, idn->>'cuit', p->>'comp', idn->>'fecha', (idn->>'original')::numeric, least((idn->>'original')::numeric, coalesce(nullif(p->>'available_amount', '')::numeric, (idn->>'original')::numeric)),
          auth.uid(), idn->>'tipo', idn->>'letra', (idn->>'pv')::int, (idn->>'numero')::bigint, idn->>'cuit')
  on conflict (fingerprint) do nothing;
  select * into n from public.credit_notes where fingerprint = fp for update;   -- bloqueo de fila: dos sesiones no reservan a la vez
  select a2.sheet_key into other from public.credit_note_applications a2 where a2.fingerprint = fp and a2.status = 'RESERVED' and a2.sheet_key <> coalesce(p->>'sheet_key', '') limit 1;
  code := case when n.status in ('IGNORADA','RECHAZADA') then 'NOC_BLOCKED'
               when n.remaining_amount <= 0.004 and n.reserved_amount <= 0.004 then 'NOC_CONSUMED'
               when other is not null then 'NOC_RESERVED_ELSEWHERE'
               when n.destination is not null and n.destination <> dest then 'NOC_DESTINATION_LOCKED'
               when n.remaining_amount <= 0.004 then 'NOC_CONSUMED' end;
  if code is not null then
    msg := case code when 'NOC_BLOCKED' then 'Administración marcó esta NOC como ' || n.status when 'NOC_CONSUMED' then 'NOTA DE CRÉDITO YA UTILIZADA'
           when 'NOC_RESERVED_ELSEWHERE' then 'NOTA DE CRÉDITO RESERVADA EN OTRO BORRADOR' else 'La NOC ya se usó en ' || n.destination || ' y no puede usarse en otro destino' end;
    perform public._noc_event(fp, 'INTENTO_DUPLICADO_BLOQUEADO', req, p->>'sheet_key', null, dest, p->>'reference', jsonb_build_object('code', code, 'op_id', p->>'op_id'));
    return jsonb_build_object('ok', false, 'code', code, 'message', msg, 'fingerprint', fp, 'status', n.status, 'original', n.original_amount, 'consumed', n.consumed_amount, 'available', n.remaining_amount);
  end if;
  applied := round(least(req, n.remaining_amount, ord), 2);
  select coalesce(sum(x.amount), 0) into prev from public.credit_note_applications x join public.credit_notes y on y.fingerprint = x.fingerprint
   where x.sheet_key = p->>'sheet_key' and x.status = 'RESERVED' and y.cuit = n.cuit;
  insert into public.credit_note_applications(fingerprint, sheet_key, amount, op_id, created_by, destination, reference)
  values (fp, coalesce(p->>'sheet_key', 'FIN:' || coalesce(p->>'reference', '')), applied, p->>'op_id', auth.uid(), dest, coalesce(p->>'reference', p->>'sheet_key'));
  update public.credit_notes set remaining_amount = remaining_amount - applied, reserved_amount = reserved_amount + applied, destination = coalesce(destination, dest) where fingerprint = fp returning * into n;
  perform public._noc_event(fp, 'RESERVADA', applied, p->>'sheet_key', null, dest, coalesce(p->>'reference', p->>'sheet_key'),
    jsonb_build_object('requested', req, 'order_amount', ord, 'cc_saldo', cc, 'floor_before', greatest(0, cc - prev), 'floor_after', greatest(0, cc - prev - applied)));
  return jsonb_build_object('ok', true, 'fingerprint', fp, 'applied', applied, 'remaining', n.remaining_amount, 'status', n.status, 'repeated', false,
    'floor_before', greatest(0, cc - prev), 'floor_after', greatest(0, cc - prev - applied), 'collect_after', round(ord - applied, 2));
end; $$;

-- Consumo definitivo (publicar la hoja o confirmar el plan de financiación)
create or replace function public._consume_noc_apps(p_where text, p_value text, p_route uuid) returns int language plpgsql security definer set search_path = public as $$
declare a record; n public.credit_notes; k int := 0;
begin
  for a in execute format('select * from public.credit_note_applications where status = ''RESERVED'' and %I::text = $1 for update', p_where) using p_value loop
    update public.credit_note_applications set status = 'CONSUMED', route_id = coalesce(p_route, route_id) where id = a.id;
    update public.credit_notes set reserved_amount = greatest(0, reserved_amount - a.amount), consumed_amount = consumed_amount + a.amount where fingerprint = a.fingerprint returning * into n;
    perform public._noc_event(a.fingerprint, case when n.remaining_amount <= 0.004 and n.reserved_amount <= 0.004 then 'APLICADA_TOTAL' else 'APLICADA_PARCIAL' end, a.amount, a.sheet_key, p_route, a.destination,
      coalesce((select 'hoja ' || number from public.routes where id = p_route), a.reference), null);
    k := k + 1;
  end loop;
  return k;
end; $$;
-- Libera SOLO lo reservado (nunca lo consumido)
create or replace function public._release_noc(p_where text, p_value text, p_reason text) returns int language plpgsql security definer set search_path = public as $$
declare a record; k int := 0;
begin
  for a in execute format('select * from public.credit_note_applications where status = ''RESERVED'' and %I::text = $1 for update', p_where) using p_value loop
    update public.credit_note_applications set status = 'RELEASED' where id = a.id;
    update public.credit_notes set reserved_amount = greatest(0, reserved_amount - a.amount), remaining_amount = least(original_amount, remaining_amount + a.amount),
           destination = case when consumed_amount > 0.004 or reserved_amount - a.amount > 0.004 then destination end where fingerprint = a.fingerprint;
    perform public._noc_event(a.fingerprint, 'RESERVA_LIBERADA', a.amount, a.sheet_key, a.route_id, a.destination, a.reference, jsonb_build_object('reason', p_reason));
    k := k + 1;
  end loop;
  return k;
end; $$;
revoke execute on function public._consume_noc_apps(text, text, uuid), public._release_noc(text, text, text) from public, anon, authenticated;
create or replace function public.release_credit_note(p_sheet_key text, p_fingerprint text) returns int language plpgsql security definer set search_path = public as $$
declare k int := 0; a record;
begin
  if not public.auth_has_perm('routes.create') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  perform public._draft(p_sheet_key, false);
  for a in select id from public.credit_note_applications where sheet_key = p_sheet_key and fingerprint = p_fingerprint and status = 'RESERVED' loop
    k := k + public._release_noc('id', a.id::text, 'deshacer');
  end loop;
  return k;
end; $$;
-- Financiación propia: reserva + consumo en una sola operación, con referencia al plan
create or replace function public.consume_credit_note_financing(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb;
begin
  if coalesce(p->>'reference', '') = '' then raise exception 'REFERENCE_REQUIRED: indicá el plan de financiación' using errcode = '23514'; end if;
  r := public.apply_credit_note(p || jsonb_build_object('destination', 'FINANCIACION_PROPIA', 'sheet_key', 'FIN:' || (p->>'reference')));
  if (r->>'ok')::boolean and not coalesce((r->>'repeated')::boolean, false) then perform public._consume_noc_apps('sheet_key', 'FIN:' || (p->>'reference'), null); end if;
  return r || jsonb_build_object('consumed', (r->>'ok')::boolean);
end; $$;
-- Admin: ignorar / rechazar (libera reservas, conserva consumos)
create or replace function public.decide_credit_note(p_fingerprint text, p_decision text, p_reason text) returns public.credit_notes language plpgsql security definer set search_path = public as $$
declare n public.credit_notes;
begin
  if not public.auth_has_perm('credit_notes.manage') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_decision not in ('IGNORADA','RECHAZADA') or coalesce(trim(p_reason), '') = '' then raise exception 'REASON_REQUIRED: indicá la decisión y el motivo' using errcode = '23514'; end if;
  perform 1 from public.credit_notes where fingerprint = p_fingerprint for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  perform public._release_noc('fingerprint', p_fingerprint, 'NOC ' || p_decision);
  update public.credit_notes set status = p_decision, reason = p_reason, decided_by = auth.uid(), decided_at = now() where fingerprint = p_fingerprint returning * into n;
  perform public._noc_event(p_fingerprint, p_decision, null, null, null, null, null, jsonb_build_object('reason', p_reason));
  return n;
end; $$;
-- Publicar = consumo definitivo de lo reservado. Eliminar/cancelar un BORRADOR = libera solo su reserva. Cancelar una hoja publicada no revierte el consumo.
create or replace function public.trg_noc_on_draft_status() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'PUBLICADA' and old.status = 'BORRADOR' then perform public._consume_noc_apps('sheet_key', new.client_sheet_key, new.route_id);
  elsif new.status = 'CANCELADA' and old.status = 'BORRADOR' then perform public._release_noc('sheet_key', new.client_sheet_key, 'borrador eliminado');
  end if;
  return new;
end; $$;
grant execute on function public.detect_credit_notes(text, jsonb), public.consume_credit_note_financing(jsonb), public.apply_credit_note(jsonb), public.release_credit_note(text, text) to authenticated;

;
-- OK DESPACHO ONLINE — RC2.1b (incremental): financiación propia REAL (plan del cliente persistido) + NOC aplicada a un plan existente.
-- Fuente importada y ajuste operativo de OK Despacho quedan SEPARADOS. No se modifica Cianbox.

create table if not exists public.financing_plans (
  id uuid primary key default gen_random_uuid(),
  client_key text not null,                          -- CUIT/DNI (columna CUIT del Saldo Comprobante) o nombre normalizado si no hay
  client_name text, comp text not null,              -- comprobante financiado (normalizado)
  comp_label text,
  status text not null default 'ACTIVO' check (status in ('ACTIVO','SALDADO','CANCELADO')),
  frequency text not null default 'POR_CONFIRMAR' check (frequency in ('SEMANAL','MENSUAL','POR_CONFIRMAR')),
  frequency_source text not null default 'AUTO' check (frequency_source in ('AUTO','CONFIRMADA')),
  frequency_confirmed_by uuid, frequency_confirmed_at timestamptz, frequency_reason text,
  parts jsonb not null default '[]',                 -- [{due, q, s}] según la última importación (fuente)
  source_pending numeric(14,2) not null default 0 check (source_pending >= 0),   -- saldo según la fuente importada
  noc_adjustments numeric(14,2) not null default 0 check (noc_adjustments >= 0), -- ajustes NOC aplicados por OK Despacho
  operational_pending numeric(14,2) generated always as (greatest(0, source_pending - noc_adjustments)) stored,
  next_due date, next_amount numeric(14,2),
  last_import_id text, last_source_at timestamptz, resolver_version text,
  created_by uuid, created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique (client_key, comp)
);
alter table public.financing_plans enable row level security;
create policy financing_plans_read on public.financing_plans for select to authenticated
  using (public.auth_has_perm('routes.create') or public.auth_has_perm('routes.view_all') or public.auth_has_perm('credit_notes.manage'));
grant select on public.financing_plans to authenticated;
revoke insert, update, delete on public.financing_plans from authenticated, anon;

-- Estado derivado: CANCELADO se respeta; si no, ACTIVO con saldo operativo > 0, si no SALDADO
create or replace function public.trg_financing_plan_state() returns trigger language plpgsql as $$
begin
  if new.status <> 'CANCELADO' then new.status := case when greatest(0, new.source_pending - new.noc_adjustments) > 0.004 then 'ACTIVO' else 'SALDADO' end; end if;
  new.updated_at := now(); return new;
end; $$;
drop trigger if exists financing_plan_state on public.financing_plans;
create trigger financing_plan_state before insert or update on public.financing_plans for each row execute function public.trg_financing_plan_state();

-- Frecuencia SOLO con evidencia consistente: ≥ 3 vencimientos distintos y TODOS los intervalos de 7 días (SEMANAL)
-- o de exactamente 1 mes calendario (MENSUAL). Si no → POR_CONFIRMAR (no se inventa).
create or replace function public.financing_frequency(p_parts jsonb) returns text language plpgsql immutable as $$
declare d date[]; i int; weekly boolean := true; monthly boolean := true;
begin
  select array_agg(x order by x) into d from (select distinct (e->>'due')::date x from jsonb_array_elements(coalesce(p_parts, '[]')) e where coalesce(e->>'due', '') ~ '^\d{4}-\d{2}-\d{2}$') t;
  if d is null or array_length(d, 1) < 3 then return 'POR_CONFIRMAR'; end if;
  for i in 2..array_length(d, 1) loop
    if d[i] - d[i-1] <> 7 then weekly := false; end if;
    if d[i] <> (d[i-1] + interval '1 month')::date and not (d[i] = (date_trunc('month', d[i]) + interval '1 month - 1 day')::date and d[i-1] = (date_trunc('month', d[i-1]) + interval '1 month - 1 day')::date
       and (date_trunc('month', d[i]) = date_trunc('month', d[i-1]) + interval '1 month')) then monthly := false; end if;
  end loop;
  return case when weekly then 'SEMANAL' when monthly then 'MENSUAL' else 'POR_CONFIRMAR' end;
end; $$;
grant execute on function public.financing_frequency(jsonb) to authenticated, service_role;

-- Sincroniza los planes detectados en una importación. Solo actualiza la parte FUENTE; nunca toca los ajustes NOC.
-- Un pedido nuevo NO se incorpora: el plan es el comprobante financiado (comp) del cliente.
create or replace function public.sync_financing_plans(p_import_id text, p_plans jsonb) returns setof public.financing_plans language plpgsql security definer set search_path = public as $$
declare p jsonb; nd record; freq text;
begin
  if not public.auth_has_perm('routes.create') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  for p in select * from jsonb_array_elements(coalesce(p_plans, '[]')) loop
    if coalesce(p->>'client_key', '') = '' or coalesce(p->>'comp', '') = '' then continue; end if;
    freq := public.financing_frequency(p->'parts');
    select (e->>'due')::date due, (e->>'s')::numeric s into nd from jsonb_array_elements(p->'parts') e
      where coalesce((e->>'s')::numeric, 0) > 0.004 and coalesce(e->>'due', '') ~ '^\d{4}-\d{2}-\d{2}$' order by (e->>'due')::date limit 1;
    insert into public.financing_plans(client_key, client_name, comp, comp_label, frequency, parts, source_pending, next_due, next_amount, last_import_id, last_source_at, resolver_version, created_by)
    values (p->>'client_key', p->>'client_name', p->>'comp', p->>'comp_label', freq, p->'parts', greatest(0, coalesce((p->>'source_pending')::numeric, 0)), nd.due, nd.s, p_import_id, now(), p->>'resolver_version', auth.uid())
    on conflict (client_key, comp) do update set client_name = excluded.client_name, comp_label = excluded.comp_label, parts = excluded.parts, source_pending = excluded.source_pending,
      next_due = excluded.next_due, next_amount = excluded.next_amount, last_import_id = excluded.last_import_id, last_source_at = now(), resolver_version = excluded.resolver_version,
      frequency = case when public.financing_plans.frequency_source = 'CONFIRMADA' then public.financing_plans.frequency else excluded.frequency end;
  end loop;
  return query select * from public.financing_plans where client_key in (select x->>'client_key' from jsonb_array_elements(coalesce(p_plans, '[]')) x);
end; $$;

-- Confirmación de frecuencia por un usuario autorizado (auditada)
create or replace function public.confirm_financing_frequency(p_plan uuid, p_frequency text, p_reason text) returns public.financing_plans language plpgsql security definer set search_path = public as $$
declare f public.financing_plans; prev text;
begin
  if not (public.auth_has_perm('credit_notes.manage') or public.auth_has_perm('settings.manage')) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_frequency not in ('SEMANAL','MENSUAL') or coalesce(trim(p_reason), '') = '' then raise exception 'REASON_REQUIRED: indicá SEMANAL o MENSUAL y el motivo' using errcode = '23514'; end if;
  select frequency into prev from public.financing_plans where id = p_plan for update;
  if not found then raise exception 'PLAN_NOT_FOUND' using errcode = 'P0002'; end if;
  update public.financing_plans set frequency = p_frequency, frequency_source = 'CONFIRMADA', frequency_confirmed_by = auth.uid(), frequency_confirmed_at = now(), frequency_reason = p_reason where id = p_plan returning * into f;
  insert into public.audit_log(actor_id, action, target_type, target_id, before, after) values (auth.uid(), 'FINANCING_FREQUENCY_CONFIRMED', 'financing_plan', p_plan::text, jsonb_build_object('frequency', prev), jsonb_build_object('frequency', p_frequency, 'reason', p_reason));
  return f;
end; $$;
grant execute on function public.sync_financing_plans(text, jsonb), public.confirm_financing_frequency(uuid, text, text) to authenticated;

-- NOC → FINANCIACIÓN PROPIA: plan REAL (id) activo, bloqueo de plan + NOC, reduce SOLO el saldo operativo del plan (nunca negativo),
-- no toca el pedido actual ni lo incorpora al plan. Referencias libres inventadas se rechazan.
create or replace function public.consume_credit_note_financing(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare f public.financing_plans; r jsonb; pid uuid; idn jsonb; applied numeric;
begin
  if not public.auth_has_perm('routes.create') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  begin pid := (p->>'plan_id')::uuid; exception when others then pid := null; end;
  if pid is null then raise exception 'PLAN_NOT_FOUND: indicá un plan de financiación existente' using errcode = 'P0002'; end if;
  select * into f from public.financing_plans where id = pid for update;
  if not found then raise exception 'PLAN_NOT_FOUND: el plan de financiación no existe' using errcode = 'P0002'; end if;
  if f.status <> 'ACTIVO' or f.operational_pending <= 0.004 then raise exception 'PLAN_INACTIVE: el plan no está activo o no tiene saldo pendiente' using errcode = '23514'; end if;
  idn := public._noc_identity(p);
  if idn ? 'error' then raise exception '%: datos de la NOC inválidos', idn->>'error' using errcode = '23514'; end if;
  if idn->>'cuit' <> regexp_replace(f.client_key, '\D', '', 'g') then raise exception 'PLAN_CLIENT_MISMATCH: la NOC no es del cliente del plan' using errcode = '23514'; end if;
  r := public.apply_credit_note(p || jsonb_build_object('destination', 'FINANCIACION_PROPIA', 'sheet_key', 'FIN:' || pid, 'reference', pid::text, 'order_amount', f.operational_pending));
  if (r->>'ok')::boolean and not coalesce((r->>'repeated')::boolean, false) then
    perform public._consume_noc_apps('sheet_key', 'FIN:' || pid, null);
    applied := (r->>'applied')::numeric;
    update public.financing_plans set noc_adjustments = noc_adjustments + applied where id = pid returning * into f;
    insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'FINANCING_NOC_APPLIED', 'financing_plan', pid::text,
      jsonb_build_object('fingerprint', r->>'fingerprint', 'applied', applied, 'operational_pending', f.operational_pending, 'source_pending', f.source_pending));
  else select * into f from public.financing_plans where id = pid; end if;
  if (r->>'ok')::boolean then r := r || (select jsonb_build_object('status', n.status, 'remaining', n.remaining_amount) from public.credit_notes n where n.fingerprint = r->>'fingerprint'); end if; -- estado ya consumido
  return r || jsonb_build_object('consumed', (r->>'ok')::boolean, 'plan_id', pid, 'plan_operational_pending', f.operational_pending, 'plan_source_pending', f.source_pending, 'plan_noc_adjustments', f.noc_adjustments, 'plan_status', f.status);
end; $$;
grant execute on function public.consume_credit_note_financing(jsonb) to authenticated;

-- Snapshot de financiación al publicar (desde el flujo real: sheet_snapshot.financing). Histórico inmutable.
alter table public.route_financing_snapshots add column if not exists plan_id uuid references public.financing_plans(id);
alter table public.route_financing_snapshots add column if not exists frequency text;
alter table public.route_financing_snapshots add column if not exists source_pending numeric(14,2);
alter table public.route_financing_snapshots add column if not exists noc_adjustments numeric(14,2);
alter table public.route_financing_snapshots add column if not exists operational_pending numeric(14,2);
alter table public.route_financing_snapshots add column if not exists source_import text;
create or replace function public.trg_route_financing_snapshot() returns trigger language plpgsql security definer set search_path = public as $$
declare e jsonb; f public.financing_plans;
begin
  for e in select * from jsonb_array_elements(coalesce(new.sheet_snapshot->'financing', '[]')) loop
    f := null;
    if coalesce(e->>'plan_id', '') <> '' then select * into f from public.financing_plans where id = (e->>'plan_id')::uuid; end if;
    insert into public.route_financing_snapshots(route_id, route_version, comp, client_name, client_cuit, parts_count, parts, total, classification, resolver_version,
      plan_id, frequency, source_pending, noc_adjustments, operational_pending, source_import)
    values (new.id, coalesce(new.version, 1), coalesce(e->>'comp', f.comp), coalesce(e->>'client_name', f.client_name), coalesce(e->>'client_key', f.client_key),
      jsonb_array_length(coalesce(e->'parts', f.parts, '[]')), coalesce(e->'parts', f.parts, '[]'), coalesce(f.operational_pending, (e->>'total')::numeric),
      coalesce(e->>'classification', 'FINANCIACION_PROPIA_VIGENTE'), coalesce(e->>'resolver_version', f.resolver_version, 'fin-2'),
      f.id, coalesce(f.frequency, e->>'frequency'), f.source_pending, f.noc_adjustments, f.operational_pending, coalesce(e->>'import_id', f.last_import_id))
    on conflict (route_id, route_version, comp) do nothing;
  end loop;
  return null;
end; $$;
drop trigger if exists route_financing_snapshot on public.routes;
create trigger route_financing_snapshot after insert on public.routes for each row execute function public.trg_route_financing_snapshot();
create policy route_financing_snapshots_read2 on public.route_financing_snapshots for select to authenticated using (public.auth_has_perm('routes.view_all') or public.auth_has_perm('routes.create'));
grant select on public.route_financing_snapshots to authenticated;

;
-- OK DESPACHO ONLINE — RC2.1c (incremental): continuidad de planes de financiación y reglas Estado/Zona → Transportista en el servidor.

-- =====================================================================
-- 4 · Continuidad del plan: una importación posterior del MISMO comprobante actualiza la fuente aunque ya quede
--     una sola cuota o saldo 0. Pero un comprobante normal (una sola parte) SIN plan previo nunca crea un plan.
--     Se preservan noc_adjustments, frecuencia CONFIRMADA, identidad del plan y auditoría.
-- =====================================================================
create or replace function public.sync_financing_plans(p_import_id text, p_plans jsonb) returns setof public.financing_plans language plpgsql security definer set search_path = public as $$
declare p jsonb; nd record; freq text; exists_plan boolean; nparts int;
begin
  if not public.auth_has_perm('routes.create') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  for p in select * from jsonb_array_elements(coalesce(p_plans, '[]')) loop
    if coalesce(p->>'client_key', '') = '' or coalesce(p->>'comp', '') = '' then continue; end if;
    exists_plan := exists (select 1 from public.financing_plans where client_key = p->>'client_key' and comp = p->>'comp');
    nparts := jsonb_array_length(coalesce(p->'parts', '[]'));
    -- crear solo con evidencia de financiación (≥ 2 partes); la continuidad (1 parte / saldo 0) solo actualiza un plan existente
    if not exists_plan and (nparts < 2 or coalesce((p->>'only_if_exists')::boolean, false)) then continue; end if;
    freq := public.financing_frequency(p->'parts');
    nd := null;
    select (e->>'due')::date due, (e->>'s')::numeric s into nd from jsonb_array_elements(p->'parts') e
      where coalesce((e->>'s')::numeric, 0) > 0.004 and coalesce(e->>'due', '') ~ '^\d{4}-\d{2}-\d{2}$' order by (e->>'due')::date limit 1;
    if exists_plan then
      update public.financing_plans set client_name = coalesce(p->>'client_name', client_name), comp_label = coalesce(p->>'comp_label', comp_label),
        parts = case when nparts >= 2 then p->'parts' else parts end,   -- con una sola fila no se pierden las partes conocidas
        source_pending = greatest(0, coalesce((p->>'source_pending')::numeric, 0)), next_due = nd.due, next_amount = nd.s,
        last_import_id = p_import_id, last_source_at = now(), resolver_version = coalesce(p->>'resolver_version', resolver_version),
        frequency = case when frequency_source = 'CONFIRMADA' or nparts < 3 then frequency else freq end
      where client_key = p->>'client_key' and comp = p->>'comp';
    else
      insert into public.financing_plans(client_key, client_name, comp, comp_label, frequency, parts, source_pending, next_due, next_amount, last_import_id, last_source_at, resolver_version, created_by)
      values (p->>'client_key', p->>'client_name', p->>'comp', p->>'comp_label', freq, p->'parts', greatest(0, coalesce((p->>'source_pending')::numeric, 0)), nd.due, nd.s, p_import_id, now(), p->>'resolver_version', auth.uid());
    end if;
  end loop;
  return query select * from public.financing_plans where client_key in (select x->>'client_key' from jsonb_array_elements(coalesce(p_plans, '[]')) x);
end; $$;
-- Claves de planes existentes (para enviar la continuidad solo de esos comprobantes)
create or replace function public.financing_plan_keys() returns table (client_key text, comp text) language sql stable security definer set search_path = public as $$
  select client_key, comp from public.financing_plans where public.auth_has_perm('routes.create') or public.auth_has_perm('routes.view_all');
$$;
grant execute on function public.financing_plan_keys() to authenticated;

-- =====================================================================
-- 5 · Reglas Estado/Zona → Transportista (versionadas, auditadas; única fuente en modo online)
-- =====================================================================
create table if not exists public.routing_rules (version int primary key, rules jsonb not null, created_by uuid, created_at timestamptz not null default now());
insert into public.routing_rules(version, rules) values (1, '[
 {"estado":"CRISTIAN","zona":"ESTE","carrier":"CRISTIAN TORRES - ESTE","priority":1,"active":true},
 {"estado":"CRISTIAN","zona":"","carrier":"CRISTIAN TORRES - ALREDEDORES","priority":2,"active":true},
 {"estado":"ALREDEDORES","zona":"","carrier":"CRISTIAN TORRES - ALREDEDORES","priority":3,"active":true},
 {"estado":"GRAN MENDOZA","zona":"","carrier":"CRISTIAN TORRES - ALREDEDORES","priority":4,"active":true},
 {"estado":"ZONA ESTE","zona":"","carrier":"CRISTIAN TORRES - ESTE","priority":5,"active":true},
 {"estado":"UCO","zona":"","carrier":"UCO","priority":6,"active":true},
 {"estado":"VASCA","zona":"","carrier":"VASCA","priority":7,"active":true},
 {"estado":"ANDESMAR","zona":"","carrier":"ANDESMAR","priority":8,"active":true},
 {"estado":"MARCHETTI","zona":"","carrier":"MARCHETTI","priority":9,"active":true}]') on conflict do nothing;
alter table public.routing_rules enable row level security;
create policy routing_rules_read on public.routing_rules for select to authenticated using (public.auth_has_perm('routes.create') or public.auth_has_perm('settings.manage'));
grant select on public.routing_rules to authenticated;
revoke insert, update, delete on public.routing_rules from authenticated, anon;
create or replace function public.set_routing_rules(p_rules jsonb) returns public.routing_rules language plpgsql security definer set search_path = public as $$
declare r public.routing_rules; prev jsonb;
begin
  if not public.auth_has_perm('settings.manage') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if jsonb_typeof(p_rules) <> 'array' then raise exception 'BAD_RULES' using errcode = '22023'; end if;
  if exists (select 1 from jsonb_array_elements(p_rules) x where coalesce(trim(x->>'estado'), '') = '' or coalesce(trim(x->>'carrier'), '') = '') then
    raise exception 'BAD_RULES: cada regla necesita estado y transportista' using errcode = '23514'; end if;
  select rules into prev from public.routing_rules order by version desc limit 1;
  insert into public.routing_rules(version, rules, created_by) values ((select max(version) from public.routing_rules) + 1, p_rules, auth.uid()) returning * into r;
  insert into public.audit_log(actor_id, action, target_type, target_id, before, after) values (auth.uid(), 'ROUTING_RULES_CHANGED', 'settings', 'v' || r.version, prev, p_rules);
  return r;
end; $$;
grant execute on function public.set_routing_rules(jsonb) to authenticated;

;
-- OK DESPACHO ONLINE — RC2.1d (incremental): routing_rules_version obligatoria y EXACTA al publicar (análogo a rules_version).
create or replace function public.trg_routes_zz_routing_version() returns trigger language plpgsql as $$
declare cur int; v int;
begin
  if coalesce(auth.role(), '') <> 'authenticated' then return new; end if;  -- restauración/cargas técnicas: el histórico conserva su versión
  select max(version) into cur from public.routing_rules;
  if new.sheet_snapshot is null or not (new.sheet_snapshot ? 'routing_rules_version') or new.sheet_snapshot->>'routing_rules_version' is null then
    raise exception 'ROUTING_RULES_REQUIRED: la hoja debe calcularse con la versión vigente de las reglas de asignación (v%)', cur using errcode = '23514'; end if;
  begin v := (new.sheet_snapshot->>'routing_rules_version')::int; exception when others then raise exception 'ROUTING_RULES_UNKNOWN: versión de reglas de asignación inválida' using errcode = '23514'; end;
  if v < cur then raise exception 'ROUTING_RULES_OUTDATED: las reglas de asignación cambiaron (v%); recalculá la hoja antes de publicar', cur using errcode = '23514'; end if;
  if v > cur then raise exception 'ROUTING_RULES_UNKNOWN: la versión de reglas de asignación v% no existe (vigente v%)', v, cur using errcode = '23514'; end if;
  return new;
end; $$;
-- después de la validación de rules_version (los triggers BEFORE INSERT corren en orden alfabético: routes_rules_version antes que routes_zz_routing_version)
drop trigger if exists routes_zz_routing_version on public.routes;
create trigger routes_zz_routing_version before insert on public.routes for each row execute function public.trg_routes_zz_routing_version();

;
-- OK DESPACHO ONLINE — RC3 (0.7.5-rc3, incremental, forward-only): circuito NOC + cancelación + conciliación con Cianbox.
-- Principio: Cianbox informa el saldo contable; OK Despacho registra las aplicaciones operativas.
-- Una importación de Cianbox NUNCA borra una aplicación local; cancelar una hoja publicada NUNCA devuelve la NOC automáticamente.

-- =====================================================================
-- 1 · Estructura (no destructiva): fuente Cianbox, reversiones y conciliación
-- =====================================================================
alter table public.credit_notes add column if not exists source_baseline_amount numeric(14,2);      -- saldo fuente al detectarla (antes de aplicaciones locales)
update public.credit_notes set source_baseline_amount = least(original_amount, remaining_amount + reserved_amount + consumed_amount) where source_baseline_amount is null;
-- toda NOC nueva guarda su saldo fuente inicial (base para comparar con importaciones posteriores)
create or replace function public.trg_credit_note_baseline() returns trigger language plpgsql as $$
begin
  if new.source_baseline_amount is null then new.source_baseline_amount := least(new.original_amount, new.remaining_amount + new.reserved_amount + new.consumed_amount); end if;
  return new;
end; $$;
drop trigger if exists credit_note_baseline on public.credit_notes;
create trigger credit_note_baseline before insert on public.credit_notes for each row execute function public.trg_credit_note_baseline();
alter table public.credit_notes add column if not exists source_remaining_amount numeric(14,2);     -- saldo informado por la ÚLTIMA importación de Cianbox
alter table public.credit_notes add column if not exists last_source_seen_at timestamptz;
alter table public.credit_notes add column if not exists last_source_import text;
alter table public.credit_notes add column if not exists reversed_amount numeric(14,2) not null default 0 check (reversed_amount >= 0);
alter table public.credit_notes add column if not exists reconciliation_status text not null default 'OK'
  check (reconciliation_status in ('OK','PENDING_CIANBOX','CANCELLED_ROUTE_REVIEW','RECONCILED','REVERSED','CIANBOX_DIFFERENCE'));
alter table public.credit_notes add column if not exists reconciliation_detail jsonb;
alter table public.credit_notes add column if not exists last_reconciled_at timestamptz;
alter table public.credit_notes add column if not exists recon_version int not null default 1;      -- concurrencia optimista de acciones administrativas

alter table public.credit_note_applications drop constraint if exists credit_note_applications_status_check;
alter table public.credit_note_applications add constraint credit_note_applications_status_check check (status in ('RESERVED','CONSUMED','RELEASED','REVERSED'));
alter table public.credit_note_applications add column if not exists order_numbers text[] not null default '{}';
alter table public.credit_note_applications add column if not exists reconciliation_status text
  check (reconciliation_status in ('OK','PENDING_CIANBOX','CANCELLED_ROUTE_REVIEW','RECONCILED','REVERSED','CIANBOX_DIFFERENCE'));
update public.credit_note_applications set reconciliation_status = 'PENDING_CIANBOX' where status = 'CONSUMED' and reconciliation_status is null;
alter table public.credit_note_applications add column if not exists cancelled_route_id uuid references public.routes(id);
alter table public.credit_note_applications add column if not exists cancelled_by uuid;
alter table public.credit_note_applications add column if not exists cancelled_at timestamptz;
alter table public.credit_note_applications add column if not exists cancel_reason text;
alter table public.credit_note_applications add column if not exists resolution text check (resolution in ('KEEP','REVERSED','RECONCILED'));
alter table public.credit_note_applications add column if not exists resolution_reason text;
alter table public.credit_note_applications add column if not exists resolved_by uuid;
alter table public.credit_note_applications add column if not exists resolved_at timestamptz;
alter table public.credit_note_applications add column if not exists reversed_op_id text unique;
alter table public.credit_note_applications add column if not exists reconciled_source_amount numeric(14,2);
alter table public.credit_note_applications add column if not exists reassigned_sheet_key text;
alter table public.credit_note_applications add column if not exists reassigned_from_route uuid references public.routes(id);

alter table public.credit_note_events drop constraint if exists credit_note_events_event_check;
alter table public.credit_note_events add constraint credit_note_events_event_check check (event in ('DETECTADA','RESERVADA','RESERVA_LIBERADA','APLICADA_PARCIAL','APLICADA_TOTAL',
  'INTENTO_DUPLICADO_BLOQUEADO','IGNORADA','RECHAZADA','HOJA_CANCELADA_REVISION','MANTENIDA_APLICADA','REVERTIDA','CONCILIADA','PENDIENTE_CIANBOX','DIFERENCIA_CIANBOX','REASOCIADA'));

-- Saldo EFECTIVO utilizable: nunca negativo, nunca mayor al original, nunca mayor a lo que Cianbox informa (menos reservas y consumos aún no reflejados)
create or replace function public.noc_effective_available(n public.credit_notes) returns numeric language sql stable as $$
  select case when n.status in ('IGNORADA','RECHAZADA') then 0::numeric else
    greatest(0, least(n.original_amount, n.remaining_amount,
      case when n.source_remaining_amount is null then n.remaining_amount
           else n.source_remaining_amount - n.reserved_amount
                - greatest(0, n.consumed_amount - greatest(0, coalesce(n.source_baseline_amount, n.original_amount) - n.source_remaining_amount)) end)) end;
$$;

-- Estado de conciliación de la NOC = el más exigente de sus aplicaciones consumidas
create or replace function public._noc_recon_aggregate(p_fp text) returns text language plpgsql security definer set search_path = public as $$
declare st text; n public.credit_notes;
begin
  select * into n from public.credit_notes where fingerprint = p_fp;
  select case when bool_or(reconciliation_status = 'CANCELLED_ROUTE_REVIEW') then 'CANCELLED_ROUTE_REVIEW'
              when bool_or(reconciliation_status = 'CIANBOX_DIFFERENCE') then 'CIANBOX_DIFFERENCE'
              when bool_or(reconciliation_status = 'PENDING_CIANBOX') then 'PENDING_CIANBOX'
              when bool_or(reconciliation_status = 'RECONCILED') then 'RECONCILED' end into st
    from public.credit_note_applications where fingerprint = p_fp and status = 'CONSUMED';
  if st is null then
    st := case when exists (select 1 from public.credit_note_applications where fingerprint = p_fp and status = 'REVERSED') then 'REVERSED' else 'OK' end;
    if n.reconciliation_status = 'CIANBOX_DIFFERENCE' and (n.reconciliation_detail->>'reason') in ('NO_INFORMADA','SALDO_MAYOR') then st := n.reconciliation_status; end if;
  end if;
  update public.credit_notes set reconciliation_status = st where fingerprint = p_fp and reconciliation_status is distinct from st;
  return st;
end; $$;
revoke execute on function public._noc_recon_aggregate(text) from public, anon, authenticated;

create or replace function public._consume_noc_apps(p_where text, p_value text, p_route uuid) returns int language plpgsql security definer set search_path = public as $$
declare a record; n public.credit_notes; k int := 0;
begin
  for a in execute format('select * from public.credit_note_applications where status = ''RESERVED'' and %I::text = $1 for update', p_where) using p_value loop
    update public.credit_note_applications set status = 'CONSUMED', route_id = coalesce(p_route, route_id), reconciliation_status = 'PENDING_CIANBOX' where id = a.id;
    update public.credit_notes set reserved_amount = greatest(0, reserved_amount - a.amount), consumed_amount = consumed_amount + a.amount where fingerprint = a.fingerprint returning * into n;
    perform public._noc_event(a.fingerprint, case when n.remaining_amount <= 0.004 and n.reserved_amount <= 0.004 then 'APLICADA_TOTAL' else 'APLICADA_PARCIAL' end, a.amount, a.sheet_key, p_route, a.destination,
      coalesce((select 'hoja ' || number from public.routes where id = p_route), a.reference), null);
    perform public._noc_recon_aggregate(a.fingerprint);
    k := k + 1;
  end loop;
  return k;
end; $$;
revoke execute on function public._consume_noc_apps(text, text, uuid) from public, anon, authenticated;

create or replace function public.apply_credit_note(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare idn jsonb; fp text; n public.credit_notes; a public.credit_note_applications; applied numeric; prev numeric; dest text := coalesce(nullif(p->>'destination', ''), 'PEDIDO_ACTUAL');
        req numeric := (p->>'amount')::numeric; ord numeric := (p->>'order_amount')::numeric; cc numeric := coalesce((p->>'cc_saldo')::numeric, 0); other text; code text; msg text; eff numeric;
begin
  if not public.auth_has_perm('routes.create') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if coalesce((p->>'accept')::boolean, false) is not true then raise exception 'NOC_NOT_ACCEPTED: la NOC se aplica solo con aceptación explícita' using errcode = '23514'; end if;
  if dest not in ('PEDIDO_ACTUAL','FINANCIACION_PROPIA') then raise exception 'BAD_DESTINATION' using errcode = '22023'; end if;
  if dest = 'PEDIDO_ACTUAL' then perform public._draft(p->>'sheet_key', true); end if;
  select * into a from public.credit_note_applications where op_id = p->>'op_id';
  if found then select * into n from public.credit_notes where fingerprint = a.fingerprint;
    return jsonb_build_object('ok', true, 'fingerprint', a.fingerprint, 'applied', a.amount, 'remaining', n.remaining_amount, 'status', n.status, 'repeated', true); end if;
  idn := public._noc_identity(p);
  if idn->>'error' = 'NOC_BAD_COMP' then raise exception 'NOC_BAD_COMP: no se puede identificar tipo/letra/punto de venta/número de "%"', p->>'comp' using errcode = '22023'; end if;
  if idn->>'error' = 'NOC_MISSING_DATA' then raise exception 'NOC_MISSING_DATA: faltan CUIT/DNI, fecha de emisión o importe original de la NOC' using errcode = '23514'; end if;
  if req is null or req <= 0 or ord is null then raise exception 'BAD_AMOUNT' using errcode = '22023'; end if;
  if ord <= 0.004 then raise exception 'NOC_NOTHING_TO_COLLECT: no hay importe a cobrar para reducir' using errcode = '23514'; end if;
  fp := idn->>'fingerprint';
  insert into public.credit_notes(fingerprint, client_key, comp, issued_date, original_amount, remaining_amount, created_by, tipo, letra, pv, numero, cuit)
  values (fp, idn->>'cuit', p->>'comp', idn->>'fecha', (idn->>'original')::numeric, least((idn->>'original')::numeric, coalesce(nullif(p->>'available_amount', '')::numeric, (idn->>'original')::numeric)),
          auth.uid(), idn->>'tipo', idn->>'letra', (idn->>'pv')::int, (idn->>'numero')::bigint, idn->>'cuit')
  on conflict (fingerprint) do nothing;
  select * into n from public.credit_notes where fingerprint = fp for update;   -- bloqueo de fila: dos sesiones no reservan a la vez
  select a2.sheet_key into other from public.credit_note_applications a2 where a2.fingerprint = fp and a2.status = 'RESERVED' and a2.sheet_key <> coalesce(p->>'sheet_key', '') limit 1;
  eff := public.noc_effective_available(n);   -- RC3: saldo realmente utilizable (Cianbox + reservas + consumos no reflejados + reversiones)
  code := case when n.status in ('IGNORADA','RECHAZADA') then 'NOC_BLOCKED'
               when n.reconciliation_status in ('CANCELLED_ROUTE_REVIEW','CIANBOX_DIFFERENCE') then 'NOC_UNDER_REVIEW'
               when eff <= 0.004 and n.reserved_amount <= 0.004 then 'NOC_CONSUMED'
               when other is not null then 'NOC_RESERVED_ELSEWHERE'
               when n.destination is not null and n.destination <> dest then 'NOC_DESTINATION_LOCKED'
               when eff <= 0.004 then 'NOC_CONSUMED' end;
  if code is not null then
    msg := case code when 'NOC_BLOCKED' then 'Administración marcó esta NOC como ' || n.status when 'NOC_CONSUMED' then 'NOTA DE CRÉDITO YA UTILIZADA'
           when 'NOC_RESERVED_ELSEWHERE' then 'NOTA DE CRÉDITO RESERVADA EN OTRO BORRADOR'
           when 'NOC_UNDER_REVIEW' then 'NOTA DE CRÉDITO EN REVISIÓN ADMINISTRATIVA (conciliación pendiente)' else 'La NOC ya se usó en ' || n.destination || ' y no puede usarse en otro destino' end;
    perform public._noc_event(fp, 'INTENTO_DUPLICADO_BLOQUEADO', req, p->>'sheet_key', null, dest, p->>'reference', jsonb_build_object('code', code, 'op_id', p->>'op_id'));
    return jsonb_build_object('ok', false, 'code', code, 'message', msg, 'fingerprint', fp, 'status', n.status, 'original', n.original_amount, 'consumed', n.consumed_amount, 'available', eff, 'reconciliation_status', n.reconciliation_status);
  end if;
  applied := round(least(req, eff, ord), 2);
  select coalesce(sum(x.amount), 0) into prev from public.credit_note_applications x join public.credit_notes y on y.fingerprint = x.fingerprint
   where x.sheet_key = p->>'sheet_key' and x.status = 'RESERVED' and y.cuit = n.cuit;
  insert into public.credit_note_applications(fingerprint, sheet_key, amount, op_id, created_by, destination, reference, order_numbers)
  values (fp, coalesce(p->>'sheet_key', 'FIN:' || coalesce(p->>'reference', '')), applied, p->>'op_id', auth.uid(), dest, coalesce(p->>'reference', p->>'sheet_key'),
          coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(p->'order_numbers', '[]')) x), '{}'));
  update public.credit_notes set remaining_amount = remaining_amount - applied, reserved_amount = reserved_amount + applied, destination = coalesce(destination, dest) where fingerprint = fp returning * into n;
  perform public._noc_event(fp, 'RESERVADA', applied, p->>'sheet_key', null, dest, coalesce(p->>'reference', p->>'sheet_key'),
    jsonb_build_object('requested', req, 'order_amount', ord, 'cc_saldo', cc, 'floor_before', greatest(0, cc - prev), 'floor_after', greatest(0, cc - prev - applied)));
  return jsonb_build_object('ok', true, 'fingerprint', fp, 'applied', applied, 'remaining', public.noc_effective_available(n), 'status', n.status, 'repeated', false,
    'floor_before', greatest(0, cc - prev), 'floor_after', greatest(0, cc - prev - applied), 'collect_after', round(ord - applied, 2));
end; $$;

create or replace function public.detect_credit_notes(p_sheet_key text, p_items jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare it jsonb; idn jsonb; n public.credit_notes; out jsonb := '[]'; last record; other record; ins boolean;
begin
  if not public.auth_has_perm('routes.create') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  for it in select * from jsonb_array_elements(coalesce(p_items, '[]')) loop
    idn := public._noc_identity(it);
    if idn ? 'error' then out := out || jsonb_build_array(jsonb_build_object('comp', it->>'comp', 'error', idn->>'error')); continue; end if;
    insert into public.credit_notes(fingerprint, client_key, comp, issued_date, original_amount, remaining_amount, created_by, tipo, letra, pv, numero, cuit)
    values (idn->>'fingerprint', idn->>'cuit', it->>'comp', idn->>'fecha', (idn->>'original')::numeric,
            least((idn->>'original')::numeric, coalesce(nullif(it->>'available_amount', '')::numeric, (idn->>'original')::numeric)), auth.uid(),
            idn->>'tipo', idn->>'letra', (idn->>'pv')::int, (idn->>'numero')::bigint, idn->>'cuit')
    on conflict (fingerprint) do nothing returning true into ins;
    if ins then perform public._noc_event(idn->>'fingerprint', 'DETECTADA', null, p_sheet_key, null, null, null, jsonb_build_object('comp', it->>'comp')); end if;
    select * into n from public.credit_notes where fingerprint = idn->>'fingerprint';
    select a.created_at, a.destination, a.reference, r.number into last from public.credit_note_applications a left join public.routes r on r.id = a.route_id
      where a.fingerprint = n.fingerprint and a.status = 'CONSUMED' order by a.created_at desc limit 1;
    select a.sheet_key, d.name, p.full_name into other from public.credit_note_applications a left join public.route_drafts d on d.client_sheet_key = a.sheet_key left join public.profiles p on p.id = a.created_by
      where a.fingerprint = n.fingerprint and a.status = 'RESERVED' and a.sheet_key <> p_sheet_key limit 1;
    out := out || jsonb_build_array(jsonb_build_object('comp', it->>'comp', 'fingerprint', n.fingerprint, 'status', n.status, 'original', n.original_amount, 'reserved', n.reserved_amount,
      'consumed', n.consumed_amount, 'available', public.noc_effective_available(n), 'destination', n.destination,
      'reconciliation_status', n.reconciliation_status, 'source_remaining', n.source_remaining_amount,
      'prior', (select coalesce(jsonb_agg(jsonb_build_object('app_id', a.id, 'amount', a.amount, 'route_number', r.number, 'order_numbers', a.order_numbers, 'state', a.reconciliation_status,
                 'resolution', a.resolution, 'reassigned_sheet_key', a.reassigned_sheet_key)), '[]'::jsonb)
                from public.credit_note_applications a left join public.routes r on r.id = a.cancelled_route_id
                where a.fingerprint = n.fingerprint and a.cancelled_route_id is not null and a.status = 'CONSUMED'),
      'mine', (select coalesce(sum(amount), 0) from public.credit_note_applications where fingerprint = n.fingerprint and sheet_key = p_sheet_key and status = 'RESERVED'),
      'reserved_elsewhere', other.sheet_key is not null,
      'reserved_by', case when other.sheet_key is not null then coalesce('borrador "' || other.name || '"', 'otro borrador') || coalesce(' · ' || other.full_name, '') end,
      'used_at', last.created_at, 'used_destination', last.destination, 'used_reference', coalesce('hoja ' || last.number, last.reference)));
  end loop;
  return out;
end; $$;
grant execute on function public.apply_credit_note(jsonb), public.detect_credit_notes(text, jsonb) to authenticated;
grant execute on function public.noc_effective_available(public.credit_notes) to authenticated, service_role;

-- =====================================================================
-- 2 · Cancelar hoja publicada: TODO el comportamiento anterior + las NOC consumidas pasan a revisión (sin tocar importes)
-- =====================================================================
create or replace function public.cancel_route(p_route uuid, p_reason text) returns public.routes language plpgsql security definer set search_path = public as $$
declare r public.routes; a record;
begin
  if not public.auth_has_perm('routes.manage_all_drafts') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
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
-- Aviso previo a cancelar (sin datos sensibles): cuántas NOC aplicadas tiene la hoja
create or replace function public.route_noc_summary(p_route uuid) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not (public.auth_has_perm('routes.manage_all_drafts') or public.auth_has_perm('credit_notes.manage')) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return (select jsonb_build_object('count', count(*), 'amount', coalesce(sum(amount), 0)) from public.credit_note_applications where route_id = p_route and status = 'CONSUMED');
end; $$;
grant execute on function public.cancel_route(uuid, text), public.route_noc_summary(uuid) to authenticated;

-- =====================================================================
-- 3 · Reimportación de Cianbox (Saldo Comprobante): concilia por huella estable, nunca sobrescribe consumos locales
-- =====================================================================
create or replace function public._noc_classify(n public.credit_notes) returns jsonb language sql immutable as $$
  select case
    when n.source_remaining_amount is null or n.consumed_amount <= 0.004 then jsonb_build_object('st', 'OK')
    when n.source_remaining_amount <= 0.004 then jsonb_build_object('st', 'RECONCILED', 'reason', 'SALDO_CERO')                                   -- caso A
    when abs(n.source_remaining_amount - (coalesce(n.source_baseline_amount, n.original_amount) - n.consumed_amount)) <= 0.01
      then jsonb_build_object('st', 'RECONCILED', 'reason', 'REDUCCION_EXACTA')                                                                -- caso C
    when abs(n.source_remaining_amount - coalesce(n.source_baseline_amount, n.original_amount)) <= 0.01
      then jsonb_build_object('st', 'PENDING_CIANBOX', 'reason', 'SIN_REFLEJAR')                                                               -- caso B
    when n.source_remaining_amount > coalesce(n.source_baseline_amount, n.original_amount)
      then jsonb_build_object('st', 'CIANBOX_DIFFERENCE', 'reason', 'SALDO_MAYOR')                                                             -- caso E
    else jsonb_build_object('st', 'CIANBOX_DIFFERENCE', 'reason', 'REDUCCION_PARCIAL')                                                         -- caso D (y reducciones mayores)
  end || jsonb_build_object('expected', coalesce(n.source_baseline_amount, n.original_amount) - n.consumed_amount, 'informed', n.source_remaining_amount,
    'difference', n.source_remaining_amount - (coalesce(n.source_baseline_amount, n.original_amount) - n.consumed_amount));
$$;
create or replace function public.reconcile_credit_notes(p_import_id text, p_items jsonb, p_complete boolean default false) returns jsonb language plpgsql security definer set search_path = public as $$
declare it jsonb; idn jsonb; n public.credit_notes; c jsonb; seen text[] := '{}'; cnt jsonb := '{}'; prev text; a record;
begin
  if not public.auth_has_perm('routes.create') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  for it in select * from jsonb_array_elements(coalesce(p_items, '[]')) loop
    idn := public._noc_identity(it);
    if idn ? 'error' then continue; end if;
    seen := seen || (idn->>'fingerprint');
    select * into n from public.credit_notes where fingerprint = idn->>'fingerprint' for update;
    if not found then continue; end if;                    -- solo se concilian NOC ya conocidas por OK Despacho
    prev := n.reconciliation_status;
    update public.credit_notes set source_remaining_amount = greatest(0, coalesce((it->>'available_amount')::numeric, 0)), last_source_seen_at = now(), last_source_import = p_import_id
      where fingerprint = n.fingerprint returning * into n;
    c := public._noc_classify(n);
    -- las aplicaciones en revisión por hoja cancelada o ya revertidas no se tocan; el resto toma el estado de la importación
    for a in select * from public.credit_note_applications where fingerprint = n.fingerprint and status = 'CONSUMED' and reconciliation_status is distinct from 'CANCELLED_ROUTE_REVIEW' loop
      update public.credit_note_applications set reconciliation_status = case when c->>'st' = 'OK' then 'PENDING_CIANBOX' else c->>'st' end,
        reconciled_source_amount = case when c->>'st' = 'RECONCILED' then n.source_remaining_amount else reconciled_source_amount end where id = a.id;
    end loop;
    update public.credit_notes set reconciliation_detail = c || jsonb_build_object('import', p_import_id),
      last_reconciled_at = case when c->>'st' = 'RECONCILED' then now() else last_reconciled_at end,
      reconciliation_status = case when c->>'st' = 'CIANBOX_DIFFERENCE' and consumed_amount > 0.004 then 'CIANBOX_DIFFERENCE' else reconciliation_status end
      where fingerprint = n.fingerprint;
    perform public._noc_recon_aggregate(n.fingerprint);
    select * into n from public.credit_notes where fingerprint = n.fingerprint;
    if n.reconciliation_status is distinct from prev then
      update public.credit_notes set recon_version = recon_version + 1 where fingerprint = n.fingerprint;
      perform public._noc_event(n.fingerprint, case n.reconciliation_status when 'RECONCILED' then 'CONCILIADA' when 'PENDING_CIANBOX' then 'PENDIENTE_CIANBOX' else 'DIFERENCIA_CIANBOX' end,
        null, null, null, null, p_import_id, c);
    end if;
    cnt := jsonb_set(cnt, array[n.reconciliation_status], to_jsonb(coalesce((cnt->>n.reconciliation_status)::int, 0) + 1));
  end loop;
  -- caso F: la NOC no aparece en una importación COMPLETA. La ausencia sola no prueba nada → revisión (sin tocar importes ni liberar saldo)
  if p_complete and jsonb_array_length(coalesce(p_items, '[]')) > 0 then   -- un archivo sin NOC no es evidencia de nada
    for n in select * from public.credit_notes where consumed_amount > 0.004 and not (fingerprint = any(seen)) and reconciliation_status in ('PENDING_CIANBOX','OK') for update loop
      update public.credit_notes set reconciliation_status = 'CIANBOX_DIFFERENCE', recon_version = recon_version + 1,
        reconciliation_detail = jsonb_build_object('st', 'CIANBOX_DIFFERENCE', 'reason', 'NO_INFORMADA', 'import', p_import_id) where fingerprint = n.fingerprint;
      update public.credit_note_applications set reconciliation_status = 'CIANBOX_DIFFERENCE' where fingerprint = n.fingerprint and status = 'CONSUMED' and reconciliation_status = 'PENDING_CIANBOX';
      perform public._noc_event(n.fingerprint, 'DIFERENCIA_CIANBOX', null, null, null, null, p_import_id, jsonb_build_object('reason', 'NO_INFORMADA'));
      cnt := jsonb_set(cnt, '{NO_INFORMADA}', to_jsonb(coalesce((cnt->>'NO_INFORMADA')::int, 0) + 1));
    end loop;
  end if;
  return cnt;
end; $$;
grant execute on function public.reconcile_credit_notes(text, jsonb, boolean) to authenticated;

-- =====================================================================
-- 4 · Acciones de Administración (credit_notes.manage): MANTENER APLICADA / REVERTIR A DISPONIBLE / CONFIRMAR CONCILIACIÓN
--     Bloqueo de fila (NOC + aplicación) + versión esperada: dos administradores no resuelven a la vez la misma NOC.
-- =====================================================================
create or replace function public.noc_resolve_application(p_app uuid, p_action text, p_reason text, p_expected_version int, p_op_id text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a public.credit_note_applications; n public.credit_notes; before jsonb; c jsonb; st text; amt numeric;
begin
  if not public.auth_has_perm('credit_notes.manage') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_action not in ('KEEP','REVERSE','RECONCILE') then raise exception 'BAD_ACTION' using errcode = '22023'; end if;
  select * into a from public.credit_note_applications where id = p_app;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  select * into n from public.credit_notes where fingerprint = a.fingerprint for update;           -- NOC primero, después la aplicación (orden fijo: sin deadlocks)
  select * into a from public.credit_note_applications where id = p_app for update;
  -- reintento idempotente de la MISMA reversión
  if p_action = 'REVERSE' and a.status = 'REVERSED' and p_op_id is not null and a.reversed_op_id = p_op_id then
    return jsonb_build_object('ok', true, 'repeated', true, 'application', a.id, 'available', public.noc_effective_available(n), 'version', n.recon_version); end if;
  if p_expected_version is not null and n.recon_version <> p_expected_version then
    raise exception 'NOC_CONFLICT: otra persona modificó esta Nota de Crédito; se recargó el estado real' using errcode = '40001'; end if;
  if p_action in ('KEEP','REVERSE') and coalesce(trim(p_reason), '') = '' then raise exception 'REASON_REQUIRED: indicá el motivo' using errcode = '23514'; end if;
  if a.status = 'REVERSED' then raise exception 'NOC_ALREADY_REVERSED: esta aplicación ya fue revertida' using errcode = '23514'; end if;
  if a.status <> 'CONSUMED' then raise exception 'BAD_STATE: solo aplicaciones consumidas' using errcode = '23514'; end if;
  before := jsonb_build_object('consumed', n.consumed_amount, 'remaining', n.remaining_amount, 'reversed', n.reversed_amount, 'available', public.noc_effective_available(n),
    'note_state', n.reconciliation_status, 'application_state', a.reconciliation_status, 'resolution', a.resolution);
  if p_action = 'KEEP' then
    if a.reconciliation_status <> 'CANCELLED_ROUTE_REVIEW' then raise exception 'BAD_STATE: solo aplicaciones de hojas canceladas en revisión' using errcode = '23514'; end if;
    c := public._noc_classify(n); st := case when c->>'st' in ('OK') then 'PENDING_CIANBOX' else c->>'st' end;
    update public.credit_note_applications set resolution = 'KEEP', resolution_reason = p_reason, resolved_by = auth.uid(), resolved_at = now(), reconciliation_status = st where id = a.id;
    perform public._noc_event(n.fingerprint, 'MANTENIDA_APLICADA', a.amount, a.sheet_key, a.cancelled_route_id, a.destination, p_reason, jsonb_build_object('application', a.id, 'state', st));
  elsif p_action = 'REVERSE' then
    if a.reconciliation_status = 'RECONCILED' then raise exception 'NOC_ALREADY_RECONCILED: Cianbox ya refleja esta aplicación; no se puede revertir desde OK Despacho' using errcode = '23514'; end if;
    amt := least(a.amount, n.consumed_amount);
    update public.credit_note_applications set status = 'REVERSED', resolution = 'REVERSED', resolution_reason = p_reason, resolved_by = auth.uid(), resolved_at = now(),
      reconciliation_status = 'REVERSED', reversed_op_id = coalesce(p_op_id, 'rev-' || a.id) where id = a.id;
    update public.credit_notes set consumed_amount = consumed_amount - amt, reversed_amount = reversed_amount + amt,
      remaining_amount = least(original_amount, remaining_amount + amt),
      destination = case when consumed_amount - amt <= 0.004 and reserved_amount <= 0.004 then null else destination end where fingerprint = n.fingerprint;
    perform public._noc_event(n.fingerprint, 'REVERTIDA', amt, a.sheet_key, coalesce(a.cancelled_route_id, a.route_id), a.destination, p_reason, jsonb_build_object('application', a.id));
  else
    update public.credit_note_applications set resolution = 'RECONCILED', resolution_reason = p_reason, resolved_by = auth.uid(), resolved_at = now(), reconciliation_status = 'RECONCILED',
      reconciled_source_amount = n.source_remaining_amount where id = a.id;
    update public.credit_notes set last_reconciled_at = now() where fingerprint = n.fingerprint;
    perform public._noc_event(n.fingerprint, 'CONCILIADA', a.amount, a.sheet_key, a.route_id, a.destination, p_reason, jsonb_build_object('application', a.id, 'cianbox', n.source_remaining_amount));
  end if;
  perform public._noc_recon_aggregate(n.fingerprint);
  update public.credit_notes set recon_version = recon_version + 1 where fingerprint = n.fingerprint returning * into n;
  select * into a from public.credit_note_applications where id = p_app;
  insert into public.audit_log(actor_id, action, target_type, target_id, before, after) values (auth.uid(), 'NOC_' || p_action, 'credit_note', n.fingerprint, before,
    jsonb_build_object('consumed', n.consumed_amount, 'remaining', n.remaining_amount, 'reversed', n.reversed_amount, 'available', public.noc_effective_available(n),
      'note_state', n.reconciliation_status, 'application_state', a.reconciliation_status, 'resolution', a.resolution, 'reason', p_reason, 'application', a.id,
      'amount', a.amount, 'route', coalesce(a.cancelled_route_id, a.route_id), 'order_numbers', a.order_numbers, 'import', n.last_source_import));
  return jsonb_build_object('ok', true, 'repeated', false, 'application', a.id, 'state', a.reconciliation_status, 'available', public.noc_effective_available(n), 'version', n.recon_version);
end; $$;
grant execute on function public.noc_resolve_application(uuid, text, text, int, text) to authenticated;

-- Reasociación OPERATIVA (sin segundo consumo): una aplicación MANTENIDA de una hoja cancelada se vincula a la nueva hoja del mismo pedido
create or replace function public.noc_reassociate(p_app uuid, p_sheet_key text) returns jsonb language plpgsql security definer set search_path = public as $$
declare a public.credit_note_applications;
begin
  if not public.auth_has_perm('routes.create') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  perform public._draft(p_sheet_key, false);
  select * into a from public.credit_note_applications where id = p_app for update;
  if not found or a.status <> 'CONSUMED' or a.cancelled_route_id is null or a.resolution is distinct from 'KEEP' then
    raise exception 'NOC_NOT_REASSIGNABLE: solo una aplicación mantenida por Administración de una hoja cancelada' using errcode = '23514'; end if;
  if a.reassigned_sheet_key is not null and a.reassigned_sheet_key <> p_sheet_key then raise exception 'NOC_ALREADY_REASSIGNED: ya se vinculó a otra hoja' using errcode = '23514'; end if;
  update public.credit_note_applications set reassigned_sheet_key = p_sheet_key where id = a.id;
  perform public._noc_event(a.fingerprint, 'REASOCIADA', a.amount, p_sheet_key, a.cancelled_route_id, a.destination, 'sin nuevo consumo', jsonb_build_object('application', a.id));
  return jsonb_build_object('ok', true, 'application', a.id, 'amount', a.amount, 'fingerprint', a.fingerprint);
end; $$;
grant execute on function public.noc_reassociate(uuid, text) to authenticated;
create or replace function public.trg_noc_on_draft_status() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'PUBLICADA' and old.status = 'BORRADOR' then
    perform public._consume_noc_apps('sheet_key', new.client_sheet_key, new.route_id);
    update public.credit_note_applications set reassigned_from_route = cancelled_route_id, route_id = new.route_id where reassigned_sheet_key = new.client_sheet_key and status = 'CONSUMED';
  elsif new.status = 'CANCELADA' and old.status = 'BORRADOR' then perform public._release_noc('sheet_key', new.client_sheet_key, 'borrador eliminado');
  end if;
  return new;
end; $$;

-- =====================================================================
-- 5 · Vista de Conciliación NOC (solo Administración)
-- =====================================================================
create or replace function public.noc_reconciliation_list(p_filter text default 'todos') returns table (
  application_id uuid, fingerprint text, comp text, client_name text, cuit text, issued_date text, original_amount numeric, source_remaining_amount numeric,
  reserved_amount numeric, consumed_amount numeric, reversed_amount numeric, effective_available numeric, application_amount numeric, application_status text,
  route_number text, route_status text, order_numbers text[], note_state text, application_state text, resolution text, resolution_reason text,
  last_source_seen_at timestamptz, last_source_import text, difference numeric, detail jsonb, recon_version int, cancel_reason text, cancelled_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.auth_has_perm('credit_notes.manage') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return query
  select a.id, n.fingerprint, n.comp, (select s.client_name from public.route_stops s where s.route_id = coalesce(a.cancelled_route_id, a.route_id) and s.order_numbers && a.order_numbers limit 1),
    n.cuit, n.issued_date, n.original_amount, n.source_remaining_amount, n.reserved_amount, n.consumed_amount, n.reversed_amount, public.noc_effective_available(n), a.amount, a.status,
    r.number, r.operational_status, a.order_numbers, n.reconciliation_status, a.reconciliation_status, a.resolution, a.resolution_reason, n.last_source_seen_at, n.last_source_import,
    (n.reconciliation_detail->>'difference')::numeric, n.reconciliation_detail, n.recon_version, a.cancel_reason, a.cancelled_at
  from public.credit_note_applications a join public.credit_notes n on n.fingerprint = a.fingerprint left join public.routes r on r.id = coalesce(a.cancelled_route_id, a.route_id)
  where a.status in ('CONSUMED','REVERSED')
    and (p_filter = 'todos' or (p_filter = 'pendientes' and a.reconciliation_status = 'PENDING_CIANBOX') or (p_filter = 'cancelada' and a.reconciliation_status = 'CANCELLED_ROUTE_REVIEW')
      or (p_filter = 'diferencias' and a.reconciliation_status = 'CIANBOX_DIFFERENCE') or (p_filter = 'conciliados' and a.reconciliation_status = 'RECONCILED')
      or (p_filter = 'revertidos' and a.reconciliation_status = 'REVERSED'))
  order by case a.reconciliation_status when 'CANCELLED_ROUTE_REVIEW' then 0 when 'CIANBOX_DIFFERENCE' then 1 when 'PENDING_CIANBOX' then 2 else 3 end, a.created_at desc;
end; $$;
grant execute on function public.noc_reconciliation_list(text) to authenticated;
-- La lectura de aplicaciones NOC queda para quien prepara hojas (necesario para operar) o Administración; Transportistas no ven nada.
drop policy if exists cna_read on public.credit_note_applications;
create policy cna_read on public.credit_note_applications for select to authenticated using (public.auth_has_perm('routes.create') or public.auth_has_perm('credit_notes.manage'));
revoke insert, update, delete on public.credit_notes, public.credit_note_applications, public.credit_note_events from authenticated, anon;

;
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
;
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
;
-- RC4.1 source-history marker
--
-- The online test environment received a generated migration named
-- rc4_1_security_grants before the final generalized hardening was applied.
-- Its narrow grant/revoke intent is superseded by the next migration:
-- 20261029000100_rc4_1_1_revoke_public_function_execute.sql
--
-- This file intentionally performs no schema/data mutation. It exists so the
-- repository documents the server-side migration history without attempting
-- to replay an obsolete intermediate security state.
select 1;
;
-- RC4.1.1 · hardening de EXECUTE en funciones públicas
--
-- PostgreSQL concede EXECUTE sobre funciones nuevas a PUBLIC por defecto.
-- En una app autenticada esto puede hacer que el rol anon herede ejecución
-- aunque no exista un GRANT explícito a anon.
--
-- Esta migración:
--   1) captura qué funciones son ejecutables hoy por authenticated;
--   2) elimina EXECUTE heredado por PUBLIC y cualquier grant directo a anon;
--   3) restaura explícitamente authenticated sólo donde ya tenía acceso;
--   4) mantiene service_role;
--   5) evita que futuras funciones creadas por el owner vuelvan a recibir
--      EXECUTE para PUBLIC por defecto.
--
-- Es forward-only, idempotente respecto del objetivo de permisos y no toca
-- datos de negocio.

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT p.oid,
           p.oid::regprocedure AS signature,
           has_function_privilege('authenticated', p.oid, 'EXECUTE') AS auth_had_execute
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC', r.signature);
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM anon', r.signature);

    IF r.auth_had_execute THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', r.signature);
    ELSE
      EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM authenticated', r.signature);
    END IF;

    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', r.signature);
  END LOOP;
END
$$;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
;
-- RC4.1.2: funciones internas/trigger no deben ser RPC públicas para usuarios autenticados.
REVOKE EXECUTE ON FUNCTION public._loc(jsonb, public.route_stops) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public._queue_on_the_way(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public._vehicle_service_check(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.rls_auto_enable() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trg_auth_users_sync() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trg_customer_email_settings() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trg_noc_on_draft_status() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trg_notify_driver_approved() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trg_on_the_way_after_change() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trg_profiles_purge_aux() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trg_route_financing_snapshot() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trg_route_km_after_finalize() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trg_route_start_needs_vehicle() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trg_route_vehicle_from_snapshot() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trg_routes_responsable_compatible() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trg_stop_from_snapshot() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trg_transportista_has_carrier() FROM authenticated;

;
-- RC4.1.3: retirar el rol legado DESPACHO.
-- OPERARIO_DEPOSITO es el rol operativo de depósito vigente.
update public.profiles
set role = 'OPERARIO_DEPOSITO'
where role = 'DESPACHO';

delete from public.role_permissions
where role_code = 'DESPACHO';

delete from public.roles
where code = 'DESPACHO';

;
alter table public.report_settings
  add column if not exists schedule_mode text not null default 'WEEKLY',
  add column if not exists biweekly_day_1 integer not null default 1,
  add column if not exists biweekly_day_2 integer not null default 15,
  add column if not exists biweekly_time text not null default '15:00';

alter table public.report_settings drop constraint if exists report_settings_schedule_mode_check;
alter table public.report_settings
  add constraint report_settings_schedule_mode_check
  check (schedule_mode in ('OFF','WEEKLY','BIWEEKLY','MONTHLY'));

alter table public.report_settings drop constraint if exists report_settings_biweekly_days_check;
alter table public.report_settings
  add constraint report_settings_biweekly_days_check
  check (biweekly_day_1 between 1 and 28 and biweekly_day_2 between 1 and 28 and biweekly_day_1 < biweekly_day_2);

alter table public.commercial_reports drop constraint if exists commercial_reports_report_type_check;
alter table public.commercial_reports
  add constraint commercial_reports_report_type_check
  check (report_type in ('WEEKLY','BIWEEKLY','MONTHLY','MANUAL'));

;
alter table public.notification_settings
  add column if not exists service_email_enabled boolean not null default false,
  add column if not exists service_warning_km integer not null default 1000,
  add column if not exists service_repeat_km integer not null default 500,
  add column if not exists service_email_recipients text[] not null default '{}'::text[],
  add column if not exists service_copy_admin boolean not null default true,
  add column if not exists service_copy_driver boolean not null default false;

alter table public.notification_settings drop constraint if exists notification_settings_service_km_check;
alter table public.notification_settings
  add constraint notification_settings_service_km_check
  check (service_warning_km >= 0 and service_repeat_km >= 1);

create table if not exists public.vehicle_service_email_jobs (
  id uuid primary key default gen_random_uuid(),
  vehicle_id uuid not null references public.vehicles(id) on delete cascade,
  cycle_base_km numeric not null,
  alert_level text not null check (alert_level in ('UPCOMING','REQUIRED')),
  alert_bucket integer not null default 0,
  recipient text not null,
  idempotency_key text not null unique,
  status text not null default 'QUEUED' check (status in ('QUEUED','SENT','ERROR')),
  queued_at timestamptz not null default now(),
  sent_at timestamptz,
  provider_id text,
  error text,
  retry_count integer not null default 0
);

create index if not exists vehicle_service_email_jobs_status_idx
  on public.vehicle_service_email_jobs(status, queued_at);

alter table public.vehicle_service_email_jobs enable row level security;
revoke all on public.vehicle_service_email_jobs from anon, authenticated;
grant select on public.vehicle_service_email_jobs to authenticated;
grant all on public.vehicle_service_email_jobs to service_role;

drop policy if exists vehicle_service_email_jobs_admin_read on public.vehicle_service_email_jobs;
create policy vehicle_service_email_jobs_admin_read
on public.vehicle_service_email_jobs for select
to authenticated
using (public.user_has_perm(auth.uid(), 'settings.manage'));

;
create or replace function public.set_notification_settings(p jsonb)
returns public.notification_settings
language plpgsql
security definer
set search_path to 'public'
as $function$
declare s public.notification_settings;
begin
  if not public.auth_has_perm('settings.manage') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  update public.notification_settings set
    on_the_way_enabled = coalesce((p->>'on_the_way_enabled')::boolean, on_the_way_enabled),
    delivered_enabled = coalesce((p->>'delivered_enabled')::boolean, delivered_enabled),
    sheet_email_enabled = coalesce((p->>'sheet_email_enabled')::boolean, sheet_email_enabled),
    sheet_email_time = coalesce(p->>'sheet_email_time', sheet_email_time),
    sheet_email_recipients = case when p ? 'sheet_email_recipients' then coalesce((select array_agg(lower(trim(x))) from jsonb_array_elements_text(p->'sheet_email_recipients') x where trim(x) <> ''), '{}'::text[]) else sheet_email_recipients end,
    provider = coalesce(p->>'provider', provider), max_retries = coalesce((p->>'max_retries')::int, max_retries),
    service_email_enabled = coalesce((p->>'service_email_enabled')::boolean, service_email_enabled),
    service_warning_km = coalesce((p->>'service_warning_km')::int, service_warning_km),
    service_repeat_km = coalesce((p->>'service_repeat_km')::int, service_repeat_km),
    service_email_recipients = case when p ? 'service_email_recipients' then coalesce((select array_agg(lower(trim(x))) from jsonb_array_elements_text(p->'service_email_recipients') x where trim(x) <> ''), '{}'::text[]) else service_email_recipients end,
    service_copy_admin = coalesce((p->>'service_copy_admin')::boolean, service_copy_admin),
    service_copy_driver = coalesce((p->>'service_copy_driver')::boolean, service_copy_driver)
  where id = 'DEFAULT' returning * into s;
  if s.service_warning_km < 0 or s.service_repeat_km < 1 then raise exception 'INVALID_SERVICE_ALERT_SETTINGS'; end if;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'NOTIFICATION_SETTINGS_CHANGED', 'settings', 'DEFAULT', to_jsonb(s));
  return s;
end;
$function$;

;
create or replace function public.register_vehicle_service(p_vehicle uuid, p_km numeric, p_date date, p_note text default null)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if not (public.auth_has_perm('vehicles.service_manage') or public.auth_has_perm('vehicles.manage')) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_km is null or p_km <= 0 then raise exception 'BAD_KM' using errcode = '22023'; end if;
  insert into public.vehicle_services(vehicle_id, service_date, km, note, created_by) values (p_vehicle, coalesce(p_date, current_date), p_km, p_note, auth.uid());
  update public.vehicles set last_service_km = p_km, last_service_date = coalesce(p_date, current_date), current_km = greatest(current_km, p_km) where id = p_vehicle;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'VEHICLE_SERVICE_REGISTERED', 'vehicle', p_vehicle::text, jsonb_build_object('km', p_km, 'date', p_date, 'note', p_note));
  perform public._vehicle_service_check(p_vehicle);
end;
$function$;

;
drop policy if exists evidence_read on public.stop_evidence;
create policy evidence_read on public.stop_evidence
for select to authenticated
using (
  exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and p.role = 'ADMIN'
      and p.status = 'ACTIVO'
  )
  and public.can_view_route((
    select s.route_id from public.route_stops s where s.id = stop_evidence.stop_id
  ))
);

drop policy if exists delivery_receipts_read on public.delivery_receipts;
create policy delivery_receipts_read on public.delivery_receipts
for select to authenticated
using (
  exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and p.role = 'ADMIN'
      and p.status = 'ACTIVO'
  )
  and public.can_view_route(route_id)
);

;
alter table public.vehicle_service_email_jobs
  drop constraint if exists vehicle_service_email_jobs_status_check;

alter table public.vehicle_service_email_jobs
  add constraint vehicle_service_email_jobs_status_check
  check (status = any (array['QUEUED'::text,'SENT'::text,'ERROR'::text,'CANCELLED'::text]));

;
insert into public.role_permissions(role_code, permission_code)
values ('OPERARIO_DEPOSITO','routes.publish')
on conflict do nothing;

insert into public.audit_log(actor_id, action, target_type, target_id, after)
values (null, 'ROLE_PERMISSION_DEFAULT_SET', 'role', 'OPERARIO_DEPOSITO',
        jsonb_build_object('permission','routes.publish','reason','El Operario Depósito publica sus propias hojas de ruta.'));

;
-- RC4.1.21 · Corrección controlada post-publicación.
-- La hoja conserva id/número; una republicación aprobada incrementa routes.version.

CREATE OR REPLACE FUNCTION public.begin_post_publish_revision(p_route uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r public.routes;
  d public.route_drafts;
  q public.route_approval_requests;
  rows_json jsonb;
  c jsonb;
begin
  if not public.auth_has_perm('routes.create') then
    raise exception 'FORBIDDEN' using errcode='42501';
  end if;

  select * into r from public.routes where id=p_route for update;
  if not found then raise exception 'NOT_FOUND' using errcode='P0002'; end if;
  if r.operational_status <> 'PUBLICADA' or r.started_at is not null then
    raise exception 'REVISION_NOT_ALLOWED: solo se corrige una hoja PUBLICADA que todavía no inició' using errcode='23514';
  end if;
  if exists(select 1 from public.route_stops where route_id=r.id and outcome <> 'PENDIENTE')
     or exists(select 1 from public.stop_evidence e join public.route_stops s on s.id=e.stop_id where s.route_id=r.id)
     or exists(select 1 from public.delivery_receipts e where e.route_id=r.id) then
    raise exception 'REVISION_HAS_EXECUTION: la hoja ya tiene trazabilidad de entrega' using errcode='23514';
  end if;

  select * into q
  from public.route_approval_requests
  where route_id=r.id
    and route_version=r.version
    and request_type='CAMBIO_POST_PUBLICACION'
    and status='APPROVED'
    and (requested_by=auth.uid() or public.auth_is_admin() or public.auth_has_perm('routes.edit'))
  order by reviewed_at desc nulls last, requested_at desc
  limit 1;

  if not found then
    raise exception 'APPROVAL_REQUIRED: necesitás una solicitud CAMBIO POST PUBLICACIÓN aprobada para esta versión' using errcode='42501';
  end if;

  select * into d from public.route_drafts where route_id=r.id for update;
  if not found then raise exception 'REVISION_DRAFT_NOT_FOUND' using errcode='P0002'; end if;
  if not public.can_manage_draft_of(d.owner_id) then
    raise exception 'FORBIDDEN_DRAFT: la hoja pertenece a otro operador' using errcode='42501';
  end if;

  c := d.content;
  if c is null or jsonb_array_length(coalesce(c->'rows','[]'::jsonb))=0 then
    select coalesce(jsonb_agg(x->'r'), '[]'::jsonb)
      into rows_json
      from jsonb_array_elements(coalesce(r.sheet_snapshot->'pdf_model'->'data','[]'::jsonb)) x
      where x ? 'r';

    if jsonb_array_length(coalesce(rows_json,'[]'::jsonb))=0 then
      raise exception 'REVISION_SOURCE_UNAVAILABLE: esta hoja antigua no tiene snapshot suficiente para reconstruir el borrador' using errcode='23514';
    end if;

    c := jsonb_build_object(
      'rows', rows_json,
      'selected', '[]'::jsonb,
      'sheetDate', coalesce(rows_json->0->>'fecha', to_char((r.published_at at time zone 'America/Argentina/Mendoza')::date,'YYYY-MM-DD')),
      'audit', '[]'::jsonb,
      'showCash', true,
      'showCheques', true,
      'showTransfers', true,
      'oldDecisions', '{}'::jsonb,
      'sheetId', r.sheet_key,
      'published', null
    );
  end if;

  c := c || jsonb_build_object(
    'sheetId', r.sheet_key,
    'published', null,
    'revision', jsonb_build_object('route_id',r.id,'number',r.number,'version',r.version,'request_id',q.id)
  );

  update public.route_drafts
     set status='BORRADOR', content=c, updated_at=now()
   where id=d.id
   returning * into d;

  update public.route_approval_requests
     set payload=coalesce(payload,'{}'::jsonb) || jsonb_build_object('revision_started_at',now(),'revision_from_version',r.version),
         updated_at=now()
   where id=q.id;

  insert into public.audit_log(actor_id,action,target_type,target_id,before,after)
  values(auth.uid(),'POST_PUBLISH_REVISION_OPENED','route',r.id::text,
         jsonb_build_object('version',r.version),
         jsonb_build_object('version',r.version,'request',q.id,'sheet_key',r.sheet_key));

  return jsonb_build_object('sheet_key',r.sheet_key,'name',coalesce(d.name,'Hoja '||r.number),'content',c,'route_id',r.id,'number',r.number,'version',r.version);
end;
$function$;

CREATE OR REPLACE FUNCTION public.publish_route_revision(p jsonb)
 RETURNS routes
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r public.routes;
  d public.route_drafts;
  q public.route_approval_requests;
  resp uuid := nullif(p->>'responsable_id','')::uuid;
  car text := p->>'carrier_id';
  s jsonb;
  i int := 0;
  ships text[];
  old_ords text[];
  new_ords text[];
  new_ver int;
  snap jsonb;
  e jsonb;
  f public.financing_plans;
begin
  if not public.auth_has_perm('routes.publish') then raise exception 'FORBIDDEN' using errcode='42501'; end if;
  if coalesce(p->>'revision_route_id','')='' then raise exception 'REVISION_ROUTE_REQUIRED' using errcode='22023'; end if;

  d := public._draft(p->>'sheet_key', false, true);
  if d.id is null or d.route_id is null or d.route_id::text <> p->>'revision_route_id' then
    raise exception 'REVISION_DRAFT_MISMATCH' using errcode='23514';
  end if;

  select * into r from public.routes where id=d.route_id for update;
  if not found then raise exception 'NOT_FOUND' using errcode='P0002'; end if;
  if r.version <> coalesce(nullif(p->>'revision_version','')::int,-1) then
    raise exception 'VERSION_CONFLICT: la hoja cambió (versión %)',r.version using errcode='40001';
  end if;
  if r.operational_status <> 'PUBLICADA' or r.started_at is not null then
    raise exception 'REVISION_NOT_ALLOWED: la hoja ya inició o cambió de estado' using errcode='23514';
  end if;
  if exists(select 1 from public.route_stops where route_id=r.id and outcome <> 'PENDIENTE')
     or exists(select 1 from public.stop_evidence e join public.route_stops s2 on s2.id=e.stop_id where s2.route_id=r.id)
     or exists(select 1 from public.delivery_receipts e where e.route_id=r.id) then
    raise exception 'REVISION_HAS_EXECUTION: la hoja ya tiene trazabilidad de entrega' using errcode='23514';
  end if;

  select * into q
  from public.route_approval_requests
  where route_id=r.id and route_version=r.version
    and request_type='CAMBIO_POST_PUBLICACION' and status='APPROVED'
    and (requested_by=auth.uid() or public.auth_is_admin() or public.auth_has_perm('routes.edit'))
  order by reviewed_at desc nulls last, requested_at desc limit 1;
  if not found then raise exception 'APPROVAL_REQUIRED' using errcode='42501'; end if;

  if car is null or car <> r.carrier_id then
    raise exception 'REVISION_CARRIER_LOCKED: el transportista no se cambia en una corrección; usá el flujo específico' using errcode='23514';
  end if;
  if resp is null or not public.can_be_responsable(resp,car) then raise exception 'RESPONSABLE_INCOMPATIBLE' using errcode='23514'; end if;
  if jsonb_array_length(coalesce(p->'stops','[]'::jsonb))=0 then raise exception 'EMPTY_SHEET' using errcode='23514'; end if;
  if exists(select 1 from jsonb_array_elements(p->'stops') x where coalesce((x->>'ready')::boolean,false)=false) then
    raise exception 'NOT_READY: hay pedidos con revisión pendiente o sin monto' using errcode='23514';
  end if;

  select array_agg(distinct v order by v) into new_ords
    from jsonb_array_elements(p->'stops') x, jsonb_array_elements_text(x->'order_numbers') v;
  select array_agg(order_id order by order_id) into old_ords
    from public.order_reservations where route_id=r.id and status='PUBLICADA';

  if coalesce(new_ords,'{}'::text[]) is distinct from coalesce(old_ords,'{}'::text[]) then
    raise exception 'REVISION_ORDERS_LOCKED: para proteger reservas y NOC, una corrección no puede agregar ni quitar pedidos; cancelá/replanificá si cambia el conjunto de pedidos' using errcode='23514';
  end if;

  select array_agg(x->>'ship_order') into ships from jsonb_array_elements(p->'stops') x where x->>'ship_fee_status'='PROVISIONAL';
  if ships is not null then perform public.assert_sheet_shipping_ready(p->>'sheet_key',ships); end if;

  new_ver := r.version + 1;
  snap := p - 'draft_content';

  update public.routes
     set responsable_id=resp,
         vehicle_id=case when coalesce(p->>'vehicle_id','')='' then vehicle_id else (p->>'vehicle_id')::uuid end,
         version=new_ver,
         sheet_snapshot=snap,
         notified_at=null,
         viewed_at=null
   where id=r.id
   returning * into r;

  delete from public.route_stops where route_id=r.id;
  for s in select * from jsonb_array_elements(p->'stops') loop
    i := i+1;
    insert into public.route_stops(
      route_id,seq,sequence_number,provenance,client_name,client_key,zone,order_numbers,
      merchandise_amount,shipping_fee,shipping_fee_source,bultos,address,action,task,expected_amount,customer_email
    )
    values(
      r.id,i,i,'PUBLISHED',s->>'client_name',s->>'client_key',nullif(s->>'zone',''),
      coalesce((select array_agg(v) from jsonb_array_elements_text(s->'order_numbers') v),'{}'),
      coalesce((s->>'merchandise_amount')::numeric,0),coalesce((s->>'shipping_fee')::numeric,0),
      case when s->>'ship_fee_status'='PROVISIONAL' then 'CONFIRMED_FALLBACK' else 'SALDO' end,
      nullif(s->>'bultos','')::int,s->>'address',coalesce(s->>'action','ENTREGA'),
      coalesce(nullif(s->>'task',''),'ENTREGA'),nullif(s->>'expected_amount','')::numeric,nullif(s->>'customer_email','')
    );
  end loop;

  -- snapshot financiero de la nueva versión, con la misma lógica del trigger de publicación inicial
  for e in select * from jsonb_array_elements(coalesce(r.sheet_snapshot->'financing','[]'::jsonb)) loop
    f := null;
    if coalesce(e->>'plan_id','')<>'' then select * into f from public.financing_plans where id=(e->>'plan_id')::uuid; end if;
    insert into public.route_financing_snapshots(
      route_id,route_version,comp,client_name,client_cuit,parts_count,parts,total,classification,resolver_version,
      plan_id,frequency,source_pending,noc_adjustments,operational_pending,source_import
    )
    values(
      r.id,new_ver,coalesce(e->>'comp',f.comp),coalesce(e->>'client_name',f.client_name),coalesce(e->>'client_key',f.client_key),
      jsonb_array_length(coalesce(e->'parts',f.parts,'[]'::jsonb)),coalesce(e->'parts',f.parts,'[]'::jsonb),
      coalesce(f.operational_pending,(e->>'total')::numeric),coalesce(e->>'classification','FINANCIACION_PROPIA_VIGENTE'),
      coalesce(e->>'resolver_version',f.resolver_version,'fin-2'),f.id,coalesce(f.frequency,e->>'frequency'),
      f.source_pending,f.noc_adjustments,f.operational_pending,coalesce(e->>'import_id',f.last_import_id)
    )
    on conflict(route_id,route_version,comp) do nothing;
  end loop;

  update public.route_drafts
     set status='PUBLICADA',
         content=coalesce(p->'draft_content',content),
         delivery_count=i,
         orders=coalesce(new_ords,'{}'::text[]),
         updated_at=now()
   where id=d.id;

  update public.route_approval_requests
     set applied=true,
         payload=coalesce(payload,'{}'::jsonb) || jsonb_build_object('applied_at',now(),'applied_version',new_ver),
         updated_at=now()
   where id=q.id;

  insert into public.notifications(user_id,route_id,route_version,type,title,body)
  values(resp,r.id,new_ver,'HOJA_CORREGIDA','HOJA CORREGIDA · NUEVA VERSIÓN','Hoja '||r.number||' · versión '||new_ver||' · '||i||' entregas')
  on conflict do nothing;

  insert into public.audit_log(actor_id,action,target_type,target_id,before,after)
  values(auth.uid(),'POST_PUBLISH_REVISION_PUBLISHED','route',r.id::text,
         jsonb_build_object('version',new_ver-1,'request',q.id),
         jsonb_build_object('version',new_ver,'request',q.id,'stops',i,'responsable',resp));

  return r;
end;
$function$;

revoke all on function public.begin_post_publish_revision(uuid) from public;
grant execute on function public.begin_post_publish_revision(uuid) to authenticated;
revoke all on function public.publish_route_revision(jsonb) from public;
grant execute on function public.publish_route_revision(jsonb) to authenticated;

;
-- RC4.1.22 · Guardas para borradores de corrección post-publicación.

CREATE OR REPLACE FUNCTION public.trg_revision_reservation_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare d public.route_drafts;
begin
  select * into d from public.route_drafts where client_sheet_key=new.sheet_key;
  if d.route_id is not null
     and not exists(
       select 1 from public.order_reservations x
       where x.order_id=new.order_id and x.route_id=d.route_id and x.status='PUBLICADA'
     ) then
    raise exception 'REVISION_ORDERS_LOCKED: una corrección post-publicación no puede agregar pedidos; cancelá/replanificá si cambia el conjunto de pedidos'
      using errcode='23514';
  end if;
  return new;
end;
$function$;

drop trigger if exists revision_reservation_guard on public.order_reservations;
create trigger revision_reservation_guard before insert on public.order_reservations for each row execute function public.trg_revision_reservation_guard();
revoke all on function public.trg_revision_reservation_guard() from public, anon, authenticated;

CREATE OR REPLACE FUNCTION public.delete_draft(p_sheet_key text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare d public.route_drafts; n int;
begin
  if not public.auth_has_perm('routes.create') then raise exception 'FORBIDDEN' using errcode='42501'; end if;
  d := public._draft(p_sheet_key, false);
  if d.id is null then return 0; end if;

  -- Un borrador ligado a una hoja publicada es una corrección versionada.
  -- "Eliminar" esa corrección vuelve a dejar intacta la hoja publicada.
  if d.route_id is not null then
    update public.route_drafts set status='PUBLICADA', updated_at=now() where id=d.id;
    insert into public.audit_log(actor_id,action,target_type,target_id,after)
    values(auth.uid(),'POST_PUBLISH_REVISION_CANCELLED','route',d.route_id::text,
           jsonb_build_object('sheet_key',p_sheet_key,'reason','revision draft discarded'));
    return -1;
  end if;

  delete from public.order_reservations
   where sheet_key=p_sheet_key and status='BORRADOR';
  get diagnostics n=row_count;
  delete from public.shipping_amount_confirmations where sheet_key=p_sheet_key and route_id is null;
  update public.route_drafts set status='CANCELADA',content=null,orders='{}',updated_at=now() where id=d.id;
  insert into public.audit_log(actor_id,action,target_type,target_id,after)
  values(auth.uid(),'DRAFT_DELETED','draft',p_sheet_key,jsonb_build_object('released',n,'owner',d.owner_id,'name',d.name));
  return n;
end;
$function$;

;
insert into public.permissions(code) values
  ('carriers.manage'),
  ('drafts.manage_all')
on conflict (code) do nothing;

insert into public.role_permissions(role_code, permission_code) values
  ('OPERARIO_DEPOSITO','routes.create'),
  ('OPERARIO_DEPOSITO','routes.edit'),
  ('OPERARIO_DEPOSITO','routes.publish'),
  ('OPERARIO_DEPOSITO','routes.assign'),
  ('OPERARIO_DEPOSITO','routes.view_all'),
  ('OPERARIO_DEPOSITO','routes.view_own'),
  ('OPERARIO_DEPOSITO','drafts.create'),
  ('OPERARIO_DEPOSITO','drafts.view_own'),
  ('OPERARIO_DEPOSITO','drafts.manage_all'),
  ('OPERARIO_DEPOSITO','requests.create'),
  ('OPERARIO_DEPOSITO','columns.view'),
  ('OPERARIO_DEPOSITO','columns.manage_defaults'),
  ('OPERARIO_DEPOSITO','columns.manage_templates'),
  ('OPERARIO_DEPOSITO','locations.view'),
  ('OPERARIO_DEPOSITO','vehicle_mileage.view'),
  ('OPERARIO_DEPOSITO','vehicle_mileage.enter'),
  ('OPERARIO_DEPOSITO','vehicles.view'),
  ('OPERARIO_DEPOSITO','vehicles.service_manage'),
  ('OPERARIO_DEPOSITO','carriers.manage')
on conflict (role_code, permission_code) do nothing;

create or replace function public.can_manage_draft_of(p_owner uuid)
returns boolean
language sql
stable
security definer
set search_path = 'public'
as $$
  select p_owner = auth.uid()
    or public.auth_has_perm('drafts.manage_all')
    or public.auth_has_perm('routes.manage_all_drafts')
    or (public.auth_has_perm('drafts.manage_team') and public.in_my_team(p_owner));
$$;

create or replace function public.can_view_draft_of(p_owner uuid)
returns boolean
language sql
stable
security definer
set search_path = 'public'
as $$
  select public.can_manage_draft_of(p_owner)
    or (public.auth_has_perm('drafts.view_team') and public.in_my_team(p_owner));
$$;

create or replace function public.upsert_carrier(p jsonb)
returns public.carriers
language plpgsql
security definer
set search_path = 'public'
as $$
declare c public.carriers;
begin
  if not (public.auth_has_perm('settings.manage') or public.auth_has_perm('carriers.manage')) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if coalesce(p->>'id', '') = '' or coalesce(p->>'name', '') = '' then
    raise exception 'BAD_CARRIER: id y nombre obligatorios' using errcode = '23514';
  end if;
  if coalesce(p->>'sequence_code', '') !~ '^[0-9]{2}$' then
    raise exception 'BAD_CODE: el código de correlativo son 2 dígitos' using errcode = '23514';
  end if;
  insert into public.carriers(id, name, kind, active, sequence_code, report_group, emails, notes)
  values (
    upper(p->>'id'),
    upper(p->>'name'),
    coalesce(p->>'kind', 'EXTERNO'),
    coalesce((p->>'active')::boolean, true),
    p->>'sequence_code',
    nullif(p->>'report_group', ''),
    coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(p->'emails','[]'::jsonb)) x), '{}'),
    p->>'notes'
  )
  on conflict (id) do update set
    name = excluded.name,
    kind = excluded.kind,
    active = excluded.active,
    sequence_code = excluded.sequence_code,
    report_group = excluded.report_group,
    emails = excluded.emails,
    notes = excluded.notes
  returning * into c;

  insert into public.audit_log(actor_id, action, target_type, target_id, after)
  values (auth.uid(), 'CARRIER_SAVED', 'carrier', c.id, to_jsonb(c));
  return c;
end;
$$;

revoke execute on function public.upsert_carrier(jsonb) from public;
grant execute on function public.upsert_carrier(jsonb) to authenticated;

;
alter table public.routes add column if not exists dispatch_mode text not null default 'APP';
alter table public.routes add column if not exists dispatched_at timestamptz;
alter table public.routes add column if not exists dispatched_by uuid references public.profiles(id);

do $$ begin
  if not exists (select 1 from pg_constraint where conname='routes_dispatch_mode_check') then
    alter table public.routes add constraint routes_dispatch_mode_check check (dispatch_mode in ('APP','EXTERNAL'));
  end if;
end $$;

create or replace function public.dispatch_external_route(p jsonb)
returns public.routes
language plpgsql
security definer
set search_path='public'
as $$
declare
  r public.routes;
  d public.route_drafts;
  car text := p->>'carrier_id';
  c public.carriers;
  s jsonb;
  i int := 0;
  ships text[];
  ords text[];
begin
  if not public.auth_has_perm('routes.publish') then
    raise exception 'FORBIDDEN' using errcode='42501';
  end if;
  d := public._draft(p->>'sheet_key', true, false);
  if d.status='PUBLICADA' then
    select * into r from public.routes where id=d.route_id;
    return r;
  end if;
  if d.status <> 'BORRADOR' then raise exception 'DRAFT_CANCELLED' using errcode='23514'; end if;

  select * into c from public.carriers where id=car and active;
  if not found then raise exception 'BAD_CARRIER: elegí el transportista' using errcode='23514'; end if;
  if c.kind <> 'EXTERNO' or c.report_group='CRISTIAN_TORRES' then
    raise exception 'NOT_EXTERNAL_DISPATCH: este transportista usa PUBLICAR HOJA' using errcode='23514';
  end if;

  if jsonb_array_length(coalesce(p->'stops','[]'::jsonb))=0 then raise exception 'EMPTY_SHEET: la hoja no tiene pedidos' using errcode='23514'; end if;
  select array_agg(x->>'ship_order') into ships from jsonb_array_elements(p->'stops') x where x->>'ship_fee_status'='PROVISIONAL';
  if ships is not null then perform public.assert_sheet_shipping_ready(p->>'sheet_key', ships); end if;
  if exists(select 1 from jsonb_array_elements(p->'stops') x where coalesce((x->>'ready')::boolean,false)=false) then
    raise exception 'NOT_READY: hay pedidos con revisión pendiente o sin monto' using errcode='23514';
  end if;
  select array_agg(distinct v) into ords from jsonb_array_elements(p->'stops') x, jsonb_array_elements_text(x->'order_numbers') v;
  perform public.reserve_orders(p->>'sheet_key', ords);

  insert into public.routes(number,carrier_id,responsable_id,status,operational_status,created_by,sheet_key,published_at,published_by,completed_at,completed_by,dispatched_at,dispatched_by,dispatch_mode,sheet_snapshot)
  values(public.next_route_number_for(car),car,null,'COMPLETADA','COMPLETADA',auth.uid(),p->>'sheet_key',now(),auth.uid(),now(),auth.uid(),now(),auth.uid(),'EXTERNAL',p)
  returning * into r;

  update public.order_reservations set status='PUBLICADA',route_id=r.id where sheet_key=p->>'sheet_key';
  update public.route_drafts set status='PUBLICADA',route_id=r.id,updated_at=now() where id=d.id;

  for s in select * from jsonb_array_elements(p->'stops') loop
    i:=i+1;
    insert into public.route_stops(route_id,seq,sequence_number,provenance,client_name,client_key,zone,order_numbers,merchandise_amount,shipping_fee,shipping_fee_source,bultos,address,action,task,expected_amount,customer_email)
    values(r.id,i,i,'PUBLISHED',s->>'client_name',s->>'client_key',nullif(s->>'zone',''),
      coalesce((select array_agg(v) from jsonb_array_elements_text(s->'order_numbers') v),'{}'),
      coalesce((s->>'merchandise_amount')::numeric,0),coalesce((s->>'shipping_fee')::numeric,0),
      case when s->>'ship_fee_status'='PROVISIONAL' then 'CONFIRMED_FALLBACK' else 'SALDO' end,
      nullif(s->>'bultos','')::int,s->>'address',coalesce(s->>'action','ENTREGA'),coalesce(s->>'task','ENTREGA'),
      nullif(s->>'expected_amount','')::numeric,nullif(s->>'customer_email',''));
  end loop;

  insert into public.audit_log(actor_id,action,target_type,target_id,after)
  values(auth.uid(),'EXTERNAL_ROUTE_DISPATCHED','route',r.id::text,jsonb_build_object('number',r.number,'carrier',car,'stops',i,'dispatch_mode','EXTERNAL'));
  return r;
end;
$$;

revoke execute on function public.dispatch_external_route(jsonb) from public;
grant execute on function public.dispatch_external_route(jsonb) to authenticated;

;
create table if not exists public.push_vapid_config(
  id text primary key,
  public_key text not null,
  private_key text not null,
  created_at timestamptz not null default now()
);
alter table public.push_vapid_config enable row level security;

create table if not exists public.push_subscriptions(
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  user_agent text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  revoked_at timestamptz
);
alter table public.push_subscriptions enable row level security;
create index if not exists push_subscriptions_user_idx on public.push_subscriptions(user_id) where revoked_at is null;

create table if not exists public.push_jobs(
  id uuid primary key default gen_random_uuid(),
  notification_id uuid not null unique references public.notifications(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'QUEUED' check(status in ('QUEUED','SENT','ERROR','SKIPPED')),
  attempt_count int not null default 0,
  last_error text,
  created_at timestamptz not null default now(),
  processed_at timestamptz
);
alter table public.push_jobs enable row level security;
create index if not exists push_jobs_status_idx on public.push_jobs(status,created_at);

create or replace function public.push_public_key()
returns text language plpgsql security definer set search_path='public' as $$
declare k text;
begin
  if auth.uid() is null then raise exception 'NO_AUTH' using errcode='42501'; end if;
  select public_key into k from public.push_vapid_config where id='DEFAULT';
  return k;
end; $$;
revoke execute on function public.push_public_key() from public;
grant execute on function public.push_public_key() to authenticated;

create or replace function public.save_push_subscription(p jsonb)
returns public.push_subscriptions language plpgsql security definer set search_path='public' as $$
declare r public.push_subscriptions;
begin
  if auth.uid() is null then raise exception 'NO_AUTH' using errcode='42501'; end if;
  if coalesce(trim(p->>'endpoint'),'')='' or coalesce(trim(p->>'p256dh'),'')='' or coalesce(trim(p->>'auth'),'')='' then
    raise exception 'BAD_SUBSCRIPTION' using errcode='22023';
  end if;
  insert into public.push_subscriptions(user_id,endpoint,p256dh,auth,user_agent,revoked_at,updated_at)
  values(auth.uid(),p->>'endpoint',p->>'p256dh',p->>'auth',nullif(p->>'user_agent',''),null,now())
  on conflict(endpoint) do update set
    user_id=excluded.user_id,p256dh=excluded.p256dh,auth=excluded.auth,user_agent=excluded.user_agent,revoked_at=null,updated_at=now()
  returning * into r;
  return r;
end; $$;
revoke execute on function public.save_push_subscription(jsonb) from public;
grant execute on function public.save_push_subscription(jsonb) to authenticated;

create or replace function public.revoke_push_subscription(p_endpoint text)
returns boolean language plpgsql security definer set search_path='public' as $$
begin
  if auth.uid() is null then raise exception 'NO_AUTH' using errcode='42501'; end if;
  update public.push_subscriptions set revoked_at=now(),updated_at=now()
   where endpoint=p_endpoint and user_id=auth.uid() and revoked_at is null;
  return found;
end; $$;
revoke execute on function public.revoke_push_subscription(text) from public;
grant execute on function public.revoke_push_subscription(text) to authenticated;

create or replace function public.queue_notification_push()
returns trigger language plpgsql security definer set search_path='public' as $$
begin
  if new.type in ('NUEVA_HOJA_PUBLICADA','HOJA_CORREGIDA','REQUEST_CREATED','REQUEST_APPROVED','REQUEST_REJECTED','REQUEST_OBSERVED') then
    insert into public.push_jobs(notification_id,user_id)
    values(new.id,new.user_id)
    on conflict(notification_id) do nothing;
  end if;
  return new;
end; $$;

drop trigger if exists trg_queue_notification_push on public.notifications;
create trigger trg_queue_notification_push
after insert on public.notifications
for each row execute function public.queue_notification_push();

revoke all on public.push_vapid_config from anon, authenticated;
revoke all on public.push_subscriptions from anon, authenticated;
revoke all on public.push_jobs from anon, authenticated;

;
drop policy if exists carriers_authenticated_read on public.carriers;
create policy carriers_authenticated_read
on public.carriers
for select
to authenticated
using (true);

;
create table if not exists public.password_recovery_limits (
  scope text not null check (scope in ('EMAIL','IP')),
  key_hash text not null,
  window_started_at timestamptz not null default now(),
  request_count integer not null default 1 check (request_count > 0),
  updated_at timestamptz not null default now(),
  primary key (scope, key_hash)
);

alter table public.password_recovery_limits enable row level security;
revoke all on table public.password_recovery_limits from anon, authenticated;

create or replace function public.consume_password_recovery_limit(
  p_scope text,
  p_key_hash text,
  p_window_seconds integer,
  p_max_count integer
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  if p_scope not in ('EMAIL','IP')
     or coalesce(length(p_key_hash),0) < 16
     or p_window_seconds < 1
     or p_max_count < 1 then
    return false;
  end if;

  insert into public.password_recovery_limits(scope,key_hash,window_started_at,request_count,updated_at)
  values(p_scope,p_key_hash,now(),1,now())
  on conflict (scope,key_hash) do update
  set
    window_started_at = case
      when password_recovery_limits.window_started_at < now() - make_interval(secs => p_window_seconds)
      then now()
      else password_recovery_limits.window_started_at
    end,
    request_count = case
      when password_recovery_limits.window_started_at < now() - make_interval(secs => p_window_seconds)
      then 1
      else password_recovery_limits.request_count + 1
    end,
    updated_at = now()
  returning request_count into v_count;

  return v_count <= p_max_count;
end;
$$;

revoke execute on function public.consume_password_recovery_limit(text,text,integer,integer) from public, anon, authenticated;
grant execute on function public.consume_password_recovery_limit(text,text,integer,integer) to service_role;

;
-- G2 · Ubicaciones para Transportista Interno
create table if not exists public.internal_locations (
  location_key text primary key,
  name text not null,
  address text,
  lat double precision not null,
  lon double precision not null,
  radius_m integer not null default 200 check (radius_m > 0),
  active boolean not null default true,
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint internal_locations_lat check (abs(lat) <= 90),
  constraint internal_locations_lon check (abs(lon) <= 180)
);
alter table public.internal_locations enable row level security;
drop policy if exists internal_locations_admin_read on public.internal_locations;
create policy internal_locations_admin_read on public.internal_locations for select to authenticated
using (public.auth_has_perm('settings.manage') or public.auth_has_perm('locations.manage'));
grant select on public.internal_locations to authenticated;

alter table public.route_stops add column if not exists internal_location_key text references public.internal_locations(location_key);
create index if not exists route_stops_internal_location_idx on public.route_stops(internal_location_key);

create or replace function public.upsert_internal_location(p jsonb) returns public.internal_locations
language plpgsql security definer set search_path=public as $$
declare l public.internal_locations;
begin
  if not (public.auth_has_perm('settings.manage') or public.auth_has_perm('locations.manage')) then raise exception 'FORBIDDEN' using errcode='42501'; end if;
  if coalesce(trim(p->>'location_key'),'')='' or coalesce(trim(p->>'name'),'')='' or (p->>'lat') is null or (p->>'lon') is null then raise exception 'BAD_LOCATION: completá clave, nombre y coordenadas' using errcode='23514'; end if;
  if abs((p->>'lat')::float8)>90 or abs((p->>'lon')::float8)>180 then raise exception 'BAD_LOCATION: coordenadas inválidas' using errcode='23514'; end if;
  insert into public.internal_locations(location_key,name,address,lat,lon,radius_m,active,note,updated_at)
  values (upper(trim(p->>'location_key')),trim(p->>'name'),nullif(trim(p->>'address'),''),(p->>'lat')::float8,(p->>'lon')::float8,greatest(coalesce((p->>'radius_m')::int,200),1),coalesce((p->>'active')::boolean,true),nullif(trim(p->>'note'),''),now())
  on conflict(location_key) do update set name=excluded.name,address=excluded.address,lat=excluded.lat,lon=excluded.lon,radius_m=excluded.radius_m,active=excluded.active,note=excluded.note,updated_at=now()
  returning * into l;
  insert into public.audit_log(actor_id,action,target_type,target_id,after) values(auth.uid(),'INTERNAL_LOCATION_SAVED','internal_location',l.location_key,to_jsonb(l));
  return l;
end $$;
grant execute on function public.upsert_internal_location(jsonb) to authenticated,service_role;

create or replace function public._match_internal_location(st public.route_stops) returns text
language plpgsql stable security definer set search_path=public as $$
declare k text;
begin
  if st.internal_location_key is not null then select location_key into k from public.internal_locations where location_key=st.internal_location_key and active; if found then return k; end if; end if;
  if st.client_key is not null then select location_key into k from public.internal_locations where active and upper(location_key)=upper(trim(st.client_key)) limit 1; if found then return k; end if; end if;
  select location_key into k from public.internal_locations
  where active and (lower(trim(name))=lower(trim(st.client_name)) or (coalesce(trim(address),'')<>'' and coalesce(trim(st.address),'')<>'' and lower(regexp_replace(trim(address),'\\s+',' ','g'))=lower(regexp_replace(trim(st.address),'\\s+',' ','g'))))
  order by case when lower(trim(name))=lower(trim(st.client_name)) then 0 else 1 end limit 1;
  return k;
end $$;
revoke execute on function public._match_internal_location(public.route_stops) from public,anon,authenticated;

create or replace function public._loc(p jsonb, st public.route_stops) returns jsonb
language plpgsql stable security definer set search_path=public as $$
declare cm public.client_locations; im public.internal_locations; d double precision; is_internal boolean:=false; ik text; radius int; expected_lat double precision; expected_lon double precision; source text;
begin
  if p is null then raise exception 'LOCATION_REQUIRED: registrá la ubicación o indicá por qué no se pudo' using errcode='23514'; end if;
  if p ? 'lat' and p ? 'lon' then
    select exists(select 1 from public.routes r join public.carriers c on c.id=r.carrier_id where r.id=st.route_id and c.kind='INTERNO') into is_internal;
    if is_internal then ik:=public._match_internal_location(st); if ik is not null then select * into im from public.internal_locations where location_key=ik and active; if found then expected_lat:=im.lat; expected_lon:=im.lon; radius:=im.radius_m; source:='INTERNAL'; end if; end if; end if;
    if expected_lat is null and st.client_key is not null then select * into cm from public.client_locations where client_key=st.client_key and active; if found then expected_lat:=cm.lat; expected_lon:=cm.lon; radius:=cm.radius_m; source:='CLIENT'; end if; end if;
    if expected_lat is not null then d:=public._dist_m(expected_lat,expected_lon,(p->>'lat')::float8,(p->>'lon')::float8); end if;
    return jsonb_build_object('lat',(p->>'lat')::float8,'lon',(p->>'lon')::float8,'accuracy',nullif(p->>'accuracy','')::float8,'at',now(),'validation_source',source,'validation_key',case when source='INTERNAL' then ik else st.client_key end,'distance_m',case when d is not null then round(d) end,'radius_m',radius,'outside_m',case when d is not null and radius is not null and d>radius then round(d) end);
  end if;
  if coalesce(trim(p->>'missing_reason'),'')='' then raise exception 'LOCATION_REASON_REQUIRED: sin ubicación hay que indicar el motivo' using errcode='23514'; end if;
  return jsonb_build_object('missing_reason',trim(p->>'missing_reason'),'at',now());
end $$;
revoke execute on function public._loc(jsonb,public.route_stops) from public,anon,authenticated;

create or replace function public._assign_internal_location() returns trigger
language plpgsql security definer set search_path=public as $$
declare is_internal boolean; k text;
begin
  if new.internal_location_key is not null then return new; end if;
  select exists(select 1 from public.routes r join public.carriers c on c.id=r.carrier_id where r.id=new.route_id and c.kind='INTERNO') into is_internal;
  if not is_internal then return new; end if;
  if new.client_key is not null then select location_key into k from public.internal_locations where active and upper(location_key)=upper(trim(new.client_key)) limit 1; end if;
  if k is null then select location_key into k from public.internal_locations where active and (lower(trim(name))=lower(trim(new.client_name)) or (coalesce(trim(address),'')<>'' and coalesce(trim(new.address),'')<>'' and lower(regexp_replace(trim(address),'\\s+',' ','g'))=lower(regexp_replace(trim(new.address),'\\s+',' ','g')))) order by case when lower(trim(name))=lower(trim(new.client_name)) then 0 else 1 end limit 1; end if;
  new.internal_location_key:=k; return new;
end $$;
drop trigger if exists trg_assign_internal_location on public.route_stops;
create trigger trg_assign_internal_location before insert or update of client_key,client_name,address,route_id,internal_location_key on public.route_stops for each row execute function public._assign_internal_location();
revoke execute on function public._assign_internal_location() from public,anon,authenticated;

;
alter table public.route_stops add column if not exists stop_type text not null default 'PEDIDO';
alter table public.route_stops add column if not exists instructions text;
alter table public.route_stops add column if not exists contact_name text;
alter table public.route_stops add column if not exists contact_phone text;
do $$ begin
  if not exists (select 1 from pg_constraint where conrelid='public.route_stops'::regclass and conname='route_stops_stop_type_check') then
    alter table public.route_stops add constraint route_stops_stop_type_check check (stop_type in ('PEDIDO','UBICACION_INTERNA','TAREA'));
  end if;
end $$;
create or replace function public._fill_stop_metadata_from_snapshot() returns trigger
language plpgsql security definer set search_path=public as $$
declare s jsonb;
begin
  select sheet_snapshot->'stops'->(new.seq-1) into s from public.routes where id=new.route_id;
  if s is not null then
    new.stop_type:=coalesce(nullif(s->>'stop_type',''),new.stop_type,'PEDIDO');
    new.instructions:=nullif(s->>'instructions','');
    new.contact_name:=nullif(s->>'contact_name','');
    new.contact_phone:=nullif(s->>'contact_phone','');
    if coalesce(s->>'internal_location_key','')<>'' then new.internal_location_key:=s->>'internal_location_key'; end if;
  end if;
  return new;
end $$;
drop trigger if exists trg_fill_stop_metadata_from_snapshot on public.route_stops;
create trigger trg_fill_stop_metadata_from_snapshot before insert on public.route_stops for each row execute function public._fill_stop_metadata_from_snapshot();
revoke execute on function public._fill_stop_metadata_from_snapshot() from public,anon,authenticated;

;
-- OK DESPACHO ONLINE — Corrección de la revisión técnica (INFORME_REVISION_CLAUDE.md): ubicaciones internas (G2), TAREA y traslados.
-- Incremental y forward-only. No renombra ni modifica migraciones aplicadas. Número mayor a todas las existentes para quedar último
-- tanto por número como por fecha real de creación (ver tests/sql/migration_order.txt).
-- Reglas de negocio: UBICACION_INTERNA = traslado interno (no es entrega comercial); TAREA = parada operativa; solo PEDIDO es comercial.

-- =====================================================================
-- 0 · Defensivo frente al drift: producción registra 20261015153841_internal_route_task_metadata (no está en el repo)
--     y el repo tiene 20261015153500_internal_route_tasks. Esto deja columnas y trigger iguales en ambos casos (idempotente).
-- =====================================================================
alter table public.route_stops add column if not exists stop_type text not null default 'PEDIDO';
alter table public.route_stops add column if not exists instructions text;
alter table public.route_stops add column if not exists contact_name text;
alter table public.route_stops add column if not exists contact_phone text;
alter table public.route_stops add column if not exists internal_location_key text references public.internal_locations(location_key);
do $$ begin
  if not exists (select 1 from pg_constraint where conrelid='public.route_stops'::regclass and conname='route_stops_stop_type_check') then
    alter table public.route_stops add constraint route_stops_stop_type_check check (stop_type in ('PEDIDO','UBICACION_INTERNA','TAREA'));
  end if;
end $$;
create or replace function public._fill_stop_metadata_from_snapshot() returns trigger
language plpgsql security definer set search_path=public as $$
declare s jsonb;
begin
  select sheet_snapshot->'stops'->(new.seq-1) into s from public.routes where id=new.route_id;
  if s is not null and new.provenance is distinct from 'DRIVER' then
    new.stop_type:=coalesce(nullif(s->>'stop_type',''),new.stop_type,'PEDIDO');
    new.instructions:=nullif(s->>'instructions','');
    new.contact_name:=nullif(s->>'contact_name','');
    new.contact_phone:=nullif(s->>'contact_phone','');
    if coalesce(s->>'internal_location_key','')<>'' then new.internal_location_key:=s->>'internal_location_key'; end if;
  end if;
  return new;
end $$;
drop trigger if exists trg_fill_stop_metadata_from_snapshot on public.route_stops;
create trigger trg_fill_stop_metadata_from_snapshot before insert on public.route_stops for each row execute function public._fill_stop_metadata_from_snapshot();
revoke execute on function public._fill_stop_metadata_from_snapshot() from public,anon,authenticated;

-- =====================================================================
-- 1 · G2: lectura para quien prepara hojas; escritura sigue restringida a la RPC (settings.manage / locations.manage)
-- =====================================================================
drop policy if exists internal_locations_admin_read on public.internal_locations;
drop policy if exists internal_locations_read on public.internal_locations;
create policy internal_locations_read on public.internal_locations for select to authenticated
  using (public.auth_has_perm('settings.manage') or public.auth_has_perm('locations.manage') or public.auth_has_perm('locations.view') or public.auth_has_perm('routes.create'));
revoke insert, update, delete on public.internal_locations from authenticated, anon;
-- Auditoría con el ANTES y datos del geocodificador
alter table public.internal_locations add column if not exists geocode_source text;
alter table public.internal_locations add column if not exists geocode_display_name text;
create or replace function public.upsert_internal_location(p jsonb) returns public.internal_locations
language plpgsql security definer set search_path=public as $$
declare l public.internal_locations; prev jsonb;
begin
  if not (public.auth_has_perm('settings.manage') or public.auth_has_perm('locations.manage')) then raise exception 'FORBIDDEN' using errcode='42501'; end if;
  if coalesce(trim(p->>'location_key'),'')='' or coalesce(trim(p->>'name'),'')='' or (p->>'lat') is null or (p->>'lon') is null then raise exception 'BAD_LOCATION: completá clave, nombre y coordenadas' using errcode='23514'; end if;
  if abs((p->>'lat')::float8)>90 or abs((p->>'lon')::float8)>180 then raise exception 'BAD_LOCATION: coordenadas inválidas' using errcode='23514'; end if;
  if coalesce((p->>'radius_m')::int, 200) not between 10 and 5000 then raise exception 'BAD_LOCATION: el radio debe estar entre 10 y 5000 m' using errcode='23514'; end if;
  if exists (select 1 from public.internal_locations where active and location_key <> upper(trim(p->>'location_key')) and lower(trim(name)) = lower(trim(p->>'name')))
    then raise exception 'DUPLICATE_LOCATION_NAME: ya existe otra ubicación activa con ese nombre' using errcode='23505'; end if;
  select to_jsonb(x) into prev from public.internal_locations x where location_key = upper(trim(p->>'location_key'));
  insert into public.internal_locations(location_key,name,address,lat,lon,radius_m,active,note,geocode_source,geocode_display_name,updated_at)
  values (upper(trim(p->>'location_key')),trim(p->>'name'),nullif(trim(p->>'address'),''),(p->>'lat')::float8,(p->>'lon')::float8,coalesce((p->>'radius_m')::int,200),coalesce((p->>'active')::boolean,true),nullif(trim(p->>'note'),''),
          nullif(trim(p->>'geocode_source'),''),nullif(trim(p->>'geocode_display_name'),''),now())
  on conflict(location_key) do update set name=excluded.name,address=excluded.address,lat=excluded.lat,lon=excluded.lon,radius_m=excluded.radius_m,active=excluded.active,note=excluded.note,
    geocode_source=coalesce(excluded.geocode_source, internal_locations.geocode_source), geocode_display_name=coalesce(excluded.geocode_display_name, internal_locations.geocode_display_name), updated_at=now()
  returning * into l;
  insert into public.audit_log(actor_id,action,target_type,target_id,before,after) values(auth.uid(),'INTERNAL_LOCATION_SAVED','internal_location',l.location_key,prev,to_jsonb(l));
  return l;
end $$;
grant execute on function public.upsert_internal_location(jsonb) to authenticated, service_role;

-- =====================================================================
-- 2 · Snapshot GPS por parada (al publicar) + reglas por tipo de parada, validadas en el SERVIDOR
-- =====================================================================
alter table public.route_stops add column if not exists expected_lat double precision;
alter table public.route_stops add column if not exists expected_lon double precision;
alter table public.route_stops add column if not exists expected_radius_m integer;
alter table public.route_stops add column if not exists internal_location_updated_at timestamptz;
-- Sin asociación heurística por nombre/domicilio: G2 solo por clave explícita (la función queda sin uso)
drop trigger if exists trg_assign_internal_location on public.route_stops;
-- Se ejecuta DESPUÉS de trg_fill_stop_metadata_from_snapshot (los BEFORE triggers corren por orden alfabético)
create or replace function public._stop_type_rules() returns trigger language plpgsql security definer set search_path=public as $$
declare kind text; l public.internal_locations;
begin
  new.stop_type := coalesce(nullif(new.stop_type, ''), 'PEDIDO');
  select c.kind into kind from public.routes r join public.carriers c on c.id = r.carrier_id where r.id = new.route_id;
  if new.stop_type in ('TAREA','UBICACION_INTERNA') and coalesce(kind, '') <> 'INTERNO' then
    raise exception 'STOP_TYPE_REQUIRES_INTERNAL: % solo se publica con Transporte Interno', new.stop_type using errcode = '23514'; end if;
  if new.stop_type = 'UBICACION_INTERNA' then
    if new.internal_location_key is null then raise exception 'INTERNAL_LOCATION_REQUIRED: la ubicación interna no tiene clave G2' using errcode = '23514'; end if;
    select * into l from public.internal_locations where location_key = new.internal_location_key;
    if not found or not l.active then raise exception 'INTERNAL_LOCATION_INACTIVE: % no existe o está desactivada en G2', new.internal_location_key using errcode = '23514'; end if;
    -- nombre y domicilio vienen de G2 (no se editan en la hoja) y el GPS queda congelado para esta versión
    new.client_name := l.name; new.address := l.address; new.client_key := l.location_key;
    new.expected_lat := l.lat; new.expected_lon := l.lon; new.expected_radius_m := l.radius_m; new.internal_location_updated_at := l.updated_at;
  else
    new.internal_location_key := null; new.expected_lat := null; new.expected_lon := null; new.expected_radius_m := null; new.internal_location_updated_at := null;
  end if;
  if new.stop_type <> 'PEDIDO' then
    -- traslado interno / tarea: nunca comercial (sin montos, sin email al cliente, sin cobranza)
    new.merchandise_amount := 0; new.shipping_fee := 0; new.customer_email := null; new.task := 'ENTREGA'; new.expected_amount := null;
  end if;
  return new;
end $$;
revoke execute on function public._stop_type_rules() from public, anon, authenticated;
drop trigger if exists trg_zz_stop_type_rules on public.route_stops;
create trigger trg_zz_stop_type_rules before insert on public.route_stops for each row execute function public._stop_type_rules();
-- Recepción interna de traslado: misma infraestructura de firma, significado PROPIO (no es Recibido Conforme comercial)
alter table public.stop_evidence add column if not exists evidence_kind text not null default 'ENTREGA_CLIENTE';
do $$ begin
  if not exists (select 1 from pg_constraint where conrelid='public.stop_evidence'::regclass and conname='stop_evidence_kind_check') then
    alter table public.stop_evidence add constraint stop_evidence_kind_check check (evidence_kind in ('ENTREGA_CLIENTE','RECEPCION_INTERNA','TAREA'));
  end if;
end $$;
-- Anti-duplicado: una sola parada por ubicación interna en cada hoja (una "segunda visita" requeriría un mecanismo explícito que no existe)
create unique index if not exists route_stops_one_internal_location_per_route on public.route_stops(route_id, internal_location_key) where stop_type = 'UBICACION_INTERNA';
-- Snapshot para hojas YA publicadas/en curso (mejor dato disponible: el punto actual), solo con clave explícita
update public.route_stops s set expected_lat = l.lat, expected_lon = l.lon, expected_radius_m = l.radius_m, internal_location_updated_at = l.updated_at
  from public.internal_locations l, public.routes r
 where l.location_key = s.internal_location_key and r.id = s.route_id and r.operational_status in ('PUBLICADA','EN_CURSO') and s.expected_lat is null
   and (s.stop_type = 'UBICACION_INTERNA' or (r.sheet_snapshot->'stops'->(s.seq-1)->>'internal_location_key') = s.internal_location_key);
insert into public.audit_log(action, target_type, target_id, after) values ('INTERNAL_LOCATION_SNAPSHOT_BACKFILL', 'route_stops', 'G2', jsonb_build_object('note', 'snapshot GPS inicial para hojas publicadas/en curso con clave G2 explícita'));

create or replace function public._loc(p jsonb, st public.route_stops) returns jsonb
language plpgsql stable security definer set search_path=public as $$
declare cm public.client_locations; im public.internal_locations; d double precision; radius int; elat double precision; elon double precision; source text; vkey text;
begin
  if p is null then raise exception 'LOCATION_REQUIRED: registrá la ubicación o indicá por qué no se pudo' using errcode='23514'; end if;
  if p ? 'lat' and p ? 'lon' then
    -- 1) Ubicación interna: SIEMPRE contra el snapshot guardado al publicar (editar o desactivar G2 después no cambia la hoja)
    if st.expected_lat is not null and st.expected_lon is not null then
      elat := st.expected_lat; elon := st.expected_lon; radius := st.expected_radius_m; source := 'INTERNAL_SNAPSHOT'; vkey := st.internal_location_key;
    -- 2) Compatibilidad: ubicación interna publicada antes del snapshot → punto vigente, solo por clave explícita (nunca por nombre/domicilio)
    elsif st.stop_type = 'UBICACION_INTERNA' and st.internal_location_key is not null then
      select * into im from public.internal_locations where location_key = st.internal_location_key;
      if found then elat := im.lat; elon := im.lon; radius := im.radius_m; source := 'INTERNAL_LIVE'; vkey := im.location_key; end if;
    end if;
    -- 3) Cliente (pedidos comerciales): igual que antes
    if elat is null and coalesce(st.stop_type, 'PEDIDO') = 'PEDIDO' and st.client_key is not null then
      select * into cm from public.client_locations where client_key = st.client_key and active;
      if found then elat := cm.lat; elon := cm.lon; radius := cm.radius_m; source := 'CLIENT'; vkey := st.client_key; end if;
    end if;
    if elat is not null then d := public._dist_m(elat, elon, (p->>'lat')::float8, (p->>'lon')::float8); end if;
    return jsonb_build_object('lat', (p->>'lat')::float8, 'lon', (p->>'lon')::float8, 'accuracy', nullif(p->>'accuracy', '')::float8, 'at', now(),
      'validation_source', source, 'validation_key', vkey, 'expected_lat', elat, 'expected_lon', elon, 'radius_m', radius,
      'distance_m', case when d is not null then round(d) end, 'outside_m', case when d is not null and radius is not null and d > radius then round(d) end);
  end if;
  if coalesce(trim(p->>'missing_reason'), '') = '' then raise exception 'LOCATION_REASON_REQUIRED: sin ubicación hay que indicar el motivo' using errcode='23514'; end if;
  return jsonb_build_object('missing_reason', trim(p->>'missing_reason'), 'at', now());
end $$;
revoke execute on function public._loc(jsonb, public.route_stops) from public, anon, authenticated;

-- =====================================================================
-- 3 · Reservas: solo las de las paradas publicadas; huérfanas rechazadas
-- =====================================================================
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
  -- Reservas huérfanas: pedidos reservados por este borrador que NO están en ninguna parada publicada → se rechaza (no se publican en silencio)
  if exists (select 1 from public.order_reservations o where o.sheet_key = p->>'sheet_key' and o.status = 'BORRADOR' and not (o.order_id = any(coalesce(ords, '{}')))) then
    raise exception 'ORPHAN_RESERVATIONS: hay pedidos reservados que no están en la hoja: %', (select string_agg(o.order_id, ', ' order by o.order_id) from public.order_reservations o
      where o.sheet_key = p->>'sheet_key' and o.status = 'BORRADOR' and not (o.order_id = any(coalesce(ords, '{}')))) using errcode = '23514';
  end if;
  insert into public.routes(number, carrier_id, responsable_id, status, operational_status, created_by, sheet_key, published_at, published_by, sheet_snapshot)
  values (public.next_route_number_for(car), car, resp, 'PUBLICADA', 'PUBLICADA', auth.uid(), p->>'sheet_key', now(), auth.uid(), p)
  returning * into r;
  update public.order_reservations set status = 'PUBLICADA', route_id = r.id where sheet_key = p->>'sheet_key' and order_id = any(coalesce(ords, '{}'));
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
create or replace function public.dispatch_external_route(p jsonb)
returns public.routes
language plpgsql
security definer
set search_path='public'
as $$
declare
  r public.routes;
  d public.route_drafts;
  car text := p->>'carrier_id';
  c public.carriers;
  s jsonb;
  i int := 0;
  ships text[];
  ords text[];
begin
  if not public.auth_has_perm('routes.publish') then
    raise exception 'FORBIDDEN' using errcode='42501';
  end if;
  d := public._draft(p->>'sheet_key', true, false);
  if d.status='PUBLICADA' then
    select * into r from public.routes where id=d.route_id;
    return r;
  end if;
  if d.status <> 'BORRADOR' then raise exception 'DRAFT_CANCELLED' using errcode='23514'; end if;

  select * into c from public.carriers where id=car and active;
  if not found then raise exception 'BAD_CARRIER: elegí el transportista' using errcode='23514'; end if;
  if c.kind <> 'EXTERNO' or c.report_group='CRISTIAN_TORRES' then
    raise exception 'NOT_EXTERNAL_DISPATCH: este transportista usa PUBLICAR HOJA' using errcode='23514';
  end if;

  if jsonb_array_length(coalesce(p->'stops','[]'::jsonb))=0 then raise exception 'EMPTY_SHEET: la hoja no tiene pedidos' using errcode='23514'; end if;
  select array_agg(x->>'ship_order') into ships from jsonb_array_elements(p->'stops') x where x->>'ship_fee_status'='PROVISIONAL';
  if ships is not null then perform public.assert_sheet_shipping_ready(p->>'sheet_key', ships); end if;
  if exists(select 1 from jsonb_array_elements(p->'stops') x where coalesce((x->>'ready')::boolean,false)=false) then
    raise exception 'NOT_READY: hay pedidos con revisión pendiente o sin monto' using errcode='23514';
  end if;
  select array_agg(distinct v) into ords from jsonb_array_elements(p->'stops') x, jsonb_array_elements_text(x->'order_numbers') v;
  perform public.reserve_orders(p->>'sheet_key', ords);
  -- Reservas huérfanas: pedidos reservados por este borrador que NO están en ninguna parada publicada → se rechaza (no se publican en silencio)
  if exists (select 1 from public.order_reservations o where o.sheet_key = p->>'sheet_key' and o.status = 'BORRADOR' and not (o.order_id = any(coalesce(ords, '{}')))) then
    raise exception 'ORPHAN_RESERVATIONS: hay pedidos reservados que no están en la hoja: %', (select string_agg(o.order_id, ', ' order by o.order_id) from public.order_reservations o
      where o.sheet_key = p->>'sheet_key' and o.status = 'BORRADOR' and not (o.order_id = any(coalesce(ords, '{}')))) using errcode = '23514';
  end if;

  insert into public.routes(number,carrier_id,responsable_id,status,operational_status,created_by,sheet_key,published_at,published_by,completed_at,completed_by,dispatched_at,dispatched_by,dispatch_mode,sheet_snapshot)
  values(public.next_route_number_for(car),car,null,'COMPLETADA','COMPLETADA',auth.uid(),p->>'sheet_key',now(),auth.uid(),now(),auth.uid(),now(),auth.uid(),'EXTERNAL',p)
  returning * into r;

  update public.order_reservations set status='PUBLICADA',route_id=r.id where sheet_key=p->>'sheet_key' and order_id = any(coalesce(ords, '{}'));
  update public.route_drafts set status='PUBLICADA',route_id=r.id,updated_at=now() where id=d.id;

  for s in select * from jsonb_array_elements(p->'stops') loop
    i:=i+1;
    insert into public.route_stops(route_id,seq,sequence_number,provenance,client_name,client_key,zone,order_numbers,merchandise_amount,shipping_fee,shipping_fee_source,bultos,address,action,task,expected_amount,customer_email)
    values(r.id,i,i,'PUBLISHED',s->>'client_name',s->>'client_key',nullif(s->>'zone',''),
      coalesce((select array_agg(v) from jsonb_array_elements_text(s->'order_numbers') v),'{}'),
      coalesce((s->>'merchandise_amount')::numeric,0),coalesce((s->>'shipping_fee')::numeric,0),
      case when s->>'ship_fee_status'='PROVISIONAL' then 'CONFIRMED_FALLBACK' else 'SALDO' end,
      nullif(s->>'bultos','')::int,s->>'address',coalesce(s->>'action','ENTREGA'),coalesce(s->>'task','ENTREGA'),
      nullif(s->>'expected_amount','')::numeric,nullif(s->>'customer_email',''));
  end loop;

  insert into public.audit_log(actor_id,action,target_type,target_id,after)
  values(auth.uid(),'EXTERNAL_ROUTE_DISPATCHED','route',r.id::text,jsonb_build_object('number',r.number,'carrier',car,'stops',i,'dispatch_mode','EXTERNAL'));
  return r;
end;
$$;

-- =====================================================================
-- 4 · Comportamiento por tipo de parada en el cierre (TAREA y traslado interno no son entrega comercial)
-- =====================================================================
create or replace function public.set_stop_outcome(p_stop uuid, p_outcome text, p_note text, p_reason text, p_op_id text, p_extra jsonb default null)
returns public.route_stops language plpgsql security definer set search_path = public as $$
declare st public.route_stops; r public.routes; cristian boolean; v_commercial boolean; v_task boolean; v_cuil text; v_email text; v_dni text; v_receipt boolean := false; ev jsonb := coalesce(p_extra->'evidence', '{}'); col jsonb := p_extra->'collection'; loc jsonb; sig bytea;
begin
  select * into st from public.route_stops where id = p_stop;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  r := public._my_route(st.route_id);
  -- Comportamiento por tipo de parada: solo PEDIDO es entrega comercial al cliente (email, Recibido Conforme, cobranza, identidad).
  v_commercial := coalesce(st.stop_type, 'PEDIDO') = 'PEDIDO';
  v_task := st.stop_type = 'TAREA';
  if p_op_id is not null and exists (select 1 from public.stop_outcome_ops where op_id = p_op_id) then return st; end if;
  if r.operational_status <> 'EN_CURSO' then raise exception 'BAD_STATE: iniciá el recorrido o la hoja ya está cerrada' using errcode = '23514'; end if;
  if p_outcome not in ('ENTREGADO','ENTREGA_PARCIAL','NO_ENTREGADO','REPROGRAMAR') then raise exception 'BAD_OUTCOME' using errcode = '22023'; end if;
  if p_outcome = 'ENTREGA_PARCIAL' and coalesce(trim(p_note), '') = '' then raise exception 'NOTE_REQUIRED: entrega parcial exige observación' using errcode = '23514'; end if;
  if p_outcome in ('NO_ENTREGADO','REPROGRAMAR') and coalesce(trim(p_reason), '') = '' then raise exception 'REASON_REQUIRED: indicá el motivo' using errcode = '23514'; end if;
  cristian := exists (select 1 from public.carriers where id = r.carrier_id and report_group = 'CRISTIAN_TORRES');
  if p_outcome in ('ENTREGADO','ENTREGA_PARCIAL') then
    -- TAREA: no se exige firma ni receptor como en una entrega comercial (alcanza GPS u observación). El resto, igual que antes.
    if not v_task and (coalesce(trim(ev->>'receiver_name'), '') = '' or coalesce(ev->>'signature_png_b64', '') = '') then raise exception 'EVIDENCE_REQUIRED: nombre del receptor y firma obligatorios' using errcode = '23514'; end if;
    sig := case when coalesce(ev->>'signature_png_b64', '') <> '' then decode(ev->>'signature_png_b64', 'base64') end;
    if cristian and v_commercial then
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
  if v_commercial and st.task in ('COBRANZA','AMBAS') then
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
    if sig is not null then
      insert into public.stop_evidence(stop_id, receiver_name, signature_png, signature_sha256, receiver_cuil, created_by, receiver_email, receiver_dni, evidence_kind)
      values (p_stop, coalesce(nullif(trim(ev->>'receiver_name'), ''), 'Sin receptor (tarea)'), sig, encode(sha256(sig), 'hex'), v_cuil, auth.uid(), case when v_commercial then v_email end, v_dni,
              case when st.stop_type = 'UBICACION_INTERNA' then 'RECEPCION_INTERNA' when v_task then 'TAREA' else 'ENTREGA_CLIENTE' end)
      on conflict (stop_id) do nothing;
    end if;
    -- RECEPCIÓN INTERNA DE TRASLADO: queda trazado qué pedidos llegaron a qué sucursal, quién recibió, quién trasladó, cuándo y dónde
    if st.stop_type = 'UBICACION_INTERNA' then
      insert into public.audit_log(actor_id, action, target_type, target_id, after)
      values (auth.uid(), 'INTERNAL_TRANSFER_RECEIVED', 'route_stop', p_stop::text, jsonb_build_object(
        'route_id', st.route_id, 'route_number', r.number, 'internal_location_key', st.internal_location_key, 'location_name', st.client_name, 'address', st.address,
        'order_numbers', to_jsonb(st.order_numbers), 'outcome', p_outcome, 'receiver_name', trim(ev->>'receiver_name'), 'signature_sha256', encode(sha256(sig), 'hex'),
        'transported_by', auth.uid(), 'at', now(), 'gps', loc));
    end if;
    -- Perfil reutilizable (misma capa de identidad que el DNI): nombre, DNI y email para próximas entregas
    if v_commercial and v_cuil is not null then perform public._upsert_identity_profile(v_cuil, trim(ev->>'receiver_name'), v_dni, v_email, st.client_key); end if;
    -- Recibido Conforme: entrega TOTAL confirmada + email válido → comprobante único + envío automático (la falla del email nunca revierte la entrega)
    if v_commercial and p_outcome = 'ENTREGADO' and v_email is not null then perform public._create_delivery_receipt(st, r, trim(ev->>'receiver_name'), v_email); v_receipt := true; end if;
    if v_commercial and coalesce(trim(st.customer_email), '') <> '' and not v_receipt then
      insert into public.customer_email_jobs(route_id, stop_id, kind, recipient, idempotency_key)
      values (st.route_id, st.id, case when p_outcome = 'ENTREGADO' then 'DELIVERED' else 'PARTIAL' end, lower(trim(st.customer_email)), st.route_id || '|' || st.id || '|' || case when p_outcome = 'ENTREGADO' then 'DELIVERED' else 'PARTIAL' end)
      on conflict (idempotency_key) do nothing;
    end if;
  end if;
  if p_op_id is not null then insert into public.stop_outcome_ops(op_id, stop_id) values (p_op_id, p_stop); end if;
  perform public._queue_on_the_way(st.route_id);
  return st;
end; $$;
create or replace function public._queue_on_the_way(p_route uuid) returns void language plpgsql security definer set search_path = public as $$
declare s public.route_stops;
begin
  select * into s from public.route_stops where route_id = p_route and outcome = 'PENDIENTE' order by sequence_number limit 1;
  if found and coalesce(s.stop_type, 'PEDIDO') = 'PEDIDO' and coalesce(trim(s.customer_email), '') <> '' then
    insert into public.customer_email_jobs(route_id, stop_id, kind, recipient, idempotency_key)
    values (p_route, s.id, 'ON_THE_WAY', lower(trim(s.customer_email)), p_route || '|' || s.id || '|ON_THE_WAY') on conflict (idempotency_key) do nothing;
  end if;
end; $$;
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
      'incidencias', (select count(*) from public.route_stops s join r on r.id = s.route_id where s.outcome in ('NO_ENTREGADO','REPROGRAMAR','ENTREGA_PARCIAL') and coalesce(s.stop_type, 'PEDIDO') = 'PEDIDO' and r.operational_status in ('PUBLICADA','EN_CURSO','FINALIZADA') and coalesce((r.completed_at at time zone 'America/Argentina/Mendoza')::date, today) = today)),
    'carriers', (select coalesce(jsonb_agg(x order by x->>'grp'), '[]') from (select jsonb_build_object('grp', grp,
        'publicadas', count(*) filter (where operational_status in ('PUBLICADA','EN_CURSO','FINALIZADA')),
        'activas', count(*) filter (where operational_status in ('PUBLICADA','EN_CURSO')),
        'finalizadas', count(*) filter (where operational_status = 'FINALIZADA'),
        'incidencias', (select count(*) from public.route_stops s where s.route_id = any(array_agg(g.id)) and s.outcome in ('NO_ENTREGADO','REPROGRAMAR','ENTREGA_PARCIAL') and coalesce(s.stop_type, 'PEDIDO') = 'PEDIDO'),
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
        'incidencia', exists (select 1 from public.route_stops s where s.route_id = r.id and s.outcome in ('NO_ENTREGADO','REPROGRAMAR','ENTREGA_PARCIAL') and coalesce(s.stop_type, 'PEDIDO') = 'PEDIDO')) order by r.published_at desc), '[]')
      from public.routes r join public.carriers c on c.id = r.carrier_id left join public.profiles p on p.id = r.responsable_id
      where r.operational_status in ('PUBLICADA','EN_CURSO') and (r.published_by = me or r.published_by in (select public.team_of(me)))),
    'notifications', (select coalesce(jsonb_agg(jsonb_build_object('title', n.title, 'body', n.body, 'at', n.created_at, 'type', n.type) order by n.created_at desc), '[]')
      from (select * from public.notifications where user_id = me or user_id in (select public.team_of(me)) order by created_at desc limit 12) n),
    'perms', jsonb_build_object('columns', public.auth_has_perm('columns.manage_defaults') or public.auth_has_perm('columns.manage_templates'),
      'km', public.auth_has_perm('vehicle_mileage.rules_manage'), 'approve', public.auth_has_perm('requests.approve_team')));
end; $$;

-- =====================================================================
-- 5 · Parada agregada por el Transportista Interno = TAREA operativa futura (provenance DRIVER, usuario, fecha, versión y auditoría ya existentes)
-- =====================================================================
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
  insert into public.route_stops(id, route_id, seq, sequence_number, provenance, client_name, address, action, bultos, added_by, added_at, stop_type, instructions, contact_name, contact_phone)
  values (coalesce(nullif(p_stop->>'id', '')::uuid, gen_random_uuid()), p_route, nseq, (select coalesce(max(sequence_number), 0) + 1 from public.route_stops where route_id = p_route), 'DRIVER', p_stop->>'client_name', p_stop->>'address',
          coalesce(nullif(p_stop->>'action', ''), 'ENTREGA'), nullif(p_stop->>'bultos', '')::int, auth.uid(), now(),
          'TAREA', nullif(trim(p_stop->>'instructions'), ''), nullif(trim(p_stop->>'contact_name'), ''), nullif(trim(p_stop->>'contact_phone'), ''))
  returning id into nid;
  update public.routes set version = version + 1, has_driver_modifications = true, modification_count = modification_count + 1 where id = p_route returning * into r;
  insert into public.route_change_events(route_id, route_version, stop_id, event_type, after, user_id, client_op_id, offline)
  values (p_route, r.version, nid::text, 'INTERNAL_STOP_ADDED', p_stop, auth.uid(), p_op_id, p_offline);
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'INTERNAL_STOP_ADDED', 'route', p_route::text, p_stop);
  return r;
end; $$;

-- =====================================================================
-- 6 · Web Push: toma ATÓMICA de trabajos (sin envíos duplicados aunque haya varias ejecuciones a la vez) y reintentos con espera
-- =====================================================================
alter table public.push_jobs add column if not exists locked_at timestamptz;
alter table public.push_jobs add column if not exists next_attempt_at timestamptz;
alter table public.push_jobs drop constraint if exists push_jobs_status_check;
alter table public.push_jobs add constraint push_jobs_status_check check (status in ('QUEUED','SENDING','SENT','ERROR','SKIPPED'));
-- Solo service_role (Edge Function). Cada trabajo lo toma UNA sola ejecución (FOR UPDATE SKIP LOCKED).
-- Reintenta ERROR hasta 5 intentos respetando next_attempt_at; recupera SENDING trabado más de 10 minutos (ejecución caída).
create or replace function public.claim_push_jobs(p_limit int default 50) returns setof public.push_jobs
language plpgsql security definer set search_path = public as $$
begin
  return query
  update public.push_jobs j set status = 'SENDING', locked_at = now(), attempt_count = j.attempt_count + 1
   where j.id in (select id from public.push_jobs
                   where status = 'QUEUED'
                      or (status = 'ERROR' and attempt_count < 5 and coalesce(next_attempt_at, now()) <= now())
                      or (status = 'SENDING' and locked_at < now() - interval '10 minutes')
                   order by created_at for update skip locked limit greatest(1, least(coalesce(p_limit, 50), 200)))
  returning j.*;
end $$;
revoke execute on function public.claim_push_jobs(int) from public, anon, authenticated;
grant execute on function public.claim_push_jobs(int) to service_role;


;
-- OK DESPACHO ONLINE — Parche G2 (incremental sobre 20261018165305, forward-only, sin borrar datos):
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
declare v_count integer;
begin
  if new.type in ('NUEVA_HOJA_PUBLICADA','HOJA_CORREGIDA') and new.route_id is not null and new.body is not null
     and exists (select 1 from public.routes r join public.carriers c on c.id = r.carrier_id where r.id = new.route_id and c.kind = 'INTERNO') then
    select ((regexp_match(new.body, '([0-9]+) entregas?'))[1])::integer into v_count;
    if v_count is not null then
      new.body := regexp_replace(
        new.body,
        '[0-9]+ entregas?',
        v_count::text || case when v_count = 1 then ' parada' else ' paradas' end,
        'g'
      );
    end if;
  end if;
  return new;
end $$;
revoke execute on function public.trg_notification_internal_wording() from public, anon, authenticated;
drop trigger if exists trg_notification_internal_wording on public.notifications;
create trigger trg_notification_internal_wording before insert on public.notifications for each row execute function public.trg_notification_internal_wording();


;
-- OK Despacho Online · G2 security hardening
-- Forward-only. No altera las migraciones históricas ni los datos.
-- La autorización funcional sigue validándose dentro de upsert_internal_location.
-- Evita que los roles públicos invoquen un RPC administrativo SECURITY DEFINER.
REVOKE EXECUTE ON FUNCTION public.upsert_internal_location(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.upsert_internal_location(jsonb) TO authenticated, service_role;

;
-- Código asignado en servidor; nunca reutilizar prefijos históricos.
create or replace function public.upsert_carrier(p jsonb)
returns public.carriers
language plpgsql security definer set search_path = public
as $$
declare
 c public.carriers;
 cid text := upper(trim(p->>'id'));
 code text;
 n integer;
begin
 if not (public.auth_has_perm('settings.manage') or public.auth_has_perm('carriers.manage')) then
   raise exception 'FORBIDDEN' using errcode='42501';
 end if;
 if cid = '' or coalesce(trim(p->>'name'),'') = '' then
   raise exception 'BAD_CARRIER: id y nombre obligatorios' using errcode='23514';
 end if;
 -- Serializa creaciones concurrentes; evita que dos transportistas reciban el mismo número.
 perform pg_advisory_xact_lock(871410, 2026);
 select * into c from public.carriers where id=cid for update;
 if found then
   code := c.sequence_code;
   if nullif(p->>'sequence_code','') is not null and p->>'sequence_code' <> code then
     raise exception 'IMMUTABLE_CODE: el correlativo histórico no se puede modificar' using errcode='23514';
   end if;
 else
   select coalesce(max(v),0)+1 into n from (
     select sequence_code::integer as v from public.carriers where sequence_code ~ '^[0-9]{2}$'
     union all
     select rs.code::integer from public.route_sequences rs where rs.code ~ '^[0-9]{2}$'
   ) all_codes;
   if n > 99 then raise exception 'NO_SEQUENCE_CODE: límite de 99 códigos alcanzado' using errcode='23514'; end if;
   code := lpad(n::text,2,'0');
 end if;
 insert into public.carriers(id,name,kind,active,sequence_code,report_group,emails,notes)
 values(cid,upper(p->>'name'),coalesce(p->>'kind','EXTERNO'),coalesce((p->>'active')::boolean,true),code,
        nullif(p->>'report_group',''),
        coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(p->'emails','[]'::jsonb)) x),'{}'),p->>'notes')
 on conflict(id) do update set name=excluded.name,kind=excluded.kind,active=excluded.active,
   report_group=excluded.report_group,emails=excluded.emails,notes=excluded.notes
 returning * into c;
 insert into public.audit_log(actor_id,action,target_type,target_id,after)
 values(auth.uid(),'CARRIER_SAVED','carrier',c.id,to_jsonb(c));
 return c;
end; $$;

;
-- Validaciones de servidor. Solo entrega comercial Cristian Torres.
CREATE OR REPLACE FUNCTION public.set_stop_outcome(p_stop uuid, p_outcome text, p_note text, p_reason text, p_op_id text, p_extra jsonb DEFAULT NULL::jsonb)
 RETURNS route_stops
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare st public.route_stops; r public.routes; cristian boolean; v_commercial boolean; v_task boolean; v_cuil text; v_email text; v_dni text; v_receipt boolean := false; ev jsonb := coalesce(p_extra->'evidence', '{}'); col jsonb := p_extra->'collection'; loc jsonb; sig bytea;
begin
  select * into st from public.route_stops where id = p_stop;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  r := public._my_route(st.route_id);
  -- Comportamiento por tipo de parada: solo PEDIDO es entrega comercial al cliente (email, Recibido Conforme, cobranza, identidad).
  v_commercial := coalesce(st.stop_type, 'PEDIDO') = 'PEDIDO';
  v_task := st.stop_type = 'TAREA';
  if p_op_id is not null and exists (select 1 from public.stop_outcome_ops where op_id = p_op_id) then return st; end if;
  if r.operational_status <> 'EN_CURSO' then raise exception 'BAD_STATE: iniciá el recorrido o la hoja ya está cerrada' using errcode = '23514'; end if;
  if p_outcome not in ('ENTREGADO','ENTREGA_PARCIAL','NO_ENTREGADO','REPROGRAMAR') then raise exception 'BAD_OUTCOME' using errcode = '22023'; end if;
  if p_outcome = 'ENTREGA_PARCIAL' and coalesce(trim(p_note), '') = '' then raise exception 'NOTE_REQUIRED: entrega parcial exige observación' using errcode = '23514'; end if;
  if p_outcome in ('NO_ENTREGADO','REPROGRAMAR') and coalesce(trim(p_reason), '') = '' then raise exception 'REASON_REQUIRED: indicá el motivo' using errcode = '23514'; end if;
  cristian := exists (select 1 from public.carriers where id = r.carrier_id and report_group = 'CRISTIAN_TORRES');
  if p_outcome in ('ENTREGADO','ENTREGA_PARCIAL') then
    -- TAREA: no se exige firma ni receptor como en una entrega comercial (alcanza GPS u observación). El resto, igual que antes.
    if not v_task and (coalesce(trim(ev->>'receiver_name'), '') = '' or coalesce(ev->>'signature_png_b64', '') = '') then raise exception 'EVIDENCE_REQUIRED: nombre del receptor y firma obligatorios' using errcode = '23514'; end if;
    sig := case when coalesce(ev->>'signature_png_b64', '') <> '' then decode(ev->>'signature_png_b64', 'base64') end;
    if cristian and v_commercial then
      v_cuil := regexp_replace(coalesce(ev->>'cuil', ''), '\D', '', 'g');
      if length(v_cuil) <> 11 then raise exception 'CUIL_INVALID: el CUIL debe tener 11 dígitos' using errcode = '23514'; end if;
      perform public._register_identity(v_cuil, ev);   -- RC1: DNI en Storage privado
      if not exists (select 1 from public.customer_identity_docs d where d.cuil = v_cuil and (d.storage_path is not null or d.dni_photo is not null)) then
        raise exception 'DNI_REQUIRED: cargá la foto del DNI para el CUIL nuevo' using errcode = '23514';
      end if;
    else
      v_cuil := nullif(regexp_replace(coalesce(ev->>'cuil', ''), '\D', '', 'g'), '');   -- Transportista Interno: CUIL opcional
      if v_cuil is not null and length(v_cuil) <> 11 then raise exception 'CUIL_INVALID: el CUIL debe tener 11 dígitos' using errcode = '23514'; end if;
    end if;
    -- RC4.1: email del receptor (segunda pantalla). Opcional; si viene, debe ser válido.
    v_email := nullif(lower(trim(coalesce(ev->>'email', ''))), '');
    if cristian and v_commercial and v_email is null then raise exception 'EMAIL_REQUIRED: el email del receptor es obligatorio' using errcode = '23514'; end if;
    if v_email is not null and not public.is_valid_email(v_email) then raise exception 'EMAIL_INVALID: el email no es válido' using errcode = '23514'; end if;
    v_dni := nullif(regexp_replace(coalesce(ev->>'dni', ''), '\D', '', 'g'), '');
    if v_dni is null and v_cuil is not null then v_dni := substr(v_cuil, 3, 8); end if;
    if v_dni is not null and length(v_dni) not between 7 and 8 then raise exception 'DNI_INVALID: el DNI debe tener 7 u 8 dígitos' using errcode = '23514'; end if;
  end if;
  -- cobranza (Cristian): el chofer no cambia el importe esperado
  if v_commercial and st.task in ('COBRANZA','AMBAS') then
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
    if sig is not null then
      insert into public.stop_evidence(stop_id, receiver_name, signature_png, signature_sha256, receiver_cuil, created_by, receiver_email, receiver_dni, evidence_kind)
      values (p_stop, coalesce(nullif(trim(ev->>'receiver_name'), ''), 'Sin receptor (tarea)'), sig, encode(sha256(sig), 'hex'), v_cuil, auth.uid(), case when v_commercial then v_email end, v_dni,
              case when st.stop_type = 'UBICACION_INTERNA' then 'RECEPCION_INTERNA' when v_task then 'TAREA' else 'ENTREGA_CLIENTE' end)
      on conflict (stop_id) do nothing;
    end if;
    -- RECEPCIÓN INTERNA DE TRASLADO: queda trazado qué pedidos llegaron a qué sucursal, quién recibió, quién trasladó, cuándo y dónde
    if st.stop_type = 'UBICACION_INTERNA' then
      insert into public.audit_log(actor_id, action, target_type, target_id, after)
      values (auth.uid(), 'INTERNAL_TRANSFER_RECEIVED', 'route_stop', p_stop::text, jsonb_build_object(
        'route_id', st.route_id, 'route_number', r.number, 'internal_location_key', st.internal_location_key, 'location_name', st.client_name, 'address', st.address,
        'order_numbers', to_jsonb(st.order_numbers), 'outcome', p_outcome, 'receiver_name', trim(ev->>'receiver_name'), 'signature_sha256', encode(sha256(sig), 'hex'),
        'transported_by', auth.uid(), 'at', now(), 'gps', loc));
    end if;
    -- Perfil reutilizable (misma capa de identidad que el DNI): nombre, DNI y email para próximas entregas
    if v_commercial and v_cuil is not null then perform public._upsert_identity_profile(v_cuil, trim(ev->>'receiver_name'), v_dni, v_email, st.client_key); end if;
    -- Recibido Conforme: entrega TOTAL confirmada + email válido → comprobante único + envío automático (la falla del email nunca revierte la entrega)
    if v_commercial and p_outcome = 'ENTREGADO' and v_email is not null then perform public._create_delivery_receipt(st, r, trim(ev->>'receiver_name'), v_email); v_receipt := true; end if;
    if v_commercial and coalesce(trim(st.customer_email), '') <> '' and not v_receipt then
      insert into public.customer_email_jobs(route_id, stop_id, kind, recipient, idempotency_key)
      values (st.route_id, st.id, case when p_outcome = 'ENTREGADO' then 'DELIVERED' else 'PARTIAL' end, lower(trim(st.customer_email)), st.route_id || '|' || st.id || '|' || case when p_outcome = 'ENTREGADO' then 'DELIVERED' else 'PARTIAL' end)
      on conflict (idempotency_key) do nothing;
    end if;
  end if;
  if p_op_id is not null then insert into public.stop_outcome_ops(op_id, stop_id) values (p_op_id, p_stop); end if;
  perform public._queue_on_the_way(st.route_id);
  return st;
end; $function$


;
-- =====================================================================================================================
-- PROPUESTA V4.17 · NO APLICADA · set_stop_outcome (corrige la propuesta V4.16, que partía de una base equivocada)
-- BASE: la definición más reciente del repositorio en el ORDEN REAL de aplicación (tests/sql/migration_order.txt, posición 45/45):
--   supabase/migrations/20261018191924_20261018201000_cristian_email_dni_required.sql (formato pg_get_functiondef).
--   PENDIENTE: confirmar contra la definición REAL de producción (ver COMPARAR_CON_PRODUCCION.md). Sin esa confirmación, no aplicar.
-- CAMBIOS (mínimos, ver propuesta_vs_base.diff):
--   (1) Entrega COMERCIAL de ambos perfiles: CUIL obligatorio + _register_identity + DNI_REQUIRED + EMAIL_REQUIRED (antes solo Cristian).
--       Vincula la foto del DNI del transportista interno y reutiliza una identidad ya registrada.
--   (2) Cobranza OPCIONAL: se valida solo si se informa; si no, se conservan los cobros existentes (no se inventan ni se borran).
--   Sin cambios: EMAIL_INVALID, DNI_INVALID, perfil reutilizable, Recibido Conforme, recepción interna (nombre + firma), TAREA,
--   segunda visita, permisos, RLS y Storage.
-- ORDEN DE MIGRACIONES: el nombre 20261108000100_… ordena DESPUÉS de todas las existentes, así que gana también en una
-- instalación desde cero.
-- =====================================================================================================================
CREATE OR REPLACE FUNCTION public.set_stop_outcome(p_stop uuid, p_outcome text, p_note text, p_reason text, p_op_id text, p_extra jsonb DEFAULT NULL::jsonb)
 RETURNS route_stops
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare st public.route_stops; r public.routes; cristian boolean; v_commercial boolean; v_task boolean; v_cuil text; v_email text; v_dni text; v_receipt boolean := false; ev jsonb := coalesce(p_extra->'evidence', '{}'); col jsonb := p_extra->'collection'; loc jsonb; sig bytea;
begin
  select * into st from public.route_stops where id = p_stop;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  r := public._my_route(st.route_id);
  -- Comportamiento por tipo de parada: solo PEDIDO es entrega comercial al cliente (email, Recibido Conforme, cobranza, identidad).
  v_commercial := coalesce(st.stop_type, 'PEDIDO') = 'PEDIDO';
  v_task := st.stop_type = 'TAREA';
  if p_op_id is not null and exists (select 1 from public.stop_outcome_ops where op_id = p_op_id) then return st; end if;
  if r.operational_status <> 'EN_CURSO' then raise exception 'BAD_STATE: iniciá el recorrido o la hoja ya está cerrada' using errcode = '23514'; end if;
  if p_outcome not in ('ENTREGADO','ENTREGA_PARCIAL','NO_ENTREGADO','REPROGRAMAR') then raise exception 'BAD_OUTCOME' using errcode = '22023'; end if;
  if p_outcome = 'ENTREGA_PARCIAL' and coalesce(trim(p_note), '') = '' then raise exception 'NOTE_REQUIRED: entrega parcial exige observación' using errcode = '23514'; end if;
  if p_outcome in ('NO_ENTREGADO','REPROGRAMAR') and coalesce(trim(p_reason), '') = '' then raise exception 'REASON_REQUIRED: indicá el motivo' using errcode = '23514'; end if;
  cristian := exists (select 1 from public.carriers where id = r.carrier_id and report_group = 'CRISTIAN_TORRES');
  if p_outcome in ('ENTREGADO','ENTREGA_PARCIAL') then
    -- TAREA: no se exige firma ni receptor como en una entrega comercial (alcanza GPS u observación). El resto, igual que antes.
    if not v_task and (coalesce(trim(ev->>'receiver_name'), '') = '' or coalesce(ev->>'signature_png_b64', '') = '') then raise exception 'EVIDENCE_REQUIRED: nombre del receptor y firma obligatorios' using errcode = '23514'; end if;
    sig := case when coalesce(ev->>'signature_png_b64', '') <> '' then decode(ev->>'signature_png_b64', 'base64') end;
    -- V4.17: entrega COMERCIAL de AMBOS perfiles (transportista externo e interno): CUIL + identidad con DNI registrado
    -- (antes: solo Cristian). _register_identity vincula la foto nueva o reutiliza una identidad ya registrada.
    if v_commercial then
      v_cuil := regexp_replace(coalesce(ev->>'cuil', ''), '\D', '', 'g');
      if length(v_cuil) <> 11 then raise exception 'CUIL_INVALID: el CUIL debe tener 11 dígitos' using errcode = '23514'; end if;
      perform public._register_identity(v_cuil, ev);   -- RC1: DNI en Storage privado
      if not exists (select 1 from public.customer_identity_docs d where d.cuil = v_cuil and (d.storage_path is not null or d.dni_photo is not null)) then
        raise exception 'DNI_REQUIRED: cargá la foto del DNI para el CUIL nuevo' using errcode = '23514';
      end if;
    else
      v_cuil := nullif(regexp_replace(coalesce(ev->>'cuil', ''), '\D', '', 'g'), '');   -- Transportista Interno: CUIL opcional
      if v_cuil is not null and length(v_cuil) <> 11 then raise exception 'CUIL_INVALID: el CUIL debe tener 11 dígitos' using errcode = '23514'; end if;
    end if;
    -- RC4.1: email del receptor (segunda pantalla). Opcional; si viene, debe ser válido.
    v_email := nullif(lower(trim(coalesce(ev->>'email', ''))), '');
    -- V4.17: email obligatorio en TODA entrega comercial (antes: solo Cristian). Sucursales y TAREA: sin email.
    if v_commercial and v_email is null then raise exception 'EMAIL_REQUIRED: el email del receptor es obligatorio' using errcode = '23514'; end if;
    if v_email is not null and not public.is_valid_email(v_email) then raise exception 'EMAIL_INVALID: el email no es válido' using errcode = '23514'; end if;
    v_dni := nullif(regexp_replace(coalesce(ev->>'dni', ''), '\D', '', 'g'), '');
    if v_dni is null and v_cuil is not null then v_dni := substr(v_cuil, 3, 8); end if;
    if v_dni is not null and length(v_dni) not between 7 and 8 then raise exception 'DNI_INVALID: el DNI debe tener 7 u 8 dígitos' using errcode = '23514'; end if;
  end if;
  -- cobranza (Cristian): el chofer no cambia el importe esperado
  -- V4.17: la cobranza es OPCIONAL (el chofer ya no la registra). Si se informa, se valida igual que antes; si no, no se registra
  -- ningún cobro y los datos de cobranza existentes de la parada se CONSERVAN (no se inventan ni se borran).
  if v_commercial and st.task in ('COBRANZA','AMBAS') and col is not null and coalesce(col->>'status', 'PENDIENTE') <> 'PENDIENTE' then
    if col->>'status' not in ('COBRADO','COBRO_PARCIAL','NO_COBRADO') then raise exception 'BAD_COLLECTION' using errcode = '22023'; end if;
    if col->>'status' in ('COBRO_PARCIAL','NO_COBRADO') and coalesce(trim(col->>'note'), '') = '' then raise exception 'COLLECTION_NOTE_REQUIRED: cobro parcial exige observación y no cobrado exige motivo' using errcode = '23514'; end if;
    if col->>'status' in ('COBRADO','COBRO_PARCIAL') and coalesce((col->>'amount')::numeric, 0) <= 0 then raise exception 'COLLECTION_AMOUNT_REQUIRED' using errcode = '23514'; end if;
  end if;
  loc := public._loc(p_extra->'location', st);
  update public.route_stops set outcome = p_outcome, outcome_at = now(), outcome_by = auth.uid(), outcome_note = nullif(trim(p_note),''), outcome_reason = nullif(trim(p_reason),''),
    finish_location = loc, location_warning = coalesce(case when loc->>'outside_m' is not null then 'FUERA DEL RADIO (' || (loc->>'outside_m') || ' m)' end, location_warning),
    collection_status = case when st.task in ('COBRANZA','AMBAS') and coalesce(col->>'status','PENDIENTE') <> 'PENDIENTE' then col->>'status' else collection_status end,
    collected_amount = case when st.task in ('COBRANZA','AMBAS') and coalesce(col->>'status','PENDIENTE') <> 'PENDIENTE' then nullif(col->>'amount','')::numeric else collected_amount end,
    payment_mode = case when st.task in ('COBRANZA','AMBAS') and coalesce(col->>'status','PENDIENTE') <> 'PENDIENTE' then col->>'mode' else payment_mode end,
    collection_note = case when st.task in ('COBRANZA','AMBAS') and coalesce(col->>'status','PENDIENTE') <> 'PENDIENTE' then nullif(trim(col->>'note'),'') else collection_note end
  where id = p_stop returning * into st;
  if p_outcome in ('ENTREGADO','ENTREGA_PARCIAL') then
    -- La entrega guarda el email USADO (inmutable aunque el perfil cambie después)
    if sig is not null then
      insert into public.stop_evidence(stop_id, receiver_name, signature_png, signature_sha256, receiver_cuil, created_by, receiver_email, receiver_dni, evidence_kind)
      values (p_stop, coalesce(nullif(trim(ev->>'receiver_name'), ''), 'Sin receptor (tarea)'), sig, encode(sha256(sig), 'hex'), v_cuil, auth.uid(), case when v_commercial then v_email end, v_dni,
              case when st.stop_type = 'UBICACION_INTERNA' then 'RECEPCION_INTERNA' when v_task then 'TAREA' else 'ENTREGA_CLIENTE' end)
      on conflict (stop_id) do nothing;
    end if;
    -- RECEPCIÓN INTERNA DE TRASLADO: queda trazado qué pedidos llegaron a qué sucursal, quién recibió, quién trasladó, cuándo y dónde
    if st.stop_type = 'UBICACION_INTERNA' then
      insert into public.audit_log(actor_id, action, target_type, target_id, after)
      values (auth.uid(), 'INTERNAL_TRANSFER_RECEIVED', 'route_stop', p_stop::text, jsonb_build_object(
        'route_id', st.route_id, 'route_number', r.number, 'internal_location_key', st.internal_location_key, 'location_name', st.client_name, 'address', st.address,
        'order_numbers', to_jsonb(st.order_numbers), 'outcome', p_outcome, 'receiver_name', trim(ev->>'receiver_name'), 'signature_sha256', encode(sha256(sig), 'hex'),
        'transported_by', auth.uid(), 'at', now(), 'gps', loc));
    end if;
    -- Perfil reutilizable (misma capa de identidad que el DNI): nombre, DNI y email para próximas entregas
    if v_commercial and v_cuil is not null then perform public._upsert_identity_profile(v_cuil, trim(ev->>'receiver_name'), v_dni, v_email, st.client_key); end if;
    -- Recibido Conforme: entrega TOTAL confirmada + email válido → comprobante único + envío automático (la falla del email nunca revierte la entrega)
    if v_commercial and p_outcome = 'ENTREGADO' and v_email is not null then perform public._create_delivery_receipt(st, r, trim(ev->>'receiver_name'), v_email); v_receipt := true; end if;
    if v_commercial and coalesce(trim(st.customer_email), '') <> '' and not v_receipt then
      insert into public.customer_email_jobs(route_id, stop_id, kind, recipient, idempotency_key)
      values (st.route_id, st.id, case when p_outcome = 'ENTREGADO' then 'DELIVERED' else 'PARTIAL' end, lower(trim(st.customer_email)), st.route_id || '|' || st.id || '|' || case when p_outcome = 'ENTREGADO' then 'DELIVERED' else 'PARTIAL' end)
      on conflict (idempotency_key) do nothing;
    end if;
  end if;
  if p_op_id is not null then insert into public.stop_outcome_ops(op_id, stop_id) values (p_op_id, p_stop); end if;
  perform public._queue_on_the_way(st.route_id);
  return st;
end; $function$;

;
-- =====================================================================================================================
-- PROPUESTA · NO APLICADA · Permiso configurable "Permitir asignación de hojas de ruta" (routes.receive_internal)
-- Un usuario de cualquier rol (p. ej. Operador/Operario de despacho) puede ser RESPONSABLE de hojas del TRANSPORTE INTERNO y
-- realizarlas con el recorrido existente del Transportista Interno. Solo SUS hojas asignadas del Transporte Interno.
--  · No crea roles, usuarios ni transportistas. No se asigna a ningún rol por defecto: se habilita por usuario con la pantalla
--    de permisos existente (set_user_permission / user_permission_overrides).
--  · No amplía otros permisos: no otorga routes.view_assigned, deliveries.update ni deliveries.capture_signature en general.
-- Base: definiciones vigentes de can_be_responsable (fase1), _my_route (fase2b1), can_view_route_row (rc4_1_scope_email) y la
-- política identity_docs_upload (rc1_dni_storage). Solo se agrega la condición del permiso nuevo.
-- =====================================================================================================================
insert into public.permissions(code) values ('routes.receive_internal') on conflict do nothing;

-- El permiso vale SOLO si se habilitó EXPLÍCITAMENTE a ese usuario (excepción GRANT), nunca por rol: ni siquiera el Admin, que
-- recibe por rol los demás permisos, queda habilitado sin que alguien lo active. Usuario ACTIVO.
create or replace function public.receives_internal_routes(p_user uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles p join public.user_permission_overrides o on o.user_id = p.id and o.permission_code = 'routes.receive_internal' and o.granted
                 where p.id = p_user and p.status = 'ACTIVO') $$;
revoke execute on function public.receives_internal_routes(uuid) from public, anon;
grant execute on function public.receives_internal_routes(uuid) to authenticated;   -- solo devuelve verdadero/falso del usuario consultado

-- El usuario de la SESIÓN tiene el permiso habilitado y su sesión no fue revocada (mismo control que auth_has_perm)
create or replace function public._auth_receives_internal() returns boolean language sql stable security definer set search_path = public as $$
  select public.receives_internal_routes(auth.uid()) and exists (select 1 from public.profiles p where p.id = auth.uid()
      and (p.sessions_revoked_at is null or coalesce((auth.jwt() ->> 'iat')::numeric, 0) > extract(epoch from p.sessions_revoked_at))) $$;

-- ¿Es una hoja del Transporte Interno?
create or replace function public._is_internal_route(p_route uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.routes r join public.carriers c on c.id = r.carrier_id where r.id = p_route and c.kind = 'INTERNO') $$;
revoke execute on function public._is_internal_route(uuid) from public, anon, authenticated;

-- 1) Elegibilidad como RESPONSABLE: INTERNO → rol Transportista interno O el permiso nuevo (usuario ACTIVO). Externos: sin cambios.
create or replace function public.can_be_responsable(p_user uuid, p_carrier text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1
    from public.profiles p
    join public.carriers c on c.id = p_carrier and c.active
    where p.id = p_user
      and p.status = 'ACTIVO'
      and (
        (c.kind = 'INTERNO' and (p.role = 'TRANSPORTISTA_INTERNO' or public.receives_internal_routes(p.id)))
        or (c.kind = 'EXTERNO' and p.role in ('TRANSPORTISTA','TRANSPORTISTA_INTERNO')
            and exists (select 1 from public.user_carriers uc where uc.user_id = p.id and uc.carrier_id = c.id))
      )
  );
$$;

-- 2) Realizar la hoja (todas las acciones del recorrido pasan por _my_route): SOLO la hoja propia, y además:
--    · Transporte Interno → Transportista Interno (como hasta hoy: solo ellos podían ser responsables) O el permiso habilitado.
--      Al quitar el permiso se corta el acceso aunque el rol tenga otros permisos (p. ej. Admin con routes.view_assigned).
--    · Transportista externo → igual que antes (routes.view_assigned).
create or replace function public._my_route(p_route uuid) returns public.routes language plpgsql security definer set search_path = public as $$
declare r public.routes;
begin
  select * into r from public.routes where id = p_route for update;
  if not found or r.responsable_id is distinct from auth.uid()
     or not (case when public._is_internal_route(r.id)
                  then (public.auth_has_perm('routes.view_assigned') and (select role from public.profiles where id = auth.uid()) = 'TRANSPORTISTA_INTERNO')
                       or public._auth_receives_internal()
                  else public.auth_has_perm('routes.view_assigned') end)
  then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return r;
end; $$;

-- 3) Ver la hoja: se agrega SOLO su hoja asignada del Transporte Interno (lo demás, igual que antes)
create or replace function public.can_view_route_row(p_route uuid, p_published_by uuid, p_responsable uuid) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(
       public.auth_has_perm('routes.view_all')
    or (p_responsable = auth.uid() and public.auth_has_perm('routes.view_assigned'))                                   -- transportistas: igual que antes
    or (p_responsable = auth.uid() and public._auth_receives_internal() and public._is_internal_route(p_route))   -- permiso de asignación (solo su hoja interna)
    or ((public.auth_has_perm('routes.view_own') or public.auth_has_perm('routes.view_team')) and public._route_belongs_to(p_route, p_published_by, auth.uid()))
    or (public.auth_has_perm('routes.view_team') and exists (select 1 from public.team_of(auth.uid()) t where public._route_belongs_to(p_route, p_published_by, t)))
  , false);
$$;

-- 4) Ubicaciones internas para "+ AGREGAR PARADA" (p. ej. segunda visita a una sucursal): con el permiso habilitado y SOLO mientras
--    tenga asignada una hoja propia del Transporte Interno pendiente o en curso. Lista de solo lectura (nombre, dirección, radio):
--    no da permisos de administración de ubicaciones. Agregar la parada sigue validando la hoja propia (add_internal_stop → _my_route).
create or replace function public.driver_internal_locations() returns table(location_key text, name text, address text, radius_m int)
language sql stable security definer set search_path = public as $$
  select l.location_key, l.name, l.address, l.radius_m from public.internal_locations l
   where l.active and (public.auth_has_perm('internal_routes.use') or public.auth_has_perm('routes.create') or public.auth_has_perm('locations.view')
     or (public._auth_receives_internal() and exists (select 1 from public.routes r where r.responsable_id = auth.uid()
           and r.operational_status in ('PUBLICADA','EN_CURSO') and public._is_internal_route(r.id))))
   order by l.name;
$$;

-- 5) Foto del DNI de una entrega comercial de su hoja interna: subir a identity-docs también con el permiso nuevo.
--    (Solo subir; vincularla a la entrega sigue exigiendo la hoja propia en set_stop_outcome → _my_route.)
drop policy if exists identity_docs_upload on storage.objects;
create policy identity_docs_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'identity-docs' and (public.auth_has_perm('deliveries.capture_signature') or public._auth_receives_internal())
              and name ~ '^[0-9]{11}/[0-9a-f-]{36}\.(jpg|png)$');

-- Explicit execution privileges for the helper used by the Storage policy.
revoke execute on function public._auth_receives_internal() from public, anon;
grant execute on function public._auth_receives_internal() to authenticated, service_role;

;
-- =====================================================================================================================
-- PROPUESTA · NO APLICADA · REENVÍOS: volver a cargar un pedido en una hoja nueva cuando el intento anterior no se concretó.
-- Hoy order_reservations tiene UNA reserva por pedido (order_id es la clave) y al publicar queda PUBLICADA para siempre: un pedido
-- con cliente ausente o reprogramado no se puede volver a cargar.
-- Cambio mínimo en reserve_orders: la reserva PUBLICADA de un pedido pasa a la hoja nueva SOLO si en su hoja anterior
--   · todas las paradas que lo contienen quedaron NO_ENTREGADO o REPROGRAMAR, o
--   · esa hoja fue CANCELADA.
-- Sigue BLOQUEADO (mismo error PEDIDO_YA_EN_OTRA_HOJA): pendiente/en curso en otra hoja activa, ENTREGADO o ENTREGA PARCIAL, y
-- cualquier borrador ajeno. Nada se libera automáticamente: solo al cargarlo explícitamente en una hoja nueva.
-- La hoja anterior, sus paradas y resultados NO se tocan. La reserva anterior queda en order_reservation_history (trazabilidad).
-- Sin cambios de permisos: reserve_orders sigue exigiendo routes.create; el historial se lee con la misma regla que las reservas.
-- =====================================================================================================================
create table if not exists public.order_reservation_history (
  id bigint generated always as identity primary key,
  order_id text not null, sheet_key text not null, route_id uuid references public.routes(id), status text not null,
  reserved_by uuid, reserved_at timestamptz, released_at timestamptz not null default now(), released_by uuid,
  released_to_sheet text not null, reason text not null);
create index if not exists order_reservation_history_order_idx on public.order_reservation_history(order_id);
alter table public.order_reservation_history enable row level security;
drop policy if exists order_reservation_history_read on public.order_reservation_history;
create policy order_reservation_history_read on public.order_reservation_history for select to authenticated
  using (public.auth_has_perm('routes.create') or public.auth_has_perm('routes.view_all'));

-- ¿Se puede volver a intentar este pedido? (su hoja publicada fue cancelada, o TODAS sus paradas quedaron no entregadas/reprogramadas)
create or replace function public._order_retryable(p_order text, p_route uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.routes rt where rt.id = p_route and rt.operational_status = 'CANCELADA')
      or (exists (select 1 from public.route_stops s where s.route_id = p_route and p_order = any (s.order_numbers))
          and not exists (select 1 from public.route_stops s where s.route_id = p_route and p_order = any (s.order_numbers)
                          and coalesce(s.outcome, 'PENDIENTE') not in ('NO_ENTREGADO', 'REPROGRAMAR'))) $$;
revoke execute on function public._order_retryable(text, uuid) from public, anon, authenticated;

create or replace function public.reserve_orders(p_sheet_key text, p_orders text[])
returns void language plpgsql security definer set search_path = public as $$
declare msg text; det jsonb;
begin
  if not public.auth_has_perm('routes.create') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  perform public._draft(p_sheet_key, true);
  -- NUEVO: reintento. La reserva publicada de un pedido NO ENTREGADO / REPROGRAMADO (o de una hoja cancelada) pasa a esta hoja.
  with mov as (
    delete from public.order_reservations r
     where r.order_id = any (p_orders) and r.sheet_key <> p_sheet_key and r.status = 'PUBLICADA' and r.route_id is not null
       and public._order_retryable(r.order_id, r.route_id)
    returning r.*)
  insert into public.order_reservation_history(order_id, sheet_key, route_id, status, reserved_by, reserved_at, released_by, released_to_sheet, reason)
  select m.order_id, m.sheet_key, m.route_id, m.status, m.reserved_by, m.reserved_at, auth.uid(), p_sheet_key,
         case when rt.operational_status = 'CANCELADA' then 'HOJA_CANCELADA' else 'REINTENTO_NO_ENTREGADO_O_REPROGRAMADO' end
    from mov m left join public.routes rt on rt.id = m.route_id;
  -- (igual que antes)
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

-- Do not inherit project default table privileges (notably TRUNCATE, which bypasses RLS).
revoke all on public.order_reservation_history from public, anon, authenticated;
grant select on public.order_reservation_history to authenticated;
grant all on public.order_reservation_history to service_role;

;
-- =====================================================================================================================
-- PROPUESTA · NO APLICADA · COMUNICACIONES INTERNAS (colaboradores, comunicados, programación, cola de envío por Gmail, WhatsApp manual)
--  · Permisos propios comms.* (ADMIN por rol; a otros usuarios, con el editor de permisos existente). Cada operación se valida AQUÍ.
--  · Lectura con RLS (comms.view); escrituras SOLO por funciones SECURITY DEFINER que verifican el permiso.
--  · Cola: reserva atómica (FOR UPDATE SKIP LOCKED), clave única ejecución + destinatario, reintentos limitados, "Por verificar".
--  · Gmail: el token de actualización se guarda CIFRADO en Supabase Vault; solo el servidor (service_role) lo lee. Nunca vuelve al navegador.
--  · No toca ni activa los correos automáticos existentes de Despacho.
-- =====================================================================================================================

-- ---------- Permisos ----------
insert into public.permissions(code) values ('comms.view'), ('comms.collaborators_manage'), ('comms.compose'), ('comms.schedule'), ('comms.test_send'), ('comms.gmail_manage')
  on conflict do nothing;
insert into public.role_permissions(role_code, permission_code)
  select 'ADMIN', c from unnest(array['comms.view','comms.collaborators_manage','comms.compose','comms.schedule','comms.test_send','comms.gmail_manage']) c
  on conflict do nothing;

create or replace function public._comm_need(p_perm text) returns void language plpgsql stable security definer set search_path = public as $$
begin if not public.auth_has_perm(p_perm) then raise exception 'FORBIDDEN: falta el permiso %', p_perm using errcode = '42501'; end if; end; $$;
revoke execute on function public._comm_need(text) from public, anon;

-- ---------- Tablas ----------
create table if not exists public.comm_collaborators (
  id uuid primary key default gen_random_uuid(), full_name text not null check (length(trim(full_name)) > 0), email text not null,
  phone text, branch text, sector text, active boolean not null default true,
  created_at timestamptz not null default now(), created_by uuid, updated_at timestamptz not null default now(), updated_by uuid);
create unique index if not exists comm_collaborators_email_uq on public.comm_collaborators (lower(email));

create table if not exists public.comm_messages (
  id uuid primary key default gen_random_uuid(), internal_name text not null check (length(trim(internal_name)) > 0),
  subject text not null default '', body_html text not null default '', from_name text not null default 'OK Accesorios',
  selection jsonb not null default '{}'::jsonb, schedule jsonb,
  status text not null default 'BORRADOR' check (status in ('BORRADOR','ACTIVO','PAUSADO','CANCELADO','FINALIZADO')),
  version int not null default 1, active_since timestamptz, cursor timestamptz,
  created_at timestamptz not null default now(), created_by uuid, updated_at timestamptz not null default now(), updated_by uuid,
  -- defensa en el servidor: el texto con formato llega sanitizado; igualmente se rechaza contenido activo
  constraint comm_body_safe check (body_html !~* '<\s*(script|iframe|object|embed|style|svg)|javascript:|\son[a-z]+\s*='));

create table if not exists public.comm_attachments (
  id uuid primary key default gen_random_uuid(), message_id uuid not null references public.comm_messages(id),
  storage_path text not null unique, file_name text not null, mime text not null check (mime in ('image/png','image/jpeg','image/webp','image/gif','application/pdf')),
  size_bytes bigint not null check (size_bytes > 0 and size_bytes <= 8388608), sha256 text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  detached boolean not null default false, created_at timestamptz not null default now(), created_by uuid);

create table if not exists public.comm_runs (
  id uuid primary key default gen_random_uuid(), message_id uuid not null references public.comm_messages(id),
  scheduled_for timestamptz not null, kind text not null check (kind in ('PROGRAMADO','PRUEBA')),
  status text not null default 'PENDIENTE' check (status in ('PENDIENTE','EN_CURSO','COMPLETADA','PERDIDA','CANCELADA')),
  snapshot jsonb not null, recipients_count int not null default 0, note text, created_at timestamptz not null default now(), created_by uuid,
  unique (message_id, scheduled_for, kind));

create table if not exists public.comm_deliveries (
  id bigint generated always as identity primary key, run_id uuid not null references public.comm_runs(id),
  collaborator_id uuid, email text, name text,
  status text not null default 'PENDIENTE' check (status in ('PENDIENTE','PROCESANDO','ENVIADO','ERROR','POR_VERIFICAR','CANCELADO','OMITIDO','VENCIDO')),
  attempts int not null default 0, retryable boolean not null default true, next_attempt_at timestamptz,
  claim_token uuid, claimed_at timestamptz, worker text, gmail_message_id text, sent_at timestamptz,
  stale_token uuid,              -- token de un trabajo interrumpido: si Gmail había aceptado y el registro llega tarde, se acepta (con su id)
  manual_ok_until timestamptz,   -- habilitación MANUAL de un vencido o "por verificar" (no lo vence la ventana durante 1 h)
  sent_at_source text check (sent_at_source in ('GMAIL','ESTIMADA_INICIO_INTENTO')),   -- de dónde sale sent_at: respuesta de Gmail o estimación
  confirmed_at timestamptz, confirmed_by uuid,                                          -- confirmación MANUAL (distinta de la hora de envío)
  last_error text, error_code text, reason text, updated_at timestamptz not null default now());
-- CLAVE ÚNICA por ejecución y destinatario (dos trabajadores nunca crean ni procesan dos veces el mismo envío)
create unique index if not exists comm_deliveries_run_dest_uq on public.comm_deliveries (run_id, coalesce(lower(email), 'omitido:' || coalesce(collaborator_id::text, name)));
create index if not exists comm_deliveries_queue_idx on public.comm_deliveries (status, next_attempt_at);

-- Limitador COMPARTIDO de llamadas a Gmail API (una cuenta conectada): ventanas de 60 s y de 1 s, para todos los trabajadores y pruebas
create table if not exists public.comm_rate_events (id bigint generated always as identity primary key, at timestamptz not null default clock_timestamp(), units int not null);
create index if not exists comm_rate_events_at_idx on public.comm_rate_events (at);
alter table public.comm_rate_events enable row level security;
create table if not exists public.comm_whatsapp_shares (id bigint generated always as identity primary key, message_id uuid not null references public.comm_messages(id),
  shared_by uuid not null, shared_at timestamptz not null default now(), note text);
create table if not exists public.comm_audit (id bigint generated always as identity primary key, message_id uuid, entity text not null, action text not null,
  actor uuid, at timestamptz not null default now(), detail jsonb not null default '{}'::jsonb);
create table if not exists public.comm_dispatches (id bigint generated always as identity primary key, at timestamptz not null default now(), worker text, status text,
  created int, missed int, claimed int, sent int, retry int, failed int, verify int, skipped int, note text);
-- estado de la conexión (sin secretos) y estados OAuth de un solo uso: sin acceso directo desde el navegador
create table if not exists public.comm_gmail_status (id int primary key default 1 check (id = 1), connected boolean not null default false, email text,
  connected_by uuid, connected_at timestamptz, needs_reconnect boolean not null default false, last_error text, last_error_at timestamptz, secret_id uuid);
insert into public.comm_gmail_status(id) values (1) on conflict do nothing;
create table if not exists public.comm_oauth_states (state text primary key, created_by uuid not null, created_at timestamptz not null default now(),
  expires_at timestamptz not null, used_at timestamptz);

alter table public.comm_collaborators enable row level security; alter table public.comm_messages enable row level security;
alter table public.comm_attachments enable row level security; alter table public.comm_runs enable row level security;
alter table public.comm_deliveries enable row level security; alter table public.comm_whatsapp_shares enable row level security;
alter table public.comm_audit enable row level security; alter table public.comm_dispatches enable row level security;
alter table public.comm_gmail_status enable row level security; alter table public.comm_oauth_states enable row level security;
-- PRIVILEGIOS de los objetos NUEVOS del módulo: se revoca TODO lo heredado (en producción, los privilegios por defecto dan a anon y
-- authenticated INSERT/UPDATE/DELETE/TRUNCATE/REFERENCES/TRIGGER; RLS no protege TRUNCATE) y se concede SOLO lo necesario.
do $$ declare t text; begin
  foreach t in array array['comm_collaborators','comm_messages','comm_attachments','comm_runs','comm_deliveries','comm_whatsapp_shares','comm_audit','comm_dispatches','comm_gmail_status','comm_oauth_states','comm_rate_events'] loop
    execute format('revoke all on table public.%I from public, anon, authenticated', t);
  end loop;
  foreach t in array array['comm_collaborators','comm_messages','comm_attachments','comm_runs','comm_deliveries','comm_whatsapp_shares','comm_audit','comm_dispatches'] loop
    execute format('drop policy if exists %I on public.%I', t || '_read', t);
    execute format('create policy %I on public.%I for select to authenticated using (public.auth_has_perm(''comms.view''))', t || '_read', t);
    execute format('grant select on table public.%I to authenticated', t);   -- SOLO lectura (filtrada por RLS); escrituras por funciones
  end loop;
  foreach t in array array['comm_deliveries_id_seq','comm_whatsapp_shares_id_seq','comm_audit_id_seq','comm_dispatches_id_seq','comm_rate_events_id_seq'] loop
    execute format('revoke all on sequence public.%I from public, anon, authenticated', t);
  end loop;
end $$;
grant select on table public.comm_gmail_status to service_role;   -- el despachador lee el estado (sin secretos)

-- ---------- Almacenamiento PRIVADO de adjuntos (sin borrar ni reemplazar: las ejecuciones conservan su copia) ----------
insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
  values ('comm-attachments', 'comm-attachments', false, 8388608, array['image/png','image/jpeg','image/webp','image/gif','application/pdf'])
  on conflict (id) do update set public = false, file_size_limit = 8388608, allowed_mime_types = excluded.allowed_mime_types;
drop policy if exists comm_attachments_upload on storage.objects;
create policy comm_attachments_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'comm-attachments' and public.auth_has_perm('comms.compose') and name ~ '^messages/[0-9a-f-]{36}/[0-9a-f-]{36}\.(png|jpg|webp|gif|pdf)$');
drop policy if exists comm_attachments_read on storage.objects;
create policy comm_attachments_read on storage.objects for select to authenticated using (bucket_id = 'comm-attachments' and public.auth_has_perm('comms.view'));

create or replace function public._comm_audit(p_msg uuid, p_entity text, p_action text, p_detail jsonb default '{}'::jsonb) returns void
language sql security definer set search_path = public as $$ insert into public.comm_audit(message_id, entity, action, actor, detail) values (p_msg, p_entity, p_action, auth.uid(), coalesce(p_detail, '{}'::jsonb)); $$;
revoke execute on function public._comm_audit(uuid, text, text, jsonb) from public, anon, authenticated;

-- ---------- Colaboradores ----------
create or replace function public.comm_save_collaborator(p jsonb) returns public.comm_collaborators language plpgsql security definer set search_path = public as $$
declare r public.comm_collaborators; v_email text := lower(trim(coalesce(p->>'email', '')));
begin
  perform public._comm_need('comms.collaborators_manage');
  if length(trim(coalesce(p->>'full_name', ''))) = 0 then raise exception 'NOMBRE_REQUERIDO: indicá nombre y apellido' using errcode = '22023'; end if;
  if v_email !~ '^[^\s@<>()",;]+@[^\s@<>()",;]+\.[a-z]{2,}$' then raise exception 'CORREO_INVALIDO: %', v_email using errcode = '22023'; end if;
  if p ? 'id' and nullif(p->>'id', '') is not null then
    update public.comm_collaborators set full_name = trim(p->>'full_name'), email = v_email, phone = nullif(trim(p->>'phone'), ''), branch = nullif(trim(p->>'branch'), ''),
      sector = nullif(trim(p->>'sector'), ''), active = coalesce((p->>'active')::boolean, active), updated_at = now(), updated_by = auth.uid()
      where id = (p->>'id')::uuid returning * into r;
    if not found then raise exception 'NO_ENCONTRADO' using errcode = 'P0002'; end if;
  else
    insert into public.comm_collaborators(full_name, email, phone, branch, sector, active, created_by, updated_by)
      values (trim(p->>'full_name'), v_email, nullif(trim(p->>'phone'), ''), nullif(trim(p->>'branch'), ''), nullif(trim(p->>'sector'), ''), coalesce((p->>'active')::boolean, true), auth.uid(), auth.uid())
      returning * into r;
  end if;
  perform public._comm_audit(null, 'COLABORADOR', case when p ? 'id' and nullif(p->>'id', '') is not null then 'MODIFICADO' else 'CREADO' end, jsonb_build_object('collaborator_id', r.id, 'active', r.active));
  return r;
exception when unique_violation then raise exception 'CORREO_DUPLICADO: ya hay un colaborador con %', v_email using errcode = '23505';
end; $$;

-- ---------- Comunicados ----------
create or replace function public.comm_save_message(p jsonb, p_confirm boolean default false) returns public.comm_messages language plpgsql security definer set search_path = public as $$
declare r public.comm_messages; old public.comm_messages; changed text[] := '{}';
begin
  perform public._comm_need('comms.compose');
  if nullif(p->>'id', '') is null then
    insert into public.comm_messages(internal_name, subject, body_html, selection, schedule, from_name, created_by, updated_by)
      values (trim(coalesce(p->>'internal_name', '')), coalesce(p->>'subject', ''), coalesce(p->>'body_html', ''), coalesce(p->'selection', '{}'::jsonb), p->'schedule',
              coalesce(nullif(p->>'from_name', ''), 'OK Accesorios'), auth.uid(), auth.uid()) returning * into r;
    perform public._comm_audit(r.id, 'COMUNICADO', 'CREADO', '{}'::jsonb); return r;
  end if;
  select * into old from public.comm_messages where id = (p->>'id')::uuid for update;
  if not found then raise exception 'NO_ENCONTRADO' using errcode = 'P0002'; end if;
  if old.status in ('CANCELADO','FINALIZADO') then raise exception 'NO_EDITABLE: el comunicado está %; duplicalo para reutilizarlo', old.status using errcode = '22023'; end if;
  if coalesce(p->>'subject', old.subject) is distinct from old.subject then changed := array_append(changed, 'asunto'); end if;
  if coalesce(p->>'body_html', old.body_html) is distinct from old.body_html then changed := array_append(changed, 'contenido'); end if;
  if coalesce(p->'selection', old.selection) is distinct from old.selection then changed := array_append(changed, 'destinatarios'); end if;
  if (p ? 'schedule') and (p->'schedule') is distinct from old.schedule then changed := array_append(changed, 'programación'); end if;
  -- un comunicado ACTIVO/PAUSADO afecta próximos envíos: se exige confirmación explícita (y permiso de programar si cambia la programación)
  if old.status in ('ACTIVO','PAUSADO') and cardinality(changed) > 0 and not p_confirm then
    raise exception 'CONFIRMATION_REQUIRED: el cambio (%) afecta los próximos envíos', array_to_string(changed, ', ') using errcode = '22023'; end if;
  if old.status in ('ACTIVO','PAUSADO') and 'programación' = any(changed) then perform public._comm_need('comms.schedule'); end if;
  update public.comm_messages set internal_name = coalesce(nullif(trim(p->>'internal_name'), ''), internal_name), subject = coalesce(p->>'subject', subject),
    body_html = coalesce(p->>'body_html', body_html), selection = coalesce(p->'selection', selection), schedule = case when p ? 'schedule' then p->'schedule' else schedule end,
    from_name = coalesce(nullif(p->>'from_name', ''), from_name), version = version + case when cardinality(changed) > 0 then 1 else 0 end,
    -- nueva programación en un comunicado activo: rige desde ahora (no se "recupera" lo vencido)
    cursor = case when 'programación' = any(changed) and status = 'ACTIVO' then greatest(coalesce(cursor, now()), now()) else cursor end,
    active_since = case when 'programación' = any(changed) and status = 'ACTIVO' then now() else active_since end,
    updated_at = now(), updated_by = auth.uid() where id = old.id returning * into r;
  perform public._comm_audit(r.id, 'COMUNICADO', 'MODIFICADO', jsonb_build_object('cambios', to_jsonb(changed), 'version', r.version, 'confirmado', p_confirm));
  return r;
end; $$;

create or replace function public.comm_duplicate_message(p_id uuid) returns public.comm_messages language plpgsql security definer set search_path = public as $$
declare src public.comm_messages; r public.comm_messages;
begin
  perform public._comm_need('comms.compose');
  select * into src from public.comm_messages where id = p_id; if not found then raise exception 'NO_ENCONTRADO' using errcode = 'P0002'; end if;
  insert into public.comm_messages(internal_name, subject, body_html, selection, schedule, from_name, created_by, updated_by)
    values (src.internal_name || ' (copia)', src.subject, src.body_html, src.selection, src.schedule, src.from_name, auth.uid(), auth.uid()) returning * into r;
  -- los adjuntos son inmutables: la copia referencia los mismos archivos
  insert into public.comm_attachments(message_id, storage_path, file_name, mime, size_bytes, sha256, created_by)
    select r.id, a.storage_path || '#copia-' || r.id, a.file_name, a.mime, a.size_bytes, a.sha256, auth.uid() from public.comm_attachments a where a.message_id = p_id and not a.detached;
  perform public._comm_audit(r.id, 'COMUNICADO', 'DUPLICADO', jsonb_build_object('origen', p_id)); return r;
end; $$;

-- El navegador SOLO sube el archivo al bucket privado. El registro lo hace la función comm-attachments del servidor, que descarga el
-- objeto, mide su tamaño REAL, detecta el formato por su CONTENIDO y calcula el hash: aquí no se confía en datos del navegador.
create or replace function public.comm_register_attachment_srv(p_message uuid, p_path text, p_name text, p_mime text, p_size bigint, p_sha text, p_actor uuid, p_confirm boolean default false)
returns public.comm_attachments language plpgsql security definer set search_path = public as $$
declare r public.comm_attachments; m public.comm_messages; tot bigint; n int; meta_size bigint;
begin
  if not public.user_has_perm(p_actor, 'comms.compose') then raise exception 'FORBIDDEN: falta el permiso comms.compose' using errcode = '42501'; end if;
  select * into m from public.comm_messages where id = p_message for update;   -- BLOQUEO: cargas simultáneas (y repeticiones) se serializan
  if not found then raise exception 'NO_ENCONTRADO' using errcode = 'P0002'; end if;
  -- IDEMPOTENTE: repetir una solicitud válida devuelve el adjunto existente (sin duplicar, sin cambiar la versión, sin auditar de nuevo)
  select * into r from public.comm_attachments where storage_path = p_path;
  if found then
    if r.message_id = p_message and r.sha256 = lower(p_sha) and r.size_bytes = p_size then return r; end if;
    raise exception 'RUTA_YA_REGISTRADA: esa ruta ya corresponde a otro adjunto' using errcode = '22023';
  end if;
  if m.status in ('CANCELADO','FINALIZADO') then raise exception 'NO_EDITABLE' using errcode = '22023'; end if;
  if m.status in ('ACTIVO','PAUSADO') and not p_confirm then raise exception 'CONFIRMATION_REQUIRED: agregar un adjunto afecta los próximos envíos' using errcode = '22023'; end if;
  if p_path !~ ('^messages/' || p_message::text || '/[0-9a-f-]{36}\.(png|jpg|webp|gif|pdf)$') then raise exception 'RUTA_INVALIDA' using errcode = '22023'; end if;
  select (o.metadata->>'size')::bigint into meta_size from storage.objects o where o.bucket_id = 'comm-attachments' and o.name = p_path;
  if not found then raise exception 'ARCHIVO_NO_SUBIDO' using errcode = '22023'; end if;
  if meta_size is not null and meta_size <> p_size then raise exception 'TAMANIO_INCONSISTENTE' using errcode = '22023'; end if;
  select coalesce(sum(size_bytes), 0), count(*) into tot, n from public.comm_attachments where message_id = p_message and not detached;
  if n + 1 > 6 then raise exception 'DEMASIADOS_ADJUNTOS: máximo 6' using errcode = '22023'; end if;
  if tot + p_size > 15728640 then raise exception 'ADJUNTOS_MUY_GRANDES: el máximo es 15 MB por comunicado' using errcode = '22023'; end if;
  insert into public.comm_attachments(message_id, storage_path, file_name, mime, size_bytes, sha256, created_by) values (p_message, p_path, p_name, p_mime, p_size, lower(p_sha), p_actor) returning * into r;
  update public.comm_messages set version = version + 1, updated_at = now(), updated_by = p_actor where id = p_message;   -- las copias de ejecuciones ya hechas no cambian
  insert into public.comm_audit(message_id, entity, action, actor, detail) values (p_message, 'ADJUNTO', 'AGREGADO', p_actor,
    jsonb_build_object('archivo', p_name, 'bytes', p_size, 'tipo', p_mime, 'confirmado', p_confirm, 'estado', m.status));
  return r;
end; $$;
-- ¿la ruta está referenciada por algún adjunto (incluidos quitados y copias de comunicados duplicados)? Nunca se borra si lo está.
create or replace function public.comm_attachment_registered(p_path text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.comm_attachments a where split_part(a.storage_path, '#', 1) = p_path); $$;
-- SOLO DIAGNÓSTICO (lectura): objetos sin referencias y antiguos. NO hay limpieza automática: los huérfanos se conservan hasta implementar
-- una limpieza coordinada con el registro (listar y borrar después no excluye un registro simultáneo de ese mismo archivo).
create or replace function public.comm_orphan_objects(p_min_age_hours int default 24, p_limit int default 20) returns setof text language sql stable security definer set search_path = public as $$
  select o.name from storage.objects o where o.bucket_id = 'comm-attachments' and o.created_at < now() - make_interval(hours => greatest(p_min_age_hours, 1))
     and not exists (select 1 from public.comm_attachments a where split_part(a.storage_path, '#', 1) = o.name)
   order by o.created_at limit greatest(p_limit, 0); $$;
create or replace function public.comm_detach_attachment(p_id uuid, p_confirm boolean default false) returns void language plpgsql security definer set search_path = public as $$
declare a public.comm_attachments; m public.comm_messages; begin
  perform public._comm_need('comms.compose');
  select * into a from public.comm_attachments where id = p_id; if not found then raise exception 'NO_ENCONTRADO' using errcode = 'P0002'; end if;
  select * into m from public.comm_messages where id = a.message_id for update;
  if m.status in ('CANCELADO','FINALIZADO') then raise exception 'NO_EDITABLE' using errcode = '22023'; end if;
  if m.status in ('ACTIVO','PAUSADO') and not p_confirm then raise exception 'CONFIRMATION_REQUIRED: quitar un adjunto afecta los próximos envíos' using errcode = '22023'; end if;
  update public.comm_attachments set detached = true where id = p_id;   -- el archivo se conserva para las ejecuciones que lo usaron
  update public.comm_messages set version = version + 1, updated_at = now(), updated_by = auth.uid() where id = m.id;
  perform public._comm_audit(m.id, 'ADJUNTO', 'QUITADO', jsonb_build_object('adjunto', p_id, 'archivo', a.file_name, 'confirmado', p_confirm, 'estado', m.status));
end; $$;

-- ---------- Programar / pausar / reanudar / cancelar ----------
create or replace function public.comm_activate(p_id uuid) returns public.comm_messages language plpgsql security definer set search_path = public as $$
declare r public.comm_messages; g public.comm_gmail_status;
begin
  perform public._comm_need('comms.schedule');
  select * into g from public.comm_gmail_status where id = 1;
  if not g.connected or g.needs_reconnect then raise exception 'GMAIL_NOT_CONNECTED: conectá Gmail antes de programar' using errcode = '22023'; end if;
  select * into r from public.comm_messages where id = p_id for update; if not found then raise exception 'NO_ENCONTRADO' using errcode = 'P0002'; end if;
  if r.status <> 'BORRADOR' then raise exception 'ESTADO_INVALIDO: %', r.status using errcode = '22023'; end if;
  if r.schedule is null or coalesce(r.schedule->>'kind', '') not in ('ONCE','DAILY','WEEKLY','MONTHLY') or coalesce(r.schedule->>'time', '') !~ '^\d{2}:\d{2}$' then
    raise exception 'PROGRAMACION_INVALIDA' using errcode = '22023'; end if;
  if r.selection = '{}'::jsonb or not (coalesce((r.selection->>'all')::boolean, false) or jsonb_array_length(coalesce(r.selection->'ids', '[]')) > 0
      or jsonb_array_length(coalesce(r.selection->'branches', '[]')) > 0 or jsonb_array_length(coalesce(r.selection->'sectors', '[]')) > 0) then
    raise exception 'SIN_DESTINATARIOS' using errcode = '22023'; end if;
  if length(trim(r.subject)) = 0 then raise exception 'SIN_ASUNTO' using errcode = '22023'; end if;
  update public.comm_messages set status = 'ACTIVO', active_since = now(), cursor = now(), updated_at = now(), updated_by = auth.uid() where id = p_id returning * into r;
  perform public._comm_audit(p_id, 'COMUNICADO', 'PROGRAMADO', jsonb_build_object('schedule', r.schedule)); return r;
end; $$;
create or replace function public.comm_pause(p_id uuid) returns void language plpgsql security definer set search_path = public as $$
begin perform public._comm_need('comms.schedule');
  update public.comm_messages set status = 'PAUSADO', updated_at = now(), updated_by = auth.uid() where id = p_id and status = 'ACTIVO';
  if not found then raise exception 'ESTADO_INVALIDO' using errcode = '22023'; end if;
  perform public._comm_audit(p_id, 'COMUNICADO', 'PAUSADO'); end; $$;
-- reanudar: la ventana arranca AHORA (lo que venció durante la pausa no se envía de golpe)
create or replace function public.comm_resume(p_id uuid) returns void language plpgsql security definer set search_path = public as $$
begin perform public._comm_need('comms.schedule');
  update public.comm_messages set status = 'ACTIVO', active_since = now(), cursor = now(), updated_at = now(), updated_by = auth.uid() where id = p_id and status = 'PAUSADO';
  if not found then raise exception 'ESTADO_INVALIDO' using errcode = '22023'; end if;
  perform public._comm_audit(p_id, 'COMUNICADO', 'REANUDADO'); end; $$;
create or replace function public.comm_cancel(p_id uuid) returns void language plpgsql security definer set search_path = public as $$
declare n int; begin perform public._comm_need('comms.schedule');
  update public.comm_messages set status = 'CANCELADO', updated_at = now(), updated_by = auth.uid() where id = p_id and status in ('BORRADOR','ACTIVO','PAUSADO');
  if not found then raise exception 'ESTADO_INVALIDO' using errcode = '22023'; end if;
  update public.comm_deliveries d set status = 'CANCELADO', reason = 'Comunicado cancelado', updated_at = now() from public.comm_runs r
   where r.id = d.run_id and r.message_id = p_id and r.kind = 'PROGRAMADO' and (d.status = 'PENDIENTE' or (d.status = 'ERROR' and d.retryable));
  get diagnostics n = row_count;
  -- los que estaban PROCESANDO se resuelven en la verificación previa al envío (lo que Gmail ya aceptó no se puede retirar)
  update public.comm_runs r set status = 'CANCELADA' where r.message_id = p_id and r.kind = 'PROGRAMADO' and r.status in ('PENDIENTE','EN_CURSO')
    and not exists (select 1 from public.comm_deliveries d where d.run_id = r.id and d.status = 'PROCESANDO');
  perform public._comm_audit(p_id, 'COMUNICADO', 'CANCELADO', jsonb_build_object('envios_cancelados', n)); end; $$;

create or replace function public.comm_request_test(p_id uuid, p_email text) returns uuid language plpgsql security definer set search_path = public as $$
declare m public.comm_messages; rid uuid; v text := lower(trim(p_email));
begin
  perform public._comm_need('comms.test_send');
  if v !~ '^[^\s@<>()",;]+@[^\s@<>()",;]+\.[a-z]{2,}$' then raise exception 'CORREO_INVALIDO' using errcode = '22023'; end if;
  select * into m from public.comm_messages where id = p_id; if not found then raise exception 'NO_ENCONTRADO' using errcode = 'P0002'; end if;
  insert into public.comm_runs(message_id, scheduled_for, kind, snapshot, recipients_count, created_by)
    values (p_id, clock_timestamp(), 'PRUEBA', jsonb_build_object('subject', '[PRUEBA] ' || m.subject, 'body_html', m.body_html, 'from_name', m.from_name, 'message_version', m.version,
      'attachments', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'name', a.file_name, 'mime', a.mime, 'size_bytes', a.size_bytes, 'sha256', a.sha256, 'storage_path', split_part(a.storage_path, '#', 1)))
        from public.comm_attachments a where a.message_id = p_id and not a.detached), '[]'::jsonb)), 1, auth.uid()) returning id into rid;
  insert into public.comm_deliveries(run_id, email, name) values (rid, v, 'Prueba');
  perform public._comm_audit(p_id, 'COMUNICADO', 'PRUEBA_SOLICITADA', jsonb_build_object('destino', v)); return rid;
end; $$;

-- WhatsApp: registro MANUAL, separado de los correos (no confirma recepción ni dispara correos)
create or replace function public.comm_register_whatsapp(p_id uuid, p_note text default null) returns bigint language plpgsql security definer set search_path = public as $$
declare n bigint; begin perform public._comm_need('comms.compose');
  if not exists (select 1 from public.comm_messages where id = p_id) then raise exception 'NO_ENCONTRADO' using errcode = 'P0002'; end if;
  insert into public.comm_whatsapp_shares(message_id, shared_by, note) values (p_id, auth.uid(), nullif(trim(p_note), '')) returning id into n;
  perform public._comm_audit(p_id, 'WHATSAPP', 'REGISTRADO_COMPARTIDO', jsonb_build_object('nota', p_note)); return n; end; $$;

-- "Por verificar": decisión humana (confirmado en Enviados de Gmail, o reintento autorizado)
create or replace function public.comm_resolve_verify(p_delivery bigint, p_result text) returns void language plpgsql security definer set search_path = public as $$
declare rid uuid; st text; begin perform public._comm_need('comms.schedule');
  if p_result not in ('CONFIRMADO_ENVIADO','REINTENTAR') then raise exception 'RESULTADO_INVALIDO' using errcode = '22023'; end if;
  select status into st from public.comm_deliveries where id = p_delivery for update;
  if st is null or st not in ('POR_VERIFICAR','VENCIDO') or (st = 'VENCIDO' and p_result = 'CONFIRMADO_ENVIADO') then raise exception 'ESTADO_INVALIDO' using errcode = '22023'; end if;
  update public.comm_deliveries set status = case when p_result = 'CONFIRMADO_ENVIADO' then 'ENVIADO' else 'PENDIENTE' end, retryable = true, attempts = least(attempts, 3),
    manual_ok_until = case when p_result = 'REINTENTAR' then now() + interval '1 hour' end, stale_token = null,
    -- confirmado a mano: la hora de envío NO se inventa. Si Gmail no la informó, se estima con el inicio del intento (claimed_at) y se rotula así;
    -- la confirmación queda aparte (quién y cuándo). El correo sigue contando en el cupo de 24 h desde ese intento.
    sent_at = case when p_result = 'CONFIRMADO_ENVIADO' then coalesce(sent_at, claimed_at, updated_at) else sent_at end,
    sent_at_source = case when p_result = 'CONFIRMADO_ENVIADO' then coalesce(sent_at_source, 'ESTIMADA_INICIO_INTENTO') else sent_at_source end,
    confirmed_at = case when p_result = 'CONFIRMADO_ENVIADO' then now() else confirmed_at end,
    confirmed_by = case when p_result = 'CONFIRMADO_ENVIADO' then auth.uid() else confirmed_by end,
    reason = case when p_result = 'CONFIRMADO_ENVIADO' then 'Confirmado manualmente en "Enviados" de Gmail' when st = 'VENCIDO' then 'Envío del vencido autorizado manualmente' else 'Reintento autorizado manualmente' end, updated_at = now()
    where id = p_delivery returning run_id into rid;
  perform public._comm_audit((select message_id from public.comm_runs where id = rid), 'ENVIO', 'VERIFICACION_' || p_result, jsonb_build_object('delivery', p_delivery, 'estado_previo', st)); end; $$;

-- ---------- Conexión Gmail (estado sin secretos; OAuth y token SOLO del lado del servidor) ----------
create or replace function public.comm_gmail_status() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare g public.comm_gmail_status; d public.comm_dispatches;
begin perform public._comm_need('comms.view');
  select * into g from public.comm_gmail_status where id = 1; select * into d from public.comm_dispatches order by id desc limit 1;
  return jsonb_build_object('connected', g.connected, 'email', g.email, 'connected_at', g.connected_at, 'needs_reconnect', g.needs_reconnect, 'last_error', g.last_error,
    'last_error_at', g.last_error_at, 'last_dispatch', case when d.id is null then null else jsonb_build_object('at', d.at, 'status', d.status, 'sent', d.sent, 'note', d.note) end);
end; $$;
create or replace function public.comm_oauth_begin() returns text language plpgsql security definer set search_path = public as $$
declare s text := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''); begin perform public._comm_need('comms.gmail_manage');   -- 244 bits aleatorios, sin pgcrypto
  delete from public.comm_oauth_states where expires_at < now() - interval '1 day';
  insert into public.comm_oauth_states(state, created_by, expires_at) values (s, auth.uid(), now() + interval '10 minutes'); return s; end; $$;
-- SOLO servidor (service_role): consumir el estado OAuth, guardar/leer el token cifrado, marcar errores, desconectar
create or replace function public.comm_oauth_consume(p_state text) returns uuid language plpgsql security definer set search_path = public as $$
declare who uuid; begin
  update public.comm_oauth_states set used_at = now() where state = p_state and used_at is null and expires_at > now() returning created_by into who;
  if who is null then raise exception 'OAUTH_STATE_INVALIDO' using errcode = '22023'; end if;
  if not public.user_has_perm(who, 'comms.gmail_manage') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return who; end; $$;
create or replace function public.comm_gmail_store(p_email text, p_refresh_token text, p_actor uuid) returns void language plpgsql security definer set search_path = public, vault as $$
declare sid uuid; begin
  select secret_id into sid from public.comm_gmail_status where id = 1;
  if sid is null or not exists (select 1 from vault.secrets where id = sid) then sid := vault.create_secret(p_refresh_token, 'comm_gmail_refresh_token', 'Comunicaciones: token de Gmail');
  else perform vault.update_secret(sid, p_refresh_token); end if;
  update public.comm_gmail_status set connected = true, email = lower(p_email), connected_by = p_actor, connected_at = now(), needs_reconnect = false, last_error = null, secret_id = sid where id = 1;
  insert into public.comm_audit(entity, action, actor, detail) values ('GMAIL', 'CONECTADO', p_actor, jsonb_build_object('email', lower(p_email))); end; $$;
create or replace function public.comm_gmail_secret() returns text language sql stable security definer set search_path = public, vault as $$
  select ds.decrypted_secret from vault.decrypted_secrets ds join public.comm_gmail_status g on g.secret_id = ds.id where g.id = 1 and g.connected; $$;
create or replace function public.comm_gmail_mark(p_needs_reconnect boolean, p_error text) returns void language sql security definer set search_path = public as $$
  update public.comm_gmail_status set needs_reconnect = p_needs_reconnect or needs_reconnect, last_error = left(p_error, 300), last_error_at = now() where id = 1; $$;
create or replace function public.comm_gmail_clear(p_actor uuid) returns void language plpgsql security definer set search_path = public, vault as $$
declare sid uuid; begin
  select secret_id into sid from public.comm_gmail_status where id = 1;
  if sid is not null then delete from vault.secrets where id = sid; end if;
  update public.comm_gmail_status set connected = false, email = null, needs_reconnect = false, secret_id = null, last_error = null where id = 1;
  insert into public.comm_audit(entity, action, actor) values ('GMAIL', 'DESCONECTADO', p_actor); end; $$;
create or replace function public.comm_can(p_perm text) returns boolean language sql stable security definer set search_path = public as $$
  select p_perm like 'comms.%' and public.auth_has_perm(p_perm); $$;

-- ---------- Cola (SOLO el despachador del servidor, service_role) ----------
create or replace function public.comm_list_active_messages() returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'subject', m.subject, 'body_html', m.body_html, 'from_name', m.from_name, 'version', m.version, 'selection', m.selection,
    'schedule', m.schedule, 'cursor', m.cursor, 'active_since', m.active_since,
    'attachments', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'name', a.file_name, 'mime', a.mime, 'size_bytes', a.size_bytes, 'sha256', a.sha256, 'storage_path', split_part(a.storage_path, '#', 1)))
      from public.comm_attachments a where a.message_id = m.id and not a.detached), '[]'::jsonb))), '[]'::jsonb)
  from public.comm_messages m where m.status = 'ACTIVO'; $$;
create or replace function public.comm_list_collaborators_all() returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(to_jsonb(c)), '[]'::jsonb) from public.comm_collaborators c; $$;
create or replace function public.comm_create_run(p_message uuid, p_scheduled_for timestamptz, p_kind text, p_missed boolean, p_recipients jsonb, p_skipped jsonb, p_snapshot jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare rid uuid; begin
  insert into public.comm_runs(message_id, scheduled_for, kind, status, snapshot, recipients_count, note)
    values (p_message, p_scheduled_for, p_kind, case when p_missed then 'PERDIDA' else 'PENDIENTE' end, p_snapshot, jsonb_array_length(coalesce(p_recipients, '[]')),
            case when p_missed then 'Ejecución perdida (el servidor no la procesó a tiempo): NO se envió; queda para revisión.' end)
    on conflict (message_id, scheduled_for, kind) do nothing returning id into rid;
  if rid is null then return null; end if;   -- ya existía (otro trabajador la creó): no se duplica
  insert into public.comm_deliveries(run_id, collaborator_id, email, name)
    select rid, nullif(x->>'collaborator_id', '')::uuid, lower(x->>'email'), x->>'name' from jsonb_array_elements(coalesce(p_recipients, '[]')) x on conflict do nothing;
  insert into public.comm_deliveries(run_id, collaborator_id, name, status, reason)
    select rid, nullif(x->>'id', '')::uuid, x->>'name', 'OMITIDO', x->>'reason' from jsonb_array_elements(coalesce(p_skipped, '[]')) x on conflict do nothing;
  return rid; end; $$;
create or replace function public.comm_advance_cursor(p_message uuid, p_prev timestamptz, p_next timestamptz) returns boolean language plpgsql security definer set search_path = public as $$
begin update public.comm_messages set cursor = p_next where id = p_message and cursor is not distinct from p_prev; return found; end; $$;
create or replace function public.comm_sent_last24h(p_now timestamptz default now()) returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from public.comm_deliveries where status = 'ENVIADO' and coalesce(sent_at, claimed_at, confirmed_at) > p_now - interval '24 hours'; $$;
create or replace function public.comm_claim(p_limit int, p_worker text, p_now timestamptz default now(), p_daily_cap int default 400, p_window_hours int default 6)
returns table(id bigint, token uuid, run_id uuid, email text, name text, collaborator_id uuid, attempts int, snapshot jsonb)
language plpgsql security definer set search_path = public as $$
declare v_used int; v_take int;
begin
  -- serializa las reservas: dos trabajadores no pueden calcular el cupo al mismo tiempo
  perform pg_advisory_xact_lock(hashtext('okd_comm_claim'));
  -- trabajador caído a mitad de envío: NO se reenvía a ciegas; se conserva su token por si el registro llega tarde
  update public.comm_deliveries set status = 'POR_VERIFICAR', stale_token = claim_token, claim_token = null, updated_at = p_now,
    last_error = 'El procesamiento se interrumpió: verificá en "Enviados" de Gmail si llegó a enviarse antes de reintentar.'
    where comm_deliveries.status = 'PROCESANDO' and claimed_at < p_now - interval '10 minutes';
  -- VENCIMIENTO también para pendientes y reintentos ya encolados (p. ej. al reanudar): quedan para revisión, sin envío
  update public.comm_deliveries d set status = 'VENCIDO', next_attempt_at = null, updated_at = p_now,
    reason = 'Vencido: no se envió dentro de las ' || p_window_hours || ' h siguientes al horario programado (pausa, desconexión o interrupción). Queda para revisión; no se envía automáticamente.'
    from public.comm_runs r where r.id = d.run_id and (d.status = 'PENDIENTE' or (d.status = 'ERROR' and d.retryable))
      and r.scheduled_for < p_now - make_interval(hours => p_window_hours) and not coalesce(d.manual_ok_until > p_now, false);
  -- CUPO diario reservado AQUÍ: enviados + en curso + inciertos de las últimas 24 h (incluye pruebas)
  select count(*) filter (where d.status = 'ENVIADO' and coalesce(d.sent_at, d.claimed_at, d.confirmed_at) > p_now - interval '24 hours')
       + count(*) filter (where d.status = 'PROCESANDO')
       + count(*) filter (where d.status = 'POR_VERIFICAR' and coalesce(d.claimed_at, d.updated_at) > p_now - interval '24 hours') into v_used from public.comm_deliveries d;
  v_take := greatest(0, least(p_limit, p_daily_cap - v_used));
  return query
  with c as (
    select d.id from public.comm_deliveries d join public.comm_runs r on r.id = d.run_id left join public.comm_messages m on m.id = r.message_id
     where (d.status = 'PENDIENTE' or (d.status = 'ERROR' and d.retryable and d.attempts < 4 and d.next_attempt_at <= p_now))
       and r.status not in ('CANCELADA','PERDIDA') and (r.kind = 'PRUEBA' or m.status = 'ACTIVO')
     order by r.scheduled_for, d.id
     for update of d skip locked
     limit v_take)
  update public.comm_deliveries d set status = 'PROCESANDO', claim_token = gen_random_uuid(), claimed_at = p_now, attempts = d.attempts + 1, worker = p_worker, updated_at = p_now
    from c, public.comm_runs r where d.id = c.id and r.id = d.run_id
  returning d.id, d.claim_token, d.run_id, d.email, d.name, d.collaborator_id, d.attempts, r.snapshot;
end; $$;
-- Cupo de VELOCIDAD compartido (todos los trabajadores y las pruebas): concede 'p_units' si caben en las ventanas de 60 s y de 1 s;
-- si no, devuelve cuántos ms esperar (nada se registra). Serializado con un candado transaccional.
create or replace function public.comm_rate_acquire(p_units int, p_per_min int default 6000, p_per_sec int default 200) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t timestamptz := clock_timestamp(); m60 int; m1 int; w60 numeric := 0; w1 numeric := 0; eid bigint;
begin
  perform pg_advisory_xact_lock(hashtext('okd_comm_rate'));
  delete from public.comm_rate_events where at < t - interval '2 minutes';
  select coalesce(sum(units), 0) into m60 from public.comm_rate_events where at > t - interval '60 seconds';
  select coalesce(sum(units), 0) into m1 from public.comm_rate_events where at > t - interval '1 second';
  if m60 + p_units <= p_per_min and m1 + p_units <= p_per_sec then
    insert into public.comm_rate_events(at, units) values (t, p_units) returning id into eid;
    return jsonb_build_object('wait_ms', 0, 'event_id', eid);
  end if;
  if m60 + p_units > p_per_min then select extract(epoch from (min(at) + interval '60 seconds' - t)) * 1000 into w60 from public.comm_rate_events where at > t - interval '60 seconds'; end if;
  if m1 + p_units > p_per_sec then select extract(epoch from (min(at) + interval '1 second' - t)) * 1000 into w1 from public.comm_rate_events where at > t - interval '1 second'; end if;
  return jsonb_build_object('wait_ms', greatest(ceil(greatest(w60, w1)), 20)::int);
end; $$;
-- devuelve EXACTAMENTE una reserva (envío interrumpido antes de llamar a Gmail: cancelado, pausado, sin conexión…)
create or replace function public.comm_rate_refund(p_event_id bigint) returns void language sql security definer set search_path = public as $$
  delete from public.comm_rate_events where id = p_event_id; $$;
create or replace function public.comm_check(p_id bigint, p_token uuid) returns text language plpgsql security definer set search_path = public as $$
declare d public.comm_deliveries; r public.comm_runs; m public.comm_messages; c public.comm_collaborators; g public.comm_gmail_status;
begin
  select * into d from public.comm_deliveries where id = p_id for update;
  if not found or d.status <> 'PROCESANDO' or d.claim_token is distinct from p_token then return 'LOST'; end if;
  select * into r from public.comm_runs where id = d.run_id; select * into m from public.comm_messages where id = r.message_id;
  if r.kind <> 'PRUEBA' then
    if r.status = 'CANCELADA' or m.status = 'CANCELADO' then update public.comm_deliveries set status = 'CANCELADO', claim_token = null, reason = 'Comunicado cancelado antes del envío', updated_at = now() where id = p_id; return 'CANCELLED'; end if;
    if m.status = 'PAUSADO' then update public.comm_deliveries set status = 'PENDIENTE', claim_token = null, attempts = attempts - 1, updated_at = now() where id = p_id; return 'PAUSED'; end if;
    if d.collaborator_id is not null then select * into c from public.comm_collaborators where id = d.collaborator_id;
      if found and not c.active then update public.comm_deliveries set status = 'OMITIDO', claim_token = null, reason = 'Colaborador desactivado antes del envío', updated_at = now() where id = p_id; return 'INACTIVE_RECIPIENT'; end if; end if;
  end if;
  select * into g from public.comm_gmail_status where id = 1;
  if not g.connected or g.needs_reconnect then update public.comm_deliveries set status = 'PENDIENTE', claim_token = null, attempts = attempts - 1, updated_at = now() where id = p_id; return 'NO_CONNECTION'; end if;
  return 'OK'; end; $$;
create or replace function public.comm_release(p_id bigint, p_token uuid) returns void language sql security definer set search_path = public as $$
  update public.comm_deliveries set status = 'PENDIENTE', claim_token = null, attempts = attempts - 1, updated_at = now() where id = p_id and claim_token = p_token and status = 'PROCESANDO'; $$;
create or replace function public._comm_settle_run(p_run uuid) returns void language sql security definer set search_path = public as $$
  update public.comm_runs r set status = case when exists (select 1 from public.comm_deliveries d where d.run_id = r.id and (d.status in ('PENDIENTE','PROCESANDO') or (d.status = 'ERROR' and d.retryable)))
    then 'EN_CURSO' else 'COMPLETADA' end where r.id = p_run and r.status not in ('CANCELADA','PERDIDA'); $$;
create or replace function public.comm_finish(p_id bigint, p_token uuid, p_outcome text, p_gmail_id text default null, p_error_code text default null, p_error text default null) returns text
language plpgsql security definer set search_path = public as $$
declare d public.comm_deliveries; begin
  select * into d from public.comm_deliveries where id = p_id for update;
  -- Gmail aceptó pero el registro llegó tarde (el trabajo ya figuraba "Por verificar"): se acepta con su id
  if found and d.status = 'POR_VERIFICAR' and p_outcome = 'ACCEPTED' and d.stale_token = p_token then
    update public.comm_deliveries set status = 'ENVIADO', gmail_message_id = p_gmail_id, sent_at = now(), sent_at_source = 'GMAIL', stale_token = null, last_error = null,
      reason = 'Registro tardío de una aceptación de Gmail', updated_at = now() where id = p_id;
    perform public._comm_settle_run(d.run_id); return 'OK'; end if;
  if not found or d.status <> 'PROCESANDO' or d.claim_token is distinct from p_token then return 'LOST'; end if;
  if p_outcome = 'ACCEPTED' then
    update public.comm_deliveries set status = 'ENVIADO', claim_token = null, gmail_message_id = p_gmail_id, sent_at = now(), sent_at_source = 'GMAIL', last_error = null, updated_at = now() where id = p_id;
  elsif p_outcome = 'RETRYABLE' and d.attempts < 4 then
    update public.comm_deliveries set status = 'ERROR', claim_token = null, retryable = true, error_code = p_error_code, last_error = left(p_error, 500), updated_at = now(),
      next_attempt_at = now() + make_interval(secs => least(3600, 60 * power(4, greatest(d.attempts - 1, 0))::int)) where id = p_id;
  elsif p_outcome = 'AMBIGUOUS' then
    update public.comm_deliveries set status = 'POR_VERIFICAR', claim_token = null, error_code = p_error_code, last_error = left(p_error, 500), updated_at = now() where id = p_id;
  else
    update public.comm_deliveries set status = 'ERROR', claim_token = null, retryable = false, next_attempt_at = null, error_code = p_error_code, updated_at = now(),
      last_error = left(case when p_outcome = 'RETRYABLE' then 'Se agotaron los reintentos. ' else '' end || coalesce(p_error, ''), 500) where id = p_id;
    if p_outcome = 'AUTH' then perform public.comm_gmail_mark(true, p_error); end if;
  end if;
  perform public._comm_settle_run(d.run_id); return 'OK'; end; $$;
create or replace function public.comm_record_dispatch(p jsonb) returns void language sql security definer set search_path = public as $$
  insert into public.comm_dispatches(at, worker, status, created, missed, claimed, sent, retry, failed, verify, skipped, note)
  values (coalesce((p->>'at')::timestamptz, now()), p->>'worker', p->>'status', (p->>'created')::int, (p->>'missed')::int, (p->>'claimed')::int, (p->>'sent')::int, (p->>'retry')::int,
          (p->>'failed')::int, (p->>'verify')::int, (p->>'skipped')::int, left(p->>'note', 300)); $$;

-- ---------- Permisos de ejecución ----------
do $$ declare f text; begin
  -- acciones de usuarios (cada una valida su permiso adentro)
  foreach f in array array['comm_save_collaborator(jsonb)','comm_save_message(jsonb,boolean)','comm_duplicate_message(uuid)',
    'comm_detach_attachment(uuid,boolean)','comm_activate(uuid)','comm_pause(uuid)','comm_resume(uuid)','comm_cancel(uuid)','comm_request_test(uuid,text)','comm_register_whatsapp(uuid,text)',
    'comm_resolve_verify(bigint,text)','comm_gmail_status()','comm_oauth_begin()','comm_can(text)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon'; execute 'grant execute on function public.' || f || ' to authenticated, service_role'; end loop;
  -- SOLO servidor: token, OAuth, cola
  foreach f in array array['comm_oauth_consume(text)','comm_gmail_store(text,text,uuid)','comm_gmail_secret()','comm_gmail_mark(boolean,text)','comm_gmail_clear(uuid)',
    'comm_list_active_messages()','comm_list_collaborators_all()','comm_create_run(uuid,timestamptz,text,boolean,jsonb,jsonb,jsonb)','comm_advance_cursor(uuid,timestamptz,timestamptz)',
    'comm_sent_last24h(timestamptz)','comm_claim(int,text,timestamptz,int,int)','comm_register_attachment_srv(uuid,text,text,text,bigint,text,uuid,boolean)',
    'comm_rate_acquire(int,int,int)','comm_rate_refund(bigint)','comm_attachment_registered(text)','comm_orphan_objects(int,int)','comm_check(bigint,uuid)','comm_release(bigint,uuid)','comm_finish(bigint,uuid,text,text,text,text)',
    'comm_record_dispatch(jsonb)','_comm_settle_run(uuid)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon, authenticated'; execute 'grant execute on function public.' || f || ' to service_role'; end loop;
  -- auxiliares internas: solo las usan otras funciones del módulo (SECURITY DEFINER)
  foreach f in array array['_comm_need(text)','_comm_audit(uuid,text,text,jsonb)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon, authenticated'; end loop;
end $$;

;
-- =====================================================================================================================
-- PROPUESTA V4.21 · NO APLICADA · set_stop_outcome: entrega SIN foto del DNI y con EMAIL OPCIONAL
-- BASE EXACTA: la V4.17 instalada en producción (verificada por el usuario: huella 5e4bf78470b993100851b6dde6ae7f74, aplicada el 22/10/2026).
-- ÚNICOS CAMBIOS contra la V4.17 (todo lo demás es idéntico, carácter por carácter):
--   (1) Se quita DNI_REQUIRED: la foto del DNI ya no se exige a ningún transportista (_register_identity solo vincula una foto si llega).
--   (2) Se quita EMAIL_REQUIRED: el email del receptor es OPCIONAL. Si viene, se valida (EMAIL_INVALID) y se genera el Recibido
--       Conforme como hasta ahora; si no viene, la entrega se confirma y NO se crea Recibido Conforme ni envío a una dirección vacía.
-- SIN CAMBIOS: nombre + firma obligatorios (EVIDENCE_REQUIRED); CUIL obligatorio en la entrega comercial de ambos transportistas
--   (CUIL_INVALID); DNI_INVALID; cobranza opcional de la V4.17 (se valida solo si se informa); recepción interna G2 (nombre + firma, sin
--   CUIL ni email); TAREA; idempotencia por op_id; llegada a destino; perfil reutilizable; avisos DELIVERED/PARTIAL al email del
--   cliente cargado en la hoja; SECURITY DEFINER, search_path, dueño y permisos (CREATE OR REPLACE los conserva). No borra datos.
-- SEGURIDAD: todo en UNA transacción. Antes de cambiar nada verifica que la función instalada sea EXACTAMENTE la V4.17 (una sola
--   definición, mismos argumentos, misma huella); si no, se detiene SIN modificar nada. Al final verifica la huella resultante.
-- =====================================================================================================================
BEGIN;
DO $guard$ BEGIN
  IF (SELECT count(*) FROM pg_proc WHERE proname = 'set_stop_outcome' AND pronamespace = 'public'::regnamespace) <> 1 THEN
    RAISE EXCEPTION 'HUELLA_INESPERADA: hay % definiciones de public.set_stop_outcome (se esperaba 1). No se modificó nada.',
      (SELECT count(*) FROM pg_proc WHERE proname = 'set_stop_outcome' AND pronamespace = 'public'::regnamespace);
  END IF;
  IF (SELECT pg_get_function_identity_arguments(oid) FROM pg_proc WHERE proname = 'set_stop_outcome' AND pronamespace = 'public'::regnamespace) <> 'p_stop uuid, p_outcome text, p_note text, p_reason text, p_op_id text, p_extra jsonb' THEN
    RAISE EXCEPTION 'HUELLA_INESPERADA: los argumentos de set_stop_outcome no son los de la V4.17. No se modificó nada.';
  END IF;
  IF (SELECT md5(prosrc) FROM pg_proc WHERE proname = 'set_stop_outcome' AND pronamespace = 'public'::regnamespace) <> '5e4bf78470b993100851b6dde6ae7f74' THEN
    RAISE EXCEPTION 'HUELLA_INESPERADA: set_stop_outcome no es la V4.17 (5e4bf78470b993100851b6dde6ae7f74); es %. No se modificó nada.',
      (SELECT md5(prosrc) FROM pg_proc WHERE proname = 'set_stop_outcome' AND pronamespace = 'public'::regnamespace);
  END IF;
END $guard$;

CREATE OR REPLACE FUNCTION public.set_stop_outcome(p_stop uuid, p_outcome text, p_note text, p_reason text, p_op_id text, p_extra jsonb DEFAULT NULL::jsonb)
 RETURNS route_stops
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare st public.route_stops; r public.routes; cristian boolean; v_commercial boolean; v_task boolean; v_cuil text; v_email text; v_dni text; v_receipt boolean := false; ev jsonb := coalesce(p_extra->'evidence', '{}'); col jsonb := p_extra->'collection'; loc jsonb; sig bytea;
begin
  select * into st from public.route_stops where id = p_stop;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  r := public._my_route(st.route_id);
  -- Comportamiento por tipo de parada: solo PEDIDO es entrega comercial al cliente (email, Recibido Conforme, cobranza, identidad).
  v_commercial := coalesce(st.stop_type, 'PEDIDO') = 'PEDIDO';
  v_task := st.stop_type = 'TAREA';
  if p_op_id is not null and exists (select 1 from public.stop_outcome_ops where op_id = p_op_id) then return st; end if;
  if r.operational_status <> 'EN_CURSO' then raise exception 'BAD_STATE: iniciá el recorrido o la hoja ya está cerrada' using errcode = '23514'; end if;
  if p_outcome not in ('ENTREGADO','ENTREGA_PARCIAL','NO_ENTREGADO','REPROGRAMAR') then raise exception 'BAD_OUTCOME' using errcode = '22023'; end if;
  if p_outcome = 'ENTREGA_PARCIAL' and coalesce(trim(p_note), '') = '' then raise exception 'NOTE_REQUIRED: entrega parcial exige observación' using errcode = '23514'; end if;
  if p_outcome in ('NO_ENTREGADO','REPROGRAMAR') and coalesce(trim(p_reason), '') = '' then raise exception 'REASON_REQUIRED: indicá el motivo' using errcode = '23514'; end if;
  cristian := exists (select 1 from public.carriers where id = r.carrier_id and report_group = 'CRISTIAN_TORRES');
  if p_outcome in ('ENTREGADO','ENTREGA_PARCIAL') then
    -- TAREA: no se exige firma ni receptor como en una entrega comercial (alcanza GPS u observación). El resto, igual que antes.
    if not v_task and (coalesce(trim(ev->>'receiver_name'), '') = '' or coalesce(ev->>'signature_png_b64', '') = '') then raise exception 'EVIDENCE_REQUIRED: nombre del receptor y firma obligatorios' using errcode = '23514'; end if;
    sig := case when coalesce(ev->>'signature_png_b64', '') <> '' then decode(ev->>'signature_png_b64', 'base64') end;
    -- V4.17: entrega COMERCIAL de AMBOS perfiles (transportista externo e interno): CUIL + identidad con DNI registrado
    -- (antes: solo Cristian). _register_identity vincula la foto nueva o reutiliza una identidad ya registrada.
    if v_commercial then
      v_cuil := regexp_replace(coalesce(ev->>'cuil', ''), '\D', '', 'g');
      if length(v_cuil) <> 11 then raise exception 'CUIL_INVALID: el CUIL debe tener 11 dígitos' using errcode = '23514'; end if;
      perform public._register_identity(v_cuil, ev);   -- V4.21: solo VINCULA una foto si llega (entregas viejas en cola); la foto del DNI ya no se exige
    else
      v_cuil := nullif(regexp_replace(coalesce(ev->>'cuil', ''), '\D', '', 'g'), '');   -- Transportista Interno: CUIL opcional
      if v_cuil is not null and length(v_cuil) <> 11 then raise exception 'CUIL_INVALID: el CUIL debe tener 11 dígitos' using errcode = '23514'; end if;
    end if;
    -- RC4.1: email del receptor (segunda pantalla). Opcional; si viene, debe ser válido.
    v_email := nullif(lower(trim(coalesce(ev->>'email', ''))), '');
    -- V4.21: el email del receptor es OPCIONAL (ambos transportistas). Si viene, se valida el formato (abajo) y se genera el Recibido
    -- Conforme; si no viene, la entrega se confirma igual y NO se intenta enviar el Recibido Conforme.
    if v_email is not null and not public.is_valid_email(v_email) then raise exception 'EMAIL_INVALID: el email no es válido' using errcode = '23514'; end if;
    v_dni := nullif(regexp_replace(coalesce(ev->>'dni', ''), '\D', '', 'g'), '');
    if v_dni is null and v_cuil is not null then v_dni := substr(v_cuil, 3, 8); end if;
    if v_dni is not null and length(v_dni) not between 7 and 8 then raise exception 'DNI_INVALID: el DNI debe tener 7 u 8 dígitos' using errcode = '23514'; end if;
  end if;
  -- cobranza (Cristian): el chofer no cambia el importe esperado
  -- V4.17: la cobranza es OPCIONAL (el chofer ya no la registra). Si se informa, se valida igual que antes; si no, no se registra
  -- ningún cobro y los datos de cobranza existentes de la parada se CONSERVAN (no se inventan ni se borran).
  if v_commercial and st.task in ('COBRANZA','AMBAS') and col is not null and coalesce(col->>'status', 'PENDIENTE') <> 'PENDIENTE' then
    if col->>'status' not in ('COBRADO','COBRO_PARCIAL','NO_COBRADO') then raise exception 'BAD_COLLECTION' using errcode = '22023'; end if;
    if col->>'status' in ('COBRO_PARCIAL','NO_COBRADO') and coalesce(trim(col->>'note'), '') = '' then raise exception 'COLLECTION_NOTE_REQUIRED: cobro parcial exige observación y no cobrado exige motivo' using errcode = '23514'; end if;
    if col->>'status' in ('COBRADO','COBRO_PARCIAL') and coalesce((col->>'amount')::numeric, 0) <= 0 then raise exception 'COLLECTION_AMOUNT_REQUIRED' using errcode = '23514'; end if;
  end if;
  loc := public._loc(p_extra->'location', st);
  update public.route_stops set outcome = p_outcome, outcome_at = now(), outcome_by = auth.uid(), outcome_note = nullif(trim(p_note),''), outcome_reason = nullif(trim(p_reason),''),
    finish_location = loc, location_warning = coalesce(case when loc->>'outside_m' is not null then 'FUERA DEL RADIO (' || (loc->>'outside_m') || ' m)' end, location_warning),
    collection_status = case when st.task in ('COBRANZA','AMBAS') and coalesce(col->>'status','PENDIENTE') <> 'PENDIENTE' then col->>'status' else collection_status end,
    collected_amount = case when st.task in ('COBRANZA','AMBAS') and coalesce(col->>'status','PENDIENTE') <> 'PENDIENTE' then nullif(col->>'amount','')::numeric else collected_amount end,
    payment_mode = case when st.task in ('COBRANZA','AMBAS') and coalesce(col->>'status','PENDIENTE') <> 'PENDIENTE' then col->>'mode' else payment_mode end,
    collection_note = case when st.task in ('COBRANZA','AMBAS') and coalesce(col->>'status','PENDIENTE') <> 'PENDIENTE' then nullif(trim(col->>'note'),'') else collection_note end
  where id = p_stop returning * into st;
  if p_outcome in ('ENTREGADO','ENTREGA_PARCIAL') then
    -- La entrega guarda el email USADO (inmutable aunque el perfil cambie después)
    if sig is not null then
      insert into public.stop_evidence(stop_id, receiver_name, signature_png, signature_sha256, receiver_cuil, created_by, receiver_email, receiver_dni, evidence_kind)
      values (p_stop, coalesce(nullif(trim(ev->>'receiver_name'), ''), 'Sin receptor (tarea)'), sig, encode(sha256(sig), 'hex'), v_cuil, auth.uid(), case when v_commercial then v_email end, v_dni,
              case when st.stop_type = 'UBICACION_INTERNA' then 'RECEPCION_INTERNA' when v_task then 'TAREA' else 'ENTREGA_CLIENTE' end)
      on conflict (stop_id) do nothing;
    end if;
    -- RECEPCIÓN INTERNA DE TRASLADO: queda trazado qué pedidos llegaron a qué sucursal, quién recibió, quién trasladó, cuándo y dónde
    if st.stop_type = 'UBICACION_INTERNA' then
      insert into public.audit_log(actor_id, action, target_type, target_id, after)
      values (auth.uid(), 'INTERNAL_TRANSFER_RECEIVED', 'route_stop', p_stop::text, jsonb_build_object(
        'route_id', st.route_id, 'route_number', r.number, 'internal_location_key', st.internal_location_key, 'location_name', st.client_name, 'address', st.address,
        'order_numbers', to_jsonb(st.order_numbers), 'outcome', p_outcome, 'receiver_name', trim(ev->>'receiver_name'), 'signature_sha256', encode(sha256(sig), 'hex'),
        'transported_by', auth.uid(), 'at', now(), 'gps', loc));
    end if;
    -- Perfil reutilizable (misma capa de identidad que el DNI): nombre, DNI y email para próximas entregas
    if v_commercial and v_cuil is not null then perform public._upsert_identity_profile(v_cuil, trim(ev->>'receiver_name'), v_dni, v_email, st.client_key); end if;
    -- Recibido Conforme: entrega TOTAL confirmada + email válido → comprobante único + envío automático (la falla del email nunca revierte la entrega)
    if v_commercial and p_outcome = 'ENTREGADO' and v_email is not null then perform public._create_delivery_receipt(st, r, trim(ev->>'receiver_name'), v_email); v_receipt := true; end if;
    if v_commercial and coalesce(trim(st.customer_email), '') <> '' and not v_receipt then
      insert into public.customer_email_jobs(route_id, stop_id, kind, recipient, idempotency_key)
      values (st.route_id, st.id, case when p_outcome = 'ENTREGADO' then 'DELIVERED' else 'PARTIAL' end, lower(trim(st.customer_email)), st.route_id || '|' || st.id || '|' || case when p_outcome = 'ENTREGADO' then 'DELIVERED' else 'PARTIAL' end)
      on conflict (idempotency_key) do nothing;
    end if;
  end if;
  if p_op_id is not null then insert into public.stop_outcome_ops(op_id, stop_id) values (p_op_id, p_stop); end if;
  perform public._queue_on_the_way(st.route_id);
  return st;
end; $function$;

DO $post$ BEGIN
  IF (SELECT md5(prosrc) FROM pg_proc WHERE proname = 'set_stop_outcome' AND pronamespace = 'public'::regnamespace) <> '5d26e5af27a068596cc6875bd6ee8bbf' THEN
    RAISE EXCEPTION 'HUELLA_FINAL_INESPERADA: la función resultante no es la V4.21 esperada (5d26e5af27a068596cc6875bd6ee8bbf). Se deshace todo.';
  END IF;
END $post$;
COMMIT;

;
-- =====================================================================================================================
-- PROPUESTA V4.23b · NO APLICADA (corregida: NO reemplaza finalize_route) · G2 (TERMINÉ EN la ubicación) + regreso obligatorio a DEPÓSITO DIAMANTE + padrón de EMAILS DE CLIENTES
-- DEPENDE de la V4.21 (set_stop_outcome 5d26e5af27a068596cc6875bd6ee8bbf): aplicar DESPUÉS de la V4.21. Verificar antes con VERIFICAR_PRODUCCION_SOLO_LECTURA.sql.
-- NO cambia ninguna función existente: finalize_route queda EXACTA (producción tiene 5bdf85ad…, que no está en el repositorio).
--   LLEGUÉ A DIAMANTE se exige con un trigger en routes (hojas internas iniciadas desde que se aplica; cierre por el propio chofer).
-- Agrega: columnas de fin de visita y de llegada al depósito, finish_internal_location, arrive_depot, configuración del depósito (sin clave
--   inventada: elegido por un administrador o la ÚNICA ubicación activa "DIAMANTE"), y el padrón de emails por CUIT validado con RLS.
-- No borra ni modifica datos existentes. Todo en UNA transacción, con verificación previa y final de huellas.
-- =====================================================================================================================
BEGIN;
DO $guard$ BEGIN
  IF (SELECT md5(prosrc) FROM pg_proc WHERE proname = 'set_stop_outcome' AND pronamespace = 'public'::regnamespace) IS DISTINCT FROM '5d26e5af27a068596cc6875bd6ee8bbf' THEN
    RAISE EXCEPTION 'HUELLA_INESPERADA: set_stop_outcome no es la V4.21: aplicá primero la V4.21. No se modificó nada.'; END IF;
  IF to_regprocedure('public._loc(jsonb, public.route_stops)') IS NULL OR to_regprocedure('public._my_route(uuid)') IS NULL THEN RAISE EXCEPTION 'DEPENDENCIA_FALTANTE: _loc / _my_route. No se modificó nada.'; END IF;
  IF to_regprocedure('public.arrive_depot(uuid, jsonb, text)') IS NOT NULL OR to_regclass('public.client_emails') IS NOT NULL THEN RAISE EXCEPTION 'YA_APLICADA: la V4.23 ya existe. No se modificó nada.'; END IF;
  -- finalize_route NO se modifica: se registra su huella (la que tenga producción) para comprobar al final que quedó idéntica
  PERFORM set_config('okd.v423_finalize_antes', coalesce((SELECT string_agg(md5(prosrc), ',' ORDER BY oid) FROM pg_proc WHERE proname = 'finalize_route' AND pronamespace = 'public'::regnamespace), ''), true);
END $guard$;

-- ---------- 1) Montecaseros / San Juan: fin de la visita a una ubicación interna (no cierra la hoja ni cambia resultados) ----------
alter table public.route_stops add column if not exists location_finished_at timestamptz;
alter table public.route_stops add column if not exists location_finished_location jsonb;
alter table public.route_stops add column if not exists location_finished_by uuid;
create or replace function public.finish_internal_location(p_stop uuid, p_location jsonb, p_op_id text) returns public.route_stops
language plpgsql security definer set search_path = public as $$
declare st public.route_stops; r public.routes; loc jsonb;
begin
  select * into st from public.route_stops where id = p_stop; if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  r := public._my_route(st.route_id);
  if r.operational_status <> 'EN_CURSO' then raise exception 'BAD_STATE' using errcode = '23514'; end if;
  if coalesce(st.stop_type, 'PEDIDO') <> 'UBICACION_INTERNA' then raise exception 'NOT_INTERNAL_LOCATION: solo para ubicaciones internas' using errcode = '23514'; end if;
  if st.location_finished_at is not null then return st; end if;   -- idempotente (reintento sin conexión, doble toque)
  if st.arrived_at is null then raise exception 'ARRIVE_FIRST: registrá primero la llegada a la ubicación' using errcode = '23514'; end if;
  if st.outcome = 'PENDIENTE' then raise exception 'RESOLVE_FIRST: resolvé la recepción antes de terminar en la ubicación' using errcode = '23514'; end if;
  loc := public._loc(p_location, st);
  update public.route_stops set location_finished_at = now(), location_finished_location = loc, location_finished_by = auth.uid() where id = p_stop returning * into st;
  return st;
end; $$;

-- ---------- 2) DEPÓSITO DIAMANTE: llegada obligatoria antes de finalizar la hoja del Transportista Interno ----------
alter table public.routes add column if not exists depot_arrived_at timestamptz;
alter table public.routes add column if not exists depot_location jsonb;
alter table public.routes add column if not exists depot_location_key text;
-- Qué ubicación EXISTENTE es el depósito de regreso (sin clave inventada) y desde cuándo rige la regla (las hojas ya iniciadas no se bloquean)
create table if not exists public.return_depot_settings (
  id text primary key default 'DEFAULT' check (id = 'DEFAULT'),
  location_key text references public.internal_locations(location_key),
  required_since timestamptz not null default now(),
  updated_at timestamptz not null default now(), updated_by uuid);
insert into public.return_depot_settings(id) values ('DEFAULT') on conflict (id) do nothing;
alter table public.return_depot_settings enable row level security;
-- Elegida por un administrador; si no, la ÚNICA ubicación activa cuyo nombre o clave contiene DIAMANTE. Varias o ninguna → null (no se adivina).
create or replace function public._return_depot() returns public.internal_locations language plpgsql stable security definer set search_path = public as $$
declare d public.internal_locations; k text; n int;
begin
  select location_key into k from public.return_depot_settings where id = 'DEFAULT';
  if k is not null then select * into d from public.internal_locations where location_key = k and active; return d; end if;
  select count(*) into n from public.internal_locations where active and (name ilike '%diamante%' or location_key ilike '%diamante%');
  if n = 1 then select * into d from public.internal_locations where active and (name ilike '%diamante%' or location_key ilike '%diamante%'); end if;
  return d;
end; $$;
create or replace function public.return_depot_status() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d public.internal_locations; s public.return_depot_settings;
begin
  if not public.auth_has_perm('settings.manage') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into s from public.return_depot_settings where id = 'DEFAULT'; d := public._return_depot();
  return jsonb_build_object('selected_key', s.location_key, 'required_since', s.required_since,
    'resolved', case when d.location_key is null then null else jsonb_build_object('location_key', d.location_key, 'name', d.name, 'lat', d.lat, 'lon', d.lon, 'radius_m', d.radius_m) end,
    'candidates', coalesce((select jsonb_agg(jsonb_build_object('location_key', l.location_key, 'name', l.name, 'radius_m', l.radius_m, 'active', l.active) order by l.name)
                            from public.internal_locations l where l.name ilike '%diamante%' or l.location_key ilike '%diamante%'), '[]'::jsonb));
end; $$;
create or replace function public.set_return_depot(p_location_key text) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.auth_has_perm('settings.manage') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_location_key is not null and not exists (select 1 from public.internal_locations where location_key = p_location_key and active) then
    raise exception 'LOCATION_NOT_FOUND: la ubicación no existe o está inactiva' using errcode = '23514'; end if;
  update public.return_depot_settings set location_key = p_location_key, updated_at = now(), updated_by = auth.uid() where id = 'DEFAULT';
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'RETURN_DEPOT_SET', 'settings', 'return_depot', jsonb_build_object('location_key', p_location_key));
  return public.return_depot_status();
end; $$;
create or replace function public.arrive_depot(p_route uuid, p_location jsonb, p_op_id text) returns public.routes
language plpgsql security definer set search_path = public as $$
declare r public.routes; d public.internal_locations; ref public.route_stops; loc jsonb; pend int;
begin
  r := public._my_route(p_route);
  if r.operational_status <> 'EN_CURSO' then raise exception 'BAD_STATE' using errcode = '23514'; end if;
  if not exists (select 1 from public.carriers c where c.id = r.carrier_id and c.kind = 'INTERNO') then raise exception 'NOT_INTERNAL: solo el Transportista Interno registra el regreso al depósito' using errcode = '23514'; end if;
  if r.depot_arrived_at is not null then return r; end if;   -- idempotente (reintento sin conexión, doble toque)
  select count(*) into pend from public.route_stops where route_id = p_route and outcome = 'PENDIENTE';
  if pend > 0 then raise exception 'PENDING_STOPS: faltan % paradas por resolver antes de volver al depósito', pend using errcode = '23514'; end if;
  d := public._return_depot();
  if d.location_key is null then raise exception 'DEPOT_NOT_CONFIGURED: falta elegir la ubicación del depósito de regreso en Configuración' using errcode = '23514'; end if;
  ref.expected_lat := d.lat; ref.expected_lon := d.lon; ref.expected_radius_m := d.radius_m;   -- mismo control de radio y advertencias que las paradas
  loc := public._loc(p_location, ref);
  update public.routes set depot_arrived_at = now(), depot_location = loc, depot_location_key = d.location_key where id = p_route returning * into r;
  return r;
end; $$;

-- ---------- 3) Padrón de EMAILS DE CLIENTES por CUIT validado (no hay código de cliente en los Excel de origen) ----------
create or replace function public._cuit_valid(p text) returns boolean language plpgsql immutable as $$
declare d int[]; w int[] := array[5,4,3,2,7,6,5,4,3,2]; s int := 0; v int; i int;
begin
  if p is null or p !~ '^\d{11}$' then return false; end if;
  for i in 1..11 loop d[i] := substr(p, i, 1)::int; end loop;
  for i in 1..10 loop s := s + d[i] * w[i]; end loop;
  v := 11 - (s % 11); if v = 11 then v := 0; elsif v = 10 then return false; end if;
  return d[11] = v;
end; $$;
create table if not exists public.client_emails (
  cuit text primary key check (public._cuit_valid(cuit)),
  client_name text, email text not null check (public.is_valid_email(email)),
  source text not null default 'MANUAL' check (source in ('MANUAL','EXCEL')),
  updated_at timestamptz not null default now(), updated_by uuid);
create table if not exists public.client_email_imports (
  id bigint generated always as identity primary key, imported_at timestamptz not null default now(), imported_by uuid,
  file_name text, mode text not null check (mode in ('CONSERVAR','REEMPLAZAR')), summary jsonb not null);
alter table public.client_emails enable row level security; alter table public.client_email_imports enable row level security;
create or replace function public._is_general_admin() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'ADMIN' and status = 'ACTIVO'); $$;
drop policy if exists client_emails_admin_read on public.client_emails;
create policy client_emails_admin_read on public.client_emails for select to authenticated using (public._is_general_admin());
drop policy if exists client_email_imports_admin_read on public.client_email_imports;
create policy client_email_imports_admin_read on public.client_email_imports for select to authenticated using (public._is_general_admin());
-- Analiza filas del Excel SIN escribir: CUIT válido, email válido, duplicados, desconocidos (CUIT que nunca figuró en una hoja), nuevos y a actualizar
create or replace function public.client_emails_preview(p_rows jsonb) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare out jsonb := '[]'::jsonb; x jsonb; c text; e text; st text; seen text[] := '{}'; dup text[] := '{}'; cur text;
begin
  if not public._is_general_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  for x in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    c := regexp_replace(coalesce(x->>'cuit', ''), '\D', '', 'g'); if c = any(seen) then dup := dup || c; end if; seen := seen || c; end loop;
  for x in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    c := regexp_replace(coalesce(x->>'cuit', ''), '\D', '', 'g'); e := nullif(lower(trim(coalesce(x->>'email', ''))), '');
    select email into cur from public.client_emails where cuit = c;
    st := case when not public._cuit_valid(c) then 'CUIT_INVALIDO' when c = any(dup) then 'DUPLICADO' when e is null then 'SIN_EMAIL'
               when not public.is_valid_email(e) then 'EMAIL_INVALIDO'
               when not exists (select 1 from public.route_stops s where s.client_key = c) and cur is null then 'DESCONOCIDO'
               when cur is null then 'NUEVO' when cur = e then 'SIN_CAMBIOS' else 'ACTUALIZAR' end;
    out := out || jsonb_build_array(jsonb_build_object('cuit', c, 'name', x->>'name', 'email', e, 'actual', cur, 'estado', st));
  end loop;
  return jsonb_build_object('filas', out, 'resumen', (select jsonb_object_agg(k, n) from (select f->>'estado' k, count(*) n from jsonb_array_elements(out) f group by 1) z));
end; $$;
-- Aplica: NUEVO siempre; ACTUALIZAR solo con REEMPLAZAR; nunca borra (celdas vacías no eliminan); no crea clientes; registra la importación
create or replace function public.client_emails_apply(p_rows jsonb, p_mode text, p_file text) returns jsonb language plpgsql security definer set search_path = public as $$
declare pv jsonb; f jsonb; ins int := 0; upd int := 0;
begin
  if not public._is_general_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_mode not in ('CONSERVAR','REEMPLAZAR') then raise exception 'MODO_INVALIDO' using errcode = '22023'; end if;
  pv := public.client_emails_preview(p_rows);
  for f in select * from jsonb_array_elements(pv->'filas') loop
    if f->>'estado' = 'NUEVO' then
      insert into public.client_emails(cuit, client_name, email, source, updated_by) values (f->>'cuit', nullif(f->>'name', ''), f->>'email', 'EXCEL', auth.uid()); ins := ins + 1;
    elsif f->>'estado' = 'ACTUALIZAR' and p_mode = 'REEMPLAZAR' then
      update public.client_emails set email = f->>'email', client_name = coalesce(nullif(f->>'name', ''), client_name), source = 'EXCEL', updated_at = now(), updated_by = auth.uid() where cuit = f->>'cuit'; upd := upd + 1;
    end if;
  end loop;
  insert into public.client_email_imports(imported_by, file_name, mode, summary) values (auth.uid(), p_file, p_mode, (pv->'resumen') || jsonb_build_object('insertados', ins, 'actualizados', upd));
  return (pv->'resumen') || jsonb_build_object('insertados', ins, 'actualizados', upd);
end; $$;
create or replace function public.client_email_upsert(p_cuit text, p_name text, p_email text) returns public.client_emails language plpgsql security definer set search_path = public as $$
declare c text := regexp_replace(coalesce(p_cuit, ''), '\D', '', 'g'); e text := nullif(lower(trim(coalesce(p_email, ''))), ''); r public.client_emails;
begin
  if not public._is_general_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if not public._cuit_valid(c) then raise exception 'CUIT_INVALIDO: el CUIT no es válido' using errcode = '23514'; end if;
  if e is null or not public.is_valid_email(e) then raise exception 'EMAIL_INVALID: el email no es válido' using errcode = '23514'; end if;
  insert into public.client_emails(cuit, client_name, email, source, updated_by) values (c, nullif(trim(p_name), ''), e, 'MANUAL', auth.uid())
  on conflict (cuit) do update set email = excluded.email, client_name = coalesce(excluded.client_name, public.client_emails.client_name), source = 'MANUAL', updated_at = now(), updated_by = auth.uid()
  returning * into r;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'CLIENT_EMAIL_SET', 'client_email', c, to_jsonb(r));
  return r;
end; $$;
-- Para el TRANSPORTISTA: SOLO el email sugerido de SU parada (nunca el padrón). Prioridad: el de la hoja; si no, el del padrón por CUIT.
create or replace function public.delivery_email_suggestion(p_stop uuid) returns text language plpgsql stable security definer set search_path = public as $$
declare st public.route_stops; r public.routes;
begin
  select * into st from public.route_stops where id = p_stop; if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  r := public._my_route(st.route_id);
  if coalesce(st.stop_type, 'PEDIDO') <> 'PEDIDO' then return null; end if;
  return coalesce(nullif(trim(st.customer_email), ''), (select email from public.client_emails where cuit = st.client_key));
end; $$;

-- ---------- 4) Privilegios: solo lo necesario (revocando lo heredado sobre los objetos NUEVOS) ----------
do $$ declare t text; f text; begin
  foreach t in array array['return_depot_settings','client_emails','client_email_imports'] loop execute format('revoke all on table public.%I from public, anon, authenticated', t); end loop;
  grant select on table public.client_emails, public.client_email_imports to authenticated;   -- filtrado por RLS: solo el Administrador General
  execute 'revoke all on sequence public.client_email_imports_id_seq from public, anon, authenticated';
  foreach f in array array['finish_internal_location(uuid,jsonb,text)','arrive_depot(uuid,jsonb,text)','return_depot_status()','set_return_depot(text)',
    'client_emails_preview(jsonb)','client_emails_apply(jsonb,text,text)','client_email_upsert(text,text,text)','delivery_email_suggestion(uuid)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon'; execute 'grant execute on function public.' || f || ' to authenticated'; end loop;
  foreach f in array array['_return_depot()','_cuit_valid(text)'] loop execute 'revoke all on function public.' || f || ' from public, anon, authenticated'; end loop;
  -- la política RLS del padrón la evalúa CON el usuario que consulta: debe poder ejecutarla (solo responde si ÉL es Administrador General)
  execute 'revoke all on function public._is_general_admin() from public, anon'; execute 'grant execute on function public._is_general_admin() to authenticated';
end $$;

-- ---------- 5) LLEGUÉ A DIAMANTE obligatorio SIN reemplazar finalize_route (V4.23b) ----------
-- En producción finalize_route tiene una versión que NO está en el repositorio (huella 5bdf85ad…). Para no perder reglas desconocidas,
-- NO se reemplaza: la exigencia se aplica con un trigger BEFORE UPDATE en routes, que solo actúa cuando ESA hoja pasa a COMPLETADA y:
--   · es del Transportista INTERNO · no tiene depot_arrived_at · se INICIÓ desde que rige la regla (las hojas en curso no se bloquean)
--   · la cierra el PROPIO responsable (el chofer, como en finalize_route). Cierres administrativos o de sistema: sin cambios.
create or replace function public.trg_route_depot_required() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.operational_status = 'COMPLETADA' and coalesce(old.operational_status, '') <> 'COMPLETADA'
     and new.depot_arrived_at is null and auth.uid() is not null and new.responsable_id = auth.uid()
     and exists (select 1 from public.carriers c where c.id = new.carrier_id and c.kind = 'INTERNO')
     and new.started_at >= coalesce((select required_since from public.return_depot_settings where id = 'DEFAULT'), 'infinity'::timestamptz) then
    raise exception 'DEPOT_ARRIVAL_REQUIRED: registrá LLEGUÉ A DIAMANTE antes de finalizar la hoja' using errcode = '23514';
  end if;
  return new;
end; $$;
revoke all on function public.trg_route_depot_required() from public, anon, authenticated;
drop trigger if exists routes_zz_depot_required on public.routes;
create trigger routes_zz_depot_required before update of operational_status on public.routes for each row execute function public.trg_route_depot_required();

DO $post$ BEGIN
  IF (SELECT string_agg(md5(prosrc), ',' ORDER BY oid) FROM pg_proc WHERE proname = 'finalize_route' AND pronamespace = 'public'::regnamespace) IS DISTINCT FROM current_setting('okd.v423_finalize_antes') THEN
    RAISE EXCEPTION 'HUELLA_FINAL_INESPERADA: finalize_route cambió durante la migración (no debe tocarse). Se deshace todo.'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'routes_zz_depot_required' AND tgrelid = 'public.routes'::regclass) THEN RAISE EXCEPTION 'HUELLA_FINAL_INESPERADA: falta el trigger. Se deshace todo.'; END IF;
END $post$;
COMMIT;

;
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

;
-- =====================================================================================================================
-- PROPUESTA · NO APLICADA · Correo diario de PDF de hojas enviado por la cuenta GMAIL conectada en Comunicaciones.
--  · Configuración → F elige el canal: 'RESEND' (actual) o 'GMAIL'. Columna PROPIA (la columna 'provider' la edita la sección E).
--  · Con GMAIL: el despachador de Comunicaciones (cada 5 min) encola, desde el horario configurado (Mendoza), UNA ejecución por versión
--    de PDF de hoja del día, con los destinatarios configurados, y la envía por la cola de Comunicaciones (reserva atómica, verificación
--    previa, cupo compartido, "Por verificar", historial por destinatario). Mismo correo que hoy: una hoja (vN) por correo y destinatario.
--  · Exclusión mutua para no duplicar el día del cambio: Resend no encola con GMAIL y excluye lo enviado por Gmail; Gmail excluye lo
--    ya enviado por Resend; la verificación previa cancela lo pendiente de Gmail si se desactiva o se vuelve a Resend.
--  · El comunicado del sistema "Correo diario de hojas (automático)" solo se pausa o reanuda (protegido en el servidor).
-- Requiere: 20261112000100_comunicaciones.sql aplicada y su programador (01_programador_comunicaciones.sql) funcionando.
-- =====================================================================================================================

-- ---------- 1) Canal del correo de hojas ----------
alter table public.notification_settings add column if not exists sheet_email_via text not null default 'RESEND';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'notification_settings_sheet_email_via_chk') then
    alter table public.notification_settings add constraint notification_settings_sheet_email_via_chk check (sheet_email_via in ('RESEND','GMAIL'));
  end if; end $$;

create or replace function public.set_notification_settings(p jsonb) returns public.notification_settings language plpgsql security definer set search_path = public as $$
declare s public.notification_settings;
begin
  if not public.auth_has_perm('settings.manage') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p ? 'sheet_email_via' and coalesce(p->>'sheet_email_via', '') not in ('RESEND','GMAIL') then raise exception 'CANAL_INVALIDO: RESEND o GMAIL' using errcode = '22023'; end if;
  update public.notification_settings set on_the_way_enabled = coalesce((p->>'on_the_way_enabled')::boolean, on_the_way_enabled), delivered_enabled = coalesce((p->>'delivered_enabled')::boolean, delivered_enabled),
    sheet_email_enabled = coalesce((p->>'sheet_email_enabled')::boolean, sheet_email_enabled), sheet_email_time = coalesce(p->>'sheet_email_time', sheet_email_time),
    sheet_email_recipients = coalesce((select array_agg(lower(x)) from jsonb_array_elements_text(p->'sheet_email_recipients') x), sheet_email_recipients),
    sheet_email_via = coalesce(p->>'sheet_email_via', sheet_email_via),
    provider = coalesce(p->>'provider', provider), max_retries = coalesce((p->>'max_retries')::int, max_retries)
  where id = 'DEFAULT' returning * into s;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'NOTIFICATION_SETTINGS_CHANGED', 'settings', 'DEFAULT', to_jsonb(s));
  return s;
end; $$;
grant execute on function public.set_notification_settings(jsonb) to authenticated;

-- ---------- 2) Resend: no encola con GMAIL y excluye lo ya enviado (o en curso) por Gmail ----------
create or replace function public.queue_sheet_emails(p_day date) returns int language plpgsql security definer set search_path = public as $$
declare s public.notification_settings; n int;
begin
  select * into s from public.notification_settings where id = 'DEFAULT';
  if not s.sheet_email_enabled then return 0; end if;
  if s.sheet_email_via <> 'RESEND' then return 0; end if;   -- el canal elegido es Gmail (Comunicaciones)
  -- el envío del día sale a partir del horario configurado (hora de Mendoza)
  if p_day = (now() at time zone 'America/Argentina/Mendoza')::date and to_char(now() at time zone 'America/Argentina/Mendoza', 'HH24:MI') < s.sheet_email_time then return 0; end if;
  insert into public.sheet_email_jobs(route_id, route_version, recipient, idempotency_key)
  select p.route_id, p.route_version, e, p.route_id || '|' || p.route_version || '|' || e
  from public.route_pdfs p cross join unnest(s.sheet_email_recipients) e
  where p.status = 'OK' and (p.generated_at at time zone 'America/Argentina/Mendoza')::date = p_day
    and not exists (select 1 from public.comm_runs r join public.comm_deliveries d on d.run_id = r.id
                     where r.source_key = 'HOJA|' || p.route_id || '|' || p.route_version and lower(d.email) = lower(e)
                       and d.status in ('ENVIADO','PROCESANDO','POR_VERIFICAR'))   -- enviado o POSIBLEMENTE enviado por Gmail
    -- (lo PENDIENTE de Gmail no salió: Resend puede enviarlo y la verificación previa de Gmail lo cancela al ver el cambio de canal)
  on conflict (idempotency_key) do nothing;
  get diagnostics n = row_count; return n;
end; $$;

-- ---------- 3) Comunicaciones: comunicado del sistema, tipo de ejecución 'HOJAS' y clave de origen ----------
alter table public.comm_messages add column if not exists system_kind text unique;
alter table public.comm_runs add column if not exists source_key text unique;
-- unicidad por comunicado + horario + tipo: solo para ejecuciones NO 'HOJAS' (las de hojas son únicas por source_key; varias hojas del
-- día comparten el horario configurado). comm_create_run se redefine IDÉNTICA salvo el ON CONFLICT, que apunta al índice parcial.
alter table public.comm_runs drop constraint if exists comm_runs_message_id_scheduled_for_kind_key;
create unique index if not exists comm_runs_unico_programado on public.comm_runs (message_id, scheduled_for, kind) where kind <> 'HOJAS';
create or replace function public.comm_create_run(p_message uuid, p_scheduled_for timestamptz, p_kind text, p_missed boolean, p_recipients jsonb, p_skipped jsonb, p_snapshot jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare rid uuid; begin
  insert into public.comm_runs(message_id, scheduled_for, kind, status, snapshot, recipients_count, note)
    values (p_message, p_scheduled_for, p_kind, case when p_missed then 'PERDIDA' else 'PENDIENTE' end, p_snapshot, jsonb_array_length(coalesce(p_recipients, '[]')),
            case when p_missed then 'Ejecución perdida (el servidor no la procesó a tiempo): NO se envió; queda para revisión.' end)
    on conflict (message_id, scheduled_for, kind) where kind <> 'HOJAS' do nothing returning id into rid;
  if rid is null then return null; end if;   -- ya existía (otro trabajador la creó): no se duplica
  insert into public.comm_deliveries(run_id, collaborator_id, email, name)
    select rid, nullif(x->>'collaborator_id', '')::uuid, lower(x->>'email'), x->>'name' from jsonb_array_elements(coalesce(p_recipients, '[]')) x on conflict do nothing;
  insert into public.comm_deliveries(run_id, collaborator_id, name, status, reason)
    select rid, nullif(x->>'id', '')::uuid, x->>'name', 'OMITIDO', x->>'reason' from jsonb_array_elements(coalesce(p_skipped, '[]')) x on conflict do nothing;
  return rid; end; $$;;
alter table public.comm_runs drop constraint if exists comm_runs_kind_check;
alter table public.comm_runs add constraint comm_runs_kind_check check (kind in ('PROGRAMADO','PRUEBA','HOJAS'));

-- el comunicado del sistema solo se pausa o reanuda; el contenido y los destinatarios salen de Configuración → F
create or replace function public._comm_protect_system_message() returns trigger language plpgsql as $$
begin
  if old.system_kind is not null and current_setting('okd.comm_system', true) is distinct from 'on' then
    if new.subject is distinct from old.subject or new.body_html is distinct from old.body_html or new.selection is distinct from old.selection
       or new.schedule is distinct from old.schedule or new.internal_name is distinct from old.internal_name or new.system_kind is distinct from old.system_kind
       or new.status not in ('ACTIVO','PAUSADO') then
      raise exception 'MENSAJE_DEL_SISTEMA: el correo diario de hojas solo se pausa o reanuda; se configura en Configuración → F' using errcode = '22023';
    end if;
  end if;
  return new;
end; $$;
drop trigger if exists comm_messages_protect_system on public.comm_messages;
create trigger comm_messages_protect_system before update on public.comm_messages for each row execute function public._comm_protect_system_message();
create or replace function public._comm_no_attachments_on_system() returns trigger language plpgsql as $$
begin
  if exists (select 1 from public.comm_messages m where m.id = new.message_id and m.system_kind is not null) then
    raise exception 'MENSAJE_DEL_SISTEMA: el correo diario de hojas adjunta los PDF de las hojas automáticamente' using errcode = '22023';
  end if;
  return new;
end; $$;
drop trigger if exists comm_attachments_no_system on public.comm_attachments;
create trigger comm_attachments_no_system before insert on public.comm_attachments for each row execute function public._comm_no_attachments_on_system();

-- ---------- 4) Encolado del correo de hojas por Gmail (SOLO servidor; lo llama el despachador de Comunicaciones) ----------
-- Elegibles: hojas PUBLICADAS (publish_route) o tercerizados DESPACHADOS (dispatch_external_route); nunca borradores ni canceladas, y sin
-- depender de que el chofer termine. Día de la hoja = el de su publicación o despacho (hora de Mendoza), NO el del PDF. Se adjunta SOLO el PDF de
-- la VERSIÓN VIGENTE (routes.version); si todavía no está, se espera (nunca se cae a una versión anterior). PDF TARDÍO: una hoja del día cuyo PDF
-- aparece después del horario sale en la vuelta siguiente; una hoja de AYER cuyo PDF recién se generó HOY también se envía (solo ese caso).
create or replace function public._comm_sheet_eligible(r public.routes) returns boolean language sql immutable as $$
  select r.operational_status in ('PUBLICADA','EN_CURSO','COMPLETADA')
     and ((coalesce(r.dispatch_mode, 'APP') <> 'EXTERNAL' and r.published_at is not null) or (r.dispatch_mode = 'EXTERNAL' and r.dispatched_at is not null)); $$;
create or replace function public.comm_enqueue_sheet_pdfs(p_now timestamptz default now()) returns int language plpgsql security definer set search_path = public as $$
declare s public.notification_settings; m public.comm_messages; v_day date := (p_now at time zone 'America/Argentina/Mendoza')::date;
        n int := 0; p record; rid uuid; nrec int; v_base timestamptz;
begin
  select * into s from public.notification_settings where id = 'DEFAULT';
  if s.id is null or not s.sheet_email_enabled or s.sheet_email_via <> 'GMAIL' or coalesce(cardinality(s.sheet_email_recipients), 0) = 0 then return 0; end if;
  perform pg_advisory_xact_lock(hashtext('okd_comm_sheet_enqueue'));
  for p in
    select r.id route_id, r.number route_number, r.version route_version, rp.file_name, rp.storage_path, rp.generated_at, x.sheet_day
      from public.routes r
      cross join lateral (select ((case when r.dispatch_mode = 'EXTERNAL' then r.dispatched_at else r.published_at end) at time zone 'America/Argentina/Mendoza')::date sheet_day) x
      join public.route_pdfs rp on rp.route_id = r.id and rp.route_version = r.version and rp.status = 'OK' and rp.storage_path is not null   -- versión VIGENTE
     where public._comm_sheet_eligible(r)
       and (   (x.sheet_day = v_day and p_now >= ((v_day::text || ' ' || s.sheet_email_time)::timestamp at time zone 'America/Argentina/Mendoza'))
            or (x.sheet_day = v_day - 1 and (rp.generated_at at time zone 'America/Argentina/Mendoza')::date = v_day) )   -- PDF tardío de ayer
       and not exists (select 1 from public.comm_runs cr where cr.source_key = 'HOJA|' || r.id || '|' || r.version)
     order by x.sheet_day, r.number
  loop
    if m.id is null then
      select * into m from public.comm_messages where system_kind = 'HOJAS_DIA';
      if not found then
        insert into public.comm_messages(internal_name, subject, body_html, status, system_kind, active_since, cursor, from_name)
          values ('Correo diario de hojas (automático)', 'OK Despacho · Hojas del día', '<p>Envío automático de los PDF de las hojas del día.</p>', 'ACTIVO', 'HOJAS_DIA', p_now, p_now, 'OK Accesorios')
          returning * into m;
        insert into public.comm_audit(message_id, entity, action, detail) values (m.id, 'COMUNICADO', 'CREADO_POR_SISTEMA', jsonb_build_object('motivo', 'correo diario de hojas por Gmail'));
      end if;
    end if;
    v_base := ((p.sheet_day::text || ' ' || s.sheet_email_time)::timestamp) at time zone 'America/Argentina/Mendoza';
    insert into public.comm_runs(message_id, scheduled_for, kind, status, snapshot, recipients_count, source_key)
      values (m.id, greatest(v_base, p.generated_at), 'HOJAS', 'PENDIENTE',
        jsonb_build_object('subject', 'OK Despacho · Hoja ' || p.route_number || ' (v' || p.route_version || ')',
          'body_html', '<p>Adjuntamos la hoja <b>' || replace(replace(replace(p.route_number, '&', '&amp;'), '<', '&lt;'), '>', '&gt;') || '</b> versión ' || p.route_version || '.</p>',
          'from_name', 'OK Accesorios', 'message_version', 1, 'route_id', p.route_id, 'route_version', p.route_version, 'sheet_day', p.sheet_day,
          'attachments', jsonb_build_array(jsonb_build_object('name', p.file_name, 'mime', 'application/pdf', 'size_bytes', null, 'sha256', null,
                                                               'storage_path', p.storage_path, 'bucket', 'route-pdfs'))),
        0, 'HOJA|' || p.route_id || '|' || p.route_version)
      on conflict (source_key) do nothing returning id into rid;
    if rid is null then continue; end if;
    insert into public.comm_deliveries(run_id, email, name)
      select rid, lower(e), 'Destinatario del correo de hojas' from unnest(s.sheet_email_recipients) e
       where not exists (select 1 from public.sheet_email_jobs j where j.route_id = p.route_id and j.route_version = p.route_version
                           and lower(j.recipient) = lower(e) and j.status = 'SENT')   -- ya enviado por Resend: no se repite
      on conflict do nothing;
    get diagnostics nrec = row_count;
    update public.comm_runs set recipients_count = nrec,
      status = case when nrec = 0 then 'COMPLETADA' else status end,
      note = case when nrec = 0 then 'Esta versión ya se había enviado por Resend a todos los destinatarios.' end
     where id = rid;
    n := n + 1;
  end loop;
  return n;
end; $$;

-- ---------- 5) Verificación previa: con el correo de hojas desactivado o vuelto a Resend, lo pendiente de Gmail se cancela ----------
create or replace function public.comm_check(p_id bigint, p_token uuid) returns text language plpgsql security definer set search_path = public as $$
declare d public.comm_deliveries; r public.comm_runs; m public.comm_messages; c public.comm_collaborators; g public.comm_gmail_status; s public.notification_settings; rt public.routes;
begin
  select * into d from public.comm_deliveries where id = p_id for update;
  if not found or d.status <> 'PROCESANDO' or d.claim_token is distinct from p_token then return 'LOST'; end if;
  select * into r from public.comm_runs where id = d.run_id; select * into m from public.comm_messages where id = r.message_id;
  if r.kind = 'HOJAS' then
    select * into s from public.notification_settings where id = 'DEFAULT';
    if not s.sheet_email_enabled or s.sheet_email_via <> 'GMAIL' then
      update public.comm_deliveries set status = 'CANCELADO', claim_token = null, reason = 'Correo de hojas desactivado o cambiado a Resend antes del envío', updated_at = now() where id = p_id; return 'CANCELLED'; end if;
    -- ESTADO y VERSIÓN de la hoja, inmediatamente antes de cada envío (también en reintentos)
    select * into rt from public.routes where id = (r.snapshot->>'route_id')::uuid;
    if not found or not public._comm_sheet_eligible(rt) then
      update public.comm_deliveries set status = 'CANCELADO', claim_token = null, reason = 'La hoja fue cancelada o dejó de estar publicada antes del envío', updated_at = now() where id = p_id; return 'CANCELLED'; end if;
    if rt.version <> (r.snapshot->>'route_version')::int then
      update public.comm_deliveries set status = 'CANCELADO', claim_token = null, reason = 'Hay una versión más nueva de la hoja (v' || rt.version || '): se envía esa', updated_at = now() where id = p_id; return 'CANCELLED'; end if;
  end if;
  if r.kind <> 'PRUEBA' then
    if r.status = 'CANCELADA' or m.status = 'CANCELADO' then update public.comm_deliveries set status = 'CANCELADO', claim_token = null, reason = 'Comunicado cancelado antes del envío', updated_at = now() where id = p_id; return 'CANCELLED'; end if;
    if m.status = 'PAUSADO' then update public.comm_deliveries set status = 'PENDIENTE', claim_token = null, attempts = attempts - 1, updated_at = now() where id = p_id; return 'PAUSED'; end if;
    if d.collaborator_id is not null then select * into c from public.comm_collaborators where id = d.collaborator_id;
      if found and not c.active then update public.comm_deliveries set status = 'OMITIDO', claim_token = null, reason = 'Colaborador desactivado antes del envío', updated_at = now() where id = p_id; return 'INACTIVE_RECIPIENT'; end if; end if;
  end if;
  select * into g from public.comm_gmail_status where id = 1;
  if not g.connected or g.needs_reconnect then update public.comm_deliveries set status = 'PENDIENTE', claim_token = null, attempts = attempts - 1, updated_at = now() where id = p_id; return 'NO_CONNECTION'; end if;
  return 'OK'; end; $$;

-- ---------- 6) Privilegios (objetos nuevos o redefinidos) ----------
revoke all on function public.comm_enqueue_sheet_pdfs(timestamptz) from public, anon, authenticated;
grant execute on function public.comm_enqueue_sheet_pdfs(timestamptz) to service_role;
revoke all on function public.comm_check(bigint, uuid) from public, anon, authenticated;
grant execute on function public.comm_check(bigint, uuid) to service_role;
revoke all on function public._comm_protect_system_message() from public, anon, authenticated;
revoke all on function public._comm_sheet_eligible(public.routes) from public, anon, authenticated;
revoke all on function public._comm_no_attachments_on_system() from public, anon, authenticated;

;
-- En Supabase, service_role ya tiene estos privilegios. Acá se otorgan para la prueba local.
grant usage on schema public to service_role;
grant all on all tables in schema public to service_role;
grant all on all sequences in schema public to service_role;
grant execute on all functions in schema public to service_role;

;
-- SOLO PARA PRUEBAS LOCALES: reproduce los privilegios POR DEFECTO observados en producción (consulta de solo lectura):
-- todo objeto nuevo de postgres en "public" hereda ALL para anon/authenticated (tablas: arwdDxtm; secuencias; funciones).
alter default privileges for role postgres in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges for role postgres in schema public grant all on sequences to anon, authenticated, service_role;
alter default privileges for role postgres in schema public grant all on functions to anon, authenticated, service_role;

;
-- =====================================================================================================================
-- PROPUESTA V4.25 · NO APLICADA · INSPECCIONES DE VEHÍCULOS (formulario R SE 4.5.1-05 Rev:00 · 30 controles exactos del Excel original)
-- Independiente de las migraciones de entregas: solo depende de tablas base (profiles, vehicles, notifications, audit_log).
-- Circuito: BORRADOR → PENDIENTE → APROBADA / RECHAZADA. Todo por funciones SECURITY DEFINER con validación del lado del servidor;
-- RLS por equipo (profiles.supervisor_user_id). Sin fotografías, cámara, adjuntos ni firmas. Aditivo: no modifica datos existentes.
-- Una transacción; si las tablas ya existen, se detiene sin cambiar nada.
-- =====================================================================================================================
BEGIN;
DO $guard$ BEGIN
  IF to_regclass('public.vehicle_inspections') IS NOT NULL THEN RAISE EXCEPTION 'YA_APLICADA: la V4.25 ya existe. No se modificó nada.'; END IF;
  IF to_regclass('public.vehicles') IS NULL OR to_regclass('public.profiles') IS NULL OR to_regclass('public.notifications') IS NULL OR to_regclass('public.audit_log') IS NULL THEN
    RAISE EXCEPTION 'DEPENDENCIA_FALTANTE: vehicles / profiles / notifications / audit_log. No se modificó nada.'; END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'profiles' AND column_name = 'supervisor_user_id') THEN
    RAISE EXCEPTION 'DEPENDENCIA_FALTANTE: profiles.supervisor_user_id. No se modificó nada.'; END IF;
END $guard$;

-- ---------- catálogo: los 30 controles EXACTOS del Excel R SE 4.5.1-05 (texto original, incluida su ortografía) ----------
create table public.vehicle_inspection_controls (
  item_no int primary key check (item_no between 1 and 30), category text not null, label text not null, extra text check (extra in ('VENCE','KM')));
insert into public.vehicle_inspection_controls(item_no, category, label, extra) values
  (1, 'DOCUMENTACIÓN', 'Poliza de Seguro + Último Recibo de Pago', 'VENCE'),
  (2, 'DOCUMENTACIÓN', 'Tarjeta Verde', null),
  (3, 'DOCUMENTACIÓN', 'Listado de Conductores Autorizados', null),
  (4, 'DOCUMENTACIÓN', 'Registro del último mantenimiento (Cam. de Aceite)', 'KM'),
  (5, 'DOCUMENTACIÓN', 'Copia de ultima verificación tecnica (RTO)', 'VENCE'),
  (6, 'ELEMENTOS DE SEGURIDAD', 'Extintor Cargado + Fecha de Vencimiento', 'VENCE'),
  (7, 'ELEMENTOS DE SEGURIDAD', 'Botiquín', null),
  (8, 'ELEMENTOS DE SEGURIDAD', 'Gato hidráulico, llave cruz y rueda de auxilio', null),
  (9, 'ELEMENTOS DE SEGURIDAD', 'Cinturon de Seguridad', null),
  (10, 'ELEMENTOS DE SEGURIDAD', 'Apoya-cabezas', null),
  (11, 'ELEMENTOS DE SEGURIDAD', 'Freno de Mano', null),
  (12, 'ELEMENTOS DE SEGURIDAD', 'Balizas Tipo Triángulo', null),
  (13, 'LUCES Y SEÑALES', 'Luz Alta y baja', null),
  (14, 'LUCES Y SEÑALES', 'Luz de Posición', null),
  (15, 'LUCES Y SEÑALES', 'Luz de Giro', null),
  (16, 'LUCES Y SEÑALES', 'Balizas', null),
  (17, 'LUCES Y SEÑALES', 'Luz de Freno', null),
  (18, 'LUCES Y SEÑALES', 'Luz Interior', null),
  (19, 'LUCES Y SEÑALES', 'Chapa Patente delantera y trasera', null),
  (20, 'LUCES Y SEÑALES', 'Bocina', null),
  (21, 'MECÁNICA Y ESTADO GENERAL', 'Espejos Retovisores', null),
  (22, 'MECÁNICA Y ESTADO GENERAL', 'Cierre de Puertas, capot, compuertas', null),
  (23, 'MECÁNICA Y ESTADO GENERAL', 'Higiene General', null),
  (24, 'MECÁNICA Y ESTADO GENERAL', 'Estado de Cubiertas', null),
  (25, 'MECÁNICA Y ESTADO GENERAL', 'Nivel Aceite Motor', null),
  (26, 'MECÁNICA Y ESTADO GENERAL', 'Nivel de Liquido refrigerante', null),
  (27, 'MECÁNICA Y ESTADO GENERAL', 'Nivel de Liquido Limpia Parabrisas', null),
  (28, 'MECÁNICA Y ESTADO GENERAL', 'Parabrisas en condiciones aceptables', null),
  (29, 'MECÁNICA Y ESTADO GENERAL', 'Calefactor/ Desempañador en buen funcionamiento', null),
  (30, 'MECÁNICA Y ESTADO GENERAL', 'Estado General de Carrocería', null);

create sequence public.vehicle_inspection_number_seq;
create table public.vehicle_inspections (
  id uuid primary key default gen_random_uuid(),
  number text not null, revision int not null default 1, parent_id uuid references public.vehicle_inspections(id),
  client_id uuid not null unique,                                  -- generado en el celular: evita duplicados al sincronizar sin conexión
  form_code text not null default 'R SE 4.5.1-05', form_rev text not null default 'Rev:00',
  vehicle_id uuid not null references public.vehicles(id), vehicle_name text, vehicle_type text, brand text, model text, plate text not null,
  km numeric(10,1),
  created_by uuid not null references public.profiles(id), created_by_name text not null, team_supervisor_id uuid references public.profiles(id),
  status text not null default 'BORRADOR' check (status in ('BORRADOR','PENDIENTE','APROBADA','RECHAZADA')),
  general_observation text, anomalies int not null default 0,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(), submitted_at timestamptz,
  reviewed_by uuid references public.profiles(id), reviewed_by_name text, reviewed_at timestamptz, reject_reason text,
  unique (number, revision));
create table public.vehicle_inspection_items (
  inspection_id uuid not null references public.vehicle_inspections(id), item_no int not null references public.vehicle_inspection_controls(item_no),
  result text check (result in ('BIEN','MAL','NO_APLICA')), defect text check (defect in ('FALTANTE','MAL_ESTADO')),
  observation text, extra_date date, extra_km numeric(10,1),
  primary key (inspection_id, item_no));
create table public.vehicle_inspection_events (
  id bigint generated always as identity primary key, inspection_id uuid not null references public.vehicle_inspections(id),
  action text not null check (action in ('CREADA','ENVIADA','APROBADA','RECHAZADA','REVISION_CREADA','EMAIL_PREPARADO','EMAIL_SOLICITADO')),
  actor uuid, actor_name text, at timestamptz not null default now(), detail jsonb);
create table public.vehicle_inspection_email_requests (
  id bigint generated always as identity primary key, inspection_id uuid not null references public.vehicle_inspections(id),
  requested_by uuid not null, requested_at timestamptz not null default now(), recipients text[] not null, subject text not null, body text not null,
  status text not null default 'PENDIENTE_ENVIO' check (status in ('PENDIENTE_ENVIO','ENVIADO','ERROR')), sent_at timestamptz, error text,
  retry_count int not null default 0);   -- lo envía internal-approvals (send_inspection_emails) con el proveedor existente; nunca al aprobar
alter table public.notifications add column if not exists inspection_id uuid references public.vehicle_inspections(id);   -- enlace directo (aditivo)

-- ---------- quién soy / alcance por equipo ----------
create or replace function public._insp_me() returns public.profiles language plpgsql stable security definer set search_path = public as $$
declare me public.profiles;
begin
  select * into me from public.profiles where id = auth.uid() and status = 'ACTIVO';
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return me;
end; $$;
create or replace function public._insp_can_view(i public.vehicle_inspections) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles me where me.id = auth.uid() and me.status = 'ACTIVO' and (
    me.role = 'ADMIN' or i.created_by = me.id
    or (me.role = 'SUPERVISOR_DESPACHO' and i.team_supervisor_id = me.id))); $$;   -- SOLO el Superior de ESE equipo (sin Superior asignado: solo el autor y el Administrador General)
create or replace function public._insp_event(p_id uuid, p_action text, p_detail jsonb) returns void language plpgsql security definer set search_path = public as $$
declare me public.profiles;
begin
  select * into me from public.profiles where id = auth.uid();
  insert into public.vehicle_inspection_events(inspection_id, action, actor, actor_name, detail) values (p_id, p_action, auth.uid(), me.full_name, p_detail);
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'INSPECTION_' || p_action, 'vehicle_inspection', p_id::text, p_detail);
end; $$;

-- ---------- borrador (crear / guardar): solo Operario Depósito y Superior Despacho; sin duplicados (client_id) ----------
create or replace function public.inspection_save_draft(p jsonb) returns public.vehicle_inspections language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._insp_me(); i public.vehicle_inspections; v public.vehicles; it jsonb; n int;
begin
  if me.role not in ('OPERARIO_DEPOSITO','SUPERVISOR_DESPACHO') then raise exception 'FORBIDDEN: solo Operario Depósito o Superior Despacho realizan inspecciones' using errcode = '42501'; end if;
  if (p->>'client_id') is null then raise exception 'CLIENT_ID_REQUIRED' using errcode = '22023'; end if;
  select * into i from public.vehicle_inspections where client_id = (p->>'client_id')::uuid;
  if i.id is not null and i.created_by <> me.id then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if i.id is not null and i.status <> 'BORRADOR' then return i; end if;   -- ya enviada: un guardado tardío (sin conexión) NO la modifica
  select * into v from public.vehicles where id = (p->>'vehicle_id')::uuid;
  if v.id is null then raise exception 'VEHICLE_NOT_FOUND: elegí un vehículo' using errcode = '23514'; end if;
  if i.id is null then
    insert into public.vehicle_inspections(number, client_id, vehicle_id, vehicle_name, vehicle_type, brand, model, plate, km, created_by, created_by_name, team_supervisor_id, general_observation)
    values ('INS-' || lpad(nextval('public.vehicle_inspection_number_seq')::text, 6, '0'), (p->>'client_id')::uuid, v.id, v.name, v.type, v.brand, v.model, v.plate,
            nullif(p->>'km', '')::numeric, me.id, me.full_name, case when me.role = 'SUPERVISOR_DESPACHO' then me.id else me.supervisor_user_id end, p->>'general_observation')
    returning * into i;
    perform public._insp_event(i.id, 'CREADA', jsonb_build_object('number', i.number, 'plate', i.plate));
  else
    update public.vehicle_inspections set vehicle_id = v.id, vehicle_name = v.name, vehicle_type = v.type, brand = v.brand, model = v.model, plate = v.plate,
      km = nullif(p->>'km', '')::numeric, general_observation = p->>'general_observation', updated_at = now() where id = i.id returning * into i;
  end if;
  for it in select * from jsonb_array_elements(coalesce(p->'items', '[]'::jsonb)) loop
    n := (it->>'n')::int; if n is null or n < 1 or n > 30 then raise exception 'ITEM_INVALID' using errcode = '22023'; end if;
    insert into public.vehicle_inspection_items(inspection_id, item_no, result, defect, observation, extra_date, extra_km)
    values (i.id, n, nullif(it->>'result', ''), nullif(it->>'defect', ''), nullif(trim(coalesce(it->>'observation', '')), ''), nullif(it->>'extra_date', '')::date, nullif(it->>'extra_km', '')::numeric)
    on conflict (inspection_id, item_no) do update set result = excluded.result, defect = excluded.defect, observation = excluded.observation, extra_date = excluded.extra_date, extra_km = excluded.extra_km;
  end loop;
  return i;
end; $$;

-- ---------- enviar a aprobación: los 30 controles; MAL exige FALTANTE/MAL ESTADO y observación ----------
create or replace function public.inspection_submit(p_id uuid) returns public.vehicle_inspections language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._insp_me(); i public.vehicle_inspections; miss int; bad int; team uuid;
begin
  select * into i from public.vehicle_inspections where id = p_id for update;
  if i.id is null or i.created_by <> me.id then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if i.status = 'PENDIENTE' then return i; end if;   -- reintento (doble toque / cola sin conexión): no duplica
  if i.status <> 'BORRADOR' then raise exception 'BAD_STATE: la inspección ya fue revisada' using errcode = '23514'; end if;
  if i.km is null or i.km < 0 then raise exception 'KM_REQUIRED: cargá el kilometraje' using errcode = '23514'; end if;
  select count(*) into miss from public.vehicle_inspection_controls c left join public.vehicle_inspection_items x on x.inspection_id = i.id and x.item_no = c.item_no where x.result is null;
  if miss > 0 then raise exception 'INCOMPLETE: faltan % controles por responder', miss using errcode = '23514'; end if;
  select count(*) into bad from public.vehicle_inspection_items where inspection_id = i.id and result = 'MAL' and (defect is null or observation is null);
  if bad > 0 then raise exception 'ANOMALY_INCOMPLETE: cada control MAL necesita FALTANTE o MAL ESTADO y una observación (% sin completar)', bad using errcode = '23514'; end if;
  -- Superior responsable: el asignado AL ENVIAR (el propio, si quien envía es Superior). Sin Superior activo asignado → no se envía ni se expone.
  team := case when me.role = 'SUPERVISOR_DESPACHO' then me.id else me.supervisor_user_id end;
  if team is null or not exists (select 1 from public.profiles p where p.id = team and p.role = 'SUPERVISOR_DESPACHO' and p.status = 'ACTIVO') then
    raise exception 'SUPERVISOR_REQUIRED: tu usuario no tiene un Superior Despacho asignado. Pedí al Administrador General que te asigne uno; la inspección queda guardada como borrador' using errcode = '23514'; end if;
  update public.vehicle_inspections set status = 'PENDIENTE', submitted_at = now(), updated_at = now(), team_supervisor_id = team,
    anomalies = (select count(*) from public.vehicle_inspection_items where inspection_id = i.id and result = 'MAL') where id = i.id returning * into i;
  perform public._insp_event(i.id, 'ENVIADA', jsonb_build_object('anomalies', i.anomalies, 'supervisor', team));
  if me.role <> 'SUPERVISOR_DESPACHO' then   -- SOLO al Superior de ese equipo (el Superior que inspecciona no se notifica a sí mismo)
    insert into public.notifications(user_id, type, title, body, inspection_id)
    values (team, 'INSPECTION_PENDING', 'Inspección ' || i.number || ' pendiente de aprobación', i.plate || ' · ' || coalesce(i.vehicle_name, '') || ' · ' || i.created_by_name || ' · ' || i.anomalies || ' anomalía(s)', i.id);
  end if;
  return i;
end; $$;

-- ---------- aprobar / rechazar: SOLO Superior Despacho de ese equipo; rechazo con motivo; sin doble decisión ----------
create or replace function public.inspection_review(p_id uuid, p_decision text, p_reason text) returns public.vehicle_inspections language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._insp_me(); i public.vehicle_inspections;
begin
  if me.role <> 'SUPERVISOR_DESPACHO' then raise exception 'FORBIDDEN: solo el Superior Despacho aprueba o rechaza inspecciones' using errcode = '42501'; end if;
  if p_decision not in ('APROBADA','RECHAZADA') then raise exception 'DECISION_INVALIDA' using errcode = '22023'; end if;
  select * into i from public.vehicle_inspections where id = p_id for update;
  if i.id is null or not coalesce(i.created_by = me.id or i.team_supervisor_id = me.id, false) then raise exception 'FORBIDDEN: la inspección es de otro equipo' using errcode = '42501'; end if;   -- sin equipo (NULL) = de otro equipo
  if i.status in ('APROBADA','RECHAZADA') then
    if i.status = p_decision then return i; end if;   -- reintento: misma decisión, no duplica
    raise exception 'ALREADY_REVIEWED: la inspección ya fue %', lower(i.status) using errcode = '23514'; end if;
  if i.status <> 'PENDIENTE' then raise exception 'BAD_STATE: la inspección no está pendiente' using errcode = '23514'; end if;
  if p_decision = 'RECHAZADA' and coalesce(trim(p_reason), '') = '' then raise exception 'REASON_REQUIRED: indicá el motivo del rechazo' using errcode = '23514'; end if;
  update public.vehicle_inspections set status = p_decision, reviewed_by = me.id, reviewed_by_name = me.full_name, reviewed_at = now(),
    reject_reason = case when p_decision = 'RECHAZADA' then trim(p_reason) end, updated_at = now() where id = i.id returning * into i;
  perform public._insp_event(i.id, p_decision, jsonb_build_object('reason', i.reject_reason, 'self', i.created_by = me.id));
  if i.created_by <> me.id then
    insert into public.notifications(user_id, type, title, body, inspection_id)
    values (i.created_by, 'INSPECTION_' || p_decision, 'Inspección ' || i.number || ' ' || lower(p_decision), i.plate || coalesce(' · Motivo: ' || i.reject_reason, ''), i.id);
  end if;
  return i;
end; $$;

-- ---------- nueva revisión (de una APROBADA o RECHAZADA): la original queda intacta; la nueva es un BORRADOR enlazado ----------
create or replace function public.inspection_new_revision(p_id uuid, p_client_id uuid) returns public.vehicle_inspections language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._insp_me(); o public.vehicle_inspections; n public.vehicle_inspections;
begin
  if me.role not in ('OPERARIO_DEPOSITO','SUPERVISOR_DESPACHO') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_id is null or p_client_id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  -- (corrección de seguridad) PRIMERO se valida la inspección ORIGINAL: existe y el usuario puede verla. Ningún dato sale antes de esto.
  select * into o from public.vehicle_inspections where id = p_id;
  if o.id is null or not public._insp_can_view(o) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  -- reintento idempotente (doble toque / sin conexión): SOLO si ese client_id es una revisión creada por ESTE usuario a partir de ESTA original.
  -- Cualquier otro uso de un client_id existente se rechaza SIN devolver datos (ni número, ni patente, ni estado).
  select * into n from public.vehicle_inspections where client_id = p_client_id;
  if n.id is not null then
    if n.created_by = me.id and n.parent_id = o.id then return n; end if;
    raise exception 'CLIENT_ID_CONFLICT: el identificador de la revisión ya está en uso; generá uno nuevo' using errcode = '23505';
  end if;
  if o.status not in ('APROBADA','RECHAZADA') then raise exception 'BAD_STATE: solo se revisa una inspección aprobada o rechazada' using errcode = '23514'; end if;
  insert into public.vehicle_inspections(number, revision, parent_id, client_id, vehicle_id, vehicle_name, vehicle_type, brand, model, plate, km, created_by, created_by_name, team_supervisor_id, general_observation)
  values (o.number, (select max(revision) + 1 from public.vehicle_inspections where number = o.number), o.id, p_client_id, o.vehicle_id, o.vehicle_name, o.vehicle_type, o.brand, o.model, o.plate, o.km,
          me.id, me.full_name, case when me.role = 'SUPERVISOR_DESPACHO' then me.id else me.supervisor_user_id end, o.general_observation) returning * into n;
  insert into public.vehicle_inspection_items(inspection_id, item_no, result, defect, observation, extra_date, extra_km)
    select n.id, item_no, result, defect, observation, extra_date, extra_km from public.vehicle_inspection_items where inspection_id = o.id;
  perform public._insp_event(n.id, 'REVISION_CREADA', jsonb_build_object('from', o.id, 'revision', n.revision));
  perform public._insp_event(o.id, 'REVISION_CREADA', jsonb_build_object('to', n.id, 'revision', n.revision));
  return n;
end; $$;

-- ---------- email a superiores: se PREPARA para revisión y se ENVÍA solo con confirmación explícita (nunca al aprobar) ----------
create or replace function public.inspection_email_request(p_id uuid, p_recipients text[], p_subject text, p_body text) returns bigint language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._insp_me(); i public.vehicle_inspections; r text; rid bigint;
begin
  if me.role <> 'SUPERVISOR_DESPACHO' then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into i from public.vehicle_inspections where id = p_id;
  if i.id is null or not public._insp_can_view(i) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if i.status <> 'APROBADA' then raise exception 'BAD_STATE: el email se prepara solo para inspecciones aprobadas' using errcode = '23514'; end if;
  if coalesce(array_length(p_recipients, 1), 0) = 0 then raise exception 'RECIPIENTS_REQUIRED' using errcode = '23514'; end if;
  foreach r in array p_recipients loop if not public.is_valid_email(r) then raise exception 'EMAIL_INVALID: %', r using errcode = '23514'; end if; end loop;
  insert into public.vehicle_inspection_email_requests(inspection_id, requested_by, recipients, subject, body) values (i.id, me.id, p_recipients, p_subject, p_body) returning id into rid;
  perform public._insp_event(i.id, 'EMAIL_SOLICITADO', jsonb_build_object('recipients', p_recipients));
  return rid;
end; $$;

-- ---------- defensa en profundidad: ninguna inspección enviada/revisada se modifica ni sus controles cambian por fuera de las funciones ----------
create or replace function public.trg_insp_items_locked() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if (select status from public.vehicle_inspections where id = coalesce(new.inspection_id, old.inspection_id)) <> 'BORRADOR' then
    raise exception 'INSPECTION_LOCKED: la inspección ya fue enviada; sus controles no se modifican' using errcode = '23514'; end if;
  return coalesce(new, old);
end; $$;
create trigger vehicle_inspection_items_locked before insert or update or delete on public.vehicle_inspection_items for each row execute function public.trg_insp_items_locked();

-- ---------- RLS y privilegios: lectura por equipo; ninguna escritura directa ----------
alter table public.vehicle_inspection_controls enable row level security; alter table public.vehicle_inspections enable row level security;
alter table public.vehicle_inspection_items enable row level security; alter table public.vehicle_inspection_events enable row level security;
alter table public.vehicle_inspection_email_requests enable row level security;
create policy insp_controls_read on public.vehicle_inspection_controls for select to authenticated using (true);
create policy insp_read on public.vehicle_inspections for select to authenticated using (public._insp_can_view(vehicle_inspections));
create policy insp_items_read on public.vehicle_inspection_items for select to authenticated using (exists (select 1 from public.vehicle_inspections i where i.id = inspection_id and public._insp_can_view(i)));
create policy insp_events_read on public.vehicle_inspection_events for select to authenticated using (exists (select 1 from public.vehicle_inspections i where i.id = inspection_id and public._insp_can_view(i)));
create policy insp_email_read on public.vehicle_inspection_email_requests for select to authenticated using (exists (select 1 from public.vehicle_inspections i where i.id = inspection_id and public._insp_can_view(i)));
do $$ declare t text; f text; begin
  foreach t in array array['vehicle_inspection_controls','vehicle_inspections','vehicle_inspection_items','vehicle_inspection_events','vehicle_inspection_email_requests'] loop
    execute format('revoke all on table public.%I from public, anon, authenticated', t); execute format('grant select on table public.%I to authenticated', t); end loop;
  execute 'revoke all on sequence public.vehicle_inspection_number_seq from public, anon, authenticated';
  foreach f in array array['inspection_save_draft(jsonb)','inspection_submit(uuid)','inspection_review(uuid,text,text)','inspection_new_revision(uuid,uuid)','inspection_email_request(uuid,text[],text,text)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon'; execute 'grant execute on function public.' || f || ' to authenticated'; end loop;
  foreach f in array array['_insp_me()','_insp_event(uuid,text,jsonb)','trg_insp_items_locked()'] loop execute 'revoke all on function public.' || f || ' from public, anon, authenticated'; end loop;
  execute 'revoke all on function public._insp_can_view(public.vehicle_inspections) from public, anon'; execute 'grant execute on function public._insp_can_view(public.vehicle_inspections) to authenticated';   -- la usa RLS
end $$;

DO $post$ BEGIN
  IF (SELECT count(*) FROM public.vehicle_inspection_controls) <> 30 THEN RAISE EXCEPTION 'HUELLA_FINAL_INESPERADA: el catálogo no tiene 30 controles. Se deshace todo.'; END IF;
END $post$;
COMMIT;

;
CREATE OR REPLACE FUNCTION public._insp_me()
 RETURNS profiles
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me public.profiles;
begin
  select * into me from public.profiles where id = auth.uid() and status = 'ACTIVO';
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return me;
end; $function$
;
;
CREATE OR REPLACE FUNCTION public._insp_event(p_id uuid, p_action text, p_detail jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me public.profiles;
begin
  select * into me from public.profiles where id = auth.uid();
  insert into public.vehicle_inspection_events(inspection_id, action, actor, actor_name, detail) values (p_id, p_action, auth.uid(), me.full_name, p_detail);
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'INSPECTION_' || p_action, 'vehicle_inspection', p_id::text, p_detail);
end; $function$
;
;
CREATE OR REPLACE FUNCTION public.inspection_save_draft(p jsonb)
 RETURNS vehicle_inspections
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me public.profiles := public._insp_me(); i public.vehicle_inspections; v public.vehicles; it jsonb; n int;
begin
  if me.role not in ('OPERARIO_DEPOSITO','SUPERVISOR_DESPACHO') then raise exception 'FORBIDDEN: solo Operario Depósito o Superior Despacho realizan inspecciones' using errcode = '42501'; end if;
  if (p->>'client_id') is null then raise exception 'CLIENT_ID_REQUIRED' using errcode = '22023'; end if;
  select * into i from public.vehicle_inspections where client_id = (p->>'client_id')::uuid;
  if i.id is not null and i.created_by <> me.id then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if i.id is not null and i.status <> 'BORRADOR' then return i; end if;   -- ya enviada: un guardado tardío (sin conexión) NO la modifica
  select * into v from public.vehicles where id = (p->>'vehicle_id')::uuid;
  if v.id is null then raise exception 'VEHICLE_NOT_FOUND: elegí un vehículo' using errcode = '23514'; end if;
  if i.id is null then
    insert into public.vehicle_inspections(number, client_id, vehicle_id, vehicle_name, vehicle_type, brand, model, plate, km, created_by, created_by_name, team_supervisor_id, general_observation)
    values ('INS-' || lpad(nextval('public.vehicle_inspection_number_seq')::text, 6, '0'), (p->>'client_id')::uuid, v.id, v.name, v.type, v.brand, v.model, v.plate,
            nullif(p->>'km', '')::numeric, me.id, me.full_name, case when me.role = 'SUPERVISOR_DESPACHO' then me.id else me.supervisor_user_id end, p->>'general_observation')
    returning * into i;
    perform public._insp_event(i.id, 'CREADA', jsonb_build_object('number', i.number, 'plate', i.plate));
  else
    update public.vehicle_inspections set vehicle_id = v.id, vehicle_name = v.name, vehicle_type = v.type, brand = v.brand, model = v.model, plate = v.plate,
      km = nullif(p->>'km', '')::numeric, general_observation = p->>'general_observation', updated_at = now() where id = i.id returning * into i;
  end if;
  for it in select * from jsonb_array_elements(coalesce(p->'items', '[]'::jsonb)) loop
    n := (it->>'n')::int; if n is null or n < 1 or n > 30 then raise exception 'ITEM_INVALID' using errcode = '22023'; end if;
    insert into public.vehicle_inspection_items(inspection_id, item_no, result, defect, observation, extra_date, extra_km)
    values (i.id, n, nullif(it->>'result', ''), nullif(it->>'defect', ''), nullif(trim(coalesce(it->>'observation', '')), ''), nullif(it->>'extra_date', '')::date, nullif(it->>'extra_km', '')::numeric)
    on conflict (inspection_id, item_no) do update set result = excluded.result, defect = excluded.defect, observation = excluded.observation, extra_date = excluded.extra_date, extra_km = excluded.extra_km;
  end loop;
  return i;
end; $function$
;
;
CREATE OR REPLACE FUNCTION public.inspection_submit(p_id uuid)
 RETURNS vehicle_inspections
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me public.profiles := public._insp_me(); i public.vehicle_inspections; miss int; bad int; team uuid;
begin
  select * into i from public.vehicle_inspections where id = p_id for update;
  if i.id is null or i.created_by <> me.id then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if i.status = 'PENDIENTE' then return i; end if;   -- reintento (doble toque / cola sin conexión): no duplica
  if i.status <> 'BORRADOR' then raise exception 'BAD_STATE: la inspección ya fue revisada' using errcode = '23514'; end if;
  if i.km is null or i.km < 0 then raise exception 'KM_REQUIRED: cargá el kilometraje' using errcode = '23514'; end if;
  select count(*) into miss from public.vehicle_inspection_controls c left join public.vehicle_inspection_items x on x.inspection_id = i.id and x.item_no = c.item_no where x.result is null;
  if miss > 0 then raise exception 'INCOMPLETE: faltan % controles por responder', miss using errcode = '23514'; end if;
  select count(*) into bad from public.vehicle_inspection_items where inspection_id = i.id and result = 'MAL' and (defect is null or observation is null);
  if bad > 0 then raise exception 'ANOMALY_INCOMPLETE: cada control MAL necesita FALTANTE o MAL ESTADO y una observación (% sin completar)', bad using errcode = '23514'; end if;
  -- Superior responsable: el asignado AL ENVIAR (el propio, si quien envía es Superior). Sin Superior activo asignado → no se envía ni se expone.
  team := case when me.role = 'SUPERVISOR_DESPACHO' then me.id else me.supervisor_user_id end;
  if team is null or not exists (select 1 from public.profiles p where p.id = team and p.role = 'SUPERVISOR_DESPACHO' and p.status = 'ACTIVO') then
    raise exception 'SUPERVISOR_REQUIRED: tu usuario no tiene un Superior Despacho asignado. Pedí al Administrador General que te asigne uno; la inspección queda guardada como borrador' using errcode = '23514'; end if;
  update public.vehicle_inspections set status = 'PENDIENTE', submitted_at = now(), updated_at = now(), team_supervisor_id = team,
    anomalies = (select count(*) from public.vehicle_inspection_items where inspection_id = i.id and result = 'MAL') where id = i.id returning * into i;
  perform public._insp_event(i.id, 'ENVIADA', jsonb_build_object('anomalies', i.anomalies, 'supervisor', team));
  if me.role <> 'SUPERVISOR_DESPACHO' then   -- SOLO al Superior de ese equipo (el Superior que inspecciona no se notifica a sí mismo)
    insert into public.notifications(user_id, type, title, body, inspection_id)
    values (team, 'INSPECTION_PENDING', 'Inspección ' || i.number || ' pendiente de aprobación', i.plate || ' · ' || coalesce(i.vehicle_name, '') || ' · ' || i.created_by_name || ' · ' || i.anomalies || ' anomalía(s)', i.id);
  end if;
  return i;
end; $function$
;
;
CREATE OR REPLACE FUNCTION public.inspection_review(p_id uuid, p_decision text, p_reason text)
 RETURNS vehicle_inspections
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me public.profiles := public._insp_me(); i public.vehicle_inspections;
begin
  if me.role <> 'SUPERVISOR_DESPACHO' then raise exception 'FORBIDDEN: solo el Superior Despacho aprueba o rechaza inspecciones' using errcode = '42501'; end if;
  if p_decision not in ('APROBADA','RECHAZADA') then raise exception 'DECISION_INVALIDA' using errcode = '22023'; end if;
  select * into i from public.vehicle_inspections where id = p_id for update;
  if i.id is null or not coalesce(i.created_by = me.id or i.team_supervisor_id = me.id, false) then raise exception 'FORBIDDEN: la inspección es de otro equipo' using errcode = '42501'; end if;   -- sin equipo (NULL) = de otro equipo
  if i.status in ('APROBADA','RECHAZADA') then
    if i.status = p_decision then return i; end if;   -- reintento: misma decisión, no duplica
    raise exception 'ALREADY_REVIEWED: la inspección ya fue %', lower(i.status) using errcode = '23514'; end if;
  if i.status <> 'PENDIENTE' then raise exception 'BAD_STATE: la inspección no está pendiente' using errcode = '23514'; end if;
  if p_decision = 'RECHAZADA' and coalesce(trim(p_reason), '') = '' then raise exception 'REASON_REQUIRED: indicá el motivo del rechazo' using errcode = '23514'; end if;
  update public.vehicle_inspections set status = p_decision, reviewed_by = me.id, reviewed_by_name = me.full_name, reviewed_at = now(),
    reject_reason = case when p_decision = 'RECHAZADA' then trim(p_reason) end, updated_at = now() where id = i.id returning * into i;
  perform public._insp_event(i.id, p_decision, jsonb_build_object('reason', i.reject_reason, 'self', i.created_by = me.id));
  if i.created_by <> me.id then
    insert into public.notifications(user_id, type, title, body, inspection_id)
    values (i.created_by, 'INSPECTION_' || p_decision, 'Inspección ' || i.number || ' ' || lower(p_decision), i.plate || coalesce(' · Motivo: ' || i.reject_reason, ''), i.id);
  end if;
  return i;
end; $function$
;
;
CREATE OR REPLACE FUNCTION public.inspection_new_revision(p_id uuid, p_client_id uuid)
 RETURNS vehicle_inspections
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me public.profiles := public._insp_me(); o public.vehicle_inspections; n public.vehicle_inspections;
begin
  if me.role not in ('OPERARIO_DEPOSITO','SUPERVISOR_DESPACHO') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_id is null or p_client_id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  -- (corrección de seguridad) PRIMERO se valida la inspección ORIGINAL: existe y el usuario puede verla. Ningún dato sale antes de esto.
  select * into o from public.vehicle_inspections where id = p_id;
  if o.id is null or not public._insp_can_view(o) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  -- reintento idempotente (doble toque / sin conexión): SOLO si ese client_id es una revisión creada por ESTE usuario a partir de ESTA original.
  -- Cualquier otro uso de un client_id existente se rechaza SIN devolver datos (ni número, ni patente, ni estado).
  select * into n from public.vehicle_inspections where client_id = p_client_id;
  if n.id is not null then
    if n.created_by = me.id and n.parent_id = o.id then return n; end if;
    raise exception 'CLIENT_ID_CONFLICT: el identificador de la revisión ya está en uso; generá uno nuevo' using errcode = '23505';
  end if;
  if o.status not in ('APROBADA','RECHAZADA') then raise exception 'BAD_STATE: solo se revisa una inspección aprobada o rechazada' using errcode = '23514'; end if;
  insert into public.vehicle_inspections(number, revision, parent_id, client_id, vehicle_id, vehicle_name, vehicle_type, brand, model, plate, km, created_by, created_by_name, team_supervisor_id, general_observation)
  values (o.number, (select max(revision) + 1 from public.vehicle_inspections where number = o.number), o.id, p_client_id, o.vehicle_id, o.vehicle_name, o.vehicle_type, o.brand, o.model, o.plate, o.km,
          me.id, me.full_name, case when me.role = 'SUPERVISOR_DESPACHO' then me.id else me.supervisor_user_id end, o.general_observation) returning * into n;
  insert into public.vehicle_inspection_items(inspection_id, item_no, result, defect, observation, extra_date, extra_km)
    select n.id, item_no, result, defect, observation, extra_date, extra_km from public.vehicle_inspection_items where inspection_id = o.id;
  perform public._insp_event(n.id, 'REVISION_CREADA', jsonb_build_object('from', o.id, 'revision', n.revision));
  perform public._insp_event(o.id, 'REVISION_CREADA', jsonb_build_object('to', n.id, 'revision', n.revision));
  return n;
end; $function$
;
;
CREATE OR REPLACE FUNCTION public.inspection_email_request(p_id uuid, p_recipients text[], p_subject text, p_body text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me public.profiles := public._insp_me(); i public.vehicle_inspections; r text; rid bigint;
begin
  if me.role <> 'SUPERVISOR_DESPACHO' then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into i from public.vehicle_inspections where id = p_id;
  if i.id is null or not public._insp_can_view(i) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if i.status <> 'APROBADA' then raise exception 'BAD_STATE: el email se prepara solo para inspecciones aprobadas' using errcode = '23514'; end if;
  if coalesce(array_length(p_recipients, 1), 0) = 0 then raise exception 'RECIPIENTS_REQUIRED' using errcode = '23514'; end if;
  foreach r in array p_recipients loop if not public.is_valid_email(r) then raise exception 'EMAIL_INVALID: %', r using errcode = '23514'; end if; end loop;
  insert into public.vehicle_inspection_email_requests(inspection_id, requested_by, recipients, subject, body) values (i.id, me.id, p_recipients, p_subject, p_body) returning id into rid;
  perform public._insp_event(i.id, 'EMAIL_SOLICITADO', jsonb_build_object('recipients', p_recipients));
  return rid;
end; $function$
;
;
CREATE OR REPLACE FUNCTION public._insp_can_view(i vehicle_inspections)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (select 1 from public.profiles me where me.id = auth.uid() and me.status = 'ACTIVO' and (
    me.role = 'ADMIN' or i.created_by = me.id
    or (me.role = 'SUPERVISOR_DESPACHO' and i.team_supervisor_id = me.id))); $function$
;
;
CREATE OR REPLACE FUNCTION public.finalize_route(p_route uuid, p_km_end numeric DEFAULT NULL::numeric)
 RETURNS routes
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end; $function$
;
;
-- Administrador General es el rol interno ADMIN, validado por _insp_me (ACTIVO).
-- Solo cinco RPC; no se cambian RLS, ACL, controles, rutas ni datos históricos.
-- Los borradores ajenos mantienen su propietario; Admin revisa cualquier equipo.
do $guard$ begin
  if (select md5(prosrc) from pg_proc where oid='public._insp_me()'::regprocedure) is distinct from '0e14354db6cfc8bc3249f36683fdd22f' then raise exception 'PRECONDITION_FAILED: _insp_me'; end if;
  if (select md5(prosrc) from pg_proc where oid='public._insp_event(uuid,text,jsonb)'::regprocedure) is distinct from '1a405fb2269b56198c7fd8a50e7d5e6e' then raise exception 'PRECONDITION_FAILED: _insp_event'; end if;
  if (select md5(prosrc) from pg_proc where oid='public.inspection_save_draft(jsonb)'::regprocedure) is distinct from '73fd5a97deb03f3514310ab5042da5cd' then raise exception 'PRECONDITION_FAILED: inspection_save_draft'; end if;
  if (select md5(prosrc) from pg_proc where oid='public.inspection_submit(uuid)'::regprocedure) is distinct from 'bbd5335d7fe620253410ca9a75440144' then raise exception 'PRECONDITION_FAILED: inspection_submit'; end if;
  if (select md5(prosrc) from pg_proc where oid='public.inspection_review(uuid,text,text)'::regprocedure) is distinct from '90129a0e55d67a6bb5c7b0ba5ee0bc64' then raise exception 'PRECONDITION_FAILED: inspection_review'; end if;
  if (select md5(prosrc) from pg_proc where oid='public.inspection_new_revision(uuid,uuid)'::regprocedure) is distinct from '95f97374a4ba1c6301929cc300995ec5' then raise exception 'PRECONDITION_FAILED: inspection_new_revision'; end if;
  if (select md5(prosrc) from pg_proc where oid='public.inspection_email_request(uuid,text[],text,text)'::regprocedure) is distinct from 'c62e056b0c544784c441641366e50519' then raise exception 'PRECONDITION_FAILED: inspection_email_request'; end if;
  if (select md5(prosrc) from pg_proc where oid='public._insp_can_view(vehicle_inspections)'::regprocedure) is distinct from '1801f00f09c1c95986a6cf2d965b3990' then raise exception 'PRECONDITION_FAILED: _insp_can_view'; end if;
  if (select md5(prosrc) from pg_proc where oid='public.finalize_route(uuid,numeric)'::regprocedure) is distinct from '5bdf85adab176a36ec9b55ceb1af3179' then raise exception 'PRECONDITION_FAILED: finalize_route'; end if;
  if (select count(*) from public.vehicle_inspection_controls) <> 30 or (select md5(jsonb_agg(to_jsonb(c) order by item_no)::text) from public.vehicle_inspection_controls c) <> '45ffdfc9144ef724c94103b56701e7a9' then raise exception 'PRECONDITION_FAILED: catalogo de controles'; end if;
end $guard$;

CREATE OR REPLACE FUNCTION public.inspection_save_draft(p jsonb)
 RETURNS vehicle_inspections
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me public.profiles := public._insp_me(); i public.vehicle_inspections; v public.vehicles; it jsonb; n int; existed boolean;
begin
  if me.role not in ('ADMIN','OPERARIO_DEPOSITO','SUPERVISOR_DESPACHO') then raise exception 'FORBIDDEN: solo Administrador General, Operario Depósito o Superior Despacho realizan inspecciones' using errcode = '42501'; end if;
  if (p->>'client_id') is null then raise exception 'CLIENT_ID_REQUIRED' using errcode = '22023'; end if;
  select * into i from public.vehicle_inspections where client_id = (p->>'client_id')::uuid;
  existed := i.id is not null;
  if i.id is not null and i.created_by <> me.id then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if i.id is not null and i.status <> 'BORRADOR' then return i; end if;   -- ya enviada: un guardado tardío (sin conexión) NO la modifica
  select * into v from public.vehicles where id = (p->>'vehicle_id')::uuid;
  if v.id is null then raise exception 'VEHICLE_NOT_FOUND: elegí un vehículo' using errcode = '23514'; end if;
  if i.id is null then
    insert into public.vehicle_inspections(number, client_id, vehicle_id, vehicle_name, vehicle_type, brand, model, plate, km, created_by, created_by_name, team_supervisor_id, general_observation)
    values ('INS-' || lpad(nextval('public.vehicle_inspection_number_seq')::text, 6, '0'), (p->>'client_id')::uuid, v.id, v.name, v.type, v.brand, v.model, v.plate,
            nullif(p->>'km', '')::numeric, me.id, me.full_name, case when me.role = 'ADMIN' then null when me.role = 'SUPERVISOR_DESPACHO' then me.id else me.supervisor_user_id end, p->>'general_observation')
    returning * into i;
    perform public._insp_event(i.id, 'CREADA', jsonb_build_object('number', i.number, 'plate', i.plate));
  else
    update public.vehicle_inspections set vehicle_id = v.id, vehicle_name = v.name, vehicle_type = v.type, brand = v.brand, model = v.model, plate = v.plate,
      km = nullif(p->>'km', '')::numeric, general_observation = p->>'general_observation', updated_at = now() where id = i.id returning * into i;
  end if;
  for it in select * from jsonb_array_elements(coalesce(p->'items', '[]'::jsonb)) loop
    n := (it->>'n')::int; if n is null or n < 1 or n > 30 then raise exception 'ITEM_INVALID' using errcode = '22023'; end if;
    insert into public.vehicle_inspection_items(inspection_id, item_no, result, defect, observation, extra_date, extra_km)
    values (i.id, n, nullif(it->>'result', ''), nullif(it->>'defect', ''), nullif(trim(coalesce(it->>'observation', '')), ''), nullif(it->>'extra_date', '')::date, nullif(it->>'extra_km', '')::numeric)
    on conflict (inspection_id, item_no) do update set result = excluded.result, defect = excluded.defect, observation = excluded.observation, extra_date = excluded.extra_date, extra_km = excluded.extra_km;
  end loop;
  if existed and me.role = 'ADMIN' then
    insert into public.audit_log(actor_id,action,target_type,target_id,after) values (me.id,'INSPECTION_BORRADOR_GUARDADO','vehicle_inspection',i.id::text,jsonb_build_object('created_by',i.created_by));
  end if;
  return i;
end; $function$
;

CREATE OR REPLACE FUNCTION public.inspection_submit(p_id uuid)
 RETURNS vehicle_inspections
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me public.profiles := public._insp_me(); i public.vehicle_inspections; miss int; bad int; team uuid;
begin
  select * into i from public.vehicle_inspections where id = p_id for update;
  if i.id is null or i.created_by <> me.id then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if i.status = 'PENDIENTE' then return i; end if;   -- reintento (doble toque / cola sin conexión): no duplica
  if i.status <> 'BORRADOR' then raise exception 'BAD_STATE: la inspección ya fue revisada' using errcode = '23514'; end if;
  if i.km is null or i.km < 0 then raise exception 'KM_REQUIRED: cargá el kilometraje' using errcode = '23514'; end if;
  select count(*) into miss from public.vehicle_inspection_controls c left join public.vehicle_inspection_items x on x.inspection_id = i.id and x.item_no = c.item_no where x.result is null;
  if miss > 0 then raise exception 'INCOMPLETE: faltan % controles por responder', miss using errcode = '23514'; end if;
  select count(*) into bad from public.vehicle_inspection_items where inspection_id = i.id and result = 'MAL' and (defect is null or observation is null);
  if bad > 0 then raise exception 'ANOMALY_INCOMPLETE: cada control MAL necesita FALTANTE o MAL ESTADO y una observación (% sin completar)', bad using errcode = '23514'; end if;
  -- Superior responsable: el asignado AL ENVIAR (el propio, si quien envía es Superior). Sin Superior activo asignado → no se envía ni se expone.
  team := case when me.role = 'ADMIN' then i.team_supervisor_id when me.role = 'SUPERVISOR_DESPACHO' then me.id else me.supervisor_user_id end;
  if me.role <> 'ADMIN' and (team is null or not exists (select 1 from public.profiles p where p.id = team and p.role = 'SUPERVISOR_DESPACHO' and p.status = 'ACTIVO')) then
    raise exception 'SUPERVISOR_REQUIRED: tu usuario no tiene un Superior Despacho asignado. Pedí al Administrador General que te asigne uno; la inspección queda guardada como borrador' using errcode = '23514'; end if;
  update public.vehicle_inspections set status = 'PENDIENTE', submitted_at = now(), updated_at = now(), team_supervisor_id = team,
    anomalies = (select count(*) from public.vehicle_inspection_items where inspection_id = i.id and result = 'MAL') where id = i.id returning * into i;
  perform public._insp_event(i.id, 'ENVIADA', jsonb_build_object('anomalies', i.anomalies, 'supervisor', team));
  if me.role not in ('ADMIN','SUPERVISOR_DESPACHO') then   -- SOLO al Superior de ese equipo (el Superior que inspecciona no se notifica a sí mismo)
    insert into public.notifications(user_id, type, title, body, inspection_id)
    values (team, 'INSPECTION_PENDING', 'Inspección ' || i.number || ' pendiente de aprobación', i.plate || ' · ' || coalesce(i.vehicle_name, '') || ' · ' || i.created_by_name || ' · ' || i.anomalies || ' anomalía(s)', i.id);
  end if;
  return i;
end; $function$
;

CREATE OR REPLACE FUNCTION public.inspection_review(p_id uuid, p_decision text, p_reason text)
 RETURNS vehicle_inspections
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me public.profiles := public._insp_me(); i public.vehicle_inspections;
begin
  if me.role not in ('ADMIN','SUPERVISOR_DESPACHO') then raise exception 'FORBIDDEN: solo Administrador General o Superior Despacho aprueban o rechazan inspecciones' using errcode = '42501'; end if;
  if p_decision not in ('APROBADA','RECHAZADA') then raise exception 'DECISION_INVALIDA' using errcode = '22023'; end if;
  select * into i from public.vehicle_inspections where id = p_id for update;
  if i.id is null or not coalesce(me.role = 'ADMIN' or i.created_by = me.id or i.team_supervisor_id = me.id, false) then raise exception 'FORBIDDEN: la inspección es de otro equipo' using errcode = '42501'; end if;   -- sin equipo (NULL) = de otro equipo
  if i.status in ('APROBADA','RECHAZADA') then
    if i.status = p_decision then return i; end if;   -- reintento: misma decisión, no duplica
    raise exception 'ALREADY_REVIEWED: la inspección ya fue %', lower(i.status) using errcode = '23514'; end if;
  if i.status <> 'PENDIENTE' then raise exception 'BAD_STATE: la inspección no está pendiente' using errcode = '23514'; end if;
  if p_decision = 'RECHAZADA' and coalesce(trim(p_reason), '') = '' then raise exception 'REASON_REQUIRED: indicá el motivo del rechazo' using errcode = '23514'; end if;
  update public.vehicle_inspections set status = p_decision, reviewed_by = me.id, reviewed_by_name = me.full_name, reviewed_at = now(),
    reject_reason = case when p_decision = 'RECHAZADA' then trim(p_reason) end, updated_at = now() where id = i.id returning * into i;
  perform public._insp_event(i.id, p_decision, jsonb_build_object('reason', i.reject_reason, 'self', i.created_by = me.id));
  if i.created_by <> me.id then
    insert into public.notifications(user_id, type, title, body, inspection_id)
    values (i.created_by, 'INSPECTION_' || p_decision, 'Inspección ' || i.number || ' ' || lower(p_decision), i.plate || coalesce(' · Motivo: ' || i.reject_reason, ''), i.id);
  end if;
  return i;
end; $function$
;

CREATE OR REPLACE FUNCTION public.inspection_new_revision(p_id uuid, p_client_id uuid)
 RETURNS vehicle_inspections
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me public.profiles := public._insp_me(); o public.vehicle_inspections; n public.vehicle_inspections;
begin
  if me.role not in ('ADMIN','OPERARIO_DEPOSITO','SUPERVISOR_DESPACHO') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_id is null or p_client_id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  -- (corrección de seguridad) PRIMERO se valida la inspección ORIGINAL: existe y el usuario puede verla. Ningún dato sale antes de esto.
  select * into o from public.vehicle_inspections where id = p_id;
  if o.id is null or not public._insp_can_view(o) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  -- reintento idempotente (doble toque / sin conexión): SOLO si ese client_id es una revisión creada por ESTE usuario a partir de ESTA original.
  -- Cualquier otro uso de un client_id existente se rechaza SIN devolver datos (ni número, ni patente, ni estado).
  select * into n from public.vehicle_inspections where client_id = p_client_id;
  if n.id is not null then
    if n.created_by = me.id and n.parent_id = o.id then return n; end if;
    raise exception 'CLIENT_ID_CONFLICT: el identificador de la revisión ya está en uso; generá uno nuevo' using errcode = '23505';
  end if;
  if o.status not in ('APROBADA','RECHAZADA') then raise exception 'BAD_STATE: solo se revisa una inspección aprobada o rechazada' using errcode = '23514'; end if;
  insert into public.vehicle_inspections(number, revision, parent_id, client_id, vehicle_id, vehicle_name, vehicle_type, brand, model, plate, km, created_by, created_by_name, team_supervisor_id, general_observation)
  values (o.number, (select max(revision) + 1 from public.vehicle_inspections where number = o.number), o.id, p_client_id, o.vehicle_id, o.vehicle_name, o.vehicle_type, o.brand, o.model, o.plate, o.km,
          me.id, me.full_name, case when me.role = 'ADMIN' then null when me.role = 'SUPERVISOR_DESPACHO' then me.id else me.supervisor_user_id end, o.general_observation) returning * into n;
  insert into public.vehicle_inspection_items(inspection_id, item_no, result, defect, observation, extra_date, extra_km)
    select n.id, item_no, result, defect, observation, extra_date, extra_km from public.vehicle_inspection_items where inspection_id = o.id;
  perform public._insp_event(n.id, 'REVISION_CREADA', jsonb_build_object('from', o.id, 'revision', n.revision));
  perform public._insp_event(o.id, 'REVISION_CREADA', jsonb_build_object('to', n.id, 'revision', n.revision));
  return n;
end; $function$
;

CREATE OR REPLACE FUNCTION public.inspection_email_request(p_id uuid, p_recipients text[], p_subject text, p_body text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me public.profiles := public._insp_me(); i public.vehicle_inspections; r text; rid bigint;
begin
  if me.role not in ('ADMIN','SUPERVISOR_DESPACHO') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into i from public.vehicle_inspections where id = p_id;
  if i.id is null or not public._insp_can_view(i) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if i.status <> 'APROBADA' then raise exception 'BAD_STATE: el email se prepara solo para inspecciones aprobadas' using errcode = '23514'; end if;
  if coalesce(array_length(p_recipients, 1), 0) = 0 then raise exception 'RECIPIENTS_REQUIRED' using errcode = '23514'; end if;
  foreach r in array p_recipients loop if not public.is_valid_email(r) then raise exception 'EMAIL_INVALID: %', r using errcode = '23514'; end if; end loop;
  insert into public.vehicle_inspection_email_requests(inspection_id, requested_by, recipients, subject, body) values (i.id, me.id, p_recipients, p_subject, p_body) returning id into rid;
  perform public._insp_event(i.id, 'EMAIL_SOLICITADO', jsonb_build_object('recipients', p_recipients));
  return rid;
end; $function$
;
do $guard$ begin
  if (select md5(prosrc) from pg_proc where oid='public._insp_me()'::regprocedure) <> '0e14354db6cfc8bc3249f36683fdd22f' then raise exception 'PROTECTED_FUNCTION_CHANGED: _insp_me'; end if;
  if (select md5(prosrc) from pg_proc where oid='public._insp_event(uuid,text,jsonb)'::regprocedure) <> '1a405fb2269b56198c7fd8a50e7d5e6e' then raise exception 'PROTECTED_FUNCTION_CHANGED: _insp_event'; end if;
  if (select md5(prosrc) from pg_proc where oid='public._insp_can_view(vehicle_inspections)'::regprocedure) <> '1801f00f09c1c95986a6cf2d965b3990' then raise exception 'PROTECTED_FUNCTION_CHANGED: _insp_can_view'; end if;
  if (select md5(prosrc) from pg_proc where oid='public.finalize_route(uuid,numeric)'::regprocedure) <> '5bdf85adab176a36ec9b55ceb1af3179' then raise exception 'PROTECTED_FUNCTION_CHANGED: finalize_route'; end if;
  if (select count(*) from public.vehicle_inspection_controls) <> 30 or (select md5(jsonb_agg(to_jsonb(c) order by item_no)::text) from public.vehicle_inspection_controls c) <> '45ffdfc9144ef724c94103b56701e7a9' then raise exception 'PRECONDITION_FAILED: catalogo de controles'; end if;
end $guard$;

;
create schema okd_delivery_security;grant usage on schema okd_delivery_security to authenticated;
;
CREATE OR REPLACE FUNCTION okd_delivery_security.may_read(p_route uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id=auth.uid() AND p.status='ACTIVO'
      AND (p.role='ADMIN' OR (
        p.role='SUPERVISOR_DESPACHO'
        AND public.auth_has_perm('signatures.view')
        AND EXISTS (
          SELECT 1 FROM public.routes r WHERE r.id=p_route
          AND (public._route_belongs_to(r.id,r.published_by,p.id)
            OR EXISTS (SELECT 1 FROM public.team_of(p.id) AS t(member_id)
              WHERE public._route_belongs_to(r.id,r.published_by,t.member_id)))
        )
      ))
  );
$function$
;
;
-- =====================================================================================================================
-- PROPUESTA V4.26 · NO APLICADA · Mejoras aprobadas: padrón de correos de clientes · «Tu pedido está en camino» · BUSCAR ENTREGA
-- DEPENDE de V4.23 (client_emails, _cuit_valid, _is_general_admin) y de las tablas base de entregas. Aditiva: NO modifica funciones existentes
-- (la sugerencia de correo de V4.23 queda igual; se agrega delivery_email_suggestion2). Una transacción; si ya está aplicada, se detiene.
-- =====================================================================================================================
BEGIN;
DO $guard$ BEGIN
  IF to_regclass('public.client_email_aliases') IS NOT NULL OR to_regprocedure('public.search_deliveries(text)') IS NOT NULL THEN
    RAISE EXCEPTION 'YA_APLICADA: la V4.26 ya existe. No se modificó nada.'; END IF;
  IF to_regclass('public.client_emails') IS NULL OR to_regprocedure('public._cuit_valid(text)') IS NULL OR to_regprocedure('public._is_general_admin()') IS NULL THEN
    RAISE EXCEPTION 'DEPENDENCIA_FALTANTE: falta la V4.23 (client_emails / _cuit_valid / _is_general_admin). No se modificó nada.'; END IF;
  IF to_regprocedure('okd_delivery_security.may_read(uuid)') IS NULL THEN RAISE EXCEPTION 'DEPENDENCIA_FALTANTE: protección vigente de firmas por equipo';END IF;
  IF (select md5(prosrc) from pg_proc where oid='public.finalize_route(uuid,numeric)'::regprocedure)<>'5bdf85adab176a36ec9b55ceb1af3179' THEN RAISE EXCEPTION 'PRECONDITION_FAILED: finalize_route';END IF;
  IF current_setting('server_encoding') <> 'UTF8' THEN RAISE EXCEPTION 'CODIFICACION: la base no está en UTF8; la normalización de nombres del padrón lo requiere. No se modificó nada.'; END IF;
  IF to_regclass('public.customer_email_jobs') IS NULL OR to_regclass('public.stop_evidence') IS NULL OR to_regprocedure('public.can_view_route_row(uuid,uuid,uuid)') IS NULL OR to_regprocedure('public.auth_has_perm(text)') IS NULL THEN
    RAISE EXCEPTION 'DEPENDENCIA_FALTANTE: tablas o funciones base de entregas. No se modificó nada.'; END IF;
END $guard$;

-- El nuevo circuito queda apagado. La autorización de publicación no autoriza envíos reales.
alter table public.notification_settings add column departure_notice_enabled boolean not null default false;
alter table public.notification_settings add column departure_notice_active_since timestamptz;

-- ---------- 1) PADRÓN: claves alternativas (DNI y NOMBRE exacto) ----------
-- Normalización IDÉNTICA a Normalizer.name del constructor: sin acentos, MAYÚSCULAS, solo A-Z0-9 separados por un espacio.
create or replace function public._okd_norm_name(s text) returns text language sql immutable set search_path = public as $$
  select btrim(regexp_replace(upper(translate(coalesce(s, ''),
    'áàäâãåÁÀÄÂÃÅéèëêÉÈËÊíìïîÍÌÏÎóòöôõÓÒÖÔÕúùüûÚÙÜÛñÑçÇ', 'aaaaaaAAAAAAeeeeEEEEiiiiIIIIoooooOOOOOuuuuUUUUnNcC')), '[^A-Z0-9]+', ' ', 'g')) $$;
create table public.client_email_aliases (
  key_type text not null check (key_type in ('DNI','NOMBRE')),
  key_value text not null check ((key_type = 'DNI' and key_value ~ '^[0-9]{7,8}$') or (key_type = 'NOMBRE' and key_value ~ '^[A-Z0-9]+( [A-Z0-9]+)+$')),
  email text not null check (public.is_valid_email(email)), client_name text,
  source text not null default 'PADRON' check (source in ('PADRON','MANUAL')), import_id bigint, updated_at timestamptz not null default now(), updated_by uuid,
  primary key (key_type, key_value));
create table public.client_padron_imports (
  id bigint generated always as identity primary key, at timestamptz not null default now(), by_user uuid not null, file_name text,
  counts jsonb not null, rejected jsonb not null default '[]');

-- correo del padrón para una parada: CUIT (V4.23, manuales incluidos) → DNI → NOMBRE exacto (clave del constructor o nombre del cliente)
create or replace function public._client_email_for(p_client_key text, p_client_name text) returns text language sql stable security definer set search_path = public as $$
  select coalesce(
    (select email from public.client_emails where cuit = p_client_key),
    (select email from public.client_email_aliases where key_type = 'DNI' and key_value = p_client_key and p_client_key ~ '^[0-9]{7,8}$'),
    (select email from public.client_email_aliases where key_type = 'NOMBRE' and key_value = public._okd_norm_name(p_client_key)),
    (select email from public.client_email_aliases where key_type = 'NOMBRE' and key_value = public._okd_norm_name(p_client_name))) $$;

-- sugerencia durante la entrega (la de V4.23 no se toca): mismo control de acceso (_my_route) y mismo orden: el correo de la hoja manda
create or replace function public.delivery_email_suggestion2(p_stop uuid) returns text language plpgsql stable security definer set search_path = public as $$
declare st public.route_stops; r public.routes;
begin
  select * into st from public.route_stops where id = p_stop; if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  r := public._my_route(st.route_id);
  if coalesce(st.stop_type, 'PEDIDO') <> 'PEDIDO' then return null; end if;
  return coalesce(nullif(trim(st.customer_email), ''), public._client_email_for(st.client_key, st.client_name));
end; $$;

-- importación del padrón (Administrador General ACTIVO). El servidor RE-VALIDA cada fila; modo CONSERVAR: nunca pisa un correo existente
-- (manuales ni importados). Un mismo NOMBRE o DNI que llegue con correos distintos se considera AMBIGUO y no se asocia.
create or replace function public.client_padron_import(p jsonb, p_apply boolean) returns jsonb language plpgsql security definer set search_path = public as $$
declare x jsonb; t text; k text; e text; n text; ins int := 0; kept int := 0; rej jsonb := '[]'; amb text[]; imp bigint; c jsonb; seen text[]:='{}';
begin
  if not public._is_general_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if jsonb_typeof(p->'rows') <> 'array' then raise exception 'ROWS_REQUIRED' using errcode = '22023'; end if;
  -- claves que llegan con más de un correo distinto: ambiguas
  select coalesce(array_agg(tk), '{}') into amb from (
    select upper(r->>'tipo') || '|' || (case when upper(r->>'tipo') = 'NOMBRE' then public._okd_norm_name(r->>'clave') else regexp_replace(coalesce(r->>'clave',''),'\D','','g') end) tk
      from jsonb_array_elements(p->'rows') r group by 1 having count(distinct lower(trim(r->>'email'))) > 1) a;
  if p_apply then insert into public.client_padron_imports(by_user, file_name, counts) values (auth.uid(), p->>'file_name', '{}') returning id into imp; end if;
  for x in select * from jsonb_array_elements(p->'rows') loop
    t := upper(coalesce(x->>'tipo', '')); e := lower(trim(coalesce(x->>'email', ''))); n := nullif(trim(coalesce(x->>'nombre', '')), '');
    k := case when t = 'NOMBRE' then public._okd_norm_name(x->>'clave') else regexp_replace(coalesce(x->>'clave', ''), '\D', '', 'g') end;
    if not public.is_valid_email(e) then rej := rej || jsonb_build_object('fila', x->'fila', 'motivo', 'correo inválido'); continue; end if;
    if (t || '|' || k) = any(amb) then rej := rej || jsonb_build_object('fila', x->'fila', 'motivo', 'clave con correos distintos (ambigua)'); continue; end if;
    if (t||'|'||k)=any(seen) then kept:=kept+1;continue;end if;seen:=seen||(t||'|'||k);
    if t = 'CUIT' then
      if not public._cuit_valid(k) then rej := rej || jsonb_build_object('fila', x->'fila', 'motivo', 'CUIT/CUIL inválido'); continue; end if;
      if exists (select 1 from public.client_emails where cuit = k) then kept := kept + 1; continue; end if;
      if p_apply then insert into public.client_emails(cuit, client_name, email, source, updated_by) values (k, n, e, 'EXCEL', auth.uid()); end if; ins := ins + 1;
    elsif t = 'DNI' or t = 'NOMBRE' then
      if (t = 'DNI' and k !~ '^[0-9]{7,8}$') or (t = 'NOMBRE' and k !~ '^[A-Z0-9]+( [A-Z0-9]+)+$') then rej := rej || jsonb_build_object('fila', x->'fila', 'motivo', t || ' con formato inválido'); continue; end if;
      if exists (select 1 from public.client_email_aliases where key_type = t and key_value = k) then kept := kept + 1; continue; end if;
      if p_apply then insert into public.client_email_aliases(key_type, key_value, email, client_name, import_id, updated_by) values (t, k, e, n, imp, auth.uid()); end if; ins := ins + 1;
    else rej := rej || jsonb_build_object('fila', x->'fila', 'motivo', 'tipo de clave desconocido'); end if;
  end loop;
  c := jsonb_build_object('nuevos', ins, 'conservados_existentes', kept, 'rechazados', jsonb_array_length(rej));
  if p_apply then update public.client_padron_imports set counts = c, rejected = rej where id = imp;
    insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'CLIENT_PADRON_IMPORT', 'client_padron_imports', imp::text, c); end if;
  return c || jsonb_build_object('rechazos', rej, 'aplicado', p_apply);
end; $$;

-- ---------- 2) «TU PEDIDO ESTÁ EN CAMINO»: al confirmarse la SALIDA REAL (started_at), para cada cliente/parada pendiente con correo y todos sus pedidos ----------
-- Reutiliza la cola existente (customer_email_jobs) y la MISMA clave idempotente que el aviso de próxima parada (ruta|parada|ON_THE_WAY):
-- como máximo UN aviso por cliente/parada y hoja, incluyendo todos sus pedidos. Solo en la transición (no reenvía hojas ya iniciadas). Sin correo → no se encola.
create or replace function public.trg_route_departure_notice() returns trigger language plpgsql security definer set search_path = public as $$
declare s public.route_stops; e text;
begin
  if old.started_at is null and new.started_at is not null and exists(select 1 from public.notification_settings where id='DEFAULT' and departure_notice_enabled and on_the_way_enabled and departure_notice_active_since is not null and new.started_at>=departure_notice_active_since) then
    for s in select * from public.route_stops where route_id = new.id and outcome = 'PENDIENTE' and coalesce(stop_type, 'PEDIDO') = 'PEDIDO' loop
      e := lower(trim(coalesce(nullif(trim(s.customer_email), ''), public._client_email_for(s.client_key, s.client_name), '')));
      if public.is_valid_email(e) then
        insert into public.customer_email_jobs(route_id, stop_id, kind, recipient, idempotency_key)
        values (new.id, s.id, 'ON_THE_WAY', e, new.id || '|' || s.id || '|ON_THE_WAY') on conflict (idempotency_key) do nothing;
      end if;
    end loop;
  end if;
  return new;
end; $$;
create trigger routes_zz_departure_notice after update of started_at on public.routes for each row execute function public.trg_route_departure_notice();

-- ---------- 3) BUSCAR ENTREGA: por pedido web, factura/NDP (snapshot publicado) o número de hoja; MISMA visibilidad que las hojas ----------
create or replace function public.search_deliveries(p_query text) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me public.profiles; q text := btrim(coalesce(p_query, '')); dg text; qpv text; qnum text; sig boolean; out jsonb := '[]'; rec record;
begin
  select * into me from public.profiles where id = auth.uid() and status = 'ACTIVO';
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  dg := regexp_replace(q, '\D', '', 'g');
  if length(dg) < 3 and q !~ '^[0-9]{2}-[0-9]{6}$' then raise exception 'QUERY_TOO_SHORT: ingresá al menos 3 dígitos' using errcode = '22023'; end if;
  qnum := ltrim(case when q ~ '-' then split_part(regexp_replace(q, '[^0-9-]', '', 'g'), '-', 2) else dg end, '0');
  qpv := case when q ~ '-' then ltrim(split_part(regexp_replace(q, '[^0-9-]', '', 'g'), '-', 1), '0') end;
  sig := false; -- Se verifica por hoja con la MISMA protección de las políticas RLS vigentes.
  for rec in
    select r.id rid, r.number, r.operational_status, r.published_at, r.started_at, r.completed_at, r.carrier_id, c.name carrier_name, rp.full_name responsable_name,
           s.id sid, s.client_name, s.address, s.order_numbers, s.outcome, s.outcome_note, s.arrived_at, s.stop_type,
           (select x->'r'->>'fecha' from jsonb_array_elements(coalesce(r.sheet_snapshot->'pdf_model'->'data', '[]')) x where x->'r' ? 'fecha' limit 1) sheet_date,
           (select string_agg(distinct d, ' · ') from jsonb_array_elements(coalesce(r.sheet_snapshot->'pdf_model'->'data', '[]')) x, lateral (values (x->'r'->>'mainDoc'), (x->'r'->>'shipDoc')) v(d)
              where d is not null and d <> '' and (x->'r'->>'mainOrder' = any(s.order_numbers) or x->'r'->>'shipOrder' = any(s.order_numbers))) docs,
           ev.receiver_name, ev.receiver_cuil, ev.created_at received_at, (ev.stop_id is not null) has_signature, dr.receipt_number, dr.generated_at receipt_at
      from public.route_stops s join public.routes r on r.id = s.route_id left join public.carriers c on c.id = r.carrier_id left join public.profiles rp on rp.id = r.responsable_id
      left join public.stop_evidence ev on ev.stop_id = s.id left join public.delivery_receipts dr on dr.stop_id = s.id
     where r.operational_status <> 'BORRADOR' and coalesce(s.stop_type, 'PEDIDO') = 'PEDIDO'
       and (public._is_general_admin() or public.can_view_route_row(r.id, r.published_by, r.responsable_id))   -- SOLO hojas que el usuario puede ver (equipo / propias / todas)
       and ( dg = any(s.order_numbers) or r.number = q
          or exists (select 1 from jsonb_array_elements(coalesce(r.sheet_snapshot->'pdf_model'->'data', '[]')) x, lateral (values (x->'r'->>'mainDoc', x->'r'->>'mainOrder'), (x->'r'->>'shipDoc', x->'r'->>'shipOrder')) v(d, o)
                      where o = any(s.order_numbers) and d is not null and qnum <> ''
                        and ltrim(split_part(regexp_replace(d, '[^0-9-]', '', 'g'), '-', 2), '0') = qnum
                        and (qpv is null or ltrim(split_part(regexp_replace(d, '[^0-9-]', '', 'g'), '-', 1), '0') = qpv)) )
     order by r.published_at desc limit 30
  loop
    sig:=okd_delivery_security.may_read(rec.rid) and (public._is_general_admin() or public.can_view_route(rec.rid));
    out := out || jsonb_build_object('route_id', rec.rid, 'route_number', rec.number, 'route_status', rec.operational_status, 'carrier', coalesce(rec.carrier_name, rec.carrier_id), 'responsable', rec.responsable_name,
      'published_at', rec.published_at, 'started_at', rec.started_at, 'completed_at', rec.completed_at, 'sheet_date', rec.sheet_date,
      'stop_id', rec.sid, 'client_name', rec.client_name, 'address', rec.address, 'order_numbers', to_jsonb(rec.order_numbers), 'docs', rec.docs,
      'outcome', rec.outcome, 'outcome_note', rec.outcome_note, 'arrived_at', rec.arrived_at, 'received_at', rec.received_at,
      'has_receipt', rec.receipt_number is not null, 'signatures_visible', sig,
      -- datos personales y constancia SOLO con signatures.view (los demás ven el estado, no quién firmó)
      'receiver_name', case when sig then rec.receiver_name end, 'receiver_cuil', case when sig then rec.receiver_cuil end,
      'has_signature', case when sig then rec.has_signature end, 'receipt_number', case when sig then rec.receipt_number end, 'receipt_at', case when sig then rec.receipt_at end);
  end loop;
  return out;
end; $$;

-- ---------- 4) Privilegios ----------
alter table public.client_email_aliases enable row level security; alter table public.client_padron_imports enable row level security;
do $$ declare t text; f text; begin
  foreach t in array array['client_email_aliases','client_padron_imports'] loop execute format('revoke all on table public.%I from public, anon, authenticated', t); end loop;
  foreach f in array array['delivery_email_suggestion2(uuid)','client_padron_import(jsonb,boolean)','search_deliveries(text)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon'; execute 'grant execute on function public.' || f || ' to authenticated'; end loop;
  foreach f in array array['_client_email_for(text,text)','trg_route_departure_notice()'] loop execute 'revoke all on function public.' || f || ' from public, anon, authenticated'; end loop;
end $$;
DO $post$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'routes_zz_departure_notice') THEN RAISE EXCEPTION 'HUELLA_FINAL_INESPERADA'; END IF;
END $post$;
COMMIT;

;
CREATE OR REPLACE FUNCTION public.finalize_route(p_route uuid, p_km_end numeric DEFAULT NULL::numeric)
 RETURNS routes
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end; $function$
;
;
CREATE OR REPLACE FUNCTION public.review_route_approval(p_request uuid, p_decision text, p_note text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end; $function$
;
;
CREATE OR REPLACE FUNCTION public.trg_notify_driver_approved()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if new.status = 'APPROVED' and old.status = 'PENDING' then
    insert into public.notifications(user_id, route_id, route_version, type, title, body)
    select r.responsable_id, r.id, new.route_version, 'INTERNAL_ROUTE_APPROVED', 'HOJA APROBADA · ' || r.number, 'Tu hoja fue aprobada.' from public.routes r where r.id = new.route_id on conflict do nothing;
  end if;
  return new;
end; $function$
;
;
-- Pruebas AUTÓNOMAS de la corrección INFORME_REVISION_CLAUDE.md (G2, traslado interno, TAREA, reservas, snapshot GPS, paradas del chofer).
-- Crea sus propios usuarios, transportistas y ubicaciones; no depende de los fixtures históricos.
-- Correr: SQL_TESTS="g2_revision_test" SKIP_CONCURRENCY=1 bash tests/sql/run.sh

create schema if not exists tst;
create table if not exists tst.results (id serial, name text, ok boolean, detail text);
grant usage on schema tst to public; grant insert, select on tst.results to public; grant usage on sequence tst.results_id_seq to public;
create or replace function tst.res(n text, ok boolean, d text default '') returns void language sql as $$ insert into tst.results(name, ok, detail) values (n, ok, d) $$;
create or replace function tst.expect(n text, q text, pat text) returns void language plpgsql as $$
begin execute q; perform tst.res(n, false, 'no falló'); exception when others then perform tst.res(n, sqlerrm like pat, sqlerrm); end $$;
create or replace function tst.as_user_iat(p_uid text, p_role text, p_iat bigint) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid, ''), true);
  perform set_config('request.jwt.claim.role', coalesce(p_role, ''), true);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', p_role, 'iat', p_iat)::text, true);
end $$;
create or replace function tst.u(p uuid) returns void language sql as $$ select tst.as_user_iat(p::text, 'authenticated', extract(epoch from now())::bigint + 60) $$;
grant execute on all functions in schema tst to public;







insert into auth.users(id, email) values ('e0000000-0000-0000-0000-00000000000a','g2admin@t'),('e0000000-0000-0000-0000-000000000005','g2sup@t'),('e0000000-0000-0000-0000-000000000006','g2op@t'),('e0000000-0000-0000-0000-000000000007','g2chofer@t'),('e0000000-0000-0000-0000-000000000008','g2ext@t'),('e0000000-0000-0000-0000-000000000009','g2otro@t') on conflict do nothing;
select set_config('okd.sync', 'on', false);
insert into public.profiles(id, full_name, email, role, status) values
  ('e0000000-0000-0000-0000-00000000000a','Admin G2','g2admin@t','ADMIN','ACTIVO'), ('e0000000-0000-0000-0000-000000000005','Superior G2','g2sup@t','SUPERVISOR_DESPACHO','ACTIVO'), ('e0000000-0000-0000-0000-000000000006','Operario G2','g2op@t','OPERARIO_DEPOSITO','ACTIVO'),
  ('e0000000-0000-0000-0000-000000000007','Chofer Interno G2','g2chofer@t','TRANSPORTISTA_INTERNO','ACTIVO'), ('e0000000-0000-0000-0000-000000000008','Externo G2','g2ext@t','SOLO_LECTURA','ACTIVO'), ('e0000000-0000-0000-0000-000000000009','Otro operador','g2otro@t','SUPERVISOR_DESPACHO','ACTIVO')
on conflict (id) do nothing;
-- un TRANSPORTISTA necesita su transportista externo antes de tener el rol
insert into public.user_carriers(user_id, carrier_id) select 'e0000000-0000-0000-0000-000000000008', id from public.carriers where kind = 'EXTERNO' and active order by id limit 1 on conflict do nothing;
update public.profiles set role = 'TRANSPORTISTA' where id = 'e0000000-0000-0000-0000-000000000008';
select set_config('okd.sync', '', false);
insert into public.vehicles(id, name, plate, current_km, last_service_km) values ('f0000000-0000-0000-0000-000000000001', 'KANGOO G2', 'G2TEST1', 1000, 1000) on conflict do nothing;
create temp table t_ext as select carrier_id from public.user_carriers where user_id = 'e0000000-0000-0000-0000-000000000008' limit 1; grant select on t_ext to public;

-- ===== G2: Admin crea dos ubicaciones; Superior/Operario LEEN pero NO modifican =====
begin; select tst.u('e0000000-0000-0000-0000-00000000000a'); set local role authenticated;
select public.upsert_internal_location('{"location_key":"MONTECASEROS","name":"Montecaseros - casa central","address":"Montecaseros 1234, Mendoza","lat":-32.8900,"lon":-68.8400,"radius_m":200}');
select public.upsert_internal_location('{"location_key":"SAN_JUAN","name":"Sucursal San Juan","address":"San Juan 500, Mendoza","lat":-32.8950,"lon":-68.8450,"radius_m":150}');
select tst.expect('G2-05 Nombre duplicado entre ubicaciones activas rechazado', $q$ select public.upsert_internal_location('{"location_key":"OTRA","name":"montecaseros - CASA central","lat":-32.9,"lon":-68.8}') $q$, 'DUPLICATE_LOCATION_NAME%');
commit;
begin; select tst.u('e0000000-0000-0000-0000-000000000005'); set local role authenticated;
select tst.res('G2-01 Superior Despacho LEE las ubicaciones G2 (antes recibía lista vacía)', (select count(*) from public.internal_locations where location_key in ('MONTECASEROS','SAN_JUAN')) = 2, '');
select tst.expect('G2-02 Superior NO modifica G2 (RPC)', $q$ select public.upsert_internal_location('{"location_key":"MONTECASEROS","name":"X","lat":0,"lon":0}') $q$, 'FORBIDDEN%');
select tst.expect('G2-03 Superior NO modifica G2 (UPDATE directo)', $q$ update public.internal_locations set lat = 0 where location_key = 'MONTECASEROS' $q$, '%');
commit;
select tst.res('G2-03b El UPDATE directo no cambió nada', (select lat from public.internal_locations where location_key = 'MONTECASEROS') = -32.89, '');
begin; select tst.u('e0000000-0000-0000-0000-000000000006'); set local role authenticated;
select tst.res('G2-04 Operario Depósito LEE G2', (select count(*) from public.internal_locations) >= 2, '');
commit;
begin; select tst.u('e0000000-0000-0000-0000-000000000007'); set local role authenticated;
select tst.res('G2-04b Transportista Interno NO lee G2 (no administra ubicaciones maestras)', not exists (select 1 from public.internal_locations), '');
commit;

-- ===== Reserva atómica: el 2º pedido está en otra hoja → ninguno queda reservado =====
begin; select tst.u('e0000000-0000-0000-0000-000000000009'); set local role authenticated; select public.reserve_orders('G2-OTRA', array['70002']); commit;
begin; select tst.u('e0000000-0000-0000-0000-000000000005'); set local role authenticated;
select tst.expect('RES-01 Reserva en UNA llamada con un pedido ya tomado → error', $q$ select public.reserve_orders('G2-HOJA', array['70001','70002','70003']) $q$, 'PEDIDO_YA_EN_OTRA_HOJA%');
commit;
select tst.res('RES-02 Ningún pedido quedó reservado a medias (70001/70003 libres)', not exists (select 1 from public.order_reservations where order_id in ('70001','70003')), '');

-- ===== Montecaseros + 3 pedidos (uno con envío) = UNA parada =====
begin; select tst.u('e0000000-0000-0000-0000-000000000005'); set local role authenticated;
select public.reserve_orders('G2-HOJA', array['71001','71002','71003','71004']);
create temp table t_r as select * from public.publish_route(jsonb_build_object('sheet_key','G2-HOJA','carrier_id','INTERNO','responsable_id','e0000000-0000-0000-0000-000000000007','vehicle_id','f0000000-0000-0000-0000-000000000001','rules_version',1,'routing_rules_version',1,'stops',jsonb_build_array(
  jsonb_build_object('client_name','lo que diga el cliente','address','domicilio cambiado a mano','stop_type','UBICACION_INTERNA','internal_location_key','MONTECASEROS',
    'order_numbers',jsonb_build_array('71001','71002','71003','71004'),'instructions','Dejar cajas vacías','merchandise_amount',99999,'customer_email','cliente@x.com','ready',true),
  jsonb_build_object('client_name','Buscar bolsas','address','Las Heras 10, Mendoza','stop_type','TAREA','instructions','Retirar 20 bolsas','contact_name','Kiosco','contact_phone','261555','ready',true))));
grant select on t_r to public;
commit;
create temp table t_s as select * from public.route_stops where route_id = (select id from t_r); grant select on t_s to public;
select tst.res('LOC-01 Montecaseros + pedidos → UNA sola route_stop UBICACION_INTERNA con todos los order_numbers',
  (select count(*) from t_s where stop_type = 'UBICACION_INTERNA') = 1 and (select order_numbers from t_s where stop_type = 'UBICACION_INTERNA') = array['71001','71002','71003','71004'], (select string_agg(stop_type, ',') from t_s));
select tst.res('LOC-02 Nombre y domicilio vienen de G2 (no editables en la hoja); clave G2 explícita', client_name = 'Montecaseros - casa central' and address = 'Montecaseros 1234, Mendoza'
  and internal_location_key = 'MONTECASEROS' and client_key = 'MONTECASEROS', client_name || ' · ' || address) from t_s where stop_type = 'UBICACION_INTERNA';
select tst.res('LOC-03 Observación publicada en instructions', instructions = 'Dejar cajas vacías', coalesce(instructions, 'NULL')) from t_s where stop_type = 'UBICACION_INTERNA';
select tst.res('LOC-04 Traslado interno NO comercial: montos 0, sin email de cliente, sin cobranza', merchandise_amount = 0 and shipping_fee = 0 and customer_email is null and task = 'ENTREGA' and expected_amount is null, '') from t_s where stop_type = 'UBICACION_INTERNA';
select tst.res('LOC-05 Snapshot GPS guardado al publicar (lat/lon/radio/versión del punto)', expected_lat = -32.89 and expected_lon = -68.84 and expected_radius_m = 200 and internal_location_updated_at is not null, '') from t_s where stop_type = 'UBICACION_INTERNA';
select tst.res('RES-03 publish_route marcó PUBLICADA solo las reservas de las paradas', (select count(*) from public.order_reservations where route_id = (select id from t_r) and status = 'PUBLICADA') = 4, '');
select tst.res('TAR-01 TAREA publicada con instrucciones/contacto, sin montos ni email', instructions = 'Retirar 20 bolsas' and contact_name = 'Kiosco' and contact_phone = '261555' and merchandise_amount = 0 and customer_email is null and internal_location_key is null, '') from t_s where stop_type = 'TAREA';

-- ===== Anti-duplicado y reglas de servidor =====
begin; select tst.u('e0000000-0000-0000-0000-000000000005'); set local role authenticated;
select tst.expect('DUP-01 Dos paradas de la MISMA ubicación interna en una hoja → rechazado', $q$ select public.publish_route('{"sheet_key":"G2-DUP","carrier_id":"INTERNO","vehicle_id":"f0000000-0000-0000-0000-000000000001","rules_version":1,"routing_rules_version":1,"responsable_id":"e0000000-0000-0000-0000-000000000007","stops":[
  {"client_name":"a","stop_type":"UBICACION_INTERNA","internal_location_key":"MONTECASEROS","order_numbers":[],"ready":true},{"client_name":"b","stop_type":"UBICACION_INTERNA","internal_location_key":"MONTECASEROS","order_numbers":[],"ready":true}]}') $q$, '%duplicate key%');
select tst.expect('EXT-01 TAREA con transportista EXTERNO → rechazado en el servidor', format($q$ select public.publish_route('{"sheet_key":"G2-EXT","carrier_id":"%s","responsable_id":"e0000000-0000-0000-0000-000000000008","rules_version":1,"routing_rules_version":1,"stops":[{"client_name":"x","stop_type":"TAREA","order_numbers":[],"ready":true}]}') $q$, (select carrier_id from t_ext)), 'STOP_TYPE_REQUIRES_INTERNAL%');
select tst.expect('EXT-02 UBICACION_INTERNA con transportista EXTERNO → rechazado', format($q$ select public.publish_route('{"sheet_key":"G2-EXT2","carrier_id":"%s","responsable_id":"e0000000-0000-0000-0000-000000000008","rules_version":1,"routing_rules_version":1,"stops":[{"client_name":"x","stop_type":"UBICACION_INTERNA","internal_location_key":"SAN_JUAN","order_numbers":[],"ready":true}]}') $q$, (select carrier_id from t_ext)), 'STOP_TYPE_REQUIRES_INTERNAL%');
select tst.expect('LOC-06 UBICACION_INTERNA sin clave G2 → rechazado', $q$ select public.publish_route('{"sheet_key":"G2-NOKEY","carrier_id":"INTERNO","vehicle_id":"f0000000-0000-0000-0000-000000000001","rules_version":1,"routing_rules_version":1,"responsable_id":"e0000000-0000-0000-0000-000000000007","stops":[{"client_name":"Montecaseros","stop_type":"UBICACION_INTERNA","order_numbers":[],"ready":true}]}') $q$, 'INTERNAL_LOCATION_REQUIRED%');
-- Reserva huérfana (del error anterior a esta corrección): publicar debe rechazarla, no consumirla en silencio
select public.reserve_orders('G2-ORF', array['72001','72099']);
select tst.expect('RES-04 Reserva huérfana (72099 reservado y no está en la hoja) → publicación rechazada', $q$ select public.publish_route('{"sheet_key":"G2-ORF","carrier_id":"INTERNO","vehicle_id":"f0000000-0000-0000-0000-000000000001","rules_version":1,"routing_rules_version":1,"responsable_id":"e0000000-0000-0000-0000-000000000007","stops":[{"client_name":"x","stop_type":"UBICACION_INTERNA","internal_location_key":"SAN_JUAN","order_numbers":["72001"],"ready":true}]}') $q$, 'ORPHAN_RESERVATIONS%72099%');
commit;
select tst.res('RES-05 La reserva huérfana NO quedó PUBLICADA', not exists (select 1 from public.order_reservations where order_id = '72099' and status = 'PUBLICADA'), '');
select tst.res('ASOC-01 Una parada que NO es ubicación interna no se asocia a G2 por nombre/domicilio', (select internal_location_key from t_s where stop_type = 'TAREA') is null, '');

-- ===== Snapshot GPS: editar/desactivar G2 después NO cambia la hoja publicada =====
begin; select tst.u('e0000000-0000-0000-0000-00000000000a'); set local role authenticated;
select public.upsert_internal_location('{"location_key":"MONTECASEROS","name":"Montecaseros - casa central","address":"Montecaseros 1234, Mendoza","lat":-33.5,"lon":-69.5,"radius_m":50,"active":false}');
commit;
begin; select tst.u('e0000000-0000-0000-0000-000000000007'); set local role authenticated;
select public.start_route((select id from t_r), 1000);
select public.arrive_stop((select id from t_s where stop_type = 'UBICACION_INTERNA'), '{"lat":-32.8901,"lon":-68.8401,"accuracy":8}', 'g2-arr-1');
commit;
select tst.res('GPS-01 Llegada validada contra el SNAPSHOT (punto original, radio 200) aunque G2 se movió y desactivó; guarda real + esperado + radio + distancia + fuente',
  (arrive_location->>'validation_source') = 'INTERNAL_SNAPSHOT' and (arrive_location->>'expected_lat')::float8 = -32.89 and (arrive_location->>'radius_m')::int = 200
  and (arrive_location->>'distance_m')::numeric < 50 and arrive_location->>'outside_m' is null and arrive_location ? 'lat' and (arrive_location->>'validation_key') = 'MONTECASEROS', arrive_location::text)
  from public.route_stops where id = (select id from t_s where stop_type = 'UBICACION_INTERNA');

-- ===== Cierre por tipo: traslado y TAREA no son entrega comercial =====
begin; select tst.u('e0000000-0000-0000-0000-000000000007'); set local role authenticated;
select tst.expect('REC-01 Recepción interna con pedidos SIN firma/receptor → rechazada', format($q$ select public.set_stop_outcome(%L, 'ENTREGADO', null, null, 'g2-out-0', '{"location":{"lat":-32.8901,"lon":-68.8401}}') $q$,
  (select id from t_s where stop_type = 'UBICACION_INTERNA')), 'EVIDENCE_REQUIRED%');
select public.set_stop_outcome((select id from t_s where stop_type = 'UBICACION_INTERNA'), 'ENTREGADO', null, null, 'g2-out-1',
  '{"evidence":{"receiver_name":"Encargado sucursal","signature_png_b64":"iVBORw0KGgo=","email":"cliente@x.com"},"location":{"lat":-32.8901,"lon":-68.8401}}');
select public.set_stop_outcome((select id from t_s where stop_type = 'TAREA'), 'ENTREGADO', 'Bolsas retiradas', null, 'g2-out-2', '{"location":{"lat":-32.88,"lon":-68.83}}');
commit;
select tst.res('LOC-07 Traslado interno cerrado: sin email al cliente, sin Recibido Conforme, sin cobranza, sin perfil de identidad',
  not exists (select 1 from public.customer_email_jobs where stop_id = (select id from t_s where stop_type = 'UBICACION_INTERNA'))
  and not exists (select 1 from public.delivery_receipts where stop_id = (select id from t_s where stop_type = 'UBICACION_INTERNA'))
  and (select collection_status from public.route_stops where id = (select id from t_s where stop_type = 'UBICACION_INTERNA')) is distinct from 'COBRADO'
  and (select receiver_email from public.stop_evidence where stop_id = (select id from t_s where stop_type = 'UBICACION_INTERNA')) is null, '');
select tst.res('REC-02 Evidencia de RECEPCIÓN INTERNA (no entrega cliente): receptor + firma guardados con su tipo propio',
  evidence_kind = 'RECEPCION_INTERNA' and receiver_name = 'Encargado sucursal' and signature_sha256 is not null and created_by = 'e0000000-0000-0000-0000-000000000007' and receiver_email is null, evidence_kind)
  from public.stop_evidence where stop_id = (select id from t_s where stop_type = 'UBICACION_INTERNA');
select tst.res('REC-03 Auditoría "INTERNAL_TRANSFER_RECEIVED": sucursal, pedidos, quién recibió, quién trasladó, hoja, GPS real y esperado',
  after->>'internal_location_key' = 'MONTECASEROS' and after->'order_numbers' = '["71001","71002","71003","71004"]'::jsonb and after->>'receiver_name' = 'Encargado sucursal'
  and after->>'transported_by' = 'e0000000-0000-0000-0000-000000000007' and after->>'route_number' is not null and (after->'gps'->>'expected_lat')::float8 = -32.89 and (after->'gps') ? 'lat', after::text)
  from public.audit_log where action = 'INTERNAL_TRANSFER_RECEIVED' and target_id = (select id::text from t_s where stop_type = 'UBICACION_INTERNA');
select tst.res('REC-04 La TAREA sin firma no genera evidencia de entrega', not exists (select 1 from public.stop_evidence where stop_id = (select id from t_s where stop_type = 'TAREA')), '');
select tst.res('LOC-08 Trazabilidad: los pedidos quedan asociados a la parada de traslado de esa hoja', (select order_numbers from public.route_stops where id = (select id from t_s where stop_type = 'UBICACION_INTERNA')) = array['71001','71002','71003','71004']
  and (select count(*) from public.order_reservations where route_id = (select id from t_r) and order_id in ('71001','71002','71003','71004')) = 4, '');
select tst.res('TAR-02 TAREA REALIZADA sin firma ni receptor (GPS + observación); sin email, sin comprobante', outcome = 'ENTREGADO' and outcome_note = 'Bolsas retiradas' and finish_location ? 'lat'
  and not exists (select 1 from public.customer_email_jobs where stop_id = s.id) and not exists (select 1 from public.delivery_receipts where stop_id = s.id), outcome) from public.route_stops s where s.id = (select id from t_s where stop_type = 'TAREA');

-- ===== Parada dinámica agregada por el Transportista Interno =====
create temp table t_v as select version from public.routes where id = (select id from t_r); grant select on t_v to public;
begin; select tst.u('e0000000-0000-0000-0000-000000000007'); set local role authenticated;
select public.add_internal_stop((select id from t_r), '{"client_name":"Banco Nación","address":"San Martín 1100, Mendoza","instructions":"Depositar efectivo","contact_name":"Caja","contact_phone":"261444","order_numbers":["99999"]}', (select version from t_v), 'g2-add-1');
commit;
select tst.res('DRV-01 Parada del chofer: provenance DRIVER, TAREA, usuario y fecha, instrucciones/contacto, al final del recorrido, sin pedidos ni G2',
  provenance = 'DRIVER' and stop_type = 'TAREA' and added_by = 'e0000000-0000-0000-0000-000000000007' and added_at is not null and instructions = 'Depositar efectivo' and contact_name = 'Caja'
  and coalesce(array_length(order_numbers, 1), 0) = 0 and internal_location_key is null and expected_lat is null
  and sequence_number = (select max(sequence_number) from public.route_stops where route_id = (select id from t_r)), stop_type || ' ' || coalesce(internal_location_key, '-'))
  from public.route_stops where route_id = (select id from t_r) and provenance = 'DRIVER';
select tst.res('DRV-02 Versionada y auditada', (select version from public.routes where id = (select id from t_r)) = (select version from t_v) + 1
  and exists (select 1 from public.route_change_events where client_op_id = 'g2-add-1' and event_type = 'INTERNAL_STOP_ADDED' and user_id = 'e0000000-0000-0000-0000-000000000007')
  and exists (select 1 from public.audit_log where action = 'INTERNAL_STOP_ADDED' and actor_id = 'e0000000-0000-0000-0000-000000000007'), '');
begin; select tst.u('e0000000-0000-0000-0000-000000000007'); set local role authenticated;
select tst.expect('DRV-03 El chofer NO reordena paradas ya resueltas', format($q$ select public.reorder_internal_stops(%L, array[%L]::uuid[], %s, 'g2-re-1') $q$, (select id from t_r),
  (select id from t_s where stop_type = 'UBICACION_INTERNA'), (select version from public.routes where id = (select id from t_r))), 'COMPLETED_STOP_FIXED%');
select tst.expect('DRV-04 El chofer NO edita paradas por UPDATE directo', format($q$ update public.route_stops set address = 'otra', order_numbers = '{}' where id = %L $q$, (select id from t_s where stop_type = 'UBICACION_INTERNA')), '%');
select tst.expect('DRV-05 El chofer NO modifica G2', $q$ select public.upsert_internal_location('{"location_key":"MONTECASEROS","name":"X","lat":0,"lon":0}') $q$, 'FORBIDDEN%');
commit;
select tst.res('DRV-06 La parada administrativa quedó intacta (domicilio y pedidos)', address = 'Montecaseros 1234, Mendoza' and order_numbers = array['71001','71002','71003','71004'], address) from public.route_stops where id = (select id from t_s where stop_type = 'UBICACION_INTERNA');

-- ===== KPIs: una TAREA no realizada NO cuenta como incidencia de entrega comercial =====
begin; select tst.u('e0000000-0000-0000-0000-00000000000a'); set local role authenticated;
create temp table t_k1 as select (public.dashboard_admin()->'kpis'->>'incidencias')::int k; grant select on t_k1 to public;
commit;
begin; select tst.u('e0000000-0000-0000-0000-000000000007'); set local role authenticated;
select public.set_stop_outcome((select id from public.route_stops where route_id = (select id from t_r) and provenance = 'DRIVER'), 'NO_ENTREGADO', null, 'Banco cerrado', 'g2-out-3', '{"location":{"lat":-32.88,"lon":-68.83}}');
commit;
begin; select tst.u('e0000000-0000-0000-0000-00000000000a'); set local role authenticated;
select tst.res('KPI-01 TAREA no realizada NO suma a las incidencias de entrega del dashboard (con el criterio anterior sí habría sumado 1)',
  (public.dashboard_admin()->'kpis'->>'incidencias')::int = (select k from t_k1)
  and (select count(*) from public.route_stops s where s.route_id = (select id from t_r) and s.outcome in ('NO_ENTREGADO','REPROGRAMAR','ENTREGA_PARCIAL')) = 1,
  (select k from t_k1)::text || ' → ' || (public.dashboard_admin()->'kpis'->>'incidencias'));
commit;

-- ===== Web Push: un trabajo por notificación, toma atómica y reintentos =====
select tst.res('PUSH-01 Publicar la hoja generó UN trabajo push para el chofer (NUEVA_HOJA_PUBLICADA)', (select count(*) from public.push_jobs j join public.notifications n on n.id = j.notification_id
  where n.user_id = 'e0000000-0000-0000-0000-000000000007' and n.type = 'NUEVA_HOJA_PUBLICADA' and n.route_id = (select id from t_r)) = 1, '');
begin; select tst.u('e0000000-0000-0000-0000-00000000000a'); set local role authenticated;
select tst.expect('PUSH-02 Un usuario (ni Admin) NO puede tomar trabajos push', $q$ select * from public.claim_push_jobs(10) $q$, '%permission denied%');
commit;
update public.push_jobs set status = 'SKIPPED';   -- dejar solo los de esta prueba
insert into public.notifications(user_id, route_id, route_version, type, title, body) values ('e0000000-0000-0000-0000-000000000007', (select id from t_r), 7, 'HOJA_CORREGIDA', 'HOJA CORREGIDA', 'prueba push');
begin; set local role service_role;
create temp table t_c1 as select * from public.claim_push_jobs(10);
create temp table t_c2 as select * from public.claim_push_jobs(10);
commit;
select tst.res('PUSH-03 Toma atómica: la 1ª ejecución toma el trabajo, la 2ª no lo vuelve a tomar (sin envío duplicado)', (select count(*) from t_c1) = 1 and (select count(*) from t_c2) = 0
  and (select status from public.push_jobs where id = (select id from t_c1)) = 'SENDING' and (select attempt_count from t_c1) = 1, '');
update public.push_jobs set status = 'ERROR', next_attempt_at = now() - interval '1 minute' where id = (select id from t_c1);
begin; set local role service_role; create temp table t_c3 as select * from public.claim_push_jobs(10); commit;
update public.push_jobs set status = 'ERROR', next_attempt_at = now() + interval '1 hour' where id = (select id from t_c1);
begin; set local role service_role; create temp table t_c4 as select * from public.claim_push_jobs(10); commit;
update public.push_jobs set status = 'ERROR', attempt_count = 5, next_attempt_at = now() - interval '1 minute' where id = (select id from t_c1);
begin; set local role service_role; create temp table t_c5 as select * from public.claim_push_jobs(10); commit;
select tst.res('PUSH-04 Reintento: un ERROR vencido se reintenta; con espera pendiente no; con 5 intentos se abandona', (select count(*) from t_c3) = 1 and (select attempt_count from t_c3) = 2
  and (select count(*) from t_c4) = 0 and (select count(*) from t_c5) = 0, '');
update public.push_jobs set status = 'SENDING', attempt_count = 1, locked_at = now() - interval '11 minutes' where id = (select id from t_c1);
begin; set local role service_role; create temp table t_c6 as select * from public.claim_push_jobs(10); commit;
select tst.res('PUSH-05 Un envío trabado (ejecución caída > 10 min) se recupera', (select count(*) from t_c6) = 1, '');
update public.push_jobs set status = 'SKIPPED';

-- ===== Wording singular/plural de avisos internos =====
insert into public.notifications(user_id, route_id, route_version, type, title, body)
values ('e0000000-0000-0000-0000-000000000007', (select id from t_r), 998, 'HOJA_CORREGIDA', 'HOJA CORREGIDA', 'Hoja singular · 1 entrega');
select tst.res('WORD-SING-01 Aviso interno singular: 1 parada (nunca 1 paradas / 1 entrega)',
  exists (
    select 1 from public.notifications
    where user_id = 'e0000000-0000-0000-0000-000000000007' and route_id = (select id from t_r) and route_version = 998
      and type = 'HOJA_CORREGIDA' and body = 'Hoja singular · 1 parada'
  ),
  coalesce((select body from public.notifications where user_id = 'e0000000-0000-0000-0000-000000000007' and route_id = (select id from t_r) and route_version = 998 and type = 'HOJA_CORREGIDA'), 'SIN AVISO')
);

-- ===== PARCHE: el chofer agrega una UBICACIÓN INTERNA G2 (segunda visita a Montecaseros) =====
select tst.res('WORD-01 Aviso de hoja interna cuenta PARADAS (no entregas)', (select bool_and(body ~ ' paradas$') and bool_and(body !~ 'entregas') and count(*) >= 1 from public.notifications where user_id = 'e0000000-0000-0000-0000-000000000007' and type = 'NUEVA_HOJA_PUBLICADA' and route_id = (select id from t_r)),
  (select string_agg(body, ' | ') from public.notifications where user_id = 'e0000000-0000-0000-0000-000000000007' and type = 'NUEVA_HOJA_PUBLICADA' and route_id = (select id from t_r)));
begin; select tst.u('e0000000-0000-0000-0000-00000000000a'); set local role authenticated;
-- G2 reactivado y movido: el snapshot de la parada nueva debe tomar ESTE punto, y la original conservar el suyo
select public.upsert_internal_location('{"location_key":"MONTECASEROS","name":"Montecaseros - casa central","address":"Montecaseros 1529, Ciudad Mendoza","lat":-32.8000,"lon":-68.8000,"radius_m":120,"active":true}');
commit;
begin; select tst.u('e0000000-0000-0000-0000-000000000007'); set local role authenticated;
select tst.res('DRVLOC-00 El chofer ve las G2 activas para elegir (sin coordenadas)', exists (select 1 from public.driver_internal_locations() where location_key = 'MONTECASEROS' and address = 'Montecaseros 1529, Ciudad Mendoza'), '');
create temp table t_v2 as select version from public.routes where id = (select id from t_r); grant select on t_v2 to public;
select public.add_internal_stop((select id from t_r), '{"id":"5e5e5e5e-0000-0000-0000-000000000001","stop_type":"UBICACION_INTERNA","internal_location_key":"montecaseros","client_name":"lo que sea","address":"otra dirección","instructions":"Retirar documentación","order_numbers":["71001","99999"]}', (select version from t_v2), 'g2-loc-1');
select public.add_internal_stop((select id from t_r), '{"id":"5e5e5e5e-0000-0000-0000-000000000001","stop_type":"UBICACION_INTERNA","internal_location_key":"montecaseros","instructions":"Retirar documentación"}', (select version from t_v2), 'g2-loc-1');
select tst.expect('DRVLOC-06 G2 inexistente o desactivada → rechazada', format($q$ select public.add_internal_stop(%L, '{"stop_type":"UBICACION_INTERNA","internal_location_key":"NO_EXISTE"}', %s, 'g2-loc-x') $q$,
  (select id from t_r), (select version from public.routes where id = (select id from t_r))), 'INTERNAL_LOCATION_INACTIVE%');
commit;
create temp table t_d2 as select * from public.route_stops where id = '5e5e5e5e-0000-0000-0000-000000000001'; grant select on t_d2 to public;
select tst.res('DRVLOC-01 Segunda visita a Montecaseros agregada por el chofer: UBICACION_INTERNA, DRIVER, al final, nombre/domicilio de G2, observación',
  d.internal_location_key = 'MONTECASEROS' and d.client_name = 'Montecaseros - casa central' and d.address = 'Montecaseros 1529, Ciudad Mendoza'
  and d.instructions = 'Retirar documentación' and d.added_by = 'e0000000-0000-0000-0000-000000000007' and d.added_at is not null and d.outcome = 'PENDIENTE'
  and d.sequence_number = (select max(sequence_number) from public.route_stops where route_id = (select id from t_r)), d.client_name || ' · ' || d.address) from t_d2 d;
select tst.res('DRVLOC-02 Snapshot GPS tomado AL AGREGARLA (punto y radio vigentes en G2 en ese momento)', expected_lat = -32.80 and expected_lon = -68.80 and expected_radius_m = 120 and internal_location_updated_at is not null, '') from t_d2;
select tst.res('DRVLOC-03 El chofer NO asocia pedidos ni montos (los ignora el servidor)', coalesce(array_length(order_numbers, 1), 0) = 0 and merchandise_amount = 0 and customer_email is null, coalesce(array_to_string(order_numbers, ','), '')) from t_d2;
select tst.res('DRVLOC-04 Mismo client_op_id dos veces → UNA sola parada nueva; versión +1 y auditada una vez', (select count(*) from public.route_stops where route_id = (select id from t_r) and provenance = 'DRIVER' and stop_type = 'UBICACION_INTERNA') = 1
  and (select version from public.routes where id = (select id from t_r)) = (select version from t_v2) + 1
  and (select count(*) from public.route_change_events where client_op_id = 'g2-loc-1') = 1, '');
select tst.res('DRVLOC-05 La parada Montecaseros ORIGINAL no cambió (pedidos, snapshot, resultado)', order_numbers = array['71001','71002','71003','71004'] and expected_lat = -32.89 and expected_radius_m = 200 and outcome = 'ENTREGADO', '')
  from public.route_stops where id = (select id from t_s where stop_type = 'UBICACION_INTERNA');
begin; select tst.u('e0000000-0000-0000-0000-00000000000a'); set local role authenticated;
select public.upsert_internal_location('{"location_key":"MONTECASEROS","name":"Montecaseros - casa central","address":"Montecaseros 1529, Ciudad Mendoza","lat":-33.9,"lon":-69.9,"radius_m":30,"active":true}');
commit;
begin; select tst.u('e0000000-0000-0000-0000-000000000007'); set local role authenticated;
select public.arrive_stop((select id from t_d2), '{"lat":-32.8001,"lon":-68.8001,"accuracy":5}', 'g2-loc-arr');
select tst.expect('DRVLOC-07 Recepción en una G2 SIN pedidos también exige receptor y firma', format($q$ select public.set_stop_outcome(%L, 'ENTREGADO', null, null, 'g2-loc-o0', '{"location":{"lat":-32.8001,"lon":-68.8001}}') $q$, (select id from t_d2)), 'EVIDENCE_REQUIRED%');
select public.set_stop_outcome((select id from t_d2), 'ENTREGADO', null, null, 'g2-loc-o1', '{"evidence":{"receiver_name":"Encargada turno tarde","signature_png_b64":"iVBORw0KGgo=","email":"x@y.com"},"location":{"lat":-32.8001,"lon":-68.8001}}');
commit;
select tst.res('DRVLOC-08 GPS de la segunda visita contra SU snapshot (G2 movido otra vez después de agregarla)', (arrive_location->>'validation_source') = 'INTERNAL_SNAPSHOT' and (arrive_location->>'expected_lat')::float8 = -32.80
  and (arrive_location->>'radius_m')::int = 120 and arrive_location->>'outside_m' is null, arrive_location::text) from public.route_stops where id = (select id from t_d2);
select tst.res('DRVLOC-09 Cierre de la segunda visita: RECEPCION_INTERNA con firma; sin email, sin Recibido Conforme, sin cobranza',
  (select evidence_kind from public.stop_evidence where stop_id = (select id from t_d2)) = 'RECEPCION_INTERNA' and (select receiver_email from public.stop_evidence where stop_id = (select id from t_d2)) is null
  and not exists (select 1 from public.customer_email_jobs where stop_id = (select id from t_d2)) and not exists (select 1 from public.delivery_receipts where stop_id = (select id from t_d2))
  and exists (select 1 from public.audit_log where action = 'INTERNAL_TRANSFER_RECEIVED' and target_id = (select id::text from t_d2)), '');
select tst.res('UNIQ-02 La unicidad sigue vigente para paradas administrativas y no para las del chofer', exists (select 1 from pg_indexes where indexname = 'route_stops_one_admin_internal_location_per_route' and indexdef ilike '%provenance%DRIVER%')
  and not exists (select 1 from pg_indexes where indexname = 'route_stops_one_internal_location_per_route'), '');

-- G2 hardening: el administrador sigue pudiendo invocar, pero anon no tiene EXECUTE.
select tst.res('SEC-G2-01 RPC admin G2 NO ejecutable por anon',
  not has_function_privilege('anon', 'public.upsert_internal_location(jsonb)', 'EXECUTE'), '');
select tst.res('SEC-G2-02 RPC admin G2 disponible para authenticated (guard de permisos interno)',
  has_function_privilege('authenticated', 'public.upsert_internal_location(jsonb)', 'EXECUTE'), '');
select tst.res('SEC-G2-03 RPC admin G2 disponible para service_role',
  has_function_privilege('service_role', 'public.upsert_internal_location(jsonb)', 'EXECUTE'), '');

-- Numeración automática independiente por transportista (fixtures aisladas).
create temp table carrier_preflight as
  select coalesce(max(v),0) as max_code from (
    select sequence_code::int as v from public.carriers where sequence_code ~ '^[0-9]{2}$'
    union all select code::int from public.route_sequences where code ~ '^[0-9]{2}$'
  ) t;
begin;
select tst.u('e0000000-0000-0000-0000-00000000000a');
set local role authenticated;
select public.upsert_carrier('{"id":"SEQ-TEST-A","name":"Transportista Sintetico A","kind":"EXTERNO","active":true,"emails":[]}');
select public.upsert_carrier('{"id":"SEQ-TEST-B","name":"Transportista Sintetico B","kind":"EXTERNO","active":true,"emails":[]}');
select tst.expect('SEQ-03 Impide cambiar código existente', $q$ select public.upsert_carrier('{"id":"SEQ-TEST-A","name":"Transportista Sintetico A","sequence_code":"01","kind":"EXTERNO"}') $q$, 'IMMUTABLE_CODE%');
commit;
select tst.res('SEQ-01 Asignación automática consecutiva',
  (select sequence_code::int from public.carriers where id='SEQ-TEST-A') = (select max_code+1 from carrier_preflight)
  and (select sequence_code::int from public.carriers where id='SEQ-TEST-B') = (select max_code+2 from carrier_preflight), '');
begin;
select tst.u('e0000000-0000-0000-0000-00000000000a');
set local role authenticated;
select public.upsert_carrier('{"id":"SEQ-TEST-A","name":"Nombre Editado","kind":"EXTERNO","active":false,"emails":[]}');
commit;
select tst.res('SEQ-02 Código permanente al editar/desactivar',
  (select sequence_code::int from public.carriers where id='SEQ-TEST-A')=(select max_code+1 from carrier_preflight), '');

;
-- =====================================================================================================================
-- PROPUESTA V4.27 · NO APLICADA · Aprobación de cambios de RUTA INTERNA · ajustes de servidor JUSTIFICADOS
-- Diagnóstico de la hoja real 03-000019: la publicó Guillermo Castillo, del EQUIPO de Leonardo → con routes.view_team Leonardo SÍ ve la hoja
-- y sus paradas (verificado con RLS real). La causa de que no la viera fue de INTERFAZ (pantalla y menú). Por eso este SQL NO agrega
-- funciones de lectura ni modifica queue_route_emails ni la RLS. Solo:
--  1) review_route_approval: + SIN autoaprobación · + sin Superior asignado → solo Administración · − aviso y correo al transportista al
--     OBSERVAR (decisión de Dirección Técnica). El resto de la función queda idéntico.
--  2) trg_notify_driver_approved: − aviso al transportista cuando se APRUEBA una solicitud de RUTA INTERNA (los demás tipos, igual).
-- Comparación con producción POR CONTENIDO: se normalizan los fines de línea (producción guarda la misma función con CRLF: huella
-- 5570f084… = misma fuente de fase2b2 con \r\n). Si el contenido difiere en cualquier otra cosa, se detiene sin cambiar nada.
-- No toca finalize_route, estados de hojas, permisos, Inspecciones, NOC/REC, Tesorería, correos de clientes ni PWA. Una transacción.
-- =====================================================================================================================
BEGIN;
DO $guard$ BEGIN
  IF to_regclass('public.route_approval_requests') IS NULL OR to_regprocedure('public.review_route_approval(uuid,text,text)') IS NULL OR to_regprocedure('public.trg_notify_driver_approved()') IS NULL THEN
    RAISE EXCEPTION 'DEPENDENCIA_FALTANTE. No se modificó nada.'; END IF;
  IF (SELECT prosrc FROM pg_proc WHERE oid = 'public.review_route_approval(uuid,text,text)'::regprocedure) LIKE '%SELF_APPROVAL%' THEN RAISE EXCEPTION 'YA_APLICADA: la V4.27 ya existe. No se modificó nada.'; END IF;
  IF (SELECT md5(replace(prosrc, E'\r\n', E'\n')) FROM pg_proc WHERE oid = 'public.review_route_approval(uuid,text,text)'::regprocedure) <> '0c4a88155b46d3122daf9e49f9b2575e' THEN
    RAISE EXCEPTION 'PRODUCCION_DISTINTA: review_route_approval no coincide (por contenido) con fase2b2. No se modificó nada.'; END IF;
  IF (SELECT md5(replace(prosrc, E'\r\n', E'\n')) FROM pg_proc WHERE oid = 'public.trg_notify_driver_approved()'::regprocedure) <> '618063b22796f3ee13771be7b5245416' THEN
    RAISE EXCEPTION 'PRODUCCION_DISTINTA: trg_notify_driver_approved no coincide (por contenido) con fase2b3. No se modificó nada.'; END IF;
END $guard$;

create or replace function public.review_route_approval(p_request uuid, p_decision text, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare q public.route_approval_requests; r public.routes; drv_email text;
begin
  if not public.auth_has_perm('can_approve_internal_route_changes') then raise exception 'FORBIDDEN: falta permiso can_approve_internal_route_changes' using errcode = '42501'; end if;
  select * into q from public.route_approval_requests where id = p_request for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  if q.status <> 'PENDING' then raise exception 'NOT_PENDING: la solicitud ya fue resuelta' using errcode = '23514'; end if;
  -- V4.27: SIN autoaprobación (para nadie) y, sin Superior asignado, la resuelve SOLO Administración
  if q.requested_by = auth.uid() then raise exception 'SELF_APPROVAL: no se pueden aprobar ni observar los propios cambios' using errcode = '42501'; end if;
  if q.supervisor_user_id is null and not public._is_general_admin() then raise exception 'FORBIDDEN: sin superior asignado la resuelve Administración' using errcode = '42501'; end if;
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
  -- V4.27 (decisión de Dirección Técnica): al OBSERVAR ya NO se notifica ni se envía correo al transportista.
end; $$;
revoke all on function public.review_route_approval(uuid,text,text) from public, anon; grant execute on function public.review_route_approval(uuid,text,text) to authenticated;

create or replace function public.trg_notify_driver_approved() returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- V4.27 (decisión de Dirección Técnica): las aprobaciones de RUTA INTERNA ya NO notifican al transportista; los demás tipos, igual que antes
  if new.status = 'APPROVED' and old.status = 'PENDING' and coalesce(new.request_type, '') <> 'INTERNAL_ROUTE_CHANGE' then
    insert into public.notifications(user_id, route_id, route_version, type, title, body)
    select r.responsable_id, r.id, new.route_version, 'INTERNAL_ROUTE_APPROVED', 'HOJA APROBADA · ' || r.number, 'Tu hoja fue aprobada.' from public.routes r where r.id = new.route_id on conflict do nothing;
  end if;
  return new;
end; $$;

DO $post$ BEGIN
  IF (SELECT prosrc FROM pg_proc WHERE oid = 'public.review_route_approval(uuid,text,text)'::regprocedure) NOT LIKE '%SELF_APPROVAL%'
     OR (SELECT prosrc FROM pg_proc WHERE oid = 'public.review_route_approval(uuid,text,text)'::regprocedure) LIKE '%queue_route_emails%'
     OR (SELECT prosrc FROM pg_proc WHERE oid = 'public.trg_notify_driver_approved()'::regprocedure) NOT LIKE '%INTERNAL_ROUTE_CHANGE%' THEN RAISE EXCEPTION 'HUELLA_FINAL_INESPERADA'; END IF;
END $post$;
COMMIT;

;
CREATE OR REPLACE FUNCTION okd_delivery_security.may_read(p_route uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id=auth.uid() AND p.status='ACTIVO'
      AND (p.role='ADMIN' OR (
        p.role='SUPERVISOR_DESPACHO'
        AND public.auth_has_perm('signatures.view')
        AND EXISTS (
          SELECT 1 FROM public.routes r WHERE r.id=p_route
          AND (public._route_belongs_to(r.id,r.published_by,p.id)
            OR EXISTS (SELECT 1 FROM public.team_of(p.id) AS t(member_id)
              WHERE public._route_belongs_to(r.id,r.published_by,t.member_id)))
        )
      ))
  );
$function$
;
;
CREATE OR REPLACE FUNCTION public.delivery_identity_lookup(p_stop uuid, p_cuil text DEFAULT NULL::text, p_dni text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end; $function$
;
;
CREATE OR REPLACE FUNCTION public.finalize_route(p_route uuid, p_km_end numeric DEFAULT NULL::numeric)
 RETURNS routes
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end; $function$
;
;
CREATE OR REPLACE FUNCTION public.review_route_approval(p_request uuid, p_decision text, p_note text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare q public.route_approval_requests; r public.routes; drv_email text;
begin
  if not public.auth_has_perm('can_approve_internal_route_changes') then raise exception 'FORBIDDEN: falta permiso can_approve_internal_route_changes' using errcode = '42501'; end if;
  select * into q from public.route_approval_requests where id = p_request for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  if q.status <> 'PENDING' then raise exception 'NOT_PENDING: la solicitud ya fue resuelta' using errcode = '23514'; end if;
  -- V4.27: SIN autoaprobación (para nadie) y, sin Superior asignado, la resuelve SOLO Administración
  if q.requested_by = auth.uid() then raise exception 'SELF_APPROVAL: no se pueden aprobar ni observar los propios cambios' using errcode = '42501'; end if;
  if q.supervisor_user_id is null and not public._is_general_admin() then raise exception 'FORBIDDEN: sin superior asignado la resuelve Administración' using errcode = '42501'; end if;
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
  -- V4.27 (decisión de Dirección Técnica): al OBSERVAR ya NO se notifica ni se envía correo al transportista.
end; $function$
;
;
CREATE OR REPLACE FUNCTION public.search_deliveries(p_query text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me public.profiles; q text := btrim(coalesce(p_query, '')); dg text; qpv text; qnum text; sig boolean; out jsonb := '[]'; rec record;
begin
  select * into me from public.profiles where id = auth.uid() and status = 'ACTIVO';
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  dg := regexp_replace(q, '\D', '', 'g');
  if length(dg) < 3 and q !~ '^[0-9]{2}-[0-9]{6}$' then raise exception 'QUERY_TOO_SHORT: ingresá al menos 3 dígitos' using errcode = '22023'; end if;
  qnum := ltrim(case when q ~ '-' then split_part(regexp_replace(q, '[^0-9-]', '', 'g'), '-', 2) else dg end, '0');
  qpv := case when q ~ '-' then ltrim(split_part(regexp_replace(q, '[^0-9-]', '', 'g'), '-', 1), '0') end;
  sig := false; -- Se verifica por hoja con la MISMA protección de las políticas RLS vigentes.
  for rec in
    select r.id rid, r.number, r.operational_status, r.published_at, r.started_at, r.completed_at, r.carrier_id, c.name carrier_name, rp.full_name responsable_name,
           s.id sid, s.client_name, s.address, s.order_numbers, s.outcome, s.outcome_note, s.arrived_at, s.stop_type,
           (select x->'r'->>'fecha' from jsonb_array_elements(coalesce(r.sheet_snapshot->'pdf_model'->'data', '[]')) x where x->'r' ? 'fecha' limit 1) sheet_date,
           (select string_agg(distinct d, ' · ') from jsonb_array_elements(coalesce(r.sheet_snapshot->'pdf_model'->'data', '[]')) x, lateral (values (x->'r'->>'mainDoc'), (x->'r'->>'shipDoc')) v(d)
              where d is not null and d <> '' and (x->'r'->>'mainOrder' = any(s.order_numbers) or x->'r'->>'shipOrder' = any(s.order_numbers))) docs,
           ev.receiver_name, ev.receiver_cuil, ev.created_at received_at, (ev.stop_id is not null) has_signature, dr.receipt_number, dr.generated_at receipt_at
      from public.route_stops s join public.routes r on r.id = s.route_id left join public.carriers c on c.id = r.carrier_id left join public.profiles rp on rp.id = r.responsable_id
      left join public.stop_evidence ev on ev.stop_id = s.id left join public.delivery_receipts dr on dr.stop_id = s.id
     where r.operational_status <> 'BORRADOR' and coalesce(s.stop_type, 'PEDIDO') = 'PEDIDO'
       and (public._is_general_admin() or public.can_view_route_row(r.id, r.published_by, r.responsable_id))   -- SOLO hojas que el usuario puede ver (equipo / propias / todas)
       and ( dg = any(s.order_numbers) or r.number = q
          or exists (select 1 from jsonb_array_elements(coalesce(r.sheet_snapshot->'pdf_model'->'data', '[]')) x, lateral (values (x->'r'->>'mainDoc', x->'r'->>'mainOrder'), (x->'r'->>'shipDoc', x->'r'->>'shipOrder')) v(d, o)
                      where o = any(s.order_numbers) and d is not null and qnum <> ''
                        and ltrim(split_part(regexp_replace(d, '[^0-9-]', '', 'g'), '-', 2), '0') = qnum
                        and (qpv is null or ltrim(split_part(regexp_replace(d, '[^0-9-]', '', 'g'), '-', 1), '0') = qpv)) )
     order by r.published_at desc limit 30
  loop
    sig:=okd_delivery_security.may_read(rec.rid) and (public._is_general_admin() or public.can_view_route(rec.rid));
    out := out || jsonb_build_object('route_id', rec.rid, 'route_number', rec.number, 'route_status', rec.operational_status, 'carrier', coalesce(rec.carrier_name, rec.carrier_id), 'responsable', rec.responsable_name,
      'published_at', rec.published_at, 'started_at', rec.started_at, 'completed_at', rec.completed_at, 'sheet_date', rec.sheet_date,
      'stop_id', rec.sid, 'client_name', rec.client_name, 'address', rec.address, 'order_numbers', to_jsonb(rec.order_numbers), 'docs', rec.docs,
      'outcome', rec.outcome, 'outcome_note', rec.outcome_note, 'arrived_at', rec.arrived_at, 'received_at', rec.received_at,
      'has_receipt', rec.receipt_number is not null, 'signatures_visible', sig,
      -- datos personales y constancia SOLO con signatures.view (los demás ven el estado, no quién firmó)
      'receiver_name', case when sig then rec.receiver_name end, 'receiver_cuil', case when sig then rec.receiver_cuil end,
      'has_signature', case when sig then rec.has_signature end, 'receipt_number', case when sig then rec.receipt_number end, 'receipt_at', case when sig then rec.receipt_at end);
  end loop;
  return out;
end; $function$
;
;
CREATE OR REPLACE FUNCTION public.set_stop_outcome(p_stop uuid, p_outcome text, p_note text, p_reason text, p_op_id text, p_extra jsonb DEFAULT NULL::jsonb)
 RETURNS route_stops
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare st public.route_stops; r public.routes; cristian boolean; v_commercial boolean; v_task boolean; v_cuil text; v_email text; v_dni text; v_receipt boolean := false; ev jsonb := coalesce(p_extra->'evidence', '{}'); col jsonb := p_extra->'collection'; loc jsonb; sig bytea;
begin
  select * into st from public.route_stops where id = p_stop;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  r := public._my_route(st.route_id);
  -- Comportamiento por tipo de parada: solo PEDIDO es entrega comercial al cliente (email, Recibido Conforme, cobranza, identidad).
  v_commercial := coalesce(st.stop_type, 'PEDIDO') = 'PEDIDO';
  v_task := st.stop_type = 'TAREA';
  if p_op_id is not null and exists (select 1 from public.stop_outcome_ops where op_id = p_op_id) then return st; end if;
  if r.operational_status <> 'EN_CURSO' then raise exception 'BAD_STATE: iniciá el recorrido o la hoja ya está cerrada' using errcode = '23514'; end if;
  if p_outcome not in ('ENTREGADO','ENTREGA_PARCIAL','NO_ENTREGADO','REPROGRAMAR') then raise exception 'BAD_OUTCOME' using errcode = '22023'; end if;
  if p_outcome = 'ENTREGA_PARCIAL' and coalesce(trim(p_note), '') = '' then raise exception 'NOTE_REQUIRED: entrega parcial exige observación' using errcode = '23514'; end if;
  if p_outcome in ('NO_ENTREGADO','REPROGRAMAR') and coalesce(trim(p_reason), '') = '' then raise exception 'REASON_REQUIRED: indicá el motivo' using errcode = '23514'; end if;
  cristian := exists (select 1 from public.carriers where id = r.carrier_id and report_group = 'CRISTIAN_TORRES');
  if p_outcome in ('ENTREGADO','ENTREGA_PARCIAL') then
    -- TAREA: no se exige firma ni receptor como en una entrega comercial (alcanza GPS u observación). El resto, igual que antes.
    if not v_task and (coalesce(trim(ev->>'receiver_name'), '') = '' or coalesce(ev->>'signature_png_b64', '') = '') then raise exception 'EVIDENCE_REQUIRED: nombre del receptor y firma obligatorios' using errcode = '23514'; end if;
    sig := case when coalesce(ev->>'signature_png_b64', '') <> '' then decode(ev->>'signature_png_b64', 'base64') end;
    -- V4.17: entrega COMERCIAL de AMBOS perfiles (transportista externo e interno): CUIL + identidad con DNI registrado
    -- (antes: solo Cristian). _register_identity vincula la foto nueva o reutiliza una identidad ya registrada.
    if v_commercial then
      v_cuil := regexp_replace(coalesce(ev->>'cuil', ''), '\D', '', 'g');
      if length(v_cuil) <> 11 then raise exception 'CUIL_INVALID: el CUIL debe tener 11 dígitos' using errcode = '23514'; end if;
      perform public._register_identity(v_cuil, ev);   -- V4.21: solo VINCULA una foto si llega (entregas viejas en cola); la foto del DNI ya no se exige
    else
      v_cuil := nullif(regexp_replace(coalesce(ev->>'cuil', ''), '\D', '', 'g'), '');   -- Transportista Interno: CUIL opcional
      if v_cuil is not null and length(v_cuil) <> 11 then raise exception 'CUIL_INVALID: el CUIL debe tener 11 dígitos' using errcode = '23514'; end if;
    end if;
    -- RC4.1: email del receptor (segunda pantalla). Opcional; si viene, debe ser válido.
    v_email := nullif(lower(trim(coalesce(ev->>'email', ''))), '');
    -- V4.21: el email del receptor es OPCIONAL (ambos transportistas). Si viene, se valida el formato (abajo) y se genera el Recibido
    -- Conforme; si no viene, la entrega se confirma igual y NO se intenta enviar el Recibido Conforme.
    if v_email is not null and not public.is_valid_email(v_email) then raise exception 'EMAIL_INVALID: el email no es válido' using errcode = '23514'; end if;
    v_dni := nullif(regexp_replace(coalesce(ev->>'dni', ''), '\D', '', 'g'), '');
    if v_dni is null and v_cuil is not null then v_dni := substr(v_cuil, 3, 8); end if;
    if v_dni is not null and length(v_dni) not between 7 and 8 then raise exception 'DNI_INVALID: el DNI debe tener 7 u 8 dígitos' using errcode = '23514'; end if;
  end if;
  -- cobranza (Cristian): el chofer no cambia el importe esperado
  -- V4.17: la cobranza es OPCIONAL (el chofer ya no la registra). Si se informa, se valida igual que antes; si no, no se registra
  -- ningún cobro y los datos de cobranza existentes de la parada se CONSERVAN (no se inventan ni se borran).
  if v_commercial and st.task in ('COBRANZA','AMBAS') and col is not null and coalesce(col->>'status', 'PENDIENTE') <> 'PENDIENTE' then
    if col->>'status' not in ('COBRADO','COBRO_PARCIAL','NO_COBRADO') then raise exception 'BAD_COLLECTION' using errcode = '22023'; end if;
    if col->>'status' in ('COBRO_PARCIAL','NO_COBRADO') and coalesce(trim(col->>'note'), '') = '' then raise exception 'COLLECTION_NOTE_REQUIRED: cobro parcial exige observación y no cobrado exige motivo' using errcode = '23514'; end if;
    if col->>'status' in ('COBRADO','COBRO_PARCIAL') and coalesce((col->>'amount')::numeric, 0) <= 0 then raise exception 'COLLECTION_AMOUNT_REQUIRED' using errcode = '23514'; end if;
  end if;
  loc := public._loc(p_extra->'location', st);
  update public.route_stops set outcome = p_outcome, outcome_at = now(), outcome_by = auth.uid(), outcome_note = nullif(trim(p_note),''), outcome_reason = nullif(trim(p_reason),''),
    finish_location = loc, location_warning = coalesce(case when loc->>'outside_m' is not null then 'FUERA DEL RADIO (' || (loc->>'outside_m') || ' m)' end, location_warning),
    collection_status = case when st.task in ('COBRANZA','AMBAS') and coalesce(col->>'status','PENDIENTE') <> 'PENDIENTE' then col->>'status' else collection_status end,
    collected_amount = case when st.task in ('COBRANZA','AMBAS') and coalesce(col->>'status','PENDIENTE') <> 'PENDIENTE' then nullif(col->>'amount','')::numeric else collected_amount end,
    payment_mode = case when st.task in ('COBRANZA','AMBAS') and coalesce(col->>'status','PENDIENTE') <> 'PENDIENTE' then col->>'mode' else payment_mode end,
    collection_note = case when st.task in ('COBRANZA','AMBAS') and coalesce(col->>'status','PENDIENTE') <> 'PENDIENTE' then nullif(trim(col->>'note'),'') else collection_note end
  where id = p_stop returning * into st;
  if p_outcome in ('ENTREGADO','ENTREGA_PARCIAL') then
    -- La entrega guarda el email USADO (inmutable aunque el perfil cambie después)
    if sig is not null then
      insert into public.stop_evidence(stop_id, receiver_name, signature_png, signature_sha256, receiver_cuil, created_by, receiver_email, receiver_dni, evidence_kind)
      values (p_stop, coalesce(nullif(trim(ev->>'receiver_name'), ''), 'Sin receptor (tarea)'), sig, encode(sha256(sig), 'hex'), v_cuil, auth.uid(), case when v_commercial then v_email end, v_dni,
              case when st.stop_type = 'UBICACION_INTERNA' then 'RECEPCION_INTERNA' when v_task then 'TAREA' else 'ENTREGA_CLIENTE' end)
      on conflict (stop_id) do nothing;
    end if;
    -- RECEPCIÓN INTERNA DE TRASLADO: queda trazado qué pedidos llegaron a qué sucursal, quién recibió, quién trasladó, cuándo y dónde
    if st.stop_type = 'UBICACION_INTERNA' then
      insert into public.audit_log(actor_id, action, target_type, target_id, after)
      values (auth.uid(), 'INTERNAL_TRANSFER_RECEIVED', 'route_stop', p_stop::text, jsonb_build_object(
        'route_id', st.route_id, 'route_number', r.number, 'internal_location_key', st.internal_location_key, 'location_name', st.client_name, 'address', st.address,
        'order_numbers', to_jsonb(st.order_numbers), 'outcome', p_outcome, 'receiver_name', trim(ev->>'receiver_name'), 'signature_sha256', encode(sha256(sig), 'hex'),
        'transported_by', auth.uid(), 'at', now(), 'gps', loc));
    end if;
    -- Perfil reutilizable (misma capa de identidad que el DNI): nombre, DNI y email para próximas entregas
    if v_commercial and v_cuil is not null then perform public._upsert_identity_profile(v_cuil, trim(ev->>'receiver_name'), v_dni, v_email, st.client_key); end if;
    -- Recibido Conforme: entrega TOTAL confirmada + email válido → comprobante único + envío automático (la falla del email nunca revierte la entrega)
    if v_commercial and p_outcome = 'ENTREGADO' and v_email is not null then perform public._create_delivery_receipt(st, r, trim(ev->>'receiver_name'), v_email); v_receipt := true; end if;
    if v_commercial and coalesce(trim(st.customer_email), '') <> '' and not v_receipt then
      insert into public.customer_email_jobs(route_id, stop_id, kind, recipient, idempotency_key)
      values (st.route_id, st.id, case when p_outcome = 'ENTREGADO' then 'DELIVERED' else 'PARTIAL' end, lower(trim(st.customer_email)), st.route_id || '|' || st.id || '|' || case when p_outcome = 'ENTREGADO' then 'DELIVERED' else 'PARTIAL' end)
      on conflict (idempotency_key) do nothing;
    end if;
  end if;
  if p_op_id is not null then insert into public.stop_outcome_ops(op_id, stop_id) values (p_op_id, p_stop); end if;
  perform public._queue_on_the_way(st.route_id);
  return st;
end; $function$
;
;
CREATE OR REPLACE FUNCTION public.trg_notify_driver_approved()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  -- V4.27 (decisión de Dirección Técnica): las aprobaciones de RUTA INTERNA ya NO notifican al transportista; los demás tipos, igual que antes
  if new.status = 'APPROVED' and old.status = 'PENDING' and coalesce(new.request_type, '') <> 'INTERNAL_ROUTE_CHANGE' then
    insert into public.notifications(user_id, route_id, route_version, type, title, body)
    select r.responsable_id, r.id, new.route_version, 'INTERNAL_ROUTE_APPROVED', 'HOJA APROBADA · ' || r.number, 'Tu hoja fue aprobada.' from public.routes r where r.id = new.route_id on conflict do nothing;
  end if;
  return new;
end; $function$
;
;
CREATE OR REPLACE FUNCTION okd_delivery_security.may_read(p_route uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id=auth.uid() AND p.status='ACTIVO'
      AND (p.role='ADMIN' OR (
        p.role='SUPERVISOR_DESPACHO'
        AND public.auth_has_perm('signatures.view')
        AND EXISTS (
          SELECT 1 FROM public.routes r WHERE r.id=p_route
          AND (public._route_belongs_to(r.id,r.published_by,p.id)
            OR EXISTS (SELECT 1 FROM public.team_of(p.id) AS t(member_id)
              WHERE public._route_belongs_to(r.id,r.published_by,t.member_id)))
        )
      ))
  );
$function$
;
;
CREATE OR REPLACE FUNCTION public._is_general_admin()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'ADMIN' and status = 'ACTIVO'); $function$
;
;
CREATE OR REPLACE FUNCTION public._route_belongs_to(p_route uuid, p_published_by uuid, p_user uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select p_published_by = p_user or exists (select 1 from public.route_drafts d where d.route_id = p_route and d.owner_id = p_user);
$function$
;
;
CREATE OR REPLACE FUNCTION public.auth_has_perm(p_perm text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select public.user_has_perm(auth.uid(), p_perm) and exists (select 1 from public.profiles p where p.id = auth.uid()
      and (p.sessions_revoked_at is null or coalesce((auth.jwt() ->> 'iat')::numeric, 0) > extract(epoch from p.sessions_revoked_at)));
$function$
;
;
CREATE OR REPLACE FUNCTION public.can_view_route(p_route uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce((select public.can_view_route_row(r.id, r.published_by, r.responsable_id) from public.routes r where r.id = p_route), false);
$function$
;
;
CREATE OR REPLACE FUNCTION public.can_view_route_row(p_route uuid, p_published_by uuid, p_responsable uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(
       public.auth_has_perm('routes.view_all')
    or (p_responsable = auth.uid() and public.auth_has_perm('routes.view_assigned'))                                   -- transportistas: igual que antes
    or (p_responsable = auth.uid() and public._auth_receives_internal() and public._is_internal_route(p_route))   -- permiso de asignación (solo su hoja interna)
    or ((public.auth_has_perm('routes.view_own') or public.auth_has_perm('routes.view_team')) and public._route_belongs_to(p_route, p_published_by, auth.uid()))
    or (public.auth_has_perm('routes.view_team') and exists (select 1 from public.team_of(auth.uid()) t where public._route_belongs_to(p_route, p_published_by, t)))
  , false);
$function$
;
;
CREATE OR REPLACE FUNCTION public.delivery_identity_lookup(p_stop uuid, p_cuil text DEFAULT NULL::text, p_dni text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end; $function$
;
;
CREATE OR REPLACE FUNCTION public.finalize_route(p_route uuid, p_km_end numeric DEFAULT NULL::numeric)
 RETURNS routes
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end; $function$
;
;
CREATE OR REPLACE FUNCTION public.review_route_approval(p_request uuid, p_decision text, p_note text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare q public.route_approval_requests; r public.routes; drv_email text;
begin
  if not public.auth_has_perm('can_approve_internal_route_changes') then raise exception 'FORBIDDEN: falta permiso can_approve_internal_route_changes' using errcode = '42501'; end if;
  select * into q from public.route_approval_requests where id = p_request for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  if q.status <> 'PENDING' then raise exception 'NOT_PENDING: la solicitud ya fue resuelta' using errcode = '23514'; end if;
  -- V4.27: SIN autoaprobación (para nadie) y, sin Superior asignado, la resuelve SOLO Administración
  if q.requested_by = auth.uid() then raise exception 'SELF_APPROVAL: no se pueden aprobar ni observar los propios cambios' using errcode = '42501'; end if;
  if q.supervisor_user_id is null and not public._is_general_admin() then raise exception 'FORBIDDEN: sin superior asignado la resuelve Administración' using errcode = '42501'; end if;
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
  -- V4.27 (decisión de Dirección Técnica): al OBSERVAR ya NO se notifica ni se envía correo al transportista.
end; $function$
;
;
CREATE OR REPLACE FUNCTION public.search_deliveries(p_query text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me public.profiles; q text := btrim(coalesce(p_query, '')); dg text; qpv text; qnum text; sig boolean; out jsonb := '[]'; rec record;
begin
  select * into me from public.profiles where id = auth.uid() and status = 'ACTIVO';
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  dg := regexp_replace(q, '\D', '', 'g');
  if length(dg) < 3 and q !~ '^[0-9]{2}-[0-9]{6}$' then raise exception 'QUERY_TOO_SHORT: ingresá al menos 3 dígitos' using errcode = '22023'; end if;
  qnum := ltrim(case when q ~ '-' then split_part(regexp_replace(q, '[^0-9-]', '', 'g'), '-', 2) else dg end, '0');
  qpv := case when q ~ '-' then ltrim(split_part(regexp_replace(q, '[^0-9-]', '', 'g'), '-', 1), '0') end;
  sig := false; -- Se verifica por hoja con la MISMA protección de las políticas RLS vigentes.
  for rec in
    select r.id rid, r.number, r.operational_status, r.published_at, r.started_at, r.completed_at, r.carrier_id, c.name carrier_name, rp.full_name responsable_name,
           s.id sid, s.client_name, s.address, s.order_numbers, s.outcome, s.outcome_note, s.arrived_at, s.stop_type,
           (select x->'r'->>'fecha' from jsonb_array_elements(coalesce(r.sheet_snapshot->'pdf_model'->'data', '[]')) x where x->'r' ? 'fecha' limit 1) sheet_date,
           (select string_agg(distinct d, ' · ') from jsonb_array_elements(coalesce(r.sheet_snapshot->'pdf_model'->'data', '[]')) x, lateral (values (x->'r'->>'mainDoc'), (x->'r'->>'shipDoc')) v(d)
              where d is not null and d <> '' and (x->'r'->>'mainOrder' = any(s.order_numbers) or x->'r'->>'shipOrder' = any(s.order_numbers))) docs,
           ev.receiver_name, ev.receiver_cuil, ev.created_at received_at, (ev.stop_id is not null) has_signature, dr.receipt_number, dr.generated_at receipt_at
      from public.route_stops s join public.routes r on r.id = s.route_id left join public.carriers c on c.id = r.carrier_id left join public.profiles rp on rp.id = r.responsable_id
      left join public.stop_evidence ev on ev.stop_id = s.id left join public.delivery_receipts dr on dr.stop_id = s.id
     where r.operational_status <> 'BORRADOR' and coalesce(s.stop_type, 'PEDIDO') = 'PEDIDO'
       and (public._is_general_admin() or public.can_view_route_row(r.id, r.published_by, r.responsable_id))   -- SOLO hojas que el usuario puede ver (equipo / propias / todas)
       and ( dg = any(s.order_numbers) or r.number = q
          or exists (select 1 from jsonb_array_elements(coalesce(r.sheet_snapshot->'pdf_model'->'data', '[]')) x, lateral (values (x->'r'->>'mainDoc', x->'r'->>'mainOrder'), (x->'r'->>'shipDoc', x->'r'->>'shipOrder')) v(d, o)
                      where o = any(s.order_numbers) and d is not null and qnum <> ''
                        and ltrim(split_part(regexp_replace(d, '[^0-9-]', '', 'g'), '-', 2), '0') = qnum
                        and (qpv is null or ltrim(split_part(regexp_replace(d, '[^0-9-]', '', 'g'), '-', 1), '0') = qpv)) )
     order by r.published_at desc limit 30
  loop
    sig:=okd_delivery_security.may_read(rec.rid) and (public._is_general_admin() or public.can_view_route(rec.rid));
    out := out || jsonb_build_object('route_id', rec.rid, 'route_number', rec.number, 'route_status', rec.operational_status, 'carrier', coalesce(rec.carrier_name, rec.carrier_id), 'responsable', rec.responsable_name,
      'published_at', rec.published_at, 'started_at', rec.started_at, 'completed_at', rec.completed_at, 'sheet_date', rec.sheet_date,
      'stop_id', rec.sid, 'client_name', rec.client_name, 'address', rec.address, 'order_numbers', to_jsonb(rec.order_numbers), 'docs', rec.docs,
      'outcome', rec.outcome, 'outcome_note', rec.outcome_note, 'arrived_at', rec.arrived_at, 'received_at', rec.received_at,
      'has_receipt', rec.receipt_number is not null, 'signatures_visible', sig,
      -- datos personales y constancia SOLO con signatures.view (los demás ven el estado, no quién firmó)
      'receiver_name', case when sig then rec.receiver_name end, 'receiver_cuil', case when sig then rec.receiver_cuil end,
      'has_signature', case when sig then rec.has_signature end, 'receipt_number', case when sig then rec.receipt_number end, 'receipt_at', case when sig then rec.receipt_at end);
  end loop;
  return out;
end; $function$
;
;
CREATE OR REPLACE FUNCTION public.set_stop_outcome(p_stop uuid, p_outcome text, p_note text, p_reason text, p_op_id text, p_extra jsonb DEFAULT NULL::jsonb)
 RETURNS route_stops
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare st public.route_stops; r public.routes; cristian boolean; v_commercial boolean; v_task boolean; v_cuil text; v_email text; v_dni text; v_receipt boolean := false; ev jsonb := coalesce(p_extra->'evidence', '{}'); col jsonb := p_extra->'collection'; loc jsonb; sig bytea;
begin
  select * into st from public.route_stops where id = p_stop;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  r := public._my_route(st.route_id);
  -- Comportamiento por tipo de parada: solo PEDIDO es entrega comercial al cliente (email, Recibido Conforme, cobranza, identidad).
  v_commercial := coalesce(st.stop_type, 'PEDIDO') = 'PEDIDO';
  v_task := st.stop_type = 'TAREA';
  if p_op_id is not null and exists (select 1 from public.stop_outcome_ops where op_id = p_op_id) then return st; end if;
  if r.operational_status <> 'EN_CURSO' then raise exception 'BAD_STATE: iniciá el recorrido o la hoja ya está cerrada' using errcode = '23514'; end if;
  if p_outcome not in ('ENTREGADO','ENTREGA_PARCIAL','NO_ENTREGADO','REPROGRAMAR') then raise exception 'BAD_OUTCOME' using errcode = '22023'; end if;
  if p_outcome = 'ENTREGA_PARCIAL' and coalesce(trim(p_note), '') = '' then raise exception 'NOTE_REQUIRED: entrega parcial exige observación' using errcode = '23514'; end if;
  if p_outcome in ('NO_ENTREGADO','REPROGRAMAR') and coalesce(trim(p_reason), '') = '' then raise exception 'REASON_REQUIRED: indicá el motivo' using errcode = '23514'; end if;
  cristian := exists (select 1 from public.carriers where id = r.carrier_id and report_group = 'CRISTIAN_TORRES');
  if p_outcome in ('ENTREGADO','ENTREGA_PARCIAL') then
    -- TAREA: no se exige firma ni receptor como en una entrega comercial (alcanza GPS u observación). El resto, igual que antes.
    if not v_task and (coalesce(trim(ev->>'receiver_name'), '') = '' or coalesce(ev->>'signature_png_b64', '') = '') then raise exception 'EVIDENCE_REQUIRED: nombre del receptor y firma obligatorios' using errcode = '23514'; end if;
    sig := case when coalesce(ev->>'signature_png_b64', '') <> '' then decode(ev->>'signature_png_b64', 'base64') end;
    -- V4.17: entrega COMERCIAL de AMBOS perfiles (transportista externo e interno): CUIL + identidad con DNI registrado
    -- (antes: solo Cristian). _register_identity vincula la foto nueva o reutiliza una identidad ya registrada.
    if v_commercial then
      v_cuil := regexp_replace(coalesce(ev->>'cuil', ''), '\D', '', 'g');
      if length(v_cuil) <> 11 then raise exception 'CUIL_INVALID: el CUIL debe tener 11 dígitos' using errcode = '23514'; end if;
      perform public._register_identity(v_cuil, ev);   -- V4.21: solo VINCULA una foto si llega (entregas viejas en cola); la foto del DNI ya no se exige
    else
      v_cuil := nullif(regexp_replace(coalesce(ev->>'cuil', ''), '\D', '', 'g'), '');   -- Transportista Interno: CUIL opcional
      if v_cuil is not null and length(v_cuil) <> 11 then raise exception 'CUIL_INVALID: el CUIL debe tener 11 dígitos' using errcode = '23514'; end if;
    end if;
    -- RC4.1: email del receptor (segunda pantalla). Opcional; si viene, debe ser válido.
    v_email := nullif(lower(trim(coalesce(ev->>'email', ''))), '');
    -- V4.21: el email del receptor es OPCIONAL (ambos transportistas). Si viene, se valida el formato (abajo) y se genera el Recibido
    -- Conforme; si no viene, la entrega se confirma igual y NO se intenta enviar el Recibido Conforme.
    if v_email is not null and not public.is_valid_email(v_email) then raise exception 'EMAIL_INVALID: el email no es válido' using errcode = '23514'; end if;
    v_dni := nullif(regexp_replace(coalesce(ev->>'dni', ''), '\D', '', 'g'), '');
    if v_dni is null and v_cuil is not null then v_dni := substr(v_cuil, 3, 8); end if;
    if v_dni is not null and length(v_dni) not between 7 and 8 then raise exception 'DNI_INVALID: el DNI debe tener 7 u 8 dígitos' using errcode = '23514'; end if;
  end if;
  -- cobranza (Cristian): el chofer no cambia el importe esperado
  -- V4.17: la cobranza es OPCIONAL (el chofer ya no la registra). Si se informa, se valida igual que antes; si no, no se registra
  -- ningún cobro y los datos de cobranza existentes de la parada se CONSERVAN (no se inventan ni se borran).
  if v_commercial and st.task in ('COBRANZA','AMBAS') and col is not null and coalesce(col->>'status', 'PENDIENTE') <> 'PENDIENTE' then
    if col->>'status' not in ('COBRADO','COBRO_PARCIAL','NO_COBRADO') then raise exception 'BAD_COLLECTION' using errcode = '22023'; end if;
    if col->>'status' in ('COBRO_PARCIAL','NO_COBRADO') and coalesce(trim(col->>'note'), '') = '' then raise exception 'COLLECTION_NOTE_REQUIRED: cobro parcial exige observación y no cobrado exige motivo' using errcode = '23514'; end if;
    if col->>'status' in ('COBRADO','COBRO_PARCIAL') and coalesce((col->>'amount')::numeric, 0) <= 0 then raise exception 'COLLECTION_AMOUNT_REQUIRED' using errcode = '23514'; end if;
  end if;
  loc := public._loc(p_extra->'location', st);
  update public.route_stops set outcome = p_outcome, outcome_at = now(), outcome_by = auth.uid(), outcome_note = nullif(trim(p_note),''), outcome_reason = nullif(trim(p_reason),''),
    finish_location = loc, location_warning = coalesce(case when loc->>'outside_m' is not null then 'FUERA DEL RADIO (' || (loc->>'outside_m') || ' m)' end, location_warning),
    collection_status = case when st.task in ('COBRANZA','AMBAS') and coalesce(col->>'status','PENDIENTE') <> 'PENDIENTE' then col->>'status' else collection_status end,
    collected_amount = case when st.task in ('COBRANZA','AMBAS') and coalesce(col->>'status','PENDIENTE') <> 'PENDIENTE' then nullif(col->>'amount','')::numeric else collected_amount end,
    payment_mode = case when st.task in ('COBRANZA','AMBAS') and coalesce(col->>'status','PENDIENTE') <> 'PENDIENTE' then col->>'mode' else payment_mode end,
    collection_note = case when st.task in ('COBRANZA','AMBAS') and coalesce(col->>'status','PENDIENTE') <> 'PENDIENTE' then nullif(trim(col->>'note'),'') else collection_note end
  where id = p_stop returning * into st;
  if p_outcome in ('ENTREGADO','ENTREGA_PARCIAL') then
    -- La entrega guarda el email USADO (inmutable aunque el perfil cambie después)
    if sig is not null then
      insert into public.stop_evidence(stop_id, receiver_name, signature_png, signature_sha256, receiver_cuil, created_by, receiver_email, receiver_dni, evidence_kind)
      values (p_stop, coalesce(nullif(trim(ev->>'receiver_name'), ''), 'Sin receptor (tarea)'), sig, encode(sha256(sig), 'hex'), v_cuil, auth.uid(), case when v_commercial then v_email end, v_dni,
              case when st.stop_type = 'UBICACION_INTERNA' then 'RECEPCION_INTERNA' when v_task then 'TAREA' else 'ENTREGA_CLIENTE' end)
      on conflict (stop_id) do nothing;
    end if;
    -- RECEPCIÓN INTERNA DE TRASLADO: queda trazado qué pedidos llegaron a qué sucursal, quién recibió, quién trasladó, cuándo y dónde
    if st.stop_type = 'UBICACION_INTERNA' then
      insert into public.audit_log(actor_id, action, target_type, target_id, after)
      values (auth.uid(), 'INTERNAL_TRANSFER_RECEIVED', 'route_stop', p_stop::text, jsonb_build_object(
        'route_id', st.route_id, 'route_number', r.number, 'internal_location_key', st.internal_location_key, 'location_name', st.client_name, 'address', st.address,
        'order_numbers', to_jsonb(st.order_numbers), 'outcome', p_outcome, 'receiver_name', trim(ev->>'receiver_name'), 'signature_sha256', encode(sha256(sig), 'hex'),
        'transported_by', auth.uid(), 'at', now(), 'gps', loc));
    end if;
    -- Perfil reutilizable (misma capa de identidad que el DNI): nombre, DNI y email para próximas entregas
    if v_commercial and v_cuil is not null then perform public._upsert_identity_profile(v_cuil, trim(ev->>'receiver_name'), v_dni, v_email, st.client_key); end if;
    -- Recibido Conforme: entrega TOTAL confirmada + email válido → comprobante único + envío automático (la falla del email nunca revierte la entrega)
    if v_commercial and p_outcome = 'ENTREGADO' and v_email is not null then perform public._create_delivery_receipt(st, r, trim(ev->>'receiver_name'), v_email); v_receipt := true; end if;
    if v_commercial and coalesce(trim(st.customer_email), '') <> '' and not v_receipt then
      insert into public.customer_email_jobs(route_id, stop_id, kind, recipient, idempotency_key)
      values (st.route_id, st.id, case when p_outcome = 'ENTREGADO' then 'DELIVERED' else 'PARTIAL' end, lower(trim(st.customer_email)), st.route_id || '|' || st.id || '|' || case when p_outcome = 'ENTREGADO' then 'DELIVERED' else 'PARTIAL' end)
      on conflict (idempotency_key) do nothing;
    end if;
  end if;
  if p_op_id is not null then insert into public.stop_outcome_ops(op_id, stop_id) values (p_op_id, p_stop); end if;
  perform public._queue_on_the_way(st.route_id);
  return st;
end; $function$
;
;
CREATE OR REPLACE FUNCTION public.set_user_permission(p_user uuid, p_perm text, p_state text, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end; $function$
;
;
CREATE OR REPLACE FUNCTION public.team_of(p_user uuid)
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with recursive t(id, d) as (select id, 1 from public.profiles where supervisor_user_id = p_user
    union all select p.id, t.d + 1 from public.profiles p join t on p.supervisor_user_id = t.id where t.d < 20)
  select distinct id from t;
$function$
;
;
CREATE OR REPLACE FUNCTION public.trg_notify_driver_approved()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  -- V4.27 (decisión de Dirección Técnica): las aprobaciones de RUTA INTERNA ya NO notifican al transportista; los demás tipos, igual que antes
  if new.status = 'APPROVED' and old.status = 'PENDING' and coalesce(new.request_type, '') <> 'INTERNAL_ROUTE_CHANGE' then
    insert into public.notifications(user_id, route_id, route_version, type, title, body)
    select r.responsable_id, r.id, new.route_version, 'INTERNAL_ROUTE_APPROVED', 'HOJA APROBADA · ' || r.number, 'Tu hoja fue aprobada.' from public.routes r where r.id = new.route_id on conflict do nothing;
  end if;
  return new;
end; $function$
;
;
CREATE OR REPLACE FUNCTION public.user_has_perm(p_user uuid, p_perm text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (select 1 from public.profiles p where p.id = p_user and p.status = 'ACTIVO'
      and ((exists (select 1 from public.role_permissions rp where rp.role_code = p.role and rp.permission_code = p_perm)
            and not exists (select 1 from public.user_permission_overrides o where o.user_id = p.id and o.permission_code = p_perm and not o.granted))
           or exists (select 1 from public.user_permission_overrides o where o.user_id = p.id and o.permission_code = p_perm and o.granted))
      and not exists (select 1 from public.module_permissions mp where mp.permission_code = p_perm and mp.module = any(p.disabled_modules)));
$function$
;
;
drop policy if exists "delivery_receipts_read" on "public"."delivery_receipts"
;
create policy "delivery_receipts_read" on "public"."delivery_receipts" as PERMISSIVE for SELECT to "authenticated" using ((can_view_route(route_id) AND okd_delivery_security.may_read(route_id)));
;
drop policy if exists "rar_team_read" on "public"."route_approval_requests"
;
create policy "rar_team_read" on "public"."route_approval_requests" as PERMISSIVE for SELECT to "authenticated" using (((requested_by = auth.uid()) OR (supervisor_user_id = auth.uid()) OR auth_is_admin() OR (auth_has_perm('requests.view_team'::text) AND in_my_team(requested_by))));
;
drop policy if exists "route_approval_read" on "public"."route_approval_requests"
;
create policy "route_approval_read" on "public"."route_approval_requests" as PERMISSIVE for SELECT to "authenticated" using (((requested_by = auth.uid()) OR (supervisor_user_id = auth.uid()) OR ((request_type = 'INTERNAL_ROUTE_CHANGE'::text) AND (auth_has_perm('can_approve_internal_route_changes'::text) OR auth_has_perm('routes.view_all'::text)))));
;
drop policy if exists "route_stops_read" on "public"."route_stops"
;
create policy "route_stops_read" on "public"."route_stops" as PERMISSIVE for SELECT to "authenticated" using (can_view_route(route_id));
;
drop policy if exists "routes_read" on "public"."routes"
;
create policy "routes_read" on "public"."routes" as PERMISSIVE for SELECT to "authenticated" using (can_view_route_row(id, published_by, responsable_id));
;
drop policy if exists "evidence_read" on "public"."stop_evidence"
;
create policy "evidence_read" on "public"."stop_evidence" as PERMISSIVE for SELECT to "authenticated" using ((can_view_route(( SELECT s.route_id
   FROM route_stops s
  WHERE (s.id = stop_evidence.stop_id))) AND okd_delivery_security.may_read(( SELECT s.route_id
   FROM route_stops s
  WHERE (s.id = stop_evidence.stop_id)))));
;
-- =====================================================================================================================
-- PROPUESTA V4.28 · NO APLICADA · VER HOJA: gestión de pendientes, historial de cambios y receptor con DNI / CUIL / CUIT
--  1) stop_followups (SOLO AGREGADO) + add_stop_followup: gestiones, observaciones e incidencias por parada. NUNCA cambia el resultado
--     de la parada (un PARCIAL no pasa a ENTREGADO); las solicitudes usan el circuito EXISTENTE (create_operational_request, tipo OTRO).
--  2) route_change_history: historial legible de la hoja para quien puede verla (resultado original, cambios de ruta interna, solicitudes
--     y decisiones con quién aprobó/observó, gestiones). Todo sale del servidor.
--  3) set_stop_outcome: receptor con DNI, CUIL o CUIT. REGLA DEFINITIVA: un documento incorrecto o faltante NUNCA bloquea la entrega
--     (la FIRMA sigue siendo obligatoria). Se guarda lo DECLARADO tal cual + tipo + validación + motivo; receiver_cuil / receiver_dni solo
--     con documentos VÁLIDOS (nunca se vincula una identidad con un documento no validado). Documento a revisar → UNA incidencia por entrega
--     (receiver_doc_reviews, idempotente) + alerta en la campana a Administración y al Superior responsable (si la alerta falla, la entrega
--     NO se deshace). Corrección posterior auditada (correct_receiver_doc) sin tocar la evidencia original.
--     Comparación POR CONTENIDO (fines de línea normalizados); si difiere, se detiene sin cambios.
-- No toca finalize_route, RLS existente, permisos, aprobaciones V4.27, Inspecciones, NOC/REC, Tesorería, correos ni PWA.
-- =====================================================================================================================
BEGIN;
DO $guard$ BEGIN
  IF to_regclass('public.stop_followups') IS NOT NULL THEN RAISE EXCEPTION 'YA_APLICADA: la V4.28 ya existe. No se modificó nada.'; END IF;
  IF to_regprocedure('public.set_stop_outcome(uuid,text,text,text,text,jsonb)') IS NULL OR to_regprocedure('public._cuit_valid(text)') IS NULL
     OR to_regprocedure('public.can_view_route(uuid)') IS NULL OR to_regprocedure('public.auth_has_perm(text)') IS NULL OR to_regprocedure('public._is_general_admin()') IS NULL THEN RAISE EXCEPTION 'DEPENDENCIA_FALTANTE. No se modificó nada.'; END IF;
  IF (SELECT md5(replace(prosrc, E'\r\n', E'\n')) FROM pg_proc WHERE oid = 'public.set_stop_outcome(uuid,text,text,text,text,jsonb)'::regprocedure) <> '5d26e5af27a068596cc6875bd6ee8bbf' THEN
    RAISE EXCEPTION 'PRODUCCION_DISTINTA: set_stop_outcome no coincide (por contenido) con V4.21. No se modificó nada.'; END IF;
  IF (SELECT md5(replace(prosrc, E'\r\n', E'\n')) FROM pg_proc WHERE oid = 'public.delivery_identity_lookup(uuid,text,text)'::regprocedure) <> '4a882db134526ea21876126f44208b4d' THEN
    RAISE EXCEPTION 'PRODUCCION_DISTINTA: delivery_identity_lookup no coincide (por contenido) con rc4_1_scope_email. No se modificó nada.'; END IF;
  IF (SELECT md5(replace(prosrc, E'\r\n', E'\n')) FROM pg_proc WHERE oid = 'public.search_deliveries(text)'::regprocedure) <> 'ee7ebbff796dac0844064280bfc3ae2a' THEN
    RAISE EXCEPTION 'PRODUCCION_DISTINTA: search_deliveries no coincide (por contenido) con V4.26. No se modificó nada.'; END IF;
END $guard$;

-- ---------- 1) GESTIONES POR PARADA (solo agregado) ----------
create table public.stop_followups (
  id bigint generated always as identity primary key,
  route_id uuid not null references public.routes(id), stop_id uuid not null references public.route_stops(id),
  kind text not null check (kind in ('GESTION', 'OBSERVACION', 'INCIDENCIA', 'SOLICITUD')),
  note text not null check (length(btrim(note)) >= 3 and length(note) <= 1000),
  request_id uuid references public.route_approval_requests(id), op_id text unique,
  created_by uuid not null references public.profiles(id), created_at timestamptz not null default now());
create index stop_followups_route_idx on public.stop_followups(route_id, created_at);
alter table public.stop_followups enable row level security;
create policy stop_followups_read on public.stop_followups for select to authenticated using (public.can_view_route(route_id));
revoke all on table public.stop_followups from public, anon, authenticated; grant select on table public.stop_followups to authenticated;
create or replace function public.trg_stop_followups_immutable() returns trigger language plpgsql as $$
begin raise exception 'APPEND_ONLY: el historial de gestiones no se modifica ni se borra' using errcode = '42501'; end; $$;
create trigger stop_followups_immutable before update or delete on public.stop_followups for each row execute function public.trg_stop_followups_immutable();

create or replace function public.add_stop_followup(p_stop uuid, p_kind text, p_note text, p_request uuid default null, p_op_id text default null)
returns public.stop_followups language plpgsql security definer set search_path = public as $$
declare st public.route_stops; q public.route_approval_requests; f public.stop_followups;
begin
  -- B2 (auditoría de Work): el orden es 1) usuario ACTIVO, 2) permiso y ALCANCE sobre la hoja y la parada, 3) correspondencia del op_id;
  -- SOLO entonces se devuelve un reintento. Un op_id conocido de otro equipo nunca revela información.
  if not exists (select 1 from public.profiles where id = auth.uid() and status = 'ACTIVO') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if not (public.auth_has_perm('requests.create') or public.auth_has_perm('users.manage')) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into st from public.route_stops where id = p_stop; if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  if not public.can_view_route(st.route_id) then raise exception 'FORBIDDEN_ROUTE: la hoja está fuera de tu alcance' using errcode = '42501'; end if;
  if p_op_id is not null then
    select * into f from public.stop_followups where op_id = p_op_id;
    if found then   -- reintento idempotente legítimo: MISMO autor, MISMA parada, MISMA operación
      if f.created_by = auth.uid() and f.stop_id = st.id and f.kind = p_kind and f.request_id is not distinct from p_request then return f; end if;
      raise exception 'OP_ID_CONFLICT: el identificador de la operación ya fue usado para otra gestión' using errcode = '23505';   -- sin datos de la otra gestión
    end if;
  end if;
  if coalesce(p_kind, '') not in ('GESTION', 'OBSERVACION', 'INCIDENCIA', 'SOLICITUD') then raise exception 'BAD_KIND' using errcode = '22023'; end if;
  if length(btrim(coalesce(p_note, ''))) < 3 then raise exception 'NOTE_REQUIRED: describí la gestión' using errcode = '23514'; end if;
  if p_request is not null then
    select * into q from public.route_approval_requests where id = p_request;
    if not found or q.route_id is distinct from st.route_id or q.requested_by <> auth.uid() or p_kind <> 'SOLICITUD' then raise exception 'BAD_REQUEST_LINK' using errcode = '22023'; end if;
  elsif p_kind = 'SOLICITUD' then raise exception 'BAD_REQUEST_LINK' using errcode = '22023'; end if;
  insert into public.stop_followups(route_id, stop_id, kind, note, request_id, op_id, created_by) values (st.route_id, st.id, p_kind, btrim(p_note), p_request, p_op_id, auth.uid()) returning * into f;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'STOP_FOLLOWUP_' || p_kind, 'route', st.route_id::text,
    jsonb_build_object('stop', st.id, 'client', st.client_name, 'outcome', st.outcome, 'note', btrim(p_note), 'request', p_request));
  return f;   -- el resultado de la parada NO se modifica
end; $$;

-- ---------- 3) RECEPTOR: DNI, CUIL o CUIT · SIN BLOQUEO, CON INCIDENCIA Y ALERTA ----------
alter table public.stop_evidence add column if not exists receiver_doc_type text check (receiver_doc_type in ('DNI', 'CUIL', 'CUIT'));   -- histórico: NULL = CUIL
alter table public.stop_evidence add column if not exists receiver_doc_declared text;   -- EXACTAMENTE como fue declarado (aunque sea inválido)
alter table public.stop_evidence add column if not exists receiver_doc_valid boolean;   -- true solo si pasó la validación; NULL en históricos
alter table public.stop_evidence add column if not exists receiver_doc_issue text;      -- motivo de la advertencia (NULL = sin advertencia)
alter table public.stop_evidence add column if not exists receiver_cuit text check (receiver_cuit ~ '^[0-9]{11}$');   -- CUIT VÁLIDO (empresa o persona): NUNCA en receiver_cuil

-- clasificación del documento (NO bloquea: devuelve el motivo o NULL si es válido). Recibe lo DECLARADO: se normalizan puntos, espacios y guiones
-- habituales; letras u otros caracteres generan advertencia («DOCUMENTO CON CARACTERES NO VÁLIDOS»)
create or replace function public._receiver_doc_issue(p_type text, p_raw text, p_required boolean) returns text language plpgsql immutable set search_path = public as $$
declare t text := coalesce(nullif(upper(btrim(p_type)), ''), 'CUIL'); raw text := btrim(coalesce(p_raw, '')); d text := regexp_replace(coalesce(p_raw, ''), '\D', '', 'g');
begin
  if raw = '' then return case when p_required then 'DOCUMENTO FALTANTE' end; end if;
  if t not in ('DNI', 'CUIL', 'CUIT') then return 'TIPO DE DOCUMENTO NO RECONOCIDO'; end if;
  if raw !~ '^[0-9 .\-–]+$' then return 'DOCUMENTO CON CARACTERES NO VÁLIDOS'; end if;
  if d = '' then return case when p_required then 'DOCUMENTO FALTANTE' end; end if;
  if t = 'DNI' then
    if d ~ '^[0-9]{7,8}$' then return null; end if;
    if length(d) = 11 then return 'PARECE UN CUIL O CUIT: SE ELIGIÓ DNI'; end if;
    return 'DNI CON CANTIDAD DE DÍGITOS INCORRECTA';
  end if;
  if length(d) in (7, 8) then return 'PARECE UN DNI: SE ELIGIÓ ' || t; end if;
  if length(d) <> 11 then return t || ' CON CANTIDAD DE DÍGITOS INCORRECTA'; end if;
  if not public._cuit_valid(d) then return t || ' CON DÍGITO VERIFICADOR INVÁLIDO'; end if;
  if t = 'CUIL' and left(d, 2) not in ('20', '23', '24', '27') then return 'PREFIJO DE EMPRESA: PARECE UN CUIT'; end if;
  return null;
end; $$;

-- incidencia de documento: UNA por entrega (la clave es la parada); lo declarado es INALTERABLE
create table public.receiver_doc_reviews (
  stop_id uuid primary key references public.route_stops(id), route_id uuid not null references public.routes(id),
  driver_id uuid references public.profiles(id), supervisor_id uuid references public.profiles(id),
  receiver_name text, declared_type text, declared_doc text, issue text not null,
  status text not null default 'A_REVISAR' check (status in ('A_REVISAR', 'CORREGIDO')), created_at timestamptz not null default now(),
  corrected_type text check (corrected_type in ('DNI', 'CUIL', 'CUIT')), corrected_doc text, corrected_by uuid references public.profiles(id), corrected_at timestamptz, correction_reason text);
create index receiver_doc_reviews_open_idx on public.receiver_doc_reviews(status, supervisor_id);
-- historial de CORRECCIONES / RECTIFICACIONES: solo agregado (ninguna corrección sobrescribe a otra en silencio)
create table public.receiver_doc_corrections (
  id bigint generated always as identity primary key, stop_id uuid not null references public.receiver_doc_reviews(stop_id), seq int not null,
  corrected_type text not null check (corrected_type in ('DNI', 'CUIL', 'CUIT')), corrected_doc text not null, reason text not null,
  is_rectification boolean not null default false, corrected_by uuid not null references public.profiles(id), corrected_at timestamptz not null default now(), unique (stop_id, seq));
alter table public.receiver_doc_corrections enable row level security; revoke all on table public.receiver_doc_corrections from public, anon, authenticated;
create or replace function public.trg_receiver_doc_corrections_immutable() returns trigger language plpgsql as $$
begin raise exception 'APPEND_ONLY: el historial de correcciones no se modifica ni se borra' using errcode = '42501'; end; $$;
create trigger receiver_doc_corrections_immutable before update or delete on public.receiver_doc_corrections for each row execute function public.trg_receiver_doc_corrections_immutable();
alter table public.receiver_doc_reviews enable row level security;   -- sin políticas: SOLO por funciones (alcance y enmascarado)
revoke all on table public.receiver_doc_reviews from public, anon, authenticated;
create or replace function public.trg_receiver_doc_reviews_guard() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception 'APPEND_ONLY: las incidencias de documento no se borran' using errcode = '42501'; end if;
  if (new.stop_id, new.route_id, new.driver_id, new.receiver_name, new.declared_type, new.declared_doc, new.issue, new.created_at)
     is distinct from (old.stop_id, old.route_id, old.driver_id, old.receiver_name, old.declared_type, old.declared_doc, old.issue, old.created_at) then
    raise exception 'APPEND_ONLY: el documento declarado y su advertencia no se modifican' using errcode = '42501'; end if;
  return new;
end; $$;
create trigger receiver_doc_reviews_guard before update or delete on public.receiver_doc_reviews for each row execute function public.trg_receiver_doc_reviews_guard();

-- ¿quién puede ver/corregir una incidencia? el ADMINISTRADOR GENERAL ACTIVO (rol real), o el usuario ACTIVO con rol SUPERIOR DESPACHO que HOY es el Superior asignado al transportista
create or replace function public._doc_review_responsible(p_driver uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles me where me.id = auth.uid() and me.status = 'ACTIVO'
    and (public._is_general_admin() or (me.role = 'SUPERVISOR_DESPACHO' and me.id = (select d.supervisor_user_id from public.profiles d where d.id = p_driver))));
  -- B1 (auditoría de Work): el acceso GLOBAL es solo del Administrador General ACTIVO por su ROL REAL (_is_general_admin); users.manage DELEGADO no lo concede
$$;
-- crea la incidencia y la alerta (la alerta, en bloque protegido: si falla, la entrega NO se deshace)
create or replace function public._receiver_doc_flag(st public.route_stops, r public.routes, p_name text, p_type text, p_raw text, p_issue text) returns void language plpgsql security definer set search_path = public as $$
declare sup uuid; ins boolean := false; body text;
begin
  select supervisor_user_id into sup from public.profiles where id = auth.uid();
  insert into public.receiver_doc_reviews(stop_id, route_id, driver_id, supervisor_id, receiver_name, declared_type, declared_doc, issue)
    values (st.id, r.id, auth.uid(), sup, p_name, p_type, nullif(p_raw, ''), p_issue) on conflict (stop_id) do nothing returning true into ins;
  if not coalesce(ins, false) then return; end if;   -- reintento (cola sin conexión): ni otra incidencia ni otra alerta
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'RECEIVER_DOC_FLAGGED', 'route', r.id::text, jsonb_build_object('stop', st.id, 'type', p_type, 'issue', p_issue));
  begin
    body := 'Hoja ' || coalesce(r.number, '') || ' · Pedido ' || coalesce(array_to_string(st.order_numbers, ' + '), '—') || ' · ' || coalesce(st.client_name, '') || ' · ' || p_issue;
    insert into public.notifications(user_id, route_id, route_version, type, title, body)
      select u.id, r.id, coalesce(r.version, 1), 'RECEIVER_DOC_REVIEW', 'DOCUMENTO DEL RECEPTOR A REVISAR', body from public.profiles u
       where u.status = 'ACTIVO' and (u.role = 'ADMIN' or (u.id = sup and u.role = 'SUPERVISOR_DESPACHO')) on conflict do nothing;   -- Superior AUTORIZADO (rol vigente)
  exception when others then null;   -- la alerta nunca deshace la entrega (la incidencia ya quedó registrada)
  end;
end; $$;

-- listado para la campana y la revisión: Administración ve todas; un Superior SOLO las de su transportista; documento ENMASCARADO sin signatures.view
create or replace function public.list_receiver_doc_reviews(p_status text default 'A_REVISAR') returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me public.profiles; adm boolean; sig boolean; out jsonb;
begin
  select * into me from public.profiles where id = auth.uid() and status = 'ACTIVO'; if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  adm := public._is_general_admin(); sig := public.auth_has_perm('signatures.view');   -- B1: rol real, no permiso delegado
  if not adm and me.role <> 'SUPERVISOR_DESPACHO' then return '[]'::jsonb; end if;   -- responsabilidad VIGENTE (no la del momento de la entrega)
  select coalesce(jsonb_agg(jsonb_build_object('stop_id', v.stop_id, 'route_id', v.route_id, 'route_number', r.number, 'orders', s.order_numbers, 'client', s.client_name,
      'driver', (select full_name from public.profiles where id = v.driver_id), 'receiver_name', v.receiver_name, 'declared_type', v.declared_type,
      'doc', case when sig then v.declared_doc when v.declared_doc is null then null else '•••' || right(regexp_replace(v.declared_doc, '\D', '', 'g'), 3) end,
      'issue', v.issue, 'status', v.status, 'created_at', v.created_at, 'corrected_type', v.corrected_type,
      'corrected_doc', case when sig then v.corrected_doc when v.corrected_doc is null then null else '•••' || right(v.corrected_doc, 3) end,
      'corrected_by', (select full_name from public.profiles where id = v.corrected_by), 'corrected_at', v.corrected_at, 'correction_reason', v.correction_reason,
      'corrections', (select coalesce(jsonb_agg(jsonb_build_object('seq', c.seq, 'type', c.corrected_type, 'doc', case when sig then c.corrected_doc else '•••' || right(c.corrected_doc, 3) end, 'reason', c.reason,
          'rectificacion', c.is_rectification, 'by', (select full_name from public.profiles where id = c.corrected_by), 'at', c.corrected_at) order by c.seq), '[]') from public.receiver_doc_corrections c where c.stop_id = v.stop_id),
      'can_correct', public._doc_review_responsible(v.driver_id)) order by v.created_at desc), '[]') into out
    from public.receiver_doc_reviews v join public.routes r on r.id = v.route_id join public.route_stops s on s.id = v.stop_id
   where public._doc_review_responsible(v.driver_id) and (coalesce(p_status, 'A_REVISAR') = 'TODOS' or v.status = coalesce(p_status, 'A_REVISAR'));
  return out;
end; $$;

-- corrección posterior (Administración o el Superior responsable): documento VÁLIDO + motivo. La PRIMERA es una corrección; las siguientes
-- SOLO como RECTIFICACIÓN explícita (p_rectify), que agrega una entrada nueva al historial inmutable. La evidencia original NO se toca.
create or replace function public.correct_receiver_doc(p_stop uuid, p_type text, p_doc text, p_reason text, p_rectify boolean default false) returns jsonb language plpgsql security definer set search_path = public as $$
declare v public.receiver_doc_reviews; d text := regexp_replace(coalesce(p_doc, ''), '\D', '', 'g'); t text := upper(btrim(coalesce(p_type, ''))); iss text; n int;
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and status = 'ACTIVO') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into v from public.receiver_doc_reviews where stop_id = p_stop for update; if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  if not public._doc_review_responsible(v.driver_id) then raise exception 'FORBIDDEN: solo Administración o el Superior Despacho ACTIVO asignado hoy al transportista' using errcode = '42501'; end if;
  if length(btrim(coalesce(p_reason, ''))) < 3 then raise exception 'REASON_REQUIRED: indicá por qué se corrige' using errcode = '23514'; end if;
  if v.status = 'CORREGIDO' and not coalesce(p_rectify, false) then
    raise exception 'ALREADY_CORRECTED: ya fue corregido; para cambiarlo usá RECTIFICAR (queda en el historial)' using errcode = '23514'; end if;
  if v.status = 'A_REVISAR' and coalesce(p_rectify, false) then raise exception 'NOTHING_TO_RECTIFY: todavía no hay una corrección para rectificar' using errcode = '23514'; end if;
  iss := public._receiver_doc_issue(t, p_doc, true);
  if iss is not null then raise exception 'DOC_STILL_INVALID: la corrección tampoco es válida (%)', iss using errcode = '23514'; end if;
  select coalesce(max(seq), 0) + 1 into n from public.receiver_doc_corrections where stop_id = p_stop;
  insert into public.receiver_doc_corrections(stop_id, seq, corrected_type, corrected_doc, reason, is_rectification, corrected_by) values (p_stop, n, t, d, btrim(p_reason), n > 1, auth.uid());
  update public.receiver_doc_reviews set status = 'CORREGIDO', corrected_type = t, corrected_doc = d, corrected_by = auth.uid(), corrected_at = now(), correction_reason = btrim(p_reason) where stop_id = p_stop returning * into v;   -- vigente = la última del historial
  insert into public.audit_log(actor_id, action, target_type, target_id, before, after) values (auth.uid(), case when n > 1 then 'RECEIVER_DOC_RECTIFIED' else 'RECEIVER_DOC_CORRECTED' end, 'route', v.route_id::text,
    jsonb_build_object('stop', v.stop_id, 'declared_type', v.declared_type, 'issue', v.issue), jsonb_build_object('type', t, 'reason', btrim(p_reason), 'seq', n));
  return jsonb_build_object('stop_id', v.stop_id, 'status', v.status, 'corrected_type', v.corrected_type, 'seq', n);
end; $$;
CREATE OR REPLACE FUNCTION public.set_stop_outcome(p_stop uuid, p_outcome text, p_note text, p_reason text, p_op_id text, p_extra jsonb DEFAULT NULL::jsonb)
 RETURNS route_stops
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_doc_type text; v_doc text; v_doc_raw text; v_doc_issue text; v_cuit text; st public.route_stops; r public.routes; cristian boolean; v_commercial boolean; v_task boolean; v_cuil text; v_email text; v_dni text; v_receipt boolean := false; ev jsonb := coalesce(p_extra->'evidence', '{}'); col jsonb := p_extra->'collection'; loc jsonb; sig bytea;
begin
  select * into st from public.route_stops where id = p_stop;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  r := public._my_route(st.route_id);
  -- Comportamiento por tipo de parada: solo PEDIDO es entrega comercial al cliente (email, Recibido Conforme, cobranza, identidad).
  v_commercial := coalesce(st.stop_type, 'PEDIDO') = 'PEDIDO';
  v_task := st.stop_type = 'TAREA';
  if p_op_id is not null and exists (select 1 from public.stop_outcome_ops where op_id = p_op_id) then return st; end if;
  if r.operational_status <> 'EN_CURSO' then raise exception 'BAD_STATE: iniciá el recorrido o la hoja ya está cerrada' using errcode = '23514'; end if;
  if p_outcome not in ('ENTREGADO','ENTREGA_PARCIAL','NO_ENTREGADO','REPROGRAMAR') then raise exception 'BAD_OUTCOME' using errcode = '22023'; end if;
  if p_outcome = 'ENTREGA_PARCIAL' and coalesce(trim(p_note), '') = '' then raise exception 'NOTE_REQUIRED: entrega parcial exige observación' using errcode = '23514'; end if;
  if p_outcome in ('NO_ENTREGADO','REPROGRAMAR') and coalesce(trim(p_reason), '') = '' then raise exception 'REASON_REQUIRED: indicá el motivo' using errcode = '23514'; end if;
  cristian := exists (select 1 from public.carriers where id = r.carrier_id and report_group = 'CRISTIAN_TORRES');
  if p_outcome in ('ENTREGADO','ENTREGA_PARCIAL') then
    -- TAREA: no se exige firma ni receptor como en una entrega comercial (alcanza GPS u observación). El resto, igual que antes.
    if not v_task and (coalesce(trim(ev->>'receiver_name'), '') = '' or coalesce(ev->>'signature_png_b64', '') = '') then raise exception 'EVIDENCE_REQUIRED: nombre del receptor y firma obligatorios' using errcode = '23514'; end if;
    sig := case when coalesce(ev->>'signature_png_b64', '') <> '' then decode(ev->>'signature_png_b64', 'base64') end;
    -- V4.17: entrega COMERCIAL de AMBOS perfiles (transportista externo e interno): CUIL + identidad con DNI registrado
    -- (antes: solo Cristian). _register_identity vincula la foto nueva o reutiliza una identidad ya registrada.
    if v_commercial then
      -- V4.28 (corregido): el documento NUNCA bloquea la entrega. Se CLASIFICA (válido / a revisar con motivo) y se guarda tal como fue declarado.
      v_doc_raw := btrim(coalesce(nullif(ev->>'receiver_doc_declared', ''), nullif(ev->>'receiver_doc', ''), ev->>'cuil', ''));
      v_doc := regexp_replace(v_doc_raw, '\D', '', 'g');
      v_doc_type := upper(nullif(btrim(coalesce(ev->>'receiver_doc_type', '')), ''));
      v_doc_issue := public._receiver_doc_issue(v_doc_type, v_doc_raw, true);
      v_cuil := case when v_doc_issue is null and coalesce(v_doc_type, 'CUIL') = 'CUIL' then v_doc end;   -- receiver_cuil: SOLO CUIL de persona
      v_cuit := case when v_doc_issue is null and v_doc_type = 'CUIT' then v_doc end;                    -- el CUIT válido va a receiver_cuit (nunca como CUIL)
      if v_doc_issue is null and coalesce(v_doc_type, 'CUIL') = 'CUIL' then perform public._register_identity(v_cuil, ev); end if;   -- SOLO un CUIL VÁLIDO de persona vincula una foto antigua (nunca un CUIT)
    else
      -- Transportista Interno: documento OPCIONAL; si se carga, se clasifica igual (sin bloquear)
      v_doc_raw := btrim(coalesce(nullif(ev->>'receiver_doc_declared', ''), nullif(ev->>'receiver_doc', ''), ev->>'cuil', ''));
      v_doc := regexp_replace(v_doc_raw, '\D', '', 'g');
      v_doc_type := upper(nullif(btrim(coalesce(ev->>'receiver_doc_type', '')), ''));
      v_doc_issue := case when v_doc_raw = '' then null else public._receiver_doc_issue(v_doc_type, v_doc_raw, false) end;
      v_cuil := case when v_doc <> '' and v_doc_issue is null and coalesce(v_doc_type, 'CUIL') = 'CUIL' then v_doc end;
      v_cuit := case when v_doc <> '' and v_doc_issue is null and v_doc_type = 'CUIT' then v_doc end;
    end if;
    
-- RC4.1: email del receptor (segunda pantalla). Opcional; si viene, debe ser válido.
    v_email := nullif(lower(trim(coalesce(ev->>'email', ''))), '');
    -- V4.21: el email del receptor es OPCIONAL (ambos transportistas). Si viene, se valida el formato (abajo) y se genera el Recibido
    -- Conforme; si no viene, la entrega se confirma igual y NO se intenta enviar el Recibido Conforme.
    if v_email is not null and not public.is_valid_email(v_email) then raise exception 'EMAIL_INVALID: el email no es válido' using errcode = '23514'; end if;
    -- V4.28: receiver_dni SOLO con un DNI VÁLIDO (declarado o derivado de un CUIL válido); un dato inválido no bloquea ni se guarda como verificado
    v_dni := case when v_doc_type = 'DNI' and v_doc_issue is null then v_doc end;
    if v_dni is null and v_cuil is not null and coalesce(v_doc_type, 'CUIL') = 'CUIL' then v_dni := substr(v_cuil, 3, 8); end if;
    if v_dni is null and coalesce(ev->>'dni', '') ~ '^\D*\d{7,8}\D*$' and v_doc_type is null then v_dni := regexp_replace(ev->>'dni', '\D', '', 'g'); end if;
  end if;
  -- cobranza (Cristian): el chofer no cambia el importe esperado
  -- V4.17: la cobranza es OPCIONAL (el chofer ya no la registra). Si se informa, se valida igual que antes; si no, no se registra
  -- ningún cobro y los datos de cobranza existentes de la parada se CONSERVAN (no se inventan ni se borran).
  if v_commercial and st.task in ('COBRANZA','AMBAS') and col is not null and coalesce(col->>'status', 'PENDIENTE') <> 'PENDIENTE' then
    if col->>'status' not in ('COBRADO','COBRO_PARCIAL','NO_COBRADO') then raise exception 'BAD_COLLECTION' using errcode = '22023'; end if;
    if col->>'status' in ('COBRO_PARCIAL','NO_COBRADO') and coalesce(trim(col->>'note'), '') = '' then raise exception 'COLLECTION_NOTE_REQUIRED: cobro parcial exige observación y no cobrado exige motivo' using errcode = '23514'; end if;
    if col->>'status' in ('COBRADO','COBRO_PARCIAL') and coalesce((col->>'amount')::numeric, 0) <= 0 then raise exception 'COLLECTION_AMOUNT_REQUIRED' using errcode = '23514'; end if;
  end if;
  loc := public._loc(p_extra->'location', st);
  update public.route_stops set outcome = p_outcome, outcome_at = now(), outcome_by = auth.uid(), outcome_note = nullif(trim(p_note),''), outcome_reason = nullif(trim(p_reason),''),
    finish_location = loc, location_warning = coalesce(case when loc->>'outside_m' is not null then 'FUERA DEL RADIO (' || (loc->>'outside_m') || ' m)' end, location_warning),
    collection_status = case when st.task in ('COBRANZA','AMBAS') and coalesce(col->>'status','PENDIENTE') <> 'PENDIENTE' then col->>'status' else collection_status end,
    collected_amount = case when st.task in ('COBRANZA','AMBAS') and coalesce(col->>'status','PENDIENTE') <> 'PENDIENTE' then nullif(col->>'amount','')::numeric else collected_amount end,
    payment_mode = case when st.task in ('COBRANZA','AMBAS') and coalesce(col->>'status','PENDIENTE') <> 'PENDIENTE' then col->>'mode' else payment_mode end,
    collection_note = case when st.task in ('COBRANZA','AMBAS') and coalesce(col->>'status','PENDIENTE') <> 'PENDIENTE' then nullif(trim(col->>'note'),'') else collection_note end
  where id = p_stop returning * into st;
  if p_outcome in ('ENTREGADO','ENTREGA_PARCIAL') then
    -- La entrega guarda el email USADO (inmutable aunque el perfil cambie después)
    if sig is not null then
      insert into public.stop_evidence(stop_id, receiver_name, signature_png, signature_sha256, receiver_cuil, created_by, receiver_email, receiver_dni, evidence_kind, receiver_doc_type, receiver_doc_declared, receiver_doc_valid, receiver_doc_issue, receiver_cuit)
      values (p_stop, coalesce(nullif(trim(ev->>'receiver_name'), ''), 'Sin receptor (tarea)'), sig, encode(sha256(sig), 'hex'), v_cuil, auth.uid(), case when v_commercial then v_email end, v_dni,
              case when st.stop_type = 'UBICACION_INTERNA' then 'RECEPCION_INTERNA' when v_task then 'TAREA' else 'ENTREGA_CLIENTE' end, case when v_doc_type in ('DNI', 'CUIL', 'CUIT') then v_doc_type when v_doc_type is null and v_doc <> '' then 'CUIL' end,
              nullif(v_doc_raw, ''), v_doc_issue is null and v_doc <> '', v_doc_issue, v_cuit)
      on conflict (stop_id) do nothing;
      -- V4.28: documento A REVISAR → UNA incidencia por entrega (idempotente) + alertas a Administración y al Superior responsable (sin bloquear)
      if v_doc_issue is not null then perform public._receiver_doc_flag(st, r, coalesce(nullif(trim(ev->>'receiver_name'), ''), 'Sin nombre'), v_doc_type, v_doc_raw, v_doc_issue); end if;
    end if;
    -- RECEPCIÓN INTERNA DE TRASLADO: queda trazado qué pedidos llegaron a qué sucursal, quién recibió, quién trasladó, cuándo y dónde
    if st.stop_type = 'UBICACION_INTERNA' then
      insert into public.audit_log(actor_id, action, target_type, target_id, after)
      values (auth.uid(), 'INTERNAL_TRANSFER_RECEIVED', 'route_stop', p_stop::text, jsonb_build_object(
        'route_id', st.route_id, 'route_number', r.number, 'internal_location_key', st.internal_location_key, 'location_name', st.client_name, 'address', st.address,
        'order_numbers', to_jsonb(st.order_numbers), 'outcome', p_outcome, 'receiver_name', trim(ev->>'receiver_name'), 'signature_sha256', encode(sha256(sig), 'hex'),
        'transported_by', auth.uid(), 'at', now(), 'gps', loc));
    end if;
    -- Perfil reutilizable (misma capa de identidad que el DNI): nombre, DNI y email para próximas entregas
    if v_commercial and v_cuil is not null and coalesce(v_doc_type, 'CUIL') = 'CUIL' and v_doc_issue is null then perform public._upsert_identity_profile(v_cuil, trim(ev->>'receiver_name'), v_dni, v_email, st.client_key); end if;   -- V4.28: el padrón de identidad PERSONAL solo con un CUIL VÁLIDO (nunca un CUIT de empresa ni un documento no validado)
    -- Recibido Conforme: entrega TOTAL confirmada + email válido → comprobante único + envío automático (la falla del email nunca revierte la entrega)
    if v_commercial and p_outcome = 'ENTREGADO' and v_email is not null then perform public._create_delivery_receipt(st, r, trim(ev->>'receiver_name'), v_email); v_receipt := true; end if;
    if v_commercial and coalesce(trim(st.customer_email), '') <> '' and not v_receipt then
      insert into public.customer_email_jobs(route_id, stop_id, kind, recipient, idempotency_key)
      values (st.route_id, st.id, case when p_outcome = 'ENTREGADO' then 'DELIVERED' else 'PARTIAL' end, lower(trim(st.customer_email)), st.route_id || '|' || st.id || '|' || case when p_outcome = 'ENTREGADO' then 'DELIVERED' else 'PARTIAL' end)
      on conflict (idempotency_key) do nothing;
    end if;
  end if;
  if p_op_id is not null then insert into public.stop_outcome_ops(op_id, stop_id) values (p_op_id, p_stop); end if;
  perform public._queue_on_the_way(st.route_id);
  return st;
end; $function$;

-- delivery_identity_lookup: un CUIT (aun histórico) NUNCA se devuelve como CUIL personal ni consulta el padrón de identidad
create or replace function public.delivery_identity_lookup(p_stop uuid, p_cuil text default null, p_dni text default null) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare st public.route_stops; r public.routes; p public.customer_identity_docs; c text := nullif(regexp_replace(coalesce(p_cuil,''), '\D', '', 'g'), ''); d text := nullif(regexp_replace(coalesce(p_dni,''), '\D', '', 'g'), ''); ev record;
begin
  select * into st from public.route_stops where id = p_stop;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  select * into r from public.routes where id = st.route_id;
  if not (r.responsable_id = auth.uid() or public.auth_is_admin()) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if c is not null and c ~ '^(20|23|24|27)[0-9]{9}$' then select * into p from public.customer_identity_docs where cuil = c; end if;   -- V4.28: el padrón PERSONAL solo se consulta con un CUIL de persona (nunca un CUIT)
  if p.cuil is null and d is not null then select * into p from public.customer_identity_docs where dni = d and cuil ~ '^(20|23|24|27)[0-9]{9}$' order by updated_at desc nulls last limit 1; end if;   -- B3 (auditoría de Work): por DNI, SOLO un CUIL de persona (nunca un CUIT histórico)
  if p.cuil is not null then
    return jsonb_build_object('source', case when c is not null and p.cuil = c then 'CUIL' else 'DNI' end, 'cuil', case when p.cuil ~ '^(20|23|24|27)[0-9]{9}$' then p.cuil end,   -- B3: segunda capa
 'dni', p.dni, 'full_name', p.full_name, 'email', p.email,
      'has_dni_photo', p.storage_path is not null or p.dni_photo is not null);
  end if;
  if coalesce(st.client_key, '') <> '' then
    select e.receiver_name, e.receiver_email, e.receiver_cuil, e.receiver_dni, e.receiver_doc_type, e.receiver_doc_valid into ev from public.stop_evidence e join public.route_stops s2 on s2.id = e.stop_id
      where s2.client_key = st.client_key and e.receiver_email is not null order by e.created_at desc limit 1;
    if ev.receiver_email is not null then
      return jsonb_build_object('source', 'CLIENTE', 'cuil', case when ev.receiver_cuil ~ '^(20|23|24|27)[0-9]{9}$' and coalesce(ev.receiver_doc_type, 'CUIL') = 'CUIL' and ev.receiver_doc_valid is not false then ev.receiver_cuil end,   -- V4.28: nunca un CUIT (ni histórico) como CUIL personal
 'dni', ev.receiver_dni, 'full_name', ev.receiver_name, 'email', ev.receiver_email,
        'has_dni_photo', ev.receiver_cuil is not null and exists (select 1 from public.customer_identity_docs x where x.cuil = ev.receiver_cuil and (x.storage_path is not null or x.dni_photo is not null)));
    end if;
  end if;
  return null;
end; $$;

-- search_deliveries: devuelve también tipo, CUIT, DNI y lo declarado, con el MISMO control (signatures.view) que el CUIL
create or replace function public.search_deliveries(p_query text) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me public.profiles; q text := btrim(coalesce(p_query, '')); dg text; qpv text; qnum text; sig boolean; out jsonb := '[]'; rec record;
begin
  select * into me from public.profiles where id = auth.uid() and status = 'ACTIVO';
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  dg := regexp_replace(q, '\D', '', 'g');
  if length(dg) < 3 and q !~ '^[0-9]{2}-[0-9]{6}$' then raise exception 'QUERY_TOO_SHORT: ingresá al menos 3 dígitos' using errcode = '22023'; end if;
  qnum := ltrim(case when q ~ '-' then split_part(regexp_replace(q, '[^0-9-]', '', 'g'), '-', 2) else dg end, '0');
  qpv := case when q ~ '-' then ltrim(split_part(regexp_replace(q, '[^0-9-]', '', 'g'), '-', 1), '0') end;
  sig := false; -- Se verifica por hoja con la MISMA protección de las políticas RLS vigentes.
  for rec in
    select r.id rid, r.number, r.operational_status, r.published_at, r.started_at, r.completed_at, r.carrier_id, c.name carrier_name, rp.full_name responsable_name,
           s.id sid, s.client_name, s.address, s.order_numbers, s.outcome, s.outcome_note, s.arrived_at, s.stop_type,
           (select x->'r'->>'fecha' from jsonb_array_elements(coalesce(r.sheet_snapshot->'pdf_model'->'data', '[]')) x where x->'r' ? 'fecha' limit 1) sheet_date,
           (select string_agg(distinct d, ' · ') from jsonb_array_elements(coalesce(r.sheet_snapshot->'pdf_model'->'data', '[]')) x, lateral (values (x->'r'->>'mainDoc'), (x->'r'->>'shipDoc')) v(d)
              where d is not null and d <> '' and (x->'r'->>'mainOrder' = any(s.order_numbers) or x->'r'->>'shipOrder' = any(s.order_numbers))) docs,
           ev.receiver_name, ev.receiver_cuil, ev.receiver_cuit, ev.receiver_dni, ev.receiver_doc_type, ev.receiver_doc_declared, ev.receiver_doc_valid, ev.created_at received_at, (ev.stop_id is not null) has_signature, dr.receipt_number, dr.generated_at receipt_at
      from public.route_stops s join public.routes r on r.id = s.route_id left join public.carriers c on c.id = r.carrier_id left join public.profiles rp on rp.id = r.responsable_id
      left join public.stop_evidence ev on ev.stop_id = s.id left join public.delivery_receipts dr on dr.stop_id = s.id
     where r.operational_status <> 'BORRADOR' and coalesce(s.stop_type, 'PEDIDO') = 'PEDIDO'
       and (public._is_general_admin() or public.can_view_route_row(r.id, r.published_by, r.responsable_id))   -- SOLO hojas que el usuario puede ver (equipo / propias / todas)
       and ( dg = any(s.order_numbers) or r.number = q
          or exists (select 1 from jsonb_array_elements(coalesce(r.sheet_snapshot->'pdf_model'->'data', '[]')) x, lateral (values (x->'r'->>'mainDoc', x->'r'->>'mainOrder'), (x->'r'->>'shipDoc', x->'r'->>'shipOrder')) v(d, o)
                      where o = any(s.order_numbers) and d is not null and qnum <> ''
                        and ltrim(split_part(regexp_replace(d, '[^0-9-]', '', 'g'), '-', 2), '0') = qnum
                        and (qpv is null or ltrim(split_part(regexp_replace(d, '[^0-9-]', '', 'g'), '-', 1), '0') = qpv)) )
     order by r.published_at desc limit 30
  loop
    sig:=okd_delivery_security.may_read(rec.rid) and (public._is_general_admin() or public.can_view_route(rec.rid));
    out := out || jsonb_build_object('route_id', rec.rid, 'route_number', rec.number, 'route_status', rec.operational_status, 'carrier', coalesce(rec.carrier_name, rec.carrier_id), 'responsable', rec.responsable_name,
      'published_at', rec.published_at, 'started_at', rec.started_at, 'completed_at', rec.completed_at, 'sheet_date', rec.sheet_date,
      'stop_id', rec.sid, 'client_name', rec.client_name, 'address', rec.address, 'order_numbers', to_jsonb(rec.order_numbers), 'docs', rec.docs,
      'outcome', rec.outcome, 'outcome_note', rec.outcome_note, 'arrived_at', rec.arrived_at, 'received_at', rec.received_at,
      'has_receipt', rec.receipt_number is not null, 'signatures_visible', sig,
      -- datos personales y constancia SOLO con signatures.view (los demás ven el estado, no quién firmó)
      'receiver_name', case when sig then rec.receiver_name end, 'receiver_cuil', case when sig then rec.receiver_cuil end, 'receiver_cuit', case when sig then rec.receiver_cuit end, 'receiver_dni', case when sig then rec.receiver_dni end,
      'receiver_doc_type', case when sig then rec.receiver_doc_type end, 'receiver_doc_declared', case when sig then rec.receiver_doc_declared end, 'receiver_doc_valid', case when sig then rec.receiver_doc_valid end,
      'has_signature', case when sig then rec.has_signature end, 'receipt_number', case when sig then rec.receipt_number end, 'receipt_at', case when sig then rec.receipt_at end);
  end loop;
  return out;
end; $$;

-- ---------- 2) HISTORIAL DE CAMBIOS (legible, del servidor) ----------
create or replace function public.route_change_history(p_route uuid) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare out jsonb;
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and status = 'ACTIVO') or not public.can_view_route(p_route) then raise exception 'FORBIDDEN_ROUTE' using errcode = '42501'; end if;
  select coalesce(jsonb_agg(e order by (e->>'at') desc nulls last), '[]') into out from (
    select jsonb_build_object('at', coalesce((to_jsonb(s)->>'outcome_at')::timestamptz, (to_jsonb(s)->>'resolved_at')::timestamptz, (to_jsonb(s)->>'updated_at')::timestamptz), 'tipo', 'RESULTADO ORIGINAL', 'parada', s.client_name,
      'resultado', s.outcome, 'motivo', coalesce(s.outcome_note, to_jsonb(s)->>'outcome_reason'), 'usuario', (select full_name from public.profiles where id::text = to_jsonb(s)->>'outcome_by')) e
      from public.route_stops s where s.route_id = p_route and s.outcome <> 'PENDIENTE'
    union all
    select jsonb_build_object('at', c.at, 'tipo', case c.event_type when 'INTERNAL_STOP_ADDED' then 'PARADA AGREGADA' when 'INTERNAL_STOPS_REORDERED' then 'PARADAS REORDENADAS' else replace(c.event_type, '_', ' ') end,
      'parada', (select client_name from public.route_stops where id::text = c.stop_id), 'motivo', c.note, 'usuario', (select full_name from public.profiles where id = c.user_id))
      from public.route_change_events c where c.route_id = p_route
    union all
    select jsonb_build_object('at', q.requested_at, 'tipo', 'SOLICITUD · ' || case q.request_type when 'INTERNAL_ROUTE_CHANGE' then 'CAMBIOS DE RUTA INTERNA' when 'OTRO' then coalesce(q.payload->>'accion', 'OTRA ACCIÓN') else replace(q.request_type, '_', ' ') end,
      'parada', q.payload->>'parada', 'resultado', q.payload->>'resultado_actual', 'nuevo', q.payload->>'propuesta', 'motivo', q.reason, 'estado', q.status,
      'usuario', (select full_name from public.profiles where id = q.requested_by),
      'resuelto_por', (select full_name from public.profiles where id = q.reviewed_by), 'resuelto_at', q.reviewed_at, 'nota_resolucion', q.review_note)
      from public.route_approval_requests q where q.route_id = p_route
    union all
    select jsonb_build_object('at', v.created_at, 'tipo', 'DOCUMENTO DEL RECEPTOR A REVISAR', 'parada', (select client_name from public.route_stops where id = v.stop_id), 'motivo', v.issue,
      'estado', v.status, 'usuario', (select full_name from public.profiles where id = v.driver_id), 'resuelto_por', (select full_name from public.profiles where id = v.corrected_by),
      'resuelto_at', v.corrected_at, 'nota_resolucion', v.correction_reason)
      from public.receiver_doc_reviews v where v.route_id = p_route
    union all
    select jsonb_build_object('at', c.corrected_at, 'tipo', case when c.is_rectification then 'RECTIFICACIÓN DEL DOCUMENTO' else 'CORRECCIÓN DEL DOCUMENTO' end, 'parada', (select client_name from public.route_stops where id = c.stop_id),
      'motivo', c.reason, 'usuario', (select full_name from public.profiles where id = c.corrected_by))
      from public.receiver_doc_corrections c join public.receiver_doc_reviews v on v.stop_id = c.stop_id where v.route_id = p_route
    union all
    select jsonb_build_object('at', f.created_at, 'tipo', f.kind, 'parada', (select client_name from public.route_stops where id = f.stop_id), 'motivo', f.note,
      'estado', (select status from public.route_approval_requests where id = f.request_id), 'usuario', (select full_name from public.profiles where id = f.created_by))
      from public.stop_followups f where f.route_id = p_route
  ) x;
  return out;
end; $$;



do $$ declare f text; begin
  foreach f in array array['add_stop_followup(uuid,text,text,uuid,text)', 'route_change_history(uuid)', 'list_receiver_doc_reviews(text)', 'correct_receiver_doc(uuid,text,text,text,boolean)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon'; execute 'grant execute on function public.' || f || ' to authenticated'; end loop;
  foreach f in array array['_doc_review_responsible(uuid)', 'trg_stop_followups_immutable()', 'trg_receiver_doc_reviews_guard()', 'trg_receiver_doc_corrections_immutable()', '_receiver_doc_flag(public.route_stops,public.routes,text,text,text,text)', '_receiver_doc_issue(text,text,boolean)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon, authenticated'; end loop;
end $$;
DO $post$ BEGIN
  IF (SELECT prosrc FROM pg_proc WHERE oid = 'public.set_stop_outcome(uuid,text,text,text,text,jsonb)'::regprocedure) NOT LIKE '%_receiver_doc_flag%'
     OR (SELECT prosrc FROM pg_proc WHERE oid = 'public.set_stop_outcome(uuid,text,text,text,text,jsonb)'::regprocedure) ~ '(CUIL_INVALID|DNI_INVALID|DOC_TYPE_INVALID)'
     OR (SELECT prosrc FROM pg_proc WHERE oid = 'public.delivery_identity_lookup(uuid,text,text)'::regprocedure) NOT LIKE '%(20|23|24|27)%'
     OR (SELECT prosrc FROM pg_proc WHERE oid = 'public.search_deliveries(text)'::regprocedure) NOT LIKE '%receiver_cuit%'
     OR (SELECT prosrc FROM pg_proc WHERE oid = 'public.set_stop_outcome(uuid,text,text,text,text,jsonb)'::regprocedure) !~ 'coalesce\(v_doc_type, ''CUIL''\) = ''CUIL'' and v_doc_issue is null then perform public._upsert_identity_profile' OR to_regclass('public.receiver_doc_reviews') IS NULL THEN RAISE EXCEPTION 'HUELLA_FINAL_INESPERADA'; END IF;
END $post$;
COMMIT;
