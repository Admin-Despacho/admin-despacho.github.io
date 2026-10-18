-- OK DESPACHO ONLINE — Corrección de la revisión técnica (INFORME_REVISION_CLAUDE.md): ubicaciones internas (G2), TAREA y traslados.
-- Incremental y forward-only. No renombra ni modifica migraciones aplicadas. Número mayor a todas las existentes para quedar último
-- tanto por número como por fecha real de creación (ver tests/sql/migration_order.txt).
-- Reglas de negocio: UBICACION_INTERNA = traslado interno (no es entrega comercial); TAREA = parada operativa; solo PEDIDO es comercial.

-- =====================================================================
-- 1 · G2: lectura para quien prepara hojas; escritura sigue restringida a la RPC (settings.manage / locations.manage)
-- =====================================================================
drop policy if exists internal_locations_admin_read on public.internal_locations;
drop policy if exists internal_locations_read on public.internal_locations;
create policy internal_locations_read on public.internal_locations for select to authenticated
  using (public.auth_has_perm('settings.manage') or public.auth_has_perm('locations.manage') or public.auth_has_perm('locations.view') or public.auth_has_perm('routes.create'));
revoke insert, update, delete on public.internal_locations from authenticated, anon;
-- Auditoría con el ANTES y datos del geocodificador
alter table public.internal_locations add column if not exists geocode_source text;
alter table public.internal_locations add column if not exists geocode_display_name text;
create or replace function public.upsert_internal_location(p jsonb) returns public.internal_locations
language plpgsql security definer set search_path=public as $$
declare l public.internal_locations; prev jsonb;
begin
  if not (public.auth_has_perm('settings.manage') or public.auth_has_perm('locations.manage')) then raise exception 'FORBIDDEN' using errcode='42501'; end if;
  if coalesce(trim(p->>'location_key'),'')='' or coalesce(trim(p->>'name'),'')='' or (p->>'lat') is null or (p->>'lon') is null then raise exception 'BAD_LOCATION: completá clave, nombre y coordenadas' using errcode='23514'; end if;
  if abs((p->>'lat')::float8)>90 or abs((p->>'lon')::float8)>180 then raise exception 'BAD_LOCATION: coordenadas inválidas' using errcode='23514'; end if;
  if coalesce((p->>'radius_m')::int, 200) not between 10 and 5000 then raise exception 'BAD_LOCATION: el radio debe estar entre 10 y 5000 m' using errcode='23514'; end if;
  if exists (select 1 from public.internal_locations where active and location_key <> upper(trim(p->>'location_key')) and lower(trim(name)) = lower(trim(p->>'name')))
    then raise exception 'DUPLICATE_LOCATION_NAME: ya existe otra ubicación activa con ese nombre' using errcode='23505'; end if;
  select to_jsonb(x) into prev from public.internal_locations x where location_key = upper(trim(p->>'location_key'));
  insert into public.internal_locations(location_key,name,address,lat,lon,radius_m,active,note,geocode_source,geocode_display_name,updated_at)
  values (upper(trim(p->>'location_key')),trim(p->>'name'),nullif(trim(p->>'address'),''),(p->>'lat')::float8,(p->>'lon')::float8,coalesce((p->>'radius_m')::int,200),coalesce((p->>'active')::boolean,true),nullif(trim(p->>'note'),''),
          nullif(trim(p->>'geocode_source'),''),nullif(trim(p->>'geocode_display_name'),''),now())
  on conflict(location_key) do update set name=excluded.name,address=excluded.address,lat=excluded.lat,lon=excluded.lon,radius_m=excluded.radius_m,active=excluded.active,note=excluded.note,
    geocode_source=coalesce(excluded.geocode_source, internal_locations.geocode_source), geocode_display_name=coalesce(excluded.geocode_display_name, internal_locations.geocode_display_name), updated_at=now()
  returning * into l;
  insert into public.audit_log(actor_id,action,target_type,target_id,before,after) values(auth.uid(),'INTERNAL_LOCATION_SAVED','internal_location',l.location_key,prev,to_jsonb(l));
  return l;
end $$;
grant execute on function public.upsert_internal_location(jsonb) to authenticated, service_role;

