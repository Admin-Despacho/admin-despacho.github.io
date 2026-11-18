-- =====================================================================================================================
-- PROPUESTA · NO APLICADA · CORREOS DE AUTORIZACIONES COMERCIALES V3 (acumulada: incluye todo lo de V2)
-- Base: producción 2a8e65b (correo corporativo SMTP ACTIVO: 20261118112054 + 20261118112513).
-- UNA transacción. Se detiene SIN CAMBIOS si falta un objeto, si ya está instalada, si alguna función a reemplazar no es
-- EXACTAMENTE la publicada (md5 del cuerpo) o si hay correos en curso. Reinstalable después de la reversión (conserva historial).
--
--  1) NUEVA SOLICITUD (evento ENVIADA) y resoluciones: Para = principales, CC = copias RATIFICADAS, sin CCO.
--  2) Foto INMUTABLE del evento + distribución ORIGINAL en la MISMA transacción del registro o la decisión.
--  3) V3 · Distribución EFECTIVA recalculada inmediatamente antes de cada envío: una dirección revocada (o un principal que dejó
--     de estar habilitado) no recibe ni figura en Para/CC de los mensajes todavía no enviados. La distribución original queda en la
--     foto y la usada en cada intento en delivery_meta. Claves de idempotencia por contenido + verificación de TODAS las claves del
--     destinatario en el ledger: un cambio de distribución nunca duplica ni genera conflictos.
--  4) V3 · Integridad: si la foto falta o no coincide con el evento inmutable, el envío se RETIENE, se registra una INCIDENCIA visible
--     en el Panel General y solo se libera por revisión administrativa controlada. Nunca se reconstruye con el estado actual.
--  5) V3 · Cupo diario: el control de 24 h vive en comm_smtp_claim (compartido por TODOS los módulos) y PERMANECE tras la reversión;
--     consumos nunca se reinician; el valor (850 propuesto) queda «pendiente de confirmación administrativa» hasta confirmarse.
--  6) Autorización/ratificación/revocación de copias validada en el SERVIDOR con bitácora inmutable.
-- No cambia: transporte SMTP, credenciales, remitente, Authentication, límite horario (100), cron, reglas comerciales, cuotas.
-- =====================================================================================================================
BEGIN;
SET LOCAL lock_timeout = '5s'; SET LOCAL statement_timeout = '60s';
DO $guard$
DECLARE f record; st text;
BEGIN
  IF to_regclass('public.com_decision_mail_outbox') IS NULL OR to_regclass('public.comm_mail_transport') IS NULL OR to_regclass('public.comm_smtp_rate') IS NULL
     OR to_regclass('public.com_mail_settings') IS NULL OR to_regclass('public.com_request_events') IS NULL OR to_regprocedure('public._com_label(uuid)') IS NULL
     OR to_regprocedure('public._comm_mail_admin()') IS NULL OR to_regprocedure('public.user_has_perm(uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'DEPENDENCIA_FALTANTE: correo corporativo o módulo comercial no instalado. No se modificó nada.'; END IF;
  IF to_regclass('public.com_mail_detail_install') IS NOT NULL THEN
    EXECUTE 'SELECT status FROM public.com_mail_detail_install WHERE id = 1' INTO st;
    IF st = 'INSTALADA' THEN RAISE EXCEPTION 'YA_APLICADA. No se modificó nada.'; END IF;
  END IF;
  FOR f IN SELECT * FROM (VALUES
      ('public.comm_smtp_claim(text,text)', NULL),
      ('public.com_mail_settings_get()', 'd23a96fb2cf877509b7ed51927e9c11c'),
      ('public.com_mail_settings_set(text[])', '29c88fb1fdcad74345470ae6a194e676'),
      ('public._com_mail_event()', 'edc79643ef9f5f07f43b40d5cd77af43'),
      ('public.comm_decision_mail_claim()', '49ba78957e31b18586f08f94d60040a2'),
      ('public.comm_decision_mail_guard(bigint,uuid)', 'd58bb9f9496993769120747f5c0d94be'),
      ('public.comm_decision_mail_finish(bigint,uuid,text,text,text)', '20b3a84c824cab03d79ebee5f2e2f531'),
      ('public.comm_mail_runtime()', '42057332ba3770ef0ed4d05d78e84d28'),
      ('public.comm_smtp_lookup(text)', NULL)) AS x(sig, h) LOOP
    IF to_regprocedure(f.sig) IS NULL OR (f.h IS NOT NULL AND md5((SELECT prosrc FROM pg_catalog.pg_proc WHERE oid = to_regprocedure(f.sig))) <> f.h) THEN
      RAISE EXCEPTION 'BASE_CAMBIADA: % no coincide con la versión publicada. No se modificó nada.', f.sig; END IF;
  END LOOP;
  -- comm_smtp_claim: la publicada o la V3 (con cupo diario) que la reversión deja a propósito
  IF md5((SELECT prosrc FROM pg_catalog.pg_proc WHERE oid = 'public.comm_smtp_claim(text,text)'::regprocedure)) NOT IN ('122468dcb26660ecf0e1499ae0ab75fd', 'f7803c123b4d233719989107080c8535') THEN
    RAISE EXCEPTION 'BASE_CAMBIADA: public.comm_smtp_claim(text,text) no coincide con la versión publicada. No se modificó nada.'; END IF;
  IF EXISTS (SELECT 1 FROM public.com_decision_mail_outbox WHERE state = 'PROCESSING') OR EXISTS (SELECT 1 FROM public.comm_smtp_ledger WHERE state = 'PROCESSING') THEN
    RAISE EXCEPTION 'TRABAJADOR_ACTIVO: hay correos en curso. Reintentar en 2 minutos. No se modificó nada.'; END IF;
END $guard$;

-- ---------- estado de instalación (se CONSERVA al revertir) ----------
CREATE TABLE IF NOT EXISTS public.com_mail_detail_install (id int PRIMARY KEY CHECK (id = 1), status text NOT NULL CHECK (status IN ('INSTALADA', 'REVERTIDA')),
  installed_at timestamptz, reverted_at timestamptz, installs int NOT NULL DEFAULT 0);
ALTER TABLE public.com_mail_detail_install ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.com_mail_detail_install FROM PUBLIC, anon, authenticated;
INSERT INTO public.com_mail_detail_install(id, status, installed_at, installs) VALUES (1, 'INSTALADA', now(), 1)
  ON CONFLICT (id) DO UPDATE SET status = 'INSTALADA', installed_at = now(), installs = public.com_mail_detail_install.installs + 1;

-- ---------- cupo diario global (se conserva el valor al revertir) ----------
ALTER TABLE public.comm_mail_transport ADD COLUMN IF NOT EXISTS daily_cap int NOT NULL DEFAULT 850 CHECK (daily_cap BETWEEN 1 AND 1000);
-- confirmación administrativa del tope diario: hasta confirmarse, 850 rige igual (conservador) y el panel lo muestra como PROPUESTO
ALTER TABLE public.comm_mail_transport ADD COLUMN IF NOT EXISTS daily_cap_confirmed_at timestamptz, ADD COLUMN IF NOT EXISTS daily_cap_confirmation text;

CREATE OR REPLACE FUNCTION public.comm_mail_capacity() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('hourly_cap', t.hourly_cap, 'hourly_used', h.n, 'daily_cap', t.daily_cap, 'daily_used', d.n,
    'available', greatest(0, least(coalesce(t.hourly_cap, 0) - h.n, t.daily_cap - d.n)), 'daily_cap_confirmed', t.daily_cap_confirmed_at IS NOT NULL,
    'daily_cap_confirmed_at', t.daily_cap_confirmed_at, 'daily_cap_confirmation', t.daily_cap_confirmation)
  FROM public.comm_mail_transport t,
       LATERAL (SELECT count(*)::int n FROM public.comm_smtp_rate WHERE at > now() - interval '1 hour') h,
       LATERAL (SELECT count(*)::int n FROM public.comm_smtp_rate WHERE at > now() - interval '24 hours') d
  WHERE t.id = 1;
$$;
CREATE OR REPLACE FUNCTION public.comm_mail_set_daily_cap(p_daily_cap int) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE oldv int;
BEGIN
  IF p_daily_cap IS NULL OR p_daily_cap NOT BETWEEN 1 AND 1000 THEN RAISE EXCEPTION 'INVALID_DAILY_CAP: entre 1 y 1000 (límite del proveedor)'; END IF;
  SELECT daily_cap INTO oldv FROM public.comm_mail_transport WHERE id = 1 FOR UPDATE;
  UPDATE public.comm_mail_transport SET daily_cap = p_daily_cap, daily_cap_confirmed_at = NULL, daily_cap_confirmation = NULL, changed_at = now() WHERE id = 1;   -- vuelve a «propuesto»
  INSERT INTO public.comm_smtp_audit(action, detail) VALUES ('DAILY_CAP_CHANGED', jsonb_build_object('before', oldv, 'after', p_daily_cap));
  RETURN public.comm_mail_capacity();
END; $$;
CREATE OR REPLACE FUNCTION public.comm_mail_confirm_daily_cap(p_daily_cap int, p_autorizacion text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE oldv int;
BEGIN
  IF p_daily_cap IS NULL OR p_daily_cap NOT BETWEEN 1 AND 1000 THEN RAISE EXCEPTION 'INVALID_DAILY_CAP: entre 1 y 1000 (límite del proveedor)'; END IF;
  IF length(btrim(coalesce(p_autorizacion, ''))) < 5 THEN RAISE EXCEPTION 'AUTORIZACION_REQUERIDA: indicá quién y cómo autorizó el tope diario'; END IF;
  SELECT daily_cap INTO oldv FROM public.comm_mail_transport WHERE id = 1 FOR UPDATE;
  UPDATE public.comm_mail_transport SET daily_cap = p_daily_cap, daily_cap_confirmed_at = now(), daily_cap_confirmation = left(btrim(p_autorizacion), 300), changed_at = now() WHERE id = 1;
  INSERT INTO public.comm_smtp_audit(action, detail) VALUES ('DAILY_CAP_CONFIRMED', jsonb_build_object('before', oldv, 'after', p_daily_cap, 'autorizacion', left(btrim(p_autorizacion), 300)));
  RETURN public.comm_mail_capacity();
END; $$;

-- comm_smtp_claim: IDÉNTICA a la publicada + verificación del cupo diario (24 h móviles). Bajo el MISMO candado de aviso que el
-- cupo horario: dos trabajadores concurrentes nunca superan ninguno de los dos límites. Mismo estado RATE_LIMIT para todos los módulos.
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

-- ---------- bandeja: participación APROBADOR (la restricción ampliada se conserva al revertir: no hay pérdida de filas) ----------
ALTER TABLE public.com_decision_mail_outbox DROP CONSTRAINT IF EXISTS com_decision_mail_outbox_kind_check;
ALTER TABLE public.com_decision_mail_outbox ADD CONSTRAINT com_decision_mail_outbox_kind_check CHECK (kind IN ('AUTHOR', 'COPY', 'APPROVER'));
-- V3: distribución EFECTIVA, huella y clave de cada intento (la ORIGINAL queda en la foto). Se conserva al revertir.
ALTER TABLE public.com_decision_mail_outbox ADD COLUMN IF NOT EXISTS delivery_meta jsonb;

-- ---------- fotos inmutables por evento (se CONSERVAN al revertir) ----------
CREATE TABLE IF NOT EXISTS public.com_decision_mail_payloads (
  event_id bigint PRIMARY KEY REFERENCES public.com_request_events(id), payload jsonb NOT NULL,
  source text NOT NULL CHECK (source IN ('EVENTO', 'HISTORICO', 'REVISION_ADMINISTRATIVA')), created_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.com_decision_mail_payloads ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.com_decision_mail_payloads FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT ON public.com_decision_mail_payloads TO service_role;
CREATE OR REPLACE FUNCTION public._com_mail_history_immutable() RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN RAISE EXCEPTION 'IMMUTABLE: el historial de correos y autorizaciones no se modifica ni se borra' USING errcode = '42501'; END; $$;
REVOKE ALL ON FUNCTION public._com_mail_history_immutable() FROM PUBLIC, anon, authenticated;
DO $t$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'com_decision_mail_payloads_immutable' AND tgrelid = 'public.com_decision_mail_payloads'::regclass) THEN
    CREATE TRIGGER com_decision_mail_payloads_immutable BEFORE UPDATE OR DELETE ON public.com_decision_mail_payloads FOR EACH ROW EXECUTE FUNCTION public._com_mail_history_immutable(); END IF;
END $t$;

-- ---------- autorización de copias adicionales (estado + bitácora inmutable; se CONSERVAN al revertir) ----------
CREATE TABLE IF NOT EXISTS public.com_mail_copy_authorizations (
  address text PRIMARY KEY CHECK (address = lower(btrim(address)) AND length(address) <= 254),
  status text NOT NULL CHECK (status IN ('PENDIENTE_RATIFICACION', 'AUTORIZADA', 'REVOCADA')),
  scope text, visible_cc boolean NOT NULL DEFAULT false,
  authorized_by uuid, authorized_at timestamptz, revoked_by uuid, revoked_at timestamptz, updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (status <> 'AUTORIZADA' OR (scope IS NOT NULL AND authorized_by IS NOT NULL AND authorized_at IS NOT NULL AND visible_cc)));
CREATE TABLE IF NOT EXISTS public.com_mail_copy_authorization_log (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, at timestamptz NOT NULL DEFAULT now(), actor uuid, address text NOT NULL,
  action text NOT NULL, scope text, before_status text, after_status text, origin text NOT NULL);
ALTER TABLE public.com_mail_copy_authorizations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.com_mail_copy_authorization_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.com_mail_copy_authorizations, public.com_mail_copy_authorization_log FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.com_mail_copy_authorizations, public.com_mail_copy_authorization_log TO service_role;
DO $t$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'com_mail_copy_authorization_log_immutable') THEN
    CREATE TRIGGER com_mail_copy_authorization_log_immutable BEFORE UPDATE OR DELETE ON public.com_mail_copy_authorization_log FOR EACH ROW EXECUTE FUNCTION public._com_mail_history_immutable(); END IF;
END $t$;
-- Sincronización con la configuración vigente: las direcciones existentes NO se eliminan; quedan PENDIENTES DE RATIFICACIÓN.
INSERT INTO public.com_mail_copy_authorization_log(actor, address, action, before_status, after_status, origin)
  SELECT NULL, x, 'PENDIENTE_DE_RATIFICAR', NULL, 'PENDIENTE_RATIFICACION', 'INSTALACION'
  FROM public.com_mail_settings s, unnest(s.copies) x WHERE s.id = 1 AND NOT EXISTS (SELECT 1 FROM public.com_mail_copy_authorizations a WHERE a.address = x);
INSERT INTO public.com_mail_copy_authorizations(address, status)
  SELECT x, 'PENDIENTE_RATIFICACION' FROM public.com_mail_settings s, unnest(s.copies) x WHERE s.id = 1 ON CONFLICT (address) DO NOTHING;
-- Reinstalación: una dirección que se quitó de la lista mientras la V2 estaba revertida queda REVOCADA (nunca recibe por error).
INSERT INTO public.com_mail_copy_authorization_log(actor, address, action, before_status, after_status, origin)
  SELECT NULL, a.address, 'REVOCADA_POR_SINCRONIZACION', a.status, 'REVOCADA', 'INSTALACION' FROM public.com_mail_copy_authorizations a
  WHERE a.status <> 'REVOCADA' AND NOT EXISTS (SELECT 1 FROM public.com_mail_settings s WHERE s.id = 1 AND a.address = ANY (s.copies));
UPDATE public.com_mail_copy_authorizations a SET status = 'REVOCADA', revoked_at = now(), updated_at = now()
  WHERE a.status <> 'REVOCADA' AND NOT EXISTS (SELECT 1 FROM public.com_mail_settings s WHERE s.id = 1 AND a.address = ANY (s.copies));

CREATE OR REPLACE FUNCTION public._com_mail_norm(p text) RETURNS text LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE WHEN v ~ '^[A-Za-z0-9.!#$%&''*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z0-9-]+$' AND length(v) <= 254 THEN v END
  FROM (SELECT lower(btrim(p)) v) x;
$$;

-- ---------- foto del evento: datos REGISTRADOS + distribución (Para / CC) tomada de las filas de la bandeja ----------
CREATE OR REPLACE FUNCTION public._com_decision_mail_payload(p_event bigint) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE e public.com_request_events; q public.com_requests; orig jsonb; prev jsonb; v_to jsonb; v_cc jsonb;
BEGIN
  SELECT * INTO e FROM public.com_request_events WHERE id = p_event;
  IF NOT FOUND THEN RAISE EXCEPTION 'EVENT_NOT_FOUND'; END IF;
  SELECT * INTO q FROM public.com_requests WHERE id = e.request_id;
  SELECT x.terms_after INTO orig FROM public.com_request_events x WHERE x.request_id = q.id AND x.kind = 'ENVIADA' ORDER BY x.seq LIMIT 1;
  SELECT jsonb_build_object('terms', x.terms_after, 'reason', x.reason, 'by', x.actor_label, 'at', x.at) INTO prev
    FROM public.com_request_events x WHERE x.request_id = q.id AND x.seq < e.seq AND x.kind = 'DEVUELTA_CON_MODIFICACIONES' ORDER BY x.seq DESC LIMIT 1;
  SELECT coalesce(jsonb_agg(o.recipient ORDER BY o.id), '[]') INTO v_to FROM public.com_decision_mail_outbox o
    WHERE o.event_id = e.id AND o.kind IN ('APPROVER', 'AUTHOR') AND o.state <> 'SKIPPED' AND o.recipient IS NOT NULL;
  SELECT coalesce(jsonb_agg(o.recipient ORDER BY o.id), '[]') INTO v_cc FROM public.com_decision_mail_outbox o
    WHERE o.event_id = e.id AND o.kind = 'COPY' AND o.state <> 'SKIPPED'
      AND EXISTS (SELECT 1 FROM public.com_mail_copy_authorizations a WHERE a.address = o.recipient AND a.status = 'AUTORIZADA');
  RETURN jsonb_build_object('version', 2,
    'event', jsonb_build_object('id', e.id, 'seq', e.seq, 'kind', e.kind, 'at', e.at, 'actor', e.actor_label,
      'by_requester', e.actor_id IS NOT DISTINCT FROM q.requested_by,
      'substitute', e.kind IN ('APROBADA', 'APROBADA_CON_MODIFICACIONES', 'RECHAZADA', 'DEVUELTA_CON_MODIFICACIONES') AND e.actor_id IS DISTINCT FROM e.assigned_approver_id,
      'reason', e.reason, 'terms_before', e.terms_before, 'terms_after', e.terms_after),
    'request', jsonb_build_object('id', q.id, 'number', q.number, 'kind', q.kind, 'created_at', q.created_at,
      'client_name', coalesce(nullif(btrim(q.client_snapshot->>'razon_social'), ''), nullif(btrim(q.client_snapshot->>'nombre'), '')),
      'client_cuit', nullif(btrim(q.client_snapshot->>'cuit'), ''), 'order_ref', q.order_ref, 'channel', q.channel, 'branch', q.branch, 'cartera_label', q.cartera_label,
      'requester', public._com_label(q.requested_by), 'approver', public._com_label(coalesce(e.assigned_approver_id, q.assigned_approver_id)),
      'notes', q.notes, 'original_terms', coalesce(orig, q.original_terms)),
    'previous_proposal', prev,
    'distribution', jsonb_build_object('to', v_to, 'cc', v_cc));
END; $$;

-- ---------- evento → destinatarios + foto, en la MISMA transacción que la solicitud o la decisión ----------
CREATE OR REPLACE FUNCTION public._com_mail_event() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE q public.com_requests; a public.profiles; p public.profiles; va text; vp text; ok text := '^[^[:space:]<>@,;]+@[^[:space:]<>@,;]+\.[^[:space:]<>@,;]+$';
BEGIN
 IF NEW.kind NOT IN ('ENVIADA','APROBADA','APROBADA_CON_MODIFICACIONES','RECHAZADA','DEVUELTA_CON_MODIFICACIONES','CANCELADA','RETIRADA_POR_COMERCIAL','CAMBIOS_ACEPTADOS_REENVIADA') THEN RETURN NEW;END IF;
 SELECT * INTO q FROM public.com_requests WHERE id=NEW.request_id;
 SELECT * INTO p FROM public.profiles WHERE id=q.requested_by; vp:=lower(btrim(p.email));
 -- PARA: en NUEVA SOLICITUD y REENVÍO primero el aprobador asignado (tiene que evaluar), luego el solicitante
 IF NEW.kind IN ('ENVIADA','CAMBIOS_ACEPTADOS_REENVIADA') AND coalesce(NEW.assigned_approver_id,q.assigned_approver_id) IS NOT NULL THEN
  SELECT * INTO a FROM public.profiles WHERE id=coalesce(NEW.assigned_approver_id,q.assigned_approver_id); va:=lower(btrim(a.email));
  INSERT INTO public.com_decision_mail_outbox(event_id,request_id,recipient_user,recipient,kind,event_kind,request_number,state,error_code)
  VALUES(NEW.id,q.id,a.id,va,'APPROVER',NEW.kind,q.number,CASE WHEN va~ok THEN 'PENDING' ELSE 'SKIPPED' END,CASE WHEN va IS NULL OR va!~ok THEN 'APPROVER_WITHOUT_EMAIL' END) ON CONFLICT DO NOTHING;
 END IF;
 INSERT INTO public.com_decision_mail_outbox(event_id,request_id,recipient_user,recipient,kind,event_kind,request_number,state,error_code)
 VALUES(NEW.id,q.id,p.id,vp,'AUTHOR',NEW.kind,q.number,CASE WHEN vp~ok THEN 'PENDING' ELSE 'SKIPPED' END,CASE WHEN vp IS NULL OR vp='' THEN 'AUTHOR_WITHOUT_EMAIL' END) ON CONFLICT DO NOTHING;
 -- CC: SOLO copias RATIFICADAS / AUTORIZADAS (las pendientes de ratificación no reciben detalle). Sin duplicar a los principales.
 INSERT INTO public.com_decision_mail_outbox(event_id,request_id,recipient,kind,event_kind,request_number)
 SELECT NEW.id,q.id,c.address,'COPY',NEW.kind,q.number FROM public.com_mail_copy_authorizations c
 WHERE c.status='AUTORIZADA' AND c.address IS DISTINCT FROM vp AND c.address IS DISTINCT FROM va ORDER BY c.address ON CONFLICT DO NOTHING;
 BEGIN
  INSERT INTO public.com_decision_mail_payloads(event_id,payload,source) VALUES(NEW.id,public._com_decision_mail_payload(NEW.id),'EVENTO') ON CONFLICT DO NOTHING;
 EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'COM_MAIL_PAYLOAD_DEFERRED event=% (%)', NEW.id, SQLSTATE;   -- nunca bloquea la solicitud: se arma al procesar
 END;
 RETURN NEW;
END;$$;

-- ---------- toma anterior DESACTIVADA: si se desplegara por error el trabajador publicado, no toma nada de la V2 ----------
CREATE OR REPLACE FUNCTION public.comm_decision_mail_claim() RETURNS SETOF public.com_decision_mail_outbox LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN RETURN; END;$$;

-- ---------- verificación del destinatario inmediatamente antes de enviar ----------
CREATE OR REPLACE FUNCTION public.comm_decision_mail_guard(p_id bigint,p_token uuid) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE d public.com_decision_mail_outbox;p public.profiles;c public.com_mail_copy_authorizations;
BEGIN
 SELECT * INTO d FROM public.com_decision_mail_outbox WHERE id=p_id AND token=p_token AND state='PROCESSING' FOR UPDATE;
 IF NOT FOUND THEN RETURN false;END IF;
 IF d.kind IN ('AUTHOR','APPROVER') THEN
  SELECT * INTO p FROM public.profiles WHERE id=d.recipient_user;
  IF p.status IS DISTINCT FROM 'ACTIVO' OR lower(btrim(p.email)) IS DISTINCT FROM d.recipient
     OR NOT coalesce(public.user_has_perm(p.id,CASE d.kind WHEN 'AUTHOR' THEN 'com.request' ELSE 'com.approve' END),false) THEN
   UPDATE public.com_decision_mail_outbox SET state='SKIPPED',error_code=d.kind||'_NO_LONGER_AUTHORIZED' WHERE id=p_id;RETURN false;END IF;
 ELSE
  SELECT * INTO c FROM public.com_mail_copy_authorizations WHERE address=d.recipient;
  IF c.status IS DISTINCT FROM 'AUTORIZADA' THEN
   UPDATE public.com_decision_mail_outbox SET state='SKIPPED',error_code=CASE WHEN c.status='PENDIENTE_RATIFICACION' THEN 'COPY_NOT_RATIFIED' ELSE 'COPY_REMOVED' END WHERE id=p_id;RETURN false;END IF;
 END IF;
 RETURN true;
END;$$;

-- ---------- V3 · incidencias de integridad (retención + revisión administrativa controlada; se CONSERVAN al revertir) ----------
CREATE TABLE IF NOT EXISTS public.com_decision_mail_incidents (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, at timestamptz NOT NULL DEFAULT now(),
  event_id bigint NOT NULL REFERENCES public.com_request_events(id), request_number text, event_kind text,
  code text NOT NULL CHECK (code IN ('SNAPSHOT_MISSING', 'SNAPSHOT_INCONSISTENT', 'DETALLE_INVALIDO')), detail text,
  status text NOT NULL DEFAULT 'ABIERTA' CHECK (status IN ('ABIERTA', 'RESUELTA_ENVIO', 'RESUELTA_DESCARTE')),
  resolved_by uuid, resolved_at timestamptz, resolution_note text);
CREATE UNIQUE INDEX IF NOT EXISTS com_decision_mail_incidents_open ON public.com_decision_mail_incidents(event_id, code) WHERE status = 'ABIERTA';
ALTER TABLE public.com_decision_mail_incidents ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.com_decision_mail_incidents FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.com_decision_mail_incidents TO service_role;
-- solo se registra la resolución, UNA vez; nunca se borra ni se reescribe
CREATE OR REPLACE FUNCTION public._com_mail_incident_guard() RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF TG_OP = 'DELETE' OR OLD.status <> 'ABIERTA' OR NEW.id <> OLD.id OR NEW.at <> OLD.at OR NEW.event_id <> OLD.event_id OR NEW.code <> OLD.code OR NEW.detail IS DISTINCT FROM OLD.detail THEN
    RAISE EXCEPTION 'IMMUTABLE: las incidencias de correo solo se resuelven una vez y no se borran' USING errcode = '42501'; END IF;
  RETURN NEW;
END; $$;
REVOKE ALL ON FUNCTION public._com_mail_incident_guard() FROM PUBLIC, anon, authenticated;
DO $t$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'com_decision_mail_incidents_guard') THEN
    CREATE TRIGGER com_decision_mail_incidents_guard BEFORE UPDATE OR DELETE ON public.com_decision_mail_incidents FOR EACH ROW EXECUTE FUNCTION public._com_mail_incident_guard(); END IF;
