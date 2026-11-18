-- =====================================================================================================================
-- REVERSIÓN · CORREOS DE AUTORIZACIONES V2 (20261202000100). NO APLICADA. UNA transacción. SIN PÉRDIDA DE HISTORIAL.
-- Orden: 1) este SQL  2) volver a desplegar comm-dispatcher del commit base 2a8e65b  3) revertir el frontend.
--   (Con este SQL aplicado y la función V2 todavía desplegada, la V2 no envía nada: no encuentra su toma.)
-- CONSERVA: fotos de eventos (com_decision_mail_payloads), autorizaciones de copias y su bitácora, bandeja con estados,
--           ledger SMTP, auditoría y el valor del cupo diario (la función publicada no lo usa). Nada se borra.
-- RESTAURA EXACTAMENTE: comm_smtp_claim, com_mail_settings_get, com_mail_settings_set, _com_mail_event,
--           comm_decision_mail_claim y comm_decision_mail_guard publicados (texto de INSTALL.sql, huellas verificadas).
-- CONCILIA antes de volver: lo que el servidor SMTP ya ACEPTÓ (con cualquier clave) queda SENT; lo incierto queda HELD;
--           los avisos solo-V2 pendientes (nueva solicitud / aprobador) quedan SKIPPED VERSION_REVERTIDA: la versión
--           publicada nunca los envía con otro formato ni duplica.
-- =====================================================================================================================
BEGIN;
SET LOCAL lock_timeout = '5s'; SET LOCAL statement_timeout = '60s';
DO $guard$ DECLARE st text; BEGIN
  IF to_regclass('public.com_mail_v2_install') IS NOT NULL THEN EXECUTE 'SELECT status FROM public.com_mail_v2_install WHERE id = 1' INTO st; END IF;
  IF st IS DISTINCT FROM 'INSTALADA' THEN
    RAISE EXCEPTION 'NO_APLICADA: no hay nada que revertir. No se modificó nada.'; END IF;
  IF EXISTS (SELECT 1 FROM public.com_decision_mail_outbox WHERE state = 'PROCESSING') OR EXISTS (SELECT 1 FROM public.comm_smtp_ledger WHERE state = 'PROCESSING') THEN
    RAISE EXCEPTION 'TRABAJADOR_ACTIVO: hay correos en curso. Reintentar en 2 minutos. No se modificó nada.'; END IF;
END $guard$;
-- 1) Conciliación con el ledger SMTP (claves publicada y V2)
UPDATE public.com_decision_mail_outbox o SET state = 'SENT', sent_at = coalesce(o.sent_at, l.updated_at), provider_id = left(l.provider_id, 100), error_code = 'CONCILIADO_REVERSION'
  FROM public.comm_smtp_ledger l
  WHERE o.state <> 'SENT' AND l.state = 'ACCEPTED' AND l.op_key IN ('decisiones:evento:' || o.event_id || ':' || o.recipient, 'decisiones:evento:' || o.event_id || ':' || o.recipient || ':v2');
UPDATE public.com_decision_mail_outbox o SET state = 'HELD', error_code = 'CONCILIADO_REVERSION_INCIERTO'
  WHERE o.state IN ('PENDING', 'ERROR') AND EXISTS (SELECT 1 FROM public.comm_smtp_ledger l WHERE l.state = 'HELD'
    AND l.op_key IN ('decisiones:evento:' || o.event_id || ':' || o.recipient, 'decisiones:evento:' || o.event_id || ':' || o.recipient || ':v2'));
UPDATE public.com_decision_mail_outbox SET state = 'SKIPPED', error_code = 'VERSION_REVERTIDA'
  WHERE state IN ('PENDING', 'ERROR') AND (event_kind = 'ENVIADA' OR kind = 'APPROVER');
