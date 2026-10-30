-- =====================================================================================================================
-- PROPUESTA · NO APLICADA · COMUNICACIONES INTERNAS (colaboradores, comunicados, programación, cola de envío por Gmail, WhatsApp manual)
--  · Permisos propios comms.* (ADMIN por rol; a otros usuarios, con el editor de permisos existente). Cada operación se valida AQUÍ.
--  · Lectura con RLS (comms.view); escrituras SOLO por funciones SECURITY DEFINER que verifican el permiso.
--  · Cola: reserva atómica (FOR UPDATE SKIP LOCKED), clave única ejecución + destinatario, reintentos limitados, "Por verificar".
--  · Gmail: el token de actualización se guarda CIFRADO en Supabase Vault; solo el servidor (service_role) lo lee. Nunca vuelve al navegador.
--  · No toca ni activa los correos automáticos existentes de Despacho.
-- =====================================================================================================================

-- ---------- Permisos ----------
insert into public.permissions(code) values ('comms.view'), ('comms.collaborators_manage'), ('comms.compose'), ('comms.schedule'), ('comms.test_send'), ('comms.gmail_manage')
  on conflict do nothing;
insert into public.role_permissions(role_code, permission_code)
  select 'ADMIN', c from unnest(array['comms.view','comms.collaborators_manage','comms.compose','comms.schedule','comms.test_send','comms.gmail_manage']) c
  on conflict do nothing;

create or replace function public._comm_need(p_perm text) returns void language plpgsql stable security definer set search_path = public as $$
begin if not public.auth_has_perm(p_perm) then raise exception 'FORBIDDEN: falta el permiso %', p_perm using errcode = '42501'; end if; end; $$;
revoke execute on function public._comm_need(text) from public, anon;

-- ---------- Tablas ----------
create table if not exists public.comm_collaborators (
  id uuid primary key default gen_random_uuid(), full_name text not null check (length(trim(full_name)) > 0), email text not null,
  phone text, branch text, sector text, active boolean not null default true,
  created_at timestamptz not null default now(), created_by uuid, updated_at timestamptz not null default now(), updated_by uuid);
create unique index if not exists comm_collaborators_email_uq on public.comm_collaborators (lower(email));

create table if not exists public.comm_messages (
  id uuid primary key default gen_random_uuid(), internal_name text not null check (length(trim(internal_name)) > 0),
  subject text not null default '', body_html text not null default '', from_name text not null default 'OK Accesorios',
  selection jsonb not null default '{}'::jsonb, schedule jsonb,
  status text not null default 'BORRADOR' check (status in ('BORRADOR','ACTIVO','PAUSADO','CANCELADO','FINALIZADO')),
  version int not null default 1, active_since timestamptz, cursor timestamptz,
  created_at timestamptz not null default now(), created_by uuid, updated_at timestamptz not null default now(), updated_by uuid,
  -- defensa en el servidor: el texto con formato llega sanitizado; igualmente se rechaza contenido activo
  constraint comm_body_safe check (body_html !~* '<\s*(script|iframe|object|embed|style|svg)|javascript:|\son[a-z]+\s*='));

create table if not exists public.comm_attachments (
  id uuid primary key default gen_random_uuid(), message_id uuid not null references public.comm_messages(id),
  storage_path text not null unique, file_name text not null, mime text not null check (mime in ('image/png','image/jpeg','image/webp','image/gif','application/pdf')),
  size_bytes bigint not null check (size_bytes > 0 and size_bytes <= 8388608), sha256 text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  detached boolean not null default false, created_at timestamptz not null default now(), created_by uuid);

create table if not exists public.comm_runs (
  id uuid primary key default gen_random_uuid(), message_id uuid not null references public.comm_messages(id),
  scheduled_for timestamptz not null, kind text not null check (kind in ('PROGRAMADO','PRUEBA')),
  status text not null default 'PENDIENTE' check (status in ('PENDIENTE','EN_CURSO','COMPLETADA','PERDIDA','CANCELADA')),
  snapshot jsonb not null, recipients_count int not null default 0, note text, created_at timestamptz not null default now(), created_by uuid,
  unique (message_id, scheduled_for, kind));

create table if not exists public.comm_deliveries (
  id bigint generated always as identity primary key, run_id uuid not null references public.comm_runs(id),
  collaborator_id uuid, email text, name text,
  status text not null default 'PENDIENTE' check (status in ('PENDIENTE','PROCESANDO','ENVIADO','ERROR','POR_VERIFICAR','CANCELADO','OMITIDO','VENCIDO')),
  attempts int not null default 0, retryable boolean not null default true, next_attempt_at timestamptz,
  claim_token uuid, claimed_at timestamptz, worker text, gmail_message_id text, sent_at timestamptz,
  stale_token uuid,              -- token de un trabajo interrumpido: si Gmail había aceptado y el registro llega tarde, se acepta (con su id)
  manual_ok_until timestamptz,   -- habilitación MANUAL de un vencido o "por verificar" (no lo vence la ventana durante 1 h)
  sent_at_source text check (sent_at_source in ('GMAIL','ESTIMADA_INICIO_INTENTO')),   -- de dónde sale sent_at: respuesta de Gmail o estimación
  confirmed_at timestamptz, confirmed_by uuid,                                          -- confirmación MANUAL (distinta de la hora de envío)
  last_error text, error_code text, reason text, updated_at timestamptz not null default now());
-- CLAVE ÚNICA por ejecución y destinatario (dos trabajadores nunca crean ni procesan dos veces el mismo envío)
create unique index if not exists comm_deliveries_run_dest_uq on public.comm_deliveries (run_id, coalesce(lower(email), 'omitido:' || coalesce(collaborator_id::text, name)));
create index if not exists comm_deliveries_queue_idx on public.comm_deliveries (status, next_attempt_at);

-- Limitador COMPARTIDO de llamadas a Gmail API (una cuenta conectada): ventanas de 60 s y de 1 s, para todos los trabajadores y pruebas
create table if not exists public.comm_rate_events (id bigint generated always as identity primary key, at timestamptz not null default clock_timestamp(), units int not null);
create index if not exists comm_rate_events_at_idx on public.comm_rate_events (at);
alter table public.comm_rate_events enable row level security;
create table if not exists public.comm_whatsapp_shares (id bigint generated always as identity primary key, message_id uuid not null references public.comm_messages(id),
  shared_by uuid not null, shared_at timestamptz not null default now(), note text);
create table if not exists public.comm_audit (id bigint generated always as identity primary key, message_id uuid, entity text not null, action text not null,
  actor uuid, at timestamptz not null default now(), detail jsonb not null default '{}'::jsonb);
