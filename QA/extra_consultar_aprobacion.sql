-- SOLO PRUEBAS LOCALES · «CONSULTAR APROBACIÓN» (com_order_alerts) · auditoría focalizada 14/11 (B-01, B-02, T-01).
-- Solicitudes creadas por el CIRCUITO REAL (Comercial crea, aprobador decide). Toda aserción de seguridad exige el resultado de forma POSITIVA.
create temp table ca_checks(name text, ok boolean, detail text);
create or replace function pg_temp.ca(u uuid, q text) returns text language plpgsql as $f$ declare o text; begin perform tst.u(u); set local role authenticated; begin execute q into o; exception when others then o := 'ERR ' || sqlerrm; end; reset role; return o; end $f$;
create or replace function pg_temp.cajs(t text) returns jsonb language sql as $f$ select case when t like '[%' or t like '{%' then t::jsonb end $f$;
create or replace function pg_temp.new_req(u uuid, erp text, ref text, op text) returns jsonb language sql as $f$
  select pg_temp.cajs(pg_temp.ca(u, format($q$select public.com_create_request('FINANCIACION', %L, %L, '{"amount":100000,"installments":2}'::jsonb, 'nota interna', %L)::text$q$,
    (select id from public.com_clients where erp_id = erp), ref, op))) $f$;
create or replace function pg_temp.decide(id uuid, d text, terms jsonb default null) returns text language sql as $f$
  select pg_temp.ca('c0000000-0000-0000-0000-0000000000a1', format($q$select public.com_decide(%L, %s, %L, %L::jsonb, 'motivo de la decisión')::text$q$, id, (select version from public.com_requests where com_requests.id = $1), d, terms)) $f$;
create or replace function pg_temp.alerts(u uuid, orders text[], cuits text[] default '{}') returns text language sql as $f$
  select pg_temp.ca(u, format('select public.com_order_alerts(%L::text[], %L::text[])::text', orders, cuits)) $f$;
create or replace function pg_temp.nums(t text) returns text language sql as $f$ select coalesce((select string_agg(x->>'order_ref' || ':' || (x->>'status'), ',' order by x->>'order_ref', x->>'number') from jsonb_array_elements(pg_temp.cajs(t)) x), t) $f$;
\set C1 'c0000000-0000-0000-0000-0000000000c1'
\set C2 'c0000000-0000-0000-0000-0000000000c2'
\set W  'c0000000-0000-0000-0000-0000000000a1'
\set F  'c0000000-0000-0000-0000-0000000000a2'
\set A  'e0000000-0000-0000-0000-00000000000a'
\set O  'e0000000-0000-0000-0000-000000000006'
\set G  'e0000000-0000-0000-0000-000000000007'
\set AP 'c0000000-0000-0000-0000-0000000000a9'
-- APROBADOR AJENO: NO es Administrador General (Solo lectura + com.approve por usuario, como Wilfredo) y no tiene solicitudes asignadas
insert into auth.users(id, email) values (:'AP', 'aprobador.ajeno@t') on conflict do nothing;
select set_config('okd.sync', 'on', false);
insert into public.profiles(id, full_name, email, role, status) values (:'AP', 'Aprobador Ajeno', 'aprobador.ajeno@t', 'SOLO_LECTURA', 'ACTIVO') on conflict (id) do nothing;
select set_config('okd.sync', '', false);
insert into public.user_permission_overrides(user_id, permission_code, granted, set_by, reason) values (:'AP', 'com.approve', true, :'A', 'prueba: aprobador sin asignaciones') on conflict do nothing;
-- solicitudes de C1 (cliente erp 106): Q-901 pendiente · Q-902 aprobada · Q-903 devuelta · Q-904 rechazada
create temp table rq as select 'Q-901' ref, (pg_temp.new_req(:'C1', '106', 'Q-901', 'op-q901')->>'id')::uuid id
  union all select 'Q-902', (pg_temp.new_req(:'C1', '106', 'Q-902', 'op-q902')->>'id')::uuid
  union all select 'Q-903', (pg_temp.new_req(:'C1', '106', 'Q-903', 'op-q903')->>'id')::uuid
  union all select 'Q-904', (pg_temp.new_req(:'C1', '106', 'Q-904', 'op-q904')->>'id')::uuid;
