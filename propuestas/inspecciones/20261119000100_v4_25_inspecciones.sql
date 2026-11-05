-- =====================================================================================================================
-- PROPUESTA V4.25 · NO APLICADA · INSPECCIONES DE VEHÍCULOS (formulario R SE 4.5.1-05 Rev:00 · 30 controles exactos del Excel original)
-- Independiente de las migraciones de entregas: solo depende de tablas base (profiles, vehicles, notifications, audit_log).
-- Circuito: BORRADOR → PENDIENTE → APROBADA / RECHAZADA. Todo por funciones SECURITY DEFINER con validación del lado del servidor;
-- RLS por equipo (profiles.supervisor_user_id). Sin fotografías, cámara, adjuntos ni firmas. Aditivo: no modifica datos existentes.
-- Una transacción; si las tablas ya existen, se detiene sin cambiar nada.
-- =====================================================================================================================
BEGIN;
DO $guard$ BEGIN
  IF to_regclass('public.vehicle_inspections') IS NOT NULL THEN RAISE EXCEPTION 'YA_APLICADA: la V4.25 ya existe. No se modificó nada.'; END IF;
  IF to_regclass('public.vehicles') IS NULL OR to_regclass('public.profiles') IS NULL OR to_regclass('public.notifications') IS NULL OR to_regclass('public.audit_log') IS NULL THEN
    RAISE EXCEPTION 'DEPENDENCIA_FALTANTE: vehicles / profiles / notifications / audit_log. No se modificó nada.'; END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'profiles' AND column_name = 'supervisor_user_id') THEN
    RAISE EXCEPTION 'DEPENDENCIA_FALTANTE: profiles.supervisor_user_id. No se modificó nada.'; END IF;
END $guard$;

-- ---------- catálogo: los 30 controles EXACTOS del Excel R SE 4.5.1-05 (texto original, incluida su ortografía) ----------
create table public.vehicle_inspection_controls (
  item_no int primary key check (item_no between 1 and 30), category text not null, label text not null, extra text check (extra in ('VENCE','KM')));
insert into public.vehicle_inspection_controls(item_no, category, label, extra) values
  (1, 'DOCUMENTACIÓN', 'Poliza de Seguro + Último Recibo de Pago', 'VENCE'),
  (2, 'DOCUMENTACIÓN', 'Tarjeta Verde', null),
  (3, 'DOCUMENTACIÓN', 'Listado de Conductores Autorizados', null),
  (4, 'DOCUMENTACIÓN', 'Registro del último mantenimiento (Cam. de Aceite)', 'KM'),
  (5, 'DOCUMENTACIÓN', 'Copia de ultima verificación tecnica (RTO)', 'VENCE'),
  (6, 'ELEMENTOS DE SEGURIDAD', 'Extintor Cargado + Fecha de Vencimiento', 'VENCE'),
  (7, 'ELEMENTOS DE SEGURIDAD', 'Botiquín', null),
  (8, 'ELEMENTOS DE SEGURIDAD', 'Gato hidráulico, llave cruz y rueda de auxilio', null),
  (9, 'ELEMENTOS DE SEGURIDAD', 'Cinturon de Seguridad', null),
  (10, 'ELEMENTOS DE SEGURIDAD', 'Apoya-cabezas', null),
  (11, 'ELEMENTOS DE SEGURIDAD', 'Freno de Mano', null),
  (12, 'ELEMENTOS DE SEGURIDAD', 'Balizas Tipo Triángulo', null),
  (13, 'LUCES Y SEÑALES', 'Luz Alta y baja', null),
  (14, 'LUCES Y SEÑALES', 'Luz de Posición', null),
  (15, 'LUCES Y SEÑALES', 'Luz de Giro', null),
  (16, 'LUCES Y SEÑALES', 'Balizas', null),
  (17, 'LUCES Y SEÑALES', 'Luz de Freno', null),
  (18, 'LUCES Y SEÑALES', 'Luz Interior', null),
  (19, 'LUCES Y SEÑALES', 'Chapa Patente delantera y trasera', null),
  (20, 'LUCES Y SEÑALES', 'Bocina', null),
  (21, 'MECÁNICA Y ESTADO GENERAL', 'Espejos Retovisores', null),
  (22, 'MECÁNICA Y ESTADO GENERAL', 'Cierre de Puertas, capot, compuertas', null),
  (23, 'MECÁNICA Y ESTADO GENERAL', 'Higiene General', null),
  (24, 'MECÁNICA Y ESTADO GENERAL', 'Estado de Cubiertas', null),
  (25, 'MECÁNICA Y ESTADO GENERAL', 'Nivel Aceite Motor', null),
  (26, 'MECÁNICA Y ESTADO GENERAL', 'Nivel de Liquido refrigerante', null),
  (27, 'MECÁNICA Y ESTADO GENERAL', 'Nivel de Liquido Limpia Parabrisas', null),
  (28, 'MECÁNICA Y ESTADO GENERAL', 'Parabrisas en condiciones aceptables', null),
  (29, 'MECÁNICA Y ESTADO GENERAL', 'Calefactor/ Desempañador en buen funcionamiento', null),
  (30, 'MECÁNICA Y ESTADO GENERAL', 'Estado General de Carrocería', null);

