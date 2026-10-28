-- Pruebas de la PROPUESTA "Permitir asignación de hojas de ruta" (routes.receive_internal). Corre DESPUÉS de g2_revision_test
-- (reutiliza A=Admin, S=Superior, G=Transportista interno, ubicaciones y vehículo). Usuarios y datos FICTICIOS.
\set ON_ERROR_STOP on
\set A   'e0000000-0000-0000-0000-00000000000a'
\set S   'e0000000-0000-0000-0000-000000000005'
\set G   'e0000000-0000-0000-0000-000000000007'
\set OP  'e0000000-0000-0000-0000-0000000000d1'
\set OP2 'e0000000-0000-0000-0000-0000000000d2'
insert into auth.users(id, email) values (:'OP', 'operador.qa@ejemplo.test'), (:'OP2', 'operador2.qa@ejemplo.test') on conflict do nothing;
select set_config('okd.sync', 'on', false);
insert into public.profiles(id, full_name, email, role, status) values
  (:'OP', 'Operador QA', 'operador.qa@ejemplo.test', 'SOLO_LECTURA', 'ACTIVO'), (:'OP2', 'Operador Dos QA', 'operador2.qa@ejemplo.test', 'SOLO_LECTURA', 'ACTIVO') on conflict (id) do nothing;
update public.profiles set role = 'OPERARIO_DEPOSITO' where id = :'OP';
update public.profiles set role = 'SUPERVISOR_DESPACHO' where id = :'OP2';
select set_config('okd.sync', '', false);
create or replace function pg_temp.eff(u uuid) returns text[] language sql as $$ select coalesce(array_agg(code order by code), '{}') from public.permissions where public.user_has_perm(u, code) $$;
\set ADM 'e0000000-0000-0000-0000-0000000000d3'
\set RO  'e0000000-0000-0000-0000-0000000000d4'
insert into auth.users(id, email) values (:'ADM', 'admin2.qa@ejemplo.test'), (:'RO', 'lectura2.qa@ejemplo.test') on conflict do nothing;
select set_config('okd.sync', 'on', false);
insert into public.profiles(id, full_name, email, role, status) values (:'ADM', 'Admin QA', 'admin2.qa@ejemplo.test', 'SOLO_LECTURA', 'ACTIVO'), (:'RO', 'Lectura QA', 'lectura2.qa@ejemplo.test', 'SOLO_LECTURA', 'ACTIVO') on conflict (id) do nothing;
update public.profiles set role = 'ADMIN' where id = :'ADM';
select set_config('okd.sync', '', false);
create temp table base_perms as select u, pg_temp.eff(u) p from unnest(array[:'OP', :'ADM', :'RO']::uuid[]) u; grant select on base_perms to public;
create temp table perms_before as select unnest(pg_temp.eff(:'OP')) p; grant select on perms_before to public;
select tst.res('PERM-00b el Admin NO queda habilitado por su rol (el permiso solo vale habilitado a la persona)', not public.can_be_responsable(:'ADM', 'INTERNO')
  and not public.receives_internal_routes(:'ADM'), '');
select tst.res('PERM-00 el permiso existe en el catálogo y NO se asigna a ningún rol por defecto',
  exists (select 1 from public.permissions where code = 'routes.receive_internal') and not exists (select 1 from public.role_permissions where permission_code = 'routes.receive_internal'), '');
-- ===== SIN el permiso: no es candidato =====
select tst.res('PERM-01 sin el permiso, un operador (Operario o Superior) NO es candidato para el Transporte Interno',
  not public.can_be_responsable(:'OP', 'INTERNO') and not public.can_be_responsable(:'OP2', 'INTERNO'), '');
begin; select tst.u(:'S'); set local role authenticated;
select tst.res('PERM-02 sin el permiso no aparece en la lista de responsables disponibles', not exists (select 1 from public.responsables_disponibles('INTERNO') x where x.id = :'OP'), '');
select tst.expect('PERM-03 sin el permiso NO se le puede publicar una hoja interna (el servidor lo rechaza)', format($q$ select public.publish_route(jsonb_build_object('sheet_key','PERM-NO','carrier_id','INTERNO','responsable_id',%L,'vehicle_id','f0000000-0000-0000-0000-000000000001','rules_version',1,'routing_rules_version',1,'stops',jsonb_build_array(
  jsonb_build_object('client_name','Sucursal San Juan','address','San Juan 500','stop_type','UBICACION_INTERNA','internal_location_key','SAN_JUAN','order_numbers',jsonb_build_array(),'ready',true)))) $q$, :'OP'), '%');
