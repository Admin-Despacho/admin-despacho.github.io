-- SOLO PRUEBAS LOCALES · HISTORIAL COMPLETO POR VENDEDOR (com_history / com_request_detail). Aserciones POSITIVAS. Datos sintéticos.
create temp table hi_checks(name text, ok boolean, detail text);
create or replace function pg_temp.hi_h(u uuid, q text) returns text language plpgsql as $f$ declare o text; begin perform tst.u(u); set local role authenticated; begin execute q into o; exception when others then o := 'ERR ' || sqlerrm; end; reset role; return o; end $f$;
create or replace function pg_temp.hi_hj(t text) returns jsonb language sql as $f$ select case when t like '[%' or t like '{%' then t::jsonb end $f$;
create or replace function pg_temp.hi_hist(u uuid, scope text, f jsonb, cur jsonb, lim int) returns jsonb language sql as $f$
  select pg_temp.hi_hj(pg_temp.hi_h(u, format('select public.com_history(%L, %L::jsonb, %L::jsonb, %s)::text', scope, f, cur, lim))) $f$;
-- recorre TODAS las páginas por cursor y devuelve los ids en el orden recibido
create or replace function pg_temp.hi_all_pages(u uuid, scope text, f jsonb, lim int) returns text[] language plpgsql as $f$
declare cur jsonb := null; r jsonb; ids text[] := '{}'; guard int := 0;
begin loop r := pg_temp.hi_hist(u, scope, f, cur, lim); exit when r is null;
  ids := ids || array(select x->>'id' from jsonb_array_elements(r->'items') x);
  exit when not (r->>'has_more')::boolean; cur := r->'next_cursor'; guard := guard + 1; exit when guard > 500; end loop; return ids; end $f$;
\set A  'e0000000-0000-0000-0000-00000000000a'
\set O  'e0000000-0000-0000-0000-000000000006'
\set C1 'c0000000-0000-0000-0000-0000000000c1'
\set W  'c0000000-0000-0000-0000-0000000000a1'
\set V1 'c0000000-0000-0000-0000-0000000000d1'
\set V2 'c0000000-0000-0000-0000-0000000000d2'
\set V3 'c0000000-0000-0000-0000-0000000000d3'
-- tres vendedores NUEVOS (Comercial, sucursal Montecaseros → aprobador Wilfredo)
insert into auth.users(id, email) values (:'V1', 'vend1@t'), (:'V2', 'vend2@t'), (:'V3', 'vend3@t') on conflict do nothing;
select set_config('okd.sync', 'on', false);
insert into public.profiles(id, full_name, email, role, status) values (:'V1', 'Vendedor Uno', 'vend1@t', 'COMERCIAL', 'ACTIVO'), (:'V2', 'Vendedor Dos', 'vend2@t', 'COMERCIAL', 'ACTIVO'),
  (:'V3', 'Vendedor Tres', 'vend3@t', 'COMERCIAL', 'ACTIVO') on conflict (id) do nothing;
select set_config('okd.sync', '', false);
select pg_temp.hi_h(:'A', format($q$select public.com_set_assignment(%L, 'SUCURSAL', 'MONTECASEROS', null)::text$q$, x)) from unnest(array[:'V1', :'V2', :'V3']::uuid[]) x;
-- H01 · cero solicitudes
create temp table hi_0 as select pg_temp.hi_hist(:'V1', 'MIS', '{}', null, 25) r;
insert into hi_checks select 'H01 vendedor con CERO solicitudes: lista vacía y sin más resultados', jsonb_array_length(r->'items') = 0 and not (r->>'has_more')::boolean, r::text from hi_0;
-- H02 · una solicitud (circuito REAL)
select pg_temp.hi_h(:'V1', format($q$select public.com_create_request('FINANCIACION', %L, 'HP-UNO', '{"amount":120000,"installments":2}'::jsonb, 'nota del vendedor', 'hi-op-1')::text$q$, (select id from public.com_clients where erp_id = '106')));
create temp table hi_1 as select pg_temp.hi_hist(:'V1', 'MIS', '{}', null, 25) r;
insert into hi_checks select 'H02 vendedor con UNA solicitud: número, cliente, pedido, tipo, importe solicitado, fecha, estado, aprobador asignado y última modificación',
  jsonb_array_length(r->'items') = 1 and (select x ?& array['number', 'client', 'order_ref', 'kind', 'amount', 'created_at', 'status', 'assigned_approver', 'updated_at'] and (x->>'amount')::numeric = 120000
    and x->>'order_ref' = 'HP-UNO' and x->>'status' = 'PENDIENTE' and x->>'assigned_approver' like 'Wilfredo%' from jsonb_array_elements(r->'items') x), left(r::text, 300) from hi_1;
