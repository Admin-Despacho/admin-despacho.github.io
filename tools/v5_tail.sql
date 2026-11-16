-- ---------- privilegios ----------
revoke all on function public._com_alarm_role(public.com_alarms,uuid) from public, anon, authenticated;
revoke all on function public._com_ar_day(date) from public, anon, authenticated;
revoke all on function public.com_set_kpi_mode(text,text) from public, anon; grant execute on function public.com_set_kpi_mode(text,text) to authenticated;
revoke all on function public.push_session_valid(uuid,numeric,text) from public, anon, authenticated;
DO $$ BEGIN IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN EXECUTE 'GRANT EXECUTE ON FUNCTION public.push_session_valid(uuid,numeric,text) TO service_role'; END IF; END $$;
DO $post$ BEGIN IF (SELECT kpi_mode FROM public.com_settings WHERE id = 'DEFAULT') <> 'DESHABILITADO' THEN RAISE EXCEPTION 'EL_KPI_DEBE_QUEDAR_DESHABILITADO'; END IF; END $post$;
COMMIT;
