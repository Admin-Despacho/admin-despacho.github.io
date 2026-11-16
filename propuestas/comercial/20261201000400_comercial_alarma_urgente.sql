-- =====================================================================================================================
-- PROPUESTA · AUTORIZACIONES COMERCIALES · ALARMA URGENTE DE APROBACIÓN COMERCIAL · NO APLICADA. Se aplica después de 000100 a 000300.
-- Despacho (sección REVISAR de la publicación) pide ATENCIÓN URGENTE de un responsable comercial para un PEDIDO de la hoja:
--  · la alarma va al destinatario inicial (Wilfredo); si nadie presiona ATENDER SOLICITUD en 3 minutos, el SERVIDOR la escala a Franco y
--    Gabriela (pg_cron cada minuto + escalamiento perezoso en cada consulta; no depende de ninguna pestaña abierta);
--  · ATENDER no es APROBAR: la resolución sigue por el circuito comercial (aprobar / rechazar / devolver / aprobar con cambios);
--  · la alarma NO modifica importes, NO aprueba operaciones y NO toca notas de crédito (sin relación con NOC);
--  · avisos por la campana (notifications) y por el push existente (push_jobs → Edge Function push-notifications), sin datos financieros;
--  · historial INMUTABLE (com_alarm_events) y alcance por rol en el servidor.
-- =====================================================================================================================
BEGIN;
SET LOCAL lock_timeout = '5s'; SET LOCAL statement_timeout = '60s';
DO $guard$ BEGIN
  IF to_regclass('public.com_requests') IS NULL OR to_regprocedure('public.com_order_alerts(text[],text[])') IS NULL THEN RAISE EXCEPTION 'DEPENDENCIA_FALTANTE: aplicar antes 000100 a 000300. No se modificó nada.'; END IF;
  IF to_regclass('public.notifications') IS NULL OR to_regclass('public.push_jobs') IS NULL OR to_regclass('public.order_reservations') IS NULL THEN RAISE EXCEPTION 'DEPENDENCIA_FALTANTE: notifications / push_jobs / order_reservations. No se modificó nada.'; END IF;
  IF to_regclass('public.com_alarms') IS NOT NULL THEN RAISE EXCEPTION 'YA_APLICADA. No se modificó nada.'; END IF;
END $guard$;

-- ---------- 1) configuración (Panel General) ----------
alter table public.com_settings add column alarm_initial_user uuid references public.profiles(id);          -- configuración EXPLÍCITA obligatoria (Wilfredo)
alter table public.com_settings add column alarm_escalation_users uuid[] not null default '{}';             -- configuración EXPLÍCITA obligatoria (Franco y Gabriela); SIN ampliación automática
alter table public.com_settings add column alarm_escalate_seconds int not null default 180 check (alarm_escalate_seconds between 60 and 3600);

-- ---------- 2) alarmas e historial inmutable ----------
create sequence public.com_alarm_seq;
create table public.com_alarms (
  id uuid primary key default gen_random_uuid(),
  number text not null unique default ('ALR-' || lpad(nextval('public.com_alarm_seq')::text, 6, '0')),
  order_ref text not null, sheet_key text not null, route_id uuid references public.routes(id),
  request_id uuid references public.com_requests(id), branch text,
  client_name text, client_cuit text, client_source text not null check (client_source in ('SOLICITUD_COMERCIAL', 'DECLARADO_POR_DESPACHO')),
  reason text not null check (length(btrim(reason)) >= 10),
  raised_by uuid not null references public.profiles(id), raised_at timestamptz not null default now(),
  initial_user uuid not null references public.profiles(id), escalate_at timestamptz not null,
  escalated_at timestamptz, escalated_to uuid[] not null default '{}',
  status text not null default 'PENDIENTE_ATENCION' check (status in ('PENDIENTE_ATENCION', 'ATENDIDA', 'CANCELADA')),
  attended_by uuid references public.profiles(id), attended_at timestamptz, attended_as text, seconds_to_attend int,
  op_id text unique, version int not null default 1);
