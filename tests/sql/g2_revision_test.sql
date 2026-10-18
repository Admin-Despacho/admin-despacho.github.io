-- Pruebas AUTÓNOMAS de la corrección INFORME_REVISION_CLAUDE.md (G2, traslado interno, TAREA, reservas, snapshot GPS, paradas del chofer).
-- Crea sus propios usuarios, transportistas y ubicaciones; no depende de los fixtures históricos.
-- Correr: SQL_TESTS="g2_revision_test" SKIP_CONCURRENCY=1 bash tests/sql/run.sh
\set ON_ERROR_STOP on
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

\set A  'e0000000-0000-0000-0000-00000000000a'
\set S  'e0000000-0000-0000-0000-000000000005'
\set O  'e0000000-0000-0000-0000-000000000006'
\set G  'e0000000-0000-0000-0000-000000000007'
\set X  'e0000000-0000-0000-0000-000000000008'
\set D2 'e0000000-0000-0000-0000-000000000009'
insert into auth.users(id, email) values (:'A','g2admin@t'),(:'S','g2sup@t'),(:'O','g2op@t'),(:'G','g2chofer@t'),(:'X','g2ext@t'),(:'D2','g2otro@t') on conflict do nothing;
select set_config('okd.sync', 'on', false);
insert into public.profiles(id, full_name, email, role, status) values
  (:'A','Admin G2','g2admin@t','ADMIN','ACTIVO'), (:'S','Superior G2','g2sup@t','SUPERVISOR_DESPACHO','ACTIVO'), (:'O','Operario G2','g2op@t','OPERARIO_DEPOSITO','ACTIVO'),
  (:'G','Chofer Interno G2','g2chofer@t','TRANSPORTISTA_INTERNO','ACTIVO'), (:'X','Externo G2','g2ext@t','SOLO_LECTURA','ACTIVO'), (:'D2','Otro operador','g2otro@t','SUPERVISOR_DESPACHO','ACTIVO')
on conflict (id) do nothing;
-- un TRANSPORTISTA necesita su transportista externo antes de tener el rol
insert into public.user_carriers(user_id, carrier_id) select :'X', id from public.carriers where kind = 'EXTERNO' and active order by id limit 1 on conflict do nothing;
update public.profiles set role = 'TRANSPORTISTA' where id = :'X';
select set_config('okd.sync', '', false);
insert into public.vehicles(id, name, plate, current_km, last_service_km) values ('f0000000-0000-0000-0000-000000000001', 'KANGOO G2', 'G2TEST1', 1000, 1000) on conflict do nothing;
create temp table t_ext as select carrier_id from public.user_carriers where user_id = :'X' limit 1; grant select on t_ext to public;

-- ===== G2: Admin crea dos ubicaciones; Superior/Operario LEEN pero NO modifican =====
begin; select tst.u(:'A'); set local role authenticated;
select public.upsert_internal_location('{"location_key":"MONTECASEROS","name":"Montecaseros - casa central","address":"Montecaseros 1234, Mendoza","lat":-32.8900,"lon":-68.8400,"radius_m":200}');
select public.upsert_internal_location('{"location_key":"SAN_JUAN","name":"Sucursal San Juan","address":"San Juan 500, Mendoza","lat":-32.8950,"lon":-68.8450,"radius_m":150}');
select tst.expect('G2-05 Nombre duplicado entre ubicaciones activas rechazado', $q$ select public.upsert_internal_location('{"location_key":"OTRA","name":"montecaseros - CASA central","lat":-32.9,"lon":-68.8}') $q$, 'DUPLICATE_LOCATION_NAME%');
commit;
begin; select tst.u(:'S'); set local role authenticated;
select tst.res('G2-01 Superior Despacho LEE las ubicaciones G2 (antes recibía lista vacía)', (select count(*) from public.internal_locations where location_key in ('MONTECASEROS','SAN_JUAN')) = 2, '');
select tst.expect('G2-02 Superior NO modifica G2 (RPC)', $q$ select public.upsert_internal_location('{"location_key":"MONTECASEROS","name":"X","lat":0,"lon":0}') $q$, 'FORBIDDEN%');
select tst.expect('G2-03 Superior NO modifica G2 (UPDATE directo)', $q$ update public.internal_locations set lat = 0 where location_key = 'MONTECASEROS' $q$, '%');
commit;
select tst.res('G2-03b El UPDATE directo no cambió nada', (select lat from public.internal_locations where location_key = 'MONTECASEROS') = -32.89, '');
begin; select tst.u(:'O'); set local role authenticated;
select tst.res('G2-04 Operario Depósito LEE G2', (select count(*) from public.internal_locations) >= 2, '');
commit;
begin; select tst.u(:'G'); set local role authenticated;
select tst.res('G2-04b Transportista Interno NO lee G2 (no administra ubicaciones maestras)', not exists (select 1 from public.internal_locations), '');
commit;