-- =====================================================================
-- 2 · Snapshot GPS por parada (al publicar) + reglas por tipo de parada, validadas en el SERVIDOR
-- =====================================================================
alter table public.route_stops add column if not exists expected_lat double precision;
alter table public.route_stops add column if not exists expected_lon double precision;
alter table public.route_stops add column if not exists expected_radius_m integer;
alter table public.route_stops add column if not exists internal_location_updated_at timestamptz;
-- Sin asociación heurística por nombre/domicilio: G2 solo por clave explícita (la función queda sin uso)
drop trigger if exists trg_assign_internal_location on public.route_stops;
-- Se ejecuta DESPUÉS de trg_fill_stop_metadata_from_snapshot (los BEFORE triggers corren por orden alfabético)
create or replace function public._stop_type_rules() returns trigger language plpgsql security definer set search_path=public as $$
declare kind text; l public.internal_locations;
begin
  new.stop_type := coalesce(nullif(new.stop_type, ''), 'PEDIDO');
  select c.kind into kind from public.routes r join public.carriers c on c.id = r.carrier_id where r.id = new.route_id;
  if new.stop_type in ('TAREA','UBICACION_INTERNA') and coalesce(kind, '') <> 'INTERNO' then
    raise exception 'STOP_TYPE_REQUIRES_INTERNAL: % solo se publica con Transporte Interno', new.stop_type using errcode = '23514'; end if;
  if new.stop_type = 'UBICACION_INTERNA' then
    if new.internal_location_key is null then raise exception 'INTERNAL_LOCATION_REQUIRED: la ubicación interna no tiene clave G2' using errcode = '23514'; end if;
    select * into l from public.internal_locations where location_key = new.internal_location_key;
    if not found or not l.active then raise exception 'INTERNAL_LOCATION_INACTIVE: % no existe o está desactivada en G2', new.internal_location_key using errcode = '23514'; end if;
    -- nombre y domicilio vienen de G2 (no se editan en la hoja) y el GPS queda congelado para esta versión
    new.client_name := l.name; new.address := l.address; new.client_key := l.location_key;
    new.expected_lat := l.lat; new.expected_lon := l.lon; new.expected_radius_m := l.radius_m; new.internal_location_updated_at := l.updated_at;
  else
    new.internal_location_key := null; new.expected_lat := null; new.expected_lon := null; new.expected_radius_m := null; new.internal_location_updated_at := null;
  end if;
  if new.stop_type <> 'PEDIDO' then
    -- traslado interno / tarea: nunca comercial (sin montos, sin email al cliente, sin cobranza)
    new.merchandise_amount := 0; new.shipping_fee := 0; new.customer_email := null; new.task := 'ENTREGA'; new.expected_amount := null;
  end if;
  return new;
end $$;
revoke execute on function public._stop_type_rules() from public, anon, authenticated;
drop trigger if exists trg_zz_stop_type_rules on public.route_stops;
create trigger trg_zz_stop_type_rules before insert on public.route_stops for each row execute function public._stop_type_rules();
-- Anti-duplicado: una sola parada por ubicación interna en cada hoja (una "segunda visita" requeriría un mecanismo explícito que no existe)
create unique index if not exists route_stops_one_internal_location_per_route on public.route_stops(route_id, internal_location_key) where stop_type = 'UBICACION_INTERNA';
-- Snapshot para hojas YA publicadas/en curso (mejor dato disponible: el punto actual), solo con clave explícita
update public.route_stops s set expected_lat = l.lat, expected_lon = l.lon, expected_radius_m = l.radius_m, internal_location_updated_at = l.updated_at
  from public.internal_locations l, public.routes r
 where l.location_key = s.internal_location_key and r.id = s.route_id and r.operational_status in ('PUBLICADA','EN_CURSO') and s.expected_lat is null
   and (s.stop_type = 'UBICACION_INTERNA' or (r.sheet_snapshot->'stops'->(s.seq-1)->>'internal_location_key') = s.internal_location_key);
insert into public.audit_log(action, target_type, target_id, after) values ('INTERNAL_LOCATION_SNAPSHOT_BACKFILL', 'route_stops', 'G2', jsonb_build_object('note', 'snapshot GPS inicial para hojas publicadas/en curso con clave G2 explícita'));

create or replace function public._loc(p jsonb, st public.route_stops) returns jsonb
language plpgsql stable security definer set search_path=public as $$
declare cm public.client_locations; im public.internal_locations; d double precision; radius int; elat double precision; elon double precision; source text; vkey text;
begin
  if p is null then raise exception 'LOCATION_REQUIRED: registrá la ubicación o indicá por qué no se pudo' using errcode='23514'; end if;
  if p ? 'lat' and p ? 'lon' then
    -- 1) Ubicación interna: SIEMPRE contra el snapshot guardado al publicar (editar o desactivar G2 después no cambia la hoja)
    if st.expected_lat is not null and st.expected_lon is not null then
      elat := st.expected_lat; elon := st.expected_lon; radius := st.expected_radius_m; source := 'INTERNAL_SNAPSHOT'; vkey := st.internal_location_key;
    -- 2) Compatibilidad: ubicación interna publicada antes del snapshot → punto vigente, solo por clave explícita (nunca por nombre/domicilio)
    elsif st.stop_type = 'UBICACION_INTERNA' and st.internal_location_key is not null then
      select * into im from public.internal_locations where location_key = st.internal_location_key;
      if found then elat := im.lat; elon := im.lon; radius := im.radius_m; source := 'INTERNAL_LIVE'; vkey := im.location_key; end if;
    end if;
    -- 3) Cliente (pedidos comerciales): igual que antes
    if elat is null and coalesce(st.stop_type, 'PEDIDO') = 'PEDIDO' and st.client_key is not null then
      select * into cm from public.client_locations where client_key = st.client_key and active;
      if found then elat := cm.lat; elon := cm.lon; radius := cm.radius_m; source := 'CLIENT'; vkey := st.client_key; end if;
    end if;
    if elat is not null then d := public._dist_m(elat, elon, (p->>'lat')::float8, (p->>'lon')::float8); end if;
    return jsonb_build_object('lat', (p->>'lat')::float8, 'lon', (p->>'lon')::float8, 'accuracy', nullif(p->>'accuracy', '')::float8, 'at', now(),
      'validation_source', source, 'validation_key', vkey, 'expected_lat', elat, 'expected_lon', elon, 'radius_m', radius,
      'distance_m', case when d is not null then round(d) end, 'outside_m', case when d is not null and radius is not null and d > radius then round(d) end);
  end if;
  if coalesce(trim(p->>'missing_reason'), '') = '' then raise exception 'LOCATION_REASON_REQUIRED: sin ubicación hay que indicar el motivo' using errcode='23514'; end if;
  return jsonb_build_object('missing_reason', trim(p->>'missing_reason'), 'at', now());
