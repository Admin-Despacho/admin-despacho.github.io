-- SOLO PRUEBAS LOCALES · V5 · reproducciones NEGATIVAS de los hallazgos de Work sobre V4 (N-V4-01/02/03/05). Aserciones POSITIVAS.
create temp table v5_checks(name text, ok boolean, detail text);
create or replace function pg_temp.v5(u uuid, q text) returns text language plpgsql as $f$ declare o text; begin perform tst.u(u); set local role authenticated; begin execute q into o; exception when others then o := 'ERR ' || sqlerrm; end; reset role; return o; end $f$;
create or replace function pg_temp.v5j(t text) returns jsonb language sql as $f$ select case when t like '[%' or t like '{%' then t::jsonb end $f$;
create or replace function pg_temp.v5sync(on_ boolean) returns void language sql as $f$ select set_config('okd.sync', case when on_ then 'on' else '' end, false) $f$;
\set A  'e0000000-0000-0000-0000-00000000000a'
\set O  'e0000000-0000-0000-0000-000000000006'
\set C1 'c0000000-0000-0000-0000-0000000000c1'
\set W  'c0000000-0000-0000-0000-0000000000a1'
\set F  'c0000000-0000-0000-0000-0000000000a2'
\set GB 'c0000000-0000-0000-0000-0000000000a3'
-- ===== N-V4-03 · estado que deja la INSTALACIÓN (lo registró el ejecutor ANTES de cualquier acción) =====
insert into v5_checks select 'V5-K01 (N-V4-03) la INSTALACIÓN deja el KPI DESHABILITADO (sin ventana PROVISORIO) y la columna tiene DESHABILITADO como valor predeterminado',
  (select modo from v5_kpi_instalacion) = 'DESHABILITADO'
  and (select column_default from information_schema.columns where table_schema = 'public' and table_name = 'com_settings' and column_name = 'kpi_mode') like '%DESHABILITADO%',
  (select modo from v5_kpi_instalacion) from (select 1) z;
-- ===== N-V4-01 · alarma pendiente para Wilfredo (circuito real) =====
select pg_temp.v5(:'A', format($q$select public.com_set_alarm_settings(%L::jsonb)::text$q$, jsonb_build_object('initial_user', :'W', 'escalation_users', jsonb_build_array(:'F', :'GB'))));
select pg_temp.v5(:'O', $q$select public.reserve_orders('V5-1', array['27501','27502','27503'])::text$q$);
create temp table v5_al as select pg_temp.v5j(pg_temp.v5(:'O', $q$select public.com_alarm_raise('27501', 'V5-1', 'x', '', 'Pedido urgente para probar permisos actuales', 'v5-op-1')::text$q$)) r;
create temp table v5_id as select (r->>'id')::uuid id from v5_al;
create temp table v5_nid as select e.notification_id nid from public.com_alarm_events e where e.alarm_id = (select id from v5_id) and e.recipient_id = :'W' and e.kind = 'NOTIFICADO' limit 1;
create temp table v5_ev0 as select count(*) n from public.com_alarm_events where alarm_id = (select id from v5_id);
create or replace function pg_temp.v5w() returns jsonb language sql as $f$ select jsonb_build_object(
  'lista', (select count(*) from jsonb_array_elements(pg_temp.v5j(pg_temp.v5('c0000000-0000-0000-0000-0000000000a1', 'select public.com_my_alarms_page(50)::text'))->'items') x where (x->>'id')::uuid = (select id from v5_id)),
  'lista_v1', (select count(*) from jsonb_array_elements(pg_temp.v5j(pg_temp.v5('c0000000-0000-0000-0000-0000000000a1', 'select public.com_my_alarms()::text'))) x where (x->>'id')::uuid = (select id from v5_id)),
  'enlace', pg_temp.v5('c0000000-0000-0000-0000-0000000000a1', format('select coalesce(public.com_alarm_by_notification(%L)::text, %L)', (select nid from v5_nid), 'null'))) $f$;
