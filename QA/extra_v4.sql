-- SOLO PRUEBAS LOCALES · V4 (auditoría Work sobre V3): B-W01 revocación integral · B-W02 idempotencia completa y alcance · O-W02 unicidad ·
-- B-W04 módulo COMERCIAL restringible · HISTORIAL por vendedor. Aserciones POSITIVAS. Datos sintéticos.
create temp table v4_checks(name text, ok boolean, detail text);
create or replace function pg_temp.v(u uuid, q text) returns text language plpgsql as $f$ declare o text; begin perform tst.u(u); set local role authenticated; begin execute q into o; exception when others then o := 'ERR ' || sqlerrm; end; reset role; return o; end $f$;
create or replace function pg_temp.vj(t text) returns jsonb language sql as $f$ select case when t like '[%' or t like '{%' then t::jsonb end $f$;
create or replace function pg_temp.sync(on_ boolean) returns void language sql as $f$ select set_config('okd.sync', case when on_ then 'on' else '' end, false) $f$;
\set A  'e0000000-0000-0000-0000-00000000000a'
\set S  'e0000000-0000-0000-0000-000000000005'
\set O  'e0000000-0000-0000-0000-000000000006'
\set C1 'c0000000-0000-0000-0000-0000000000c1'
\set C3 'c0000000-0000-0000-0000-0000000000c3'
\set C4 'c0000000-0000-0000-0000-0000000000c4'
\set W  'c0000000-0000-0000-0000-0000000000a1'

-- ======================= B-W01 · revocación integral =======================
-- llamada a CADA RPC expuesta del módulo con argumentos nulos: la guarda va PRIMERO, así que con sesión revocada debe rechazar antes de mirar argumentos
create or replace function pg_temp.all_rpcs() returns table(sig text, call text) language sql as $f$
  select p.oid::regprocedure::text, format('select public.%I(%s)::text', p.proname, coalesce((select string_agg('null::' || format_type(t, null), ', ') from unnest(p.proargtypes) t), ''))
  from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname like 'com\_%' and has_function_privilege('authenticated', p.oid, 'EXECUTE') order by 1 $f$;
create temp table v4_rpcs as select * from pg_temp.all_rpcs();
create temp table v4_rev(rol text, sig text, r text);
do $$ declare u record; f record; begin
  for u in select * from (values ('COMERCIAL', 'c0000000-0000-0000-0000-0000000000c1'::uuid), ('APROBADOR', 'c0000000-0000-0000-0000-0000000000a1'::uuid),
                                 ('DESPACHO', 'e0000000-0000-0000-0000-000000000006'::uuid), ('ADMINISTRADOR', 'e0000000-0000-0000-0000-00000000000a'::uuid)) x(rol, id) loop
    perform pg_temp.sync(true); update public.profiles set sessions_revoked_at = now() + interval '1 hour' where id = u.id; perform pg_temp.sync(false);
    for f in select * from v4_rpcs loop insert into v4_rev values (u.rol, f.sig, pg_temp.v(u.id, f.call)); end loop;
    perform pg_temp.sync(true); update public.profiles set sessions_revoked_at = null where id = u.id; perform pg_temp.sync(false);
  end loop; end $$;
insert into v4_checks select 'V4-S01 (B-W01) MATRIZ: ' || (select count(*) from v4_rpcs) || ' RPC expuestas × 4 roles (Comercial, aprobador, Despacho, Administrador) con sesión REVOCADA → FORBIDDEN en TODAS',
  (select count(*) from v4_rpcs) >= 32 and not exists (select 1 from v4_rev where r not like 'ERR FORBIDDEN%'),
  coalesce((select string_agg(rol || ':' || sig || '=' || left(r, 40), ' | ') from (select * from v4_rev where r not like 'ERR FORBIDDEN%' limit 6) z), 'todas FORBIDDEN') from (select 1) z;
