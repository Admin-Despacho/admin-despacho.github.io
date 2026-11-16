-- =====================================================================================================================
-- PROPUESTA · AUTORIZACIONES COMERCIALES · V5 (auditoría Work V4, 15/11) · NO APLICADA. Después de 000100 a 000800.
-- Generada por tools/gen_v5.py desde el TEXTO EXACTO vigente de cada función, con reemplazos verificados.
--  · N-V4-01 · PERMISO ACTUAL en alarmas: lectura, enlace directo, atención y respuesta de emisión exigen el permiso efectivo de HOY
--    (user_has_perm descuenta módulos restringidos, también sobre permisos individuales). Una asignación histórica no da acceso.
--    Política de Dirección: la restricción COMERCIAL también rige para el Administrador General (_com_admin).
--    Alarmas e historial se CONSERVAN para auditoría y para los usuarios que siguen autorizados.
--  · N-V4-03 · KPI DESHABILITADO por defecto y DESDE la instalación; las fotos guardadas no se exponen mientras esté deshabilitado
--    (se conservan). Reactivarlo exige una referencia a la autorización de Dirección General, auditada.
--  · N-V4-05 · límites diarios en el horario operativo de Argentina (America/Argentina/Mendoza): historial y, por la revisión anticipatoria,
--    también historial de alarmas, informes y estadísticas de Despacho. No cambia datos ni el timezone global.
--  · N-V4-02 · push_session_valid: el handler de push comprueba la VIGENCIA de la sesión (claims completos, perfil activo, token posterior
--    a sessions_revoked_at y sesión existente) ANTES de reclamar trabajos. Solo para el servicio.
-- =====================================================================================================================
BEGIN;
SET LOCAL lock_timeout = '5s'; SET LOCAL statement_timeout = '60s';
DO $guard$ BEGIN
  IF to_regprocedure('public.com_my_alarms_page(integer)') IS NULL OR to_regprocedure('public.com_set_kpi_mode(text)') IS NULL THEN
    RAISE EXCEPTION 'DEPENDENCIA_FALTANTE: aplicar antes 000100 a 000800. No se modificó nada.'; END IF;
  IF to_regprocedure('public._com_alarm_role(public.com_alarms,uuid)') IS NOT NULL THEN RAISE EXCEPTION 'YA_APLICADA. No se modificó nada.'; END IF;
END $guard$;

-- ---------- N-V4-01 · administrador con sesión vigente y SIN la restricción COMERCIAL (política de Dirección) ----------
create or replace function public._com_admin() returns boolean language sql stable security definer set search_path = public as $$
  select (public._com_active()).id is not null and public._is_general_admin()
     and not exists (select 1 from public.profiles p where p.id = auth.uid() and 'COMERCIAL' = any(p.disabled_modules));
$$;
-- papel de un usuario frente a una alarma, con su permiso ACTUAL (null = sin acceso)
create or replace function public._com_alarm_role(a public.com_alarms, p_me uuid) returns text language sql stable security definer set search_path = public as $$
  select case
    when p_me = a.initial_user and public.user_has_perm(p_me, 'com.approve') then 'DESTINATARIO_INICIAL'
    when p_me = any(a.escalated_to) and public.user_has_perm(p_me, 'com.approve') then 'ESCALAMIENTO'
    when p_me = auth.uid() and public._com_admin() then 'ADMINISTRADOR_GENERAL'
    when p_me = a.raised_by and public.user_has_perm(p_me, 'com.track') then 'SOLICITANTE' end;
$$;

-- ---------- N-V4-05 · inicio del día ARGENTINO (America/Argentina/Mendoza) para todos los filtros por fecha del módulo ----------
create or replace function public._com_ar_day(p date) returns timestamptz language sql immutable set search_path = public as $$
  select p::timestamp at time zone 'America/Argentina/Mendoza';
$$;