-- 2) Quitar SOLO funciones nuevas (las tablas y sus datos quedan)
DROP FUNCTION public.comm_decision_mail_claim_next();
DROP FUNCTION public.comm_decision_mail_release(bigint,uuid,text);
DROP FUNCTION public.com_mail_copy_authorize(text[],text,boolean);
DROP FUNCTION public.com_mail_copy_revoke(text[]);
DROP FUNCTION public._com_mail_copies_sync();
DROP FUNCTION public.comm_mail_set_daily_cap(int);
-- 3) Funciones publicadas, texto idéntico a propuestas/correo_corporativo/INSTALL.sql
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
CREATE OR REPLACE FUNCTION public.com_mail_settings_set(p_copies text[]) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v text[];oldv text[];
BEGIN IF NOT coalesce(public._comm_mail_admin(),false) THEN RAISE EXCEPTION 'FORBIDDEN' USING errcode='42501';END IF;
 SELECT coalesce(array_agg(DISTINCT lower(btrim(x)) ORDER BY lower(btrim(x))),'{}') INTO v FROM unnest(coalesce(p_copies,'{}')) x WHERE btrim(x)<>'';
 IF cardinality(v)>20 OR EXISTS(SELECT 1 FROM unnest(v)x WHERE length(x)>254 OR x!~'^[^[:space:]<>@,;]+@[^[:space:]<>@,;]+\.[^[:space:]<>@,;]+$') THEN RAISE EXCEPTION 'INVALID_EMAIL_LIST';END IF;
 SELECT copies INTO oldv FROM public.com_mail_settings WHERE id=1 FOR UPDATE;
 UPDATE public.com_mail_settings SET copies=v,changed_by=auth.uid(),changed_at=now() WHERE id=1;
 INSERT INTO public.audit_log(actor_id,action,target_type,target_id,before,after) VALUES(auth.uid(),'COM_MAIL_RECIPIENTS_CHANGED','com_mail_settings','1',jsonb_build_object('copies',oldv),jsonb_build_object('copies',v));
 RETURN public.com_mail_settings_get();END;$$;
CREATE OR REPLACE FUNCTION public._com_mail_event() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE q public.com_requests;p public.profiles;v text;
BEGIN
 IF NEW.kind NOT IN ('APROBADA','APROBADA_CON_MODIFICACIONES','RECHAZADA','DEVUELTA_CON_MODIFICACIONES','CANCELADA','RETIRADA_POR_COMERCIAL','CAMBIOS_ACEPTADOS_REENVIADA') THEN RETURN NEW;END IF;
 SELECT * INTO q FROM public.com_requests WHERE id=NEW.request_id;SELECT * INTO p FROM public.profiles WHERE id=q.requested_by;
 v:=lower(btrim(p.email));
 INSERT INTO public.com_decision_mail_outbox(event_id,request_id,recipient_user,recipient,kind,event_kind,request_number,state,error_code)
 VALUES(NEW.id,q.id,p.id,v,'AUTHOR',NEW.kind,q.number,CASE WHEN v~'^[^[:space:]<>@,;]+@[^[:space:]<>@,;]+\.[^[:space:]<>@,;]+$' THEN 'PENDING' ELSE 'SKIPPED' END,CASE WHEN v IS NULL OR v='' THEN 'AUTHOR_WITHOUT_EMAIL' END) ON CONFLICT DO NOTHING;
 INSERT INTO public.com_decision_mail_outbox(event_id,request_id,recipient,kind,event_kind,request_number)
 SELECT NEW.id,q.id,x,'COPY',NEW.kind,q.number FROM public.com_mail_settings s,unnest(s.copies)x WHERE s.id=1 AND x IS DISTINCT FROM v ON CONFLICT DO NOTHING;
 RETURN NEW;
END;$$;
CREATE OR REPLACE FUNCTION public.comm_decision_mail_claim() RETURNS SETOF public.com_decision_mail_outbox LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF (public.comm_mail_runtime()->>'provider')<>'SMTP' OR NOT (public.comm_mail_runtime()->>'connected')::boolean THEN RETURN;END IF;
 UPDATE public.com_decision_mail_outbox SET state='HELD',error_code='WORKER_INTERRUPTED' WHERE state='PROCESSING' AND claimed_at<now()-interval '2 minutes';
 RETURN QUERY WITH c AS (SELECT id FROM public.com_decision_mail_outbox WHERE state IN ('PENDING','ERROR') AND attempts<4 AND next_at<=now() ORDER BY id FOR UPDATE SKIP LOCKED LIMIT 1)
 UPDATE public.com_decision_mail_outbox d SET state='PROCESSING',token=gen_random_uuid(),claimed_at=now(),attempts=attempts+1 FROM c WHERE d.id=c.id RETURNING d.*;
