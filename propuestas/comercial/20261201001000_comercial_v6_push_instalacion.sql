-- =====================================================================================================================
-- PROPUESTA · AUTORIZACIONES COMERCIALES · V6 (auditoría Work V5, 15/11) · NO APLICADA. Después de 000100 a 000900.
--  · N-V5-02 · push_session_valid EXIGE la identidad de sesión (session_id): ausente → SESION_NO_IDENTIFICADA (nunca se omite la comprobación).
--  · N-V5-03 · push_recipient_allowed: antes de ENVIAR un trabajo COM_ALARMA se verifica el acceso ACTUAL del destinatario; si ya no lo tiene,
--    el trabajo se omite y queda AUDITADO. Los demás tipos de aviso no cambian.
--  · Prioridad de alarmas en la cola compartida: claim_com_alarm_push_jobs (misma semántica que claim_push_jobs, SOLO trabajos COM_ALARMA).
--    claim_push_jobs de producción NO se modifica.
--  · N-V5-05 · estado de instalación (INSTALADO_CERRADO / ACTIVO / REVERTIDO) con historial: una instalación revertida no se reactiva.
--  · N-V5-04 · las políticas de Storage del módulo exigen además _com_module_open(): con el módulo cerrado o revertido los originales comerciales
--    quedan cerrados SIN romper la evaluación de políticas de otros buckets (el instalador ya no retira la ejecución de sus funciones auxiliares).
--  · Configuración PRIVILEGIADA antes de abrir (_com_install_configure) y verificación de preparación (_com_install_ready) para ACTIVAR.
-- =====================================================================================================================
BEGIN;
SET LOCAL lock_timeout = '5s'; SET LOCAL statement_timeout = '60s';
DO $guard$ BEGIN
  IF to_regprocedure('public.push_session_valid(uuid,numeric,text)') IS NULL OR to_regprocedure('public._com_alarm_role(public.com_alarms,uuid)') IS NULL THEN
    RAISE EXCEPTION 'DEPENDENCIA_FALTANTE: aplicar antes 000100 a 000900. No se modificó nada.'; END IF;
  IF to_regclass('public.com_install_state') IS NOT NULL THEN RAISE EXCEPTION 'YA_APLICADA. No se modificó nada.'; END IF;
END $guard$;

-- ---------- N-V5-02 · la identidad de sesión es OBLIGATORIA ----------
create or replace function public.push_session_valid(p_user uuid, p_iat numeric, p_session text) returns jsonb language plpgsql stable security definer set search_path = public, auth as $$
declare p public.profiles;
begin
  if p_user is null or p_iat is null then return jsonb_build_object('ok', false, 'motivo', 'CLAIMS_INCOMPLETOS'); end if;
  if p_session is null or btrim(p_session) = '' then return jsonb_build_object('ok', false, 'motivo', 'SESION_NO_IDENTIFICADA'); end if;   -- N-V5-02
  select * into p from public.profiles where id = p_user;
  if not found or p.status <> 'ACTIVO' then return jsonb_build_object('ok', false, 'motivo', 'PERFIL_NO_ACTIVO'); end if;
  if p.sessions_revoked_at is not null and p_iat <= extract(epoch from p.sessions_revoked_at) then return jsonb_build_object('ok', false, 'motivo', 'SESION_REVOCADA'); end if;
  if to_regclass('auth.sessions') is null then return jsonb_build_object('ok', false, 'motivo', 'SESIONES_NO_VERIFICABLES'); end if;   -- sin tabla de sesiones: nunca se aprueba a ciegas
  if not exists (select 1 from auth.sessions s where s.id::text = p_session and s.user_id = p_user) then return jsonb_build_object('ok', false, 'motivo', 'SESION_INEXISTENTE'); end if;
  return jsonb_build_object('ok', true);
end; $$;

