-- Pruebas Fase 2A (informe comercial): RLS, costo con vigencias, snapshot inmutable, idempotencia de emails.
\set ON_ERROR_STOP on
\set A '00000000-0000-0000-0000-00000000000a'
\set D '00000000-0000-0000-0000-00000000000d'
\set G '00000000-0000-0000-0000-000000000001'
\set C '00000000-0000-0000-0000-000000000003'

-- Datos (como servidor)
begin; select tst.svc(); set local role service_role;
insert into public.routes(id, number, carrier_id, responsable_id, operational_status, completed_at) values
 ('77777777-7777-7777-7777-777777777777','CTE-0100','CT-ESTE',:'C','COMPLETADA','2026-10-08 20:00+00');
insert into public.route_stops(route_id, seq, client_name, zone, shipping_fee, merchandise_amount, outcome) values
 ('77777777-7777-7777-7777-777777777777', 1, 'Todo Móvil', 'ESTE', 13000, 150000, 'ENTREGADO'),
 ('77777777-7777-7777-7777-777777777777', 2, 'Celular Shop', 'ESTE', 13000, 90000, 'ENTREGA_PARCIAL');
insert into public.commercial_reports(id, report_type, period_start, period_end, snapshot, pdf_status) values
 ('88888888-8888-8888-8888-888888888888','WEEKLY','2026-10-05','2026-10-10','{"coverage":{"cost":361290.32}}','OK');
insert into public.report_emails(report_id, recipient, idempotency_key, status) values
 ('88888888-8888-8888-8888-888888888888','admin@ok.test','WEEKLY|2026-10-05|2026-10-10|admin@ok.test|v1','SENT');
commit;

-- REPORT-MAIL-25 RLS
begin; select tst.as_user_iat(:'G', 'authenticated', extract(epoch from now())::bigint + 60); set local role authenticated;
insert into tst.results(name, ok, detail) select 'R25a Transportista interno no ve informes, costos ni emails',
  (select count(*) from public.commercial_reports) = 0 and (select count(*) from public.transport_cost_settings) = 0 and (select count(*) from public.report_emails) = 0, '';
commit;
begin; select tst.as_user_iat(:'C', 'authenticated', extract(epoch from now())::bigint + 60); set local role authenticated;
insert into tst.results(name, ok, detail) select 'R25b Cristian no ve el informe comercial ni el costo (salvo permiso explícito)',
  (select count(*) from public.commercial_reports) = 0 and (select count(*) from public.transport_cost_settings) = 0, '';
insert into tst.results(name, ok, detail) select 'R25c Cristian sí ve las paradas de SU hoja (operación)', count(*) = 2, count(*)::text from public.route_stops where route_id = '77777777-7777-7777-7777-777777777777';
commit;
begin; select tst.as_user_iat(:'D', 'authenticated', extract(epoch from now())::bigint + 60); set local role authenticated;
insert into tst.results(name, ok, detail) select 'R25d Despacho sin permiso comercial no ve informes ni costos',
  (select count(*) from public.commercial_reports) = 0 and (select count(*) from public.transport_cost_settings) = 0, '';
do $$ begin
  perform public.set_transport_cost('CRISTIAN_TORRES', 999, '2026-11-01', null);
  insert into tst.results(name, ok, detail) values ('R25e Sin permiso no se cambia el costo', false, 'cambió');
exception when others then insert into tst.results(name, ok, detail) values ('R25e Sin permiso no se cambia el costo', sqlerrm like 'FORBIDDEN%', sqlerrm); end $$;
commit;
begin; select tst.as_user_iat(:'A', 'authenticated', extract(epoch from now())::bigint + 60); set local role authenticated;
insert into tst.results(name, ok, detail) select 'R25f Admin (con permiso) ve informes, costos y emails',
  (select count(*) from public.commercial_reports) = 1 and (select count(*) from public.transport_cost_settings) >= 1 and (select count(*) from public.report_emails) = 1, '';
do $$ begin
  insert into public.commercial_reports(report_type, period_start, period_end, snapshot) values ('MANUAL','2026-10-01','2026-10-02','{}');
  insert into tst.results(name, ok, detail) values ('R25g Nadie escribe informes desde la app (solo el servidor)', false, 'insertó');
exception when others then insert into tst.results(name, ok, detail) values ('R25g Nadie escribe informes desde la app (solo el servidor)', sqlerrm like '%permission denied%', sqlerrm); end $$;
commit;
begin; set local role anon;
do $$ begin perform * from public.commercial_reports; insert into tst.results(name, ok, detail) values ('R25h Sin sesión no se leen informes', false, 'leyó');
exception when others then insert into tst.results(name, ok, detail) values ('R25h Sin sesión no se leen informes', true, sqlerrm); end $$;
commit;

-- Costo con vigencia histórica (el pasado no se reescribe)
begin; select tst.svc(); set local role service_role;
select public.set_transport_cost('CRISTIAN_TORRES', 2000000, '2026-11-01', null);
insert into tst.results(name, ok, detail) select 'R15b Nueva vigencia cierra la anterior y conserva el histórico',
  (select valid_to from public.transport_cost_settings where carrier_group = 'CRISTIAN_TORRES' and valid_from = '2026-01-01') = '2026-10-31'
  and (select monthly_cost from public.transport_cost_settings where carrier_group = 'CRISTIAN_TORRES' and valid_from = '2026-11-01') = 2000000, '';
-- REPORT-MAIL-22/23: el snapshot guardado no se recalcula
do $$ begin
  update public.commercial_reports set snapshot = '{"coverage":{"cost":400000}}' where id = '88888888-8888-8888-8888-888888888888';
  insert into tst.results(name, ok, detail) values ('R22 El snapshot del histórico es inmutable (aunque cambie el costo)', false, 'se modificó');
exception when others then insert into tst.results(name, ok, detail) values ('R22 El snapshot del histórico es inmutable (aunque cambie el costo)', sqlerrm like 'SNAPSHOT_INMUTABLE%', sqlerrm); end $$;
update public.commercial_reports set pdf_status = 'OK', pdf_path = 'x.pdf' where id = '88888888-8888-8888-8888-888888888888';
insert into tst.results(name, ok, detail) select 'R22b Se puede actualizar el estado del PDF sin tocar el snapshot', (snapshot->'coverage'->>'cost')::numeric = 361290.32, snapshot::text from public.commercial_reports where id = '88888888-8888-8888-8888-888888888888';
-- REPORT-MAIL-21: idempotencia en la base
do $$ begin
  insert into public.report_emails(report_id, recipient, idempotency_key) values ('88888888-8888-8888-8888-888888888888','admin@ok.test','WEEKLY|2026-10-05|2026-10-10|admin@ok.test|v1');
  insert into tst.results(name, ok, detail) values ('R21b La base rechaza un segundo email con la misma clave', false, 'duplicó');
exception when others then insert into tst.results(name, ok, detail) values ('R21b La base rechaza un segundo email con la misma clave', sqlerrm like '%duplicate key%', sqlerrm); end $$;
do $$ begin
  update public.route_stops set outcome = 'OTRO' where route_id = '77777777-7777-7777-7777-777777777777' and seq = 1;
  insert into tst.results(name, ok, detail) values ('R02b Solo resultados válidos de parada', false, 'aceptó');
exception when others then insert into tst.results(name, ok, detail) values ('R02b Solo resultados válidos de parada', sqlerrm like '%check constraint%', sqlerrm); end $$;
commit;
