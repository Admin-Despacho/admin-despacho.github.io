-- =====================================================================================================================
-- PROPUESTA V4.28 · NO APLICADA · VER HOJA: gestión de pendientes, historial de cambios y receptor con DNI / CUIL / CUIT
--  1) stop_followups (SOLO AGREGADO) + add_stop_followup: gestiones, observaciones e incidencias por parada. NUNCA cambia el resultado
--     de la parada (un PARCIAL no pasa a ENTREGADO); las solicitudes usan el circuito EXISTENTE (create_operational_request, tipo OTRO).
--  2) route_change_history: historial legible de la hoja para quien puede verla (resultado original, cambios de ruta interna, solicitudes
--     y decisiones con quién aprobó/observó, gestiones). Todo sale del servidor.
--  3) set_stop_outcome: receptor con DNI, CUIL o CUIT. REGLA DEFINITIVA: un documento incorrecto o faltante NUNCA bloquea la entrega
--     (la FIRMA sigue siendo obligatoria). Se guarda lo DECLARADO tal cual + tipo + validación + motivo; receiver_cuil / receiver_dni solo
--     con documentos VÁLIDOS (nunca se vincula una identidad con un documento no validado). Documento a revisar → UNA incidencia por entrega
--     (receiver_doc_reviews, idempotente) + alerta en la campana a Administración y al Superior responsable (si la alerta falla, la entrega
--     NO se deshace). Corrección posterior auditada (correct_receiver_doc) sin tocar la evidencia original.
--     Comparación POR CONTENIDO (fines de línea normalizados); si difiere, se detiene sin cambios.
-- No toca finalize_route, RLS existente, permisos, aprobaciones V4.27, Inspecciones, NOC/REC, Tesorería, correos ni PWA.
-- =====================================================================================================================
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';
DO $guard$ BEGIN
  IF to_regclass('public.stop_followups') IS NOT NULL THEN RAISE EXCEPTION 'YA_APLICADA: la V4.28 ya existe. No se modificó nada.'; END IF;
  IF to_regprocedure('public.set_stop_outcome(uuid,text,text,text,text,jsonb)') IS NULL OR to_regprocedure('public._cuit_valid(text)') IS NULL
     OR to_regprocedure('public.can_view_route(uuid)') IS NULL OR to_regprocedure('public.auth_has_perm(text)') IS NULL OR to_regprocedure('public._is_general_admin()') IS NULL THEN RAISE EXCEPTION 'DEPENDENCIA_FALTANTE. No se modificó nada.'; END IF;
  IF (SELECT md5(replace(prosrc, E'\r\n', E'\n')) FROM pg_proc WHERE oid = 'public.set_stop_outcome(uuid,text,text,text,text,jsonb)'::regprocedure) <> '5d26e5af27a068596cc6875bd6ee8bbf' THEN
    RAISE EXCEPTION 'PRODUCCION_DISTINTA: set_stop_outcome no coincide (por contenido) con V4.21. No se modificó nada.'; END IF;
  IF (SELECT md5(replace(prosrc, E'\r\n', E'\n')) FROM pg_proc WHERE oid = 'public.delivery_identity_lookup(uuid,text,text)'::regprocedure) <> '4a882db134526ea21876126f44208b4d' THEN
    RAISE EXCEPTION 'PRODUCCION_DISTINTA: delivery_identity_lookup no coincide (por contenido) con rc4_1_scope_email. No se modificó nada.'; END IF;
  IF (SELECT md5(replace(prosrc, E'\r\n', E'\n')) FROM pg_proc WHERE oid = 'public.search_deliveries(text)'::regprocedure) <> 'ee7ebbff796dac0844064280bfc3ae2a' THEN
    RAISE EXCEPTION 'PRODUCCION_DISTINTA: search_deliveries no coincide (por contenido) con V4.26. No se modificó nada.'; END IF;
END $guard$;

-- ---------- 1) GESTIONES POR PARADA (solo agregado) ----------
create table public.stop_followups (
  id bigint generated always as identity primary key,
  route_id uuid not null references public.routes(id), stop_id uuid not null references public.route_stops(id),
  kind text not null check (kind in ('GESTION', 'OBSERVACION', 'INCIDENCIA', 'SOLICITUD')),
  note text not null check (length(btrim(note)) >= 3 and length(note) <= 1000),
  request_id uuid references public.route_approval_requests(id), op_id text unique,
  created_by uuid not null references public.profiles(id), created_at timestamptz not null default now());
create index stop_followups_route_idx on public.stop_followups(route_id, created_at);
alter table public.stop_followups enable row level security;
create policy stop_followups_read on public.stop_followups for select to authenticated using (public.can_view_route(route_id));
revoke all on table public.stop_followups from public, anon, authenticated; grant select on table public.stop_followups to authenticated;
create or replace function public.trg_stop_followups_immutable() returns trigger language plpgsql as $$
begin raise exception 'APPEND_ONLY: el historial de gestiones no se modifica ni se borra' using errcode = '42501'; end; $$;
create trigger stop_followups_immutable before update or delete on public.stop_followups for each row execute function public.trg_stop_followups_immutable();

