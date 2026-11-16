-- SOLO PRUEBAS LOCALES · ALARMA COMERCIAL URGENTE (contratos reales: notifications, push_jobs, order_reservations). Aserciones POSITIVAS.
create temp table al_checks(name text, ok boolean, detail text);
create or replace function pg_temp.al(u uuid, q text) returns text language plpgsql as $f$ declare o text; begin perform tst.u(u); set local role authenticated; begin execute q into o; exception when others then o := 'ERR ' || sqlerrm; end; reset role; return o; end $f$;
create or replace function pg_temp.aljs(t text) returns jsonb language sql as $f$ select case when t like '[%' or t like '{%' then t::jsonb end $f$;
create or replace function pg_temp.raise_(u uuid, ord text, sheet text, reason text, op text) returns text language sql as $f$
  select pg_temp.al(u, format('select public.com_alarm_raise(%L, %L, %L, %L, %L, %L)::text', ord, sheet, 'CLIENTE DECLARADO', '30500010912', reason, op)) $f$;
create or replace function pg_temp.attend(u uuid, id uuid) returns text language sql as $f$
  select pg_temp.al(u, format('select public.com_alarm_attend(%L, %s)::text', id, (select version from public.com_alarms where com_alarms.id = $2))) $f$;
\set A  'e0000000-0000-0000-0000-00000000000a'
\set O  'e0000000-0000-0000-0000-000000000006'
\set G  'e0000000-0000-0000-0000-000000000007'
\set C1 'c0000000-0000-0000-0000-0000000000c1'
\set W  'c0000000-0000-0000-0000-0000000000a1'
\set F  'c0000000-0000-0000-0000-0000000000a2'
\set GB 'c0000000-0000-0000-0000-0000000000a3'
\set AP 'c0000000-0000-0000-0000-0000000000a9'
-- pedidos REALMENTE reservados en la hoja AL-1 (como los reserva el Constructor)
select pg_temp.al(:'O', $q$select public.reserve_orders('AL-1', array['27101','27102','27103'])::text$q$);
select pg_temp.al(:'A', format($q$select public.com_set_alarm_settings(%L::jsonb)::text$q$, jsonb_build_object('initial_user', :'W', 'escalation_users', jsonb_build_array(:'F', :'GB'))));   -- configuración EXPLÍCITA
create temp table al_r1 as select pg_temp.raise_(:'O', '27101', 'AL-1', 'Cliente pide financiación antes de salir', 'al-op-1') r;
create temp table al_al1 as select * from public.com_alarms where order_ref = '27101';
insert into al_checks select 'AL-01 EMITIR desde Despacho: alarma PENDIENTE DE ATENCIÓN vinculada a pedido, hoja y solicitante; destinatario inicial = Wilfredo; aviso en la campana y en la cola push',
  pg_temp.aljs(r)->>'status' = 'PENDIENTE_ATENCION' and (select initial_user = :'W' and raised_by = :'O' and sheet_key = 'AL-1' and escalated_at is null from al_al1)
  and exists (select 1 from public.notifications n join public.push_jobs j on j.notification_id = n.id where n.user_id = :'W' and n.type = 'COM_ALARMA' and j.status = 'QUEUED')
  and (select body !~ '\$|\d{3}\.\d{3}' from public.notifications where user_id = :'W' and type = 'COM_ALARMA' order by created_at desc limit 1), r from al_r1;
insert into al_checks select 'AL-02 SIN DUPLICADOS: otra alarma para el mismo pedido devuelve la ACTIVA (no crea otra); el mismo op_id es idempotente',
  (pg_temp.aljs(pg_temp.raise_(:'O', '27101', 'AL-1', 'Otro operador insiste con el pedido', 'al-op-2'))->>'existing')::boolean
  and (pg_temp.aljs(pg_temp.raise_(:'O', '27101', 'AL-1', 'Cliente pide financiación antes de salir', 'al-op-1'))->>'repeated')::boolean
  and (select count(*) from public.com_alarms where order_ref = '27101') = 1, '' from (select 1) z;
