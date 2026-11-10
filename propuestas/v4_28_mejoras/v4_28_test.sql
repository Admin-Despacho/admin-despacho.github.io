-- Pruebas de la PROPUESTA V4.28 (receptor DNI/CUIL/CUIT · gestiones de solo agregado · historial). Corre después de g2_revision_test. Datos FICTICIOS.
\set ON_ERROR_STOP on
\set A 'e0000000-0000-0000-0000-00000000000a'
\set S 'e0000000-0000-0000-0000-000000000005'
\set O 'e0000000-0000-0000-0000-000000000006'
\set G 'e0000000-0000-0000-0000-000000000007'
\set S2 'e0000000-0000-0000-0000-0000000000f8'
\set VH 'f0000000-0000-0000-0000-000000000001'
insert into auth.users(id, email) values (:'S2', 'v428.s2@t') on conflict do nothing;
select set_config('okd.sync', 'on', false);
insert into public.profiles(id, full_name, email, role, status) values (:'S2', 'Superior Otro Equipo 428', 'v428.s2@t', 'SUPERVISOR_DESPACHO', 'ACTIVO') on conflict (id) do nothing;
select set_config('okd.sync', '', false);
insert into public.user_permission_overrides(user_id, permission_code, granted) values (:'S', 'can_approve_internal_route_changes', true) on conflict do nothing;   -- la jerarquía exige que el Superior pueda aprobar
select set_config('okd.sync', 'on', false);
update public.profiles set supervisor_user_id = :'S' where id in (:'O', :'G');
select set_config('okd.sync', '', false);
create or replace function pg_temp.err(q text) returns text language plpgsql as $f$ begin execute q; return 'OK'; exception when others then return sqlerrm; end $f$;
create or replace function pg_temp.as(u text, q text) returns text language plpgsql as $f$ declare o text; begin perform tst.u(u::uuid); set local role authenticated; o := pg_temp.err(q); reset role; return o; end $f$;
create or replace function pg_temp.get(u text, q text) returns text language plpgsql as $f$ declare o text; begin perform tst.u(u::uuid); set local role authenticated; execute q into o; reset role; return o; exception when others then reset role; return 'ERR ' || sqlerrm; end $f$;
-- hoja interna con 10 pedidos comerciales (la publica el Operario del equipo de S; la ejecuta el Transportista Interno G)
begin; select tst.u(:'O'); set local role authenticated;
select public.reserve_orders('V428-A', array['84001','84002','84003','84004','84005','84006','84007','84008','84009','84010','84011','84012','84013','84014','84015','84016','84017','84018']);
create temp table ra as select * from public.publish_route(jsonb_build_object('sheet_key','V428-A','carrier_id','INTERNO','responsable_id',:'G','vehicle_id',:'VH','rules_version',1,'routing_rules_version',1,
  'stops', (select jsonb_agg(jsonb_build_object('client_name','Cliente ' || o,'client_key','CLI' || o,'address','Calle ' || o,'stop_type','PEDIDO','order_numbers',jsonb_build_array(o),'merchandise_amount',1000,'task','ENTREGA','ready',true) order by o)
            from unnest(array['84001','84002','84003','84004','84005','84006','84007','84008','84009','84010','84011','84012','84013','84014','84015','84016','84017','84018']) o))); grant select on ra to public;