create or replace function public.add_stop_followup(p_stop uuid, p_kind text, p_note text, p_request uuid default null, p_op_id text default null)
returns public.stop_followups language plpgsql security definer set search_path = public as $$
declare st public.route_stops; q public.route_approval_requests; f public.stop_followups;
begin
  -- B2 (auditoría de Work): el orden es 1) usuario ACTIVO, 2) permiso y ALCANCE sobre la hoja y la parada, 3) correspondencia del op_id;
  -- SOLO entonces se devuelve un reintento. Un op_id conocido de otro equipo nunca revela información.
  if not exists (select 1 from public.profiles where id = auth.uid() and status = 'ACTIVO') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if not (public.auth_has_perm('requests.create') or public.auth_has_perm('users.manage')) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into st from public.route_stops where id = p_stop; if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  if not public.can_view_route(st.route_id) then raise exception 'FORBIDDEN_ROUTE: la hoja está fuera de tu alcance' using errcode = '42501'; end if;
  if p_op_id is not null then
    select * into f from public.stop_followups where op_id = p_op_id;
    if found then   -- reintento idempotente legítimo: MISMO autor, MISMA parada, MISMA operación
      if f.created_by = auth.uid() and f.stop_id = st.id and f.kind = p_kind and f.request_id is not distinct from p_request then return f; end if;
      raise exception 'OP_ID_CONFLICT: el identificador de la operación ya fue usado para otra gestión' using errcode = '23505';   -- sin datos de la otra gestión
    end if;
  end if;
  if coalesce(p_kind, '') not in ('GESTION', 'OBSERVACION', 'INCIDENCIA', 'SOLICITUD') then raise exception 'BAD_KIND' using errcode = '22023'; end if;
  if length(btrim(coalesce(p_note, ''))) < 3 then raise exception 'NOTE_REQUIRED: describí la gestión' using errcode = '23514'; end if;
  if p_request is not null then
    select * into q from public.route_approval_requests where id = p_request;
    if not found or q.route_id is distinct from st.route_id or q.requested_by <> auth.uid() or p_kind <> 'SOLICITUD' then raise exception 'BAD_REQUEST_LINK' using errcode = '22023'; end if;
  elsif p_kind = 'SOLICITUD' then raise exception 'BAD_REQUEST_LINK' using errcode = '22023'; end if;
  insert into public.stop_followups(route_id, stop_id, kind, note, request_id, op_id, created_by) values (st.route_id, st.id, p_kind, btrim(p_note), p_request, p_op_id, auth.uid()) returning * into f;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'STOP_FOLLOWUP_' || p_kind, 'route', st.route_id::text,
    jsonb_build_object('stop', st.id, 'client', st.client_name, 'outcome', st.outcome, 'note', btrim(p_note), 'request', p_request));
  return f;   -- el resultado de la parada NO se modifica
end; $$;

-- ---------- 3) RECEPTOR: DNI, CUIL o CUIT · SIN BLOQUEO, CON INCIDENCIA Y ALERTA ----------
alter table public.stop_evidence add column if not exists receiver_doc_type text check (receiver_doc_type in ('DNI', 'CUIL', 'CUIT'));   -- histórico: NULL = CUIL
alter table public.stop_evidence add column if not exists receiver_doc_declared text;   -- EXACTAMENTE como fue declarado (aunque sea inválido)
alter table public.stop_evidence add column if not exists receiver_doc_valid boolean;   -- true solo si pasó la validación; NULL en históricos
alter table public.stop_evidence add column if not exists receiver_doc_issue text;      -- motivo de la advertencia (NULL = sin advertencia)
alter table public.stop_evidence add column if not exists receiver_cuit text check (receiver_cuit ~ '^[0-9]{11}$');   -- CUIT VÁLIDO (empresa o persona): NUNCA en receiver_cuil

-- clasificación del documento (NO bloquea: devuelve el motivo o NULL si es válido). Recibe lo DECLARADO: se normalizan puntos, espacios y guiones
-- habituales; letras u otros caracteres generan advertencia («DOCUMENTO CON CARACTERES NO VÁLIDOS»)
create or replace function public._receiver_doc_issue(p_type text, p_raw text, p_required boolean) returns text language plpgsql immutable set search_path = public as $$
declare t text := coalesce(nullif(upper(btrim(p_type)), ''), 'CUIL'); raw text := btrim(coalesce(p_raw, '')); d text := regexp_replace(coalesce(p_raw, ''), '\D', '', 'g');
begin
  if raw = '' then return case when p_required then 'DOCUMENTO FALTANTE' end; end if;
  if t not in ('DNI', 'CUIL', 'CUIT') then return 'TIPO DE DOCUMENTO NO RECONOCIDO'; end if;
  if raw !~ '^[0-9 .\-–]+$' then return 'DOCUMENTO CON CARACTERES NO VÁLIDOS'; end if;
  if d = '' then return case when p_required then 'DOCUMENTO FALTANTE' end; end if;
  if t = 'DNI' then
    if d ~ '^[0-9]{7,8}$' then return null; end if;
    if length(d) = 11 then return 'PARECE UN CUIL O CUIT: SE ELIGIÓ DNI'; end if;
    return 'DNI CON CANTIDAD DE DÍGITOS INCORRECTA';
  end if;
  if length(d) in (7, 8) then return 'PARECE UN DNI: SE ELIGIÓ ' || t; end if;
  if length(d) <> 11 then return t || ' CON CANTIDAD DE DÍGITOS INCORRECTA'; end if;
  if not public._cuit_valid(d) then return t || ' CON DÍGITO VERIFICADOR INVÁLIDO'; end if;
  if t = 'CUIL' and left(d, 2) not in ('20', '23', '24', '27') then return 'PREFIJO DE EMPRESA: PARECE UN CUIT'; end if;
  return null;
end; $$;

-- incidencia de documento: UNA por entrega (la clave es la parada); lo declarado es INALTERABLE
create table public.receiver_doc_reviews (
  stop_id uuid primary key references public.route_stops(id), route_id uuid not null references public.routes(id),
  driver_id uuid references public.profiles(id), supervisor_id uuid references public.profiles(id),
  receiver_name text, declared_type text, declared_doc text, issue text not null,
  status text not null default 'A_REVISAR' check (status in ('A_REVISAR', 'CORREGIDO')), created_at timestamptz not null default now(),
  corrected_type text check (corrected_type in ('DNI', 'CUIL', 'CUIT')), corrected_doc text, corrected_by uuid references public.profiles(id), corrected_at timestamptz, correction_reason text);
create index receiver_doc_reviews_open_idx on public.receiver_doc_reviews(status, supervisor_id);
-- historial de CORRECCIONES / RECTIFICACIONES: solo agregado (ninguna corrección sobrescribe a otra en silencio)
create table public.receiver_doc_corrections (
  id bigint generated always as identity primary key, stop_id uuid not null references public.receiver_doc_reviews(stop_id), seq int not null,
  corrected_type text not null check (corrected_type in ('DNI', 'CUIL', 'CUIT')), corrected_doc text not null, reason text not null,
  is_rectification boolean not null default false, corrected_by uuid not null references public.profiles(id), corrected_at timestamptz not null default now(), unique (stop_id, seq));
