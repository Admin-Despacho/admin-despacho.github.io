-- Solo PostgreSQL temporal de pruebas. Del esquema QA/base_setup.sql.
CREATE OR REPLACE FUNCTION public.finalize_route(p_route uuid, p_km_end numeric DEFAULT NULL::numeric)
 RETURNS routes
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS E'\r\ndeclare r public.routes; pend int; summ jsonb; mods int; sup uuid; v public.vehicles;\r\nbegin\r\n  r := public._my_route(p_route);\r\n  if r.operational_status = ''COMPLETADA'' then return r; end if;\r\n  if r.operational_status <> ''EN_CURSO'' then raise exception ''BAD_STATE'' using errcode = ''23514''; end if;\r\n  select count(*) filter (where outcome = ''PENDIENTE'') into pend from public.route_stops where route_id = p_route;\r\n  if pend > 0 then raise exception ''PENDING_STOPS: faltan % entregas por resolver'', pend using errcode = ''23514''; end if;\r\n  if r.vehicle_id is not null then\r\n    select * into v from public.vehicles where id = r.vehicle_id for update;\r\n    if p_km_end is null then raise exception ''KM_REQUIRED: cargá el kilometraje final'' using errcode = ''23514''; end if;\r\n    if p_km_end < v.current_km then raise exception ''KM_LOWER: el kilometraje no puede bajar (último %)'', v.current_km using errcode = ''23514''; end if;\r\n    update public.vehicles set current_km = p_km_end where id = v.id;\r\n  end if;\r\n  select jsonb_object_agg(outcome, n) into summ from (select outcome, count(*) n from public.route_stops where route_id = p_route group by outcome) x;\r\n  select count(*) into mods from public.route_change_events where route_id = p_route and event_type in (''INTERNAL_STOP_ADDED'',''INTERNAL_STOP_REORDERED'');\r\n  update public.routes set operational_status = ''COMPLETADA'', status = ''COMPLETADA'', completed_at = now(), completed_by = auth.uid(), final_summary = summ, km_end = p_km_end,\r\n         approval_status = case when mods > 0 then ''PENDIENTE'' else ''NO_REQUERIDA'' end where id = p_route returning * into r;\r\n  if mods > 0 then\r\n    select coalesce(p.supervisor_user_id, s.supervisor_user_id) into sup from public.profiles p, public.internal_route_notification_settings s where p.id = r.responsable_id and s.id = ''DEFAULT'';\r\n    if sup is not null and not public.user_has_perm(sup, ''can_approve_internal_route_changes'') then sup := null; end if;\r\n    insert into public.route_approval_requests(route_id, route_version, requested_by, supervisor_user_id, supervisor_missing, modification_count)\r\n    values (p_route, r.version, auth.uid(), sup, sup is null, mods) on conflict (route_id, route_version) do nothing;\r\n    insert into public.notifications(user_id, route_id, route_version, type, title, body)\r\n    select u, p_route, r.version, case when sup is null then ''INTERNAL_ROUTE_NO_SUPERVISOR'' else ''INTERNAL_ROUTE_APPROVAL_REQUEST'' end,\r\n           ''HOJA '' || r.number || '' PENDIENTE DE APROBACIÓN'', mods || '' cambio(s) del chofer'' || case when sup is null then '' · sin superior configurado'' else '''' end\r\n    from (select sup u where sup is not null union select id from public.profiles where sup is null and role = ''ADMIN'' and status = ''ACTIVO'') x on conflict do nothing;\r\n    perform public.queue_route_emails(p_route, r.version, ''INTERNAL_ROUTE_APPROVAL_REQUEST'');\r\n  end if;\r\n  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), ''ROUTE_FINALIZED'', ''route'', p_route::text, summ || jsonb_build_object(''modifications'', mods, ''km_end'', p_km_end));\r\n  return r;\r\nend; '
;
;
CREATE OR REPLACE FUNCTION public.review_route_approval(p_request uuid, p_decision text, p_note text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare q public.route_approval_requests; r public.routes; drv_email text;
begin
  if not public.auth_has_perm('can_approve_internal_route_changes') then raise exception 'FORBIDDEN: falta permiso can_approve_internal_route_changes' using errcode = '42501'; end if;
  select * into q from public.route_approval_requests where id = p_request for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  if q.status <> 'PENDING' then raise exception 'NOT_PENDING: la solicitud ya fue resuelta' using errcode = '23514'; end if;
  if q.supervisor_user_id is not null and q.supervisor_user_id <> auth.uid() and not public.auth_has_perm('users.manage') then
    raise exception 'FORBIDDEN: la revisa el superior asignado o Administración' using errcode = '42501';
  end if;
  if p_decision not in ('APPROVED','OBSERVED') then raise exception 'BAD_DECISION' using errcode = '22023'; end if;
  if p_decision = 'OBSERVED' and coalesce(trim(p_note), '') = '' then raise exception 'NOTE_REQUIRED: para solicitar aclaración hay que indicar el motivo' using errcode = '23514'; end if;
  update public.route_approval_requests set status = p_decision, reviewed_by = auth.uid(), reviewed_at = now(), review_note = p_note, updated_at = now() where id = p_request;
  update public.routes set approval_status = case p_decision when 'APPROVED' then 'APROBADA' else 'OBSERVADA' end where id = q.route_id returning * into r;
  insert into public.audit_log(actor_id, action, target_type, target_id, before, after)
  values (auth.uid(), case p_decision when 'APPROVED' then 'INTERNAL_ROUTE_APPROVED' else 'INTERNAL_ROUTE_OBSERVED' end, 'route', q.route_id::text,
          jsonb_build_object('status', q.status), jsonb_build_object('status', p_decision, 'note', p_note));
  if p_decision = 'OBSERVED' then
    insert into public.notifications(user_id, route_id, route_version, type, title, body)
    values (r.responsable_id, r.id, q.route_version, 'INTERNAL_ROUTE_OBSERVED', 'ACLARACIÓN SOLICITADA · HOJA ' || r.number, p_note) on conflict do nothing;
    select email into drv_email from public.profiles where id = r.responsable_id;
    perform public.queue_route_emails(r.id, q.route_version, 'INTERNAL_ROUTE_OBSERVED', drv_email);
  end if;
end; $function$
;
;
CREATE OR REPLACE FUNCTION public.trg_notify_driver_approved()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if new.status = 'APPROVED' and old.status = 'PENDING' then
    insert into public.notifications(user_id, route_id, route_version, type, title, body)
    select r.responsable_id, r.id, new.route_version, 'INTERNAL_ROUTE_APPROVED', 'HOJA APROBADA · ' || r.number, 'Tu hoja fue aprobada.' from public.routes r where r.id = new.route_id on conflict do nothing;
  end if;
  return new;
end; $function$
;
;