-- volumen: 135 solicitudes de V2 (copia de una plantilla REAL) con estados y fechas variadas; 12 con la MISMA fecha (desempate por id)
create temp table hi_tpl as select * from public.com_requests where op_id = 'hi-op-1';
insert into public.com_requests select (jsonb_populate_record(null::public.com_requests, to_jsonb(t) || jsonb_build_object(
    'id', gen_random_uuid(), 'number', 'HIS-' || lpad(g::text, 6, '0'), 'op_id', 'hi-v2-' || g, 'requested_by', :'V2', 'order_ref', 'HP-' || g,
    'kind', case when g % 4 = 0 then 'ECHEQ' else 'FINANCIACION' end,
    'status', (array['PENDIENTE', 'APROBADA', 'APROBADA_MOD', 'RECHAZADA', 'DEVUELTA', 'CANCELADA'])[1 + g % 6],
    'created_at', case when g between 50 and 61 then timestamptz '2026-10-15 10:00:00+00' else timestamptz '2026-09-01 08:00:00+00' + make_interval(hours => g * 7) end,
    'updated_at', timestamptz '2026-11-01 00:00:00+00'))).*
  from hi_tpl t, generate_series(1, 135) g;
create temp table hi_v2 as select array_agg(id::text order by created_at desc, id desc) ids from public.com_requests where requested_by = :'V2';
create temp table hi_p as select pg_temp.hi_all_pages(:'V2', 'MIS', '{}', 25) p25, pg_temp.hi_all_pages(:'V2', 'MIS', '{}', 7) p7, pg_temp.hi_hist(:'V2', 'MIS', '{}', null, 500) big;
insert into hi_checks select 'H03 MÁS DE 30 y MÁS DE 100 (135 solicitudes): la paginación por cursor recorre TODO sin faltantes ni duplicados y en orden estable (páginas de 25 y de 7), aun con 12 solicitudes de fecha idéntica',
  cardinality(p25) = 135 and (select count(distinct x) from unnest(p25) x) = 135 and p25 = (select ids from hi_v2) and p7 = (select ids from hi_v2), cardinality(p25) || ' / ' || cardinality(p7) from hi_p;
insert into hi_checks select 'H03b sin LÍMITE artificial de 30, pero con página máxima de 100 (no carga miles de registros juntos) e indicación de que quedan resultados',
  jsonb_array_length(big->'items') = 100 and (big->>'has_more')::boolean and (big->>'page_size')::int = 100, '' from hi_p;
insert into hi_checks select 'H04 historial con APROBADAS, RECHAZADAS, PENDIENTES, DEVUELTAS, CON MODIFICACIONES y CANCELADAS: todas se conservan y el filtro por estado devuelve exactamente cada grupo',
  (select bool_and(cardinality(pg_temp.hi_all_pages(:'V2', 'MIS', jsonb_build_object('status', jsonb_build_array(s)), 50)) = (select count(*) from public.com_requests where requested_by = :'V2' and status = s))
     from unnest(array['PENDIENTE', 'APROBADA', 'APROBADA_MOD', 'RECHAZADA', 'DEVUELTA', 'CANCELADA']) s)
  and cardinality(pg_temp.hi_all_pages(:'V2', 'MIS', '{"status":["APROBADA","CANCELADA"]}', 50)) = (select count(*) from public.com_requests where requested_by = :'V2' and status in ('APROBADA', 'CANCELADA')), '' from (select 1) z;
