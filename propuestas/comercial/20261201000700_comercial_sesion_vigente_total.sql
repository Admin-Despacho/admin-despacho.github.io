-- =====================================================================================================================
-- PROPUESTA · AUTORIZACIONES COMERCIALES · V4 · SESIÓN VIGENTE EN TODAS LAS RPC (auditoría B-W01) · NO APLICADA. Después de 000100 a 000600.
-- Cada RPC expuesta del módulo verifica PRIMERO perfil activo y token posterior a la revocación (= _com_active / auth_has_perm de la base), antes de
-- evaluar cualquier permiso alternativo. Ningún otro cambio en las funciones. Generado por tools/gen_com_sesion_guard.py desde el texto final.
-- RPC (32): com_alarm_attend, com_alarm_by_notification, com_alarm_history, com_alarm_raise, com_alarm_settings, com_approvers, com_client_finance, com_config, com_create_request, com_decide, com_dispatch_stats, com_history, com_import_clients, com_ingest, com_ingest_error, com_kpi_for_client, com_list, com_my_alarms, com_my_notifications, com_order_alerts, com_register_source_file, com_report, com_request_detail, com_respond, com_search_clients, com_set_alarm_settings, com_set_assignment, com_set_comp_type, com_set_routing, com_set_settings, com_sources_status, com_track
-- =====================================================================================================================
BEGIN;
SET LOCAL lock_timeout = '5s'; SET LOCAL statement_timeout = '60s';
DO $guard$ BEGIN
  IF to_regprocedure('public.com_history(text,jsonb,jsonb,integer)') IS NULL THEN RAISE EXCEPTION 'DEPENDENCIA_FALTANTE: aplicar antes 000600. No se modificó nada.'; END IF;
END $guard$;
create or replace function public._com_require_session() returns void language plpgsql stable security definer set search_path = public as $$
begin
  if (public._com_active()).id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
end; $$;
revoke all on function public._com_require_session() from public, anon, authenticated;

-- com_alarm_attend
create or replace function public.com_alarm_attend(p_id uuid, p_version int) returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._com_active(); a public.com_alarms; como text; u uuid;
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  perform public.com_alarm_escalate_due();
  select * into a from public.com_alarms where id = p_id for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  como := case when me.id = a.initial_user then 'DESTINATARIO_INICIAL' when me.id = any(a.escalated_to) then 'ESCALAMIENTO'
               when public._com_admin() then 'ADMINISTRADOR_GENERAL' end;
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

