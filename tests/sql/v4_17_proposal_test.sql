-- Pruebas de la PROPUESTA V4.17 (set_stop_outcome, base = migración 45 cristian_email_dni_required). Corre DESPUÉS de g2_revision_test (reutiliza sus usuarios, ubicaciones y vehículo).
-- Ver propuestas/v4_16/run_proposal_tests.sh. Datos ficticios.
\set ON_ERROR_STOP on
\set G  'e0000000-0000-0000-0000-000000000007'
\set S  'e0000000-0000-0000-0000-000000000005'
\set C  'e0000000-0000-0000-0000-0000000000c1'
-- Chofer EXTERNO de Cristian (configuración: carrier con report_group CRISTIAN_TORRES)
insert into auth.users(id, email) values (:'C','v416ct@t') on conflict do nothing;
select set_config('okd.sync', 'on', false);
insert into public.profiles(id, full_name, email, role, status) values (:'C','Chofer Externo V416','v416ct@t','SOLO_LECTURA','ACTIVO') on conflict (id) do nothing;
insert into public.user_carriers(user_id, carrier_id) values (:'C','CT-ESTE') on conflict do nothing;
update public.profiles set role = 'TRANSPORTISTA' where id = :'C';
select set_config('okd.sync', '', false);
select tst.res('V416-00 CT-ESTE está configurado como Cristian (report_group)', (select report_group from public.carriers where id = 'CT-ESTE') = 'CRISTIAN_TORRES', '');

-- ===== Hojas: Gabriel (INTERNO) con entrega comercial nueva + San Juan; Cristian con parada ANTIGUA (AMBAS) y una nueva =====
begin; select tst.u(:'S'); set local role authenticated;
select public.reserve_orders('V416-GB', array['73001','73002']);
create temp table v_gb as select * from public.publish_route(jsonb_build_object('sheet_key','V416-GB','carrier_id','INTERNO','responsable_id',:'G','vehicle_id','f0000000-0000-0000-0000-000000000001','rules_version',1,'routing_rules_version',1,'stops',jsonb_build_array(
  jsonb_build_object('client_name','CLIENTE V416 UNO','address','Calle 1, Mendoza','stop_type','PEDIDO','order_numbers',jsonb_build_array('73001'),'merchandise_amount',1000,'task','ENTREGA','ready',true),
  jsonb_build_object('client_name','CLIENTE V416 DOS','address','Calle 2, Mendoza','stop_type','PEDIDO','order_numbers',jsonb_build_array('73002'),'merchandise_amount',1000,'task','ENTREGA','ready',true),
  jsonb_build_object('client_name','Sucursal San Juan','address','San Juan 500, Mendoza','stop_type','UBICACION_INTERNA','internal_location_key','SAN_JUAN','order_numbers',jsonb_build_array(),'ready',true))));
grant select on v_gb to public;
select public.reserve_orders('V416-CT', array['73010','73011']);
create temp table v_ct as select * from public.publish_route(jsonb_build_object('sheet_key','V416-CT','carrier_id','CT-ESTE','responsable_id',:'C','rules_version',1,'routing_rules_version',1,'stops',jsonb_build_array(
  jsonb_build_object('client_name','CLIENTE V416 CT ANTIGUA','address','Calle 10, Mendoza','stop_type','PEDIDO','order_numbers',jsonb_build_array('73010'),'merchandise_amount',1000,'task','AMBAS','expected_amount',1000,'ready',true),
  jsonb_build_object('client_name','CLIENTE V416 CT NUEVA','address','Calle 11, Mendoza','stop_type','PEDIDO','order_numbers',jsonb_build_array('73011'),'merchandise_amount',1000,'task','ENTREGA','expected_amount',1000,'ready',true))));
grant select on v_ct to public;
commit;
create temp table v_s as select id, route_id, client_name, task, stop_type from public.route_stops where route_id in ((select id from v_gb), (select id from v_ct)); grant select on v_s to public;
-- cobranza registrada ANTES en la parada antigua (no debe borrarse ni cambiarse)
update public.route_stops set collection_status = 'COBRO_PARCIAL', collected_amount = 400, payment_mode = 'EFECTIVO', collection_note = 'registrada antes'
 where id = (select id from v_s where client_name = 'CLIENTE V416 CT ANTIGUA');
