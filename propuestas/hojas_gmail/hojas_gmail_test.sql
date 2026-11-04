-- Pruebas de la PROPUESTA "correo diario de hojas por Gmail" (Postgres local). Corre DESPUÉS de comms_test. Datos FICTICIOS.
\set ON_ERROR_STOP on
\set ADM 'e0000000-0000-0000-0000-0000000000c1'
\set OPN 'e0000000-0000-0000-0000-0000000000c3'
-- ===== HGS-01 canal del correo de hojas =====
begin; select tst.u(:'ADM'); set local role authenticated;
select tst.expect('HGS-01a canal inválido: rechazado en el servidor', $q$ select public.set_notification_settings('{"sheet_email_via":"SMTP"}') $q$, 'CANAL_INVALIDO%');
select public.set_notification_settings('{"sheet_email_enabled":true,"sheet_email_time":"17:35","sheet_email_recipients":["Logistica@Ejemplo.test","admin@ejemplo.test"],"sheet_email_via":"GMAIL"}');
commit;
select tst.res('HGS-01b canal GMAIL guardado (destinatarios en minúsculas) y auditado', (select sheet_email_via = 'GMAIL' and sheet_email_recipients = array['logistica@ejemplo.test','admin@ejemplo.test'] from public.notification_settings where id = 'DEFAULT')
  and exists (select 1 from public.audit_log where action = 'NOTIFICATION_SETTINGS_CHANGED' and after->>'sheet_email_via' = 'GMAIL'), '');
-- ===== datos ficticios: hojas y PDF del 02/11/2026 (claves foráneas y disparadores desactivados SOLO para preparar datos) =====
update public.comm_gmail_status set connected = true, needs_reconnect = false where id = 1;
create temp table hr as select gen_random_uuid() pub, gen_random_uuid() cur, gen_random_uuid() bor, gen_random_uuid() can, gen_random_uuid() ext, gen_random_uuid() exn,
  gen_random_uuid() sinpdf, gen_random_uuid() ayert, gen_random_uuid() ayerok, gen_random_uuid() res; grant select on hr to public;
create or replace function pg_temp.ruta(p_id uuid, p_num text, p_op text, p_ver int, p_pub timestamptz, p_mode text default 'APP', p_disp timestamptz default null) returns void language sql as $f$
  insert into public.routes(id, number, carrier_id, status, operational_status, version, published_at, dispatch_mode, dispatched_at)
  values (p_id, p_num, 'QA-HOJAS', p_op, p_op, p_ver, p_pub, p_mode, p_disp) $f$;
create or replace function pg_temp.pdf(p_id uuid, p_num text, p_ver int, p_gen timestamptz, p_st text default 'OK') returns void language sql as $f$
  insert into public.route_pdfs(route_id, route_version, route_number, file_name, storage_path, status, generated_at)
  values (p_id, p_ver, p_num, 'Hoja_' || p_num || '_v' || p_ver || '.pdf', p_id || '/v' || p_ver || '/Hoja_' || p_num || '_v' || p_ver || '.pdf', p_st, p_gen) $f$;
