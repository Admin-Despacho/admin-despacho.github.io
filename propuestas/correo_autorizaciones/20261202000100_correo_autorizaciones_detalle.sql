-- =====================================================================================================================
-- PROPUESTA · NO APLICADA · CORREOS DE AUTORIZACIONES COMERCIALES CON DETALLE COMPLETO + PROCESAMIENTO POR LOTES + CUPO DIARIO
-- Base: producción con 20261118112054 corporate_mail_starttls_install y 20261118112513 corporate_mail_cron (SMTP ACTIVO).
-- UNA transacción. Se detiene SIN CAMBIOS si falta un objeto, si ya está aplicada o si alguna función a reemplazar no es
-- EXACTAMENTE la publicada (huella md5 del cuerpo: independiente de la versión de PostgreSQL).
--
-- Qué hace:
--  1) Foto INMUTABLE por evento (com_decision_mail_payloads): los datos de la solicitud y de la resolución TAL COMO estaban al
--     registrarse el evento. Un cambio posterior de la solicitud no altera lo notificado. Los eventos históricos sin foto se
--     fotografían una sola vez al procesarse (con sus términos registrados; nunca se recalculan).
--  2) comm_decision_mail_claim_next(): toma de a UN destinatario por llamada, con cupo previo (horario + diario) y SKIP LOCKED.
--     El trabajador (comm-dispatcher, el MISMO cron) llama varias veces por ciclo: autor + copias salen en el mismo ciclo.
--  3) comm_decision_mail_release(): devuelve a PENDIENTE sin gastar intento cuando el envío no empezó por falta de cupo.
--  4) Cupo DIARIO global de la app (comm_mail_transport.daily_cap, 24 h móviles, predeterminado 850 de 1.000 del proveedor;
--     reserva 150 para Authentication y uso directo de la cuenta). Lo aplica comm_smtp_claim para TODOS los módulos.
--     El límite horario (hourly_cap = 100) NO se modifica.
--  5) com_mail_settings_get(): agrega el estado REAL del proveedor, el consumo del cupo y el historial con intentos y fechas.
-- No cambia: credenciales, remitente, transporte SMTP, Authentication, reglas de aprobación, calendario de cuotas,
-- com_mail_settings_set (destinatarios y su auditoría), guard/finish existentes ni el cron.
-- =====================================================================================================================
BEGIN;
SET LOCAL lock_timeout = '5s'; SET LOCAL statement_timeout = '60s';
DO $guard$
DECLARE f record;
BEGIN
  IF to_regclass('public.com_decision_mail_outbox') IS NULL OR to_regclass('public.comm_mail_transport') IS NULL OR to_regclass('public.comm_smtp_rate') IS NULL
     OR to_regclass('public.com_request_events') IS NULL OR to_regprocedure('public._com_label(uuid)') IS NULL OR to_regprocedure('public._comm_mail_admin()') IS NULL THEN
    RAISE EXCEPTION 'DEPENDENCIA_FALTANTE: correo corporativo o módulo comercial no instalado. No se modificó nada.'; END IF;
  IF to_regclass('public.com_decision_mail_payloads') IS NOT NULL THEN RAISE EXCEPTION 'YA_APLICADA. No se modificó nada.'; END IF;
  FOR f IN SELECT * FROM (VALUES
      ('public.comm_smtp_claim(text,text)', '122468dcb26660ecf0e1499ae0ab75fd'),
      ('public.com_mail_settings_get()', 'd23a96fb2cf877509b7ed51927e9c11c'),
      ('public.comm_mail_runtime()', '42057332ba3770ef0ed4d05d78e84d28'),
      ('public.comm_decision_mail_guard(bigint,uuid)', 'd58bb9f9496993769120747f5c0d94be'),
      ('public.comm_decision_mail_finish(bigint,uuid,text,text,text)', '20b3a84c824cab03d79ebee5f2e2f531'),
      ('public._com_mail_event()', 'edc79643ef9f5f07f43b40d5cd77af43')) AS x(sig, h) LOOP
    IF to_regprocedure(f.sig) IS NULL OR md5((SELECT prosrc FROM pg_catalog.pg_proc WHERE oid = to_regprocedure(f.sig))) <> f.h THEN
      RAISE EXCEPTION 'BASE_CAMBIADA: % no coincide con la versión publicada. No se modificó nada.', f.sig; END IF;
  END LOOP;
  IF EXISTS (SELECT 1 FROM public.com_decision_mail_outbox WHERE state = 'PROCESSING') THEN
    RAISE EXCEPTION 'TRABAJADOR_ACTIVO: hay correos de autorizaciones en PROCESSING. Reintentar en 2 minutos. No se modificó nada.'; END IF;
END $guard$;

