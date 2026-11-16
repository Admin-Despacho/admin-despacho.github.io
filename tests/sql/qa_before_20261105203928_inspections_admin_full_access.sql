-- Solo PostgreSQL temporal de pruebas. Del esquema QA/base_setup.sql.
CREATE OR REPLACE FUNCTION public._insp_me()
 RETURNS profiles
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me public.profiles;
begin
  select * into me from public.profiles where id = auth.uid() and status = 'ACTIVO';
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return me;
end; $function$
;
;
CREATE OR REPLACE FUNCTION public._insp_event(p_id uuid, p_action text, p_detail jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me public.profiles;
begin
  select * into me from public.profiles where id = auth.uid();
  insert into public.vehicle_inspection_events(inspection_id, action, actor, actor_name, detail) values (p_id, p_action, auth.uid(), me.full_name, p_detail);
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'INSPECTION_' || p_action, 'vehicle_inspection', p_id::text, p_detail);
end; $function$
;
;
CREATE OR REPLACE FUNCTION public.inspection_save_draft(p jsonb)
 RETURNS vehicle_inspections
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me public.profiles := public._insp_me(); i public.vehicle_inspections; v public.vehicles; it jsonb; n int;
begin
  if me.role not in ('OPERARIO_DEPOSITO','SUPERVISOR_DESPACHO') then raise exception 'FORBIDDEN: solo Operario Depósito o Superior Despacho realizan inspecciones' using errcode = '42501'; end if;
  if (p->>'client_id') is null then raise exception 'CLIENT_ID_REQUIRED' using errcode = '22023'; end if;
  select * into i from public.vehicle_inspections where client_id = (p->>'client_id')::uuid;
  if i.id is not null and i.created_by <> me.id then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if i.id is not null and i.status <> 'BORRADOR' then return i; end if;   -- ya enviada: un guardado tardío (sin conexión) NO la modifica
  select * into v from public.vehicles where id = (p->>'vehicle_id')::uuid;
  if v.id is null then raise exception 'VEHICLE_NOT_FOUND: elegí un vehículo' using errcode = '23514'; end if;
  if i.id is null then
    insert into public.vehicle_inspections(number, client_id, vehicle_id, vehicle_name, vehicle_type, brand, model, plate, km, created_by, created_by_name, team_supervisor_id, general_observation)
    values ('INS-' || lpad(nextval('public.vehicle_inspection_number_seq')::text, 6, '0'), (p->>'client_id')::uuid, v.id, v.name, v.type, v.brand, v.model, v.plate,
            nullif(p->>'km', '')::numeric, me.id, me.full_name, case when me.role = 'SUPERVISOR_DESPACHO' then me.id else me.supervisor_user_id end, p->>'general_observation')
    returning * into i;
    perform public._insp_event(i.id, 'CREADA', jsonb_build_object('number', i.number, 'plate', i.plate));
  else
    update public.vehicle_inspections set vehicle_id = v.id, vehicle_name = v.name, vehicle_type = v.type, brand = v.brand, model = v.model, plate = v.plate,
      km = nullif(p->>'km', '')::numeric, general_observation = p->>'general_observation', updated_at = now() where id = i.id returning * into i;
  end if;
  for it in select * from jsonb_array_elements(coalesce(p->'items', '[]'::jsonb)) loop
    n := (it->>'n')::int; if n is null or n < 1 or n > 30 then raise exception 'ITEM_INVALID' using errcode = '22023'; end if;
    insert into public.vehicle_inspection_items(inspection_id, item_no, result, defect, observation, extra_date, extra_km)
    values (i.id, n, nullif(it->>'result', ''), nullif(it->>'defect', ''), nullif(trim(coalesce(it->>'observation', '')), ''), nullif(it->>'extra_date', '')::date, nullif(it->>'extra_km', '')::numeric)
    on conflict (inspection_id, item_no) do update set result = excluded.result, defect = excluded.defect, observation = excluded.observation, extra_date = excluded.extra_date, extra_km = excluded.extra_km;
  end loop;
  return i;
