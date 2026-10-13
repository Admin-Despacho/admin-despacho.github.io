-- OK DESPACHO ONLINE — RC3 (0.7.5-rc3, incremental, forward-only): circuito NOC + cancelación + conciliación con Cianbox.
-- Principio: Cianbox informa el saldo contable; OK Despacho registra las aplicaciones operativas.
-- Una importación de Cianbox NUNCA borra una aplicación local; cancelar una hoja publicada NUNCA devuelve la NOC automáticamente.

-- =====================================================================
-- 1 · Estructura (no destructiva): fuente Cianbox, reversiones y conciliación
-- =====================================================================
alter table public.credit_notes add column if not exists source_baseline_amount numeric(14,2);      -- saldo fuente al detectarla (antes de aplicaciones locales)
update public.credit_notes set source_baseline_amount = least(original_amount, remaining_amount + reserved_amount + consumed_amount) where source_baseline_amount is null;
-- toda NOC nueva guarda su saldo fuente inicial (base para comparar con importaciones posteriores)
create or replace function public.trg_credit_note_baseline() returns trigger language plpgsql as $$
begin
  if new.source_baseline_amount is null then new.source_baseline_amount := least(new.original_amount, new.remaining_amount + new.reserved_amount + new.consumed_amount); end if;
  return new;
end; $$;
drop trigger if exists credit_note_baseline on public.credit_notes;
create trigger credit_note_baseline before insert on public.credit_notes for each row execute function public.trg_credit_note_baseline();
alter table public.credit_notes add column if not exists source_remaining_amount numeric(14,2);     -- saldo informado por la ÚLTIMA importación de Cianbox
alter table public.credit_notes add column if not exists last_source_seen_at timestamptz;
alter table public.credit_notes add column if not exists last_source_import text;
alter table public.credit_notes add column if not exists reversed_amount numeric(14,2) not null default 0 check (reversed_amount >= 0);
alter table public.credit_notes add column if not exists reconciliation_status text not null default 'OK'
  check (reconciliation_status in ('OK','PENDING_CIANBOX','CANCELLED_ROUTE_REVIEW','RECONCILED','REVERSED','CIANBOX_DIFFERENCE'));
alter table public.credit_notes add column if not exists reconciliation_detail jsonb;
alter table public.credit_notes add column if not exists last_reconciled_at timestamptz;
alter table public.credit_notes add column if not exists recon_version int not null default 1;      -- concurrencia optimista de acciones administrativas

alter table public.credit_note_applications drop constraint if exists credit_note_applications_status_check;
alter table public.credit_note_applications add constraint credit_note_applications_status_check check (status in ('RESERVED','CONSUMED','RELEASED','REVERSED'));
alter table public.credit_note_applications add column if not exists order_numbers text[] not null default '{}';
alter table public.credit_note_applications add column if not exists reconciliation_status text
  check (reconciliation_status in ('OK','PENDING_CIANBOX','CANCELLED_ROUTE_REVIEW','RECONCILED','REVERSED','CIANBOX_DIFFERENCE'));
update public.credit_note_applications set reconciliation_status = 'PENDING_CIANBOX' where status = 'CONSUMED' and reconciliation_status is null;
alter table public.credit_note_applications add column if not exists cancelled_route_id uuid references public.routes(id);
alter table public.credit_note_applications add column if not exists cancelled_by uuid;
alter table public.credit_note_applications add column if not exists cancelled_at timestamptz;
alter table public.credit_note_applications add column if not exists cancel_reason text;
alter table public.credit_note_applications add column if not exists resolution text check (resolution in ('KEEP','REVERSED','RECONCILED'));
alter table public.credit_note_applications add column if not exists resolution_reason text;
alter table public.credit_note_applications add column if not exists resolved_by uuid;
alter table public.credit_note_applications add column if not exists resolved_at timestamptz;
alter table public.credit_note_applications add column if not exists reversed_op_id text unique;
alter table public.credit_note_applications add column if not exists reconciled_source_amount numeric(14,2);
alter table public.credit_note_applications add column if not exists reassigned_sheet_key text;
alter table public.credit_note_applications add column if not exists reassigned_from_route uuid references public.routes(id);

