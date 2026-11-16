-- Pruebas del MÓDULO AUTORIZACIONES COMERCIALES (propuesta). Corre después de g2_revision_test. Datos FICTICIOS; sin envíos.
\set ON_ERROR_STOP on
\set A  'e0000000-0000-0000-0000-00000000000a'
\set S  'e0000000-0000-0000-0000-000000000005'
\set O  'e0000000-0000-0000-0000-000000000006'
\set G  'e0000000-0000-0000-0000-000000000007'
\set C1 'c0000000-0000-0000-0000-0000000000c1'
\set C2 'c0000000-0000-0000-0000-0000000000c2'
\set C3 'c0000000-0000-0000-0000-0000000000c3'
\set C4 'c0000000-0000-0000-0000-0000000000c4'
\set W  'c0000000-0000-0000-0000-0000000000a1'
\set F  'c0000000-0000-0000-0000-0000000000a2'
\set GB 'c0000000-0000-0000-0000-0000000000a3'
create or replace function pg_temp.err(q text) returns text language plpgsql as $f$ begin execute q; return 'OK'; exception when others then return sqlerrm; end $f$;
create or replace function pg_temp.get(u text, q text) returns text language plpgsql as $f$ declare o text; begin perform tst.u(u::uuid); set local role authenticated; execute q into o; reset role; return o; exception when others then reset role; return 'ERR ' || sqlerrm; end $f$;
create or replace function pg_temp.as(u text, q text) returns text language plpgsql as $f$ declare o text; begin perform tst.u(u::uuid); set local role authenticated; o := pg_temp.err(q); reset role; return o; end $f$;
insert into auth.users(id, email) values (:'C1','com.mc@t'),(:'C2','com.sj@t'),(:'C3','com.cart@t'),(:'C4','com.sa@t'),(:'W','wguzman@t'),(:'F','fgutierrez@t'),(:'GB','gbrandani@t') on conflict do nothing;
select set_config('okd.sync', 'on', false);
insert into public.profiles(id, full_name, email, role, status) values
  (:'C1', 'Comercial Montecaseros', 'com.mc@t', 'COMERCIAL', 'ACTIVO'), (:'C2', 'Comercial San Juan', 'com.sj@t', 'COMERCIAL', 'ACTIVO'), (:'C3', 'Hernán Cartera', 'com.cart@t', 'COMERCIAL', 'ACTIVO'),
  (:'C4', 'Comercial Sin Asignar', 'com.sa@t', 'COMERCIAL', 'ACTIVO'), (:'W', 'Wilfredo Guzmán', 'wguzman@t', 'SOLO_LECTURA', 'ACTIVO'),
  (:'F', 'Franco Gutiérrez', 'fgutierrez@t', 'ADMIN', 'ACTIVO'), (:'GB', 'Gabriela Brandani', 'gbrandani@t', 'ADMIN', 'ACTIVO') on conflict (id) do nothing;
insert into public.user_permission_overrides(user_id, permission_code, granted, set_by, reason) values (:'W', 'com.approve', true, :'A', 'Gerencia: aprueba sucursales') on conflict do nothing;
select set_config('okd.sync', '', false);
-- ======================= PADRÓN =======================
create temp table rows0 as select '[
 {"_row":2,"erp_id":"101","razon_social":"TECNOLOGIA DEL NORTE S.A.","nombre":"Tecno Norte","doc_type":"CUIT","doc_number":"30-50001091-2","email":"compras@tecno.qa"},
 {"_row":3,"erp_id":"102","razon_social":"TECNOCASA SRL","doc_type":"CUIT","doc_number":"30707865888"},
 {"_row":4,"erp_id":"103","razon_social":"Caribe S A","doc_type":"CUIT","doc_number":"30707865888"},
 {"_row":5,"erp_id":"104","razon_social":"PEREZ JUAN","doc_type":"DNI","doc_number":"30.111.222"},
 {"_row":6,"erp_id":"105","razon_social":"CONSUMIDOR FINAL - MONTECASEROS","doc_type":"DNI","doc_number":"99999999"},
 {"_row":7,"erp_id":"106","razon_social":"GOMEZ ANA","doc_type":"CUIL","doc_number":"27-28777666-4"},
 {"_row":8,"erp_id":"107","razon_social":"MAL CUIT SA","doc_type":"CUIT","doc_number":"30500010913"},
 {"_row":9,"erp_id":"","razon_social":"SIN ID SA","doc_type":"CUIT","doc_number":"30500010912"}]'::jsonb j; grant select on rows0 to public;
create temp table cv as select n from (select '2728777666' || d::text n from generate_series(0, 9) d) x where public._cuit_valid(n) limit 1; grant select on cv to public;
update rows0 set j = jsonb_set(j, '{5,doc_number}', to_jsonb((select n from cv)));
create temp table i1 as select pg_temp.get(:'A', format('select public.com_import_clients(%L, %L, %L::jsonb)::text', 'listado_clientes.xlsx', 'sha-1', (select j from rows0)))::jsonb r,
  pg_temp.get(:'S', format('select public.com_import_clients(%L, %L, %L::jsonb)::text', 'x.xlsx', 'sha-x', (select j from rows0))) sup; grant select on i1 to public;
