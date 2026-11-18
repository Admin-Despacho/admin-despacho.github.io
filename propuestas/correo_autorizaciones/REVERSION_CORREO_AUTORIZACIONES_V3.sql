-- =====================================================================================================================
-- REVERSIÓN · CORREOS DE AUTORIZACIONES V3 (20261202000100). NO APLICADA. UNA transacción. SIN PÉRDIDA DE HISTORIAL.
-- Orden: 1) este SQL  2) volver a desplegar comm-dispatcher del commit base 2a8e65b  3) revertir el frontend.
--   (Con este SQL aplicado y la función V3 todavía desplegada, la V3 no envía nada: no encuentra su toma.)
-- CONSERVA (nada se borra): fotos de eventos, incidencias, autorizaciones de copias y su bitácora, bandeja con estados y
--   distribución efectiva de cada intento, ledger SMTP, consumos (comm_smtp_rate) y auditoría.
-- CONSERVA A PROPÓSITO el CONTROL DIARIO: comm_smtp_claim con el tope de 24 h, comm_mail_capacity, comm_mail_set_daily_cap,
--   comm_mail_confirm_daily_cap y las columnas del tope. Lo usan TODOS los módulos (también el trabajador publicado): sin él, la
--   versión anterior podría seguir enviando sin control diario. Para quitarlo hace falta una decisión expresa aparte.
-- RESTAURA EXACTAMENTE (texto de INSTALL.sql, huellas verificadas): com_mail_settings_get, com_mail_settings_set, _com_mail_event,
--   comm_decision_mail_claim y comm_decision_mail_guard.
-- CONCILIA antes de volver: lo ACEPTADO por SMTP con CUALQUIER clave queda SENT; lo incierto, HELD; los avisos solo-V3 pendientes
--   (nueva solicitud / aprobador) quedan SKIPPED VERSION_REVERTIDA: la versión publicada nunca los envía con otro formato ni duplica.
-- =====================================================================================================================
BEGIN;
SET LOCAL lock_timeout = '5s'; SET LOCAL statement_timeout = '60s';
DO $guard$ DECLARE st text; BEGIN
  IF to_regclass('public.com_mail_detail_install') IS NOT NULL THEN EXECUTE 'SELECT status FROM public.com_mail_detail_install WHERE id = 1' INTO st; END IF;
  IF st IS DISTINCT FROM 'INSTALADA' THEN RAISE EXCEPTION 'NO_APLICADA: no hay nada que revertir. No se modificó nada.'; END IF;
  IF EXISTS (SELECT 1 FROM public.com_decision_mail_outbox WHERE state = 'PROCESSING') OR EXISTS (SELECT 1 FROM public.comm_smtp_ledger WHERE state = 'PROCESSING') THEN
    RAISE EXCEPTION 'TRABAJADOR_ACTIVO: hay correos en curso. Reintentar en 2 minutos. No se modificó nada.'; END IF;
END $guard$;
-- 1) Conciliación con el ledger SMTP: TODAS las claves del (evento, destinatario): publicada, :v2 y por contenido :v3:…
CREATE TEMP TABLE okd_rev_keys ON COMMIT DROP AS
  SELECT o.id, l.state, l.provider_id, l.updated_at FROM public.com_decision_mail_outbox o
  JOIN public.comm_smtp_ledger l ON l.op_key = 'decisiones:evento:' || o.event_id || ':' || o.recipient
    OR (l.op_key > 'decisiones:evento:' || o.event_id || ':' || o.recipient || ':' AND l.op_key < 'decisiones:evento:' || o.event_id || ':' || o.recipient || ';')
  WHERE o.state <> 'SENT';
UPDATE public.com_decision_mail_outbox o SET state = 'SENT', sent_at = coalesce(o.sent_at, k.updated_at), provider_id = left(k.provider_id, 100), error_code = 'CONCILIADO_REVERSION'
  FROM (SELECT DISTINCT ON (id) id, provider_id, updated_at FROM okd_rev_keys WHERE state = 'ACCEPTED' ORDER BY id, updated_at) k WHERE o.id = k.id;
