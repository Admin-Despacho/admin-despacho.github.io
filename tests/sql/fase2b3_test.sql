\set ON_ERROR_STOP on
\set A '00000000-0000-0000-0000-00000000000a'
\set D '00000000-0000-0000-0000-00000000000d'
\set G '00000000-0000-0000-0000-000000000001'
\set C '00000000-0000-0000-0000-000000000003'
create or replace function tst.res(n text, ok boolean, d text default '') returns void language sql as $$ insert into tst.results(name, ok, detail) values (n, ok, d) $$;
grant execute on function tst.res(text, boolean, text) to public;
create or replace function tst.expect(n text, q text, pat text) returns void language plpgsql as $$
begin execute q; perform tst.res(n, false, 'no falló');
exception when others then perform tst.res(n, sqlerrm like pat, sqlerrm); end $$;
grant execute on function tst.expect(text, text, text) to public;
insert into public.client_locations values ('CLI-RADIO', -32.8895, -68.8458, 150);
-- Hoja de Cristian con entrega+cobranza y emails de cliente
begin; select tst.u(:'D'); set local role authenticated;
create temp table t_c as select * from public.publish_route('{"sheet_key":"B3-C","carrier_id":"CT-ALR","responsable_id":"00000000-0000-0000-0000-000000000003","stops":[
 {"client_name":"Cliente Uno","client_key":"CLI-RADIO","zone":"ALREDEDORES","order_numbers":["90001"],"shipping_fee":9000,"ready":true,"task":"AMBAS","expected_amount":50000,"customer_email":"Uno@Cliente.com"},
 {"client_name":"Cliente Dos","zone":"CENTRO","order_numbers":["90002"],"shipping_fee":7000,"ready":true,"customer_email":"dos@cliente.com"},
 {"client_name":"Cliente Tres","zone":"CENTRO","order_numbers":["90003"],"shipping_fee":7000,"ready":true}]}');