end $$;
revoke execute on function public._loc(jsonb, public.route_stops) from public, anon, authenticated;

-- =====================================================================
-- 3 · Reservas: solo las de las paradas publicadas; huérfanas rechazadas
-- =====================================================================
create or replace function public.publish_route(p jsonb)
returns public.routes language plpgsql security definer set search_path = public as $$
declare r public.routes; d public.route_drafts; resp uuid := (p->>'responsable_id')::uuid; car text := p->>'carrier_id'; s jsonb; i int := 0; ships text[]; ords text[];
begin
  if not public.auth_has_perm('routes.publish') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  d := public._draft(p->>'sheet_key', true, false);                   -- dueño (o permiso global) aunque ya esté publicada
  if d.status = 'PUBLICADA' then select * into r from public.routes where id = d.route_id; return r; end if;   -- reintento
  if d.status <> 'BORRADOR' then raise exception 'DRAFT_CANCELLED' using errcode = '23514'; end if;
  if car is null or not exists (select 1 from public.carriers where id = car and active) then raise exception 'BAD_CARRIER: elegí el transportista' using errcode = '23514'; end if;
  if resp is null or not public.can_be_responsable(resp, car) then raise exception 'RESPONSABLE_INCOMPATIBLE' using errcode = '23514'; end if;
  if jsonb_array_length(coalesce(p->'stops', '[]')) = 0 then raise exception 'EMPTY_SHEET: la hoja no tiene pedidos' using errcode = '23514'; end if;
  select array_agg(x->>'ship_order') into ships from jsonb_array_elements(p->'stops') x where x->>'ship_fee_status' = 'PROVISIONAL';
  if ships is not null then perform public.assert_sheet_shipping_ready(p->>'sheet_key', ships); end if;
  if exists (select 1 from jsonb_array_elements(p->'stops') x where coalesce((x->>'ready')::boolean, false) = false) then
    raise exception 'NOT_READY: hay pedidos con revisión pendiente o sin monto' using errcode = '23514';
  end if;
  select array_agg(distinct v) into ords from jsonb_array_elements(p->'stops') x, jsonb_array_elements_text(x->'order_numbers') v;
  perform public.reserve_orders(p->>'sheet_key', ords);
  -- Reservas huérfanas: pedidos reservados por este borrador que NO están en ninguna parada publicada → se rechaza (no se publican en silencio)
  if exists (select 1 from public.order_reservations o where o.sheet_key = p->>'sheet_key' and o.status = 'BORRADOR' and not (o.order_id = any(coalesce(ords, '{}')))) then
    raise exception 'ORPHAN_RESERVATIONS: hay pedidos reservados que no están en la hoja: %', (select string_agg(o.order_id, ', ' order by o.order_id) from public.order_reservations o
      where o.sheet_key = p->>'sheet_key' and o.status = 'BORRADOR' and not (o.order_id = any(coalesce(ords, '{}')))) using errcode = '23514';
  end if;
  insert into public.routes(number, carrier_id, responsable_id, status, operational_status, created_by, sheet_key, published_at, published_by, sheet_snapshot)
  values (public.next_route_number_for(car), car, resp, 'PUBLICADA', 'PUBLICADA', auth.uid(), p->>'sheet_key', now(), auth.uid(), p)
  returning * into r;
  update public.order_reservations set status = 'PUBLICADA', route_id = r.id where sheet_key = p->>'sheet_key' and order_id = any(coalesce(ords, '{}'));
  update public.route_drafts set status = 'PUBLICADA', route_id = r.id, updated_at = now() where id = d.id;
  for s in select * from jsonb_array_elements(p->'stops') loop
    i := i + 1;
    insert into public.route_stops(route_id, seq, sequence_number, provenance, client_name, client_key, zone, order_numbers, merchandise_amount, shipping_fee, shipping_fee_source, bultos, address, action)
    values (r.id, i, i, 'PUBLISHED', s->>'client_name', s->>'client_key', nullif(s->>'zone',''), coalesce((select array_agg(v) from jsonb_array_elements_text(s->'order_numbers') v), '{}'),
            coalesce((s->>'merchandise_amount')::numeric, 0), coalesce((s->>'shipping_fee')::numeric, 0),
            case when s->>'ship_fee_status' = 'PROVISIONAL' then 'CONFIRMED_FALLBACK' else 'SALDO' end, nullif(s->>'bultos','')::int, s->>'address', coalesce(s->>'action', 'ENTREGA'));
  end loop;
  insert into public.notifications(user_id, route_id, route_version, type, title, body)
  values (resp, r.id, 1, 'NUEVA_HOJA_PUBLICADA', 'NUEVA HOJA PUBLICADA', 'Hoja ' || r.number || ' · ' || i || ' entregas')
  on conflict do nothing;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'ROUTE_PUBLISHED', 'route', r.id::text, jsonb_build_object('number', r.number, 'carrier', car, 'responsable', resp, 'stops', i));
  return r;