create temp table v5_base as select pg_temp.v5w() r;
-- (a) COMERCIAL restringido
select pg_temp.v5sync(true); update public.profiles set disabled_modules = array['COMERCIAL'] where id = :'W'; select pg_temp.v5sync(false);
create temp table v5_a as select pg_temp.v5w() r, pg_temp.v5(:'W', format('select public.com_alarm_attend(%L, 1)::text', (select id from v5_id))) atender;
select pg_temp.v5sync(true); update public.profiles set disabled_modules = '{}' where id = :'W'; select pg_temp.v5sync(false);
-- (b) pierde el permiso individual com.approve
delete from public.user_permission_overrides where user_id = :'W' and permission_code = 'com.approve';
create temp table v5_b as select pg_temp.v5w() r, pg_temp.v5(:'W', format('select public.com_alarm_attend(%L, 1)::text', (select id from v5_id))) atender;
insert into public.user_permission_overrides(user_id, permission_code, granted, set_by, reason) values (:'W', 'com.approve', true, :'A', 'restaurado por la prueba V5');
-- (c) cambio de ROL (a uno sin com.approve)
select pg_temp.v5sync(true); update public.profiles set role = 'OPERARIO_DEPOSITO' where id = :'W'; select pg_temp.v5sync(false);
delete from public.user_permission_overrides where user_id = :'W' and permission_code = 'com.approve';
create temp table v5_c as select pg_temp.v5w() r, pg_temp.v5(:'W', format('select public.com_alarm_attend(%L, 1)::text', (select id from v5_id))) atender;
select pg_temp.v5sync(true); update public.profiles set role = 'SOLO_LECTURA' where id = :'W'; select pg_temp.v5sync(false);
insert into public.user_permission_overrides(user_id, permission_code, granted, set_by, reason) values (:'W', 'com.approve', true, :'A', 'restaurado por la prueba V5');
-- (d) DESHABILITADO
select pg_temp.v5sync(true); update public.profiles set status = 'DESHABILITADO' where id = :'W'; select pg_temp.v5sync(false);
create temp table v5_d as select pg_temp.v5(:'W', 'select public.com_my_alarms_page(50)::text') lista, pg_temp.v5(:'W', format('select public.com_alarm_attend(%L, 1)::text', (select id from v5_id))) atender;
select pg_temp.v5sync(true); update public.profiles set status = 'ACTIVO' where id = :'W'; select pg_temp.v5sync(false);
create temp table v5_rest as select pg_temp.v5w() r;
insert into v5_checks select 'V5-P01 (N-V4-01) APROBADOR con COMERCIAL RESTRINGIDO: no ve la alarma (listado nuevo y anterior), el ENLACE previo del push no la abre y ATENDER se rechaza; la alarma sigue pendiente',
  (select (r->>'lista')::int = 1 and (r->>'lista_v1')::int = 1 and r->>'enlace' <> 'null' from v5_base)
  and (select (r->>'lista')::int = 0 and (r->>'lista_v1')::int = 0 and r->>'enlace' = 'null' and pg_temp.v5j(atender)->>'code' = 'FORBIDDEN' from v5_a)
  and (select status = 'PENDIENTE_ATENCION' and attended_by is null from public.com_alarms where id = (select id from v5_id)), (select r::text || ' · ' || left(atender, 60) from v5_a) from (select 1) z;
insert into v5_checks select 'V5-P02 (N-V4-01) aprobador que PIERDE su permiso individual com.approve: sin listado, sin enlace y sin atención',
  (r->>'lista')::int = 0 and r->>'enlace' = 'null' and pg_temp.v5j(atender)->>'code' = 'FORBIDDEN', r::text from v5_b;
insert into v5_checks select 'V5-P03 (N-V4-01) CAMBIO DE ROL del destinatario a uno sin aprobación: sin listado, sin enlace y sin atención (la asignación histórica no da acceso)',
  (r->>'lista')::int = 0 and r->>'enlace' = 'null' and pg_temp.v5j(atender)->>'code' = 'FORBIDDEN', r::text from v5_c;
insert into v5_checks select 'V5-P04 (N-V4-01) destinatario DESHABILITADO: FORBIDDEN en el listado y en la atención',
  lista like 'ERR FORBIDDEN%' and atender like 'ERR FORBIDDEN%', left(lista, 30) || ' · ' || left(atender, 30) from v5_d;
insert into v5_checks select 'V5-P05 (N-V4-01) al RESTABLECER permiso, rol y estado, el destinatario vuelve a ver y a poder abrir la alarma (no se perdió nada)',
  (r->>'lista')::int = 1 and r->>'enlace' <> 'null', r::text from v5_rest;
