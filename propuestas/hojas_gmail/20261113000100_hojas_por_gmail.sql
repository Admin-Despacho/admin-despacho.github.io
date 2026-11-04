-- =====================================================================================================================
-- PROPUESTA · NO APLICADA · Correo diario de PDF de hojas enviado por la cuenta GMAIL conectada en Comunicaciones.
--  · Configuración → F elige el canal: 'RESEND' (actual) o 'GMAIL'. Columna PROPIA (la columna 'provider' la edita la sección E).
--  · Con GMAIL: el despachador de Comunicaciones (cada 5 min) encola, desde el horario configurado (Mendoza), UNA ejecución por versión
--    de PDF de hoja del día, con los destinatarios configurados, y la envía por la cola de Comunicaciones (reserva atómica, verificación
--    previa, cupo compartido, "Por verificar", historial por destinatario). Mismo correo que hoy: una hoja (vN) por correo y destinatario.
--  · Exclusión mutua para no duplicar el día del cambio: Resend no encola con GMAIL y excluye lo enviado por Gmail; Gmail excluye lo
--    ya enviado por Resend; la verificación previa cancela lo pendiente de Gmail si se desactiva o se vuelve a Resend.
--  · El comunicado del sistema "Correo diario de hojas (automático)" solo se pausa o reanuda (protegido en el servidor).
-- Requiere: 20261112000100_comunicaciones.sql aplicada y su programador (01_programador_comunicaciones.sql) funcionando.
-- =====================================================================================================================

-- ---------- 1) Canal del correo de hojas ----------
alter table public.notification_settings add column if not exists sheet_email_via text not null default 'RESEND';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'notification_settings_sheet_email_via_chk') then
    alter table public.notification_settings add constraint notification_settings_sheet_email_via_chk check (sheet_email_via in ('RESEND','GMAIL'));
  end if; end $$;

create or replace function public.set_notification_settings(p jsonb) returns public.notification_settings language plpgsql security definer set search_path = public as $$
declare s public.notification_settings;
begin
  if not public.auth_has_perm('settings.manage') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p ? 'sheet_email_via' and coalesce(p->>'sheet_email_via', '') not in ('RESEND','GMAIL') then raise exception 'CANAL_INVALIDO: RESEND o GMAIL' using errcode = '22023'; end if;
  update public.notification_settings set on_the_way_enabled = coalesce((p->>'on_the_way_enabled')::boolean, on_the_way_enabled), delivered_enabled = coalesce((p->>'delivered_enabled')::boolean, delivered_enabled),
    sheet_email_enabled = coalesce((p->>'sheet_email_enabled')::boolean, sheet_email_enabled), sheet_email_time = coalesce(p->>'sheet_email_time', sheet_email_time),
    sheet_email_recipients = coalesce((select array_agg(lower(x)) from jsonb_array_elements_text(p->'sheet_email_recipients') x), sheet_email_recipients),
    sheet_email_via = coalesce(p->>'sheet_email_via', sheet_email_via),
    provider = coalesce(p->>'provider', provider), max_retries = coalesce((p->>'max_retries')::int, max_retries)
  where id = 'DEFAULT' returning * into s;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'NOTIFICATION_SETTINGS_CHANGED', 'settings', 'DEFAULT', to_jsonb(s));
  return s;
end; $$;
grant execute on function public.set_notification_settings(jsonb) to authenticated;

-- ---------- 2) Resend: no encola con GMAIL y excluye lo ya enviado (o en curso) por Gmail ----------
create or replace function public.queue_sheet_emails(p_day date) returns int language plpgsql security definer set search_path = public as $$
declare s public.notification_settings; n int;
begin
  select * into s from public.notification_settings where id = 'DEFAULT';
  if not s.sheet_email_enabled then return 0; end if;
  if s.sheet_email_via <> 'RESEND' then return 0; end if;   -- el canal elegido es Gmail (Comunicaciones)
  -- el envío del día sale a partir del horario configurado (hora de Mendoza)
  if p_day = (now() at time zone 'America/Argentina/Mendoza')::date and to_char(now() at time zone 'America/Argentina/Mendoza', 'HH24:MI') < s.sheet_email_time then return 0; end if;
  insert into public.sheet_email_jobs(route_id, route_version, recipient, idempotency_key)
  select p.route_id, p.route_version, e, p.route_id || '|' || p.route_version || '|' || e
  from public.route_pdfs p cross join unnest(s.sheet_email_recipients) e
  where p.status = 'OK' and (p.generated_at at time zone 'America/Argentina/Mendoza')::date = p_day
    and not exists (select 1 from public.comm_runs r join public.comm_deliveries d on d.run_id = r.id
                     where r.source_key = 'HOJA|' || p.route_id || '|' || p.route_version and lower(d.email) = lower(e)
                       and d.status in ('ENVIADO','PROCESANDO','POR_VERIFICAR'))   -- enviado o POSIBLEMENTE enviado por Gmail
    -- (lo PENDIENTE de Gmail no salió: Resend puede enviarlo y la verificación previa de Gmail lo cancela al ver el cambio de canal)
  on conflict (idempotency_key) do nothing;
  get diagnostics n = row_count; return n;
