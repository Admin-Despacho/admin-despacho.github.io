\set ON_ERROR_STOP on
\set D '00000000-0000-0000-0000-00000000000d'
\set G '00000000-0000-0000-0000-000000000001'
-- Financiación propia en la base
begin; select tst.svc(); set local role service_role;
insert into public.source_imports(id, kind, file_name) values ('aaaaaaaa-0000-0000-0000-000000000001','SALDO_COMPROBANTE','a.xlsx'),('aaaaaaaa-0000-0000-0000-000000000002','SALDO_COMPROBANTE','b.xlsx');
insert into public.financial_document_groups(source_import_id, comp_normalized, client_key, classification, parts_count, pending_count, settled_count, total_pending, resolver_version)
values ('aaaaaaaa-0000-0000-0000-000000000001','NDPX002000007242','12156143','FINANCIACION_PROPIA_VIGENTE',6,6,0,5165598.86,'fin-1'),
       ('aaaaaaaa-0000-0000-0000-000000000002','NDPX002000007242','12156143','FINANCIACION_PROPIA_VIGENTE',6,4,2,3443732.58,'fin-1');
insert into tst.results(name, ok, detail) select 'FP-ON-17 (SQL) Importaciones distintas no se mezclan (un grupo por importación)', count(*) = 2, count(*)::text from public.financial_document_groups where comp_normalized = 'NDPX002000007242';
do $$ begin
  insert into public.financial_document_groups(source_import_id, comp_normalized, client_key, classification, parts_count, total_pending, resolver_version)
  values ('aaaaaaaa-0000-0000-0000-000000000001','NDPX0001','X','POSIBLE_FINANCIACION_REVISAR',2,100,'fin-1');
  insert into tst.results(name, ok, detail) values ('FP-ON-18 (SQL) Una posible financiación a revisar no suma', false, 'sumó');
exception when others then insert into tst.results(name, ok, detail) values ('FP-ON-18 (SQL) Una posible financiación a revisar no suma', sqlerrm like 'FIN_REVISAR_NO_SUMA%', sqlerrm); end $$;
insert into public.routes(id, number, carrier_id, operational_status) values ('99999999-9999-9999-9999-999999999999','03-90','CT-ALR','PUBLICADA');
insert into public.route_financing_snapshots(route_id, route_version, comp, client_name, client_cuit, parts_count, parts, total, classification, resolver_version)
values ('99999999-9999-9999-9999-999999999999',1,'NDP [X] 0020-00007242','MORAN ELISA','12156143',6,'[{"due":"2026-10-15","s":860933.14}]',5165598.86,'FINANCIACION_PROPIA_VIGENTE','fin-1');
do $$ begin
  update public.route_financing_snapshots set total = 1 where route_id = '99999999-9999-9999-9999-999999999999';
  insert into tst.results(name, ok, detail) values ('FP-ON-14 (SQL) Snapshot financiero de la hoja es inmutable', false, 'cambió');
exception when others then insert into tst.results(name, ok, detail) values ('FP-ON-14 (SQL) Snapshot financiero de la hoja es inmutable', sqlerrm like 'SNAPSHOT_INMUTABLE%', sqlerrm); end $$;
commit;
begin; select tst.as_user_iat(:'G', 'authenticated', extract(epoch from now())::bigint + 60); set local role authenticated;
insert into tst.results(name, ok, detail) select 'FP-ON-15 (SQL) Transportista no ve grupos financieros ni snapshots', (select count(*) from public.financial_document_groups) = 0 and (select count(*) from public.route_financing_snapshots) = 0, '';
insert into tst.results(name, ok, detail) select 'ENV-ON-24 (SQL) Transportista no ve confirmaciones de envío', count(*) = 0, '' from public.shipping_amount_confirmations;
do $$ begin
  perform public.confirm_shipping_amount('{"sheet_key":"H1","ship_order":"25610","detected_amount":10000,"confirmed_amount":10000,"fingerprint":"f1"}');
  insert into tst.results(name, ok, detail) values ('ENV-ON-24b (SQL) Sin permiso no se confirma', false, 'confirmó');
exception when others then insert into tst.results(name, ok, detail) values ('ENV-ON-24b (SQL) Sin permiso no se confirma', sqlerrm like 'FORBIDDEN%', sqlerrm); end $$;
commit;
-- Confirmaciones (Despacho)
begin; select tst.as_user_iat(:'D', 'authenticated', extract(epoch from now())::bigint + 60); set local role authenticated;
do $$ begin
  perform public.assert_sheet_shipping_ready('H1', array['25610']);
  insert into tst.results(name, ok, detail) values ('ENV-ON-14 (SQL) Envío pendiente bloquea la publicación', false, 'pasó');