alter table public.receiver_doc_corrections enable row level security; revoke all on table public.receiver_doc_corrections from public, anon, authenticated;
create or replace function public.trg_receiver_doc_corrections_immutable() returns trigger language plpgsql as $$
begin raise exception 'APPEND_ONLY: el historial de correcciones no se modifica ni se borra' using errcode = '42501'; end; $$;
create trigger receiver_doc_corrections_immutable before update or delete on public.receiver_doc_corrections for each row execute function public.trg_receiver_doc_corrections_immutable();
alter table public.receiver_doc_reviews enable row level security;   -- sin políticas: SOLO por funciones (alcance y enmascarado)
revoke all on table public.receiver_doc_reviews from public, anon, authenticated;
create or replace function public.trg_receiver_doc_reviews_guard() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception 'APPEND_ONLY: las incidencias de documento no se borran' using errcode = '42501'; end if;
  if (new.stop_id, new.route_id, new.driver_id, new.receiver_name, new.declared_type, new.declared_doc, new.issue, new.created_at)
     is distinct from (old.stop_id, old.route_id, old.driver_id, old.receiver_name, old.declared_type, old.declared_doc, old.issue, old.created_at) then
    raise exception 'APPEND_ONLY: el documento declarado y su advertencia no se modifican' using errcode = '42501'; end if;
  return new;
end; $$;
create trigger receiver_doc_reviews_guard before update or delete on public.receiver_doc_reviews for each row execute function public.trg_receiver_doc_reviews_guard();

-- ¿quién puede ver/corregir una incidencia? el ADMINISTRADOR GENERAL ACTIVO (rol real), o el usuario ACTIVO con rol SUPERIOR DESPACHO que HOY es el Superior asignado al transportista
create or replace function public._doc_review_responsible(p_driver uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles me where me.id = auth.uid() and me.status = 'ACTIVO'
    and (public._is_general_admin() or (me.role = 'SUPERVISOR_DESPACHO' and me.id = (select d.supervisor_user_id from public.profiles d where d.id = p_driver))));
  -- B1 (auditoría de Work): el acceso GLOBAL es solo del Administrador General ACTIVO por su ROL REAL (_is_general_admin); users.manage DELEGADO no lo concede
$$;
-- crea la incidencia y la alerta (la alerta, en bloque protegido: si falla, la entrega NO se deshace)
create or replace function public._receiver_doc_flag(st public.route_stops, r public.routes, p_name text, p_type text, p_raw text, p_issue text) returns void language plpgsql security definer set search_path = public as $$
declare sup uuid; ins boolean := false; body text;
begin
  select supervisor_user_id into sup from public.profiles where id = auth.uid();
  insert into public.receiver_doc_reviews(stop_id, route_id, driver_id, supervisor_id, receiver_name, declared_type, declared_doc, issue)
    values (st.id, r.id, auth.uid(), sup, p_name, p_type, nullif(p_raw, ''), p_issue) on conflict (stop_id) do nothing returning true into ins;
  if not coalesce(ins, false) then return; end if;   -- reintento (cola sin conexión): ni otra incidencia ni otra alerta
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'RECEIVER_DOC_FLAGGED', 'route', r.id::text, jsonb_build_object('stop', st.id, 'type', p_type, 'issue', p_issue));
  begin
    body := 'Hoja ' || coalesce(r.number, '') || ' · Pedido ' || coalesce(array_to_string(st.order_numbers, ' + '), '—') || ' · ' || coalesce(st.client_name, '') || ' · ' || p_issue;
    insert into public.notifications(user_id, route_id, route_version, type, title, body)
      select u.id, r.id, coalesce(r.version, 1), 'RECEIVER_DOC_REVIEW', 'DOCUMENTO DEL RECEPTOR A REVISAR', body from public.profiles u
       where u.status = 'ACTIVO' and (u.role = 'ADMIN' or (u.id = sup and u.role = 'SUPERVISOR_DESPACHO')) on conflict do nothing;   -- Superior AUTORIZADO (rol vigente)
  exception when others then null;   -- la alerta nunca deshace la entrega (la incidencia ya quedó registrada)
  end;
end; $$;

-- listado para la campana y la revisión: Administración ve todas; un Superior SOLO las de su transportista; documento ENMASCARADO sin signatures.view
create or replace function public.list_receiver_doc_reviews(p_status text default 'A_REVISAR') returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me public.profiles; adm boolean; sig boolean; out jsonb;
begin
  select * into me from public.profiles where id = auth.uid() and status = 'ACTIVO'; if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  adm := public._is_general_admin(); sig := public.auth_has_perm('signatures.view');   -- B1: rol real, no permiso delegado
  if not adm and me.role <> 'SUPERVISOR_DESPACHO' then return '[]'::jsonb; end if;   -- responsabilidad VIGENTE (no la del momento de la entrega)
  select coalesce(jsonb_agg(jsonb_build_object('stop_id', v.stop_id, 'route_id', v.route_id, 'route_number', r.number, 'orders', s.order_numbers, 'client', s.client_name,
      'driver', (select full_name from public.profiles where id = v.driver_id), 'receiver_name', v.receiver_name, 'declared_type', v.declared_type,
      'doc', case when sig then v.declared_doc when v.declared_doc is null then null else '•••' || right(regexp_replace(v.declared_doc, '\D', '', 'g'), 3) end,
      'issue', v.issue, 'status', v.status, 'created_at', v.created_at, 'corrected_type', v.corrected_type,
      'corrected_doc', case when sig then v.corrected_doc when v.corrected_doc is null then null else '•••' || right(v.corrected_doc, 3) end,
      'corrected_by', (select full_name from public.profiles where id = v.corrected_by), 'corrected_at', v.corrected_at, 'correction_reason', v.correction_reason,
      'corrections', (select coalesce(jsonb_agg(jsonb_build_object('seq', c.seq, 'type', c.corrected_type, 'doc', case when sig then c.corrected_doc else '•••' || right(c.corrected_doc, 3) end, 'reason', c.reason,
          'rectificacion', c.is_rectification, 'by', (select full_name from public.profiles where id = c.corrected_by), 'at', c.corrected_at) order by c.seq), '[]') from public.receiver_doc_corrections c where c.stop_id = v.stop_id),
      'can_correct', public._doc_review_responsible(v.driver_id)) order by v.created_at desc), '[]') into out
    from public.receiver_doc_reviews v join public.routes r on r.id = v.route_id join public.route_stops s on s.id = v.stop_id
   where public._doc_review_responsible(v.driver_id) and (coalesce(p_status, 'A_REVISAR') = 'TODOS' or v.status = coalesce(p_status, 'A_REVISAR'));
  return out;
