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