create table if not exists public.comm_dispatches (id bigint generated always as identity primary key, at timestamptz not null default now(), worker text, status text,
  created int, missed int, claimed int, sent int, retry int, failed int, verify int, skipped int, note text);
-- estado de la conexión (sin secretos) y estados OAuth de un solo uso: sin acceso directo desde el navegador
create table if not exists public.comm_gmail_status (id int primary key default 1 check (id = 1), connected boolean not null default false, email text,
  connected_by uuid, connected_at timestamptz, needs_reconnect boolean not null default false, last_error text, last_error_at timestamptz, secret_id uuid);
insert into public.comm_gmail_status(id) values (1) on conflict do nothing;
create table if not exists public.comm_oauth_states (state text primary key, created_by uuid not null, created_at timestamptz not null default now(),
  expires_at timestamptz not null, used_at timestamptz);

alter table public.comm_collaborators enable row level security; alter table public.comm_messages enable row level security;
alter table public.comm_attachments enable row level security; alter table public.comm_runs enable row level security;
alter table public.comm_deliveries enable row level security; alter table public.comm_whatsapp_shares enable row level security;
alter table public.comm_audit enable row level security; alter table public.comm_dispatches enable row level security;
alter table public.comm_gmail_status enable row level security; alter table public.comm_oauth_states enable row level security;
-- PRIVILEGIOS de los objetos NUEVOS del módulo: se revoca TODO lo heredado (en producción, los privilegios por defecto dan a anon y
-- authenticated INSERT/UPDATE/DELETE/TRUNCATE/REFERENCES/TRIGGER; RLS no protege TRUNCATE) y se concede SOLO lo necesario.
do $$ declare t text; begin
  foreach t in array array['comm_collaborators','comm_messages','comm_attachments','comm_runs','comm_deliveries','comm_whatsapp_shares','comm_audit','comm_dispatches','comm_gmail_status','comm_oauth_states','comm_rate_events'] loop
    execute format('revoke all on table public.%I from public, anon, authenticated', t);
  end loop;
  foreach t in array array['comm_collaborators','comm_messages','comm_attachments','comm_runs','comm_deliveries','comm_whatsapp_shares','comm_audit','comm_dispatches'] loop
    execute format('drop policy if exists %I on public.%I', t || '_read', t);
    execute format('create policy %I on public.%I for select to authenticated using (public.auth_has_perm(''comms.view''))', t || '_read', t);
    execute format('grant select on table public.%I to authenticated', t);   -- SOLO lectura (filtrada por RLS); escrituras por funciones
  end loop;
  foreach t in array array['comm_deliveries_id_seq','comm_whatsapp_shares_id_seq','comm_audit_id_seq','comm_dispatches_id_seq','comm_rate_events_id_seq'] loop
    execute format('revoke all on sequence public.%I from public, anon, authenticated', t);
  end loop;
end $$;
grant select on table public.comm_gmail_status to service_role;   -- el despachador lee el estado (sin secretos)

-- ---------- Almacenamiento PRIVADO de adjuntos (sin borrar ni reemplazar: las ejecuciones conservan su copia) ----------
insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
  values ('comm-attachments', 'comm-attachments', false, 8388608, array['image/png','image/jpeg','image/webp','image/gif','application/pdf'])
  on conflict (id) do update set public = false, file_size_limit = 8388608, allowed_mime_types = excluded.allowed_mime_types;
drop policy if exists comm_attachments_upload on storage.objects;
create policy comm_attachments_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'comm-attachments' and public.auth_has_perm('comms.compose') and name ~ '^messages/[0-9a-f-]{36}/[0-9a-f-]{36}\.(png|jpg|webp|gif|pdf)$');
drop policy if exists comm_attachments_read on storage.objects;
create policy comm_attachments_read on storage.objects for select to authenticated using (bucket_id = 'comm-attachments' and public.auth_has_perm('comms.view'));

create or replace function public._comm_audit(p_msg uuid, p_entity text, p_action text, p_detail jsonb default '{}'::jsonb) returns void
language sql security definer set search_path = public as $$ insert into public.comm_audit(message_id, entity, action, actor, detail) values (p_msg, p_entity, p_action, auth.uid(), coalesce(p_detail, '{}'::jsonb)); $$;
revoke execute on function public._comm_audit(uuid, text, text, jsonb) from public, anon, authenticated;

-- ---------- Colaboradores ----------
create or replace function public.comm_save_collaborator(p jsonb) returns public.comm_collaborators language plpgsql security definer set search_path = public as $$
declare r public.comm_collaborators; v_email text := lower(trim(coalesce(p->>'email', '')));
begin
  perform public._comm_need('comms.collaborators_manage');
  if length(trim(coalesce(p->>'full_name', ''))) = 0 then raise exception 'NOMBRE_REQUERIDO: indicá nombre y apellido' using errcode = '22023'; end if;
  if v_email !~ '^[^\s@<>()",;]+@[^\s@<>()",;]+\.[a-z]{2,}$' then raise exception 'CORREO_INVALIDO: %', v_email using errcode = '22023'; end if;
  if p ? 'id' and nullif(p->>'id', '') is not null then
    update public.comm_collaborators set full_name = trim(p->>'full_name'), email = v_email, phone = nullif(trim(p->>'phone'), ''), branch = nullif(trim(p->>'branch'), ''),
      sector = nullif(trim(p->>'sector'), ''), active = coalesce((p->>'active')::boolean, active), updated_at = now(), updated_by = auth.uid()
      where id = (p->>'id')::uuid returning * into r;
    if not found then raise exception 'NO_ENCONTRADO' using errcode = 'P0002'; end if;
  else
    insert into public.comm_collaborators(full_name, email, phone, branch, sector, active, created_by, updated_by)
      values (trim(p->>'full_name'), v_email, nullif(trim(p->>'phone'), ''), nullif(trim(p->>'branch'), ''), nullif(trim(p->>'sector'), ''), coalesce((p->>'active')::boolean, true), auth.uid(), auth.uid())
      returning * into r;
  end if;
  perform public._comm_audit(null, 'COLABORADOR', case when p ? 'id' and nullif(p->>'id', '') is not null then 'MODIFICADO' else 'CREADO' end, jsonb_build_object('collaborator_id', r.id, 'active', r.active));
  return r;
exception when unique_violation then raise exception 'CORREO_DUPLICADO: ya hay un colaborador con %', v_email using errcode = '23505';
end; $$;