end; $$;

-- corrección posterior (Administración o el Superior responsable): documento VÁLIDO + motivo. La PRIMERA es una corrección; las siguientes
-- SOLO como RECTIFICACIÓN explícita (p_rectify), que agrega una entrada nueva al historial inmutable. La evidencia original NO se toca.
create or replace function public.correct_receiver_doc(p_stop uuid, p_type text, p_doc text, p_reason text, p_rectify boolean default false) returns jsonb language plpgsql security definer set search_path = public as $$
declare v public.receiver_doc_reviews; d text := regexp_replace(coalesce(p_doc, ''), '\D', '', 'g'); t text := upper(btrim(coalesce(p_type, ''))); iss text; n int;
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and status = 'ACTIVO') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into v from public.receiver_doc_reviews where stop_id = p_stop for update; if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  if not public._doc_review_responsible(v.driver_id) then raise exception 'FORBIDDEN: solo Administración o el Superior Despacho ACTIVO asignado hoy al transportista' using errcode = '42501'; end if;
  if length(btrim(coalesce(p_reason, ''))) < 3 then raise exception 'REASON_REQUIRED: indicá por qué se corrige' using errcode = '23514'; end if;
  if v.status = 'CORREGIDO' and not coalesce(p_rectify, false) then
    raise exception 'ALREADY_CORRECTED: ya fue corregido; para cambiarlo usá RECTIFICAR (queda en el historial)' using errcode = '23514'; end if;
  if v.status = 'A_REVISAR' and coalesce(p_rectify, false) then raise exception 'NOTHING_TO_RECTIFY: todavía no hay una corrección para rectificar' using errcode = '23514'; end if;
  iss := public._receiver_doc_issue(t, p_doc, true);
  if iss is not null then raise exception 'DOC_STILL_INVALID: la corrección tampoco es válida (%)', iss using errcode = '23514'; end if;
  select coalesce(max(seq), 0) + 1 into n from public.receiver_doc_corrections where stop_id = p_stop;
  insert into public.receiver_doc_corrections(stop_id, seq, corrected_type, corrected_doc, reason, is_rectification, corrected_by) values (p_stop, n, t, d, btrim(p_reason), n > 1, auth.uid());
  update public.receiver_doc_reviews set status = 'CORREGIDO', corrected_type = t, corrected_doc = d, corrected_by = auth.uid(), corrected_at = now(), correction_reason = btrim(p_reason) where stop_id = p_stop returning * into v;   -- vigente = la última del historial
  insert into public.audit_log(actor_id, action, target_type, target_id, before, after) values (auth.uid(), case when n > 1 then 'RECEIVER_DOC_RECTIFIED' else 'RECEIVER_DOC_CORRECTED' end, 'route', v.route_id::text,
    jsonb_build_object('stop', v.stop_id, 'declared_type', v.declared_type, 'issue', v.issue), jsonb_build_object('type', t, 'reason', btrim(p_reason), 'seq', n));
  return jsonb_build_object('stop_id', v.stop_id, 'status', v.status, 'corrected_type', v.corrected_type, 'seq', n);
end; $$;
CREATE OR REPLACE FUNCTION public.set_stop_outcome(p_stop uuid, p_outcome text, p_note text, p_reason text, p_op_id text, p_extra jsonb DEFAULT NULL::jsonb)
 RETURNS route_stops
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_doc_type text; v_doc text; v_doc_raw text; v_doc_issue text; v_cuit text; st public.route_stops; r public.routes; cristian boolean; v_commercial boolean; v_task boolean; v_cuil text; v_email text; v_dni text; v_receipt boolean := false; ev jsonb := coalesce(p_extra->'evidence', '{}'); col jsonb := p_extra->'collection'; loc jsonb; sig bytea;
begin
  select * into st from public.route_stops where id = p_stop;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  r := public._my_route(st.route_id);
  -- Comportamiento por tipo de parada: solo PEDIDO es entrega comercial al cliente (email, Recibido Conforme, cobranza, identidad).
  v_commercial := coalesce(st.stop_type, 'PEDIDO') = 'PEDIDO';
  v_task := st.stop_type = 'TAREA';
  if p_op_id is not null and exists (select 1 from public.stop_outcome_ops where op_id = p_op_id) then return st; end if;
  if r.operational_status <> 'EN_CURSO' then raise exception 'BAD_STATE: iniciá el recorrido o la hoja ya está cerrada' using errcode = '23514'; end if;
  if p_outcome not in ('ENTREGADO','ENTREGA_PARCIAL','NO_ENTREGADO','REPROGRAMAR') then raise exception 'BAD_OUTCOME' using errcode = '22023'; end if;
  if p_outcome = 'ENTREGA_PARCIAL' and coalesce(trim(p_note), '') = '' then raise exception 'NOTE_REQUIRED: entrega parcial exige observación' using errcode = '23514'; end if;
  if p_outcome in ('NO_ENTREGADO','REPROGRAMAR') and coalesce(trim(p_reason), '') = '' then raise exception 'REASON_REQUIRED: indicá el motivo' using errcode = '23514'; end if;
  cristian := exists (select 1 from public.carriers where id = r.carrier_id and report_group = 'CRISTIAN_TORRES');
  if p_outcome in ('ENTREGADO','ENTREGA_PARCIAL') then
    -- TAREA: no se exige firma ni receptor como en una entrega comercial (alcanza GPS u observación). El resto, igual que antes.
    if not v_task and (coalesce(trim(ev->>'receiver_name'), '') = '' or coalesce(ev->>'signature_png_b64', '') = '') then raise exception 'EVIDENCE_REQUIRED: nombre del receptor y firma obligatorios' using errcode = '23514'; end if;
    sig := case when coalesce(ev->>'signature_png_b64', '') <> '' then decode(ev->>'signature_png_b64', 'base64') end;
    -- V4.17: entrega COMERCIAL de AMBOS perfiles (transportista externo e interno): CUIL + identidad con DNI registrado
    -- (antes: solo Cristian). _register_identity vincula la foto nueva o reutiliza una identidad ya registrada.
    if v_commercial then
      -- V4.28 (corregido): el documento NUNCA bloquea la entrega. Se CLASIFICA (válido / a revisar con motivo) y se guarda tal como fue declarado.
      v_doc_raw := btrim(coalesce(nullif(ev->>'receiver_doc_declared', ''), nullif(ev->>'receiver_doc', ''), ev->>'cuil', ''));
      v_doc := regexp_replace(v_doc_raw, '\D', '', 'g');
      v_doc_type := upper(nullif(btrim(coalesce(ev->>'receiver_doc_type', '')), ''));
      v_doc_issue := public._receiver_doc_issue(v_doc_type, v_doc_raw, true);
      v_cuil := case when v_doc_issue is null and coalesce(v_doc_type, 'CUIL') = 'CUIL' then v_doc end;   -- receiver_cuil: SOLO CUIL de persona
      v_cuit := case when v_doc_issue is null and v_doc_type = 'CUIT' then v_doc end;                    -- el CUIT válido va a receiver_cuit (nunca como CUIL)
      if v_doc_issue is null and coalesce(v_doc_type, 'CUIL') = 'CUIL' then perform public._register_identity(v_cuil, ev); end if;   -- SOLO un CUIL VÁLIDO de persona vincula una foto antigua (nunca un CUIT)
    else
      -- Transportista Interno: documento OPCIONAL; si se carga, se clasifica igual (sin bloquear)
      v_doc_raw := btrim(coalesce(nullif(ev->>'receiver_doc_declared', ''), nullif(ev->>'receiver_doc', ''), ev->>'cuil', ''));
      v_doc := regexp_replace(v_doc_raw, '\D', '', 'g');
      v_doc_type := upper(nullif(btrim(coalesce(ev->>'receiver_doc_type', '')), ''));
      v_doc_issue := case when v_doc_raw = '' then null else public._receiver_doc_issue(v_doc_type, v_doc_raw, false) end;
      v_cuil := case when v_doc <> '' and v_doc_issue is null and coalesce(v_doc_type, 'CUIL') = 'CUIL' then v_doc end;
      v_cuit := case when v_doc <> '' and v_doc_issue is null and v_doc_type = 'CUIT' then v_doc end;
    end if;
    
