-- Pruebas de la PROPUESTA V4.25 (inspecciones de vehículos). Corre DESPUÉS de g2_revision_test. Datos FICTICIOS.
\set ON_ERROR_STOP on
\set A 'e0000000-0000-0000-0000-00000000000a'
\set S 'e0000000-0000-0000-0000-000000000005'
\set O 'e0000000-0000-0000-0000-000000000006'
\set G 'e0000000-0000-0000-0000-000000000007'
\set S2 'e0000000-0000-0000-0000-0000000000e2'
\set VH 'f0000000-0000-0000-0000-000000000001'
insert into auth.users(id, email) values (:'S2', 'insp.s2@t') on conflict do nothing;
select set_config('okd.sync', 'on', false);
insert into public.profiles(id, full_name, email, role, status) values (:'S2', 'Superior Otro Equipo', 'insp.s2@t', 'SUPERVISOR_DESPACHO', 'ACTIVO') on conflict (id) do nothing;
update public.profiles set supervisor_user_id = :'S' where id = :'O';
select set_config('okd.sync', '', false);
create or replace function pg_temp.items(res text) returns jsonb language sql as $f$ select jsonb_agg(jsonb_build_object('n', g, 'result', res)) from generate_series(1, 30) g $f$;
select tst.res('I-01 catálogo: los 30 controles EXACTOS del Excel R SE 4.5.1-05 (número, categoría y texto)',
  (select string_agg(item_no || '|' || category || '|' || label, ';' order by item_no) from public.vehicle_inspection_controls) = '1|DOCUMENTACIÓN|Poliza de Seguro + Último Recibo de Pago;2|DOCUMENTACIÓN|Tarjeta Verde;3|DOCUMENTACIÓN|Listado de Conductores Autorizados;4|DOCUMENTACIÓN|Registro del último mantenimiento (Cam. de Aceite);5|DOCUMENTACIÓN|Copia de ultima verificación tecnica (RTO);6|ELEMENTOS DE SEGURIDAD|Extintor Cargado + Fecha de Vencimiento;7|ELEMENTOS DE SEGURIDAD|Botiquín;8|ELEMENTOS DE SEGURIDAD|Gato hidráulico, llave cruz y rueda de auxilio;9|ELEMENTOS DE SEGURIDAD|Cinturon de Seguridad;10|ELEMENTOS DE SEGURIDAD|Apoya-cabezas;11|ELEMENTOS DE SEGURIDAD|Freno de Mano;12|ELEMENTOS DE SEGURIDAD|Balizas Tipo Triángulo;13|LUCES Y SEÑALES|Luz Alta y baja;14|LUCES Y SEÑALES|Luz de Posición;15|LUCES Y SEÑALES|Luz de Giro;16|LUCES Y SEÑALES|Balizas;17|LUCES Y SEÑALES|Luz de Freno;18|LUCES Y SEÑALES|Luz Interior;19|LUCES Y SEÑALES|Chapa Patente delantera y trasera;20|LUCES Y SEÑALES|Bocina;21|MECÁNICA Y ESTADO GENERAL|Espejos Retovisores;22|MECÁNICA Y ESTADO GENERAL|Cierre de Puertas, capot, compuertas;23|MECÁNICA Y ESTADO GENERAL|Higiene General;24|MECÁNICA Y ESTADO GENERAL|Estado de Cubiertas;25|MECÁNICA Y ESTADO GENERAL|Nivel Aceite Motor;26|MECÁNICA Y ESTADO GENERAL|Nivel de Liquido refrigerante;27|MECÁNICA Y ESTADO GENERAL|Nivel de Liquido Limpia Parabrisas;28|MECÁNICA Y ESTADO GENERAL|Parabrisas en condiciones aceptables;29|MECÁNICA Y ESTADO GENERAL|Calefactor/ Desempañador en buen funcionamiento;30|MECÁNICA Y ESTADO GENERAL|Estado General de Carrocería', (select count(*)::text from public.vehicle_inspection_controls));