insert into al_checks select 'AL-03 PERMISOS DE EMISIÓN: Comercial y chofer → FORBIDDEN; pedido que no está en la hoja → ORDER_NOT_IN_SHEET; sin motivo → REASON_REQUIRED',
  (pg_temp.raise_(:'C1', '27102', 'AL-1', 'Motivo suficiente de prueba', 'al-x01') like 'ERR FORBIDDEN%') = true and (pg_temp.raise_(:'G', '27102', 'AL-1', 'Motivo suficiente de prueba', 'al-x02') like 'ERR FORBIDDEN%') = true
  and (pg_temp.raise_(:'O', '99999', 'AL-1', 'Motivo suficiente de prueba', 'al-x03') like 'ERR ORDER_NOT_IN_SHEET%') = true and (pg_temp.raise_(:'O', '27102', 'AL-1', 'corto', 'al-x04') like 'ERR REASON_REQUIRED%') = true, '' from (select 1) z;
insert into al_checks select 'AL-04 NO escala antes de los 3 minutos', public.com_alarm_escalate_due() = 0 and (select escalated_at is null from public.com_alarms where order_ref = '27101'), '' from (select 1) z;
-- pasan los 3 minutos (reloj del SERVIDOR): ninguna sesión abierta; lo ejecuta la tarea programada (superusuario)
update public.com_alarms set escalate_at = now() - interval '1 second' where order_ref = '27101';
create temp table al_e1 as select public.com_alarm_escalate_due() n;
insert into al_checks select 'AL-05 ESCALAMIENTO DEL SERVIDOR sin ningún navegador: a Franco y Gabriela, con fecha y hora; avisos en la campana y en la cola push',
  (select n from al_e1) = 1 and (select escalated_at is not null and escalated_to @> array[:'F', :'GB']::uuid[] and cardinality(escalated_to) = 2 from public.com_alarms where order_ref = '27101')
  and (select count(*) from public.notifications n join public.push_jobs j on j.notification_id = n.id where n.type = 'COM_ALARMA_ESCALADA' and n.user_id in (:'F', :'GB')) = 2, '' from (select 1) z;
insert into al_checks select 'AL-06 ESCALAMIENTO NO DUPLICADO: repetir la tarea no vuelve a escalar ni a notificar',
  public.com_alarm_escalate_due() = 0 and (select count(*) from public.com_alarm_events e join public.com_alarms a on a.id = e.alarm_id where a.order_ref = '27101' and e.kind = 'ESCALADA') = 1, '' from (select 1) z;
insert into al_checks select 'AL-07 ALCANCE: el Comercial no ve la alarma; Despacho (quien la pidió) la ve SIN sonido; Wilfredo y Franco (escalado) la ven CON sonido',
  pg_temp.al(:'C1', 'select public.com_my_alarms()::text') = '[]'
  and (select (x->>'ring')::boolean = false from jsonb_array_elements(pg_temp.aljs(pg_temp.al(:'O', 'select public.com_my_alarms()::text'))) x where x->>'order_ref' = '27101')
  and (select (x->>'ring')::boolean from jsonb_array_elements(pg_temp.aljs(pg_temp.al(:'W', 'select public.com_my_alarms()::text'))) x where x->>'order_ref' = '27101')
  and (select (x->>'ring')::boolean from jsonb_array_elements(pg_temp.aljs(pg_temp.al(:'F', 'select public.com_my_alarms()::text'))) x where x->>'order_ref' = '27101'), '' from (select 1) z;
create temp table al_nz as select pg_temp.attend(:'AP', (select id from al_al1)) ap, pg_temp.attend(:'C1', (select id from al_al1)) c1;   -- intentos en una sentencia PREVIA
insert into al_checks select 'AL-08 ATENDER sin autorización (aprobador ajeno, Comercial): rechazo FORBIDDEN, la alarma no cambia y queda REGISTRADO cada intento',
  pg_temp.aljs(ap)->>'code' = 'FORBIDDEN' and pg_temp.aljs(c1)->>'code' = 'FORBIDDEN' and (select status = 'PENDIENTE_ATENCION' from public.com_alarms where order_ref = '27101')
  and (select count(*) from public.com_alarm_events where alarm_id = (select id from al_al1) and kind = 'INTENTO_ATENDER_RECHAZADO') = 2, ap || ' · ' || c1 from al_nz;