-- RC4.1: email del receptor (segunda pantalla). Opcional; si viene, debe ser válido.
    v_email := nullif(lower(trim(coalesce(ev->>'email', ''))), '');
    -- V4.21: el email del receptor es OPCIONAL (ambos transportistas). Si viene, se valida el formato (abajo) y se genera el Recibido
    -- Conforme; si no viene, la entrega se confirma igual y NO se intenta enviar el Recibido Conforme.
    if v_email is not null and not public.is_valid_email(v_email) then raise exception 'EMAIL_INVALID: el email no es válido' using errcode = '23514'; end if;
    -- V4.28: receiver_dni SOLO con un DNI VÁLIDO (declarado o derivado de un CUIL válido); un dato inválido no bloquea ni se guarda como verificado
    v_dni := case when v_doc_type = 'DNI' and v_doc_issue is null then v_doc end;
    if v_dni is null and v_cuil is not null and coalesce(v_doc_type, 'CUIL') = 'CUIL' then v_dni := substr(v_cuil, 3, 8); end if;
    if v_dni is null and coalesce(ev->>'dni', '') ~ '^\D*\d{7,8}\D*$' and v_doc_type is null then v_dni := regexp_replace(ev->>'dni', '\D', '', 'g'); end if;
  end if;
  -- cobranza (Cristian): el chofer no cambia el importe esperado
  -- V4.17: la cobranza es OPCIONAL (el chofer ya no la registra). Si se informa, se valida igual que antes; si no, no se registra
  -- ningún cobro y los datos de cobranza existentes de la parada se CONSERVAN (no se inventan ni se borran).
  if v_commercial and st.task in ('COBRANZA','AMBAS') and col is not null and coalesce(col->>'status', 'PENDIENTE') <> 'PENDIENTE' then
    if col->>'status' not in ('COBRADO','COBRO_PARCIAL','NO_COBRADO') then raise exception 'BAD_COLLECTION' using errcode = '22023'; end if;
    if col->>'status' in ('COBRO_PARCIAL','NO_COBRADO') and coalesce(trim(col->>'note'), '') = '' then raise exception 'COLLECTION_NOTE_REQUIRED: cobro parcial exige observación y no cobrado exige motivo' using errcode = '23514'; end if;
    if col->>'status' in ('COBRADO','COBRO_PARCIAL') and coalesce((col->>'amount')::numeric, 0) <= 0 then raise exception 'COLLECTION_AMOUNT_REQUIRED' using errcode = '23514'; end if;
  end if;
  loc := public._loc(p_extra->'location', st);
  update public.route_stops set outcome = p_outcome, outcome_at = now(), outcome_by = auth.uid(), outcome_note = nullif(trim(p_note),''), outcome_reason = nullif(trim(p_reason),''),
    finish_location = loc, location_warning = coalesce(case when loc->>'outside_m' is not null then 'FUERA DEL RADIO (' || (loc->>'outside_m') || ' m)' end, location_warning),
    collection_status = case when st.task in ('COBRANZA','AMBAS') and coalesce(col->>'status','PENDIENTE') <> 'PENDIENTE' then col->>'status' else collection_status end,
    collected_amount = case when st.task in ('COBRANZA','AMBAS') and coalesce(col->>'status','PENDIENTE') <> 'PENDIENTE' then nullif(col->>'amount','')::numeric else collected_amount end,
    payment_mode = case when st.task in ('COBRANZA','AMBAS') and coalesce(col->>'status','PENDIENTE') <> 'PENDIENTE' then col->>'mode' else payment_mode end,
    collection_note = case when st.task in ('COBRANZA','AMBAS') and coalesce(col->>'status','PENDIENTE') <> 'PENDIENTE' then nullif(trim(col->>'note'),'') else collection_note end
  where id = p_stop returning * into st;
  if p_outcome in ('ENTREGADO','ENTREGA_PARCIAL') then
    -- La entrega guarda el email USADO (inmutable aunque el perfil cambie después)
    if sig is not null then
      insert into public.stop_evidence(stop_id, receiver_name, signature_png, signature_sha256, receiver_cuil, created_by, receiver_email, receiver_dni, evidence_kind, receiver_doc_type, receiver_doc_declared, receiver_doc_valid, receiver_doc_issue, receiver_cuit)
      values (p_stop, coalesce(nullif(trim(ev->>'receiver_name'), ''), 'Sin receptor (tarea)'), sig, encode(sha256(sig), 'hex'), v_cuil, auth.uid(), case when v_commercial then v_email end, v_dni,
              case when st.stop_type = 'UBICACION_INTERNA' then 'RECEPCION_INTERNA' when v_task then 'TAREA' else 'ENTREGA_CLIENTE' end, case when v_doc_type in ('DNI', 'CUIL', 'CUIT') then v_doc_type when v_doc_type is null and v_doc <> '' then 'CUIL' end,
              nullif(v_doc_raw, ''), v_doc_issue is null and v_doc <> '', v_doc_issue, v_cuit)
      on conflict (stop_id) do nothing;
      -- V4.28: documento A REVISAR → UNA incidencia por entrega (idempotente) + alertas a Administración y al Superior responsable (sin bloquear)
      if v_doc_issue is not null then perform public._receiver_doc_flag(st, r, coalesce(nullif(trim(ev->>'receiver_name'), ''), 'Sin nombre'), v_doc_type, v_doc_raw, v_doc_issue); end if;
    end if;
    -- RECEPCIÓN INTERNA DE TRASLADO: queda trazado qué pedidos llegaron a qué sucursal, quién recibió, quién trasladó, cuándo y dónde
    if st.stop_type = 'UBICACION_INTERNA' then
      insert into public.audit_log(actor_id, action, target_type, target_id, after)
      values (auth.uid(), 'INTERNAL_TRANSFER_RECEIVED', 'route_stop', p_stop::text, jsonb_build_object(
        'route_id', st.route_id, 'route_number', r.number, 'internal_location_key', st.internal_location_key, 'location_name', st.client_name, 'address', st.address,
        'order_numbers', to_jsonb(st.order_numbers), 'outcome', p_outcome, 'receiver_name', trim(ev->>'receiver_name'), 'signature_sha256', encode(sha256(sig), 'hex'),
        'transported_by', auth.uid(), 'at', now(), 'gps', loc));
    end if;
    -- Perfil reutilizable (misma capa de identidad que el DNI): nombre, DNI y email para próximas entregas
    if v_commercial and v_cuil is not null and coalesce(v_doc_type, 'CUIL') = 'CUIL' and v_doc_issue is null then perform public._upsert_identity_profile(v_cuil, trim(ev->>'receiver_name'), v_dni, v_email, st.client_key); end if;   -- V4.28: el padrón de identidad PERSONAL solo con un CUIL VÁLIDO (nunca un CUIT de empresa ni un documento no validado)
    -- Recibido Conforme: entrega TOTAL confirmada + email válido → comprobante único + envío automático (la falla del email nunca revierte la entrega)
    if v_commercial and p_outcome = 'ENTREGADO' and v_email is not null then perform public._create_delivery_receipt(st, r, trim(ev->>'receiver_name'), v_email); v_receipt := true; end if;
    if v_commercial and coalesce(trim(st.customer_email), '') <> '' and not v_receipt then
      insert into public.customer_email_jobs(route_id, stop_id, kind, recipient, idempotency_key)
      values (st.route_id, st.id, case when p_outcome = 'ENTREGADO' then 'DELIVERED' else 'PARTIAL' end, lower(trim(st.customer_email)), st.route_id || '|' || st.id || '|' || case when p_outcome = 'ENTREGADO' then 'DELIVERED' else 'PARTIAL' end)
      on conflict (idempotency_key) do nothing;
    end if;
  end if;
  if p_op_id is not null then insert into public.stop_outcome_ops(op_id, stop_id) values (p_op_id, p_stop); end if;
  perform public._queue_on_the_way(st.route_id);
  return st;