-- fotos del DNI subidas a Storage por cada chofer (mismo bucket/política que producción)
insert into storage.buckets(id, name, public) values ('identity-docs','identity-docs',false) on conflict do nothing;
insert into storage.objects(bucket_id, name, owner, metadata) values
  ('identity-docs', '20111111112/11111111-1111-1111-1111-111111111111.jpg', :'G', '{"mimetype":"image/jpeg","size":180000}'),
  ('identity-docs', '20333333334/33333333-3333-3333-3333-333333333333.jpg', :'C', '{"mimetype":"image/jpeg","size":190000}');

begin; select tst.u(:'G'); set local role authenticated; select public.start_route((select id from v_gb), 2000); commit;
begin; select tst.u(:'C'); set local role authenticated; select public.start_route((select id from v_ct), null); commit;

-- ===== Gabriel · entrega COMERCIAL: email + CUIL + foto del DNI + firma → DNI vinculado y Recibido Conforme =====
begin; select tst.u(:'G'); set local role authenticated;
select tst.expect('V417-G1 Gabriel (INTERNO) entrega comercial SIN email → EMAIL_REQUIRED', format($q$ select public.set_stop_outcome(%L, 'ENTREGADO', null, null, 'v417-ga',
  '{"evidence":{"receiver_name":"Receptor Uno","signature_png_b64":"iVBORw0KGgo=","cuil":"20111111112","dni_storage_path":"20111111112/11111111-1111-1111-1111-111111111111.jpg"},"location":{"lat":-32.89,"lon":-68.84}}') $q$,
  (select id from v_s where client_name = 'CLIENTE V416 UNO')), 'EMAIL_REQUIRED%');
select tst.expect('V417-G2 Gabriel entrega comercial con CUIL NUEVO y sin foto del DNI → DNI_REQUIRED', format($q$ select public.set_stop_outcome(%L, 'ENTREGADO', null, null, 'v417-gb',
  '{"evidence":{"receiver_name":"Receptor Uno","signature_png_b64":"iVBORw0KGgo=","cuil":"20111111112","email":"uno@cliente.test"},"location":{"lat":-32.89,"lon":-68.84}}') $q$,
  (select id from v_s where client_name = 'CLIENTE V416 UNO')), 'DNI_REQUIRED%');
select tst.expect('V417-G3 Gabriel entrega comercial SIN CUIL → CUIL_INVALID', format($q$ select public.set_stop_outcome(%L, 'ENTREGADO', null, null, 'v417-gc',
  '{"evidence":{"receiver_name":"Receptor Uno","signature_png_b64":"iVBORw0KGgo=","email":"uno@cliente.test"},"location":{"lat":-32.89,"lon":-68.84}}') $q$,
  (select id from v_s where client_name = 'CLIENTE V416 UNO')), 'CUIL_INVALID%');
select tst.expect('V416-01 Gabriel: ruta del DNI no subida → rechazada (se mantienen las validaciones)', format($q$ select public.set_stop_outcome(%L, 'ENTREGADO', null, null, 'v416-g0',
  '{"evidence":{"receiver_name":"Receptor Uno","signature_png_b64":"iVBORw0KGgo=","cuil":"20111111112","email":"uno@cliente.test","dni_storage_path":"20111111112/99999999-9999-9999-9999-999999999999.jpg"},"location":{"lat":-32.89,"lon":-68.84}}') $q$,
  (select id from v_s where client_name = 'CLIENTE V416 UNO')), 'DNI_UPLOAD_INVALID%');
select public.set_stop_outcome((select id from v_s where client_name = 'CLIENTE V416 UNO'), 'ENTREGADO', null, null, 'v416-g1',
  '{"evidence":{"receiver_name":"Receptor Uno","signature_png_b64":"iVBORw0KGgo=","cuil":"20111111112","email":"uno@cliente.test","dni_storage_path":"20111111112/11111111-1111-1111-1111-111111111111.jpg"},"location":{"lat":-32.89,"lon":-68.84}}');
commit;
select tst.res('V416-02 Gabriel: la foto del DNI queda VINCULADA y recuperable desde la entrega (stop_evidence.receiver_cuil → customer_identity_docs)',
  exists (select 1 from public.stop_evidence e join public.customer_identity_docs d on d.cuil = e.receiver_cuil
          where e.stop_id = (select id from v_s where client_name = 'CLIENTE V416 UNO') and d.storage_path = '20111111112/11111111-1111-1111-1111-111111111111.jpg'
            and e.receiver_email = 'uno@cliente.test' and e.evidence_kind = 'ENTREGA_CLIENTE'), '');