end; $$;

-- ---------- 3) Comunicaciones: comunicado del sistema, tipo de ejecución 'HOJAS' y clave de origen ----------
alter table public.comm_messages add column if not exists system_kind text unique;
alter table public.comm_runs add column if not exists source_key text unique;
-- unicidad por comunicado + horario + tipo: solo para ejecuciones NO 'HOJAS' (las de hojas son únicas por source_key; varias hojas del
-- día comparten el horario configurado). comm_create_run se redefine IDÉNTICA salvo el ON CONFLICT, que apunta al índice parcial.
alter table public.comm_runs drop constraint if exists comm_runs_message_id_scheduled_for_kind_key;
create unique index if not exists comm_runs_unico_programado on public.comm_runs (message_id, scheduled_for, kind) where kind <> 'HOJAS';
create or replace function public.comm_create_run(p_message uuid, p_scheduled_for timestamptz, p_kind text, p_missed boolean, p_recipients jsonb, p_skipped jsonb, p_snapshot jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare rid uuid; begin
  insert into public.comm_runs(message_id, scheduled_for, kind, status, snapshot, recipients_count, note)
    values (p_message, p_scheduled_for, p_kind, case when p_missed then 'PERDIDA' else 'PENDIENTE' end, p_snapshot, jsonb_array_length(coalesce(p_recipients, '[]')),
            case when p_missed then 'Ejecución perdida (el servidor no la procesó a tiempo): NO se envió; queda para revisión.' end)
    on conflict (message_id, scheduled_for, kind) where kind <> 'HOJAS' do nothing returning id into rid;
  if rid is null then return null; end if;   -- ya existía (otro trabajador la creó): no se duplica
  insert into public.comm_deliveries(run_id, collaborator_id, email, name)
    select rid, nullif(x->>'collaborator_id', '')::uuid, lower(x->>'email'), x->>'name' from jsonb_array_elements(coalesce(p_recipients, '[]')) x on conflict do nothing;
  insert into public.comm_deliveries(run_id, collaborator_id, name, status, reason)
    select rid, nullif(x->>'id', '')::uuid, x->>'name', 'OMITIDO', x->>'reason' from jsonb_array_elements(coalesce(p_skipped, '[]')) x on conflict do nothing;
  return rid; end; $$;;
alter table public.comm_runs drop constraint if exists comm_runs_kind_check;
alter table public.comm_runs add constraint comm_runs_kind_check check (kind in ('PROGRAMADO','PRUEBA','HOJAS'));

-- el comunicado del sistema solo se pausa o reanuda; el contenido y los destinatarios salen de Configuración → F
create or replace function public._comm_protect_system_message() returns trigger language plpgsql as $$
begin
  if old.system_kind is not null and current_setting('okd.comm_system', true) is distinct from 'on' then
    if new.subject is distinct from old.subject or new.body_html is distinct from old.body_html or new.selection is distinct from old.selection
       or new.schedule is distinct from old.schedule or new.internal_name is distinct from old.internal_name or new.system_kind is distinct from old.system_kind
       or new.status not in ('ACTIVO','PAUSADO') then
      raise exception 'MENSAJE_DEL_SISTEMA: el correo diario de hojas solo se pausa o reanuda; se configura en Configuración → F' using errcode = '22023';
    end if;
  end if;
  return new;
end; $$;
drop trigger if exists comm_messages_protect_system on public.comm_messages;
create trigger comm_messages_protect_system before update on public.comm_messages for each row execute function public._comm_protect_system_message();
create or replace function public._comm_no_attachments_on_system() returns trigger language plpgsql as $$
begin
  if exists (select 1 from public.comm_messages m where m.id = new.message_id and m.system_kind is not null) then
    raise exception 'MENSAJE_DEL_SISTEMA: el correo diario de hojas adjunta los PDF de las hojas automáticamente' using errcode = '22023';
  end if;
  return new;
end; $$;
drop trigger if exists comm_attachments_no_system on public.comm_attachments;
create trigger comm_attachments_no_system before insert on public.comm_attachments for each row execute function public._comm_no_attachments_on_system();

-- ---------- 4) Encolado del correo de hojas por Gmail (SOLO servidor; lo llama el despachador de Comunicaciones) ----------
-- Elegibles: hojas PUBLICADAS (publish_route) o tercerizados DESPACHADOS (dispatch_external_route); nunca borradores ni canceladas, y sin
-- depender de que el chofer termine. Día de la hoja = el de su publicación o despacho (hora de Mendoza), NO el del PDF. Se adjunta SOLO el PDF de
-- la VERSIÓN VIGENTE (routes.version); si todavía no está, se espera (nunca se cae a una versión anterior). PDF TARDÍO: una hoja del día cuyo PDF
-- aparece después del horario sale en la vuelta siguiente; una hoja de AYER cuyo PDF recién se generó HOY también se envía (solo ese caso).
create or replace function public._comm_sheet_eligible(r public.routes) returns boolean language sql immutable as $$
  select r.operational_status in ('PUBLICADA','EN_CURSO','COMPLETADA')
     and ((coalesce(r.dispatch_mode, 'APP') <> 'EXTERNAL' and r.published_at is not null) or (r.dispatch_mode = 'EXTERNAL' and r.dispatched_at is not null)); $$;