alter table public.credit_note_events drop constraint if exists credit_note_events_event_check;
alter table public.credit_note_events add constraint credit_note_events_event_check check (event in ('DETECTADA','RESERVADA','RESERVA_LIBERADA','APLICADA_PARCIAL','APLICADA_TOTAL',
  'INTENTO_DUPLICADO_BLOQUEADO','IGNORADA','RECHAZADA','HOJA_CANCELADA_REVISION','MANTENIDA_APLICADA','REVERTIDA','CONCILIADA','PENDIENTE_CIANBOX','DIFERENCIA_CIANBOX','REASOCIADA'));

-- Saldo EFECTIVO utilizable: nunca negativo, nunca mayor al original, nunca mayor a lo que Cianbox informa (menos reservas y consumos aún no reflejados)
create or replace function public.noc_effective_available(n public.credit_notes) returns numeric language sql stable as $$
  select case when n.status in ('IGNORADA','RECHAZADA') then 0::numeric else
    greatest(0, least(n.original_amount, n.remaining_amount,
      case when n.source_remaining_amount is null then n.remaining_amount
           else n.source_remaining_amount - n.reserved_amount
                - greatest(0, n.consumed_amount - greatest(0, coalesce(n.source_baseline_amount, n.original_amount) - n.source_remaining_amount)) end)) end;
$$;

-- Estado de conciliación de la NOC = el más exigente de sus aplicaciones consumidas
create or replace function public._noc_recon_aggregate(p_fp text) returns text language plpgsql security definer set search_path = public as $$
declare st text; n public.credit_notes;
begin
  select * into n from public.credit_notes where fingerprint = p_fp;
  select case when bool_or(reconciliation_status = 'CANCELLED_ROUTE_REVIEW') then 'CANCELLED_ROUTE_REVIEW'
              when bool_or(reconciliation_status = 'CIANBOX_DIFFERENCE') then 'CIANBOX_DIFFERENCE'
              when bool_or(reconciliation_status = 'PENDING_CIANBOX') then 'PENDING_CIANBOX'
              when bool_or(reconciliation_status = 'RECONCILED') then 'RECONCILED' end into st
    from public.credit_note_applications where fingerprint = p_fp and status = 'CONSUMED';
  if st is null then
    st := case when exists (select 1 from public.credit_note_applications where fingerprint = p_fp and status = 'REVERSED') then 'REVERSED' else 'OK' end;
    if n.reconciliation_status = 'CIANBOX_DIFFERENCE' and (n.reconciliation_detail->>'reason') in ('NO_INFORMADA','SALDO_MAYOR') then st := n.reconciliation_status; end if;
  end if;
  update public.credit_notes set reconciliation_status = st where fingerprint = p_fp and reconciliation_status is distinct from st;
  return st;
end; $$;
revoke execute on function public._noc_recon_aggregate(text) from public, anon, authenticated;

create or replace function public._consume_noc_apps(p_where text, p_value text, p_route uuid) returns int language plpgsql security definer set search_path = public as $$
declare a record; n public.credit_notes; k int := 0;
begin
  for a in execute format('select * from public.credit_note_applications where status = ''RESERVED'' and %I::text = $1 for update', p_where) using p_value loop
    update public.credit_note_applications set status = 'CONSUMED', route_id = coalesce(p_route, route_id), reconciliation_status = 'PENDING_CIANBOX' where id = a.id;
    update public.credit_notes set reserved_amount = greatest(0, reserved_amount - a.amount), consumed_amount = consumed_amount + a.amount where fingerprint = a.fingerprint returning * into n;
    perform public._noc_event(a.fingerprint, case when n.remaining_amount <= 0.004 and n.reserved_amount <= 0.004 then 'APLICADA_TOTAL' else 'APLICADA_PARCIAL' end, a.amount, a.sheet_key, p_route, a.destination,
      coalesce((select 'hoja ' || number from public.routes where id = p_route), a.reference), null);
    perform public._noc_recon_aggregate(a.fingerprint);
    k := k + 1;
  end loop;
  return k;
end; $$;
revoke execute on function public._consume_noc_apps(text, text, uuid) from public, anon, authenticated;

