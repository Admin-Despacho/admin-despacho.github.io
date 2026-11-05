-- Administrador General es el rol interno ADMIN, validado por _insp_me (ACTIVO).
-- Solo cinco RPC; no se cambian RLS, ACL, controles, rutas ni datos históricos.
-- Los borradores ajenos mantienen su propietario; Admin revisa cualquier equipo.
do $guard$ begin
  if (select md5(prosrc) from pg_proc where oid='public._insp_me()'::regprocedure) is distinct from '0e14354db6cfc8bc3249f36683fdd22f' then raise exception 'PRECONDITION_FAILED: _insp_me'; end if;
  if (select md5(prosrc) from pg_proc where oid='public._insp_event(uuid,text,jsonb)'::regprocedure) is distinct from '1a405fb2269b56198c7fd8a50e7d5e6e' then raise exception 'PRECONDITION_FAILED: _insp_event'; end if;
  if (select md5(prosrc) from pg_proc where oid='public.inspection_save_draft(jsonb)'::regprocedure) is distinct from '73fd5a97deb03f3514310ab5042da5cd' then raise exception 'PRECONDITION_FAILED: inspection_save_draft'; end if;
  if (select md5(prosrc) from pg_proc where oid='public.inspection_submit(uuid)'::regprocedure) is distinct from 'bbd5335d7fe620253410ca9a75440144' then raise exception 'PRECONDITION_FAILED: inspection_submit'; end if;
  if (select md5(prosrc) from pg_proc where oid='public.inspection_review(uuid,text,text)'::regprocedure) is distinct from '90129a0e55d67a6bb5c7b0ba5ee0bc64' then raise exception 'PRECONDITION_FAILED: inspection_review'; end if;
  if (select md5(prosrc) from pg_proc where oid='public.inspection_new_revision(uuid,uuid)'::regprocedure) is distinct from '95f97374a4ba1c6301929cc300995ec5' then raise exception 'PRECONDITION_FAILED: inspection_new_revision'; end if;
  if (select md5(prosrc) from pg_proc where oid='public.inspection_email_request(uuid,text[],text,text)'::regprocedure) is distinct from 'c62e056b0c544784c441641366e50519' then raise exception 'PRECONDITION_FAILED: inspection_email_request'; end if;
  if (select md5(prosrc) from pg_proc where oid='public._insp_can_view(vehicle_inspections)'::regprocedure) is distinct from '1801f00f09c1c95986a6cf2d965b3990' then raise exception 'PRECONDITION_FAILED: _insp_can_view'; end if;
  if (select md5(prosrc) from pg_proc where oid='public.finalize_route(uuid,numeric)'::regprocedure) is distinct from '5bdf85adab176a36ec9b55ceb1af3179' then raise exception 'PRECONDITION_FAILED: finalize_route'; end if;
  if (select count(*) from public.vehicle_inspection_controls) <> 30 or (select md5(jsonb_agg(to_jsonb(c) order by item_no)::text) from public.vehicle_inspection_controls c) <> '45ffdfc9144ef724c94103b56701e7a9' then raise exception 'PRECONDITION_FAILED: catalogo de controles'; end if;
end $guard$;

CREATE OR REPLACE FUNCTION public.inspection_save_draft(p jsonb)
 RETURNS vehicle_inspections
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me public.profiles := public._insp_me(); i public.vehicle_inspections; v public.vehicles; it jsonb; n int; existed boolean;
begin
  if me.role not in ('ADMIN','OPERARIO_DEPOSITO','SUPERVISOR_DESPACHO') then raise exception 'FORBIDDEN: solo Administrador General, Operario Depósito o Superior Despacho realizan inspecciones' using errcode = '42501'; end if;
  if (p->>'client_id') is null then raise exception 'CLIENT_ID_REQUIRED' using errcode = '22023'; end if;
  select * into i from public.vehicle_inspections where client_id = (p->>'client_id')::uuid;
  existed := i.id is not null;
  if i.id is not null and i.created_by <> me.id then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if i.id is not null and i.status <> 'BORRADOR' then return i; end if;   -- ya enviada: un guardado tardío (sin conexión) NO la modifica
  select * into v from public.vehicles where id = (p->>'vehicle_id')::uuid;
  if v.id is null then raise exception 'VEHICLE_NOT_FOUND: elegí un vehículo' using errcode = '23514'; end if;
  if i.id is null then
    insert into public.vehicle_inspections(number, client_id, vehicle_id, vehicle_name, vehicle_type, brand, model, plate, km, created_by, created_by_name, team_supervisor_id, general_observation)
    values ('INS-' || lpad(nextval('public.vehicle_inspection_number_seq')::text, 6, '0'), (p->>'client_id')::uuid, v.id, v.name, v.type, v.brand, v.model, v.plate,
            nullif(p->>'km', '')::numeric, me.id, me.full_name, case when me.role = 'ADMIN' then null when me.role = 'SUPERVISOR_DESPACHO' then me.id else me.supervisor_user_id end, p->>'general_observation')
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
  if existed and me.role = 'ADMIN' then
    insert into public.audit_log(actor_id,action,target_type,target_id,after) values (me.id,'INSPECTION_BORRADOR_GUARDADO','vehicle_inspection',i.id::text,jsonb_build_object('created_by',i.created_by));
  end if;
  return i;
