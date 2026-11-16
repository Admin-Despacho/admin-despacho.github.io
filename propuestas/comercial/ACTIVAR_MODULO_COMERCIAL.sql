-- =====================================================================================================================
-- ACTIVACIÓN · MÓDULO AUTORIZACIONES COMERCIALES + ALARMA · NO APLICAR sin autorización. Después de INSTALAR, CONFIGURAR y programar las tareas.
-- Exige: estado INSTALADO_CERRADO (N-V5-05: una instalación REVERTIDA nunca se reactiva) y TODOS los controles de _com_install_ready():
-- KPI deshabilitado, destinatarios válidos y las dos tareas automáticas programadas (N-V5-01). Si falta algo, se detiene SIN cambios.
-- =====================================================================================================================
BEGIN;
SET LOCAL lock_timeout = '5s';
DO $chk$ DECLARE st text; rd jsonb; BEGIN
  IF to_regclass('public.com_install_state') IS NULL THEN RAISE EXCEPTION 'NADA_QUE_ACTIVAR: no hay una instalación del módulo con estado. No se modificó nada.'; END IF;
  SELECT status INTO st FROM public.com_install_state WHERE id = 'DEFAULT';
  IF st IS DISTINCT FROM 'INSTALADO_CERRADO' THEN RAISE EXCEPTION 'ESTADO_INVALIDO: la instalación está % (solo se activa una instalación CERRADA pendiente). No se modificó nada.', coalesce(st, 'SIN ESTADO'); END IF;
  IF to_regclass('public.com_install_grants') IS NULL OR NOT EXISTS (SELECT 1 FROM public.com_install_grants) THEN RAISE EXCEPTION 'LISTA_DE_PERMISOS_AUSENTE. No se modificó nada.'; END IF;
  rd := public._com_install_ready();
  IF NOT (rd->>'listo')::boolean THEN
    RAISE EXCEPTION 'NO_LISTO: faltan controles: %. No se modificó nada.', (SELECT string_agg(e->>'control', ', ') FROM jsonb_array_elements(rd->'controles') e WHERE NOT (e->>'ok')::boolean); END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND (left(p.proname, 4) = 'com_' OR left(p.proname, 5) = '_com_')
             AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
             AND NOT EXISTS (SELECT 1 FROM pg_policies pl WHERE pl.schemaname = 'storage' AND (coalesce(pl.qual, '') ~ ('[[:<:]]' || p.proname || '[(]') OR coalesce(pl.with_check, '') ~ ('[[:<:]]' || p.proname || '[(]')))) THEN
    RAISE EXCEPTION 'EL_MODULO_NO_ESTA_CERRADO: hay funciones ya ejecutables. Revisar antes de activar. No se modificó nada.'; END IF;
END $chk$;
DO $grant$ DECLARE g record; BEGIN
  FOR g IN SELECT fn, grantee FROM public.com_install_grants LOOP EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO %I', g.fn, g.grantee); END LOOP;
END $grant$;
INSERT INTO public.com_install_log(status, detail) VALUES ('ACTIVO', jsonb_build_object('paso', 'ACTIVAR', 'permisos_otorgados', (SELECT jsonb_agg(fn::text ORDER BY fn::text) FROM public.com_install_grants WHERE grantee = 'authenticated')));
UPDATE public.com_install_state SET status = 'ACTIVO', updated_at = now() WHERE id = 'DEFAULT';
INSERT INTO public.audit_log(actor_id, action, target_type, target_id, after) VALUES (auth.uid(), 'COM_MODULE_ACTIVATED', 'module', 'COMERCIAL',
  jsonb_build_object('funciones_habilitadas', (SELECT count(*) FROM public.com_install_grants WHERE grantee = 'authenticated'), 'kpi_mode', 'DESHABILITADO'));
DROP TABLE public.com_install_grants;
COMMIT;