-- ---------- Comunicados ----------
create or replace function public.comm_save_message(p jsonb, p_confirm boolean default false) returns public.comm_messages language plpgsql security definer set search_path = public as $$
declare r public.comm_messages; old public.comm_messages; changed text[] := '{}';
begin
  perform public._comm_need('comms.compose');
  if nullif(p->>'id', '') is null then
    insert into public.comm_messages(internal_name, subject, body_html, selection, schedule, from_name, created_by, updated_by)
      values (trim(coalesce(p->>'internal_name', '')), coalesce(p->>'subject', ''), coalesce(p->>'body_html', ''), coalesce(p->'selection', '{}'::jsonb), p->'schedule',
              coalesce(nullif(p->>'from_name', ''), 'OK Accesorios'), auth.uid(), auth.uid()) returning * into r;
    perform public._comm_audit(r.id, 'COMUNICADO', 'CREADO', '{}'::jsonb); return r;
  end if;
  select * into old from public.comm_messages where id = (p->>'id')::uuid for update;
  if not found then raise exception 'NO_ENCONTRADO' using errcode = 'P0002'; end if;
  if old.status in ('CANCELADO','FINALIZADO') then raise exception 'NO_EDITABLE: el comunicado está %; duplicalo para reutilizarlo', old.status using errcode = '22023'; end if;
  if coalesce(p->>'subject', old.subject) is distinct from old.subject then changed := array_append(changed, 'asunto'); end if;
  if coalesce(p->>'body_html', old.body_html) is distinct from old.body_html then changed := array_append(changed, 'contenido'); end if;
  if coalesce(p->'selection', old.selection) is distinct from old.selection then changed := array_append(changed, 'destinatarios'); end if;
  if (p ? 'schedule') and (p->'schedule') is distinct from old.schedule then changed := array_append(changed, 'programación'); end if;
  -- un comunicado ACTIVO/PAUSADO afecta próximos envíos: se exige confirmación explícita (y permiso de programar si cambia la programación)
  if old.status in ('ACTIVO','PAUSADO') and cardinality(changed) > 0 and not p_confirm then
    raise exception 'CONFIRMATION_REQUIRED: el cambio (%) afecta los próximos envíos', array_to_string(changed, ', ') using errcode = '22023'; end if;
  if old.status in ('ACTIVO','PAUSADO') and 'programación' = any(changed) then perform public._comm_need('comms.schedule'); end if;
  update public.comm_messages set internal_name = coalesce(nullif(trim(p->>'internal_name'), ''), internal_name), subject = coalesce(p->>'subject', subject),
    body_html = coalesce(p->>'body_html', body_html), selection = coalesce(p->'selection', selection), schedule = case when p ? 'schedule' then p->'schedule' else schedule end,
    from_name = coalesce(nullif(p->>'from_name', ''), from_name), version = version + case when cardinality(changed) > 0 then 1 else 0 end,
    -- nueva programación en un comunicado activo: rige desde ahora (no se "recupera" lo vencido)
    cursor = case when 'programación' = any(changed) and status = 'ACTIVO' then greatest(coalesce(cursor, now()), now()) else cursor end,
    active_since = case when 'programación' = any(changed) and status = 'ACTIVO' then now() else active_since end,
    updated_at = now(), updated_by = auth.uid() where id = old.id returning * into r;
  perform public._comm_audit(r.id, 'COMUNICADO', 'MODIFICADO', jsonb_build_object('cambios', to_jsonb(changed), 'version', r.version, 'confirmado', p_confirm));
  return r;
end; $$;

create or replace function public.comm_duplicate_message(p_id uuid) returns public.comm_messages language plpgsql security definer set search_path = public as $$
declare src public.comm_messages; r public.comm_messages;
begin
  perform public._comm_need('comms.compose');
  select * into src from public.comm_messages where id = p_id; if not found then raise exception 'NO_ENCONTRADO' using errcode = 'P0002'; end if;
  insert into public.comm_messages(internal_name, subject, body_html, selection, schedule, from_name, created_by, updated_by)
    values (src.internal_name || ' (copia)', src.subject, src.body_html, src.selection, src.schedule, src.from_name, auth.uid(), auth.uid()) returning * into r;
  -- los adjuntos son inmutables: la copia referencia los mismos archivos
  insert into public.comm_attachments(message_id, storage_path, file_name, mime, size_bytes, sha256, created_by)
    select r.id, a.storage_path || '#copia-' || r.id, a.file_name, a.mime, a.size_bytes, a.sha256, auth.uid() from public.comm_attachments a where a.message_id = p_id and not a.detached;
  perform public._comm_audit(r.id, 'COMUNICADO', 'DUPLICADO', jsonb_build_object('origen', p_id)); return r;
end; $$;

-- El navegador SOLO sube el archivo al bucket privado. El registro lo hace la función comm-attachments del servidor, que descarga el
-- objeto, mide su tamaño REAL, detecta el formato por su CONTENIDO y calcula el hash: aquí no se confía en datos del navegador.
create or replace function public.comm_register_attachment_srv(p_message uuid, p_path text, p_name text, p_mime text, p_size bigint, p_sha text, p_actor uuid, p_confirm boolean default false)
returns public.comm_attachments language plpgsql security definer set search_path = public as $$
declare r public.comm_attachments; m public.comm_messages; tot bigint; n int; meta_size bigint;
begin
  if not public.user_has_perm(p_actor, 'comms.compose') then raise exception 'FORBIDDEN: falta el permiso comms.compose' using errcode = '42501'; end if;
  select * into m from public.comm_messages where id = p_message for update;   -- BLOQUEO: cargas simultáneas (y repeticiones) se serializan
  if not found then raise exception 'NO_ENCONTRADO' using errcode = 'P0002'; end if;
  -- IDEMPOTENTE: repetir una solicitud válida devuelve el adjunto existente (sin duplicar, sin cambiar la versión, sin auditar de nuevo)
  select * into r from public.comm_attachments where storage_path = p_path;
  if found then
    if r.message_id = p_message and r.sha256 = lower(p_sha) and r.size_bytes = p_size then return r; end if;
    raise exception 'RUTA_YA_REGISTRADA: esa ruta ya corresponde a otro adjunto' using errcode = '22023';
  end if;
  if m.status in ('CANCELADO','FINALIZADO') then raise exception 'NO_EDITABLE' using errcode = '22023'; end if;
  if m.status in ('ACTIVO','PAUSADO') and not p_confirm then raise exception 'CONFIRMATION_REQUIRED: agregar un adjunto afecta los próximos envíos' using errcode = '22023'; end if;
  if p_path !~ ('^messages/' || p_message::text || '/[0-9a-f-]{36}\.(png|jpg|webp|gif|pdf)$') then raise exception 'RUTA_INVALIDA' using errcode = '22023'; end if;
  select (o.metadata->>'size')::bigint into meta_size from storage.objects o where o.bucket_id = 'comm-attachments' and o.name = p_path;
  if not found then raise exception 'ARCHIVO_NO_SUBIDO' using errcode = '22023'; end if;
  if meta_size is not null and meta_size <> p_size then raise exception 'TAMANIO_INCONSISTENTE' using errcode = '22023'; end if;
  select coalesce(sum(size_bytes), 0), count(*) into tot, n from public.comm_attachments where message_id = p_message and not detached;
  if n + 1 > 6 then raise exception 'DEMASIADOS_ADJUNTOS: máximo 6' using errcode = '22023'; end if;
  if tot + p_size > 15728640 then raise exception 'ADJUNTOS_MUY_GRANDES: el máximo es 15 MB por comunicado' using errcode = '22023'; end if;
  insert into public.comm_attachments(message_id, storage_path, file_name, mime, size_bytes, sha256, created_by) values (p_message, p_path, p_name, p_mime, p_size, lower(p_sha), p_actor) returning * into r;
  update public.comm_messages set version = version + 1, updated_at = now(), updated_by = p_actor where id = p_message;   -- las copias de ejecuciones ya hechas no cambian
  insert into public.comm_audit(message_id, entity, action, actor, detail) values (p_message, 'ADJUNTO', 'AGREGADO', p_actor,
    jsonb_build_object('archivo', p_name, 'bytes', p_size, 'tipo', p_mime, 'confirmado', p_confirm, 'estado', m.status));
  return r;