create temp table hi_f as select pg_temp.hi_all_pages(:'V2', 'MIS', '{"status":["PENDIENTE","APROBADA"],"kind":"FINANCIACION","from":"2026-09-10","to":"2026-10-20"}', 10) f1,
  pg_temp.hi_all_pages(:'V2', 'MIS', '{"order_ref":"HP-12"}', 10) f2, pg_temp.hi_all_pages(:'V2', 'MIS', '{"number":"HIS-000077"}', 10) f3,
  pg_temp.hi_all_pages(:'V2', 'MIS', jsonb_build_object('q', (select left(client_snapshot->>'razon_social', 5) from hi_tpl)), 50) f4;
insert into hi_checks select 'H05 FILTROS COMBINADOS (estado + tipo + fecha desde/hasta) y búsqueda por pedido, por número de solicitud y por cliente: coinciden con la consulta directa',
  cardinality(f1) = (select count(*) from public.com_requests where requested_by = :'V2' and status in ('PENDIENTE', 'APROBADA') and kind = 'FINANCIACION'
    and created_at >= (date '2026-09-10'::timestamp at time zone 'America/Argentina/Mendoza') and created_at < ((date '2026-10-20' + 1)::timestamp at time zone 'America/Argentina/Mendoza'))   -- día operativo ARGENTINO (N-V4-05)
  and cardinality(f1) > 0 and cardinality(f2) = (select count(*) from public.com_requests where requested_by = :'V2' and order_ref like 'HP-12%')
  and cardinality(f3) = 1 and cardinality(f4) = 135, cardinality(f1) || ' · ' || cardinality(f2) || ' · ' || cardinality(f3) || ' · ' || cardinality(f4) from hi_f;
insert into hi_checks select 'H06 LIMPIAR FILTROS recupera el listado completo (sin filtros = 135)', cardinality(pg_temp.hi_all_pages(:'V2', 'MIS', '{}', 50)) = 135, '' from (select 1) z;
-- H07 · solicitudes NUEVAS mientras se pagina
create temp table hi_n1 as select pg_temp.hi_hist(:'V2', 'MIS', '{}', null, 25) p1;
insert into public.com_requests select (jsonb_populate_record(null::public.com_requests, to_jsonb(t) || jsonb_build_object('id', gen_random_uuid(), 'number', 'HIS-NEW-' || g, 'op_id', 'hi-new-' || g,
  'requested_by', :'V2', 'created_at', now() + make_interval(secs => g)))).* from hi_tpl t, generate_series(1, 3) g;
create temp table hi_n2 as select (select array_agg(x->>'id') from jsonb_array_elements(p1->'items') x) pag1, p1->'next_cursor' cur from hi_n1;
create or replace function pg_temp.hi_rest(u uuid, cur jsonb) returns text[] language plpgsql as $f$ declare r jsonb; ids text[] := '{}'; begin loop r := pg_temp.hi_hist(u, 'MIS', '{}', cur, 25);
  ids := ids || array(select x->>'id' from jsonb_array_elements(r->'items') x); exit when not (r->>'has_more')::boolean; cur := r->'next_cursor'; end loop; return ids; end $f$;
create temp table hi_n3 as select pag1 || pg_temp.hi_rest(:'V2', cur) todos from hi_n2;
insert into hi_checks select 'H07 NUEVAS solicitudes durante la consulta: seguir con el cursor completa las 135 originales SIN duplicar ni omitir (las nuevas aparecen al volver a empezar: 138)',
  cardinality(todos) = 135 and (select count(distinct x) from unnest(todos) x) = 135 and todos = (select ids from hi_v2)
  and cardinality(pg_temp.hi_all_pages(:'V2', 'MIS', '{}', 50)) = 138, cardinality(todos)::text from hi_n3;