-- ---------- N-V4-03 · KPI DESHABILITADO por defecto y en la instalación ----------
alter table public.com_settings alter column kpi_mode set default 'DESHABILITADO';
update public.com_settings set kpi_mode = 'DESHABILITADO' where id = 'DEFAULT';
drop function public.com_set_kpi_mode(text);
create or replace function public.com_set_kpi_mode(p_mode text, p_autorizacion text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._com_active(); antes text;
begin
  if me.id is null or not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_mode not in ('PROVISORIO', 'DESHABILITADO') then raise exception 'BAD_MODE' using errcode = '22023'; end if;
  -- reactivar el KPI es una decisión EXPRESA de Dirección General: se exige la referencia escrita y queda auditada
  if p_mode = 'PROVISORIO' and length(btrim(coalesce(p_autorizacion, ''))) < 20 then
    raise exception 'AUTORIZACION_REQUERIDA: indicá la referencia a la autorización expresa de Dirección General para reactivar el KPI' using errcode = '23514'; end if;
  select kpi_mode into antes from public.com_settings where id = 'DEFAULT';
  update public.com_settings set kpi_mode = p_mode where id = 'DEFAULT';
  insert into public.audit_log(actor_id, action, target_type, target_id, before, after) values (me.id, 'COM_KPI_MODE', 'com_settings', 'DEFAULT',
    jsonb_build_object('kpi_mode', antes), jsonb_build_object('kpi_mode', p_mode, 'autorizacion', nullif(btrim(coalesce(p_autorizacion, '')), '')));
  return jsonb_build_object('kpi_mode', p_mode);
end; $$;

-- ---------- N-V4-02 · vigencia de la sesión para el handler de push (SOLO servicio) ----------
create or replace function public.push_session_valid(p_user uuid, p_iat numeric, p_session text) returns jsonb language plpgsql stable security definer set search_path = public, auth as $$
declare p public.profiles;
begin
  if p_user is null or p_iat is null then return jsonb_build_object('ok', false, 'motivo', 'CLAIMS_INCOMPLETOS'); end if;
  select * into p from public.profiles where id = p_user;
  if not found or p.status <> 'ACTIVO' then return jsonb_build_object('ok', false, 'motivo', 'PERFIL_NO_ACTIVO'); end if;
  if p.sessions_revoked_at is not null and p_iat <= extract(epoch from p.sessions_revoked_at) then return jsonb_build_object('ok', false, 'motivo', 'SESION_REVOCADA'); end if;
  if p_session is not null and to_regclass('auth.sessions') is not null
     and not exists (select 1 from auth.sessions s where s.id::text = p_session and s.user_id = p_user) then return jsonb_build_object('ok', false, 'motivo', 'SESION_INEXISTENTE'); end if;
  return jsonb_build_object('ok', true);
end; $$;

-- _com_view (texto exacto vigente + reemplazos verificados)
create or replace function public._com_view(q public.com_requests, p_full boolean) returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', q.id, 'number', q.number, 'kind', q.kind, 'status', q.status, 'client', q.client_snapshot, 'order_ref', q.order_ref, 'channel', q.channel, 'branch', q.branch,
    'cartera_label', q.cartera_label, 'requested_by', public._com_label(q.requested_by), 'assigned_approver', public._com_label(q.assigned_approver_id), 'assigned_approver_id', q.assigned_approver_id,
    'decided_by', public._com_label(q.decided_by), 'decided_as', q.decided_as, 'decided_at', q.decided_at, 'created_at', q.created_at, 'updated_at', q.updated_at, 'version', q.version,
    'current_terms', q.current_terms, 'final_terms', q.final_terms, 'original_terms', case when p_full then q.original_terms end, 'notes', case when p_full then q.notes end,
    'kpi', case when p_full then (case when (select kpi_mode from public.com_settings where id = 'DEFAULT') = 'DESHABILITADO'
      then jsonb_build_object('status', 'DESHABILITADO', 'provisional', true, 'detail', 'KPI DESHABILITADO — pendiente de verificar los informes de Cianbox. La autorización es manual.')
      else q.kpi_snapshot end) end,   -- N-V4-03: con el KPI deshabilitado no se EXPONE la foto guardada (se CONSERVA en la tabla)
    'timeline', (select jsonb_agg(jsonb_build_object('seq', e.seq, 'kind', e.kind, 'by', e.actor_label, 'at', e.at, 'reason', case when p_full then e.reason end,
       'assigned', public._com_label(e.assigned_approver_id), 'terms_after', case when p_full then e.terms_after end) order by e.seq) from public.com_request_events e where e.request_id = q.id));
