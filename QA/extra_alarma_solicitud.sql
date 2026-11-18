-- SOLO PRUEBAS LOCALES · ALARMA URGENTE DESDE LA SOLICITUD COMERCIAL (001300). Aserciones exactas. Sin envíos reales (cola local).
create temp table as_checks(name text, ok boolean, detail text);
\set A  'e0000000-0000-0000-0000-00000000000a'
\set S  'e0000000-0000-0000-0000-000000000005'
\set O  'e0000000-0000-0000-0000-000000000006'
\set C1 'c0000000-0000-0000-0000-0000000000c1'
\set C2 'c0000000-0000-0000-0000-0000000000c2'
\set W  'c0000000-0000-0000-0000-0000000000a1'
\set F  'c0000000-0000-0000-0000-0000000000a2'
\set GB 'c0000000-0000-0000-0000-0000000000a3'
create or replace function pg_temp.as_u(u uuid, q text) returns text language plpgsql as $f$ declare o text; begin perform tst.u(u); set local role authenticated; begin execute q into o; exception when others then o := 'ERR ' || sqlerrm; end; reset role; return o; end $f$;
create or replace function pg_temp.as_j(t text) returns jsonb language sql as $f$ select case when t like '{%' or t like '[%' then t::jsonb else jsonb_build_object('error', t) end $f$;
create or replace function pg_temp.as_sync(on_ boolean) returns void language sql as $f$ select set_config('okd.sync', case when on_ then 'on' else '' end, false) $f$;
-- destinatarios vigentes (los MISMOS que usa REVISAR) y alarmas previas cerradas para aislar estas pruebas
select pg_temp.as_u(:'A', format($q$select public.com_set_alarm_settings(%L::jsonb)::text$q$, jsonb_build_object('initial_user', :'W', 'escalation_users', jsonb_build_array(:'F', :'GB'))));
create or replace function pg_temp.as_new(op text, cliente text) returns uuid language plpgsql as $f$ declare r jsonb; begin
  r := pg_temp.as_j(pg_temp.as_u('c0000000-0000-0000-0000-0000000000c1', format($q$select public.com_create_request('FINANCIACION', %L, null, '{"amount":250000,"installments":1,"first_due":"%s"}'::jsonb, null, %L)::text$q$,
    (select id from public.com_clients where erp_id = cliente), ((now() at time zone 'America/Argentina/Mendoza')::date + 7)::text, op)));
  return (select id from public.com_requests where op_id = op); end $f$;
create or replace function pg_temp.as_raise(u uuid, req uuid, op text, motivo text default 'El cliente espera la aprobación para cargar') returns jsonb language sql as $f$
  select pg_temp.as_j(pg_temp.as_u(u, format('select public.com_alarm_raise_request(%L, %L, %L)::text', req, motivo, op))) $f$;
-- ===== AS-01 · CASO DE LA CAPTURA: autorización PENDIENTE sin pedido ni hoja → alarma → el destinatario la abre y la atiende =====
create temp table as_r1 as select pg_temp.as_new('as-sol-1', '106') id;
create temp table as_a1 as select pg_temp.as_raise(:'O', (select id from as_r1), 'as-op-1') r;
create temp table as_al1 as select * from public.com_alarms where id = (select (r->>'id')::uuid from as_a1);
create temp table as_n1 as select e.notification_id nid from public.com_alarm_events e where e.alarm_id = (select id from as_al1) and e.kind = 'NOTIFICADO' and e.recipient_id = :'W';
insert into as_checks select 'AS-01a una autorización PENDIENTE SIN pedido ni hoja: el Operario genera la alarma; queda vinculada al identificador REAL (request_id) con su número AUT-… y los datos del cliente salen del SERVIDOR',
  (select r->>'ok' = 'true' and r->>'existing' = 'false' and r->>'status' = 'PENDIENTE_ATENCION' from as_a1)
  and (select request_id = (select id from as_r1) and order_ref = (select number from public.com_requests where id = (select id from as_r1)) and sheet_key = 'AUTORIZACION'
         and client_source = 'SOLICITUD_COMERCIAL' and client_name is not null and route_id is null and raised_by = :'O' and initial_user = :'W' from as_al1)
  and (select order_ref is null from public.com_requests where id = (select id from as_r1)), (select left(r::text, 160) from as_a1) from (select 1) z;