end; $$;
create or replace function public.dispatch_external_route(p jsonb)
returns public.routes
language plpgsql
security definer
set search_path='public'
as $$
declare
  r public.routes;
  d public.route_drafts;
  car text := p->>'carrier_id';
  c public.carriers;
  s jsonb;
  i int := 0;
  ships text[];
  ords text[];
begin
  if not public.auth_has_perm('routes.publish') then
    raise exception 'FORBIDDEN' using errcode='42501';
  end if;
  d := public._draft(p->>'sheet_key', true, false);
  if d.status='PUBLICADA' then
    select * into r from public.routes where id=d.route_id;
    return r;
  end if;
  if d.status <> 'BORRADOR' then raise exception 'DRAFT_CANCELLED' using errcode='23514'; end if;

  select * into c from public.carriers where id=car and active;
  if not found then raise exception 'BAD_CARRIER: elegí el transportista' using errcode='23514'; end if;
  if c.kind <> 'EXTERNO' or c.report_group='CRISTIAN_TORRES' then
    raise exception 'NOT_EXTERNAL_DISPATCH: este transportista usa PUBLICAR HOJA' using errcode='23514';
  end if;

  if jsonb_array_length(coalesce(p->'stops','[]'::jsonb))=0 then raise exception 'EMPTY_SHEET: la hoja no tiene pedidos' using errcode='23514'; end if;
  select array_agg(x->>'ship_order') into ships from jsonb_array_elements(p->'stops') x where x->>'ship_fee_status'='PROVISIONAL';
  if ships is not null then perform public.assert_sheet_shipping_ready(p->>'sheet_key', ships); end if;
  if exists(select 1 from jsonb_array_elements(p->'stops') x where coalesce((x->>'ready')::boolean,false)=false) then
    raise exception 'NOT_READY: hay pedidos con revisión pendiente o sin monto' using errcode='23514';
  end if;
  select array_agg(distinct v) into ords from jsonb_array_elements(p->'stops') x, jsonb_array_elements_text(x->'order_numbers') v;
  perform public.reserve_orders(p->>'sheet_key', ords);
  -- Reservas huérfanas: pedidos reservados por este borrador que NO están en ninguna parada publicada → se rechaza (no se publican en silencio)
  if exists (select 1 from public.order_reservations o where o.sheet_key = p->>'sheet_key' and o.status = 'BORRADOR' and not (o.order_id = any(coalesce(ords, '{}')))) then
    raise exception 'ORPHAN_RESERVATIONS: hay pedidos reservados que no están en la hoja: %', (select string_agg(o.order_id, ', ' order by o.order_id) from public.order_reservations o
      where o.sheet_key = p->>'sheet_key' and o.status = 'BORRADOR' and not (o.order_id = any(coalesce(ords, '{}')))) using errcode = '23514';
  end if;

  insert into public.routes(number,carrier_id,responsable_id,status,operational_status,created_by,sheet_key,published_at,published_by,completed_at,completed_by,dispatched_at,dispatched_by,dispatch_mode,sheet_snapshot)
  values(public.next_route_number_for(car),car,null,'COMPLETADA','COMPLETADA',auth.uid(),p->>'sheet_key',now(),auth.uid(),now(),auth.uid(),now(),auth.uid(),'EXTERNAL',p)
  returning * into r;

  update public.order_reservations set status='PUBLICADA',route_id=r.id where sheet_key=p->>'sheet_key' and order_id = any(coalesce(ords, '{}'));
  update public.route_drafts set status='PUBLICADA',route_id=r.id,updated_at=now() where id=d.id;

  for s in select * from jsonb_array_elements(p->'stops') loop
    i:=i+1;
    insert into public.route_stops(route_id,seq,sequence_number,provenance,client_name,client_key,zone,order_numbers,merchandise_amount,shipping_fee,shipping_fee_source,bultos,address,action,task,expected_amount,customer_email)
    values(r.id,i,i,'PUBLISHED',s->>'client_name',s->>'client_key',nullif(s->>'zone',''),
      coalesce((select array_agg(v) from jsonb_array_elements_text(s->'order_numbers') v),'{}'),
      coalesce((s->>'merchandise_amount')::numeric,0),coalesce((s->>'shipping_fee')::numeric,0),
      case when s->>'ship_fee_status'='PROVISIONAL' then 'CONFIRMED_FALLBACK' else 'SALDO' end,
      nullif(s->>'bultos','')::int,s->>'address',coalesce(s->>'action','ENTREGA'),coalesce(s->>'task','ENTREGA'),
      nullif(s->>'expected_amount','')::numeric,nullif(s->>'customer_email',''));
  end loop;

  insert into public.audit_log(actor_id,action,target_type,target_id,after)
  values(auth.uid(),'EXTERNAL_ROUTE_DISPATCHED','route',r.id::text,jsonb_build_object('number',r.number,'carrier',car,'stops',i,'dispatch_mode','EXTERNAL'));
  return r;
