-- =====================================================================
-- OK DESPACHO ONLINE — FASE 2A (incremental): INFORME COMERCIAL CRISTIAN TORRES
-- · Paradas de hoja con resultado (ENTREGADO / ENTREGA_PARCIAL / NO_ENTREGADO / REPROGRAMAR) y tarifa congelada
-- · Costo mensual con vigencias · Configuración de envío · Informes con snapshot inmutable · Emails idempotentes
-- · Permisos y RLS. No modifica migraciones anteriores.
-- =====================================================================

-- ---------- Permisos ----------
insert into public.permissions(code) values ('can_view_commercial_transport_reports'), ('can_manage_commercial_transport_reports') on conflict do nothing;
insert into public.role_permissions(role_code, permission_code) values
  ('ADMIN','can_view_commercial_transport_reports'), ('ADMIN','can_manage_commercial_transport_reports') on conflict do nothing;

-- ---------- Carriers que forman "Cristian Torres" ----------
alter table public.carriers add column if not exists report_group text;
update public.carriers set report_group = 'CRISTIAN_TORRES' where id in ('CT-ESTE','CT-ALR');

-- ---------- Paradas de la hoja (las completa el recorrido en Fase 2B) ----------
create table if not exists public.route_stops (
  id uuid primary key default gen_random_uuid(),
  route_id uuid not null references public.routes(id) on delete restrict,
  seq int not null,
  client_name text not null,
  client_key text,
  zone text not null check (zone in ('ESTE','ALREDEDORES','CENTRO')),
  order_numbers text[] not null default '{}',
  merchandise_amount numeric(14,2) not null default 0,     -- mercadería: NUNCA es ingreso de transporte
  merchandise_collected numeric(14,2) not null default 0,  -- cobranza: NUNCA es ingreso de transporte
  shipping_fee numeric(14,2) not null default 0,           -- tarifa de envío CONGELADA al publicar
  outcome text not null default 'PENDIENTE' check (outcome in ('PENDIENTE','ENTREGADO','ENTREGA_PARCIAL','NO_ENTREGADO','REPROGRAMAR')),
  outcome_at timestamptz,
  created_at timestamptz not null default now(),
  unique (route_id, seq)
);
create index if not exists route_stops_route_idx on public.route_stops(route_id);
create index if not exists routes_completed_idx on public.routes(operational_status, completed_at);

-- ---------- Costo mensual con vigencia histórica ----------
create table if not exists public.transport_cost_settings (
  id bigserial primary key,
  carrier_group text not null,
  monthly_cost numeric(14,2) not null check (monthly_cost > 0),
  valid_from date not null,
  valid_to date,
  created_by uuid,
  created_at timestamptz not null default now(),
  unique (carrier_group, valid_from)
);
insert into public.transport_cost_settings(carrier_group, monthly_cost, valid_from) values ('CRISTIAN_TORRES', 1600000, '2026-01-01')
on conflict do nothing;