end; $function$;

-- delivery_identity_lookup: un CUIT (aun histórico) NUNCA se devuelve como CUIL personal ni consulta el padrón de identidad
create or replace function public.delivery_identity_lookup(p_stop uuid, p_cuil text default null, p_dni text default null) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare st public.route_stops; r public.routes; p public.customer_identity_docs; c text := nullif(regexp_replace(coalesce(p_cuil,''), '\D', '', 'g'), ''); d text := nullif(regexp_replace(coalesce(p_dni,''), '\D', '', 'g'), ''); ev record;
begin
  select * into st from public.route_stops where id = p_stop;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  select * into r from public.routes where id = st.route_id;
  if not (r.responsable_id = auth.uid() or public.auth_is_admin()) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if c is not null and c ~ '^(20|23|24|27)[0-9]{9}$' then select * into p from public.customer_identity_docs where cuil = c; end if;   -- V4.28: el padrón PERSONAL solo se consulta con un CUIL de persona (nunca un CUIT)
  if p.cuil is null and d is not null then select * into p from public.customer_identity_docs where dni = d and cuil ~ '^(20|23|24|27)[0-9]{9}$' order by updated_at desc nulls last limit 1; end if;   -- B3 (auditoría de Work): por DNI, SOLO un CUIL de persona (nunca un CUIT histórico)
  if p.cuil is not null then
    return jsonb_build_object('source', case when c is not null and p.cuil = c then 'CUIL' else 'DNI' end, 'cuil', case when p.cuil ~ '^(20|23|24|27)[0-9]{9}$' then p.cuil end,   -- B3: segunda capa
 'dni', p.dni, 'full_name', p.full_name, 'email', p.email,
      'has_dni_photo', p.storage_path is not null or p.dni_photo is not null);
  end if;
  if coalesce(st.client_key, '') <> '' then
    select e.receiver_name, e.receiver_email, e.receiver_cuil, e.receiver_dni, e.receiver_doc_type, e.receiver_doc_valid into ev from public.stop_evidence e join public.route_stops s2 on s2.id = e.stop_id
      where s2.client_key = st.client_key and e.receiver_email is not null order by e.created_at desc limit 1;
    if ev.receiver_email is not null then
      return jsonb_build_object('source', 'CLIENTE', 'cuil', case when ev.receiver_cuil ~ '^(20|23|24|27)[0-9]{9}$' and coalesce(ev.receiver_doc_type, 'CUIL') = 'CUIL' and ev.receiver_doc_valid is not false then ev.receiver_cuil end,   -- V4.28: nunca un CUIT (ni histórico) como CUIL personal
 'dni', ev.receiver_dni, 'full_name', ev.receiver_name, 'email', ev.receiver_email,
        'has_dni_photo', ev.receiver_cuil is not null and exists (select 1 from public.customer_identity_docs x where x.cuil = ev.receiver_cuil and (x.storage_path is not null or x.dni_photo is not null)));
    end if;
  end if;
  return null;