-- H08 · acceso ajeno y llamadas manipuladas
create temp table hi_m as select (select id from public.com_requests where requested_by = :'V2' limit 1) ajena;
create temp table hi_m2 as select pg_temp.hi_h(:'V1', format('select public.com_request_detail(%L)::text', ajena)) det_ajena, pg_temp.hi_h(:'V1', format('select public.com_request_detail(%L)::text', gen_random_uuid())) det_inexistente,
  pg_temp.hi_h(:'V1', $q$select public.com_history('TODAS', '{}'::jsonb, null, 25)::text$q$) todas, pg_temp.hi_h(:'V1', $q$select public.com_history('BANDEJA', '{}'::jsonb, null, 25)::text$q$) bandeja,
  pg_temp.hi_h(:'V1', $q$select public.com_history('MIS', '{}'::jsonb, '{"c":"x","i":"y"}'::jsonb, 25)::text$q$) cursor_malo,
  pg_temp.hi_h(:'V1', $q$select public.com_history('MIS', '{"q":"%'' or 1=1 --","number":"%"}'::jsonb, null, 25)::text$q$) inyeccion,
  pg_temp.hi_h(:'V1', $q$select public.com_history('OTRO', '{}'::jsonb, null, 25)::text$q$) alcance_raro from hi_m;
insert into hi_checks select 'H08 ACCESO AJENO y MANIPULACIÓN: el detalle de una solicitud ajena responde IGUAL que una inexistente; alcances TODAS/BANDEJA/desconocido rechazados; cursor manipulado rechazado; filtros con comodines o comillas no amplían el alcance',
  det_ajena like 'ERR FORBIDDEN%' and det_inexistente like 'ERR FORBIDDEN%' and det_ajena = det_inexistente and todas like 'ERR FORBIDDEN%' and bandeja like 'ERR FORBIDDEN%'
  and cursor_malo like 'ERR BAD_CURSOR%' and alcance_raro like 'ERR %' and pg_temp.hi_hj(inyeccion)->'items' = '[]'::jsonb
  and not exists (select 1 from unnest(pg_temp.hi_all_pages(:'V1', 'MIS', '{}', 50)) x where x::uuid in (select id from public.com_requests where requested_by <> :'V1')),
  left(det_ajena, 40) || ' | ' || left(todas, 30) || ' | ' || left(cursor_malo, 30) from hi_m2;
-- H09 · cambio de rol  ·  H10 · deshabilitación y sesión revocada
select set_config('okd.sync', 'on', false); update public.profiles set role = 'SOLO_LECTURA' where id = :'V1'; select set_config('okd.sync', '', false);
create temp table hi_r as select pg_temp.hi_h(:'V1', $q$select public.com_history('MIS', '{}'::jsonb, null, 25)::text$q$) sin_rol,
  pg_temp.hi_h(:'V1', format('select public.com_request_detail(%L)::text', (select id from public.com_requests where op_id = 'hi-op-1'))) det_sin_rol;
select set_config('okd.sync', 'on', false); update public.profiles set role = 'COMERCIAL', status = 'DESHABILITADO' where id = :'V1'; select set_config('okd.sync', '', false);
insert into hi_r(sin_rol) select pg_temp.hi_h(:'V1', $q$select public.com_history('MIS', '{}'::jsonb, null, 25)::text$q$);
select set_config('okd.sync', 'on', false); update public.profiles set status = 'ACTIVO', sessions_revoked_at = now() + interval '1 hour' where id = :'V1'; select set_config('okd.sync', '', false);
insert into hi_r(sin_rol) select pg_temp.hi_h(:'V1', $q$select public.com_history('MIS', '{}'::jsonb, null, 25)::text$q$);
select set_config('okd.sync', 'on', false); update public.profiles set sessions_revoked_at = null where id = :'V1'; select set_config('okd.sync', '', false);
insert into hi_checks select 'H09/H10 CAMBIO DE ROL (Comercial → Solo lectura), DESHABILITACIÓN y SESIÓN REVOCADA: el historial y el detalle quedan inaccesibles (FORBIDDEN); al restablecer, vuelve a funcionar',
  (select count(*) from hi_r where sin_rol like 'ERR FORBIDDEN%') = 3 and (select det_sin_rol like 'ERR FORBIDDEN%' from hi_r where det_sin_rol is not null)
  and jsonb_array_length(pg_temp.hi_hist(:'V1', 'MIS', '{}', null, 25)->'items') = 1, (select string_agg(left(sin_rol, 22), ' | ') from hi_r) from (select 1) z;