end;
$$;

-- =====================================================================
-- 4 · Comportamiento por tipo de parada en el cierre (TAREA y traslado interno no son entrega comercial)
-- =====================================================================
create or replace function public.set_stop_outcome(p_stop uuid, p_outcome text, p_note text, p_reason text, p_op_id text, p_extra jsonb default null)
returns public.route_stops language plpgsql security definer set search_path = public as $$
declare st public.route_stops; r public.routes; cristian boolean; v_commercial boolean; v_task boolean; v_cuil text; v_email text; v_dni text; v_receipt boolean := false; ev jsonb := coalesce(p_extra->'evidence', '{}'); col jsonb := p_extra->'collection'; loc jsonb; sig bytea;
begin
  select * into st from public.route_stops where id = p_stop;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  r := public._my_route(st.route_id);
  -- Comportamiento por tipo de parada: solo PEDIDO es entrega comercial al cliente (email, Recibido Conforme, cobranza, identidad).
  v_commercial := coalesce(st.stop_type, 'PEDIDO') = 'PEDIDO';
  v_task := st.stop_type = 'TAREA';
  if p_op_id is not null and exists (select 1 from public.stop_outcome_ops where op_id = p_op_id) then return st; end if;
  if r.operational_status <> 'EN_CURSO' then raise exception 'BAD_STATE: iniciá el recorrido o la hoja ya está cerrada' using errcode = '23514'; end if;
  if p_outcome not in ('ENTREGADO','ENTREGA_PARCIAL','NO_ENTREGADO','REPROGRAMAR') then raise exception 'BAD_OUTCOME' using errcode = '22023'; end if;
  if p_outcome = 'ENTREGA_PARCIAL' and coalesce(trim(p_note), '') = '' then raise exception 'NOTE_REQUIRED: entrega parcial exige observación' using errcode = '23514'; end if;
  if p_outcome in ('NO_ENTREGADO','REPROGRAMAR') and coalesce(trim(p_reason), '') = '' then raise exception 'REASON_REQUIRED: indicá el motivo' using errcode = '23514'; end if;
  cristian := exists (select 1 from public.carriers where id = r.carrier_id and report_group = 'CRISTIAN_TORRES');
  if p_outcome in ('ENTREGADO','ENTREGA_PARCIAL') then
    -- TAREA: no se exige firma ni receptor como en una entrega comercial (alcanza GPS u observación). El resto, igual que antes.
    if not v_task and (coalesce(trim(ev->>'receiver_name'), '') = '' or coalesce(ev->>'signature_png_b64', '') = '') then raise exception 'EVIDENCE_REQUIRED: nombre del receptor y firma obligatorios' using errcode = '23514'; end if;
    sig := case when coalesce(ev->>'signature_png_b64', '') <> '' then decode(ev->>'signature_png_b64', 'base64') end;
    if cristian and v_commercial then
      v_cuil := regexp_replace(coalesce(ev->>'cuil', ''), '\D', '', 'g');
      if length(v_cuil) <> 11 then raise exception 'CUIL_INVALID: el CUIL debe tener 11 dígitos' using errcode = '23514'; end if;
      perform public._register_identity(v_cuil, ev);   -- RC1: DNI en Storage privado
    else
      v_cuil := nullif(regexp_replace(coalesce(ev->>'cuil', ''), '\D', '', 'g'), '');   -- Transportista Interno: CUIL opcional
      if v_cuil is not null and length(v_cuil) <> 11 then raise exception 'CUIL_INVALID: el CUIL debe tener 11 dígitos' using errcode = '23514'; end if;
    end if;
    -- RC4.1: email del receptor (segunda pantalla). Opcional; si viene, debe ser válido.
    v_email := nullif(lower(trim(coalesce(ev->>'email', ''))), '');
    if v_email is not null and not public.is_valid_email(v_email) then raise exception 'EMAIL_INVALID: el email no es válido' using errcode = '23514'; end if;
    v_dni := nullif(regexp_replace(coalesce(ev->>'dni', ''), '\D', '', 'g'), '');
    if v_dni is null and v_cuil is not null then v_dni := substr(v_cuil, 3, 8); end if;
    if v_dni is not null and length(v_dni) not between 7 and 8 then raise exception 'DNI_INVALID: el DNI debe tener 7 u 8 dígitos' using errcode = '23514'; end if;
  end if;
  -- cobranza (Cristian): el chofer no cambia el importe esperado
  if v_commercial and st.task in ('COBRANZA','AMBAS') then
    if col is null or coalesce(col->>'status', 'PENDIENTE') = 'PENDIENTE' then raise exception 'COLLECTION_REQUIRED: indicá el resultado de la cobranza' using errcode = '23514'; end if;
    if col->>'status' not in ('COBRADO','COBRO_PARCIAL','NO_COBRADO') then raise exception 'BAD_COLLECTION' using errcode = '22023'; end if;
    if col->>'status' in ('COBRO_PARCIAL','NO_COBRADO') and coalesce(trim(col->>'note'), '') = '' then raise exception 'COLLECTION_NOTE_REQUIRED: cobro parcial exige observación y no cobrado exige motivo' using errcode = '23514'; end if;
    if col->>'status' in ('COBRADO','COBRO_PARCIAL') and coalesce((col->>'amount')::numeric, 0) <= 0 then raise exception 'COLLECTION_AMOUNT_REQUIRED' using errcode = '23514'; end if;
  end if;
  loc := public._loc(p_extra->'location', st);
  update public.route_stops set outcome = p_outcome, outcome_at = now(), outcome_by = auth.uid(), outcome_note = nullif(trim(p_note),''), outcome_reason = nullif(trim(p_reason),''),
    finish_location = loc, location_warning = coalesce(case when loc->>'outside_m' is not null then 'FUERA DEL RADIO (' || (loc->>'outside_m') || ' m)' end, location_warning),
    collection_status = case when st.task in ('COBRANZA','AMBAS') then col->>'status' else collection_status end,
    collected_amount = case when st.task in ('COBRANZA','AMBAS') then nullif(col->>'amount','')::numeric else collected_amount end,
    payment_mode = case when st.task in ('COBRANZA','AMBAS') then col->>'mode' else payment_mode end,
    collection_note = case when st.task in ('COBRANZA','AMBAS') then nullif(trim(col->>'note'),'') else collection_note end
  where id = p_stop returning * into st;
  if p_outcome in ('ENTREGADO','ENTREGA_PARCIAL') then
    -- La entrega guarda el email USADO (inmutable aunque el perfil cambie después)
    if sig is not null then
      insert into public.stop_evidence(stop_id, receiver_name, signature_png, signature_sha256, receiver_cuil, created_by, receiver_email, receiver_dni)
      values (p_stop, nullif(trim(ev->>'receiver_name'), ''), sig, encode(sha256(sig), 'hex'), v_cuil, auth.uid(), case when v_commercial then v_email end, v_dni)
      on conflict (stop_id) do nothing;
    end if;
    -- Perfil reutilizable (misma capa de identidad que el DNI): nombre, DNI y email para próximas entregas
    if v_commercial and v_cuil is not null then perform public._upsert_identity_profile(v_cuil, trim(ev->>'receiver_name'), v_dni, v_email, st.client_key); end if;
    -- Recibido Conforme: entrega TOTAL confirmada + email válido → comprobante único + envío automático (la falla del email nunca revierte la entrega)
    if v_commercial and p_outcome = 'ENTREGADO' and v_email is not null then perform public._create_delivery_receipt(st, r, trim(ev->>'receiver_name'), v_email); v_receipt := true; end if;
    if v_commercial and coalesce(trim(st.customer_email), '') <> '' and not v_receipt then
      insert into public.customer_email_jobs(route_id, stop_id, kind, recipient, idempotency_key)
      values (st.route_id, st.id, case when p_outcome = 'ENTREGADO' then 'DELIVERED' else 'PARTIAL' end, lower(trim(st.customer_email)), st.route_id || '|' || st.id || '|' || case when p_outcome = 'ENTREGADO' then 'DELIVERED' else 'PARTIAL' end)
      on conflict (idempotency_key) do nothing;
    end if;
  end if;
  if p_op_id is not null then insert into public.stop_outcome_ops(op_id, stop_id) values (p_op_id, p_stop); end if;
  perform public._queue_on_the_way(st.route_id);
  return st;