create or replace function public.apply_credit_note(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare idn jsonb; fp text; n public.credit_notes; a public.credit_note_applications; applied numeric; prev numeric; dest text := coalesce(nullif(p->>'destination', ''), 'PEDIDO_ACTUAL');
        req numeric := (p->>'amount')::numeric; ord numeric := (p->>'order_amount')::numeric; cc numeric := coalesce((p->>'cc_saldo')::numeric, 0); other text; code text; msg text; eff numeric;
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
  eff := public.noc_effective_available(n);   -- RC3: saldo realmente utilizable (Cianbox + reservas + consumos no reflejados + reversiones)
  code := case when n.status in ('IGNORADA','RECHAZADA') then 'NOC_BLOCKED'
               when n.reconciliation_status in ('CANCELLED_ROUTE_REVIEW','CIANBOX_DIFFERENCE') then 'NOC_UNDER_REVIEW'
               when eff <= 0.004 and n.reserved_amount <= 0.004 then 'NOC_CONSUMED'
               when other is not null then 'NOC_RESERVED_ELSEWHERE'
               when n.destination is not null and n.destination <> dest then 'NOC_DESTINATION_LOCKED'
               when eff <= 0.004 then 'NOC_CONSUMED' end;
  if code is not null then
    msg := case code when 'NOC_BLOCKED' then 'Administración marcó esta NOC como ' || n.status when 'NOC_CONSUMED' then 'NOTA DE CRÉDITO YA UTILIZADA'
           when 'NOC_RESERVED_ELSEWHERE' then 'NOTA DE CRÉDITO RESERVADA EN OTRO BORRADOR'
           when 'NOC_UNDER_REVIEW' then 'NOTA DE CRÉDITO EN REVISIÓN ADMINISTRATIVA (conciliación pendiente)' else 'La NOC ya se usó en ' || n.destination || ' y no puede usarse en otro destino' end;
    perform public._noc_event(fp, 'INTENTO_DUPLICADO_BLOQUEADO', req, p->>'sheet_key', null, dest, p->>'reference', jsonb_build_object('code', code, 'op_id', p->>'op_id'));
    return jsonb_build_object('ok', false, 'code', code, 'message', msg, 'fingerprint', fp, 'status', n.status, 'original', n.original_amount, 'consumed', n.consumed_amount, 'available', eff, 'reconciliation_status', n.reconciliation_status);
  end if;
  applied := round(least(req, eff, ord), 2);
  select coalesce(sum(x.amount), 0) into prev from public.credit_note_applications x join public.credit_notes y on y.fingerprint = x.fingerprint
   where x.sheet_key = p->>'sheet_key' and x.status = 'RESERVED' and y.cuit = n.cuit;
  insert into public.credit_note_applications(fingerprint, sheet_key, amount, op_id, created_by, destination, reference, order_numbers)
  values (fp, coalesce(p->>'sheet_key', 'FIN:' || coalesce(p->>'reference', '')), applied, p->>'op_id', auth.uid(), dest, coalesce(p->>'reference', p->>'sheet_key'),
          coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(p->'order_numbers', '[]')) x), '{}'));
  update public.credit_notes set remaining_amount = remaining_amount - applied, reserved_amount = reserved_amount + applied, destination = coalesce(destination, dest) where fingerprint = fp returning * into n;
  perform public._noc_event(fp, 'RESERVADA', applied, p->>'sheet_key', null, dest, coalesce(p->>'reference', p->>'sheet_key'),
    jsonb_build_object('requested', req, 'order_amount', ord, 'cc_saldo', cc, 'floor_before', greatest(0, cc - prev), 'floor_after', greatest(0, cc - prev - applied)));
  return jsonb_build_object('ok', true, 'fingerprint', fp, 'applied', applied, 'remaining', public.noc_effective_available(n), 'status', n.status, 'repeated', false,
    'floor_before', greatest(0, cc - prev), 'floor_after', greatest(0, cc - prev - applied), 'collect_after', round(ord - applied, 2));