-- ---------- N-V5-03 · acceso ACTUAL del destinatario de un aviso COM_ALARMA, antes de ENVIARLO ----------
create or replace function public.push_recipient_allowed(p_notification uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare n record; a public.com_alarms; r public.profiles; ok boolean;
begin
  select id, user_id, type into n from public.notifications where id = p_notification;
  if not found then return jsonb_build_object('ok', false, 'motivo', 'AVISO_INEXISTENTE'); end if;
  if n.type is distinct from 'COM_ALARMA' then return jsonb_build_object('ok', true, 'motivo', 'TIPO_SIN_RESTRICCION'); end if;   -- los demás avisos: sin cambios
  select al.* into a from public.com_alarm_events e join public.com_alarms al on al.id = e.alarm_id where e.notification_id = p_notification limit 1;
  select * into r from public.profiles where id = n.user_id;
  ok := a.id is not null and r.id is not null and r.status = 'ACTIVO' and (
        ((r.id = a.initial_user or r.id = any(a.escalated_to)) and public.user_has_perm(r.id, 'com.approve'))
     or (r.id = a.raised_by and public.user_has_perm(r.id, 'com.track'))
     or (r.role = 'ADMIN' and not ('COMERCIAL' = any(r.disabled_modules))));
  if not ok then
    insert into public.audit_log(actor_id, action, target_type, target_id, after) values (null, 'COM_ALARM_PUSH_OMITIDO', 'notifications', p_notification::text,
      jsonb_build_object('destinatario', n.user_id, 'alarma', a.id, 'motivo', case when a.id is null then 'ALARMA_INEXISTENTE' when r.id is null or r.status <> 'ACTIVO' then 'DESTINATARIO_NO_ACTIVO' else 'DESTINATARIO_SIN_ACCESO_ACTUAL' end));
    return jsonb_build_object('ok', false, 'motivo', 'DESTINATARIO_SIN_ACCESO_ACTUAL');
  end if;
  return jsonb_build_object('ok', true);
end; $$;

-- ---------- prioridad de alarmas en la cola compartida (misma semántica que claim_push_jobs; SOLO COM_ALARMA) ----------
create or replace function public.claim_com_alarm_push_jobs(p_limit int default 50) returns setof public.push_jobs language plpgsql security definer set search_path = public as $$
begin
  return query update public.push_jobs j set status = 'SENDING', locked_at = now(), attempt_count = j.attempt_count + 1
   where j.id in (select pj.id from public.push_jobs pj join public.notifications nt on nt.id = pj.notification_id
                   where nt.type = 'COM_ALARMA' and (pj.status = 'QUEUED' or (pj.status = 'ERROR' and pj.attempt_count < 5 and coalesce(pj.next_attempt_at, now()) <= now())
                         or (pj.status = 'SENDING' and pj.locked_at < now() - interval '10 minutes'))
                   order by pj.created_at for update of pj skip locked limit greatest(1, least(coalesce(p_limit, 50), 200)))
  returning j.*;
end; $$;

-- ---------- N-V5-05 · estado de instalación con historial ----------
create table public.com_install_state (id text primary key default 'DEFAULT' check (id = 'DEFAULT'), status text not null check (status in ('INSTALADO_CERRADO', 'ACTIVO', 'REVERTIDO')), updated_at timestamptz not null default now());
create table public.com_install_log (id bigserial primary key, at timestamptz not null default now(), status text not null, detail jsonb not null default '{}'::jsonb);
alter table public.com_install_state enable row level security; alter table public.com_install_log enable row level security;
revoke all on public.com_install_state, public.com_install_log from public, anon, authenticated;
create or replace function public._com_install_log_inmutable() returns trigger language plpgsql as $$ begin raise exception 'INMUTABLE: el historial de instalación no se modifica ni se borra'; end; $$;
create trigger com_install_log_inmutable before update or delete on public.com_install_log for each row execute function public._com_install_log_inmutable();
-- sin fila = migraciones aplicadas una por una (entorno de prueba): se considera ABIERTO; el instalador siempre crea la fila
create or replace function public._com_module_open() returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select status = 'ACTIVO' from public.com_install_state where id = 'DEFAULT'), true);
$$;