$$;

-- com_alarm_history (texto exacto vigente + reemplazos verificados)
create or replace function public.com_alarm_history(p_from date, p_to date) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;   -- B-AL-04: también rechaza un token REVOCADO
  return coalesce((select jsonb_agg(public._com_alarm_view(a, auth.uid()) || jsonb_build_object(
      'resolucion_comercial', (select jsonb_build_object('estado', q.status, 'resolvio', public._com_label(q.decided_by), 'cuando', q.decided_at) from public.com_requests q where q.id = a.request_id),
      'eventos', (select jsonb_agg(jsonb_build_object('kind', e.kind, 'at', e.at, 'actor', public._com_label(e.actor_id), 'destinatario', public._com_label(e.recipient_id),
                   'push', (select j.status || coalesce(' · ' || j.last_error, '') from public.push_jobs j where j.notification_id = e.notification_id), 'detalle', e.detail) order by e.id)
                  from public.com_alarm_events e where e.alarm_id = a.id)) order by a.raised_at desc)
    from public.com_alarms a where a.raised_at >= public._com_ar_day(p_from) and a.raised_at < public._com_ar_day(p_to + 1)), '[]'::jsonb);
end; $$;

-- com_alarm_history_page (texto exacto vigente + reemplazos verificados)
create or replace function public.com_alarm_history_page(p_from date, p_to date, p_cursor jsonb, p_limit int default 25) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me public.profiles := public._com_active(); lim int := greatest(1, least(coalesce(p_limit, 25), 100)); cc timestamptz; ci uuid; rows jsonb; n int;
begin
  if me.id is null or not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_cursor is not null then begin cc := (p_cursor->>'c')::timestamptz; ci := (p_cursor->>'i')::uuid; exception when others then raise exception 'BAD_CURSOR' using errcode = '22023'; end; end if;
  select coalesce(jsonb_agg(x order by (x->>'raised_at')::timestamptz desc, (x->>'id') desc), '[]'::jsonb), count(*) into rows, n from (
    select public._com_alarm_view(a, me.id) || jsonb_build_object(
      'resolucion_comercial', (select jsonb_build_object('estado', q.status, 'resolvio', public._com_label(q.decided_by), 'cuando', q.decided_at) from public.com_requests q where q.id = a.request_id),
      'eventos', (select jsonb_agg(jsonb_build_object('kind', e.kind, 'at', e.at, 'actor', public._com_label(e.actor_id), 'destinatario', public._com_label(e.recipient_id),
                   'push', (select j.status || coalesce(' · ' || j.last_error, '') from public.push_jobs j where j.notification_id = e.notification_id), 'detalle', e.detail) order by e.id)
                  from public.com_alarm_events e where e.alarm_id = a.id)) x
    from public.com_alarms a
    where a.raised_at >= coalesce(public._com_ar_day(p_from), '-infinity'::timestamptz) and a.raised_at < coalesce(public._com_ar_day(p_to + 1), 'infinity'::timestamptz)
      and (p_cursor is null or (a.raised_at, a.id) < (cc, ci))
    order by a.raised_at desc, a.id desc limit lim + 1) t;
  if n > lim then rows := rows - lim; end if;
  return jsonb_build_object('items', rows, 'has_more', n > lim, 'page_size', lim,
    'next_cursor', case when n > lim then jsonb_build_object('c', rows->(lim - 1)->>'raised_at', 'i', rows->(lim - 1)->>'id') end);
end; $$;

-- com_dispatch_stats (texto exacto vigente + reemplazos verificados)
create or replace function public.com_dispatch_stats(p_from date, p_to date) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(x order by (x->>'paradas')::int desc) from (
    select jsonb_build_object('transportista', coalesce(ca.name, r.carrier_id), 'zona', coalesce(nullif(s.zone, ''), 'SIN ZONA'), 'hojas', count(distinct r.id), 'paradas', count(*),
      'entregadas', count(*) filter (where s.outcome = 'ENTREGADO')) x
    from public.routes r join public.route_stops s on s.route_id = r.id left join public.carriers ca on ca.id = r.carrier_id
    where coalesce(s.stop_type, 'PEDIDO') = 'PEDIDO' and r.published_at >= public._com_ar_day(p_from) and r.published_at < public._com_ar_day(p_to + 1) group by coalesce(ca.name, r.carrier_id), coalesce(nullif(s.zone, ''), 'SIN ZONA')) t), '[]'::jsonb);