-- el caso EXACTO de Work (IND-S01): búsqueda del padrón con sesión revocada (y vigente devuelve clientes)
select pg_temp.sync(true); update public.profiles set sessions_revoked_at = now() + interval '1 hour' where id = :'C1'; select pg_temp.sync(false);
create temp table v4_s02 as select pg_temp.v(:'C1', $q$select public.com_search_clients('TE', 12)::text$q$) rev;
select pg_temp.sync(true); update public.profiles set sessions_revoked_at = null where id = :'C1'; select pg_temp.sync(false);
insert into v4_checks select 'V4-S02 (B-W01 · IND-S01) com_search_clients con sesión REVOCADA → FORBIDDEN (sin clientes); con sesión vigente devuelve clientes',
  (rev like 'ERR FORBIDDEN%') = true and jsonb_array_length(pg_temp.vj(pg_temp.v(:'C1', $q$select public.com_search_clients('TE', 12)::text$q$))) > 0, left(rev, 60) from v4_s02;

-- ======================= B-W02 · idempotencia completa y alcance =======================
create or replace function pg_temp.raise_(u uuid, ord text, sheet text, op text) returns jsonb language sql as $f$
  select pg_temp.vj(pg_temp.v(u, format('select public.com_alarm_raise(%L, %L, %L, %L, %L, %L)::text', ord, sheet, 'CLIENTE', '', 'Motivo de prueba de idempotencia V4', op))) $f$;
select pg_temp.v(:'O', $q$select public.reserve_orders('V4-H1', array['28001','28002'])::text$q$);
create temp table v4_i1 as select pg_temp.raise_(:'O', '28001', 'V4-H1', 'v4-op-A') a, pg_temp.raise_(:'O', '28001', 'V4-H1', 'v4-op-B') b;
select pg_temp.v(:'W', format('select public.com_alarm_attend(%L, 1)::text', (select (a->>'id') from v4_i1)));
create temp table v4_i1b as select pg_temp.raise_(:'O', '28001', 'V4-H1', 'v4-op-B') b2;
insert into v4_checks select 'V4-I01 (B-W02 · IND-I01) op-B recibe la alarma ACTIVA de op-A; tras ATENDERLA, reintentar EXACTAMENTE op-B devuelve la MISMA respuesta y NO crea otra alarma',
  (b->>'existing')::boolean and (b->>'id') = (a->>'id') and (b2->>'id') = (a->>'id') and (b2->>'repeated')::boolean
  and (select count(*) from public.com_alarms where order_ref = '28001') = 1, left(b2::text, 120) from v4_i1, v4_i1b;
create temp table v4_i3 as select pg_temp.raise_(:'O', '28002', 'V4-H1', 'v4-op-B') r;
insert into v4_checks select 'V4-I02 (B-W02 · IND-I03) reutilizar op-B (ya vinculado por la deduplicación) para OTRO pedido → OP_ID_CONFLICT sin datos y sin alarma nueva',
  r->>'code' = 'OP_ID_CONFLICT' and not (r ?| array['id', 'number', 'status']) and not exists (select 1 from public.com_alarms where order_ref = '28002'), r::text from v4_i3;
-- alcance: el Supervisor (com.track y routes.manage_all_drafts) usa un op NUEVO para el mismo pedido mientras hay una alarma ACTIVA ajena
-- la alarma ACTIVA del pedido la pide el ADMINISTRADOR sobre la hoja del Operario; después el Operario (dueño de la hoja, ni destinatario ni administrador)
create temp table v4_i4a as select pg_temp.raise_(:'A', '28002', 'V4-H1', 'v4-op-C') a;
create temp table v4_i4 as select pg_temp.raise_(:'O', '28002', 'V4-H1', 'v4-op-S') r, pg_temp.raise_(:'O', '28002', 'V4-H1', 'v4-op-S') r2,
  pg_temp.v(:'S', format('select public.com_alarm_raise(%L,%L,%L,%L,%L,%L)::text', '28002', 'V4-H1', 'x', '', 'Motivo de prueba de idempotencia V4', 'v4-op-S9')) sup;
insert into v4_checks select 'V4-I03 (B-W02 · IND-S02) el dueño de la hoja, fuera del alcance de la alarma ACTIVA ajena (pedida por el Administrador), recibe una respuesta MÍNIMA (existing, sin id ni número) y su op queda vinculado; el Supervisor que NO puede operar esa hoja recibe ORDER_NOT_IN_SHEET (sin datos)',
  (r->>'existing')::boolean and not (r ?| array['id', 'number']) and r->>'status' = 'PENDIENTE_ATENCION' and (r2->>'repeated')::boolean and not (r2 ?| array['id', 'number'])
  and exists (select 1 from public.com_alarm_ops where op_id = 'v4-op-S' and user_id = :'O') and (sup like 'ERR ORDER_NOT_IN_SHEET%') = true,
  coalesce(r::text, 'NULL') || ' | Supervisor sin la hoja: ' || left(sup, 60) from v4_i4;