commit;
create temp table st as select id, order_numbers[1] o from public.route_stops where route_id = (select id from ra); grant select on st to public;
begin; select tst.u(:'G'); set local role authenticated; select public.start_route((select id from ra), (select current_km from public.vehicles where id = 'f0000000-0000-0000-0000-000000000001') + 5); commit;
-- entrega con un documento dado (firma PNG válida mínima)
create or replace function pg_temp.ent(o text, outcome text, ev jsonb) returns text language plpgsql as $f$ begin return pg_temp.as('e0000000-0000-0000-0000-000000000007',
  format($q$ select public.set_stop_outcome(%L, %L, %L, null, %L, %L::jsonb) $q$, (select id from st where st.o = $1), outcome, case when outcome = 'ENTREGA_PARCIAL' then 'Quedó una tarea pendiente de revisión' end, 'op-' || $1,
    jsonb_build_object('location', jsonb_build_object('lat', -32.9, 'lon', -68.8), 'evidence', jsonb_build_object('receiver_name', 'Receptor QA', 'signature_png_b64', 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==') || ev)::text)); end $f$;
create temp table d as select pg_temp.ent('84001', 'ENTREGADO', '{"receiver_doc_type":"DNI","receiver_doc":"30.111.222"}') dni,
  pg_temp.ent('84002', 'ENTREGADO', '{"receiver_doc_type":"CUIL","receiver_doc":"20-12345678-6"}') cuil,
  pg_temp.ent('84003', 'ENTREGADO', '{"receiver_doc_type":"CUIT","receiver_doc":"30500010912"}') cuit,
  pg_temp.ent('84004', 'ENTREGADO', '{"receiver_doc_type":"DNI","receiver_doc":"123","receiver_doc_declared":"123"}') dni_malo,
  pg_temp.ent('84005', 'ENTREGADO', '{"receiver_doc_type":"CUIL","receiver_doc":"20123456787","receiver_doc_declared":"20-12345678-7"}') cuil_malo,
  pg_temp.ent('84006', 'ENTREGADO', '{"receiver_doc_type":"CUIT","receiver_doc":"3050001091"}') cuit_corto,
  pg_temp.ent('84007', 'ENTREGADO', '{"receiver_doc_type":"PASAPORTE","receiver_doc":"AB123456","receiver_doc_declared":"AB123456"}') tipo_malo,
  pg_temp.ent('84008', 'ENTREGADO', '{"cuil":"20111111112"}') anterior_en_cola,
  pg_temp.ent('84009', 'ENTREGA_PARCIAL', '{"receiver_doc_type":"DNI","receiver_doc":"28999888"}') parcial,
  pg_temp.ent('84011', 'ENTREGADO', '{"receiver_doc_type":"DNI","receiver_doc":"20123456786"}') dni_con_cuil,
  pg_temp.ent('84012', 'ENTREGADO', '{"receiver_doc_type":"CUIL","receiver_doc":"30500010912"}') cuil_de_empresa,
  pg_temp.ent('84013', 'ENTREGADO', '{"receiver_doc_type":"DNI","receiver_doc":""}') faltante;
grant select on d to public;
create or replace function pg_temp.ev(o text) returns text language sql as $f$ select coalesce(e.receiver_doc_type, '∅') || '|' || coalesce(e.receiver_cuil, '∅') || '|' || coalesce(e.receiver_dni, '∅') || '|' || coalesce(e.receiver_doc_valid::text, '∅') || '|' || coalesce(e.receiver_cuit, '∅')
  from public.stop_evidence e where e.stop_id = (select id from st where st.o = $1) $f$;
create or replace function pg_temp.rv(o text) returns text language sql as $f$ select coalesce(v.issue, '∅') || '|' || coalesce(v.declared_doc, '∅') || '|' || v.status from public.receiver_doc_reviews v where v.stop_id = (select id from st where st.o = $1) $f$;
create or replace function pg_temp.out(o text) returns text language sql as $f$ select outcome from public.route_stops where id = (select id from st where st.o = $1) $f$;
select tst.res('D-01 DNI válido: entrega OK, tipo DNI, número en receiver_dni, documento VÁLIDO y SIN incidencia', (select dni from d) = 'OK' and pg_temp.ev('84001') = 'DNI|∅|30111222|true|∅' and pg_temp.rv('84001') is null, (select dni from d) || ' · ' || coalesce(pg_temp.ev('84001'), '∅'));
select tst.res('D-02 CUIL válido: entrega OK, CUIL guardado, DNI derivado como antes, SIN incidencia', (select cuil from d) = 'OK' and pg_temp.ev('84002') = 'CUIL|20123456786|12345678|true|∅' and pg_temp.rv('84002') is null, coalesce(pg_temp.ev('84002'), '∅'));
select tst.res('D-03 CUIT válido (empresa): entrega OK, guardado en receiver_cuit (NUNCA en receiver_cuil), sin derivar DNI, SIN incidencia', (select cuit from d) = 'OK' and pg_temp.ev('84003') = 'CUIT|∅|∅|true|30500010912' and pg_temp.rv('84003') is null, coalesce(pg_temp.ev('84003'), '∅'));
select tst.res('D-04 documentos INCORRECTOS NO BLOQUEAN: DNI corto, CUIL con verificador inválido, CUIT corto, tipo inexistente, DNI con 11 dígitos y CUIL de empresa → entrega CONFIRMADA + INCIDENCIA con su motivo; nada se guarda como verificado',
  (select dni_malo = 'OK' and cuil_malo = 'OK' and cuit_corto = 'OK' and tipo_malo = 'OK' and dni_con_cuil = 'OK' and cuil_de_empresa = 'OK' from d)
  and pg_temp.out('84004') = 'ENTREGADO' and pg_temp.rv('84004') = 'DNI CON CANTIDAD DE DÍGITOS INCORRECTA|123|A_REVISAR' and pg_temp.ev('84004') = 'DNI|∅|∅|false|∅'
  and pg_temp.rv('84005') = 'CUIL CON DÍGITO VERIFICADOR INVÁLIDO|20-12345678-7|A_REVISAR' and pg_temp.ev('84005') like 'CUIL|∅|∅|false|∅'
  and pg_temp.rv('84006') like 'CUIT CON CANTIDAD DE DÍGITOS INCORRECTA|%' and pg_temp.rv('84007') = 'TIPO DE DOCUMENTO NO RECONOCIDO|AB123456|A_REVISAR'
  and pg_temp.rv('84011') like 'PARECE UN CUIL O CUIT: SE ELIGIÓ DNI|%' and pg_temp.rv('84012') like 'PREFIJO DE EMPRESA: PARECE UN CUIT|%'
  and (select receiver_doc_declared from public.stop_evidence where stop_id = (select id from st where o = '84005')) = '20-12345678-7',
  pg_temp.rv('84004') || ' · ' || pg_temp.rv('84005') || ' · ' || pg_temp.rv('84012'));
select tst.res('D-05 entrega ANTERIOR en cola sin conexión (solo «cuil», sin tipo): se acepta siempre (con incidencia si el número no valida)', (select anterior_en_cola from d) = 'OK' and pg_temp.out('84008') = 'ENTREGADO', (select anterior_en_cola from d) || ' · ' || coalesce(pg_temp.rv('84008'), 'sin incidencia'));
select tst.res('D-06 la FIRMA sigue siendo OBLIGATORIA: sin firma la entrega se rechaza (aunque el documento sea válido)', pg_temp.as(:'G', format($q$ select public.set_stop_outcome(%L, 'ENTREGADO', null, null, 'op-sinfirma', '{"location":{"lat":-32.9,"lon":-68.8},"evidence":{"receiver_name":"R","receiver_doc_type":"DNI","receiver_doc":"30111222"}}'::jsonb) $q$, (select id from st where o = '84010'))) <> 'OK'
  and not exists (select 1 from public.stop_evidence where stop_id = (select id from st where o = '84010')), '');
select tst.res('D-07 documento FALTANTE: entrega CONFIRMADA + incidencia «DOCUMENTO FALTANTE»', (select faltante from d) = 'OK' and pg_temp.out('84013') = 'ENTREGADO' and pg_temp.rv('84013') like 'DOCUMENTO FALTANTE|%|A_REVISAR', coalesce(pg_temp.rv('84013'), '∅'));
-- ===== ALERTAS =====
create temp table nalert as select (select count(*) from public.receiver_doc_reviews where route_id = (select id from ra)) inc,
  (select count(*) from public.notifications where type = 'RECEIVER_DOC_REVIEW' and route_id = (select id from ra) and user_id = 'e0000000-0000-0000-0000-00000000000a') adm,
  (select count(*) from public.notifications where type = 'RECEIVER_DOC_REVIEW' and route_id = (select id from ra) and user_id = 'e0000000-0000-0000-0000-000000000005') sup,
  (select count(*) from public.notifications where type = 'RECEIVER_DOC_REVIEW' and route_id = (select id from ra) and user_id = 'e0000000-0000-0000-0000-0000000000f8') otro,
  (select title from public.notifications where type = 'RECEIVER_DOC_REVIEW' and route_id = (select id from ra) limit 1) titulo,
  (select body from public.notifications where type = 'RECEIVER_DOC_REVIEW' and route_id = (select id from ra) limit 1) cuerpo;
grant select on nalert to public;
select tst.res('A-01 ALERTA «DOCUMENTO DEL RECEPTOR A REVISAR» al ADMINISTRADOR y al SUPERIOR responsable del transportista; NO a otro Superior; el aviso no expone el documento',
  (select adm = 1 and sup = 1 and otro = 0 and titulo = 'DOCUMENTO DEL RECEPTOR A REVISAR' from nalert) and (select cuerpo from nalert) like 'Hoja %Pedido%' and (select cuerpo from nalert) !~ '20123456787|30111222',
  (select inc || ' incidencias · ' || cuerpo from nalert));
select pg_temp.ent('84005', 'ENTREGADO', '{"receiver_doc_type":"CUIL","receiver_doc":"20123456787"}');   -- reintento de sincronización (mismo op_id)
select tst.res('A-02 SIN DUPLICADOS: el reintento de sincronización (mismo op_id) no crea otra incidencia ni otra alerta (una por entrega)',
  (select count(*) from public.receiver_doc_reviews where route_id = (select id from ra)) = (select inc from nalert) and (select count(*) from public.receiver_doc_reviews where stop_id = (select id from st where o = '84005')) = 1
  and (select count(*) from public.notifications where type = 'RECEIVER_DOC_REVIEW' and route_id = (select id from ra)) = (select adm + sup from nalert) + (select count(*) - 1 from public.profiles where role = 'ADMIN' and status = 'ACTIVO'), '');
create temp table lst as select pg_temp.get(:'S', $q$ select jsonb_array_length(public.list_receiver_doc_reviews('A_REVISAR'))::text $q$) s, pg_temp.get(:'S2', $q$ select jsonb_array_length(public.list_receiver_doc_reviews('A_REVISAR'))::text $q$) s2,
  pg_temp.get(:'A', $q$ select jsonb_array_length(public.list_receiver_doc_reviews('A_REVISAR'))::text $q$) a, pg_temp.get(:'O', $q$ select jsonb_array_length(public.list_receiver_doc_reviews('A_REVISAR'))::text $q$) o,
  pg_temp.get(:'S', $q$ select (public.list_receiver_doc_reviews('A_REVISAR')->0)::text $q$) fila;
grant select on lst to public;
select tst.res('A-03 ALCANCE: el Superior responsable y el Administrador ven las incidencias; OTRO Superior y el Operario NO; sin lectura directa de la tabla',
  (select s::int = (select inc from nalert) and a::int = (select inc from nalert) and s2 = '0' and o = '0' from lst) and pg_temp.as(:'S', 'select count(*) from public.receiver_doc_reviews') like '%permission denied%', (select 'S=' || s || ' A=' || a || ' S2=' || s2 || ' O=' || o from lst));
-- A-04: si la ALERTA falla, la entrega NO se deshace (la incidencia queda)
create or replace function pg_temp.boom() returns trigger language plpgsql as $f$ begin raise exception 'servicio de notificaciones caído'; end $f$;
create trigger zz_boom after insert on public.notifications for each row when (new.type = 'RECEIVER_DOC_REVIEW') execute function pg_temp.boom();
create temp table a4 as select pg_temp.as(:'G', format($q$ select public.set_stop_outcome(%L, 'ENTREGADO', null, null, 'op-a4', '{"location":{"lat":-32.9,"lon":-68.8},"evidence":{"receiver_name":"R","receiver_doc_type":"DNI","receiver_doc":"1","signature_png_b64":"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="}}'::jsonb) $q$,
  (select id from st where o = '84014'))) r; grant select on a4 to public;
drop trigger zz_boom on public.notifications;
select tst.res('A-04 si el servicio de notificaciones FALLA, la entrega NO se deshace: queda ENTREGADA con su incidencia (la alerta se omite)',
  (select r from a4) = 'OK' and pg_temp.out('84014') = 'ENTREGADO' and exists (select 1 from public.receiver_doc_reviews where stop_id = (select id from st where o = '84014')), (select r from a4));
-- ===== CORRECCIÓN ADMINISTRATIVA =====
create temp table c as select pg_temp.as(:'S2', format($q$ select public.correct_receiver_doc(%L, 'CUIL', '20123456786', 'otro equipo') $q$, (select id from st where o = '84005'))) otro,
  pg_temp.as(:'G', format($q$ select public.correct_receiver_doc(%L, 'CUIL', '20123456786', 'el chofer') $q$, (select id from st where o = '84005'))) chofer,
  pg_temp.as(:'S', format($q$ select public.correct_receiver_doc(%L, 'CUIL', '20123456787', 'sigue mal') $q$, (select id from st where o = '84005'))) invalida,
  pg_temp.as(:'S', format($q$ select public.correct_receiver_doc(%L, 'CUIL', '20123456786', '') $q$, (select id from st where o = '84005'))) sin_motivo,
  pg_temp.as(:'S', format($q$ select public.correct_receiver_doc(%L, 'CUIL', '20-12345678-6', 'El receptor confirmó su CUIL por teléfono') $q$, (select id from st where o = '84005'))) ok;
grant select on c to public;
select tst.res('C-01 CORRECCIÓN por el Superior responsable: CORREGIDO con quién, cuándo y por qué + auditoría; la EVIDENCIA ORIGINAL queda intacta (declarado, inválido, sin CUIL verificado)',
  (select ok from c) = 'OK' and pg_temp.rv('84005') = 'CUIL CON DÍGITO VERIFICADOR INVÁLIDO|20-12345678-7|CORREGIDO'
  and (select corrected_doc || '|' || corrected_by::text || '|' || correction_reason from public.receiver_doc_reviews where stop_id = (select id from st where o = '84005')) = '20123456786|' || :'S' || '|El receptor confirmó su CUIL por teléfono'
  and pg_temp.ev('84005') = 'CUIL|∅|∅|false|∅' and (select receiver_doc_declared from public.stop_evidence where stop_id = (select id from st where o = '84005')) = '20-12345678-7'
  and exists (select 1 from public.audit_log where action = 'RECEIVER_DOC_CORRECTED'), (select ok from c));
select tst.res('C-02 correcciones NO permitidas: otro Superior → FORBIDDEN · el chofer → FORBIDDEN · documento que sigue inválido → DOC_STILL_INVALID · sin motivo → REASON_REQUIRED',
  (select otro like 'FORBIDDEN%' and chofer like 'FORBIDDEN%' and invalida like 'DOC_STILL_INVALID%' and sin_motivo like 'REASON_REQUIRED%' from c), (select otro || ' · ' || chofer || ' · ' || invalida || ' · ' || sin_motivo from c));
-- ===== V4.28 (revisión): CUIT válido sin padrón personal · caracteres inesperados · rectificación con historial =====
create temp table x as select pg_temp.ent('84015', 'ENTREGADO', '{"receiver_doc_type":"DNI","receiver_doc":"30111222A","receiver_doc_declared":"30.111.222A"}') alfa,
  pg_temp.ent('84016', 'ENTREGADO', '{"receiver_doc_type":"CUIL","receiver_doc":"20 12345678 6","receiver_doc_declared":"20 12345678 6"}') espacios;
grant select on x to public;
select tst.res('I-01 CUIT VÁLIDO de empresa: entrega aceptada y guardada como CUIT, pero NO crea ni actualiza un perfil de identidad PERSONAL (customer_identity_docs); un CUIL válido sí, como antes',
  pg_temp.ev('84003') = 'CUIT|∅|∅|true|30500010912' and not exists (select 1 from public.customer_identity_docs where cuil = '30500010912')
  and exists (select 1 from public.customer_identity_docs where cuil = '20123456786'), coalesce((select string_agg(cuil, ',') from public.customer_identity_docs), '∅'));
select tst.res('X-01 CARACTERES INESPERADOS: «30.111.222A» NO bloquea (entrega confirmada) → incidencia «DOCUMENTO CON CARACTERES NO VÁLIDOS» y declarado guardado tal cual; «20 12345678 6» (espacios) se normaliza y es VÁLIDO',
  (select alfa from x) = 'OK' and pg_temp.out('84015') = 'ENTREGADO' and pg_temp.rv('84015') = 'DOCUMENTO CON CARACTERES NO VÁLIDOS|30.111.222A|A_REVISAR'
  and pg_temp.ev('84015') = 'DNI|∅|∅|false|∅' and (select espacios from x) = 'OK' and pg_temp.rv('84016') is null and pg_temp.ev('84016') like 'CUIL|20123456786|%|true|∅',
  (select alfa || ' · ' || espacios from x) || ' · ' || coalesce(pg_temp.rv('84015'), '∅'));
create temp table rc as select pg_temp.as(:'S', format($q$ select public.correct_receiver_doc(%L, 'CUIL', '20123456786', 'otra vez sin rectificar') $q$, (select id from st where o = '84005'))) sin_rectificar,
  pg_temp.as(:'S', format($q$ select public.correct_receiver_doc(%L, 'DNI', '12345678', 'Rectifico: el receptor presentó DNI', true) $q$, (select id from st where o = '84005'))) rectifica,
  pg_temp.as(:'S', format($q$ select public.correct_receiver_doc(%L, 'DNI', '30111222', 'nada corregido aún', true) $q$, (select id from st where o = '84015'))) nada;
grant select on rc to public;
select tst.res('R-01 DOBLE CORRECCIÓN: sin RECTIFICAR → ALREADY_CORRECTED (no sobrescribe); RECTIFICAR con motivo agrega la entrada 2 y CONSERVA la 1; rectificar algo nunca corregido → NOTHING_TO_RECTIFY; auditoría de ambas',
  (select sin_rectificar like 'ALREADY_CORRECTED%' and rectifica = 'OK' and nada like 'NOTHING_TO_RECTIFY%' from rc)
  and (select string_agg(seq || ':' || corrected_type || ':' || corrected_doc || ':' || is_rectification, ' ' order by seq) from public.receiver_doc_corrections where stop_id = (select id from st where o = '84005'))
      = '1:CUIL:20123456786:false 2:DNI:12345678:true'
  and (select corrected_type || '|' || corrected_doc from public.receiver_doc_reviews where stop_id = (select id from st where o = '84005')) = 'DNI|12345678'
  and exists (select 1 from public.audit_log where action = 'RECEIVER_DOC_RECTIFIED') and exists (select 1 from public.audit_log where action = 'RECEIVER_DOC_CORRECTED'),
  (select sin_rectificar || ' · ' || rectifica || ' · ' || nada from rc));
select tst.res('R-02 el HISTORIAL de correcciones es INALTERABLE: no se modifica ni se borra (ni siquiera el superusuario)',
  pg_temp.err('update public.receiver_doc_corrections set corrected_doc = ''x''') like 'APPEND_ONLY%' and pg_temp.err('delete from public.receiver_doc_corrections') like 'APPEND_ONLY%', '');
create or replace function pg_temp.j(t text) returns jsonb language plpgsql as $f$ begin return t::jsonb; exception when others then return jsonb_build_object('error', t); end $f$;
-- ===== V4.28 (revisión 2): CUIT ≠ CUIL en autocompletado y buscador =====
update public.route_stops set client_key = 'CLI84017' where id = (select id from st where o = '84010');   -- 84010 (pendiente) es del MISMO cliente que 84017
create temp table k as select pg_temp.ent('84017', 'ENTREGADO', '{"receiver_doc_type":"CUIT","receiver_doc":"30-50001091-2","email":"compras@empresa.qa"}') r; grant select on k to public;
create temp table lk as select pg_temp.get(:'G', format($q$ select public.delivery_identity_lookup(%L, null, null)::text $q$, (select id from st where o = '84010'))) cliente,
  pg_temp.get(:'G', format($q$ select public.delivery_identity_lookup(%L, '30500010912', null)::text $q$, (select id from st where o = '84010'))) con_cuit; grant select on lk to public;
select tst.res('K-01 AUTOCOMPLETADO: la entrega anterior del MISMO cliente con CUIT devuelve nombre y email, pero NUNCA el CUIT como «cuil»; consultar con un CUIT no usa el padrón personal',
  (select r from k) = 'OK' and pg_temp.ev('84017') = 'CUIT|∅|∅|true|30500010912' and pg_temp.j((select cliente from lk))->>'email' = 'compras@empresa.qa' and pg_temp.j((select cliente from lk))->>'cuil' is null
  and coalesce(pg_temp.j((select con_cuit from lk))->>'source', '') <> 'CUIL' and pg_temp.j((select con_cuit from lk))->>'cuil' is null, (select cliente || ' · ' || coalesce(con_cuit, '∅') from lk));
-- registro HISTÓRICO (anterior a V4.28: solo se controlaba la longitud) con un CUIT dentro de receiver_cuil y sin tipo
set session_replication_role = replica;
update public.stop_evidence set receiver_cuil = '30500010912', receiver_cuit = null, receiver_doc_type = null, receiver_doc_valid = null where stop_id = (select id from st where o = '84017');
set session_replication_role = origin;
select tst.res('K-02 HISTÓRICO con un CUIT guardado como CUIL: el autocompletado tampoco lo devuelve como «cuil» (solo CUIL con prefijo de persona)',
  pg_temp.get(:'G', format($q$ select ((public.delivery_identity_lookup(%L, null, null)->>'cuil') is null)::text $q$, (select id from st where o = '84010'))) = 'true', '');
set session_replication_role = replica;
update public.stop_evidence set receiver_cuil = null, receiver_cuit = '30500010912', receiver_doc_type = 'CUIT', receiver_doc_valid = true where stop_id = (select id from st where o = '84017');
set session_replication_role = origin;
create temp table sd as select pg_temp.get(:'S', $q$ select (select x::text from jsonb_array_elements(public.search_deliveries('84017')) x limit 1) $q$) j,
  pg_temp.get(:'O', $q$ select (select x::text from jsonb_array_elements(public.search_deliveries('84017')) x limit 1) $q$) sin_permiso; grant select on sd to public;
select tst.res('K-03 BUSCAR ENTREGA: con permiso de firmas devuelve tipo CUIT y el CUIT (receiver_cuil vacío); sin ese permiso NO devuelve documento alguno',
  pg_temp.j((select j from sd))->>'receiver_doc_type' = 'CUIT' and pg_temp.j((select j from sd))->>'receiver_cuit' = '30500010912' and pg_temp.j((select j from sd))->>'receiver_cuil' is null
  and coalesce(pg_temp.j((select sin_permiso from sd))->>'receiver_cuit', '') = '' and coalesce(pg_temp.j((select sin_permiso from sd))->>'receiver_doc_declared', '') = '', left(coalesce((select j from sd), '∅'), 220) || ' · ' || left(coalesce((select sin_permiso from sd), '∅'), 80));
-- ===== permisos VIGENTES para corregir =====
create or replace function pg_temp.cor(u text, o text) returns text language sql as $f$ select pg_temp.as(u, format($q$ select public.correct_receiver_doc(%L, 'CUIT', '30500010912', 'Corrección de prueba') $q$, (select id from st where st.o = $2))) $f$;
create or replace function pg_temp.n(u text) returns text language sql as $f$ select pg_temp.get(u, $q$ select jsonb_array_length(public.list_receiver_doc_reviews('TODOS'))::text $q$) $f$;
select set_config('okd.sync', 'on', false); update public.profiles set role = 'OPERARIO_DEPOSITO' where id = :'S'; select set_config('okd.sync', '', false);
create temp table p1 as select pg_temp.cor(:'S', '84006') cor, pg_temp.n(:'S') n; grant select on p1 to public;
select set_config('okd.sync', 'on', false); update public.profiles set role = 'SUPERVISOR_DESPACHO' where id = :'S'; update public.profiles set status = 'DESHABILITADO' where id = :'S'; select set_config('okd.sync', '', false);
create temp table p2 as select pg_temp.cor(:'S', '84006') cor; grant select on p2 to public;
select set_config('okd.sync', 'on', false); update public.profiles set status = 'ACTIVO' where id = :'S'; select set_config('okd.sync', '', false);
select tst.res('P-01 SUPERIOR AL QUE SE LE CAMBIÓ EL ROL (ahora Operario): aunque figura como Superior del transportista NO corrige (FORBIDDEN) ni ve incidencias',
  (select cor like 'FORBIDDEN%' and n = '0' from p1), (select cor || ' · ve ' || n from p1));
select tst.res('P-02 SUPERIOR DESHABILITADO: NO corrige', (select cor from p2) like 'FORBIDDEN%', (select cor from p2));
insert into public.user_permission_overrides(user_id, permission_code, granted) values (:'S2', 'can_approve_internal_route_changes', true) on conflict do nothing;
select set_config('okd.sync', 'on', false); update public.profiles set supervisor_user_id = :'S2' where id = :'G'; select set_config('okd.sync', '', false);
create temp table p3 as select pg_temp.cor(:'S', '84006') anterior, pg_temp.n(:'S') ve_anterior, pg_temp.n(:'S2') ve_nuevo, pg_temp.cor(:'S2', '84006') nuevo; grant select on p3 to public;
select tst.res('P-03 CAMBIO DE SUPERIOR ASIGNADO: el ANTERIOR pierde el acceso (no ve ni corrige); el NUEVO Superior asignado lo obtiene y corrige con auditoría',
  (select anterior like 'FORBIDDEN%' and ve_anterior = '0' and ve_nuevo::int > 0 and nuevo = 'OK' from p3)
  and (select corrected_by from public.receiver_doc_reviews where stop_id = (select id from st where o = '84006')) = :'S2', (select anterior || ' · ' || ve_anterior || ' · ' || ve_nuevo || ' · ' || nuevo from p3));
select set_config('okd.sync', 'on', false); update public.profiles set supervisor_user_id = :'S' where id = :'G'; select set_config('okd.sync', '', false);
select tst.res('C-03 el documento DECLARADO y su advertencia son INALTERABLES: no se modifican ni se borran (ni siquiera el superusuario)',
  pg_temp.err('update public.receiver_doc_reviews set declared_doc = ''x''') like 'APPEND_ONLY%' and pg_temp.err('delete from public.receiver_doc_reviews') like 'APPEND_ONLY%', '');
-- ===== GESTIONES (solo agregado) =====
create temp table s9 as select id from st where o = '84009'; grant select on s9 to public;
create temp table f1 as select pg_temp.as(:'O', format($q$ select public.add_stop_followup(%L, 'GESTION', 'Se coordinó con el cliente la entrega del faltante', null, 'fu-1') $q$, (select id from s9))) ok,
  pg_temp.as(:'O', format($q$ select public.add_stop_followup(%L, 'GESTION', 'Se coordinó con el cliente la entrega del faltante', null, 'fu-1') $q$, (select id from s9))) reintento,
  pg_temp.as(:'G', format($q$ select public.add_stop_followup(%L, 'OBSERVACION', 'nota del chofer', null, null) $q$, (select id from s9))) chofer,
  pg_temp.as(:'S2', format($q$ select public.add_stop_followup(%L, 'INCIDENCIA', 'otro equipo', null, null) $q$, (select id from s9))) otro_equipo,
  pg_temp.as(:'O', format($q$ select public.add_stop_followup(%L, 'GESTION', 'x', null, null) $q$, (select id from s9))) sin_motivo;
grant select on f1 to public;
select tst.res('F-01 GESTIÓN posterior registrada (Operario con permiso, hoja a su alcance) · el reintento con el mismo op_id NO duplica · queda en auditoría',
  (select ok from f1) = 'OK' and (select reintento from f1) = 'OK' and (select count(*) from public.stop_followups where stop_id = (select id from s9)) = 1
  and exists (select 1 from public.audit_log where action = 'STOP_FOLLOWUP_GESTION' and target_id = (select id::text from ra)), '');
select tst.res('F-02 sin permiso o fuera de alcance NO registra: Transportista → FORBIDDEN · Superior de otro equipo → FORBIDDEN_ROUTE · motivo vacío → NOTE_REQUIRED',
  (select chofer from f1) like 'FORBIDDEN%' and (select otro_equipo from f1) like 'FORBIDDEN_ROUTE%' and (select sin_motivo from f1) like 'NOTE_REQUIRED%', (select chofer || ' · ' || otro_equipo || ' · ' || sin_motivo from f1));
select tst.res('F-03 historial INALTERABLE: ni modificar ni borrar (ni siquiera el superusuario) · sin escritura directa para usuarios',
  pg_temp.err('update public.stop_followups set note = ''cambiada''') like 'APPEND_ONLY%' and pg_temp.err('delete from public.stop_followups') like 'APPEND_ONLY%'
  and pg_temp.as(:'O', format($q$ insert into public.stop_followups(route_id, stop_id, kind, note, created_by) values (%L, %L, 'GESTION', 'directo', %L) $q$, (select id from ra), (select id from s9), 'e0000000-0000-0000-0000-000000000006')) like '%permission denied%', '');
-- solicitud de REPROGRAMACIÓN por el circuito EXISTENTE (tipo OTRO, sin efectos automáticos) + gestión enlazada
create temp table rq as select pg_temp.get(:'O', format($q$ select (public.create_operational_request(jsonb_build_object('request_type', 'OTRO', 'route_id', %L, 'reason', 'Reprogramar el faltante de Cliente 84009',
  'op_id', 'rq-428-1', 'payload', jsonb_build_object('origen', 'VER_HOJA', 'accion', 'SOLICITAR REPROGRAMACIÓN', 'parada', 'Cliente 84009', 'stop_id', %L, 'resultado_actual', 'ENTREGA_PARCIAL')))).id::text $q$, (select id from ra), (select id from s9))) id;
grant select on rq to public;
create temp table f2 as select pg_temp.as(:'O', format($q$ select public.add_stop_followup(%L, 'SOLICITUD', 'Solicitada la reprogramación del faltante', %L, 'fu-2') $q$, (select id from s9), (select id from rq))) enlace,
  pg_temp.as(:'O', format($q$ select public.add_stop_followup(%L, 'SOLICITUD', 'enlace a solicitud inexistente', gen_random_uuid(), null) $q$, (select id from s9))) enlace_malo;
grant select on f2 to public;
select tst.res('F-04 REPROGRAMACIÓN: solicitud PENDIENTE dirigida al Superior del equipo (circuito existente) + gestión SOLICITUD enlazada; un enlace ajeno o inexistente se rechaza',
  (select status from public.route_approval_requests where id = (select id from rq)::uuid) = 'PENDING' and (select supervisor_user_id from public.route_approval_requests where id = (select id from rq)::uuid) = :'S'
  and (select enlace from f2) = 'OK' and (select enlace_malo from f2) like 'BAD_REQUEST_LINK%'
  and exists (select 1 from public.notifications where user_id = :'S' and type = 'REQUEST_CREATED'), (select enlace || ' · ' || enlace_malo from f2));
-- el Superior la APRUEBA por el circuito existente; la aprobación NO cambia el resultado de la parada
select pg_temp.as(:'S', format($q$ select public.resolve_operational_request(%L, 'APPROVED', 'Reprogramar para el lunes', 'res-428-1') $q$, (select id from rq)));
select tst.res('P-01 el resultado ORIGINAL nunca cambia: la parada sigue ENTREGA_PARCIAL con su observación tras gestiones, solicitud y aprobación',
  (select outcome from public.route_stops where id = (select id from s9)) = 'ENTREGA_PARCIAL' and (select outcome_note from public.route_stops where id = (select id from s9)) = 'Quedó una tarea pendiente de revisión', '');
create temp table h as select pg_temp.get(:'O', format('select public.route_change_history(%L)::text', (select id from ra))) j, pg_temp.get(:'S2', format('select public.route_change_history(%L)::text', (select id from ra))) otro;
grant select on h to public;
select tst.res('H-01 HISTORIAL DE CAMBIOS (servidor): resultado original PARCIAL con su motivo, la GESTIÓN, la SOLICITUD con su estado APROBADA y QUIÉN la resolvió, y la observación de la resolución',
  ((select j from h) like '%RESULTADO ORIGINAL%' and (select j from h) like '%ENTREGA_PARCIAL%' and (select j from h) like '%Quedó una tarea pendiente de revisión%')
  and (select j from h) like '%Se coordinó con el cliente%' and (select j from h) like '%SOLICITAR REPROGRAMACIÓN%' and (select j from h) like '%APPROVED%' and (select j from h) like '%Reprogramar para el lunes%', left((select j from h), 260));
select tst.res('H-03 HISTORIAL: «DOCUMENTO DEL RECEPTOR A REVISAR» con su motivo, quién corrigió y por qué, SIN exponer números de documento',
  (select j from h) like '%DOCUMENTO DEL RECEPTOR A REVISAR%' and (select j from h) like '%DÍGITO VERIFICADOR INVÁLIDO%' and (select j from h) like '%confirmó su CUIL por teléfono%' and (select j from h) not like '%20123456787%'
  and (select j from h) like '%CORRECCIÓN DEL DOCUMENTO%' and (select j from h) like '%RECTIFICACIÓN DEL DOCUMENTO%' and (select j from h) like '%presentó DNI%', '');
select tst.res('H-02 el historial NO se muestra a un Superior de otro equipo (FORBIDDEN_ROUTE)', (select otro from h) like 'ERR FORBIDDEN_ROUTE%', (select otro from h));
-- ===== B2 (auditoría de Work): el op_id SOLO devuelve un reintento con el mismo autor, la misma parada y la misma operación =====
create temp table b2 as select pg_temp.get(:'O', format($q$ select to_jsonb(public.add_stop_followup(%L, 'GESTION', 'otra parada', null, 'fu-1'))::text $q$, (select id from st where o = '84004'))) otra_parada,
  pg_temp.get(:'O', format($q$ select to_jsonb(public.add_stop_followup(%L, 'OBSERVACION', 'otro tipo', null, 'fu-1'))::text $q$, (select id from s9))) otro_tipo,
  pg_temp.get(:'S', format($q$ select to_jsonb(public.add_stop_followup(%L, 'GESTION', 'mismo equipo, otro autor', null, 'fu-1'))::text $q$, (select id from s9))) otro_autor,
  pg_temp.get(:'O', format($q$ select to_jsonb(public.add_stop_followup(%L, 'GESTION', 'Se coordinó con el cliente la entrega del faltante', null, 'fu-1'))::text $q$, (select id from s9))) legitimo;
grant select on b2 to public;
select tst.res('B2-01 MISMO autor con su op_id en OTRA parada u OTRO tipo → OP_ID_CONFLICT SIN datos de la gestión; no se crea otra',
  (select otra_parada like 'ERR OP_ID_CONFLICT%' and otro_tipo like 'ERR OP_ID_CONFLICT%' and otra_parada not like '%coordinó%' and otro_tipo not like '%coordinó%' from b2)
  and (select count(*) from public.stop_followups where op_id = 'fu-1') = 1, (select otra_parada || ' · ' || otro_tipo from b2));
select tst.res('B2-02 OTRO usuario del MISMO equipo (con alcance sobre la hoja) que reutiliza un op_id ajeno NO obtiene la gestión (OP_ID_CONFLICT); el reintento LEGÍTIMO del autor sí la devuelve, sin duplicar',
  (select otro_autor like 'ERR OP_ID_CONFLICT%' and otro_autor not like '%coordinó%' and legitimo like '%"op_id": "fu-1"%' from b2) and (select count(*) from public.stop_followups where op_id = 'fu-1') = 1,
  (select otro_autor || ' · legítimo: ' || left(legitimo, 60) from b2));
select tst.res('V-01 privilegios: anon no ejecuta las funciones nuevas; trg inmutable no invocable',
  not has_function_privilege('anon', 'public.add_stop_followup(uuid,text,text,uuid,text)', 'EXECUTE') and not has_function_privilege('anon', 'public.route_change_history(uuid)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.trg_stop_followups_immutable()', 'EXECUTE'), '');
