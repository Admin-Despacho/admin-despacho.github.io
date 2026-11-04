-- Pruebas de la PROPUESTA V4.23 (G2 TERMINÉ EN, regreso a Diamante, padrón de emails). Corre DESPUÉS de g2_revision_test. Datos FICTICIOS.
\set ON_ERROR_STOP on
\set A 'e0000000-0000-0000-0000-00000000000a'
\set S 'e0000000-0000-0000-0000-000000000005'
\set O 'e0000000-0000-0000-0000-000000000006'
\set G 'e0000000-0000-0000-0000-000000000007'
\set PNG 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='
-- dos ubicaciones "Diamante" (para probar la ambigüedad) — ficticias, a ~5 km una de otra
insert into public.internal_locations(location_key, name, address, lat, lon, radius_m) values
  ('QA_DEP_DIAMANTE', 'Depósito Diamante QA', 'Calle Diamante 100', -32.9000, -68.8000, 150),
  ('QA_DIAMANTE_VIEJO', 'Diamante (anterior) QA', 'Calle Vieja 1', -32.9500, -68.8000, 150) on conflict do nothing;
-- hoja del INTERNO (Gabriel): 1 entrega comercial + Montecaseros; iniciada DESPUÉS de aplicar la V4.23
begin; select tst.u(:'S'); set local role authenticated;
select public.reserve_orders('V423-GB', array['75001','75002']);
create temp table f4 as select * from public.publish_route(jsonb_build_object('sheet_key','V423-GB','carrier_id','INTERNO','responsable_id',:'G','vehicle_id','f0000000-0000-0000-0000-000000000001','rules_version',1,'routing_rules_version',1,'stops',jsonb_build_array(
  jsonb_build_object('client_name','CLIENTE V423','address','Calle 1, Mendoza','stop_type','PEDIDO','order_numbers',jsonb_build_array('75001'),'merchandise_amount',1000,'task','ENTREGA','ready',true),
  jsonb_build_object('client_name','Montecaseros - casa central','address','Montecaseros','stop_type','UBICACION_INTERNA','internal_location_key','MONTECASEROS','order_numbers',jsonb_build_array('75002'),'ready',true))));
grant select on f4 to public; commit;
create temp table s4 as select id, client_name, stop_type from public.route_stops where route_id = (select id from f4); grant select on s4 to public;
update public.route_stops set client_key = '20123456786', customer_email = null where id = (select id from s4 where client_name = 'CLIENTE V423');
select set_config('okd.qa_km', (select current_km::text from public.vehicles where id = 'f0000000-0000-0000-0000-000000000001'), false);
begin; select tst.u(:'G'); set local role authenticated; select public.start_route((select id from f4), current_setting('okd.qa_km')::numeric + 10); commit;
create or replace function pg_temp.loc(lat float, lon float) returns jsonb language sql as $f$ select jsonb_build_object('lat', lat, 'lon', lon, 'accuracy', 10) $f$;
-- ===== G4: TERMINÉ EN MONTECASEROS =====
begin; select tst.u(:'G'); set local role authenticated;
select tst.expect('G4-01 TERMINÉ antes de LLEGUÉ → ARRIVE_FIRST', format($q$ select public.finish_internal_location(%L, %L, 'g4-0') $q$, (select id from s4 where stop_type = 'UBICACION_INTERNA'), pg_temp.loc(-32.89, -68.84)), 'ARRIVE_FIRST%');
select public.arrive_stop((select id from s4 where stop_type = 'UBICACION_INTERNA'), pg_temp.loc(-32.89, -68.84), 'g4-a');
select tst.expect('G4-02 TERMINÉ antes de resolver la recepción → RESOLVE_FIRST', format($q$ select public.finish_internal_location(%L, %L, 'g4-1') $q$, (select id from s4 where stop_type = 'UBICACION_INTERNA'), pg_temp.loc(-32.89, -68.84)), 'RESOLVE_FIRST%');
select tst.expect('G4-03 TERMINÉ en una entrega comercial → NOT_INTERNAL_LOCATION', format($q$ select public.finish_internal_location(%L, %L, 'g4-2') $q$, (select id from s4 where stop_type = 'PEDIDO'), pg_temp.loc(-32.89, -68.84)), 'NOT_INTERNAL_LOCATION%');
select public.set_stop_outcome((select id from s4 where stop_type = 'UBICACION_INTERNA'), 'ENTREGA_PARCIAL', 'faltó una caja', null, 'g4-o',
  jsonb_build_object('location', pg_temp.loc(-32.89, -68.84), 'evidence', jsonb_build_object('receiver_name', 'Encargada QA', 'signature_png_b64', :'PNG')));