grant select on t_c to public;
commit;
create temp table t_s as select (select id from public.route_stops where route_id = (select id from t_c) and seq = 1) s1, (select id from public.route_stops where route_id = (select id from t_c) and seq = 2) s2, (select id from public.route_stops where route_id = (select id from t_c) and seq = 3) s3;
grant select on t_s to public;
select tst.res('COB-00 La tarea, el importe esperado y el email del cliente vienen de la hoja', task = 'AMBAS' and expected_amount = 50000 and customer_email = 'Uno@Cliente.com', task) from public.route_stops where id = (select s1 from t_s);
begin; select tst.u(:'C'); set local role authenticated;
select public.start_route((select id from t_c));
commit;
select tst.res('MAILC-01 Al iniciar: "va en camino" solo a la primera parada (no a toda la ruta)', count(*) = 1 and min(recipient) = 'uno@cliente.com', count(*)::text) from public.customer_email_jobs where route_id = (select id from t_c) and kind = 'ON_THE_WAY';
begin; select tst.u(:'C'); set local role authenticated;
select tst.expect('LOC-02 Llegar sin ubicación ni motivo: rechazado', format('select public.arrive_stop(%L, null, %L)', (select s1 from t_s), 'a0'), 'LOCATION_REQUIRED%');
select tst.expect('LOC-02b Sin ubicación exige motivo', format('select public.arrive_stop(%L, %L, %L)', (select s1 from t_s), '{"missing_reason":" "}', 'a0'), 'LOCATION_REASON_REQUIRED%');
select public.arrive_stop((select s1 from t_s), '{"lat":-32.9100,"lon":-68.8458,"accuracy":20}', 'a1');
select tst.res('LOC-01/03 Llegar: lat/lon, precisión y hora del servidor; fuera del radio → advertencia', arrive_location->>'lat' = '-32.91' and arrive_location ? 'at' and location_warning like 'FUERA DEL RADIO%', location_warning) from public.route_stops where id = (select s1 from t_s);
select tst.expect('EVD-01 ENTREGADO sin receptor ni firma: rechazado', format('select public.set_stop_outcome(%L, %L, null, null, %L, %L)', (select s1 from t_s), 'ENTREGADO', 'e1', '{"location":{"lat":-32.88,"lon":-68.84}}'), 'EVIDENCE_REQUIRED%');
select tst.expect('EVD-02 Cristian: CUIL inválido rechazado', format('select public.set_stop_outcome(%L, %L, null, null, %L, %L)', (select s1 from t_s), 'ENTREGADO', 'e2', '{"evidence":{"receiver_name":"Juan","signature_png_b64":"iVBORw0KGgo=","cuil":"20-123"},"location":{"lat":-32.88,"lon":-68.84}}'), 'CUIL_INVALID%');
select tst.expect('COB-01 Entrega+cobranza exige resultado de la cobranza', format('select public.set_stop_outcome(%L, %L, null, null, %L, %L)', (select s1 from t_s), 'ENTREGADO', 'e3', '{"evidence":{"receiver_name":"Juan","signature_png_b64":"iVBORw0KGgo=","cuil":"20-12345678-6"},"location":{"lat":-32.88,"lon":-68.84}}'), 'COLLECTION_REQUIRED%');
select tst.expect('COB-02 Cobro parcial exige observación', format('select public.set_stop_outcome(%L, %L, null, null, %L, %L)', (select s1 from t_s), 'ENTREGADO', 'e4', '{"evidence":{"receiver_name":"Juan","signature_png_b64":"iVBORw0KGgo=","cuil":"20123456786"},"location":{"lat":-32.88,"lon":-68.84},"collection":{"status":"COBRO_PARCIAL","amount":20000,"mode":"EFECTIVO"}}'), 'COLLECTION_NOTE_REQUIRED%');
select tst.expect('COB-02b No cobrado exige motivo', format('select public.set_stop_outcome(%L, %L, null, null, %L, %L)', (select s1 from t_s), 'ENTREGADO', 'e5', '{"evidence":{"receiver_name":"Juan","signature_png_b64":"iVBORw0KGgo=","cuil":"20123456786"},"location":{"lat":-32.88,"lon":-68.84},"collection":{"status":"NO_COBRADO"}}'), 'COLLECTION_NOTE_REQUIRED%');
insert into storage.objects(bucket_id, name, metadata) values ('identity-docs', '20123456786/0f8fad5b-d9cb-469f-a165-70867728950e.jpg', '{"mimetype":"image/jpeg","size":120000}');
select public.set_stop_outcome((select s1 from t_s), 'ENTREGADO', null, null, 'e6', '{"evidence":{"receiver_name":"Juan Pérez","signature_png_b64":"iVBORw0KGgo=","cuil":"20-12345678-6","dni_storage_path":"20123456786/0f8fad5b-d9cb-469f-a165-70867728950e.jpg"},"location":{"lat":-32.8896,"lon":-68.8459,"accuracy":8},"collection":{"status":"COBRO_PARCIAL","amount":20000,"mode":"TRANSFERENCIA","note":"Paga el resto el lunes"}}');
select tst.res('COB-03 Cobranza parcial: cobrado, modo y observación guardados; esperado sin cambios', collection_status = 'COBRO_PARCIAL' and collected_amount = 20000 and payment_mode = 'TRANSFERENCIA' and expected_amount = 50000, collection_status) from public.route_stops where id = (select s1 from t_s);
select tst.res('EVD-02b CUIL nuevo con foto: DNI registrado (el chofer solo ve que existe)', public.cuil_has_dni('20123456786') and public.cuil_has_dni('20-12345678-6'), '');
select tst.res('EVD-03 El chofer no ve firmas ni DNI', (select count(*) from public.stop_evidence) = 0 and (select count(*) from public.customer_identity_docs) = 0, '');
select tst.expect('COB-04 El chofer no cambia el importe esperado', format('select public.set_expected_amount(%L, 1, %L)', (select s1 from t_s), 'x'), 'FORBIDDEN%');
commit;
begin; select tst.u(:'A'); set local role authenticated;
select public.set_expected_amount((select s1 from t_s), 45000, 'Ajuste comercial');
commit;
select tst.res('COB-04b Con permiso se ajusta el importe esperado (auditado)', expected_amount = 45000 and exists (select 1 from public.audit_log where action = 'EXPECTED_AMOUNT_CHANGED'), '') from public.route_stops where id = (select s1 from t_s);
select tst.res('MAILC-02 Al resolver: confirmación ENTREGADO y "va en camino" a la nueva parada actual', (select count(*) from public.customer_email_jobs where stop_id = (select s1 from t_s) and kind = 'DELIVERED') = 1
  and (select count(*) from public.customer_email_jobs where stop_id = (select s2 from t_s) and kind = 'ON_THE_WAY') = 1, '');
