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