create or replace function public.comm_enqueue_sheet_pdfs(p_now timestamptz default now()) returns int language plpgsql security definer set search_path = public as $$
declare s public.notification_settings; m public.comm_messages; v_day date := (p_now at time zone 'America/Argentina/Mendoza')::date;
        n int := 0; p record; rid uuid; nrec int; v_base timestamptz;
begin
  select * into s from public.notification_settings where id = 'DEFAULT';
  if s.id is null or not s.sheet_email_enabled or s.sheet_email_via <> 'GMAIL' or coalesce(cardinality(s.sheet_email_recipients), 0) = 0 then return 0; end if;
  perform pg_advisory_xact_lock(hashtext('okd_comm_sheet_enqueue'));
  for p in
    select r.id route_id, r.number route_number, r.version route_version, rp.file_name, rp.storage_path, rp.generated_at, x.sheet_day
      from public.routes r
      cross join lateral (select ((case when r.dispatch_mode = 'EXTERNAL' then r.dispatched_at else r.published_at end) at time zone 'America/Argentina/Mendoza')::date sheet_day) x
      join public.route_pdfs rp on rp.route_id = r.id and rp.route_version = r.version and rp.status = 'OK' and rp.storage_path is not null   -- versión VIGENTE
     where public._comm_sheet_eligible(r)
       and (   (x.sheet_day = v_day and p_now >= ((v_day::text || ' ' || s.sheet_email_time)::timestamp at time zone 'America/Argentina/Mendoza'))
            or (x.sheet_day = v_day - 1 and (rp.generated_at at time zone 'America/Argentina/Mendoza')::date = v_day) )   -- PDF tardío de ayer
       and not exists (select 1 from public.comm_runs cr where cr.source_key = 'HOJA|' || r.id || '|' || r.version)
     order by x.sheet_day, r.number
  loop
    if m.id is null then
      select * into m from public.comm_messages where system_kind = 'HOJAS_DIA';
      if not found then
        insert into public.comm_messages(internal_name, subject, body_html, status, system_kind, active_since, cursor, from_name)
          values ('Correo diario de hojas (automático)', 'OK Despacho · Hojas del día', '<p>Envío automático de los PDF de las hojas del día.</p>', 'ACTIVO', 'HOJAS_DIA', p_now, p_now, 'OK Accesorios')
          returning * into m;
        insert into public.comm_audit(message_id, entity, action, detail) values (m.id, 'COMUNICADO', 'CREADO_POR_SISTEMA', jsonb_build_object('motivo', 'correo diario de hojas por Gmail'));
      end if;
    end if;
    v_base := ((p.sheet_day::text || ' ' || s.sheet_email_time)::timestamp) at time zone 'America/Argentina/Mendoza';
    insert into public.comm_runs(message_id, scheduled_for, kind, status, snapshot, recipients_count, source_key)
      values (m.id, greatest(v_base, p.generated_at), 'HOJAS', 'PENDIENTE',
        jsonb_build_object('subject', 'OK Despacho · Hoja ' || p.route_number || ' (v' || p.route_version || ')',
          'body_html', '<p>Adjuntamos la hoja <b>' || replace(replace(replace(p.route_number, '&', '&amp;'), '<', '&lt;'), '>', '&gt;') || '</b> versión ' || p.route_version || '.</p>',
          'from_name', 'OK Accesorios', 'message_version', 1, 'route_id', p.route_id, 'route_version', p.route_version, 'sheet_day', p.sheet_day,
          'attachments', jsonb_build_array(jsonb_build_object('name', p.file_name, 'mime', 'application/pdf', 'size_bytes', null, 'sha256', null,
                                                               'storage_path', p.storage_path, 'bucket', 'route-pdfs'))),
        0, 'HOJA|' || p.route_id || '|' || p.route_version)
      on conflict (source_key) do nothing returning id into rid;
    if rid is null then continue; end if;
    insert into public.comm_deliveries(run_id, email, name)
      select rid, lower(e), 'Destinatario del correo de hojas' from unnest(s.sheet_email_recipients) e
       where not exists (select 1 from public.sheet_email_jobs j where j.route_id = p.route_id and j.route_version = p.route_version
                           and lower(j.recipient) = lower(e) and j.status = 'SENT')   -- ya enviado por Resend: no se repite
      on conflict do nothing;
    get diagnostics nrec = row_count;
    update public.comm_runs set recipients_count = nrec,
      status = case when nrec = 0 then 'COMPLETADA' else status end,
      note = case when nrec = 0 then 'Esta versión ya se había enviado por Resend a todos los destinatarios.' end
     where id = rid;
    n := n + 1;
  end loop;
  return n;