end; $$;
-- ¿la ruta está referenciada por algún adjunto (incluidos quitados y copias de comunicados duplicados)? Nunca se borra si lo está.
create or replace function public.comm_attachment_registered(p_path text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.comm_attachments a where split_part(a.storage_path, '#', 1) = p_path); $$;
-- SOLO DIAGNÓSTICO (lectura): objetos sin referencias y antiguos. NO hay limpieza automática: los huérfanos se conservan hasta implementar
-- una limpieza coordinada con el registro (listar y borrar después no excluye un registro simultáneo de ese mismo archivo).
create or replace function public.comm_orphan_objects(p_min_age_hours int default 24, p_limit int default 20) returns setof text language sql stable security definer set search_path = public as $$
  select o.name from storage.objects o where o.bucket_id = 'comm-attachments' and o.created_at < now() - make_interval(hours => greatest(p_min_age_hours, 1))
     and not exists (select 1 from public.comm_attachments a where split_part(a.storage_path, '#', 1) = o.name)
   order by o.created_at limit greatest(p_limit, 0); $$;
create or replace function public.comm_detach_attachment(p_id uuid, p_confirm boolean default false) returns void language plpgsql security definer set search_path = public as $$
declare a public.comm_attachments; m public.comm_messages; begin
  perform public._comm_need('comms.compose');
  select * into a from public.comm_attachments where id = p_id; if not found then raise exception 'NO_ENCONTRADO' using errcode = 'P0002'; end if;
  select * into m from public.comm_messages where id = a.message_id for update;
  if m.status in ('CANCELADO','FINALIZADO') then raise exception 'NO_EDITABLE' using errcode = '22023'; end if;
  if m.status in ('ACTIVO','PAUSADO') and not p_confirm then raise exception 'CONFIRMATION_REQUIRED: quitar un adjunto afecta los próximos envíos' using errcode = '22023'; end if;
  update public.comm_attachments set detached = true where id = p_id;   -- el archivo se conserva para las ejecuciones que lo usaron
  update public.comm_messages set version = version + 1, updated_at = now(), updated_by = auth.uid() where id = m.id;
  perform public._comm_audit(m.id, 'ADJUNTO', 'QUITADO', jsonb_build_object('adjunto', p_id, 'archivo', a.file_name, 'confirmado', p_confirm, 'estado', m.status));
end; $$;

-- ---------- Programar / pausar / reanudar / cancelar ----------
create or replace function public.comm_activate(p_id uuid) returns public.comm_messages language plpgsql security definer set search_path = public as $$
declare r public.comm_messages; g public.comm_gmail_status;
begin
  perform public._comm_need('comms.schedule');
  select * into g from public.comm_gmail_status where id = 1;
  if not g.connected or g.needs_reconnect then raise exception 'GMAIL_NOT_CONNECTED: conectá Gmail antes de programar' using errcode = '22023'; end if;
  select * into r from public.comm_messages where id = p_id for update; if not found then raise exception 'NO_ENCONTRADO' using errcode = 'P0002'; end if;
  if r.status <> 'BORRADOR' then raise exception 'ESTADO_INVALIDO: %', r.status using errcode = '22023'; end if;
  if r.schedule is null or coalesce(r.schedule->>'kind', '') not in ('ONCE','DAILY','WEEKLY','MONTHLY') or coalesce(r.schedule->>'time', '') !~ '^\d{2}:\d{2}$' then
    raise exception 'PROGRAMACION_INVALIDA' using errcode = '22023'; end if;
  if r.selection = '{}'::jsonb or not (coalesce((r.selection->>'all')::boolean, false) or jsonb_array_length(coalesce(r.selection->'ids', '[]')) > 0
      or jsonb_array_length(coalesce(r.selection->'branches', '[]')) > 0 or jsonb_array_length(coalesce(r.selection->'sectors', '[]')) > 0) then
    raise exception 'SIN_DESTINATARIOS' using errcode = '22023'; end if;
  if length(trim(r.subject)) = 0 then raise exception 'SIN_ASUNTO' using errcode = '22023'; end if;
  update public.comm_messages set status = 'ACTIVO', active_since = now(), cursor = now(), updated_at = now(), updated_by = auth.uid() where id = p_id returning * into r;
  perform public._comm_audit(p_id, 'COMUNICADO', 'PROGRAMADO', jsonb_build_object('schedule', r.schedule)); return r;
end; $$;
create or replace function public.comm_pause(p_id uuid) returns void language plpgsql security definer set search_path = public as $$
begin perform public._comm_need('comms.schedule');
  update public.comm_messages set status = 'PAUSADO', updated_at = now(), updated_by = auth.uid() where id = p_id and status = 'ACTIVO';
  if not found then raise exception 'ESTADO_INVALIDO' using errcode = '22023'; end if;
  perform public._comm_audit(p_id, 'COMUNICADO', 'PAUSADO'); end; $$;