exception when others then insert into tst.results(name, ok, detail) values ('ENV-ON-14 (SQL) Envío pendiente bloquea la publicación', sqlerrm like 'SHIPPING_PENDING%', sqlerrm); end $$;
select public.confirm_shipping_amount('{"sheet_key":"H1","ship_order":"25610","ship_doc":"NDP [X] 0014-00009186","main_order":"25537","detected_amount":10000,"confirmed_amount":10000,"fingerprint":"f1"}');
select public.confirm_shipping_amount('{"sheet_key":"H1","ship_order":"25610","ship_doc":"NDP [X] 0014-00009186","main_order":"25537","detected_amount":10000,"confirmed_amount":10000,"fingerprint":"f1"}');
insert into tst.results(name, ok, detail) select 'ENV-ON-15 (SQL) Confirmación guardada en el servidor (quién y hora del servidor)', status = 'CONFIRMED' and confirmed_by = :'D' and confirmed_at is not null, status from public.shipping_amount_confirmations where sheet_key = 'H1' and status <> 'INVALIDATED';
insert into tst.results(name, ok, detail) select 'ENV-ON-23 (SQL) Doble clic no duplica', count(*) = 1, count(*)::text from public.shipping_amount_confirmations where sheet_key = 'H1';
do $$ begin perform public.assert_sheet_shipping_ready('H1', array['25610']); insert into tst.results(name, ok, detail) values ('ENV-ON-14b (SQL) Confirmado: la publicación puede seguir', true, '');
exception when others then insert into tst.results(name, ok, detail) values ('ENV-ON-14b (SQL) Confirmado: la publicación puede seguir', false, sqlerrm); end $$;
do $$ begin
  perform public.confirm_shipping_amount('{"sheet_key":"H2","ship_order":"777","detected_amount":10000,"confirmed_amount":12000,"fingerprint":"g"}');
  insert into tst.results(name, ok, detail) values ('ENV-ON-12 (SQL) Cambiar importe exige motivo', false, 'sin motivo');
exception when others then insert into tst.results(name, ok, detail) values ('ENV-ON-12 (SQL) Cambiar importe exige motivo', sqlerrm like 'REASON_REQUIRED%', sqlerrm); end $$;
select public.confirm_shipping_amount('{"sheet_key":"H2","ship_order":"777","detected_amount":10000,"confirmed_amount":12000,"fingerprint":"g","reason":"Tarifa nueva"}');
insert into tst.results(name, ok, detail) select 'ENV-ON-11 (SQL) Modificado y confirmado: anterior, nuevo, motivo y auditoría', c.status = 'MODIFIED_CONFIRMED' and c.detected_amount = 10000 and c.confirmed_amount = 12000 and c.reason = 'Tarifa nueva', c.status from public.shipping_amount_confirmations c where sheet_key = 'H2' and status <> 'INVALIDATED';
select public.invalidate_shipping_confirmation('H1', '25610', 'f2-cambio-de-ndp');
insert into tst.results(name, ok, detail) select 'ENV-ON-16 (SQL) Un cambio invalida la confirmación (vuelve a pendiente)', not exists (select 1 from public.shipping_amount_confirmations where sheet_key = 'H1' and status <> 'INVALIDATED'), '';
do $$ begin perform public.assert_sheet_shipping_ready('H1', array['25610']); insert into tst.results(name, ok, detail) values ('ENV-ON-16b (SQL) Invalidada: vuelve a bloquear', false, 'pasó');
exception when others then insert into tst.results(name, ok, detail) values ('ENV-ON-16b (SQL) Invalidada: vuelve a bloquear', sqlerrm like 'SHIPPING_PENDING%', ''); end $$;
select public.confirm_shipping_amount('{"sheet_key":"H3","ship_order":"1","detected_amount":10000,"confirmed_amount":10000,"fingerprint":"h"}');
select public.confirm_shipping_amount('{"sheet_key":"H4","ship_order":"1","detected_amount":10000,"confirmed_amount":10000,"fingerprint":"h"}');
insert into tst.results(name, ok, detail) select 'ENV-ON-18 (SQL) NDP real que coincide: se resuelve sola', public.reconcile_shipping_with_saldo(id, 10000) = 'RESOLVED_BY_SALDO', '' from public.shipping_amount_confirmations where sheet_key = 'H3' and status <> 'INVALIDATED';
insert into tst.results(name, ok, detail) select 'ENV-ON-19 (SQL) NDP real con otro importe: DIFERENCIA · REVISAR (no se pisa)', public.reconcile_shipping_with_saldo(id, 13000) = 'DIFFERENCE_REVIEW' and confirmed_amount = 10000, '' from public.shipping_amount_confirmations where sheet_key = 'H4' and status <> 'INVALIDATED';
commit;
insert into tst.results(name, ok, detail) select 'FP-ON-16 (SQL) Confirmaciones auditadas (confirmado y modificado)', count(*) filter (where action = 'SHIPPING_AMOUNT_CONFIRMED') >= 1 and count(*) filter (where action = 'SHIPPING_AMOUNT_MODIFIED') = 1, count(*)::text from public.audit_log where action like 'SHIPPING_AMOUNT_%';
-- La tarifa de una parada del informe nunca puede venir de un provisorio sin confirmar
begin; select tst.svc(); set local role service_role;
do $$ begin
  insert into public.route_stops(route_id, seq, client_name, zone, shipping_fee, shipping_fee_source) values ('99999999-9999-9999-9999-999999999999', 1, 'X', 'ESTE', 10000, 'PENDING_CONFIRMATION');
  insert into tst.results(name, ok, detail) values ('ENV-ON-25 (SQL) La tarifa del informe no acepta un envío sin confirmar', false, 'aceptó');
exception when others then insert into tst.results(name, ok, detail) values ('ENV-ON-25 (SQL) La tarifa del informe no acepta un envío sin confirmar', sqlerrm like '%check constraint%', sqlerrm); end $$;
commit;