-- com_alarm_by_notification
create or replace function public.com_alarm_by_notification(p_notification uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._com_active(); a public.com_alarms;
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  perform public.com_alarm_escalate_due();
  select al.* into a from public.com_alarm_events e join public.com_alarms al on al.id = e.alarm_id where e.notification_id = p_notification and e.recipient_id = me.id limit 1;
  if not found then return null; end if;
  return public._com_alarm_view(a, me.id);
end; $$;

-- com_alarm_history
create or replace function public.com_alarm_history(p_from date, p_to date) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;   -- B-AL-04: también rechaza un token REVOCADO
  return coalesce((select jsonb_agg(public._com_alarm_view(a, auth.uid()) || jsonb_build_object(
      'resolucion_comercial', (select jsonb_build_object('estado', q.status, 'resolvio', public._com_label(q.decided_by), 'cuando', q.decided_at) from public.com_requests q where q.id = a.request_id),
      'eventos', (select jsonb_agg(jsonb_build_object('kind', e.kind, 'at', e.at, 'actor', public._com_label(e.actor_id), 'destinatario', public._com_label(e.recipient_id),
                   'push', (select j.status || coalesce(' · ' || j.last_error, '') from public.push_jobs j where j.notification_id = e.notification_id), 'detalle', e.detail) order by e.id)
                  from public.com_alarm_events e where e.alarm_id = a.id)) order by a.raised_at desc)
    from public.com_alarms a where a.raised_at >= p_from and a.raised_at < p_to + 1), '[]'::jsonb);
end; $$;

-- com_alarm_raise
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
    if a.raised_by = me.id or a.initial_user = me.id or me.id = any(a.escalated_to) or public._com_admin() then
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

-- com_alarm_settings
create or replace function public.com_alarm_settings() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare st public.com_settings; pr text[] := '{}';
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into st from public.com_settings where id = 'DEFAULT';
  if st.alarm_initial_user is null then pr := pr || 'Falta el destinatario inicial (la alarma no se puede pedir).'::text;
  elsif public._com_alarm_initial() is null then pr := pr || 'El destinatario inicial guardado NO está activo o no tiene permiso de aprobación.'::text; end if;
  if cardinality(st.alarm_escalation_users) = 0 then pr := pr || 'Faltan destinatarios de escalamiento (la alarma no se puede pedir).'::text;
  elsif cardinality(public._com_alarm_escalation()) < cardinality(st.alarm_escalation_users) then pr := pr || 'Algún destinatario de escalamiento guardado NO está activo: no se reemplaza automáticamente.'::text; end if;
  return jsonb_build_object('initial_user', st.alarm_initial_user, 'escalation_users', to_jsonb(st.alarm_escalation_users),
    'efectivos', jsonb_build_object('inicial', public._com_label(public._com_alarm_initial()), 'escalamiento', (select coalesce(jsonb_agg(public._com_label(x)), '[]') from unnest(public._com_alarm_escalation()) x)),
    'guardados', (select coalesce(jsonb_agg(jsonb_build_object('id', x, 'nombre', public._com_label(x), 'activo', exists (select 1 from public.profiles p where p.id = x and p.status = 'ACTIVO'))), '[]') from unnest(st.alarm_escalation_users) x),
    'problemas', to_jsonb(pr), 'escala_en_segundos', st.alarm_escalate_seconds);
end; $$;

-- com_approvers
create or replace function public.com_approvers() returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', public._com_label(p.id)) order by p.full_name) from public.profiles p where p.status = 'ACTIVO' and public.user_has_perm(p.id, 'com.approve')), '[]'::jsonb);
end; $$;

-- com_client_finance
create or replace function public.com_client_finance(p_client uuid) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare c public.com_clients; i public.com_ingests; b public.com_cc_balances; ls bigint;
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if (public._com_active()).id is null or not (public._com_admin() or public.user_has_perm(auth.uid(), 'com.approve')) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if not public._com_admin() and not exists(select 1 from public.com_requests where client_id=p_client and assigned_approver_id=auth.uid()) then raise exception 'FORBIDDEN_CLIENT' using errcode='42501'; end if;
  select * into c from public.com_clients where id = p_client; if not found or c.cuit is null then return jsonb_build_object('status', 'SIN_CUIT'); end if;
  select * into i from public.com_ingests where kind = 'CC' and status = 'OK' order by at desc limit 1;
  if found then select * into b from public.com_cc_balances where ingest_id = i.id and cuit = c.cuit; end if;
  select id into ls from public.com_ingests where kind = 'SC' and status = 'OK' order by at desc, id desc limit 1;   -- la carga MÁS RECIENTE por fecha
  return jsonb_build_object('cc_saldo', b.saldo, 'cc_fecha', i.at, 'cc_disponible', b.cuit is not null,
    'pendientes', coalesce((select jsonb_agg(jsonb_build_object('comprobante', comp, 'fecha', doc_date, 'vence', due, 'saldo', last_saldo) order by due nulls last, doc_date)
       from public.com_sc_documents where cuit = c.cuit and last_ingest_id = ls and coalesce(last_saldo, 0) > 0.004 and class = 'VENTA'), '[]'::jsonb),
    'sc_fecha', (select at from public.com_ingests where id = ls));
end; $$;

-- com_config
create or replace function public.com_config() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me public.profiles := public._com_active();
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return jsonb_build_object('settings', (select to_jsonb(s) - 'updated_by' from public.com_settings s where id = 'DEFAULT'),
    'my_assignment', (select to_jsonb(a) || jsonb_build_object('approver', public._com_label(r.approver_user_id)) from public.com_user_assignments a
       left join public.com_routing r on r.channel_key = case when a.channel = 'CARTERA' then 'CARTERA' else 'SUCURSAL:' || a.branch end where a.user_id = me.id),
    'is_admin', public._com_admin(), 'can_request', public.user_has_perm(me.id, 'com.request'), 'can_approve', public.user_has_perm(me.id, 'com.approve') or public._com_admin(),
    'can_track', public.user_has_perm(me.id, 'com.track') or public._com_admin(), 'can_upload', public.user_has_perm(me.id, 'com.sources.upload'),
    'routing', case when public._com_admin() then (select jsonb_agg(jsonb_build_object('channel_key', channel_key, 'approver_user_id', approver_user_id, 'approver', public._com_label(approver_user_id)) order by channel_key) from public.com_routing) end,
    'assignments', case when public._com_admin() then (select jsonb_agg(jsonb_build_object('user_id', p.id, 'name', p.full_name, 'channel', a.channel, 'branch', a.branch, 'cartera_label', a.cartera_label) order by p.full_name)
       from public.profiles p left join public.com_user_assignments a on a.user_id = p.id where p.role = 'COMERCIAL') end);
end; $$;

-- com_create_request
create or replace function public.com_create_request(p_kind text, p_client uuid, p_order_ref text, p_terms jsonb, p_notes text, p_op_id text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles; asg public.com_user_assignments; rt public.com_routing; c public.com_clients; q public.com_requests; t jsonb; n int; ck text;
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  me := public._com_active();
  if me.id is null or not public.user_has_perm(me.id, 'com.request') then raise exception 'FORBIDDEN: solo Comercial crea solicitudes' using errcode = '42501'; end if;
  if p_op_id is not null then
    perform pg_advisory_xact_lock(hashtextextended('com-request|'||p_op_id,0));
    select * into q from public.com_requests where op_id = p_op_id;
    if found then
      if q.requested_by <> me.id then raise exception 'OP_ID_REUSED' using errcode='42501'; end if;
      if q.client_id <> p_client or q.kind <> p_kind or q.order_ref is distinct from left(nullif(btrim(p_order_ref),''),60) then raise exception 'OP_ID_MISMATCH' using errcode='23514'; end if;
      return jsonb_build_object('id',q.id,'number',q.number,'status',q.status,'repeated',true);
    end if;
  end if;
  if p_kind not in ('FINANCIACION', 'ECHEQ') then raise exception 'BAD_KIND' using errcode = '23514'; end if;
  select * into asg from public.com_user_assignments where user_id = me.id;
  if not found then raise exception 'NO_ASSIGNMENT: Administración todavía no te asignó sucursal o cartera' using errcode = '23514'; end if;
  ck := case when asg.channel = 'CARTERA' then 'CARTERA' else 'SUCURSAL:' || asg.branch end;
  select * into rt from public.com_routing where channel_key = ck;
  if rt.approver_user_id is null or public._com_active(rt.approver_user_id) is null then raise exception 'NO_APPROVER: no hay aprobador ACTIVO configurado para %', ck using errcode = '23514'; end if;
  select * into c from public.com_clients where id = p_client;
  if not found then raise exception 'CLIENT_NOT_FOUND: CLIENTE NO ENCONTRADO' using errcode = 'P0002'; end if;
  if c.status <> 'ACTIVO' then raise exception 'CLIENT_IN_REVIEW: el cliente está pendiente de revisión (%)', array_to_string(c.review_reasons, ', ') using errcode = '23514'; end if;
  t := public._com_terms(p_kind, p_terms, c, (now() at time zone 'America/Argentina/Mendoza')::date);
  insert into public.com_requests(kind, client_id, client_snapshot, channel, branch, cartera_label, requested_by, assigned_approver_id, order_ref, notes, original_terms, current_terms, kpi_snapshot, op_id)
  values (p_kind, c.id, jsonb_build_object('id', c.id, 'erp_id', c.erp_id, 'razon_social', c.razon_social, 'nombre', c.nombre, 'doc_type', c.doc_type, 'doc_number', c.doc_number, 'cuit', c.cuit),
    asg.channel, asg.branch, asg.cartera_label, me.id, rt.approver_user_id, left(nullif(btrim(p_order_ref), ''), 60), left(nullif(btrim(p_notes), ''), 600), t, t,
    case when p_kind = 'FINANCIACION' then public.com_kpi_for_client(c.id) else jsonb_build_object('status', 'NO_APLICA') end, p_op_id) returning * into q;
  perform public._com_event(q.id, 'ENVIADA', null, null, t);
  n := public._com_event(q.id, 'PENDIENTE', null, null, null);
  perform public._com_notify(q.id, n, rt.approver_user_id, 'NUEVA', 'Autorización ' || q.number || ' pendiente', (case when p_kind = 'FINANCIACION' then 'Financiación propia' else 'Aceptación de e-cheq' end) || ' · ' || c.razon_social || ' · $ ' || to_char((t->>'amount')::numeric, 'FM999G999G999D00'));
  return jsonb_build_object('id', q.id, 'number', q.number, 'status', q.status, 'approver', public._com_label(rt.approver_user_id), 'repeated', false);
end; $$;

-- com_decide
create or replace function public.com_decide(p_id uuid, p_version int, p_decision text, p_terms jsonb, p_reason text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles; q public.com_requests; c public.com_clients; t jsonb; st text; asn text; n int; ev text;
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  me := public._com_active();
  select * into q from public.com_requests where id = p_id for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if q.assigned_approver_id = me.id and public.user_has_perm(me.id, 'com.approve') then asn := 'APROBADOR';
  elsif public._com_admin() then asn := case when q.assigned_approver_id = me.id then 'APROBADOR' else 'SUPLENTE_ADMIN' end;
  else raise exception 'FORBIDDEN: no sos el aprobador asignado ni Administrador General activo' using errcode = '42501'; end if;
  if p_version is null then raise exception 'BAD_VERSION' using errcode='23514'; end if;
  if q.status <> 'PENDIENTE' or q.version <> p_version then
    raise exception 'CONFLICT: la solicitud ya fue resuelta o cambió (estado %, por %)', q.status, coalesce(public._com_label(q.decided_by), '—') using errcode = '40001'; end if;
  if p_decision not in ('APROBAR', 'APROBAR_CON_CAMBIOS', 'RECHAZAR', 'DEVOLVER') then raise exception 'BAD_DECISION' using errcode = '23514'; end if;
  if p_decision <> 'APROBAR' and length(btrim(coalesce(p_reason, ''))) < 5 then raise exception 'REASON_REQUIRED: indicá el motivo' using errcode = '23514'; end if;
  select * into c from public.com_clients where id = q.client_id;
  t := case when p_decision in ('APROBAR_CON_CAMBIOS', 'DEVOLVER') then public._com_terms(q.kind, p_terms, c, (q.created_at at time zone 'America/Argentina/Mendoza')::date) else q.current_terms end;
  if p_decision in ('APROBAR_CON_CAMBIOS', 'DEVOLVER') and t = q.current_terms then raise exception 'NO_CHANGES: no hay cambios en importe, cuotas o plazo' using errcode = '23514'; end if;
  st := case p_decision when 'APROBAR' then 'APROBADA' when 'APROBAR_CON_CAMBIOS' then 'APROBADA_MOD' when 'RECHAZAR' then 'RECHAZADA' else 'DEVUELTA' end;
  update public.com_requests set status = st, current_terms = t, final_terms = case when st in ('APROBADA', 'APROBADA_MOD') then t end,
    decided_by = case when st = 'DEVUELTA' then null else me.id end, decided_at = case when st = 'DEVUELTA' then null else now() end, decided_as = case when st = 'DEVUELTA' then null else asn end,
    version = version + 1, updated_at = now() where id = q.id and version = p_version;
  ev := case st when 'APROBADA' then 'APROBADA' when 'APROBADA_MOD' then 'APROBADA_CON_MODIFICACIONES' when 'RECHAZADA' then 'RECHAZADA' else 'DEVUELTA_CON_MODIFICACIONES' end;
  n := public._com_event(q.id, ev, nullif(btrim(p_reason), ''), q.current_terms, t);
  update public.com_notifications set read_at = coalesce(read_at, now()) where request_id = q.id and kind = 'NUEVA';   -- sale de las bandejas pendientes
  perform public._com_notify(q.id, n, q.requested_by, ev, 'Autorización ' || q.number || ' · ' || replace(ev, '_', ' '),
    'Resuelta por ' || public._com_label(me.id) || case when asn = 'SUPLENTE_ADMIN' then ' (asignada a ' || coalesce(public._com_label(q.assigned_approver_id), '—') || ')' else '' end);
  if asn = 'SUPLENTE_ADMIN' then perform public._com_notify(q.id, n, q.assigned_approver_id, 'RESUELTA_POR_SUPLENTE', 'Autorización ' || q.number || ' resuelta por ' || public._com_label(me.id), ev); end if;
  insert into public.audit_log(actor_id, action, target_type, target_id, before, after) values (me.id, 'COM_' || ev, 'com_requests', q.id::text,
    jsonb_build_object('terms', q.current_terms, 'assigned_approver', q.assigned_approver_id), jsonb_build_object('terms', t, 'decided_as', asn, 'reason', p_reason));
  return jsonb_build_object('id', q.id, 'status', st, 'decided_as', asn, 'version', q.version + 1);
end; $$;

-- com_dispatch_stats
create or replace function public.com_dispatch_stats(p_from date, p_to date) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(x order by (x->>'paradas')::int desc) from (
    select jsonb_build_object('transportista', coalesce(ca.name, r.carrier_id), 'zona', coalesce(nullif(s.zone, ''), 'SIN ZONA'), 'hojas', count(distinct r.id), 'paradas', count(*),
      'entregadas', count(*) filter (where s.outcome = 'ENTREGADO')) x
    from public.routes r join public.route_stops s on s.route_id = r.id left join public.carriers ca on ca.id = r.carrier_id
    where coalesce(s.stop_type, 'PEDIDO') = 'PEDIDO' and r.published_at >= p_from and r.published_at < p_to + 1 group by coalesce(ca.name, r.carrier_id), coalesce(nullif(s.zone, ''), 'SIN ZONA')) t), '[]'::jsonb);
end; $$;

-- com_history
create or replace function public.com_history(p_scope text, p_filters jsonb, p_cursor jsonb, p_limit int default 25) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me public.profiles := public._com_active(); adm boolean := public._com_admin(); f jsonb := coalesce(p_filters, '{}'::jsonb);
  lim int := greatest(1, least(coalesce(p_limit, 25), 100)); cc timestamptz; ci uuid; rows jsonb; n int;
  qq text := public._com_norm(f->>'q'); qd text := regexp_replace(coalesce(f->>'q', ''), '\D', '', 'g');
  st text[] := (select array_agg(x) from jsonb_array_elements_text(case when jsonb_typeof(f->'status') = 'array' then f->'status' else '[]'::jsonb end) x);
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_scope = 'MIS' and not public.user_has_perm(me.id, 'com.request') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_scope = 'BANDEJA' and not (public.user_has_perm(me.id, 'com.approve') or adm) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_scope = 'TODAS' and not adm then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_scope not in ('MIS', 'BANDEJA', 'TODAS') then raise exception 'BAD_SCOPE' using errcode = '22023'; end if;
  if p_cursor is not null then
    begin cc := (p_cursor->>'c')::timestamptz; ci := (p_cursor->>'i')::uuid; exception when others then raise exception 'BAD_CURSOR' using errcode = '22023'; end;
  end if;
  select coalesce(jsonb_agg(x order by (x->>'created_at')::timestamptz desc, (x->>'id') desc), '[]'::jsonb), count(*) into rows, n from (
    select jsonb_build_object('id', q.id, 'number', q.number, 'kind', q.kind, 'status', q.status, 'order_ref', q.order_ref,
      'client', q.client_snapshot->>'razon_social', 'cuit', q.client_snapshot->>'cuit',
      'amount', coalesce((q.original_terms->>'amount')::numeric, (q.current_terms->>'amount')::numeric),
      'created_at', q.created_at, 'updated_at', q.updated_at, 'assigned_approver', public._com_label(q.assigned_approver_id)) x
    from public.com_requests q
    where ((p_scope = 'MIS' and q.requested_by = me.id) or (p_scope = 'BANDEJA' and (q.assigned_approver_id = me.id or adm)) or (p_scope = 'TODAS' and adm))
      and (p_cursor is null or (q.created_at, q.id) < (cc, ci))
      and (coalesce(f->>'q', '') = '' or public._com_norm(q.client_snapshot->>'razon_social') like '%' || qq || '%' or public._com_norm(q.client_snapshot->>'nombre') like '%' || qq || '%'
           or (length(qd) >= 3 and regexp_replace(coalesce(q.client_snapshot->>'cuit', ''), '\D', '', 'g') like '%' || qd || '%'))
      and (coalesce(f->>'order_ref', '') = '' or upper(btrim(coalesce(q.order_ref, ''))) like '%' || upper(btrim(f->>'order_ref')) || '%')
      and (coalesce(f->>'number', '') = '' or upper(q.number) like '%' || upper(btrim(f->>'number')) || '%')
      and (coalesce(f->>'from', '') = '' or q.created_at >= (f->>'from')::date)
      and (coalesce(f->>'to', '') = '' or q.created_at < (f->>'to')::date + 1)
      and (st is null or q.status = any(st))
      and (coalesce(f->>'kind', '') = '' or q.kind = f->>'kind')
    order by q.created_at desc, q.id desc limit lim + 1) t;
  if n > lim then rows := rows - lim; end if;   -- se pidió una fila de más solo para saber si quedan resultados
  return jsonb_build_object('items', rows, 'has_more', n > lim, 'page_size', lim,
    'next_cursor', case when n > lim then jsonb_build_object('c', rows->(lim - 1)->>'created_at', 'i', rows->(lim - 1)->>'id') end);
end; $$;

-- com_import_clients
create or replace function public.com_import_clients(p_file_name text, p_sha256 text, p_rows jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare imp bigint; r jsonb; t text; n text; v boolean; cu text; cur public.com_clients; ins int := 0; upd int := 0; same int := 0; rej jsonb := '[]'; aft jsonb; bef jsonb;
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if not public._com_admin() then raise exception 'FORBIDDEN: solo el Administrador General importa el padrón' using errcode = '42501'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then raise exception 'EMPTY_FILE' using errcode = '23514'; end if;
  insert into public.com_client_imports(by_user, file_name, file_sha256) values (auth.uid(), left(p_file_name, 200), left(p_sha256, 80)) returning id into imp;
  for r in select * from jsonb_array_elements(p_rows) loop
    if coalesce(btrim(r->>'erp_id'), '') = '' or coalesce(btrim(r->>'razon_social'), '') = '' then rej := rej || jsonb_build_object('fila', r->>'_row', 'motivo', 'SIN ID O SIN RAZÓN SOCIAL'); continue; end if;
    t := upper(btrim(coalesce(r->>'doc_type', ''))); n := regexp_replace(coalesce(r->>'doc_number', ''), '\D', '', 'g');
    t := case when n = '' and coalesce(btrim(r->>'doc_number'), '') = '' then 'SIN_DOC' when t in ('CUIT', 'CUIL', 'DNI') then t else 'OTRO' end;   -- sin número = SIN DOCUMENTO (a revisión)
    if t = 'OTRO' then n := nullif(btrim(r->>'doc_number'), ''); end if;
    v := case when t in ('CUIT', 'CUIL') then public._cuit_valid(n) when t = 'DNI' then n ~ '^\d{7,8}$' and n !~ '^(\d)\1{6,7}$' else false end;
    cu := case when t in ('CUIT', 'CUIL') and v then n end;   -- un DNI NUNCA se convierte en CUIT
    aft := jsonb_build_object('razon_social', btrim(r->>'razon_social'), 'nombre', nullif(btrim(r->>'nombre'), ''), 'doc_type', t, 'doc_number', nullif(n, ''), 'cuit', cu,
      'email', nullif(lower(btrim(r->>'email')), ''), 'vendedor', nullif(btrim(r->>'vendedor'), ''), 'localidad', nullif(btrim(r->>'localidad'), ''));
    select * into cur from public.com_clients where erp_id = btrim(r->>'erp_id');
    if not found then
      insert into public.com_clients(erp_id, razon_social, nombre, cond_fiscal, doc_type, doc_number, doc_valid, cuit, localidad, provincia, email, vendedor, zona, categoria, cod_interno, search_text, first_import_id, last_import_id)
      values (btrim(r->>'erp_id'), btrim(r->>'razon_social'), nullif(btrim(r->>'nombre'), ''), nullif(btrim(r->>'cond_fiscal'), ''), t, nullif(n, ''), v, cu, nullif(btrim(r->>'localidad'), ''), nullif(btrim(r->>'provincia'), ''),
        nullif(lower(btrim(r->>'email')), ''), nullif(btrim(r->>'vendedor'), ''), nullif(btrim(r->>'zona'), ''), nullif(btrim(r->>'categoria'), ''), nullif(btrim(r->>'cod_interno'), ''),
        public._com_norm(concat_ws(' ', r->>'razon_social', r->>'nombre', n)), imp, imp);
      ins := ins + 1;
    else
      bef := jsonb_build_object('razon_social', cur.razon_social, 'nombre', cur.nombre, 'doc_type', cur.doc_type, 'doc_number', cur.doc_number, 'cuit', cur.cuit, 'email', cur.email, 'vendedor', cur.vendedor, 'localidad', cur.localidad);
      if bef = aft then same := same + 1; update public.com_clients set last_import_id = imp where id = cur.id; continue; end if;
      insert into public.com_client_changes(client_id, import_id, before, after) values (cur.id, imp, bef, aft);
      update public.com_clients set razon_social = aft->>'razon_social', nombre = aft->>'nombre', cond_fiscal = nullif(btrim(r->>'cond_fiscal'), ''), doc_type = t, doc_number = nullif(n, ''), doc_valid = v, cuit = cu,
        localidad = aft->>'localidad', provincia = nullif(btrim(r->>'provincia'), ''), email = aft->>'email', vendedor = aft->>'vendedor', zona = nullif(btrim(r->>'zona'), ''), categoria = nullif(btrim(r->>'categoria'), ''),
        cod_interno = nullif(btrim(r->>'cod_interno'), ''), search_text = public._com_norm(concat_ws(' ', r->>'razon_social', r->>'nombre', n)), last_import_id = imp, updated_at = now() where id = cur.id;
      upd := upd + 1;
    end if;
  end loop;
  perform public._com_recompute_reviews();
  update public.com_client_imports set counts = jsonb_build_object('filas', jsonb_array_length(p_rows), 'nuevos', ins, 'actualizados', upd, 'sin_cambios', same, 'rechazados', jsonb_array_length(rej),
      'en_revision', (select count(*) from public.com_clients where status = 'REVISION'), 'total', (select count(*) from public.com_clients)), rejected = rej where id = imp;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'COM_CLIENTS_IMPORTED', 'com_client_imports', imp::text, (select counts from public.com_client_imports where id = imp));
  return (select jsonb_build_object('import_id', imp) || counts from public.com_client_imports where id = imp);
end; $$;

-- com_ingest
create or replace function public.com_ingest(p_kind text, p_meta jsonb, p_rows jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare g public.com_ingests; b int := coalesce((p_meta->>'batch')::int, 1); nb int := greatest(1, coalesce((p_meta->>'batches')::int, 1)); r jsonb; cu text; k text; d public.com_sc_documents;
  amt numeric; pre text; cls text; dt date; st jsonb := '{}'; c public.com_clients; nm text;
  add_ int := 0; seen int := 0; conf int := 0; skip_cuit int := 0; skip_san int := 0; unk int := 0;
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if public._com_active() is null or not public.user_has_perm(auth.uid(), 'com.sources.upload') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_kind not in ('SC', 'CC') or coalesce(p_meta->>'hash', '') = '' then raise exception 'BAD_INGEST' using errcode = '23514'; end if;
  if jsonb_typeof(p_rows) is distinct from 'array' or jsonb_array_length(p_rows) > 2000 or b < 1 or b > nb or nb > 10000 then raise exception 'BAD_BATCH' using errcode='23514'; end if;
  if p_meta->>'owner_id' is not null and p_meta->>'owner_id' <> auth.uid()::text then raise exception 'FORBIDDEN_OWNER' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended('com-ingest|'||p_kind||'|'||(p_meta->>'hash')||'|'||coalesce(p_meta->>'loaded_at','')||'|'||auth.uid()::text,0));
  select * into g from public.com_ingests where kind = p_kind and content_hash = p_meta->>'hash' and loaded_at is not distinct from (p_meta->>'loaded_at')::timestamptz and by_user=auth.uid() for update;
  if found and g.status='ERROR' and g.batches_done=0 then update public.com_ingests set batches=nb where id=g.id; g.batches:=nb; end if;
  if found and g.batches <> nb then raise exception 'BAD_BATCH_METADATA' using errcode='23514'; end if;
  if not found then
    insert into public.com_ingests(kind, content_hash, file_name, loaded_at, by_user, batches) values (p_kind, p_meta->>'hash', left(p_meta->>'file_name', 200), (p_meta->>'loaded_at')::timestamptz, auth.uid(), nb) returning * into g;
    perform public._com_link_source(g.id, p_kind, p_meta);   -- respaldo privado: con el respaldo ACTIVO exige el archivo original ya recibido
  end if;
  if exists (select 1 from public.com_ingest_batches where ingest_id = g.id and batch = b) then
    return jsonb_build_object('ingest_id', g.id, 'batch', b, 'repeated', true, 'status', g.status); end if;   -- reintento o misma carga: no duplica
  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]')) loop
    cu := regexp_replace(coalesce(r->>'cuit', ''), '\D', '', 'g'); nm := nullif(btrim(r->>'c'), '');
    if p_kind = 'CC' then
      if not public._cuit_valid(cu) then skip_cuit := skip_cuit + 1; continue; end if;
      insert into public.com_cc_balances(ingest_id, cuit, client_name, saldo, localidad) values (g.id, cu, nm, (r->>'saldo')::numeric, nullif(btrim(r->>'localidad'), ''))
        on conflict (ingest_id, cuit) do update set saldo = excluded.saldo;
      add_ := add_ + 1; continue;
    end if;
    if coalesce((r->>'san')::boolean, false) then skip_san := skip_san + 1; continue; end if;   -- «Saldo Anterior»: NO es venta
    if not public._cuit_valid(cu) then skip_cuit := skip_cuit + 1; continue; end if;            -- sin CUIT verificable: no se cruza
    pre := upper(left(regexp_replace(coalesce(r->>'comp', ''), '^\s+', ''), 3)); select class into cls from public.com_comp_types where prefix = pre;
    amt := coalesce((r->>'m')::numeric, (r->>'ve')::numeric); dt := nullif(r->>'d', '')::date;
    -- WORK-K02: la PARTE se identifica como en el Constructor (financing.js partKey): número de cuota y, si no hay, vencimiento
    k := cu || '|' || coalesce(nullif(r->>'n', ''), upper(regexp_replace(coalesce(r->>'comp', ''), '[\s\[\]\-_.()]', '', 'g'))) || '|'
      || coalesce(nullif(btrim(r->>'q'), ''), case when nullif(btrim(r->>'due'), '') is not null then 'V' || btrim(r->>'due') end, '-');
    perform pg_advisory_xact_lock(hashtextextended('com-doc|'||k,0));
    select * into d from public.com_sc_documents where doc_key = k for update;
    if not found then
      insert into public.com_sc_documents(doc_key, cuit, client_name, comp, comp_n, prefix, class, cuota, doc_date, due, amount, last_saldo, first_ingest_id, last_ingest_id, status)
      values (k, cu, nm, left(r->>'comp', 80), split_part(k, '|', 2), pre, cls, nullif(btrim(r->>'q'), ''), dt, nullif(r->>'due', '')::date, amt, (r->>'s')::numeric, g.id, g.id,
        case when cls is null then 'SIN_CLASIFICAR' when amt is null then 'SIN_IMPORTE' when dt is null then 'SIN_FECHA' else 'OK' end);
      add_ := add_ + 1;
      if cls is null then unk := unk + 1; insert into public.com_reconciliation_issues(ingest_id, cuit, doc_key, kind, detail) values (g.id, cu, k, 'TIPO_SIN_CLASIFICAR', jsonb_build_object('prefijo', pre, 'comprobante', r->>'comp')) on conflict do nothing; end if;
    else
      seen := seen + 1;
      if d.amount is distinct from amt or d.doc_date is distinct from dt then   -- el MISMO comprobante con otro importe/fecha: a conciliación, fuera del KPI
        conf := conf + 1;
        update public.com_sc_documents set status = 'CONFLICTO', conflict = coalesce(conflict, '[]'::jsonb) || jsonb_build_array(jsonb_build_object('ingest', g.id, 'importe', amt, 'fecha', dt)),
          last_ingest_id = g.id, last_seen_at = now(), seen_count = seen_count + 1, last_saldo = (r->>'s')::numeric where doc_key = k;
        insert into public.com_reconciliation_issues(ingest_id, cuit, doc_key, kind, detail) values (g.id, cu, k, 'IMPORTE_CAMBIADO', jsonb_build_object('antes', jsonb_build_object('importe', d.amount, 'fecha', d.doc_date), 'ahora', jsonb_build_object('importe', amt, 'fecha', dt))) on conflict do nothing;
      else
        update public.com_sc_documents set last_ingest_id = g.id, last_seen_at = now(), seen_count = seen_count + 1, last_saldo = (r->>'s')::numeric where doc_key = k;
      end if;
    end if;
  end loop;
  -- conciliación con el padrón (una vez por CUIT y carga; sin sobrescribir)
  if p_kind = 'SC' then
    for r in select jsonb_build_object('cuit', cuit, 'name', max(client_name)) from public.com_sc_documents where last_ingest_id = g.id group by cuit loop
      select * into c from public.com_clients where cuit = r->>'cuit' and status <> 'BAJA' order by status limit 1;
      if not found then insert into public.com_reconciliation_issues(ingest_id, cuit, kind, detail) values (g.id, r->>'cuit', 'CUIT_NO_EN_PADRON', jsonb_build_object('nombre', r->>'name')) on conflict do nothing;
      elsif c.status = 'REVISION' then insert into public.com_reconciliation_issues(ingest_id, cuit, kind, detail, client_id) values (g.id, r->>'cuit', 'CUIT_EN_REVISION', jsonb_build_object('nombre', r->>'name'), c.id) on conflict do nothing;
      elsif coalesce(r->>'name', '') <> '' and public._com_norm(r->>'name') not in (public._com_norm(c.razon_social), public._com_norm(c.nombre)) then
        insert into public.com_reconciliation_issues(ingest_id, cuit, kind, detail, client_id) values (g.id, r->>'cuit', 'NOMBRE_DISTINTO', jsonb_build_object('en_carga', r->>'name', 'en_padron', c.razon_social), c.id) on conflict do nothing; end if;
    end loop;
  end if;
  insert into public.com_ingest_batches(ingest_id, batch, rows) values (g.id, b, jsonb_array_length(coalesce(p_rows, '[]')));
  update public.com_ingests set batches_done = batches_done + 1, rows = rows + jsonb_array_length(coalesce(p_rows, '[]')),
    stats = jsonb_build_object('nuevos', coalesce((stats->>'nuevos')::int, 0) + add_, 'repetidos', coalesce((stats->>'repetidos')::int, 0) + seen, 'conflictos', coalesce((stats->>'conflictos')::int, 0) + conf,
      'sin_cuit', coalesce((stats->>'sin_cuit')::int, 0) + skip_cuit, 'saldo_anterior', coalesce((stats->>'saldo_anterior')::int, 0) + skip_san, 'sin_clasificar', coalesce((stats->>'sin_clasificar')::int, 0) + unk),
    status = case when batches_done + 1 >= batches then 'OK' else 'EN_PROCESO' end,
    date_min = least(date_min, (select min(doc_date) from public.com_sc_documents where last_ingest_id = g.id)), date_max = greatest(date_max, (select max(doc_date) from public.com_sc_documents where last_ingest_id = g.id))
   where id = g.id returning * into g;
  return jsonb_build_object('ingest_id', g.id, 'batch', b, 'status', g.status, 'repeated', false, 'stats', g.stats);