-- ===== Reserva atómica: el 2º pedido está en otra hoja → ninguno queda reservado =====
begin; select tst.u(:'D2'); set local role authenticated; select public.reserve_orders('G2-OTRA', array['70002']); commit;
begin; select tst.u(:'S'); set local role authenticated;
select tst.expect('RES-01 Reserva en UNA llamada con un pedido ya tomado → error', $q$ select public.reserve_orders('G2-HOJA', array['70001','70002','70003']) $q$, 'PEDIDO_YA_EN_OTRA_HOJA%');
commit;
select tst.res('RES-02 Ningún pedido quedó reservado a medias (70001/70003 libres)', not exists (select 1 from public.order_reservations where order_id in ('70001','70003')), '');

-- ===== Montecaseros + 3 pedidos (uno con envío) = UNA parada =====
begin; select tst.u(:'S'); set local role authenticated;
select public.reserve_orders('G2-HOJA', array['71001','71002','71003','71004']);
create temp table t_r as select * from public.publish_route(jsonb_build_object('sheet_key','G2-HOJA','carrier_id','INTERNO','responsable_id',:'G','vehicle_id','f0000000-0000-0000-0000-000000000001','rules_version',1,'routing_rules_version',1,'stops',jsonb_build_array(
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
begin; select tst.u(:'S'); set local role authenticated;
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
begin; select tst.u(:'A'); set local role authenticated;
select public.upsert_internal_location('{"location_key":"MONTECASEROS","name":"Montecaseros - casa central","address":"Montecaseros 1234, Mendoza","lat":-33.5,"lon":-69.5,"radius_m":50,"active":false}');
commit;
begin; select tst.u(:'G'); set local role authenticated;
select public.start_route((select id from t_r), 1000);
select public.arrive_stop((select id from t_s where stop_type = 'UBICACION_INTERNA'), '{"lat":-32.8901,"lon":-68.8401,"accuracy":8}', 'g2-arr-1');
commit;
select tst.res('GPS-01 Llegada validada contra el SNAPSHOT (punto original, radio 200) aunque G2 se movió y desactivó; guarda real + esperado + radio + distancia + fuente',
  (arrive_location->>'validation_source') = 'INTERNAL_SNAPSHOT' and (arrive_location->>'expected_lat')::float8 = -32.89 and (arrive_location->>'radius_m')::int = 200
  and (arrive_location->>'distance_m')::numeric < 50 and arrive_location->>'outside_m' is null and arrive_location ? 'lat' and (arrive_location->>'validation_key') = 'MONTECASEROS', arrive_location::text)
  from public.route_stops where id = (select id from t_s where stop_type = 'UBICACION_INTERNA');

-- ===== Cierre por tipo: traslado y TAREA no son entrega comercial =====
begin; select tst.u(:'G'); set local role authenticated;
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
  evidence_kind = 'RECEPCION_INTERNA' and receiver_name = 'Encargado sucursal' and signature_sha256 is not null and created_by = :'G' and receiver_email is null, evidence_kind)
  from public.stop_evidence where stop_id = (select id from t_s where stop_type = 'UBICACION_INTERNA');
select tst.res('REC-03 Auditoría "INTERNAL_TRANSFER_RECEIVED": sucursal, pedidos, quién recibió, quién trasladó, hoja, GPS real y esperado',
  after->>'internal_location_key' = 'MONTECASEROS' and after->'order_numbers' = '["71001","71002","71003","71004"]'::jsonb and after->>'receiver_name' = 'Encargado sucursal'
  and after->>'transported_by' = :'G' and after->>'route_number' is not null and (after->'gps'->>'expected_lat')::float8 = -32.89 and (after->'gps') ? 'lat', after::text)
  from public.audit_log where action = 'INTERNAL_TRANSFER_RECEIVED' and target_id = (select id::text from t_s where stop_type = 'UBICACION_INTERNA');
select tst.res('REC-04 La TAREA sin firma no genera evidencia de entrega', not exists (select 1 from public.stop_evidence where stop_id = (select id from t_s where stop_type = 'TAREA')), '');
select tst.res('LOC-08 Trazabilidad: los pedidos quedan asociados a la parada de traslado de esa hoja', (select order_numbers from public.route_stops where id = (select id from t_s where stop_type = 'UBICACION_INTERNA')) = array['71001','71002','71003','71004']
  and (select count(*) from public.order_reservations where route_id = (select id from t_r) and order_id in ('71001','71002','71003','71004')) = 4, '');
select tst.res('TAR-02 TAREA REALIZADA sin firma ni receptor (GPS + observación); sin email, sin comprobante', outcome = 'ENTREGADO' and outcome_note = 'Bolsas retiradas' and finish_location ? 'lat'
  and not exists (select 1 from public.customer_email_jobs where stop_id = s.id) and not exists (select 1 from public.delivery_receipts where stop_id = s.id), outcome) from public.route_stops s where s.id = (select id from t_s where stop_type = 'TAREA');

-- ===== Parada dinámica agregada por el Transportista Interno =====
create temp table t_v as select version from public.routes where id = (select id from t_r); grant select on t_v to public;
begin; select tst.u(:'G'); set local role authenticated;
select public.add_internal_stop((select id from t_r), '{"client_name":"Banco Nación","address":"San Martín 1100, Mendoza","instructions":"Depositar efectivo","contact_name":"Caja","contact_phone":"261444","order_numbers":["99999"]}', (select version from t_v), 'g2-add-1');
commit;
select tst.res('DRV-01 Parada del chofer: provenance DRIVER, TAREA, usuario y fecha, instrucciones/contacto, al final del recorrido, sin pedidos ni G2',
  provenance = 'DRIVER' and stop_type = 'TAREA' and added_by = :'G' and added_at is not null and instructions = 'Depositar efectivo' and contact_name = 'Caja'
  and coalesce(array_length(order_numbers, 1), 0) = 0 and internal_location_key is null and expected_lat is null
  and sequence_number = (select max(sequence_number) from public.route_stops where route_id = (select id from t_r)), stop_type || ' ' || coalesce(internal_location_key, '-'))
  from public.route_stops where route_id = (select id from t_r) and provenance = 'DRIVER';
select tst.res('DRV-02 Versionada y auditada', (select version from public.routes where id = (select id from t_r)) = (select version from t_v) + 1
  and exists (select 1 from public.route_change_events where client_op_id = 'g2-add-1' and event_type = 'INTERNAL_STOP_ADDED' and user_id = :'G')
  and exists (select 1 from public.audit_log where action = 'INTERNAL_STOP_ADDED' and actor_id = :'G'), '');
begin; select tst.u(:'G'); set local role authenticated;
select tst.expect('DRV-03 El chofer NO reordena paradas ya resueltas', format($q$ select public.reorder_internal_stops(%L, array[%L]::uuid[], %s, 'g2-re-1') $q$, (select id from t_r),
  (select id from t_s where stop_type = 'UBICACION_INTERNA'), (select version from public.routes where id = (select id from t_r))), 'COMPLETED_STOP_FIXED%');
select tst.expect('DRV-04 El chofer NO edita paradas por UPDATE directo', format($q$ update public.route_stops set address = 'otra', order_numbers = '{}' where id = %L $q$, (select id from t_s where stop_type = 'UBICACION_INTERNA')), '%');
select tst.expect('DRV-05 El chofer NO modifica G2', $q$ select public.upsert_internal_location('{"location_key":"MONTECASEROS","name":"X","lat":0,"lon":0}') $q$, 'FORBIDDEN%');
commit;
select tst.res('DRV-06 La parada administrativa quedó intacta (domicilio y pedidos)', address = 'Montecaseros 1234, Mendoza' and order_numbers = array['71001','71002','71003','71004'], address) from public.route_stops where id = (select id from t_s where stop_type = 'UBICACION_INTERNA');

-- ===== KPIs: una TAREA no realizada NO cuenta como incidencia de entrega comercial =====
begin; select tst.u(:'A'); set local role authenticated;
create temp table t_k1 as select (public.dashboard_admin()->'kpis'->>'incidencias')::int k; grant select on t_k1 to public;
commit;
begin; select tst.u(:'G'); set local role authenticated;
select public.set_stop_outcome((select id from public.route_stops where route_id = (select id from t_r) and provenance = 'DRIVER'), 'NO_ENTREGADO', null, 'Banco cerrado', 'g2-out-3', '{"location":{"lat":-32.88,"lon":-68.83}}');
commit;
begin; select tst.u(:'A'); set local role authenticated;
select tst.res('KPI-01 TAREA no realizada NO suma a las incidencias de entrega del dashboard (con el criterio anterior sí habría sumado 1)',
  (public.dashboard_admin()->'kpis'->>'incidencias')::int = (select k from t_k1)
  and (select count(*) from public.route_stops s where s.route_id = (select id from t_r) and s.outcome in ('NO_ENTREGADO','REPROGRAMAR','ENTREGA_PARCIAL')) = 1,
  (select k from t_k1)::text || ' → ' || (public.dashboard_admin()->'kpis'->>'incidencias'));
commit;

-- ===== Web Push: un trabajo por notificación, toma atómica y reintentos =====
select tst.res('PUSH-01 Publicar la hoja generó UN trabajo push para el chofer (NUEVA_HOJA_PUBLICADA)', (select count(*) from public.push_jobs j join public.notifications n on n.id = j.notification_id
  where n.user_id = :'G' and n.type = 'NUEVA_HOJA_PUBLICADA' and n.route_id = (select id from t_r)) = 1, '');
begin; select tst.u(:'A'); set local role authenticated;
select tst.expect('PUSH-02 Un usuario (ni Admin) NO puede tomar trabajos push', $q$ select * from public.claim_push_jobs(10) $q$, '%permission denied%');
commit;
update public.push_jobs set status = 'SKIPPED';   -- dejar solo los de esta prueba
insert into public.notifications(user_id, route_id, route_version, type, title, body) values (:'G', (select id from t_r), 7, 'HOJA_CORREGIDA', 'HOJA CORREGIDA', 'prueba push');
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
values (:'G', (select id from t_r), 998, 'HOJA_CORREGIDA', 'HOJA CORREGIDA', 'Hoja singular · 1 entrega');
select tst.res('WORD-SING-01 Aviso interno singular: 1 parada (nunca 1 paradas / 1 entrega)',
  exists (
    select 1 from public.notifications
    where user_id = :'G' and route_id = (select id from t_r) and route_version = 998
      and type = 'HOJA_CORREGIDA' and body = 'Hoja singular · 1 parada'
  ),
  coalesce((select body from public.notifications where user_id = :'G' and route_id = (select id from t_r) and route_version = 998 and type = 'HOJA_CORREGIDA'), 'SIN AVISO')
);

-- ===== PARCHE: el chofer agrega una UBICACIÓN INTERNA G2 (segunda visita a Montecaseros) =====
select tst.res('WORD-01 Aviso de hoja interna cuenta PARADAS (no entregas)', (select bool_and(body ~ ' paradas$') and bool_and(body !~ 'entregas') and count(*) >= 1 from public.notifications where user_id = :'G' and type = 'NUEVA_HOJA_PUBLICADA' and route_id = (select id from t_r)),
  (select string_agg(body, ' | ') from public.notifications where user_id = :'G' and type = 'NUEVA_HOJA_PUBLICADA' and route_id = (select id from t_r)));
begin; select tst.u(:'A'); set local role authenticated;
-- G2 reactivado y movido: el snapshot de la parada nueva debe tomar ESTE punto, y la original conservar el suyo
select public.upsert_internal_location('{"location_key":"MONTECASEROS","name":"Montecaseros - casa central","address":"Montecaseros 1529, Ciudad Mendoza","lat":-32.8000,"lon":-68.8000,"radius_m":120,"active":true}');
commit;
begin; select tst.u(:'G'); set local role authenticated;
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
  and d.instructions = 'Retirar documentación' and d.added_by = :'G' and d.added_at is not null and d.outcome = 'PENDIENTE'
  and d.sequence_number = (select max(sequence_number) from public.route_stops where route_id = (select id from t_r)), d.client_name || ' · ' || d.address) from t_d2 d;
select tst.res('DRVLOC-02 Snapshot GPS tomado AL AGREGARLA (punto y radio vigentes en G2 en ese momento)', expected_lat = -32.80 and expected_lon = -68.80 and expected_radius_m = 120 and internal_location_updated_at is not null, '') from t_d2;
select tst.res('DRVLOC-03 El chofer NO asocia pedidos ni montos (los ignora el servidor)', coalesce(array_length(order_numbers, 1), 0) = 0 and merchandise_amount = 0 and customer_email is null, coalesce(array_to_string(order_numbers, ','), '')) from t_d2;
select tst.res('DRVLOC-04 Mismo client_op_id dos veces → UNA sola parada nueva; versión +1 y auditada una vez', (select count(*) from public.route_stops where route_id = (select id from t_r) and provenance = 'DRIVER' and stop_type = 'UBICACION_INTERNA') = 1
  and (select version from public.routes where id = (select id from t_r)) = (select version from t_v2) + 1
  and (select count(*) from public.route_change_events where client_op_id = 'g2-loc-1') = 1, '');
select tst.res('DRVLOC-05 La parada Montecaseros ORIGINAL no cambió (pedidos, snapshot, resultado)', order_numbers = array['71001','71002','71003','71004'] and expected_lat = -32.89 and expected_radius_m = 200 and outcome = 'ENTREGADO', '')
  from public.route_stops where id = (select id from t_s where stop_type = 'UBICACION_INTERNA');
begin; select tst.u(:'A'); set local role authenticated;
select public.upsert_internal_location('{"location_key":"MONTECASEROS","name":"Montecaseros - casa central","address":"Montecaseros 1529, Ciudad Mendoza","lat":-33.9,"lon":-69.9,"radius_m":30,"active":true}');
commit;
begin; select tst.u(:'G'); set local role authenticated;
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