-- el que pide debe poder OPERAR la hoja: un Comercial (com.track no) ya se rechaza por permiso; un usuario con com.track SIN la hoja → ORDER_NOT_IN_SHEET (igual que hoja inexistente)
select pg_temp.v(:'A', $q$select public.reserve_orders('V4-AJENA', array['28003'])::text$q$);
insert into v4_checks select 'V4-I04 (B-W02) el Operario NO puede pedir alarma sobre una hoja AJENA (dueño Administrador): misma respuesta que una hoja inexistente (no revela existencia)',
  pg_temp.v(:'O', format('select public.com_alarm_raise(%L,%L,%L,%L,%L,%L)::text', '28003', 'V4-AJENA', 'x', '', 'Motivo suficiente de prueba', 'v4-op-D')) like 'ERR ORDER_NOT_IN_SHEET%'
  and pg_temp.v(:'O', format('select public.com_alarm_raise(%L,%L,%L,%L,%L,%L)::text', '28003', 'NO-EXISTE', 'x', '', 'Motivo suficiente de prueba', 'v4-op-E')) like 'ERR ORDER_NOT_IN_SHEET%', '' from (select 1) z;
-- O-W02: el respaldo de unicidad identifica la restricción y queda AUDITADO (se fuerza una colisión real de com_alarms.op_id sin registro de operación)
insert into public.com_alarms(order_ref, sheet_key, client_source, reason, raised_by, initial_user, escalate_at, op_id, status)
  values ('FB-0', 'V4-H1', 'DECLARADO_POR_DESPACHO', 'colisión forzada para la prueba', :'O', :'W', now() + interval '1 hour', 'v4-op-FB', 'ATENDIDA');
select pg_temp.v(:'O', $q$select public.reserve_orders('V4-H1', array['28004'])::text$q$);
create temp table v4_fb as select pg_temp.raise_(:'O', '28004', 'V4-H1', 'v4-op-FB') r;
insert into v4_checks select 'V4-I05 (O-W02) colisión REAL de unicidad: se identifica la restricción (com_alarms_op_id_key), se AUDITA (COM_ALARM_UNIQUE_FALLBACK) y se responde sin datos',
  r->>'code' = 'OP_ID_CONFLICT' and not (r ? 'id') and exists (select 1 from public.audit_log where action = 'COM_ALARM_UNIQUE_FALLBACK' and after->>'restriccion' = 'com_alarms_op_id_key'),
  r::text from v4_fb;
insert into v4_checks select 'V4-I06 (B-W02) el identificador de operación es OBLIGATORIO (sin él no hay idempotencia) y el registro de operaciones es INMUTABLE',
  pg_temp.v(:'O', format('select public.com_alarm_raise(%L,%L,%L,%L,%L,%L)::text', '28004', 'V4-H1', 'x', '', 'Motivo suficiente de prueba', null)) like 'ERR BAD_OP%'
  and pg_temp.v(:'O', $q$select count(*)::text from public.com_alarm_ops$q$) like 'ERR%', '' from (select 1) z;
do $$ begin begin update public.com_alarm_ops set result = '{}' where op_id = 'v4-op-A'; insert into v4_checks values ('V4-I07 registro de operaciones inmutable (superusuario)', false, 'se pudo modificar');
  exception when others then insert into v4_checks values ('V4-I07 registro de operaciones INMUTABLE: tampoco el dueño de la tabla puede modificarlo (disparador)', sqlerrm like 'IMMUTABLE%', sqlerrm); end; end $$;

-- ======================= B-W04 · módulo COMERCIAL restringible =======================
create temp table v4_m as select pg_get_constraintdef(oid) def from pg_constraint where conname = 'profiles_disabled_modules_valid';
select pg_temp.sync(true); update public.profiles set disabled_modules = array['COMERCIAL'] where id = :'C1'; select pg_temp.sync(false);
create temp table v4_m1 as select pg_temp.v(:'C1', $q$select public.com_list('MIS', null, 10, 0)::text$q$) lista, pg_temp.v(:'C1', $q$select public.com_search_clients('TE', 5)::text$q$) busca,
  pg_temp.v(:'C1', $q$select public.com_history('MIS', '{}'::jsonb, null, 10)::text$q$) hist;