create unique index com_alarms_one_active on public.com_alarms(upper(btrim(order_ref))) where status = 'PENDIENTE_ATENCION';   -- sin duplicados
create index com_alarms_due on public.com_alarms(escalate_at) where status = 'PENDIENTE_ATENCION' and escalated_at is null;
create table public.com_alarm_events (
  id bigint generated always as identity primary key, alarm_id uuid not null references public.com_alarms(id),
  kind text not null check (kind in ('CREADA', 'DUPLICADA_EXISTENTE', 'NOTIFICADO', 'ESCALADA', 'ESCALAMIENTO_SIN_DESTINATARIOS', 'ATENDIDA', 'INTENTO_ATENDER_RECHAZADO',
    'OP_ID_REUTILIZADO_RECHAZADO', 'CONFLICTO_UNICIDAD', 'CANCELADA', 'ERROR')),
  actor_id uuid references public.profiles(id), recipient_id uuid references public.profiles(id), notification_id uuid, detail jsonb, at timestamptz not null default now());
-- B-W02: REGISTRO PERSISTENTE de cada operación de emisión (op_id → usuario, pedido, hoja, alarma y RESPUESTA dada). Solo alta.
create table public.com_alarm_ops (
  op_id text primary key check (length(btrim(op_id)) between 6 and 120),
  user_id uuid not null references public.profiles(id), order_ref text not null, sheet_key text not null,
  alarm_id uuid references public.com_alarms(id), result jsonb not null, created_at timestamptz not null default now());
create index com_alarm_ops_alarm on public.com_alarm_ops(alarm_id);
create or replace function public.trg_com_alarm_events_immutable() returns trigger language plpgsql as $$
begin raise exception 'IMMUTABLE: el historial de alarmas no se modifica ni se borra' using errcode = '42501'; end; $$;
create trigger com_alarm_events_immutable before update or delete on public.com_alarm_events for each row execute function public.trg_com_alarm_events_immutable();
create trigger com_alarm_ops_immutable before update or delete on public.com_alarm_ops for each row execute function public.trg_com_alarm_events_immutable();

-- ---------- 3) destinatarios: SOLO la configuración EXPLÍCITA del Administrador General (auditoría B-AL-03). Nunca se amplía automáticamente ----------
-- administrador con SESIÓN VIGENTE (auditoría B-AL-04): perfil activo y token posterior a una revocación (_com_active) + Administrador General
create or replace function public._com_admin() returns boolean language sql stable security definer set search_path = public as $$
  select (public._com_active()).id is not null and public._is_general_admin();
$$;
create or replace function public._com_alarm_initial() returns uuid language sql stable security definer set search_path = public as $$
  select p.id from public.com_settings s join public.profiles p on p.id = s.alarm_initial_user
   where s.id = 'DEFAULT' and p.status = 'ACTIVO' and public.user_has_perm(p.id, 'com.approve');
$$;
create or replace function public._com_alarm_escalation() returns uuid[] language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(p.id order by p.full_name), '{}') from public.com_settings s, unnest(s.alarm_escalation_users) u join public.profiles p on p.id = u
   where s.id = 'DEFAULT' and p.status = 'ACTIVO' and p.role = 'ADMIN';
$$;
-- aviso por la campana; el disparador existente lo pasa al push (tipos agregados abajo). Sin importes: se ve en la pantalla bloqueada.
create or replace function public._com_alarm_notify(a public.com_alarms, p_user uuid, p_type text, p_title text, p_body text, p_actor uuid) returns void language plpgsql security definer set search_path = public as $$
declare nid uuid;
begin
  insert into public.notifications(user_id, type, title, body) values (p_user, p_type, p_title, p_body) returning id into nid;
  insert into public.com_alarm_events(alarm_id, kind, actor_id, recipient_id, notification_id, detail) values (a.id, 'NOTIFICADO', p_actor, p_user, nid, jsonb_build_object('tipo', p_type, 'canal', 'CAMPANA+PUSH'));
