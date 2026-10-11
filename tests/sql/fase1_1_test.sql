-- Pruebas de la migración incremental Fase 1.1 (corre después de fase1_test.sql, sobre los mismos datos).
\set ON_ERROR_STOP on
\set A '00000000-0000-0000-0000-00000000000a'
\set D '00000000-0000-0000-0000-00000000000d'
\set G '00000000-0000-0000-0000-000000000001'
\set C '00000000-0000-0000-0000-000000000003'
\set DI '00000000-0000-0000-0000-000000000004'

create or replace function tst.as_user_iat(p_uid text, p_role text, p_iat bigint) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid, ''), true);
  perform set_config('request.jwt.claim.role', coalesce(p_role, ''), true);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', p_role, 'iat', p_iat)::text, true);
end $$;
grant execute on function tst.as_user_iat(text, text, bigint) to public;
create or replace function tst.svc() returns void language plpgsql as $$ begin perform tst.as_user_iat(null, 'service_role', null); end $$;
grant execute on function tst.svc() to public;

-- ===== F1.1-04 Último acceso real (lo escribe Supabase Auth en auth.users) =====
update auth.users set last_sign_in_at = '2026-10-09 08:15:00+00' where id = :'G';
insert into tst.results(name, ok, detail) select 'F1.1-04 Último acceso real se copia desde Auth', last_sign_in_at = '2026-10-09 08:15:00+00', last_sign_in_at::text from public.profiles where id = :'G';

-- ===== F1.1-06 Email de Auth y profile siempre iguales =====
update auth.users set email = 'Gabriel.Nuevo@OK.test' where id = :'G';
insert into tst.results(name, ok, detail) select 'F1.1-06 Cambio de email en Auth se refleja en profile', email = 'gabriel.nuevo@ok.test', email from public.profiles where id = :'G';

-- ===== F1.1-07 / 08 Rol TRANSPORTISTA siempre con carrier =====
begin; select tst.svc(); set local role service_role;
do $$ begin
  perform public.admin_update_profile('00000000-0000-0000-0000-00000000000d', null, null, null, 'TRANSPORTISTA', null, false, null);
  insert into tst.results(name, ok, detail) values ('F1.1-07 DESPACHO → TRANSPORTISTA sin carrier: RECHAZADO', false, 'se aceptó');
exception when others then
  insert into tst.results(name, ok, detail) values ('F1.1-07 DESPACHO → TRANSPORTISTA sin carrier: RECHAZADO', sqlerrm like 'CARRIER_REQUIRED%', sqlerrm);
end $$;
do $$ begin
  update public.profiles set role = 'TRANSPORTISTA' where id = '00000000-0000-0000-0000-00000000000d';
  set constraints all immediate;
  insert into tst.results(name, ok, detail) values ('F1.1-07b Ni con UPDATE directo del servidor queda un TRANSPORTISTA sin carrier', false, 'se aceptó');
exception when others then
  insert into tst.results(name, ok, detail) values ('F1.1-07b Ni con UPDATE directo del servidor queda un TRANSPORTISTA sin carrier', sqlerrm like 'CARRIER_REQUIRED%', sqlerrm);
end $$;
select public.admin_update_profile(:'D', null, null, null, 'TRANSPORTISTA', array['CT-ESTE'], false, null);
insert into tst.results(name, ok, detail) select 'F1.1-08 DESPACHO → TRANSPORTISTA con CT-ESTE: ACEPTADO', p.role = 'TRANSPORTISTA' and exists (select 1 from public.user_carriers where user_id = p.id and carrier_id = 'CT-ESTE'), p.role from public.profiles p where id = :'D';
select public.admin_update_profile(:'D', null, null, null, 'DESPACHO', array[]::text[], false, null);
commit;

-- ===== F1.1-09 Cambio de carriers atómico: si falla, quedan los anteriores =====
begin; select tst.svc(); set local role service_role;
do $$ begin
  perform public.set_user_carriers('00000000-0000-0000-0000-000000000003', array['CT-ESTE','NO-EXISTE']);
  insert into tst.results(name, ok, detail) values ('F1.1-09 Carrier inválido → error y conserva los anteriores', false, 'se aceptó');
