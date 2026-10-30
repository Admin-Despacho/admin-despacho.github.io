-- Pruebas de la PROPUESTA de Comunicaciones (Postgres local). Corre DESPUÉS de g2_revision_test. Datos y usuarios FICTICIOS.
\set ON_ERROR_STOP on
\set ADM 'e0000000-0000-0000-0000-0000000000c1'
\set OPC 'e0000000-0000-0000-0000-0000000000c2'
\set OPN 'e0000000-0000-0000-0000-0000000000c3'
\set A   'e0000000-0000-0000-0000-00000000000a'
insert into auth.users(id, email) values (:'ADM', 'adm.com@ejemplo.test'), (:'OPC', 'opc.com@ejemplo.test'), (:'OPN', 'opn.com@ejemplo.test') on conflict do nothing;
select set_config('okd.sync', 'on', false);
insert into public.profiles(id, full_name, email, role, status) values (:'ADM', 'Admin Com QA', 'adm.com@ejemplo.test', 'SOLO_LECTURA', 'ACTIVO'),
  (:'OPC', 'Operario Com QA', 'opc.com@ejemplo.test', 'SOLO_LECTURA', 'ACTIVO'), (:'OPN', 'Operario Sin QA', 'opn.com@ejemplo.test', 'SOLO_LECTURA', 'ACTIVO') on conflict (id) do nothing;
update public.profiles set role = 'ADMIN' where id = :'ADM'; update public.profiles set role = 'OPERARIO_DEPOSITO' where id in (:'OPC', :'OPN');
select set_config('okd.sync', '', false);

select tst.res('CS-01 seis permisos comms.*; ADMIN los tiene por rol; un Operario NO', (select count(*) from public.permissions where code like 'comms.%') = 6
  and public.user_has_perm(:'ADM', 'comms.gmail_manage') and not public.user_has_perm(:'OPN', 'comms.view'), '');
-- ===== sin permisos: cada operación se rechaza EN EL SERVIDOR =====
begin; select tst.u(:'OPN'); set local role authenticated;
select tst.expect('CS-02a sin permiso: guardar colaborador', $q$ select public.comm_save_collaborator('{"full_name":"X","email":"x@ejemplo.test"}') $q$, 'FORBIDDEN%');
select tst.expect('CS-02b sin permiso: redactar', $q$ select public.comm_save_message('{"internal_name":"X"}') $q$, 'FORBIDDEN%');
select tst.expect('CS-02c sin permiso: estado de Gmail', $q$ select public.comm_gmail_status() $q$, 'FORBIDDEN%');
select tst.expect('CS-02d sin permiso: iniciar conexión Gmail', $q$ select public.comm_oauth_begin() $q$, 'FORBIDDEN%');
select tst.expect('CS-02e funciones del SERVIDOR inaccesibles para un usuario (cola)', $q$ select * from public.comm_claim(5, 'x') $q$, '%permission denied%');
select tst.expect('CS-02f funciones del SERVIDOR inaccesibles para un usuario (token)', $q$ select public.comm_gmail_secret() $q$, '%permission denied%');
select tst.expect('CS-02g la tabla de estado de Gmail no se lee directo', $q$ select * from public.comm_gmail_status $q$, '%permission denied%');
commit;
-- ===== permisos INDIVIDUALES otorgados y revocados =====
begin; select tst.u(:'A'); set local role authenticated;
select public.set_user_permission(:'OPC', 'comms.view', 'GRANT', 'prueba'); select public.set_user_permission(:'OPC', 'comms.collaborators_manage', 'GRANT', 'prueba');
select public.set_user_permission(:'OPC', 'comms.compose', 'GRANT', 'prueba'); commit;
begin; select tst.u(:'OPC'); set local role authenticated;
select public.comm_save_collaborator('{"full_name":"Ana Díaz","email":"ana@ejemplo.test","branch":"Mendoza","sector":"Cobranzas"}');
select public.comm_save_collaborator('{"full_name":"Bruno Paz","email":"bruno@ejemplo.test","branch":"San Juan","sector":"Cobranzas"}');
select public.comm_save_collaborator('{"full_name":"Carla Ruiz","email":"carla@ejemplo.test","branch":"Mendoza","sector":"Depósito"}');
select tst.expect('CS-03a correo duplicado (otra mayúscula) rechazado', $q$ select public.comm_save_collaborator('{"full_name":"Otra","email":"ANA@ejemplo.test"}') $q$, 'CORREO_DUPLICADO%');
select tst.expect('CS-03b correo inválido rechazado', $q$ select public.comm_save_collaborator('{"full_name":"Otra","email":"no-es-correo"}') $q$, 'CORREO_INVALIDO%');
select tst.expect('CS-03c contenido activo (<script>) rechazado por el servidor', $q$ select public.comm_save_message('{"internal_name":"X","body_html":"<p>a</p><script>alert(1)</script>"}') $q$, '%comm_body_safe%');
create temp table m1 as select (public.comm_save_message('{"internal_name":"Normas de cobro","subject":"Recordatorio: normas de cobro","body_html":"<p>Hola <b>equipo</b></p>","selection":{"sectors":["Cobranzas"]},"schedule":{"kind":"WEEKLY","time":"09:00","start_date":"2026-11-01","weekdays":[1]}}')).id;
grant select on m1 to public;
select tst.expect('CS-03d con "redactar" pero SIN "programar": no puede activar', format('select public.comm_activate(%L)', (select id from m1)), 'FORBIDDEN%');
commit;
select tst.res('CS-03e Operario con permisos INDIVIDUALES: creó colaboradores y un borrador (sin cambiar su rol)', (select count(*) from public.comm_collaborators) = 3
  and (select status from public.comm_messages where id = (select id from m1)) = 'BORRADOR' and (select role from public.profiles where id = :'OPC') = 'OPERARIO_DEPOSITO', '');