select pg_temp.decide((select id from rq where ref = 'Q-902'), 'APROBAR');
select pg_temp.decide((select id from rq where ref = 'Q-903'), 'DEVOLVER', '{"amount":80000,"installments":2}');
select pg_temp.decide((select id from rq where ref = 'Q-904'), 'RECHAZAR');
create temp table a1 as select pg_temp.cajs(pg_temp.alerts(:'O', array['Q-901', 'q-902 ', 'Q-903', 'Q-904', 'Q-999'])) r;
insert into ca_checks select 'CA-01 PENDIENTE, DEVUELTA y RECHAZADA → «CONSULTAR APROBACIÓN»; DEVUELTA nunca como aprobada (sin condiciones finales); pedidos inexistentes no aparecen',
  coalesce((select count(*) from jsonb_array_elements(r) x where x->>'alert' = 'CONSULTAR APROBACIÓN') = 3
  and (select x->'final_terms' = 'null'::jsonb and x->>'status' = 'DEVUELTA' from jsonb_array_elements(r) x where x->>'order_ref' = 'Q-903') and jsonb_array_length(r) = 4, false), left(r::text, 240) from a1;
insert into ca_checks select 'CA-02 APROBADA → sin alerta, con las condiciones FINALES autorizadas; el pedido se compara sin mayúsculas ni espacios',
  coalesce((select x->'alert' = 'null'::jsonb and (x->'final_terms'->>'amount')::numeric = 100000 from jsonb_array_elements(r) x where x->>'order_ref' = 'Q-902'), false), '' from a1;
insert into ca_checks select 'CA-03 SIN DATOS INTERNOS: no devuelve KPI, notas, condiciones originales, línea de tiempo ni motivos',
  coalesce(not exists (select 1 from jsonb_array_elements(r) x where x ?| array['kpi', 'notes', 'original_terms', 'timeline', 'reason', 'kpi_snapshot']), false), '' from a1;
-- ===== B-01: misma solicitud por pedido Y por CUIT; pedidos distintos del mismo cliente =====
select pg_temp.new_req(:'C1', '106', 'Q-901', 'op-q901-b');   -- segunda solicitud del MISMO pedido (mismo instante: desempate por número)
create temp table b1 as select (select client_snapshot->>'cuit' from public.com_requests where order_ref = 'Q-901' limit 1) cuit;
insert into ca_checks select 'CA-04 (B-01) pedido + CUIT del mismo cliente: el pedido Q-901 aparece UNA sola vez (la solicitud más reciente), también al pasar el CUIT',
  pg_temp.nums(pg_temp.alerts(:'O', array['Q-901'])) = 'Q-901:PENDIENTE'
  and (select count(*) from jsonb_array_elements(pg_temp.cajs(pg_temp.alerts(:'O', array['Q-901'], array[(select cuit from b1)]))) x where x->>'order_ref' = 'Q-901') = 1
  and (select x->>'number' from jsonb_array_elements(pg_temp.cajs(pg_temp.alerts(:'O', array['Q-901'], array[(select cuit from b1)]))) x where x->>'order_ref' = 'Q-901') = (select max(number) from public.com_requests where order_ref = 'Q-901'),
  pg_temp.nums(pg_temp.alerts(:'O', array['Q-901'], array[(select cuit from b1)])) from (select 1) z;
insert into ca_checks select 'CA-05 (B-01) OTROS pedidos del mismo cliente: solo por CUIT se ven las EN CURSO de cada pedido (una por pedido; la devuelta sí, aprobada y rechazada no)',
  pg_temp.nums(pg_temp.alerts(:'O', '{}', array[(select cuit from b1)])) = 'Q-901:PENDIENTE,Q-903:DEVUELTA', pg_temp.nums(pg_temp.alerts(:'O', '{}', array[(select cuit from b1)])) from (select 1) z;
-- ===== B-02: alcance por registro (invocación DIRECTA) =====
select pg_temp.new_req(:'C2', '101', 'Q-950', 'op-q950');   -- solicitud de OTRO Comercial (cliente 101, activo; el 107 está EN REVISIÓN)
insert into ca_checks select 'CA-06 (B-02) COMERCIAL AJENO: C2 NO ve las solicitudes de C1 aunque conozca el pedido y el CUIT; solo las propias',
  pg_temp.nums(pg_temp.alerts(:'C2', array['Q-901', 'Q-902', 'Q-950'], array[(select cuit from b1)])) = 'Q-950:PENDIENTE',
  pg_temp.nums(pg_temp.alerts(:'C2', array['Q-901', 'Q-902', 'Q-950'], array[(select cuit from b1)])) from (select 1) z;
