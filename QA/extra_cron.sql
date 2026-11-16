-- SOLO PRUEBAS LOCALES · tarea programada de push y escalamiento (B-W05). cron, net y vault son SIMULADOS solo en esta base local:
-- se ejecuta el comando programado y se registra la llamada HTTP que haría. Ningún envío real.
create temp table cron_checks(name text, ok boolean, detail text);
create schema if not exists cron; create schema if not exists net;
create table if not exists cron.job(jobid serial primary key, jobname text unique, schedule text, command text);
create or replace function cron.schedule(p_name text, p_sched text, p_cmd text) returns bigint language sql as $f$
  insert into cron.job(jobname, schedule, command) values (p_name, p_sched, p_cmd) on conflict (jobname) do update set schedule = excluded.schedule, command = excluded.command returning jobid $f$;
create or replace function cron.unschedule(p_name text) returns boolean language sql as $f$ with d as (delete from cron.job where jobname = p_name returning 1) select exists (select 1 from d) $f$;
create table if not exists net.llamadas(id serial, url text, headers jsonb, body jsonb, timeout int);
create or replace function net.http_post(url text, body jsonb default '{}', params jsonb default '{}', headers jsonb default '{}', timeout_milliseconds int default 5000) returns bigint language sql as $f$
  insert into net.llamadas(url, headers, body, timeout) values (url, headers, body, timeout_milliseconds) returning id $f$;
-- Vault: se usa la simulación de la base de pruebas de Work (vault.secrets / vault.decrypted_secrets / vault.create_secret, como en Supabase)
-- (a) SIN secretos en Vault: no se programa nada
create temp table cron_a(err text);
do $$ begin begin execute pg_read_file('/tmp/okd_cron_test.sql'); insert into cron_a values ('SIN ERROR'); exception when others then insert into cron_a values (sqlerrm); end; end $$;
insert into cron_checks select 'CR-01 sin los secretos en Vault la propuesta se DETIENE con un mensaje claro y NO programa ninguna tarea',
  err like 'FALTAN los secretos%' and (select count(*) from cron.job) = 0, err from cron_a;
-- (b) con secretos: dos tareas, cada minuto; idempotente
select vault.create_secret('https://proyecto-de-prueba.supabase.co', 'okd_project_url', 'prueba'), vault.create_secret('secreto-de-prueba-123', 'okd_push_cron_secret', 'prueba');
-- JWT SINTÉTICO de prueba (no es una credencial real): encabezado.contenido.firma en base64url
create or replace function pg_temp.jwt(payload jsonb) returns text language sql as $f$
  select rtrim(translate(encode(convert_to('{"alg":"HS256","typ":"JWT"}', 'UTF8'), 'base64'), '+/', '-_'), '=') || '.' ||
         rtrim(translate(replace(encode(convert_to(payload::text, 'UTF8'), 'base64'), chr(10), ''), '+/', '-_'), '=') || '.firma-sintetica' $f$;