begin; select tst.u(:'G'); set local role authenticated;
select tst.expect('I-02 el TRANSPORTISTA no realiza inspecciones', $q$ select public.inspection_save_draft(jsonb_build_object('client_id', gen_random_uuid(), 'vehicle_id', 'f0000000-0000-0000-0000-000000000001')) $q$, 'FORBIDDEN%');
commit;
-- ===== Operario: borrador → envío =====
begin; select tst.u(:'O'); set local role authenticated;
create temp table c1 as select gen_random_uuid() cid; grant select on c1 to public;
create temp table i1 as select * from public.inspection_save_draft(jsonb_build_object('client_id', (select cid from c1), 'vehicle_id', :'VH', 'items', jsonb_build_array(jsonb_build_object('n', 1, 'result', 'BIEN')))); grant select on i1 to public;
create temp table i1b as select * from public.inspection_save_draft(jsonb_build_object('client_id', (select cid from c1), 'vehicle_id', :'VH', 'items', jsonb_build_array(jsonb_build_object('n', 2, 'result', 'BIEN')))); grant select on i1b to public;
select tst.expect('I-04 enviar INCOMPLETA → INCOMPLETE', format($q$ select public.inspection_submit(%L) $q$, (select id from i1)), 'KM_REQUIRED%');
select public.inspection_save_draft(jsonb_build_object('client_id', (select cid from c1), 'vehicle_id', :'VH', 'km', 50500));
select tst.expect('I-04b enviar con controles SIN responder → INCOMPLETE', format($q$ select public.inspection_submit(%L) $q$, (select id from i1)), 'INCOMPLETE%');
select public.inspection_save_draft(jsonb_build_object('client_id', (select cid from c1), 'vehicle_id', :'VH', 'km', 50500, 'items', pg_temp.items('BIEN') || jsonb_build_array(jsonb_build_object('n', 7, 'result', 'MAL'))));
select tst.expect('I-05 control MAL sin FALTANTE/MAL ESTADO ni observación → ANOMALY_INCOMPLETE', format($q$ select public.inspection_submit(%L) $q$, (select id from i1)), 'ANOMALY_INCOMPLETE%');
select public.inspection_save_draft(jsonb_build_object('client_id', (select cid from c1), 'vehicle_id', :'VH', 'km', 50500, 'items', jsonb_build_array(
  jsonb_build_object('n', 7, 'result', 'MAL', 'defect', 'FALTANTE', 'observation', 'No hay botiquín'), jsonb_build_object('n', 24, 'result', 'MAL', 'defect', 'MAL_ESTADO', 'observation', 'Cubierta trasera gastada'),
  jsonb_build_object('n', 18, 'result', 'NO_APLICA'), jsonb_build_object('n', 1, 'result', 'BIEN', 'extra_date', '2027-03-31'), jsonb_build_object('n', 4, 'result', 'BIEN', 'extra_km', 48000))));
select public.inspection_submit((select id from i1)); select public.inspection_submit((select id from i1));   -- doble envío
select tst.expect('I-08 el OPERARIO no aprueba', format($q$ select public.inspection_review(%L, 'APROBADA', null) $q$, (select id from i1)), 'FORBIDDEN%');
select tst.expect('I-08b el OPERARIO no escribe directo en la tabla', format($q$ update public.vehicle_inspections set status = 'APROBADA' where id = %L $q$, (select id from i1)), '%permission denied%');
create temp table vis_o as select count(*) n from public.vehicle_inspections; grant select on vis_o to public;
commit;
select tst.res('I-03 borrador SIN duplicados (mismo client_id) con número INS-xxxxxx y evento CREADA',
  (select id from i1) = (select id from i1b) and (select number from i1) ~ '^INS-[0-9]{6}$' and (select count(*) from public.vehicle_inspection_events where inspection_id = (select id from i1) and action = 'CREADA') = 1, (select number from i1));
select tst.res('I-07 ENVIADA: PENDIENTE con 2 anomalías; doble envío no duplica; UNA notificación al Superior del equipo con enlace directo; snapshot de patente, km, marca y responsable del sistema',
  (select status = 'PENDIENTE' and anomalies = 2 and plate is not null and km = 50500 and created_by = 'e0000000-0000-0000-0000-000000000006' and created_by_name is not null and team_supervisor_id = 'e0000000-0000-0000-0000-000000000005' from public.vehicle_inspections where id = (select id from i1))
  and (select count(*) from public.notifications where inspection_id = (select id from i1) and user_id = 'e0000000-0000-0000-0000-000000000005' and type = 'INSPECTION_PENDING') = 1
  and (select count(*) from public.vehicle_inspection_events where inspection_id = (select id from i1) and action = 'ENVIADA') = 1
  and (select count(*) from public.vehicle_inspection_items where inspection_id = (select id from i1) and item_no = 1 and extra_date = '2027-03-31') = 1, '');