end; $$;

-- com_ingest_error
create or replace function public.com_ingest_error(p_kind text, p_meta jsonb, p_error text) returns void language plpgsql security definer set search_path = public as $$
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if public._com_active() is null or not public.user_has_perm(auth.uid(), 'com.sources.upload') then return; end if;
  insert into public.com_ingests(kind, content_hash, file_name, loaded_at, by_user, status, error) values (p_kind, coalesce(p_meta->>'hash', 'error-' || gen_random_uuid()), left(p_meta->>'file_name', 200),
    (p_meta->>'loaded_at')::timestamptz, auth.uid(), 'ERROR', left(p_error, 400)) on conflict (kind, content_hash, loaded_at, by_user) do update set error = excluded.error, status = case when com_ingests.status = 'OK' then 'OK' else 'ERROR' end;
end; $$;

-- com_kpi_for_client
create or replace function public.com_kpi_for_client(p_client uuid, p_at timestamptz default now()) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if (public._com_active()).id is null or not (public._com_admin() or public.user_has_perm(auth.uid(),'com.request') or public.user_has_perm(auth.uid(),'com.approve')) then raise exception 'FORBIDDEN' using errcode='42501'; end if;
  if not public._com_admin() and not public.user_has_perm(auth.uid(),'com.request') and not exists(select 1 from public.com_requests where client_id=p_client and assigned_approver_id=auth.uid()) then raise exception 'FORBIDDEN_CLIENT' using errcode='42501'; end if;
  return public._com_kpi_raw(p_client,p_at) || (select jsonb_build_object('provisional',not s.kpi_source_verified,'label',case when s.kpi_source_verified then null else 'RECOMENDACIÓN PROVISORIA — BASADA EN COMPROBANTES DISPONIBLES' end) from public.com_settings s where id='DEFAULT');