-- H11 · aprobador, Administrador y Despacho
insert into hi_checks select 'H11 ALCANCES: el aprobador ve en BANDEJA solo las asignadas a él; el Administrador ve TODAS; Despacho no accede al historial comercial (sin com.request ni com.approve)',
  (select bool_and(x->>'assigned_approver' like 'Wilfredo%') from jsonb_array_elements(pg_temp.hi_hist(:'W', 'BANDEJA', '{}', null, 100)->'items') x)
  and cardinality(pg_temp.hi_all_pages(:'A', 'TODAS', '{}', 100)) = (select count(*) from public.com_requests)
  and pg_temp.hi_h(:'O', $q$select public.com_history('MIS', '{}'::jsonb, null, 25)::text$q$) like 'ERR FORBIDDEN%' and pg_temp.hi_h(:'O', $q$select public.com_history('TODAS', '{}'::jsonb, null, 25)::text$q$) like 'ERR FORBIDDEN%', '' from (select 1) z;
-- H12 · rendimiento con volumen representativo (3.000 solicitudes de otro vendedor; se mide una página con el índice)
insert into public.com_requests select (jsonb_populate_record(null::public.com_requests, to_jsonb(t) || jsonb_build_object('id', gen_random_uuid(), 'number', 'VOL-' || lpad(g::text, 6, '0'), 'op_id', 'hi-vol-' || g,
  'requested_by', :'V3', 'created_at', timestamptz '2025-01-01 00:00:00+00' + make_interval(mins => g * 97)))).* from hi_tpl t, generate_series(1, 3000) g;
analyze public.com_requests;
create temp table hi_t as select clock_timestamp() t0, pg_temp.hi_hist(:'V3', 'MIS', '{}', null, 25) r1, clock_timestamp() t1;
insert into hi_t select clock_timestamp(), pg_temp.hi_hist(:'V3', 'MIS', '{}', (select r1->'next_cursor' from hi_t limit 1), 25), clock_timestamp();
insert into hi_checks select 'H12 RENDIMIENTO: con 3.000 solicitudes del vendedor (y ~3.300 en total) cada página de 25 responde en < 300 ms y sigue indicando que quedan resultados',
  (select bool_and(extract(milliseconds from t1 - t0) < 300 and jsonb_array_length(r1->'items') = 25 and (r1->>'has_more')::boolean) from hi_t),
  (select string_agg(round(extract(milliseconds from t1 - t0))::text || ' ms', ' · ') from hi_t) from (select 1) z;
