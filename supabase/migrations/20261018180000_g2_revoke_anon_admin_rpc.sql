-- OK Despacho Online · G2 security hardening
-- Forward-only. No altera las migraciones históricas ni los datos.
-- La autorización funcional sigue validándose dentro de upsert_internal_location.
-- Evita que los roles públicos invoquen un RPC administrativo SECURITY DEFINER.
REVOKE EXECUTE ON FUNCTION public.upsert_internal_location(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.upsert_internal_location(jsonb) TO authenticated, service_role;