end; $$;

-- com_report (texto exacto vigente + reemplazos verificados)
create or replace function public.com_report(p_from date, p_to date) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return (with r as (select * from public.com_requests where created_at >= public._com_ar_day(p_from) and created_at < public._com_ar_day(p_to + 1))
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

-- _com_alarm_escalation (texto exacto vigente + reemplazos verificados)
create or replace function public._com_alarm_escalation() returns uuid[] language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(p.id order by p.full_name), '{}') from public.com_settings s, unnest(s.alarm_escalation_users) u join public.profiles p on p.id = u
   where s.id = 'DEFAULT' and p.status = 'ACTIVO' and p.role = 'ADMIN' and not ('COMERCIAL' = any(p.disabled_modules));
$$;

-- _com_alarm_view (texto exacto vigente + reemplazos verificados)
create or replace function public._com_alarm_view(a public.com_alarms, p_me uuid) returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', a.id, 'number', a.number, 'order_ref', a.order_ref, 'sheet_key', a.sheet_key, 'client', a.client_name, 'cuit', a.client_cuit, 'client_source', a.client_source,
    'branch', a.branch, 'reason', a.reason, 'raised_by', public._com_label(a.raised_by), 'raised_at', a.raised_at, 'initial_user', public._com_label(a.initial_user), 'escalate_at', a.escalate_at,
    'escalated_at', a.escalated_at, 'escalated_to', (select coalesce(jsonb_agg(public._com_label(x)), '[]') from unnest(a.escalated_to) x), 'status', a.status,
    'attended_by', public._com_label(a.attended_by), 'attended_at', a.attended_at, 'seconds_to_attend', a.seconds_to_attend, 'version', a.version,
    'request', (select jsonb_build_object('id', q.id, 'number', q.number, 'status', q.status) from public.com_requests q where q.id = a.request_id),
    -- ¿le SUENA a este usuario? destinatario inicial mientras esté pendiente; escalados después del escalamiento
    'ring', a.status = 'PENDIENTE_ATENCION' and (p_me = a.initial_user or p_me = any(a.escalated_to)) and public.user_has_perm(p_me, 'com.approve'),   -- N-V4-01: permiso ACTUAL
    'can_attend', a.status = 'PENDIENTE_ATENCION' and coalesce(public._com_alarm_role(a, p_me), 'SOLICITANTE') <> 'SOLICITANTE');   -- N-V4-01
$$;

-- com_alarm_raise (texto exacto vigente + reemplazos verificados)
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

-- com_alarm_attend (texto exacto vigente + reemplazos verificados)
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

