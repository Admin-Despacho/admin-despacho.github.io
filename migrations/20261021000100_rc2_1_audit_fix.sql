-- OK DESPACHO ONLINE — RC2.1 (incremental): correcciones de auditoría.
-- P0-01 NOC: la NOC aceptada REDUCE el piso de Saldo CC.  P0-02 huella NOC completa.
-- P1-04 rules_version obligatorio y exacto.  P1-05 sin escritura directa en routes/carriers.  P1-10 ruta interna exige vehículo activo.

-- =====================================================================
-- P0-02 · Comprobante parseado de forma determinística + huella completa
-- Formatos aceptados (mayúsculas/espacios/ceros a la izquierda indistintos):  "NOC [X] 0020-00001340", "NOC X 20-1340", "noc[x]0020-00001340".
-- Si el comprobante no se puede separar en tipo/letra/punto de venta/número → se rechaza (no se inventa).
-- =====================================================================
create or replace function public.parse_comprobante(p text) returns table (tipo text, letra text, pv int, numero bigint) language plpgsql immutable as $$
declare m text[];
begin
  -- tipo de 3 letras; la letra va entre corchetes o separada por espacio (así "NOC 0020-…" sin letra NO se confunde con tipo "NO" + letra "C")
  m := regexp_match(upper(coalesce(p, '')), '^\s*([A-Z]{3})\s*(?:\[\s*([A-Z])\s*\]|\s([A-Z]))\s*0*(\d{1,5})\s*-\s*0*(\d{1,8})\s*$');
  if m is null then return; end if;
  tipo := m[1]; letra := coalesce(m[2], m[3]); pv := m[4]::int; numero := m[5]::bigint; return next;
end; $$;
drop function if exists public.noc_fingerprint(text, text, text);
-- tipo + letra + punto_de_venta + número + CUIT + fecha de emisión + importe original
create or replace function public.noc_fingerprint(p_tipo text, p_letra text, p_pv int, p_numero bigint, p_cuit text, p_fecha date, p_importe numeric) returns text language sql immutable as $$
  select encode(sha256(convert_to(upper(trim(p_tipo)) || '|' || upper(trim(p_letra)) || '|' || p_pv || '|' || p_numero || '|' || regexp_replace(coalesce(p_cuit, ''), '\D', '', 'g')
    || '|' || to_char(p_fecha, 'YYYY-MM-DD') || '|' || to_char(round(abs(p_importe), 2), 'FM999999999990.00'), 'UTF8')), 'hex');
$$;
grant execute on function public.parse_comprobante(text), public.noc_fingerprint(text, text, int, bigint, text, date, numeric) to authenticated, service_role;
alter table public.credit_notes add column if not exists tipo text;
alter table public.credit_notes add column if not exists letra text;
alter table public.credit_notes add column if not exists pv int;
alter table public.credit_notes add column if not exists numero bigint;
alter table public.credit_notes add column if not exists cuit text;

