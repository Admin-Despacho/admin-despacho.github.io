-- PROPUESTO: no aplicado. Instalación atómica; proveedor LEGACY hasta activación expresa.
BEGIN;
DO $$ BEGIN
IF md5(pg_get_functiondef('public.comm_activate(uuid)'::regprocedure)) <> '7f4324304c03340b10a300417bac7877' THEN RAISE EXCEPTION 'BASE_CHANGED_comm_activate';END IF;
IF md5(pg_get_functiondef('public.comm_check(bigint,uuid)'::regprocedure)) <> 'ffb09688c2325b9ba9fda2e9c808ac77' THEN RAISE EXCEPTION 'BASE_CHANGED_comm_check';END IF;
IF md5(pg_get_functiondef('public.comm_gmail_status()'::regprocedure)) <> '633d92b249817905f0b3e4ac19fd0fa0' THEN RAISE EXCEPTION 'BASE_CHANGED_comm_gmail_status';END IF;
END;$$;
CREATE TABLE public.comm_mail_transport (
 id int PRIMARY KEY CHECK(id=1), provider text NOT NULL DEFAULT 'LEGACY' CHECK(provider IN ('LEGACY','SMTP')),
 verified_at timestamptz, secret_version timestamptz, hourly_cap int CHECK(hourly_cap BETWEEN 1 AND 1000),
 auth_native_verified boolean NOT NULL DEFAULT false, reverted boolean NOT NULL DEFAULT false, changed_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.comm_mail_transport(id) VALUES(1);
CREATE TABLE public.comm_smtp_ledger (
 op_key text PRIMARY KEY CHECK(length(op_key)<=550), fingerprint text NOT NULL CHECK(fingerprint~'^[a-f0-9]{64}$'),
 state text NOT NULL CHECK(state IN ('PROCESSING','ACCEPTED','HELD','RETRYABLE','REJECTED','AUTH_ERROR')),
 token uuid, claimed_at timestamptz NOT NULL DEFAULT now(), provider_id text, updated_at timestamptz NOT NULL DEFAULT now(),rollback_reviewed_at timestamptz
);
CREATE TABLE public.comm_smtp_rate (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, at timestamptz NOT NULL DEFAULT now());
CREATE INDEX comm_smtp_rate_at ON public.comm_smtp_rate(at);
CREATE TABLE public.comm_smtp_audit (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,at timestamptz NOT NULL DEFAULT now(),action text NOT NULL,detail jsonb NOT NULL DEFAULT '{}');
ALTER TABLE public.comm_mail_transport ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.comm_smtp_ledger ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.comm_smtp_rate ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.comm_smtp_audit ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.comm_mail_transport,public.comm_smtp_ledger,public.comm_smtp_rate,public.comm_smtp_audit FROM PUBLIC,anon,authenticated;
GRANT SELECT,INSERT,UPDATE ON public.comm_mail_transport,public.comm_smtp_ledger,public.comm_smtp_rate,public.comm_smtp_audit TO service_role;
GRANT USAGE,SELECT ON SEQUENCE public.comm_smtp_rate_id_seq,public.comm_smtp_audit_id_seq TO service_role;

CREATE FUNCTION public.comm_mail_runtime() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT CASE WHEN t.provider='SMTP' THEN jsonb_build_object('provider','SMTP','email','fgutierrez@okaccesorios.com',
 'connected',t.verified_at IS NOT NULL AND t.secret_version IS NOT DISTINCT FROM v.updated_at,'needs_reconnect',t.verified_at IS NULL OR t.secret_version IS DISTINCT FROM v.updated_at,
 'secret_version',v.updated_at,'hourly_cap',t.hourly_cap,'available_slots',greatest(0,coalesce(t.hourly_cap,0)-(SELECT count(*) FROM public.comm_smtp_rate WHERE at>now()-interval '1 hour')))
 ELSE jsonb_build_object('provider','LEGACY','email',g.email,'connected',coalesce(g.connected,false),'needs_reconnect',coalesce(g.needs_reconnect,false)) END
 FROM public.comm_mail_transport t LEFT JOIN public.comm_gmail_status g ON g.id=1
 LEFT JOIN vault.secrets v ON v.name='comm_smtp_password' WHERE t.id=1;
$$;
CREATE FUNCTION public.comm_smtp_credentials() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT jsonb_build_object('host','wo47.wiroos.host','port',465,'user','fgutierrez@okaccesorios.com','from','fgutierrez@okaccesorios.com','password',v.decrypted_secret,'secret_version',v.updated_at)
 FROM vault.decrypted_secrets v WHERE v.name='comm_smtp_password' AND length(v.decrypted_secret)>0;
$$;
CREATE FUNCTION public.comm_smtp_probe_result(p_ok boolean,p_secret_version timestamptz) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM vault.secrets WHERE name='comm_smtp_password' AND updated_at=p_secret_version) THEN RETURN false; END IF;
 UPDATE public.comm_mail_transport SET verified_at=CASE WHEN p_ok THEN now() END,secret_version=p_secret_version WHERE id=1;
 INSERT INTO public.comm_smtp_audit(action,detail) VALUES('SMTP_AUTH_CHECK',jsonb_build_object('ok',p_ok)); RETURN p_ok;