select tst.res('CM-01 PADRÓN: importa TODOS (con o sin correo) con identificador estable; CUIT/CUIL válidos vinculados; DNI SIN CUIT inventado; CUIT duplicado, DNI genérico y CUIT inválido EN REVISIÓN; sin ID se rechaza; solo el Administrador General',
  (select (r->>'nuevos')::int = 7 and (r->>'rechazados')::int = 1 from i1) and (select sup like 'ERR FORBIDDEN%' from i1)
  and (select cuit from public.com_clients where erp_id = '101') = '30500010912' and (select cuit is null and doc_number = '30111222' and status = 'ACTIVO' from public.com_clients where erp_id = '104')
  and (select status from public.com_clients where erp_id = '102') = 'REVISION' and (select status from public.com_clients where erp_id = '103') = 'REVISION'
  and (select 'CUIT DUPLICADO EN EL PADRÓN' = any(review_reasons) from public.com_clients where erp_id = '102') and (select status from public.com_clients where erp_id = '105') = 'REVISION'
  and (select status from public.com_clients where erp_id = '107') = 'REVISION' and (select cuit is null from public.com_clients where erp_id = '107') and (select status from public.com_clients where erp_id = '106') = 'ACTIVO',
  (select r::text from i1));
update rows0 set j = jsonb_set(j, '{0,razon_social}', '"TECNOLOGIA DEL NORTE SOCIEDAD ANONIMA"') || '[{"_row":10,"erp_id":"108","razon_social":"NUEVO CLIENTE SRL","doc_type":"CUIT","doc_number":"30717780406"}]'::jsonb;
create temp table i2 as select pg_temp.get(:'A', format('select public.com_import_clients(%L, %L, %L::jsonb)::text', 'listado_clientes (14).xlsx', 'sha-2', (select j from rows0)))::jsonb r; grant select on i2 to public;
select tst.res('CM-02 REIMPORTACIÓN: el MISMO cliente (por ID) se actualiza con historial; sin duplicados; los iguales quedan sin cambios; el nuevo se agrega',
  (select (r->>'nuevos')::int = 1 and (r->>'actualizados')::int = 1 and (r->>'sin_cambios')::int = 6 from i2) and (select count(*) from public.com_clients where erp_id = '101') = 1
  and exists (select 1 from public.com_client_changes h join public.com_clients c on c.id = h.client_id where c.erp_id = '101' and h.before->>'razon_social' = 'TECNOLOGIA DEL NORTE S.A.'), (select r::text from i2));
create temp table sr as select pg_temp.get(:'C1', 'select public.com_search_clients(''TECNO'')::text')::jsonb a, pg_temp.get(:'C1', 'select public.com_search_clients(''30500010'')::text')::jsonb b,
  pg_temp.get(:'C1', 'select public.com_search_clients(''30111'')::text')::jsonb c, pg_temp.get(:'G', 'select public.com_search_clients(''TECNO'')::text') g; grant select on sr to public;
select tst.res('CM-03 BÚSQUEDA en el servidor: «TECNO» trae coincidencias (el ambiguo marcado NO seleccionable); por CUIT y por DNI; sin permiso (transportista) se rechaza',
  (select jsonb_array_length(a) = 2 and b->0->>'erp_id' = '101' and c->0->>'erp_id' = '104' and g like 'ERR FORBIDDEN%' from sr)
  and (select bool_and(case when x->>'erp_id' = '102' then (x->>'selectable')::boolean = false else true end) from sr, jsonb_array_elements(a) x), (select a::text from sr));
-- ======================= CONFIGURACIÓN =======================
create temp table cf as select pg_temp.as(:'A', format($q$ select public.com_set_routing('SUCURSAL:MONTECASEROS', %L) $q$, :'W')) a, pg_temp.as(:'A', format($q$ select public.com_set_routing('SUCURSAL:SAN_JUAN', %L) $q$, :'W')) b,
  pg_temp.as(:'A', format($q$ select public.com_set_routing('CARTERA', %L) $q$, :'F')) c, pg_temp.as(:'A', format($q$ select public.com_set_routing('CARTERA', %L) $q$, :'G')) sin_perm,
  pg_temp.as(:'S', format($q$ select public.com_set_routing('CARTERA', %L) $q$, :'F')) sup,
  pg_temp.as(:'A', format($q$ select public.com_set_assignment(%L, 'SUCURSAL', 'MONTECASEROS', null) $q$, :'C1')) a1, pg_temp.as(:'A', format($q$ select public.com_set_assignment(%L, 'SUCURSAL', 'SAN_JUAN', null) $q$, :'C2')) a2,
  pg_temp.as(:'A', format($q$ select public.com_set_assignment(%L, 'CARTERA', null, 'Hernán') $q$, :'C3')) a3, pg_temp.as(:'A', format($q$ select public.com_set_assignment(%L, 'CARTERA', null, 'x') $q$, :'G')) no_com;