set session_replication_role = replica;
select pg_temp.ruta((select pub from hr), '03-000120', 'PUBLICADA', 1, '2026-11-02 12:00+00'), pg_temp.pdf((select pub from hr), '03-000120', 1, '2026-11-02 12:01+00');   -- publicada (09:00 Mendoza)
select pg_temp.ruta((select cur from hr), '03-000121', 'EN_CURSO', 1, '2026-11-02 12:05+00'), pg_temp.pdf((select cur from hr), '03-000121', 1, '2026-11-02 12:06+00');    -- en curso (chofer no terminó)
select pg_temp.ruta((select bor from hr), '03-000122', 'BORRADOR', 1, null), pg_temp.pdf((select bor from hr), '03-000122', 1, '2026-11-02 12:07+00');                      -- borrador
select pg_temp.ruta((select can from hr), '03-000123', 'CANCELADA', 1, '2026-11-02 12:08+00'), pg_temp.pdf((select can from hr), '03-000123', 1, '2026-11-02 12:09+00');  -- cancelada ANTES del encolado
select pg_temp.ruta((select ext from hr), '07-000001', 'COMPLETADA', 1, '2026-11-01 11:00+00', 'EXTERNAL', '2026-11-02 13:00+00'), pg_temp.pdf((select ext from hr), '07-000001', 1, '2026-11-02 13:01+00');   -- tercerizado despachado hoy
select pg_temp.ruta((select exn from hr), '07-000002', 'COMPLETADA', 1, '2026-11-02 11:00+00', 'EXTERNAL', null), pg_temp.pdf((select exn from hr), '07-000002', 1, '2026-11-02 13:02+00');                   -- tercerizado sin despacho
select pg_temp.ruta((select sinpdf from hr), '03-000124', 'PUBLICADA', 2, '2026-11-02 12:10+00'), pg_temp.pdf((select sinpdf from hr), '03-000124', 1, '2026-11-02 12:11+00');   -- vigente v2 SIN PDF (solo v1)
select pg_temp.ruta((select ayert from hr), '03-000201', 'PUBLICADA', 1, '2026-11-01 19:00+00'), pg_temp.pdf((select ayert from hr), '03-000201', 1, '2026-11-02 03:40+00');    -- de ayer, PDF TARDÍO (hoy 00:40)
select pg_temp.ruta((select ayerok from hr), '03-000202', 'PUBLICADA', 1, '2026-11-01 19:00+00'), pg_temp.pdf((select ayerok from hr), '03-000202', 1, '2026-11-01 19:01+00');  -- de ayer, PDF a tiempo
set session_replication_role = origin;
-- ===== HGS-02 encolado: solo publicadas o tercerizados despachados, por su día, con el PDF de la versión VIGENTE =====
begin; set local role service_role;
create temp table e1 as select public.comm_enqueue_sheet_pdfs('2026-11-02 20:30+00') n; grant select on e1 to public;   -- 17:30 Mendoza
create temp table e2 as select public.comm_enqueue_sheet_pdfs('2026-11-02 20:36+00') n; grant select on e2 to public;   -- 17:36 Mendoza
commit;
create temp table keys as select source_key k from public.comm_runs where kind = 'HOJAS'; grant select on keys to public;
select tst.res('HGS-02a antes de las 17:35 (Mendoza): solo el PDF TARDÍO de una hoja de ayer (la hoja de ayer con PDF a tiempo, no)', (select n from e1) = 1
  and exists (select 1 from keys where k = 'HOJA|' || (select ayert from hr) || '|1') and not exists (select 1 from keys where k like 'HOJA|' || (select ayerok from hr) || '|%'), (select n::text from e1));
select tst.res('HGS-02b desde las 17:35: publicada, en curso y tercerizado DESPACHADO; NO borrador, cancelada, sin despacho ni versión vigente sin PDF',
  (select n from e2) = 3 and (select count(*) from keys) = 4
  and exists (select 1 from keys where k = 'HOJA|' || (select pub from hr) || '|1') and exists (select 1 from keys where k = 'HOJA|' || (select cur from hr) || '|1')
  and exists (select 1 from keys where k = 'HOJA|' || (select ext from hr) || '|1')
  and not exists (select 1 from keys where k like any (array['HOJA|' || (select bor from hr) || '%', 'HOJA|' || (select can from hr) || '%', 'HOJA|' || (select exn from hr) || '%', 'HOJA|' || (select sinpdf from hr) || '%'])),
  (select string_agg(k, ' ') from keys));
select tst.res('HGS-02c cada ejecución lleva hoja, versión y día en su copia; PDF de route-pdfs; 2 destinatarios; programada al horario o al PDF tardío',
  (select bool_and(snapshot ? 'route_id' and snapshot ? 'route_version' and snapshot->'attachments'->0->>'bucket' = 'route-pdfs') from public.comm_runs where kind = 'HOJAS')
  and (select count(*) from public.comm_deliveries d join public.comm_runs r on r.id = d.run_id where r.kind = 'HOJAS') = 8
  and (select scheduled_for from public.comm_runs where source_key = 'HOJA|' || (select pub from hr) || '|1') = '2026-11-02 20:35+00'
  and (select scheduled_for from public.comm_runs where source_key = 'HOJA|' || (select ayert from hr) || '|1') = '2026-11-02 03:40+00', '');
select tst.res('HGS-02d comunicado del sistema creado ACTIVO y auditado', exists (select 1 from public.comm_messages where system_kind = 'HOJAS_DIA' and status = 'ACTIVO')
  and exists (select 1 from public.comm_audit where action = 'CREADO_POR_SISTEMA'), '');
