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