insert into as_checks select 'AS-01b el destinatario inicial CONFIGURADO recibe el aviso (campana + push encolado) que nombra la AUTORIZACIÓN; desde el aviso abre ESA autorización',
  exists (select 1 from public.notifications n join public.push_jobs j on j.notification_id = n.id where n.id = (select nid from as_n1) and n.type = 'COM_ALARMA'
            and n.body like 'Autorización ' || (select number from public.com_requests where id = (select id from as_r1)) || '%')
  and (select (pg_temp.as_j(pg_temp.as_u(:'W', format('select public.com_alarm_by_notification(%L)::text', (select nid from as_n1))))->'request'->>'id')::uuid = (select id from as_r1))
  and (select (pg_temp.as_j(pg_temp.as_u(:'W', format('select public.com_alarm_request_detail(%L)::text', (select id from as_al1))))->'request'->>'id')::uuid = (select id from as_r1)), '' from (select 1) z;
create temp table as_att as select pg_temp.as_j(pg_temp.as_u(:'W', format('select public.com_alarm_attend(%L, %s)::text', (select id from as_al1), (select version from as_al1)))) r;
create temp table as_st1 as select pg_temp.as_j(pg_temp.as_u(:'O', format('select public.com_request_alarm(%L)::text', (select id from as_r1)))) r;
insert into as_checks select 'AS-01c el destinatario ATIENDE: queda registrado QUIÉN y CUÁNDO; al volver al detalle el Operario ve la atención; la solicitud CONSERVA su estado comercial (PENDIENTE)',
  (select status = 'ATENDIDA' and attended_by = :'W' and attended_at is not null from public.com_alarms where id = (select id from as_al1))
  and (select r->>'status' = 'ATENDIDA' and r->>'attended_by' is not null and r->>'attended_at' is not null and r->>'origen' = 'SOLICITUD' and r->>'request_status' = 'PENDIENTE' from as_st1)
  and (select status = 'PENDIENTE' from public.com_requests where id = (select id from as_r1)), (select left(r::text, 200) from as_st1) from (select 1) z;
-- ===== AS-02 · doble toque / reintento por pérdida de conexión =====
create temp table as_r2 as select pg_temp.as_new('as-sol-2', '106') id;
create temp table as_a2 as select pg_temp.as_raise(:'O', (select id from as_r2), 'as-op-2') a, pg_temp.as_raise(:'O', (select id from as_r2), 'as-op-2') b, pg_temp.as_raise(:'O', (select id from as_r2), 'as-op-2b') c;
insert into as_checks select 'AS-02 DOBLE TOQUE (misma operación) y REINTENTO con otra operación: UNA sola alarma activa; la repetición devuelve la MISMA respuesta y el reintento muestra la EXISTENTE',
  a->>'id' = b->>'id' and b->>'repeated' = 'true' and c->>'existing' = 'true' and c->>'id' = a->>'id'
  and (select count(*) from public.com_alarms where request_id = (select id from as_r2)) = 1, left(c::text, 120) from as_a2;
-- ===== AS-04 · dos solicitudes del MISMO cliente: alarmas separadas e identificables =====
create temp table as_r4 as select pg_temp.as_new('as-sol-4a', '106') a, pg_temp.as_new('as-sol-4b', '106') b;
create temp table as_a4 as select pg_temp.as_raise(:'O', (select a from as_r4), 'as-op-4a') x, pg_temp.as_raise(:'O', (select b from as_r4), 'as-op-4b') y;
select pg_temp.as_u(:'W', format('select public.com_alarm_attend(%L, 1)::text', (select (x->>'id')::uuid from as_a4)));
insert into as_checks select 'AS-04 DOS solicitudes del MISMO cliente: dos alarmas distintas, cada una con SU autorización; atender una NO atiende la otra',
  x->>'id' <> y->>'id' and x->>'existing' = 'false' and y->>'existing' = 'false'
  and (select status from public.com_alarms where id = (x->>'id')::uuid) = 'ATENDIDA' and (select status from public.com_alarms where id = (y->>'id')::uuid) = 'PENDIENTE_ATENCION'
  and (select request_id from public.com_alarms where id = (y->>'id')::uuid) = (select b from as_r4), '' from as_a4;
