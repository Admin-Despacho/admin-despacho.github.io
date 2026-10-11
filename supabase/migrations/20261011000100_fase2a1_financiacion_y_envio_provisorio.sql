-- OK DESPACHO ONLINE — FASE 2A.1 (incremental): financiación propia, envío provisorio y confirmación server-side.

-- ---------- Importaciones fuente ----------
create table if not exists public.source_imports (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('PEDIDOS','SALDO_COMPROBANTE','CUENTA_CORRIENTE')),
  file_name text not null, file_hash text, rows int, imported_by uuid, imported_at timestamptz not null default now()
);

-- ---------- Financiación propia: grupos y partes (por comprobante + cliente + importación) ----------
create table if not exists public.financial_document_groups (
  id uuid primary key default gen_random_uuid(),
  source_import_id uuid not null references public.source_imports(id),
  comp_normalized text not null, client_key text not null, client_name text, client_cuit text,
  classification text not null check (classification in ('NORMAL','FINANCIACION_PROPIA_VIGENTE','FINANCIACION_PROPIA_SALDADA','POSIBLE_FINANCIACION_REVISAR')),
  parts_count int not null, pending_count int, settled_count int, duplicates int not null default 0,
  total_pending numeric(14,2), resolver_version text not null,
  created_at timestamptz not null default now(),
  unique (source_import_id, comp_normalized, client_key)
);
create table if not exists public.financial_document_parts (
  id bigserial primary key,
  group_id uuid not null references public.financial_document_groups(id) on delete cascade,
  due_date date, installment text, issue_date date, original_amount numeric(14,2), pending_amount numeric(14,2)
);
-- Suma de saldos pendientes de partes válidas; REVISAR no suma (NULL)
create or replace function public.trg_fin_group_check() returns trigger language plpgsql as $$
begin
  if new.classification = 'POSIBLE_FINANCIACION_REVISAR' and new.total_pending is not null then
    raise exception 'FIN_REVISAR_NO_SUMA: una posible financiación sin distinguir no se suma' using errcode = '23514';
  end if;
  if new.classification = 'FINANCIACION_PROPIA_SALDADA' and coalesce(new.total_pending, 0) > 0 then
    raise exception 'FIN_SALDADA_CON_SALDO' using errcode = '23514';
  end if;
  return new;
end; $$;
drop trigger if exists fin_group_check on public.financial_document_groups;
create trigger fin_group_check before insert or update on public.financial_document_groups for each row execute function public.trg_fin_group_check();

-- ---------- Snapshot del grupo financiero al publicar (una hoja histórica no cambia con un Excel posterior) ----------
create table if not exists public.route_financing_snapshots (
  id bigserial primary key,
  route_id uuid not null references public.routes(id),
  route_version int not null,
  comp text not null, client_name text, client_cuit text,
  parts_count int, parts jsonb not null, total numeric(14,2), classification text not null,
  source_import_id uuid, resolver_version text not null,
  created_at timestamptz not null default now(),
  unique (route_id, route_version, comp)
);
create or replace function public.trg_snapshot_immutable_generic() returns trigger language plpgsql as $$
begin raise exception 'SNAPSHOT_INMUTABLE' using errcode = '23514'; end; $$;
drop trigger if exists route_financing_snapshot_immutable on public.route_financing_snapshots;
create trigger route_financing_snapshot_immutable before update on public.route_financing_snapshots for each row execute function public.trg_snapshot_immutable_generic();

-- ---------- Confirmación de costo de envío provisorio ----------
create table if not exists public.shipping_amount_confirmations (
  id uuid primary key default gen_random_uuid(),
  sheet_key text not null,                 -- hoja (borrador) hasta que se publique
  route_id uuid references public.routes(id), route_version int,
  ship_order text not null, ship_doc text, main_order text, carrier_id text,
  source_import_id text, fingerprint text not null,
  detected_amount numeric(14,2) not null check (detected_amount > 0),
  confirmed_amount numeric(14,2),
  source text not null default 'INFORME_PEDIDOS',
  status text not null default 'PENDING_CONFIRMATION'
    check (status in ('PENDING_CONFIRMATION','CONFIRMED','MODIFIED_CONFIRMED','INVALIDATED','RESOLVED_BY_SALDO','DIFFERENCE_REVIEW')),
  confirmed_by uuid, confirmed_at timestamptz, reason text, note text,
  created_at timestamptz not null default now()
);
-- Una sola confirmación activa por hoja y pedido de envío
create unique index if not exists shipping_conf_active on public.shipping_amount_confirmations(sheet_key, ship_order) where status <> 'INVALIDATED';

create or replace function public.confirm_shipping_amount(p jsonb)
returns public.shipping_amount_confirmations language plpgsql security definer set search_path = public as $$
declare cur public.shipping_amount_confirmations; det numeric := (p->>'detected_amount')::numeric; amt numeric := (p->>'confirmed_amount')::numeric;
        changed boolean; res public.shipping_amount_confirmations;