grant select on cf to public;
select tst.res('CM-04 ASIGNACIONES (Panel General): Montecaseros y San Juan → Wilfredo, cartera → Franco (por ID); aprobador sin permiso rechazado; solo el Administrador General; solo usuarios Comerciales',
  (select a = 'OK' and b = 'OK' and c = 'OK' and sin_perm like 'BAD_APPROVER%' and sup like 'FORBIDDEN%' and a1 = 'OK' and a2 = 'OK' and a3 = 'OK' and no_com like 'NOT_COMERCIAL%' from cf), (select sin_perm || ' · ' || no_com from cf));
-- ======================= SOLICITUDES =======================
create or replace function pg_temp.cid(e text) returns uuid language sql as $f$ select id from public.com_clients where erp_id = $1 $f$;
create temp table r1 as select pg_temp.get(:'C1', format($q$ select public.com_create_request('FINANCIACION', %L, '26764', '{"amount":2750000,"installments":4}'::jsonb, 'Cliente de años', 'op-r1')::text $q$, pg_temp.cid('101')))::jsonb r; grant select on r1 to public;
create temp table r1x as select pg_temp.get(:'C1', format($q$ select public.com_create_request('FINANCIACION', %L, '26764', '{"amount":2750000,"installments":4}'::jsonb, null, 'op-r1')::text $q$, pg_temp.cid('101')))::jsonb r,
  pg_temp.as(:'C1', format($q$ select public.com_create_request('FINANCIACION', %L, 'x', '{"amount":1000,"installments":5}'::jsonb, null, null) $q$, pg_temp.cid('101'))) cinco,
  pg_temp.as(:'C1', format($q$ select public.com_create_request('FINANCIACION', %L, 'x', '{"amount":1000,"installments":2}'::jsonb, null, null) $q$, pg_temp.cid('102'))) revision,
  pg_temp.as(:'C4', format($q$ select public.com_create_request('FINANCIACION', %L, 'x', '{"amount":1000,"installments":2}'::jsonb, null, null) $q$, pg_temp.cid('101'))) sin_asig,
  pg_temp.as(:'S', format($q$ select public.com_create_request('FINANCIACION', %L, 'x', '{"amount":1000,"installments":2}'::jsonb, null, null) $q$, pg_temp.cid('101'))) no_com; grant select on r1x to public;
create temp table q1 as select * from public.com_requests where id = (select (r->>'id')::uuid from r1); grant select on q1 to public;
select tst.res('CM-05 FINANCIACIÓN: Comercial de Montecaseros → asignada a Wilfredo; 4 cuotas SEMANALES (último vencimiento a 28 días); 5 cuotas (35 días) rechazadas; cliente en revisión no se usa; sin asignación o sin rol Comercial no se crea; reintento con el mismo op_id no duplica',
  (select assigned_approver_id from q1) = :'W' and (select jsonb_array_length(current_terms->'schedule') = 4 and (current_terms->>'days')::int = 28 and client_snapshot->>'cuit' = '30500010912' from q1)
  and (select (r->>'repeated')::boolean and r->>'id' = (select r->>'id' from r1) from r1x) and (select cinco like 'BAD_INSTALLMENTS%' and revision like 'CLIENT_IN_REVIEW%' and sin_asig like 'NO_ASSIGNMENT%' and no_com like 'FORBIDDEN%' from r1x)
  and (select string_agg(kind, '>' order by seq) from public.com_request_events where request_id = (select id from q1)) = 'ENVIADA>PENDIENTE'
  and exists (select 1 from public.com_notifications where user_id = :'W' and request_id = (select id from q1)) and exists (select 1 from public.com_email_jobs where request_id = (select id from q1) and status = 'PREPARADO')
  and (select kpi_snapshot->>'status' from q1) = 'PENDIENTE_IMPORTACION', (select cinco || ' · ' || revision from r1x));
create temp table e1 as select pg_temp.get(:'C2', format($q$ select public.com_create_request('ECHEQ', %L, 'P-55', jsonb_build_object('amount', 900000, 'due_date', (current_date + 20)), null, 'op-e1')::text $q$, pg_temp.cid('101')))::jsonb ok,
  pg_temp.as(:'C2', format($q$ select public.com_create_request('ECHEQ', %L, 'P-56', jsonb_build_object('amount', 900000, 'due_date', (current_date + 45)), null, null) $q$, pg_temp.cid('101'))) lejos,
  pg_temp.as(:'C2', format($q$ select public.com_create_request('ECHEQ', %L, 'P-57', jsonb_build_object('amount', 900000, 'due_date', (current_date + 10), 'issuer_name', 'Otro SA', 'issuer_cuit', '30500010913'), null, null) $q$, pg_temp.cid('101'))) mal_cuit;
grant select on e1 to public;
select tst.res('CM-06 E-CHEQ: emisor VACÍO = el mismo cliente (con su CUIT del padrón, sin inventar); vencimiento > 30 días o CUIT de emisor inválido se rechazan; San Juan → Wilfredo',
  (select current_terms->>'issuer_is_client' = 'true' and current_terms->>'issuer_cuit' = '30500010912' and assigned_approver_id = :'W' from public.com_requests where id = (select (ok->>'id')::uuid from e1))
  and (select lejos like 'BAD_DUE_DATE%' and mal_cuit like 'BAD_ISSUER_CUIT%' from e1), (select lejos || ' · ' || mal_cuit from e1));