-- ===== otro Superior (otro equipo) =====
begin; select tst.u(:'S2'); set local role authenticated;
create temp table vis_s2 as select count(*) n from public.vehicle_inspections where id = (select id from i1); grant select on vis_s2 to public;
select tst.expect('I-09 un Superior de OTRO equipo no decide', format($q$ select public.inspection_review(%L, 'APROBADA', null) $q$, (select id from i1)), 'FORBIDDEN%');
commit;
select tst.res('I-09b RLS: el Superior de otro equipo NO ve la inspección; el Operario ve solo las suyas', (select n from vis_s2) = 0 and (select n from vis_o) = 1, '');
-- ===== Superior del equipo: rechazo =====
begin; select tst.u(:'S'); set local role authenticated;
select tst.expect('I-10 rechazar SIN motivo → REASON_REQUIRED', format($q$ select public.inspection_review(%L, 'RECHAZADA', '  ') $q$, (select id from i1)), 'REASON_REQUIRED%');
select tst.expect('I-15a email de una inspección NO aprobada → BAD_STATE', format($q$ select public.inspection_email_request(%L, array['jefe@ok.test'], 'x', 'y') $q$, (select id from i1)), 'BAD_STATE%');
select public.inspection_review((select id from i1), 'RECHAZADA', 'Falta botiquín: reponer y volver a inspeccionar');
select public.inspection_review((select id from i1), 'RECHAZADA', 'otra vez');
select tst.expect('I-10b una inspección RECHAZADA no se puede aprobar después', format($q$ select public.inspection_review(%L, 'APROBADA', null) $q$, (select id from i1)), 'ALREADY_REVIEWED%');
commit;
select tst.res('I-10c RECHAZADA con motivo, usuario y fecha del sistema; UNA notificación al Operario; el reintento no duplica',
  (select status = 'RECHAZADA' and reviewed_by = 'e0000000-0000-0000-0000-000000000005' and reviewed_at is not null and reject_reason like 'Falta botiquín%' from public.vehicle_inspections where id = (select id from i1))
  and (select count(*) from public.notifications where inspection_id = (select id from i1) and user_id = 'e0000000-0000-0000-0000-000000000006' and type = 'INSPECTION_RECHAZADA') = 1
  and (select count(*) from public.vehicle_inspection_events where inspection_id = (select id from i1) and action = 'RECHAZADA') = 1, '');
-- ===== nueva revisión (la original queda intacta) =====
begin; select tst.u(:'O'); set local role authenticated;
create temp table r2 as select * from public.inspection_new_revision((select id from i1), gen_random_uuid()); grant select on r2 to public;
create temp table late as select * from public.inspection_save_draft(jsonb_build_object('client_id', (select cid from c1), 'vehicle_id', :'VH', 'km', 1, 'items', jsonb_build_array(jsonb_build_object('n', 7, 'result', 'BIEN')))); grant select on late to public;
commit;
select tst.res('I-11 NUEVA REVISIÓN de la rechazada: mismo número, revisión 2, controles copiados, BORRADOR; la ORIGINAL intacta (RECHAZADA, sus 30 controles y su motivo)',
  (select number from r2) = (select number from i1) and (select revision from r2) = 2 and (select status from r2) = 'BORRADOR' and (select parent_id from r2) = (select id from i1)
  and (select count(*) from public.vehicle_inspection_items where inspection_id = (select id from r2)) = 30
  and (select status from public.vehicle_inspections where id = (select id from i1)) = 'RECHAZADA' and (select count(*) from public.vehicle_inspection_events where action = 'REVISION_CREADA') = 2, '');
select tst.res('I-14 un guardado TARDÍO (sin conexión) sobre una inspección ya enviada NO la modifica',
  (select km from public.vehicle_inspections where id = (select id from i1)) = 50500 and (select result from public.vehicle_inspection_items where inspection_id = (select id from i1) and item_no = 7) = 'MAL', '');
select tst.expect('I-13 nadie modifica los controles de una inspección enviada (ni por fuera de las funciones)', format($q$ update public.vehicle_inspection_items set result = 'BIEN' where inspection_id = %L and item_no = 7 $q$, (select id from i1)), 'INSPECTION_LOCKED%');
-- ===== Superior: inspección propia y AUTOAPROBACIÓN =====
begin; select tst.u(:'S'); set local role authenticated;
create temp table i3 as select * from public.inspection_save_draft(jsonb_build_object('client_id', gen_random_uuid(), 'vehicle_id', :'VH', 'km', 50600, 'items', pg_temp.items('BIEN'))); grant select on i3 to public;
select public.inspection_submit((select id from i3)); select public.inspection_review((select id from i3), 'APROBADA', null);
select tst.expect('I-15b email con destinatario inválido → EMAIL_INVALID', format($q$ select public.inspection_email_request(%L, array['no-es-email'], 'x', 'y') $q$, (select id from i3)), 'EMAIL_INVALID%');
create temp table em_before as select count(*) n from public.vehicle_inspection_email_requests; grant select on em_before to public;
select public.inspection_email_request((select id from i3), array['gerencia@ok.test'], 'Inspección aprobada', 'Detalle de prueba');
commit;
select tst.res('I-12 AUTOAPROBACIÓN del Superior: completó, envió y aprobó la suya (sin notificarse a sí mismo; el registro indica que fue propia)',
  (select status = 'APROBADA' and created_by = reviewed_by from public.vehicle_inspections where id = (select id from i3))
  and (select count(*) from public.notifications where inspection_id = (select id from i3)) = 0 and (select (detail->>'self')::boolean from public.vehicle_inspection_events where inspection_id = (select id from i3) and action = 'APROBADA'), '');
