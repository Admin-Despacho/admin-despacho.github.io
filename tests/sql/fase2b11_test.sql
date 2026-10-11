\set ON_ERROR_STOP on
\set D '00000000-0000-0000-0000-00000000000d'
\set A '00000000-0000-0000-0000-00000000000a'
-- ===== Correlativo =====
begin; select tst.svc(); set local role service_role;
create temp table t_n as select public.next_route_number_for('UCO') a, public.next_route_number_for('UCO') b, public.next_route_number_for('CT-ESTE') e, public.next_route_number_for('CT-ALR') l, public.next_route_number_for('INTERNO') i;
commit;
insert into tst.results(name, ok, detail) select 'C-01 Correlativos consecutivos del mismo transportista (CODIGO-SECUENCIA)', a ~ '^02-[0-9]{6}$' and right(b, 6)::int = right(a, 6)::int + 1, a || ' → ' || b from t_n;
insert into tst.results(name, ok, detail) select 'C-02 CT Este y CT Alrededores comparten la secuencia 01', e like '01-%' and l like '01-%' and right(l, 6)::int = right(e, 6)::int + 1, e || ' → ' || l from t_n;
insert into tst.results(name, ok, detail) select 'C-03 UCO usa otra secuencia (02) e Interno la 03', a like '02-%' and i like '03-%', a || ' / ' || i from t_n;
insert into tst.results(name, ok, detail) select 'C-04 Cambio de fecha no reinicia (no depende del día)', not exists (select 1 from pg_proc where proname = 'next_route_number_for' and pg_get_functiondef(oid) ~* 'current_date|now\(\)'), 'sin fecha en el allocator';
-- 2B1: la hoja publicada usa el nuevo correlativo
insert into tst.results(name, ok, detail) select 'C-05 publish_route usa el correlativo por transportista', count(*) >= 2 and bool_and(number ~ '^01-[0-9]{6}$'), string_agg(number, ', ') from public.routes where sheet_key like 'HB%';
-- ===== Reservas =====
begin; select tst.as_user_iat(:'D', 'authenticated', extract(epoch from now())::bigint + 60); set local role authenticated;
select public.reserve_orders('S-A', array['40001','40002']);
select public.reserve_orders('S-A', array['40001','40002']);
insert into tst.results(name, ok, detail) select 'R-01 Reintento de reservar la misma hoja no duplica', count(*) = 2, count(*)::text from public.order_reservations where sheet_key = 'S-A';
do $$ begin perform public.reserve_orders('S-B', array['40003','40002']);
  insert into tst.results(name, ok, detail) values ('R-02 Dos hojas de la misma sesión: el pedido no se duplica', false, 'reservó');
exception when others then insert into tst.results(name, ok, detail) values ('R-02 Dos hojas de la misma sesión: el pedido no se duplica', sqlerrm like 'PEDIDO_YA_EN_OTRA_HOJA: 40002 (otra hoja borrador de Depósito)%', sqlerrm); end $$;
insert into tst.results(name, ok, detail) select 'R-02b Al fallar no queda reservado ningún pedido de esa operación', not exists (select 1 from public.order_reservations where sheet_key = 'S-B'), '';
commit;
begin; select tst.as_user_iat(:'A', 'authenticated', extract(epoch from now())::bigint + 60); set local role authenticated;
do $$ begin perform public.reserve_orders('S-ADMIN', array['40001']);
  insert into tst.results(name, ok, detail) values ('R-03 Otro usuario/sesión no puede usar el pedido', false, 'reservó');
exception when others then insert into tst.results(name, ok, detail) values ('R-03 Otro usuario/sesión no puede usar el pedido', sqlerrm like 'PEDIDO_YA_EN_OTRA_HOJA%', sqlerrm); end $$;
commit;
-- publicar conserva la reserva (y devuelve el correlativo en el conflicto)
begin; select tst.as_user_iat(:'D', 'authenticated', extract(epoch from now())::bigint + 60); set local role authenticated;
create temp table t_pub as select (public.publish_route('{"sheet_key":"S-A","carrier_id":"CT-ESTE","responsable_id":"00000000-0000-0000-0000-000000000003","stops":[{"client_name":"X","zone":"ESTE","order_numbers":["40001","40002"],"merchandise_amount":1,"shipping_fee":13000,"ready":true}]}')).*;
do $$ begin perform public.release_orders('S-A', null); exception when others then null; end $$;
commit;
insert into tst.results(name, ok, detail) select 'R-04 Publicar conserva la reserva (PUBLICADA, con la hoja) y liberar no la suelta', count(*) = 2 and bool_and(status = 'PUBLICADA' and route_id = (select id from t_pub)), (select number from t_pub) from public.order_reservations where sheet_key = 'S-A';
begin; select tst.as_user_iat(:'A', 'authenticated', extract(epoch from now())::bigint + 60); set local role authenticated;
do $$ begin perform public.reserve_orders('S-OTRA', array['40002']);
  insert into tst.results(name, ok, detail) values ('R-05 Pedido de hoja publicada: rechazo con el correlativo', false, 'reservó');
exception when others then insert into tst.results(name, ok, detail) values ('R-05 Pedido de hoja publicada: rechazo con el correlativo', sqlerrm ~ 'PEDIDO_YA_EN_OTRA_HOJA: 40002 \(hoja 01-[0-9]{6}\)', sqlerrm); end $$;
do $$ begin perform public.publish_route('{"sheet_key":"S-OTRA","carrier_id":"CT-ESTE","responsable_id":"00000000-0000-0000-0000-000000000003","stops":[{"client_name":"Y","zone":"ESTE","order_numbers":["40002"],"merchandise_amount":1,"shipping_fee":13000,"ready":true}]}');
  insert into tst.results(name, ok, detail) values ('R-06 publish_route también rechaza un pedido ya publicado', false, 'publicó');
exception when others then insert into tst.results(name, ok, detail) values ('R-06 publish_route también rechaza un pedido ya publicado', sqlerrm like 'PEDIDO_YA_EN_OTRA_HOJA%', sqlerrm); end $$;
commit;
-- liberar borrador
begin; select tst.as_user_iat(:'D', 'authenticated', extract(epoch from now())::bigint + 60); set local role authenticated;
select public.reserve_orders('S-DEL', array['40010']); select public.release_orders('S-DEL', array['40010']);
select public.reserve_orders('S-OTRA2', array['40010']);
insert into tst.results(name, ok, detail) select 'R-07 Quitar el pedido de un borrador lo libera para otra hoja', sheet_key = 'S-OTRA2', sheet_key from public.order_reservations where order_id = '40010';
commit;