-- ===== AS-05 · sesión REVOCADA =====
create temp table as_r5 as select pg_temp.as_new('as-sol-5', '106') id;
select pg_temp.as_sync(true); update public.profiles set sessions_revoked_at = now() + interval '1 hour' where id = :'O'; select pg_temp.as_sync(false);
create temp table as_a5 as select pg_temp.as_raise(:'O', (select id from as_r5), 'as-op-5') r, pg_temp.as_u(:'O', format('select public.com_request_alarm(%L)::text', (select id from as_r5))) estado;
select pg_temp.as_sync(true); update public.profiles set sessions_revoked_at = null where id = :'O'; select pg_temp.as_sync(false);
insert into as_checks select 'AS-05 SESIÓN REVOCADA: FORBIDDEN al emitir y al consultar el estado; no se crea alarma',
  r->>'error' like 'ERR FORBIDDEN%' and estado like 'ERR FORBIDDEN%' and not exists (select 1 from public.com_alarms where request_id = (select id from as_r5)), left(r->>'error', 40) from as_a5;
-- ===== AS-06 · identificador MANIPULADO, rol sin permiso y motivo corto =====
create temp table as_a6 as select pg_temp.as_raise(:'O', gen_random_uuid(), 'as-op-6a') inexistente, pg_temp.as_raise(:'C1', (select id from as_r5), 'as-op-6b') comercial,
  pg_temp.as_raise(:'O', (select id from as_r5), 'as-op-6c', 'corto') motivo, pg_temp.as_raise(:'O', null, 'as-op-6d') nulo,
  pg_temp.as_u(:'C2', format('select public.com_alarm_request_detail(%L)::text', (select id from as_al1))) ajeno;
insert into as_checks select 'AS-06 IDENTIFICADOR MANIPULADO (inexistente o nulo) → FORBIDDEN igual que sin acceso; Comercial sin com.track → FORBIDDEN; motivo corto → REASON_REQUIRED; un ajeno no abre la autorización desde una alarma',
  inexistente->>'error' like 'ERR FORBIDDEN%' and nulo->>'error' like 'ERR FORBIDDEN%' and comercial->>'error' like 'ERR FORBIDDEN%' and motivo->>'error' like 'ERR REASON_REQUIRED%' and ajeno like 'ERR FORBIDDEN%'
  and not exists (select 1 from public.com_alarms where request_id = (select id from as_r5)), '' from as_a6;
-- ===== AS-07 · la solicitud se RESOLVIÓ mientras el operario escribía =====
create temp table as_r7 as select pg_temp.as_new('as-sol-7', '106') id;
select pg_temp.as_u(:'A', format($q$select public.com_decide(%L, %s, 'APROBAR', null, null)::text$q$, (select id from as_r7), (select version from public.com_requests where id = (select id from as_r7))));
create temp table as_a7 as select pg_temp.as_raise(:'O', (select id from as_r7), 'as-op-7') r, pg_temp.as_raise(:'O', (select id from as_r7), 'as-op-7') again;
insert into as_checks select 'AS-07 la autorización se RESOLVIÓ antes de confirmar: NO se envía; se informa el estado VIGENTE (APROBADA); reintentar la misma operación da la misma respuesta',
  r->>'ok' = 'false' and r->>'code' = 'NOT_PENDING' and r->>'status' = 'APROBADA' and again->>'code' = 'NOT_PENDING' and again->>'repeated' = 'true'
  and not exists (select 1 from public.com_alarms where request_id = (select id from as_r7)), left(r->>'message', 120) from as_a7;
-- ===== AS-08 · ESCALAMIENTO por falta de atención =====
create temp table as_r8 as select pg_temp.as_new('as-sol-8', '106') id;
create temp table as_a8 as select pg_temp.as_raise(:'O', (select id from as_r8), 'as-op-8') r;
update public.com_alarms set escalate_at = now() - interval '1 second' where id = (select (r->>'id')::uuid from as_a8);
select public.com_alarm_escalate_due();
insert into as_checks select 'AS-08 sin atención: el ESCALAMIENTO automático vigente la escala a los destinatarios configurados con un aviso que nombra la AUTORIZACIÓN (no «Pedido»)',
  (select escalated_at is not null and escalated_to @> array[:'F', :'GB']::uuid[] from public.com_alarms where id = (select (r->>'id')::uuid from as_a8))
  and exists (select 1 from public.com_alarm_events e join public.notifications n on n.id = e.notification_id where e.alarm_id = (select (r->>'id')::uuid from as_a8) and n.type = 'COM_ALARMA_ESCALADA' and n.body like 'Autorización AUT-%')
  and (select (pg_temp.as_j(pg_temp.as_u(:'GB', format('select public.com_alarm_request_detail(%L)::text', (r->>'id')::uuid)))->'request'->>'id')::uuid = (select id from as_r8)), '' from as_a8;