select public.finish_internal_location((select id from s4 where stop_type = 'UBICACION_INTERNA'), pg_temp.loc(-32.89, -68.84), 'g4-3');
create temp table g4t as select location_finished_at t from public.route_stops where id = (select id from s4 where stop_type = 'UBICACION_INTERNA'); grant select on g4t to public;
select public.finish_internal_location((select id from s4 where stop_type = 'UBICACION_INTERNA'), pg_temp.loc(-32.89, -68.84), 'g4-3');
commit;
select tst.res('G4-04 TERMINÉ EN MONTECASEROS registra hora y GPS; NO cambia la recepción (PARCIAL) ni cierra la hoja; repetirlo no duplica',
  (select location_finished_at is not null and location_finished_location ? 'lat' and outcome = 'ENTREGA_PARCIAL' and location_finished_at = (select t from g4t) from public.route_stops where id = (select id from s4 where stop_type = 'UBICACION_INTERNA'))
  and (select operational_status from public.routes where id = (select id from f4)) = 'EN_CURSO', '');
-- ===== D4: regreso a DIAMANTE =====
begin; select tst.u(:'G'); set local role authenticated;
select tst.expect('D4-01 LLEGUÉ A DIAMANTE con paradas pendientes → PENDING_STOPS', format($q$ select public.arrive_depot(%L, %L, 'd4-0') $q$, (select id from f4), pg_temp.loc(-32.90, -68.80)), 'PENDING_STOPS%');
select public.set_stop_outcome((select id from s4 where stop_type = 'PEDIDO'), 'ENTREGADO', null, null, 'd4-e',
  jsonb_build_object('location', pg_temp.loc(-32.89, -68.84), 'evidence', jsonb_build_object('receiver_name', 'Receptor V423', 'signature_png_b64', :'PNG', 'cuil', '20123456786')));
select tst.expect('D4-02 dos ubicaciones "Diamante" y ninguna elegida → DEPOT_NOT_CONFIGURED (no se adivina)', format($q$ select public.arrive_depot(%L, %L, 'd4-1') $q$, (select id from f4), pg_temp.loc(-32.90, -68.80)), 'DEPOT_NOT_CONFIGURED%');
select tst.expect('D4-03 FINALIZAR sin LLEGUÉ A DIAMANTE → DEPOT_ARRIVAL_REQUIRED', format($q$ select public.finalize_route(%L, %s) $q$, (select id from f4), current_setting('okd.qa_km')::numeric + 50), 'DEPOT_ARRIVAL_REQUIRED%');
select tst.expect('D4-04 el transportista NO puede elegir el depósito', $q$ select public.set_return_depot('QA_DEP_DIAMANTE') $q$, 'FORBIDDEN%');
commit;
begin; select tst.u(:'A'); set local role authenticated;
create temp table rds as select public.return_depot_status() s; grant select on rds to public;
select public.set_return_depot('QA_DEP_DIAMANTE');
commit;
select tst.res('D4-05 el administrador ve las candidatas (clave, nombre, radio) y elige la ubicación EXISTENTE', jsonb_array_length((select s from rds)->'candidates') = 2 and (select s from rds)->'resolved' = 'null'::jsonb
  and (select location_key from public.return_depot_settings) = 'QA_DEP_DIAMANTE', (select (s->'candidates')::text from rds));