select tst.res('V416-03 Gabriel: Recibido Conforme generado y su correo encolado (simulado, no se envía)',
  exists (select 1 from public.delivery_receipts where stop_id = (select id from v_s where client_name = 'CLIENTE V416 UNO') and recipient_email = 'uno@cliente.test')
  and exists (select 1 from public.customer_email_jobs where stop_id = (select id from v_s where client_name = 'CLIENTE V416 UNO') and recipient = 'uno@cliente.test'), '');
-- identidad ya registrada: se REUTILIZA sin nueva foto
begin; select tst.u(:'G'); set local role authenticated;
select public.set_stop_outcome((select id from v_s where client_name = 'CLIENTE V416 DOS'), 'ENTREGADO', null, null, 'v416-g2',
  '{"evidence":{"receiver_name":"Receptor Uno","signature_png_b64":"iVBORw0KGgo=","cuil":"20111111112","email":"uno@cliente.test"},"location":{"lat":-32.89,"lon":-68.84}}');
commit;
select tst.res('V417-G4 Gabriel: ACEPTA con identidad reutilizable (CUIL ya registrado, sin foto nueva), sin duplicar la identidad',
  (select count(*) from public.customer_identity_docs where cuil = '20111111112') = 1
  and exists (select 1 from public.stop_evidence where stop_id = (select id from v_s where client_name = 'CLIENTE V416 DOS') and receiver_cuil = '20111111112'), '');
-- sucursal: solo nombre y firma
begin; select tst.u(:'G'); set local role authenticated;
select public.set_stop_outcome((select id from v_s where client_name = 'Sucursal San Juan'), 'ENTREGADO', null, null, 'v416-g3',
  '{"evidence":{"receiver_name":"Encargado San Juan","signature_png_b64":"iVBORw0KGgo="},"location":{"lat":-32.895,"lon":-68.845}}');
commit;
select tst.res('V416-05 sucursal (San Juan): solo nombre + firma → RECEPCION_INTERNA, sin identidad ni email',
  exists (select 1 from public.stop_evidence where stop_id = (select id from v_s where client_name = 'Sucursal San Juan') and evidence_kind = 'RECEPCION_INTERNA' and receiver_cuil is null and receiver_email is null), '');

-- ===== Cristian · parada ANTIGUA (AMBAS) sin cobranza: se guarda y NO se inventa ni se borra ningún cobro =====
begin; select tst.u(:'C'); set local role authenticated;
select tst.expect('V417-C1 Cristian (EXTERNO) entrega comercial SIN email → EMAIL_REQUIRED (control vigente conservado)', format($q$ select public.set_stop_outcome(%L, 'ENTREGADO', null, null, 'v417-ca',
  '{"evidence":{"receiver_name":"Receptor CT","signature_png_b64":"iVBORw0KGgo=","cuil":"20333333334","dni_storage_path":"20333333334/33333333-3333-3333-3333-333333333333.jpg"},"location":{"lat":-32.89,"lon":-68.84}}') $q$,
  (select id from v_s where client_name = 'CLIENTE V416 CT ANTIGUA')), 'EMAIL_REQUIRED%');
select tst.expect('V417-C2 Cristian con CUIL NUEVO y sin foto del DNI → DNI_REQUIRED (control vigente conservado)', format($q$ select public.set_stop_outcome(%L, 'ENTREGADO', null, null, 'v417-cb',
  '{"evidence":{"receiver_name":"Receptor CT","signature_png_b64":"iVBORw0KGgo=","cuil":"20333333334","email":"ct@cliente.test"},"location":{"lat":-32.89,"lon":-68.84}}') $q$,
  (select id from v_s where client_name = 'CLIENTE V416 CT ANTIGUA')), 'DNI_REQUIRED%');