select tst.res('I-15 email: la APROBACIÓN no genera ningún email; se registra SOLO al pedirlo explícitamente (1 pedido + evento)', (select n from em_before) = 0
  and (select count(*) from public.vehicle_inspection_email_requests) = 1 and (select count(*) from public.vehicle_inspection_events where inspection_id = (select id from i3) and action = 'EMAIL_SOLICITADO') = 1, '');
begin; select tst.u(:'O'); set local role authenticated;
select tst.expect('I-15c el OPERARIO no envía emails a superiores', format($q$ select public.inspection_email_request(%L, array['x@ok.test'], 'x', 'y') $q$, (select id from i3)), 'FORBIDDEN%');
create temp table vis_o2 as select count(*) n from public.vehicle_inspections where id = (select id from i3); grant select on vis_o2 to public;
commit;
begin; select tst.u(:'A'); set local role authenticated;
create temp table vis_a as select count(*) n from public.vehicle_inspections; grant select on vis_a to public;
select tst.expect('I-16b el ADMINISTRADOR consulta pero NO aprueba', format($q$ select public.inspection_review(%L, 'APROBADA', null) $q$, (select id from r2)), 'FORBIDDEN%');
commit;
select tst.res('I-16 RLS: el Operario NO ve la inspección del Superior; el Administrador ve TODAS', (select n from vis_o2) = 0 and (select n from vis_a) = 3, '');
select tst.res('I-17 privilegios: anon sin acceso; authenticated sin INSERT/UPDATE/DELETE directos (solo funciones)',
  not exists (select 1 from unnest(array['vehicle_inspections','vehicle_inspection_items','vehicle_inspection_events','vehicle_inspection_controls','vehicle_inspection_email_requests']) t, unnest(array['SELECT','INSERT','UPDATE','DELETE']) p where has_table_privilege('anon', 'public.' || t, p))
  and not has_table_privilege('authenticated', 'public.vehicle_inspections', 'UPDATE') and not has_table_privilege('authenticated', 'public.vehicle_inspection_items', 'INSERT')
  and not has_function_privilege('anon', 'public.inspection_review(uuid,text,text)', 'EXECUTE') and not has_function_privilege('authenticated', 'public._insp_event(uuid,text,jsonb)', 'EXECUTE'), '');
-- ===== PERMISOS ENTRE EQUIPOS · Operario SIN Superior asignado (corrección DT) =====
\set O2 'e0000000-0000-0000-0000-0000000000e3'
\set O3 'e0000000-0000-0000-0000-0000000000e4'
\set S3 'e0000000-0000-0000-0000-0000000000e5'
\set O4 'e0000000-0000-0000-0000-0000000000e6'
insert into auth.users(id, email) values (:'O2', 'insp.o2@t'), (:'O3', 'insp.o3@t'), (:'S3', 'insp.s3@t'), (:'O4', 'insp.o4@t') on conflict do nothing;
select set_config('okd.sync', 'on', false);
insert into public.profiles(id, full_name, email, role, status) values (:'O2', 'Operario Sin Superior', 'insp.o2@t', 'OPERARIO_DEPOSITO', 'ACTIVO'), (:'O3', 'Operario Superior Inactivo', 'insp.o3@t', 'OPERARIO_DEPOSITO', 'ACTIVO'),
  (:'S3', 'Superior Inactivo', 'insp.s3@t', 'SUPERVISOR_DESPACHO', 'ACTIVO'), (:'O4', 'Operario Con Admin', 'insp.o4@t', 'OPERARIO_DEPOSITO', 'ACTIVO') on conflict (id) do nothing;
update public.profiles set supervisor_user_id = null where id = :'O2';
update public.profiles set supervisor_user_id = :'S3' where id = :'O3'; update public.profiles set status = 'DESHABILITADO' where id = :'S3';   -- su Superior Despacho quedó DESHABILITADO
update public.profiles set supervisor_user_id = :'A' where id = :'O4';    -- su superior es el ADMINISTRADOR GENERAL (permitido por el sistema; no aprueba inspecciones)
select set_config('okd.sync', '', false);
begin; select tst.u(:'O2'); set local role authenticated;
create temp table n1 as select * from public.inspection_save_draft(jsonb_build_object('client_id', gen_random_uuid(), 'vehicle_id', :'VH', 'km', 50800, 'items', pg_temp.items('BIEN'))); grant select on n1 to public;
select tst.expect('I-18 Operario SIN Superior: el envío se rechaza (SUPERVISOR_REQUIRED) y queda como BORRADOR', format($q$ select public.inspection_submit(%L) $q$, (select id from n1)), 'SUPERVISOR_REQUIRED%');
create temp table v_o2 as select count(*) n from public.vehicle_inspections where id = (select id from n1); grant select on v_o2 to public;
commit;
select tst.res('I-18b sin Superior: sigue BORRADOR, sin responsable de equipo y SIN ninguna notificación',
  (select status = 'BORRADOR' and team_supervisor_id is null from public.vehicle_inspections where id = (select id from n1)) and (select count(*) from public.notifications where inspection_id = (select id from n1)) = 0, '');