select pg_temp.sync(true); update public.profiles set disabled_modules = '{}' where id = :'C1'; select pg_temp.sync(false);
insert into v4_checks select 'V4-M01 (B-W04 · IND-M01) restringir COMERCIAL a un usuario se ACEPTA (antes: SQLSTATE 23514) y vale en el SERVIDOR: listado, padrón e historial → FORBIDDEN; al restaurar, vuelve a funcionar',
  (lista like 'ERR FORBIDDEN%') = true and (busca like 'ERR FORBIDDEN%') = true and (hist like 'ERR FORBIDDEN%') = true
  and pg_temp.v(:'C1', $q$select public.com_list('MIS', null, 10, 0)::text$q$) not like 'ERR%', left(lista, 40) || ' | ' || left(busca, 40) || ' | ' || left(hist, 40) from v4_m1;
insert into v4_checks select 'V4-M02 (B-W04) la restricción CONSERVA los módulos anteriores (los 7 vigentes siguen restringibles) y mapea los 4 permisos del módulo (= rules.js)',
  def ~ 'DESPACHO' and def ~ 'MIS_HOJAS' and def ~ 'USUARIOS' and def ~ 'INFORMES' and def ~ 'APROBACIONES' and def ~ 'CONFIGURACION' and def ~ 'AUDITORIA' and def ~ 'COMERCIAL'
  and (select count(*) from public.module_permissions where module = 'COMERCIAL' and permission_code in ('com.request', 'com.approve', 'com.track', 'com.sources.upload')) = 4, def from v4_m;
select pg_temp.sync(true); update public.profiles set disabled_modules = array['INFORMES'] where id = :'C1'; update public.profiles set disabled_modules = '{}' where id = :'C1'; select pg_temp.sync(false);
insert into v4_checks values ('V4-M03 (B-W04) las restricciones de OTROS módulos siguen funcionando igual (INFORMES aceptado y restaurado)', true, '');

-- ======================= HISTORIAL COMPLETO POR VENDEDOR =======================
create or replace function pg_temp.mk(u uuid, erp text, ref text, op text) returns uuid language sql as $f$
  select (pg_temp.vj(pg_temp.v(u, format($q$select public.com_create_request('FINANCIACION', %L, %L, '{"amount":150000,"installments":2}'::jsonb, 'nota', %L)::text$q$,
    (select id from public.com_clients where erp_id = erp), ref, op)))->>'id')::uuid $f$;
create or replace function pg_temp.hist(u uuid, scope text, f jsonb, cur jsonb, lim int) returns jsonb language sql as $f$
  select pg_temp.vj(pg_temp.v(u, format('select public.com_history(%L, %L::jsonb, %L::jsonb, %s)::text', scope, f, cur, lim))) $f$;
-- todas las páginas siguiendo el cursor
create or replace function pg_temp.all_pages(u uuid, scope text, f jsonb, lim int) returns table(ids uuid[], pages int) language plpgsql as $f$
declare cur jsonb := null; r jsonb; acc uuid[] := '{}'; n int := 0;
begin loop r := pg_temp.hist(u, scope, f, cur, lim); n := n + 1;
  acc := acc || coalesce((select array_agg((x->>'id')::uuid order by o) from jsonb_array_elements(r->'items') with ordinality t(x, o)), '{}');
  exit when not (r->>'has_more')::boolean or n > 200; cur := r->'next_cursor'; end loop; ids := acc; pages := n; return next; end $f$;
insert into v4_checks select 'H-01 vendedor con CERO solicitudes: lista vacía, sin más resultados', (pg_temp.hist(:'C4', 'MIS', '{}', null, 25)->'items') = '[]' and not (pg_temp.hist(:'C4', 'MIS', '{}', null, 25)->>'has_more')::boolean,
  left(pg_temp.hist(:'C4', 'MIS', '{}', null, 25)::text, 80) from (select 1) z;