exception when others then
  insert into tst.results(name, ok, detail) select 'F1.1-09 Carrier inválido → error y conserva los anteriores',
    sqlerrm like 'BAD_CARRIER%' and (select array_agg(carrier_id order by carrier_id) from public.user_carriers where user_id = '00000000-0000-0000-0000-000000000003') = array['CT-ALR','CT-ESTE'], sqlerrm;
end $$;
do $$ begin
  perform public.set_user_carriers('00000000-0000-0000-0000-000000000003', array[]::text[]);
  insert into tst.results(name, ok, detail) values ('F1.1-09b Dejar a un TRANSPORTISTA sin carriers → error y rollback', false, 'se aceptó');
exception when others then
  insert into tst.results(name, ok, detail) select 'F1.1-09b Dejar a un TRANSPORTISTA sin carriers → error y rollback',
    sqlerrm like 'CARRIER_REQUIRED%' and (select count(*) from public.user_carriers where user_id = '00000000-0000-0000-0000-000000000003') = 2, sqlerrm;
end $$;
commit;

-- ===== F1.1-13 / 14 Hojas activas: no se deshabilita ni archiva en silencio =====
begin; select tst.svc(); set local role service_role;
insert into tst.results(name, ok, detail) select 'F1.1-13a Cristian tiene una hoja activa (CTE-01)', count(*) = 1, count(*)::text from public.user_active_routes(:'C');
do $$ begin
  update public.profiles set status = 'DESHABILITADO' where id = '00000000-0000-0000-0000-000000000003';
  insert into tst.results(name, ok, detail) values ('F1.1-13 Usuario con hoja activa no se DESHABILITA', false, 'se deshabilitó');
exception when others then
  insert into tst.results(name, ok, detail) values ('F1.1-13 Usuario con hoja activa no se DESHABILITA', sqlerrm like 'ACTIVE_ROUTES%', sqlerrm);
end $$;
do $$ begin
  update public.profiles set status = 'ARCHIVADO' where id = '00000000-0000-0000-0000-000000000003';
  insert into tst.results(name, ok, detail) values ('F1.1-14 Usuario con hoja activa no se ARCHIVA', false, 'se archivó');
exception when others then
  insert into tst.results(name, ok, detail) values ('F1.1-14 Usuario con hoja activa no se ARCHIVA', sqlerrm like 'ACTIVE_ROUTES%', sqlerrm);
end $$;
do $$ begin
  perform public.reassign_active_routes('00000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000001');
  insert into tst.results(name, ok, detail) values ('F1.1-13c Reasignar a un usuario incompatible → rechazado', false, 'se reasignó');
exception when others then
  insert into tst.results(name, ok, detail) values ('F1.1-13c Reasignar a un usuario incompatible → rechazado', sqlerrm like 'RESPONSABLE_INCOMPATIBLE%', sqlerrm);
end $$;
select public.set_user_carriers(:'DI', array['CT-ALR','CT-ESTE']);
insert into tst.results(name, ok, detail) select 'F1.1-13d Reasignar a un usuario compatible (Diego con CT-ESTE)', public.reassign_active_routes(:'C', :'DI') = 1, '';
update public.profiles set status = 'DESHABILITADO' where id = :'C';
insert into tst.results(name, ok, detail) select 'F1.1-13e Sin hojas activas, ahora sí se deshabilita', status = 'DESHABILITADO', status from public.profiles where id = :'C';
update public.profiles set status = 'ACTIVO' where id = :'C';
commit;

-- ===== F1.1-03 Cerrar sesiones abiertas (server-side) =====
insert into auth.sessions(user_id) values (:'D'), (:'D');
begin; select tst.as_user_iat(:'D', 'authenticated', 1000); set local role authenticated;
do $$ begin
  perform public.revoke_user_sessions('00000000-0000-0000-0000-00000000000d');
  insert into tst.results(name, ok, detail) values ('F1.1-03a Un usuario común no puede cerrar sesiones', false, 'pudo');
exception when others then
  insert into tst.results(name, ok, detail) values ('F1.1-03a Un usuario común no puede cerrar sesiones', sqlerrm like '%permission denied%', sqlerrm);