select tst.expect('V416-06 si la cobranza SE INFORMA, se sigue validando (cobro parcial sin observación → rechazado)', format($q$ select public.set_stop_outcome(%L, 'ENTREGADO', null, null, 'v416-c0',
  '{"evidence":{"receiver_name":"Receptor CT","signature_png_b64":"iVBORw0KGgo=","cuil":"20333333334","email":"ct@cliente.test","dni_storage_path":"20333333334/33333333-3333-3333-3333-333333333333.jpg"},"collection":{"status":"COBRO_PARCIAL","amount":100},"location":{"lat":-32.89,"lon":-68.84}}') $q$,
  (select id from v_s where client_name = 'CLIENTE V416 CT ANTIGUA')), 'COLLECTION_NOTE_REQUIRED%');
select public.set_stop_outcome((select id from v_s where client_name = 'CLIENTE V416 CT ANTIGUA'), 'ENTREGADO', null, null, 'v416-c1',
  '{"evidence":{"receiver_name":"Receptor CT","signature_png_b64":"iVBORw0KGgo=","cuil":"20333333334","email":"ct@cliente.test","dni_storage_path":"20333333334/33333333-3333-3333-3333-333333333333.jpg"},"location":{"lat":-32.89,"lon":-68.84}}');
select public.set_stop_outcome((select id from v_s where client_name = 'CLIENTE V416 CT NUEVA'), 'ENTREGADO', null, null, 'v416-c2',
  '{"evidence":{"receiver_name":"Receptor CT","signature_png_b64":"iVBORw0KGgo=","cuil":"20333333334","email":"ct@cliente.test"},"location":{"lat":-32.89,"lon":-68.84}}');
commit;
select tst.res('V416-07 Cristian: hoja ANTIGUA (AMBAS) se guarda SIN cobranza y la cobranza registrada antes se CONSERVA',
  (select outcome = 'ENTREGADO' and collection_status = 'COBRO_PARCIAL' and collected_amount = 400 and payment_mode = 'EFECTIVO' and collection_note = 'registrada antes'
     from public.route_stops where id = (select id from v_s where client_name = 'CLIENTE V416 CT ANTIGUA')), '');
select tst.res('V417-C3 Cristian: ACEPTA con identidad reutilizable (la parada NUEVA usa el CUIL ya registrado, sin foto nueva)',
  exists (select 1 from public.stop_evidence e join public.customer_identity_docs d on d.cuil = e.receiver_cuil
          where e.stop_id = (select id from v_s where client_name = 'CLIENTE V416 CT NUEVA') and d.cuil = '20333333334' and d.storage_path is not null)
  and (select count(*) from public.customer_identity_docs where cuil = '20333333334') = 1, '');
select tst.res('V416-08 Cristian: hoja NUEVA (ENTREGA) sin cobranza → no se registra ningún cobro',
  (select outcome = 'ENTREGADO' and coalesce(collection_status, 'PENDIENTE') = 'PENDIENTE' and collected_amount is null and payment_mode is null
     from public.route_stops where id = (select id from v_s where client_name = 'CLIENTE V416 CT NUEVA')), '');
select tst.res('V416-09 Cristian: DNI vinculado y Recibido Conforme (sigue igual que antes)',
  exists (select 1 from public.stop_evidence e join public.customer_identity_docs d on d.cuil = e.receiver_cuil where e.stop_id = (select id from v_s where client_name = 'CLIENTE V416 CT ANTIGUA'))
  and exists (select 1 from public.delivery_receipts where stop_id = (select id from v_s where client_name = 'CLIENTE V416 CT ANTIGUA')), '');
select tst.res('V416-10 la definición vigente de set_stop_outcome es la de la PROPUESTA (orden de migraciones resuelto)',
  pg_get_functiondef('public.set_stop_outcome(uuid,text,text,text,text,jsonb)'::regprocedure) like '%V4.17%', '');
select tst.res('V417-00 la propuesta CONSERVA los controles vigentes: EMAIL_REQUIRED, DNI_REQUIRED, EMAIL_INVALID, DNI_INVALID y el perfil reutilizable',
  (select bool_and(pg_get_functiondef('public.set_stop_outcome(uuid,text,text,text,text,jsonb)'::regprocedure) like '%' || x || '%')
     from unnest(array['EMAIL_REQUIRED','DNI_REQUIRED','EMAIL_INVALID','DNI_INVALID','_upsert_identity_profile','_register_identity','_create_delivery_receipt','INTERNAL_TRANSFER_RECEIVED']) x), '');
