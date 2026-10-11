\set ON_ERROR_STOP on
\set A '00000000-0000-0000-0000-00000000000a'
\set D '00000000-0000-0000-0000-00000000000d'
\set C '00000000-0000-0000-0000-000000000003'
select tst.res('DNI-01 Bucket identity-docs privado, 5 MB, solo JPEG/PNG', public = false and file_size_limit = 5242880 and allowed_mime_types = array['image/jpeg','image/png'], '') from storage.buckets where id = 'identity-docs';
select tst.res('DNI-02 La base guarda solo la ruta (sin foto) para el DNI nuevo', storage_path like '20123456786/%.jpg' and dni_photo is null and mime = 'image/jpeg', storage_path) from public.customer_identity_docs where cuil = '20123456786';
-- Hoja nueva de Cristian para probar validaciones de subida
begin; select tst.u(:'D'); set local role authenticated;
create temp table t_r as select * from public.publish_route('{"sheet_key":"RC1-C","carrier_id":"CT-ESTE","responsable_id":"00000000-0000-0000-0000-000000000003","stops":[{"client_name":"A","zone":"ESTE","order_numbers":["98001"],"ready":true},{"client_name":"B","zone":"ESTE","order_numbers":["98002"],"ready":true},{"client_name":"C","zone":"ESTE","order_numbers":["98003"],"ready":true}]}');
grant select on t_r to public;
commit;
create or replace function tst.ev2(cuil text, path text) returns jsonb language sql as $$ select jsonb_build_object('evidence', jsonb_build_object('receiver_name','R','signature_png_b64','iVBORw0KGgo=','cuil',cuil,'dni_storage_path',path), 'location', jsonb_build_object('lat',-32.9,'lon',-68.8)) $$;
grant execute on function tst.ev2(text, text) to public;
begin; select tst.u(:'C'); set local role authenticated;
select public.start_route((select id from t_r));
-- subida (lo que hace supabase-js con la política de Storage)
insert into storage.objects(bucket_id, name, metadata) values ('identity-docs', '27222222223/1b4e28ba-2fa1-11d2-883f-0016d3cca427.jpg', '{"mimetype":"image/jpeg","size":250000}');
select tst.expect('DNI-03 Subir fuera de la carpeta del CUIL o con nombre libre: rechazado por la política', $q$ insert into storage.objects(bucket_id, name, metadata) values ('identity-docs', 'cualquiera.jpg', '{"mimetype":"image/jpeg","size":1}') $q$, '%row-level security%');
select tst.res('DNI-04 El chofer NO puede descargar fotos (sin lectura)', count(*) = 0, count(*)::text) from storage.objects where bucket_id = 'identity-docs';
insert into storage.objects(bucket_id, name, metadata) values ('identity-docs', '27333333334/2c5ea4c0-4067-11e9-8bad-9b1deb4d3b7d.png', '{"mimetype":"image/gif","size":1000}');
insert into storage.objects(bucket_id, name, metadata) values ('identity-docs', '27444444445/3d6f9e64-4067-11e9-8bad-9b1deb4d3b7d.jpg', '{"mimetype":"image/jpeg","size":6000000}');
select tst.expect('DNI-05 Tipo inválido (no JPEG/PNG): rechazado', format('select public.set_stop_outcome(%L, %L, null, null, %L, %L)', (select id from public.route_stops where route_id = (select id from t_r) and seq = 1), 'ENTREGADO', 'r1', tst.ev2('27333333334', '27333333334/2c5ea4c0-4067-11e9-8bad-9b1deb4d3b7d.png')), 'DNI_UPLOAD_INVALID: BAD_TYPE%');
select tst.expect('DNI-06 Más de 5 MB: rechazado', format('select public.set_stop_outcome(%L, %L, null, null, %L, %L)', (select id from public.route_stops where route_id = (select id from t_r) and seq = 1), 'ENTREGADO', 'r2', tst.ev2('27444444445', '27444444445/3d6f9e64-4067-11e9-8bad-9b1deb4d3b7d.jpg')), 'DNI_UPLOAD_INVALID: BAD_SIZE%');
select tst.expect('DNI-07 Ruta de otro CUIL o sin subir: rechazado', format('select public.set_stop_outcome(%L, %L, null, null, %L, %L)', (select id from public.route_stops where route_id = (select id from t_r) and seq = 1), 'ENTREGADO', 'r3', tst.ev2('27555555556', '27222222223/1b4e28ba-2fa1-11d2-883f-0016d3cca427.jpg')), 'DNI_UPLOAD_INVALID: BAD_PATH%');
select tst.expect('DNI-08 La foto en base64 ya no se acepta', format('select public.set_stop_outcome(%L, %L, null, null, %L, %L)', (select id from public.route_stops where route_id = (select id from t_r) and seq = 1), 'ENTREGADO', 'r4', '{"evidence":{"receiver_name":"R","signature_png_b64":"iVBORw0KGgo=","cuil":"27666666667","dni_photo_b64":"/9j/"},"location":{"lat":-32.9,"lon":-68.8}}'), 'DNI_STORAGE_REQUIRED%');
select public.set_stop_outcome((select id from public.route_stops where route_id = (select id from t_r) and seq = 1), 'ENTREGADO', null, null, 'r5', tst.ev2('27222222223', '27222222223/1b4e28ba-2fa1-11d2-883f-0016d3cca427.jpg'));
select tst.res('DNI-09 Subida válida: el chofer solo ve que el CUIL ya tiene DNI', public.cuil_has_dni('27222222223'), '');
select tst.res('DNI-04b El chofer no ve la tabla de DNI', count(*) = 0, '') from public.customer_identity_docs;
commit;
begin; select tst.u(:'D'); set local role authenticated;
select tst.res('DNI-10 Despacho (sin identity_docs.view) no ve fotos ni rutas', (select count(*) from storage.objects where bucket_id = 'identity-docs') = 0 and (select count(*) from public.customer_identity_docs) = 0, '');
commit;
begin; select tst.u(:'A'); set local role authenticated;
select tst.res('DNI-11 Admin con identity_docs.view lee la ruta para pedir URL firmada temporal', (select count(*) from storage.objects where bucket_id = 'identity-docs' and name like '27222222223/%') = 1 and (select storage_path from public.customer_identity_docs where cuil = '27222222223') is not null, '');
commit;
select tst.res('DNI-12 Registros viejos con foto en la base siguen siendo válidos (compatibilidad)', (select count(*) from information_schema.columns where table_name = 'customer_identity_docs' and column_name = 'dni_photo' and is_nullable = 'YES') = 1, '');