begin; select tst.u(:'G'); set local role authenticated;
select public.arrive_depot((select id from f4), pg_temp.loc(-32.92, -68.80), 'd4-2');    -- ~2,2 km afuera del radio de 150 m
create temp table d4t as select depot_arrived_at t from public.routes where id = (select id from f4); grant select on d4t to public;
select public.arrive_depot((select id from f4), pg_temp.loc(-32.90, -68.80), 'd4-2');
select tst.expect('D4-06 KM final MENOR al del vehículo → KM_LOWER (regla existente)', format($q$ select public.finalize_route(%L, %s) $q$, (select id from f4), current_setting('okd.qa_km')::numeric - 1), 'KM_LOWER%');
select tst.expect('D4-07 sin KM final → KM_REQUIRED (regla existente)', format($q$ select public.finalize_route(%L, null) $q$, (select id from f4)), 'KM_REQUIRED%');
select public.finalize_route((select id from f4), current_setting('okd.qa_km')::numeric + 60);
commit;
select tst.res('D4-08 LLEGUÉ A DIAMANTE registra hora, GPS (FUERA del radio, con advertencia, se permite seguir) y la clave; repetirlo no duplica; después FINALIZA y actualiza el km del vehículo',
  (select depot_location_key = 'QA_DEP_DIAMANTE' and depot_location ? 'outside_m' and (depot_location->>'outside_m')::int > 1000 and depot_arrived_at = (select t from d4t)
     and operational_status = 'COMPLETADA' from public.routes where id = (select id from f4))
  and (select current_km from public.vehicles where id = 'f0000000-0000-0000-0000-000000000001') = current_setting('okd.qa_km')::numeric + 60, (select depot_location::text from public.routes where id = (select id from f4)));
-- transición: una hoja interna INICIADA ANTES de aplicar la V4.23 no se bloquea
begin; select tst.u(:'S'); set local role authenticated;
select public.reserve_orders('V423-OLD', array['75010']);
create temp table f5 as select * from public.publish_route(jsonb_build_object('sheet_key','V423-OLD','carrier_id','INTERNO','responsable_id',:'G','vehicle_id','f0000000-0000-0000-0000-000000000001','rules_version',1,'routing_rules_version',1,'stops',jsonb_build_array(
  jsonb_build_object('client_name','Sucursal San Juan','address','San Juan','stop_type','UBICACION_INTERNA','internal_location_key','SAN_JUAN','order_numbers',jsonb_build_array('75010'),'ready',true))));
grant select on f5 to public; commit;
begin; select tst.u(:'G'); set local role authenticated; select public.start_route((select id from f5), current_setting('okd.qa_km')::numeric + 70);
select public.set_stop_outcome((select id from public.route_stops where route_id = (select id from f5)), 'REPROGRAMAR', null, 'cerrado', 'd5-r', jsonb_build_object('location', pg_temp.loc(-32.89, -68.84))); commit;
update public.routes set started_at = (select required_since from public.return_depot_settings) - interval '1 hour' where id = (select id from f5);
begin; select tst.u(:'G'); set local role authenticated; select public.finalize_route((select id from f5), current_setting('okd.qa_km')::numeric + 80); commit;
select tst.res('D4-09 TRANSICIÓN: una hoja interna INICIADA ANTES de aplicar la V4.23 se finaliza sin Diamante (no se bloquea a nadie)', (select operational_status from public.routes where id = (select id from f5)) = 'COMPLETADA', '');
-- ===== EM: padrón de emails por CUIT =====
-- CUIT conocidos = figuran en alguna parada (client_key); 27555555550 es VÁLIDO pero DESCONOCIDO; 20123456781 tiene dígito verificador MAL
set session_replication_role = replica;   -- (paradas ficticias solo para que esos CUIT figuren como clientes conocidos)
insert into public.route_stops(route_id, seq, sequence_number, client_name, address, stop_type, client_key, order_numbers, outcome)
  select (select id from f5), 90 + n, 90 + n, 'Cliente QA ' || k, 'Calle QA', 'PEDIDO', k, '{}'::text[], 'PENDIENTE'
  from (values (1, '20111111112'), (2, '20222222223'), (3, '20333333334'), (4, '20444444445')) v(n, k);
set session_replication_role = origin;
begin; select tst.u(:'A'); set local role authenticated;
select public.client_email_upsert('20123456786', 'Cliente V423 SA', 'pagos@cliente-v423.test');
select public.client_email_upsert('20444444445', 'Cliente Conservar', 'viejo@conservar.test');
create temp table rows_x as select '[
  {"cuit":"20-12345678-6","name":"Cliente V423 SA","email":"nuevo@cliente-v423.test"},
  {"cuit":"20123456781","name":"CUIT mal","email":"a@b.test"},
  {"cuit":"27555555550","name":"Desconocido","email":"x@y.test"},
  {"cuit":"20111111112","name":"Duplicado","email":"d1@d.test"},
  {"cuit":"20111111112","name":"Duplicado","email":"d2@d.test"},
  {"cuit":"20222222223","name":"Email malo","email":"no-es-email"},
  {"cuit":"20333333334","name":"Nuevo SA","email":"compras@nuevo.test"},
  {"cuit":"20444444445","name":"Cliente Conservar","email":""}]'::jsonb j; grant select on rows_x to public;
