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