end; $$;

-- search_deliveries: devuelve también tipo, CUIT, DNI y lo declarado, con el MISMO control (signatures.view) que el CUIL
create or replace function public.search_deliveries(p_query text) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me public.profiles; q text := btrim(coalesce(p_query, '')); dg text; qpv text; qnum text; sig boolean; out jsonb := '[]'; rec record;
begin
  select * into me from public.profiles where id = auth.uid() and status = 'ACTIVO';
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  dg := regexp_replace(q, '\D', '', 'g');
  if length(dg) < 3 and q !~ '^[0-9]{2}-[0-9]{6}$' then raise exception 'QUERY_TOO_SHORT: ingresá al menos 3 dígitos' using errcode = '22023'; end if;
  qnum := ltrim(case when q ~ '-' then split_part(regexp_replace(q, '[^0-9-]', '', 'g'), '-', 2) else dg end, '0');
  qpv := case when q ~ '-' then ltrim(split_part(regexp_replace(q, '[^0-9-]', '', 'g'), '-', 1), '0') end;
  sig := false; -- Se verifica por hoja con la MISMA protección de las políticas RLS vigentes.
  for rec in
    select r.id rid, r.number, r.operational_status, r.published_at, r.started_at, r.completed_at, r.carrier_id, c.name carrier_name, rp.full_name responsable_name,
           s.id sid, s.client_name, s.address, s.order_numbers, s.outcome, s.outcome_note, s.arrived_at, s.stop_type,
           (select x->'r'->>'fecha' from jsonb_array_elements(coalesce(r.sheet_snapshot->'pdf_model'->'data', '[]')) x where x->'r' ? 'fecha' limit 1) sheet_date,
           (select string_agg(distinct d, ' · ') from jsonb_array_elements(coalesce(r.sheet_snapshot->'pdf_model'->'data', '[]')) x, lateral (values (x->'r'->>'mainDoc'), (x->'r'->>'shipDoc')) v(d)
              where d is not null and d <> '' and (x->'r'->>'mainOrder' = any(s.order_numbers) or x->'r'->>'shipOrder' = any(s.order_numbers))) docs,
           ev.receiver_name, ev.receiver_cuil, ev.receiver_cuit, ev.receiver_dni, ev.receiver_doc_type, ev.receiver_doc_declared, ev.receiver_doc_valid, ev.created_at received_at, (ev.stop_id is not null) has_signature, dr.receipt_number, dr.generated_at receipt_at
      from public.route_stops s join public.routes r on r.id = s.route_id left join public.carriers c on c.id = r.carrier_id left join public.profiles rp on rp.id = r.responsable_id
      left join public.stop_evidence ev on ev.stop_id = s.id left join public.delivery_receipts dr on dr.stop_id = s.id
     where r.operational_status <> 'BORRADOR' and coalesce(s.stop_type, 'PEDIDO') = 'PEDIDO'
       and (public._is_general_admin() or public.can_view_route_row(r.id, r.published_by, r.responsable_id))   -- SOLO hojas que el usuario puede ver (equipo / propias / todas)
       and ( dg = any(s.order_numbers) or r.number = q
          or exists (select 1 from jsonb_array_elements(coalesce(r.sheet_snapshot->'pdf_model'->'data', '[]')) x, lateral (values (x->'r'->>'mainDoc', x->'r'->>'mainOrder'), (x->'r'->>'shipDoc', x->'r'->>'shipOrder')) v(d, o)
                      where o = any(s.order_numbers) and d is not null and qnum <> ''
                        and ltrim(split_part(regexp_replace(d, '[^0-9-]', '', 'g'), '-', 2), '0') = qnum
                        and (qpv is null or ltrim(split_part(regexp_replace(d, '[^0-9-]', '', 'g'), '-', 1), '0') = qpv)) )
     order by r.published_at desc limit 30
  loop
    sig:=okd_delivery_security.may_read(rec.rid) and (public._is_general_admin() or public.can_view_route(rec.rid));
    out := out || jsonb_build_object('route_id', rec.rid, 'route_number', rec.number, 'route_status', rec.operational_status, 'carrier', coalesce(rec.carrier_name, rec.carrier_id), 'responsable', rec.responsable_name,
      'published_at', rec.published_at, 'started_at', rec.started_at, 'completed_at', rec.completed_at, 'sheet_date', rec.sheet_date,
      'stop_id', rec.sid, 'client_name', rec.client_name, 'address', rec.address, 'order_numbers', to_jsonb(rec.order_numbers), 'docs', rec.docs,
      'outcome', rec.outcome, 'outcome_note', rec.outcome_note, 'arrived_at', rec.arrived_at, 'received_at', rec.received_at,
      'has_receipt', rec.receipt_number is not null, 'signatures_visible', sig,
      -- datos personales y constancia SOLO con signatures.view (los demás ven el estado, no quién firmó)
      'receiver_name', case when sig then rec.receiver_name end, 'receiver_cuil', case when sig then rec.receiver_cuil end, 'receiver_cuit', case when sig then rec.receiver_cuit end, 'receiver_dni', case when sig then rec.receiver_dni end,
      'receiver_doc_type', case when sig then rec.receiver_doc_type end, 'receiver_doc_declared', case when sig then rec.receiver_doc_declared end, 'receiver_doc_valid', case when sig then rec.receiver_doc_valid end,
      'has_signature', case when sig then rec.has_signature end, 'receipt_number', case when sig then rec.receipt_number end, 'receipt_at', case when sig then rec.receipt_at end);
  end loop;
  return out;