-- ======================= DECISIONES =======================
create temp table d1 as select pg_temp.as(:'C1', format($q$ select public.com_decide(%L, 1, 'APROBAR', null, null) $q$, (select id from q1))) com,
  pg_temp.as(:'S', format($q$ select public.com_decide(%L, 1, 'APROBAR', null, null) $q$, (select id from q1))) otro,
  pg_temp.as(:'W', format($q$ select public.com_decide(%L, 1, 'APROBAR_CON_CAMBIOS', '{"amount":2500000,"installments":3}'::jsonb, 'x') $q$, (select id from q1))) sin_motivo,
  pg_temp.as(:'W', format($q$ select public.com_decide(%L, 1, 'APROBAR_CON_CAMBIOS', '{"amount":2500000,"installments":3}'::jsonb, 'Se ajusta al techo sugerido') $q$, (select id from q1))) ok,
  pg_temp.as(:'GB', format($q$ select public.com_decide(%L, 1, 'RECHAZAR', null, 'Decisión simultánea') $q$, (select id from q1))) simultanea;
grant select on d1 to public;
create temp table q1b as select * from public.com_requests where id = (select id from q1); grant select on q1b to public;
select tst.res('CM-07 DECISIÓN: Comercial y otros roles NO deciden; aprobar con cambios exige motivo; Wilfredo aprueba con cambios (originales conservados); una decisión SIMULTÁNEA posterior se rechaza (CONFLICT); el historial es INALTERABLE',
  (select com like 'FORBIDDEN%' and otro like 'FORBIDDEN%' and sin_motivo like 'REASON_REQUIRED%' and ok = 'OK' and simultanea like 'CONFLICT%' from d1)
  and (select status = 'APROBADA_MOD' and (original_terms->>'amount')::numeric = 2750000 and (final_terms->>'amount')::numeric = 2500000 and (final_terms->>'installments')::int = 3 and decided_as = 'APROBADOR' from q1b)
  and pg_temp.err(format('update public.com_request_events set reason = ''x'' where request_id = %L', (select id from q1))) like 'IMMUTABLE%'
  and pg_temp.err(format('delete from public.com_request_events where request_id = %L', (select id from q1))) like 'IMMUTABLE%', (select simultanea from d1));
-- SUPLENCIA: Gabriela (Administradora General) resuelve una solicitud ASIGNADA a Wilfredo
create temp table e1q as select * from public.com_requests where id = (select (ok->>'id')::uuid from e1); grant select on e1q to public;
create temp table s1 as select pg_temp.as(:'GB', format($q$ select public.com_decide(%L, 1, 'APROBAR', null, null) $q$, (select id from e1q))) gb,
  pg_temp.as(:'W', format($q$ select public.com_decide(%L, 1, 'RECHAZAR', null, 'Wilfredo llega tarde') $q$, (select id from e1q))) w; grant select on s1 to public;
create temp table e1r as select * from public.com_requests where id = (select id from e1q); grant select on e1r to public;
select tst.res('CM-08 SUPLENCIA: Gabriela (Administradora General ACTIVA) resuelve lo asignado a Wilfredo SIN transferencia; queda «asignada a Wilfredo Guzmán» y «resuelta por Gabriela Brandani — Administrador General»; Wilfredo después NO puede decidir (una sola decisión); se le avisa',
  (select gb = 'OK' and w like 'CONFLICT%' from s1) and (select assigned_approver_id = :'W' and decided_by = :'GB' and decided_as = 'SUPLENTE_ADMIN' and status = 'APROBADA' from e1r)
  and (select actor_label || ' | ' || public._com_label(assigned_approver_id) from public.com_request_events where request_id = (select id from e1q) and kind = 'APROBADA') = 'Gabriela Brandani — Administrador General | Wilfredo Guzmán'
  and exists (select 1 from public.com_notifications where user_id = :'W' and request_id = (select id from e1q) and kind = 'RESUELTA_POR_SUPLENTE')
  and (select count(*) from public.com_request_events where request_id = (select id from e1q) and kind in ('APROBADA', 'RECHAZADA')) = 1, (select gb || ' · ' || w from s1));
-- pérdida del rol: sin ADMIN, sin acceso global INMEDIATO
create temp table r2 as select pg_temp.get(:'C1', format($q$ select public.com_create_request('FINANCIACION', %L, 'P-60', '{"amount":500000,"installments":2}'::jsonb, null, 'op-r2')::text $q$, pg_temp.cid('106')))::jsonb r; grant select on r2 to public;
select set_config('okd.sync', 'on', false); update public.profiles set role = 'SUPERVISOR_DESPACHO' where id = :'GB'; select set_config('okd.sync', '', false);
create temp table s2 as select pg_temp.as(:'GB', format($q$ select public.com_decide(%L, 1, 'APROBAR', null, null) $q$, (select (r->>'id')::uuid from r2))) gb,
  pg_temp.get(:'GB', 'select public.com_list(''TODAS'')::text') lista; grant select on s2 to public;