commit;
-- ===== se habilita el permiso (pantalla de permisos existente: set_user_permission) =====
begin; select tst.u(:'A'); set local role authenticated; select public.set_user_permission(:'OP', 'routes.receive_internal', 'GRANT', 'Prueba: realiza hojas del Transporte Interno'); commit;
select tst.res('PERM-04 con el permiso aparece como candidato para el Transporte Interno (conserva su rol)', public.can_be_responsable(:'OP', 'INTERNO')
  and (select role from public.profiles where id = :'OP') = 'OPERARIO_DEPOSITO', '');
select tst.res('PERM-05 el permiso NO lo habilita para transportistas EXTERNOS (Cristian)', not public.can_be_responsable(:'OP', 'CT-ESTE'), '');
create temp table perms_after as select unnest(pg_temp.eff(:'OP')) p; grant select on perms_after to public;
select tst.res('PERM-06 conserva TODOS sus permisos de operador y solo se agrega el nuevo (sin view_assigned, deliveries.update ni capture_signature)',
  (select array_agg(p order by p) from perms_after) = (select array_agg(p order by p) from (select p from perms_before union select 'routes.receive_internal') x)
  and not exists (select 1 from perms_after where p in ('routes.view_assigned','deliveries.update','deliveries.capture_signature','internal_routes.use')),
  (select string_agg(p, ',') from perms_after where p not in (select p from perms_before)));
begin; select tst.u(:'S'); set local role authenticated;
select tst.res('PERM-07 con el permiso aparece en la lista de responsables disponibles', exists (select 1 from public.responsables_disponibles('INTERNO') x where x.id = :'OP'), '');
create temp table r_op as select * from public.publish_route(jsonb_build_object('sheet_key','PERM-OP-1','carrier_id','INTERNO','responsable_id',:'OP','vehicle_id','f0000000-0000-0000-0000-000000000001','rules_version',1,'routing_rules_version',1,'stops',jsonb_build_array(
  jsonb_build_object('client_name','Sucursal San Juan','address','San Juan 500','stop_type','UBICACION_INTERNA','internal_location_key','SAN_JUAN','order_numbers',jsonb_build_array(),'ready',true))));
create temp table r_op2 as select * from public.publish_route(jsonb_build_object('sheet_key','PERM-OP-2','carrier_id','INTERNO','responsable_id',:'OP','vehicle_id','f0000000-0000-0000-0000-000000000001','rules_version',1,'routing_rules_version',1,'stops',jsonb_build_array(
  jsonb_build_object('client_name','Sucursal San Juan','address','San Juan 500','stop_type','UBICACION_INTERNA','internal_location_key','SAN_JUAN','order_numbers',jsonb_build_array(),'ready',true))));
create temp table r_g as select * from public.publish_route(jsonb_build_object('sheet_key','PERM-G-1','carrier_id','INTERNO','responsable_id',:'G','vehicle_id','f0000000-0000-0000-0000-000000000001','rules_version',1,'routing_rules_version',1,'stops',jsonb_build_array(
  jsonb_build_object('client_name','Sucursal San Juan','address','San Juan 500','stop_type','UBICACION_INTERNA','internal_location_key','SAN_JUAN','order_numbers',jsonb_build_array(),'ready',true))));
grant select on r_op, r_op2, r_g to public;
commit;
select tst.res('PERM-08 se le publicó la hoja del Transporte Interno (responsable = el operador)', (select responsable_id from r_op) = :'OP', '');
-- ===== realiza SU hoja con el recorrido del Transportista Interno =====
begin; select tst.u(:'OP'); set local role authenticated;
select tst.res('PERM-09 ve su hoja asignada', public.can_view_route((select id from r_op)), '');
select public.start_route((select id from r_op), 3000);
select public.set_stop_outcome((select id from public.route_stops where route_id = (select id from r_op) limit 1), 'ENTREGADO', null, null, 'perm-op-1',
  '{"evidence":{"receiver_name":"Encargado San Juan","signature_png_b64":"iVBORw0KGgo="},"location":{"lat":-32.895,"lon":-68.845}}');
