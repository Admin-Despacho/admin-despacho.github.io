-- OK DESPACHO ONLINE — RC2.1b (incremental): financiación propia REAL (plan del cliente persistido) + NOC aplicada a un plan existente.
-- Fuente importada y ajuste operativo de OK Despacho quedan SEPARADOS. No se modifica Cianbox.

create table if not exists public.financing_plans (
  id uuid primary key default gen_random_uuid(),
  client_key text not null,                          -- CUIT/DNI (columna CUIT del Saldo Comprobante) o nombre normalizado si no hay
  client_name text, comp text not null,              -- comprobante financiado (normalizado)
  comp_label text,
  status text not null default 'ACTIVO' check (status in ('ACTIVO','SALDADO','CANCELADO')),
  frequency text not null default 'POR_CONFIRMAR' check (frequency in ('SEMANAL','MENSUAL','POR_CONFIRMAR')),
  frequency_source text not null default 'AUTO' check (frequency_source in ('AUTO','CONFIRMADA')),
  frequency_confirmed_by uuid, frequency_confirmed_at timestamptz, frequency_reason text,
  parts jsonb not null default '[]',                 -- [{due, q, s}] según la última importación (fuente)
  source_pending numeric(14,2) not null default 0 check (source_pending >= 0),   -- saldo según la fuente importada
  noc_adjustments numeric(14,2) not null default 0 check (noc_adjustments >= 0), -- ajustes NOC aplicados por OK Despacho
  operational_pending numeric(14,2) generated always as (greatest(0, source_pending - noc_adjustments)) stored,
  next_due date, next_amount numeric(14,2),
  last_import_id text, last_source_at timestamptz, resolver_version text,
  created_by uuid, created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique (client_key, comp)
);
alter table public.financing_plans enable row level security;
create policy financing_plans_read on public.financing_plans for select to authenticated
  using (public.auth_has_perm('routes.create') or public.auth_has_perm('routes.view_all') or public.auth_has_perm('credit_notes.manage'));
grant select on public.financing_plans to authenticated;
revoke insert, update, delete on public.financing_plans from authenticated, anon;

-- Estado derivado: CANCELADO se respeta; si no, ACTIVO con saldo operativo > 0, si no SALDADO
create or replace function public.trg_financing_plan_state() returns trigger language plpgsql as $$
begin
  if new.status <> 'CANCELADO' then new.status := case when greatest(0, new.source_pending - new.noc_adjustments) > 0.004 then 'ACTIVO' else 'SALDADO' end; end if;
  new.updated_at := now(); return new;
end; $$;
drop trigger if exists financing_plan_state on public.financing_plans;
create trigger financing_plan_state before insert or update on public.financing_plans for each row execute function public.trg_financing_plan_state();

-- Frecuencia SOLO con evidencia consistente: ≥ 3 vencimientos distintos y TODOS los intervalos de 7 días (SEMANAL)
-- o de exactamente 1 mes calendario (MENSUAL). Si no → POR_CONFIRMAR (no se inventa).
create or replace function public.financing_frequency(p_parts jsonb) returns text language plpgsql immutable as $$
declare d date[]; i int; weekly boolean := true; monthly boolean := true;
begin
  select array_agg(x order by x) into d from (select distinct (e->>'due')::date x from jsonb_array_elements(coalesce(p_parts, '[]')) e where coalesce(e->>'due', '') ~ '^\d{4}-\d{2}-\d{2}$') t;
  if d is null or array_length(d, 1) < 3 then return 'POR_CONFIRMAR'; end if;
  for i in 2..array_length(d, 1) loop
    if d[i] - d[i-1] <> 7 then weekly := false; end if;
    if d[i] <> (d[i-1] + interval '1 month')::date and not (d[i] = (date_trunc('month', d[i]) + interval '1 month - 1 day')::date and d[i-1] = (date_trunc('month', d[i-1]) + interval '1 month - 1 day')::date
       and (date_trunc('month', d[i]) = date_trunc('month', d[i-1]) + interval '1 month')) then monthly := false; end if;
  end loop;
  return case when weekly then 'SEMANAL' when monthly then 'MENSUAL' else 'POR_CONFIRMAR' end;
end; $$;
grant execute on function public.financing_frequency(jsonb) to authenticated, service_role;