select set_config('okd.sync', 'on', false); update public.profiles set role = 'ADMIN' where id = :'GB'; select set_config('okd.sync', '', false);
select tst.res('CM-09 PÉRDIDA DEL ROL: si Gabriela deja de ser Administradora General, pierde EN EL ACTO la suplencia y la vista global', (select gb like 'FORBIDDEN%' and lista like 'ERR FORBIDDEN%' from s2), (select gb from s2));
-- DEVOLUCIÓN y respuesta de Comercial
create temp table dv as select pg_temp.as(:'W', format($q$ select public.com_decide(%L, 1, 'DEVOLVER', '{"amount":400000,"installments":2}'::jsonb, 'Bajar el importe') $q$, (select (r->>'id')::uuid from r2))) dev,
  pg_temp.as(:'C2', format($q$ select public.com_respond(%L, 2, true, 'ok') $q$, (select (r->>'id')::uuid from r2))) ajeno,
  pg_temp.as(:'C1', format($q$ select public.com_respond(%L, 2, true, 'Acepto el nuevo importe') $q$, (select (r->>'id')::uuid from r2))) acepta,
  pg_temp.as(:'W', format($q$ select public.com_decide(%L, 3, 'APROBAR', null, null) $q$, (select (r->>'id')::uuid from r2))) aprueba; grant select on dv to public;
select tst.res('CM-10 DEVOLUCIÓN: «devuelta» NO es aprobación; el Comercial que la creó acepta los cambios y se REENVÍA (otro Comercial no puede); luego se aprueba con las condiciones aceptadas; cronología completa',
  (select dev = 'OK' and ajeno like 'FORBIDDEN%' and acepta = 'OK' and aprueba = 'OK' from dv)
  and (select status = 'APROBADA' and (final_terms->>'amount')::numeric = 400000 and (original_terms->>'amount')::numeric = 500000 from public.com_requests where id = (select (r->>'id')::uuid from r2))
  and (select string_agg(kind, '>' order by seq) from public.com_request_events where request_id = (select (r->>'id')::uuid from r2)) = 'ENVIADA>PENDIENTE>DEVUELTA_CON_MODIFICACIONES>CAMBIOS_ACEPTADOS_REENVIADA>PENDIENTE>APROBADA', '');
create temp table ct as select pg_temp.get(:'C3', format($q$ select public.com_create_request('FINANCIACION', %L, 'C-1', '{"amount":300000,"installments":1}'::jsonb, null, 'op-c3')::text $q$, pg_temp.cid('101')))::jsonb r; grant select on ct to public;
create temp table ctd as select pg_temp.as(:'F', format($q$ select public.com_decide(%L, 1, 'RECHAZAR', null, 'Sin respaldo de compras') $q$, (select (r->>'id')::uuid from ct))) f; grant select on ctd to public;
select tst.res('CM-11 CARTERA → Franco: asignada a Franco, que la resuelve COMO aprobador (no como suplente); rechazo con motivo',
  (select assigned_approver_id = :'F' and decided_as = 'APROBADOR' and status = 'RECHAZADA' from public.com_requests where id = (select (r->>'id')::uuid from ct)) and (select f from ctd) = 'OK', '');
-- ======================= KPI AUTOMÁTICO desde las cargas DIARIAS de Depósito =======================
create temp table per as select ((date_trunc('month', now() at time zone 'America/Argentina/Mendoza') - interval '3 month')::date) m0, ((date_trunc('month', now() at time zone 'America/Argentina/Mendoza') - interval '1 month')::date) m1; grant select on per to public;
-- comprobantes del cliente 101 (CUIT 30500010912): m0 1.500.000 · m0+1 2.000.000 · m1 2.000.000 + 700.000 − NOC 200.000 = 2.500.000
create or replace function pg_temp.docs(upto date) returns jsonb language sql as $f$
  select coalesce(jsonb_agg(x), '[]') from (
    select jsonb_build_object('c', 'TECNOLOGIA DEL NORTE SOCIEDAD ANONIMA', 'cuit', '30-50001091-2', 'comp', comp, 'n', upper(regexp_replace(comp, '[\s\[\]\-_.()]', '', 'g')), 'd', d, 'm', m, 's', m, 'q', '') x
    from (values ('FAC A 0001-00000101', (select m0 from per) + 5, 1500000::numeric), ('FAC A 0001-00000102', (select m0 from per) + 40, 2000000), ('FAC A 0001-00000103', (select m1 from per) + 3, 2000000),
                 ('NDP 0001-00000104', (select m1 from per) + 12, 700000), ('NOC A 0001-00000005', (select m1 from per) + 20, -200000), ('REC 0001-00000009', (select m1 from per) + 21, 900000),
                 ('XYZ 0001-00000001', (select m1 from per) + 22, 50000)) v(comp, d, m) where d <= upto
    union all select jsonb_build_object('c', 'TECNOLOGIA DEL NORTE SOCIEDAD ANONIMA', 'cuit', '30500010912', 'comp', 'Saldo Anterior', 'san', true, 'v', 99999999)
    union all select jsonb_build_object('c', 'OTRO NOMBRE DISTINTO', 'cuit', (select n from cv), 'comp', 'FAC B 0002-00000001', 'd', (select m1 from per) + 2, 'm', 90000, 's', 90000)
    union all select jsonb_build_object('c', 'TECNOCASA SRL', 'cuit', '30707865888', 'comp', 'FAC A 0003-00000001', 'd', (select m1 from per) + 2, 'm', 70000, 's', 70000)
    union all select jsonb_build_object('c', 'ARQPLAY S A', 'cuit', '30717322637', 'comp', 'FAC A 0004-00000001', 'd', (select m1 from per) + 2, 'm', 50000, 's', 50000)) t; $f$;