end; $$;

-- ---------- 5) Verificación previa: con el correo de hojas desactivado o vuelto a Resend, lo pendiente de Gmail se cancela ----------
create or replace function public.comm_check(p_id bigint, p_token uuid) returns text language plpgsql security definer set search_path = public as $$
declare d public.comm_deliveries; r public.comm_runs; m public.comm_messages; c public.comm_collaborators; g public.comm_gmail_status; s public.notification_settings; rt public.routes;
begin
  select * into d from public.comm_deliveries where id = p_id for update;
  if not found or d.status <> 'PROCESANDO' or d.claim_token is distinct from p_token then return 'LOST'; end if;
  select * into r from public.comm_runs where id = d.run_id; select * into m from public.comm_messages where id = r.message_id;
  if r.kind = 'HOJAS' then
    select * into s from public.notification_settings where id = 'DEFAULT';
    if not s.sheet_email_enabled or s.sheet_email_via <> 'GMAIL' then
      update public.comm_deliveries set status = 'CANCELADO', claim_token = null, reason = 'Correo de hojas desactivado o cambiado a Resend antes del envío', updated_at = now() where id = p_id; return 'CANCELLED'; end if;
    -- ESTADO y VERSIÓN de la hoja, inmediatamente antes de cada envío (también en reintentos)
    select * into rt from public.routes where id = (r.snapshot->>'route_id')::uuid;
    if not found or not public._comm_sheet_eligible(rt) then
      update public.comm_deliveries set status = 'CANCELADO', claim_token = null, reason = 'La hoja fue cancelada o dejó de estar publicada antes del envío', updated_at = now() where id = p_id; return 'CANCELLED'; end if;
    if rt.version <> (r.snapshot->>'route_version')::int then
      update public.comm_deliveries set status = 'CANCELADO', claim_token = null, reason = 'Hay una versión más nueva de la hoja (v' || rt.version || '): se envía esa', updated_at = now() where id = p_id; return 'CANCELLED'; end if;
  end if;
  if r.kind <> 'PRUEBA' then
    if r.status = 'CANCELADA' or m.status = 'CANCELADO' then update public.comm_deliveries set status = 'CANCELADO', claim_token = null, reason = 'Comunicado cancelado antes del envío', updated_at = now() where id = p_id; return 'CANCELLED'; end if;
    if m.status = 'PAUSADO' then update public.comm_deliveries set status = 'PENDIENTE', claim_token = null, attempts = attempts - 1, updated_at = now() where id = p_id; return 'PAUSED'; end if;
    if d.collaborator_id is not null then select * into c from public.comm_collaborators where id = d.collaborator_id;
      if found and not c.active then update public.comm_deliveries set status = 'OMITIDO', claim_token = null, reason = 'Colaborador desactivado antes del envío', updated_at = now() where id = p_id; return 'INACTIVE_RECIPIENT'; end if; end if;
  end if;
  select * into g from public.comm_gmail_status where id = 1;
  if not g.connected or g.needs_reconnect then update public.comm_deliveries set status = 'PENDIENTE', claim_token = null, attempts = attempts - 1, updated_at = now() where id = p_id; return 'NO_CONNECTION'; end if;
  return 'OK'; end; $$;

-- ---------- 6) Privilegios (objetos nuevos o redefinidos) ----------
revoke all on function public.comm_enqueue_sheet_pdfs(timestamptz) from public, anon, authenticated;
grant execute on function public.comm_enqueue_sheet_pdfs(timestamptz) to service_role;
revoke all on function public.comm_check(bigint, uuid) from public, anon, authenticated;
grant execute on function public.comm_check(bigint, uuid) to service_role;
revoke all on function public._comm_protect_system_message() from public, anon, authenticated;
revoke all on function public._comm_sheet_eligible(public.routes) from public, anon, authenticated;
revoke all on function public._comm_no_attachments_on_system() from public, anon, authenticated;