-- Sincroniza los planes detectados en una importación. Solo actualiza la parte FUENTE; nunca toca los ajustes NOC.
-- Un pedido nuevo NO se incorpora: el plan es el comprobante financiado (comp) del cliente.
create or replace function public.sync_financing_plans(p_import_id text, p_plans jsonb) returns setof public.financing_plans language plpgsql security definer set search_path = public as $$
declare p jsonb; nd record; freq text;
begin
  if not public.auth_has_perm('routes.create') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  for p in select * from jsonb_array_elements(coalesce(p_plans, '[]')) loop
    if coalesce(p->>'client_key', '') = '' or coalesce(p->>'comp', '') = '' then continue; end if;
    freq := public.financing_frequency(p->'parts');
    select (e->>'due')::date due, (e->>'s')::numeric s into nd from jsonb_array_elements(p->'parts') e
      where coalesce((e->>'s')::numeric, 0) > 0.004 and coalesce(e->>'due', '') ~ '^\d{4}-\d{2}-\d{2}$' order by (e->>'due')::date limit 1;
    insert into public.financing_plans(client_key, client_name, comp, comp_label, frequency, parts, source_pending, next_due, next_amount, last_import_id, last_source_at, resolver_version, created_by)
    values (p->>'client_key', p->>'client_name', p->>'comp', p->>'comp_label', freq, p->'parts', greatest(0, coalesce((p->>'source_pending')::numeric, 0)), nd.due, nd.s, p_import_id, now(), p->>'resolver_version', auth.uid())
    on conflict (client_key, comp) do update set client_name = excluded.client_name, comp_label = excluded.comp_label, parts = excluded.parts, source_pending = excluded.source_pending,
      next_due = excluded.next_due, next_amount = excluded.next_amount, last_import_id = excluded.last_import_id, last_source_at = now(), resolver_version = excluded.resolver_version,
      frequency = case when public.financing_plans.frequency_source = 'CONFIRMADA' then public.financing_plans.frequency else excluded.frequency end;
  end loop;
  return query select * from public.financing_plans where client_key in (select x->>'client_key' from jsonb_array_elements(coalesce(p_plans, '[]')) x);
end; $$;

-- Confirmación de frecuencia por un usuario autorizado (auditada)
create or replace function public.confirm_financing_frequency(p_plan uuid, p_frequency text, p_reason text) returns public.financing_plans language plpgsql security definer set search_path = public as $$
declare f public.financing_plans; prev text;
begin
  if not (public.auth_has_perm('credit_notes.manage') or public.auth_has_perm('settings.manage')) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_frequency not in ('SEMANAL','MENSUAL') or coalesce(trim(p_reason), '') = '' then raise exception 'REASON_REQUIRED: indicá SEMANAL o MENSUAL y el motivo' using errcode = '23514'; end if;
  select frequency into prev from public.financing_plans where id = p_plan for update;
  if not found then raise exception 'PLAN_NOT_FOUND' using errcode = 'P0002'; end if;
  update public.financing_plans set frequency = p_frequency, frequency_source = 'CONFIRMADA', frequency_confirmed_by = auth.uid(), frequency_confirmed_at = now(), frequency_reason = p_reason where id = p_plan returning * into f;
  insert into public.audit_log(actor_id, action, target_type, target_id, before, after) values (auth.uid(), 'FINANCING_FREQUENCY_CONFIRMED', 'financing_plan', p_plan::text, jsonb_build_object('frequency', prev), jsonb_build_object('frequency', p_frequency, 'reason', p_reason));
  return f;
end; $$;
grant execute on function public.sync_financing_plans(text, jsonb), public.confirm_financing_frequency(uuid, text, text) to authenticated;