UPDATE public.com_decision_mail_outbox o SET state = 'HELD', error_code = 'CONCILIADO_REVERSION_INCIERTO'
  WHERE o.state IN ('PENDING', 'ERROR') AND EXISTS (SELECT 1 FROM okd_rev_keys k WHERE k.id = o.id AND k.state = 'HELD');
UPDATE public.com_decision_mail_outbox SET state = 'SKIPPED', error_code = 'VERSION_REVERTIDA'
  WHERE state IN ('PENDING', 'ERROR') AND (event_kind = 'ENVIADA' OR kind = 'APPROVER');
-- 2) Quitar SOLO funciones nuevas de la distribución/integridad (tablas, datos y control diario quedan)
DROP FUNCTION public.comm_decision_mail_claim_next();
DROP FUNCTION public.comm_decision_mail_release(bigint,uuid,text);
DROP FUNCTION public.comm_decision_mail_distribution(bigint,uuid);
DROP FUNCTION public.comm_decision_mail_note_delivery(bigint,uuid,jsonb);
DROP FUNCTION public.comm_decision_mail_hold(bigint,uuid,text,text);
DROP FUNCTION public.comm_decision_mail_ledger_state(bigint,text);
DROP FUNCTION public.com_mail_incident_resolve(bigint,text,boolean,text);
DROP FUNCTION public.com_mail_copy_authorize(text[],text,boolean);
DROP FUNCTION public.com_mail_copy_revoke(text[]);
DROP FUNCTION public._com_mail_copies_sync();
DROP FUNCTION public._com_decision_mail_effective(bigint,jsonb);
DROP FUNCTION public._com_mail_principal_ok(bigint,text);
DROP FUNCTION public._com_decision_mail_payload_issue(jsonb,public.com_decision_mail_outbox);
DROP FUNCTION public._com_mail_hold_event(bigint,bigint,text,text);
-- 3) Funciones publicadas, texto idéntico a propuestas/correo_corporativo/INSTALL.sql
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
REVOKE ALL ON FUNCTION public._com_mail_event(), public.comm_decision_mail_claim(), public.comm_decision_mail_guard(bigint,uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.comm_decision_mail_claim(), public.comm_decision_mail_guard(bigint,uuid) TO service_role;
REVOKE ALL ON FUNCTION public.com_mail_settings_get(), public.com_mail_settings_set(text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.com_mail_settings_get(), public.com_mail_settings_set(text[]) TO authenticated;
DO $check$ DECLARE f record; BEGIN
  FOR f IN SELECT * FROM (VALUES ('public.com_mail_settings_get()', 'd23a96fb2cf877509b7ed51927e9c11c'),
      ('public.com_mail_settings_set(text[])', '29c88fb1fdcad74345470ae6a194e676'), ('public._com_mail_event()', 'edc79643ef9f5f07f43b40d5cd77af43'),
      ('public.comm_decision_mail_claim()', '49ba78957e31b18586f08f94d60040a2'), ('public.comm_decision_mail_guard(bigint,uuid)', 'd58bb9f9496993769120747f5c0d94be'),
      ('public.comm_smtp_claim(text,text)', 'f7803c123b4d233719989107080c8535')) x(sig, h) LOOP   -- comm_smtp_claim: la V3 CON control diario
    IF md5((SELECT prosrc FROM pg_catalog.pg_proc WHERE oid = to_regprocedure(f.sig))) <> f.h THEN RAISE EXCEPTION 'REVERSION_INCOMPLETA: % no coincide. No se modificó nada.', f.sig; END IF;
  END LOOP;
  IF to_regprocedure('public.comm_mail_capacity()') IS NULL OR to_regprocedure('public.comm_mail_confirm_daily_cap(integer,text)') IS NULL THEN RAISE EXCEPTION 'REVERSION_INCOMPLETA: falta el control diario'; END IF;
END $check$;
UPDATE public.com_mail_detail_install SET status = 'REVERTIDA', reverted_at = now() WHERE id = 1;
INSERT INTO public.comm_smtp_audit(action, detail) VALUES ('COM_DECISION_MAIL_V3_REVERTED', jsonb_build_object('conservado', 'fotos, incidencias, autorizaciones, bitacora, bandeja, ledger, consumos y CONTROL DIARIO activo'));
COMMIT;
