-- Pruebas de la PROPUESTA V4.26 (padrón de correos · «en camino» · BUSCAR ENTREGA). Corre DESPUÉS de g2_revision_test. Datos FICTICIOS.
\set ON_ERROR_STOP on
\set A 'e0000000-0000-0000-0000-00000000000a'
\set S 'e0000000-0000-0000-0000-000000000005'
\set O 'e0000000-0000-0000-0000-000000000006'
\set G 'e0000000-0000-0000-0000-000000000007'
\set S2 'e0000000-0000-0000-0000-0000000000f2'
\set VH 'f0000000-0000-0000-0000-000000000001'
insert into auth.users(id, email) values (:'S2', 'v426.s2@t') on conflict do nothing;
select set_config('okd.sync', 'on', false);
insert into public.profiles(id, full_name, email, role, status) values (:'S2', 'Superior Otro Equipo', 'v426.s2@t', 'SUPERVISOR_DESPACHO', 'ACTIVO') on conflict (id) do nothing;
update public.profiles set supervisor_user_id = :'S' where id = :'O';
select set_config('okd.sync', '', false);
-- un correo MANUAL ya cargado (de los 47 actuales): NO se pisa
insert into public.client_emails(cuit, client_name, email, source) values ('20123456786', 'CLIENTE MANUAL', 'manual@cliente.test', 'MANUAL');
create temp table pad as select jsonb_build_object('file_name', 'listado_clientes (13).xlsx', 'rows', jsonb_build_array(
  jsonb_build_object('fila', 2, 'tipo', 'CUIT', 'clave', '20123456786', 'email', 'otro@cliente.test', 'nombre', 'CLIENTE MANUAL'),          -- existe MANUAL → se conserva
  jsonb_build_object('fila', 3, 'tipo', 'CUIT', 'clave', '30717780406', 'email', 'sac@5ta.test', 'nombre', '5TA INFORMATICA'),            -- nuevo
  jsonb_build_object('fila', 4, 'tipo', 'CUIT', 'clave', '30717780407', 'email', 'x@y.test', 'nombre', 'CUIT MALO'),                     -- dígito inválido
  jsonb_build_object('fila', 5, 'tipo', 'DNI', 'clave', '42935147', 'email', 'abel@cliente.test', 'nombre', 'ABEL CALLE'),
  jsonb_build_object('fila', 5, 'tipo', 'NOMBRE', 'clave', 'Abel Calle', 'email', 'abel@cliente.test', 'nombre', 'ABEL CALLE'),
  jsonb_build_object('fila', 6, 'tipo', 'NOMBRE', 'clave', 'Gómez Hnos S.A.', 'email', 'gomez@cliente.test', 'nombre', 'GÓMEZ HNOS S.A.'),
  jsonb_build_object('fila', 7, 'tipo', 'NOMBRE', 'clave', 'Pérez Juan', 'email', 'perez1@cliente.test', 'nombre', 'PEREZ JUAN'),       -- mismo nombre,
  jsonb_build_object('fila', 8, 'tipo', 'NOMBRE', 'clave', 'PEREZ JUAN', 'email', 'perez2@cliente.test', 'nombre', 'PEREZ JUAN'),       -- otro correo → AMBIGUO
  jsonb_build_object('fila', 9, 'tipo', 'DNI', 'clave', '1234', 'email', 'corto@cliente.test', 'nombre', 'DNI CORTO'),
  jsonb_build_object('fila', 10, 'tipo', 'CUIT', 'clave', '30500010912', 'email', 'no-es-correo', 'nombre', 'SIN CORREO VALIDO'))) p;
grant select on pad to public;
begin; select tst.u(:'S'); set local role authenticated;
select tst.expect('P-02 un usuario que NO es Administrador General no importa el padrón', $q$ select public.client_padron_import((select p from pad), true) $q$, 'FORBIDDEN%');
commit;
begin; select tst.u(:'A'); set local role authenticated;
create temp table prev as select public.client_padron_import((select p from pad), false) r; grant select on prev to public;
commit;
create temp table cnt0 as select (select count(*) from public.client_email_aliases) + (select count(*) from public.client_emails) n; grant select on cnt0 to public;   -- superusuario: la vista previa no escribió
begin; select tst.u(:'A'); set local role authenticated;
create temp table appl as select public.client_padron_import((select p from pad), true) r; grant select on appl to public;
commit;
select tst.res('P-01c la IMPORTACIÓN del padrón NO encola ni envía ningún correo a clientes', (select count(*) from public.customer_email_jobs) = 0, '');
select tst.res('P-01a VISTA PREVIA: informa lo mismo que aplicaría y NO escribe nada', (select r->>'aplicado' from prev) = 'false' and (select n from cnt0) = 1
  and (select r->'nuevos' from prev) = (select r->'nuevos' from appl), (select r::text from prev));
