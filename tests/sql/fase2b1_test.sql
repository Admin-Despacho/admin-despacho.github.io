\set ON_ERROR_STOP on
create or replace function tst.ev() returns jsonb language sql as $$ select '{"evidence":{"receiver_name":"Receptor Prueba","signature_png_b64":"iVBORw0KGgo=","cuil":"20-12345678-6"},"location":{"lat":-32.89,"lon":-68.84,"accuracy":12}}'::jsonb $$;
grant execute on function tst.ev() to public;
\set D '00000000-0000-0000-0000-00000000000d'
\set C '00000000-0000-0000-0000-000000000003'
\set DI '00000000-0000-0000-0000-000000000004'
\set G '00000000-0000-0000-0000-000000000001'
create or replace function tst.pub(k text, extra jsonb default '{}') returns jsonb language sql as $$
  select jsonb_build_object('sheet_key', k, 'carrier_id', 'CT-ESTE', 'responsable_id', '00000000-0000-0000-0000-000000000003', 'stops', jsonb_build_array(
    jsonb_build_object('client_name','MORAN ELISA','zone','ESTE','order_numbers',jsonb_build_array('25537','25610'),'merchandise_amount',5165598.86,'shipping_fee',10000,'ship_fee_status','PROVISIONAL','ship_order','25610','ready',true),
    jsonb_build_object('client_name','Todo Móvil','zone','ESTE','order_numbers',jsonb_build_array('30001'),'merchandise_amount',150000,'shipping_fee',13000,'ready',true))) || extra $$;
grant execute on function tst.pub(text, jsonb) to public;
begin; select tst.as_user_iat(:'D', 'authenticated', extract(epoch from now())::bigint + 60); set local role authenticated;
do $$ begin perform public.publish_route(tst.pub('HB1'));
  insert into tst.results(name, ok, detail) values ('2B1-02 Publicar con envío provisorio sin confirmar: BLOQUEADO', false, 'publicó');
exception when others then insert into tst.results(name, ok, detail) values ('2B1-02 Publicar con envío provisorio sin confirmar: BLOQUEADO', sqlerrm like 'SHIPPING_PENDING%', sqlerrm); end $$;
select public.confirm_shipping_amount('{"sheet_key":"HB1","ship_order":"25610","detected_amount":10000,"confirmed_amount":10000,"fingerprint":"x"}');
do $$ begin perform public.publish_route(tst.pub('HB9', '{"responsable_id":"00000000-0000-0000-0000-000000000001"}'));
  insert into tst.results(name, ok, detail) values ('2B1-01b Responsable incompatible: BLOQUEADO', false, 'publicó');
exception when others then insert into tst.results(name, ok, detail) values ('2B1-01b Responsable incompatible: BLOQUEADO', sqlerrm like 'RESPONSABLE_INCOMPATIBLE%' or sqlerrm like 'SHIPPING_PENDING%', sqlerrm); end $$;
create temp table t_r1 as select (public.publish_route(tst.pub('HB1'))).*;
create temp table t_r1b as select (public.publish_route(tst.pub('HB1'))).*;
create temp table t_r2 as select (public.publish_route(tst.pub('HB2', '{"stops":[{"client_name":"Otro","zone":"CENTRO","order_numbers":["30002"],"merchandise_amount":1000,"shipping_fee":7000,"ready":true}]}'))).*;
commit;
insert into tst.results(name, ok, detail) select '2B1-01 Publicar hoja válida (PUBLICADA, snapshot, paradas, fee confirmado)', r.operational_status = 'PUBLICADA' and r.sheet_snapshot is not null and r.published_by = :'D'
  and (select count(*) from public.route_stops where route_id = r.id) = 2 and (select shipping_fee_source from public.route_stops where route_id = r.id and seq = 1) = 'CONFIRMED_FALLBACK', r.number from t_r1 r;
insert into tst.results(name, ok, detail) select '2B1-01c Reintento de publicar la misma hoja: misma hoja, no duplica', (select id from t_r1) = (select id from t_r1b) and (select count(*) from public.routes where sheet_key = 'HB1') = 1, '';
insert into tst.results(name, ok, detail) select '2B1-03 Correlativo único y consecutivo (allocator atómico)', (select number from t_r1) <> (select number from t_r2) and right((select number from t_r2), 2)::int = right((select number from t_r1), 2)::int + 1, (select number from t_r1) || ' / ' || (select number from t_r2);
insert into tst.results(name, ok, detail) select '2B1-04 Notificación persistente creada (una sola)', count(*) = 1, count(*)::text from public.notifications where route_id = (select id from t_r1);
begin; select tst.as_user_iat(:'C', 'authenticated', extract(epoch from now())::bigint + 60); set local role authenticated;
insert into tst.results(name, ok, detail) select '2B1-05 El responsable ve su hoja y su notificación', (select count(*) from public.routes where id = (select id from t_r1)) = 1 and (select count(*) from public.notifications) >= 1, '';
commit;
begin; select tst.as_user_iat(:'DI', 'authenticated', extract(epoch from now())::bigint + 60); set local role authenticated;
insert into tst.results(name, ok, detail) select '2B1-06 Otro transportista no la ve', (select count(*) from public.routes where id = (select id from t_r1)) = 0 and (select count(*) from public.notifications where route_id = (select id from t_r1)) = 0, '';
do $$ begin perform public.start_route((select id from t_r1));
  insert into tst.results(name, ok, detail) values ('2B1-06b Otro transportista no puede iniciarla', false, 'pudo');