-- (e) ADMINISTRADOR GENERAL con COMERCIAL restringido (política de Dirección)
select pg_temp.v5sync(true); update public.profiles set disabled_modules = array['COMERCIAL'] where id = :'F'; select pg_temp.v5sync(false);
create temp table v5_e as select pg_temp.v5(:'F', 'select public.com_config()::text') cfg, pg_temp.v5(:'F', $q$select public.com_history('TODAS', '{}'::jsonb, null, 25)::text$q$) hist,
  pg_temp.v5(:'F', 'select public.com_alarm_history_page(null, null, null, 25)::text') alh, pg_temp.v5(:'F', 'select public.com_my_alarms_page(50)::text') mis,
  pg_temp.v5(:'F', format('select public.com_alarm_attend(%L, 1)::text', (select id from v5_id))) atender,
  pg_temp.v5(:'F', format($q$select public.com_set_alarm_settings(%L::jsonb)::text$q$, jsonb_build_object('initial_user', 'c0000000-0000-0000-0000-0000000000a1', 'escalation_users', jsonb_build_array('c0000000-0000-0000-0000-0000000000a3')))) cfg_alarma,
  pg_temp.v5(:'A', format($q$select public.com_set_alarm_settings(%L::jsonb)::text$q$, jsonb_build_object('initial_user', 'c0000000-0000-0000-0000-0000000000a1', 'escalation_users', jsonb_build_array('c0000000-0000-0000-0000-0000000000a2')))) restringido_como_escalamiento;
-- escalamiento con Franco restringido: va SOLO a Gabriela
update public.com_alarms set escalate_at = now() - interval '1 second' where id = (select id from v5_id); select public.com_alarm_escalate_due();
create temp table v5_e2 as select escalated_to from public.com_alarms where id = (select id from v5_id);
select pg_temp.v5sync(true); update public.profiles set disabled_modules = '{}' where id = :'F'; select pg_temp.v5sync(false);
insert into v5_checks select 'V5-P06 (N-V4-01) ADMINISTRADOR GENERAL con COMERCIAL RESTRINGIDO (política de Dirección): FORBIDDEN en configuración, historial TODAS, historial de alarmas y configuración de destinatarios; no ve ni atiende alarmas',
  cfg like 'ERR FORBIDDEN%' and hist like 'ERR FORBIDDEN%' and alh like 'ERR FORBIDDEN%' and jsonb_array_length(pg_temp.v5j(mis)->'items') = 0
  and pg_temp.v5j(atender)->>'code' = 'FORBIDDEN' and cfg_alarma like 'ERR FORBIDDEN%',
  left(cfg, 22) || ' | ' || left(hist, 22) || ' | ' || left(alh, 22) || ' | ' || left(atender, 50) from v5_e;
insert into v5_checks select 'V5-P07 (N-V4-01) un Administrador con COMERCIAL restringido NO se acepta como destinatario de escalamiento y el escalamiento lo EXCLUYE (va solo a Gabriela)',
  (select restringido_como_escalamiento like 'ERR BAD_RECIPIENT%' from v5_e) and (select escalated_to = array[:'GB']::uuid[] from v5_e2),
  (select array_to_string(escalated_to, ',') from v5_e2) from (select 1) z;
-- (f) Despacho (solicitante) restringido
select pg_temp.v5sync(true); update public.profiles set disabled_modules = array['COMERCIAL'] where id = :'O'; select pg_temp.v5sync(false);
create temp table v5_f as select pg_temp.v5(:'O', $q$select public.com_alarm_raise('27502', 'V5-1', 'x', '', 'Intento con COMERCIAL restringido', 'v5-op-2')::text$q$) emitir,
  (select count(*) from jsonb_array_elements(pg_temp.v5j(pg_temp.v5(:'O', 'select public.com_my_alarms_page(50)::text'))->'items')) mis;
select pg_temp.v5sync(true); update public.profiles set disabled_modules = '{}' where id = :'O'; select pg_temp.v5sync(false);
insert into v5_checks select 'V5-P08 (N-V4-01) DESPACHO con COMERCIAL restringido: no puede emitir alarmas ni ve las que pidió',
  emitir like 'ERR FORBIDDEN%' and mis = 0, left(emitir, 40) || ' · mis=' || mis from v5_f;
insert into v5_checks select 'V5-P09 (N-V4-01) las restricciones NO borran nada: la alarma y su historial siguen (eventos solo crecen) y el Administrador AUTORIZADO los ve',
  (select count(*) from public.com_alarm_events where alarm_id = (select id from v5_id)) >= (select n from v5_ev0)
  and exists (select 1 from jsonb_array_elements(pg_temp.v5j(pg_temp.v5(:'A', 'select public.com_alarm_history_page(null, null, null, 100)::text'))->'items') x where (x->>'id')::uuid = (select id from v5_id)), '' from (select 1) z;