-- ---------- 4) Cupo diario global ----------
ALTER TABLE public.comm_mail_transport ADD COLUMN daily_cap int NOT NULL DEFAULT 850 CHECK (daily_cap BETWEEN 1 AND 1000);

CREATE FUNCTION public.comm_mail_capacity() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('hourly_cap', t.hourly_cap, 'hourly_used', h.n, 'daily_cap', t.daily_cap, 'daily_used', d.n,
    'available', greatest(0, least(coalesce(t.hourly_cap, 0) - h.n, t.daily_cap - d.n)))
  FROM public.comm_mail_transport t,
       LATERAL (SELECT count(*)::int n FROM public.comm_smtp_rate WHERE at > now() - interval '1 hour') h,
       LATERAL (SELECT count(*)::int n FROM public.comm_smtp_rate WHERE at > now() - interval '24 hours') d
  WHERE t.id = 1;
$$;

CREATE FUNCTION public.comm_mail_set_daily_cap(p_daily_cap int) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE oldv int;
BEGIN
  IF p_daily_cap IS NULL OR p_daily_cap NOT BETWEEN 1 AND 1000 THEN RAISE EXCEPTION 'INVALID_DAILY_CAP: entre 1 y 1000 (límite del proveedor)'; END IF;
  SELECT daily_cap INTO oldv FROM public.comm_mail_transport WHERE id = 1 FOR UPDATE;
  UPDATE public.comm_mail_transport SET daily_cap = p_daily_cap, changed_at = now() WHERE id = 1;
  INSERT INTO public.comm_smtp_audit(action, detail) VALUES ('DAILY_CAP_CHANGED', jsonb_build_object('before', oldv, 'after', p_daily_cap));
  RETURN public.comm_mail_capacity();
END; $$;

