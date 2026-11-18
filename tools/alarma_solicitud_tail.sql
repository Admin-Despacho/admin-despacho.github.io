-- ---------- privilegios (las tres nuevas: solo usuarios autenticados; la verificación real está DENTRO de cada función) ----------
revoke all on function public.com_alarm_raise_request(uuid, text, text) from public, anon; grant execute on function public.com_alarm_raise_request(uuid, text, text) to authenticated;
revoke all on function public.com_request_alarm(uuid) from public, anon; grant execute on function public.com_request_alarm(uuid) to authenticated;
revoke all on function public.com_alarm_request_detail(uuid) from public, anon; grant execute on function public.com_alarm_request_detail(uuid) to authenticated;
comment on function public.com_alarm_raise_request(uuid, text, text) is 'OKD:ALARMA_SOLICITUD_V1';
COMMIT;