end; $$;

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
      'consumed', n.consumed_amount, 'available', public.noc_effective_available(n), 'destination', n.destination,
      'reconciliation_status', n.reconciliation_status, 'source_remaining', n.source_remaining_amount,
      'prior', (select coalesce(jsonb_agg(jsonb_build_object('app_id', a.id, 'amount', a.amount, 'route_number', r.number, 'order_numbers', a.order_numbers, 'state', a.reconciliation_status,
                 'resolution', a.resolution, 'reassigned_sheet_key', a.reassigned_sheet_key)), '[]'::jsonb)
                from public.credit_note_applications a left join public.routes r on r.id = a.cancelled_route_id
                where a.fingerprint = n.fingerprint and a.cancelled_route_id is not null and a.status = 'CONSUMED'),
      'mine', (select coalesce(sum(amount), 0) from public.credit_note_applications where fingerprint = n.fingerprint and sheet_key = p_sheet_key and status = 'RESERVED'),
      'reserved_elsewhere', other.sheet_key is not null,
      'reserved_by', case when other.sheet_key is not null then coalesce('borrador "' || other.name || '"', 'otro borrador') || coalesce(' · ' || other.full_name, '') end,
      'used_at', last.created_at, 'used_destination', last.destination, 'used_reference', coalesce('hoja ' || last.number, last.reference)));
  end loop;
  return out;
end; $$;
grant execute on function public.apply_credit_note(jsonb), public.detect_credit_notes(text, jsonb) to authenticated;
grant execute on function public.noc_effective_available(public.credit_notes) to authenticated, service_role;

-- =====================================================================
-- 2 · Cancelar hoja publicada: TODO el comportamiento anterior + las NOC consumidas pasan a revisión (sin tocar importes)
-- =====================================================================
create or replace function public.cancel_route(p_route uuid, p_reason text) returns public.routes language plpgsql security definer set search_path = public as $$
declare r public.routes; a record;
begin
  if not public.auth_has_perm('routes.manage_all_drafts') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'REASON_REQUIRED' using errcode = '23514'; end if;
  update public.routes set operational_status = 'CANCELADA', status = 'CANCELADA' where id = p_route and operational_status in ('PUBLICADA','EN_CURSO') returning * into r;
  if not found then raise exception 'BAD_STATE: solo hojas publicadas o en curso' using errcode = '23514'; end if;
  update public.route_drafts set status = 'CANCELADA', updated_at = now() where route_id = p_route;
  delete from public.order_reservations where route_id = p_route;   -- la hoja cancelada ya no retiene los pedidos
  insert into public.notifications(user_id, route_id, route_version, type, title, body) values (r.responsable_id, r.id, r.version, 'ROUTE_CANCELLED', 'HOJA ' || r.number || ' CANCELADA', p_reason) on conflict do nothing;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'ROUTE_CANCELLED', 'route', p_route::text, jsonb_build_object('reason', p_reason, 'number', r.number));
  -- RC3: cancelar ≠ revertir NOC. consumed_amount y saldo quedan IGUALES; la aplicación queda pendiente de conciliación administrativa.
  for a in select * from public.credit_note_applications where route_id = p_route and status = 'CONSUMED' for update loop
    update public.credit_note_applications set reconciliation_status = 'CANCELLED_ROUTE_REVIEW', cancelled_route_id = p_route, cancelled_by = auth.uid(), cancelled_at = now(),
      cancel_reason = p_reason, resolution = null where id = a.id;
    perform public._noc_event(a.fingerprint, 'HOJA_CANCELADA_REVISION', a.amount, a.sheet_key, p_route, a.destination, 'hoja ' || r.number,
      jsonb_build_object('reason', p_reason, 'order_numbers', a.order_numbers, 'application', a.id));
    perform public._noc_recon_aggregate(a.fingerprint);
    update public.credit_notes set recon_version = recon_version + 1 where fingerprint = a.fingerprint;
  end loop;
  return r;
end; $$;
-- Aviso previo a cancelar (sin datos sensibles): cuántas NOC aplicadas tiene la hoja
create or replace function public.route_noc_summary(p_route uuid) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not (public.auth_has_perm('routes.manage_all_drafts') or public.auth_has_perm('credit_notes.manage')) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return (select jsonb_build_object('count', count(*), 'amount', coalesce(sum(amount), 0)) from public.credit_note_applications where route_id = p_route and status = 'CONSUMED');
end; $$;
grant execute on function public.cancel_route(uuid, text), public.route_noc_summary(uuid) to authenticated;

