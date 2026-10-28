-- Pruebas de la PROPUESTA de reenvíos (reserve_orders). Corre DESPUÉS de g2_revision_test (usa S = Superior, G = Transportista interno,
-- O = Operario, vehículo y ubicaciones). Pedidos FICTICIOS.
\set ON_ERROR_STOP on
\set S 'e0000000-0000-0000-0000-000000000005'
\set O 'e0000000-0000-0000-0000-000000000006'
\set G 'e0000000-0000-0000-0000-000000000007'
create or replace function pg_temp.pub(k text, orders text[]) returns uuid language plpgsql as $f$ declare rid uuid; begin
  perform public.reserve_orders(k, orders);
  select id into rid from public.publish_route(jsonb_build_object('sheet_key', k, 'carrier_id', 'INTERNO', 'responsable_id', 'e0000000-0000-0000-0000-000000000007',
    'vehicle_id', 'f0000000-0000-0000-0000-000000000001', 'rules_version', 1, 'routing_rules_version', 1, 'stops',
    (select jsonb_agg(jsonb_build_object('client_name', 'Cliente ' || o, 'address', 'Calle ' || o, 'stop_type', 'PEDIDO', 'order_numbers', jsonb_build_array(o), 'merchandise_amount', 1000, 'task', 'ENTREGA', 'ready', true)) from unnest(orders) o)));
  return rid; end $f$;
grant execute on function pg_temp.pub(text, text[]) to public;
begin; select tst.u(:'S'); set local role authenticated;
create temp table r1 as select pg_temp.pub('RE-H1', array['RE81001','RE81002','RE81003','RE81005']) id;
create temp table r3 as select pg_temp.pub('RE-H3', array['RE81004']) id;
grant select on r1, r3 to public;
commit;
-- resultados del primer intento: no entregado, pendiente, entregado; RE81005 en DOS paradas (una no entregada y otra pendiente)
update public.route_stops set outcome = 'NO_ENTREGADO' where route_id = (select id from r1) and 'RE81001' = any(order_numbers);
update public.route_stops set outcome = 'ENTREGADO' where route_id = (select id from r1) and 'RE81003' = any(order_numbers);
update public.route_stops set outcome = 'NO_ENTREGADO' where route_id = (select id from r1) and 'RE81005' = any(order_numbers);
insert into public.route_stops(route_id, seq, sequence_number, client_name, order_numbers, stop_type, outcome)
  values ((select id from r1), 99, 99, 'Cliente RE81005 bis', array['RE81005'], 'PEDIDO', 'PENDIENTE');
update public.routes set operational_status = 'CANCELADA', status = 'CANCELADA' where id = (select id from r3);
create temp table before_r1 as select id, outcome, order_numbers from public.route_stops where route_id = (select id from r1); grant select on before_r1 to public;
begin; select tst.u(:'S'); set local role authenticated;
select public.reserve_orders('RE-H2', array['RE81001']);
commit;
select tst.res('RE-SQL-01 pedido NO ENTREGADO: se puede volver a cargar en una hoja nueva (la reserva pasa al borrador nuevo)',
  (select sheet_key = 'RE-H2' and status = 'BORRADOR' and route_id is null from public.order_reservations where order_id = 'RE81001'), '');
select tst.res('RE-SQL-02 la reserva anterior queda en el historial (hoja, motivo y destino)',
  exists (select 1 from public.order_reservation_history where order_id = 'RE81001' and route_id = (select id from r1) and released_to_sheet = 'RE-H2' and reason = 'REINTENTO_NO_ENTREGADO_O_REPROGRAMADO'), '');
select tst.res('RE-SQL-03 la hoja anterior y sus resultados NO se tocan', not exists (select 1 from before_r1 b join public.route_stops s on s.id = b.id where s.outcome is distinct from b.outcome)
  and (select count(*) from public.route_stops where route_id = (select id from r1)) = (select count(*) from before_r1), '');