commit;
select tst.res('PERM-10 realiza su hoja: inicia el recorrido y registra la recepción en sucursal (nombre + firma)',
  (select operational_status from public.routes where id = (select id from r_op)) = 'EN_CURSO'
  and (select outcome from public.route_stops where route_id = (select id from r_op) limit 1) = 'ENTREGADO', '');
-- ===== solo SUS hojas: no puede operar ni ver la de otro chofer =====
begin; select tst.u(:'OP'); set local role authenticated;
select tst.expect('PERM-11 NO puede iniciar la hoja de otro chofer', format('select public.start_route(%L, 3000)', (select id from r_g)), 'FORBIDDEN%');
select tst.expect('PERM-12 NO puede registrar entregas en la hoja de otro chofer', format($q$ select public.set_stop_outcome(%L, 'ENTREGADO', null, null, 'perm-op-x', '{"evidence":{"receiver_name":"X","signature_png_b64":"iVBORw0KGgo="},"location":{"lat":-32.895,"lon":-68.845}}') $q$,
  (select id from public.route_stops where route_id = (select id from r_g) limit 1)), 'FORBIDDEN%');
commit;
-- El Operario YA ve todas las hojas por su rol (routes.view_all, permiso original que se conserva). Para verificar que el permiso
-- nuevo NO agrega visibilidad sobre hojas ajenas, se le quita temporalmente view_all (solo en esta base de prueba).
insert into public.user_permission_overrides(user_id, permission_code, granted, set_by, reason) values (:'OP', 'routes.view_all', false, :'A', 'prueba de visibilidad');
begin; select tst.u(:'OP'); set local role authenticated;
select tst.res('PERM-13 el permiso nuevo solo agrega SU hoja interna: la ve, y NO ve la de otro chofer', public.can_view_route((select id from r_op)) and not public.can_view_route((select id from r_g)), '');
commit;
delete from public.user_permission_overrides where user_id = :'OP' and permission_code = 'routes.view_all';
-- ===== el Transportista Interno existente sigue igual =====
select tst.res('PERM-14 el Transportista Interno sigue siendo candidato', public.can_be_responsable(:'G', 'INTERNO'), '');
begin; select tst.u(:'G'); set local role authenticated; select public.start_route((select id from r_g), 4000); commit;
select tst.res('PERM-15 el Transportista Interno sigue realizando su hoja', (select operational_status from public.routes where id = (select id from r_g)) = 'EN_CURSO', '');
-- ===== se QUITA el permiso: deja de ser candidato y no puede operar ni la hoja que tenía asignada =====
begin; select tst.u(:'A'); set local role authenticated; select public.set_user_permission(:'OP', 'routes.receive_internal', 'ROLE', 'Fin de prueba'); commit;
select tst.res('PERM-16 sin el permiso deja de ser candidato', not public.can_be_responsable(:'OP', 'INTERNO'), '');
begin; select tst.u(:'OP'); set local role authenticated;
select tst.expect('PERM-17 sin el permiso NO puede operar la hoja que tenía asignada (el servidor lo valida en cada acción)', format('select public.start_route(%L, 3000)', (select id from r_op2)), 'FORBIDDEN%');
commit;
select tst.res('PERM-18 sus permisos de operador quedan exactamente como antes', pg_temp.eff(:'OP') = (select array_agg(p order by p) from perms_before), '');
select tst.res('PERM-19 al quitar el permiso se CONSERVA lo registrado (recepción en sucursal y recorrido iniciado)',
  (select outcome from public.route_stops where route_id = (select id from r_op) limit 1) = 'ENTREGADO' and (select operational_status from public.routes where id = (select id from r_op)) = 'EN_CURSO'
  and exists (select 1 from public.stop_evidence where stop_id = (select id from public.route_stops where route_id = (select id from r_op) limit 1)), '');