end; $function$
;
;
CREATE OR REPLACE FUNCTION public.inspection_submit(p_id uuid)
 RETURNS vehicle_inspections
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me public.profiles := public._insp_me(); i public.vehicle_inspections; miss int; bad int; team uuid;
begin
  select * into i from public.vehicle_inspections where id = p_id for update;
  if i.id is null or i.created_by <> me.id then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if i.status = 'PENDIENTE' then return i; end if;   -- reintento (doble toque / cola sin conexión): no duplica
  if i.status <> 'BORRADOR' then raise exception 'BAD_STATE: la inspección ya fue revisada' using errcode = '23514'; end if;
  if i.km is null or i.km < 0 then raise exception 'KM_REQUIRED: cargá el kilometraje' using errcode = '23514'; end if;
  select count(*) into miss from public.vehicle_inspection_controls c left join public.vehicle_inspection_items x on x.inspection_id = i.id and x.item_no = c.item_no where x.result is null;
  if miss > 0 then raise exception 'INCOMPLETE: faltan % controles por responder', miss using errcode = '23514'; end if;
  select count(*) into bad from public.vehicle_inspection_items where inspection_id = i.id and result = 'MAL' and (defect is null or observation is null);
  if bad > 0 then raise exception 'ANOMALY_INCOMPLETE: cada control MAL necesita FALTANTE o MAL ESTADO y una observación (% sin completar)', bad using errcode = '23514'; end if;
  -- Superior responsable: el asignado AL ENVIAR (el propio, si quien envía es Superior). Sin Superior activo asignado → no se envía ni se expone.
  team := case when me.role = 'SUPERVISOR_DESPACHO' then me.id else me.supervisor_user_id end;
  if team is null or not exists (select 1 from public.profiles p where p.id = team and p.role = 'SUPERVISOR_DESPACHO' and p.status = 'ACTIVO') then
    raise exception 'SUPERVISOR_REQUIRED: tu usuario no tiene un Superior Despacho asignado. Pedí al Administrador General que te asigne uno; la inspección queda guardada como borrador' using errcode = '23514'; end if;
  update public.vehicle_inspections set status = 'PENDIENTE', submitted_at = now(), updated_at = now(), team_supervisor_id = team,
    anomalies = (select count(*) from public.vehicle_inspection_items where inspection_id = i.id and result = 'MAL') where id = i.id returning * into i;
  perform public._insp_event(i.id, 'ENVIADA', jsonb_build_object('anomalies', i.anomalies, 'supervisor', team));
  if me.role <> 'SUPERVISOR_DESPACHO' then   -- SOLO al Superior de ese equipo (el Superior que inspecciona no se notifica a sí mismo)
    insert into public.notifications(user_id, type, title, body, inspection_id)
    values (team, 'INSPECTION_PENDING', 'Inspección ' || i.number || ' pendiente de aprobación', i.plate || ' · ' || coalesce(i.vehicle_name, '') || ' · ' || i.created_by_name || ' · ' || i.anomalies || ' anomalía(s)', i.id);
  end if;
  return i;
end; $function$
;
;
CREATE OR REPLACE FUNCTION public.inspection_review(p_id uuid, p_decision text, p_reason text)
 RETURNS vehicle_inspections
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me public.profiles := public._insp_me(); i public.vehicle_inspections;
begin
  if me.role <> 'SUPERVISOR_DESPACHO' then raise exception 'FORBIDDEN: solo el Superior Despacho aprueba o rechaza inspecciones' using errcode = '42501'; end if;
  if p_decision not in ('APROBADA','RECHAZADA') then raise exception 'DECISION_INVALIDA' using errcode = '22023'; end if;
  select * into i from public.vehicle_inspections where id = p_id for update;
  if i.id is null or not coalesce(i.created_by = me.id or i.team_supervisor_id = me.id, false) then raise exception 'FORBIDDEN: la inspección es de otro equipo' using errcode = '42501'; end if;   -- sin equipo (NULL) = de otro equipo
  if i.status in ('APROBADA','RECHAZADA') then
    if i.status = p_decision then return i; end if;   -- reintento: misma decisión, no duplica
    raise exception 'ALREADY_REVIEWED: la inspección ya fue %', lower(i.status) using errcode = '23514'; end if;
  if i.status <> 'PENDIENTE' then raise exception 'BAD_STATE: la inspección no está pendiente' using errcode = '23514'; end if;
  if p_decision = 'RECHAZADA' and coalesce(trim(p_reason), '') = '' then raise exception 'REASON_REQUIRED: indicá el motivo del rechazo' using errcode = '23514'; end if;
  update public.vehicle_inspections set status = p_decision, reviewed_by = me.id, reviewed_by_name = me.full_name, reviewed_at = now(),
    reject_reason = case when p_decision = 'RECHAZADA' then trim(p_reason) end, updated_at = now() where id = i.id returning * into i;
  perform public._insp_event(i.id, p_decision, jsonb_build_object('reason', i.reject_reason, 'self', i.created_by = me.id));
  if i.created_by <> me.id then
    insert into public.notifications(user_id, type, title, body, inspection_id)
    values (i.created_by, 'INSPECTION_' || p_decision, 'Inspección ' || i.number || ' ' || lower(p_decision), i.plate || coalesce(' · Motivo: ' || i.reject_reason, ''), i.id);
  end if;
  return i;