begin; select tst.u(:'S'); set local role authenticated;
create temp table v_s as select count(*) n from public.vehicle_inspections where id = (select id from n1); grant select on v_s to public;
create temp table v_si as select count(*) n from public.vehicle_inspection_items where inspection_id = (select id from n1); grant select on v_si to public;
select tst.expect('I-19b un Superior NO decide sobre la inspección de un Operario sin Superior', format($q$ select public.inspection_review(%L, 'APROBADA', null) $q$, (select id from n1)), 'FORBIDDEN%');
commit;
begin; select tst.u(:'S2'); set local role authenticated;
create temp table v_s2 as select count(*) n from public.vehicle_inspections where id = (select id from n1); grant select on v_s2 to public;
commit;
begin; select tst.u(:'A'); set local role authenticated;
create temp table v_a as select count(*) n from public.vehicle_inspections where id = (select id from n1); grant select on v_a to public;
commit;
select tst.res('I-19 RLS sin Superior: NINGÚN Superior la ve (ni sus controles); la ven SOLO el autor y el Administrador General',
  (select n from v_s) = 0 and (select n from v_si) = 0 and (select n from v_s2) = 0 and (select n from v_o2) = 1 and (select n from v_a) = 1, '');
-- se le asigna Superior (S2) → ahora sí se envía, y SOLO S2 la ve, la recibe y decide
select set_config('okd.sync', 'on', false); update public.profiles set supervisor_user_id = :'S2' where id = :'O2'; select set_config('okd.sync', '', false);
begin; select tst.u(:'O2'); set local role authenticated; select public.inspection_submit((select id from n1)); commit;
begin; select tst.u(:'S'); set local role authenticated;
create temp table v_s3 as select count(*) n from public.vehicle_inspections where id = (select id from n1); grant select on v_s3 to public;
select tst.expect('I-20b el Superior de OTRO equipo (S) no decide', format($q$ select public.inspection_review(%L, 'APROBADA', null) $q$, (select id from n1)), 'FORBIDDEN%');
commit;
begin; select tst.u(:'S2'); set local role authenticated; select public.inspection_review((select id from n1), 'APROBADA', null); commit;
select tst.res('I-20 con Superior asignado (S2): se envía con S2 responsable; la notificación va SOLO a S2; S no la ve; S2 la aprueba',
  (select status = 'APROBADA' and team_supervisor_id = 'e0000000-0000-0000-0000-0000000000e2' and reviewed_by = 'e0000000-0000-0000-0000-0000000000e2' from public.vehicle_inspections where id = (select id from n1))
  and (select count(*) from public.notifications where inspection_id = (select id from n1) and type = 'INSPECTION_PENDING') = 1
  and (select count(*) from public.notifications where inspection_id = (select id from n1) and type = 'INSPECTION_PENDING' and user_id = 'e0000000-0000-0000-0000-0000000000e2') = 1 and (select n from v_s3) = 0, '');
begin; select tst.u(:'O3'); set local role authenticated;
create temp table n3 as select * from public.inspection_save_draft(jsonb_build_object('client_id', gen_random_uuid(), 'vehicle_id', :'VH', 'km', 50900, 'items', pg_temp.items('BIEN'))); grant select on n3 to public;
select tst.expect('I-21 Superior Despacho asignado pero DESHABILITADO → SUPERVISOR_REQUIRED', format($q$ select public.inspection_submit(%L) $q$, (select id from n3)), 'SUPERVISOR_REQUIRED%');
commit;
select tst.res('I-21b sin Superior válido: BORRADOR y ninguna notificación', (select status from public.vehicle_inspections where id = (select id from n3)) = 'BORRADOR' and (select count(*) from public.notifications where inspection_id = (select id from n3)) = 0, '');
begin; select tst.u(:'O4'); set local role authenticated;
create temp table n4 as select * from public.inspection_save_draft(jsonb_build_object('client_id', gen_random_uuid(), 'vehicle_id', :'VH', 'km', 51000, 'items', pg_temp.items('BIEN'))); grant select on n4 to public;
select tst.expect('I-22 Operario cuyo superior es el ADMINISTRADOR GENERAL (que no aprueba inspecciones) → SUPERVISOR_REQUIRED (no quedan pendientes sin quien decida)', format($q$ select public.inspection_submit(%L) $q$, (select id from n4)), 'SUPERVISOR_REQUIRED%');
commit;
select tst.res('I-22b sin Superior Despacho: BORRADOR, ninguna notificación y ningún Superior la ve', (select status from public.vehicle_inspections where id = (select id from n4)) = 'BORRADOR'
  and (select count(*) from public.notifications where inspection_id = (select id from n4)) = 0, '');
