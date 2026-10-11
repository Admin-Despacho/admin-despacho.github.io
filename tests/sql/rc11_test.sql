\set ON_ERROR_STOP on
\set A '00000000-0000-0000-0000-00000000000a'
\set D '00000000-0000-0000-0000-00000000000d'
\set C '00000000-0000-0000-0000-000000000003'
\set T '00000000-0000-0000-0000-0000000000f1'
\set L '00000000-0000-0000-0000-0000000000f2'
insert into auth.users(id, email) values (:'T', 'prueba@ok.test'), (:'L', 'lectura@ok.test');
insert into public.profiles(id, full_name, email, role, status) values (:'T', 'Usuario Prueba', 'prueba@ok.test', 'DESPACHO', 'ACTIVO'), (:'L', 'Solo Lectura', 'lectura@ok.test', 'SOLO_LECTURA', 'ACTIVO');
begin; select tst.u(:'D'); set local role authenticated;
select tst.res('MOD-01 Despacho: módulos efectivos = DESPACHO (sin Usuarios, Informes ni Configuración)', public.my_modules() = array['DESPACHO'], public.my_modules()::text);
select tst.expect('MOD-02 Un usuario no cambia sus propios módulos', format('update public.profiles set disabled_modules = %L where id = %L', '{}', '00000000-0000-0000-0000-00000000000d'), 'permission denied%');
commit;
begin; select tst.u(:'C'); set local role authenticated;
select tst.res('MOD-03 Transportista: solo MIS_HOJAS', public.my_modules() = array['MIS_HOJAS'], public.my_modules()::text);
select tst.expect('USR-12 (SQL) Transportista no accede a una RPC de Despacho', $q$ select * from public.responsables_disponibles('INTERNO') $q$, 'FORBIDDEN%');
select tst.res('USR-12b (SQL) Transportista no lee usuarios ni hojas ajenas', (select count(*) from public.profiles) = 1 and not exists (select 1 from public.routes where responsable_id <> '00000000-0000-0000-0000-000000000003'), '');
commit;
-- Admin restringe el módulo DESPACHO a un usuario: el servidor bloquea aunque el rol lo permita
begin; select tst.svc(); set local role service_role;
select public.admin_set_disabled_modules(:'D', array['DESPACHO']);
commit;
begin; select tst.u(:'D'); set local role authenticated;
select tst.expect('USR-13 Módulo restringido por Admin: publicar queda bloqueado en el servidor', $q$ select public.publish_route('{"sheet_key":"RC11-X","carrier_id":"UCO","responsable_id":"00000000-0000-0000-0000-000000000005","stops":[{"client_name":"Z","order_numbers":["99901"],"ready":true}]}') $q$, 'FORBIDDEN%');
select tst.res('USR-13b Con el módulo restringido no ve hojas', count(*) = 0, count(*)::text) from public.routes;
commit;
begin; select tst.svc(); set local role service_role;
select public.admin_set_disabled_modules(:'D', array[]::text[]);
commit;
select tst.expect('MOD-04 Módulos inválidos rechazados', format('update public.profiles set disabled_modules = %L where id = %L', '{NO_EXISTE}', '00000000-0000-0000-0000-00000000000d'), '%profiles_disabled_modules_valid%');
-- Solo lectura
begin; select tst.u(:'L'); set local role authenticated;
select tst.res('USR-10 (SQL) Solo lectura ve hojas', count(*) > 0, count(*)::text) from public.routes;
select tst.expect('USR-10b (SQL) Solo lectura no publica', $q$ select public.publish_route('{"sheet_key":"RC11-L","carrier_id":"UCO","responsable_id":"00000000-0000-0000-0000-000000000005","stops":[{"client_name":"Z","order_numbers":["99902"],"ready":true}]}') $q$, 'FORBIDDEN%');
select tst.expect('USR-10c (SQL) Solo lectura no reserva ni confirma', $q$ select public.reserve_orders('RC11-L', array['99903']) $q$, 'FORBIDDEN%');
commit;
-- Usuario de prueba sin historial (aceptó invitación, tiene borrador, notificación y passkey): se elimina completo
begin; select tst.u(:'T'); set local role authenticated;
select public.reserve_orders('RC11-T', array['99910']);
commit;
insert into public.audit_log(actor_id, action, target_type, target_id) values (:'T', 'INVITE_ACCEPTED', 'user', :'T');
insert into public.notifications(user_id, type, title) values (:'T', 'X', 'x');
insert into public.user_passkeys(user_id, credential_id, public_key) values (:'T', 'cred-prueba', 'pk');
select tst.res('USR-14a Aceptar la invitación no cuenta como historial', not public.user_has_history(:'T'), '');
begin; select tst.svc(); set local role service_role;
delete from auth.users where id = :'T';
commit;
select tst.res('USR-14 Usuario sin historial se elimina completo (perfil, borrador, reservas, notificaciones, passkeys)',
  not exists (select 1 from public.profiles where id = :'T') and not exists (select 1 from public.route_drafts where client_sheet_key = 'RC11-T')
  and not exists (select 1 from public.order_reservations where order_id = '99910') and not exists (select 1 from public.user_passkeys where credential_id = 'cred-prueba'), '');
begin; select tst.svc(); set local role service_role;
select tst.expect('USR-15 (SQL) Usuario con historial no se elimina', $q$ delete from auth.users where id = '00000000-0000-0000-0000-000000000003' $q$, 'HAS_HISTORY%');
commit;
