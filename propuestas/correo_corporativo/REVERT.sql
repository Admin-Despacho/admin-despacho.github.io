-- No ejecutar mientras haya trabajadores activos. Restaurar los Edge originales después de este cambio y antes de retirar RPC nuevas.
BEGIN;
SELECT pg_advisory_xact_lock(hashtext('okd_smtp_claim'));
SELECT pg_advisory_xact_lock(hashtext('okd_comm_claim'));
DO $$BEGIN IF EXISTS(SELECT 1 FROM public.comm_deliveries WHERE status='PROCESANDO') OR EXISTS(SELECT 1 FROM public.comm_smtp_ledger WHERE state='PROCESSING') THEN RAISE EXCEPTION 'WORKERS_ACTIVE';END IF;END;$$;
DO $$BEGIN IF EXISTS(SELECT 1 FROM public.comm_smtp_ledger WHERE state IN ('ACCEPTED','HELD') AND rollback_reviewed_at IS NULL) THEN RAISE EXCEPTION 'RECONCILE_SMTP_LEDGER_BEFORE_LEGACY';END IF;END;$$;
ALTER TABLE public.com_request_events DISABLE TRIGGER com_corporate_mail_event;
UPDATE public.comm_mail_transport SET provider='LEGACY',verified_at=NULL,reverted=true,changed_at=now() WHERE id=1;
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
  if not g.connected or g.needs_reconnect then raise exception 'GMAIL_NOT_CONNECTED: conectá Gmail antes de programar' using errcode = '22023'; end if;
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
  if not g.connected or g.needs_reconnect then update public.comm_deliveries set status = 'PENDIENTE', claim_token = null, attempts = attempts - 1, updated_at = now() where id = p_id; return 'NO_CONNECTION'; end if;
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
  return jsonb_build_object('connected', g.connected, 'email', g.email, 'connected_at', g.connected_at, 'needs_reconnect', g.needs_reconnect, 'last_error', g.last_error,
    'last_error_at', g.last_error_at, 'last_dispatch', case when d.id is null then null else jsonb_build_object('at', d.at, 'status', d.status, 'sent', d.sent, 'note', d.note) end);
end; $function$
;
-- Conservar ledger, colas, copias e historial. No borrar secretos ni resolver incertidumbres a ciegas.
COMMIT;