begin; select tst.u(:'S'); set local role authenticated;
select tst.expect('PERM-20 sin el permiso se RECHAZA una nueva asignación', format($q$ select public.publish_route(jsonb_build_object('sheet_key','PERM-OP-3','carrier_id','INTERNO','responsable_id',%L,'vehicle_id','f0000000-0000-0000-0000-000000000001','rules_version',1,'routing_rules_version',1,'stops',jsonb_build_array(
  jsonb_build_object('client_name','Sucursal San Juan','address','San Juan 500','stop_type','UBICACION_INTERNA','internal_location_key','SAN_JUAN','order_numbers',jsonb_build_array(),'ready',true)))) $q$, :'OP'), '%');
commit;
-- ===== ADMIN y SOLO LECTURA: mismo permiso, conservan rol y permisos; solo sus hojas internas =====
begin; select tst.u(:'A'); set local role authenticated;
select public.set_user_permission(:'ADM', 'routes.receive_internal', 'GRANT', 'Prueba'); select public.set_user_permission(:'RO', 'routes.receive_internal', 'GRANT', 'Prueba');
commit;
select tst.res('PERM-21 Admin y Solo Lectura con el permiso son candidatos y conservan rol y permisos (solo se agrega el nuevo)',
  public.can_be_responsable(:'ADM', 'INTERNO') and public.can_be_responsable(:'RO', 'INTERNO')
  and (select role from public.profiles where id = :'ADM') = 'ADMIN' and (select role from public.profiles where id = :'RO') = 'SOLO_LECTURA'
  and pg_temp.eff(:'RO') = (select array_agg(x order by x) from (select unnest(p) x from base_perms where u = :'RO' union select 'routes.receive_internal') y)
  and not ('routes.create' = any (pg_temp.eff(:'RO')) or 'deliveries.update' = any (pg_temp.eff(:'RO'))), '');
begin; select tst.u(:'S'); set local role authenticated;
create temp table r_ro as select * from public.publish_route(jsonb_build_object('sheet_key','PERM-RO-1','carrier_id','INTERNO','responsable_id',:'RO','vehicle_id','f0000000-0000-0000-0000-000000000001','rules_version',1,'routing_rules_version',1,'stops',jsonb_build_array(
  jsonb_build_object('client_name','Sucursal San Juan','address','San Juan 500','stop_type','UBICACION_INTERNA','internal_location_key','SAN_JUAN','order_numbers',jsonb_build_array(),'ready',true))));
create temp table r_adm2 as select * from public.publish_route(jsonb_build_object('sheet_key','PERM-ADM-2','carrier_id','INTERNO','responsable_id',:'ADM','vehicle_id','f0000000-0000-0000-0000-000000000001','rules_version',1,'routing_rules_version',1,'stops',jsonb_build_array(
  jsonb_build_object('client_name','Sucursal San Juan','address','San Juan 500','stop_type','UBICACION_INTERNA','internal_location_key','SAN_JUAN','order_numbers',jsonb_build_array(),'ready',true))));
grant select on r_adm2 to public;
create temp table r_adm as select * from public.publish_route(jsonb_build_object('sheet_key','PERM-ADM-1','carrier_id','INTERNO','responsable_id',:'ADM','vehicle_id','f0000000-0000-0000-0000-000000000001','rules_version',1,'routing_rules_version',1,'stops',jsonb_build_array(
  jsonb_build_object('client_name','Sucursal San Juan','address','San Juan 500','stop_type','UBICACION_INTERNA','internal_location_key','SAN_JUAN','order_numbers',jsonb_build_array(),'ready',true))));
grant select on r_ro, r_adm to public;
commit;
begin; select tst.u(:'RO'); set local role authenticated;
select public.start_route((select id from r_ro), 5000);
select public.set_stop_outcome((select id from public.route_stops where route_id = (select id from r_ro) limit 1), 'ENTREGADO', null, null, 'perm-ro-1',
  '{"evidence":{"receiver_name":"Encargado","signature_png_b64":"iVBORw0KGgo="},"location":{"lat":-32.895,"lon":-68.845}}');
