alter table public.route_stops add column if not exists stop_type text not null default 'PEDIDO';
alter table public.route_stops add column if not exists instructions text;
alter table public.route_stops add column if not exists contact_name text;
alter table public.route_stops add column if not exists contact_phone text;
do $$ begin
  if not exists (select 1 from pg_constraint where conrelid='public.route_stops'::regclass and conname='route_stops_stop_type_check') then
    alter table public.route_stops add constraint route_stops_stop_type_check check (stop_type in ('PEDIDO','UBICACION_INTERNA','TAREA'));
  end if;
end $$;
create or replace function public._fill_stop_metadata_from_snapshot() returns trigger
language plpgsql security definer set search_path=public as $$
declare s jsonb;
begin
  select sheet_snapshot->'stops'->(new.seq-1) into s from public.routes where id=new.route_id;
  if s is not null then
    new.stop_type:=coalesce(nullif(s->>'stop_type',''),new.stop_type,'PEDIDO');
    new.instructions:=nullif(s->>'instructions','');
    new.contact_name:=nullif(s->>'contact_name','');
    new.contact_phone:=nullif(s->>'contact_phone','');
    if coalesce(s->>'internal_location_key','')<>'' then new.internal_location_key:=s->>'internal_location_key'; end if;
  end if;
  return new;
end $$;
drop trigger if exists trg_fill_stop_metadata_from_snapshot on public.route_stops;
create trigger trg_fill_stop_metadata_from_snapshot before insert on public.route_stops for each row execute function public._fill_stop_metadata_from_snapshot();
revoke execute on function public._fill_stop_metadata_from_snapshot() from public,anon,authenticated;