-- H13 · detalle y trazabilidad (circuito REAL: devolución → nueva propuesta → aprobación con modificaciones)
create temp table hi_d as select id, version from public.com_requests where op_id = 'hi-op-1';
select pg_temp.hi_h(:'W', format($q$select public.com_decide(%L, %s, 'DEVOLVER', '{"amount":100000,"installments":2}'::jsonb, 'Bajar el importe')::text$q$, (select id from hi_d), (select version from hi_d)));
select pg_temp.hi_h(:'V1', format($q$select public.com_respond(%L, %s, true, 'Acepto la propuesta')::text$q$, (select id from hi_d), (select version from public.com_requests where op_id = 'hi-op-1')));
create temp table hi_dd as select pg_temp.hi_hj(pg_temp.hi_h(:'V1', format('select public.com_request_detail(%L)::text', (select id from hi_d)))) d;
insert into hi_checks select 'H13 DETALLE y TRAZABILIDAD: datos originales, condiciones propuestas y finales, devolución con motivo, cambios de estado con usuario y fecha de cada intervención; el historial no se puede editar',
  (d->'original_terms'->>'amount')::numeric = 120000 and jsonb_array_length(d->'timeline') >= 3
  and (select bool_and(e ? 'by' and e ? 'at' and e->>'at' is not null) from jsonb_array_elements(d->'timeline') e)
  and exists (select 1 from jsonb_array_elements(d->'timeline') e where e->>'reason' = 'Bajar el importe')
  and pg_temp.hi_h(:'V1', format($q$select count(*)::text from public.com_request_events where request_id = %L$q$, (select id from hi_d))) like 'ERR%',
  left((d->'timeline')::text, 260) from hi_dd;
-- ===================== O-W05 / O-W04 (000800) =====================
create temp table hi_al as select pg_temp.hi_hj(pg_temp.hi_h(:'A', 'select public.com_my_alarms_page(2)::text')) p2, pg_temp.hi_hj(pg_temp.hi_h(:'A', 'select public.com_my_alarms_page(500)::text')) pmax,
  (select count(*) from public.com_alarms where status = 'PENDIENTE_ATENCION' or attended_at > now() - interval '12 hours') vis;
insert into hi_checks select 'H14 (O-W05) mis alarmas con TOPE: página de 2 → 2 tarjetas, total de pendientes y aviso de que hay más; el tope máximo es 50',
  jsonb_array_length(p2->'items') = 2 and (p2->>'has_more')::boolean = (vis > 2) and (p2->>'total_pending')::int = (select count(*) from public.com_alarms where status = 'PENDIENTE_ATENCION')
  and (pmax->>'page_size')::int = 50, 'visibles=' || vis from hi_al;
create or replace function pg_temp.hi_al_pages(lim int) returns text[] language plpgsql as $f$ declare cur jsonb; r jsonb; ids text[] := '{}'; begin loop
  r := pg_temp.hi_hj(pg_temp.hi_h('e0000000-0000-0000-0000-00000000000a', format('select public.com_alarm_history_page(null, null, %L::jsonb, %s)::text', cur, lim)));
  ids := ids || array(select x->>'id' from jsonb_array_elements(r->'items') x); exit when not (r->>'has_more')::boolean; cur := r->'next_cursor'; end loop; return ids; end $f$;
create temp table hi_ah as select pg_temp.hi_al_pages(3) p3, (select array_agg(id::text order by raised_at desc, id desc) from public.com_alarms) todas;
insert into hi_checks select 'H15 (O-W05) historial ADMINISTRATIVO de alarmas por cursor: todas las alarmas, sin faltantes ni duplicados y en orden estable (páginas de 3); solo Administrador',
  p3 = todas and cardinality(p3) > 3 and pg_temp.hi_h(:'O', $q$select public.com_alarm_history_page(null, null, null, 25)::text$q$) like 'ERR FORBIDDEN%', cardinality(p3)::text from hi_ah;
insert into public.push_subscriptions(user_id, endpoint, p256dh, auth) values (:'W', 'https://push.example/w1', 'k', 'a'), (:'W', 'https://push.example/w2', 'k', 'a');
insert into public.push_subscriptions(user_id, endpoint, p256dh, auth, revoked_at) values (:'W', 'https://push.example/w3', 'k', 'a', now());
create temp table hi_ps as select pg_temp.hi_hj(pg_temp.hi_h(:'A', 'select public.com_alarm_push_status()::text')) st,
  pg_temp.hi_hj(pg_temp.hi_h(:'W', 'select public.com_my_push_devices()::text')) w, pg_temp.hi_hj(pg_temp.hi_h(:'C1', 'select public.com_my_push_devices()::text')) c1;