-- ===== HGS-03 sin duplicar: repetición y DOS conexiones simultáneas =====
select dblink_connect('h1', 'dbname=' || current_database() || ' port=' || current_setting('port') || ' host=/tmp user=postgres');
select dblink_connect('h2', 'dbname=' || current_database() || ' port=' || current_setting('port') || ' host=/tmp user=postgres');
select dblink_send_query('h1', 'select public.comm_enqueue_sheet_pdfs(''2026-11-02 20:41+00'')');
select dblink_send_query('h2', 'select public.comm_enqueue_sheet_pdfs(''2026-11-02 20:41+00'')');
create temp table hq as select * from dblink_get_result('h1') as t(n int) union all select * from dblink_get_result('h2') as t(n int);
select dblink_disconnect('h1'); select dblink_disconnect('h2');
select tst.res('HGS-03 repetición SIMULTÁNEA: ninguna ejecución nueva, sin duplicados', (select sum(n) from hq) = 0 and (select count(*) from public.comm_runs where kind = 'HOJAS') = 4, (select sum(n)::text from hq));
-- ===== HGS-10 VERSIÓN VIGENTE sin PDF: cuando el PDF aparece TARDE, se encola (programada por el PDF) =====
set session_replication_role = replica; select pg_temp.pdf((select sinpdf from hr), '03-000124', 2, '2026-11-02 22:10+00'); set session_replication_role = origin;
begin; set local role service_role; create temp table e10 as select public.comm_enqueue_sheet_pdfs('2026-11-02 22:12+00') n; grant select on e10 to public; commit;
select tst.res('HGS-10 PDF tardío de la versión vigente (v2): se encola la v2 (nunca la v1), programada al momento del PDF', (select n from e10) = 1
  and (select scheduled_for from public.comm_runs where source_key = 'HOJA|' || (select sinpdf from hr) || '|2') = '2026-11-02 22:10+00'
  and not exists (select 1 from public.comm_runs where source_key = 'HOJA|' || (select sinpdf from hr) || '|1'), '');
-- ===== HGS-11 CANCELADA DESPUÉS del encolado y VERSIÓN ANTERIOR: la verificación previa cancela, sin enviar =====
update public.routes set operational_status = 'CANCELADA', status = 'CANCELADA' where id = (select cur from hr);
set session_replication_role = replica;
update public.routes set version = 2 where id = (select pub from hr); select pg_temp.pdf((select pub from hr), '03-000120', 2, '2026-11-02 22:20+00');
set session_replication_role = origin;
begin; set local role service_role;
create temp table c11 as select c.*, r.source_key from public.comm_claim(100, 'H11', '2026-11-02 22:21+00') c join public.comm_runs r on r.id = c.run_id
  where r.source_key in ('HOJA|' || (select cur from hr) || '|1', 'HOJA|' || (select pub from hr) || '|1'); grant select on c11 to public;
create temp table k11 as select source_key, public.comm_check(id, token) r from c11; grant select on k11 to public;
commit;
select tst.res('HGS-11a hoja CANCELADA después del encolado: CANCELLED, con motivo', (select bool_and(r = 'CANCELLED') from k11 where source_key like 'HOJA|' || (select cur from hr) || '%')
  and (select bool_and(d.status = 'CANCELADO' and d.reason like 'La hoja fue cancelada%') from public.comm_deliveries d join public.comm_runs r on r.id = d.run_id where r.source_key = 'HOJA|' || (select cur from hr) || '|1'),
  (select string_agg(r, ',') from k11));
select tst.res('HGS-11b VERSIÓN ANTERIOR (v1) con la v2 vigente: CANCELLED con motivo; la v2 se encola aparte', (select bool_and(r = 'CANCELLED') from k11 where source_key = 'HOJA|' || (select pub from hr) || '|1')
  and (select bool_and(d.reason like 'Hay una versión más nueva de la hoja (v2)%') from public.comm_deliveries d join public.comm_runs r on r.id = d.run_id where r.source_key = 'HOJA|' || (select pub from hr) || '|1')
  and (select count(*) from k11) = 4, '');