-- comm_smtp_claim: IDÉNTICA a la publicada + verificación del cupo diario (24 h móviles) después del horario. Mismo estado RATE_LIMIT,
-- que todos los módulos ya tratan como «reintentar más tarde» sin enviar.
CREATE OR REPLACE FUNCTION public.comm_smtp_claim(p_key text,p_fingerprint text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE d public.comm_smtp_ledger;t public.comm_mail_transport; n int;n24 int;tok uuid;
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
 SELECT count(*) INTO n24 FROM public.comm_smtp_rate WHERE at>now()-interval '24 hours';
 IF t.daily_cap IS NULL OR n24>=t.daily_cap THEN RETURN jsonb_build_object('state','RATE_LIMIT'); END IF;
 INSERT INTO public.comm_smtp_rate DEFAULT VALUES;
 tok:=gen_random_uuid();
 INSERT INTO public.comm_smtp_ledger(op_key,fingerprint,state,token,claimed_at) VALUES(p_key,p_fingerprint,'PROCESSING',tok,now())
 ON CONFLICT(op_key) DO UPDATE SET state='PROCESSING',token=tok,claimed_at=now(),updated_at=now();
 RETURN jsonb_build_object('state','READY','token',tok);
END;$$;

-- ---------- 1) Foto inmutable por evento ----------
CREATE TABLE public.com_decision_mail_payloads (
  event_id bigint PRIMARY KEY REFERENCES public.com_request_events(id),
  payload jsonb NOT NULL,
  source text NOT NULL CHECK (source IN ('EVENTO', 'HISTORICO')),
  created_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.com_decision_mail_payloads ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.com_decision_mail_payloads FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT ON public.com_decision_mail_payloads TO service_role;
CREATE FUNCTION public._com_decision_mail_payloads_immutable() RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN RAISE EXCEPTION 'IMMUTABLE: la foto del correo notificado no se modifica ni se borra' USING errcode = '42501'; END; $$;
CREATE TRIGGER com_decision_mail_payloads_immutable BEFORE UPDATE OR DELETE ON public.com_decision_mail_payloads FOR EACH ROW EXECUTE FUNCTION public._com_decision_mail_payloads_immutable();

-- Solo datos REGISTRADOS. Sin KPI, sin documento de identidad, sin saldo, sin lista de copias, sin datos de otras solicitudes.
CREATE FUNCTION public._com_decision_mail_payload(p_event bigint) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE e public.com_request_events; q public.com_requests; orig jsonb; prev jsonb;
BEGIN
  SELECT * INTO e FROM public.com_request_events WHERE id = p_event;
  IF NOT FOUND THEN RAISE EXCEPTION 'EVENT_NOT_FOUND'; END IF;
  SELECT * INTO q FROM public.com_requests WHERE id = e.request_id;
  -- condiciones ORIGINALES: las del evento ENVIADA (inmutable); si no existiera, las guardadas en la solicitud
  SELECT x.terms_after INTO orig FROM public.com_request_events x WHERE x.request_id = q.id AND x.kind = 'ENVIADA' ORDER BY x.seq LIMIT 1;
  -- última propuesta de Gerencia ANTERIOR a este evento (para «aceptó» o «retiró» los cambios)
  SELECT jsonb_build_object('terms', x.terms_after, 'reason', x.reason, 'by', x.actor_label, 'at', x.at) INTO prev
    FROM public.com_request_events x WHERE x.request_id = q.id AND x.seq < e.seq AND x.kind = 'DEVUELTA_CON_MODIFICACIONES' ORDER BY x.seq DESC LIMIT 1;
  RETURN jsonb_build_object('version', 1,
    'event', jsonb_build_object('id', e.id, 'seq', e.seq, 'kind', e.kind, 'at', e.at, 'actor', e.actor_label,
      'by_requester', e.actor_id IS NOT DISTINCT FROM q.requested_by,
      'substitute', e.kind IN ('APROBADA', 'APROBADA_CON_MODIFICACIONES', 'RECHAZADA', 'DEVUELTA_CON_MODIFICACIONES') AND e.actor_id IS DISTINCT FROM e.assigned_approver_id,
      'reason', e.reason, 'terms_before', e.terms_before, 'terms_after', e.terms_after),
    'request', jsonb_build_object('id', q.id, 'number', q.number, 'kind', q.kind, 'created_at', q.created_at,
      'client_name', coalesce(nullif(btrim(q.client_snapshot->>'razon_social'), ''), nullif(btrim(q.client_snapshot->>'nombre'), '')),
      'client_cuit', nullif(btrim(q.client_snapshot->>'cuit'), ''),
      'order_ref', q.order_ref, 'channel', q.channel, 'branch', q.branch, 'cartera_label', q.cartera_label,
      'requester', public._com_label(q.requested_by), 'approver', public._com_label(e.assigned_approver_id),
      'notes', q.notes, 'original_terms', coalesce(orig, q.original_terms)),
    'previous_proposal', prev);
END; $$;

CREATE FUNCTION public._com_decision_mail_payload_store() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NEW.kind NOT IN ('APROBADA','APROBADA_CON_MODIFICACIONES','RECHAZADA','DEVUELTA_CON_MODIFICACIONES','CANCELADA','RETIRADA_POR_COMERCIAL','CAMBIOS_ACEPTADOS_REENVIADA') THEN RETURN NEW; END IF;
  BEGIN
    INSERT INTO public.com_decision_mail_payloads(event_id, payload, source) VALUES (NEW.id, public._com_decision_mail_payload(NEW.id), 'EVENTO') ON CONFLICT DO NOTHING;
  EXCEPTION WHEN OTHERS THEN
    -- Nunca bloquea la decisión comercial: si la foto falla, se arma al procesar el correo (con los datos inmutables del evento).
    RAISE WARNING 'COM_MAIL_PAYLOAD_DEFERRED event=% (%)', NEW.id, SQLSTATE;
  END;
  RETURN NEW;
END; $$;
CREATE TRIGGER com_corporate_mail_payload AFTER INSERT ON public.com_request_events FOR EACH ROW EXECUTE FUNCTION public._com_decision_mail_payload_store();

-- ---------- 2) Toma de a un destinatario, con cupo previo ----------
CREATE FUNCTION public.comm_decision_mail_claim_next() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE rt jsonb := public.comm_mail_runtime(); cap jsonb; d public.com_decision_mail_outbox; pl jsonb;
BEGIN
  IF rt->>'provider' IS DISTINCT FROM 'SMTP' OR NOT coalesce((rt->>'connected')::boolean, false) THEN RETURN jsonb_build_object('state', 'NOT_ACTIVE'); END IF;
  -- igual que la toma publicada: un PROCESSING abandonado queda RETENIDO (resultado incierto: nunca se reenvía solo)
  UPDATE public.com_decision_mail_outbox SET state = 'HELD', error_code = 'WORKER_INTERRUPTED' WHERE state = 'PROCESSING' AND claimed_at < now() - interval '2 minutes';
  cap := public.comm_mail_capacity();
  IF coalesce((cap->>'available')::int, 0) < 1 THEN RETURN jsonb_build_object('state', 'NO_CAPACITY', 'capacity', cap); END IF;
  WITH c AS (SELECT id FROM public.com_decision_mail_outbox WHERE state IN ('PENDING', 'ERROR') AND attempts < 4 AND next_at <= now() ORDER BY id FOR UPDATE SKIP LOCKED LIMIT 1)
  UPDATE public.com_decision_mail_outbox o SET state = 'PROCESSING', token = gen_random_uuid(), claimed_at = now(), attempts = o.attempts + 1
    FROM c WHERE o.id = c.id RETURNING o.* INTO d;
  IF d.id IS NULL THEN RETURN jsonb_build_object('state', 'EMPTY'); END IF;
  SELECT payload INTO pl FROM public.com_decision_mail_payloads WHERE event_id = d.event_id;
  IF pl IS NULL THEN
    BEGIN
      INSERT INTO public.com_decision_mail_payloads(event_id, payload, source) VALUES (d.event_id, public._com_decision_mail_payload(d.event_id), 'HISTORICO') ON CONFLICT DO NOTHING;
      SELECT payload INTO pl FROM public.com_decision_mail_payloads WHERE event_id = d.event_id;
    EXCEPTION WHEN OTHERS THEN pl := NULL; END;
    IF pl IS NULL THEN
      UPDATE public.com_decision_mail_outbox SET state = 'ERROR', error_code = 'DETALLE_NO_DISPONIBLE', next_at = now() + interval '5 minutes' WHERE id = d.id AND token = d.token;
      RETURN jsonb_build_object('state', 'ROW_FAILED', 'id', d.id);
    END IF;
  END IF;
  RETURN jsonb_build_object('state', 'CLAIMED', 'payload', pl,
    'job', jsonb_build_object('id', d.id, 'token', d.token, 'event_id', d.event_id, 'request_id', d.request_id, 'recipient', d.recipient, 'kind', d.kind,
      'event_kind', d.event_kind, 'request_number', d.request_number, 'attempts', d.attempts));
