alter table public.routes add column if not exists dispatch_mode text not null default 'APP';
alter table public.routes add column if not exists dispatched_at timestamptz;
alter table public.routes add column if not exists dispatched_by uuid references public.profiles(id);

do $$ begin
  if not exists (select 1 from pg_constraint where conname='routes_dispatch_mode_check') then
    alter table public.routes add constraint routes_dispatch_mode_check check (dispatch_mode in ('APP','EXTERNAL'));
  end if;
end $$;

create or replace function public.dispatch_external_route(p jsonb)
returns public.routes
language plpgsql
security definer
set search_path='public'
as $$
declare
  r public.routes;
  d public.route_drafts;
  car text := p->>'carrier_id';
  c public.carriers;
  s jsonb;
  i int := 0;
  ships text[];
  ords text[];
begin
  if not public.auth_has_perm('routes.publish') then
    raise exception 'FORBIDDEN' using errcode='42501';
  end if;
  d := public._draft(p->>'sheet_key', true, false);
  if d.status='PUBLICADA' then
    select * into r from public.routes where id=d.route_id;
    return r;
  end if;
  if d.status <> 'BORRADOR' then raise exception 'DRAFT_CANCELLED' using errcode='23514'; end if;

  select * into c from public.carriers where id=car and active;
  if not found then raise exception 'BAD_CARRIER: elegí el transportista' using errcode='23514'; end if;
  if c.kind <> 'EXTERNO' or c.report_group='CRISTIAN_TORRES' then
    raise exception 'NOT_EXTERNAL_DISPATCH: este transportista usa PUBLICAR HOJA' using errcode='23514';
  end if;

  if jsonb_array_length(coalesce(p->'stops','[]'::jsonb))=0 then raise exception 'EMPTY_SHEET: la hoja no tiene pedidos' using errcode='23514'; end if;
  select array_agg(x->>'ship_order') into ships from jsonb_array_elements(p->'stops') x where x->>'ship_fee_status'='PROVISIONAL';
  if ships is not null then perform public.assert_sheet_shipping_ready(p->>'sheet_key', ships); end if;
  if exists(select 1 from jsonb_array_elements(p->'stops') x where coalesce((x->>'ready')::boolean,false)=false) then
    raise exception 'NOT_READY: hay pedidos con revisión pendiente o sin monto' using errcode='23514';
  end if;
  select array_agg(distinct v) into ords from jsonb_array_elements(p->'stops') x, jsonb_array_elements_text(x->'order_numbers') v;
  perform public.reserve_orders(p->>'sheet_key', ords);

  insert into public.routes(number,carrier_id,responsable_id,status,operational_status,created_by,sheet_key,published_at,published_by,completed_at,completed_by,dispatched_at,dispatched_by,dispatch_mode,sheet_snapshot)
  values(public.next_route_number_for(car),car,null,'COMPLETADA','COMPLETADA',auth.uid(),p->>'sheet_key',now(),auth.uid(),now(),auth.uid(),now(),auth.uid(),'EXTERNAL',p)
  returning * into r;

  update public.order_reservations set status='PUBLICADA',route_id=r.id where sheet_key=p->>'sheet_key';
  update public.route_drafts set status='PUBLICADA',route_id=r.id,updated_at=now() where id=d.id;

  for s in select * from jsonb_array_elements(p->'stops') loop
    i:=i+1;
    insert into public.route_stops(route_id,seq,sequence_number,provenance,client_name,client_key,zone,order_numbers,merchandise_amount,shipping_fee,shipping_fee_source,bultos,address,action,task,expected_amount,customer_email)
    values(r.id,i,i,'PUBLISHED',s->>'client_name',s->>'client_key',nullif(s->>'zone',''),
      coalesce((select array_agg(v) from jsonb_array_elements_text(s->'order_numbers') v),'{}'),
      coalesce((s->>'merchandise_amount')::numeric,0),coalesce((s->>'shipping_fee')::numeric,0),
      case when s->>'ship_fee_status'='PROVISIONAL' then 'CONFIRMED_FALLBACK' else 'SALDO' end,
      nullif(s->>'bultos','')::int,s->>'address',coalesce(s->>'action','ENTREGA'),coalesce(s->>'task','ENTREGA'),
      nullif(s->>'expected_amount','')::numeric,nullif(s->>'customer_email',''));
  end loop;

  insert into public.audit_log(actor_id,action,target_type,target_id,after)
  values(auth.uid(),'EXTERNAL_ROUTE_DISPATCHED','route',r.id::text,jsonb_build_object('number',r.number,'carrier',car,'stops',i,'dispatch_mode','EXTERNAL'));
  return r;
end;
$$;

revoke execute on function public.dispatch_external_route(jsonb) from public;
grant execute on function public.dispatch_external_route(jsonb) to authenticated;
