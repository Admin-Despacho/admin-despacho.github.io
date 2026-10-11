\set ON_ERROR_STOP on
\set A '00000000-0000-0000-0000-00000000000a'
\set D '00000000-0000-0000-0000-00000000000d'
\set C '00000000-0000-0000-0000-000000000003'
select tst.res('PDFPUB-00 Bucket route-pdfs privado (solo PDF)', public = false and allowed_mime_types = array['application/pdf'], '') from storage.buckets where id = 'route-pdfs';
begin; select tst.u(:'D'); set local role authenticated;
select tst.res('PDFPUB-CFG Despacho lee la configuración efectiva (por defecto: generar y descargar)', pdf_auto_generate and pdf_auto_download, '') from public.dispatch_settings;
select tst.expect('PDFPUB-12 Sin settings.manage no cambia la configuración', $q$ select public.set_dispatch_settings(false, false) $q$, 'FORBIDDEN%');
select tst.expect('PDFPUB-11 Envío pendiente: no publica (no hay hoja ni PDF)', $q$ select public.publish_route('{"sheet_key":"RC12-P","carrier_id":"CT-ESTE","responsable_id":"00000000-0000-0000-0000-000000000003","stops":[{"client_name":"X","zone":"ESTE","order_numbers":["99950"],"ready":true,"ship_fee_status":"PROVISIONAL","ship_order":"99951","shipping_fee":10000}]}') $q$, 'SHIPPING_PENDING%');
create temp table t_p as select * from public.publish_route('{"sheet_key":"RC12-OK","carrier_id":"CT-ESTE","responsable_id":"00000000-0000-0000-0000-000000000003","stops":[{"client_name":"Cliente PDF","zone":"ESTE","order_numbers":["99960"],"ready":true}],"pdf_model":{"head":["CLIENTE"],"total":1234}}');
grant select on t_p to public;
-- falla de generación: queda pendiente
select public.register_route_pdf((select id from t_p), 1, null, 'Sin espacio en el dispositivo');
commit;
select tst.res('PDFPUB-09 Falla de generación: hoja PUBLICADA y PDF pendiente (PDF_ERROR) para reintentar', p.status = 'PDF_ERROR' and r.operational_status = 'PUBLICADA', p.status) from public.route_pdfs p join public.routes r on r.id = p.route_id where p.route_id = (select id from t_p);
begin; select tst.u(:'D'); set local role authenticated;
select tst.res('PDFPUB-02 El snapshot para regenerar es el publicado', public.route_pdf_snapshot((select id from t_p))->'pdf_model'->>'total' = '1234', '');
insert into storage.objects(bucket_id, name, metadata) values ('route-pdfs', (select id from t_p) || '/v1/Hoja_' || (select number from t_p) || '_v1.pdf', '{"mimetype":"application/pdf","size":9000}');
select tst.expect('PDFPUB-03b Ruta de archivo inválida rechazada', format('select public.register_route_pdf(%L, 1, %L, null)', (select id from t_p), 'otra/ruta.pdf'), 'BAD_PATH%');
select public.register_route_pdf((select id from t_p), 1, (select id from t_p) || '/v1/Hoja_' || (select number from t_p) || '_v1.pdf', null);
select public.register_route_pdf((select id from t_p), 1, (select id from t_p) || '/v1/Hoja_' || (select number from t_p) || '_v1.pdf', null);
select public.register_route_pdf((select id from t_p), 1, null, 'reintento tardío que falla');
commit;
select tst.res('PDFPUB-03/04/10 Retry: un solo PDF lógico por hoja+versión, OK, con correlativo y versión en el nombre; un error tardío no pisa el OK',
  count(*) = 1 and bool_and(status = 'OK' and file_name = 'Hoja_' || route_number || '_v1.pdf' and route_version = 1 and generated_at is not null and attempts = 4), string_agg(file_name || ' ' || status, ',')) from public.route_pdfs where route_id = (select id from t_p);
select tst.expect('PDFPUB-05 Un archivo publicado no se sobrescribe (único en Storage)', format($q$ insert into storage.objects(bucket_id, name, metadata) values ('route-pdfs', %L, '{}') $q$, (select id from t_p) || '/v1/Hoja_' || (select number from t_p) || '_v1.pdf'), '%duplicate key%');
begin; select tst.u(:'D'); set local role authenticated;
insert into storage.objects(bucket_id, name, metadata) values ('route-pdfs', (select id from t_p) || '/v2/Hoja_' || (select number from t_p) || '_v2.pdf', '{"mimetype":"application/pdf","size":9100}');
select public.register_route_pdf((select id from t_p), 2, (select id from t_p) || '/v2/Hoja_' || (select number from t_p) || '_v2.pdf', null);
commit;
select tst.res('PDFPUB-05b La v2 convive con la v1 (no la sobrescribe)', array_agg(file_name order by route_version) = array['Hoja_' || (select number from t_p) || '_v1.pdf', 'Hoja_' || (select number from t_p) || '_v2.pdf'], '') from public.route_pdfs where route_id = (select id from t_p);
begin; select tst.u(:'C'); set local role authenticated;
select tst.res('PDFPUB-14 El responsable ve los PDF de su hoja (para URL firmada)', count(*) = 2, count(*)::text) from storage.objects where bucket_id = 'route-pdfs' and split_part(name, '/', 1) = (select id from t_p)::text;
select tst.expect('PDFPUB-14b El transportista no sube PDFs de hoja', format($q$ insert into storage.objects(bucket_id, name, metadata) values ('route-pdfs', %L, '{}') $q$, (select id from t_p) || '/v3/Hoja_' || (select number from t_p) || '_v3.pdf'), '%row-level security%');
commit;
begin; select tst.u(:'A'); set local role authenticated;
select public.set_dispatch_settings(true, false);
commit;
select tst.res('PDFPUB-12b Admin (settings.manage) cambia la configuración', pdf_auto_generate and not pdf_auto_download, '') from public.dispatch_settings;