end; $$;
create or replace function public._queue_on_the_way(p_route uuid) returns void language plpgsql security definer set search_path = public as $$
declare s public.route_stops;
begin
  select * into s from public.route_stops where route_id = p_route and outcome = 'PENDIENTE' order by sequence_number limit 1;
  if found and coalesce(s.stop_type, 'PEDIDO') = 'PEDIDO' and coalesce(trim(s.customer_email), '') <> '' then
    insert into public.customer_email_jobs(route_id, stop_id, kind, recipient, idempotency_key)
    values (p_route, s.id, 'ON_THE_WAY', lower(trim(s.customer_email)), p_route || '|' || s.id || '|ON_THE_WAY') on conflict (idempotency_key) do nothing;
  end if;
end; $$;
create or replace function public.dashboard_admin() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare today date := (now() at time zone 'America/Argentina/Mendoza')::date; res jsonb;
begin
  if not public.auth_is_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  with r as (select r.*, c.kind, c.id cid from public.routes r join public.carriers c on c.id = r.carrier_id where r.operational_status <> 'CANCELADA'),
  g as (select case when cid like 'CT-%' then 'CRISTIAN' when kind = 'INTERNO' then 'INTERNO' else 'OTROS' end grp, r.* from r)
  select jsonb_build_object(
    'kpis', jsonb_build_object(
      'hojas_hoy', (select count(*) from r where (published_at at time zone 'America/Argentina/Mendoza')::date = today),
      'en_curso', (select count(*) from r where operational_status = 'EN_CURSO'),
      'finalizadas', (select count(*) from r where operational_status = 'FINALIZADA' and (completed_at at time zone 'America/Argentina/Mendoza')::date = today),
      'incidencias', (select count(*) from public.route_stops s join r on r.id = s.route_id where s.outcome in ('NO_ENTREGADO','REPROGRAMAR','ENTREGA_PARCIAL') and coalesce(s.stop_type, 'PEDIDO') = 'PEDIDO' and r.operational_status in ('PUBLICADA','EN_CURSO','FINALIZADA') and coalesce((r.completed_at at time zone 'America/Argentina/Mendoza')::date, today) = today)),
    'carriers', (select coalesce(jsonb_agg(x order by x->>'grp'), '[]') from (select jsonb_build_object('grp', grp,
        'publicadas', count(*) filter (where operational_status in ('PUBLICADA','EN_CURSO','FINALIZADA')),
        'activas', count(*) filter (where operational_status in ('PUBLICADA','EN_CURSO')),
        'finalizadas', count(*) filter (where operational_status = 'FINALIZADA'),
        'incidencias', (select count(*) from public.route_stops s where s.route_id = any(array_agg(g.id)) and s.outcome in ('NO_ENTREGADO','REPROGRAMAR','ENTREGA_PARCIAL') and coalesce(s.stop_type, 'PEDIDO') = 'PEDIDO'),
        'devoluciones', (select count(*) from public.route_return_requests rr where rr.route_id = any(array_agg(g.id)) and rr.status = 'PENDING'),
        'km', coalesce(sum(km_end - km_start) filter (where km_end is not null and km_start is not null), 0)) x from g group by grp) t),
    'alerts', jsonb_build_object(
      'solicitudes', (select count(*) from public.route_approval_requests where status = 'PENDING'),
      'incidencias', (select count(*) from public.route_return_requests where status = 'PENDING'),
      'service', (select count(*) from public.vehicle_service_status where service_due),
      'emails_error', (select count(*) from public.customer_email_jobs where status = 'ERROR') + (select count(*) from public.sheet_email_jobs where status = 'ERROR'),
      'noc', (select count(*) from public.credit_notes where reconciliation_status in ('CANCELLED_ROUTE_REVIEW','CIANBOX_DIFFERENCE')),
      'km', (select count(*) from public.vehicle_mileage_alerts where status = 'OPEN')),
    'users', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'full_name', p.full_name, 'role', p.role, 'status', p.status, 'supervisor', s.full_name,
        'columns', public.user_has_perm(p.id, 'columns.manage_defaults'), 'km', public.user_has_perm(p.id, 'vehicle_mileage.rules_manage'),
        'approve', public.user_has_perm(p.id, 'requests.approve_team')) order by p.role, p.full_name), '[]')
      from public.profiles p left join public.profiles s on s.id = p.supervisor_user_id where p.role in ('ADMIN','SUPERVISOR_DESPACHO','OPERARIO_DEPOSITO','DESPACHO') and p.status <> 'ARCHIVADO')
  ) into res;
  return res;