end $$;
commit;
begin; select tst.svc(); set local role service_role;
select public.revoke_user_sessions(:'D');
insert into tst.results(name, ok, detail) select 'F1.1-03b Se borran sus sesiones en Auth (no puede renovar el token)', count(*) = 0, count(*)::text from auth.sessions where user_id = :'D';
commit;
begin; select tst.as_user_iat(:'D', 'authenticated', 1000); set local role authenticated;
do $$ begin
  perform * from public.responsables_disponibles('INTERNO');
  insert into tst.results(name, ok, detail) values ('F1.1-03c El token emitido ANTES del cierre ya no tiene permisos', false, 'siguió con permisos');
exception when others then
  insert into tst.results(name, ok, detail) values ('F1.1-03c El token emitido ANTES del cierre ya no tiene permisos', sqlerrm like 'FORBIDDEN%', sqlerrm);
end $$;
commit;
begin; select tst.as_user_iat(:'D', 'authenticated', extract(epoch from now())::bigint + 60); set local role authenticated;
insert into tst.results(name, ok, detail) select 'F1.1-03d Un inicio de sesión NUEVO funciona normalmente', count(*) >= 1, count(*)::text from public.responsables_disponibles('INTERNO');
commit;

-- ===== Autogestión: el usuario no se asigna carriers ni superior =====
begin; select tst.as_user_iat(:'G', 'authenticated', extract(epoch from now())::bigint + 60); set local role authenticated;
do $$ begin
  insert into public.user_carriers values ('00000000-0000-0000-0000-000000000001', 'CT-ESTE');
  insert into tst.results(name, ok, detail) values ('F1.1-AG1 El usuario no se autoasigna carriers', false, 'pudo');
exception when others then
  insert into tst.results(name, ok, detail) values ('F1.1-AG1 El usuario no se autoasigna carriers', true, sqlerrm);
end $$;
do $$ begin
  update public.profiles set supervisor_user_id = '00000000-0000-0000-0000-000000000001' where id = '00000000-0000-0000-0000-000000000001';
  insert into tst.results(name, ok, detail) values ('F1.1-AG2 El usuario no cambia su superior', false, 'pudo');
exception when others then
  insert into tst.results(name, ok, detail) values ('F1.1-AG2 El usuario no cambia su superior', true, sqlerrm);
end $$;
commit;

-- ===== F1.1-21 / 22 Permiso y superior configurable =====
insert into tst.results(name, ok, detail) select 'F1.1-21 Existe el permiso can_approve_internal_route_changes (ADMIN sí, DESPACHO no)',
  exists (select 1 from public.permissions where code = 'can_approve_internal_route_changes')
  and exists (select 1 from public.role_permissions where role_code = 'ADMIN' and permission_code = 'can_approve_internal_route_changes')
  and not exists (select 1 from public.role_permissions where role_code = 'DESPACHO' and permission_code = 'can_approve_internal_route_changes'), '';
begin; select tst.svc(); set local role service_role;
select public.admin_update_profile(:'G', null, null, null, null, null, true, :'A');
insert into tst.results(name, ok, detail) select 'F1.1-22 Superior configurable por usuario (sin nombres fijos en el código)', supervisor_user_id = :'A', '' from public.profiles where id = :'G';
do $$ begin
  perform public.admin_update_profile('00000000-0000-0000-0000-000000000001', null, null, null, null, null, true, '00000000-0000-0000-0000-00000000000d');
  insert into tst.results(name, ok, detail) values ('F1.1-22b Un superior sin permiso de aprobación se rechaza', false, 'se aceptó');
exception when others then
  insert into tst.results(name, ok, detail) values ('F1.1-22b Un superior sin permiso de aprobación se rechaza', sqlerrm like 'BAD_SUPERVISOR%', sqlerrm);
end $$;
commit;

-- ===== F1.1-24 / 25 / 26 Base de aprobación de rutas internas =====
begin; select tst.svc(); set local role service_role;
insert into public.routes(id, number, carrier_id, responsable_id, operational_status) values
 ('33333333-3333-3333-3333-333333333333','03-05','INTERNO',:'G','EN_CURSO'),
 ('44444444-4444-4444-4444-444444444444','03-06','INTERNO',:'G','EN_CURSO'),
 ('55555555-5555-5555-5555-555555555555','03-07','INTERNO',:'G','EN_CURSO'),
 ('66666666-6666-6666-6666-666666666666','CTE-09','CT-ESTE',:'C','EN_CURSO');