-- NOC → FINANCIACIÓN PROPIA: plan REAL (id) activo, bloqueo de plan + NOC, reduce SOLO el saldo operativo del plan (nunca negativo),
-- no toca el pedido actual ni lo incorpora al plan. Referencias libres inventadas se rechazan.
create or replace function public.consume_credit_note_financing(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare f public.financing_plans; r jsonb; pid uuid; idn jsonb; applied numeric;
begin
  if not public.auth_has_perm('routes.create') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  begin pid := (p->>'plan_id')::uuid; exception when others then pid := null; end;
  if pid is null then raise exception 'PLAN_NOT_FOUND: indicá un plan de financiación existente' using errcode = 'P0002'; end if;
  select * into f from public.financing_plans where id = pid for update;
  if not found then raise exception 'PLAN_NOT_FOUND: el plan de financiación no existe' using errcode = 'P0002'; end if;
  if f.status <> 'ACTIVO' or f.operational_pending <= 0.004 then raise exception 'PLAN_INACTIVE: el plan no está activo o no tiene saldo pendiente' using errcode = '23514'; end if;
  idn := public._noc_identity(p);
  if idn ? 'error' then raise exception '%: datos de la NOC inválidos', idn->>'error' using errcode = '23514'; end if;
  if idn->>'cuit' <> regexp_replace(f.client_key, '\D', '', 'g') then raise exception 'PLAN_CLIENT_MISMATCH: la NOC no es del cliente del plan' using errcode = '23514'; end if;
  r := public.apply_credit_note(p || jsonb_build_object('destination', 'FINANCIACION_PROPIA', 'sheet_key', 'FIN:' || pid, 'reference', pid::text, 'order_amount', f.operational_pending));
  if (r->>'ok')::boolean and not coalesce((r->>'repeated')::boolean, false) then
    perform public._consume_noc_apps('sheet_key', 'FIN:' || pid, null);
    applied := (r->>'applied')::numeric;
    update public.financing_plans set noc_adjustments = noc_adjustments + applied where id = pid returning * into f;
    insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'FINANCING_NOC_APPLIED', 'financing_plan', pid::text,
      jsonb_build_object('fingerprint', r->>'fingerprint', 'applied', applied, 'operational_pending', f.operational_pending, 'source_pending', f.source_pending));
  else select * into f from public.financing_plans where id = pid; end if;
  if (r->>'ok')::boolean then r := r || (select jsonb_build_object('status', n.status, 'remaining', n.remaining_amount) from public.credit_notes n where n.fingerprint = r->>'fingerprint'); end if; -- estado ya consumido
  return r || jsonb_build_object('consumed', (r->>'ok')::boolean, 'plan_id', pid, 'plan_operational_pending', f.operational_pending, 'plan_source_pending', f.source_pending, 'plan_noc_adjustments', f.noc_adjustments, 'plan_status', f.status);
end; $$;
grant execute on function public.consume_credit_note_financing(jsonb) to authenticated;

-- Snapshot de financiación al publicar (desde el flujo real: sheet_snapshot.financing). Histórico inmutable.
alter table public.route_financing_snapshots add column if not exists plan_id uuid references public.financing_plans(id);
alter table public.route_financing_snapshots add column if not exists frequency text;
alter table public.route_financing_snapshots add column if not exists source_pending numeric(14,2);
alter table public.route_financing_snapshots add column if not exists noc_adjustments numeric(14,2);
alter table public.route_financing_snapshots add column if not exists operational_pending numeric(14,2);
alter table public.route_financing_snapshots add column if not exists source_import text;
create or replace function public.trg_route_financing_snapshot() returns trigger language plpgsql security definer set search_path = public as $$
declare e jsonb; f public.financing_plans;
begin
  for e in select * from jsonb_array_elements(coalesce(new.sheet_snapshot->'financing', '[]')) loop
    f := null;
    if coalesce(e->>'plan_id', '') <> '' then select * into f from public.financing_plans where id = (e->>'plan_id')::uuid; end if;
    insert into public.route_financing_snapshots(route_id, route_version, comp, client_name, client_cuit, parts_count, parts, total, classification, resolver_version,
      plan_id, frequency, source_pending, noc_adjustments, operational_pending, source_import)
    values (new.id, coalesce(new.version, 1), coalesce(e->>'comp', f.comp), coalesce(e->>'client_name', f.client_name), coalesce(e->>'client_key', f.client_key),
      jsonb_array_length(coalesce(e->'parts', f.parts, '[]')), coalesce(e->'parts', f.parts, '[]'), coalesce(f.operational_pending, (e->>'total')::numeric),
      coalesce(e->>'classification', 'FINANCIACION_PROPIA_VIGENTE'), coalesce(e->>'resolver_version', f.resolver_version, 'fin-2'),
      f.id, coalesce(f.frequency, e->>'frequency'), f.source_pending, f.noc_adjustments, f.operational_pending, coalesce(e->>'import_id', f.last_import_id))
    on conflict (route_id, route_version, comp) do nothing;
  end loop;
  return null;
end; $$;
drop trigger if exists route_financing_snapshot on public.routes;
create trigger route_financing_snapshot after insert on public.routes for each row execute function public.trg_route_financing_snapshot();
create policy route_financing_snapshots_read2 on public.route_financing_snapshots for select to authenticated using (public.auth_has_perm('routes.view_all') or public.auth_has_perm('routes.create'));
grant select on public.route_financing_snapshots to authenticated;