-- ===== SEGURIDAD · ninguna RPC SECURITY DEFINER filtra inspecciones ajenas (corrección inspection_new_revision) =====
-- el atacante CONOCE el client_id y el id de la inspección ajena (n1: Operario O2, equipo de S2, APROBADA)
create temp table foreign_i as select id, client_id, number, plate from public.vehicle_inspections where id = (select id from n1); grant select on foreign_i to public;
create temp table r2c as select client_id from public.vehicle_inspections where id = (select id from r2); grant select on r2c to public;
create or replace function pg_temp.err(q text) returns text language plpgsql as $f$ begin execute q; return 'SIN_ERROR'; exception when others then return sqlerrm; end $f$;
create or replace function pg_temp.leak(m text) returns boolean language sql as $f$ select m like '%' || (select number from foreign_i) || '%' $f$;
-- I-23: Operario O (equipo de S) pide una revisión de SU inspección usando el client_id de la inspección AJENA
begin; select tst.u(:'O'); set local role authenticated;
create temp table e23 as select pg_temp.err(format($q$ select * from public.inspection_new_revision(%L, %L) $q$, (select id from i1), (select client_id from foreign_i))) m; grant select on e23 to public;
create temp table e26 as select * from public.inspection_new_revision((select id from i1), (select client_id from r2c)); grant select on e26 to public;   -- reintento legítimo
-- I-28: barrido de TODAS las RPC y tablas como Operario O sobre la inspección AJENA
create temp table e28 as select x.k, pg_temp.err(x.q) m from (values
  ('save_draft', format($q$ select public.inspection_save_draft(jsonb_build_object('client_id', %L, 'vehicle_id', 'f0000000-0000-0000-0000-000000000001')) $q$, (select client_id from foreign_i))),
  ('submit', format($q$ select public.inspection_submit(%L) $q$, (select id from foreign_i))),
  ('review', format($q$ select public.inspection_review(%L, 'APROBADA', null) $q$, (select id from foreign_i))),
  ('new_revision', format($q$ select public.inspection_new_revision(%L, gen_random_uuid()) $q$, (select id from foreign_i))),
  ('email', format($q$ select public.inspection_email_request(%L, array['x@ok.test'], 's', 'b') $q$, (select id from foreign_i)))) x(k, q);
grant select on e28 to public;
create temp table t28 as select (select count(*) from public.vehicle_inspections where id = (select id from foreign_i)) + (select count(*) from public.vehicle_inspection_items where inspection_id = (select id from foreign_i))
  + (select count(*) from public.vehicle_inspection_events where inspection_id = (select id from foreign_i)) + (select count(*) from public.vehicle_inspection_email_requests where inspection_id = (select id from foreign_i)) n; grant select on t28 to public;
commit;
select tst.res('I-23 VULNERABILIDAD CORREGIDA: un Operario que usa el client_id de una inspección de OTRO equipo recibe CLIENT_ID_CONFLICT, sin número, patente ni estado',
  (select m from e23) like 'CLIENT_ID_CONFLICT%' and not pg_temp.leak((select m from e23)), (select m from e23));
select tst.res('I-26 IDEMPOTENCIA: el reintento del MISMO autor con la MISMA original y el mismo client_id devuelve la MISMA revisión', (select id from e26) = (select id from r2), '');
select tst.res('I-28 Operario contra inspección AJENA: las 5 RPC rechazan (FORBIDDEN) sin datos en el mensaje, y las 4 tablas devuelven 0 filas',
  (select bool_and(m like 'FORBIDDEN%' and not pg_temp.leak(m)) from e28) and (select n from t28) = 0, (select string_agg(k || '=' || left(m, 30), ' · ') from e28));