create temp table v4_b0 as select count(*)::int b0 from public.com_requests where requested_by = :'C3';   -- solicitudes PREVIAS de C3 (de otras pruebas)
select pg_temp.mk(:'C3', '106', 'H-ONE', 'h-one-1');
create temp table v4_c3_1 as select pg_temp.hist(:'C3', 'MIS', '{}', null, 25) r;
insert into v4_checks select 'H-02 vendedor con UNA solicitud: una fila con número, cliente, pedido, tipo, importe, fecha, estado, aprobador y última modificación',
  jsonb_array_length(r->'items') = (select b0 from v4_b0) + 1 and (r->'items'->0->>'order_ref') = 'H-ONE' and (r->'items'->0) ?& array['number', 'client', 'order_ref', 'kind', 'amount', 'created_at', 'status', 'assigned_approver', 'updated_at'], left(r::text, 200) from v4_c3_1;
-- volumen: 129 solicitudes más de C3 (total 130), estados mezclados
do $$ declare k int; begin for k in 1..129 loop perform pg_temp.mk('c0000000-0000-0000-0000-0000000000c3', case when k % 2 = 0 then '101' else '106' end, 'H-' || lpad(k::text, 4, '0'), 'h-op-' || k); end loop; end $$;
do $$ declare q record; k int := 0; begin for q in select id, version from public.com_requests where requested_by = 'c0000000-0000-0000-0000-0000000000c3' and order_ref like 'H-0%' order by order_ref loop k := k + 1;
  if k % 5 = 0 then perform pg_temp.v('e0000000-0000-0000-0000-00000000000a', format($q$select public.com_decide(%L, %s, 'APROBAR', null, 'ok aprobada')::text$q$, q.id, q.version));
  elsif k % 5 = 1 then perform pg_temp.v('e0000000-0000-0000-0000-00000000000a', format($q$select public.com_decide(%L, %s, 'RECHAZAR', null, 'no corresponde por riesgo')::text$q$, q.id, q.version));
  elsif k % 5 = 2 then perform pg_temp.v('e0000000-0000-0000-0000-00000000000a', format($q$select public.com_decide(%L, %s, 'DEVOLVER', '{"amount":100000,"installments":2}'::jsonb, 'bajar importe')::text$q$, q.id, q.version)); end if; end loop; end $$;
do $$ declare q record; begin for q in select id, version from public.com_requests where requested_by = 'c0000000-0000-0000-0000-0000000000c3' and status = 'DEVUELTA' limit 5 loop
  perform pg_temp.v('c0000000-0000-0000-0000-0000000000c3', format($q$select public.com_respond(%L, %s, false, 'se retira')::text$q$, q.id, q.version)); end loop; end $$;
-- en el ejecutor todo el archivo es UNA transacción (now() igual): se dan fechas sucesivas a lo existente, como si cada solicitud fuera de su propia transacción
update public.com_requests r set created_at = now() - make_interval(secs => x.k) from (select id, row_number() over (order by order_ref, id) k from public.com_requests where requested_by = 'c0000000-0000-0000-0000-0000000000c3') x where r.id = x.id;
create temp table v4_pg as select * from pg_temp.all_pages(:'C3', 'MIS', '{}', 25);
insert into v4_checks select 'H-03/04 vendedor con MÁS DE 30 y MÁS DE 100 (130 nuevas + previas) solicitudes: la paginación por cursor recorre TODAS, sin faltantes ni duplicados, en orden estable',
  cardinality(ids) = (select b0 from v4_b0) + 130 and (select count(distinct x) from unnest(ids) x) = cardinality(ids) and (select count(*) from public.com_requests where requested_by = :'C3') = cardinality(ids) and cardinality(ids) > 100,
  cardinality(ids) || ' ids en ' || pages || ' páginas' from v4_pg;
insert into v4_checks select 'H-05 el historial conserva APROBADAS, RECHAZADAS, DEVUELTAS, CANCELADAS (retiradas) y PENDIENTES',
  (select count(distinct status) from public.com_requests where requested_by = :'C3' and status in ('APROBADA', 'RECHAZADA', 'DEVUELTA', 'CANCELADA', 'PENDIENTE')) = 5
  and (select count(distinct x->>'status') from jsonb_array_elements(pg_temp.hist(:'C3', 'MIS', '{}', null, 100)->'items') x) >= 4, '' from (select 1) z;