-- ===== N-V4-03 · fotos ANTERIORES con cifras no se exponen con el KPI deshabilitado =====
create temp table v5_k as select id from public.com_requests where requested_by = :'C1' order by created_at limit 1;
update public.com_requests set kpi_snapshot = jsonb_build_object('status', 'OK', 'average', 1000, 'floor', 1250, 'ceiling', 1500, 'months', 3) where id = (select id from v5_k);
select pg_temp.v5(:'A', $q$select public.com_set_kpi_mode('DESHABILITADO', null)::text$q$);
create temp table v5_k2 as select pg_temp.v5j(pg_temp.v5(:'C1', format('select public.com_request_detail(%L)::text', (select id from v5_k)))) det,
  pg_temp.v5(:'W', $q$select public.com_list('BANDEJA', null, 100, 0)::text$q$) bandeja;
insert into v5_checks select 'V5-K02 (N-V4-03) una foto ANTERIOR con cifras (promedio/piso/techo) NO se expone con el KPI deshabilitado (detalle y bandeja), pero se CONSERVA en la tabla; los IMPORTES de la solicitud siguen visibles',
  det->'kpi'->>'status' = 'DESHABILITADO' and not (det->'kpi' ?| array['average', 'floor', 'ceiling']) and det->'original_terms' ? 'amount'
  and bandeja !~ '"average"' and bandeja !~ '"ceiling"'
  and (select (kpi_snapshot->>'average')::int = 1000 from public.com_requests where id = (select id from v5_k)), left((det->'kpi')::text, 120) from v5_k2;
create temp table v5_k3 as select pg_temp.v5(:'A', $q$select public.com_set_kpi_mode('PROVISORIO', null)::text$q$) sin_aut, pg_temp.v5(:'A', $q$select public.com_set_kpi_mode('PROVISORIO', 'corta')::text$q$) corta;
select pg_temp.v5(:'A', $q$select public.com_set_kpi_mode('PROVISORIO', 'Resolución DG-2026-XX (prueba local, no real)')::text$q$);
create temp table v5_k4 as select pg_temp.v5j(pg_temp.v5(:'C1', format('select public.com_request_detail(%L)::text', (select id from v5_k)))) det;
insert into v5_checks select 'V5-K03 (N-V4-03) REACTIVAR el KPI exige la referencia escrita a la autorización de Dirección General (sin ella o corta → rechazo); con ella queda AUDITADA y la foto vuelve a verse',
  sin_aut like 'ERR AUTORIZACION_REQUERIDA%' and corta like 'ERR AUTORIZACION_REQUERIDA%' and (select (det->'kpi'->>'average')::int = 1000 from v5_k4)
  and exists (select 1 from public.audit_log where action = 'COM_KPI_MODE' and after->>'autorizacion' like 'Resolución DG-%'), left(sin_aut, 40) from v5_k3;
select pg_temp.v5(:'A', $q$select public.com_set_kpi_mode('DESHABILITADO', null)::text$q$);
-- ===== N-V4-05 · bordes del día ARGENTINO (UTC−3) =====
\set V9 'c0000000-0000-0000-0000-0000000000d9'
insert into auth.users(id, email) values (:'V9', 'vend9@t') on conflict do nothing;
select pg_temp.v5sync(true); insert into public.profiles(id, full_name, email, role, status) values (:'V9', 'Vendedor Fechas', 'vend9@t', 'COMERCIAL', 'ACTIVO') on conflict (id) do nothing; select pg_temp.v5sync(false);
select pg_temp.v5(:'A', format($q$select public.com_set_assignment(%L, 'SUCURSAL', 'MONTECASEROS', null)::text$q$, :'V9'));
create temp table v5_tpl as select * from public.com_requests where requested_by = :'C1' order by created_at limit 1;
insert into public.com_requests select (jsonb_populate_record(null::public.com_requests, to_jsonb(t) || jsonb_build_object('id', gen_random_uuid(), 'number', 'FEC-' || x.k, 'op_id', 'v5-fec-' || x.k,
  'requested_by', :'V9', 'order_ref', 'F-' || x.k, 'created_at', x.ts, 'status', x.st))).*
  from v5_tpl t, (values ('a', timestamptz '2026-11-14 02:59:59+00', 'PENDIENTE'), ('b', timestamptz '2026-11-14 03:00:00+00', 'APROBADA'), ('c', timestamptz '2026-11-15 01:30:00+00', 'PENDIENTE'),
                         ('d', timestamptz '2026-11-15 02:59:59+00', 'RECHAZADA'), ('e', timestamptz '2026-11-15 03:00:00+00', 'PENDIENTE')) x(k, ts, st);