select tst.res('LOC-03b Dentro del radio: sin advertencia nueva y la ubicación final queda guardada', finish_location->>'outside_m' is null and finish_location ? 'lat', coalesce(location_warning, '')) from public.route_stops where id = (select s1 from t_s);
begin; select tst.u(:'C'); set local role authenticated;
select public.set_stop_outcome((select s2 from t_s), 'ENTREGA_PARCIAL', 'Faltó 1 caja', null, 'e7', '{"evidence":{"receiver_name":"Ana","signature_png_b64":"iVBORw0KGgo=","cuil":"27-11111111-4"},"location":{"missing_reason":"El celular no tomó señal"}}');
select public.set_stop_outcome((select s3 from t_s), 'NO_ENTREGADO', null, 'Cerrado', 'e8', '{"location":{"missing_reason":"Sin GPS"}}');
select public.set_stop_outcome((select s3 from t_s), 'NO_ENTREGADO', null, 'Cerrado', 'e8', '{"location":{"missing_reason":"Sin GPS"}}');
select public.finalize_route((select id from t_c));
commit;
select tst.res('MAILC-03 Parcial notifica como PARCIAL; sin email no bloquea; reintentos no duplican', (select count(*) from public.customer_email_jobs where stop_id = (select s2 from t_s) and kind = 'PARTIAL') = 1
  and (select count(*) from public.customer_email_jobs where stop_id = (select s3 from t_s)) = 0 and (select operational_status from public.routes where id = (select id from t_c)) = 'COMPLETADA', '');
select tst.res('LOC-02c Sin ubicación: queda el motivo, nunca una ubicación inventada', finish_location->>'missing_reason' = 'El celular no tomó señal' and not (finish_location ? 'lat'), finish_location::text) from public.route_stops where id = (select s2 from t_s);
select tst.res('EVD-04 Firma con hash; CUIL solo en la evidencia privada (no en la parada ni en la hoja)', e.signature_sha256 is not null and e.receiver_cuil = '20123456786'
  and not exists (select 1 from information_schema.columns where table_name in ('route_stops','routes','customer_email_jobs','commercial_reports') and column_name ~* 'cuil|dni')
  and (select sheet_snapshot::text from public.routes where id = (select id from t_c)) !~* 'cuil|dni', '') from public.stop_evidence e where stop_id = (select s1 from t_s);