commit;

begin; select tst.as_user_iat(:'DI', 'authenticated', extract(epoch from now())::bigint + 60); set local role authenticated;
do $$ begin
  perform public.request_route_approval('33333333-3333-3333-3333-333333333333', 1, 3);
  insert into tst.results(name, ok, detail) values ('F1.1-24a Solo el responsable cierra su hoja', false, 'otro la cerró');
exception when others then
  insert into tst.results(name, ok, detail) values ('F1.1-24a Solo el responsable cierra su hoja', sqlerrm like 'FORBIDDEN%', sqlerrm);
end $$;
commit;

begin; select tst.as_user_iat(:'G', 'authenticated', extract(epoch from now())::bigint + 60); set local role authenticated;
create temp table t_req as select public.request_route_approval('33333333-3333-3333-3333-333333333333', 1, 3) as id;
commit;
insert into tst.results(name, ok, detail) select 'F1.1-24 Ruta interna con 3 cambios queda preparada para aprobación', r.has_driver_modifications and r.modification_count = 3 and q.status = 'PENDING' and q.supervisor_user_id = :'A' and not q.supervisor_missing,
  r.operational_status || ' / ' || r.approval_status from public.routes r join public.route_approval_requests q on q.route_id = r.id where r.id = '33333333-3333-3333-3333-333333333333';
insert into tst.results(name, ok, detail) select 'F1.1-25 Estado operativo COMPLETADA y estado de aprobación PENDIENTE son campos separados', operational_status = 'COMPLETADA' and approval_status = 'PENDIENTE', operational_status || ' · ' || approval_status from public.routes where id = '33333333-3333-3333-3333-333333333333';

begin; select tst.as_user_iat(:'G', 'authenticated', extract(epoch from now())::bigint + 60); set local role authenticated;
insert into tst.results(name, ok, detail) select 'F1.1-26 Doble cierre (doble toque / reintento) no crea otra solicitud', public.request_route_approval('33333333-3333-3333-3333-333333333333', 1, 3) = (select id from t_req)
  and (select count(*) from public.route_approval_requests where route_id = '33333333-3333-3333-3333-333333333333' and route_version = 1) = 1, '';
insert into tst.results(name, ok, detail) select 'F1.1-26b El responsable ve su solicitud', count(*) = 1, count(*)::text from public.route_approval_requests where route_id = '33333333-3333-3333-3333-333333333333';
select public.request_route_approval('44444444-4444-4444-4444-444444444444', 1, 0);
commit;
insert into tst.results(name, ok, detail) select 'F1.1-24b Sin cambios: auto-cierre (sin solicitud de aprobación)', operational_status = 'COMPLETADA' and approval_status = 'NO_REQUERIDA'
  and not exists (select 1 from public.route_approval_requests where route_id = '44444444-4444-4444-4444-444444444444'), approval_status from public.routes where id = '44444444-4444-4444-4444-444444444444';

begin; select tst.svc(); set local role service_role;
select public.admin_update_profile(:'G', null, null, null, null, null, true, null);
do $$ begin
  perform public.request_route_approval('66666666-6666-6666-6666-666666666666', 1, 2);
  insert into tst.results(name, ok, detail) values ('F1.1-24c La aprobación de cambios aplica solo a rutas internas', false, 'se aceptó');
exception when others then
  insert into tst.results(name, ok, detail) values ('F1.1-24c La aprobación de cambios aplica solo a rutas internas', sqlerrm like 'NOT_INTERNAL%', sqlerrm);
end $$;
select public.request_route_approval('55555555-5555-5555-5555-555555555555', 1, 1);
commit;
insert into tst.results(name, ok, detail) select 'F1.1-24d Sin superior configurado igual se completa y queda marcada para Admin', r.operational_status = 'COMPLETADA' and r.approval_status = 'PENDIENTE' and q.supervisor_missing,
  'supervisor_missing=' || q.supervisor_missing from public.routes r join public.route_approval_requests q on q.route_id = r.id where r.id = '55555555-5555-5555-5555-555555555555';

