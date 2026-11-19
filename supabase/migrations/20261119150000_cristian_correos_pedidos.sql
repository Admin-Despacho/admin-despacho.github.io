-- Solo nuevas hojas publicadas con el importador de renglones.
alter table public.routes add column customer_receipt_v1 boolean not null default false;
create function public.mark_customer_receipt_route() returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
  new.customer_receipt_v1 := coalesce(new.carrier_id in ('CT-ESTE','CT-ALR'),false) and coalesce(new.sheet_snapshot->>'customer_receipt_version','')='1';
  return new;
end $$;
create trigger customer_receipt_route before insert on public.routes for each row execute function public.mark_customer_receipt_route();

-- La misma clave que el aviso individual evita repetirlo al avanzar de parada.
create function public.cristian_departure_emails() returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if new.customer_receipt_v1 and new.carrier_id in ('CT-ESTE','CT-ALR') and old.started_at is null and new.started_at is not null
     and exists(select 1 from public.notification_settings where id='DEFAULT' and on_the_way_enabled) then
    insert into public.customer_email_jobs(route_id,stop_id,kind,recipient,idempotency_key)
    select new.id,s.id,'ON_THE_WAY',e.email,new.id||'|'||s.id||'|ON_THE_WAY'
    from public.route_stops s cross join lateral (select lower(trim(coalesce(nullif(trim(s.customer_email),''),public._client_email_for(s.client_key,s.client_name)))) email) e
    where s.route_id=new.id and s.outcome='PENDIENTE' and coalesce(s.stop_type,'PEDIDO')='PEDIDO' and public.is_valid_email(e.email) and e.email is not null
    on conflict(idempotency_key) do nothing;
  end if;
  return new;
end $$;
revoke all on function public.cristian_departure_emails() from public,anon,authenticated;
create trigger cristian_departure_emails after update of started_at on public.routes for each row execute function public.cristian_departure_emails();

-- Conserva íntegros el control de sesión, evidencia, firma e idempotencia de la función desplegada.
do $migration$
declare f regprocedure; d text; needle text; ins text;
begin
  select oid::regprocedure into strict f from pg_proc where proname='set_stop_outcome' and pronamespace='public'::regnamespace;
  d:=pg_get_functiondef(f);
  if md5(d)<>'06c5a4de044daf22746a2648441a14ce' then raise exception 'set_stop_outcome cambió'; end if;
  needle:='    if v_commercial and p_outcome = ''ENTREGADO'' and v_email is not null then';
  ins:=$body$    if v_commercial and p_outcome='ENTREGADO' and r.customer_receipt_v1 and r.carrier_id in ('CT-ESTE','CT-ALR') then
      if exists(select 1 from public.notification_settings where id='DEFAULT' and delivered_enabled) then
        v_email := lower(trim(coalesce(v_email,nullif(trim(st.customer_email),''),public._client_email_for(st.client_key,st.client_name))));
        if v_email is not null and public.is_valid_email(v_email) then
          perform public._create_delivery_receipt(st,r,trim(ev->>'receiver_name'),v_email);
        end if;
      end if;
      v_receipt:=true; -- Ya se resolvió el único aviso de entrega total.
    elsif v_commercial and p_outcome = 'ENTREGADO' and v_email is not null then$body$;
  if strpos(d,needle)=0 then raise exception 'No se encontró rama de entrega'; end if;
  d:=replace(d,needle,ins);
  needle:='    if v_commercial and coalesce(trim(st.customer_email), '''') <> '''' and not v_receipt then';
  ins:=$body$    if v_commercial and p_outcome='ENTREGA_PARCIAL' and r.customer_receipt_v1 and r.carrier_id in ('CT-ESTE','CT-ALR') then
      v_email := lower(trim(coalesce(v_email,nullif(trim(st.customer_email),''),public._client_email_for(st.client_key,st.client_name))));
      if v_email is not null and public.is_valid_email(v_email) and exists(select 1 from public.notification_settings where id='DEFAULT' and delivered_enabled) then
        insert into public.customer_email_jobs(route_id,stop_id,kind,recipient,idempotency_key)
        values(r.id,st.id,'PARTIAL',v_email,r.id||'|'||st.id||'|PARTIAL') on conflict(idempotency_key) do nothing;
      end if;
    elsif v_commercial and coalesce(trim(st.customer_email), '') <> '' and not v_receipt then$body$;
  if strpos(d,needle)=0 then raise exception 'No se encontró rama de entrega parcial'; end if;
  execute replace(d,needle,ins);
  select oid::regprocedure into strict f from pg_proc where proname='_create_delivery_receipt' and pronamespace='public'::regnamespace;
  d:=pg_get_functiondef(f);
  if md5(d)<>'296c2c4c946de98ce10f15d508e0b1a1' then raise exception 'La plantilla del comprobante cambió'; end if;
  needle:='  insert into public.delivery_receipts(';
  ins:=$body$  if r.customer_receipt_v1 and r.carrier_id in ('CT-ESTE','CT-ALR') then
    declare source_stop jsonb; lines jsonb; orders jsonb;
    begin
      select x into source_stop from jsonb_array_elements(r.sheet_snapshot->'stops') x
       where x->>'client_key'=st.client_key and x->>'client_name'=st.client_name
       and array(select jsonb_array_elements_text(x->'order_numbers'))=st.order_numbers::text[] limit 1;
      select coalesce(jsonb_agg(value),'[]') into orders from jsonb_array_elements_text(to_jsonb(st.order_numbers))
       where value is distinct from source_stop->>'ship_order';
      select coalesce(jsonb_agg(x order by n),'[]') into lines
       from jsonb_array_elements(case when jsonb_typeof(source_stop->'merchandise')='array' then source_stop->'merchandise' else '[]'::jsonb end) with ordinality as t(x,n)
       where orders ? (x->>'order') and nullif(trim(x->>'description'),'') is not null;
      snap:=snap||jsonb_build_object('customer_receipt_version',1,'merchandise',lines,'merchandise_orders',orders,'bultos',st.bultos,
        'driver_name',(select full_name from public.profiles where id=r.responsable_id));
    end;
  end if;
$body$;
  if strpos(d,needle)=0 then raise exception 'No se encontró instantánea'; end if;
  execute replace(d,needle,ins||needle);
end $migration$;