create sequence public.vehicle_inspection_number_seq;
create table public.vehicle_inspections (
  id uuid primary key default gen_random_uuid(),
  number text not null, revision int not null default 1, parent_id uuid references public.vehicle_inspections(id),
  client_id uuid not null unique,                                  -- generado en el celular: evita duplicados al sincronizar sin conexión
  form_code text not null default 'R SE 4.5.1-05', form_rev text not null default 'Rev:00',
  vehicle_id uuid not null references public.vehicles(id), vehicle_name text, vehicle_type text, brand text, model text, plate text not null,
  km numeric(10,1),
  created_by uuid not null references public.profiles(id), created_by_name text not null, team_supervisor_id uuid references public.profiles(id),
  status text not null default 'BORRADOR' check (status in ('BORRADOR','PENDIENTE','APROBADA','RECHAZADA')),
  general_observation text, anomalies int not null default 0,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(), submitted_at timestamptz,
  reviewed_by uuid references public.profiles(id), reviewed_by_name text, reviewed_at timestamptz, reject_reason text,
  unique (number, revision));
create table public.vehicle_inspection_items (
  inspection_id uuid not null references public.vehicle_inspections(id), item_no int not null references public.vehicle_inspection_controls(item_no),
  result text check (result in ('BIEN','MAL','NO_APLICA')), defect text check (defect in ('FALTANTE','MAL_ESTADO')),
  observation text, extra_date date, extra_km numeric(10,1),
  primary key (inspection_id, item_no));
create table public.vehicle_inspection_events (
  id bigint generated always as identity primary key, inspection_id uuid not null references public.vehicle_inspections(id),
  action text not null check (action in ('CREADA','ENVIADA','APROBADA','RECHAZADA','REVISION_CREADA','EMAIL_PREPARADO','EMAIL_SOLICITADO')),
  actor uuid, actor_name text, at timestamptz not null default now(), detail jsonb);
create table public.vehicle_inspection_email_requests (
  id bigint generated always as identity primary key, inspection_id uuid not null references public.vehicle_inspections(id),
  requested_by uuid not null, requested_at timestamptz not null default now(), recipients text[] not null, subject text not null, body text not null,
  status text not null default 'PENDIENTE_ENVIO' check (status in ('PENDIENTE_ENVIO','ENVIADO','ERROR')), sent_at timestamptz, error text,
  retry_count int not null default 0);   -- lo envía internal-approvals (send_inspection_emails) con el proveedor existente; nunca al aprobar
alter table public.notifications add column if not exists inspection_id uuid references public.vehicle_inspections(id);   -- enlace directo (aditivo)

-- ---------- quién soy / alcance por equipo ----------
create or replace function public._insp_me() returns public.profiles language plpgsql stable security definer set search_path = public as $$
declare me public.profiles;
begin
  select * into me from public.profiles where id = auth.uid() and status = 'ACTIVO';
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return me;
end; $$;
create or replace function public._insp_can_view(i public.vehicle_inspections) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles me where me.id = auth.uid() and me.status = 'ACTIVO' and (
    me.role = 'ADMIN' or i.created_by = me.id
    or (me.role = 'SUPERVISOR_DESPACHO' and i.team_supervisor_id = me.id))); $$;   -- SOLO el Superior de ESE equipo (sin Superior asignado: solo el autor y el Administrador General)
create or replace function public._insp_event(p_id uuid, p_action text, p_detail jsonb) returns void language plpgsql security definer set search_path = public as $$
declare me public.profiles;
begin
  select * into me from public.profiles where id = auth.uid();
  insert into public.vehicle_inspection_events(inspection_id, action, actor, actor_name, detail) values (p_id, p_action, auth.uid(), me.full_name, p_detail);
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'INSPECTION_' || p_action, 'vehicle_inspection', p_id::text, p_detail);
end; $$;

-- ---------- borrador (crear / guardar): solo Operario Depósito y Superior Despacho; sin duplicados (client_id) ----------
create or replace function public.inspection_save_draft(p jsonb) returns public.vehicle_inspections language plpgsql security definer set search_path = public as $$
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
end; $$;

