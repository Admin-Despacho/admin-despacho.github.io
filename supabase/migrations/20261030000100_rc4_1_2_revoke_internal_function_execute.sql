-- RC4.1.2: funciones internas/trigger no deben ser RPC públicas para usuarios autenticados.
REVOKE EXECUTE ON FUNCTION public._loc(jsonb, public.route_stops) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public._queue_on_the_way(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public._vehicle_service_check(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.rls_auto_enable() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trg_auth_users_sync() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trg_customer_email_settings() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trg_noc_on_draft_status() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trg_notify_driver_approved() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trg_on_the_way_after_change() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trg_profiles_purge_aux() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trg_route_financing_snapshot() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trg_route_km_after_finalize() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trg_route_start_needs_vehicle() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trg_route_vehicle_from_snapshot() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trg_routes_responsable_compatible() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trg_stop_from_snapshot() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trg_transportista_has_carrier() FROM authenticated;