END; $$;

-- ---------- 3) Devolver sin gastar intento (el envío NO empezó: sin cupo, proveedor ocupado o inactivo) ----------
CREATE FUNCTION public.comm_decision_mail_release(p_id bigint, p_token uuid, p_code text) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  UPDATE public.com_decision_mail_outbox SET state = 'PENDING', token = NULL, attempts = greatest(attempts - 1, 0), next_at = now() + interval '1 minute', error_code = left(p_code, 80)
   WHERE id = p_id AND token = p_token AND state = 'PROCESSING';
  RETURN FOUND;
END; $$;

-- ---------- 5) Panel: estado real del proveedor, consumo e historial (solo Administrador General con sesión vigente) ----------
CREATE OR REPLACE FUNCTION public.com_mail_settings_get() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE rt jsonb; cap jsonb;
BEGIN IF NOT coalesce(public._comm_mail_admin(),false) THEN RAISE EXCEPTION 'FORBIDDEN' USING errcode='42501';END IF;
 rt := public.comm_mail_runtime(); cap := public.comm_mail_capacity();
 RETURN (SELECT jsonb_build_object('copies',s.copies,'author_always',true,'detail_version',1,
   'transport',jsonb_build_object('provider',rt->>'provider','connected',coalesce((rt->>'connected')::boolean,false),'sender',CASE WHEN rt->>'provider'='SMTP' THEN rt->>'email' END,
     'hourly_cap',cap->'hourly_cap','hourly_used',cap->'hourly_used','daily_cap',cap->'daily_cap','daily_used',cap->'daily_used'),
   'history',coalesce((SELECT jsonb_agg(x ORDER BY x.id DESC) FROM (SELECT id,request_number,event_kind,kind,recipient,state,attempts,created_at,sent_at,next_at,error_code
      FROM public.com_decision_mail_outbox ORDER BY id DESC LIMIT 30)x),'[]'::jsonb))
  FROM public.com_mail_settings s WHERE id=1);END;$$;

-- ---------- Privilegios: nada para usuarios salvo el panel (que valida Administrador General + sesión) ----------
REVOKE ALL ON FUNCTION public.comm_mail_capacity(), public.comm_mail_set_daily_cap(int), public._com_decision_mail_payload(bigint), public._com_decision_mail_payload_store(),
  public._com_decision_mail_payloads_immutable(), public.comm_decision_mail_claim_next(), public.comm_decision_mail_release(bigint,uuid,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.comm_mail_capacity(), public.comm_mail_set_daily_cap(int), public.comm_decision_mail_claim_next(), public.comm_decision_mail_release(bigint,uuid,text) TO service_role;
REVOKE ALL ON FUNCTION public.comm_smtp_claim(text,text) FROM PUBLIC, anon, authenticated; GRANT EXECUTE ON FUNCTION public.comm_smtp_claim(text,text) TO service_role;
REVOKE ALL ON FUNCTION public.com_mail_settings_get() FROM PUBLIC, anon; GRANT EXECUTE ON FUNCTION public.com_mail_settings_get() TO authenticated;
COMMENT ON TABLE public.com_decision_mail_payloads IS 'OKD:CORREO_AUTORIZACIONES_DETALLE_V1';
INSERT INTO public.comm_smtp_audit(action, detail) VALUES ('COM_DECISION_MAIL_DETAIL_INSTALLED', jsonb_build_object('daily_cap', 850, 'version', 1));
COMMIT;