create temp table al_v0 as select version from public.com_alarms where order_ref = '27101';
create temp table al_at1 as select pg_temp.attend(:'GB', (select id from al_al1)) r;
insert into al_checks select 'AL-09 ATENDER (Gabriela, escalada): queda ATENDIDA con quién, cuándo, cómo y tiempo transcurrido; se avisa a quien la pidió y a los demás destinatarios',
  pg_temp.aljs(r)->>'status' = 'ATENDIDA' and pg_temp.aljs(r)->>'attended_as' = 'ESCALAMIENTO'
  and (select attended_by = :'GB' and attended_at is not null and seconds_to_attend is not null from public.com_alarms where order_ref = '27101')
  and (select count(*) from public.notifications where type = 'COM_ALARMA_ATENDIDA' and user_id in (:'O', :'W', :'F')) = 3, r from al_at1;
insert into al_checks select 'AL-10 DOS RESPONSABLES A LA VEZ: el segundo (versión anterior) recibe CONFLICT y la alarma queda atendida por el primero',
  (pg_temp.al(:'F', format('select public.com_alarm_attend(%L, %s)::text', (select id from al_al1), (select version from al_v0))) like 'ERR CONFLICT%') = true
  and (select attended_by = :'GB' from public.com_alarms where order_ref = '27101'), '' from (select 1) z;
-- atender ANTES de los 3 minutos cancela el escalamiento
create temp table al_r2 as select pg_temp.raise_(:'O', '27102', 'AL-1', 'Segundo pedido urgente de prueba', 'al-op-3') r;
select pg_temp.attend(:'W', (pg_temp.aljs((select r from al_r2))->>'id')::uuid);
update public.com_alarms set escalate_at = now() - interval '1 second' where order_ref = '27102';
insert into al_checks select 'AL-11 ATENDER antes de los 3 minutos CANCELA el escalamiento: la tarea no la escala ni notifica a Franco y Gabriela',
  public.com_alarm_escalate_due() = 0 and (select status = 'ATENDIDA' and escalated_at is null and attended_as = 'DESTINATARIO_INICIAL' from public.com_alarms where order_ref = '27102'), '' from (select 1) z;
insert into al_checks select 'AL-12 ATENDER NO ES APROBAR: la alarma no cambia solicitudes comerciales, importes ni notas de crédito',
  (select count(*) from public.com_request_events e where e.at > (select raised_at from al_al1) and e.kind not in ('ENVIADA', 'PENDIENTE')) = 0
  and not exists (select 1 from public.credit_note_events where at > (select raised_at from al_al1)), '' from (select 1) z;
select set_config('okd.sync', 'on', false); update public.profiles set sessions_revoked_at = now() + interval '1 hour' where id = :'W'; select set_config('okd.sync', '', false);
create temp table al_rv as select pg_temp.al(:'W', 'select public.com_my_alarms()::text') r;
select set_config('okd.sync', 'on', false); update public.profiles set sessions_revoked_at = null where id = :'W'; select set_config('okd.sync', '', false);
insert into al_checks select 'AL-13 SESIÓN REVOCADA: FORBIDDEN', (r like 'ERR FORBIDDEN%') = true, r from al_rv;
insert into al_checks select 'AL-14 HISTORIAL INMUTABLE y AUDITORÍA: no se puede modificar ni borrar; el historial (solo Administrador General) trae eventos, destinatarios y estado del push',
  (pg_temp.al(:'A', $q$select count(*)::text from public.com_alarm_events$q$) like 'ERR%') = true
  and (select count(*) from public.com_alarm_events where alarm_id = (select id from al_al1) and kind in ('CREADA', 'NOTIFICADO', 'ESCALADA', 'ATENDIDA')) >= 6
  and (pg_temp.al(:'O', format('select public.com_alarm_history(%L, %L)::text', current_date - 1, current_date)) like 'ERR FORBIDDEN%') = true
  and (select x->'eventos' @> '[{"kind":"ESCALADA"}]' and x ? 'resolucion_comercial' from jsonb_array_elements(pg_temp.aljs(pg_temp.al(:'A', format('select public.com_alarm_history(%L, %L)::text', current_date - 1, current_date)))) x where x->>'order_ref' = '27101'), '' from (select 1) z;