begin; select tst.u(:'A'); set local role authenticated; select public.set_user_permission(:'OPC', 'comms.compose', 'REVOKE', 'prueba'); commit;
begin; select tst.u(:'OPC'); set local role authenticated;
select tst.expect('CS-03f permiso REVOCADO: ya no puede redactar', $q$ select public.comm_save_message('{"internal_name":"Y"}') $q$, 'FORBIDDEN%');
commit;
-- ===== Gmail: activar exige conexión; el token queda en Vault y nunca se ve =====
begin; select tst.u(:'ADM'); set local role authenticated;
select tst.expect('CS-04a no se puede programar sin Gmail conectado', format('select public.comm_activate(%L)', (select id from m1)), 'GMAIL_NOT_CONNECTED%');
create temp table st1 as select public.comm_oauth_begin() s; grant select on st1 to public;
commit;
begin; set local role service_role;
select tst.res('CS-04b el estado OAuth es de un solo uso y lo consume el servidor', public.comm_oauth_consume((select s from st1)) = :'ADM', '');
select tst.expect('CS-04c un estado OAuth ya usado se rechaza', format('select public.comm_oauth_consume(%L)', (select s from st1)), 'OAUTH_STATE_INVALIDO%');
select public.comm_gmail_store('comunicados.qa@gmail.com', 'TOKEN-SECRETO-QA-1234', :'ADM');
commit;
begin; select tst.u(:'ADM'); set local role authenticated;
select tst.res('CS-04d el estado visible NO contiene el token (solo conexión, cuenta y errores)', public.comm_gmail_status()::text not like '%TOKEN-SECRETO%'
  and (public.comm_gmail_status()->>'connected')::boolean and public.comm_gmail_status()->>'email' = 'comunicados.qa@gmail.com', public.comm_gmail_status()::text);
select tst.expect('CS-04e un usuario NO puede leer Vault', $q$ select * from vault.decrypted_secrets $q$, '%permission denied%');
select public.comm_activate((select id from m1));
commit;
select tst.res('CS-04f el token está en Vault y solo el servidor lo lee', (select public.comm_gmail_secret()) = 'TOKEN-SECRETO-QA-1234'
  and (select status from public.comm_messages where id = (select id from m1)) = 'ACTIVO', '');
-- ===== ejecución idempotente, clave única ejecución + destinatario =====
begin; set local role service_role;
create temp table r1 as select public.comm_create_run((select id from m1), '2026-11-02 12:00+00', 'PROGRAMADO', false,
  '[{"collaborator_id":null,"email":"ana@ejemplo.test","name":"Ana Díaz"},{"collaborator_id":null,"email":"bruno@ejemplo.test","name":"Bruno Paz"},{"collaborator_id":null,"email":"ANA@ejemplo.test","name":"Ana bis"}]',
  '[{"id":null,"name":"Carla Ruiz","reason":"Inactivo"}]', '{"subject":"Recordatorio: normas de cobro","body_html":"<p>Hola <b>equipo</b></p>","attachments":[]}') id;
grant select on r1 to public;
select tst.res('CS-05a la misma ejecución creada por OTRO trabajador no se duplica', public.comm_create_run((select id from m1), '2026-11-02 12:00+00', 'PROGRAMADO', false, '[]', '[]', '{}') is null, '');
commit;
select tst.res('CS-05b un envío por destinatario (sin duplicar el mismo correo) + omitido con motivo', (select count(*) from public.comm_deliveries where run_id = (select id from r1) and status = 'PENDIENTE') = 2
  and (select reason from public.comm_deliveries where run_id = (select id from r1) and status = 'OMITIDO') = 'Inactivo', '');
-- ===== DOS trabajadores realmente simultáneos (dos conexiones) =====
create extension if not exists dblink;
do $$ declare i int; begin for i in 1..8 loop insert into public.comm_deliveries(run_id, email, name) values ((select id from r1), 'p' || i || '@ejemplo.test', 'Persona ' || i); end loop; end $$;
select dblink_connect('w1', 'dbname=' || current_database() || ' port=' || current_setting('port') || ' host=/tmp user=postgres');
select dblink_connect('w2', 'dbname=' || current_database() || ' port=' || current_setting('port') || ' host=/tmp user=postgres');
select dblink_exec('w1', 'begin');
create temp table c1 as select * from dblink('w1', 'select id from public.comm_claim(6, ''A'', now())') as t(id bigint);   -- w1 mantiene su reserva abierta
select dblink_send_query('w2', 'select id from public.comm_claim(6, ''B'', now())');   -- w2 llega MIENTRAS w1 no confirmó (espera la serialización)
select pg_sleep(0.5); select dblink_exec('w1', 'commit');
create temp table c2 as select * from dblink_get_result('w2') as t(id bigint);
select dblink_disconnect('w1'); select dblink_disconnect('w2');
select tst.res('CS-06 dos trabajadores a la vez: reservas DISJUNTAS (ninguno toma el envío del otro) y todas tomadas',
  (select count(*) from c1) = 6 and (select count(*) from c2) = 4 and not exists (select 1 from c1 join c2 using (id)), (select count(*) from c1) || '+' || (select count(*) from c2));
-- ===== verificación antes de enviar, cierre y reintentos =====
create temp table t as select id, claim_token tok, email from public.comm_deliveries where run_id = (select id from r1) and status = 'PROCESANDO'; grant select on t to public;
begin; set local role service_role;
select tst.res('CS-07a verificación OK con el token correcto; con otro token: LOST', public.comm_check((select id from t where email = 'ana@ejemplo.test'), (select tok from t where email = 'ana@ejemplo.test')) = 'OK'
  and public.comm_check((select id from t where email = 'ana@ejemplo.test'), gen_random_uuid()) = 'LOST', '');
