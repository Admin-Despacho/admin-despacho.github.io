alter table public.report_settings
  add column if not exists schedule_mode text not null default 'WEEKLY',
  add column if not exists biweekly_day_1 integer not null default 1,
  add column if not exists biweekly_day_2 integer not null default 15,
  add column if not exists biweekly_time text not null default '15:00';

alter table public.report_settings drop constraint if exists report_settings_schedule_mode_check;
alter table public.report_settings
  add constraint report_settings_schedule_mode_check
  check (schedule_mode in ('OFF','WEEKLY','BIWEEKLY','MONTHLY'));

alter table public.report_settings drop constraint if exists report_settings_biweekly_days_check;
alter table public.report_settings
  add constraint report_settings_biweekly_days_check
  check (biweekly_day_1 between 1 and 28 and biweekly_day_2 between 1 and 28 and biweekly_day_1 < biweekly_day_2);

alter table public.commercial_reports drop constraint if exists commercial_reports_report_type_check;
alter table public.commercial_reports
  add constraint commercial_reports_report_type_check
  check (report_type in ('WEEKLY','BIWEEKLY','MONTHLY','MANUAL'));