do $$ begin begin update public.com_alarm_events set kind = 'ERROR' where id = (select min(id) from public.com_alarm_events); raise exception 'NO_BLOQUEO'; exception when others then
  if sqlerrm like 'IMMUTABLE%' then insert into al_checks values ('AL-15 el superusuario TAMPOCO modifica el historial (disparador IMMUTABLE)', true, sqlerrm); else insert into al_checks values ('AL-15 el superusuario TAMPOCO modifica el historial (disparador IMMUTABLE)', false, sqlerrm); end if; end; end $$;
insert into al_checks select 'AL-16 CONFIGURACIÓN y PRIVILEGIOS: escalamiento solo a Administradores Generales ACTIVOS; destinatario inicial con permiso de aprobación; anon y funciones internas sin acceso; el push conserva los tipos existentes',
  (pg_temp.al(:'A', format($q$select public.com_set_alarm_settings(%L::jsonb)::text$q$, jsonb_build_object('initial_user', :'W', 'escalation_users', jsonb_build_array(:'C1')))) like 'ERR BAD_RECIPIENT%') = true
  and (pg_temp.al(:'A', format($q$select public.com_set_alarm_settings(%L::jsonb)::text$q$, jsonb_build_object('initial_user', :'C1', 'escalation_users', jsonb_build_array(:'F')))) like 'ERR BAD_RECIPIENT%') = true
  and not has_function_privilege('anon', 'public.com_alarm_raise(text,text,text,text,text,text)', 'EXECUTE') and not has_function_privilege('authenticated', 'public.com_alarm_escalate_due()', 'EXECUTE')
  and pg_get_functiondef('public.queue_notification_push()'::regprocedure) ~ 'REQUEST_OBSERVED' and pg_get_functiondef('public.queue_notification_push()'::regprocedure) ~ 'NUEVA_HOJA_PUBLICADA', '' from (select 1) z;

-- ===================== auditoría independiente 14/11 (alarma) =====================
create or replace function pg_temp.sync_on() returns void language sql as $f$ select set_config('okd.sync', 'on', false) $f$;
create or replace function pg_temp.sync_off() returns void language sql as $f$ select set_config('okd.sync', '', false) $f$;
-- AL-17 · B-AL-03: configuración explícita y completa; lo GUARDADO se lee igual al reabrir
create temp table al_c17 as select pg_temp.al(:'A', $q$select public.com_set_alarm_settings('{"initial_user":null,"escalation_users":[]}'::jsonb)::text$q$) vacio,
  pg_temp.aljs(pg_temp.al(:'A', 'select public.com_alarm_settings()::text')) leido;
insert into al_checks select 'AL-17 (B-AL-03) guardar VACÍO o incompleto se RECHAZA (no se borra la configuración por accidente); al reabrir se leen los destinatarios GUARDADOS (Wilfredo; Franco y Gabriela), sin problemas',
  (vacio like 'ERR INCOMPLETE%') = true and leido->>'initial_user' = :'W' and leido->'escalation_users' @> to_jsonb(array[:'F', :'GB']) and jsonb_array_length(leido->'escalation_users') = 2
  and jsonb_array_length(leido->'problemas') = 0, left(leido::text, 200) from al_c17;
