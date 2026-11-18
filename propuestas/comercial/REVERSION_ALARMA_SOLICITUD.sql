-- =====================================================================================================================
-- REVERSIÓN · ALARMA URGENTE DESDE LA SOLICITUD (001300) · NO APLICAR sin autorización.
-- Elimina SOLO las tres funciones nuevas y el índice por autorización, restaura el índice publicado por pedido, y restaura EXACTAMENTE com_alarm_raise, com_alarm_attend y com_alarm_escalate_due (huellas verificadas).
-- CONSERVA todas las alarmas, sus eventos, el registro de operaciones y los historiales (también las alarmas creadas desde la solicitud, que
-- siguen pudiendo atenderse y escalarse con las funciones restauradas).
-- =====================================================================================================================
BEGIN;
SET LOCAL lock_timeout = '5s';
DO $chk$ BEGIN
  IF to_regprocedure('public.com_alarm_raise_request(uuid,text,text)') IS NULL THEN RAISE EXCEPTION 'NADA_QUE_REVERTIR: 001300 no está aplicada. No se modificó nada.'; END IF;
END $chk$;
-- el índice publicado (una activa por PEDIDO, para todas) solo se puede restaurar si no hay dos alarmas activas del mismo pedido.
-- Si las hay (dos autorizaciones que comparten pedido), NO se toca ningún dato: hay que atenderlas antes de revertir.
DO $dup$ DECLARE n int; BEGIN
  SELECT count(*) INTO n FROM (SELECT 1 FROM public.com_alarms WHERE status = 'PENDIENTE_ATENCION' GROUP BY upper(btrim(order_ref)) HAVING count(*) > 1) x;
  IF n > 0 THEN RAISE EXCEPTION 'REVERSION_BLOQUEADA: % pedido(s) con más de una alarma activa (autorizaciones distintas). Atenderlas antes de revertir. No se modificó nada.', n; END IF;