begin
  if not public.auth_has_perm('routes.create') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if amt is null or amt <= 0 or det is null or det <= 0 then raise exception 'BAD_AMOUNT' using errcode = '22023'; end if;
  changed := abs(amt - det) > 0.004;
  if changed and coalesce(trim(p->>'reason'), '') = '' then raise exception 'REASON_REQUIRED: para cambiar el importe hay que indicar el motivo' using errcode = '23514'; end if;
  select * into cur from public.shipping_amount_confirmations where sheet_key = p->>'sheet_key' and ship_order = p->>'ship_order' and status <> 'INVALIDATED' for update;
  -- Doble clic / reintento: misma confirmación → no se duplica
  if found and cur.fingerprint = p->>'fingerprint' and cur.confirmed_amount = amt and cur.status in ('CONFIRMED','MODIFIED_CONFIRMED') then return cur; end if;
  if found then update public.shipping_amount_confirmations set status = 'INVALIDATED' where id = cur.id; end if;
  insert into public.shipping_amount_confirmations(sheet_key, route_id, route_version, ship_order, ship_doc, main_order, carrier_id, source_import_id, fingerprint,
    detected_amount, confirmed_amount, status, confirmed_by, confirmed_at, reason, note)
  values (p->>'sheet_key', nullif(p->>'route_id','')::uuid, nullif(p->>'route_version','')::int, p->>'ship_order', p->>'ship_doc', p->>'main_order', p->>'carrier_id',
    p->>'source_import_id', p->>'fingerprint', det, amt, case when changed then 'MODIFIED_CONFIRMED' else 'CONFIRMED' end, auth.uid(), now(),
    case when changed then p->>'reason' end, p->>'note')
  returning * into res;
  insert into public.audit_log(actor_id, action, target_type, target_id, before, after)
  values (auth.uid(), case when changed then 'SHIPPING_AMOUNT_MODIFIED' else 'SHIPPING_AMOUNT_CONFIRMED' end, 'shipping', res.id::text,
    jsonb_build_object('amount', det), jsonb_build_object('amount', amt, 'reason', p->>'reason', 'ship_order', p->>'ship_order'));
  return res;
end; $$;

-- Si cambia NDP, pedido, costo, asociación, transportista o importación: la confirmación deja de valer
create or replace function public.invalidate_shipping_confirmation(p_sheet_key text, p_ship_order text, p_fingerprint text)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.auth_has_perm('routes.create') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  update public.shipping_amount_confirmations set status = 'INVALIDATED'
   where sheet_key = p_sheet_key and ship_order = p_ship_order and status <> 'INVALIDATED' and fingerprint <> p_fingerprint;
  get diagnostics n = row_count; return n;
end; $$;

-- La NDP real apareció: si coincide se resuelve; si difiere queda para revisar (no se pisa)
create or replace function public.reconcile_shipping_with_saldo(p_id uuid, p_saldo numeric, p_tolerance numeric default 1)
returns text language plpgsql security definer set search_path = public as $$
declare cur public.shipping_amount_confirmations; ref numeric;
begin
  if not public.auth_has_perm('routes.create') and coalesce(auth.role(),'') <> 'service_role' then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into cur from public.shipping_amount_confirmations where id = p_id for update;
  ref := coalesce(cur.confirmed_amount, cur.detected_amount);
  update public.shipping_amount_confirmations set status = case when abs(p_saldo - ref) <= p_tolerance then 'RESOLVED_BY_SALDO' else 'DIFFERENCE_REVIEW' end
   where id = p_id;
  return case when abs(p_saldo - ref) <= p_tolerance then 'RESOLVED_BY_SALDO' else 'DIFFERENCE_REVIEW' end;
end; $$;

-- Puerta para PUBLICAR (Fase 2B): no se publica con envíos pendientes o en diferencia
create or replace function public.assert_sheet_shipping_ready(p_sheet_key text, p_ship_orders text[])
returns void language plpgsql stable security definer set search_path = public as $$
declare missing text;
begin
  select string_agg(o, ', ') into missing from unnest(p_ship_orders) o
   where not exists (select 1 from public.shipping_amount_confirmations c where c.sheet_key = p_sheet_key and c.ship_order = o and c.status in ('CONFIRMED','MODIFIED_CONFIRMED','RESOLVED_BY_SALDO'));
  if missing is not null then raise exception 'SHIPPING_PENDING: envíos sin confirmar: %', missing using errcode = '23514'; end if;
end; $$;

-- ---------- Informe: la tarifa congelada nunca puede ser un provisorio sin confirmar ----------
alter table public.route_stops add column if not exists shipping_fee_source text not null default 'SALDO'
  check (shipping_fee_source in ('SALDO','CONFIRMED_FALLBACK'));

-- ---------- RLS ----------
alter table public.source_imports enable row level security;
alter table public.financial_document_groups enable row level security;
alter table public.financial_document_parts enable row level security;
alter table public.route_financing_snapshots enable row level security;
alter table public.shipping_amount_confirmations enable row level security;
create policy source_imports_read on public.source_imports for select to authenticated using (public.auth_has_perm('routes.create') or public.auth_has_perm('routes.view_all'));
create policy fin_groups_read on public.financial_document_groups for select to authenticated using (public.auth_has_perm('routes.create') or public.auth_has_perm('routes.view_all'));
create policy fin_parts_read on public.financial_document_parts for select to authenticated using (public.auth_has_perm('routes.create') or public.auth_has_perm('routes.view_all'));
create policy fin_snap_read on public.route_financing_snapshots for select to authenticated using (public.auth_has_perm('routes.view_all'));
create policy ship_conf_read on public.shipping_amount_confirmations for select to authenticated using (public.auth_has_perm('routes.create') or public.auth_has_perm('routes.view_all'));
grant select on public.source_imports, public.financial_document_groups, public.financial_document_parts, public.route_financing_snapshots, public.shipping_amount_confirmations to authenticated;
revoke execute on function public.confirm_shipping_amount(jsonb), public.invalidate_shipping_confirmation(text, text, text), public.reconcile_shipping_with_saldo(uuid, numeric, numeric), public.assert_sheet_shipping_ready(text, text[]) from public, anon;
grant execute on function public.confirm_shipping_amount(jsonb), public.invalidate_shipping_confirmation(text, text, text), public.reconcile_shipping_with_saldo(uuid, numeric, numeric), public.assert_sheet_shipping_ready(text, text[]) to authenticated, service_role;