-- cargas DIARIAS (cada 3 días) desde 2 días antes del primer mes hasta pasado el último: el mismo comprobante aparece MUCHAS veces
create temp table days as select (g::date) d, row_number() over () n from generate_series((select m0 from per) - 2, (select m1 from per) + 34, interval '3 day') g; grant select on days to public;
create or replace function pg_temp.ingest(dd date, n int) returns text language plpgsql as $f$ declare o text; begin
  perform tst.u('e0000000-0000-0000-0000-000000000006'); set local role authenticated;
  o := public.com_ingest('SC', jsonb_build_object('hash', 'sc-dia-' || n, 'file_name', 'Saldo comprobante ' || dd || '.xlsx', 'loaded_at', dd, 'batch', 1, 'batches', 1), pg_temp.docs(dd))::text; reset role;
  update public.com_ingests set at = dd + interval '9 hour' where content_hash = 'sc-dia-' || n; return o; end $f$;
select pg_temp.ingest(d, n::int) from days order by d;
create temp table ing as select count(*) n, sum((stats->>'repetidos')::int) rep from public.com_ingests where kind = 'SC'; grant select on ing to public;
create temp table k1 as select pg_temp.get(:'C1', format('select (public.com_kpi_for_client(%L))::text', pg_temp.cid('101')))::jsonb k, pg_temp.get(:'C1', format('select (public.com_kpi_for_client(%L))::text', pg_temp.cid('104')))::jsonb dni,
  pg_temp.as(:'C1', $q$ select public.com_ingest('SC', '{"hash":"x","batch":1,"batches":1}'::jsonb, '[]'::jsonb) $q$) comercial; grant select on k1 to public;
select tst.res('CM-12 KPI AUTOMÁTICO desde las cargas diarias (sin segunda carga ni confirmación): cada comprobante cuenta UNA vez aunque aparezca en muchas cargas; la NOC resta; recibo, «Saldo Anterior» y tipo desconocido NO suman → promedio $2.000.000, piso $2.500.000, techo $3.000.000; Comercial NO carga; un cliente solo con DNI → SIN HISTORIAL',
  (select k->>'status' = 'OK' and (k->>'average')::numeric = 2000000 and (k->>'floor')::numeric = 2500000 and (k->>'ceiling')::numeric = 3000000 and (k->>'coverage')::int = 3 from k1)
  and (select count(*) from public.com_sc_documents where cuit = '30500010912') = 7 and (select n > 20 and rep > 50 from ing)
  and (select status from public.com_sc_documents where comp = 'XYZ 0001-00000001') = 'SIN_CLASIFICAR' and (select class from public.com_sc_documents where comp = 'REC 0001-00000009') = 'PAGO'
  and (select dni->>'status' from k1) = 'SIN_HISTORIAL' and (select comercial like 'FORBIDDEN%' from k1), (select k::text from k1));
-- reintento de la MISMA carga y comprobante que reaparece con OTRO importe
create temp table rr as select pg_temp.get(:'O', format($q$ select public.com_ingest('SC', jsonb_build_object('hash','sc-dia-1','batch',1,'batches',1,'loaded_at',%L::date), '[]'::jsonb)::text $q$, (select min(d) from days)))::jsonb rep; grant select on rr to public;
select pg_temp.get(:'O', format($q$ select public.com_ingest('SC', '{"hash":"sc-conf","batch":1,"batches":1}'::jsonb, %L::jsonb)::text $q$, jsonb_build_array(jsonb_build_object('c', 'TECNOLOGIA DEL NORTE SOCIEDAD ANONIMA', 'cuit', '30500010912', 'comp', 'NDP 0001-00000104', 'd', (select m1 from per) + 12, 'm', 750000, 's', 750000))));
update public.com_ingests set at = (select max(at) from public.com_ingests where content_hash like 'sc-dia-%') - interval '1 day' where content_hash = 'sc-conf';
create temp table k2 as select pg_temp.get(:'C1', format('select (public.com_kpi_for_client(%L))::text', pg_temp.cid('101')))::jsonb k; grant select on k2 to public;
select tst.res('CM-13 DUPLICADOS y CONCILIACIÓN: la misma carga no se reprocesa; un comprobante que vuelve con OTRO importe queda EN CONCILIACIÓN y FUERA del KPI (no se suma dos veces); CUIT en revisión, CUIT fuera del padrón, nombre distinto y tipo sin clasificar son INCIDENCIAS; el padrón NO se toca',
  (select (rep->>'repeated')::boolean from rr) and (select status from public.com_sc_documents where comp = 'NDP 0001-00000104') = 'CONFLICTO'
  and (select (k->>'excluded_docs')::int >= 2 and (k->'months'->2->>'amount')::numeric = 1800000 from k2)
  and (select string_agg(distinct kind, ',' order by kind) from public.com_reconciliation_issues where status = 'ABIERTA') = 'CUIT_EN_REVISION,CUIT_NO_EN_PADRON,IMPORTE_CAMBIADO,NOMBRE_DISTINTO,TIPO_SIN_CLASIFICAR'
  and (select razon_social from public.com_clients where cuit = (select n from cv)) = 'GOMEZ ANA', (select k::text from k2));