-- ---------- N-V5-04 · políticas de Storage del módulo: además, módulo ABIERTO ----------
DO $pol$ BEGIN
  IF to_regclass('storage.objects') IS NOT NULL THEN
    EXECUTE 'DROP POLICY IF EXISTS com_sources_select ON storage.objects';
    EXECUTE 'DROP POLICY IF EXISTS com_sources_insert ON storage.objects';
    EXECUTE $p$create policy com_sources_select on storage.objects for select to authenticated using (bucket_id = 'com-sources' and public._com_module_open() and public._com_admin())$p$;
    EXECUTE $p$create policy com_sources_insert on storage.objects for insert to authenticated with check (bucket_id = 'com-sources' and public._com_module_open()
      and public._com_can_upload_source() and name ~ '^(SC|CC)/[0-9a-f]{64}\.(xlsx|xls|csv)$')$p$;
  END IF;
END $pol$;

-- ---------- configuración PRIVILEGIADA antes de abrir (autoridad de instalación; sin sesión de usuario; mismas reglas que el Panel) ----------
create or replace function public._com_install_configure(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare ini uuid := nullif(p->'alarm'->>'initial_user', '')::uuid;
        esc uuid[] := (select coalesce(array_agg(distinct x::uuid), '{}') from jsonb_array_elements_text(coalesce(p->'alarm'->'escalation_users', '[]')) x);
        x jsonb;
begin
  if coalesce((select status from public.com_install_state where id = 'DEFAULT'), '') <> 'INSTALADO_CERRADO' then
    raise exception 'ESTADO_INVALIDO: la configuración privilegiada solo corre con una instalación CERRADA pendiente de activar'; end if;
  if ini is null or cardinality(esc) = 0 then raise exception 'INCOMPLETE: destinatario inicial y al menos un destinatario de escalamiento' using errcode = '23514'; end if;
  if not exists (select 1 from public.profiles where id = ini and status = 'ACTIVO' and public.user_has_perm(id, 'com.approve')) then
    raise exception 'BAD_RECIPIENT: el destinatario inicial debe estar ACTIVO y tener permiso de aprobación' using errcode = '23514'; end if;
  if exists (select 1 from unnest(esc) u where not exists (select 1 from public.profiles where id = u and status = 'ACTIVO' and role = 'ADMIN' and not ('COMERCIAL' = any(disabled_modules)))) then
    raise exception 'BAD_RECIPIENT: el escalamiento solo puede dirigirse a Administradores Generales ACTIVOS sin COMERCIAL restringido' using errcode = '23514'; end if;
  update public.com_settings set alarm_initial_user = ini, alarm_escalation_users = esc where id = 'DEFAULT';
  for x in select * from jsonb_array_elements(coalesce(p->'assignments', '[]')) loop
    if not exists (select 1 from public.profiles where id = (x->>'user_id')::uuid and role = 'COMERCIAL') then raise exception 'NOT_COMERCIAL: %', x->>'user_id' using errcode = '23514'; end if;
    insert into public.com_user_assignments(user_id, channel, branch, cartera_label, updated_by)
      values ((x->>'user_id')::uuid, x->>'channel', case when x->>'channel' = 'SUCURSAL' then x->>'branch' end, case when x->>'channel' = 'CARTERA' then nullif(btrim(x->>'cartera'), '') end, null)
      on conflict (user_id) do update set channel = excluded.channel, branch = excluded.branch, cartera_label = excluded.cartera_label, updated_by = null, updated_at = now();
  end loop;
  for x in select * from jsonb_array_elements(coalesce(p->'routing', '[]')) loop
    if (x->>'approver') is not null and (public._com_active((x->>'approver')::uuid) is null or not public.user_has_perm((x->>'approver')::uuid, 'com.approve')) then
      raise exception 'BAD_APPROVER: %', x->>'approver' using errcode = '23514'; end if;
    update public.com_routing set approver_user_id = (x->>'approver')::uuid, updated_by = null, updated_at = now() where channel_key = x->>'channel_key';
    if not found then raise exception 'BAD_CHANNEL: %', x->>'channel_key' using errcode = '23514'; end if;
  end loop;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (null, 'COM_CONFIGURACION_INSTALACION', 'com_settings', 'DEFAULT', p);
  insert into public.com_install_log(status, detail) values ('INSTALADO_CERRADO', jsonb_build_object('paso', 'CONFIGURACION', 'destinatario_inicial', ini, 'escalamiento', to_jsonb(esc)));
  return public._com_install_ready();
end; $$;

-- ---------- preparación para ACTIVAR (todas las condiciones, con su resultado) ----------
create or replace function public._com_install_ready() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare s public.com_settings; c jsonb := '[]'::jsonb; cron_ok boolean := to_regclass('cron.job') is not null; esc_job boolean := false; push_job boolean := false;
begin
  if cron_ok then   -- consulta DINÁMICA: sin pg_cron la tabla no existe y se informa «no programada» en vez de fallar
    execute $q$select exists (select 1 from cron.job where jobname = 'okd-com-alarma-escalamiento' and active)$q$ into esc_job;
    execute $q$select exists (select 1 from cron.job where jobname = 'okd-push-notificaciones' and active)$q$ into push_job;
  end if;
  select * into s from public.com_settings where id = 'DEFAULT';
  c := c || jsonb_build_object('control', 'ESTADO_INSTALADO_CERRADO', 'ok', coalesce((select status = 'INSTALADO_CERRADO' from public.com_install_state where id = 'DEFAULT'), false));
  c := c || jsonb_build_object('control', 'KPI_DESHABILITADO', 'ok', s.kpi_mode = 'DESHABILITADO');
  c := c || jsonb_build_object('control', 'DESTINATARIO_INICIAL_VALIDO', 'ok', exists (select 1 from public.profiles where id = s.alarm_initial_user and status = 'ACTIVO' and public.user_has_perm(id, 'com.approve')));
  c := c || jsonb_build_object('control', 'ESCALAMIENTO_VALIDO', 'ok', cardinality(coalesce(s.alarm_escalation_users, '{}')) > 0
        and not exists (select 1 from unnest(s.alarm_escalation_users) u where not exists (select 1 from public.profiles where id = u and status = 'ACTIVO' and role = 'ADMIN' and not ('COMERCIAL' = any(disabled_modules)))));
  -- N-V5-01: no se abre la alarma urgente sin su automatización PROGRAMADA (escalamiento SQL y envío push)
  c := c || jsonb_build_object('control', 'TAREA_ESCALAMIENTO_PROGRAMADA', 'ok', esc_job);
  c := c || jsonb_build_object('control', 'TAREA_PUSH_PROGRAMADA', 'ok', push_job);
  return jsonb_build_object('listo', not exists (select 1 from jsonb_array_elements(c) e where not (e->>'ok')::boolean), 'controles', c);
end; $$;

-- ---------- privilegios ----------
revoke all on function public.push_recipient_allowed(uuid) from public, anon, authenticated;
revoke all on function public.claim_com_alarm_push_jobs(int) from public, anon, authenticated;
revoke all on function public._com_install_configure(jsonb) from public, anon, authenticated;
revoke all on function public._com_install_ready() from public, anon, authenticated;
revoke all on function public._com_install_log_inmutable() from public, anon, authenticated;
revoke all on function public._com_module_open() from public, anon;   -- WORK-S06: nada comercial ejecutable por anon (las funciones nuevas nacen ejecutables por PUBLIC)
grant execute on function public._com_module_open() to authenticated;   -- solo devuelve verdadero/falso; lo evalúan las políticas de Storage
DO $$ BEGIN IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
  EXECUTE 'GRANT EXECUTE ON FUNCTION public.push_recipient_allowed(uuid) TO service_role';
  EXECUTE 'GRANT EXECUTE ON FUNCTION public.claim_com_alarm_push_jobs(int) TO service_role'; END IF; END $$;
COMMIT;