-- =====================================================================
-- 3 · Reimportación de Cianbox (Saldo Comprobante): concilia por huella estable, nunca sobrescribe consumos locales
-- =====================================================================
create or replace function public._noc_classify(n public.credit_notes) returns jsonb language sql immutable as $$
  select case
    when n.source_remaining_amount is null or n.consumed_amount <= 0.004 then jsonb_build_object('st', 'OK')
    when n.source_remaining_amount <= 0.004 then jsonb_build_object('st', 'RECONCILED', 'reason', 'SALDO_CERO')                                   -- caso A
    when abs(n.source_remaining_amount - (coalesce(n.source_baseline_amount, n.original_amount) - n.consumed_amount)) <= 0.01
      then jsonb_build_object('st', 'RECONCILED', 'reason', 'REDUCCION_EXACTA')                                                                -- caso C
    when abs(n.source_remaining_amount - coalesce(n.source_baseline_amount, n.original_amount)) <= 0.01
      then jsonb_build_object('st', 'PENDING_CIANBOX', 'reason', 'SIN_REFLEJAR')                                                               -- caso B
    when n.source_remaining_amount > coalesce(n.source_baseline_amount, n.original_amount)
      then jsonb_build_object('st', 'CIANBOX_DIFFERENCE', 'reason', 'SALDO_MAYOR')                                                             -- caso E
    else jsonb_build_object('st', 'CIANBOX_DIFFERENCE', 'reason', 'REDUCCION_PARCIAL')                                                         -- caso D (y reducciones mayores)
  end || jsonb_build_object('expected', coalesce(n.source_baseline_amount, n.original_amount) - n.consumed_amount, 'informed', n.source_remaining_amount,
    'difference', n.source_remaining_amount - (coalesce(n.source_baseline_amount, n.original_amount) - n.consumed_amount));
$$;
create or replace function public.reconcile_credit_notes(p_import_id text, p_items jsonb, p_complete boolean default false) returns jsonb language plpgsql security definer set search_path = public as $$
declare it jsonb; idn jsonb; n public.credit_notes; c jsonb; seen text[] := '{}'; cnt jsonb := '{}'; prev text; a record;
begin
  if not public.auth_has_perm('routes.create') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  for it in select * from jsonb_array_elements(coalesce(p_items, '[]')) loop
    idn := public._noc_identity(it);
    if idn ? 'error' then continue; end if;
    seen := seen || (idn->>'fingerprint');
    select * into n from public.credit_notes where fingerprint = idn->>'fingerprint' for update;
    if not found then continue; end if;                    -- solo se concilian NOC ya conocidas por OK Despacho
    prev := n.reconciliation_status;
    update public.credit_notes set source_remaining_amount = greatest(0, coalesce((it->>'available_amount')::numeric, 0)), last_source_seen_at = now(), last_source_import = p_import_id
      where fingerprint = n.fingerprint returning * into n;
    c := public._noc_classify(n);
    -- las aplicaciones en revisión por hoja cancelada o ya revertidas no se tocan; el resto toma el estado de la importación
    for a in select * from public.credit_note_applications where fingerprint = n.fingerprint and status = 'CONSUMED' and reconciliation_status is distinct from 'CANCELLED_ROUTE_REVIEW' loop
      update public.credit_note_applications set reconciliation_status = case when c->>'st' = 'OK' then 'PENDING_CIANBOX' else c->>'st' end,
        reconciled_source_amount = case when c->>'st' = 'RECONCILED' then n.source_remaining_amount else reconciled_source_amount end where id = a.id;
    end loop;
    update public.credit_notes set reconciliation_detail = c || jsonb_build_object('import', p_import_id),
      last_reconciled_at = case when c->>'st' = 'RECONCILED' then now() else last_reconciled_at end,
      reconciliation_status = case when c->>'st' = 'CIANBOX_DIFFERENCE' and consumed_amount > 0.004 then 'CIANBOX_DIFFERENCE' else reconciliation_status end
      where fingerprint = n.fingerprint;
    perform public._noc_recon_aggregate(n.fingerprint);
    select * into n from public.credit_notes where fingerprint = n.fingerprint;
    if n.reconciliation_status is distinct from prev then
      update public.credit_notes set recon_version = recon_version + 1 where fingerprint = n.fingerprint;
      perform public._noc_event(n.fingerprint, case n.reconciliation_status when 'RECONCILED' then 'CONCILIADA' when 'PENDING_CIANBOX' then 'PENDIENTE_CIANBOX' else 'DIFERENCIA_CIANBOX' end,
        null, null, null, null, p_import_id, c);
    end if;
    cnt := jsonb_set(cnt, array[n.reconciliation_status], to_jsonb(coalesce((cnt->>n.reconciliation_status)::int, 0) + 1));
  end loop;
  -- caso F: la NOC no aparece en una importación COMPLETA. La ausencia sola no prueba nada → revisión (sin tocar importes ni liberar saldo)
  if p_complete and jsonb_array_length(coalesce(p_items, '[]')) > 0 then   -- un archivo sin NOC no es evidencia de nada
    for n in select * from public.credit_notes where consumed_amount > 0.004 and not (fingerprint = any(seen)) and reconciliation_status in ('PENDING_CIANBOX','OK') for update loop
      update public.credit_notes set reconciliation_status = 'CIANBOX_DIFFERENCE', recon_version = recon_version + 1,
        reconciliation_detail = jsonb_build_object('st', 'CIANBOX_DIFFERENCE', 'reason', 'NO_INFORMADA', 'import', p_import_id) where fingerprint = n.fingerprint;
      update public.credit_note_applications set reconciliation_status = 'CIANBOX_DIFFERENCE' where fingerprint = n.fingerprint and status = 'CONSUMED' and reconciliation_status = 'PENDING_CIANBOX';
      perform public._noc_event(n.fingerprint, 'DIFERENCIA_CIANBOX', null, null, null, null, p_import_id, jsonb_build_object('reason', 'NO_INFORMADA'));
      cnt := jsonb_set(cnt, '{NO_INFORMADA}', to_jsonb(coalesce((cnt->>'NO_INFORMADA')::int, 0) + 1));
    end loop;
  end if;
  return cnt;