-- ===== AS-09 · cruce con REVISAR (una activa por solicitud en ambos sentidos) y REVISAR intacto =====
create temp table as_r9 as select pg_temp.as_new('as-sol-9', '106') id;
update public.com_requests set order_ref = '27503' where id = (select id from as_r9);   -- pedido ya reservado en la hoja V5-1 (fixture)
create temp table as_a9 as select pg_temp.as_raise(:'O', (select id from as_r9), 'as-op-9') sol;
alter table as_a9 add column rev jsonb; update as_a9 set rev = pg_temp.as_j(pg_temp.as_u(:'O', $q$select public.com_alarm_raise('27503', 'V5-1', 'x', '', 'REVISAR para el mismo pedido de la solicitud', 'as-op-9r')::text$q$));
insert into as_checks select 'AS-09 CRUCE con REVISAR: con la alarma de la solicitud activa, REVISAR para su pedido devuelve la MISMA alarma (no crea otra)',
  sol->>'existing' = 'false' and rev->>'existing' = 'true' and rev->>'id' = sol->>'id'
  and (select count(*) from public.com_alarms where status = 'PENDIENTE_ATENCION' and (request_id = (select id from as_r9) or upper(order_ref) = '27503')) = 1, left(rev::text, 100) from as_a9;
select pg_temp.as_u(:'W', format('select public.com_alarm_attend(%L, 1)::text', (select (sol->>'id')::uuid from as_a9)));
create temp table as_a9b as select pg_temp.as_j(pg_temp.as_u(:'O', $q$select public.com_alarm_raise('27503', 'V5-1', 'x', '', 'REVISAR primero, ahora para el mismo pedido', 'as-op-9r2')::text$q$)) rev;
alter table as_a9b add column sol jsonb; update as_a9b set sol = pg_temp.as_raise(:'O', (select id from as_r9), 'as-op-9s2');
insert into as_checks select 'AS-10 CRUCE inverso: con la alarma de REVISAR activa para su pedido, la de la solicitud muestra la EXISTENTE; REVISAR sigue usando «Pedido …»',
  rev->>'existing' = 'false' and sol->>'existing' = 'true' and sol->>'id' = rev->>'id'
  and (select sheet_key = 'V5-1' and order_ref = '27503' from public.com_alarms where id = (rev->>'id')::uuid)
  and exists (select 1 from public.com_alarm_events e join public.notifications n on n.id = e.notification_id where e.alarm_id = (rev->>'id')::uuid and n.body like 'Pedido 27503%'), '' from as_a9b;
-- ===== AS-11 · permisos ACTUALES del destinatario al despachar (validación vigente) =====
select pg_temp.as_sync(true); update public.profiles set disabled_modules = array['COMERCIAL'] where id = :'W'; select pg_temp.as_sync(false);
create temp table as_a11 as select public.push_recipient_allowed((select e.notification_id from public.com_alarm_events e where e.alarm_id = (select (r->>'id')::uuid from as_a8) and e.recipient_id = :'W' and e.kind = 'NOTIFICADO' limit 1)) r;
select pg_temp.as_sync(true); update public.profiles set disabled_modules = '{}' where id = :'W'; select pg_temp.as_sync(false);
insert into as_checks select 'AS-11 al DESPACHAR el push se verifica el acceso ACTUAL del destinatario (COMERCIAL restringido → no se envía)', r->>'ok' = 'false', r::text from as_a11;
-- ===================== CORRECCIÓN (auditoría Work): la alarma de una autorización se identifica por su request_id =====================
create or replace function pg_temp.as_rev(ped text, op text) returns jsonb language sql as $f$
  select pg_temp.as_j(pg_temp.as_u('e0000000-0000-0000-0000-000000000006', format($q$select public.com_alarm_raise(%L, 'V5-1', 'x', '', 'REVISAR desde la hoja para este pedido', %L)::text$q$, ped, op))) $f$;
create or replace function pg_temp.as_open(alarm uuid) returns uuid language sql as $f$
  select (pg_temp.as_j(pg_temp.as_u('c0000000-0000-0000-0000-0000000000a1', format('select public.com_alarm_request_detail(%L)::text', alarm)))->'request'->>'id')::uuid $f$;