select tst.expect('PERM-22 Solo Lectura NO puede operar la hoja de otro (solo las suyas)', format('select public.start_route(%L, 5000)', (select id from r_g)), 'FORBIDDEN%');
commit;
-- ===== Ubicaciones internas para "+ AGREGAR PARADA": Solo Lectura con el permiso y su hoja interna EN CURSO =====
\set RO2 'e0000000-0000-0000-0000-0000000000d5'
insert into auth.users(id, email) values (:'RO2', 'lectura3.qa@ejemplo.test') on conflict do nothing;
select set_config('okd.sync', 'on', false);
insert into public.profiles(id, full_name, email, role, status) values (:'RO2', 'Lectura Tres QA', 'lectura3.qa@ejemplo.test', 'SOLO_LECTURA', 'ACTIVO') on conflict (id) do nothing;
select set_config('okd.sync', '', false);
begin; select tst.u(:'RO'); set local role authenticated;
select tst.res('PERM-26 Solo Lectura con el permiso y su hoja interna en curso VE las ubicaciones internas (antes: lista vacía)', (select count(*) from public.driver_internal_locations()) > 0,
  (select count(*)::text from public.driver_internal_locations()));
select public.add_internal_stop((select id from r_ro), jsonb_build_object('stop_type','UBICACION_INTERNA','internal_location_key','MONTECASEROS','instructions','Segunda visita QA'),
  (select version from public.routes where id = (select id from r_ro)), 'perm-ro-add', false);
commit;
select tst.res('PERM-27 y agrega una visita a una ubicación interna en SU hoja (recorrido existente)',
  exists (select 1 from public.route_stops where route_id = (select id from r_ro) and stop_type = 'UBICACION_INTERNA' and internal_location_key = 'MONTECASEROS' and provenance = 'DRIVER'), '');
begin; select tst.u(:'RO2'); set local role authenticated;
select tst.res('PERM-28 Solo Lectura SIN el permiso sigue sin ver ubicaciones (sin permisos generales nuevos)', (select count(*) from public.driver_internal_locations()) = 0, '');
commit;
begin; select tst.u(:'A'); set local role authenticated; select public.set_user_permission(:'RO2', 'routes.receive_internal', 'GRANT', 'Prueba sin hoja'); commit;
begin; select tst.u(:'RO2'); set local role authenticated;
select tst.res('PERM-29 con el permiso pero SIN hoja interna asignada activa tampoco ve ubicaciones', (select count(*) from public.driver_internal_locations()) = 0, '');
select tst.expect('PERM-30 y no puede agregar paradas en una hoja ajena', format($q$ select public.add_internal_stop(%L, '{"stop_type":"UBICACION_INTERNA","internal_location_key":"MONTECASEROS"}'::jsonb, 1, 'perm-ro2-x', false) $q$, (select id from r_g)), 'FORBIDDEN%');
commit;
select tst.res('PERM-23 Solo Lectura con el permiso registra entregas ÚNICAMENTE en su ruta asignada', (select outcome from public.route_stops where route_id = (select id from r_ro) limit 1) = 'ENTREGADO', '');
begin; select tst.u(:'ADM'); set local role authenticated; select public.start_route((select id from r_adm), 6000); commit;
begin; select tst.u(:'A'); set local role authenticated; select public.set_user_permission(:'ADM', 'routes.receive_internal', 'ROLE', 'Fin'); commit;
begin; select tst.u(:'ADM'); set local role authenticated;
select tst.expect('PERM-24 al quitarle el permiso al Admin, NO puede seguir operando su hoja interna (aunque su rol tenga routes.view_assigned)',
  format($q$ select public.set_stop_outcome(%L, 'ENTREGADO', null, null, 'perm-adm-x', '{"evidence":{"receiver_name":"X","signature_png_b64":"iVBORw0KGgo="},"location":{"lat":-32.895,"lon":-68.845}}') $q$,
  (select id from public.route_stops where route_id = (select id from r_adm) limit 1)), 'FORBIDDEN%');
commit;
begin; select tst.u(:'ADM'); set local role authenticated;
select tst.expect('PERM-31 al quitarle el permiso al Admin, tampoco puede INICIAR otra hoja interna que tenía asignada', format('select public.start_route(%L, 9000)', (select id from r_adm2)), 'FORBIDDEN%');
commit;
select tst.res('PERM-25 el Admin conserva todos sus permisos originales al habilitar y quitar', pg_temp.eff(:'ADM') = (select p from base_perms where u = :'ADM'), '');