exception when others then
  insert into public.com_alarm_events(alarm_id, kind, actor_id, recipient_id, detail) values (a.id, 'ERROR', p_actor, p_user, jsonb_build_object('tipo', p_type, 'error', sqlerrm));
end; $$;

-- ---------- 4) emitir (Despacho, desde REVISAR) ----------
create or replace function public.com_alarm_raise(p_order_ref text, p_sheet_key text, p_client_name text, p_client_cuit text, p_reason text, p_op_id text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._com_active(); a public.com_alarms; o public.com_alarm_ops; q public.com_requests; ini uuid; st public.com_settings;
  ref text := upper(btrim(coalesce(p_order_ref, ''))); op text := btrim(coalesce(p_op_id, '')); res jsonb; cname text;
  aviso constant text := 'Ese identificador de operación ya se usó para otra operación. Reintentá desde la pantalla.';
begin
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

-- ---------- 5) escalamiento del SERVIDOR (pg_cron cada minuto + perezoso). Idempotente: cada alarma se escala UNA vez ----------
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

-- ---------- 6) ATENDER (no es aprobar). Una sola persona la toma: bloqueo de fila + versión ----------
create or replace function public.com_alarm_attend(p_id uuid, p_version int) returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._com_active(); a public.com_alarms; como text; u uuid;
begin
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

-- ---------- 7) consultas por rol ----------
create or replace function public._com_alarm_view(a public.com_alarms, p_me uuid) returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', a.id, 'number', a.number, 'order_ref', a.order_ref, 'sheet_key', a.sheet_key, 'client', a.client_name, 'cuit', a.client_cuit, 'client_source', a.client_source,
    'branch', a.branch, 'reason', a.reason, 'raised_by', public._com_label(a.raised_by), 'raised_at', a.raised_at, 'initial_user', public._com_label(a.initial_user), 'escalate_at', a.escalate_at,
    'escalated_at', a.escalated_at, 'escalated_to', (select coalesce(jsonb_agg(public._com_label(x)), '[]') from unnest(a.escalated_to) x), 'status', a.status,
    'attended_by', public._com_label(a.attended_by), 'attended_at', a.attended_at, 'seconds_to_attend', a.seconds_to_attend, 'version', a.version,
    'request', (select jsonb_build_object('id', q.id, 'number', q.number, 'status', q.status) from public.com_requests q where q.id = a.request_id),
    -- ¿le SUENA a este usuario? destinatario inicial mientras esté pendiente; escalados después del escalamiento
    'ring', a.status = 'PENDIENTE_ATENCION' and (p_me = a.initial_user or p_me = any(a.escalated_to)),
    'can_attend', a.status = 'PENDIENTE_ATENCION' and (p_me = a.initial_user or p_me = any(a.escalated_to) or public._com_admin()));
$$;
create or replace function public.com_my_alarms() returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._com_active();
begin
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  perform public.com_alarm_escalate_due();   -- perezoso: adelanta el escalamiento si hay alguien conectado (el reloj sigue siendo el del servidor)
  return coalesce((select jsonb_agg(public._com_alarm_view(a, me.id) order by a.raised_at desc) from public.com_alarms a
    where (a.status = 'PENDIENTE_ATENCION' or a.attended_at > now() - interval '12 hours')
      and (a.raised_by = me.id or a.initial_user = me.id or me.id = any(a.escalated_to) or public._com_admin())), '[]'::jsonb);