end; $function$
;
;
CREATE OR REPLACE FUNCTION public.inspection_new_revision(p_id uuid, p_client_id uuid)
 RETURNS vehicle_inspections
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me public.profiles := public._insp_me(); o public.vehicle_inspections; n public.vehicle_inspections;
begin
  if me.role not in ('OPERARIO_DEPOSITO','SUPERVISOR_DESPACHO') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_id is null or p_client_id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  -- (corrección de seguridad) PRIMERO se valida la inspección ORIGINAL: existe y el usuario puede verla. Ningún dato sale antes de esto.
  select * into o from public.vehicle_inspections where id = p_id;
  if o.id is null or not public._insp_can_view(o) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  -- reintento idempotente (doble toque / sin conexión): SOLO si ese client_id es una revisión creada por ESTE usuario a partir de ESTA original.
  -- Cualquier otro uso de un client_id existente se rechaza SIN devolver datos (ni número, ni patente, ni estado).
  select * into n from public.vehicle_inspections where client_id = p_client_id;
  if n.id is not null then
    if n.created_by = me.id and n.parent_id = o.id then return n; end if;
    raise exception 'CLIENT_ID_CONFLICT: el identificador de la revisión ya está en uso; generá uno nuevo' using errcode = '23505';
  end if;
  if o.status not in ('APROBADA','RECHAZADA') then raise exception 'BAD_STATE: solo se revisa una inspección aprobada o rechazada' using errcode = '23514'; end if;
  insert into public.vehicle_inspections(number, revision, parent_id, client_id, vehicle_id, vehicle_name, vehicle_type, brand, model, plate, km, created_by, created_by_name, team_supervisor_id, general_observation)
  values (o.number, (select max(revision) + 1 from public.vehicle_inspections where number = o.number), o.id, p_client_id, o.vehicle_id, o.vehicle_name, o.vehicle_type, o.brand, o.model, o.plate, o.km,
          me.id, me.full_name, case when me.role = 'SUPERVISOR_DESPACHO' then me.id else me.supervisor_user_id end, o.general_observation) returning * into n;
  insert into public.vehicle_inspection_items(inspection_id, item_no, result, defect, observation, extra_date, extra_km)
    select n.id, item_no, result, defect, observation, extra_date, extra_km from public.vehicle_inspection_items where inspection_id = o.id;
  perform public._insp_event(n.id, 'REVISION_CREADA', jsonb_build_object('from', o.id, 'revision', n.revision));
  perform public._insp_event(o.id, 'REVISION_CREADA', jsonb_build_object('to', n.id, 'revision', n.revision));
  return n;
end; $function$
;
;
CREATE OR REPLACE FUNCTION public.inspection_email_request(p_id uuid, p_recipients text[], p_subject text, p_body text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me public.profiles := public._insp_me(); i public.vehicle_inspections; r text; rid bigint;
begin
  if me.role <> 'SUPERVISOR_DESPACHO' then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into i from public.vehicle_inspections where id = p_id;
  if i.id is null or not public._insp_can_view(i) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if i.status <> 'APROBADA' then raise exception 'BAD_STATE: el email se prepara solo para inspecciones aprobadas' using errcode = '23514'; end if;
  if coalesce(array_length(p_recipients, 1), 0) = 0 then raise exception 'RECIPIENTS_REQUIRED' using errcode = '23514'; end if;
  foreach r in array p_recipients loop if not public.is_valid_email(r) then raise exception 'EMAIL_INVALID: %', r using errcode = '23514'; end if; end loop;
  insert into public.vehicle_inspection_email_requests(inspection_id, requested_by, recipients, subject, body) values (i.id, me.id, p_recipients, p_subject, p_body) returning id into rid;
  perform public._insp_event(i.id, 'EMAIL_SOLICITADO', jsonb_build_object('recipients', p_recipients));
  return rid;
end; $function$
;
;
CREATE OR REPLACE FUNCTION public._insp_can_view(i vehicle_inspections)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (select 1 from public.profiles me where me.id = auth.uid() and me.status = 'ACTIVO' and (
    me.role = 'ADMIN' or i.created_by = me.id
    or (me.role = 'SUPERVISOR_DESPACHO' and i.team_supervisor_id = me.id))); $function$
;
;
CREATE OR REPLACE FUNCTION public.finalize_route(p_route uuid, p_km_end numeric DEFAULT NULL::numeric)
 RETURNS routes
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end; $function$
;