end; $function$
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
  team := case when me.role = 'ADMIN' then i.team_supervisor_id when me.role = 'SUPERVISOR_DESPACHO' then me.id else me.supervisor_user_id end;
  if me.role <> 'ADMIN' and (team is null or not exists (select 1 from public.profiles p where p.id = team and p.role = 'SUPERVISOR_DESPACHO' and p.status = 'ACTIVO')) then
    raise exception 'SUPERVISOR_REQUIRED: tu usuario no tiene un Superior Despacho asignado. Pedí al Administrador General que te asigne uno; la inspección queda guardada como borrador' using errcode = '23514'; end if;
  update public.vehicle_inspections set status = 'PENDIENTE', submitted_at = now(), updated_at = now(), team_supervisor_id = team,
    anomalies = (select count(*) from public.vehicle_inspection_items where inspection_id = i.id and result = 'MAL') where id = i.id returning * into i;
  perform public._insp_event(i.id, 'ENVIADA', jsonb_build_object('anomalies', i.anomalies, 'supervisor', team));
  if me.role not in ('ADMIN','SUPERVISOR_DESPACHO') then   -- SOLO al Superior de ese equipo (el Superior que inspecciona no se notifica a sí mismo)
    insert into public.notifications(user_id, type, title, body, inspection_id)
    values (team, 'INSPECTION_PENDING', 'Inspección ' || i.number || ' pendiente de aprobación', i.plate || ' · ' || coalesce(i.vehicle_name, '') || ' · ' || i.created_by_name || ' · ' || i.anomalies || ' anomalía(s)', i.id);
  end if;
  return i;
end; $function$
;

CREATE OR REPLACE FUNCTION public.inspection_review(p_id uuid, p_decision text, p_reason text)
 RETURNS vehicle_inspections
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me public.profiles := public._insp_me(); i public.vehicle_inspections;
begin
  if me.role not in ('ADMIN','SUPERVISOR_DESPACHO') then raise exception 'FORBIDDEN: solo Administrador General o Superior Despacho aprueban o rechazan inspecciones' using errcode = '42501'; end if;
  if p_decision not in ('APROBADA','RECHAZADA') then raise exception 'DECISION_INVALIDA' using errcode = '22023'; end if;
  select * into i from public.vehicle_inspections where id = p_id for update;
  if i.id is null or not coalesce(me.role = 'ADMIN' or i.created_by = me.id or i.team_supervisor_id = me.id, false) then raise exception 'FORBIDDEN: la inspección es de otro equipo' using errcode = '42501'; end if;   -- sin equipo (NULL) = de otro equipo
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

CREATE OR REPLACE FUNCTION public.inspection_new_revision(p_id uuid, p_client_id uuid)
 RETURNS vehicle_inspections
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me public.profiles := public._insp_me(); o public.vehicle_inspections; n public.vehicle_inspections;
begin
  if me.role not in ('ADMIN','OPERARIO_DEPOSITO','SUPERVISOR_DESPACHO') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
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
          me.id, me.full_name, case when me.role = 'ADMIN' then null when me.role = 'SUPERVISOR_DESPACHO' then me.id else me.supervisor_user_id end, o.general_observation) returning * into n;
  insert into public.vehicle_inspection_items(inspection_id, item_no, result, defect, observation, extra_date, extra_km)
    select n.id, item_no, result, defect, observation, extra_date, extra_km from public.vehicle_inspection_items where inspection_id = o.id;
  perform public._insp_event(n.id, 'REVISION_CREADA', jsonb_build_object('from', o.id, 'revision', n.revision));
  perform public._insp_event(o.id, 'REVISION_CREADA', jsonb_build_object('to', n.id, 'revision', n.revision));
  return n;
end; $function$
;

CREATE OR REPLACE FUNCTION public.inspection_email_request(p_id uuid, p_recipients text[], p_subject text, p_body text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me public.profiles := public._insp_me(); i public.vehicle_inspections; r text; rid bigint;
begin
  if me.role not in ('ADMIN','SUPERVISOR_DESPACHO') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
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
do $guard$ begin
  if (select md5(prosrc) from pg_proc where oid='public._insp_me()'::regprocedure) <> '0e14354db6cfc8bc3249f36683fdd22f' then raise exception 'PROTECTED_FUNCTION_CHANGED: _insp_me'; end if;
  if (select md5(prosrc) from pg_proc where oid='public._insp_event(uuid,text,jsonb)'::regprocedure) <> '1a405fb2269b56198c7fd8a50e7d5e6e' then raise exception 'PROTECTED_FUNCTION_CHANGED: _insp_event'; end if;
  if (select md5(prosrc) from pg_proc where oid='public._insp_can_view(vehicle_inspections)'::regprocedure) <> '1801f00f09c1c95986a6cf2d965b3990' then raise exception 'PROTECTED_FUNCTION_CHANGED: _insp_can_view'; end if;
  if (select md5(prosrc) from pg_proc where oid='public.finalize_route(uuid,numeric)'::regprocedure) <> '5bdf85adab176a36ec9b55ceb1af3179' then raise exception 'PROTECTED_FUNCTION_CHANGED: finalize_route'; end if;
  if (select count(*) from public.vehicle_inspection_controls) <> 30 or (select md5(jsonb_agg(to_jsonb(c) order by item_no)::text) from public.vehicle_inspection_controls c) <> '45ffdfc9144ef724c94103b56701e7a9' then raise exception 'PRECONDITION_FAILED: catalogo de controles'; end if;
end $guard$;
