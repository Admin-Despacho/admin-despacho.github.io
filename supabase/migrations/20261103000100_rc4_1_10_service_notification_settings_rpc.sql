create or replace function public.set_notification_settings(p jsonb)
returns public.notification_settings
language plpgsql
security definer
set search_path to 'public'
as $function$
declare s public.notification_settings;
begin
  if not public.auth_has_perm('settings.manage') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  update public.notification_settings set
    on_the_way_enabled = coalesce((p->>'on_the_way_enabled')::boolean, on_the_way_enabled),
    delivered_enabled = coalesce((p->>'delivered_enabled')::boolean, delivered_enabled),
    sheet_email_enabled = coalesce((p->>'sheet_email_enabled')::boolean, sheet_email_enabled),
    sheet_email_time = coalesce(p->>'sheet_email_time', sheet_email_time),
    sheet_email_recipients = case when p ? 'sheet_email_recipients' then coalesce((select array_agg(lower(trim(x))) from jsonb_array_elements_text(p->'sheet_email_recipients') x where trim(x) <> ''), '{}'::text[]) else sheet_email_recipients end,
    provider = coalesce(p->>'provider', provider), max_retries = coalesce((p->>'max_retries')::int, max_retries),
    service_email_enabled = coalesce((p->>'service_email_enabled')::boolean, service_email_enabled),
    service_warning_km = coalesce((p->>'service_warning_km')::int, service_warning_km),
    service_repeat_km = coalesce((p->>'service_repeat_km')::int, service_repeat_km),
    service_email_recipients = case when p ? 'service_email_recipients' then coalesce((select array_agg(lower(trim(x))) from jsonb_array_elements_text(p->'service_email_recipients') x where trim(x) <> ''), '{}'::text[]) else service_email_recipients end,
    service_copy_admin = coalesce((p->>'service_copy_admin')::boolean, service_copy_admin),
    service_copy_driver = coalesce((p->>'service_copy_driver')::boolean, service_copy_driver)
  where id = 'DEFAULT' returning * into s;
  if s.service_warning_km < 0 or s.service_repeat_km < 1 then raise exception 'INVALID_SERVICE_ALERT_SETTINGS'; end if;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'NOTIFICATION_SETTINGS_CHANGED', 'settings', 'DEFAULT', to_jsonb(s));
  return s;
end;
$function$;
