-- Pruebas de la PROPUESTA V4.21 (base PRODUCCIÓN = V4.17) · set_stop_outcome SIN foto del DNI y con EMAIL OPCIONAL. Corre DESPUÉS de g2_revision_test (usuarios ficticios). Datos ficticios.
\set ON_ERROR_STOP on
\set G  'e0000000-0000-0000-0000-000000000007'
\set S  'e0000000-0000-0000-0000-000000000005'
\set C  'e0000000-0000-0000-0000-0000000000c9'
\set PNG 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='
insert into auth.users(id, email) values (:'C','v419ct@t') on conflict do nothing;
select set_config('okd.sync', 'on', false);
insert into public.profiles(id, full_name, email, role, status) values (:'C','Chofer Externo V419','v419ct@t','SOLO_LECTURA','ACTIVO') on conflict (id) do nothing;
insert into public.user_carriers(user_id, carrier_id) values (:'C','CT-ESTE') on conflict do nothing;
update public.profiles set role = 'TRANSPORTISTA' where id = :'C';
select set_config('okd.sync', '', false);
-- identidad HISTÓRICA con foto (no debe tocarse)
insert into storage.buckets(id, name, public) values ('identity-docs','identity-docs',false) on conflict do nothing;
insert into public.customer_identity_docs(cuil, storage_path, mime, registered_by) values ('20999999990', '20999999990/99999999-9999-9999-9999-999999999999.jpg', 'image/jpeg', :'G') on conflict do nothing;
create temp table hist as select cuil, storage_path, dni_photo is not null foto_bytea from public.customer_identity_docs; grant select on hist to public;
-- ===== hojas: Gabriel (INTERNO) con 4 entregas comerciales + San Juan; Cristian (EXTERNO) con 1 =====
begin; select tst.u(:'S'); set local role authenticated;
select public.reserve_orders('V419-GB', array['74001','74002','74003','74004']);
create temp table f_gb as select * from public.publish_route(jsonb_build_object('sheet_key','V419-GB','carrier_id','INTERNO','responsable_id',:'G','vehicle_id','f0000000-0000-0000-0000-000000000001','rules_version',1,'routing_rules_version',1,'stops',jsonb_build_array(
  jsonb_build_object('client_name','CLIENTE V419 UNO','address','Calle 1, Mendoza','stop_type','PEDIDO','order_numbers',jsonb_build_array('74001'),'merchandise_amount',1000,'task','ENTREGA','ready',true),
  jsonb_build_object('client_name','CLIENTE V419 DOS','address','Calle 2, Mendoza','stop_type','PEDIDO','order_numbers',jsonb_build_array('74002'),'merchandise_amount',1000,'task','ENTREGA','ready',true),
  jsonb_build_object('client_name','CLIENTE V419 TRES','address','Calle 3, Mendoza','stop_type','PEDIDO','order_numbers',jsonb_build_array('74003'),'merchandise_amount',1000,'task','ENTREGA','ready',true),
  jsonb_build_object('client_name','CLIENTE V419 CUATRO','address','Calle 4, Mendoza','stop_type','PEDIDO','order_numbers',jsonb_build_array('74004'),'merchandise_amount',1000,'task','ENTREGA','ready',true),
  jsonb_build_object('client_name','Sucursal San Juan','address','San Juan 500, Mendoza','stop_type','UBICACION_INTERNA','internal_location_key','SAN_JUAN','order_numbers',jsonb_build_array(),'ready',true))));
grant select on f_gb to public;
select public.reserve_orders('V419-CT', array['74010','74011']);
create temp table f_ct as select * from public.publish_route(jsonb_build_object('sheet_key','V419-CT','carrier_id','CT-ESTE','responsable_id',:'C','rules_version',1,'routing_rules_version',1,'stops',jsonb_build_array(
  jsonb_build_object('client_name','CLIENTE V419 CT','address','Calle 10, Mendoza','stop_type','PEDIDO','order_numbers',jsonb_build_array('74010'),'merchandise_amount',1000,'task','ENTREGA','expected_amount',1000,'ready',true),
  jsonb_build_object('client_name','CLIENTE V419 CT COBRANZA','address','Calle 11, Mendoza','stop_type','PEDIDO','order_numbers',jsonb_build_array('74011'),'merchandise_amount',1000,'task','AMBAS','expected_amount',1000,'ready',true))));
