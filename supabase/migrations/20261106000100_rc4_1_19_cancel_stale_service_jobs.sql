alter table public.vehicle_service_email_jobs
  drop constraint if exists vehicle_service_email_jobs_status_check;

alter table public.vehicle_service_email_jobs
  add constraint vehicle_service_email_jobs_status_check
  check (status = any (array['QUEUED'::text,'SENT'::text,'ERROR'::text,'CANCELLED'::text]));