begin; set local role service_role; select public.comm_enqueue_sheet_pdfs('2026-11-02 22:22+00'); commit;
select tst.res('HGS-11c la versión vigente (v2) se encola', exists (select 1 from public.comm_runs where source_key = 'HOJA|' || (select pub from hr) || '|2'), '');
-- ===== HGS-12 REINTENTO: un envío en ERROR (reintentable) cuya hoja se cancela antes del reintento =====
update public.comm_deliveries d set status = 'ERROR', retryable = true, attempts = 1, next_attempt_at = '2026-11-02 22:00+00', claim_token = null
  from public.comm_runs r where r.id = d.run_id and r.source_key = 'HOJA|' || (select ext from hr) || '|1';
update public.routes set operational_status = 'CANCELADA', status = 'CANCELADA' where id = (select ext from hr);
begin; set local role service_role;
create temp table c12 as select c.* from public.comm_claim(100, 'H12', '2026-11-02 22:30+00') c join public.comm_runs r on r.id = c.run_id where r.source_key = 'HOJA|' || (select ext from hr) || '|1'; grant select on c12 to public;
create temp table k12 as select public.comm_check(id, token) r from c12; grant select on k12 to public;
commit;
select tst.res('HGS-12 en el REINTENTO también se verifica el estado: hoja cancelada → CANCELLED (no se reenvía)', (select count(*) from k12) = 2 and (select bool_and(r = 'CANCELLED') from k12), (select string_agg(r, ',') from k12));
-- ===== HGS-04 lo enviado por Resend no se repite por Gmail =====
set session_replication_role = replica;
select pg_temp.ruta((select res from hr), '03-000125', 'PUBLICADA', 1, '2026-11-02 12:30+00'), pg_temp.pdf((select res from hr), '03-000125', 1, '2026-11-02 23:00+00');
insert into public.sheet_email_jobs(route_id, route_version, recipient, idempotency_key, status) values ((select res from hr), 1, 'logistica@ejemplo.test', (select res from hr) || '|1|logistica@ejemplo.test', 'SENT');
set session_replication_role = origin;
begin; set local role service_role; select public.comm_enqueue_sheet_pdfs('2026-11-02 23:01+00'); commit;
select tst.res('HGS-04 versión ya enviada por Resend a un destinatario: por Gmail solo al otro', (select array_agg(d.email) from public.comm_deliveries d join public.comm_runs r on r.id = d.run_id
  where r.source_key = 'HOJA|' || (select res from hr) || '|1') = array['admin@ejemplo.test'], '');
-- ===== HGS-05 Resend: con GMAIL no encola; con RESEND excluye lo enviado (o posiblemente enviado) por Gmail =====
create temp table q1 as select public.queue_sheet_emails('2026-11-02') n; grant select on q1 to public;
update public.comm_deliveries d set status = 'ENVIADO', sent_at = now() from public.comm_runs r where r.id = d.run_id and r.source_key = 'HOJA|' || (select ayert from hr) || '|1' and d.email = 'logistica@ejemplo.test';
update public.notification_settings set sheet_email_via = 'RESEND' where id = 'DEFAULT';
set session_replication_role = replica;
create temp table q2 as select public.queue_sheet_emails('2026-11-02') n; grant select on q2 to public;
set session_replication_role = origin;
select tst.res('HGS-05 Resend: con GMAIL 0 trabajos; con RESEND no repite lo ENVIADO por Gmail, y sí lo no enviado', (select n from q1) = 0
  and not exists (select 1 from public.sheet_email_jobs where route_id = (select ayert from hr) and recipient = 'logistica@ejemplo.test')
  and exists (select 1 from public.sheet_email_jobs where route_id = (select ayert from hr) and recipient = 'admin@ejemplo.test'), (select n::text from q2));
-- ===== HGS-06 vuelto a RESEND con envíos de Gmail pendientes: la verificación previa los CANCELA =====
begin; set local role service_role;
create temp table c6 as select c.* from public.comm_claim(1, 'H6', '2026-11-02 23:02+00') c join public.comm_runs r on r.id = c.run_id where r.kind = 'HOJAS'; grant select on c6 to public;
create temp table k6 as select public.comm_check((select id from c6), (select token from c6)) r; grant select on k6 to public;
commit;
select tst.res('HGS-06 canal cambiado a RESEND antes de enviar: CANCELLED, con motivo', (select r from k6) = 'CANCELLED'
  and (select status = 'CANCELADO' and reason like 'Correo de hojas desactivado o cambiado a Resend%' from public.comm_deliveries where id = (select id from c6)), (select r from k6));
