-- La vinculación al padrón pertenece al servidor, incluso si la PWA publica desde caché.
create or replace function public.mark_customer_receipt_route() returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
  new.customer_receipt_v1 := coalesce(new.carrier_id in ('CT-ESTE','CT-ALR'),false);
  return new;
end $$;
create function public.cristian_stop_customer_email() returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if coalesce(new.stop_type,'PEDIDO')='PEDIDO' and nullif(trim(new.customer_email),'') is null
     and exists(select 1 from public.routes where id=new.route_id and customer_receipt_v1 and carrier_id in ('CT-ESTE','CT-ALR')) then
    new.customer_email := public._client_email_for(new.client_key,new.client_name);
  end if;
  return new;
end $$;
revoke all on function public.cristian_stop_customer_email() from public,anon,authenticated;
create trigger cristian_stop_email before insert on public.route_stops for each row execute function public.cristian_stop_customer_email();
-- Regularizar exclusivamente la hoja solicitada mientras siga pendiente de salida.
do $$
declare rid uuid;
begin
 select id into rid from public.routes where number='01-000034' and carrier_id='CT-ALR' and operational_status='PUBLICADA' and started_at is null for update;
 if rid is not null then
   update public.routes set customer_receipt_v1=true where id=rid;
   update public.route_stops s set customer_email=public._client_email_for(s.client_key,s.client_name)
    where s.route_id=rid and s.outcome='PENDIENTE' and coalesce(s.stop_type,'PEDIDO')='PEDIDO' and nullif(trim(s.customer_email),'') is null;
 end if;
end $$;

-- Recuperar renglones de hojas pendientes desde el informe disponible en el constructor de su publicador.
create function public.sync_pending_receipt_items(p_rows jsonb default null) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare r record; st jsonb; idx int; items jsonb; ord text; changed int:=0; pending jsonb:='[]'; input jsonb; snapshot jsonb;
begin
 if not public.auth_has_perm('routes.publish') then raise exception 'FORBIDDEN' using errcode='42501'; end if;
 if p_rows is not null and jsonb_typeof(p_rows)<>'object' then raise exception 'BAD_INPUT'; end if;
 for r in select id,sheet_snapshot from public.routes where customer_receipt_v1 and carrier_id in ('CT-ESTE','CT-ALR')
    and published_by=auth.uid() and operational_status='PUBLICADA' and started_at is null order by id for update loop
   snapshot:=r.sheet_snapshot;
   for st,idx in select value,(ordinality-1)::int from jsonb_array_elements(snapshot->'stops') with ordinality loop
     if coalesce(st->>'stop_type','PEDIDO')<>'PEDIDO' or jsonb_array_length(coalesce(st->'merchandise','[]'))>0 then continue; end if;
     if (select count(*) from jsonb_array_elements_text(st->'order_numbers') x where x is distinct from st->>'ship_order')<>1 then continue; end if;
     select x into ord from jsonb_array_elements_text(st->'order_numbers') x where x is distinct from st->>'ship_order';
     if p_rows is null then pending:=pending||jsonb_build_array(ord); continue; end if;
     input:=p_rows->ord;
     if input is null or public._okd_norm_name(input->>'client') is distinct from public._okd_norm_name(st->>'client_name')
        or nullif(trim(input->>'client'),'') is null then continue; end if;
     items:=input->'lines';
     if jsonb_typeof(items) is distinct from 'array' then continue; end if;
     if jsonb_array_length(items)=0 or exists(select 1 from jsonb_array_elements(items) i where i->>'order' is distinct from ord or nullif(trim(i->>'description'),'') is null or nullif(trim(i->>'quantity'),'') is null) then continue; end if;
     snapshot:=jsonb_set(snapshot,array['stops',idx::text,'merchandise'],items,true);
     changed:=changed+1;
   end loop;
   if snapshot is distinct from r.sheet_snapshot then update public.routes set sheet_snapshot=snapshot where id=r.id; end if;
 end loop;
 return jsonb_build_object('orders',pending,'updated',changed);
end $$;
revoke all on function public.sync_pending_receipt_items(jsonb) from public,anon;
grant execute on function public.sync_pending_receipt_items(jsonb) to authenticated;
