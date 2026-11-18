-- =====================================================================================================================
-- REVERSIÓN · CORREOS DE AUTORIZACIONES CON DETALLE (20261202000100). NO APLICADA. UNA transacción.
-- ANTES: volver a desplegar comm-dispatcher con el código del commit base (2a8e65b) para que nada llame a las funciones nuevas.
-- Conserva: la bandeja com_decision_mail_outbox (estados, intentos, fechas) y la auditoría; los SENT nunca se reenvían.
-- Restaura EXACTAMENTE comm_smtp_claim y com_mail_settings_get publicados (texto de INSTALL.sql) y quita el cupo diario.
-- Se pierde solo la foto por evento (com_decision_mail_payloads); el historial de eventos de la solicitud no se toca.
-- =====================================================================================================================
BEGIN;
SET LOCAL lock_timeout = '5s'; SET LOCAL statement_timeout = '60s';
DO $guard$ BEGIN
  IF to_regclass('public.com_decision_mail_payloads') IS NULL THEN RAISE EXCEPTION 'NO_APLICADA: no hay nada que revertir. No se modificó nada.'; END IF;
  IF EXISTS (SELECT 1 FROM public.com_decision_mail_outbox WHERE state = 'PROCESSING') THEN
    RAISE EXCEPTION 'TRABAJADOR_ACTIVO: hay correos en PROCESSING. Reintentar en 2 minutos. No se modificó nada.'; END IF;
  IF EXISTS (SELECT 1 FROM public.comm_smtp_ledger WHERE state = 'PROCESSING') THEN
    RAISE EXCEPTION 'TRABAJADOR_ACTIVO: hay envíos SMTP en curso. Reintentar en 2 minutos. No se modificó nada.'; END IF;
END $guard$;
DROP TRIGGER com_corporate_mail_payload ON public.com_request_events;
DROP FUNCTION public._com_decision_mail_payload_store();
DROP FUNCTION public.comm_decision_mail_claim_next();
DROP FUNCTION public.comm_decision_mail_release(bigint,uuid,text);
DROP FUNCTION public._com_decision_mail_payload(bigint);
DROP TABLE public.com_decision_mail_payloads;
DROP FUNCTION public._com_decision_mail_payloads_immutable();
-- Funciones publicadas, texto idéntico a propuestas/correo_corporativo/INSTALL.sql
CREATE OR REPLACE FUNCTION public.comm_smtp_claim(p_key text,p_fingerprint text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE d public.comm_smtp_ledger;t public.comm_mail_transport; n int;tok uuid;
BEGIN
 PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('okd_smtp_claim'));
 SELECT * INTO t FROM public.comm_mail_transport WHERE id=1;
 IF t.provider<>'SMTP' OR NOT coalesce((public.comm_mail_runtime()->>'connected')::boolean,false) THEN RETURN jsonb_build_object('state','NOT_ACTIVE'); END IF;
 IF p_key IS NULL OR length(p_key)>550 OR p_fingerprint!~'^[a-f0-9]{64}$' OR p_fingerprint IS NULL THEN RAISE EXCEPTION 'SMTP_INVALID_OPERATION'; END IF;
 SELECT * INTO d FROM public.comm_smtp_ledger WHERE op_key=p_key FOR UPDATE;
 IF FOUND THEN
  IF d.fingerprint<>p_fingerprint THEN RETURN jsonb_build_object('state','CONFLICT'); END IF;
  IF d.state IN ('ACCEPTED','HELD','REJECTED') THEN RETURN jsonb_build_object('state',d.state,'provider_id',d.provider_id); END IF;
  IF d.state='PROCESSING' THEN
   IF d.claimed_at<now()-interval '2 minutes' THEN UPDATE public.comm_smtp_ledger SET state='HELD',updated_at=now() WHERE op_key=p_key; RETURN jsonb_build_object('state','HELD'); END IF;
   RETURN jsonb_build_object('state','BUSY');
  END IF;
 END IF;
 SELECT count(*) INTO n FROM public.comm_smtp_rate WHERE at>now()-interval '1 hour';
 IF t.hourly_cap IS NULL OR n>=t.hourly_cap THEN RETURN jsonb_build_object('state','RATE_LIMIT'); END IF;
 INSERT INTO public.comm_smtp_rate DEFAULT VALUES;
 tok:=gen_random_uuid();
 INSERT INTO public.comm_smtp_ledger(op_key,fingerprint,state,token,claimed_at) VALUES(p_key,p_fingerprint,'PROCESSING',tok,now())
 ON CONFLICT(op_key) DO UPDATE SET state='PROCESSING',token=tok,claimed_at=now(),updated_at=now();
 RETURN jsonb_build_object('state','READY','token',tok);
END;$$;
CREATE OR REPLACE FUNCTION public.com_mail_settings_get() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN IF NOT coalesce(public._comm_mail_admin(),false) THEN RAISE EXCEPTION 'FORBIDDEN' USING errcode='42501';END IF;
 RETURN (SELECT jsonb_build_object('copies',s.copies,'author_always',true,'history',coalesce((SELECT jsonb_agg(x) FROM (SELECT request_number,event_kind,recipient,state,sent_at,error_code FROM public.com_decision_mail_outbox ORDER BY id DESC LIMIT 20)x),'[]'::jsonb)) FROM public.com_mail_settings s WHERE id=1);END;$$;
DROP FUNCTION public.comm_mail_set_daily_cap(int);
DROP FUNCTION public.comm_mail_capacity();
ALTER TABLE public.comm_mail_transport DROP COLUMN daily_cap;
REVOKE ALL ON FUNCTION public.comm_smtp_claim(text,text) FROM PUBLIC, anon, authenticated; GRANT EXECUTE ON FUNCTION public.comm_smtp_claim(text,text) TO service_role;
REVOKE ALL ON FUNCTION public.com_mail_settings_get() FROM PUBLIC, anon; GRANT EXECUTE ON FUNCTION public.com_mail_settings_get() TO authenticated;
-- Los destinatarios que quedaron PENDING por cupo siguen en la bandeja y los toma la versión anterior (de a uno por minuto).
DO $check$ BEGIN
  IF md5((SELECT prosrc FROM pg_catalog.pg_proc WHERE oid = 'public.comm_smtp_claim(text,text)'::regprocedure)) <> '122468dcb26660ecf0e1499ae0ab75fd'
     OR md5((SELECT prosrc FROM pg_catalog.pg_proc WHERE oid = 'public.com_mail_settings_get()'::regprocedure)) <> 'd23a96fb2cf877509b7ed51927e9c11c' THEN
    RAISE EXCEPTION 'REVERSION_INCOMPLETA: las funciones restauradas no coinciden con las publicadas. No se modificó nada.'; END IF;
END $check$;
INSERT INTO public.comm_smtp_audit(action, detail) VALUES ('COM_DECISION_MAIL_DETAIL_REVERTED', '{}'::jsonb);
COMMIT;