-- F1.1-23 Sin permiso no se aprueba
begin; select tst.as_user_iat(:'D', 'authenticated', extract(epoch from now())::bigint + 60); set local role authenticated;
do $$ begin
  perform public.review_route_approval((select id from public.route_approval_requests where route_id = '33333333-3333-3333-3333-333333333333'), 'APPROVED', null);
  insert into tst.results(name, ok, detail) values ('F1.1-23 Usuario sin permiso no puede aprobar', false, 'aprobó');
exception when others then
  insert into tst.results(name, ok, detail) values ('F1.1-23 Usuario sin permiso no puede aprobar', sqlerrm like 'FORBIDDEN%' or sqlerrm like '%permission denied%', sqlerrm);
end $$;
commit;
begin; select tst.as_user_iat(:'G', 'authenticated', extract(epoch from now())::bigint + 60); set local role authenticated;
do $$ begin
  perform public.review_route_approval((select id from public.route_approval_requests where route_id = '33333333-3333-3333-3333-333333333333'), 'APPROVED', null);
  insert into tst.results(name, ok, detail) values ('F1.1-23b El propio transportista no aprueba su hoja', false, 'aprobó');
exception when others then
  insert into tst.results(name, ok, detail) values ('F1.1-23b El propio transportista no aprueba su hoja', sqlerrm like 'FORBIDDEN%', sqlerrm);
end $$;
commit;

-- Aprobar / observar (base de Fase 2)
begin; select tst.as_user_iat(:'A', 'authenticated', extract(epoch from now())::bigint + 60); set local role authenticated;
select public.review_route_approval((select id from public.route_approval_requests where route_id = '33333333-3333-3333-3333-333333333333'), 'APPROVED', null);
do $$ begin
  perform public.review_route_approval((select id from public.route_approval_requests where route_id = '55555555-5555-5555-5555-555555555555'), 'OBSERVED', '  ');
  insert into tst.results(name, ok, detail) values ('F1.1-AP2 Solicitar aclaración exige motivo', false, 'sin motivo');
exception when others then
  insert into tst.results(name, ok, detail) values ('F1.1-AP2 Solicitar aclaración exige motivo', sqlerrm like 'NOTE_REQUIRED%', sqlerrm);
end $$;
select public.review_route_approval((select id from public.route_approval_requests where route_id = '55555555-5555-5555-5555-555555555555'), 'OBSERVED', 'Falta la firma de la parada 2');
commit;
insert into tst.results(name, ok, detail) select 'F1.1-AP1 Aprobar: COMPLETADA · APROBADA, con quién y cuándo, y auditoría', r.operational_status = 'COMPLETADA' and r.approval_status = 'APROBADA' and q.reviewed_by = :'A' and q.reviewed_at is not null
  and exists (select 1 from public.audit_log where action = 'INTERNAL_ROUTE_APPROVED' and target_id = r.id::text), r.operational_status || ' · ' || r.approval_status
  from public.routes r join public.route_approval_requests q on q.route_id = r.id where r.id = '33333333-3333-3333-3333-333333333333';
insert into tst.results(name, ok, detail) select 'F1.1-AP3 Observar: COMPLETADA · OBSERVADA (no vuelve a EN CURSO)', operational_status = 'COMPLETADA' and approval_status = 'OBSERVADA', operational_status || ' · ' || approval_status from public.routes where id = '55555555-5555-5555-5555-555555555555';
begin; select tst.as_user_iat(:'G', 'authenticated', extract(epoch from now())::bigint + 60); set local role authenticated;
select public.request_route_approval('33333333-3333-3333-3333-333333333333', 1, 3);
commit;
insert into tst.results(name, ok, detail) select 'F1.1-AP4 Reintentar el cierre de una hoja ya aprobada no la vuelve a PENDIENTE', approval_status = 'APROBADA'
  and (select count(*) from public.route_approval_requests where route_id = '33333333-3333-3333-3333-333333333333') = 1, approval_status from public.routes where id = '33333333-3333-3333-3333-333333333333';