-- CUENTA CORRIENTE: complementaria, solo para quien decide
select pg_temp.get(:'O', format($q$ select public.com_ingest('CC', '{"hash":"cc-1","batch":1,"batches":1,"file_name":"Saldo cuenta corriente.xlsx"}'::jsonb, %L::jsonb)::text $q$, '[{"c":"TECNOLOGIA DEL NORTE","cuit":"30500010912","saldo":1250000}]'));
create temp table fi as select pg_temp.get(:'W', format('select public.com_client_finance(%L)::text', pg_temp.cid('101')))::jsonb w, pg_temp.get(:'C1', format('select public.com_client_finance(%L)::text', pg_temp.cid('101'))) c; grant select on fi to public;
select tst.res('CM-14 CUENTA CORRIENTE complementaria: Gerencia ve saldo, fecha y comprobantes pendientes (no se suman a ventas); Comercial NO la ve',
  (select (w->>'cc_saldo')::numeric = 1250000 and jsonb_array_length(w->'pendientes') >= 3 and c like 'ERR FORBIDDEN%' from fi), (select left(w::text, 160) from fi));
-- foto de la solicitud y coberturas incompletas
create temp table r3 as select pg_temp.get(:'C1', format($q$ select public.com_create_request('FINANCIACION', %L, 'P-70', '{"amount":2800000,"installments":4}'::jsonb, null, 'op-r3')::text $q$, pg_temp.cid('101')))::jsonb r; grant select on r3 to public;
select pg_temp.as(:'A', $q$ select public.com_set_settings('{"kpi_months":6}'::jsonb) $q$);
create temp table k6 as select pg_temp.get(:'C1', format('select (public.com_kpi_for_client(%L))::text', pg_temp.cid('101')))::jsonb no_regla; grant select on k6 to public;
select pg_temp.as(:'A', $q$ select public.com_set_settings('{"kpi_partial_rule":"PROMEDIO_MESES_CUBIERTOS"}'::jsonb) $q$);
insert into k6 select pg_temp.get(:'C1', format('select (public.com_kpi_for_client(%L))::text', pg_temp.cid('101')))::jsonb;
select tst.res('CM-15 FOTO y COBERTURA: la solicitud guarda el KPI usado; con 6 meses configurados y solo 3 con cargas, los meses sin datos NO son $0 → «SIN HISTORIAL SUFICIENTE · 3 de 6 meses con cargas»; solo si se CONFIGURA la regla parcial se promedia sobre los meses cubiertos',
  (select kpi_snapshot->>'status' = 'OK' and (kpi_snapshot->>'coverage')::int = 3 from public.com_requests where id = (select (r->>'id')::uuid from r3))
  and (select no_regla->>'status' = 'SIN_HISTORIAL' and no_regla->>'detail' like '%3 de 6 meses con cargas%' from k6 limit 1)
  and (select no_regla->>'status' = 'PARCIAL' and (no_regla->>'coverage')::int = 3 from k6 offset 1 limit 1)
  and (select bool_and(x->'amount' = 'null'::jsonb) from k6, jsonb_array_elements(no_regla->'months') x where not (x->>'covered')::boolean), '');
select pg_temp.as(:'A', $q$ select public.com_set_settings('{"kpi_months":3,"kpi_partial_rule":"NO_CALCULAR"}'::jsonb) $q$);
create temp table ps as select pg_temp.get(:'A', 'select public.com_sources_status()::text')::jsonb a, pg_temp.get(:'O', 'select public.com_sources_status()::text') o; grant select on ps to public;
create temp table lbl as select pg_temp.get(:'C1', format('select (public.com_kpi_for_client(%L))::text', pg_temp.cid('101')))::jsonb k0; grant select on lbl to public;
select pg_temp.as(:'A', $q$ select public.com_set_settings('{"kpi_source_verified":true}'::jsonb) $q$);
insert into lbl select pg_temp.get(:'C1', format('select (public.com_kpi_for_client(%L))::text', pg_temp.cid('101')))::jsonb;
select pg_temp.as(:'A', $q$ select public.com_set_settings('{"kpi_source_verified":false}'::jsonb) $q$);
select tst.res('CM-15B KPI PROVISORIO: mientras no se verifique la fuente, el KPI se rotula «RECOMENDACIÓN PROVISORIA — BASADA EN COMPROBANTES DISPONIBLES»; al verificarla, deja de serlo',
  (select k0->>'label' = 'RECOMENDACIÓN PROVISORIA — BASADA EN COMPROBANTES DISPONIBLES' and (k0->>'provisional')::boolean from lbl limit 1)
  and (select k0->'label' = 'null'::jsonb and not (k0->>'provisional')::boolean from lbl offset 1 limit 1), '');