END;$$;
CREATE FUNCTION public.comm_smtp_lookup(p_key text) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT jsonb_build_object('state',CASE WHEN state='PROCESSING' THEN 'HELD' ELSE state END,'provider_id',provider_id) FROM public.comm_smtp_ledger WHERE op_key=p_key;
$$;
CREATE FUNCTION public.comm_smtp_claim(p_key text,p_fingerprint text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
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
CREATE FUNCTION public.comm_smtp_finish(p_key text,p_token uuid,p_state text,p_provider_id text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF p_state NOT IN ('ACCEPTED','HELD','RETRYABLE','REJECTED','AUTH_ERROR') THEN RAISE EXCEPTION 'INVALID_STATE';END IF;
 UPDATE public.comm_smtp_ledger SET state=p_state,provider_id=left(p_provider_id,100),updated_at=now()
 WHERE op_key=p_key AND token=p_token AND state='PROCESSING';
 IF NOT FOUND THEN RAISE EXCEPTION 'SMTP_CLAIM_LOST';END IF;
END;$$;
CREATE TABLE public.comm_mail_components(component text PRIMARY KEY,build text NOT NULL,seen_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.comm_mail_components ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.comm_mail_components FROM PUBLIC,anon,authenticated;GRANT SELECT,INSERT,UPDATE ON public.comm_mail_components TO service_role;
CREATE FUNCTION public.comm_mail_register(p_component text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$BEGIN
IF p_component NOT IN ('comm-dispatcher','internal-approvals','commercial-reports','password-recovery') THEN RAISE EXCEPTION 'INVALID_COMPONENT';END IF;
INSERT INTO public.comm_mail_components(component,build) VALUES(p_component,'SMTP-WORK-1') ON CONFLICT(component) DO UPDATE SET build='SMTP-WORK-1',seen_at=now();END;$$;
REVOKE ALL ON FUNCTION public.comm_mail_register(text) FROM PUBLIC,anon,authenticated;GRANT EXECUTE ON FUNCTION public.comm_mail_register(text) TO service_role;
CREATE FUNCTION public.comm_mail_set_provider(p_provider text,p_hourly_cap int DEFAULT NULL,p_auth_native_verified boolean DEFAULT false) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF EXISTS(SELECT 1 FROM public.comm_mail_transport WHERE reverted) THEN RAISE EXCEPTION 'MAIL_INSTALL_REVERTED';END IF;
 PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('okd_smtp_claim'));
 PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('okd_comm_claim'));
 IF p_provider NOT IN ('LEGACY','SMTP') THEN RAISE EXCEPTION 'INVALID_PROVIDER';END IF;
 IF EXISTS(SELECT 1 FROM public.comm_deliveries WHERE status='PROCESANDO') OR EXISTS(SELECT 1 FROM public.comm_smtp_ledger WHERE state='PROCESSING') THEN RAISE EXCEPTION 'MAIL_WORKERS_ACTIVE';END IF;
 IF p_provider='SMTP' THEN
  IF EXISTS(SELECT 1 FROM public.vehicle_inspection_email_requests WHERE error LIKE 'GMAIL_INSPECTION_HOLD:%') THEN RAISE EXCEPTION 'INSPECTION_HOLDS_REQUIRE_REVIEW';END IF;
  IF (SELECT count(*) FROM public.comm_mail_components WHERE build='SMTP-WORK-1' AND seen_at>now()-interval '24 hours')<>4 THEN RAISE EXCEPTION 'MAIL_COMPONENTS_NOT_READY';END IF;
  IF EXISTS(SELECT 1 FROM (
    SELECT error::text e FROM public.approval_email_jobs WHERE status='ERROR'
    UNION ALL SELECT error::text FROM public.customer_email_jobs WHERE status='ERROR'
    UNION ALL SELECT error::text FROM public.sheet_email_jobs WHERE status='ERROR'
    UNION ALL SELECT error::text FROM public.vehicle_service_email_jobs WHERE status='ERROR'
    UNION ALL SELECT error::text FROM public.report_emails WHERE status='ERROR'
  )x WHERE coalesce(e,'')!~'Resend (400|401|403|404|413|422|429):') THEN RAISE EXCEPTION 'LEGACY_MAIL_ERRORS_REQUIRE_REVIEW';END IF;
  IF p_hourly_cap IS NULL OR p_hourly_cap NOT BETWEEN 1 AND 1000 OR NOT p_auth_native_verified THEN RAISE EXCEPTION 'SMTP_LIMITS_OR_NATIVE_AUTH_NOT_CERTIFIED';END IF;
  IF NOT EXISTS(SELECT 1 FROM public.comm_mail_transport t JOIN vault.secrets v ON v.name='comm_smtp_password' AND v.updated_at=t.secret_version WHERE t.id=1 AND t.verified_at>now()-interval '24 hours') THEN RAISE EXCEPTION 'SMTP_AUTH_NOT_CERTIFIED';END IF;
 END IF;
 UPDATE public.comm_mail_transport SET provider=p_provider,hourly_cap=coalesce(p_hourly_cap,hourly_cap),auth_native_verified=p_auth_native_verified,changed_at=now() WHERE id=1;
 INSERT INTO public.comm_smtp_audit(action,detail) VALUES('PROVIDER_CHANGED',jsonb_build_object('provider',p_provider,'hourly_cap',p_hourly_cap));
END;$$;
DO $$DECLARE f regprocedure;BEGIN
 FOR f IN SELECT p.oid::regprocedure FROM pg_proc p WHERE p.pronamespace='public'::regnamespace AND p.proname IN ('comm_mail_runtime','comm_smtp_credentials','comm_smtp_probe_result','comm_smtp_lookup','comm_smtp_claim','comm_smtp_finish','comm_mail_set_provider') LOOP
 EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,anon,authenticated',f);EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role',f);END LOOP;
END;$$;
-- Reemplazos mínimos y verificados de funciones existentes se incorporan al generar la entrega.

-- Notificaciones de decisiones: autor obligatorio y copias configurables por Administrador General vigente.
CREATE TABLE IF NOT EXISTS public.com_mail_settings(id int PRIMARY KEY CHECK(id=1),copies text[] NOT NULL DEFAULT '{}',changed_by uuid,changed_at timestamptz NOT NULL DEFAULT now());
INSERT INTO public.com_mail_settings(id) VALUES(1) ON CONFLICT(id) DO NOTHING;
CREATE TABLE public.com_decision_mail_outbox (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,event_id bigint NOT NULL REFERENCES public.com_request_events(id),request_id uuid NOT NULL REFERENCES public.com_requests(id),
 recipient_user uuid,recipient text,kind text NOT NULL CHECK(kind IN ('AUTHOR','COPY')),event_kind text NOT NULL,request_number text NOT NULL,
 state text NOT NULL DEFAULT 'PENDING' CHECK(state IN ('PENDING','PROCESSING','SENT','SKIPPED','HELD','ERROR')),
 token uuid,attempts int NOT NULL DEFAULT 0,next_at timestamptz NOT NULL DEFAULT now(),claimed_at timestamptz,sent_at timestamptz,provider_id text,error_code text,
 created_at timestamptz NOT NULL DEFAULT now(),UNIQUE(event_id,recipient)
);
ALTER TABLE public.com_mail_settings ENABLE ROW LEVEL SECURITY;ALTER TABLE public.com_decision_mail_outbox ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.com_mail_settings,public.com_decision_mail_outbox FROM PUBLIC,anon,authenticated;
GRANT SELECT,INSERT,UPDATE ON public.com_mail_settings,public.com_decision_mail_outbox TO service_role;
GRANT USAGE,SELECT ON SEQUENCE public.com_decision_mail_outbox_id_seq TO service_role;
CREATE OR REPLACE FUNCTION public._comm_mail_admin() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT coalesce(public._com_admin(),false) AND EXISTS(SELECT 1 FROM auth.sessions s WHERE s.user_id=auth.uid() AND s.id::text=auth.jwt()->>'session_id' AND (s.not_after IS NULL OR s.not_after>now()));
$$;
REVOKE ALL ON FUNCTION public._comm_mail_admin() FROM PUBLIC,anon,authenticated;
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
CREATE FUNCTION public._com_mail_event() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
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
CREATE TRIGGER com_corporate_mail_event AFTER INSERT ON public.com_request_events FOR EACH ROW EXECUTE FUNCTION public._com_mail_event();
CREATE FUNCTION public.comm_decision_mail_claim() RETURNS SETOF public.com_decision_mail_outbox LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF (public.comm_mail_runtime()->>'provider')<>'SMTP' OR NOT (public.comm_mail_runtime()->>'connected')::boolean THEN RETURN;END IF;
 UPDATE public.com_decision_mail_outbox SET state='HELD',error_code='WORKER_INTERRUPTED' WHERE state='PROCESSING' AND claimed_at<now()-interval '2 minutes';
 RETURN QUERY WITH c AS (SELECT id FROM public.com_decision_mail_outbox WHERE state IN ('PENDING','ERROR') AND attempts<4 AND next_at<=now() ORDER BY id FOR UPDATE SKIP LOCKED LIMIT 1)
 UPDATE public.com_decision_mail_outbox d SET state='PROCESSING',token=gen_random_uuid(),claimed_at=now(),attempts=attempts+1 FROM c WHERE d.id=c.id RETURNING d.*;
END;$$;
CREATE FUNCTION public.comm_decision_mail_guard(p_id bigint,p_token uuid) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
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
CREATE FUNCTION public.comm_decision_mail_finish(p_id bigint,p_token uuid,p_state text,p_reference text DEFAULT NULL,p_error text DEFAULT NULL) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF p_state NOT IN ('SENT','ERROR','HELD','SKIPPED') THEN RAISE EXCEPTION 'INVALID_STATE';END IF;
 UPDATE public.com_decision_mail_outbox SET state=p_state,provider_id=left(p_reference,100),error_code=left(p_error,80),sent_at=CASE WHEN p_state='SENT' THEN now() ELSE sent_at END,next_at=now()+interval '5 minutes'
 WHERE id=p_id AND token=p_token AND state='PROCESSING';
END;$$;
REVOKE ALL ON FUNCTION public._com_mail_event() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.com_mail_settings_get(),public.com_mail_settings_set(text[]) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.com_mail_settings_get(),public.com_mail_settings_set(text[]) TO authenticated;
REVOKE ALL ON FUNCTION public.comm_decision_mail_claim(),public.comm_decision_mail_guard(bigint,uuid),public.comm_decision_mail_finish(bigint,uuid,text,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.comm_decision_mail_claim(),public.comm_decision_mail_guard(bigint,uuid),public.comm_decision_mail_finish(bigint,uuid,text,text,text) TO service_role;

CREATE OR REPLACE FUNCTION public.comm_activate(p_id uuid)
 RETURNS comm_messages
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r public.comm_messages; g public.comm_gmail_status;
begin
  perform public._comm_need('comms.schedule');
  select * into g from public.comm_gmail_status where id = 1;
  if not coalesce((public.comm_mail_runtime()->>'connected')::boolean,false) then raise exception 'MAIL_NOT_CONNECTED: revisá la conexión del correo antes de programar' using errcode = '22023'; end if;
  select * into r from public.comm_messages where id = p_id for update; if not found then raise exception 'NO_ENCONTRADO' using errcode = 'P0002'; end if;
  if r.status <> 'BORRADOR' then raise exception 'ESTADO_INVALIDO: %', r.status using errcode = '22023'; end if;
  if r.schedule is null or coalesce(r.schedule->>'kind', '') not in ('ONCE','DAILY','WEEKLY','MONTHLY') or coalesce(r.schedule->>'time', '') !~ '^\d{2}:\d{2}$' then
    raise exception 'PROGRAMACION_INVALIDA' using errcode = '22023'; end if;
  if r.selection = '{}'::jsonb or not (coalesce((r.selection->>'all')::boolean, false) or jsonb_array_length(coalesce(r.selection->'ids', '[]')) > 0
      or jsonb_array_length(coalesce(r.selection->'branches', '[]')) > 0 or jsonb_array_length(coalesce(r.selection->'sectors', '[]')) > 0) then
    raise exception 'SIN_DESTINATARIOS' using errcode = '22023'; end if;
  if length(trim(r.subject)) = 0 then raise exception 'SIN_ASUNTO' using errcode = '22023'; end if;
  update public.comm_messages set status = 'ACTIVO', active_since = now(), cursor = now(), updated_at = now(), updated_by = auth.uid() where id = p_id returning * into r;
  perform public._comm_audit(p_id, 'COMUNICADO', 'PROGRAMADO', jsonb_build_object('schedule', r.schedule)); return r;
end; $function$
;
CREATE OR REPLACE FUNCTION public.comm_check(p_id bigint, p_token uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare d public.comm_deliveries; r public.comm_runs; m public.comm_messages; c public.comm_collaborators; g public.comm_gmail_status; s public.notification_settings; rt public.routes;
begin
  select * into d from public.comm_deliveries where id = p_id for update;
  if not found or d.status <> 'PROCESANDO' or d.claim_token is distinct from p_token then return 'LOST'; end if;
  select * into r from public.comm_runs where id = d.run_id; select * into m from public.comm_messages where id = r.message_id;
  if r.kind = 'HOJAS' then
    select * into s from public.notification_settings where id = 'DEFAULT';
    if not s.sheet_email_enabled or s.sheet_email_via <> 'GMAIL' then
      update public.comm_deliveries set status = 'CANCELADO', claim_token = null, reason = 'Correo de hojas desactivado o cambiado a Resend antes del envío', updated_at = now() where id = p_id; return 'CANCELLED'; end if;
    -- ESTADO y VERSIÓN de la hoja, inmediatamente antes de cada envío (también en reintentos)
    select * into rt from public.routes where id = (r.snapshot->>'route_id')::uuid;
    if not found or not public._comm_sheet_eligible(rt) then
      update public.comm_deliveries set status = 'CANCELADO', claim_token = null, reason = 'La hoja fue cancelada o dejó de estar publicada antes del envío', updated_at = now() where id = p_id; return 'CANCELLED'; end if;
    if rt.version <> (r.snapshot->>'route_version')::int then
      update public.comm_deliveries set status = 'CANCELADO', claim_token = null, reason = 'Hay una versión más nueva de la hoja (v' || rt.version || '): se envía esa', updated_at = now() where id = p_id; return 'CANCELLED'; end if;
  end if;
  if r.kind <> 'PRUEBA' then
    if r.status = 'CANCELADA' or m.status = 'CANCELADO' then update public.comm_deliveries set status = 'CANCELADO', claim_token = null, reason = 'Comunicado cancelado antes del envío', updated_at = now() where id = p_id; return 'CANCELLED'; end if;
    if m.status = 'PAUSADO' then update public.comm_deliveries set status = 'PENDIENTE', claim_token = null, attempts = attempts - 1, updated_at = now() where id = p_id; return 'PAUSED'; end if;
    if d.collaborator_id is not null then select * into c from public.comm_collaborators where id = d.collaborator_id;
      if found and not c.active then update public.comm_deliveries set status = 'OMITIDO', claim_token = null, reason = 'Colaborador desactivado antes del envío', updated_at = now() where id = p_id; return 'INACTIVE_RECIPIENT'; end if; end if;
  end if;
  select * into g from public.comm_gmail_status where id = 1;
  if not coalesce((public.comm_mail_runtime()->>'connected')::boolean,false) then update public.comm_deliveries set status = 'PENDIENTE', claim_token = null, attempts = attempts - 1, updated_at = now() where id = p_id; return 'NO_CONNECTION'; end if;
  return 'OK'; end; $function$
;
CREATE OR REPLACE FUNCTION public.comm_gmail_status()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare g public.comm_gmail_status; d public.comm_dispatches;
begin perform public._comm_need('comms.view');
  select * into g from public.comm_gmail_status where id = 1; select * into d from public.comm_dispatches order by id desc limit 1;
  if public.comm_mail_runtime()->>'provider'='SMTP' then
    return public.comm_mail_runtime() || jsonb_build_object('last_dispatch',case when d.id is null then null else jsonb_build_object('at',d.at,'status',d.status,'sent',d.sent,'note',d.note) end);
  end if;
  return jsonb_build_object('connected', g.connected, 'email', g.email, 'connected_at', g.connected_at, 'needs_reconnect', g.needs_reconnect, 'last_error', g.last_error,
    'last_error_at', g.last_error_at, 'last_dispatch', case when d.id is null then null else jsonb_build_object('at', d.at, 'status', d.status, 'sent', d.sent, 'note', d.note) end);
end; $function$
;
COMMIT;
