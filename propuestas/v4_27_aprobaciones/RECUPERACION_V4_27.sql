-- RECUPERACIÓN V4.27: restaura review_route_approval (fase2b2) y trg_notify_driver_approved (fase2b3) ORIGINALES. No modifica solicitudes ni hojas.
BEGIN;
create or replace function public.review_route_approval(p_request uuid, p_decision text, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare q public.route_approval_requests; r public.routes; drv_email text;
begin
  if not public.auth_has_perm('can_approve_internal_route_changes') then raise exception 'FORBIDDEN: falta permiso can_approve_internal_route_changes' using errcode = '42501'; end if;
  select * into q from public.route_approval_requests where id = p_request for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  if q.status <> 'PENDING' then raise exception 'NOT_PENDING: la solicitud ya fue resuelta' using errcode = '23514'; end if;
  if q.supervisor_user_id is not null and q.supervisor_user_id <> auth.uid() and not public.auth_has_perm('users.manage') then
    raise exception 'FORBIDDEN: la revisa el superior asignado o Administración' using errcode = '42501';
  end if;
  if p_decision not in ('APPROVED','OBSERVED') then raise exception 'BAD_DECISION' using errcode = '22023'; end if;
  if p_decision = 'OBSERVED' and coalesce(trim(p_note), '') = '' then raise exception 'NOTE_REQUIRED: para solicitar aclaración hay que indicar el motivo' using errcode = '23514'; end if;
  update public.route_approval_requests set status = p_decision, reviewed_by = auth.uid(), reviewed_at = now(), review_note = p_note, updated_at = now() where id = p_request;
  update public.routes set approval_status = case p_decision when 'APPROVED' then 'APROBADA' else 'OBSERVADA' end where id = q.route_id returning * into r;
  insert into public.audit_log(actor_id, action, target_type, target_id, before, after)
  values (auth.uid(), case p_decision when 'APPROVED' then 'INTERNAL_ROUTE_APPROVED' else 'INTERNAL_ROUTE_OBSERVED' end, 'route', q.route_id::text,
          jsonb_build_object('status', q.status), jsonb_build_object('status', p_decision, 'note', p_note));
  if p_decision = 'OBSERVED' then
    insert into public.notifications(user_id, route_id, route_version, type, title, body)
    values (r.responsable_id, r.id, q.route_version, 'INTERNAL_ROUTE_OBSERVED', 'ACLARACIÓN SOLICITADA · HOJA ' || r.number, p_note) on conflict do nothing;
    select email into drv_email from public.profiles where id = r.responsable_id;
    perform public.queue_route_emails(r.id, q.route_version, 'INTERNAL_ROUTE_OBSERVED', drv_email);
  end if;
end; $$;
revoke all on function public.review_route_approval(uuid,text,text) from public, anon; grant execute on function public.review_route_approval(uuid,text,text) to authenticated;
create or replace function public.trg_notify_driver_approved() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'APPROVED' and old.status = 'PENDING' then
    insert into public.notifications(user_id, route_id, route_version, type, title, body)
    select r.responsable_id, r.id, new.route_version, 'INTERNAL_ROUTE_APPROVED', 'HOJA APROBADA · ' || r.number, 'Tu hoja fue aprobada.' from public.routes r where r.id = new.route_id on conflict do nothing;
  end if;
  return new;
end; $$;
COMMIT;