-- reanudar: la ventana arranca AHORA (lo que venció durante la pausa no se envía de golpe)
create or replace function public.comm_resume(p_id uuid) returns void language plpgsql security definer set search_path = public as $$
begin perform public._comm_need('comms.schedule');
  update public.comm_messages set status = 'ACTIVO', active_since = now(), cursor = now(), updated_at = now(), updated_by = auth.uid() where id = p_id and status = 'PAUSADO';
  if not found then raise exception 'ESTADO_INVALIDO' using errcode = '22023'; end if;
  perform public._comm_audit(p_id, 'COMUNICADO', 'REANUDADO'); end; $$;
create or replace function public.comm_cancel(p_id uuid) returns void language plpgsql security definer set search_path = public as $$
declare n int; begin perform public._comm_need('comms.schedule');
  update public.comm_messages set status = 'CANCELADO', updated_at = now(), updated_by = auth.uid() where id = p_id and status in ('BORRADOR','ACTIVO','PAUSADO');
  if not found then raise exception 'ESTADO_INVALIDO' using errcode = '22023'; end if;
  update public.comm_deliveries d set status = 'CANCELADO', reason = 'Comunicado cancelado', updated_at = now() from public.comm_runs r
   where r.id = d.run_id and r.message_id = p_id and r.kind = 'PROGRAMADO' and (d.status = 'PENDIENTE' or (d.status = 'ERROR' and d.retryable));
  get diagnostics n = row_count;
  -- los que estaban PROCESANDO se resuelven en la verificación previa al envío (lo que Gmail ya aceptó no se puede retirar)
  update public.comm_runs r set status = 'CANCELADA' where r.message_id = p_id and r.kind = 'PROGRAMADO' and r.status in ('PENDIENTE','EN_CURSO')
    and not exists (select 1 from public.comm_deliveries d where d.run_id = r.id and d.status = 'PROCESANDO');
  perform public._comm_audit(p_id, 'COMUNICADO', 'CANCELADO', jsonb_build_object('envios_cancelados', n)); end; $$;

create or replace function public.comm_request_test(p_id uuid, p_email text) returns uuid language plpgsql security definer set search_path = public as $$
declare m public.comm_messages; rid uuid; v text := lower(trim(p_email));
begin
  perform public._comm_need('comms.test_send');
  if v !~ '^[^\s@<>()",;]+@[^\s@<>()",;]+\.[a-z]{2,}$' then raise exception 'CORREO_INVALIDO' using errcode = '22023'; end if;
  select * into m from public.comm_messages where id = p_id; if not found then raise exception 'NO_ENCONTRADO' using errcode = 'P0002'; end if;
  insert into public.comm_runs(message_id, scheduled_for, kind, snapshot, recipients_count, created_by)
    values (p_id, clock_timestamp(), 'PRUEBA', jsonb_build_object('subject', '[PRUEBA] ' || m.subject, 'body_html', m.body_html, 'from_name', m.from_name, 'message_version', m.version,
      'attachments', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'name', a.file_name, 'mime', a.mime, 'size_bytes', a.size_bytes, 'sha256', a.sha256, 'storage_path', split_part(a.storage_path, '#', 1)))
        from public.comm_attachments a where a.message_id = p_id and not a.detached), '[]'::jsonb)), 1, auth.uid()) returning id into rid;
  insert into public.comm_deliveries(run_id, email, name) values (rid, v, 'Prueba');
  perform public._comm_audit(p_id, 'COMUNICADO', 'PRUEBA_SOLICITADA', jsonb_build_object('destino', v)); return rid;
end; $$;

-- WhatsApp: registro MANUAL, separado de los correos (no confirma recepción ni dispara correos)
create or replace function public.comm_register_whatsapp(p_id uuid, p_note text default null) returns bigint language plpgsql security definer set search_path = public as $$
declare n bigint; begin perform public._comm_need('comms.compose');
  if not exists (select 1 from public.comm_messages where id = p_id) then raise exception 'NO_ENCONTRADO' using errcode = 'P0002'; end if;
  insert into public.comm_whatsapp_shares(message_id, shared_by, note) values (p_id, auth.uid(), nullif(trim(p_note), '')) returning id into n;
  perform public._comm_audit(p_id, 'WHATSAPP', 'REGISTRADO_COMPARTIDO', jsonb_build_object('nota', p_note)); return n; end; $$;

-- "Por verificar": decisión humana (confirmado en Enviados de Gmail, o reintento autorizado)
create or replace function public.comm_resolve_verify(p_delivery bigint, p_result text) returns void language plpgsql security definer set search_path = public as $$
declare rid uuid; st text; begin perform public._comm_need('comms.schedule');
  if p_result not in ('CONFIRMADO_ENVIADO','REINTENTAR') then raise exception 'RESULTADO_INVALIDO' using errcode = '22023'; end if;
  select status into st from public.comm_deliveries where id = p_delivery for update;
  if st is null or st not in ('POR_VERIFICAR','VENCIDO') or (st = 'VENCIDO' and p_result = 'CONFIRMADO_ENVIADO') then raise exception 'ESTADO_INVALIDO' using errcode = '22023'; end if;
  update public.comm_deliveries set status = case when p_result = 'CONFIRMADO_ENVIADO' then 'ENVIADO' else 'PENDIENTE' end, retryable = true, attempts = least(attempts, 3),
    manual_ok_until = case when p_result = 'REINTENTAR' then now() + interval '1 hour' end, stale_token = null,
    -- confirmado a mano: la hora de envío NO se inventa. Si Gmail no la informó, se estima con el inicio del intento (claimed_at) y se rotula así;
    -- la confirmación queda aparte (quién y cuándo). El correo sigue contando en el cupo de 24 h desde ese intento.
    sent_at = case when p_result = 'CONFIRMADO_ENVIADO' then coalesce(sent_at, claimed_at, updated_at) else sent_at end,
    sent_at_source = case when p_result = 'CONFIRMADO_ENVIADO' then coalesce(sent_at_source, 'ESTIMADA_INICIO_INTENTO') else sent_at_source end,
    confirmed_at = case when p_result = 'CONFIRMADO_ENVIADO' then now() else confirmed_at end,
    confirmed_by = case when p_result = 'CONFIRMADO_ENVIADO' then auth.uid() else confirmed_by end,
    reason = case when p_result = 'CONFIRMADO_ENVIADO' then 'Confirmado manualmente en "Enviados" de Gmail' when st = 'VENCIDO' then 'Envío del vencido autorizado manualmente' else 'Reintento autorizado manualmente' end, updated_at = now()
    where id = p_delivery returning run_id into rid;
  perform public._comm_audit((select message_id from public.comm_runs where id = rid), 'ENVIO', 'VERIFICACION_' || p_result, jsonb_build_object('delivery', p_delivery, 'estado_previo', st)); end; $$;