select public.comm_finish((select id from t where email = 'ana@ejemplo.test'), (select tok from t where email = 'ana@ejemplo.test'), 'ACCEPTED', 'gm-qa-1');
select public.comm_finish((select id from t where email = 'bruno@ejemplo.test'), (select tok from t where email = 'bruno@ejemplo.test'), 'RETRYABLE', null, '503', 'Gmail no disponible');
select public.comm_finish((select id from t where email = 'p1@ejemplo.test'), (select tok from t where email = 'p1@ejemplo.test'), 'AMBIGUOUS', null, 'AFTER_SEND', 'respuesta perdida');
commit;
select tst.res('CS-07b aceptado guarda el id de Gmail; recuperable con espera; ambiguo queda "Por verificar"',
  (select gmail_message_id from public.comm_deliveries where email = 'ana@ejemplo.test') = 'gm-qa-1'
  and (select status = 'ERROR' and retryable and next_attempt_at > now() from public.comm_deliveries where email = 'bruno@ejemplo.test')
  and (select status from public.comm_deliveries where email = 'p1@ejemplo.test') = 'POR_VERIFICAR', '');
begin; set local role service_role;
select tst.res('CS-07c ni el de espera (antes de tiempo) ni el "Por verificar" se vuelven a tomar', not exists (select 1 from public.comm_claim(50, 'C', now())
  where email in ('bruno@ejemplo.test', 'p1@ejemplo.test')), '');
commit;
-- PAUSA y CANCELACIÓN comprobadas antes de enviar
update public.comm_deliveries set status = 'PENDIENTE', claim_token = null where status = 'PROCESANDO';
begin; set local role service_role; create temp table t2 as select * from public.comm_claim(2, 'D', now()); grant select on t2 to public; commit;
update public.comm_messages set status = 'PAUSADO' where id = (select id from m1);
create temp table t2a as select id, token, attempts from t2 order by id limit 1; grant select on t2a to public;
begin; set local role service_role; create temp table chk8 as select public.comm_check((select id from t2a), (select token from t2a)) r; grant select on chk8 to public; commit;
select tst.res('CS-08a PAUSADO: la verificación previa lo devuelve a pendiente SIN gastar intento', (select r from chk8) = 'PAUSED'
  and (select status = 'PENDIENTE' and attempts = (select attempts from t2a) - 1 from public.comm_deliveries where id = (select id from t2a)), (select r from chk8));
update public.comm_messages set status = 'ACTIVO' where id = (select id from m1);
begin; select tst.u(:'ADM'); set local role authenticated; select public.comm_cancel((select id from m1)); commit;
begin; set local role service_role;
select tst.res('CS-08b CANCELADO: lo que estaba en curso se cancela en la verificación previa; lo pendiente quedó cancelado', public.comm_check((select id from t2 where id <> (select id from t2a)), (select token from t2 where id <> (select id from t2a))) = 'CANCELLED'
  and not exists (select 1 from public.comm_deliveries where run_id = (select id from r1) and status = 'PENDIENTE'), '');
commit;
-- AUTORIZACIÓN y procesamiento interrumpido
update public.comm_messages set status = 'ACTIVO' where id = (select id from m1);
insert into public.comm_deliveries(run_id, email, name) values ((select id from r1), 'auth@ejemplo.test', 'Auth QA'), ((select id from r1), 'caido@ejemplo.test', 'Caído QA');
update public.comm_runs set status = 'EN_CURSO' where id = (select id from r1);
begin; set local role service_role; create temp table t3 as select * from public.comm_claim(2, 'E', now()); grant select on t3 to public;
select public.comm_finish((select id from t3 where email = 'auth@ejemplo.test'), (select token from t3 where email = 'auth@ejemplo.test'), 'AUTH', null, 'invalid_grant', 'Gmail rechazó la autorización');
create temp table chk as select public.comm_check((select id from t3 where email = 'caido@ejemplo.test'), (select token from t3 where email = 'caido@ejemplo.test')) r; grant select on chk to public;
commit;
select tst.res('CS-09a error de AUTORIZACIÓN: error final, "hay que reconectar", y la verificación de los demás NO envía (vuelven a pendiente)',
  (select r from chk) = 'NO_CONNECTION' and (select status = 'ERROR' and not retryable from public.comm_deliveries where email = 'auth@ejemplo.test')
  and (select needs_reconnect from public.comm_gmail_status where id = 1) and (select status from public.comm_deliveries where email = 'caido@ejemplo.test') = 'PENDIENTE', '');
update public.comm_gmail_status set needs_reconnect = false where id = 1;   -- (reconexión simulada)
-- procesamiento interrumpido: un trabajador lo tomó y se cayó → a los 10 min queda "Por verificar", no se reenvía
begin; set local role service_role; create temp table t4 as select * from public.comm_claim(1, 'MUERTO', now() - interval '15 minutes'); grant select on t4 to public; commit;
begin; set local role service_role; create temp table t5 as select * from public.comm_claim(10, 'F', now()); grant select on t5 to public; commit;
select tst.res('CS-09b procesamiento interrumpido: pasa a "Por verificar" y NO lo toma otro trabajador', (select status from public.comm_deliveries where id = (select id from t4)) = 'POR_VERIFICAR'
  and not exists (select 1 from t5 where id = (select id from t4)), '');