insert into hi_checks select 'H16 (O-W04) push por DESTINATARIO y DISPOSITIVO: el Panel informa los dispositivos ACTIVOS de cada destinatario (Wilfredo: 2; la revocada no cuenta); cada usuario ve solo los suyos; solo el Administrador ve el estado general',
  (select (x->>'dispositivos_activos')::int = 2 from jsonb_array_elements(st) x where x->>'rol' = 'INICIAL') and (w->>'activos')::int = 2 and (c1->>'activos')::int = 0
  and pg_temp.hi_h(:'W', 'select public.com_alarm_push_status()::text') like 'ERR FORBIDDEN%', st::text from hi_ps;

-- H17 · B-W04: con COMERCIAL restringido, com_config tampoco entrega la configuración del módulo (antes devolvía parámetros, asignación y aprobador)
select set_config('okd.sync', 'on', false); update public.profiles set disabled_modules = array['COMERCIAL'] where id = :'V1'; select set_config('okd.sync', '', false);
create temp table hi_17 as select pg_temp.hi_h(:'V1', 'select public.com_config()::text') restringido;
select set_config('okd.sync', 'on', false); update public.profiles set disabled_modules = '{}' where id = :'V1'; select set_config('okd.sync', '', false);
insert into hi_checks select 'H17 (B-W04) con el módulo COMERCIAL restringido, com_config responde FORBIDDEN (no entrega parámetros, asignación ni aprobador); al restaurarlo, vuelve a responder',
  restringido like 'ERR FORBIDDEN%' and pg_temp.hi_h(:'V1', 'select public.com_config()::text') not like 'ERR%', left(restringido, 40) from hi_17;

-- H18 · sección 5: KPI DESHABILITADO (separación segura de cifras no verificadas)
create temp table hi_18 as select pg_temp.hi_h(:'V1', $q$select public.com_set_kpi_mode('DESHABILITADO', null)::text$q$) vendedor,
  pg_temp.hi_h(:'A', $q$select public.com_set_kpi_mode('DESHABILITADO', null)::text$q$) admin;
create temp table hi_18b as select pg_temp.hi_hj(pg_temp.hi_h(:'V1', format('select public.com_kpi_for_client(%L)::text', (select id from public.com_clients where erp_id = '106')))) kpi;
select pg_temp.hi_h(:'V1', format($q$select public.com_create_request('FINANCIACION', %L, 'HP-KPI', '{"amount":90000,"installments":2}'::jsonb, null, 'hi-op-kpi')::text$q$, (select id from public.com_clients where erp_id = '106')));
create temp table hi_18c as select kpi_snapshot from public.com_requests where op_id = 'hi-op-kpi';
select pg_temp.hi_h(:'A', $q$select public.com_set_kpi_mode('PROVISORIO', 'Prueba local: autorización de Dirección General simulada')::text$q$);
insert into hi_checks select 'H18 (sección 5) KPI DESHABILITADO: solo el Administrador lo cambia (auditado); no se calcula ni se muestra ninguna cifra; la solicitud se crea igual y guarda solo la marca; al volver a PROVISORIO se calcula de nuevo',
  vendedor like 'ERR FORBIDDEN%' and admin not like 'ERR%' and (select kpi->>'status' = 'DESHABILITADO' and not (kpi ?| array['avg', 'floor', 'ceiling', 'months', 'total']) from hi_18b)
  and (select kpi_snapshot->>'status' = 'DESHABILITADO' from hi_18c) and exists (select 1 from public.audit_log where action = 'COM_KPI_MODE')
  and pg_temp.hi_hj(pg_temp.hi_h(:'V1', format('select public.com_kpi_for_client(%L)::text', (select id from public.com_clients where erp_id = '106'))))->>'status' <> 'DESHABILITADO',
  left(vendedor, 30) || ' · ' || (select left(kpi::text, 120) from hi_18b) from hi_18;
