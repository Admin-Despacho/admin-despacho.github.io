alter table public.notification_settings
  add column if not exists service_email_enabled boolean not null default false,
  add column if not exists service_warning_km integer not null default 1000,
  add column if not exists service_repeat_km integer not null default 500,
  add column if not exists service_email_recipients text[] not null default '{}'::text[],
  add column if not exists service_copy_admin boolean not null default true,
  add column if not exists service_copy_driver boolean not null default false;

alter table public.notification_settings drop constraint if exists notification_settings_service_km_check;
alter table public.notification_settings
  add constraint notification_settings_service_km_check
  check (service_warning_km >= 0 and service_repeat_km >= 1);

create table if not exists public.vehicle_service_email_jobs (
  id uuid primary key default gen_random_uuid(),
  vehicle_id uuid not null references public.vehicles(id) on delete cascade,
  cycle_base_km numeric not null,
  alert_level text not null check (alert_level in ('UPCOMING','REQUIRED')),
  alert_bucket integer not null default 0,
  recipient text not null,
  idempotency_key text not null unique,
  status text not null default 'QUEUED' check (status in ('QUEUED','SENT','ERROR')),
  queued_at timestamptz not null default now(),
  sent_at timestamptz,
  provider_id text,
  error text,
  retry_count integer not null default 0
);

create index if not exists vehicle_service_email_jobs_status_idx
  on public.vehicle_service_email_jobs(status, queued_at);

alter table public.vehicle_service_email_jobs enable row level security;
revoke all on public.vehicle_service_email_jobs from anon, authenticated;
grant select on public.vehicle_service_email_jobs to authenticated;
grant all on public.vehicle_service_email_jobs to service_role;

drop policy if exists vehicle_service_email_jobs_admin_read on public.vehicle_service_email_jobs;
create policy vehicle_service_email_jobs_admin_read
on public.vehicle_service_email_jobs for select
to authenticated
using (public.user_has_perm(auth.uid(), 'settings.manage'));