-- ---------- Conexión Gmail (estado sin secretos; OAuth y token SOLO del lado del servidor) ----------
create or replace function public.comm_gmail_status() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare g public.comm_gmail_status; d public.comm_dispatches;
begin perform public._comm_need('comms.view');
  select * into g from public.comm_gmail_status where id = 1; select * into d from public.comm_dispatches order by id desc limit 1;
  return jsonb_build_object('connected', g.connected, 'email', g.email, 'connected_at', g.connected_at, 'needs_reconnect', g.needs_reconnect, 'last_error', g.last_error,
    'last_error_at', g.last_error_at, 'last_dispatch', case when d.id is null then null else jsonb_build_object('at', d.at, 'status', d.status, 'sent', d.sent, 'note', d.note) end);
end; $$;
create or replace function public.comm_oauth_begin() returns text language plpgsql security definer set search_path = public as $$
declare s text := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''); begin perform public._comm_need('comms.gmail_manage');   -- 244 bits aleatorios, sin pgcrypto
  delete from public.comm_oauth_states where expires_at < now() - interval '1 day';
  insert into public.comm_oauth_states(state, created_by, expires_at) values (s, auth.uid(), now() + interval '10 minutes'); return s; end; $$;
-- SOLO servidor (service_role): consumir el estado OAuth, guardar/leer el token cifrado, marcar errores, desconectar
create or replace function public.comm_oauth_consume(p_state text) returns uuid language plpgsql security definer set search_path = public as $$
declare who uuid; begin
  update public.comm_oauth_states set used_at = now() where state = p_state and used_at is null and expires_at > now() returning created_by into who;
  if who is null then raise exception 'OAUTH_STATE_INVALIDO' using errcode = '22023'; end if;
  if not public.user_has_perm(who, 'comms.gmail_manage') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return who; end; $$;
create or replace function public.comm_gmail_store(p_email text, p_refresh_token text, p_actor uuid) returns void language plpgsql security definer set search_path = public, vault as $$
declare sid uuid; begin
  select secret_id into sid from public.comm_gmail_status where id = 1;
  if sid is null or not exists (select 1 from vault.secrets where id = sid) then sid := vault.create_secret(p_refresh_token, 'comm_gmail_refresh_token', 'Comunicaciones: token de Gmail');
  else perform vault.update_secret(sid, p_refresh_token); end if;
  update public.comm_gmail_status set connected = true, email = lower(p_email), connected_by = p_actor, connected_at = now(), needs_reconnect = false, last_error = null, secret_id = sid where id = 1;
  insert into public.comm_audit(entity, action, actor, detail) values ('GMAIL', 'CONECTADO', p_actor, jsonb_build_object('email', lower(p_email))); end; $$;
create or replace function public.comm_gmail_secret() returns text language sql stable security definer set search_path = public, vault as $$
  select ds.decrypted_secret from vault.decrypted_secrets ds join public.comm_gmail_status g on g.secret_id = ds.id where g.id = 1 and g.connected; $$;
create or replace function public.comm_gmail_mark(p_needs_reconnect boolean, p_error text) returns void language sql security definer set search_path = public as $$
  update public.comm_gmail_status set needs_reconnect = p_needs_reconnect or needs_reconnect, last_error = left(p_error, 300), last_error_at = now() where id = 1; $$;
create or replace function public.comm_gmail_clear(p_actor uuid) returns void language plpgsql security definer set search_path = public, vault as $$
declare sid uuid; begin
  select secret_id into sid from public.comm_gmail_status where id = 1;
  if sid is not null then delete from vault.secrets where id = sid; end if;
  update public.comm_gmail_status set connected = false, email = null, needs_reconnect = false, secret_id = null, last_error = null where id = 1;
  insert into public.comm_audit(entity, action, actor) values ('GMAIL', 'DESCONECTADO', p_actor); end; $$;
create or replace function public.comm_can(p_perm text) returns boolean language sql stable security definer set search_path = public as $$
  select p_perm like 'comms.%' and public.auth_has_perm(p_perm); $$;

-- ---------- Cola (SOLO el despachador del servidor, service_role) ----------
create or replace function public.comm_list_active_messages() returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'subject', m.subject, 'body_html', m.body_html, 'from_name', m.from_name, 'version', m.version, 'selection', m.selection,
    'schedule', m.schedule, 'cursor', m.cursor, 'active_since', m.active_since,
    'attachments', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'name', a.file_name, 'mime', a.mime, 'size_bytes', a.size_bytes, 'sha256', a.sha256, 'storage_path', split_part(a.storage_path, '#', 1)))
      from public.comm_attachments a where a.message_id = m.id and not a.detached), '[]'::jsonb))), '[]'::jsonb)
  from public.comm_messages m where m.status = 'ACTIVO'; $$;
