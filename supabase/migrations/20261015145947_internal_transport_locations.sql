-- G2 · Ubicaciones para Transportista Interno
create table if not exists public.internal_locations (
  location_key text primary key,
  name text not null,
  address text,
  lat double precision not null,
  lon double precision not null,
  radius_m integer not null default 200 check (radius_m > 0),
  active boolean not null default true,
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint internal_locations_lat check (abs(lat) <= 90),
  constraint internal_locations_lon check (abs(lon) <= 180)
);
alter table public.internal_locations enable row level security;
drop policy if exists internal_locations_admin_read on public.internal_locations;
create policy internal_locations_admin_read on public.internal_locations for select to authenticated
using (public.auth_has_perm('settings.manage') or public.auth_has_perm('locations.manage'));
grant select on public.internal_locations to authenticated;

alter table public.route_stops add column if not exists internal_location_key text references public.internal_locations(location_key);
create index if not exists route_stops_internal_location_idx on public.route_stops(internal_location_key);

create or replace function public.upsert_internal_location(p jsonb) returns public.internal_locations
language plpgsql security definer set search_path=public as $$
declare l public.internal_locations;
begin
  if not (public.auth_has_perm('settings.manage') or public.auth_has_perm('locations.manage')) then raise exception 'FORBIDDEN' using errcode='42501'; end if;
  if coalesce(trim(p->>'location_key'),'')='' or coalesce(trim(p->>'name'),'')='' or (p->>'lat') is null or (p->>'lon') is null then raise exception 'BAD_LOCATION: completá clave, nombre y coordenadas' using errcode='23514'; end if;
  if abs((p->>'lat')::float8)>90 or abs((p->>'lon')::float8)>180 then raise exception 'BAD_LOCATION: coordenadas inválidas' using errcode='23514'; end if;
  insert into public.internal_locations(location_key,name,address,lat,lon,radius_m,active,note,updated_at)
  values (upper(trim(p->>'location_key')),trim(p->>'name'),nullif(trim(p->>'address'),''),(p->>'lat')::float8,(p->>'lon')::float8,greatest(coalesce((p->>'radius_m')::int,200),1),coalesce((p->>'active')::boolean,true),nullif(trim(p->>'note'),''),now())
  on conflict(location_key) do update set name=excluded.name,address=excluded.address,lat=excluded.lat,lon=excluded.lon,radius_m=excluded.radius_m,active=excluded.active,note=excluded.note,updated_at=now()
  returning * into l;
  insert into public.audit_log(actor_id,action,target_type,target_id,after) values(auth.uid(),'INTERNAL_LOCATION_SAVED','internal_location',l.location_key,to_jsonb(l));
  return l;
end $$;
grant execute on function public.upsert_internal_location(jsonb) to authenticated,service_role;

create or replace function public._match_internal_location(st public.route_stops) returns text
language plpgsql stable security definer set search_path=public as $$
declare k text;
begin
  if st.internal_location_key is not null then select location_key into k from public.internal_locations where location_key=st.internal_location_key and active; if found then return k; end if; end if;
  if st.client_key is not null then select location_key into k from public.internal_locations where active and upper(location_key)=upper(trim(st.client_key)) limit 1; if found then return k; end if; end if;
  select location_key into k from public.internal_locations
  where active and (lower(trim(name))=lower(trim(st.client_name)) or (coalesce(trim(address),'')<>'' and coalesce(trim(st.address),'')<>'' and lower(regexp_replace(trim(address),'\\s+',' ','g'))=lower(regexp_replace(trim(st.address),'\\s+',' ','g'))))
  order by case when lower(trim(name))=lower(trim(st.client_name)) then 0 else 1 end limit 1;
  return k;
end $$;
revoke execute on function public._match_internal_location(public.route_stops) from public,anon,authenticated;

create or replace function public._loc(p jsonb, st public.route_stops) returns jsonb
language plpgsql stable security definer set search_path=public as $$
declare cm public.client_locations; im public.internal_locations; d double precision; is_internal boolean:=false; ik text; radius int; expected_lat double precision; expected_lon double precision; source text;
begin
  if p is null then raise exception 'LOCATION_REQUIRED: registrá la ubicación o indicá por qué no se pudo' using errcode='23514'; end if;
  if p ? 'lat' and p ? 'lon' then
    select exists(select 1 from public.routes r join public.carriers c on c.id=r.carrier_id where r.id=st.route_id and c.kind='INTERNO') into is_internal;
    if is_internal then ik:=public._match_internal_location(st); if ik is not null then select * into im from public.internal_locations where location_key=ik and active; if found then expected_lat:=im.lat; expected_lon:=im.lon; radius:=im.radius_m; source:='INTERNAL'; end if; end if; end if;
    if expected_lat is null and st.client_key is not null then select * into cm from public.client_locations where client_key=st.client_key and active; if found then expected_lat:=cm.lat; expected_lon:=cm.lon; radius:=cm.radius_m; source:='CLIENT'; end if; end if;
    if expected_lat is not null then d:=public._dist_m(expected_lat,expected_lon,(p->>'lat')::float8,(p->>'lon')::float8); end if;
    return jsonb_build_object('lat',(p->>'lat')::float8,'lon',(p->>'lon')::float8,'accuracy',nullif(p->>'accuracy','')::float8,'at',now(),'validation_source',source,'validation_key',case when source='INTERNAL' then ik else st.client_key end,'distance_m',case when d is not null then round(d) end,'radius_m',radius,'outside_m',case when d is not null and radius is not null and d>radius then round(d) end);
  end if;
  if coalesce(trim(p->>'missing_reason'),'')='' then raise exception 'LOCATION_REASON_REQUIRED: sin ubicación hay que indicar el motivo' using errcode='23514'; end if;
  return jsonb_build_object('missing_reason',trim(p->>'missing_reason'),'at',now());
end $$;
revoke execute on function public._loc(jsonb,public.route_stops) from public,anon,authenticated;

create or replace function public._assign_internal_location() returns trigger
language plpgsql security definer set search_path=public as $$
declare is_internal boolean; k text;
begin
  if new.internal_location_key is not null then return new; end if;
  select exists(select 1 from public.routes r join public.carriers c on c.id=r.carrier_id where r.id=new.route_id and c.kind='INTERNO') into is_internal;
  if not is_internal then return new; end if;
  if new.client_key is not null then select location_key into k from public.internal_locations where active and upper(location_key)=upper(trim(new.client_key)) limit 1; end if;
  if k is null then select location_key into k from public.internal_locations where active and (lower(trim(name))=lower(trim(new.client_name)) or (coalesce(trim(address),'')<>'' and coalesce(trim(new.address),'')<>'' and lower(regexp_replace(trim(address),'\\s+',' ','g'))=lower(regexp_replace(trim(new.address),'\\s+',' ','g')))) order by case when lower(trim(name))=lower(trim(new.client_name)) then 0 else 1 end limit 1; end if;
  new.internal_location_key:=k; return new;
end $$;
drop trigger if exists trg_assign_internal_location on public.route_stops;
create trigger trg_assign_internal_location before insert or update of client_key,client_name,address,route_id,internal_location_key on public.route_stops for each row execute function public._assign_internal_location();
revoke execute on function public._assign_internal_location() from public,anon,authenticated;