END $dup$;
drop index if exists public.com_alarms_one_active_request;
drop index public.com_alarms_one_active;
create unique index com_alarms_one_active on public.com_alarms(upper(btrim(order_ref))) where status = 'PENDIENTE_ATENCION';
drop function public.com_alarm_request_detail(uuid);
drop function public.com_request_alarm(uuid);
drop function public.com_alarm_raise_request(uuid, text, text);
create or replace function public.com_alarm_raise(p_order_ref text, p_sheet_key text, p_client_name text, p_client_cuit text, p_reason text, p_op_id text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._com_active(); a public.com_alarms; o public.com_alarm_ops; q public.com_requests; ini uuid; st public.com_settings;
  ref text := upper(btrim(coalesce(p_order_ref, ''))); op text := btrim(coalesce(p_op_id, '')); res jsonb; cname text;
  aviso constant text := 'Ese identificador de operación ya se usó para otra operación. Reintentá desde la pantalla.';
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if me.id is null or not (public.user_has_perm(me.id, 'com.track') or public._com_admin()) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if ref = '' or coalesce(btrim(p_sheet_key), '') = '' then raise exception 'BAD_ORDER: indicá el pedido y la hoja' using errcode = '22023'; end if;
  if length(op) < 6 then raise exception 'BAD_OP: falta el identificador de la operación' using errcode = '22023'; end if;   -- B-W02: obligatorio (sin él no hay idempotencia)
  -- 1) IDEMPOTENCIA (B-AL-06 / B-W02): las llamadas con el mismo op_id se ordenan; una operación YA RESPONDIDA devuelve SIEMPRE la misma respuesta
  --    (también si la alarma ya se atendió o escaló). Reutilizarla para OTRO usuario, pedido u hoja se rechaza sin datos y se registra.
  perform pg_advisory_xact_lock(hashtext('com_alarm_op:' || op));
  select * into o from public.com_alarm_ops where op_id = op;
  if found then
    if o.user_id = me.id and o.order_ref = ref and o.sheet_key = p_sheet_key then return o.result || jsonb_build_object('repeated', true); end if;
    if o.alarm_id is not null then
      insert into public.com_alarm_events(alarm_id, kind, actor_id, detail) values (o.alarm_id, 'OP_ID_REUTILIZADO_RECHAZADO', me.id,
        jsonb_build_object('op_id', op, 'pedido_pedido', btrim(p_order_ref), 'hoja_pedida', p_sheet_key, 'difiere', array_remove(array[
          case when o.user_id <> me.id then 'usuario' end, case when o.order_ref <> ref then 'pedido' end, case when o.sheet_key <> p_sheet_key then 'hoja' end], null)));
    end if;
    insert into public.audit_log(actor_id, action, target_type, target_id, after) values (me.id, 'COM_ALARM_OP_ID_REUSE', 'com_alarm_ops', op, jsonb_build_object('pedido', btrim(p_order_ref), 'hoja', p_sheet_key));
    return jsonb_build_object('ok', false, 'code', 'OP_ID_CONFLICT', 'message', aviso);
  end if;
  if length(btrim(coalesce(p_reason, ''))) < 10 then raise exception 'REASON_REQUIRED: indicá el motivo (al menos 10 caracteres)' using errcode = '23514'; end if;
  -- 2) ALCANCE (B-W02 / IND-S02): el pedido debe estar reservado en esa hoja Y el usuario debe poder operar esa hoja (misma regla que _draft: dueño,
  --    routes.manage_all_drafts o Administrador General). «Hoja inexistente» y «sin permiso» responden IGUAL (no se revela existencia).
  if not exists (select 1 from public.order_reservations r join public.route_drafts d on d.client_sheet_key = r.sheet_key
                  where upper(btrim(r.order_id)) = ref and r.sheet_key = p_sheet_key
                    and (d.owner_id = me.id or public.user_has_perm(me.id, 'routes.manage_all_drafts') or public._com_admin())) then
    raise exception 'ORDER_NOT_IN_SHEET: el pedido no pertenece a una hoja que puedas operar' using errcode = '23514'; end if;
  -- 3) una sola alarma ACTIVA por pedido
  perform pg_advisory_xact_lock(hashtext('com_alarm:' || ref));
  select * into a from public.com_alarms where upper(btrim(order_ref)) = ref and status = 'PENDIENTE_ATENCION';
  if found then
    insert into public.com_alarm_events(alarm_id, kind, actor_id, detail) values (a.id, 'DUPLICADA_EXISTENTE', me.id, jsonb_build_object('op_id', op, 'motivo', btrim(p_reason)));
    if public._com_alarm_role(a, me.id) is not null then
      res := jsonb_build_object('ok', true, 'id', a.id, 'number', a.number, 'status', a.status, 'existing', true);
    else   -- fuera de su alcance: respuesta MÍNIMA, sin número ni identificador de la alarma ajena
      res := jsonb_build_object('ok', true, 'existing', true, 'status', 'PENDIENTE_ATENCION', 'message', 'Ya hay una alarma activa para ese pedido, pedida por otra persona.');
    end if;
    insert into public.com_alarm_ops(op_id, user_id, order_ref, sheet_key, alarm_id, result) values (op, me.id, ref, p_sheet_key, a.id, res);   -- la deduplicación TAMBIÉN queda vinculada
    return res || jsonb_build_object('repeated', false);
  end if;
  -- 4) alta
  ini := public._com_alarm_initial();
  if ini is null then raise exception 'ALARM_NOT_CONFIGURED: falta configurar (o no está activo) el destinatario inicial de la alarma. Avisá al Administrador General.' using errcode = '23514'; end if;
  if cardinality(public._com_alarm_escalation()) = 0 then raise exception 'ALARM_NOT_CONFIGURED: faltan destinatarios de escalamiento activos configurados. Avisá al Administrador General.' using errcode = '23514'; end if;
  select * into st from public.com_settings where id = 'DEFAULT';
  select * into q from public.com_requests where upper(btrim(coalesce(order_ref, ''))) = ref and status <> 'CANCELADA' order by created_at desc, number desc limit 1;
  begin
    insert into public.com_alarms(order_ref, sheet_key, route_id, request_id, branch, client_name, client_cuit, client_source, reason, raised_by, initial_user, escalate_at, op_id)
      values (btrim(p_order_ref), p_sheet_key, (select route_id from public.order_reservations where upper(btrim(order_id)) = ref and sheet_key = p_sheet_key limit 1), q.id,
              coalesce(q.branch, q.cartera_label), coalesce(q.client_snapshot->>'razon_social', left(btrim(p_client_name), 160)), coalesce(q.client_snapshot->>'cuit', nullif(regexp_replace(coalesce(p_client_cuit, ''), '\D', '', 'g'), '')),
              case when q.id is null then 'DECLARADO_POR_DESPACHO' else 'SOLICITUD_COMERCIAL' end, btrim(p_reason), me.id, ini, now() + make_interval(secs => st.alarm_escalate_seconds), op)
      returning * into a;
  exception when unique_violation then
    -- O-W02: última defensa DIFERENCIADA (los bloqueos ya ordenan las llamadas): se identifica la restricción, se AUDITA y se responde sin datos
    get stacked diagnostics cname = constraint_name;
    insert into public.audit_log(actor_id, action, target_type, target_id, after) values (me.id, 'COM_ALARM_UNIQUE_FALLBACK', 'com_alarms', op, jsonb_build_object('restriccion', cname, 'pedido', btrim(p_order_ref), 'hoja', p_sheet_key));
    if cname = 'com_alarms_one_active' then return jsonb_build_object('ok', false, 'code', 'RETRY', 'message', 'Otra alarma para ese pedido se registró en el mismo instante. Reintentá: vas a ver la alarma activa.'); end if;
    return jsonb_build_object('ok', false, 'code', 'OP_ID_CONFLICT', 'message', aviso);
  end;
  insert into public.com_alarm_events(alarm_id, kind, actor_id, detail) values (a.id, 'CREADA', me.id, jsonb_build_object('op_id', op, 'pedido', a.order_ref, 'hoja', a.sheet_key, 'motivo', a.reason, 'escala_a_las', a.escalate_at));
  perform public._com_alarm_notify(a, ini, 'COM_ALARMA', 'APROBACIÓN COMERCIAL URGENTE', 'Pedido ' || a.order_ref || ' · solicitada por ' || me.full_name || ' · tocá para ATENDER', me.id);
  res := jsonb_build_object('ok', true, 'id', a.id, 'number', a.number, 'status', 'PENDIENTE_ATENCION', 'existing', false, 'escalate_at', a.escalate_at);
  insert into public.com_alarm_ops(op_id, user_id, order_ref, sheet_key, alarm_id, result) values (op, me.id, ref, p_sheet_key, a.id, res);
  return res || jsonb_build_object('repeated', false);
