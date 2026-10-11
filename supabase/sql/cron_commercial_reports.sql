-- Programación del informe de Cristian Torres (ejecutar UNA vez en el SQL Editor del proyecto real).
-- Requiere las extensiones pg_cron y pg_net (Database → Extensions) y el secreto CRON_SECRET
-- cargado también en la Edge Function. El cron corre cada 15 minutos; la función decide si corresponde
-- el semanal (sábado 15:00 Mendoza) o el mensual (último día del mes, hora configurable) y no duplica envíos.
select cron.schedule(
  'okd-commercial-reports',
  '*/15 * * * *',
  $$ select net.http_post(
       url := 'https://TU-PROYECTO.supabase.co/functions/v1/commercial-reports',
       headers := jsonb_build_object('content-type', 'application/json', 'x-cron-secret', 'TU_CRON_SECRET'),
       body := jsonb_build_object('action', 'scheduled')
     ); $$
);

-- RC1: colas de emails de rutas internas y de clientes (cada 5 minutos; idempotentes)
select cron.schedule('okd-internal-approvals', '*/5 * * * *',
  $$ select net.http_post(url := 'https://TU-PROYECTO.supabase.co/functions/v1/internal-approvals',
       headers := jsonb_build_object('content-type','application/json','x-cron-secret','TU_CRON_SECRET'), body := jsonb_build_object('action','send_queued')); $$);
select cron.schedule('okd-customer-emails', '*/5 * * * *',
  $$ select net.http_post(url := 'https://TU-PROYECTO.supabase.co/functions/v1/internal-approvals',
       headers := jsonb_build_object('content-type','application/json','x-cron-secret','TU_CRON_SECRET'), body := jsonb_build_object('action','send_customer_queued')); $$);
