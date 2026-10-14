-- RC4.1.1 · hardening de EXECUTE en funciones públicas
--
-- PostgreSQL concede EXECUTE sobre funciones nuevas a PUBLIC por defecto.
-- En una app autenticada esto puede hacer que el rol anon herede ejecución
-- aunque no exista un GRANT explícito a anon.
--
-- Esta migración:
--   1) captura qué funciones son ejecutables hoy por authenticated;
--   2) elimina EXECUTE heredado por PUBLIC y cualquier grant directo a anon;
--   3) restaura explícitamente authenticated sólo donde ya tenía acceso;
--   4) mantiene service_role;
--   5) evita que futuras funciones creadas por el owner vuelvan a recibir
--      EXECUTE para PUBLIC por defecto.
--
-- Es forward-only, idempotente respecto del objetivo de permisos y no toca
-- datos de negocio.

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT p.oid,
           p.oid::regprocedure AS signature,
           has_function_privilege('authenticated', p.oid, 'EXECUTE') AS auth_had_execute
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC', r.signature);
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM anon', r.signature);

    IF r.auth_had_execute THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', r.signature);
    ELSE
      EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM authenticated', r.signature);
    END IF;

    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', r.signature);
  END LOOP;
END
$$;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;