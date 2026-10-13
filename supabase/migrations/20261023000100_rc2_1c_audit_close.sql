-- OK DESPACHO ONLINE — RC2.1c (incremental): continuidad de planes de financiación y reglas Estado/Zona → Transportista en el servidor.

-- =====================================================================
-- 4 · Continuidad del plan: una importación posterior del MISMO comprobante actualiza la fuente aunque ya quede
--     una sola cuota o saldo 0. Pero un comprobante normal (una sola parte) SIN plan previo nunca crea un plan.
--     Se preservan noc_adjustments, frecuencia CONFIRMADA, identidad del plan y auditoría.
-- =====================================================================
create or replace function public.sync_financing_plans(p_import_id text, p_plans jsonb) returns setof public.financing_plans language plpgsql security definer set search_path = public as $$
declare p jsonb; nd record; freq text; exists_plan boolean; nparts int;
begin
  if not public.auth_has_perm('routes.create') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  for p in select * from jsonb_array_elements(coalesce(p_plans, '[]')) loop
    if coalesce(p->>'client_key', '') = '' or coalesce(p->>'comp', '') = '' then continue; end if;
    exists_plan := exists (select 1 from public.financing_plans where client_key = p->>'client_key' and comp = p->>'comp');
    nparts := jsonb_array_length(coalesce(p->'parts', '[]'));
    -- crear solo con evidencia de financiación (≥ 2 partes); la continuidad (1 parte / saldo 0) solo actualiza un plan existente
    if not exists_plan and (nparts < 2 or coalesce((p->>'only_if_exists')::boolean, false)) then continue; end if;
    freq := public.financing_frequency(p->'parts');
    nd := null;
    select (e->>'due')::date due, (e->>'s')::numeric s into nd from jsonb_array_elements(p->'parts') e
      where coalesce((e->>'s')::numeric, 0) > 0.004 and coalesce(e->>'due', '') ~ '^\d{4}-\d{2}-\d{2}$' order by (e->>'due')::date limit 1;
    if exists_plan then
      update public.financing_plans set client_name = coalesce(p->>'client_name', client_name), comp_label = coalesce(p->>'comp_label', comp_label),
        parts = case when nparts >= 2 then p->'parts' else parts end,   -- con una sola fila no se pierden las partes conocidas
        source_pending = greatest(0, coalesce((p->>'source_pending')::numeric, 0)), next_due = nd.due, next_amount = nd.s,
        last_import_id = p_import_id, last_source_at = now(), resolver_version = coalesce(p->>'resolver_version', resolver_version),
        frequency = case when frequency_source = 'CONFIRMADA' or nparts < 3 then frequency else freq end
      where client_key = p->>'client_key' and comp = p->>'comp';
    else
      insert into public.financing_plans(client_key, client_name, comp, comp_label, frequency, parts, source_pending, next_due, next_amount, last_import_id, last_source_at, resolver_version, created_by)
      values (p->>'client_key', p->>'client_name', p->>'comp', p->>'comp_label', freq, p->'parts', greatest(0, coalesce((p->>'source_pending')::numeric, 0)), nd.due, nd.s, p_import_id, now(), p->>'resolver_version', auth.uid());
    end if;
  end loop;
  return query select * from public.financing_plans where client_key in (select x->>'client_key' from jsonb_array_elements(coalesce(p_plans, '[]')) x);
end; $$;
-- Claves de planes existentes (para enviar la continuidad solo de esos comprobantes)
create or replace function public.financing_plan_keys() returns table (client_key text, comp text) language sql stable security definer set search_path = public as $$
  select client_key, comp from public.financing_plans where public.auth_has_perm('routes.create') or public.auth_has_perm('routes.view_all');
$$;
grant execute on function public.financing_plan_keys() to authenticated;

-- =====================================================================
-- 5 · Reglas Estado/Zona → Transportista (versionadas, auditadas; única fuente en modo online)
-- =====================================================================
create table if not exists public.routing_rules (version int primary key, rules jsonb not null, created_by uuid, created_at timestamptz not null default now());
insert into public.routing_rules(version, rules) values (1, '[
 {"estado":"CRISTIAN","zona":"ESTE","carrier":"CRISTIAN TORRES - ESTE","priority":1,"active":true},
 {"estado":"CRISTIAN","zona":"","carrier":"CRISTIAN TORRES - ALREDEDORES","priority":2,"active":true},
 {"estado":"ALREDEDORES","zona":"","carrier":"CRISTIAN TORRES - ALREDEDORES","priority":3,"active":true},
 {"estado":"GRAN MENDOZA","zona":"","carrier":"CRISTIAN TORRES - ALREDEDORES","priority":4,"active":true},
 {"estado":"ZONA ESTE","zona":"","carrier":"CRISTIAN TORRES - ESTE","priority":5,"active":true},
 {"estado":"UCO","zona":"","carrier":"UCO","priority":6,"active":true},
 {"estado":"VASCA","zona":"","carrier":"VASCA","priority":7,"active":true},
 {"estado":"ANDESMAR","zona":"","carrier":"ANDESMAR","priority":8,"active":true},
 {"estado":"MARCHETTI","zona":"","carrier":"MARCHETTI","priority":9,"active":true}]') on conflict do nothing;
alter table public.routing_rules enable row level security;
create policy routing_rules_read on public.routing_rules for select to authenticated using (public.auth_has_perm('routes.create') or public.auth_has_perm('settings.manage'));
grant select on public.routing_rules to authenticated;
revoke insert, update, delete on public.routing_rules from authenticated, anon;
create or replace function public.set_routing_rules(p_rules jsonb) returns public.routing_rules language plpgsql security definer set search_path = public as $$
declare r public.routing_rules; prev jsonb;
begin
  if not public.auth_has_perm('settings.manage') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if jsonb_typeof(p_rules) <> 'array' then raise exception 'BAD_RULES' using errcode = '22023'; end if;
  if exists (select 1 from jsonb_array_elements(p_rules) x where coalesce(trim(x->>'estado'), '') = '' or coalesce(trim(x->>'carrier'), '') = '') then
    raise exception 'BAD_RULES: cada regla necesita estado y transportista' using errcode = '23514'; end if;
  select rules into prev from public.routing_rules order by version desc limit 1;
  insert into public.routing_rules(version, rules, created_by) values ((select max(version) from public.routing_rules) + 1, p_rules, auth.uid()) returning * into r;
  insert into public.audit_log(actor_id, action, target_type, target_id, before, after) values (auth.uid(), 'ROUTING_RULES_CHANGED', 'settings', 'v' || r.version, prev, p_rules);
  return r;
end; $$;
grant execute on function public.set_routing_rules(jsonb) to authenticated;