insert into ca_checks select 'CA-07 (B-02) COMERCIAL DUEÑO: C1 ve las suyas (incluida la aprobada con sus condiciones) y no la de C2',
  pg_temp.nums(pg_temp.alerts(:'C1', array['Q-901', 'Q-902', 'Q-950'])) = 'Q-901:PENDIENTE,Q-902:APROBADA', pg_temp.nums(pg_temp.alerts(:'C1', array['Q-901', 'Q-902', 'Q-950'])) from (select 1) z;
insert into ca_checks select 'CA-08 (B-02) APROBADOR AJENO (no administrador, sin asignaciones) no ve las asignadas a Wilfredo; el APROBADOR ASIGNADO (Wilfredo) sí',
  public.user_has_perm(:'AP', 'com.approve') and pg_temp.alerts(:'AP', array['Q-901', 'Q-902']) = '[]' and pg_temp.nums(pg_temp.alerts(:'W', array['Q-901', 'Q-902'])) = 'Q-901:PENDIENTE,Q-902:APROBADA',
  pg_temp.alerts(:'AP', array['Q-901', 'Q-902']) || ' · ' || pg_temp.nums(pg_temp.alerts(:'W', array['Q-901', 'Q-902'])) from (select 1) z;
insert into ca_checks select 'CA-09 DESPACHO (com.track) y ADMINISTRADOR GENERAL ven todas según la trazabilidad autorizada',
  pg_temp.nums(pg_temp.alerts(:'O', array['Q-901', 'Q-950'])) = 'Q-901:PENDIENTE,Q-950:PENDIENTE' and pg_temp.nums(pg_temp.alerts(:'A', array['Q-901', 'Q-950'])) = 'Q-901:PENDIENTE,Q-950:PENDIENTE', '' from (select 1) z;
-- ===== T-01: usuario REALMENTE sin permisos del módulo; anon; sesión revocada =====
insert into ca_checks select 'CA-10 (T-01) SIN PERMISOS del módulo (chofer interno: sin com.track/request/approve): FORBIDDEN exigido de forma positiva',
  (pg_temp.alerts(:'G', array['Q-901']) like 'ERR FORBIDDEN%') = true
  and not public.user_has_perm(:'G', 'com.track') and not public.user_has_perm(:'G', 'com.request') and not public.user_has_perm(:'G', 'com.approve'), pg_temp.alerts(:'G', array['Q-901']) from (select 1) z;
insert into ca_checks select 'CA-11 anon no ejecuta la función; más de 300 pedidos → TOO_MANY; es de solo lectura (STABLE)',
  not has_function_privilege('anon', 'public.com_order_alerts(text[],text[])', 'EXECUTE')
  and (pg_temp.ca(:'O', format('select public.com_order_alerts(%L::text[], %L)::text', (select array_agg('P' || g) from generate_series(1, 301) g), '{}')) like 'ERR TOO_MANY%') = true
  and (select provolatile from pg_proc where oid = 'public.com_order_alerts(text[],text[])'::regprocedure) = 's', '';
select set_config('okd.sync', 'on', false); update public.profiles set sessions_revoked_at = now() + interval '1 hour' where id = :'C1'; select set_config('okd.sync', '', false);
create temp table rv as select pg_temp.alerts(:'C1', array['Q-901']) alerta, pg_temp.ca(:'C1', $q$select public.com_list('MIS', null, 10, 0)::text$q$) lista;
select set_config('okd.sync', 'on', false); update public.profiles set sessions_revoked_at = null where id = :'C1'; select set_config('okd.sync', '', false);
insert into ca_checks select 'CA-12 SESIÓN REVOCADA: con un token anterior a la revocación, C1 recibe FORBIDDEN en la consulta y en el resto del módulo (com_list); al restablecer, vuelve a ver',
  (alerta like 'ERR FORBIDDEN%') = true and (lista like 'ERR FORBIDDEN%') = true and pg_temp.nums(pg_temp.alerts(:'C1', array['Q-901'])) = 'Q-901:PENDIENTE', alerta || ' · ' || left(lista, 60) from rv;
