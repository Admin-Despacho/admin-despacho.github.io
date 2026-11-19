create or replace function public._com_month_covered(p_month date)
returns boolean language sql stable security definer set search_path to 'public' as $$
  with settings as (
    select coverage_gap_days, kpi_source_verified from public.com_settings where id = 'DEFAULT'
  ), bounds as (
    select p_month as first_day, (p_month + interval '1 month' - interval '1 day')::date as last_day
  ), uploads as (
    select distinct (at at time zone 'America/Argentina/Mendoza')::date as day
    from public.com_ingests where kind = 'SC' and status = 'OK'
  )
  select (s.kpi_source_verified is true and exists (
    select 1 from public.com_ingests i
    where i.kind = 'SC' and i.status = 'OK' and i.date_min <= b.first_day and i.date_max >= b.last_day
  )) or coalesce((
    select min(day) <= b.first_day + s.coverage_gap_days and max(day) >= b.last_day
       and coalesce(max(gap),0) <= s.coverage_gap_days
    from (
      select day, lead(day) over(order by day) - day as gap
      from uploads where day between b.first_day - s.coverage_gap_days and b.last_day + s.coverage_gap_days
    ) daily
  ), false)
  from settings s cross join bounds b;
$$;