END $t$;

-- retiene TODOS los avisos pendientes de ese evento (no solo el tomado) y registra UNA incidencia abierta por evento y causa
CREATE OR REPLACE FUNCTION public._com_mail_hold_event(p_row bigint, p_event bigint, p_code text, p_detail text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE d public.com_decision_mail_outbox;
BEGIN
  SELECT * INTO d FROM public.com_decision_mail_outbox WHERE id = p_row;
  INSERT INTO public.com_decision_mail_incidents(event_id, request_number, event_kind, code, detail)
    VALUES (p_event, d.request_number, d.event_kind, p_code, left(p_detail, 500)) ON CONFLICT (event_id, code) WHERE status = 'ABIERTA' DO NOTHING;
  UPDATE public.com_decision_mail_outbox SET state = 'HELD', error_code = p_code, token = NULL
   WHERE event_id = p_event AND (id = p_row OR state IN ('PENDING', 'ERROR'));
END; $$;

-- foto ↔ evento INMUTABLE: si algo no coincide, no se envía
CREATE OR REPLACE FUNCTION public._com_decision_mail_payload_issue(pl jsonb, d public.com_decision_mail_outbox) RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE e public.com_request_events; q public.com_requests; env jsonb;
BEGIN
  IF pl IS NULL OR jsonb_typeof(pl) <> 'object' OR (pl->>'version') NOT IN ('1', '2') THEN RETURN 'versión de la foto desconocida'; END IF;
  SELECT * INTO e FROM public.com_request_events WHERE id = d.event_id;
  SELECT * INTO q FROM public.com_requests WHERE id = d.request_id;
  IF e.id IS NULL OR q.id IS NULL THEN RETURN 'evento o solicitud inexistente'; END IF;
  IF (pl->'event'->>'id') IS DISTINCT FROM e.id::text OR (pl->'event'->>'kind') IS DISTINCT FROM e.kind OR e.kind IS DISTINCT FROM d.event_kind THEN RETURN 'el evento de la foto no es el notificado'; END IF;
  IF (pl->'request'->>'id') IS DISTINCT FROM q.id::text OR (pl->'request'->>'number') IS DISTINCT FROM q.number OR q.number IS DISTINCT FROM d.request_number
     OR (pl->'request'->>'kind') IS DISTINCT FROM q.kind OR e.request_id IS DISTINCT FROM q.id THEN RETURN 'la solicitud de la foto no es la notificada'; END IF;
  IF (pl->'event'->>'at')::timestamptz IS DISTINCT FROM e.at OR (pl->'event'->>'reason') IS DISTINCT FROM e.reason
     OR coalesce(pl->'event'->'terms_before', 'null') IS DISTINCT FROM coalesce(e.terms_before, 'null') OR coalesce(pl->'event'->'terms_after', 'null') IS DISTINCT FROM coalesce(e.terms_after, 'null') THEN RETURN 'los datos del evento no coinciden con el registro inmutable'; END IF;
  SELECT x.terms_after INTO env FROM public.com_request_events x WHERE x.request_id = q.id AND x.kind = 'ENVIADA' ORDER BY x.seq LIMIT 1;
  IF env IS NOT NULL AND (pl->'request'->'original_terms') IS DISTINCT FROM env THEN RETURN 'las condiciones originales no coinciden con el registro inmutable'; END IF;
  IF jsonb_typeof(pl->'distribution'->'to') <> 'array' OR jsonb_typeof(pl->'distribution'->'cc') <> 'array' THEN RETURN 'la foto no tiene distribución'; END IF;
  IF d.kind <> 'COPY' AND NOT ((pl->'distribution'->'to') ? d.recipient OR (pl->'distribution'->'cc') ? d.recipient) THEN RETURN 'el destinatario principal no figura en la distribución original'; END IF;
  RETURN NULL;
END; $$;

-- ¿un principal (solicitante / aprobador) sigue habilitado? (independiente de su condición de copia)
CREATE OR REPLACE FUNCTION public._com_mail_principal_ok(p_event bigint, p_recipient text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (SELECT 1 FROM public.com_decision_mail_outbox o JOIN public.profiles p ON p.id = o.recipient_user
    WHERE o.event_id = p_event AND o.recipient = p_recipient AND o.kind IN ('AUTHOR', 'APPROVER') AND o.state <> 'SKIPPED'
      AND p.status = 'ACTIVO' AND lower(btrim(p.email)) = o.recipient
      AND coalesce(public.user_has_perm(p.id, CASE o.kind WHEN 'AUTHOR' THEN 'com.request' ELSE 'com.approve' END), false));
$$;
-- distribución EFECTIVA = original de la foto − revocados/no habilitados (orden original; CC sin duplicar Para)
CREATE OR REPLACE FUNCTION public._com_decision_mail_effective(p_event bigint, pl jsonb) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_to jsonb; v_cc jsonb;
BEGIN
  SELECT coalesce(jsonb_agg(x ORDER BY n), '[]') INTO v_to FROM jsonb_array_elements_text(pl->'distribution'->'to') WITH ORDINALITY t(x, n) WHERE public._com_mail_principal_ok(p_event, x);
  SELECT coalesce(jsonb_agg(x ORDER BY n), '[]') INTO v_cc FROM jsonb_array_elements_text(pl->'distribution'->'cc') WITH ORDINALITY t(x, n)
    WHERE NOT v_to ? x AND EXISTS (SELECT 1 FROM public.com_mail_copy_authorizations a WHERE a.address = x AND a.status = 'AUTORIZADA');
  RETURN jsonb_build_object('to', v_to, 'cc', v_cc, 'hash', md5(v_to::text || '|' || v_cc::text));
END; $$;

-- ---------- toma de a un destinatario con cupo previo, foto verificada y distribución efectiva ----------
CREATE OR REPLACE FUNCTION public.comm_decision_mail_claim_next() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE rt jsonb := public.comm_mail_runtime(); cap jsonb; d public.com_decision_mail_outbox; pl jsonb; issue text;
BEGIN
  IF rt->>'provider' IS DISTINCT FROM 'SMTP' OR NOT coalesce((rt->>'connected')::boolean, false) THEN RETURN jsonb_build_object('state', 'NOT_ACTIVE'); END IF;
  UPDATE public.com_decision_mail_outbox SET state = 'HELD', error_code = 'WORKER_INTERRUPTED' WHERE state = 'PROCESSING' AND claimed_at < now() - interval '2 minutes';
  cap := public.comm_mail_capacity();
  IF coalesce((cap->>'available')::int, 0) < 1 THEN RETURN jsonb_build_object('state', 'NO_CAPACITY', 'capacity', cap - 'daily_cap_confirmation'); END IF;
  WITH c AS (SELECT id FROM public.com_decision_mail_outbox WHERE state IN ('PENDING', 'ERROR') AND attempts < 4 AND next_at <= now() ORDER BY id FOR UPDATE SKIP LOCKED LIMIT 1)
  UPDATE public.com_decision_mail_outbox o SET state = 'PROCESSING', token = gen_random_uuid(), claimed_at = now(), attempts = o.attempts + 1
    FROM c WHERE o.id = c.id RETURNING o.* INTO d;
  IF d.id IS NULL THEN RETURN jsonb_build_object('state', 'EMPTY'); END IF;
  SELECT payload INTO pl FROM public.com_decision_mail_payloads WHERE event_id = d.event_id;
  -- V3: SIN foto no se reconstruye nada con el estado actual: se retiene y se registra la incidencia
  IF pl IS NULL THEN
    PERFORM public._com_mail_hold_event(d.id, d.event_id, 'SNAPSHOT_MISSING', 'No existe la foto del evento ' || d.event_kind || ' de ' || d.request_number || ': no se envía para no informar datos que no puedan garantizarse.');
    RETURN jsonb_build_object('state', 'ROW_HELD', 'id', d.id, 'code', 'SNAPSHOT_MISSING');
  END IF;
  -- una copia que NO figura en la distribución original no estaba autorizada al registrarse el evento: no recibe (no es una incidencia)
  IF d.kind = 'COPY' AND jsonb_typeof(pl->'distribution'->'cc') = 'array' AND NOT ((pl->'distribution'->'cc') ? d.recipient OR (pl->'distribution'->'to') ? d.recipient) THEN
    UPDATE public.com_decision_mail_outbox SET state = 'SKIPPED', token = NULL,
      error_code = CASE WHEN EXISTS (SELECT 1 FROM public.com_mail_copy_authorizations a WHERE a.address = d.recipient AND a.status = 'PENDIENTE_RATIFICACION') THEN 'COPY_NOT_RATIFIED' ELSE 'COPY_NOT_IN_DISTRIBUTION' END
     WHERE id = d.id;
    RETURN jsonb_build_object('state', 'ROW_SKIPPED', 'id', d.id);
  END IF;
  issue := public._com_decision_mail_payload_issue(pl, d);
  IF issue IS NOT NULL THEN
    PERFORM public._com_mail_hold_event(d.id, d.event_id, 'SNAPSHOT_INCONSISTENT', issue);
    RETURN jsonb_build_object('state', 'ROW_HELD', 'id', d.id, 'code', 'SNAPSHOT_INCONSISTENT');
  END IF;
  RETURN jsonb_build_object('state', 'CLAIMED', 'payload', pl, 'distribution', public._com_decision_mail_effective(d.event_id, pl),
    'job', jsonb_build_object('id', d.id, 'token', d.token, 'event_id', d.event_id, 'request_id', d.request_id, 'recipient', d.recipient, 'kind', d.kind,
      'event_kind', d.event_kind, 'request_number', d.request_number, 'attempts', d.attempts));
END; $$;

-- distribución efectiva AHORA (el trabajador la compara justo antes de MAIL FROM y de DATA)
CREATE OR REPLACE FUNCTION public.comm_decision_mail_distribution(p_id bigint, p_token uuid) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE d public.com_decision_mail_outbox; pl jsonb;
BEGIN
  SELECT * INTO d FROM public.com_decision_mail_outbox WHERE id = p_id AND token = p_token AND state = 'PROCESSING';
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT payload INTO pl FROM public.com_decision_mail_payloads WHERE event_id = d.event_id;
  RETURN CASE WHEN pl IS NULL THEN NULL ELSE public._com_decision_mail_effective(d.event_id, pl) END;
END; $$;
-- traza de cada intento: distribución efectiva, huella y clave (historial; la foto conserva la original)
CREATE OR REPLACE FUNCTION public.comm_decision_mail_note_delivery(p_id bigint, p_token uuid, p_meta jsonb) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  UPDATE public.com_decision_mail_outbox SET delivery_meta = coalesce(delivery_meta, '[]'::jsonb) || jsonb_build_array(coalesce(p_meta, '{}'::jsonb) || jsonb_build_object('at', now(), 'attempt', attempts))
   WHERE id = p_id AND token = p_token AND state = 'PROCESSING';
  RETURN FOUND;
END; $$;
-- incidencia detectada por el trabajador (p. ej. la plantilla rechaza la foto): retención + incidencia, nunca envío
CREATE OR REPLACE FUNCTION public.comm_decision_mail_hold(p_id bigint, p_token uuid, p_code text, p_detail text) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE d public.com_decision_mail_outbox;
BEGIN
  IF p_code NOT IN ('SNAPSHOT_INCONSISTENT', 'DETALLE_INVALIDO') THEN RAISE EXCEPTION 'INVALID_INCIDENT_CODE'; END IF;
  SELECT * INTO d FROM public.com_decision_mail_outbox WHERE id = p_id AND token = p_token AND state = 'PROCESSING' FOR UPDATE;
  IF NOT FOUND THEN RETURN false; END IF;
  PERFORM public._com_mail_hold_event(d.id, d.event_id, p_code, p_detail);
  RETURN true;
END; $$;
-- estado AGREGADO de TODAS las claves de un (evento, destinatario) en el ledger: publicada, V2 y por contenido (V3)
CREATE OR REPLACE FUNCTION public.comm_decision_mail_ledger_state(p_event bigint, p_recipient text) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  WITH k AS (SELECT 'decisiones:evento:' || p_event || ':' || p_recipient AS base),
       l AS (SELECT l.* FROM public.comm_smtp_ledger l, k WHERE l.op_key = k.base OR (l.op_key > k.base || ':' AND l.op_key < k.base || ';'))
  SELECT CASE WHEN bool_or(state = 'ACCEPTED') THEN jsonb_build_object('state', 'ACCEPTED', 'provider_id', (array_agg(provider_id) FILTER (WHERE state = 'ACCEPTED'))[1])
              WHEN bool_or(state IN ('HELD', 'PROCESSING')) THEN jsonb_build_object('state', 'HELD')
              WHEN bool_or(state = 'REJECTED') THEN jsonb_build_object('state', 'REJECTED') END FROM l;
$$;

CREATE OR REPLACE FUNCTION public.comm_decision_mail_release(p_id bigint, p_token uuid, p_code text) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  UPDATE public.com_decision_mail_outbox SET state = 'PENDING', token = NULL, attempts = greatest(attempts - 1, 0), next_at = now() + interval '1 minute', error_code = left(p_code, 80)
   WHERE id = p_id AND token = p_token AND state = 'PROCESSING';
  RETURN FOUND;
END; $$;

-- ---------- copias adicionales: autorización validada en el SERVIDOR ----------
CREATE OR REPLACE FUNCTION public._com_mail_copies_sync() RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  UPDATE public.com_mail_settings SET copies = coalesce((SELECT array_agg(address ORDER BY address) FROM public.com_mail_copy_authorizations WHERE status <> 'REVOCADA'), '{}'),
    changed_by = auth.uid(), changed_at = now() WHERE id = 1;
$$;

CREATE OR REPLACE FUNCTION public.com_mail_copy_authorize(p_addresses text[], p_scope text, p_confirm boolean) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE x text; v text; prev public.com_mail_copy_authorizations; n int; list text[] := '{}';
BEGIN
  IF NOT coalesce(public._comm_mail_admin(), false) THEN RAISE EXCEPTION 'FORBIDDEN' USING errcode = '42501'; END IF;
  IF p_confirm IS NOT TRUE OR p_scope IS DISTINCT FROM 'DETALLE_COMERCIAL_COMPLETO_CC_VISIBLE' THEN
    RAISE EXCEPTION 'AUTHORIZATION_CONFIRMATION_REQUIRED: confirmá que las direcciones están autorizadas a recibir el detalle comercial completo y a figurar en copia visible' USING errcode = '22023'; END IF;
  FOREACH x IN ARRAY coalesce(p_addresses, '{}') LOOP
    v := public._com_mail_norm(x);
    IF v IS NULL THEN RAISE EXCEPTION 'INVALID_EMAIL_LIST' USING errcode = '22023'; END IF;
    IF NOT v = ANY (list) THEN list := list || v; END IF;
  END LOOP;
  IF cardinality(list) = 0 THEN RAISE EXCEPTION 'INVALID_EMAIL_LIST' USING errcode = '22023'; END IF;
  PERFORM 1 FROM public.com_mail_settings WHERE id = 1 FOR UPDATE;
  FOREACH v IN ARRAY list LOOP
    SELECT * INTO prev FROM public.com_mail_copy_authorizations WHERE address = v FOR UPDATE;
    IF prev.status = 'AUTORIZADA' THEN CONTINUE; END IF;
    INSERT INTO public.com_mail_copy_authorizations(address, status, scope, visible_cc, authorized_by, authorized_at, revoked_by, revoked_at, updated_at)
      VALUES (v, 'AUTORIZADA', p_scope, true, auth.uid(), now(), NULL, NULL, now())
      ON CONFLICT (address) DO UPDATE SET status = 'AUTORIZADA', scope = p_scope, visible_cc = true, authorized_by = auth.uid(), authorized_at = now(), revoked_by = NULL, revoked_at = NULL, updated_at = now();
    INSERT INTO public.com_mail_copy_authorization_log(actor, address, action, scope, before_status, after_status, origin)
      VALUES (auth.uid(), v, CASE prev.status WHEN 'PENDIENTE_RATIFICACION' THEN 'RATIFICADA' WHEN 'REVOCADA' THEN 'REAUTORIZADA' ELSE 'AUTORIZADA' END, p_scope, prev.status, 'AUTORIZADA', 'com_mail_copy_authorize');
  END LOOP;
  SELECT count(*) INTO n FROM public.com_mail_copy_authorizations WHERE status <> 'REVOCADA';
  IF n > 20 THEN RAISE EXCEPTION 'INVALID_EMAIL_LIST: máximo 20 direcciones adicionales' USING errcode = '22023'; END IF;
  PERFORM public._com_mail_copies_sync();
  INSERT INTO public.audit_log(actor_id, action, target_type, target_id, before, after) VALUES (auth.uid(), 'COM_MAIL_COPIES_AUTHORIZED', 'com_mail_settings', '1', NULL, jsonb_build_object('addresses', list, 'scope', p_scope));
  RETURN public.com_mail_settings_get();
END; $$;

CREATE OR REPLACE FUNCTION public.com_mail_copy_revoke(p_addresses text[]) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE x text; v text; prev public.com_mail_copy_authorizations; done text[] := '{}';
BEGIN
  IF NOT coalesce(public._comm_mail_admin(), false) THEN RAISE EXCEPTION 'FORBIDDEN' USING errcode = '42501'; END IF;
  PERFORM 1 FROM public.com_mail_settings WHERE id = 1 FOR UPDATE;
  FOREACH x IN ARRAY coalesce(p_addresses, '{}') LOOP
    v := lower(btrim(x));
    SELECT * INTO prev FROM public.com_mail_copy_authorizations WHERE address = v FOR UPDATE;
    IF NOT FOUND OR prev.status = 'REVOCADA' THEN CONTINUE; END IF;
    UPDATE public.com_mail_copy_authorizations SET status = 'REVOCADA', revoked_by = auth.uid(), revoked_at = now(), updated_at = now() WHERE address = v;
    INSERT INTO public.com_mail_copy_authorization_log(actor, address, action, scope, before_status, after_status, origin)
      VALUES (auth.uid(), v, 'REVOCADA', prev.scope, prev.status, 'REVOCADA', 'com_mail_copy_revoke');
    done := done || v;
  END LOOP;
  PERFORM public._com_mail_copies_sync();
  IF cardinality(done) > 0 THEN INSERT INTO public.audit_log(actor_id, action, target_type, target_id, before, after) VALUES (auth.uid(), 'COM_MAIL_COPIES_REVOKED', 'com_mail_settings', '1', NULL, jsonb_build_object('addresses', done)); END IF;
  RETURN public.com_mail_settings_get();
END; $$;

-- Función publicada de guardado de copias: se conserva la firma, pero ya NO puede autorizar. Altas → PENDIENTE DE RATIFICACIÓN;
-- bajas → REVOCADA. Una llamada directa por RPC nunca habilita el envío de detalle.
CREATE OR REPLACE FUNCTION public.com_mail_settings_set(p_copies text[]) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v text[];oldv text[];a text;prev public.com_mail_copy_authorizations;
BEGIN IF NOT coalesce(public._comm_mail_admin(),false) THEN RAISE EXCEPTION 'FORBIDDEN' USING errcode='42501';END IF;
 SELECT coalesce(array_agg(DISTINCT lower(btrim(x)) ORDER BY lower(btrim(x))),'{}') INTO v FROM unnest(coalesce(p_copies,'{}')) x WHERE btrim(x)<>'';
 IF cardinality(v)>20 OR EXISTS(SELECT 1 FROM unnest(v)x WHERE public._com_mail_norm(x) IS NULL) THEN RAISE EXCEPTION 'INVALID_EMAIL_LIST';END IF;
 SELECT copies INTO oldv FROM public.com_mail_settings WHERE id=1 FOR UPDATE;
 FOREACH a IN ARRAY v LOOP
  SELECT * INTO prev FROM public.com_mail_copy_authorizations WHERE address=a FOR UPDATE;
  IF FOUND AND prev.status<>'REVOCADA' THEN CONTINUE;END IF;
  INSERT INTO public.com_mail_copy_authorizations(address,status,updated_at) VALUES(a,'PENDIENTE_RATIFICACION',now())
   ON CONFLICT(address) DO UPDATE SET status='PENDIENTE_RATIFICACION',scope=NULL,visible_cc=false,authorized_by=NULL,authorized_at=NULL,updated_at=now();
  INSERT INTO public.com_mail_copy_authorization_log(actor,address,action,before_status,after_status,origin) VALUES(auth.uid(),a,'ALTA_SIN_RATIFICAR',prev.status,'PENDIENTE_RATIFICACION','com_mail_settings_set');
 END LOOP;
 FOR prev IN SELECT * FROM public.com_mail_copy_authorizations WHERE status<>'REVOCADA' AND NOT address=ANY(v) FOR UPDATE LOOP
  UPDATE public.com_mail_copy_authorizations SET status='REVOCADA',revoked_by=auth.uid(),revoked_at=now(),updated_at=now() WHERE address=prev.address;
  INSERT INTO public.com_mail_copy_authorization_log(actor,address,action,scope,before_status,after_status,origin) VALUES(auth.uid(),prev.address,'REVOCADA',prev.scope,prev.status,'REVOCADA','com_mail_settings_set');
 END LOOP;
 PERFORM public._com_mail_copies_sync();
 INSERT INTO public.audit_log(actor_id,action,target_type,target_id,before,after) VALUES(auth.uid(),'COM_MAIL_RECIPIENTS_CHANGED','com_mail_settings','1',jsonb_build_object('copies',oldv),jsonb_build_object('copies',v,'nota','altas sin ratificar: no reciben hasta autorizarse'));
 RETURN public.com_mail_settings_get();END;$$;

-- ---------- V3 · revisión administrativa CONTROLADA de una incidencia (Administrador General con sesión vigente) ----------
--  · DESCARTAR: los avisos retenidos de ese evento quedan SKIPPED (DESCARTADO_REVISION). Nada se envía.
--  · ENVIAR_CON_DATOS_REGISTRADOS (solo si FALTA la foto): se arma con los datos INMUTABLES (eventos, condiciones originales, motivo,
--    fechas, quién resolvió) y los nombres vigentes a la fecha de la revisión, que el administrador confirma; la foto queda marcada
--    REVISION_ADMINISTRATIVA con quién, cuándo y su nota, y el correo lo aclara. Una foto INCONSISTENTE no se reemplaza: solo se descarta.
CREATE OR REPLACE FUNCTION public.com_mail_incident_resolve(p_incident bigint, p_action text, p_confirm boolean, p_note text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE i public.com_decision_mail_incidents; pl jsonb; n int;
BEGIN
  IF NOT coalesce(public._comm_mail_admin(), false) THEN RAISE EXCEPTION 'FORBIDDEN' USING errcode = '42501'; END IF;
  IF p_confirm IS NOT TRUE OR length(btrim(coalesce(p_note, ''))) < 5 THEN RAISE EXCEPTION 'REVIEW_CONFIRMATION_REQUIRED: confirmá la revisión e indicá una nota (mínimo 5 caracteres)' USING errcode = '22023'; END IF;
  SELECT * INTO i FROM public.com_decision_mail_incidents WHERE id = p_incident FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'NOT_FOUND' USING errcode = 'P0002'; END IF;
  IF i.status <> 'ABIERTA' THEN RAISE EXCEPTION 'ALREADY_RESOLVED' USING errcode = '40001'; END IF;
  IF EXISTS (SELECT 1 FROM public.com_decision_mail_outbox WHERE event_id = i.event_id AND state = 'PROCESSING') THEN RAISE EXCEPTION 'BUSY: reintentá en unos segundos' USING errcode = '40001'; END IF;
  IF p_action = 'DESCARTAR' THEN
    UPDATE public.com_decision_mail_outbox SET state = 'SKIPPED', error_code = 'DESCARTADO_REVISION' WHERE event_id = i.event_id AND state = 'HELD' AND error_code = i.code;
    GET DIAGNOSTICS n = ROW_COUNT;
    UPDATE public.com_decision_mail_incidents SET status = 'RESUELTA_DESCARTE', resolved_by = auth.uid(), resolved_at = now(), resolution_note = left(btrim(p_note), 500) WHERE id = i.id;
  ELSIF p_action = 'ENVIAR_CON_DATOS_REGISTRADOS' THEN
    IF i.code <> 'SNAPSHOT_MISSING' OR EXISTS (SELECT 1 FROM public.com_decision_mail_payloads WHERE event_id = i.event_id) THEN
      RAISE EXCEPTION 'ACTION_NOT_ALLOWED: solo se puede enviar cuando falta la foto; una foto inconsistente solo se descarta' USING errcode = '22023'; END IF;
    pl := public._com_decision_mail_payload(i.event_id) || jsonb_build_object('review', jsonb_build_object('by', public._com_label(auth.uid()), 'at', now(), 'note', left(btrim(p_note), 300)));
    INSERT INTO public.com_decision_mail_payloads(event_id, payload, source) VALUES (i.event_id, pl, 'REVISION_ADMINISTRATIVA');
    UPDATE public.com_decision_mail_outbox SET state = 'PENDING', error_code = 'LIBERADO_REVISION', attempts = 0, next_at = now(), token = NULL
     WHERE event_id = i.event_id AND state = 'HELD' AND error_code = 'SNAPSHOT_MISSING';
    GET DIAGNOSTICS n = ROW_COUNT;
    UPDATE public.com_decision_mail_incidents SET status = 'RESUELTA_ENVIO', resolved_by = auth.uid(), resolved_at = now(), resolution_note = left(btrim(p_note), 500) WHERE id = i.id;
  ELSE RAISE EXCEPTION 'INVALID_ACTION' USING errcode = '22023'; END IF;
  INSERT INTO public.audit_log(actor_id, action, target_type, target_id, before, after) VALUES (auth.uid(), 'COM_MAIL_INCIDENT_' || p_action, 'com_decision_mail_incidents', i.id::text,
    jsonb_build_object('code', i.code, 'event_id', i.event_id), jsonb_build_object('rows', n, 'note', left(btrim(p_note), 300)));
  RETURN public.com_mail_settings_get();
END; $$;

-- ---------- panel (Administrador General con sesión vigente) ----------
CREATE OR REPLACE FUNCTION public.com_mail_settings_get() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE rt jsonb; cap jsonb;
BEGIN IF NOT coalesce(public._comm_mail_admin(),false) THEN RAISE EXCEPTION 'FORBIDDEN' USING errcode='42501';END IF;
 rt := public.comm_mail_runtime(); cap := public.comm_mail_capacity();
 RETURN (SELECT jsonb_build_object('copies',s.copies,'author_always',true,'detail_version',2,'distribution','PARA_Y_CC_VISIBLE','scope_required','DETALLE_COMERCIAL_COMPLETO_CC_VISIBLE',
   'recipients',coalesce((SELECT jsonb_agg(jsonb_build_object('address',a.address,'status',a.status,'scope',a.scope,'visible_cc',a.visible_cc,
      'authorized_by',public._com_label(a.authorized_by),'authorized_at',a.authorized_at,'revoked_by',public._com_label(a.revoked_by),'revoked_at',a.revoked_at) ORDER BY a.status<>'PENDIENTE_RATIFICACION', a.address)
      FROM public.com_mail_copy_authorizations a),'[]'::jsonb),
   'authorization_log',coalesce((SELECT jsonb_agg(x ORDER BY x.id DESC) FROM (SELECT l.id,l.at,public._com_label(l.actor) actor,l.address,l.action,l.scope,l.before_status,l.after_status,l.origin
      FROM public.com_mail_copy_authorization_log l ORDER BY l.id DESC LIMIT 20)x),'[]'::jsonb),
   'transport',jsonb_build_object('provider',rt->>'provider','connected',coalesce((rt->>'connected')::boolean,false),'sender',CASE WHEN rt->>'provider'='SMTP' THEN rt->>'email' END,
     'hourly_cap',cap->'hourly_cap','hourly_used',cap->'hourly_used','daily_cap',cap->'daily_cap','daily_used',cap->'daily_used',
     'daily_cap_confirmed',cap->'daily_cap_confirmed','daily_cap_confirmed_at',cap->'daily_cap_confirmed_at'),
   'incidents',coalesce((SELECT jsonb_agg(x ORDER BY x.status<>'ABIERTA', x.id DESC) FROM (SELECT i.id,i.at,i.request_number,i.event_kind,i.code,i.detail,i.status,public._com_label(i.resolved_by) resolved_by,i.resolved_at,i.resolution_note,
      (SELECT count(*) FROM public.com_decision_mail_outbox o WHERE o.event_id=i.event_id AND o.state='HELD' AND o.error_code=i.code) held_rows,
      i.code='SNAPSHOT_MISSING' AND NOT EXISTS (SELECT 1 FROM public.com_decision_mail_payloads p WHERE p.event_id=i.event_id) can_send
      FROM public.com_decision_mail_incidents i ORDER BY i.status<>'ABIERTA', i.id DESC LIMIT 30)x),'[]'::jsonb),
   'history',coalesce((SELECT jsonb_agg(x ORDER BY x.id DESC) FROM (SELECT id,request_number,event_kind,kind,recipient,state,attempts,created_at,sent_at,next_at,error_code
      FROM public.com_decision_mail_outbox ORDER BY id DESC LIMIT 40)x),'[]'::jsonb))
  FROM public.com_mail_settings s WHERE id=1);END;$$;

-- ---------- privilegios ----------
REVOKE ALL ON FUNCTION public.comm_mail_confirm_daily_cap(int,text), public._com_mail_hold_event(bigint,bigint,text,text), public._com_decision_mail_payload_issue(jsonb,public.com_decision_mail_outbox),
  public._com_mail_principal_ok(bigint,text), public._com_decision_mail_effective(bigint,jsonb), public.comm_decision_mail_distribution(bigint,uuid), public.comm_decision_mail_note_delivery(bigint,uuid,jsonb),
  public.comm_decision_mail_hold(bigint,uuid,text,text), public.comm_decision_mail_ledger_state(bigint,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.comm_mail_confirm_daily_cap(int,text), public.comm_decision_mail_distribution(bigint,uuid), public.comm_decision_mail_note_delivery(bigint,uuid,jsonb),
  public.comm_decision_mail_hold(bigint,uuid,text,text), public.comm_decision_mail_ledger_state(bigint,text) TO service_role;
REVOKE ALL ON FUNCTION public.com_mail_incident_resolve(bigint,text,boolean,text) FROM PUBLIC, anon; GRANT EXECUTE ON FUNCTION public.com_mail_incident_resolve(bigint,text,boolean,text) TO authenticated;
REVOKE ALL ON FUNCTION public.comm_mail_capacity(), public.comm_mail_set_daily_cap(int), public._com_decision_mail_payload(bigint), public._com_mail_norm(text),
  public.comm_decision_mail_claim_next(), public.comm_decision_mail_release(bigint,uuid,text), public._com_mail_copies_sync(),
  public.comm_smtp_claim(text,text), public._com_mail_event(), public.comm_decision_mail_claim(), public.comm_decision_mail_guard(bigint,uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.comm_mail_capacity(), public.comm_mail_set_daily_cap(int), public.comm_decision_mail_claim_next(), public.comm_decision_mail_release(bigint,uuid,text),
  public.comm_smtp_claim(text,text), public.comm_decision_mail_claim(), public.comm_decision_mail_guard(bigint,uuid) TO service_role;
REVOKE ALL ON FUNCTION public.com_mail_settings_get(), public.com_mail_settings_set(text[]), public.com_mail_copy_authorize(text[],text,boolean), public.com_mail_copy_revoke(text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.com_mail_settings_get(), public.com_mail_settings_set(text[]), public.com_mail_copy_authorize(text[],text,boolean), public.com_mail_copy_revoke(text[]) TO authenticated;
COMMENT ON TABLE public.com_mail_detail_install IS 'OKD:CORREO_AUTORIZACIONES_V3';
INSERT INTO public.comm_smtp_audit(action, detail) VALUES ('COM_DECISION_MAIL_V3_INSTALLED', jsonb_build_object('daily_cap', (SELECT daily_cap FROM public.comm_mail_transport WHERE id = 1), 'version', 3));
COMMIT;