end; $$;

-- com_list
create or replace function public.com_list(p_scope text, p_status text default null, p_limit int default 30, p_offset int default 0) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me public.profiles := public._com_active(); adm boolean := public._com_admin();
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_scope = 'MIS' and not public.user_has_perm(me.id, 'com.request') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_scope = 'BANDEJA' and not (public.user_has_perm(me.id, 'com.approve') or adm) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_scope = 'TODAS' and not adm then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(public._com_view(q, true) order by q.status <> 'PENDIENTE', q.updated_at desc) from (
    select * from public.com_requests q where
      ((p_scope = 'MIS' and q.requested_by = me.id) or (p_scope = 'BANDEJA' and (q.assigned_approver_id = me.id or adm)) or p_scope = 'TODAS')
      and (p_status is null or q.status = p_status) order by q.status <> 'PENDIENTE', q.updated_at desc limit greatest(1, least(coalesce(p_limit, 30), 100)) offset greatest(0, coalesce(p_offset, 0))) q), '[]'::jsonb);
end; $$;

-- com_my_alarms
create or replace function public.com_my_alarms() returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._com_active();
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  perform public.com_alarm_escalate_due();   -- perezoso: adelanta el escalamiento si hay alguien conectado (el reloj sigue siendo el del servidor)
  return coalesce((select jsonb_agg(public._com_alarm_view(a, me.id) order by a.raised_at desc) from public.com_alarms a
    where (a.status = 'PENDIENTE_ATENCION' or a.attended_at > now() - interval '12 hours')
      and (a.raised_by = me.id or a.initial_user = me.id or me.id = any(a.escalated_to) or public._com_admin())), '[]'::jsonb);