end; $$;

-- ---------- 2) HISTORIAL DE CAMBIOS (legible, del servidor) ----------
create or replace function public.route_change_history(p_route uuid) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare out jsonb;
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and status = 'ACTIVO') or not public.can_view_route(p_route) then raise exception 'FORBIDDEN_ROUTE' using errcode = '42501'; end if;
  select coalesce(jsonb_agg(e order by (e->>'at') desc nulls last), '[]') into out from (
    select jsonb_build_object('at', coalesce((to_jsonb(s)->>'outcome_at')::timestamptz, (to_jsonb(s)->>'resolved_at')::timestamptz, (to_jsonb(s)->>'updated_at')::timestamptz), 'tipo', 'RESULTADO ORIGINAL', 'parada', s.client_name,
      'resultado', s.outcome, 'motivo', coalesce(s.outcome_note, to_jsonb(s)->>'outcome_reason'), 'usuario', (select full_name from public.profiles where id::text = to_jsonb(s)->>'outcome_by')) e
      from public.route_stops s where s.route_id = p_route and s.outcome <> 'PENDIENTE'
    union all
    select jsonb_build_object('at', c.at, 'tipo', case c.event_type when 'INTERNAL_STOP_ADDED' then 'PARADA AGREGADA' when 'INTERNAL_STOPS_REORDERED' then 'PARADAS REORDENADAS' else replace(c.event_type, '_', ' ') end,
      'parada', (select client_name from public.route_stops where id::text = c.stop_id), 'motivo', c.note, 'usuario', (select full_name from public.profiles where id = c.user_id))
      from public.route_change_events c where c.route_id = p_route
    union all
    select jsonb_build_object('at', q.requested_at, 'tipo', 'SOLICITUD · ' || case q.request_type when 'INTERNAL_ROUTE_CHANGE' then 'CAMBIOS DE RUTA INTERNA' when 'OTRO' then coalesce(q.payload->>'accion', 'OTRA ACCIÓN') else replace(q.request_type, '_', ' ') end,
      'parada', q.payload->>'parada', 'resultado', q.payload->>'resultado_actual', 'nuevo', q.payload->>'propuesta', 'motivo', q.reason, 'estado', q.status,
      'usuario', (select full_name from public.profiles where id = q.requested_by),
      'resuelto_por', (select full_name from public.profiles where id = q.reviewed_by), 'resuelto_at', q.reviewed_at, 'nota_resolucion', q.review_note)
      from public.route_approval_requests q where q.route_id = p_route
    union all
    select jsonb_build_object('at', v.created_at, 'tipo', 'DOCUMENTO DEL RECEPTOR A REVISAR', 'parada', (select client_name from public.route_stops where id = v.stop_id), 'motivo', v.issue,
      'estado', v.status, 'usuario', (select full_name from public.profiles where id = v.driver_id), 'resuelto_por', (select full_name from public.profiles where id = v.corrected_by),
      'resuelto_at', v.corrected_at, 'nota_resolucion', v.correction_reason)
      from public.receiver_doc_reviews v where v.route_id = p_route
    union all
    select jsonb_build_object('at', c.corrected_at, 'tipo', case when c.is_rectification then 'RECTIFICACIÓN DEL DOCUMENTO' else 'CORRECCIÓN DEL DOCUMENTO' end, 'parada', (select client_name from public.route_stops where id = c.stop_id),
      'motivo', c.reason, 'usuario', (select full_name from public.profiles where id = c.corrected_by))
      from public.receiver_doc_corrections c join public.receiver_doc_reviews v on v.stop_id = c.stop_id where v.route_id = p_route
    union all
    select jsonb_build_object('at', f.created_at, 'tipo', f.kind, 'parada', (select client_name from public.route_stops where id = f.stop_id), 'motivo', f.note,
      'estado', (select status from public.route_approval_requests where id = f.request_id), 'usuario', (select full_name from public.profiles where id = f.created_by))
      from public.stop_followups f where f.route_id = p_route
  ) x;
  return out;
end; $$;



do $$ declare f text; begin
  foreach f in array array['add_stop_followup(uuid,text,text,uuid,text)', 'route_change_history(uuid)', 'list_receiver_doc_reviews(text)', 'correct_receiver_doc(uuid,text,text,text,boolean)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon'; execute 'grant execute on function public.' || f || ' to authenticated'; end loop;
  foreach f in array array['_doc_review_responsible(uuid)', 'trg_stop_followups_immutable()', 'trg_receiver_doc_reviews_guard()', 'trg_receiver_doc_corrections_immutable()', '_receiver_doc_flag(public.route_stops,public.routes,text,text,text,text)', '_receiver_doc_issue(text,text,boolean)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon, authenticated'; end loop;
end $$;
DO $post$ BEGIN
  IF (SELECT prosrc FROM pg_proc WHERE oid = 'public.set_stop_outcome(uuid,text,text,text,text,jsonb)'::regprocedure) NOT LIKE '%_receiver_doc_flag%'
     OR (SELECT prosrc FROM pg_proc WHERE oid = 'public.set_stop_outcome(uuid,text,text,text,text,jsonb)'::regprocedure) ~ '(CUIL_INVALID|DNI_INVALID|DOC_TYPE_INVALID)'
     OR (SELECT prosrc FROM pg_proc WHERE oid = 'public.delivery_identity_lookup(uuid,text,text)'::regprocedure) NOT LIKE '%(20|23|24|27)%'
     OR (SELECT prosrc FROM pg_proc WHERE oid = 'public.search_deliveries(text)'::regprocedure) NOT LIKE '%receiver_cuit%'
     OR (SELECT prosrc FROM pg_proc WHERE oid = 'public.set_stop_outcome(uuid,text,text,text,text,jsonb)'::regprocedure) !~ 'coalesce\(v_doc_type, ''CUIL''\) = ''CUIL'' and v_doc_issue is null then perform public._upsert_identity_profile' OR to_regclass('public.receiver_doc_reviews') IS NULL THEN RAISE EXCEPTION 'HUELLA_FINAL_INESPERADA'; END IF;
END $post$;
COMMIT;