select tst.res('P-01 IMPORTACIÓN (CONSERVAR): 4 nuevos (CUIT, DNI y 2 nombres), el correo MANUAL se conserva, y se rechazan CUIT inválido, nombre ambiguo (2), DNI corto y correo inválido',
  (select (r->>'nuevos')::int = 4 and (r->>'conservados_existentes')::int = 1 and (r->>'rechazados')::int = 5 from appl)
  and (select email from public.client_emails where cuit = '20123456786') = 'manual@cliente.test' and (select source from public.client_emails where cuit = '20123456786') = 'MANUAL'
  and (select email from public.client_emails where cuit = '30717780406') = 'sac@5ta.test'
  and (select email from public.client_email_aliases where key_type = 'NOMBRE' and key_value = 'GOMEZ HNOS S A') = 'gomez@cliente.test'
  and not exists (select 1 from public.client_email_aliases where key_value = 'PEREZ JUAN')
  and (select count(*) from public.client_padron_imports) = 1, (select r::text from appl));
-- ===== hoja con 4 pedidos (equipo de S: la publica el Operario O) + snapshot con factura/NDP =====
begin; select tst.u(:'O'); set local role authenticated;
select public.reserve_orders('V426-A', array['78001','78002','78003','78004']);
create temp table ra as select * from public.publish_route(jsonb_build_object('sheet_key','V426-A','carrier_id','INTERNO','responsable_id',:'G','vehicle_id',:'VH','rules_version',1,'routing_rules_version',1,
  'pdf_model', jsonb_build_object('data', jsonb_build_array(jsonb_build_object('r', jsonb_build_object('fecha','2026-11-20','mainOrder','78001','mainDoc','FCB 0002-00012345')),
                                                            jsonb_build_object('r', jsonb_build_object('fecha','2026-11-20','mainOrder','78002','mainDoc','NDP 0001-00000777')))),
  'stops',jsonb_build_array(
   jsonb_build_object('client_name','CLIENTE MANUAL','client_key','20123456786','address','Calle 1','stop_type','PEDIDO','order_numbers',jsonb_build_array('78001'),'merchandise_amount',1000,'task','ENTREGA','ready',true),
   jsonb_build_object('client_name','ABEL CALLE','client_key','42935147','address','Calle 2','stop_type','PEDIDO','order_numbers',jsonb_build_array('78002'),'merchandise_amount',1000,'task','ENTREGA','ready',true),
   jsonb_build_object('client_name','Gómez Hnos S.A.','client_key','GOMEZ HNOS S A','address','Calle 3','stop_type','PEDIDO','order_numbers',jsonb_build_array('78003'),'merchandise_amount',1000,'task','ENTREGA','ready',true),
   jsonb_build_object('client_name','PEREZ JUAN','client_key','PEREZ JUAN','address','Calle 4','stop_type','PEDIDO','order_numbers',jsonb_build_array('78004'),'merchandise_amount',1000,'task','ENTREGA','ready',true)))); grant select on ra to public;
commit;
create temp table st as select id, order_numbers[1] o from public.route_stops where route_id = (select id from ra); grant select on st to public;
begin; select tst.u(:'G'); set local role authenticated;
create temp table sug as select o, public.delivery_email_suggestion2(id) e from st; grant select on sug to public;
commit;
select tst.res('P-03 SUGERENCIA en la entrega: CUIT → correo MANUAL · DNI → padrón · nombre exacto → padrón · nombre AMBIGUO → ninguna',
  (select e from sug where o = '78001') = 'manual@cliente.test' and (select e from sug where o = '78002') = 'abel@cliente.test'
  and (select e from sug where o = '78003') = 'gomez@cliente.test' and (select e from sug where o = '78004') is null, (select string_agg(o || '=' || coalesce(e, '∅'), ' · ') from sug));
-- ===== SALIDA REAL → «en camino» =====
create temp table j0 as select count(*) n from public.customer_email_jobs where route_id = (select id from ra); grant select on j0 to public;
begin; select tst.u(:'G'); set local role authenticated;
select public.start_route((select id from ra), (select current_km from public.vehicles where id = 'f0000000-0000-0000-0000-000000000001') + 10);
commit;
create temp table j1 as select s.o, j.recipient, j.kind from public.customer_email_jobs j join st s on s.id = j.stop_id where j.route_id = (select id from ra); grant select on j1 to public;
select tst.res('P-04 SALIDA REAL: «en camino» encolado UNA vez por pedido CON correo (78001 manual, 78002 DNI, 78003 nombre); SIN correo (78004) no se encola; nada antes de salir',
  (select n from j0) = 0 and (select count(*) from j1 where kind = 'ON_THE_WAY') = 3 and not exists (select 1 from j1 where o = '78004')
  and (select recipient from j1 where o = '78001') = 'manual@cliente.test' and (select recipient from j1 where o = '78002') = 'abel@cliente.test', (select string_agg(o || '→' || recipient, ' · ') from j1));
-- otra transición de started_at + el aviso de "próxima parada" existente: misma clave → SIN duplicados
update public.routes set started_at = null where id = (select id from ra); update public.routes set started_at = now() where id = (select id from ra);
select public._queue_on_the_way((select id from ra));
select tst.res('P-04b SIN DUPLICADOS: una segunda transición de salida y el aviso de próxima parada no generan un segundo correo para el mismo pedido',
  (select count(*) from public.customer_email_jobs where route_id = (select id from ra) and kind = 'ON_THE_WAY') = 3, '');