select pg_temp.as_u(:'O', $q$select public.reserve_orders('V5-1', array['27504','27505','27506'])::text$q$);
-- ===== AS-13 · CASO DE WORK: A (REVISAR) y B (Seguimiento) comparten pedido y cliente =====
create temp table as13 as select pg_temp.as_new('as-sol-13b', '106') b;   -- B se crea primero; A después (REVISAR vincula la MÁS RECIENTE)
alter table as13 add column a uuid; update as13 set a = pg_temp.as_new('as-sol-13a', '106');
update public.com_requests set order_ref = '27502' where id in (select a from as13 union select b from as13);
alter table as13 add column rev jsonb; update as13 set rev = pg_temp.as_rev('27502', 'as-op-13r');
alter table as13 add column sol jsonb; update as13 set sol = pg_temp.as_raise(:'O', (select b from as13), 'as-op-13s');
insert into as_checks select 'AS-13 CASO DE WORK (pedido 27502 compartido): A desde REVISAR y B desde Seguimiento → DOS alarmas activas independientes, cada una con SU request_id; el aviso de cada una abre SU autorización',
  rev->>'existing' = 'false' and sol->>'existing' = 'false' and rev->>'id' <> sol->>'id'
  and (select request_id from public.com_alarms where id = (rev->>'id')::uuid) = a and (select request_id from public.com_alarms where id = (sol->>'id')::uuid) = b
  and (select count(*) from public.com_alarms where status = 'PENDIENTE_ATENCION' and request_id in (a, b)) = 2
  and pg_temp.as_open((rev->>'id')::uuid) = a and pg_temp.as_open((sol->>'id')::uuid) = b,
  'pedido 27502 · A=' || a || ' · B=' || b || ' · alarma A=' || coalesce(rev->>'id', '?') || ' · alarma B=' || coalesce(sol->>'id', '?') || ' (existing B=' || coalesce(sol->>'existing', '?') || ')' from as13;
select pg_temp.as_u(:'W', format('select public.com_alarm_attend(%L, 1)::text', (select (rev->>'id')::uuid from as13)));
insert into as_checks select 'AS-13b atender la alarma de A deja la de B PENDIENTE (y ninguna aprueba ni rechaza)',
  (select status from public.com_alarms where id = (rev->>'id')::uuid) = 'ATENDIDA' and (select status from public.com_alarms where id = (sol->>'id')::uuid) = 'PENDIENTE_ATENCION'
  and (select string_agg(status, ',' order by status) from public.com_requests where id in (a, b)) = 'PENDIENTE,PENDIENTE', '' from as13;
-- ===== AS-14 · orden INVERTIDO: primero Seguimiento (B) y después REVISAR (A) =====
create temp table as14 as select pg_temp.as_new('as-sol-14b', '106') b;
alter table as14 add column a uuid; update as14 set a = pg_temp.as_new('as-sol-14a', '106');
update public.com_requests set order_ref = '27504' where id in (select a from as14 union select b from as14);
alter table as14 add column sol jsonb; update as14 set sol = pg_temp.as_raise(:'O', (select b from as14), 'as-op-14s');
alter table as14 add column rev jsonb; update as14 set rev = pg_temp.as_rev('27504', 'as-op-14r');
insert into as_checks select 'AS-14 orden INVERTIDO (pedido 27504): B desde Seguimiento y DESPUÉS A desde REVISAR → dos alarmas activas independientes, cada aviso abre SU autorización',
  sol->>'existing' = 'false' and rev->>'existing' = 'false' and rev->>'id' <> sol->>'id'
  and (select request_id from public.com_alarms where id = (rev->>'id')::uuid) = a and (select request_id from public.com_alarms where id = (sol->>'id')::uuid) = b
  and pg_temp.as_open((rev->>'id')::uuid) = a and pg_temp.as_open((sol->>'id')::uuid) = b,
  'alarma A=' || coalesce(rev->>'id', '?') || ' (existing ' || coalesce(rev->>'existing', '?') || ') · alarma B=' || coalesce(sol->>'id', '?') from as14;