-- I-24 / I-27 / I-29: como Superior S (equipo de S)
begin; select tst.u(:'S'); set local role authenticated;
create temp table e24 as select pg_temp.err(format($q$ select * from public.inspection_new_revision(%L, %L) $q$, (select id from i3), (select client_id from foreign_i))) m; grant select on e24 to public;
create temp table e27 as select pg_temp.err(format($q$ select * from public.inspection_new_revision(%L, %L) $q$, (select id from i1), (select client_id from r2c))) m; grant select on e27 to public;
create temp table e29 as select x.k, pg_temp.err(x.q) m from (values
  ('save_draft', format($q$ select public.inspection_save_draft(jsonb_build_object('client_id', %L, 'vehicle_id', 'f0000000-0000-0000-0000-000000000001')) $q$, (select client_id from foreign_i))),
  ('submit', format($q$ select public.inspection_submit(%L) $q$, (select id from foreign_i))),
  ('review', format($q$ select public.inspection_review(%L, 'RECHAZADA', 'x') $q$, (select id from foreign_i))),
  ('new_revision', format($q$ select public.inspection_new_revision(%L, gen_random_uuid()) $q$, (select id from foreign_i))),
  ('email', format($q$ select public.inspection_email_request(%L, array['x@ok.test'], 's', 'b') $q$, (select id from foreign_i)))) x(k, q);
grant select on e29 to public;
create temp table t29 as select (select count(*) from public.vehicle_inspections where id = (select id from foreign_i)) + (select count(*) from public.vehicle_inspection_items where inspection_id = (select id from foreign_i))
  + (select count(*) from public.vehicle_inspection_events where inspection_id = (select id from foreign_i)) + (select count(*) from public.vehicle_inspection_email_requests where inspection_id = (select id from foreign_i)) n; grant select on t29 to public;
commit;
select tst.res('I-24 un SUPERIOR que usa el client_id de una inspección de OTRO equipo (sobre una original propia) recibe CLIENT_ID_CONFLICT sin datos',
  (select m from e24) like 'CLIENT_ID_CONFLICT%' and not pg_temp.leak((select m from e24)), (select m from e24));
select tst.res('I-27 el client_id de una revisión de OTRO AUTOR (aunque sea del mismo equipo y de la misma original) se rechaza: el reintento solo vale para su autor',
  (select m from e27) like 'CLIENT_ID_CONFLICT%', (select m from e27));
select tst.res('I-29 Superior contra inspección de OTRO equipo: las 5 RPC rechazan (FORBIDDEN) sin datos en el mensaje, y las 4 tablas devuelven 0 filas',
  (select bool_and(m like 'FORBIDDEN%' and not pg_temp.leak(m)) from e29) and (select n from t29) = 0, (select string_agg(k || '=' || left(m, 30), ' · ') from e29));
-- I-25: Superior S2 pide revisión de una original que NO puede ver (i1, equipo de S)
begin; select tst.u(:'S2'); set local role authenticated;
create temp table e25 as select pg_temp.err(format($q$ select * from public.inspection_new_revision(%L, %L) $q$, (select id from i1), (select client_id from r2c))) m; grant select on e25 to public;
commit;
select tst.res('I-25 una revisión de una original que el usuario NO puede ver → FORBIDDEN (aunque se conozca el client_id de una revisión existente)',
  (select m from e25) like 'FORBIDDEN%' and (select m from e25) not like '%' || (select number from public.vehicle_inspections where id = (select id from i1)) || '%', (select m from e25));
select tst.res('I-30 funciones internas NO invocables por usuarios: _insp_me, _insp_event y el trigger de bloqueo',
  not has_function_privilege('authenticated', 'public._insp_me()', 'EXECUTE') and not has_function_privilege('authenticated', 'public._insp_event(uuid,text,jsonb)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.trg_insp_items_locked()', 'EXECUTE') and not has_function_privilege('anon', 'public.inspection_new_revision(uuid,uuid)', 'EXECUTE'), '');