-- Nueva vigencia: cierra la anterior el día previo; nunca reescribe períodos pasados ya informados.
create or replace function public.set_transport_cost(p_group text, p_monthly_cost numeric, p_valid_from date, p_by uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' and not public.auth_has_perm('can_manage_commercial_transport_reports') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_monthly_cost <= 0 then raise exception 'BAD_COST' using errcode = '22023'; end if;
  update public.transport_cost_settings set valid_to = p_valid_from - 1
   where carrier_group = p_group and valid_from < p_valid_from and (valid_to is null or valid_to >= p_valid_from);
  insert into public.transport_cost_settings(carrier_group, monthly_cost, valid_from, created_by)
  values (p_group, p_monthly_cost, p_valid_from, p_by)
  on conflict (carrier_group, valid_from) do update set monthly_cost = excluded.monthly_cost, created_by = excluded.created_by;
end; $$;

-- ---------- Configuración de envío del informe ----------
create table if not exists public.report_settings (
  id text primary key,
  recipients text[] not null default '{}',
  weekly_day int not null default 6,          -- sábado
  weekly_time text not null default '15:00',  -- America/Argentina/Mendoza
  monthly_time text not null default '23:30', -- último día del mes calendario
  require_pdf boolean not null default true,
  timezone text not null default 'America/Argentina/Mendoza'
);
insert into public.report_settings(id) values ('CRISTIAN_TORRES') on conflict do nothing;

-- ---------- Informes (snapshot inmutable) ----------
create table if not exists public.commercial_reports (
  id uuid primary key default gen_random_uuid(),
  report_type text not null check (report_type in ('WEEKLY','MONTHLY','MANUAL')),
  period_start date not null,
  period_end date not null,
  version int not null default 1,
  generated_at timestamptz not null default now(),
  generated_by uuid,
  snapshot jsonb not null,
  pdf_status text not null default 'PENDING' check (pdf_status in ('PENDING','OK','PDF_ERROR')),
  pdf_path text,
  pdf_error text,
  unique (report_type, period_start, period_end, version)
);
-- El snapshot no se modifica nunca (histórico fiel aunque cambien costos o tarifas)
create or replace function public.trg_report_snapshot_immutable()
returns trigger language plpgsql as $$
begin
  if new.snapshot is distinct from old.snapshot or new.period_start is distinct from old.period_start
     or new.period_end is distinct from old.period_end or new.report_type is distinct from old.report_type or new.version is distinct from old.version then
    raise exception 'SNAPSHOT_INMUTABLE: un informe generado no se recalcula; generá una versión nueva' using errcode = '23514';
  end if;
  return new;
end; $$;
drop trigger if exists report_snapshot_immutable on public.commercial_reports;
create trigger report_snapshot_immutable before update on public.commercial_reports for each row execute function public.trg_report_snapshot_immutable();

-- ---------- Emails (idempotentes) ----------
create table if not exists public.report_emails (
  id uuid primary key default gen_random_uuid(),
  report_id uuid not null references public.commercial_reports(id) on delete restrict,
  recipient text not null,
  idempotency_key text not null unique,  -- report_type|period_start|period_end|recipient|vN[|reenvio-n]
  is_resend boolean not null default false,
  status text not null default 'QUEUED' check (status in ('QUEUED','SENT','ERROR','PDF_ERROR')),
  queued_at timestamptz not null default now(),
  sent_at timestamptz,
  provider_id text,
  error text,
  retry_count int not null default 0
);

-- =====================================================================
-- RLS: solo quien tiene permiso ve costos, informes y emails
-- =====================================================================
alter table public.route_stops enable row level security;
alter table public.transport_cost_settings enable row level security;
alter table public.report_settings enable row level security;
alter table public.commercial_reports enable row level security;
alter table public.report_emails enable row level security;

create policy route_stops_read on public.route_stops for select to authenticated
  using (exists (select 1 from public.routes r where r.id = route_id and (public.auth_has_perm('routes.view_all') or (r.responsable_id = auth.uid() and public.auth_has_perm('routes.view_assigned')))));
create policy cost_read on public.transport_cost_settings for select to authenticated
  using (public.auth_has_perm('can_view_commercial_transport_reports') or public.auth_has_perm('can_manage_commercial_transport_reports'));
create policy report_settings_read on public.report_settings for select to authenticated
  using (public.auth_has_perm('can_manage_commercial_transport_reports'));
create policy reports_read on public.commercial_reports for select to authenticated
  using (public.auth_has_perm('can_view_commercial_transport_reports') or public.auth_has_perm('can_manage_commercial_transport_reports'));
create policy report_emails_read on public.report_emails for select to authenticated
  using (public.auth_has_perm('can_manage_commercial_transport_reports'));

grant select on public.route_stops, public.transport_cost_settings, public.report_settings, public.commercial_reports, public.report_emails to authenticated;
revoke execute on function public.set_transport_cost(text, numeric, date, uuid) from public, anon;
grant execute on function public.set_transport_cost(text, numeric, date, uuid) to authenticated, service_role;
-- Escritura de informes, emails y paradas: solo el servidor (service_role / Edge Functions)