END;$$;
CREATE OR REPLACE FUNCTION public.comm_decision_mail_guard(p_id bigint,p_token uuid) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE d public.com_decision_mail_outbox;p public.profiles;
BEGIN
 SELECT * INTO d FROM public.com_decision_mail_outbox WHERE id=p_id AND token=p_token AND state='PROCESSING' FOR UPDATE;
 IF NOT FOUND THEN RETURN false;END IF;
 IF d.kind='AUTHOR' THEN
  SELECT * INTO p FROM public.profiles WHERE id=d.recipient_user;
  IF p.status IS DISTINCT FROM 'ACTIVO' OR lower(btrim(p.email)) IS DISTINCT FROM d.recipient OR NOT coalesce(public.user_has_perm(p.id,'com.request'),false) THEN
   UPDATE public.com_decision_mail_outbox SET state='SKIPPED',error_code='AUTHOR_NO_LONGER_AUTHORIZED' WHERE id=p_id;RETURN false;END IF;
 ELSE
  IF NOT EXISTS(SELECT 1 FROM public.com_mail_settings WHERE id=1 AND d.recipient=ANY(copies)) THEN UPDATE public.com_decision_mail_outbox SET state='SKIPPED',error_code='COPY_REMOVED' WHERE id=p_id;RETURN false;END IF;
 END IF;
 RETURN true;
END;$$;
DROP FUNCTION public._com_decision_mail_payload(bigint);
DROP FUNCTION public.comm_mail_capacity();
REVOKE ALL ON FUNCTION public.comm_smtp_claim(text,text), public._com_mail_event(), public.comm_decision_mail_claim(), public.comm_decision_mail_guard(bigint,uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.comm_smtp_claim(text,text), public.comm_decision_mail_claim(), public.comm_decision_mail_guard(bigint,uuid) TO service_role;
REVOKE ALL ON FUNCTION public.com_mail_settings_get(), public.com_mail_settings_set(text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.com_mail_settings_get(), public.com_mail_settings_set(text[]) TO authenticated;
DO $check$ DECLARE f record; BEGIN
  FOR f IN SELECT * FROM (VALUES ('public.comm_smtp_claim(text,text)', '122468dcb26660ecf0e1499ae0ab75fd'), ('public.com_mail_settings_get()', 'd23a96fb2cf877509b7ed51927e9c11c'),
      ('public.com_mail_settings_set(text[])', '29c88fb1fdcad74345470ae6a194e676'), ('public._com_mail_event()', 'edc79643ef9f5f07f43b40d5cd77af43'),
      ('public.comm_decision_mail_claim()', '49ba78957e31b18586f08f94d60040a2'), ('public.comm_decision_mail_guard(bigint,uuid)', 'd58bb9f9496993769120747f5c0d94be')) x(sig, h) LOOP
    IF md5((SELECT prosrc FROM pg_catalog.pg_proc WHERE oid = to_regprocedure(f.sig))) <> f.h THEN RAISE EXCEPTION 'REVERSION_INCOMPLETA: % no coincide con la publicada. No se modificó nada.', f.sig; END IF;
  END LOOP;
END $check$;
UPDATE public.com_mail_v2_install SET status = 'REVERTIDA', reverted_at = now() WHERE id = 1;
INSERT INTO public.comm_smtp_audit(action, detail) VALUES ('COM_DECISION_MAIL_V2_REVERTED', jsonb_build_object('conservado', 'fotos, autorizaciones, bitacora, bandeja, ledger, cupo diario'));
COMMIT;