create or replace function pg_temp.v5f(f jsonb) returns text language sql as $f$
  select coalesce((select string_agg(x->>'order_ref', ',' order by x->>'order_ref') from jsonb_array_elements(pg_temp.v5j(pg_temp.v5('c0000000-0000-0000-0000-0000000000d9', format('select public.com_history(%L, %L::jsonb, null, 100)::text', 'MIS', f)))->'items') x), '') $f$;
insert into v5_checks select 'V5-F01 (N-V4-05) día ARGENTINO 14/11: incluye 14/11 00:00 AR (03:00 UTC) y 23:59:59 AR (15/11 02:59:59 UTC, también 22:30 AR = 01:30 UTC); EXCLUYE 13/11 23:59:59 AR y 15/11 00:00 AR',
  pg_temp.v5f('{"from":"2026-11-14","to":"2026-11-14"}') = 'F-b,F-c,F-d', pg_temp.v5f('{"from":"2026-11-14","to":"2026-11-14"}') from (select 1) z;
insert into v5_checks select 'V5-F02 (N-V4-05) DESDE 15/11 empieza a las 00:00 AR (03:00 UTC); HASTA 13/11 termina a las 23:59:59 AR; combinado con estado (14/11 + PENDIENTE = solo 22:30 AR)',
  pg_temp.v5f('{"from":"2026-11-15"}') = 'F-e' and pg_temp.v5f('{"to":"2026-11-13"}') = 'F-a' and pg_temp.v5f('{"from":"2026-11-14","to":"2026-11-14","status":["PENDIENTE"]}') = 'F-c',
  pg_temp.v5f('{"from":"2026-11-15"}') || ' | ' || pg_temp.v5f('{"to":"2026-11-13"}') || ' | ' || pg_temp.v5f('{"from":"2026-11-14","to":"2026-11-14","status":["PENDIENTE"]}') from (select 1) z;
insert into v5_checks select 'V5-F03 (N-V4-05) no se modificaron los timestamps guardados ni el timezone de la base',
  (select created_at = timestamptz '2026-11-15 01:30:00+00' from public.com_requests where op_id = 'v5-fec-c') and current_setting('TimeZone') in ('UTC', 'Etc/UTC', 'GMT'), current_setting('TimeZone') from (select 1) z;
-- ===== N-V4-02 · vigencia de la sesión para el push (servidor) =====
insert into auth.sessions(id, user_id) values ('5e550000-0000-0000-0000-000000000001', :'C1') on conflict do nothing;
select pg_temp.v5sync(true); update public.profiles set sessions_revoked_at = now() where id = :'C1'; select pg_temp.v5sync(false);
create temp table v5_s as select
  public.push_session_valid(null, 1, null)->>'motivo' sin_usuario, public.push_session_valid(:'C1', null, null)->>'motivo' sin_iat,
  public.push_session_valid(:'C1', extract(epoch from now()) - 60, '5e550000-0000-0000-0000-000000000001')->>'motivo' revocada,   -- sesión EXISTENTE: el único motivo es la revocación
  public.push_session_valid(:'C1', extract(epoch from now()) + 60, null)->>'motivo' posterior,   -- N-V5-02: sin session_id → SESION_NO_IDENTIFICADA
  public.push_session_valid(:'C1', extract(epoch from now()) + 60, '5e550000-0000-0000-0000-0000000000ff')->>'motivo' inexistente,
  (public.push_session_valid(:'C1', extract(epoch from now()) + 60, '5e550000-0000-0000-0000-000000000001')->>'ok')::boolean existente;
