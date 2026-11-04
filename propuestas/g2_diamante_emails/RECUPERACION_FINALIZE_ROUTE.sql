-- RECUPERACIÓN V4.23 · devuelve finalize_route a su versión EXACTA anterior (c5bc9e2f98853281bebfeb6151b7d119) y así deja de exigir LLEGUÉ A DIAMANTE.
-- No borra columnas, tablas ni datos (son inertes sin la pantalla nueva). Se detiene si finalize_route no es la V4.23 ni la anterior.
-- ORDEN: si la pantalla nueva ya está publicada, volver PRIMERO la pantalla a la versión anterior.
BEGIN;
DO $g$ BEGIN IF (SELECT md5(prosrc) FROM pg_proc WHERE proname = 'finalize_route' AND pronamespace = 'public'::regnamespace) NOT IN ('779f1959bf9f5084088fa3c817f3ab1c', 'c5bc9e2f98853281bebfeb6151b7d119') THEN RAISE EXCEPTION 'HUELLA_INESPERADA: no se modificó nada.'; END IF; END $g$;
create or replace function public.finalize_route(p_route uuid, p_km_end numeric default null) returns public.routes language plpgsql security definer set search_path = public as $$
declare r public.routes; pend int; summ jsonb; mods int; sup uuid; v public.vehicles;
begin
  r := public._my_route(p_route);
  if r.operational_status = 'COMPLETADA' then return r; end if;
  if r.operational_status <> 'EN_CURSO' then raise exception 'BAD_STATE' using errcode = '23514'; end if;
  select count(*) filter (where outcome = 'PENDIENTE') into pend from public.route_stops where route_id = p_route;
  if pend > 0 then raise exception 'PENDING_STOPS: faltan % entregas por resolver', pend using errcode = '23514'; end if;
  if r.vehicle_id is not null then
    select * into v from public.vehicles where id = r.vehicle_id for update;
    if p_km_end is null then raise exception 'KM_REQUIRED: cargá el kilometraje final' using errcode = '23514'; end if;
    if p_km_end < v.current_km then raise exception 'KM_LOWER: el kilometraje no puede bajar (último %)', v.current_km using errcode = '23514'; end if;
    update public.vehicles set current_km = p_km_end where id = v.id;
  end if;
  select jsonb_object_agg(outcome, n) into summ from (select outcome, count(*) n from public.route_stops where route_id = p_route group by outcome) x;
  select count(*) into mods from public.route_change_events where route_id = p_route and event_type in ('INTERNAL_STOP_ADDED','INTERNAL_STOP_REORDERED');
  update public.routes set operational_status = 'COMPLETADA', status = 'COMPLETADA', completed_at = now(), completed_by = auth.uid(), final_summary = summ, km_end = p_km_end,
         approval_status = case when mods > 0 then 'PENDIENTE' else 'NO_REQUERIDA' end where id = p_route returning * into r;
  if mods > 0 then
    select coalesce(p.supervisor_user_id, s.supervisor_user_id) into sup from public.profiles p, public.internal_route_notification_settings s where p.id = r.responsable_id and s.id = 'DEFAULT';
    if sup is not null and not public.user_has_perm(sup, 'can_approve_internal_route_changes') then sup := null; end if;
    insert into public.route_approval_requests(route_id, route_version, requested_by, supervisor_user_id, supervisor_missing, modification_count)
    values (p_route, r.version, auth.uid(), sup, sup is null, mods) on conflict (route_id, route_version) do nothing;
    insert into public.notifications(user_id, route_id, route_version, type, title, body)
    select u, p_route, r.version, case when sup is null then 'INTERNAL_ROUTE_NO_SUPERVISOR' else 'INTERNAL_ROUTE_APPROVAL_REQUEST' end,
           'HOJA ' || r.number || ' PENDIENTE DE APROBACIÓN', mods || ' cambio(s) del chofer' || case when sup is null then ' · sin superior configurado' else '' end
    from (select sup u where sup is not null union select id from public.profiles where sup is null and role = 'ADMIN' and status = 'ACTIVO') x on conflict do nothing;
    perform public.queue_route_emails(p_route, r.version, 'INTERNAL_ROUTE_APPROVAL_REQUEST');
  end if;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'ROUTE_FINALIZED', 'route', p_route::text, summ || jsonb_build_object('modifications', mods, 'km_end', p_km_end));
  return r;
end; $$;
DO $p$ BEGIN IF (SELECT md5(prosrc) FROM pg_proc WHERE proname = 'finalize_route' AND pronamespace = 'public'::regnamespace) <> 'c5bc9e2f98853281bebfeb6151b7d119' THEN RAISE EXCEPTION 'HUELLA_FINAL_INESPERADA'; END IF; END $p$;
COMMIT;
