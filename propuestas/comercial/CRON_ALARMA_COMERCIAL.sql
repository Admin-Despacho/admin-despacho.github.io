-- =====================================================================================================================
-- TAREAS PROGRAMADAS · ALARMA COMERCIAL (N-V5-01) · NO APLICAR sin autorización. Ver PLAN_PUBLICACION (orden y verificaciones previas).
-- Compatible con la autenticación VIGENTE: push-notifications mantiene verify_jwt = true (gateway) y el handler valida además x-cron-secret.
--  1) ESCALAMIENTO: tarea SOLO SQL (com_alarm_escalate_due cada minuto). No pasa por el gateway ni depende de navegadores abiertos.
--  2) ENVÍO PUSH: net.http_post con DOS credenciales leídas de VAULT en cada ejecución:
--       · Authorization: Bearer <okd_push_gateway_jwt>  → la exige el GATEWAY (verify_jwt = true). Debe ser un JWT del proyecto con role
--         service_role (p. ej. la clave service_role JWT del proyecto). Si el proyecto tiene las claves JWT anteriores DESHABILITADAS, esta vía
--         NO sirve y se requiere otra aprobada y ENSAYADA en Supabase aislado (pendiente: NOT RUN).
--       · x-cron-secret: <okd_push_cron_secret> → la exige el HANDLER (auth.ts; igual al secreto CRON_SECRET de la Edge Function).
-- Requisitos (los carga el Administrador en el panel de Supabase, NUNCA en el repositorio): Vault con okd_project_url, okd_push_cron_secret y
-- okd_push_gateway_jwt; extensiones pg_cron y pg_net; módulo INSTALADO (ACTIVAR exige ambas tareas programadas).
-- =====================================================================================================================
DO $pre$ DECLARE j text; parts text[]; p jsonb; BEGIN
  IF to_regprocedure('cron.schedule(text,text,text)') IS NULL THEN RAISE EXCEPTION 'FALTA pg_cron. No se programó nada.'; END IF;
  IF to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') IS NULL THEN RAISE EXCEPTION 'FALTA pg_net. No se programó nada.'; END IF;
  IF to_regclass('vault.decrypted_secrets') IS NULL THEN RAISE EXCEPTION 'FALTA Vault. No se programó nada.'; END IF;
  IF (SELECT count(*) FROM vault.decrypted_secrets WHERE name IN ('okd_project_url', 'okd_push_cron_secret', 'okd_push_gateway_jwt') AND coalesce(decrypted_secret, '') <> '') < 3 THEN
    RAISE EXCEPTION 'FALTAN los secretos okd_project_url / okd_push_cron_secret / okd_push_gateway_jwt en Vault. No se programó nada.'; END IF;
  IF to_regprocedure('public.com_alarm_escalate_due()') IS NULL THEN RAISE EXCEPTION 'FALTA la migración 000400 (com_alarm_escalate_due). No se programó nada.'; END IF;
  -- la credencial del gateway debe ser un JWT de servicio VIGENTE (no se guarda ni se muestra: solo se verifican su forma, su role y su vencimiento)
  SELECT decrypted_secret INTO j FROM vault.decrypted_secrets WHERE name = 'okd_push_gateway_jwt';
  parts := string_to_array(j, '.');
  IF cardinality(parts) <> 3 THEN RAISE EXCEPTION 'CREDENCIAL_DE_GATEWAY_INVALIDA: okd_push_gateway_jwt no es un JWT. No se programó nada.'; END IF;
  BEGIN
    p := convert_from(decode(rpad(translate(parts[2], '-_', '+/'), ((length(parts[2]) + 3) / 4) * 4, '='), 'base64'), 'UTF8')::jsonb;
  EXCEPTION WHEN others THEN RAISE EXCEPTION 'CREDENCIAL_DE_GATEWAY_INVALIDA: no se pudo leer el contenido del JWT. No se programó nada.'; END;
  IF p->>'role' IS DISTINCT FROM 'service_role' THEN RAISE EXCEPTION 'CREDENCIAL_DE_GATEWAY_INVALIDA: el JWT debe tener role service_role. No se programó nada.'; END IF;
  IF p ? 'exp' AND (p->>'exp')::numeric <= extract(epoch from now()) + 30 * 86400 THEN
    RAISE EXCEPTION 'CREDENCIAL_DE_GATEWAY_POR_VENCER: el JWT vence en menos de 30 días (o ya venció). No se programó nada.'; END IF;
END $pre$;
-- idempotente: si ya existen, se reemplazan (no se duplican)
DO $re$ BEGIN
  PERFORM cron.unschedule(jobname) FROM cron.job WHERE jobname IN ('okd-com-alarma-escalamiento', 'okd-push-notificaciones');
END $re$;
-- 1) escalamiento a los 3 minutos (SQL: no pasa por el gateway)
SELECT cron.schedule('okd-com-alarma-escalamiento', '* * * * *', $job$ select public.com_alarm_escalate_due(); $job$);
-- 2) envío push cada minuto (prioriza alarmas: claim_com_alarm_push_jobs y después claim_push_jobs, dentro del handler)
SELECT cron.schedule('okd-push-notificaciones', '* * * * *', $job$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'okd_project_url') || '/functions/v1/push-notifications',
    body := '{}'::jsonb, params := '{}'::jsonb,
    headers := jsonb_build_object('content-type', 'application/json',
      'authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'okd_push_gateway_jwt'),
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'okd_push_cron_secret')),
    timeout_milliseconds := 10000); $job$);
-- REVERSIÓN EXACTA (solo estas tareas; Comunicaciones no se toca): select cron.unschedule('okd-com-alarma-escalamiento'); select cron.unschedule('okd-push-notificaciones');
