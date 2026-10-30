-- =====================================================================================================================
-- PROPUESTA · NO APLICADA · Programador PROPIO de Comunicaciones (no toca ni activa los otros correos de Despacho).
-- Llama al despachador cada 5 minutos con el encabezado secreto x-comm-cron. Requiere pg_cron y pg_net (extensiones de Supabase).
-- Reemplazar <PROJECT_REF> antes de ejecutar. El secreto se guarda en Vault (no queda escrito en el trabajo programado).
-- =====================================================================================================================
create extension if not exists pg_cron;
create extension if not exists pg_net;

-- 1) Guardar el secreto del programador en Vault (el MISMO valor que el secreto COMM_CRON_SECRET de la función):
--    select vault.create_secret('<VALOR_LARGO_ALEATORIO>', 'comm_cron_secret', 'Comunicaciones: secreto del programador');

-- 2) Programar (cada 5 minutos). Nombre propio: no reemplaza ni modifica otros trabajos.
select cron.schedule('okd-comunicaciones-despachador', '*/5 * * * *', $job$
  select net.http_post(
    url := 'https://<PROJECT_REF>.supabase.co/functions/v1/comm-dispatcher',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-comm-cron', (select decrypted_secret from vault.decrypted_secrets where name = 'comm_cron_secret')),
    body := '{}'::jsonb, timeout_milliseconds := 60000);
$job$);

-- Verificar:   select jobid, jobname, schedule, active from cron.job where jobname = 'okd-comunicaciones-despachador';
-- Últimas:     select status, return_message, start_time from cron.job_run_details where jobid = (select jobid from cron.job where jobname = 'okd-comunicaciones-despachador') order by start_time desc limit 5;
-- Detener:     select cron.unschedule('okd-comunicaciones-despachador');