-- AL-18 · B-AL-03: un destinatario de escalamiento deja de estar ACTIVO → se escala SOLO a los activos (no a todos los Administradores)
select pg_temp.sync_on(); update public.profiles set status = 'DESHABILITADO' where id = :'GB'; select pg_temp.sync_off();
create temp table al_r18 as select pg_temp.raise_(:'O', '27103', 'AL-1', 'Tercer pedido urgente de prueba', 'al-op-18') r;
update public.com_alarms set escalate_at = now() - interval '1 second' where order_ref = '27103'; select public.com_alarm_escalate_due();
create temp table al_c18 as select (select escalated_to from public.com_alarms where order_ref = '27103') dest, pg_temp.aljs(pg_temp.al(:'A', 'select public.com_alarm_settings()::text'))->'problemas' prob;
-- ahora NINGÚN destinatario activo
select pg_temp.sync_on(); update public.profiles set status = 'DESHABILITADO' where id = :'F'; select pg_temp.sync_off();
select pg_temp.attend(:'W', (select id from public.com_alarms where order_ref = '27103'));
create temp table al_r18b as select pg_temp.raise_(:'O', '27101', 'AL-1', 'Pedido urgente sin escalamiento posible', 'al-op-18b') bloqueada;
insert into al_checks select 'AL-18 (B-AL-03) destinatario INACTIVO: se escala solo a los ACTIVOS (Franco), NUNCA se amplía a otros Administradores; el Panel lo advierte; sin ninguno activo NO se pueden pedir alarmas (ALARM_NOT_CONFIGURED)',
  dest = array[:'F']::uuid[] and not (dest @> array[:'A']::uuid[]) and jsonb_array_length(prob) = 1 and (select bloqueada like 'ERR ALARM_NOT_CONFIGURED%' from al_r18b), array_to_string(dest, ',') || ' · ' || prob::text from al_c18;
-- alarma pendiente cuando ya no queda NINGÚN destinatario de escalamiento activo
select pg_temp.sync_on(); update public.profiles set status = 'ACTIVO' where id in (:'F', :'GB'); select pg_temp.sync_off();
create temp table al_r18c as select pg_temp.raise_(:'O', '27101', 'AL-1', 'Pedido urgente para probar sin destinatarios', 'al-op-18c') r;
select pg_temp.sync_on(); update public.profiles set status = 'DESHABILITADO' where id in (:'F', :'GB'); select pg_temp.sync_off();
update public.com_alarms set escalate_at = now() - interval '1 second' where order_ref = '27101' and status = 'PENDIENTE_ATENCION'; select public.com_alarm_escalate_due();
insert into al_checks select 'AL-18b (B-AL-03) SIN destinatarios activos al vencer: se registra ESCALAMIENTO_SIN_DESTINATARIOS, se avisa a Wilfredo y a quien la pidió, y la alarma SIGUE pendiente (no se notifica a otros)',
  (select status = 'PENDIENTE_ATENCION' and cardinality(escalated_to) = 0 and escalated_at is not null from public.com_alarms where order_ref = '27101' and op_id = 'al-op-18c')
  and exists (select 1 from public.com_alarm_events e join public.com_alarms a on a.id = e.alarm_id where a.op_id = 'al-op-18c' and e.kind = 'ESCALAMIENTO_SIN_DESTINATARIOS')
  and (select count(distinct e.recipient_id) from public.com_alarm_events e join public.com_alarms a on a.id = e.alarm_id where a.op_id = 'al-op-18c' and e.kind = 'NOTIFICADO' and e.detail->>'tipo' = 'COM_ALARMA_ESCALADA') = 2
  and not exists (select 1 from public.com_alarm_events e join public.com_alarms a on a.id = e.alarm_id where a.op_id = 'al-op-18c' and e.kind = 'NOTIFICADO' and e.recipient_id = :'A'), '' from (select 1) z;
select pg_temp.sync_on(); update public.profiles set status = 'ACTIVO' where id in (:'F', :'GB'); select pg_temp.sync_off();
-- AL-20 · O-AL-05: atender en el instante del escalamiento con la versión ANTERIOR (nadie la atendió) → se puede; la doble toma sigue protegida
create temp table al_v20 as select id, version v1 from public.com_alarms where op_id = 'al-op-18c';
create temp table al_a20 as select pg_temp.al(:'W', format('select public.com_alarm_attend(%L, %s)::text', (select id from al_v20), (select v1 from al_v20))) prim,
  pg_temp.al(:'GB', format('select public.com_alarm_attend(%L, %s)::text', (select id from al_v20), (select v1 from al_v20))) seg;
