-- =====================================================================================================================
-- PROPUESTA · AUTORIZACIONES COMERCIALES · V4 · ALARMA: PAGINACIÓN (O-W05) y PUSH POR DESTINATARIO/DISPOSITIVO (O-W04) · NO APLICADA.
-- Después de 000100 a 000700. Agrega funciones de LECTURA, endurece com_config (B-W04) y el modo del KPI (sección 5: columna kpi_mode, predeterminado PROVISORIO = sin cambios). Todas validan la sesión vigente PRIMERO (_com_active).
-- =====================================================================================================================
BEGIN;
SET LOCAL lock_timeout = '5s'; SET LOCAL statement_timeout = '60s';
DO $guard$ BEGIN
  IF to_regclass('public.com_alarm_ops') IS NULL OR to_regprocedure('public.com_history(text,jsonb,jsonb,integer)') IS NULL THEN RAISE EXCEPTION 'DEPENDENCIA_FALTANTE: aplicar antes 000100 a 000700. No se modificó nada.'; END IF;
END $guard$;

-- O-W05 · mis alarmas con TOPE: las pendientes más recientes primero (máx. p_limit) + el total, para no cargar decenas de tarjetas ni de filas
create or replace function public.com_my_alarms_page(p_limit int default 20) returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._com_active(); lim int := greatest(1, least(coalesce(p_limit, 20), 50)); items jsonb; tot int;
begin
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  perform public.com_alarm_escalate_due();
  with vis as (select a.* from public.com_alarms a where (a.status = 'PENDIENTE_ATENCION' or a.attended_at > now() - interval '12 hours')
                 and (a.raised_by = me.id or a.initial_user = me.id or me.id = any(a.escalated_to) or public._com_admin()))
  select (select count(*) from vis where status = 'PENDIENTE_ATENCION'),
         coalesce((select jsonb_agg(public._com_alarm_view(v, me.id) order by (v.status = 'PENDIENTE_ATENCION') desc, v.raised_at desc, v.id desc)
                     from (select * from vis order by (status = 'PENDIENTE_ATENCION') desc, raised_at desc, id desc limit lim) v), '[]'::jsonb)
    into tot, items;
  return jsonb_build_object('items', items, 'total_pending', tot, 'has_more', (select count(*) from public.com_alarms a where (a.status = 'PENDIENTE_ATENCION' or a.attended_at > now() - interval '12 hours')
    and (a.raised_by = me.id or a.initial_user = me.id or me.id = any(a.escalated_to) or public._com_admin())) > lim, 'page_size', lim);
end; $$;

-- O-W05 · historial ADMINISTRATIVO de alarmas por CURSOR estable (raised_at, id)
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
    where a.raised_at >= coalesce(p_from, '-infinity'::date) and a.raised_at < coalesce(p_to, 'infinity'::date) + 1
      and (p_cursor is null or (a.raised_at, a.id) < (cc, ci))
    order by a.raised_at desc, a.id desc limit lim + 1) t;
  if n > lim then rows := rows - lim; end if;
  return jsonb_build_object('items', rows, 'has_more', n > lim, 'page_size', lim,
    'next_cursor', case when n > lim then jsonb_build_object('c', rows->(lim - 1)->>'raised_at', 'i', rows->(lim - 1)->>'id') end);
end; $$;

-- O-W04 · el sonido NO equivale a una suscripción push: dispositivos con push ACTIVO de cada destinatario configurado (Panel General)
create or replace function public.com_alarm_push_status() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me public.profiles := public._com_active(); st public.com_settings;
begin
  if me.id is null or not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into st from public.com_settings where id = 'DEFAULT';
  return coalesce((select jsonb_agg(jsonb_build_object('rol', r.rol, 'usuario', public._com_label(r.uid),
      'dispositivos_activos', (select count(*) from public.push_subscriptions s where s.user_id = r.uid and s.revoked_at is null),
      'ultima_actualizacion', (select max(s.updated_at) from public.push_subscriptions s where s.user_id = r.uid and s.revoked_at is null)) order by r.ord)
    from (select 'INICIAL' rol, st.alarm_initial_user uid, 0 ord where st.alarm_initial_user is not null
          union all select 'ESCALAMIENTO', u, 1 from unnest(st.alarm_escalation_users) u) r), '[]'::jsonb);
end; $$;
-- O-W04 · ¿este usuario tiene push ACTIVO registrado en el servidor? (la alarma ofrece REACTIVAR si el navegador tiene permiso pero no hay registro)
create or replace function public.com_my_push_devices() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me public.profiles := public._com_active();
begin
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return jsonb_build_object('activos', (select count(*) from public.push_subscriptions where user_id = me.id and revoked_at is null));
end; $$;

