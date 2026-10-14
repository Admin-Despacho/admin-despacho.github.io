-- RC4.1.22 · Guardas para borradores de corrección post-publicación.

CREATE OR REPLACE FUNCTION public.trg_revision_reservation_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare d public.route_drafts;
begin
  select * into d from public.route_drafts where client_sheet_key=new.sheet_key;
  if d.route_id is not null
     and not exists(
       select 1 from public.order_reservations x
       where x.order_id=new.order_id and x.route_id=d.route_id and x.status='PUBLICADA'
     ) then
    raise exception 'REVISION_ORDERS_LOCKED: una corrección post-publicación no puede agregar pedidos; cancelá/replanificá si cambia el conjunto de pedidos'
      using errcode='23514';
  end if;
  return new;
end;
$function$;

drop trigger if exists revision_reservation_guard on public.order_reservations;
create trigger revision_reservation_guard before insert on public.order_reservations for each row execute function public.trg_revision_reservation_guard();
revoke all on function public.trg_revision_reservation_guard() from public, anon, authenticated;

CREATE OR REPLACE FUNCTION public.delete_draft(p_sheet_key text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare d public.route_drafts; n int;
begin
  if not public.auth_has_perm('routes.create') then raise exception 'FORBIDDEN' using errcode='42501'; end if;
  d := public._draft(p_sheet_key, false);
  if d.id is null then return 0; end if;

  -- Un borrador ligado a una hoja publicada es una corrección versionada.
  -- "Eliminar" esa corrección vuelve a dejar intacta la hoja publicada.
  if d.route_id is not null then
    update public.route_drafts set status='PUBLICADA', updated_at=now() where id=d.id;
    insert into public.audit_log(actor_id,action,target_type,target_id,after)
    values(auth.uid(),'POST_PUBLISH_REVISION_CANCELLED','route',d.route_id::text,
           jsonb_build_object('sheet_key',p_sheet_key,'reason','revision draft discarded'));
    return -1;
  end if;

  delete from public.order_reservations
   where sheet_key=p_sheet_key and status='BORRADOR';
  get diagnostics n=row_count;
  delete from public.shipping_amount_confirmations where sheet_key=p_sheet_key and route_id is null;
  update public.route_drafts set status='CANCELADA',content=null,orders='{}',updated_at=now() where id=d.id;
  insert into public.audit_log(actor_id,action,target_type,target_id,after)
  values(auth.uid(),'DRAFT_DELETED','draft',p_sheet_key,jsonb_build_object('released',n,'owner',d.owner_id,'name',d.name));
  return n;
end;
$function$;