-- =====================================================================
-- P0-01 · NOC: Saldo CC es el piso POR DEFECTO; si el operador ACEPTA la NOC, el importe aceptado REDUCE ese piso.
-- Ejemplo: cobro 150.000, Saldo CC 150.000, NOC aceptada 30.000 → cobro efectivo 120.000.
-- Si no la acepta, no se llama a esta función y el piso sigue siendo el Saldo CC.
-- =====================================================================
create or replace function public.apply_credit_note(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare c record; fp text; n public.credit_notes; a public.credit_note_applications; applied numeric; prev numeric; v_cuit text := regexp_replace(coalesce(p->>'cuit', ''), '\D', '', 'g');
        req numeric := (p->>'amount')::numeric; ord numeric := (p->>'order_amount')::numeric; cc numeric := coalesce((p->>'cc_saldo')::numeric, 0); fecha date; orig numeric := abs((p->>'original_amount')::numeric);
begin
  if not public.auth_has_perm('routes.create') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if coalesce((p->>'accept')::boolean, false) is not true then raise exception 'NOC_NOT_ACCEPTED: la NOC se aplica solo con aceptación explícita' using errcode = '23514'; end if;
  perform public._draft(p->>'sheet_key', true);
  select * into a from public.credit_note_applications where op_id = p->>'op_id';
  if found then select * into n from public.credit_notes where fingerprint = a.fingerprint;
    return jsonb_build_object('fingerprint', a.fingerprint, 'applied', a.amount, 'remaining', n.remaining_amount, 'status', n.status, 'repeated', true); end if;
  select * into c from public.parse_comprobante(p->>'comp');
  if c.tipo is null then raise exception 'NOC_BAD_COMP: no se puede identificar tipo/letra/punto de venta/número de "%"', p->>'comp' using errcode = '22023'; end if;
  if c.tipo <> 'NOC' then raise exception 'NOC_BAD_COMP: el comprobante no es una NOC' using errcode = '22023'; end if;
  -- Identificación fiscal tal como figura en la columna CUIT del Saldo Comprobante: CUIT (11 dígitos) o, en consumidores finales, DNI (7–8 dígitos).
  -- No se completa ni se inventa: si falta o tiene otro largo, se rechaza.
  if length(v_cuit) not in (7, 8, 11) then raise exception 'NOC_MISSING_DATA: falta el CUIT/DNI del cliente (columna CUIT del Saldo Comprobante)' using errcode = '23514'; end if;
  begin fecha := (p->>'issued_date')::date; exception when others then fecha := null; end;
  if fecha is null then raise exception 'NOC_MISSING_DATA: falta la fecha de emisión de la NOC' using errcode = '23514'; end if;
  if orig is null or orig <= 0 then raise exception 'NOC_MISSING_DATA: falta el importe original de la NOC' using errcode = '23514'; end if;
  if req is null or req <= 0 or ord is null then raise exception 'BAD_AMOUNT' using errcode = '22023'; end if;
  if ord <= 0.004 then raise exception 'NOC_NOTHING_TO_COLLECT: no hay importe a cobrar para reducir' using errcode = '23514'; end if;
  fp := public.noc_fingerprint(c.tipo, c.letra, c.pv, c.numero, v_cuit, fecha, orig);
  insert into public.credit_notes(fingerprint, client_key, comp, issued_date, original_amount, remaining_amount, created_by, tipo, letra, pv, numero, cuit)
  values (fp, v_cuit, p->>'comp', to_char(fecha, 'YYYY-MM-DD'), orig, coalesce(nullif((p->>'available_amount'), '')::numeric, orig), auth.uid(), c.tipo, c.letra, c.pv, c.numero, v_cuit)
  on conflict (fingerprint) do nothing;
  select * into n from public.credit_notes where fingerprint = fp for update;
  if n.status in ('IGNORADA','RECHAZADA') then raise exception 'NOC_BLOCKED: Administración marcó esta NOC como %', n.status using errcode = '23514'; end if;
  if n.remaining_amount <= 0.004 then raise exception 'NOC_CONSUMED: la NOC ya fue utilizada' using errcode = '23514'; end if;
  applied := round(least(req, n.remaining_amount, ord), 2);   -- parcial: lo que queda de la NOC o lo que hay para cobrar
  select coalesce(sum(x.amount), 0) into prev from public.credit_note_applications x join public.credit_notes y on y.fingerprint = x.fingerprint
   where x.sheet_key = p->>'sheet_key' and x.status = 'RESERVED' and y.cuit = v_cuit;
  insert into public.credit_note_applications(fingerprint, sheet_key, amount, op_id, created_by) values (fp, p->>'sheet_key', applied, p->>'op_id', auth.uid());
  update public.credit_notes set remaining_amount = remaining_amount - applied, status = public._noc_status(remaining_amount - applied, original_amount, status) where fingerprint = fp returning * into n;
  insert into public.credit_note_events(fingerprint, event, amount, sheet_key, actor, detail)
  values (fp, 'ACCEPTED', applied, p->>'sheet_key', auth.uid(), jsonb_build_object('requested', req, 'order_amount', ord, 'cc_saldo', cc, 'floor_after', greatest(0, cc - prev - applied)));
  insert into public.audit_log(actor_id, action, target_type, target_id, after)
  values (auth.uid(), 'NOC_ACCEPTED', 'credit_note', fp, jsonb_build_object('comp', n.comp, 'applied', applied, 'remaining', n.remaining_amount, 'sheet', p->>'sheet_key', 'floor_before', cc - prev, 'floor_after', greatest(0, cc - prev - applied)));
  return jsonb_build_object('fingerprint', fp, 'applied', applied, 'remaining', n.remaining_amount, 'status', n.status, 'repeated', false,
    'floor_before', greatest(0, cc - prev), 'floor_after', greatest(0, cc - prev - applied), 'collect_after', round(ord - applied, 2));
end; $$;

-- =====================================================================
-- P1-04 · rules_version OBLIGATORIO y EXACTO (no depende del frontend)
-- =====================================================================
create or replace function public.trg_routes_rules_version() returns trigger language plpgsql as $$
declare cur int; v int;
begin
  if coalesce(auth.role(), '') <> 'authenticated' then return new; end if;  -- restauración/cargas técnicas: el histórico conserva su versión
  select max(version) into cur from public.financial_rules;
  if new.sheet_snapshot is null or not (new.sheet_snapshot ? 'rules_version') or new.sheet_snapshot->>'rules_version' is null then
    raise exception 'RULES_REQUIRED: la hoja debe calcularse con la versión vigente de las reglas financieras (v%)', cur using errcode = '23514'; end if;
  begin v := (new.sheet_snapshot->>'rules_version')::int; exception when others then raise exception 'RULES_UNKNOWN: versión de reglas inválida' using errcode = '23514'; end;
  if v < cur then raise exception 'RULES_OUTDATED: las reglas financieras cambiaron (v%); recalculá la hoja antes de publicar', cur using errcode = '23514'; end if;
  if v > cur then raise exception 'RULES_UNKNOWN: la versión de reglas v% no existe (vigente v%)', v, cur using errcode = '23514'; end if;
  return new;
end; $$;

-- =====================================================================
-- P1-05 · Sin escritura directa en routes ni carriers: solo RPCs controladas y auditadas
-- =====================================================================
drop policy if exists routes_insert on public.routes;
drop policy if exists routes_update on public.routes;
drop policy if exists carriers_write on public.carriers;
revoke insert, update, delete on public.routes from authenticated, anon;
revoke insert, update, delete on public.carriers from authenticated, anon;

-- =====================================================================
-- P1-10 · Ruta INTERNA: vehículo activo obligatorio (al publicar y, para hojas viejas, al iniciar)
-- =====================================================================
create or replace function public.trg_route_vehicle_from_snapshot() returns trigger language plpgsql security definer set search_path = public as $$
declare internal boolean;
begin
  if coalesce(auth.role(), '') <> 'authenticated' then return new; end if;  -- restauración/cargas técnicas
  internal := exists (select 1 from public.carriers where id = new.carrier_id and kind = 'INTERNO');
  if internal then
    if new.sheet_snapshot is null or coalesce(new.sheet_snapshot->>'vehicle_id', '') = '' then raise exception 'VEHICLE_REQUIRED: la ruta interna necesita un vehículo activo' using errcode = '23514'; end if;
    new.vehicle_id := (new.sheet_snapshot->>'vehicle_id')::uuid;
    select plate, name into new.vehicle_plate, new.vehicle_name from public.vehicles where id = new.vehicle_id and active;
    if new.vehicle_plate is null then raise exception 'BAD_VEHICLE: vehículo inexistente o inactivo' using errcode = '23514'; end if;
  end if;
  return new;
end; $$;
create or replace function public.trg_route_start_needs_vehicle() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce(auth.role(), '') <> 'authenticated' then return new; end if;
  if new.operational_status = 'EN_CURSO' and old.operational_status = 'PUBLICADA' and new.vehicle_id is null
     and exists (select 1 from public.carriers where id = new.carrier_id and kind = 'INTERNO') then
    raise exception 'VEHICLE_REQUIRED: la ruta interna necesita un vehículo activo para iniciar' using errcode = '23514'; end if;
  return new;
end; $$;
drop trigger if exists route_start_needs_vehicle on public.routes;
create trigger route_start_needs_vehicle before update on public.routes for each row execute function public.trg_route_start_needs_vehicle();

-- =====================================================================
-- ADDENDUM RC2.1 · NOC YA UTILIZADA / NO REUTILIZABLE
-- Importes explícitos (original, reservado, consumido, disponible), estados funcionales, destino (pedido / financiación),
-- detección server-side, reserva exclusiva por borrador, consumo definitivo al publicar, re-importación sin revivir saldo,
-- intentos duplicados registrados (la función devuelve el rechazo en vez de abortar, para que el evento quede guardado).
-- =====================================================================
alter table public.credit_notes add column if not exists reserved_amount numeric(14,2) not null default 0 check (reserved_amount >= 0);
alter table public.credit_notes add column if not exists consumed_amount numeric(14,2) not null default 0 check (consumed_amount >= 0);
alter table public.credit_notes add column if not exists destination text check (destination in ('PEDIDO_ACTUAL','FINANCIACION_PROPIA'));
alter table public.credit_notes drop constraint if exists credit_notes_status_check;
update public.credit_notes set status = case status when 'PARCIAL' then 'PARCIALMENTE_UTILIZADA' when 'CONSUMIDA' then 'UTILIZADA' else status end;
alter table public.credit_notes add constraint credit_notes_status_check check (status in ('DISPONIBLE','RESERVADA','PARCIALMENTE_UTILIZADA','UTILIZADA','IGNORADA','RECHAZADA'));
alter table public.credit_note_applications add column if not exists destination text not null default 'PEDIDO_ACTUAL' check (destination in ('PEDIDO_ACTUAL','FINANCIACION_PROPIA'));
alter table public.credit_note_applications add column if not exists reference text;
alter table public.credit_note_events drop constraint if exists credit_note_events_event_check;
update public.credit_note_events set event = case event when 'ACCEPTED' then 'RESERVADA' when 'CONSUMED' then 'APLICADA_PARCIAL' when 'RELEASED' then 'RESERVA_LIBERADA' when 'IGNORED' then 'IGNORADA' when 'REJECTED' then 'RECHAZADA' else event end;
alter table public.credit_note_events add constraint credit_note_events_event_check check (event in ('DETECTADA','RESERVADA','RESERVA_LIBERADA','APLICADA_PARCIAL','APLICADA_TOTAL','INTENTO_DUPLICADO_BLOQUEADO','IGNORADA','RECHAZADA'));
alter table public.credit_note_events add column if not exists remaining numeric(14,2);
alter table public.credit_note_events add column if not exists destination text;
alter table public.credit_note_events add column if not exists reference text;

-- Estado SIEMPRE derivado de los importes (salvo decisión de Administración)
create or replace function public.trg_credit_note_state() returns trigger language plpgsql as $$
begin
  if new.status in ('IGNORADA','RECHAZADA') then return new; end if;
  new.status := case when new.reserved_amount > 0.004 then 'RESERVADA'
                     when new.remaining_amount <= 0.004 and new.consumed_amount > 0.004 then 'UTILIZADA'
                     when new.consumed_amount > 0.004 then 'PARCIALMENTE_UTILIZADA'
                     else 'DISPONIBLE' end;
  return new;
end; $$;
drop trigger if exists credit_note_state on public.credit_notes;
create trigger credit_note_state before insert or update on public.credit_notes for each row execute function public.trg_credit_note_state();

create or replace function public._noc_event(p_fp text, p_event text, p_amount numeric, p_sheet text, p_route uuid, p_dest text, p_ref text, p_detail jsonb) returns void language plpgsql security definer set search_path = public as $$
declare n public.credit_notes;
begin
  select * into n from public.credit_notes where fingerprint = p_fp;
  insert into public.credit_note_events(fingerprint, event, amount, sheet_key, route_id, actor, detail, remaining, destination, reference)
  values (p_fp, p_event, p_amount, p_sheet, p_route, auth.uid(), p_detail, n.remaining_amount, p_dest, p_ref);
  insert into public.audit_log(actor_id, action, target_type, target_id, after)
  values (auth.uid(), 'NOC_' || p_event, 'credit_note', p_fp, coalesce(p_detail, '{}'::jsonb) || jsonb_build_object('amount', p_amount, 'remaining', n.remaining_amount, 'destination', p_dest, 'reference', p_ref, 'sheet', p_sheet));
end; $$;
revoke execute on function public._noc_event(text, text, numeric, text, uuid, text, text, jsonb) from public, anon, authenticated;

-- Identidad de una NOC a partir de los datos de la fuente (mismas reglas que apply_credit_note)
create or replace function public._noc_identity(p jsonb) returns jsonb language plpgsql immutable as $$
declare c record; v_cuit text := regexp_replace(coalesce(p->>'cuit', ''), '\D', '', 'g'); f date; o numeric := abs((p->>'original_amount')::numeric);
begin
  select * into c from public.parse_comprobante(p->>'comp');
  if c.tipo is null or c.tipo <> 'NOC' then return jsonb_build_object('error', 'NOC_BAD_COMP'); end if;
  if length(v_cuit) not in (7, 8, 11) then return jsonb_build_object('error', 'NOC_MISSING_DATA'); end if;
  begin f := (p->>'issued_date')::date; exception when others then f := null; end;
  if f is null or o is null or o <= 0 then return jsonb_build_object('error', 'NOC_MISSING_DATA'); end if;
  return jsonb_build_object('fingerprint', public.noc_fingerprint(c.tipo, c.letra, c.pv, c.numero, v_cuit, f, o), 'tipo', c.tipo, 'letra', c.letra, 'pv', c.pv, 'numero', c.numero, 'cuit', v_cuit, 'fecha', to_char(f, 'YYYY-MM-DD'), 'original', o);
end; $$;

-- DETECCIÓN: registra (o reconoce) cada NOC del archivo y devuelve su estado REAL. Re-importar NUNCA revive saldo (insert ... on conflict do nothing).
create or replace function public.detect_credit_notes(p_sheet_key text, p_items jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare it jsonb; idn jsonb; n public.credit_notes; out jsonb := '[]'; last record; other record; ins boolean;
begin
  if not public.auth_has_perm('routes.create') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  for it in select * from jsonb_array_elements(coalesce(p_items, '[]')) loop
    idn := public._noc_identity(it);
    if idn ? 'error' then out := out || jsonb_build_array(jsonb_build_object('comp', it->>'comp', 'error', idn->>'error')); continue; end if;
    insert into public.credit_notes(fingerprint, client_key, comp, issued_date, original_amount, remaining_amount, created_by, tipo, letra, pv, numero, cuit)
    values (idn->>'fingerprint', idn->>'cuit', it->>'comp', idn->>'fecha', (idn->>'original')::numeric,
            least((idn->>'original')::numeric, coalesce(nullif(it->>'available_amount', '')::numeric, (idn->>'original')::numeric)), auth.uid(),
            idn->>'tipo', idn->>'letra', (idn->>'pv')::int, (idn->>'numero')::bigint, idn->>'cuit')
    on conflict (fingerprint) do nothing returning true into ins;
    if ins then perform public._noc_event(idn->>'fingerprint', 'DETECTADA', null, p_sheet_key, null, null, null, jsonb_build_object('comp', it->>'comp')); end if;
    select * into n from public.credit_notes where fingerprint = idn->>'fingerprint';
    select a.created_at, a.destination, a.reference, r.number into last from public.credit_note_applications a left join public.routes r on r.id = a.route_id
      where a.fingerprint = n.fingerprint and a.status = 'CONSUMED' order by a.created_at desc limit 1;
    select a.sheet_key, d.name, p.full_name into other from public.credit_note_applications a left join public.route_drafts d on d.client_sheet_key = a.sheet_key left join public.profiles p on p.id = a.created_by
      where a.fingerprint = n.fingerprint and a.status = 'RESERVED' and a.sheet_key <> p_sheet_key limit 1;
    out := out || jsonb_build_array(jsonb_build_object('comp', it->>'comp', 'fingerprint', n.fingerprint, 'status', n.status, 'original', n.original_amount, 'reserved', n.reserved_amount,
      'consumed', n.consumed_amount, 'available', n.remaining_amount, 'destination', n.destination,
      'mine', (select coalesce(sum(amount), 0) from public.credit_note_applications where fingerprint = n.fingerprint and sheet_key = p_sheet_key and status = 'RESERVED'),
      'reserved_elsewhere', other.sheet_key is not null,
      'reserved_by', case when other.sheet_key is not null then coalesce('borrador "' || other.name || '"', 'otro borrador') || coalesce(' · ' || other.full_name, '') end,
      'used_at', last.created_at, 'used_destination', last.destination, 'used_reference', coalesce('hoja ' || last.number, last.reference)));
  end loop;
  return out;
end; $$;

-- RESERVA (aceptación explícita). Exclusiva por borrador; consumo único; destino fijo. Los intentos inválidos por uso previo
-- devuelven { ok:false, code } y quedan registrados (INTENTO_DUPLICADO_BLOQUEADO).
create or replace function public.apply_credit_note(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare idn jsonb; fp text; n public.credit_notes; a public.credit_note_applications; applied numeric; prev numeric; dest text := coalesce(nullif(p->>'destination', ''), 'PEDIDO_ACTUAL');
        req numeric := (p->>'amount')::numeric; ord numeric := (p->>'order_amount')::numeric; cc numeric := coalesce((p->>'cc_saldo')::numeric, 0); other text; code text; msg text;
begin
  if not public.auth_has_perm('routes.create') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if coalesce((p->>'accept')::boolean, false) is not true then raise exception 'NOC_NOT_ACCEPTED: la NOC se aplica solo con aceptación explícita' using errcode = '23514'; end if;
  if dest not in ('PEDIDO_ACTUAL','FINANCIACION_PROPIA') then raise exception 'BAD_DESTINATION' using errcode = '22023'; end if;
  if dest = 'PEDIDO_ACTUAL' then perform public._draft(p->>'sheet_key', true); end if;
  select * into a from public.credit_note_applications where op_id = p->>'op_id';
  if found then select * into n from public.credit_notes where fingerprint = a.fingerprint;
    return jsonb_build_object('ok', true, 'fingerprint', a.fingerprint, 'applied', a.amount, 'remaining', n.remaining_amount, 'status', n.status, 'repeated', true); end if;
  idn := public._noc_identity(p);
  if idn->>'error' = 'NOC_BAD_COMP' then raise exception 'NOC_BAD_COMP: no se puede identificar tipo/letra/punto de venta/número de "%"', p->>'comp' using errcode = '22023'; end if;
  if idn->>'error' = 'NOC_MISSING_DATA' then raise exception 'NOC_MISSING_DATA: faltan CUIT/DNI, fecha de emisión o importe original de la NOC' using errcode = '23514'; end if;
  if req is null or req <= 0 or ord is null then raise exception 'BAD_AMOUNT' using errcode = '22023'; end if;
  if ord <= 0.004 then raise exception 'NOC_NOTHING_TO_COLLECT: no hay importe a cobrar para reducir' using errcode = '23514'; end if;
  fp := idn->>'fingerprint';
  insert into public.credit_notes(fingerprint, client_key, comp, issued_date, original_amount, remaining_amount, created_by, tipo, letra, pv, numero, cuit)
  values (fp, idn->>'cuit', p->>'comp', idn->>'fecha', (idn->>'original')::numeric, least((idn->>'original')::numeric, coalesce(nullif(p->>'available_amount', '')::numeric, (idn->>'original')::numeric)),
          auth.uid(), idn->>'tipo', idn->>'letra', (idn->>'pv')::int, (idn->>'numero')::bigint, idn->>'cuit')
  on conflict (fingerprint) do nothing;
  select * into n from public.credit_notes where fingerprint = fp for update;   -- bloqueo de fila: dos sesiones no reservan a la vez
  select a2.sheet_key into other from public.credit_note_applications a2 where a2.fingerprint = fp and a2.status = 'RESERVED' and a2.sheet_key <> coalesce(p->>'sheet_key', '') limit 1;
  code := case when n.status in ('IGNORADA','RECHAZADA') then 'NOC_BLOCKED'
               when n.remaining_amount <= 0.004 and n.reserved_amount <= 0.004 then 'NOC_CONSUMED'
               when other is not null then 'NOC_RESERVED_ELSEWHERE'
               when n.destination is not null and n.destination <> dest then 'NOC_DESTINATION_LOCKED'
               when n.remaining_amount <= 0.004 then 'NOC_CONSUMED' end;
  if code is not null then
    msg := case code when 'NOC_BLOCKED' then 'Administración marcó esta NOC como ' || n.status when 'NOC_CONSUMED' then 'NOTA DE CRÉDITO YA UTILIZADA'
           when 'NOC_RESERVED_ELSEWHERE' then 'NOTA DE CRÉDITO RESERVADA EN OTRO BORRADOR' else 'La NOC ya se usó en ' || n.destination || ' y no puede usarse en otro destino' end;
    perform public._noc_event(fp, 'INTENTO_DUPLICADO_BLOQUEADO', req, p->>'sheet_key', null, dest, p->>'reference', jsonb_build_object('code', code, 'op_id', p->>'op_id'));
    return jsonb_build_object('ok', false, 'code', code, 'message', msg, 'fingerprint', fp, 'status', n.status, 'original', n.original_amount, 'consumed', n.consumed_amount, 'available', n.remaining_amount);
  end if;
  applied := round(least(req, n.remaining_amount, ord), 2);
  select coalesce(sum(x.amount), 0) into prev from public.credit_note_applications x join public.credit_notes y on y.fingerprint = x.fingerprint
   where x.sheet_key = p->>'sheet_key' and x.status = 'RESERVED' and y.cuit = n.cuit;
  insert into public.credit_note_applications(fingerprint, sheet_key, amount, op_id, created_by, destination, reference)
  values (fp, coalesce(p->>'sheet_key', 'FIN:' || coalesce(p->>'reference', '')), applied, p->>'op_id', auth.uid(), dest, coalesce(p->>'reference', p->>'sheet_key'));
  update public.credit_notes set remaining_amount = remaining_amount - applied, reserved_amount = reserved_amount + applied, destination = coalesce(destination, dest) where fingerprint = fp returning * into n;
  perform public._noc_event(fp, 'RESERVADA', applied, p->>'sheet_key', null, dest, coalesce(p->>'reference', p->>'sheet_key'),
    jsonb_build_object('requested', req, 'order_amount', ord, 'cc_saldo', cc, 'floor_before', greatest(0, cc - prev), 'floor_after', greatest(0, cc - prev - applied)));
  return jsonb_build_object('ok', true, 'fingerprint', fp, 'applied', applied, 'remaining', n.remaining_amount, 'status', n.status, 'repeated', false,
    'floor_before', greatest(0, cc - prev), 'floor_after', greatest(0, cc - prev - applied), 'collect_after', round(ord - applied, 2));
end; $$;

-- Consumo definitivo (publicar la hoja o confirmar el plan de financiación)
create or replace function public._consume_noc_apps(p_where text, p_value text, p_route uuid) returns int language plpgsql security definer set search_path = public as $$
declare a record; n public.credit_notes; k int := 0;
begin
  for a in execute format('select * from public.credit_note_applications where status = ''RESERVED'' and %I::text = $1 for update', p_where) using p_value loop
    update public.credit_note_applications set status = 'CONSUMED', route_id = coalesce(p_route, route_id) where id = a.id;
    update public.credit_notes set reserved_amount = greatest(0, reserved_amount - a.amount), consumed_amount = consumed_amount + a.amount where fingerprint = a.fingerprint returning * into n;
    perform public._noc_event(a.fingerprint, case when n.remaining_amount <= 0.004 and n.reserved_amount <= 0.004 then 'APLICADA_TOTAL' else 'APLICADA_PARCIAL' end, a.amount, a.sheet_key, p_route, a.destination,
      coalesce((select 'hoja ' || number from public.routes where id = p_route), a.reference), null);
    k := k + 1;
  end loop;
  return k;
end; $$;
-- Libera SOLO lo reservado (nunca lo consumido)
create or replace function public._release_noc(p_where text, p_value text, p_reason text) returns int language plpgsql security definer set search_path = public as $$
declare a record; k int := 0;
begin
  for a in execute format('select * from public.credit_note_applications where status = ''RESERVED'' and %I::text = $1 for update', p_where) using p_value loop
    update public.credit_note_applications set status = 'RELEASED' where id = a.id;
    update public.credit_notes set reserved_amount = greatest(0, reserved_amount - a.amount), remaining_amount = least(original_amount, remaining_amount + a.amount),
           destination = case when consumed_amount > 0.004 or reserved_amount - a.amount > 0.004 then destination end where fingerprint = a.fingerprint;
    perform public._noc_event(a.fingerprint, 'RESERVA_LIBERADA', a.amount, a.sheet_key, a.route_id, a.destination, a.reference, jsonb_build_object('reason', p_reason));
    k := k + 1;
  end loop;
  return k;
end; $$;
revoke execute on function public._consume_noc_apps(text, text, uuid), public._release_noc(text, text, text) from public, anon, authenticated;
create or replace function public.release_credit_note(p_sheet_key text, p_fingerprint text) returns int language plpgsql security definer set search_path = public as $$
declare k int := 0; a record;
begin
  if not public.auth_has_perm('routes.create') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  perform public._draft(p_sheet_key, false);
  for a in select id from public.credit_note_applications where sheet_key = p_sheet_key and fingerprint = p_fingerprint and status = 'RESERVED' loop
    k := k + public._release_noc('id', a.id::text, 'deshacer');
  end loop;
  return k;
end; $$;
-- Financiación propia: reserva + consumo en una sola operación, con referencia al plan
create or replace function public.consume_credit_note_financing(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb;
begin
  if coalesce(p->>'reference', '') = '' then raise exception 'REFERENCE_REQUIRED: indicá el plan de financiación' using errcode = '23514'; end if;
  r := public.apply_credit_note(p || jsonb_build_object('destination', 'FINANCIACION_PROPIA', 'sheet_key', 'FIN:' || (p->>'reference')));
  if (r->>'ok')::boolean and not coalesce((r->>'repeated')::boolean, false) then perform public._consume_noc_apps('sheet_key', 'FIN:' || (p->>'reference'), null); end if;
  return r || jsonb_build_object('consumed', (r->>'ok')::boolean);
end; $$;
-- Admin: ignorar / rechazar (libera reservas, conserva consumos)
create or replace function public.decide_credit_note(p_fingerprint text, p_decision text, p_reason text) returns public.credit_notes language plpgsql security definer set search_path = public as $$
declare n public.credit_notes;
begin
  if not public.auth_has_perm('credit_notes.manage') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_decision not in ('IGNORADA','RECHAZADA') or coalesce(trim(p_reason), '') = '' then raise exception 'REASON_REQUIRED: indicá la decisión y el motivo' using errcode = '23514'; end if;
  perform 1 from public.credit_notes where fingerprint = p_fingerprint for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  perform public._release_noc('fingerprint', p_fingerprint, 'NOC ' || p_decision);
  update public.credit_notes set status = p_decision, reason = p_reason, decided_by = auth.uid(), decided_at = now() where fingerprint = p_fingerprint returning * into n;
  perform public._noc_event(p_fingerprint, p_decision, null, null, null, null, null, jsonb_build_object('reason', p_reason));
  return n;
end; $$;
-- Publicar = consumo definitivo de lo reservado. Eliminar/cancelar un BORRADOR = libera solo su reserva. Cancelar una hoja publicada no revierte el consumo.
create or replace function public.trg_noc_on_draft_status() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'PUBLICADA' and old.status = 'BORRADOR' then perform public._consume_noc_apps('sheet_key', new.client_sheet_key, new.route_id);
  elsif new.status = 'CANCELADA' and old.status = 'BORRADOR' then perform public._release_noc('sheet_key', new.client_sheet_key, 'borrador eliminado');
  end if;
  return new;
end; $$;
grant execute on function public.detect_credit_notes(text, jsonb), public.consume_credit_note_financing(jsonb), public.apply_credit_note(jsonb), public.release_credit_note(text, text) to authenticated;