create or replace function public.comm_list_collaborators_all() returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(to_jsonb(c)), '[]'::jsonb) from public.comm_collaborators c; $$;
create or replace function public.comm_create_run(p_message uuid, p_scheduled_for timestamptz, p_kind text, p_missed boolean, p_recipients jsonb, p_skipped jsonb, p_snapshot jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare rid uuid; begin
  insert into public.comm_runs(message_id, scheduled_for, kind, status, snapshot, recipients_count, note)
    values (p_message, p_scheduled_for, p_kind, case when p_missed then 'PERDIDA' else 'PENDIENTE' end, p_snapshot, jsonb_array_length(coalesce(p_recipients, '[]')),
            case when p_missed then 'Ejecución perdida (el servidor no la procesó a tiempo): NO se envió; queda para revisión.' end)
    on conflict (message_id, scheduled_for, kind) do nothing returning id into rid;
  if rid is null then return null; end if;   -- ya existía (otro trabajador la creó): no se duplica
  insert into public.comm_deliveries(run_id, collaborator_id, email, name)
    select rid, nullif(x->>'collaborator_id', '')::uuid, lower(x->>'email'), x->>'name' from jsonb_array_elements(coalesce(p_recipients, '[]')) x on conflict do nothing;
  insert into public.comm_deliveries(run_id, collaborator_id, name, status, reason)
    select rid, nullif(x->>'id', '')::uuid, x->>'name', 'OMITIDO', x->>'reason' from jsonb_array_elements(coalesce(p_skipped, '[]')) x on conflict do nothing;
  return rid; end; $$;
create or replace function public.comm_advance_cursor(p_message uuid, p_prev timestamptz, p_next timestamptz) returns boolean language plpgsql security definer set search_path = public as $$
begin update public.comm_messages set cursor = p_next where id = p_message and cursor is not distinct from p_prev; return found; end; $$;
create or replace function public.comm_sent_last24h(p_now timestamptz default now()) returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from public.comm_deliveries where status = 'ENVIADO' and coalesce(sent_at, claimed_at, confirmed_at) > p_now - interval '24 hours'; $$;
create or replace function public.comm_claim(p_limit int, p_worker text, p_now timestamptz default now(), p_daily_cap int default 400, p_window_hours int default 6)
returns table(id bigint, token uuid, run_id uuid, email text, name text, collaborator_id uuid, attempts int, snapshot jsonb)
language plpgsql security definer set search_path = public as $$
declare v_used int; v_take int;
begin
  -- serializa las reservas: dos trabajadores no pueden calcular el cupo al mismo tiempo
  perform pg_advisory_xact_lock(hashtext('okd_comm_claim'));
  -- trabajador caído a mitad de envío: NO se reenvía a ciegas; se conserva su token por si el registro llega tarde
  update public.comm_deliveries set status = 'POR_VERIFICAR', stale_token = claim_token, claim_token = null, updated_at = p_now,
    last_error = 'El procesamiento se interrumpió: verificá en "Enviados" de Gmail si llegó a enviarse antes de reintentar.'
    where comm_deliveries.status = 'PROCESANDO' and claimed_at < p_now - interval '10 minutes';
  -- VENCIMIENTO también para pendientes y reintentos ya encolados (p. ej. al reanudar): quedan para revisión, sin envío
  update public.comm_deliveries d set status = 'VENCIDO', next_attempt_at = null, updated_at = p_now,
    reason = 'Vencido: no se envió dentro de las ' || p_window_hours || ' h siguientes al horario programado (pausa, desconexión o interrupción). Queda para revisión; no se envía automáticamente.'
    from public.comm_runs r where r.id = d.run_id and (d.status = 'PENDIENTE' or (d.status = 'ERROR' and d.retryable))
      and r.scheduled_for < p_now - make_interval(hours => p_window_hours) and not coalesce(d.manual_ok_until > p_now, false);
  -- CUPO diario reservado AQUÍ: enviados + en curso + inciertos de las últimas 24 h (incluye pruebas)
  select count(*) filter (where d.status = 'ENVIADO' and coalesce(d.sent_at, d.claimed_at, d.confirmed_at) > p_now - interval '24 hours')
       + count(*) filter (where d.status = 'PROCESANDO')
       + count(*) filter (where d.status = 'POR_VERIFICAR' and coalesce(d.claimed_at, d.updated_at) > p_now - interval '24 hours') into v_used from public.comm_deliveries d;
  v_take := greatest(0, least(p_limit, p_daily_cap - v_used));
  return query
  with c as (
    select d.id from public.comm_deliveries d join public.comm_runs r on r.id = d.run_id left join public.comm_messages m on m.id = r.message_id
     where (d.status = 'PENDIENTE' or (d.status = 'ERROR' and d.retryable and d.attempts < 4 and d.next_attempt_at <= p_now))
       and r.status not in ('CANCELADA','PERDIDA') and (r.kind = 'PRUEBA' or m.status = 'ACTIVO')
     order by r.scheduled_for, d.id
     for update of d skip locked
     limit v_take)
  update public.comm_deliveries d set status = 'PROCESANDO', claim_token = gen_random_uuid(), claimed_at = p_now, attempts = d.attempts + 1, worker = p_worker, updated_at = p_now
    from c, public.comm_runs r where d.id = c.id and r.id = d.run_id
  returning d.id, d.claim_token, d.run_id, d.email, d.name, d.collaborator_id, d.attempts, r.snapshot;
end; $$;
-- Cupo de VELOCIDAD compartido (todos los trabajadores y las pruebas): concede 'p_units' si caben en las ventanas de 60 s y de 1 s;
-- si no, devuelve cuántos ms esperar (nada se registra). Serializado con un candado transaccional.
create or replace function public.comm_rate_acquire(p_units int, p_per_min int default 6000, p_per_sec int default 200) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t timestamptz := clock_timestamp(); m60 int; m1 int; w60 numeric := 0; w1 numeric := 0; eid bigint;
begin
  perform pg_advisory_xact_lock(hashtext('okd_comm_rate'));
  delete from public.comm_rate_events where at < t - interval '2 minutes';
  select coalesce(sum(units), 0) into m60 from public.comm_rate_events where at > t - interval '60 seconds';
  select coalesce(sum(units), 0) into m1 from public.comm_rate_events where at > t - interval '1 second';
  if m60 + p_units <= p_per_min and m1 + p_units <= p_per_sec then
    insert into public.comm_rate_events(at, units) values (t, p_units) returning id into eid;
    return jsonb_build_object('wait_ms', 0, 'event_id', eid);
  end if;
  if m60 + p_units > p_per_min then select extract(epoch from (min(at) + interval '60 seconds' - t)) * 1000 into w60 from public.comm_rate_events where at > t - interval '60 seconds'; end if;
  if m1 + p_units > p_per_sec then select extract(epoch from (min(at) + interval '1 second' - t)) * 1000 into w1 from public.comm_rate_events where at > t - interval '1 second'; end if;
  return jsonb_build_object('wait_ms', greatest(ceil(greatest(w60, w1)), 20)::int);
end; $$;
-- devuelve EXACTAMENTE una reserva (envío interrumpido antes de llamar a Gmail: cancelado, pausado, sin conexión…)
create or replace function public.comm_rate_refund(p_event_id bigint) returns void language sql security definer set search_path = public as $$
  delete from public.comm_rate_events where id = p_event_id; $$;
create or replace function public.comm_check(p_id bigint, p_token uuid) returns text language plpgsql security definer set search_path = public as $$
declare d public.comm_deliveries; r public.comm_runs; m public.comm_messages; c public.comm_collaborators; g public.comm_gmail_status;
begin
  select * into d from public.comm_deliveries where id = p_id for update;
  if not found or d.status <> 'PROCESANDO' or d.claim_token is distinct from p_token then return 'LOST'; end if;
  select * into r from public.comm_runs where id = d.run_id; select * into m from public.comm_messages where id = r.message_id;
  if r.kind <> 'PRUEBA' then
    if r.status = 'CANCELADA' or m.status = 'CANCELADO' then update public.comm_deliveries set status = 'CANCELADO', claim_token = null, reason = 'Comunicado cancelado antes del envío', updated_at = now() where id = p_id; return 'CANCELLED'; end if;
    if m.status = 'PAUSADO' then update public.comm_deliveries set status = 'PENDIENTE', claim_token = null, attempts = attempts - 1, updated_at = now() where id = p_id; return 'PAUSED'; end if;
    if d.collaborator_id is not null then select * into c from public.comm_collaborators where id = d.collaborator_id;
      if found and not c.active then update public.comm_deliveries set status = 'OMITIDO', claim_token = null, reason = 'Colaborador desactivado antes del envío', updated_at = now() where id = p_id; return 'INACTIVE_RECIPIENT'; end if; end if;
  end if;
  select * into g from public.comm_gmail_status where id = 1;
  if not g.connected or g.needs_reconnect then update public.comm_deliveries set status = 'PENDIENTE', claim_token = null, attempts = attempts - 1, updated_at = now() where id = p_id; return 'NO_CONNECTION'; end if;
  return 'OK'; end; $$;
create or replace function public.comm_release(p_id bigint, p_token uuid) returns void language sql security definer set search_path = public as $$
  update public.comm_deliveries set status = 'PENDIENTE', claim_token = null, attempts = attempts - 1, updated_at = now() where id = p_id and claim_token = p_token and status = 'PROCESANDO'; $$;
create or replace function public._comm_settle_run(p_run uuid) returns void language sql security definer set search_path = public as $$
  update public.comm_runs r set status = case when exists (select 1 from public.comm_deliveries d where d.run_id = r.id and (d.status in ('PENDIENTE','PROCESANDO') or (d.status = 'ERROR' and d.retryable)))
    then 'EN_CURSO' else 'COMPLETADA' end where r.id = p_run and r.status not in ('CANCELADA','PERDIDA'); $$;
create or replace function public.comm_finish(p_id bigint, p_token uuid, p_outcome text, p_gmail_id text default null, p_error_code text default null, p_error text default null) returns text
language plpgsql security definer set search_path = public as $$
declare d public.comm_deliveries; begin
  select * into d from public.comm_deliveries where id = p_id for update;
  -- Gmail aceptó pero el registro llegó tarde (el trabajo ya figuraba "Por verificar"): se acepta con su id
  if found and d.status = 'POR_VERIFICAR' and p_outcome = 'ACCEPTED' and d.stale_token = p_token then
    update public.comm_deliveries set status = 'ENVIADO', gmail_message_id = p_gmail_id, sent_at = now(), sent_at_source = 'GMAIL', stale_token = null, last_error = null,
      reason = 'Registro tardío de una aceptación de Gmail', updated_at = now() where id = p_id;
    perform public._comm_settle_run(d.run_id); return 'OK'; end if;
  if not found or d.status <> 'PROCESANDO' or d.claim_token is distinct from p_token then return 'LOST'; end if;
  if p_outcome = 'ACCEPTED' then
    update public.comm_deliveries set status = 'ENVIADO', claim_token = null, gmail_message_id = p_gmail_id, sent_at = now(), sent_at_source = 'GMAIL', last_error = null, updated_at = now() where id = p_id;
  elsif p_outcome = 'RETRYABLE' and d.attempts < 4 then
    update public.comm_deliveries set status = 'ERROR', claim_token = null, retryable = true, error_code = p_error_code, last_error = left(p_error, 500), updated_at = now(),
      next_attempt_at = now() + make_interval(secs => least(3600, 60 * power(4, greatest(d.attempts - 1, 0))::int)) where id = p_id;
  elsif p_outcome = 'AMBIGUOUS' then
    update public.comm_deliveries set status = 'POR_VERIFICAR', claim_token = null, error_code = p_error_code, last_error = left(p_error, 500), updated_at = now() where id = p_id;
  else
    update public.comm_deliveries set status = 'ERROR', claim_token = null, retryable = false, next_attempt_at = null, error_code = p_error_code, updated_at = now(),
      last_error = left(case when p_outcome = 'RETRYABLE' then 'Se agotaron los reintentos. ' else '' end || coalesce(p_error, ''), 500) where id = p_id;
    if p_outcome = 'AUTH' then perform public.comm_gmail_mark(true, p_error); end if;
  end if;
  perform public._comm_settle_run(d.run_id); return 'OK'; end; $$;
create or replace function public.comm_record_dispatch(p jsonb) returns void language sql security definer set search_path = public as $$
  insert into public.comm_dispatches(at, worker, status, created, missed, claimed, sent, retry, failed, verify, skipped, note)
  values (coalesce((p->>'at')::timestamptz, now()), p->>'worker', p->>'status', (p->>'created')::int, (p->>'missed')::int, (p->>'claimed')::int, (p->>'sent')::int, (p->>'retry')::int,
          (p->>'failed')::int, (p->>'verify')::int, (p->>'skipped')::int, left(p->>'note', 300)); $$;

-- ---------- Permisos de ejecución ----------
do $$ declare f text; begin
  -- acciones de usuarios (cada una valida su permiso adentro)
  foreach f in array array['comm_save_collaborator(jsonb)','comm_save_message(jsonb,boolean)','comm_duplicate_message(uuid)',
    'comm_detach_attachment(uuid,boolean)','comm_activate(uuid)','comm_pause(uuid)','comm_resume(uuid)','comm_cancel(uuid)','comm_request_test(uuid,text)','comm_register_whatsapp(uuid,text)',
    'comm_resolve_verify(bigint,text)','comm_gmail_status()','comm_oauth_begin()','comm_can(text)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon'; execute 'grant execute on function public.' || f || ' to authenticated, service_role'; end loop;
  -- SOLO servidor: token, OAuth, cola
  foreach f in array array['comm_oauth_consume(text)','comm_gmail_store(text,text,uuid)','comm_gmail_secret()','comm_gmail_mark(boolean,text)','comm_gmail_clear(uuid)',
    'comm_list_active_messages()','comm_list_collaborators_all()','comm_create_run(uuid,timestamptz,text,boolean,jsonb,jsonb,jsonb)','comm_advance_cursor(uuid,timestamptz,timestamptz)',
    'comm_sent_last24h(timestamptz)','comm_claim(int,text,timestamptz,int,int)','comm_register_attachment_srv(uuid,text,text,text,bigint,text,uuid,boolean)',
    'comm_rate_acquire(int,int,int)','comm_rate_refund(bigint)','comm_attachment_registered(text)','comm_orphan_objects(int,int)','comm_check(bigint,uuid)','comm_release(bigint,uuid)','comm_finish(bigint,uuid,text,text,text,text)',
    'comm_record_dispatch(jsonb)','_comm_settle_run(uuid)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon, authenticated'; execute 'grant execute on function public.' || f || ' to service_role'; end loop;
  -- auxiliares internas: solo las usan otras funciones del módulo (SECURITY DEFINER)
  foreach f in array array['_comm_need(text)','_comm_audit(uuid,text,text,jsonb)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon, authenticated'; end loop;
end $$;