end; $$;

create or replace function public.com_alarm_attend(p_id uuid, p_version int) returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._com_active(); a public.com_alarms; como text; u uuid;
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  perform public.com_alarm_escalate_due();
  select * into a from public.com_alarms where id = p_id for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  como := nullif(public._com_alarm_role(a, me.id), 'SOLICITANTE');   -- N-V4-01: papel con el permiso ACTUAL (una asignación histórica no alcanza)
  if como is null then
    -- se REGISTRA el intento y se RESPONDE el rechazo (sin excepción: una excepción desharía también el registro). La alarma no cambia.
    insert into public.com_alarm_events(alarm_id, kind, actor_id, detail) values (a.id, 'INTENTO_ATENDER_RECHAZADO', me.id, jsonb_build_object('motivo', 'sin autorización'));
    return jsonb_build_object('ok', false, 'code', 'FORBIDDEN', 'message', 'No sos destinatario de esta alarma.'); end if;
  -- O-AL-05: hay conflicto SOLO si la alarma ya NO está pendiente (otra persona la atendió). Un cambio de versión por el ESCALAMIENTO no
  -- bloquea a un destinatario autorizado; la doble toma sigue impedida por el bloqueo de la fila (FOR UPDATE) y el estado.
  if a.status <> 'PENDIENTE_ATENCION' then
    raise exception 'CONFLICT: la alarma ya fue atendida por % (%)', coalesce((select full_name from public.profiles where id = a.attended_by), '—'), a.attended_at using errcode = '40001'; end if;
  update public.com_alarms set status = 'ATENDIDA', attended_by = me.id, attended_at = now(), attended_as = como, seconds_to_attend = extract(epoch from now() - raised_at)::int, version = version + 1
   where id = a.id returning * into a;
  insert into public.com_alarm_events(alarm_id, kind, actor_id, detail) values (a.id, 'ATENDIDA', me.id, jsonb_build_object('como', como, 'segundos', a.seconds_to_attend, 'escalada', a.escalated_at is not null));
  -- se informa a quien la pidió y a los demás destinatarios (las alertas de la app se detienen al ver ATENDIDA)
  foreach u in array (array[a.raised_by, a.initial_user] || a.escalated_to) loop
    if u is distinct from me.id then perform public._com_alarm_notify(a, u, 'COM_ALARMA_ATENDIDA', 'Alarma comercial ATENDIDA', 'Pedido ' || a.order_ref || ' · atendida por ' || me.full_name, me.id); end if;
  end loop;
  return jsonb_build_object('ok', true, 'id', a.id, 'number', a.number, 'status', a.status, 'attended_as', como, 'seconds_to_attend', a.seconds_to_attend, 'request_id', a.request_id);