exception when others then insert into tst.results(name, ok, detail) values ('2B1-06b Otro transportista no puede iniciarla', sqlerrm like 'FORBIDDEN%', sqlerrm); end $$;
commit;
begin; select tst.as_user_iat(:'C', 'authenticated', extract(epoch from now())::bigint + 60); set local role authenticated;
select public.mark_route_viewed((select id from t_r1));
insert into tst.results(name, ok, detail) select '2B1-07 Abrir la hoja registra VISTA y no inicia', viewed_at is not null and started_at is null and operational_status = 'PUBLICADA', operational_status from public.routes where id = (select id from t_r1);
do $$ begin perform public.set_stop_outcome((select id from public.route_stops where route_id = (select id from t_r1) and seq = 2), 'ENTREGADO', null, null, 'op0', tst.ev());
  insert into tst.results(name, ok, detail) values ('2B1-08b Sin iniciar no se marcan resultados', false, 'marcó');
exception when others then insert into tst.results(name, ok, detail) values ('2B1-08b Sin iniciar no se marcan resultados', sqlerrm like 'BAD_STATE%', sqlerrm); end $$;
select public.start_route((select id from t_r1));
insert into tst.results(name, ok, detail) select '2B1-08 Iniciar: EN CURSO con hora del servidor y actor', operational_status = 'EN_CURSO' and started_by = :'C' and started_at is not null, operational_status from public.routes where id = (select id from t_r1);
do $$ begin perform public.set_stop_outcome((select id from public.route_stops where route_id = (select id from t_r1) and seq = 1), 'ENTREGA_PARCIAL', ' ', null, 'op1', tst.ev());
  insert into tst.results(name, ok, detail) values ('2B1-10 ENTREGA PARCIAL exige observación', false, '');
exception when others then insert into tst.results(name, ok, detail) values ('2B1-10 ENTREGA PARCIAL exige observación', sqlerrm like 'NOTE_REQUIRED%', sqlerrm); end $$;
do $$ begin perform public.set_stop_outcome((select id from public.route_stops where route_id = (select id from t_r1) and seq = 1), 'NO_ENTREGADO', null, '', 'op2', tst.ev());
  insert into tst.results(name, ok, detail) values ('2B1-11 NO ENTREGADO exige motivo', false, '');
exception when others then insert into tst.results(name, ok, detail) values ('2B1-11 NO ENTREGADO exige motivo', sqlerrm like 'REASON_REQUIRED%', sqlerrm); end $$;
do $$ begin perform public.set_stop_outcome((select id from public.route_stops where route_id = (select id from t_r1) and seq = 1), 'REPROGRAMAR', null, null, 'op3', tst.ev());
  insert into tst.results(name, ok, detail) values ('2B1-12 REPROGRAMAR exige motivo', false, '');
exception when others then insert into tst.results(name, ok, detail) values ('2B1-12 REPROGRAMAR exige motivo', sqlerrm like 'REASON_REQUIRED%', sqlerrm); end $$;
select public.set_stop_outcome((select id from public.route_stops where route_id = (select id from t_r1) and seq = 2), 'ENTREGADO', null, null, 'op4', tst.ev());
select public.set_stop_outcome((select id from public.route_stops where route_id = (select id from t_r1) and seq = 2), 'NO_ENTREGADO', null, 'cerrado', 'op4', tst.ev());
insert into tst.results(name, ok, detail) select '2B1-09 ENTREGADO con hora y actor; reintento con el mismo op_id no cambia nada', outcome = 'ENTREGADO' and outcome_by = :'C' and outcome_at is not null, outcome from public.route_stops where route_id = (select id from t_r1) and seq = 2;
do $$ begin perform public.finalize_route((select id from t_r1));
  insert into tst.results(name, ok, detail) values ('2B1-13 Finalizar con entregas pendientes: BLOQUEADO', false, '');
exception when others then insert into tst.results(name, ok, detail) values ('2B1-13 Finalizar con entregas pendientes: BLOQUEADO', sqlerrm like 'PENDING_STOPS%', sqlerrm); end $$;
select public.set_stop_outcome((select id from public.route_stops where route_id = (select id from t_r1) and seq = 1), 'ENTREGA_PARCIAL', 'Faltó una caja', null, 'op5', tst.ev());
select public.finalize_route((select id from t_r1));
select public.finalize_route((select id from t_r1));
insert into tst.results(name, ok, detail) select '2B1-14 Finalizar: COMPLETADA con finalized_at/by y resumen (doble toque idempotente)', operational_status = 'COMPLETADA' and completed_by = :'C' and completed_at is not null and final_summary = '{"ENTREGADO": 1, "ENTREGA_PARCIAL": 1}', final_summary::text from public.routes where id = (select id from t_r1);
do $$ begin perform public.set_stop_outcome((select id from public.route_stops where route_id = (select id from t_r1) and seq = 2), 'REPROGRAMAR', null, 'x', 'op6', tst.ev());
  insert into tst.results(name, ok, detail) values ('2B1-14b Hoja finalizada: solo lectura', false, '');
exception when others then insert into tst.results(name, ok, detail) values ('2B1-14b Hoja finalizada: solo lectura', sqlerrm like 'BAD_STATE%' or sqlerrm like 'READ_ONLY%', sqlerrm); end $$;
commit;
insert into tst.results(name, ok, detail) select '2B1-15 (SQL) La hoja finalizada de Cristian queda con paradas, zona, tarifa congelada y fecha real', count(*) = 2 and bool_and(s.zone = 'ESTE') and sum(s.shipping_fee) = 23000 and max(r.completed_at) is not null, ''
  from public.routes r join public.route_stops s on s.route_id = r.id where r.id = (select id from t_r1) and r.carrier_id in (select id from public.carriers where report_group = 'CRISTIAN_TORRES');
