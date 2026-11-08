-- =====================================================================================================================
-- PROPUESTA V4.27 · NO APLICADA · Aprobación de cambios de RUTA INTERNA · ajustes de servidor JUSTIFICADOS
-- Diagnóstico de la hoja real 03-000019: la publicó Guillermo Castillo, del EQUIPO de Leonardo → con routes.view_team Leonardo SÍ ve la hoja
-- y sus paradas (verificado con RLS real). La causa de que no la viera fue de INTERFAZ (pantalla y menú). Por eso este SQL NO agrega
-- funciones de lectura ni modifica queue_route_emails ni la RLS. Solo:
--  1) review_route_approval: + SIN autoaprobación · + sin Superior asignado → solo Administración · − aviso y correo al transportista al
--     OBSERVAR (decisión de Dirección Técnica). El resto de la función queda idéntico.
--  2) trg_notify_driver_approved: − aviso al transportista cuando se APRUEBA una solicitud de RUTA INTERNA (los demás tipos, igual).
-- Comparación con producción POR CONTENIDO: se normalizan los fines de línea (producción guarda la misma función con CRLF: huella
-- 5570f084… = misma fuente de fase2b2 con \r\n). Si el contenido difiere en cualquier otra cosa, se detiene sin cambiar nada.
-- No toca finalize_route, estados de hojas, permisos, Inspecciones, NOC/REC, Tesorería, correos de clientes ni PWA. Una transacción.
-- =====================================================================================================================
BEGIN;
DO $guard$ BEGIN
  IF to_regclass('public.route_approval_requests') IS NULL OR to_regprocedure('public.review_route_approval(uuid,text,text)') IS NULL OR to_regprocedure('public.trg_notify_driver_approved()') IS NULL THEN
    RAISE EXCEPTION 'DEPENDENCIA_FALTANTE. No se modificó nada.'; END IF;
  IF (SELECT prosrc FROM pg_proc WHERE oid = 'public.review_route_approval(uuid,text,text)'::regprocedure) LIKE '%SELF_APPROVAL%' THEN RAISE EXCEPTION 'YA_APLICADA: la V4.27 ya existe. No se modificó nada.'; END IF;
  IF (SELECT md5(replace(prosrc, E'\r\n', E'\n')) FROM pg_proc WHERE oid = 'public.review_route_approval(uuid,text,text)'::regprocedure) <> '0c4a88155b46d3122daf9e49f9b2575e' THEN
    RAISE EXCEPTION 'PRODUCCION_DISTINTA: review_route_approval no coincide (por contenido) con fase2b2. No se modificó nada.'; END IF;
  IF (SELECT md5(replace(prosrc, E'\r\n', E'\n')) FROM pg_proc WHERE oid = 'public.trg_notify_driver_approved()'::regprocedure) <> '618063b22796f3ee13771be7b5245416' THEN
    RAISE EXCEPTION 'PRODUCCION_DISTINTA: trg_notify_driver_approved no coincide (por contenido) con fase2b3. No se modificó nada.'; END IF;
END $guard$;

create or replace function public.review_route_approval(p_request uuid, p_decision text, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare q public.route_approval_requests; r public.routes; drv_email text;
begin
  if not public.auth_has_perm('can_approve_internal_route_changes') then raise exception 'FORBIDDEN: falta permiso can_approve_internal_route_changes' using errcode = '42501'; end if;
  select * into q from public.route_approval_requests where id = p_request for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  if q.status <> 'PENDING' then raise exception 'NOT_PENDING: la solicitud ya fue resuelta' using errcode = '23514'; end if;
  -- V4.27: SIN autoaprobación (para nadie) y, sin Superior asignado, la resuelve SOLO Administración
  if q.requested_by = auth.uid() then raise exception 'SELF_APPROVAL: no se pueden aprobar ni observar los propios cambios' using errcode = '42501'; end if;
  if q.supervisor_user_id is null and not public._is_general_admin() then raise exception 'FORBIDDEN: sin superior asignado la resuelve Administración' using errcode = '42501'; end if;
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
  -- V4.27 (decisión de Dirección Técnica): al OBSERVAR ya NO se notifica ni se envía correo al transportista.
end; $$;
revoke all on function public.review_route_approval(uuid,text,text) from public, anon; grant execute on function public.review_route_approval(uuid,text,text) to authenticated;

create or replace function public.trg_notify_driver_approved() returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- V4.27 (decisión de Dirección Técnica): las aprobaciones de RUTA INTERNA ya NO notifican al transportista; los demás tipos, igual que antes
  if new.status = 'APPROVED' and old.status = 'PENDING' and coalesce(new.request_type, '') <> 'INTERNAL_ROUTE_CHANGE' then
    insert into public.notifications(user_id, route_id, route_version, type, title, body)
    select r.responsable_id, r.id, new.route_version, 'INTERNAL_ROUTE_APPROVED', 'HOJA APROBADA · ' || r.number, 'Tu hoja fue aprobada.' from public.routes r where r.id = new.route_id on conflict do nothing;
  end if;
  return new;
end; $$;

DO $post$ BEGIN
  IF (SELECT prosrc FROM pg_proc WHERE oid = 'public.review_route_approval(uuid,text,text)'::regprocedure) NOT LIKE '%SELF_APPROVAL%'
     OR (SELECT prosrc FROM pg_proc WHERE oid = 'public.review_route_approval(uuid,text,text)'::regprocedure) LIKE '%queue_route_emails%'
     OR (SELECT prosrc FROM pg_proc WHERE oid = 'public.trg_notify_driver_approved()'::regprocedure) NOT LIKE '%INTERNAL_ROUTE_CHANGE%' THEN RAISE EXCEPTION 'HUELLA_FINAL_INESPERADA'; END IF;
END $post$;
COMMIT;