create temp table v4_f as select * from pg_temp.all_pages(:'C3', 'MIS', jsonb_build_object('status', jsonb_build_array('APROBADA'), 'kind', 'FINANCIACION', 'from', current_date - 1, 'to', current_date, 'order_ref', 'H-00'), 10);
insert into v4_checks select 'H-06 FILTROS COMBINADOS (estado + tipo + fechas + pedido): exactamente las que cumplen todo, también paginando',
  cardinality(ids) = (select count(*) from public.com_requests where requested_by = :'C3' and status = 'APROBADA' and kind = 'FINANCIACION' and order_ref like '%H-00%')
  and cardinality(ids) > 0 and jsonb_array_length(pg_temp.hist(:'C3', 'MIS', jsonb_build_object('number', (select number from public.com_requests where order_ref = 'H-ONE')), null, 25)->'items') = 1
  and jsonb_array_length(pg_temp.hist(:'C3', 'MIS', jsonb_build_object('q', 'GOMEZ'), null, 100)->'items') > 0, cardinality(ids)::text from v4_f;
-- nuevas solicitudes MIENTRAS se consulta: no desplazan páginas
create temp table v4_p1 as select pg_temp.hist(:'C3', 'MIS', '{}', null, 25) r;
select pg_temp.mk(:'C3', '106', 'H-NEW-1', 'h-new-1'); select pg_temp.mk(:'C3', '101', 'H-NEW-2', 'h-new-2');
create temp table v4_rest as select (select array_agg((x->>'id')::uuid) from jsonb_array_elements(r->'items') x) p1, r->'next_cursor' cur from v4_p1;
create or replace function pg_temp.rest(u uuid, cur jsonb) returns uuid[] language plpgsql as $f$
declare r jsonb; acc uuid[] := '{}'; begin loop r := pg_temp.hist(u, 'MIS', '{}', cur, 25);
  acc := acc || coalesce((select array_agg((x->>'id')::uuid) from jsonb_array_elements(r->'items') x), '{}'); exit when not (r->>'has_more')::boolean; cur := r->'next_cursor'; end loop; return acc; end $f$;
insert into v4_checks select 'H-07 NUEVAS solicitudes durante la consulta: continuar con el cursor completa TODAS las originales SIN duplicados ni omisiones; las nuevas aparecen al recargar',
  cardinality(p1 || pg_temp.rest(:'C3', cur)) = (select b0 from v4_b0) + 130 and (select count(distinct x) from unnest(p1 || pg_temp.rest(:'C3', cur)) x) = (select b0 from v4_b0) + 130
  and not ((select id from public.com_requests where order_ref = 'H-NEW-1') = any(p1 || pg_temp.rest(:'C3', cur)))
  and (select array_agg(x->>'order_ref' order by x->>'order_ref') from jsonb_array_elements(pg_temp.hist(:'C3', 'MIS', '{}', null, 2)->'items') x) = array['H-NEW-1', 'H-NEW-2'],
  'p1=' || cardinality(p1) || ' resto=' || cardinality(pg_temp.rest(:'C3', cur)) || ' distintos=' || (select count(distinct x) from unnest(p1 || pg_temp.rest(:'C3', cur)) x)
  || ' b0=' || (select b0 from v4_b0) || ' primera=' || coalesce(pg_temp.hist(:'C3', 'MIS', '{}', null, 1)->'items'->0->>'order_ref', '?')
  || ' nueva_en_resto=' || ((select id from public.com_requests where order_ref = 'H-NEW-1') = any(p1 || pg_temp.rest(:'C3', cur)))::text from v4_rest;
-- privacidad
create temp table v4_x as select (select id from public.com_requests where order_ref = 'H-ONE') ajena;
insert into v4_checks select 'H-10/11 OTRO VENDEDOR: C1 no ve las solicitudes de C3 en su historial, ni por filtros; el detalle directo de una ajena y de una INEXISTENTE responden IGUAL (FORBIDDEN)',
  not exists (select 1 from jsonb_array_elements(pg_temp.hist(:'C1', 'MIS', jsonb_build_object('order_ref', 'H-'), null, 100)->'items') x)
  and pg_temp.v(:'C1', format('select public.com_request_detail(%L)::text', ajena)) like 'ERR FORBIDDEN%'
  and pg_temp.v(:'C1', format('select public.com_request_detail(%L)::text', gen_random_uuid())) like 'ERR FORBIDDEN%'
  and pg_temp.v(:'C1', $q$select public.com_history('TODAS', '{}'::jsonb, null, 10)::text$q$) like 'ERR FORBIDDEN%'
  and pg_temp.v(:'C1', $q$select public.com_history('MIS', '{}'::jsonb, '{"c":"x","i":"y"}'::jsonb, 10)::text$q$) like 'ERR BAD_CURSOR%', '' from v4_x;