begin; select tst.u(:'ADM'); set local role authenticated; select public.comm_resolve_verify((select id from t4), 'REINTENTAR'); commit;
select tst.res('CS-09c "Por verificar" solo vuelve a la cola por decisión MANUAL', (select status from public.comm_deliveries where id = (select id from t4)) = 'PENDIENTE', '');
-- ===== editar un comunicado ACTIVO: confirmación obligatoria; la copia de lo ya ejecutado no cambia =====
begin; select tst.u(:'ADM'); set local role authenticated;
create temp table m2 as select (public.comm_save_message('{"internal_name":"Aviso","subject":"Aviso QA","body_html":"<p>v1</p>","selection":{"all":true},"schedule":{"kind":"DAILY","time":"08:00","start_date":"2026-11-01"}}')).id;
grant select on m2 to public; select public.comm_activate((select id from m2));
commit;
begin; set local role service_role; select public.comm_create_run((select id from m2), '2026-11-03 11:00+00', 'PROGRAMADO', false, '[{"email":"ana@ejemplo.test","name":"Ana"}]', '[]', '{"subject":"Aviso QA","body_html":"<p>v1</p>","attachments":[]}'); commit;
begin; select tst.u(:'ADM'); set local role authenticated;
select tst.expect('CS-10a editar contenido de un comunicado ACTIVO exige confirmación', format($q$ select public.comm_save_message('{"id":"%s","body_html":"<p>v2</p>"}') $q$, (select id from m2)), 'CONFIRMATION_REQUIRED%');
select public.comm_save_message(jsonb_build_object('id', (select id from m2), 'body_html', '<p>v2</p>'), true);
commit;
select tst.res('CS-10b confirmado: el comunicado pasa a v2, la COPIA de la ejecución sigue en v1 y queda auditado', (select body_html from public.comm_messages where id = (select id from m2)) = '<p>v2</p>'
  and (select snapshot->>'body_html' from public.comm_runs where message_id = (select id from m2)) = '<p>v1</p>'
  and exists (select 1 from public.comm_audit where message_id = (select id from m2) and action = 'MODIFICADO' and detail->>'confirmado' = 'true'), '');
-- ===== WhatsApp: registro manual, separado de los correos =====
create temp table before_dl as select count(*) n, string_agg(status, ',' order by id) s from public.comm_deliveries; grant select on before_dl to public;
begin; select tst.u(:'ADM'); set local role authenticated; select public.comm_register_whatsapp((select id from m2), 'Grupo OK Accesorios · Comunicados'); commit;
select tst.res('CS-11 "Registrar como compartido por WhatsApp" guarda usuario y fecha y NO toca ni dispara correos',
  (select count(*) from public.comm_whatsapp_shares where message_id = (select id from m2) and shared_by = :'ADM' and shared_at is not null) = 1
  and (select count(*) n from public.comm_deliveries) = (select n from before_dl) and (select string_agg(status, ',' order by id) from public.comm_deliveries) = (select s from before_dl), '');
-- ===== adjuntos: almacenamiento privado y registro SOLO del servidor (contenido validado por la función comm-attachments) =====
begin; select tst.u(:'OPN'); set local role authenticated;
select tst.expect('CS-12a sin permiso no puede subir al almacenamiento privado', format($q$ insert into storage.objects(bucket_id, name) values ('comm-attachments', 'messages/%s/%s.png') $q$, (select id from m2), gen_random_uuid()), '%row-level security%');
commit;
begin; select tst.u(:'ADM'); set local role authenticated;
select tst.expect('CS-12b ruta fuera de la carpeta del comunicado rechazada', $q$ insert into storage.objects(bucket_id, name) values ('comm-attachments', 'otra/../x.png') $q$, '%row-level security%');
select tst.expect('CS-12c un USUARIO no puede registrar adjuntos directamente (solo el servidor, que valida el contenido)', format($q$ select public.comm_register_attachment_srv('%s', 'x', 'x', 'application/pdf', 1, '%s', '%s', true) $q$, (select id from m2), repeat('a', 64), :'ADM'), '%permission denied%');
commit;
-- borrador nuevo para las cargas: 1 MB ya registrado
begin; select tst.u(:'ADM'); set local role authenticated;
create temp table m3 as select (public.comm_save_message('{"internal_name":"Adjuntos QA","subject":"Adjuntos","body_html":"<p>a</p>","selection":{"all":true},"schedule":{"kind":"DAILY","time":"08:00","start_date":"2026-11-01"}}')).id;
grant select on m3 to public; commit;
create temp table up as select gen_random_uuid() k1, gen_random_uuid() k2, gen_random_uuid() k3, gen_random_uuid() k4; grant select on up to public;
insert into storage.objects(bucket_id, name, metadata) select 'comm-attachments', 'messages/' || (select id from m3) || '/' || k || '.pdf', jsonb_build_object('size', sz)
  from (values ((select k1 from up), 1000000), ((select k2 from up), 7500000), ((select k3 from up), 7500000), ((select k4 from up), 9000000)) v(k, sz);
begin; set local role service_role;
select public.comm_register_attachment_srv((select id from m3), 'messages/' || (select id from m3) || '/' || (select k1 from up) || '.pdf', 'base.pdf', 'application/pdf', 1000000, repeat('a', 64), :'ADM', false);
select tst.expect('CS-12d tamaño distinto del registrado por el almacenamiento: rechazado', format($q$ select public.comm_register_attachment_srv('%s', 'messages/%s/%s.pdf', 'x.pdf', 'application/pdf', 100, '%s', '%s', false) $q$,
  (select id from m3), (select id from m3), (select k4 from up), repeat('d', 64), :'ADM'), 'TAMANIO_INCONSISTENTE%');
select tst.expect('CS-12e más de 8 MB: rechazado', format($q$ select public.comm_register_attachment_srv('%s', 'messages/%s/%s.pdf', 'x.pdf', 'application/pdf', 9000000, '%s', '%s', false) $q$,
  (select id from m3), (select id from m3), (select k4 from up), repeat('d', 64), :'ADM'), '%comm_attachments_size_bytes_check%');
select tst.expect('CS-12f tipo no permitido: rechazado', format($q$ select public.comm_register_attachment_srv('%s', 'messages/%s/%s.pdf', 'x.exe', 'application/x-msdownload', 7500000, '%s', '%s', false) $q$,
  (select id from m3), (select id from m3), (select k2 from up), repeat('e', 64), :'ADM'), '%comm_attachments_mime_check%');