end; $$;

-- com_my_notifications
create or replace function public.com_my_notifications() returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  return (select coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'request_id', n.request_id, 'kind', n.kind, 'title', n.title, 'body', n.body, 'at', n.created_at, 'read', n.read_at is not null) order by n.created_at desc), '[]'::jsonb)
  from (select * from public.com_notifications where user_id = auth.uid() and (public._com_active()).id is not null and (public._com_admin() or public.user_has_perm(auth.uid(),'com.request') or public.user_has_perm(auth.uid(),'com.approve')) order by created_at desc limit 50) n);
end; $$;

-- com_order_alerts
create or replace function public.com_order_alerts(p_orders text[], p_cuits text[]) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me public.profiles := public._com_active();
  o text[] := (select coalesce(array_agg(distinct upper(btrim(x))), '{}') from unnest(coalesce(p_orders, '{}')) x where coalesce(btrim(x), '') <> '');
  c text[] := (select coalesce(array_agg(distinct regexp_replace(x, '\D', '', 'g')), '{}') from unnest(coalesce(p_cuits, '{}')) x where length(regexp_replace(coalesce(x, ''), '\D', '', 'g')) in (7, 8, 11));
  todas boolean; aprob boolean; propias boolean;
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  todas := public._com_admin() or public.user_has_perm(me.id, 'com.track');
  aprob := public.user_has_perm(me.id, 'com.approve'); propias := public.user_has_perm(me.id, 'com.request');
  if not (todas or aprob or propias) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if cardinality(o) > 300 or cardinality(c) > 300 then raise exception 'TOO_MANY: máximo 300 pedidos y 300 clientes por consulta' using errcode = '22023'; end if;
  return coalesce((select jsonb_agg(x order by x->>'created_at' desc, x->>'number' desc) from (
    select jsonb_build_object('number', r.number, 'kind', r.kind, 'status', r.status, 'order_ref', r.order_ref, 'match', case when r.ref = any(o) then 'PEDIDO' else 'CLIENTE' end,
      'client', r.client_snapshot->>'razon_social', 'cuit', r.client_snapshot->>'cuit', 'created_at', r.created_at, 'decided_at', r.decided_at,
      'alert', case when r.status in ('PENDIENTE', 'DEVUELTA', 'RECHAZADA') then 'CONSULTAR APROBACIÓN' end,
      'final_terms', case when r.status in ('APROBADA', 'APROBADA_MOD') then r.final_terms end) x
    from (
      -- 1) alcance por registro; 2) UNA política de deduplicación para ambas coincidencias: la más reciente por número de pedido
      select v.*, row_number() over (partition by coalesce(nullif(v.ref, ''), v.id::text) order by v.created_at desc, v.number desc) rn
        from (select q.*, upper(btrim(coalesce(q.order_ref, ''))) ref from public.com_requests q
               where q.status <> 'CANCELADA'
                 and (todas or (aprob and q.assigned_approver_id = me.id) or (propias and q.requested_by = me.id))) v) r
    where r.rn = 1
      and (r.ref = any(o) or (r.status in ('PENDIENTE', 'DEVUELTA') and regexp_replace(coalesce(r.client_snapshot->>'cuit', ''), '\D', '', 'g') = any(c)))) t), '[]'::jsonb);
