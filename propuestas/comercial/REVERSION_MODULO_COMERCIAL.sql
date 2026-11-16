-- =====================================================================================================================
-- REVERSIÓN · MÓDULO AUTORIZACIONES COMERCIALES + ALARMA (000100 a 001100) · NO APLICAR sin autorización. Probada en la base local (QA/extra_reversion.sql).
-- PARTE 1 · REVERSIÓN FUNCIONAL (la que corresponde ante un problema): el módulo queda INERTE y se restauran EXACTAMENTE los objetos previos que
--   el módulo había modificado (restricción de módulos de profiles, module_permissions, queue_notification_push). Los DATOS y el HISTORIAL de
--   autorizaciones y alarmas se CONSERVAN (son auditoría). Antes: quitar las tareas programadas (ver CRON_ALARMA_COMERCIAL.sql) y volver la
--   pantalla a 1925c44; Edge Functions: volver a desplegar la copia exacta guardada por tools/edge_drift_check.sh.
-- PARTE 2 · ELIMINACIÓN TOTAL (opcional): solo si NO hay ninguna solicitud ni alarma; si hay datos, se detiene sin tocar nada.
-- =====================================================================================================================
BEGIN;
SET LOCAL lock_timeout = '5s'; SET LOCAL statement_timeout = '120s';
DO $pre$ BEGIN
  IF to_regclass('public.com_requests') IS NULL THEN RAISE EXCEPTION 'NADA_QUE_REVERTIR: el módulo no está aplicado. No se modificó nada.'; END IF;
  IF EXISTS (SELECT 1 FROM public.profiles WHERE 'COMERCIAL' = ANY(disabled_modules)) THEN
    RAISE EXCEPTION 'USUARIOS_CON_COMERCIAL_RESTRINGIDO: quitá la restricción COMERCIAL de esos usuarios antes de revertir (la restricción restaurada la rechazaría). No se modificó nada.'; END IF;
END $pre$;
-- 0) N-V5-05: la reversión ANULA cualquier activación pendiente (los permisos guardados se archivan en el historial y la tabla desaparece)
DO $st$ DECLARE pend jsonb; BEGIN
  IF to_regclass('public.com_install_grants') IS NOT NULL THEN   -- consulta dinámica: la tabla puede no existir
    EXECUTE $q$SELECT coalesce(jsonb_agg(fn::text ORDER BY fn::text), '[]'::jsonb) FROM public.com_install_grants WHERE grantee = 'authenticated'$q$ INTO pend; END IF;
  IF to_regclass('public.com_install_state') IS NOT NULL THEN
    INSERT INTO public.com_install_log(status, detail) VALUES ('REVERTIDO', jsonb_build_object('paso', 'REVERTIR',
      'estado_anterior', (SELECT status FROM public.com_install_state WHERE id = 'DEFAULT'), 'permisos_pendientes_anulados', pend));
    INSERT INTO public.com_install_state(id, status) VALUES ('DEFAULT', 'REVERTIDO') ON CONFLICT (id) DO UPDATE SET status = 'REVERTIDO', updated_at = now();
  END IF;
  IF to_regclass('public.com_install_grants') IS NOT NULL THEN EXECUTE 'DROP TABLE public.com_install_grants'; END IF;
END $st$;
-- 1.a) módulo INERTE: ninguna función comercial queda ejecutable por usuarios
DO $rev$ DECLARE f regprocedure; BEGIN
  FOR f IN SELECT p.oid::regprocedure FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND (left(p.proname, 4) = 'com_' OR left(p.proname, 5) = '_com_') LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f); END LOOP;
END $rev$;
DO $pol$ BEGIN IF to_regclass('storage.objects') IS NOT NULL THEN
  EXECUTE 'DROP POLICY IF EXISTS com_sources_select ON storage.objects'; EXECUTE 'DROP POLICY IF EXISTS com_sources_insert ON storage.objects'; END IF; END $pol$;
-- 1.b) restricción de módulos: la VIGENTE sin COMERCIAL (no escrita a mano)
DO $mod$ DECLARE def text; mods text[]; BEGIN
  SELECT pg_get_constraintdef(oid) INTO def FROM pg_constraint WHERE conname = 'profiles_disabled_modules_valid' AND conrelid = 'public.profiles'::regclass;
  SELECT array_agg(DISTINCT m ORDER BY m) INTO mods FROM (
    SELECT (regexp_matches(def, '''([A-Z_]+)''', 'g'))[1] m WHERE def !~ '''\{'
    UNION SELECT btrim(x) FROM unnest(string_to_array((regexp_match(def, '''\{([^}]*)\}'''))[1], ',')) x WHERE def ~ '''\{') y
  WHERE m <> 'COMERCIAL';
  -- freno: NUNCA una restricción vacía o nula (una restricción NULL se considera cumplida y quedaría DESACTIVADA)
  IF mods IS NULL OR cardinality(mods) < 3 THEN RAISE EXCEPTION 'NO_SE_PUDO_LEER_LA_RESTRICCION: %', def; END IF;
  ALTER TABLE public.profiles DROP CONSTRAINT profiles_disabled_modules_valid;
  EXECUTE format('ALTER TABLE public.profiles ADD CONSTRAINT profiles_disabled_modules_valid CHECK (disabled_modules <@ %L::text[])', mods);
END $mod$;
DELETE FROM public.module_permissions WHERE module = 'COMERCIAL' AND permission_code IN ('com.request', 'com.approve', 'com.track', 'com.sources.upload');
-- 1.c) push: los 6 tipos ORIGINALES (texto exacto de 20261014202300_web_push_notifications.sql)
create or replace function public.queue_notification_push()
returns trigger language plpgsql security definer set search_path='public' as $$
begin
  if new.type in ('NUEVA_HOJA_PUBLICADA','HOJA_CORREGIDA','REQUEST_CREATED','REQUEST_APPROVED','REQUEST_REJECTED','REQUEST_OBSERVED') then
    insert into public.push_jobs(notification_id,user_id)
    values(new.id,new.user_id)
    on conflict(notification_id) do nothing;
  end if;
  return new;
end; $$;
INSERT INTO public.audit_log(actor_id, action, target_type, target_id, after) VALUES (auth.uid(), 'COM_MODULE_REVERTED', 'module', 'COMERCIAL',
  jsonb_build_object('solicitudes_conservadas', (SELECT count(*) FROM public.com_requests), 'alarmas_conservadas', (SELECT count(*) FROM public.com_alarms)));
COMMIT;
-- ======================= PARTE 2 (OPCIONAL) · eliminación total, SOLO sin datos =======================
-- BEGIN;
-- DO $x$ BEGIN IF EXISTS (SELECT 1 FROM public.com_requests) OR EXISTS (SELECT 1 FROM public.com_alarms) THEN
--   RAISE EXCEPTION 'HAY_DATOS: no se elimina el historial de autorizaciones ni de alarmas. No se modificó nada.'; END IF; END $x$;
-- (DROP de funciones com_* / _com_*, tablas com_* y secuencias com_*_seq en orden inverso de dependencia; columnas agregadas a com_settings
--  desaparecen con la tabla.) COMMIT;
