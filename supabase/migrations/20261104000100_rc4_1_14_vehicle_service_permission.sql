create or replace function public.register_vehicle_service(p_vehicle uuid, p_km numeric, p_date date, p_note text default null)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if not (public.auth_has_perm('vehicles.service_manage') or public.auth_has_perm('vehicles.manage')) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_km is null or p_km <= 0 then raise exception 'BAD_KM' using errcode = '22023'; end if;
  insert into public.vehicle_services(vehicle_id, service_date, km, note, created_by) values (p_vehicle, coalesce(p_date, current_date), p_km, p_note, auth.uid());
  update public.vehicles set last_service_km = p_km, last_service_date = coalesce(p_date, current_date), current_km = greatest(current_km, p_km) where id = p_vehicle;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'VEHICLE_SERVICE_REGISTERED', 'vehicle', p_vehicle::text, jsonb_build_object('km', p_km, 'date', p_date, 'note', p_note));
  perform public._vehicle_service_check(p_vehicle);
end;
$function$;