-- ---------- enviar a aprobación: los 30 controles; MAL exige FALTANTE/MAL ESTADO y observación ----------
create or replace function public.inspection_submit(p_id uuid) returns public.vehicle_inspections language plpgsql security definer set search_path = public as $$
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
end; $$;

-- ---------- aprobar / rechazar: SOLO Superior Despacho de ese equipo; rechazo con motivo; sin doble decisión ----------
create or replace function public.inspection_review(p_id uuid, p_decision text, p_reason text) returns public.vehicle_inspections language plpgsql security definer set search_path = public as $$
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
end; $$;

-- ---------- nueva revisión (de una APROBADA o RECHAZADA): la original queda intacta; la nueva es un BORRADOR enlazado ----------
create or replace function public.inspection_new_revision(p_id uuid, p_client_id uuid) returns public.vehicle_inspections language plpgsql security definer set search_path = public as $$
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
end; $$;

-- ---------- email a superiores: se PREPARA para revisión y se ENVÍA solo con confirmación explícita (nunca al aprobar) ----------
create or replace function public.inspection_email_request(p_id uuid, p_recipients text[], p_subject text, p_body text) returns bigint language plpgsql security definer set search_path = public as $$
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
end; $$;

-- ---------- defensa en profundidad: ninguna inspección enviada/revisada se modifica ni sus controles cambian por fuera de las funciones ----------
create or replace function public.trg_insp_items_locked() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if (select status from public.vehicle_inspections where id = coalesce(new.inspection_id, old.inspection_id)) <> 'BORRADOR' then
    raise exception 'INSPECTION_LOCKED: la inspección ya fue enviada; sus controles no se modifican' using errcode = '23514'; end if;
  return coalesce(new, old);
end; $$;
create trigger vehicle_inspection_items_locked before insert or update or delete on public.vehicle_inspection_items for each row execute function public.trg_insp_items_locked();

-- ---------- RLS y privilegios: lectura por equipo; ninguna escritura directa ----------
alter table public.vehicle_inspection_controls enable row level security; alter table public.vehicle_inspections enable row level security;
alter table public.vehicle_inspection_items enable row level security; alter table public.vehicle_inspection_events enable row level security;
alter table public.vehicle_inspection_email_requests enable row level security;
create policy insp_controls_read on public.vehicle_inspection_controls for select to authenticated using (true);
create policy insp_read on public.vehicle_inspections for select to authenticated using (public._insp_can_view(vehicle_inspections));
create policy insp_items_read on public.vehicle_inspection_items for select to authenticated using (exists (select 1 from public.vehicle_inspections i where i.id = inspection_id and public._insp_can_view(i)));
create policy insp_events_read on public.vehicle_inspection_events for select to authenticated using (exists (select 1 from public.vehicle_inspections i where i.id = inspection_id and public._insp_can_view(i)));
create policy insp_email_read on public.vehicle_inspection_email_requests for select to authenticated using (exists (select 1 from public.vehicle_inspections i where i.id = inspection_id and public._insp_can_view(i)));
do $$ declare t text; f text; begin
  foreach t in array array['vehicle_inspection_controls','vehicle_inspections','vehicle_inspection_items','vehicle_inspection_events','vehicle_inspection_email_requests'] loop
    execute format('revoke all on table public.%I from public, anon, authenticated', t); execute format('grant select on table public.%I to authenticated', t); end loop;
  execute 'revoke all on sequence public.vehicle_inspection_number_seq from public, anon, authenticated';
  foreach f in array array['inspection_save_draft(jsonb)','inspection_submit(uuid)','inspection_review(uuid,text,text)','inspection_new_revision(uuid,uuid)','inspection_email_request(uuid,text[],text,text)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon'; execute 'grant execute on function public.' || f || ' to authenticated'; end loop;
  foreach f in array array['_insp_me()','_insp_event(uuid,text,jsonb)','trg_insp_items_locked()'] loop execute 'revoke all on function public.' || f || ' from public, anon, authenticated'; end loop;
  execute 'revoke all on function public._insp_can_view(public.vehicle_inspections) from public, anon'; execute 'grant execute on function public._insp_can_view(public.vehicle_inspections) to authenticated';   -- la usa RLS
end $$;

DO $post$ BEGIN
  IF (SELECT count(*) FROM public.vehicle_inspection_controls) <> 30 THEN RAISE EXCEPTION 'HUELLA_FINAL_INESPERADA: el catálogo no tiene 30 controles. Se deshace todo.'; END IF;
END $post$;
COMMIT;