-- ===== AS-15 · UNA autorización, DOS pantallas (en ambos sentidos): una sola alarma activa =====
create temp table as15 as select pg_temp.as_new('as-sol-15', '106') e;
update public.com_requests set order_ref = '27505' where id = (select e from as15);
alter table as15 add column rev jsonb; update as15 set rev = pg_temp.as_rev('27505', 'as-op-15r');
alter table as15 add column sol jsonb; update as15 set sol = pg_temp.as_raise(:'O', (select e from as15), 'as-op-15s');
alter table as15 add column estado jsonb; update as15 set estado = pg_temp.as_j(pg_temp.as_u(:'O', format('select public.com_request_alarm(%L)::text', (select e from as15))));
create temp table as15b as select pg_temp.as_new('as-sol-15b', '106') f;
update public.com_requests set order_ref = '27506' where id = (select f from as15b);
alter table as15b add column sol jsonb; update as15b set sol = pg_temp.as_raise(:'O', (select f from as15b), 'as-op-15bs');
alter table as15b add column rev jsonb; update as15b set rev = pg_temp.as_rev('27506', 'as-op-15br');
insert into as_checks select 'AS-15 MISMA autorización en las DOS pantallas: REVISAR→Seguimiento y Seguimiento→REVISAR recuperan la MISMA alarma (una sola activa) y el estado la muestra',
  (select sol->>'existing' = 'true' and sol->>'id' = rev->>'id' and estado->>'id' = rev->>'id' and (select count(*) from public.com_alarms where status = 'PENDIENTE_ATENCION' and request_id = e) = 1 from as15)
  and (select rev->>'existing' = 'true' and rev->>'id' = sol->>'id' and (select count(*) from public.com_alarms where status = 'PENDIENTE_ATENCION' and request_id = f) = 1 from as15b),
  (select 'REVISAR→Seg: ' || coalesce(sol->>'existing', '?') from as15) || ' · ' || (select 'Seg→REVISAR: ' || coalesce(rev->>'existing', '?') from as15b) from (select 1) z;
-- ===== AS-16 · alarma de PEDIDO sin request_id: no se atribuye a una autorización por la sola coincidencia del pedido =====
select pg_temp.as_u(:'O', $q$select public.reserve_orders('V5-1', array['27507'])::text$q$);
create temp table as16 as select pg_temp.as_rev('27507', 'as-op-16r') rev;   -- ninguna autorización con ese pedido todavía → request_id null
alter table as16 add column g uuid; update as16 set g = pg_temp.as_new('as-sol-16', '106');
update public.com_requests set order_ref = '27507' where id = (select g from as16);
alter table as16 add column antes jsonb; update as16 set antes = pg_temp.as_j(pg_temp.as_u(:'O', format('select coalesce(public.com_request_alarm(%L)::text, %L)', (select g from as16), 'null')));
alter table as16 add column sol jsonb; update as16 set sol = pg_temp.as_raise(:'O', (select g from as16), 'as-op-16s');
alter table as16 add column rev2 jsonb; update as16 set rev2 = pg_temp.as_rev('27507', 'as-op-16r2');
insert into as_checks select 'AS-16 alarma de PEDIDO sin request_id: el estado de la autorización NO la toma como propia; Seguimiento crea la SUYA; REVISAR recupera la de la AUTORIZACIÓN por su request_id',
  (select request_id is null from public.com_alarms where id = (rev->>'id')::uuid) and antes->>'error' = 'null' and sol->>'existing' = 'false' and sol->>'id' <> rev->>'id'
  and (select request_id from public.com_alarms where id = (sol->>'id')::uuid) = g and rev2->>'existing' = 'true' and rev2->>'id' = sol->>'id',   -- REVISAR: la de la AUTORIZACIÓN (request_id)
  'estado previo=' || coalesce(antes::text, 'null') || ' · Seguimiento existing=' || coalesce(sol->>'existing', '?') from as16;