-- com_alarm_by_notification (texto exacto vigente + reemplazos verificados)
create or replace function public.com_alarm_by_notification(p_notification uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._com_active(); a public.com_alarms;
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  perform public.com_alarm_escalate_due();
  select al.* into a from public.com_alarm_events e join public.com_alarms al on al.id = e.alarm_id where e.notification_id = p_notification and e.recipient_id = me.id limit 1;
  if not found or public._com_alarm_role(a, me.id) is null then return null; end if;   -- N-V4-01: el enlace previo no da acceso sin el permiso ACTUAL
  return public._com_alarm_view(a, me.id);
end; $$;

-- com_my_alarms (texto exacto vigente + reemplazos verificados)
create or replace function public.com_my_alarms() returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._com_active();
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  perform public.com_alarm_escalate_due();   -- perezoso: adelanta el escalamiento si hay alguien conectado (el reloj sigue siendo el del servidor)
  return coalesce((select jsonb_agg(public._com_alarm_view(a, me.id) order by a.raised_at desc) from public.com_alarms a
    where (a.status = 'PENDIENTE_ATENCION' or a.attended_at > now() - interval '12 hours')
      and (public._com_alarm_role(a, me.id) is not null)), '[]'::jsonb);
end; $$;

-- com_my_alarms_page (texto exacto vigente + reemplazos verificados)
create or replace function public.com_my_alarms_page(p_limit int default 20) returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._com_active(); lim int := greatest(1, least(coalesce(p_limit, 20), 50)); items jsonb; tot int;
begin
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  perform public.com_alarm_escalate_due();
  with vis as (select a.* from public.com_alarms a where (a.status = 'PENDIENTE_ATENCION' or a.attended_at > now() - interval '12 hours')
                 and (public._com_alarm_role(a, me.id) is not null))
  select (select count(*) from vis where status = 'PENDIENTE_ATENCION'),
         coalesce((select jsonb_agg(public._com_alarm_view(v, me.id) order by (v.status = 'PENDIENTE_ATENCION') desc, v.raised_at desc, v.id desc)
                     from (select * from vis order by (status = 'PENDIENTE_ATENCION') desc, raised_at desc, id desc limit lim) v), '[]'::jsonb)
    into tot, items;
  return jsonb_build_object('items', items, 'total_pending', tot, 'has_more', (select count(*) from public.com_alarms a where (a.status = 'PENDIENTE_ATENCION' or a.attended_at > now() - interval '12 hours')
    and (public._com_alarm_role(a, me.id) is not null)) > lim, 'page_size', lim);
end; $$;

-- com_set_alarm_settings (texto exacto vigente + reemplazos verificados)
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
  if exists (select 1 from unnest(esc) x where not exists (select 1 from public.profiles where id = x and status = 'ACTIVO' and role = 'ADMIN' and not ('COMERCIAL' = any(disabled_modules)))) then
    raise exception 'BAD_RECIPIENT: el escalamiento solo puede dirigirse a Administradores Generales ACTIVOS (suplentes por regla)' using errcode = '23514'; end if;
  select jsonb_build_object('initial_user', alarm_initial_user, 'escalation_users', to_jsonb(alarm_escalation_users)) into antes from public.com_settings where id = 'DEFAULT';
  update public.com_settings set alarm_initial_user = ini, alarm_escalation_users = esc where id = 'DEFAULT';
  insert into public.audit_log(actor_id, action, target_type, target_id, before, after) values (auth.uid(), 'COM_ALARM_SETTINGS', 'com_settings', 'DEFAULT', antes, jsonb_build_object('initial_user', ini, 'escalation_users', to_jsonb(esc)));
  return public.com_alarm_settings();
end; $$;

-- com_history (texto exacto vigente + reemplazos verificados)
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
      and (coalesce(f->>'from', '') = '' or q.created_at >= ((f->>'from')::date::timestamp at time zone 'America/Argentina/Mendoza'))   -- N-V4-05: día operativo argentino
      and (coalesce(f->>'to', '') = '' or q.created_at < (((f->>'to')::date + 1)::timestamp at time zone 'America/Argentina/Mendoza'))
      and (st is null or q.status = any(st))
      and (coalesce(f->>'kind', '') = '' or q.kind = f->>'kind')
    order by q.created_at desc, q.id desc limit lim + 1) t;
  if n > lim then rows := rows - lim; end if;   -- se pidió una fila de más solo para saber si quedan resultados
  return jsonb_build_object('items', rows, 'has_more', n > lim, 'page_size', lim,
    'next_cursor', case when n > lim then jsonb_build_object('c', rows->(lim - 1)->>'created_at', 'i', rows->(lim - 1)->>'id') end);
end; $$;

-- ---------- privilegios ----------
revoke all on function public._com_alarm_role(public.com_alarms,uuid) from public, anon, authenticated;
revoke all on function public._com_ar_day(date) from public, anon, authenticated;
revoke all on function public.com_set_kpi_mode(text,text) from public, anon; grant execute on function public.com_set_kpi_mode(text,text) to authenticated;
revoke all on function public.push_session_valid(uuid,numeric,text) from public, anon, authenticated;
DO $$ BEGIN IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN EXECUTE 'GRANT EXECUTE ON FUNCTION public.push_session_valid(uuid,numeric,text) TO service_role'; END IF; END $$;
DO $post$ BEGIN IF (SELECT kpi_mode FROM public.com_settings WHERE id = 'DEFAULT') <> 'DESHABILITADO' THEN RAISE EXCEPTION 'EL_KPI_DEBE_QUEDAR_DESHABILITADO'; END IF; END $post$;
COMMIT;