create temp table pv as select public.client_emails_preview((select j from rows_x)) p; grant select on pv to public;
commit;
select tst.res('EM-01 VISTA PREVIA (no escribe): ACTUALIZAR · CUIT_INVALIDO (dígito verificador) · DESCONOCIDO · DUPLICADO ×2 · EMAIL_INVALIDO · NUEVO · SIN_EMAIL',
  (select string_agg(f->>'estado', ',' order by ord) from pv, jsonb_array_elements(p->'filas') with ordinality as t(f, ord)) = 'ACTUALIZAR,CUIT_INVALIDO,DESCONOCIDO,DUPLICADO,DUPLICADO,EMAIL_INVALIDO,NUEVO,SIN_EMAIL'
  and (select count(*) from public.client_emails) = 2,
  (select string_agg(f->>'estado', ',' order by ord) from pv, jsonb_array_elements(p->'filas') with ordinality as t(f, ord)));
begin; select tst.u(:'A'); set local role authenticated;
create temp table ap1 as select public.client_emails_apply((select j from rows_x), 'CONSERVAR', 'emails_qa.xlsx') r; grant select on ap1 to public; commit;
select tst.res('EM-02 CONSERVAR: agrega SOLO el nuevo; NO cambia el existente; el vacío NO borra; nada de desconocidos, duplicados ni inválidos; queda registrada la importación',
  (select email from public.client_emails where cuit = '20333333334') = 'compras@nuevo.test' and (select email from public.client_emails where cuit = '20123456786') = 'pagos@cliente-v423.test'
  and (select email from public.client_emails where cuit = '20444444445') = 'viejo@conservar.test' and (select count(*) from public.client_emails) = 3
  and (select (r->>'insertados')::int = 1 and (r->>'actualizados')::int = 0 from ap1) and exists (select 1 from public.client_email_imports where file_name = 'emails_qa.xlsx' and mode = 'CONSERVAR'), (select r::text from ap1));
begin; select tst.u(:'A'); set local role authenticated;
create temp table ap2 as select public.client_emails_apply((select j from rows_x), 'REEMPLAZAR', 'emails_qa2.xlsx') r; grant select on ap2 to public; commit;
select tst.res('EM-03 REEMPLAZAR: actualiza el existente por el del Excel; el vacío sigue sin borrar', (select email from public.client_emails where cuit = '20123456786') = 'nuevo@cliente-v423.test'
  and (select email from public.client_emails where cuit = '20444444445') = 'viejo@conservar.test' and (select (r->>'actualizados')::int from ap2) = 1, (select r::text from ap2));
begin; select tst.u(:'A'); set local role authenticated;
select tst.expect('EM-04a edición manual con CUIT inválido → CUIT_INVALIDO', $q$ select public.client_email_upsert('20123456781', 'x', 'a@b.test') $q$, 'CUIT_INVALIDO%');
select tst.expect('EM-04b edición manual con email inválido → EMAIL_INVALID', $q$ select public.client_email_upsert('20123456786', 'x', 'mal') $q$, 'EMAIL_INVALID%');
commit;
begin; select tst.u(:'O'); set local role authenticated;
select tst.expect('EM-05a el OPERARIO no administra el padrón (solo el Administrador General)', $q$ select public.client_emails_preview('[]') $q$, 'FORBIDDEN%');
commit;
begin; select tst.u(:'G'); set local role authenticated;
create temp table vis as select (select count(*) from public.client_emails) n; grant select on vis to public;
select tst.expect('EM-05b el TRANSPORTISTA no puede editar el padrón', $q$ select public.client_email_upsert('20123456786', 'x', 'a@b.test') $q$, 'FORBIDDEN%');
commit;
select tst.res('EM-05c el TRANSPORTISTA no ve el padrón completo (RLS: 0 filas)', (select n from vis) = 0, (select n::text from vis));
-- sugerencia para la entrega: solo SU parada; la hoja manda sobre el padrón
begin; select tst.u(:'S'); set local role authenticated;
select public.reserve_orders('V423-SUG', array['75020','75021']);
create temp table f6 as select * from public.publish_route(jsonb_build_object('sheet_key','V423-SUG','carrier_id','INTERNO','responsable_id',:'G','vehicle_id','f0000000-0000-0000-0000-000000000001','rules_version',1,'routing_rules_version',1,'stops',jsonb_build_array(
  jsonb_build_object('client_name','Con padrón','address','Calle 6','stop_type','PEDIDO','order_numbers',jsonb_build_array('75020'),'merchandise_amount',100,'task','ENTREGA','ready',true),
  jsonb_build_object('client_name','Con email en la hoja','address','Calle 7','stop_type','PEDIDO','order_numbers',jsonb_build_array('75021'),'merchandise_amount',100,'task','ENTREGA','ready',true))));