-- ===================== CORRECCIÓN 2 (Work): REVISAR resuelve la autorización UNA vez y recupera la alarma por request_id =====================
select pg_temp.as_u(:'O', $q$select public.reserve_orders('V5-1', array['27509','27510','27511'])::text$q$);
-- ===== AS-18a · CASO DE WORK: A (REVISAR) y B (Seguimiento, más reciente) comparten pedido; VOLVER a REVISAR → la alarma de B =====
create temp table as18 as select pg_temp.as_new('as-sol-18a', '106') a;
update public.com_requests set order_ref = '27509' where id = (select a from as18);
alter table as18 add column xa jsonb; update as18 set xa = pg_temp.as_rev('27509', 'as-op-18ra');            -- A es la única: REVISAR la vincula a A
alter table as18 add column b uuid; update as18 set b = pg_temp.as_new('as-sol-18b', '106');
update public.com_requests set order_ref = '27509' where id = (select b from as18);
alter table as18 add column yb jsonb; update as18 set yb = pg_temp.as_raise(:'O', (select b from as18), 'as-op-18sb');   -- B desde Seguimiento
alter table as18 add column otra jsonb; update as18 set otra = pg_temp.as_rev('27509', 'as-op-18rb');          -- VOLVER a REVISAR: ahora vincula B (la más reciente)
insert into as_checks select 'AS-18a CASO DE WORK 2 (pedido 27509): con la alarma de A (REVISAR) y la de B (Seguimiento) activas, VOLVER a REVISAR devuelve la de B (su request_id), NO la más antigua de A; el aviso abre B',
  xa->>'existing' = 'false' and yb->>'existing' = 'false' and otra->>'existing' = 'true' and otra->>'id' = yb->>'id' and otra->>'id' <> xa->>'id'
  and (select request_id from public.com_alarms where id = (otra->>'id')::uuid) = b and pg_temp.as_open((otra->>'id')::uuid) = b
  and (select request_id from public.com_alarms where id = (xa->>'id')::uuid) = a,
  'A=' || a || ' (alarma ' || coalesce(xa->>'id','?') || ') · B=' || b || ' (alarma ' || coalesce(yb->>'id','?') || ') · REVISAR devolvió ' || coalesce(otra->>'id','?') from as18;
-- ===== AS-18b · A con alarma de REVISAR y B (más reciente) SIN alarma: REVISAR CREA la de B; la de A queda intacta =====
create temp table as18b as select pg_temp.as_new('as-sol-18c', '106') c;
update public.com_requests set order_ref = '27510' where id = (select c from as18b);
alter table as18b add column xc jsonb; update as18b set xc = pg_temp.as_rev('27510', 'as-op-18rc');
alter table as18b add column d uuid; update as18b set d = pg_temp.as_new('as-sol-18d', '106');
update public.com_requests set order_ref = '27510' where id = (select d from as18b);
alter table as18b add column xd jsonb; update as18b set xd = pg_temp.as_rev('27510', 'as-op-18rd');
insert into as_checks select 'AS-18b REVISAR para un pedido cuya alarma activa es de OTRA autorización: CREA la alarma de la autorización vigente (B) en vez de devolver la de A; dos activas del mismo pedido, cada una con su request_id',
  xc->>'existing' = 'false' and xd->>'existing' = 'false' and xd->>'id' <> xc->>'id'
  and (select request_id from public.com_alarms where id = (xd->>'id')::uuid) = d and (select request_id from public.com_alarms where id = (xc->>'id')::uuid) = c
  and (select count(*) from public.com_alarms where status = 'PENDIENTE_ATENCION' and upper(order_ref) = '27510') = 2
  and pg_temp.as_open((xd->>'id')::uuid) = d and pg_temp.as_open((xc->>'id')::uuid) = c, 'C=' || c || ' · D=' || d from as18b;
-- ===== AS-18c · CONVIVENCIA: alarma de PEDIDO sin autorización (anterior a la solicitud) =====
create temp table as18c as select pg_temp.as_rev('27511', 'as-op-18rp') p;                                       -- sin autorización todavía → request_id null
alter table as18c add column e uuid; update as18c set e = pg_temp.as_new('as-sol-18e', '106');
update public.com_requests set order_ref = '27511' where id = (select e from as18c);
alter table as18c add column rev2 jsonb; update as18c set rev2 = pg_temp.as_rev('27511', 'as-op-18rp2');
alter table as18c add column sol jsonb; update as18c set sol = pg_temp.as_raise(:'O', (select e from as18c), 'as-op-18se');
insert into as_checks select 'AS-18c CONVIVENCIA: la alarma de PEDIDO sin autorización se REUTILIZA desde REVISAR (no se duplica) y NO se atribuye a la autorización; Seguimiento crea la SUYA',
  (select request_id is null from public.com_alarms where id = (p->>'id')::uuid) and rev2->>'existing' = 'true' and rev2->>'id' = p->>'id'
  and sol->>'existing' = 'false' and sol->>'id' <> p->>'id' and (select request_id from public.com_alarms where id = (sol->>'id')::uuid) = e
  and (select request_id is null from public.com_alarms where id = (p->>'id')::uuid), '' from as18c;