insert into al_checks select 'AL-20 (O-AL-05) ATENDER con la versión anterior tras el cambio de etapa por escalamiento: Wilfredo la atiende (sin falso CONFLICT); una segunda atención SÍ recibe CONFLICT',
  pg_temp.aljs(prim)->>'status' = 'ATENDIDA' and pg_temp.aljs(prim)->>'attended_as' = 'DESTINATARIO_INICIAL' and (seg like 'ERR CONFLICT%') = true, left(prim, 120) || ' · ' || left(seg, 90) from al_a20;
-- AL-21 · B-AL-02: el enlace del push (aviso) abre ESA alarma, solo para su destinatario
create temp table al_n21 as select n.id nid from public.notifications n where n.user_id = :'W' and n.type = 'COM_ALARMA' order by n.created_at limit 1;
insert into al_checks select 'AL-21 (B-AL-02) el aviso del push abre la alarma ESPECÍFICA para su destinatario (Wilfredo); otro usuario con el mismo enlace no obtiene nada',
  pg_temp.aljs(pg_temp.al(:'W', format('select public.com_alarm_by_notification(%L)::text', (select nid from al_n21))))->>'order_ref' = '27101'
  and coalesce(pg_temp.al(:'C1', format('select public.com_alarm_by_notification(%L)::text', (select nid from al_n21))), 'null') in ('null', '') , '' from (select 1) z;
-- AL-19 · B-AL-04: Administrador General con token REVOCADO → FORBIDDEN en las funciones administrativas
select pg_temp.sync_on(); update public.profiles set sessions_revoked_at = now() + interval '1 hour' where id = :'A'; select pg_temp.sync_off();
create temp table al_c19 as select
  pg_temp.al(:'A', format('select public.com_alarm_history(%L, %L)::text', current_date - 1, current_date)) hist,
  pg_temp.al(:'A', format($q$select public.com_set_alarm_settings(%L::jsonb)::text$q$, jsonb_build_object('initial_user', :'W', 'escalation_users', jsonb_build_array(:'F')))) cfg,
  pg_temp.al(:'A', 'select public.com_alarm_settings()::text') lee,
  pg_temp.al(:'A', $q$select public.com_set_settings('{"window_months":3}'::jsonb)::text$q$) settings,
  pg_temp.al(:'A', format('select public.com_report(%L, %L)::text', current_date - 30, current_date)) informe,
  pg_temp.al(:'A', 'select public.com_sources_status()::text') fuentes,
  pg_temp.al(:'A', format($q$select public.com_set_routing('SUCURSAL:MONTECASEROS', %L)::text$q$, :'W')) ruteo;
select pg_temp.sync_on(); update public.profiles set sessions_revoked_at = null where id = :'A'; select pg_temp.sync_off();
insert into al_checks select 'AL-19 (B-AL-04) ADMINISTRADOR con token REVOCADO: FORBIDDEN en historial, lectura y cambio de destinatarios de la alarma, y en funciones administrativas del módulo (parámetros, informes, fuentes, ruteo); al restablecer, vuelve a funcionar',
  (hist like 'ERR FORBIDDEN%') = true and (cfg like 'ERR FORBIDDEN%') = true and (lee like 'ERR FORBIDDEN%') = true and (settings like 'ERR FORBIDDEN%') = true
  and (informe like 'ERR FORBIDDEN%') = true and (fuentes like 'ERR FORBIDDEN%') = true and (ruteo like 'ERR FORBIDDEN%') = true
  and pg_temp.al(:'A', 'select public.com_alarm_settings()::text') not like 'ERR%',
  left(hist, 30) || ' | ' || left(cfg, 30) || ' | ' || left(settings, 30) || ' | ' || left(informe, 30) || ' | ' || left(fuentes, 30) || ' | ' || left(ruteo, 30) from al_c19;