-- hoja SOLO con ubicaciones internas: no hay pedidos comerciales → nada
begin; select tst.u(:'O'); set local role authenticated;
create temp table rb as select * from public.publish_route(jsonb_build_object('sheet_key','V426-B','carrier_id','INTERNO','responsable_id',:'G','vehicle_id',:'VH','rules_version',1,'routing_rules_version',1,
  'stops',jsonb_build_array(jsonb_build_object('client_name','Montecaseros','address','Montecaseros','stop_type','UBICACION_INTERNA','internal_location_key','MONTECASEROS','order_numbers',jsonb_build_array(),'ready',true)))); grant select on rb to public;
commit;
update public.routes set started_at = now(), operational_status = 'EN_CURSO' where id = (select id from rb);
select tst.res('P-05 hoja SOLO con ubicaciones internas: la salida no envía ningún aviso a clientes', (select count(*) from public.customer_email_jobs where route_id = (select id from rb)) = 0, '');
-- ===== BUSCAR ENTREGA =====
insert into public.stop_evidence(stop_id, receiver_name, signature_png, signature_sha256, receiver_cuil, created_by)
  values ((select id from st where o = '78001'), 'María Receptora', '\x89504e47'::bytea, 'abc', '27111111110', :'G');   -- entrega recibida (simulada)
create or replace function pg_temp.find(q text) returns jsonb language plpgsql as $f$ begin return public.search_deliveries(q); exception when others then return to_jsonb(sqlerrm); end $f$;
begin; select tst.u(:'A'); set local role authenticated;
create temp table sa as select pg_temp.find('78001') a1, pg_temp.find('12345') a2, pg_temp.find('0002-00012345') a3, pg_temp.find('FCB 0002-00012345') a4, pg_temp.find('0003-00012345') a5,
  pg_temp.find('NDP 0001-00000777') a6, pg_temp.find((select number from ra)) a7, pg_temp.find('78') a8; grant select on sa to public;
commit;
begin; select tst.u(:'S'); set local role authenticated; create temp table ss as select pg_temp.find('78001') r; grant select on ss to public; commit;
begin; select tst.u(:'S2'); set local role authenticated; create temp table s2 as select pg_temp.find('78001') r; grant select on s2 to public; commit;
begin; select tst.u(:'G'); set local role authenticated; create temp table sg as select pg_temp.find('78001') r; grant select on sg to public; commit;
select tst.res('P-06 BUSCAR por PEDIDO, por FACTURA/NDP (12345 · 0002-00012345 · FCB 0002-00012345 · NDP 0001-00000777) y por HOJA; un punto de venta distinto no coincide',
  jsonb_array_length((select a1 from sa)) = 1 and (select a1->0->>'client_name' from sa) = 'CLIENTE MANUAL' and (select a1->0->>'docs' from sa) like '%0002-00012345%'
  and jsonb_array_length((select a2 from sa)) = 1 and jsonb_array_length((select a3 from sa)) = 1 and jsonb_array_length((select a4 from sa)) = 1 and jsonb_array_length((select a5 from sa)) = 0
  and (select a6->0->'order_numbers'->>0 from sa) = '78002' and jsonb_array_length((select a7 from sa)) = 4, '');
select tst.res('P-06b consulta demasiado corta → QUERY_TOO_SHORT', (select a8 #>> '{}' from sa) like 'QUERY_TOO_SHORT%', (select a8::text from sa));
select tst.res('P-06c PERMISOS: el Administrador ve receptor, CUIL y firma; el Superior del EQUIPO la encuentra; el Superior de OTRO equipo NO; el transportista ve su hoja',
  (select a1->0->>'receiver_name' from sa) = 'María Receptora' and (select a1->0->>'receiver_cuil' from sa) = '27111111110' and (select (a1->0->>'has_signature')::boolean from sa)
  and jsonb_array_length((select r from ss)) = 1 and jsonb_array_length((select r from s2)) = 0 and jsonb_array_length((select r from sg)) = 1, '');
select tst.res('P-06d SIN signatures.view (transportista): ve el estado, pero NO quién recibió, el CUIL ni la firma',
  (select r->0->>'outcome' from sg) is not null and (select r->0->'receiver_name' from sg) = 'null'::jsonb and (select r->0->'receiver_cuil' from sg) = 'null'::jsonb
  and (select r->0->'has_signature' from sg) = 'null'::jsonb and (select (r->0->>'signatures_visible')::boolean from sg) = false, (select (r->0)::text from sg));
select tst.res('P-07 privilegios: anon sin acceso; las tablas del padrón no se leen ni escriben directo; las funciones internas no son invocables',
  not has_function_privilege('anon', 'public.search_deliveries(text)', 'EXECUTE') and not has_table_privilege('authenticated', 'public.client_email_aliases', 'SELECT')
  and not has_table_privilege('authenticated', 'public.client_email_aliases', 'INSERT') and not has_function_privilege('authenticated', 'public._client_email_for(text,text)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.trg_route_departure_notice()', 'EXECUTE'), '');
