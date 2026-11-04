-- Pruebas de la PROPUESTA V4.24 (salida del depósito y SALÍ DE <SUCURSAL>). Corre DESPUÉS de g2_revision_test. Datos FICTICIOS.
\set ON_ERROR_STOP on
\set S 'e0000000-0000-0000-0000-000000000005'
\set G 'e0000000-0000-0000-0000-000000000007'
\set A 'e0000000-0000-0000-0000-00000000000a'
\set PNG 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='
insert into public.internal_locations(location_key, name, address, lat, lon, radius_m) values ('QA_DEP_DIAMANTE', 'Depósito Diamante QA', 'Calle Diamante 100', -32.9000, -68.8000, 150) on conflict do nothing;
create or replace function pg_temp.loc(lat float, lon float) returns jsonb language sql as $f$ select jsonb_build_object('lat', lat, 'lon', lon, 'accuracy', 8) $f$;
begin; select tst.u(:'S'); set local role authenticated;
select public.reserve_orders('V424-GB', array['76001','76002']);
create temp table f4 as select * from public.publish_route(jsonb_build_object('sheet_key','V424-GB','carrier_id','INTERNO','responsable_id',:'G','vehicle_id','f0000000-0000-0000-0000-000000000001','rules_version',1,'routing_rules_version',1,'stops',jsonb_build_array(
  jsonb_build_object('client_name','CLIENTE V424','address','Calle 1','stop_type','PEDIDO','order_numbers',jsonb_build_array('76001'),'merchandise_amount',1000,'task','ENTREGA','ready',true),
  jsonb_build_object('client_name','Montecaseros - casa central','address','Montecaseros','stop_type','UBICACION_INTERNA','internal_location_key','MONTECASEROS','order_numbers',jsonb_build_array('76002'),'ready',true))));
grant select on f4 to public; commit;
create temp table s4 as select id, stop_type from public.route_stops where route_id = (select id from f4); grant select on s4 to public;
begin; select tst.u(:'G'); set local role authenticated;
select tst.expect('SR-01 GPS de salida ANTES de iniciar el recorrido → START_FIRST', format($q$ select public.record_route_departure(%L, %L, 's0') $q$, (select id from f4), pg_temp.loc(-32.90, -68.80)), 'START_FIRST%');
select public.start_route((select id from f4), (select current_km from public.vehicles where id = 'f0000000-0000-0000-0000-000000000001') + 10);
select public.record_route_departure((select id from f4), pg_temp.loc(-32.9001, -68.8001), 's1');
create temp table t1 as select start_location l from public.routes where id = (select id from f4); grant select on t1 to public;
select public.record_route_departure((select id from f4), pg_temp.loc(-32.95, -68.90), 's1');
commit;
select tst.res('SR-02 SALÍ DEL DEPÓSITO: reutiliza el inicio (started_at, km_start) y guarda el GPS con el radio del depósito configurado (dentro); repetirlo NO lo cambia',
  (select started_at is not null and km_start is not null and start_location = (select l from t1) and start_location_key = 'QA_DEP_DIAMANTE' and not (start_location ? 'outside_m' and start_location->>'outside_m' is not null) from public.routes where id = (select id from f4)), (select start_location::text from public.routes where id = (select id from f4)));
begin; select tst.u(:'G'); set local role authenticated;
select tst.expect('SR-03 SALÍ DE una entrega COMERCIAL → NOT_INTERNAL_LOCATION', format($q$ select public.depart_internal_location(%L, %L, 'd0') $q$, (select id from s4 where stop_type = 'PEDIDO'), pg_temp.loc(-32.89, -68.84)), 'NOT_INTERNAL_LOCATION%');
select public.arrive_stop((select id from s4 where stop_type = 'UBICACION_INTERNA'), pg_temp.loc(-32.89, -68.84), 'a1');
select public.set_stop_outcome((select id from s4 where stop_type = 'UBICACION_INTERNA'), 'ENTREGA_PARCIAL', 'faltó una caja', null, 'o1',
  jsonb_build_object('location', pg_temp.loc(-32.89, -68.84), 'evidence', jsonb_build_object('receiver_name', 'Encargada QA', 'signature_png_b64', :'PNG')));
select tst.expect('SR-04 SALÍ DE MONTECASEROS ANTES de TERMINÉ → FINISH_FIRST (no se confunden)', format($q$ select public.depart_internal_location(%L, %L, 'd1') $q$, (select id from s4 where stop_type = 'UBICACION_INTERNA'), pg_temp.loc(-32.89, -68.84)), 'FINISH_FIRST%');
select public.finish_internal_location((select id from s4 where stop_type = 'UBICACION_INTERNA'), pg_temp.loc(-32.89, -68.84), 'f1');
commit;   -- TERMINÉ y SALÍ son DOS acciones del chofer (dos operaciones): now() es distinto en cada una
begin; select tst.u(:'G'); set local role authenticated;
select public.depart_internal_location((select id from s4 where stop_type = 'UBICACION_INTERNA'), pg_temp.loc(-32.8901, -68.8401), 'd2');
create temp table t2 as select location_departed_at t from public.route_stops where id = (select id from s4 where stop_type = 'UBICACION_INTERNA'); grant select on t2 to public;
select public.depart_internal_location((select id from s4 where stop_type = 'UBICACION_INTERNA'), pg_temp.loc(-32.95, -68.90), 'd2');
commit;
select tst.res('SR-05 SALÍ DE MONTECASEROS: evento PROPIO (hora y GPS distintos de TERMINÉ); NO cambia la recepción PARCIAL ni cierra la hoja; repetirlo NO duplica',
  (select location_departed_at = (select t from t2) and location_departed_at > location_finished_at and location_departed_location ? 'lat' and outcome = 'ENTREGA_PARCIAL'
     from public.route_stops where id = (select id from s4 where stop_type = 'UBICACION_INTERNA')) and (select operational_status from public.routes where id = (select id from f4)) = 'EN_CURSO', '');
begin; select tst.u(:'G'); set local role authenticated;
select tst.expect('SR-06 el cierre SIGUE exigiendo LLEGUÉ A DIAMANTE (V4.23)', format($q$ select public.finalize_route(%L, %s) $q$, (select id from f4), (select km_start + 50 from public.routes where id = (select id from f4))), 'PENDING_STOPS%');
commit;
select tst.res('PV-24 anon sin ejecución de las funciones nuevas; authenticated sí (controladas por _my_route)',
  not has_function_privilege('anon', 'public.record_route_departure(uuid,jsonb,text)', 'EXECUTE') and not has_function_privilege('anon', 'public.depart_internal_location(uuid,jsonb,text)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.depart_internal_location(uuid,jsonb,text)', 'EXECUTE'), '');