select pg_temp.v5sync(true); update public.profiles set sessions_revoked_at = null, status = 'DESHABILITADO' where id = :'C1'; select pg_temp.v5sync(false);
insert into v5_s(sin_usuario) select public.push_session_valid(:'C1', extract(epoch from now()) + 60, '5e550000-0000-0000-0000-000000000001')->>'motivo';
select pg_temp.v5sync(true); update public.profiles set status = 'ACTIVO' where id = :'C1'; select pg_temp.v5sync(false);
insert into v5_checks select 'V5-S01 (N-V4-02 + N-V5-02) vigencia de sesión para el push: claims incompletos, token ANTERIOR a la revocación, SIN session_id, sesión inexistente y perfil no activo → rechazo; SOLO token posterior CON sesión existente → válida',
  (select sin_usuario = 'CLAIMS_INCOMPLETOS' and sin_iat = 'CLAIMS_INCOMPLETOS' and revocada = 'SESION_REVOCADA' and posterior = 'SESION_NO_IDENTIFICADA' and inexistente = 'SESION_INEXISTENTE' and existente from v5_s where sin_iat is not null)
  and (select sin_usuario = 'PERFIL_NO_ACTIVO' from v5_s where sin_iat is null), (select row_to_json(v5_s)::text from v5_s where sin_iat is not null) from (select 1) z;
insert into v5_checks select 'V5-S02 (N-V4-02) push_session_valid es SOLO del servicio: ni anon ni usuarios autenticados la ejecutan',
  not has_function_privilege('anon', 'public.push_session_valid(uuid,numeric,text)', 'EXECUTE') and not has_function_privilege('authenticated', 'public.push_session_valid(uuid,numeric,text)', 'EXECUTE'), '' from (select 1) z;
-- ===== revisión anticipatoria · el MISMO defecto de N-V4-05 en informes e historial de alarmas =====
create or replace function pg_temp.v5rep(d1 date, d2 date) returns int language sql as $f$
  select coalesce((select sum((x->>'cantidad')::int) from jsonb_array_elements(pg_temp.v5j(pg_temp.v5('e0000000-0000-0000-0000-00000000000a', format('select public.com_report(%L, %L)::text', d1, d2)))->'por_tipo_estado') x), 0)::int $f$;
create temp table v5_rep as select pg_temp.v5rep('2026-11-14', '2026-11-14') dia14, (select count(*)::int from public.com_requests
  where created_at >= timestamptz '2026-11-14 03:00:00+00' and created_at < timestamptz '2026-11-15 03:00:00+00') esperado14;
insert into v5_checks select 'V5-F04 (revisión anticipatoria) INFORMES (com_report) cuentan el día ARGENTINO: el 14/11 = de 03:00 UTC del 14 a 03:00 UTC del 15 (incluye las solicitudes de las 22:30 y 23:59:59 AR)',
  dia14 = esperado14 and esperado14 >= 3, dia14 || ' = ' || esperado14 from v5_rep;
select pg_temp.v5sync(true);
alter table public.com_alarms disable trigger user; update public.com_alarms set raised_at = timestamptz '2026-11-15 01:30:00+00' where id = (select id from v5_id); alter table public.com_alarms enable trigger user;
select pg_temp.v5sync(false);
create or replace function pg_temp.v5alh(d1 date, d2 date) returns boolean language sql as $f$
  select exists (select 1 from jsonb_array_elements(pg_temp.v5j(pg_temp.v5('e0000000-0000-0000-0000-00000000000a', format('select public.com_alarm_history_page(%L, %L, null, 100)::text', d1, d2)))->'items') x where (x->>'id')::uuid = (select id from v5_id)) $f$;
create or replace function pg_temp.v5alh1(d1 date, d2 date) returns boolean language sql as $f$
  select exists (select 1 from jsonb_array_elements(pg_temp.v5j(pg_temp.v5('e0000000-0000-0000-0000-00000000000a', format('select public.com_alarm_history(%L, %L)::text', d1, d2)))) x where (x->>'id')::uuid = (select id from v5_id)) $f$;
insert into v5_checks select 'V5-F05 (revisión anticipatoria) HISTORIAL DE ALARMAS (paginado y anterior): una alarma de las 22:30 AR del 14/11 (01:30 UTC del 15) figura el 14/11 y NO el 15/11',
  pg_temp.v5alh('2026-11-14', '2026-11-14') and not pg_temp.v5alh('2026-11-15', '2026-11-15') and pg_temp.v5alh1('2026-11-14', '2026-11-14') and not pg_temp.v5alh1('2026-11-15', '2026-11-15'),
  pg_temp.v5alh('2026-11-14', '2026-11-14')::text || '/' || pg_temp.v5alh('2026-11-15', '2026-11-15')::text from (select 1) z;