end; $$;

-- com_register_source_file
create or replace function public.com_register_source_file(p_kind text, p_sha256 text, p_size bigint, p_name text, p_mime text, p_path text) returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.com_settings; f public.com_source_files; v int; ok boolean;
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if public._com_active() is null or not public.user_has_perm(auth.uid(), 'com.sources.upload') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into s from public.com_settings where id = 'DEFAULT';
  if not s.source_backup_enabled then raise exception 'BACKUP_DISABLED: el respaldo de originales no está habilitado' using errcode = '23514'; end if;
  if p_kind not in ('SC', 'CC') or p_sha256 !~ '^[0-9a-f]{64}$' or p_path is distinct from (p_kind || '/' || p_sha256 || '.' || lower(regexp_replace(coalesce(p_name, ''), '^.*\.', ''))) or p_path !~ '\.(xlsx|xls|csv)$' then
    raise exception 'BAD_SOURCE: tipo, hash o ruta inválidos' using errcode = '23514'; end if;
  if p_size is null or p_size <= 0 or p_size > s.source_max_mb::bigint * 1048576 then raise exception 'FILE_TOO_LARGE: supera % MB', s.source_max_mb using errcode = '23514'; end if;
  if to_regclass('storage.objects') is not null then   -- el ORIGINAL debe estar realmente en el almacenamiento privado
    execute 'select exists (select 1 from storage.objects where bucket_id = ''com-sources'' and name = $1)' into ok using p_path;
    if not ok then raise exception 'SOURCE_NOT_UPLOADED: el original todavía no está en el almacenamiento' using errcode = '23514'; end if;
  end if;
  perform pg_advisory_xact_lock(hashtext('com_source_files:' || p_kind));
  select * into f from public.com_source_files where kind = p_kind and sha256 = p_sha256;
  if found then return jsonb_build_object('id', f.id, 'version', f.version, 'repeated', true); end if;
  select coalesce(max(version), 0) + 1 into v from public.com_source_files where kind = p_kind;
  insert into public.com_source_files(kind, version, sha256, size_bytes, original_name, mime, storage_path, uploaded_by) values (p_kind, v, p_sha256, p_size, left(p_name, 200), left(p_mime, 120), p_path, auth.uid()) returning * into f;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'COM_SOURCE_FILE', 'com_source_files', f.id::text, jsonb_build_object('kind', p_kind, 'version', v, 'sha256', p_sha256, 'size', p_size));
  return jsonb_build_object('id', f.id, 'version', f.version, 'repeated', false);