-- ===================== B-AL-06 · idempotencia de com_alarm_raise (op_id vinculado a pedido, hoja y usuario) =====================
\set S 'e0000000-0000-0000-0000-000000000005'
select pg_temp.al(:'O', $q$select public.reserve_orders('AL-2', array['27201'])::text$q$);   -- otra hoja con otro pedido
create temp table al_o1 as select pg_temp.raise_(:'O', '27103', 'AL-1', 'Pedido para probar idempotencia', 'op-idem-1') r;
create temp table al_o2 as select pg_temp.raise_(:'O', '27103', 'AL-1', 'Pedido para probar idempotencia', 'op-idem-1') r;
insert into al_checks select 'AL-22 (B-AL-06) REPETIR EXACTAMENTE la misma operación (mismo op_id, pedido, hoja y usuario) devuelve el resultado anterior sin duplicar',
  (pg_temp.aljs((select r from al_o1))->>'id') = (pg_temp.aljs((select r from al_o2))->>'id') and (pg_temp.aljs((select r from al_o2))->>'repeated')::boolean
  and (select count(*) from public.com_alarms where op_id = 'op-idem-1') = 1, (select r from al_o2) from (select 1) z;
create temp table al_o3 as select pg_temp.raise_(:'O', '27101', 'AL-1', 'Mismo op_id para OTRO pedido', 'op-idem-1') otro_pedido,
  pg_temp.raise_(:'O', '27201', 'AL-2', 'Mismo op_id para OTRA hoja y pedido', 'op-idem-1') otra_hoja,
  pg_temp.raise_(:'S', '27103', 'AL-1', 'Mismo op_id con OTRO usuario', 'op-idem-1') otro_usuario;
insert into al_checks select 'AL-23 (B-AL-06) REUTILIZAR el op_id para OTRO PEDIDO → OP_ID_CONFLICT, sin datos de la alarma existente y sin crear otra',
  pg_temp.aljs(otro_pedido)->>'code' = 'OP_ID_CONFLICT' and not (pg_temp.aljs(otro_pedido) ?| array['id', 'number', 'order_ref', 'client', 'status', 'raised_by'])
  and (select count(*) from public.com_alarms where op_id = 'op-idem-1') = 1, otro_pedido from al_o3;
insert into al_checks select 'AL-24 (B-AL-06) REUTILIZARLO para OTRA HOJA → OP_ID_CONFLICT sin datos', pg_temp.aljs(otra_hoja)->>'code' = 'OP_ID_CONFLICT' and not (pg_temp.aljs(otra_hoja) ?| array['id', 'number', 'order_ref', 'client']), otra_hoja from al_o3;
insert into al_checks select 'AL-25 (B-AL-06) REUTILIZARLO desde OTRO USUARIO (Supervisor, mismo pedido y hoja) → OP_ID_CONFLICT sin revelar la alarma ajena',
  pg_temp.aljs(otro_usuario)->>'code' = 'OP_ID_CONFLICT' and not (pg_temp.aljs(otro_usuario) ?| array['id', 'number', 'order_ref', 'client', 'status']), otro_usuario from al_o3;
insert into al_checks select 'AL-26 (B-AL-06) cada intento rechazado queda REGISTRADO (historial de la alarma, con qué difiere, y audit_log) y la alarma original no cambia',
  (select count(*) from public.com_alarm_events e join public.com_alarms a on a.id = e.alarm_id where a.op_id = 'op-idem-1' and e.kind = 'OP_ID_REUTILIZADO_RECHAZADO') = 3
  and (select count(*) from public.audit_log where action = 'COM_ALARM_OP_ID_REUSE') = 3
  and exists (select 1 from public.com_alarm_events e join public.com_alarms a on a.id = e.alarm_id where a.op_id = 'op-idem-1' and e.kind = 'OP_ID_REUTILIZADO_RECHAZADO' and e.detail->'difiere' ? 'usuario')
  and (select order_ref = '27103' and sheet_key = 'AL-1' and raised_by = :'O' from public.com_alarms where op_id = 'op-idem-1'), '' from (select 1) z;