grant select on f_ct to public;
commit;
create temp table f_s as select id, client_name from public.route_stops where route_id in ((select id from f_gb), (select id from f_ct)); grant select on f_s to public;
begin; select tst.u(:'G'); set local role authenticated; select public.start_route((select id from f_gb), 2000); commit;
begin; select tst.u(:'C'); set local role authenticated; select public.start_route((select id from f_ct), null); commit;
create or replace function pg_temp.ev(p_name text, p_cuil text, p_email text, p_sig boolean default true, p_extra jsonb default '{}') returns jsonb language sql as $f$
  select jsonb_build_object('location', jsonb_build_object('lat', -32.89, 'lon', -68.84, 'accuracy', 10), 'evidence', jsonb_strip_nulls(jsonb_build_object('receiver_name', p_name, 'cuil', p_cuil, 'email', p_email,
    'signature_png_b64', case when p_sig then 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==' end)) || p_extra) $f$;
-- ===== FS-00: definición vigente =====
select tst.res('FS-00a la función vigente es la V4.21 (huella 5d26e5af…) y partió EXACTAMENTE de la V4.17 (5e4bf784…)',
  (select md5(prosrc) from pg_proc where proname = 'set_stop_outcome') = '5d26e5af27a068596cc6875bd6ee8bbf' and (select huella from public.qa_priv_before) = '5e4bf78470b993100851b6dde6ae7f74'
  and (select prosrc from pg_proc where proname = 'set_stop_outcome') not like '%exception ''DNI_REQUIRED%' and (select prosrc from pg_proc where proname = 'set_stop_outcome') not like '%exception ''EMAIL_REQUIRED%'
  and (select bool_and((select prosrc from pg_proc where proname = 'set_stop_outcome') like '%' || k || '%') from unnest(array['EVIDENCE_REQUIRED','CUIL_INVALID','EMAIL_INVALID','DNI_INVALID','_create_delivery_receipt']) k), '');
select tst.res('FS-00b PERMISOS y SEGURIDAD idénticos a los de la V4.17 instalada (anon / authenticated / service_role, SECURITY DEFINER, search_path, dueño)',
  (select (b.anon_x, b.auth_x, b.srv_x, b.sd, b.cfg, b.duenio) is not distinct from (has_function_privilege('anon', p.oid, 'EXECUTE'), has_function_privilege('authenticated', p.oid, 'EXECUTE'),
     has_function_privilege('service_role', p.oid, 'EXECUTE'), p.prosecdef, p.proconfig, pg_get_userbyid(p.proowner))
   from public.qa_priv_before b, pg_proc p where p.proname = 'set_stop_outcome' and p.pronamespace = 'public'::regnamespace) and (select sd from public.qa_priv_before),
  (select row(anon_x, auth_x, srv_x, sd, cfg, duenio)::text from public.qa_priv_before));
-- ===== Gabriel (INTERNO): validaciones que se conservan =====
begin; select tst.u(:'G'); set local role authenticated;
select tst.expect('FS-01 entrega comercial SIN CUIL → CUIL_INVALID (CUIL obligatorio también para el interno)', format($q$ select public.set_stop_outcome(%L, 'ENTREGADO', null, null, 'v419-01', %L) $q$,
  (select id from f_s where client_name = 'CLIENTE V419 UNO'), pg_temp.ev('Receptor QA', null, 'r1@ejemplo.test')), 'CUIL_INVALID%');
select tst.expect('FS-02 SIN firma → EVIDENCE_REQUIRED', format($q$ select public.set_stop_outcome(%L, 'ENTREGADO', null, null, 'v419-02', %L) $q$,
  (select id from f_s where client_name = 'CLIENTE V419 UNO'), pg_temp.ev('Receptor QA', '20111222333', 'r1@ejemplo.test', false)), 'EVIDENCE_REQUIRED%');
select tst.expect('FS-03 SIN nombre → EVIDENCE_REQUIRED', format($q$ select public.set_stop_outcome(%L, 'ENTREGADO', null, null, 'v419-03', %L) $q$,
  (select id from f_s where client_name = 'CLIENTE V419 UNO'), pg_temp.ev('', '20111222333', 'r1@ejemplo.test')), 'EVIDENCE_REQUIRED%');
select tst.expect('FS-10b email con formato INVÁLIDO → EMAIL_INVALID (no se acepta en silencio)', format($q$ select public.set_stop_outcome(%L, 'ENTREGADO', null, null, 'v419-10b', %L) $q$,
  (select id from f_s where client_name = 'CLIENTE V419 TRES'), pg_temp.ev('Receptor QA', '20111222333', 'no-es-un-email')), 'EMAIL_INVALID%');
-- FS-10: SIN email → se confirma igual (V4.21)
select public.set_stop_outcome((select id from f_s where client_name = 'CLIENTE V419 TRES'), 'ENTREGADO', null, null, 'v419-10', pg_temp.ev('Receptor QA Tres', '20666777888', null));
-- FS-04: CUIL NUEVO y SIN foto → se acepta
select public.set_stop_outcome((select id from f_s where client_name = 'CLIENTE V419 UNO'), 'ENTREGADO', null, null, 'v419-04', pg_temp.ev('Receptor QA Uno', '20111222333', 'r1@ejemplo.test'));
-- FS-06: misma operación repetida (doble toque / reintento sin conexión)
select public.set_stop_outcome((select id from f_s where client_name = 'CLIENTE V419 UNO'), 'ENTREGADO', null, null, 'v419-04', pg_temp.ev('Receptor QA Uno', '20111222333', 'r1@ejemplo.test'));
-- FS-07: recepción interna de traslado G2 (sin CUIL ni email)
select public.set_stop_outcome((select id from f_s where client_name = 'Sucursal San Juan'), 'ENTREGADO', null, null, 'v419-07', pg_temp.ev('Encargada Sucursal QA', null, null));
-- FS-09: foto heredada de una entrega guardada sin conexión ANTES de la actualización → se sigue vinculando
insert into storage.objects(bucket_id, name, owner, metadata) values ('identity-docs', '20444444445/44444444-4444-4444-4444-444444444444.jpg', :'G', '{"mimetype":"image/jpeg","size":120000}');
select public.set_stop_outcome((select id from f_s where client_name = 'CLIENTE V419 DOS'), 'ENTREGADO', null, null, 'v419-09',
  pg_temp.ev('Receptor QA Dos', '20444444445', 'r2@ejemplo.test', true, '{}') || jsonb_build_object('evidence', pg_temp.ev('Receptor QA Dos', '20444444445', 'r2@ejemplo.test')->'evidence' || '{"dni_storage_path":"20444444445/44444444-4444-4444-4444-444444444444.jpg"}'));
commit;
select tst.res('FS-04 INTERNO: entrega comercial con CUIL NUEVO y SIN foto del DNI → ENTREGADO, nombre + CUIL + firma guardados (PNG con su huella) y Recibido Conforme encolado',
  (select outcome from public.route_stops where id = (select id from f_s where client_name = 'CLIENTE V419 UNO')) = 'ENTREGADO'
  and (select receiver_name = 'Receptor QA Uno' and receiver_cuil = '20111222333' and signature_png = decode(:'PNG', 'base64') and signature_sha256 = encode(sha256(decode(:'PNG', 'base64')), 'hex')
         from public.stop_evidence where stop_id = (select id from f_s where client_name = 'CLIENTE V419 UNO'))
  and not exists (select 1 from public.customer_identity_docs where cuil = '20111222333' and (storage_path is not null or dni_photo is not null))   -- (el perfil reutilizable sin foto sí se crea, como antes)
  and exists (select 1 from public.customer_email_jobs where stop_id = (select id from f_s where client_name = 'CLIENTE V419 UNO') and kind = 'RECIBIDO_CONFORME'), '');
select tst.res('FS-10 SIN email: la entrega se CONFIRMA (nombre + CUIL + firma guardados) y NO se genera Recibido Conforme ni ningún envío a una dirección vacía',
  (select outcome from public.route_stops where id = (select id from f_s where client_name = 'CLIENTE V419 TRES')) = 'ENTREGADO'
  and (select receiver_name = 'Receptor QA Tres' and receiver_cuil = '20666777888' and receiver_email is null and signature_png is not null from public.stop_evidence where stop_id = (select id from f_s where client_name = 'CLIENTE V419 TRES'))
  and not exists (select 1 from public.customer_email_jobs where stop_id = (select id from f_s where client_name = 'CLIENTE V419 TRES'))
  and not exists (select 1 from public.customer_email_jobs where coalesce(trim(recipient), '') = ''), '');
select tst.res('FS-06 la MISMA operación repetida no duplica la confirmación (una evidencia, una operación, un Recibido Conforme)',
  (select count(*) from public.stop_evidence where stop_id = (select id from f_s where client_name = 'CLIENTE V419 UNO')) = 1
  and (select count(*) from public.stop_outcome_ops where op_id = 'v419-04') = 1
  and (select count(*) from public.customer_email_jobs where stop_id = (select id from f_s where client_name = 'CLIENTE V419 UNO') and kind = 'RECIBIDO_CONFORME') = 1, '');
select tst.res('FS-07 G2 · recepción interna de traslado: nombre + firma, SIN CUIL ni email → RECEPCION_INTERNA (reglas particulares conservadas)',
  (select evidence_kind = 'RECEPCION_INTERNA' and receiver_cuil is null and receiver_email is null from public.stop_evidence where stop_id = (select id from f_s where client_name = 'Sucursal San Juan')), '');
select tst.res('FS-09 una foto HEREDADA (entrega guardada sin conexión antes de la actualización) se sigue vinculando como antes',
  exists (select 1 from public.customer_identity_docs where cuil = '20444444445' and storage_path = '20444444445/44444444-4444-4444-4444-444444444444.jpg'), '');
-- ===== Cristian (EXTERNO) =====
begin; select tst.u(:'C'); set local role authenticated;
select public.set_stop_outcome((select id from f_s where client_name = 'CLIENTE V419 CT'), 'ENTREGADO', null, null, 'v419-05', pg_temp.ev('Receptora QA CT', '27555666777', 'rct@ejemplo.test'));
select tst.expect('FS-11a cobranza IGUAL que la V4.17: si se INFORMA, se valida (cobro parcial sin observación → rechazado)', format($q$ select public.set_stop_outcome(%L, 'ENTREGADO', null, null, 'v419-11', %L) $q$,
  (select id from f_s where client_name = 'CLIENTE V419 CT COBRANZA'), pg_temp.ev('Receptora QA CT', '27555666777', 'rct@ejemplo.test') || '{"collection":{"status":"COBRO_PARCIAL","amount":100}}'), 'COLLECTION_NOTE_REQUIRED%');
select public.set_stop_outcome((select id from f_s where client_name = 'CLIENTE V419 CT COBRANZA'), 'ENTREGADO', null, null, 'v419-11b', pg_temp.ev('Receptora QA CT', '27555666777', 'rct@ejemplo.test'));
commit;
select tst.res('FS-05 EXTERNO (Cristian): CUIL NUEVO y SIN foto del DNI → ENTREGADO (antes: DNI_REQUIRED), con CUIL y firma guardados',
  (select outcome from public.route_stops where id = (select id from f_s where client_name = 'CLIENTE V419 CT')) = 'ENTREGADO'
  and (select receiver_cuil = '27555666777' and signature_png is not null from public.stop_evidence where stop_id = (select id from f_s where client_name = 'CLIENTE V419 CT'))
  and not exists (select 1 from public.customer_identity_docs where cuil = '27555666777' and (storage_path is not null or dni_photo is not null)), '');
select tst.res('FS-11b cobranza IGUAL que la V4.17: sin informarla, la parada AMBAS se guarda (cobranza opcional)', (select outcome from public.route_stops where id = (select id from f_s where client_name = 'CLIENTE V419 CT COBRANZA')) = 'ENTREGADO', '');
select tst.res('FS-08 identidades y fotos HISTÓRICAS intactas (no se borra ni modifica ninguna)',
  exists (select 1 from public.customer_identity_docs where cuil = '20999999990' and storage_path = '20999999990/99999999-9999-9999-9999-999999999999.jpg')
  and not exists (select 1 from hist h left join public.customer_identity_docs d on d.cuil = h.cuil
                   where d.cuil is null or d.storage_path is distinct from h.storage_path or (d.dni_photo is not null) <> h.foto_bytea), '');