update public.notification_settings set sheet_email_via = 'GMAIL' where id = 'DEFAULT';
-- ===== HGS-07 el comunicado del sistema solo se pausa o reanuda =====
begin; select tst.u(:'ADM'); set local role authenticated;
select tst.expect('HGS-07a no se edita (asunto)', format($q$ select public.comm_save_message('{"id":"%s","internal_name":"Otro","subject":"Otro","body_html":"<p>x</p>","selection":{"all":true},"schedule":{"kind":"DAILY","time":"08:00","start_date":"2026-11-01"}}', true) $q$,
  (select id from public.comm_messages where system_kind = 'HOJAS_DIA')), '%MENSAJE_DEL_SISTEMA%');
select tst.expect('HGS-07b no se cancela', format('select public.comm_cancel(%L)', (select id from public.comm_messages where system_kind = 'HOJAS_DIA')), '%MENSAJE_DEL_SISTEMA%');
select public.comm_pause((select id from public.comm_messages where system_kind = 'HOJAS_DIA'));
commit;
select tst.res('HGS-07c se PAUSA (y se reanuda) normalmente', (select status from public.comm_messages where system_kind = 'HOJAS_DIA') = 'PAUSADO', '');
begin; select tst.u(:'ADM'); set local role authenticated; select public.comm_resume((select id from public.comm_messages where system_kind = 'HOJAS_DIA')); commit;
insert into storage.objects(bucket_id, name, metadata) values ('comm-attachments', 'messages/' || (select id from public.comm_messages where system_kind = 'HOJAS_DIA') || '/' || gen_random_uuid() || '.png', '{"size":10}');
begin; set local role service_role;
select tst.expect('HGS-07d no recibe adjuntos manuales', format($q$ select public.comm_register_attachment_srv('%s', (select name from storage.objects where name like 'messages/%s/%%' limit 1), 'x.png', 'image/png', 10, '%s', '%s', true) $q$,
  (select id from public.comm_messages where system_kind = 'HOJAS_DIA'), (select id from public.comm_messages where system_kind = 'HOJAS_DIA'), repeat('a', 64), :'ADM'), '%MENSAJE_DEL_SISTEMA%');
commit;
select tst.res('HGS-07e reanudado: vuelve a ACTIVO', (select status from public.comm_messages where system_kind = 'HOJAS_DIA') = 'ACTIVO', '');
-- ===== HGS-08 la unicidad por horario sigue valiendo para los comunicados (no para las hojas) =====
begin; set local role service_role;
create temp table u8 as select public.comm_create_run((select id from public.comm_messages where system_kind is null order by created_at limit 1), '2030-01-01 12:00+00', 'PROGRAMADO', false, '[]', '[]', '{}') a,
  public.comm_create_run((select id from public.comm_messages where system_kind is null order by created_at limit 1), '2030-01-01 12:00+00', 'PROGRAMADO', false, '[]', '[]', '{}') b; grant select on u8 to public;
commit;
select tst.res('HGS-08 comunicados: una ejecución por comunicado + horario (la repetición devuelve NULL); hojas: varias al mismo horario',
  (select a is not null and b is null from u8) and (select count(*) from public.comm_runs where kind = 'HOJAS' and scheduled_for = '2026-11-02 20:35+00') >= 2, '');
-- ===== HGS-09 privilegios de lo nuevo o redefinido =====
select tst.res('HGS-09 encolado y verificación: solo el servidor (ni anon ni authenticated)', not has_function_privilege('authenticated', 'public.comm_enqueue_sheet_pdfs(timestamptz)', 'EXECUTE')
  and not has_function_privilege('anon', 'public._comm_sheet_eligible(public.routes)', 'EXECUTE') and not has_function_privilege('authenticated', 'public._comm_sheet_eligible(public.routes)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.comm_enqueue_sheet_pdfs(timestamptz)', 'EXECUTE') and not has_function_privilege('authenticated', 'public.comm_check(bigint,uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.comm_check(bigint,uuid)', 'EXECUTE') and has_function_privilege('service_role', 'public.comm_enqueue_sheet_pdfs(timestamptz)', 'EXECUTE'), '');