begin; select tst.u(:'S'); set local role authenticated;
select tst.expect('RE-SQL-04 pedido PENDIENTE en otra hoja activa: NO se libera (mismo bloqueo de siempre)', $q$ select public.reserve_orders('RE-H2', array['RE81002']) $q$, 'PEDIDO_YA_EN_OTRA_HOJA%');
select tst.expect('RE-SQL-05 pedido ENTREGADO: NO se libera', $q$ select public.reserve_orders('RE-H2', array['RE81003']) $q$, 'PEDIDO_YA_EN_OTRA_HOJA%');
select tst.expect('RE-SQL-06 pedido con OTRA parada pendiente en la misma hoja: NO se libera', $q$ select public.reserve_orders('RE-H2', array['RE81005']) $q$, 'PEDIDO_YA_EN_OTRA_HOJA%');
select public.reserve_orders('RE-H4', array['RE81004']);
commit;
select tst.res('RE-SQL-07 primera hoja CANCELADA: el pedido se puede volver a cargar (motivo HOJA_CANCELADA)',
  (select sheet_key from public.order_reservations where order_id = 'RE81004') = 'RE-H4' and exists (select 1 from public.order_reservation_history where order_id = 'RE81004' and reason = 'HOJA_CANCELADA'), '');
-- el mismo pedido NO puede quedar en dos hojas activas: un segundo borrador no lo toma mientras RE-H2 lo tiene
begin; select tst.u(:'O'); set local role authenticated;
select tst.expect('RE-SQL-08 mientras el reintento está en un borrador, otra hoja NO lo puede tomar', $q$ select public.reserve_orders('RE-H5-OP', array['RE81001']) $q$, 'PEDIDO_YA_EN_OTRA_HOJA%');
commit;
begin; select tst.u(:'S'); set local role authenticated;
create temp table r2 as select id from public.publish_route(jsonb_build_object('sheet_key', 'RE-H2', 'carrier_id', 'INTERNO', 'responsable_id', :'G', 'vehicle_id', 'f0000000-0000-0000-0000-000000000001',
  'rules_version', 1, 'routing_rules_version', 1, 'stops', jsonb_build_array(jsonb_build_object('client_name', 'Cliente RE81001', 'address', 'Calle', 'stop_type', 'PEDIDO', 'order_numbers', jsonb_build_array('RE81001'), 'merchandise_amount', 1000, 'task', 'ENTREGA', 'ready', true))));
grant select on r2 to public;
commit;
select tst.res('RE-SQL-09 publicado el reintento, la reserva queda PUBLICADA en la hoja nueva; la anterior conserva su parada NO ENTREGADO',
  (select route_id = (select id from r2) and status = 'PUBLICADA' from public.order_reservations where order_id = 'RE81001')
  and (select outcome from public.route_stops where route_id = (select id from r1) and 'RE81001' = any(order_numbers)) = 'NO_ENTREGADO', '');
begin; select tst.u(:'S'); set local role authenticated;
select tst.expect('RE-SQL-10 ya publicado y pendiente en la hoja nueva: tampoco se puede cargar en una tercera hoja', $q$ select public.reserve_orders('RE-H6', array['RE81001']) $q$, 'PEDIDO_YA_EN_OTRA_HOJA%');
commit;

select tst.res('RE-ACL-01 authenticated can read history, subject to RLS', has_table_privilege('authenticated','public.order_reservation_history','SELECT'), '');
select tst.res('RE-ACL-02 authenticated cannot mutate or truncate history', not has_table_privilege('authenticated','public.order_reservation_history','INSERT,UPDATE,DELETE,TRUNCATE'), '');
select tst.res('RE-ACL-03 anon cannot access history', not has_table_privilege('anon','public.order_reservation_history','SELECT,INSERT,UPDATE,DELETE,TRUNCATE'), '');
select tst.res('PERM-ACL-01 Storage helper executable by authenticated only', has_function_privilege('authenticated','public._auth_receives_internal()','EXECUTE') and not has_function_privilege('anon','public._auth_receives_internal()','EXECUTE'), '');