begin; select tst.u(:'D'); set local role authenticated;
select tst.res('EVD-03b Despacho (signatures.view) ve firmas pero no DNI', (select count(*) from public.stop_evidence) >= 2 and (select count(*) from public.customer_identity_docs) = 0, '');
commit;
begin; select tst.u(:'A'); set local role authenticated;
select tst.res('EVD-03c Admin autorizado ve el DNI', count(*) >= 1, count(*)::text) from public.customer_identity_docs;
commit;
-- ===== Vehículos y km =====
begin; select tst.u(:'A'); set local role authenticated;
create temp table t_v as select * from public.upsert_vehicle('{"name":"Kangoo","plate":"ab123cd","current_km":50000,"last_service_km":41000,"brand":"Renault"}');
grant select on t_v to public;
commit;
select tst.res('VEH-03 Service: alerta cuando pasan 10.000 km (intervalo configurable)', service_due = false and km_since_service = 9000, km_since_service::text) from public.vehicle_service_status where id = (select id from t_v);
begin; select tst.u(:'D'); set local role authenticated;
create temp table t_i as select * from public.publish_route(jsonb_build_object('sheet_key','B3-I','carrier_id','INTERNO','responsable_id','00000000-0000-0000-0000-000000000001','vehicle_id',(select id from t_v),'stops',jsonb_build_array(jsonb_build_object('client_name','Banco','order_numbers',jsonb_build_array('91001'),'ready',true))));
grant select on t_i to public;
commit;
select tst.res('VEH-01 Vehículo asignado a la ruta interna con km inicial', vehicle_id = (select id from t_v) and km_start = 50000, '') from public.routes where id = (select id from t_i);
begin; select tst.u(:'G'); set local role authenticated;
select public.start_route((select id from t_i));
select public.set_stop_outcome(id, 'ENTREGADO', null, null, 'v1', tst.ev()) from public.route_stops where route_id = (select id from t_i);
select tst.expect('VEH-02 Finalizar ruta interna sin km final: rechazado', format('select public.finalize_route(%L)', (select id from t_i)), 'KM_REQUIRED%');
select tst.expect('VEH-02b El kilometraje no puede bajar', format('select public.finalize_route(%L, 49990)', (select id from t_i)), 'KM_LOWER%');
select public.finalize_route((select id from t_i), 51200);
select tst.expect('VEH-04 El chofer no corrige el km del vehículo', format('select public.correct_vehicle_km(%L, 1, %L)', (select id from t_v), 'x'), 'FORBIDDEN%');
commit;
select tst.res('VEH-02c Km final guardado y vehículo actualizado; service vencido → alerta', r.km_end = 51200 and v.current_km = 51200 and v.service_due, v.km_since_service::text) from public.routes r, public.vehicle_service_status v where r.id = (select id from t_i) and v.id = (select id from t_v);
begin; select tst.u(:'A'); set local role authenticated;
select tst.expect('VEH-04b Corrección Admin exige motivo', format('select public.correct_vehicle_km(%L, 51000, %L)', (select id from t_v), ' '), 'REASON_REQUIRED%');
select public.correct_vehicle_km((select id from t_v), 51100, 'Error de carga');
select public.register_vehicle_service((select id from t_v), 51100, '2026-10-10');
commit;
select tst.res('VEH-05 Corrección auditada y REGISTRAR SERVICE REALIZADO quita la alerta', v.current_km = 51100 and not v.service_due and exists (select 1 from public.audit_log where action = 'VEHICLE_KM_CORRECTED') and exists (select 1 from public.audit_log where action = 'VEHICLE_SERVICE_REGISTERED'), '') from public.vehicle_service_status v where id = (select id from t_v);
-- ===== Devolver hoja =====
begin; select tst.u(:'C'); set local role authenticated;
select tst.expect('RET-01 Devolver hoja exige motivo', format('select public.request_route_return(%L, %L)', (select id from t_c), ' '), 'REASON_REQUIRED%');
select public.request_route_return((select id from t_c), 'Me equivoqué en la parada 2');
select public.request_route_return((select id from t_c), 'Me equivoqué en la parada 2');
commit;
select tst.res('RET-02 Es una solicitud (la hoja no cambia) y no se duplica', (select count(*) from public.route_return_requests where route_id = (select id from t_c)) = 1 and (select operational_status from public.routes where id = (select id from t_c)) = 'COMPLETADA', '');
update public.routes set completed_at = now() - interval '4 days' where id = (select id from t_i);
begin; select tst.u(:'G'); set local role authenticated;
select tst.expect('RET-03 Más de 2 días calendario: vencido', format('select public.request_route_return(%L, %L)', (select id from t_i), 'tarde'), 'RETURN_EXPIRED%');
commit;
begin; select tst.u(:'A'); set local role authenticated;
select public.resolve_route_return((select id from public.route_return_requests where route_id = (select id from t_c)), 'RESOLVED', 'Se corrige con versión 2');
commit;
select tst.res('RET-04 Administración resuelve la solicitud (auditada)', status = 'RESOLVED' and resolved_by = :'A', status) from public.route_return_requests where route_id = (select id from t_c);
-- ===== Cancelar hoja activa: libera reservas, correlativo no se reutiliza =====
begin; select tst.u(:'D'); set local role authenticated;
create temp table t_x as select * from public.publish_route('{"sheet_key":"B3-X","carrier_id":"UCO","responsable_id":"00000000-0000-0000-0000-000000000005","stops":[{"client_name":"Z","order_numbers":["92001"],"ready":true}]}');
grant select on t_x to public;
select tst.expect('CAN-00 Despacho no cancela (requiere Administración)', format('select public.cancel_route(%L, %L)', (select id from t_x), 'x'), 'FORBIDDEN%');
commit;
begin; select tst.u(:'A'); set local role authenticated;
select public.cancel_route((select id from t_x), 'Cliente suspendió el pedido');
commit;
begin; select tst.u(:'D'); set local role authenticated;
create temp table t_x2 as select * from public.publish_route('{"sheet_key":"B3-X2","carrier_id":"UCO","responsable_id":"00000000-0000-0000-0000-000000000005","stops":[{"client_name":"Z","order_numbers":["92001"],"ready":true}]}');
grant select on t_x2 to public;
commit;
select tst.res('CAN-01 Cancelar libera los pedidos y el correlativo nunca se reutiliza', (select operational_status from public.routes where id = (select id from t_x)) = 'CANCELADA'
  and right((select number from t_x2), 6)::int = right((select number from t_x), 6)::int + 1 and (select route_id from public.order_reservations where order_id = '92001') = (select id from t_x2), (select number from t_x) || ' → ' || (select number from t_x2));
-- ===== Aprobar avisa al chofer =====
select tst.res('APRV-01 Al aprobar se avisa "HOJA APROBADA" al chofer', exists (select 1 from public.notifications where type = 'INTERNAL_ROUTE_APPROVED' and user_id = :'G'), '');