-- Sección 5 · separación segura de los KPI financieros NO verificados (WORK-K02 / Cianbox): modo PROVISORIO (actual, predeterminado) o DESHABILITADO.
-- Con DESHABILITADO el circuito de autorizaciones, el historial y la alarma siguen iguales (el KPI nunca bloqueó), pero no se calcula ni se muestra.
alter table public.com_settings add column kpi_mode text not null default 'PROVISORIO' check (kpi_mode in ('PROVISORIO', 'DESHABILITADO'));
create or replace function public.com_kpi_for_client(p_client uuid, p_at timestamptz default now()) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if (public._com_active()).id is null or not (public._com_admin() or public.user_has_perm(auth.uid(),'com.request') or public.user_has_perm(auth.uid(),'com.approve')) then raise exception 'FORBIDDEN' using errcode='42501'; end if;
  if not public._com_admin() and not public.user_has_perm(auth.uid(),'com.request') and not exists(select 1 from public.com_requests where client_id=p_client and assigned_approver_id=auth.uid()) then raise exception 'FORBIDDEN_CLIENT' using errcode='42501'; end if;
  -- Sección 5 de la orden V4: con el KPI DESHABILITADO no se calcula ni se muestra ninguna cifra no verificada (la solicitud guarda solo esta marca)
  if (select kpi_mode from public.com_settings where id = 'DEFAULT') = 'DESHABILITADO' then
    return jsonb_build_object('status', 'DESHABILITADO', 'provisional', true, 'detail', 'KPI DESHABILITADO — pendiente de verificar los informes de Cianbox. La autorización es manual.');
  end if;
  return public._com_kpi_raw(p_client,p_at) || (select jsonb_build_object('provisional',not s.kpi_source_verified,'label',case when s.kpi_source_verified then null else 'RECOMENDACIÓN PROVISORIA — BASADA EN COMPROBANTES DISPONIBLES' end) from public.com_settings s where id='DEFAULT');
end; $$;
create or replace function public.com_set_kpi_mode(p_mode text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._com_active(); antes text;
begin
  if me.id is null or not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_mode not in ('PROVISORIO', 'DESHABILITADO') then raise exception 'BAD_MODE' using errcode = '22023'; end if;
  select kpi_mode into antes from public.com_settings where id = 'DEFAULT';
  update public.com_settings set kpi_mode = p_mode where id = 'DEFAULT';
  insert into public.audit_log(actor_id, action, target_type, target_id, before, after) values (me.id, 'COM_KPI_MODE', 'com_settings', 'DEFAULT', jsonb_build_object('kpi_mode', antes), jsonb_build_object('kpi_mode', p_mode));
  return jsonb_build_object('kpi_mode', p_mode);
end; $$;

-- B-W04 · com_config (texto EXACTO de 000700 + exigencia de algún permiso del módulo): un usuario con COMERCIAL restringido no recibe la configuración
create or replace function public.com_config() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me public.profiles := public._com_active();
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  -- B-W04: con el módulo COMERCIAL restringido (o sin ningún permiso del módulo) no se entrega su configuración interna
  if not (public.user_has_perm(me.id, 'com.request') or public.user_has_perm(me.id, 'com.approve') or public.user_has_perm(me.id, 'com.track')
          or public.user_has_perm(me.id, 'com.sources.upload') or public._com_admin()) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return jsonb_build_object('settings', (select to_jsonb(s) - 'updated_by' from public.com_settings s where id = 'DEFAULT'),
    'my_assignment', (select to_jsonb(a) || jsonb_build_object('approver', public._com_label(r.approver_user_id)) from public.com_user_assignments a
       left join public.com_routing r on r.channel_key = case when a.channel = 'CARTERA' then 'CARTERA' else 'SUCURSAL:' || a.branch end where a.user_id = me.id),
    'is_admin', public._com_admin(), 'can_request', public.user_has_perm(me.id, 'com.request'), 'can_approve', public.user_has_perm(me.id, 'com.approve') or public._com_admin(),
    'can_track', public.user_has_perm(me.id, 'com.track') or public._com_admin(), 'can_upload', public.user_has_perm(me.id, 'com.sources.upload'),
    'routing', case when public._com_admin() then (select jsonb_agg(jsonb_build_object('channel_key', channel_key, 'approver_user_id', approver_user_id, 'approver', public._com_label(approver_user_id)) order by channel_key) from public.com_routing) end,
    'assignments', case when public._com_admin() then (select jsonb_agg(jsonb_build_object('user_id', p.id, 'name', p.full_name, 'channel', a.channel, 'branch', a.branch, 'cartera_label', a.cartera_label) order by p.full_name)
       from public.profiles p left join public.com_user_assignments a on a.user_id = p.id where p.role = 'COMERCIAL') end);
end; $$;

do $$ declare f text; begin
  foreach f in array array['com_my_alarms_page(integer)', 'com_alarm_history_page(date,date,jsonb,integer)', 'com_alarm_push_status()', 'com_my_push_devices()', 'com_set_kpi_mode(text)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon'; execute 'grant execute on function public.' || f || ' to authenticated'; end loop;
end $$;
COMMIT;