-- ===== ESTADO ACTIVO · usuarios DESHABILITADOS no ven ni actúan (auditoría de omisiones equivalentes) =====
\set S4 'e0000000-0000-0000-0000-0000000000e7'
\set O5 'e0000000-0000-0000-0000-0000000000e8'
insert into auth.users(id, email) values (:'S4', 'insp.s4@t'), (:'O5', 'insp.o5@t') on conflict do nothing;
select set_config('okd.sync', 'on', false);
insert into public.profiles(id, full_name, email, role, status) values (:'S4', 'Superior Que Se Deshabilita', 'insp.s4@t', 'SUPERVISOR_DESPACHO', 'ACTIVO'), (:'O5', 'Operario Que Se Deshabilita', 'insp.o5@t', 'OPERARIO_DEPOSITO', 'ACTIVO') on conflict (id) do nothing;
update public.profiles set supervisor_user_id = :'S4' where id = :'O5';
select set_config('okd.sync', '', false);
-- O5 (activo) envía una inspección a S4 (activo); S4 la aprueba → existe un pedido de email de S4; después O5 manda otra que queda PENDIENTE
begin; select tst.u(:'O5'); set local role authenticated;
create temp table d1 as select * from public.inspection_save_draft(jsonb_build_object('client_id', gen_random_uuid(), 'vehicle_id', :'VH', 'km', 52000, 'items', pg_temp.items('BIEN'))); grant select on d1 to public;
select public.inspection_submit((select id from d1)); commit;
begin; select tst.u(:'S4'); set local role authenticated; select public.inspection_review((select id from d1), 'APROBADA', null); select public.inspection_email_request((select id from d1), array['jefe@ok.test'], 's', 'b'); commit;
begin; select tst.u(:'O5'); set local role authenticated;
create temp table d2 as select * from public.inspection_save_draft(jsonb_build_object('client_id', gen_random_uuid(), 'vehicle_id', :'VH', 'km', 52100, 'items', pg_temp.items('BIEN'))); grant select on d2 to public;
select public.inspection_submit((select id from d2)); commit;
-- se DESHABILITAN ambos
select set_config('okd.sync', 'on', false); update public.profiles set status = 'DESHABILITADO' where id in (:'S4', :'O5'); select set_config('okd.sync', '', false);
create temp table d_num as select number from public.vehicle_inspections where id = (select id from d2); grant select on d_num to public;
begin; select tst.u(:'S4'); set local role authenticated;
create temp table e31 as select x.k, pg_temp.err(x.q) m from (values
  ('review_aprobar', format($q$ select public.inspection_review(%L, 'APROBADA', null) $q$, (select id from d2))),
  ('review_rechazar', format($q$ select public.inspection_review(%L, 'RECHAZADA', 'x') $q$, (select id from d2))),
  ('new_revision', format($q$ select public.inspection_new_revision(%L, gen_random_uuid()) $q$, (select id from d1))),
  ('email', format($q$ select public.inspection_email_request(%L, array['x@ok.test'], 's', 'b') $q$, (select id from d1))),
  ('save_draft', format($q$ select public.inspection_save_draft(jsonb_build_object('client_id', gen_random_uuid(), 'vehicle_id', %L)) $q$, 'f0000000-0000-0000-0000-000000000001'))) x(k, q);
grant select on e31 to public;
create temp table t31 as select (select count(*) from public.vehicle_inspections where id in ((select id from d1), (select id from d2))) + (select count(*) from public.vehicle_inspection_items where inspection_id in ((select id from d1), (select id from d2)))
  + (select count(*) from public.vehicle_inspection_events where inspection_id in ((select id from d1), (select id from d2))) + (select count(*) from public.vehicle_inspection_email_requests where inspection_id = (select id from d1)) n; grant select on t31 to public;
commit;
select tst.res('I-31 Superior Despacho DESHABILITADO (con una inspección PENDIENTE de su equipo y un pedido de email propio): las 5 RPC rechazan (FORBIDDEN) sin datos y NO ve inspecciones, controles, auditoría ni pedidos (0 filas)',
  (select bool_and(m like 'FORBIDDEN%' and m not like '%' || (select number from d_num) || '%') from e31) and (select n from t31) = 0 and (select status from public.vehicle_inspections where id = (select id from d2)) = 'PENDIENTE',
  (select string_agg(k || '=' || left(m, 20), ' · ') from e31));
begin; select tst.u(:'O5'); set local role authenticated;
create temp table e32 as select x.k, pg_temp.err(x.q) m from (values
  ('save_draft', format($q$ select public.inspection_save_draft(jsonb_build_object('client_id', %L, 'vehicle_id', %L)) $q$, (select client_id from public.vehicle_inspections where id = (select id from d2)), 'f0000000-0000-0000-0000-000000000001')),
  ('submit', format($q$ select public.inspection_submit(%L) $q$, (select id from d2))),
  ('new_revision', format($q$ select public.inspection_new_revision(%L, gen_random_uuid()) $q$, (select id from d1)))) x(k, q);
grant select on e32 to public;
create temp table t32 as select count(*) n from public.vehicle_inspections where created_by = 'e0000000-0000-0000-0000-0000000000e8'; grant select on t32 to public;
commit;
select tst.res('I-32 Operario DESHABILITADO: no guarda, no envía ni crea revisiones (FORBIDDEN) y NO ve ni sus propias inspecciones (0 filas)',
  (select bool_and(m like 'FORBIDDEN%') from e32) and (select n from t32) = 0, (select string_agg(k || '=' || left(m, 20), ' · ') from e32));
-- I-33: Operario ACTIVO cuyo Superior asignado está DESHABILITADO → no se envía ni se notifica (O3 → S3 DESHABILITADO, ya preparado arriba)
select tst.res('I-33 Superior asignado DESHABILITADO: el envío se rechaza (SUPERVISOR_REQUIRED) y no se genera ninguna notificación',
  (select status from public.vehicle_inspections where id = (select id from n3)) = 'BORRADOR' and (select count(*) from public.notifications where inspection_id = (select id from n3)) = 0
  and (select count(*) from public.notifications where user_id = 'e0000000-0000-0000-0000-0000000000e5') = 0, '');