end; $$;

create or replace function public.com_alarm_escalate_due() returns int language plpgsql security definer set search_path = public as $$
declare a public.com_alarms; n int := 0; dest uuid[]; u uuid;
begin
  for a in select * from public.com_alarms where status = 'PENDIENTE_ATENCION' and escalated_at is null and escalate_at <= now() order by escalate_at for update skip locked loop
    dest := array(select x from unnest(public._com_alarm_escalation()) x where x <> a.initial_user);
    update public.com_alarms set escalated_at = now(), escalated_to = dest, version = version + 1 where id = a.id returning * into a;
    if cardinality(dest) = 0 then
      -- SIN ampliación automática: se registra el error y se avisa a Wilfredo y a quien la pidió; la alarma SIGUE pendiente (B-AL-03)
      insert into public.com_alarm_events(alarm_id, kind, detail) values (a.id, 'ESCALAMIENTO_SIN_DESTINATARIOS', jsonb_build_object('a_las', a.escalated_at, 'motivo', 'ningún destinatario de escalamiento configurado está ACTIVO'));
      perform public._com_alarm_notify(a, a.initial_user, 'COM_ALARMA_ESCALADA', 'ALARMA COMERCIAL SIN ESCALAMIENTO', 'Pedido ' || a.order_ref || ' · no hay destinatarios de escalamiento activos · atendela', null);
      perform public._com_alarm_notify(a, a.raised_by, 'COM_ALARMA_ESCALADA', 'ALARMA COMERCIAL SIN ESCALAMIENTO', 'Pedido ' || a.order_ref || ' · no se pudo escalar: avisá al Administrador General', null);
      n := n + 1; continue;
    end if;
    insert into public.com_alarm_events(alarm_id, kind, detail) values (a.id, 'ESCALADA', jsonb_build_object('destinatarios', dest, 'a_las', a.escalated_at, 'sin_atender_desde', a.raised_at));
    foreach u in array dest loop
      perform public._com_alarm_notify(a, u, 'COM_ALARMA_ESCALADA', 'APROBACIÓN COMERCIAL URGENTE · ESCALADA', 'Pedido ' || a.order_ref || ' · sin atender en 3 minutos · tocá para ATENDER', null);
    end loop;
    n := n + 1;
  end loop;
  return n;
end; $$;
DO $post$ BEGIN
  IF md5(pg_get_functiondef('public.com_alarm_raise(text,text,text,text,text,text)'::regprocedure)) <> '28e609cc5878f2ebb00e1716462d5437' THEN RAISE EXCEPTION 'REVERSION_INEXACTA: com_alarm_raise'; END IF;
  IF md5(pg_get_functiondef('public.com_alarm_attend(uuid,integer)'::regprocedure)) <> '20acc69d602e6c673dae73071f263dc1' THEN RAISE EXCEPTION 'REVERSION_INEXACTA: com_alarm_attend'; END IF;
  IF md5(pg_get_functiondef('public.com_alarm_escalate_due()'::regprocedure)) <> '71e22065703488416360c702fca075e6' THEN RAISE EXCEPTION 'REVERSION_INEXACTA: com_alarm_escalate_due'; END IF;
END $post$;
COMMIT;