create temp table dsp as select pg_temp.get(:'A', format('select public.com_dispatch_stats(%L, %L)::text', current_date - 365, current_date))::jsonb a, pg_temp.get(:'A', 'select public.com_approvers()::text')::jsonb ap, pg_temp.get(:'C1', 'select public.com_approvers()::text') c1; grant select on dsp to public;
select tst.res('CM-15C PANEL: aprobadores posibles = ACTIVOS con permiso (Wilfredo, Franco, Gabriela, Admin); despachos por transportista y zona SOLO desde hojas reales; Comercial no accede',
  (select jsonb_typeof(a) = 'array' and ap::text like '%Wilfredo Guzmán%' and ap::text like '%Gabriela Brandani%' and c1 like 'ERR FORBIDDEN%' from dsp), (select left(a::text, 160) from dsp));
select tst.res('CM-16 PANEL GENERAL: fecha y archivo de la última carga de Saldo comprobante y de Saldo cuenta corriente, meses cubiertos, incidencias y clientes sin historial (solo Administrador General)',
  (select a->'ultima_sc' ? 'at' and a->'ultima_cc'->>'archivo' = 'Saldo cuenta corriente.xlsx' and jsonb_array_length(a->'meses_cubiertos') >= 3 and (a->'incidencias') ? 'IMPORTE_CAMBIADO' and o like 'ERR FORBIDDEN%' from ps), left((select a::text from ps), 200));
-- ======================= DESPACHO, BANDEJAS, INFORMES, SEGURIDAD =======================
create temp table tr as select pg_temp.get(:'S', 'select public.com_track(''30500010912'')::text')::jsonb s, pg_temp.get(:'O', 'select public.com_track(''26764'')::text')::jsonb o,
  pg_temp.get(:'S', 'select public.com_track('''', true)::text')::jsonb abiertas, pg_temp.get(:'G', 'select public.com_track(''TECNO'')::text') g; grant select on tr to public;
select tst.res('CM-17 TRAZABILIDAD de Despacho: por CUIT, pedido o en curso; estado, línea de tiempo y condiciones FINALES; SIN KPI, notas ni motivos; el transportista no accede',
  (select jsonb_array_length(s) >= 3 and s->0 ? 'timeline' and s->0->'kpi' = 'null'::jsonb and s->0->'notes' = 'null'::jsonb and o->0->>'order_ref' = '26764' and o->0->>'status' = 'APROBADA_MOD'
     and (o->0->'final_terms'->>'amount')::numeric = 2500000 and g like 'ERR FORBIDDEN%' from tr)
  and (select bool_and(x->>'status' in ('PENDIENTE', 'DEVUELTA')) from tr, jsonb_array_elements(abiertas) x)
  and (select bool_and(e->'reason' = 'null'::jsonb) from tr, jsonb_array_elements(s) x, jsonb_array_elements(x->'timeline') e), left((select o::text from tr), 200));
create temp table bl as select pg_temp.get(:'C1', 'select jsonb_array_length(public.com_list(''MIS''))::text') c1, pg_temp.get(:'C2', 'select jsonb_array_length(public.com_list(''MIS''))::text') c2,
  pg_temp.get(:'W', 'select jsonb_array_length(public.com_list(''BANDEJA''))::text') w, pg_temp.get(:'F', 'select jsonb_array_length(public.com_list(''BANDEJA''))::text') f,
  pg_temp.get(:'C1', 'select public.com_list(''TODAS'')::text') c1todas, pg_temp.get(:'F', 'select public.com_report(current_date - 30, current_date)::text')::jsonb rep, pg_temp.get(:'W', 'select public.com_report(current_date - 30, current_date)::text') wrep;
grant select on bl to public;
select tst.res('CM-18 BANDEJAS e INFORMES: Comercial ve SOLO las suyas; Wilfredo su bandeja; un Administrador General ve TODAS (incluidas las de Wilfredo); informes solo para el Administrador General',
  (select c1::int = 3 and c2::int = 1 and w::int = 4 and f::int = (select count(*) from public.com_requests) and c1todas like 'ERR FORBIDDEN%' and rep ? 'por_aprobador' and wrep like 'ERR FORBIDDEN%' from bl),
  (select c1 || '/' || c2 || '/' || w || '/' || f from bl));
select tst.res('CM-19 SEGURIDAD: ningún usuario lee las tablas directo (RLS + sin privilegios); anon no ejecuta; funciones internas no invocables',
  pg_temp.get(:'A', 'select count(*)::text from public.com_requests') like 'ERR %' and pg_temp.get(:'C1', 'select count(*)::text from public.com_clients') like 'ERR %'
  and not has_function_privilege('anon', 'public.com_create_request(text,uuid,text,jsonb,text,text)', 'EXECUTE') and not has_function_privilege('authenticated', 'public._com_notify(uuid,integer,uuid,text,text,text)', 'EXECUTE'), '');