end; $$;

-- com_report
create or replace function public.com_report(p_from date, p_to date) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return (with r as (select * from public.com_requests where created_at >= p_from and created_at < p_to + 1)
  select jsonb_build_object(
    'por_tipo_estado', (select coalesce(jsonb_agg(jsonb_build_object('tipo', kind, 'estado', status, 'cantidad', n, 'solicitado', sol, 'autorizado', aut)), '[]') from
       (select kind, status, count(*) n, sum((original_terms->>'amount')::numeric) sol, sum((final_terms->>'amount')::numeric) aut from r group by 1, 2) x),
    'por_aprobador', (select coalesce(jsonb_agg(jsonb_build_object('asignado', public._com_label(assigned_approver_id), 'resuelto_por', public._com_label(decided_by), 'como', decided_as, 'cantidad', n, 'horas_promedio', h)), '[]') from
       (select assigned_approver_id, decided_by, decided_as, count(*) n, round(avg(extract(epoch from decided_at - created_at) / 3600)::numeric, 1) h from r where decided_at is not null group by 1, 2, 3) x),
    'por_canal', (select coalesce(jsonb_agg(jsonb_build_object('canal', channel, 'sucursal', branch, 'cartera', cartera_label, 'cantidad', n, 'autorizado', aut)), '[]') from
       (select channel, branch, cartera_label, count(*) n, sum((final_terms->>'amount')::numeric) aut from r group by 1, 2, 3) x),
    'por_mes', (select coalesce(jsonb_agg(jsonb_build_object('mes', m, 'cantidad', n, 'solicitado', sol, 'autorizado', aut) order by m), '[]') from
       (select to_char(created_at at time zone 'America/Argentina/Mendoza', 'YYYY-MM') m, count(*) n, sum((original_terms->>'amount')::numeric) sol, sum((final_terms->>'amount')::numeric) aut from r group by 1) x),
    'por_trimestre', (select coalesce(jsonb_agg(jsonb_build_object('trimestre', t, 'cantidad', n, 'autorizado', aut) order by t), '[]') from
       (select to_char(created_at at time zone 'America/Argentina/Mendoza', 'YYYY-"T"Q') t, count(*) n, sum((final_terms->>'amount')::numeric) aut from r group by 1) x),
    'vencimientos', (select coalesce(jsonb_agg(jsonb_build_object('numero', number, 'cliente', client_snapshot->>'razon_social', 'tipo', kind, 'importe', (final_terms->>'amount')::numeric,
       'vence', coalesce(final_terms->>'last_due', final_terms->>'due_date')) order by coalesce(final_terms->>'last_due', final_terms->>'due_date')), '[]') from r where status in ('APROBADA', 'APROBADA_MOD')),
    'score_externo', 'XFact/Veraz: integración FUTURA. No se consulta ningún servicio externo.'));
end; $$;

-- com_request_detail
create or replace function public.com_request_detail(p_id uuid) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me public.profiles := public._com_active(); q public.com_requests;
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into q from public.com_requests where id = p_id;
  if not found or not ((q.requested_by = me.id and public.user_has_perm(me.id, 'com.request')) or (q.assigned_approver_id = me.id and public.user_has_perm(me.id, 'com.approve')) or public._com_admin()) then
    raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return public._com_view(q, true);
end; $$;

-- com_respond
create or replace function public.com_respond(p_id uuid, p_version int, p_accept boolean, p_comment text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles; q public.com_requests; n int;
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  me := public._com_active();
  select * into q from public.com_requests where id = p_id for update;
  if not found or me.id is null or q.requested_by <> me.id or not public.user_has_perm(me.id,'com.request') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_version is null or p_accept is null then raise exception 'BAD_VERSION_OR_RESPONSE' using errcode='23514'; end if;
  if q.status <> 'DEVUELTA' or q.version <> p_version then raise exception 'CONFLICT: la solicitud no está devuelta o cambió' using errcode = '40001'; end if;
  update public.com_requests set status = case when p_accept then 'PENDIENTE' else 'CANCELADA' end, version = version + 1, updated_at = now() where id = q.id;
  n := public._com_event(q.id, case when p_accept then 'CAMBIOS_ACEPTADOS_REENVIADA' else 'RETIRADA_POR_COMERCIAL' end, nullif(btrim(p_comment), ''), null, case when p_accept then q.current_terms end);
  if p_accept then n := public._com_event(q.id, 'PENDIENTE', null, null, null);
    perform public._com_notify(q.id, n, q.assigned_approver_id, 'NUEVA', 'Autorización ' || q.number || ' reenviada con los cambios aceptados', coalesce(p_comment, '')); end if;
  return jsonb_build_object('id', q.id, 'status', case when p_accept then 'PENDIENTE' else 'CANCELADA' end, 'version', q.version + 1);
end; $$;

-- com_search_clients
create or replace function public.com_search_clients(p_q text, p_limit int default 12) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare q text := public._com_norm(p_q); d text := regexp_replace(coalesce(p_q, ''), '\D', '', 'g');
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if not (public.user_has_perm(auth.uid(), 'com.request') or public.user_has_perm(auth.uid(), 'com.approve') or public.user_has_perm(auth.uid(), 'com.track') or public._com_admin()) then
    raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if length(q) < 2 and length(d) < 3 then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(x) from (
    select jsonb_build_object('id', c.id, 'erp_id', c.erp_id, 'razon_social', c.razon_social, 'nombre', c.nombre, 'doc_type', c.doc_type, 'doc_number', c.doc_number, 'cuit', c.cuit,
      'status', c.status, 'review_reasons', c.review_reasons, 'localidad', c.localidad, 'selectable', c.status = 'ACTIVO') x
    from public.com_clients c
    where c.status <> 'BAJA' and ((length(d) >= 3 and (c.doc_number like d || '%' or c.cuit like d || '%')) or (length(q) >= 2 and (c.search_text like q || '%' or c.search_text like '% ' || q || '%')))
    order by (c.status = 'ACTIVO') desc, (length(d) >= 3 and (c.doc_number = d or c.cuit = d)) desc, (c.search_text like q || '%') desc, c.razon_social   -- seleccionables y coincidencias exactas primero
    limit greatest(1, least(coalesce(p_limit, 12), 30))) t), '[]'::jsonb);
end; $$;