grant select on f6 to public; commit;
update public.route_stops set client_key = '20333333334', customer_email = null where route_id = (select id from f6) and client_name = 'Con padrón';
update public.route_stops set client_key = '20333333334', customer_email = 'hoja@cliente.test' where route_id = (select id from f6) and client_name = 'Con email en la hoja';
begin; select tst.u(:'G'); set local role authenticated;
create temp table sg as select public.delivery_email_suggestion((select id from public.route_stops where route_id = (select id from f6) and client_name = 'Con padrón')) a,
  public.delivery_email_suggestion((select id from public.route_stops where route_id = (select id from f6) and client_name = 'Con email en la hoja')) b; grant select on sg to public;
commit;
select tst.res('EM-06 sugerencia en la entrega: del PADRÓN si la hoja no trae email; si la hoja trae uno, ese manda', (select a = 'compras@nuevo.test' and b = 'hoja@cliente.test' from sg), (select a || ' / ' || b from sg));
begin; select tst.u(:'G'); set local role authenticated; select public.start_route((select id from f6), (select current_km from public.vehicles where id = 'f0000000-0000-0000-0000-000000000001') + 5);
select public.set_stop_outcome((select id from public.route_stops where route_id = (select id from f6) and client_name = 'Con padrón'), 'ENTREGADO', null, null, 'em-7',
  jsonb_build_object('location', pg_temp.loc(-32.89, -68.84), 'evidence', jsonb_build_object('receiver_name', 'Receptor QA', 'signature_png_b64', :'PNG', 'cuil', '20333333334', 'email', 'otro@escrito.test')));
select public.set_stop_outcome((select id from public.route_stops where route_id = (select id from f6) and client_name = 'Con padrón'), 'ENTREGADO', null, null, 'em-7',
  jsonb_build_object('location', pg_temp.loc(-32.89, -68.84), 'evidence', jsonb_build_object('receiver_name', 'Receptor QA', 'signature_png_b64', :'PNG', 'cuil', '20333333334', 'email', 'otro@escrito.test')));
commit;
select tst.res('EM-07 email ESCRITO por el transportista: se usa en ESA entrega (un solo Recibido Conforme) y NO cambia el padrón',
  (select receiver_email from public.stop_evidence where stop_id = (select id from public.route_stops where route_id = (select id from f6) and client_name = 'Con padrón')) = 'otro@escrito.test'
  and (select email from public.client_emails where cuit = '20333333334') = 'compras@nuevo.test'
  and (select count(*) from public.customer_email_jobs where stop_id = (select id from public.route_stops where route_id = (select id from f6) and client_name = 'Con padrón') and kind = 'RECIBIDO_CONFORME') = 1, '');
-- ===== privilegios de los objetos nuevos =====
select tst.res('PV-01 anon sin acceso a tablas y funciones nuevas; las auxiliares no las ejecuta authenticated (salvo la de RLS)',
  not exists (select 1 from unnest(array['return_depot_settings','client_emails','client_email_imports']) t, unnest(array['SELECT','INSERT','UPDATE','DELETE','TRUNCATE']) pr where has_table_privilege('anon', 'public.' || t, pr))
  and not has_table_privilege('authenticated', 'public.client_emails', 'INSERT') and not has_table_privilege('authenticated', 'public.client_emails', 'TRUNCATE')
  and not has_function_privilege('authenticated', 'public._cuit_valid(text)', 'EXECUTE') and not has_function_privilege('authenticated', 'public._return_depot()', 'EXECUTE')
  and not has_function_privilege('anon', 'public.arrive_depot(uuid,jsonb,text)', 'EXECUTE') and has_function_privilege('authenticated', 'public._is_general_admin()', 'EXECUTE'), '');