end; $$;
create or replace function public.dashboard_supervisor() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid(); today date := (now() at time zone 'America/Argentina/Mendoza')::date;
begin
  if not (public.auth_has_perm('requests.view_team') or public.auth_has_perm('drafts.view_team')) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return jsonb_build_object(
    'kpis', jsonb_build_object(
      'borradores', (select count(*) from public.route_drafts d where d.status = 'BORRADOR' and (d.owner_id = me or d.owner_id in (select public.team_of(me)))),
      'borradores_equipo', (select count(*) from public.route_drafts d where d.status = 'BORRADOR' and d.owner_id in (select public.team_of(me))),
      'pendientes', (select count(*) from public.route_approval_requests q where q.status = 'PENDING' and q.supervisor_user_id = me),
      'activas', (select count(*) from public.routes r where r.operational_status in ('PUBLICADA','EN_CURSO') and (r.published_by = me or r.published_by in (select public.team_of(me)))),
      'operarios', (select count(*) from public.team_of(me))),
    'team', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'full_name', p.full_name, 'role', p.role, 'status', p.status,
        'borradores', (select count(*) from public.route_drafts d where d.owner_id = p.id and d.status = 'BORRADOR'),
        'publicadas_hoy', (select count(*) from public.routes r where r.published_by = p.id and (r.published_at at time zone 'America/Argentina/Mendoza')::date = today),
        'solicitudes', (select count(*) from public.route_approval_requests q where q.requested_by = p.id and q.status = 'PENDING')) order by p.full_name), '[]')
      from public.profiles p where p.id in (select public.team_of(me))),
    'requests', (select coalesce(jsonb_agg(jsonb_build_object('id', q.id, 'type', q.request_type, 'reason', q.reason, 'requested_by', p.full_name, 'at', q.requested_at, 'route', r.number) order by q.requested_at), '[]')
      from public.route_approval_requests q join public.profiles p on p.id = q.requested_by left join public.routes r on r.id = q.route_id
      where q.status = 'PENDING' and q.supervisor_user_id = me),
    'active', (select coalesce(jsonb_agg(jsonb_build_object('number', r.number, 'carrier', c.name, 'responsable', p.full_name, 'status', r.operational_status,
        'incidencia', exists (select 1 from public.route_stops s where s.route_id = r.id and s.outcome in ('NO_ENTREGADO','REPROGRAMAR','ENTREGA_PARCIAL') and coalesce(s.stop_type, 'PEDIDO') = 'PEDIDO')) order by r.published_at desc), '[]')
      from public.routes r join public.carriers c on c.id = r.carrier_id left join public.profiles p on p.id = r.responsable_id
      where r.operational_status in ('PUBLICADA','EN_CURSO') and (r.published_by = me or r.published_by in (select public.team_of(me)))),
    'notifications', (select coalesce(jsonb_agg(jsonb_build_object('title', n.title, 'body', n.body, 'at', n.created_at, 'type', n.type) order by n.created_at desc), '[]')
      from (select * from public.notifications where user_id = me or user_id in (select public.team_of(me)) order by created_at desc limit 12) n),
    'perms', jsonb_build_object('columns', public.auth_has_perm('columns.manage_defaults') or public.auth_has_perm('columns.manage_templates'),
      'km', public.auth_has_perm('vehicle_mileage.rules_manage'), 'approve', public.auth_has_perm('requests.approve_team')));