end; $$;
create or replace function public.com_alarm_history(p_from date, p_to date) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;   -- B-AL-04: también rechaza un token REVOCADO
  return coalesce((select jsonb_agg(public._com_alarm_view(a, auth.uid()) || jsonb_build_object(
      'resolucion_comercial', (select jsonb_build_object('estado', q.status, 'resolvio', public._com_label(q.decided_by), 'cuando', q.decided_at) from public.com_requests q where q.id = a.request_id),
      'eventos', (select jsonb_agg(jsonb_build_object('kind', e.kind, 'at', e.at, 'actor', public._com_label(e.actor_id), 'destinatario', public._com_label(e.recipient_id),
                   'push', (select j.status || coalesce(' · ' || j.last_error, '') from public.push_jobs j where j.notification_id = e.notification_id), 'detalle', e.detail) order by e.id)
                  from public.com_alarm_events e where e.alarm_id = a.id)) order by a.raised_at desc)
    from public.com_alarms a where a.raised_at >= p_from and a.raised_at < p_to + 1), '[]'::jsonb);
end; $$;
create or replace function public.com_alarm_settings() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare st public.com_settings; pr text[] := '{}';
begin
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
create or replace function public.com_set_alarm_settings(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare ini uuid := nullif(p->>'initial_user', '')::uuid; esc uuid[] := (select coalesce(array_agg(distinct x::uuid), '{}') from jsonb_array_elements_text(coalesce(p->'escalation_users', '[]')) x);
  antes jsonb;
begin
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
-- B-AL-02: el enlace del push (#/autorizaciones?alarma_n=<aviso>) abre ESA alarma. Solo responde al DESTINATARIO de ese aviso.
create or replace function public.com_alarm_by_notification(p_notification uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._com_active(); a public.com_alarms;
begin
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  perform public.com_alarm_escalate_due();
  select al.* into a from public.com_alarm_events e join public.com_alarms al on al.id = e.alarm_id where e.notification_id = p_notification and e.recipient_id = me.id limit 1;
  if not found then return null; end if;
  return public._com_alarm_view(a, me.id);
end; $$;

-- ---------- 8) push: los avisos de la alarma usan la cola EXISTENTE (se conservan los 6 tipos vigentes) ----------
create or replace function public.queue_notification_push()
returns trigger language plpgsql security definer set search_path='public' as $$
begin
  if new.type in ('NUEVA_HOJA_PUBLICADA','HOJA_CORREGIDA','REQUEST_CREATED','REQUEST_APPROVED','REQUEST_REJECTED','REQUEST_OBSERVED',
                  'COM_ALARMA','COM_ALARMA_ESCALADA','COM_ALARMA_ATENDIDA') then   -- Autorizaciones comerciales: alarma urgente
    insert into public.push_jobs(notification_id,user_id)
    values(new.id,new.user_id)
    on conflict(notification_id) do nothing;
  end if;
  return new;
end; $$;

-- ---------- 9) privilegios ----------
do $$ declare f text; begin
  foreach f in array array['com_alarms', 'com_alarm_events', 'com_alarm_ops'] loop
    execute 'alter table public.' || f || ' enable row level security'; execute 'revoke all on public.' || f || ' from anon, authenticated'; end loop;
  foreach f in array array['com_alarm_raise(text,text,text,text,text,text)', 'com_alarm_attend(uuid,int)', 'com_my_alarms()', 'com_alarm_history(date,date)', 'com_set_alarm_settings(jsonb)',
                           'com_alarm_settings()', 'com_alarm_by_notification(uuid)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon'; execute 'grant execute on function public.' || f || ' to authenticated'; end loop;
  foreach f in array array['com_alarm_escalate_due()', '_com_alarm_initial()', '_com_alarm_escalation()', '_com_alarm_notify(public.com_alarms,uuid,text,text,text,uuid)',
                           '_com_alarm_view(public.com_alarms,uuid)', 'trg_com_alarm_events_immutable()'] loop
    execute 'revoke all on function public.' || f || ' from public, anon, authenticated'; end loop;
end $$;
-- _com_admin() solo informa sobre el PROPIO usuario; las políticas de almacenamiento (000500) la evalúan con los privilegios de quien consulta
revoke all on function public._com_admin() from public, anon; grant execute on function public._com_admin() to authenticated;
COMMIT;
