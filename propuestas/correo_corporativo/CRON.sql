-- PROPUESTO: aplicar solo después de certificar gateway, SMTP/Auth nativo y despliegue de los cuatro componentes.
-- Gmail/Resend siguen activos si el selector está en LEGACY. No se cambia el cron existente de Comunicaciones.
BEGIN;
CREATE FUNCTION public.comm_smtp_tick() RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE gateway text;commsecret text;othersecret text;action text;root text:='https://uqwilzzeyfuatlmwzxna.supabase.co/functions/v1/';
BEGIN
 IF public.comm_mail_runtime()->>'provider'<>'SMTP' OR NOT coalesce((public.comm_mail_runtime()->>'connected')::boolean,false) THEN RETURN;END IF;
 SELECT decrypted_secret INTO gateway FROM vault.decrypted_secrets WHERE name='okd_push_gateway_jwt';
 SELECT decrypted_secret INTO commsecret FROM vault.decrypted_secrets WHERE name='comm_cron_secret';
 SELECT decrypted_secret INTO othersecret FROM vault.decrypted_secrets WHERE name='okd_cron_secret';
 IF coalesce(gateway,'')='' OR coalesce(commsecret,'')='' OR coalesce(othersecret,'')='' THEN RAISE EXCEPTION 'MAIL_CRON_CONFIGURATION_MISSING';END IF;
 PERFORM net.http_post(url:=root||'comm-dispatcher',headers:=jsonb_build_object('Authorization','Bearer '||gateway,'Content-Type','application/json','x-comm-cron',commsecret,'x-mail-smtp-only','1'),body:='{}'::jsonb,timeout_milliseconds:=140000);
 FOREACH action IN ARRAY ARRAY['send_queued','send_customer_queued','send_sheet_emails','send_inspection_emails','send_service_alerts'] LOOP
  PERFORM net.http_post(url:=root||'internal-approvals',headers:=jsonb_build_object('Authorization','Bearer '||gateway,'Content-Type','application/json','x-cron-secret',othersecret),body:=jsonb_build_object('action',action),timeout_milliseconds:=140000);
 END LOOP;
 PERFORM net.http_post(url:=root||'commercial-reports',headers:=jsonb_build_object('Authorization','Bearer '||gateway,'Content-Type','application/json','x-cron-secret',othersecret),body:='{"action":"drain_corporate"}'::jsonb,timeout_milliseconds:=140000);
 IF extract(minute FROM now())::int%15=0 THEN
  PERFORM net.http_post(url:=root||'commercial-reports',headers:=jsonb_build_object('Authorization','Bearer '||gateway,'Content-Type','application/json','x-cron-secret',othersecret),body:='{"action":"scheduled"}'::jsonb,timeout_milliseconds:=140000);
 END IF;
END;$$;
REVOKE ALL ON FUNCTION public.comm_smtp_tick() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.comm_smtp_tick() TO service_role;
SELECT cron.schedule('okd-corporate-mail','* * * * *','select public.comm_smtp_tick()');
COMMIT;