insert into v4_checks select 'H-04b DETALLE propio con trazabilidad: datos originales, condiciones, decisiones, motivos, responsables y fechas',
  (select (d ?& array['original_terms', 'current_terms', 'final_terms', 'timeline', 'requested_by', 'assigned_approver']) and jsonb_array_length(d->'timeline') >= 2
     and exists (select 1 from jsonb_array_elements(d->'timeline') e where e ? 'by' and e ? 'at')
   from (select pg_temp.vj(pg_temp.v(:'C3', format('select public.com_request_detail(%L)::text', (select id from public.com_requests where requested_by = :'C3' and status = 'RECHAZADA' limit 1)))) d) z), '' from (select 1) z;
select pg_temp.sync(true); update public.profiles set role = 'SOLO_LECTURA' where id = :'C3'; select pg_temp.sync(false);
create temp table v4_rc as select pg_temp.v(:'C3', $q$select public.com_history('MIS', '{}'::jsonb, null, 10)::text$q$) r;
select pg_temp.sync(true); update public.profiles set role = 'COMERCIAL' where id = :'C3'; update public.profiles set status = 'DESHABILITADO' where id = :'C3'; select pg_temp.sync(false);
insert into v4_checks select 'H-12/13 CAMBIO DE ROL (sin com.request) y DESHABILITACIÓN → FORBIDDEN (la revocación de sesión está en V4-S01)',
  (r like 'ERR FORBIDDEN%') = true and (pg_temp.v(:'C3', $q$select public.com_history('MIS', '{}'::jsonb, null, 10)::text$q$) like 'ERR FORBIDDEN%') = true, left(r, 40) from v4_rc;
select pg_temp.sync(true); update public.profiles set status = 'ACTIVO' where id = :'C3'; select pg_temp.sync(false);
insert into v4_checks select 'H-14 APROBADOR: BANDEJA solo con las ASIGNADAS (Wilfredo no ve las de cartera de C3); ADMINISTRADOR: TODAS',
  not exists (select 1 from jsonb_array_elements(pg_temp.hist(:'W', 'BANDEJA', jsonb_build_object('order_ref', 'H-'), null, 100)->'items') x
              where (select assigned_approver_id from public.com_requests where id = (x->>'id')::uuid) <> :'W')
  and (select cardinality(ids) from pg_temp.all_pages(:'A', 'TODAS', jsonb_build_object('order_ref', 'H-'), 50)) >= 130, '' from (select 1) z;
-- rendimiento: 5000 solicitudes adicionales de otro vendedor (copias sintéticas) + páginas profundas
insert into public.com_requests
  select (jsonb_populate_record(r, jsonb_build_object('id', gen_random_uuid(), 'number', 'AUT-P' || lpad(g::text, 6, '0'), 'order_ref', 'P-' || g, 'op_id', 'perf-op-' || g,
    'requested_by', 'c0000000-0000-0000-0000-0000000000c1', 'created_at', now() - make_interval(mins => g), 'updated_at', now() - make_interval(mins => g), 'version', 1))).*
  from public.com_requests r, generate_series(1, 5000) g where r.order_ref = 'H-ONE';
create temp table v4_perf as select clock_timestamp() t0;
select pg_temp.all_pages(:'C1', 'MIS', '{}', 100);
create temp table v4_perf2 as select extract(epoch from clock_timestamp() - (select t0 from v4_perf)) * 1000 ms;
insert into v4_checks select 'H-15 RENDIMIENTO: vendedor con más de 5000 solicitudes: recorrer TODO el historial en páginas de 100 (más de 50 consultas) en menos de 10 s en total',
  ms < 10000 and (select cardinality(ids) from pg_temp.all_pages(:'C1', 'MIS', '{}', 100)) >= 5000, round(ms)::text || ' ms' from v4_perf2;