commit;
-- ===== CS-15: DOS cargas simultáneas (7,5 MB + 7,5 MB sobre 1 MB = 16 MB > 15 MB): SOLO una entra (bloqueo de la fila del comunicado) =====
select dblink_connect('a1', 'dbname=' || current_database() || ' port=' || current_setting('port') || ' host=/tmp user=postgres');
select dblink_connect('a2', 'dbname=' || current_database() || ' port=' || current_setting('port') || ' host=/tmp user=postgres');
select dblink_exec('a1', 'begin');
select * from dblink('a1', format($q$ select (public.comm_register_attachment_srv('%s', 'messages/%s/%s.pdf', 'uno.pdf', 'application/pdf', 7500000, '%s', '%s', false)).id::text $q$,
  (select id from m3), (select id from m3), (select k2 from up), repeat('b', 64), :'ADM')) as t(x text);
select dblink_send_query('a2', format($q$ select (public.comm_register_attachment_srv('%s', 'messages/%s/%s.pdf', 'dos.pdf', 'application/pdf', 7500000, '%s', '%s', false)).id::text $q$,
  (select id from m3), (select id from m3), (select k3 from up), repeat('c', 64), :'ADM'));   -- queda ESPERANDO el bloqueo
select pg_sleep(0.5); select dblink_exec('a1', 'commit');
create temp table a2r as select coalesce((select string_agg(x, ',') from dblink_get_result('a2', false) as t(x text)), '') || dblink_error_message('a2') e; grant select on a2r to public;
select dblink_disconnect('a1'); select dblink_disconnect('a2');
select tst.res('CS-15 dos cargas SIMULTÁNEAS: una entra y la otra se rechaza por el límite acumulado (bloqueo de fila)', (select count(*) from public.comm_attachments where message_id = (select id from m3) and not detached) = 2
  and (select sum(size_bytes) from public.comm_attachments where message_id = (select id from m3)) = 8500000, (select e from a2r));
-- ===== CS-16: agregar/quitar adjuntos de un comunicado ACTIVO: confirmación, versión, auditoría y copias históricas intactas =====
insert into storage.objects(bucket_id, name, metadata) values ('comm-attachments', 'messages/' || (select id from m2) || '/' || (select k1 from up) || '.png', '{"size":2000}');
create temp table v0 as select version, (select snapshot::text from public.comm_runs where message_id = (select id from m2) order by created_at limit 1) snap from public.comm_messages where id = (select id from m2); grant select on v0 to public;
begin; set local role service_role;
select tst.expect('CS-16a agregar un adjunto a un comunicado PROGRAMADO sin confirmar: rechazado', format($q$ select public.comm_register_attachment_srv('%s', 'messages/%s/%s.png', 'i.png', 'image/png', 2000, '%s', '%s', false) $q$,
  (select id from m2), (select id from m2), (select k1 from up), repeat('f', 64), :'ADM'), 'CONFIRMATION_REQUIRED%');
create temp table att16 as select (public.comm_register_attachment_srv((select id from m2), 'messages/' || (select id from m2) || '/' || (select k1 from up) || '.png', 'i.png', 'image/png', 2000, repeat('f', 64), :'ADM', true)).id; grant select on att16 to public;
commit;
begin; select tst.u(:'ADM'); set local role authenticated;
select tst.expect('CS-16b quitar un adjunto de un comunicado PROGRAMADO sin confirmar: rechazado', format('select public.comm_detach_attachment(%L)', (select id from att16)), 'CONFIRMATION_REQUIRED%');
select public.comm_detach_attachment((select id from att16), true);
commit;
select tst.res('CS-16c confirmados: versión +2, auditados (con "confirmado") y la COPIA de la ejecución anterior intacta',
  (select version from public.comm_messages where id = (select id from m2)) = (select version from v0) + 2
  and (select count(*) from public.comm_audit where message_id = (select id from m2) and entity = 'ADJUNTO' and detail->>'confirmado' = 'true') = 2
  and (select snapshot::text from public.comm_runs where message_id = (select id from m2) order by created_at limit 1) = (select snap from v0), '');
-- ===== CS-17: vencimiento de pendientes ya encolados (también al reanudar) =====
begin; set local role service_role;
create temp table r17 as select public.comm_create_run((select id from m2), now() - interval '7 hours', 'PROGRAMADO', false, '[{"email":"vencido@ejemplo.test","name":"Vencido QA"}]', '[]', '{"subject":"s","body_html":"b","attachments":[]}') id;
grant select on r17 to public;
create temp table c17 as select * from public.comm_claim(50, 'G', now()); grant select on c17 to public;
commit;
select tst.res('CS-17a un pendiente de hace 7 h NO se reserva: queda VENCIDO, para revisión y en el historial', not exists (select 1 from c17 where email = 'vencido@ejemplo.test')
  and (select status from public.comm_deliveries where email = 'vencido@ejemplo.test') = 'VENCIDO'
  and (select reason from public.comm_deliveries where email = 'vencido@ejemplo.test') like 'Vencido:%Queda para revisión%', '');