create or replace function pg_temp.cron_try() returns text language plpgsql as $f$ begin execute pg_read_file('/tmp/okd_cron_test.sql'); return 'SIN ERROR'; exception when others then return sqlerrm; end $f$;
-- (b0) credenciales de gateway INVÁLIDAS: no se programa nada
select vault.create_secret('no-es-un-jwt', 'okd_push_gateway_jwt', 'prueba');
create temp table cron_g as select pg_temp.cron_try() forma;
update vault.secrets set secret = pg_temp.jwt('{"role":"anon","exp":4102444800}') where name = 'okd_push_gateway_jwt';
alter table cron_g add column rol text; update cron_g set rol = pg_temp.cron_try();
update vault.secrets set secret = pg_temp.jwt(jsonb_build_object('role', 'service_role', 'exp', extract(epoch from now())::bigint + 86400)) where name = 'okd_push_gateway_jwt';
alter table cron_g add column vence text; update cron_g set vence = pg_temp.cron_try();
insert into cron_checks select 'CR-07 (N-V5-01) credencial de gateway que NO es un JWT → se DETIENE sin programar', forma like 'CREDENCIAL_DE_GATEWAY_INVALIDA%' and (select count(*) from cron.job) = 0, forma from cron_g;
insert into cron_checks select 'CR-08 (N-V5-01) JWT con role distinto de service_role → se DETIENE sin programar', rol like 'CREDENCIAL_DE_GATEWAY_INVALIDA%service_role%' and (select count(*) from cron.job) = 0, rol from cron_g;
insert into cron_checks select 'CR-09 (N-V5-01) JWT de servicio que vence en menos de 30 días → se DETIENE sin programar', vence like 'CREDENCIAL_DE_GATEWAY_POR_VENCER%' and (select count(*) from cron.job) = 0, vence from cron_g;
update vault.secrets set secret = pg_temp.jwt('{"role":"service_role","exp":4102444800}') where name = 'okd_push_gateway_jwt';
do $$ begin execute pg_read_file('/tmp/okd_cron_test.sql'); execute pg_read_file('/tmp/okd_cron_test.sql'); end $$;
insert into cron_checks select 'CR-02 con los secretos: programa EXACTAMENTE las dos tareas cada minuto (escalamiento y push) y repetir NO las duplica',
  (select count(*) from cron.job) = 2 and (select bool_and(schedule = '* * * * *') from cron.job), (select string_agg(jobname, ', ') from cron.job) from (select 1) z;
-- (c) ejecutar el comando programado del push: la llamada HTTP armada
do $$ begin execute (select command from cron.job where jobname = 'okd-push-notificaciones'); end $$;
insert into cron_checks select 'CR-03 (N-V5-01) la tarea de push llama a <URL de Vault>/functions/v1/push-notifications con las DOS credenciales leídas de Vault: Authorization Bearer <JWT de servicio> (gateway, verify_jwt = true) y x-cron-secret (handler)',
  url = 'https://proyecto-de-prueba.supabase.co/functions/v1/push-notifications' and headers->>'x-cron-secret' = 'secreto-de-prueba-123'
  and headers->>'authorization' = 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'okd_push_gateway_jwt') and headers->>'content-type' = 'application/json' and timeout = 10000,
  url || ' · cabeceras: ' || (select string_agg(k, ', ' order by k) from jsonb_object_keys(headers) k) from net.llamadas order by id desc limit 1;
insert into cron_checks select 'CR-04 el archivo NO contiene secretos ni marcadores (TU-PROYECTO, TU_CRON_SECRET, claves) — los lee de Vault en cada ejecución',
  pg_read_file('/tmp/okd_cron_test.sql') !~ '(TU-PROYECTO|TU_CRON_SECRET|secreto-de-prueba|sb_secret_|eyJ|firma-sintetica)' and pg_read_file('/tmp/okd_cron_test.sql') ~ 'vault\.decrypted_secrets', '' from (select 1) z;
-- (d) ejecutar el comando de escalamiento: invoca la función real del servidor
create temp table cron_e as select (select count(*) from public.com_alarm_events where kind = 'ESCALADA') antes;
update public.com_alarms set escalate_at = now() - interval '1 second' where status = 'PENDIENTE_ATENCION' and escalated_at is null;
do $$ begin execute (select command from cron.job where jobname = 'okd-com-alarma-escalamiento'); end $$;
insert into cron_checks select 'CR-05 la tarea de escalamiento ejecuta com_alarm_escalate_due() real: escala las alarmas vencidas (sin navegador abierto)',
  (select count(*) from public.com_alarm_events where kind in ('ESCALADA', 'ESCALAMIENTO_SIN_DESTINATARIOS')) > (select antes from cron_e)
  and not exists (select 1 from public.com_alarms where status = 'PENDIENTE_ATENCION' and escalated_at is null and escalate_at < now()), '' from (select 1) z;
-- (e) reversión exacta
select cron.unschedule('okd-com-alarma-escalamiento'); select cron.unschedule('okd-push-notificaciones');
insert into cron_checks select 'CR-06 la REVERSIÓN documentada quita ambas tareas y no deja nada programado', (select count(*) from cron.job) = 0, '' from (select 1) z;
