-- RC4.1.21 · Corrección controlada post-publicación.
-- La hoja conserva id/número; una republicación aprobada incrementa routes.version.

CREATE OR REPLACE FUNCTION public.begin_post_publish_revision(p_route uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r public.routes;
  d public.route_drafts;
  q public.route_approval_requests;
  rows_json jsonb;
  c jsonb;
begin
  if not public.auth_has_perm('routes.create') then
    raise exception 'FORBIDDEN' using errcode='42501';
  end if;

  select * into r from public.routes where id=p_route for update;
  if not found then raise exception 'NOT_FOUND' using errcode='P0002'; end if;
  if r.operational_status <> 'PUBLICADA' or r.started_at is not null then
    raise exception 'REVISION_NOT_ALLOWED: solo se corrige una hoja PUBLICADA que todavía no inició' using errcode='23514';
  end if;
  if exists(select 1 from public.route_stops where route_id=r.id and outcome <> 'PENDIENTE')
     or exists(select 1 from public.stop_evidence e join public.route_stops s on s.id=e.stop_id where s.route_id=r.id)
     or exists(select 1 from public.delivery_receipts e where e.route_id=r.id) then
    raise exception 'REVISION_HAS_EXECUTION: la hoja ya tiene trazabilidad de entrega' using errcode='23514';
  end if;

  select * into q
  from public.route_approval_requests
  where route_id=r.id
    and route_version=r.version
    and request_type='CAMBIO_POST_PUBLICACION'
    and status='APPROVED'
    and (requested_by=auth.uid() or public.auth_is_admin() or public.auth_has_perm('routes.edit'))
  order by reviewed_at desc nulls last, requested_at desc
  limit 1;

  if not found then
    raise exception 'APPROVAL_REQUIRED: necesitás una solicitud CAMBIO POST PUBLICACIÓN aprobada para esta versión' using errcode='42501';
  end if;

  select * into d from public.route_drafts where route_id=r.id for update;
  if not found then raise exception 'REVISION_DRAFT_NOT_FOUND' using errcode='P0002'; end if;
  if not public.can_manage_draft_of(d.owner_id) then
    raise exception 'FORBIDDEN_DRAFT: la hoja pertenece a otro operador' using errcode='42501';
  end if;

  c := d.content;
  if c is null or jsonb_array_length(coalesce(c->'rows','[]'::jsonb))=0 then
    select coalesce(jsonb_agg(x->'r'), '[]'::jsonb)
      into rows_json
      from jsonb_array_elements(coalesce(r.sheet_snapshot->'pdf_model'->'data','[]'::jsonb)) x
      where x ? 'r';

    if jsonb_array_length(coalesce(rows_json,'[]'::jsonb))=0 then
      raise exception 'REVISION_SOURCE_UNAVAILABLE: esta hoja antigua no tiene snapshot suficiente para reconstruir el borrador' using errcode='23514';
    end if;

    c := jsonb_build_object(
      'rows', rows_json,
      'selected', '[]'::jsonb,
      'sheetDate', coalesce(rows_json->0->>'fecha', to_char((r.published_at at time zone 'America/Argentina/Mendoza')::date,'YYYY-MM-DD')),
      'audit', '[]'::jsonb,
      'showCash', true,
      'showCheques', true,
      'showTransfers', true,
      'oldDecisions', '{}'::jsonb,
      'sheetId', r.sheet_key,
      'published', null
    );
  end if;

  c := c || jsonb_build_object(
    'sheetId', r.sheet_key,
    'published', null,
    'revision', jsonb_build_object('route_id',r.id,'number',r.number,'version',r.version,'request_id',q.id)
  );

  update public.route_drafts
     set status='BORRADOR', content=c, updated_at=now()
   where id=d.id
   returning * into d;

  update public.route_approval_requests
     set payload=coalesce(payload,'{}'::jsonb) || jsonb_build_object('revision_started_at',now(),'revision_from_version',r.version),
         updated_at=now()
   where id=q.id;

  insert into public.audit_log(actor_id,action,target_type,target_id,before,after)
  values(auth.uid(),'POST_PUBLISH_REVISION_OPENED','route',r.id::text,
         jsonb_build_object('version',r.version),
         jsonb_build_object('version',r.version,'request',q.id,'sheet_key',r.sheet_key));

  return jsonb_build_object('sheet_key',r.sheet_key,'name',coalesce(d.name,'Hoja '||r.number),'content',c,'route_id',r.id,'number',r.number,'version',r.version);
end;
$function$;

CREATE OR REPLACE FUNCTION public.publish_route_revision(p jsonb)
 RETURNS routes
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r public.routes;
  d public.route_drafts;
  q public.route_approval_requests;
  resp uuid := nullif(p->>'responsable_id','')::uuid;
  car text := p->>'carrier_id';
  s jsonb;
  i int := 0;
  ships text[];
  old_ords text[];
  new_ords text[];
  new_ver int;
  snap jsonb;
  e jsonb;
  f public.financing_plans;
begin
  if not public.auth_has_perm('routes.publish') then raise exception 'FORBIDDEN' using errcode='42501'; end if;
  if coalesce(p->>'revision_route_id','')='' then raise exception 'REVISION_ROUTE_REQUIRED' using errcode='22023'; end if;

  d := public._draft(p->>'sheet_key', false, true);
  if d.id is null or d.route_id is null or d.route_id::text <> p->>'revision_route_id' then
    raise exception 'REVISION_DRAFT_MISMATCH' using errcode='23514';
  end if;

  select * into r from public.routes where id=d.route_id for update;
  if not found then raise exception 'NOT_FOUND' using errcode='P0002'; end if;
  if r.version <> coalesce(nullif(p->>'revision_version','')::int,-1) then
    raise exception 'VERSION_CONFLICT: la hoja cambió (versión %)',r.version using errcode='40001';
  end if;
  if r.operational_status <> 'PUBLICADA' or r.started_at is not null then
    raise exception 'REVISION_NOT_ALLOWED: la hoja ya inició o cambió de estado' using errcode='23514';
  end if;
  if exists(select 1 from public.route_stops where route_id=r.id and outcome <> 'PENDIENTE')
     or exists(select 1 from public.stop_evidence e join public.route_stops s2 on s2.id=e.stop_id where s2.route_id=r.id)
     or exists(select 1 from public.delivery_receipts e where e.route_id=r.id) then
    raise exception 'REVISION_HAS_EXECUTION: la hoja ya tiene trazabilidad de entrega' using errcode='23514';
  end if;

  select * into q
  from public.route_approval_requests
  where route_id=r.id and route_version=r.version
    and request_type='CAMBIO_POST_PUBLICACION' and status='APPROVED'
    and (requested_by=auth.uid() or public.auth_is_admin() or public.auth_has_perm('routes.edit'))
  order by reviewed_at desc nulls last, requested_at desc limit 1;
  if not found then raise exception 'APPROVAL_REQUIRED' using errcode='42501'; end if;

  if car is null or car <> r.carrier_id then
    raise exception 'REVISION_CARRIER_LOCKED: el transportista no se cambia en una corrección; usá el flujo específico' using errcode='23514';
  end if;
  if resp is null or not public.can_be_responsable(resp,car) then raise exception 'RESPONSABLE_INCOMPATIBLE' using errcode='23514'; end if;
  if jsonb_array_length(coalesce(p->'stops','[]'::jsonb))=0 then raise exception 'EMPTY_SHEET' using errcode='23514'; end if;
  if exists(select 1 from jsonb_array_elements(p->'stops') x where coalesce((x->>'ready')::boolean,false)=false) then
    raise exception 'NOT_READY: hay pedidos con revisión pendiente o sin monto' using errcode='23514';
  end if;

  select array_agg(distinct v order by v) into new_ords
    from jsonb_array_elements(p->'stops') x, jsonb_array_elements_text(x->'order_numbers') v;
  select array_agg(order_id order by order_id) into old_ords
    from public.order_reservations where route_id=r.id and status='PUBLICADA';

  if coalesce(new_ords,'{}'::text[]) is distinct from coalesce(old_ords,'{}'::text[]) then
    raise exception 'REVISION_ORDERS_LOCKED: para proteger reservas y NOC, una corrección no puede agregar ni quitar pedidos; cancelá/replanificá si cambia el conjunto de pedidos' using errcode='23514';
  end if;

  select array_agg(x->>'ship_order') into ships from jsonb_array_elements(p->'stops') x where x->>'ship_fee_status'='PROVISIONAL';
  if ships is not null then perform public.assert_sheet_shipping_ready(p->>'sheet_key',ships); end if;

  new_ver := r.version + 1;
  snap := p - 'draft_content';

  update public.routes
     set responsable_id=resp,
         vehicle_id=case when coalesce(p->>'vehicle_id','')='' then vehicle_id else (p->>'vehicle_id')::uuid end,
         version=new_ver,
         sheet_snapshot=snap,
         notified_at=null,
         viewed_at=null
   where id=r.id
   returning * into r;

  delete from public.route_stops where route_id=r.id;
  for s in select * from jsonb_array_elements(p->'stops') loop
    i := i+1;
    insert into public.route_stops(
      route_id,seq,sequence_number,provenance,client_name,client_key,zone,order_numbers,
      merchandise_amount,shipping_fee,shipping_fee_source,bultos,address,action,task,expected_amount,customer_email
    )
    values(
      r.id,i,i,'PUBLISHED',s->>'client_name',s->>'client_key',nullif(s->>'zone',''),
      coalesce((select array_agg(v) from jsonb_array_elements_text(s->'order_numbers') v),'{}'),
      coalesce((s->>'merchandise_amount')::numeric,0),coalesce((s->>'shipping_fee')::numeric,0),
      case when s->>'ship_fee_status'='PROVISIONAL' then 'CONFIRMED_FALLBACK' else 'SALDO' end,
      nullif(s->>'bultos','')::int,s->>'address',coalesce(s->>'action','ENTREGA'),
      coalesce(nullif(s->>'task',''),'ENTREGA'),nullif(s->>'expected_amount','')::numeric,nullif(s->>'customer_email','')
    );
  end loop;

  -- snapshot financiero de la nueva versión, con la misma lógica del trigger de publicación inicial
  for e in select * from jsonb_array_elements(coalesce(r.sheet_snapshot->'financing','[]'::jsonb)) loop
    f := null;
    if coalesce(e->>'plan_id','')<>'' then select * into f from public.financing_plans where id=(e->>'plan_id')::uuid; end if;
    insert into public.route_financing_snapshots(
      route_id,route_version,comp,client_name,client_cuit,parts_count,parts,total,classification,resolver_version,
      plan_id,frequency,source_pending,noc_adjustments,operational_pending,source_import
    )
    values(
      r.id,new_ver,coalesce(e->>'comp',f.comp),coalesce(e->>'client_name',f.client_name),coalesce(e->>'client_key',f.client_key),
      jsonb_array_length(coalesce(e->'parts',f.parts,'[]'::jsonb)),coalesce(e->'parts',f.parts,'[]'::jsonb),
      coalesce(f.operational_pending,(e->>'total')::numeric),coalesce(e->>'classification','FINANCIACION_PROPIA_VIGENTE'),
      coalesce(e->>'resolver_version',f.resolver_version,'fin-2'),f.id,coalesce(f.frequency,e->>'frequency'),
      f.source_pending,f.noc_adjustments,f.operational_pending,coalesce(e->>'import_id',f.last_import_id)
    )
    on conflict(route_id,route_version,comp) do nothing;
  end loop;

  update public.route_drafts
     set status='PUBLICADA',
         content=coalesce(p->'draft_content',content),
         delivery_count=i,
         orders=coalesce(new_ords,'{}'::text[]),
         updated_at=now()
   where id=d.id;

  update public.route_approval_requests
     set applied=true,
         payload=coalesce(payload,'{}'::jsonb) || jsonb_build_object('applied_at',now(),'applied_version',new_ver),
         updated_at=now()
   where id=q.id;

  insert into public.notifications(user_id,route_id,route_version,type,title,body)
  values(resp,r.id,new_ver,'HOJA_CORREGIDA','HOJA CORREGIDA · NUEVA VERSIÓN','Hoja '||r.number||' · versión '||new_ver||' · '||i||' entregas')
  on conflict do nothing;

  insert into public.audit_log(actor_id,action,target_type,target_id,before,after)
  values(auth.uid(),'POST_PUBLISH_REVISION_PUBLISHED','route',r.id::text,
         jsonb_build_object('version',new_ver-1,'request',q.id),
         jsonb_build_object('version',new_ver,'request',q.id,'stops',i,'responsable',resp));

  return r;
end;
$function$;

revoke all on function public.begin_post_publish_revision(uuid) from public;
grant execute on function public.begin_post_publish_revision(uuid) to authenticated;
revoke all on function public.publish_route_revision(jsonb) from public;
grant execute on function public.publish_route_revision(jsonb) to authenticated;