update public.comm_deliveries set status = 'PENDIENTE', claim_token = null where status = 'PROCESANDO';
begin; select tst.u(:'ADM'); set local role authenticated; select public.comm_resolve_verify((select id from public.comm_deliveries where email = 'vencido@ejemplo.test'), 'REINTENTAR'); commit;
begin; set local role service_role; create temp table c17b as select * from public.comm_claim(50, 'H', now()); grant select on c17b to public; commit;
select tst.res('CS-17b un VENCIDO solo se reserva tras la habilitación MANUAL', exists (select 1 from c17b where email = 'vencido@ejemplo.test'), '');
-- ===== CS-18: registro TARDÍO de una aceptación (el trabajo ya figuraba "Por verificar") =====
update public.comm_deliveries set status = 'PENDIENTE', claim_token = null where status = 'PROCESANDO';
insert into public.comm_deliveries(run_id, email, name) values ((select id from r1), 'tardio@ejemplo.test', 'Tardío QA');
update public.comm_messages set status = 'ACTIVO' where id = (select id from m1);
begin; set local role service_role; create temp table c18 as select * from public.comm_claim(50, 'I', now() - interval '20 minutes') where email = 'tardio@ejemplo.test'; grant select on c18 to public; commit;
begin; set local role service_role; select public.comm_claim(0, 'J', now()); select public.comm_finish((select id from c18), (select token from c18), 'ACCEPTED', 'gm-tardio-1'); commit;
select tst.res('CS-18 Gmail aceptó y el registro llegó TARDE (ya "Por verificar"): queda ENVIADO con su id, sin reenvío', (select status = 'ENVIADO' and gmail_message_id = 'gm-tardio-1' from public.comm_deliveries where email = 'tardio@ejemplo.test'), '');
-- ===== CS-14: CUPO diario con DOS conexiones simultáneas (y envíos de PRUEBA) =====
update public.comm_deliveries set status = 'CANCELADO' where status in ('PENDIENTE','PROCESANDO','ERROR');
insert into public.comm_deliveries(run_id, email, name) select (select id from r1), 'cupo' || i || '@ejemplo.test', 'Cupo ' || i from generate_series(1, 4) i;
create temp table used0 as select count(*) filter (where status = 'ENVIADO' and sent_at > now() - interval '24 hours') + count(*) filter (where status = 'POR_VERIFICAR') n from public.comm_deliveries; grant select on used0 to public;
select dblink_connect('q1', 'dbname=' || current_database() || ' port=' || current_setting('port') || ' host=/tmp user=postgres');
select dblink_connect('q2', 'dbname=' || current_database() || ' port=' || current_setting('port') || ' host=/tmp user=postgres');
select dblink_exec('q1', 'begin');
create temp table q1r as select * from dblink('q1', format('select id from public.comm_claim(5, ''A'', now(), %s)', (select n + 1 from used0))) as t(id bigint);
select dblink_send_query('q2', format('select id from public.comm_claim(5, ''B'', now(), %s)', (select n + 1 from used0)));   -- espera el bloqueo de la reserva
select pg_sleep(0.5); select dblink_exec('q1', 'commit');
create temp table q2r as select * from dblink_get_result('q2') as t(id bigint);
select dblink_disconnect('q1'); select dblink_disconnect('q2');
select tst.res('CS-14a cupo = 1 con DOS trabajadores SIMULTÁNEOS: se reserva UN solo envío', (select count(*) from q1r) + (select count(*) from q2r) = 1, (select count(*) from q1r) || '+' || (select count(*) from q2r));
begin; select tst.u(:'ADM'); set local role authenticated; select public.comm_request_test((select id from m2), 'prueba.cupo@ejemplo.test'); commit;
begin; set local role service_role;
select tst.res('CS-14b con el cupo ocupado (incluye lo EN CURSO), tampoco sale un envío de PRUEBA', not exists (select 1 from public.comm_claim(5, 'C', now(), (select n + 1 from used0)::int)), '');
commit;
-- ===== CS-13: PRIVILEGIOS efectivos con los privilegios por defecto de PRODUCCIÓN =====
create table public.zz_sonda_privilegios(x int);
select tst.res('CS-13a la simulación de privilegios por defecto funciona: una tabla AJENA nueva hereda TRUNCATE para anon', has_table_privilege('anon', 'public.zz_sonda_privilegios', 'TRUNCATE'), '');
drop table public.zz_sonda_privilegios;
create temp table privs as select c.relname, r.rol, p.priv, has_table_privilege(r.rol, 'public.' || c.relname, p.priv) ok
  from pg_class c cross join (values ('anon'), ('authenticated')) r(rol) cross join (values ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE'), ('REFERENCES'), ('TRIGGER')) p(priv)
  where c.relnamespace = 'public'::regnamespace and c.relkind = 'r' and c.relname like 'comm\_%';
grant select on privs to public;
select tst.res('CS-13b tablas nuevas: anon SIN ningún privilegio; authenticated SOLO SELECT (y nada sobre estado de Gmail ni estados OAuth)',
  not exists (select 1 from privs where ok and (rol = 'anon' or priv <> 'SELECT' or relname in ('comm_gmail_status','comm_oauth_states')))
  and (select count(*) from privs where ok) = 8, (select string_agg(relname || ':' || rol || ':' || priv, ',') from privs where ok and (rol = 'anon' or priv <> 'SELECT')));
select tst.res('CS-13c secuencias nuevas: sin USAGE/SELECT/UPDATE para anon ni authenticated', not exists (select 1 from pg_class c cross join (values ('anon'), ('authenticated')) r(rol) cross join (values ('USAGE'), ('SELECT'), ('UPDATE')) p(priv)
  where c.relnamespace = 'public'::regnamespace and c.relkind = 'S' and c.relname like 'comm\_%' and has_sequence_privilege(r.rol, 'public.' || c.relname, p.priv)), '');
select tst.res('CS-13d funciones nuevas: anon no ejecuta NINGUNA; authenticated no ejecuta las del servidor ni las auxiliares',
  not exists (select 1 from pg_proc f where f.pronamespace = 'public'::regnamespace and (f.proname like 'comm\_%' or f.proname like '\_comm\_%') and has_function_privilege('anon', f.oid, 'EXECUTE'))
  and not exists (select 1 from pg_proc f where f.pronamespace = 'public'::regnamespace and f.proname in ('comm_claim','comm_check','comm_finish','comm_release','comm_create_run','comm_gmail_secret','comm_gmail_store',
    'comm_gmail_clear','comm_gmail_mark','comm_oauth_consume','comm_register_attachment_srv','comm_list_active_messages','comm_list_collaborators_all','comm_advance_cursor','comm_sent_last24h',
    'comm_record_dispatch','_comm_settle_run','_comm_need','_comm_audit') and has_function_privilege('authenticated', f.oid, 'EXECUTE')),
  (select string_agg(f.proname, ',') from pg_proc f where f.pronamespace = 'public'::regnamespace and (f.proname like 'comm\_%' or f.proname like '\_comm\_%') and has_function_privilege('anon', f.oid, 'EXECUTE')));
-- ===== CS-19 (Codex): confirmado a mano SIGUE contando en el cupo; hora de envío estimada y confirmación por separado =====
update public.comm_deliveries set status = 'CANCELADO' where status in ('PENDIENTE','PROCESANDO','ERROR');
update public.comm_messages set status = 'ACTIVO' where id = (select id from m2);
begin; set local role service_role;
create temp table r19 as select public.comm_create_run((select id from m2), now() + interval '1 minute', 'PROGRAMADO', false, '[{"email":"cupo19a@ejemplo.test","name":"A"},{"email":"cupo19b@ejemplo.test","name":"B"}]', '[]', '{"subject":"s","body_html":"b","attachments":[]}') id;
grant select on r19 to public; commit;
create temp table used19 as select count(*) filter (where status = 'ENVIADO' and coalesce(sent_at, claimed_at, confirmed_at) > now() - interval '24 hours') + count(*) filter (where status = 'PROCESANDO')
  + count(*) filter (where status = 'POR_VERIFICAR' and coalesce(claimed_at, updated_at) > now() - interval '24 hours') n from public.comm_deliveries; grant select on used19 to public;
begin; set local role service_role;
create temp table c19 as select * from public.comm_claim(5, 'X', now(), (select n + 1 from used19)::int); grant select on c19 to public;
select public.comm_finish((select id from c19), (select token from c19), 'AMBIGUOUS', null, 'AFTER_SEND', 'respuesta perdida');
commit;
begin; select tst.u(:'ADM'); set local role authenticated; select public.comm_resolve_verify((select id from c19), 'CONFIRMADO_ENVIADO'); commit;
select tst.res('CS-19a confirmado a mano: ENVIADO con hora ESTIMADA (inicio del intento), confirmación aparte (quién y cuándo)',
  (select status = 'ENVIADO' and sent_at = claimed_at and sent_at_source = 'ESTIMADA_INICIO_INTENTO' and confirmed_by = :'ADM' and confirmed_at >= claimed_at
     from public.comm_deliveries where id = (select id from c19)), '');
select dblink_connect('k1', 'dbname=' || current_database() || ' port=' || current_setting('port') || ' host=/tmp user=postgres');
select dblink_connect('k2', 'dbname=' || current_database() || ' port=' || current_setting('port') || ' host=/tmp user=postgres');
select dblink_send_query('k1', format('select id from public.comm_claim(5, ''K1'', now(), %s)', (select n + 1 from used19)));
select dblink_send_query('k2', format('select id from public.comm_claim(5, ''K2'', now(), %s)', (select n + 1 from used19)));
create temp table k as select * from dblink_get_result('k1') as t(id bigint) union all select * from dblink_get_result('k2') as t(id bigint);
select dblink_disconnect('k1'); select dblink_disconnect('k2');
select tst.res('CS-19b el confirmado SIGUE ocupando el cupo: dos trabajadores simultáneos NO sacan un segundo correo', (select count(*) from k) = 0
  and (select status from public.comm_deliveries where email = 'cupo19b@ejemplo.test') = 'PENDIENTE', (select count(*) from k)::text);
-- ===== CS-20: registro de adjuntos IDEMPOTENTE (repetición y dos solicitudes simultáneas) =====
begin; select tst.u(:'ADM'); set local role authenticated;
create temp table m4 as select (public.comm_save_message('{"internal_name":"Idempotencia QA","subject":"I","body_html":"<p>i</p>","selection":{"all":true},"schedule":{"kind":"DAILY","time":"08:00","start_date":"2026-11-01"}}')).id;
grant select on m4 to public; commit;
create temp table p4 as select 'messages/' || (select id from m4) || '/' || gen_random_uuid() || '.png' a, 'messages/' || (select id from m4) || '/' || gen_random_uuid() || '.png' b; grant select on p4 to public;
insert into storage.objects(bucket_id, name, metadata) values ('comm-attachments', (select a from p4), '{"size":3000}'), ('comm-attachments', (select b from p4), '{"size":4000}');
begin; set local role service_role;
create temp table x1 as select (public.comm_register_attachment_srv((select id from m4), (select a from p4), 'a.png', 'image/png', 3000, repeat('1', 64), :'ADM', false)).id; grant select on x1 to public;
commit;
create temp table st20 as select version, (select count(*) from public.comm_audit where message_id = (select id from m4)) aud from public.comm_messages where id = (select id from m4); grant select on st20 to public;
begin; set local role service_role;
create temp table x2 as select (public.comm_register_attachment_srv((select id from m4), (select a from p4), 'a.png', 'image/png', 3000, repeat('1', 64), :'ADM', false)).id; grant select on x2 to public;
select tst.expect('CS-20b la MISMA ruta con OTRO contenido (hash distinto): rechazada, sin tocar el registrado', format($q$ select public.comm_register_attachment_srv('%s', '%s', 'a.png', 'image/png', 3000, '%s', '%s', false) $q$,
  (select id from m4), (select a from p4), repeat('2', 64), :'ADM'), 'RUTA_YA_REGISTRADA%');
commit;
select tst.res('CS-20a REPETIR devuelve el MISMO adjunto: sin duplicar, sin cambiar la versión ni volver a auditar', (select id from x1) = (select id from x2)
  and (select count(*) from public.comm_attachments where storage_path = (select a from p4)) = 1
  and (select version from public.comm_messages where id = (select id from m4)) = (select version from st20)
  and (select count(*) from public.comm_audit where message_id = (select id from m4)) = (select aud from st20), '');
select dblink_connect('s1', 'dbname=' || current_database() || ' port=' || current_setting('port') || ' host=/tmp user=postgres');
select dblink_connect('s2', 'dbname=' || current_database() || ' port=' || current_setting('port') || ' host=/tmp user=postgres');
select dblink_exec('s1', 'begin');
create temp table y1 as select * from dblink('s1', format($q$ select (public.comm_register_attachment_srv('%s', '%s', 'b.png', 'image/png', 4000, '%s', '%s', false)).id::text $q$,
  (select id from m4), (select b from p4), repeat('3', 64), :'ADM')) as t(id text);
select dblink_send_query('s2', format($q$ select (public.comm_register_attachment_srv('%s', '%s', 'b.png', 'image/png', 4000, '%s', '%s', false)).id::text $q$,
  (select id from m4), (select b from p4), repeat('3', 64), :'ADM'));   -- espera el bloqueo de la fila del comunicado
select pg_sleep(0.4); select dblink_exec('s1', 'commit');
create temp table y2 as select * from dblink_get_result('s2') as t(id text);
select dblink_disconnect('s1'); select dblink_disconnect('s2');
select tst.res('CS-20c dos solicitudes SIMULTÁNEAS con la misma ruta: UN solo registro y ambas reciben el mismo adjunto', (select id from y1) = (select id from y2)
  and (select count(*) from public.comm_attachments where storage_path = (select b from p4)) = 1, '');
-- ===== CS-21: limpieza SOLO de huérfanos reales (sin referencias y antiguos) =====
begin; select tst.u(:'ADM'); set local role authenticated; select public.comm_detach_attachment((select id from x1)); select public.comm_duplicate_message((select id from m4)); commit;
create temp table o21 as select 'messages/' || (select id from m4) || '/' || gen_random_uuid() || '.png' viejo, 'messages/' || (select id from m4) || '/' || gen_random_uuid() || '.png' nuevo; grant select on o21 to public;
insert into storage.objects(bucket_id, name, metadata, created_at) values ('comm-attachments', (select viejo from o21), '{"size":10}', now() - interval '2 days'), ('comm-attachments', (select nuevo from o21), '{"size":10}', now());
update storage.objects set created_at = now() - interval '2 days' where name in ((select a from p4), (select b from p4));
begin; set local role service_role; create temp table orf as select * from public.comm_orphan_objects(24, 100) n; grant select on orf to public; commit;
select tst.res('CS-21 huérfanos: solo el objeto ANTIGUO sin referencias; nunca uno registrado, QUITADO, COPIADO en otro comunicado ni reciente',
  (select array_agg(n) from orf where n like 'messages/' || (select id from m4) || '/%') = array[(select viejo from o21)], (select string_agg(n, ',') from orf));
-- ===== CS-22: limitador COMPARTIDO con dos conexiones simultáneas (6.000 unidades/min; 200 unidades/s) =====
delete from public.comm_rate_events;
select dblink_connect('l1', 'dbname=' || current_database() || ' port=' || current_setting('port') || ' host=/tmp user=postgres');
select dblink_connect('l2', 'dbname=' || current_database() || ' port=' || current_setting('port') || ' host=/tmp user=postgres');
select dblink_send_query('l1', 'select count(*) from generate_series(1, 45) g where (public.comm_rate_acquire(100, 6000, 1000000)->>''wait_ms'')::int = 0');
select dblink_send_query('l2', 'select count(*) from generate_series(1, 45) g where (public.comm_rate_acquire(100, 6000, 1000000)->>''wait_ms'')::int = 0');
create temp table g60 as select * from dblink_get_result('l1') as t(n bigint) union all select * from dblink_get_result('l2') as t(n bigint);
select dblink_disconnect('l1'); select dblink_disconnect('l2');   -- (conexiones nuevas para la segunda medición)
delete from public.comm_rate_events;
select dblink_connect('l3', 'dbname=' || current_database() || ' port=' || current_setting('port') || ' host=/tmp user=postgres');
select dblink_connect('l4', 'dbname=' || current_database() || ' port=' || current_setting('port') || ' host=/tmp user=postgres');
select dblink_send_query('l3', 'select count(*) from generate_series(1, 10) g where (public.comm_rate_acquire(100, 6000, 200)->>''wait_ms'')::int = 0');
select dblink_send_query('l4', 'select count(*) from generate_series(1, 10) g where (public.comm_rate_acquire(100, 6000, 200)->>''wait_ms'')::int = 0');
create temp table g1 as select * from dblink_get_result('l3') as t(n bigint) union all select * from dblink_get_result('l4') as t(n bigint);
select dblink_disconnect('l3'); select dblink_disconnect('l4');
select tst.res('CS-22a dos trabajadores simultáneos: como máximo 60 envíos (6.000 unidades) en 60 s', (select sum(n) from g60) = 60, (select sum(n)::text from g60));
select tst.res('CS-22b y como máximo 2 envíos (200 unidades) en el mismo segundo', (select sum(n) from g1) = 2, (select sum(n)::text from g1));
select tst.res('CS-22c el limitador no es accesible para usuarios (solo el servidor)', not has_function_privilege('authenticated', 'public.comm_rate_acquire(int,int,int)', 'EXECUTE')
  and not has_table_privilege('authenticated', 'public.comm_rate_events', 'SELECT') and not has_table_privilege('anon', 'public.comm_rate_events', 'TRUNCATE'), '');
-- ===== CS-23: una reserva de velocidad se DEVUELVE exactamente (envío interrumpido antes de llamar a Gmail) =====
delete from public.comm_rate_events;
begin; set local role service_role;
create temp table rv as select public.comm_rate_acquire(100, 6000, 1000000) a, public.comm_rate_acquire(100, 6000, 1000000) b; grant select on rv to public;
select public.comm_rate_refund(((select a from rv)->>'event_id')::bigint);
commit;
select tst.res('CS-23 el limitador devuelve el id de lo reservado y comm_rate_refund libera SOLO esa reserva (la otra sigue contando)',
  ((select a from rv)->>'wait_ms')::int = 0 and (select count(*) from public.comm_rate_events) = 1
  and exists (select 1 from public.comm_rate_events where id = ((select b from rv)->>'event_id')::bigint)
  and not has_function_privilege('authenticated', 'public.comm_rate_refund(bigint)', 'EXECUTE'), '');