-- com_set_alarm_settings
create or replace function public.com_set_alarm_settings(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare ini uuid := nullif(p->>'initial_user', '')::uuid; esc uuid[] := (select coalesce(array_agg(distinct x::uuid), '{}') from jsonb_array_elements_text(coalesce(p->'escalation_users', '[]')) x);
  antes jsonb;
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;   -- B-AL-04
  -- B-AL-03: configuración EXPLÍCITA y COMPLETA (no se guarda «vacío» por accidente)
  if ini is null or cardinality(esc) = 0 then raise exception 'INCOMPLETE: elegí el destinatario inicial y al menos un destinatario de escalamiento' using errcode = '23514'; end if;
  if not exists (select 1 from public.profiles where id = ini and status = 'ACTIVO' and public.user_has_perm(id, 'com.approve')) then
    raise exception 'BAD_RECIPIENT: el destinatario inicial debe estar ACTIVO y tener permiso de aprobación' using errcode = '23514'; end if;
  if exists (select 1 from unnest(esc) x where not exists (select 1 from public.profiles where id = x and status = 'ACTIVO' and role = 'ADMIN')) then
    raise exception 'BAD_RECIPIENT: el escalamiento solo puede dirigirse a Administradores Generales ACTIVOS (suplentes por regla)' using errcode = '23514'; end if;
  select jsonb_build_object('initial_user', alarm_initial_user, 'escalation_users', to_jsonb(alarm_escalation_users)) into antes from public.com_settings where id = 'DEFAULT';
  update public.com_settings set alarm_initial_user = ini, alarm_escalation_users = esc where id = 'DEFAULT';
  insert into public.audit_log(actor_id, action, target_type, target_id, before, after) values (auth.uid(), 'COM_ALARM_SETTINGS', 'com_settings', 'DEFAULT', antes, jsonb_build_object('initial_user', ini, 'escalation_users', to_jsonb(esc)));
  return public.com_alarm_settings();
end; $$;

-- com_set_assignment
create or replace function public.com_set_assignment(p_user uuid, p_channel text, p_branch text, p_cartera text) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if not exists (select 1 from public.profiles where id = p_user and role = 'COMERCIAL') then raise exception 'NOT_COMERCIAL: el usuario no tiene rol Comercial' using errcode = '23514'; end if;
  insert into public.com_user_assignments(user_id, channel, branch, cartera_label, updated_by) values (p_user, p_channel, case when p_channel = 'SUCURSAL' then p_branch end, case when p_channel = 'CARTERA' then nullif(btrim(p_cartera), '') end, auth.uid())
    on conflict (user_id) do update set channel = excluded.channel, branch = excluded.branch, cartera_label = excluded.cartera_label, updated_by = auth.uid(), updated_at = now();
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'COM_ASSIGNMENT', 'profiles', p_user::text, jsonb_build_object('channel', p_channel, 'branch', p_branch, 'cartera', p_cartera));
  return jsonb_build_object('user_id', p_user, 'channel', p_channel);
end; $$;

-- com_set_comp_type
create or replace function public.com_set_comp_type(p_prefix text, p_class text) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  insert into public.com_comp_types(prefix, class, updated_by) values (upper(p_prefix), p_class, auth.uid()) on conflict (prefix) do update set class = excluded.class, updated_by = auth.uid(), updated_at = now();
  update public.com_sc_documents set class = p_class, status = case when status = 'SIN_CLASIFICAR' then case when amount is null then 'SIN_IMPORTE' when doc_date is null then 'SIN_FECHA' else 'OK' end else status end where prefix = upper(p_prefix);
  update public.com_reconciliation_issues set status = 'RESUELTA' where kind = 'TIPO_SIN_CLASIFICAR' and detail->>'prefijo' = upper(p_prefix) and status = 'ABIERTA';
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'COM_COMP_TYPE', 'com_comp_types', upper(p_prefix), jsonb_build_object('class', p_class));
  return jsonb_build_object('prefix', upper(p_prefix), 'class', p_class);
end; $$;

-- com_set_routing
create or replace function public.com_set_routing(p_channel_key text, p_approver uuid) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_approver is not null and (public._com_active(p_approver) is null or not public.user_has_perm(p_approver, 'com.approve')) then
    raise exception 'BAD_APPROVER: el aprobador debe estar ACTIVO y tener permiso de aprobación' using errcode = '23514'; end if;
  update public.com_routing set approver_user_id = p_approver, updated_by = auth.uid(), updated_at = now() where channel_key = p_channel_key;
  if not found then raise exception 'BAD_CHANNEL' using errcode = '23514'; end if;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'COM_ROUTING', 'com_routing', p_channel_key, jsonb_build_object('approver', p_approver));
  return jsonb_build_object('channel_key', p_channel_key, 'approver', public._com_label(p_approver));
end; $$;

-- com_set_settings
create or replace function public.com_set_settings(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.com_settings;
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  update public.com_settings set kpi_months = coalesce((p->>'kpi_months')::int, kpi_months), floor_pct = coalesce((p->>'floor_pct')::numeric, floor_pct), ceiling_pct = coalesce((p->>'ceiling_pct')::numeric, ceiling_pct),
    fin_max_days = coalesce((p->>'fin_max_days')::int, fin_max_days), cheq_max_days = coalesce((p->>'cheq_max_days')::int, cheq_max_days),
    coverage_gap_days = coalesce((p->>'coverage_gap_days')::int, coverage_gap_days), kpi_partial_rule = coalesce(p->>'kpi_partial_rule', kpi_partial_rule),
    kpi_source_verified = coalesce((p->>'kpi_source_verified')::boolean, kpi_source_verified), cuota_rule = coalesce(p->>'cuota_rule', cuota_rule),
    source_backup_enabled = coalesce((p->>'source_backup_enabled')::boolean, source_backup_enabled), source_max_mb = coalesce((p->>'source_max_mb')::int, source_max_mb),
    updated_by = auth.uid(), updated_at = now() where id = 'DEFAULT' returning * into s;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'COM_SETTINGS', 'com_settings', 'DEFAULT', to_jsonb(s));
  return to_jsonb(s);
end; $$;

-- com_sources_status
create or replace function public.com_sources_status() returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return jsonb_build_object(
    'ultima_sc', (select jsonb_build_object('at', at, 'archivo', file_name, 'filas', rows, 'stats', stats, 'periodo', jsonb_build_array(date_min, date_max)) from public.com_ingests where kind = 'SC' and status = 'OK' order by at desc limit 1),
    'ultima_cc', (select jsonb_build_object('at', at, 'archivo', file_name, 'filas', rows) from public.com_ingests where kind = 'CC' and status = 'OK' order by at desc limit 1),
    'errores', (select coalesce(jsonb_agg(jsonb_build_object('at', at, 'kind', kind, 'archivo', file_name, 'error', error) order by at desc), '[]') from (select * from public.com_ingests where status <> 'OK' order by at desc limit 10) e),
    'meses_cubiertos', (select coalesce(jsonb_agg(m order by m), '[]') from (select g::date m from generate_series(date_trunc('month', now()) - interval '12 month', date_trunc('month', now()) - interval '1 month', interval '1 month') g where public._com_month_covered(g::date)) x),
    'incidencias', (select coalesce(jsonb_object_agg(kind, n), '{}') from (select kind, count(*) n from public.com_reconciliation_issues where status = 'ABIERTA' group by kind) x),
    'tipos', (select jsonb_agg(jsonb_build_object('prefijo', prefix, 'clase', class) order by prefix) from public.com_comp_types),
    'clientes_sin_historial', (select count(*) from public.com_clients c where c.status = 'ACTIVO' and (c.cuit is null or not exists (select 1 from public.com_sc_documents d where d.cuit = c.cuit))));
end; $$;

-- com_track
create or replace function public.com_track(p_q text, p_open_only boolean default false, p_limit int default 20, p_offset int default 0) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me public.profiles := public._com_active(); q text := public._com_norm(p_q); d text := regexp_replace(coalesce(p_q, ''), '\D', '', 'g');
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if me.id is null or not (public.user_has_perm(me.id, 'com.track') or public._com_admin()) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(public._com_view(r, public._com_can_see_full(r)) order by r.updated_at desc) from (
    select * from public.com_requests r where (not p_open_only or r.status in ('PENDIENTE', 'DEVUELTA'))
      and (coalesce(btrim(p_q), '') = '' or public._com_norm(r.client_snapshot->>'razon_social') like '%' || q || '%' or public._com_norm(r.client_snapshot->>'nombre') like '%' || q || '%'
           or (length(d) >= 3 and ((r.client_snapshot->>'cuit') like '%' || d || '%' or (r.client_snapshot->>'doc_number') like '%' || d || '%')) or public._com_norm(r.order_ref) like '%' || q || '%' or r.number ilike '%' || p_q || '%')
    order by r.updated_at desc limit greatest(1, least(coalesce(p_limit, 20), 50)) offset greatest(0, coalesce(p_offset, 0))) r), '[]'::jsonb);
end; $$;

COMMIT;
