-- At commit the complete set of published stops and their linked emails is available.
create function public.cristian_publication_emails() returns trigger
language plpgsql security definer set search_path=public,pg_temp as $$
begin
  insert into public.customer_email_jobs(route_id, stop_id, kind, recipient, idempotency_key)
  select r.id, s.id, 'ON_THE_WAY', lower(trim(s.customer_email)), r.id||'|'||s.id||'|ON_THE_WAY'
  from public.routes r
  join public.carriers c on c.id=r.carrier_id
  join public.route_stops s on s.route_id=r.id
  where r.id=new.id and r.operational_status='PUBLICADA'
    and c.kind='EXTERNO' and c.id in ('CT-ESTE','CT-ALR')
    and s.outcome='PENDIENTE' and coalesce(s.stop_type,'PEDIDO')='PEDIDO'
    and s.customer_email is not null and public.is_valid_email(s.customer_email)
    and exists(select 1 from public.notification_settings where id='DEFAULT' and on_the_way_enabled)
  on conflict(idempotency_key) do nothing;
  return null;
end $$;
revoke all on function public.cristian_publication_emails() from public,anon,authenticated;
create constraint trigger cristian_publication_emails after insert on public.routes
deferrable initially deferred for each row
when (new.operational_status='PUBLICADA' and new.carrier_id in ('CT-ALR','CT-ESTE'))
execute function public.cristian_publication_emails();

-- Protect internal transfer/task stops even if another workflow requests customer mail.
create function public.skip_internal_transfer_customer_mail() returns trigger
language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if exists(select 1 from public.route_stops s join public.routes r on r.id=s.route_id
    join public.carriers c on c.id=r.carrier_id where s.id=new.stop_id
    and c.kind='INTERNO' and s.stop_type in ('UBICACION_INTERNA','TAREA')) then
    return null;
  end if;
  return new;
end $$;
revoke all on function public.skip_internal_transfer_customer_mail() from public,anon,authenticated;
create trigger skip_internal_transfer_customer_mail before insert on public.customer_email_jobs
for each row execute function public.skip_internal_transfer_customer_mail();