end; $$;
grant execute on function public.reconcile_credit_notes(text, jsonb, boolean) to authenticated;

-- =====================================================================
-- 4 · Acciones de Administración (credit_notes.manage): MANTENER APLICADA / REVERTIR A DISPONIBLE / CONFIRMAR CONCILIACIÓN
--     Bloqueo de fila (NOC + aplicación) + versión esperada: dos administradores no resuelven a la vez la misma NOC.
-- =====================================================================
create or replace function public.noc_resolve_application(p_app uuid, p_action text, p_reason text, p_expected_version int, p_op_id text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a public.credit_note_applications; n public.credit_notes; before jsonb; c jsonb; st text; amt numeric;
begin
  if not public.auth_has_perm('credit_notes.manage') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_action not in ('KEEP','REVERSE','RECONCILE') then raise exception 'BAD_ACTION' using errcode = '22023'; end if;
  select * into a from public.credit_note_applications where id = p_app;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  select * into n from public.credit_notes where fingerprint = a.fingerprint for update;           -- NOC primero, después la aplicación (orden fijo: sin deadlocks)
  select * into a from public.credit_note_applications where id = p_app for update;
  -- reintento idempotente de la MISMA reversión
  if p_action = 'REVERSE' and a.status = 'REVERSED' and p_op_id is not null and a.reversed_op_id = p_op_id then
    return jsonb_build_object('ok', true, 'repeated', true, 'application', a.id, 'available', public.noc_effective_available(n), 'version', n.recon_version); end if;
  if p_expected_version is not null and n.recon_version <> p_expected_version then
    raise exception 'NOC_CONFLICT: otra persona modificó esta Nota de Crédito; se recargó el estado real' using errcode = '40001'; end if;
  if p_action in ('KEEP','REVERSE') and coalesce(trim(p_reason), '') = '' then raise exception 'REASON_REQUIRED: indicá el motivo' using errcode = '23514'; end if;
  if a.status = 'REVERSED' then raise exception 'NOC_ALREADY_REVERSED: esta aplicación ya fue revertida' using errcode = '23514'; end if;
  if a.status <> 'CONSUMED' then raise exception 'BAD_STATE: solo aplicaciones consumidas' using errcode = '23514'; end if;
  before := jsonb_build_object('consumed', n.consumed_amount, 'remaining', n.remaining_amount, 'reversed', n.reversed_amount, 'available', public.noc_effective_available(n),
    'note_state', n.reconciliation_status, 'application_state', a.reconciliation_status, 'resolution', a.resolution);
  if p_action = 'KEEP' then
    if a.reconciliation_status <> 'CANCELLED_ROUTE_REVIEW' then raise exception 'BAD_STATE: solo aplicaciones de hojas canceladas en revisión' using errcode = '23514'; end if;
    c := public._noc_classify(n); st := case when c->>'st' in ('OK') then 'PENDING_CIANBOX' else c->>'st' end;
    update public.credit_note_applications set resolution = 'KEEP', resolution_reason = p_reason, resolved_by = auth.uid(), resolved_at = now(), reconciliation_status = st where id = a.id;
    perform public._noc_event(n.fingerprint, 'MANTENIDA_APLICADA', a.amount, a.sheet_key, a.cancelled_route_id, a.destination, p_reason, jsonb_build_object('application', a.id, 'state', st));
  elsif p_action = 'REVERSE' then
    if a.reconciliation_status = 'RECONCILED' then raise exception 'NOC_ALREADY_RECONCILED: Cianbox ya refleja esta aplicación; no se puede revertir desde OK Despacho' using errcode = '23514'; end if;
    amt := least(a.amount, n.consumed_amount);
    update public.credit_note_applications set status = 'REVERSED', resolution = 'REVERSED', resolution_reason = p_reason, resolved_by = auth.uid(), resolved_at = now(),
      reconciliation_status = 'REVERSED', reversed_op_id = coalesce(p_op_id, 'rev-' || a.id) where id = a.id;
    update public.credit_notes set consumed_amount = consumed_amount - amt, reversed_amount = reversed_amount + amt,
      remaining_amount = least(original_amount, remaining_amount + amt),
      destination = case when consumed_amount - amt <= 0.004 and reserved_amount <= 0.004 then null else destination end where fingerprint = n.fingerprint;
    perform public._noc_event(n.fingerprint, 'REVERTIDA', amt, a.sheet_key, coalesce(a.cancelled_route_id, a.route_id), a.destination, p_reason, jsonb_build_object('application', a.id));
  else
    update public.credit_note_applications set resolution = 'RECONCILED', resolution_reason = p_reason, resolved_by = auth.uid(), resolved_at = now(), reconciliation_status = 'RECONCILED',
      reconciled_source_amount = n.source_remaining_amount where id = a.id;
    update public.credit_notes set last_reconciled_at = now() where fingerprint = n.fingerprint;
    perform public._noc_event(n.fingerprint, 'CONCILIADA', a.amount, a.sheet_key, a.route_id, a.destination, p_reason, jsonb_build_object('application', a.id, 'cianbox', n.source_remaining_amount));
  end if;
  perform public._noc_recon_aggregate(n.fingerprint);
  update public.credit_notes set recon_version = recon_version + 1 where fingerprint = n.fingerprint returning * into n;
  select * into a from public.credit_note_applications where id = p_app;
  insert into public.audit_log(actor_id, action, target_type, target_id, before, after) values (auth.uid(), 'NOC_' || p_action, 'credit_note', n.fingerprint, before,
    jsonb_build_object('consumed', n.consumed_amount, 'remaining', n.remaining_amount, 'reversed', n.reversed_amount, 'available', public.noc_effective_available(n),
      'note_state', n.reconciliation_status, 'application_state', a.reconciliation_status, 'resolution', a.resolution, 'reason', p_reason, 'application', a.id,
      'amount', a.amount, 'route', coalesce(a.cancelled_route_id, a.route_id), 'order_numbers', a.order_numbers, 'import', n.last_source_import));
  return jsonb_build_object('ok', true, 'repeated', false, 'application', a.id, 'state', a.reconciliation_status, 'available', public.noc_effective_available(n), 'version', n.recon_version);
end; $$;
grant execute on function public.noc_resolve_application(uuid, text, text, int, text) to authenticated;

-- Reasociación OPERATIVA (sin segundo consumo): una aplicación MANTENIDA de una hoja cancelada se vincula a la nueva hoja del mismo pedido
create or replace function public.noc_reassociate(p_app uuid, p_sheet_key text) returns jsonb language plpgsql security definer set search_path = public as $$
declare a public.credit_note_applications;
begin
  if not public.auth_has_perm('routes.create') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  perform public._draft(p_sheet_key, false);
  select * into a from public.credit_note_applications where id = p_app for update;
  if not found or a.status <> 'CONSUMED' or a.cancelled_route_id is null or a.resolution is distinct from 'KEEP' then
    raise exception 'NOC_NOT_REASSIGNABLE: solo una aplicación mantenida por Administración de una hoja cancelada' using errcode = '23514'; end if;
  if a.reassigned_sheet_key is not null and a.reassigned_sheet_key <> p_sheet_key then raise exception 'NOC_ALREADY_REASSIGNED: ya se vinculó a otra hoja' using errcode = '23514'; end if;
  update public.credit_note_applications set reassigned_sheet_key = p_sheet_key where id = a.id;
  perform public._noc_event(a.fingerprint, 'REASOCIADA', a.amount, p_sheet_key, a.cancelled_route_id, a.destination, 'sin nuevo consumo', jsonb_build_object('application', a.id));
  return jsonb_build_object('ok', true, 'application', a.id, 'amount', a.amount, 'fingerprint', a.fingerprint);
end; $$;
grant execute on function public.noc_reassociate(uuid, text) to authenticated;
create or replace function public.trg_noc_on_draft_status() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'PUBLICADA' and old.status = 'BORRADOR' then
    perform public._consume_noc_apps('sheet_key', new.client_sheet_key, new.route_id);
    update public.credit_note_applications set reassigned_from_route = cancelled_route_id, route_id = new.route_id where reassigned_sheet_key = new.client_sheet_key and status = 'CONSUMED';
  elsif new.status = 'CANCELADA' and old.status = 'BORRADOR' then perform public._release_noc('sheet_key', new.client_sheet_key, 'borrador eliminado');
  end if;
  return new;
end; $$;

-- =====================================================================
-- 5 · Vista de Conciliación NOC (solo Administración)
-- =====================================================================
create or replace function public.noc_reconciliation_list(p_filter text default 'todos') returns table (
  application_id uuid, fingerprint text, comp text, client_name text, cuit text, issued_date text, original_amount numeric, source_remaining_amount numeric,
  reserved_amount numeric, consumed_amount numeric, reversed_amount numeric, effective_available numeric, application_amount numeric, application_status text,
  route_number text, route_status text, order_numbers text[], note_state text, application_state text, resolution text, resolution_reason text,
  last_source_seen_at timestamptz, last_source_import text, difference numeric, detail jsonb, recon_version int, cancel_reason text, cancelled_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.auth_has_perm('credit_notes.manage') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return query
  select a.id, n.fingerprint, n.comp, (select s.client_name from public.route_stops s where s.route_id = coalesce(a.cancelled_route_id, a.route_id) and s.order_numbers && a.order_numbers limit 1),
    n.cuit, n.issued_date, n.original_amount, n.source_remaining_amount, n.reserved_amount, n.consumed_amount, n.reversed_amount, public.noc_effective_available(n), a.amount, a.status,
    r.number, r.operational_status, a.order_numbers, n.reconciliation_status, a.reconciliation_status, a.resolution, a.resolution_reason, n.last_source_seen_at, n.last_source_import,
    (n.reconciliation_detail->>'difference')::numeric, n.reconciliation_detail, n.recon_version, a.cancel_reason, a.cancelled_at
  from public.credit_note_applications a join public.credit_notes n on n.fingerprint = a.fingerprint left join public.routes r on r.id = coalesce(a.cancelled_route_id, a.route_id)
  where a.status in ('CONSUMED','REVERSED')
    and (p_filter = 'todos' or (p_filter = 'pendientes' and a.reconciliation_status = 'PENDING_CIANBOX') or (p_filter = 'cancelada' and a.reconciliation_status = 'CANCELLED_ROUTE_REVIEW')
      or (p_filter = 'diferencias' and a.reconciliation_status = 'CIANBOX_DIFFERENCE') or (p_filter = 'conciliados' and a.reconciliation_status = 'RECONCILED')
      or (p_filter = 'revertidos' and a.reconciliation_status = 'REVERSED'))
  order by case a.reconciliation_status when 'CANCELLED_ROUTE_REVIEW' then 0 when 'CIANBOX_DIFFERENCE' then 1 when 'PENDING_CIANBOX' then 2 else 3 end, a.created_at desc;
end; $$;
grant execute on function public.noc_reconciliation_list(text) to authenticated;
-- La lectura de aplicaciones NOC queda para quien prepara hojas (necesario para operar) o Administración; Transportistas no ven nada.
drop policy if exists cna_read on public.credit_note_applications;
create policy cna_read on public.credit_note_applications for select to authenticated using (public.auth_has_perm('routes.create') or public.auth_has_perm('credit_notes.manage'));
revoke insert, update, delete on public.credit_notes, public.credit_note_applications, public.credit_note_events from authenticated, anon;