end; $$;

-- =====================================================================
-- 5 · Parada agregada por el Transportista Interno = TAREA operativa futura (provenance DRIVER, usuario, fecha, versión y auditoría ya existentes)
-- =====================================================================
create or replace function public.add_internal_stop(p_route uuid, p_stop jsonb, p_version int, p_op_id text, p_offline boolean default false)
returns public.routes language plpgsql security definer set search_path = public as $$
declare r public.routes; nid uuid; nseq int;
begin
  r := public._my_route(p_route);
  if exists (select 1 from public.route_change_events where client_op_id = p_op_id) then return r; end if;   -- reintento offline
  if not exists (select 1 from public.carriers c where c.id = r.carrier_id and c.kind = 'INTERNO') then raise exception 'NOT_INTERNAL' using errcode = '23514'; end if;
  if r.operational_status <> 'EN_CURSO' then raise exception 'BAD_STATE' using errcode = '23514'; end if;
  if p_version <> r.version then raise exception 'VERSION_CONFLICT: la hoja cambió (versión %)', r.version using errcode = '40001'; end if;
  if coalesce(trim(p_stop->>'client_name'), '') = '' then raise exception 'NAME_REQUIRED' using errcode = '23514'; end if;
  select coalesce(max(seq), 0) + 1 into nseq from public.route_stops where route_id = p_route;
  -- el celular puede enviar el id (UUID) de la parada nueva: así un reordenamiento hecho offline ya la referencia
  insert into public.route_stops(id, route_id, seq, sequence_number, provenance, client_name, address, action, bultos, added_by, added_at, stop_type, instructions, contact_name, contact_phone)
  values (coalesce(nullif(p_stop->>'id', '')::uuid, gen_random_uuid()), p_route, nseq, (select coalesce(max(sequence_number), 0) + 1 from public.route_stops where route_id = p_route), 'DRIVER', p_stop->>'client_name', p_stop->>'address',
          coalesce(nullif(p_stop->>'action', ''), 'ENTREGA'), nullif(p_stop->>'bultos', '')::int, auth.uid(), now(),
          'TAREA', nullif(trim(p_stop->>'instructions'), ''), nullif(trim(p_stop->>'contact_name'), ''), nullif(trim(p_stop->>'contact_phone'), ''))
  returning id into nid;
  update public.routes set version = version + 1, has_driver_modifications = true, modification_count = modification_count + 1 where id = p_route returning * into r;
  insert into public.route_change_events(route_id, route_version, stop_id, event_type, after, user_id, client_op_id, offline)
  values (p_route, r.version, nid::text, 'INTERNAL_STOP_ADDED', p_stop, auth.uid(), p_op_id, p_offline);
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'INTERNAL_STOP_ADDED', 'route', p_route::text, p_stop);
  return r;
end; $$;

