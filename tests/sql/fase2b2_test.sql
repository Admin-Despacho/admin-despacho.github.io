\set ON_ERROR_STOP on
\set A '00000000-0000-0000-0000-00000000000a'
\set D '00000000-0000-0000-0000-00000000000d'
\set G '00000000-0000-0000-0000-000000000001'
\set C '00000000-0000-0000-0000-000000000003'
\set O '00000000-0000-0000-0000-0000000000e2'
create or replace function tst.u(p uuid) returns void language sql as $$ select tst.as_user_iat(p::text, 'authenticated', extract(epoch from now())::bigint + 60) $$;
grant execute on function tst.u(uuid) to public;
insert into auth.users(id, email) values (:'O', 'operador2@ok.test');
insert into public.profiles(id, full_name, email, role, status) values (:'O', 'Operador Dos', 'operador2@ok.test', 'DESPACHO', 'ACTIVO');
-- ===== SEGURIDAD: borradores con dueño =====
begin; select tst.u(:'D'); set local role authenticated;
select public.reserve_orders('SEC-D', array['50001']);
insert into tst.results(name, ok, detail) select 'SEC-01 El dueño opera su borrador (crea, reserva, confirma)', d.owner_id = :'D' and d.status = 'BORRADOR', d.status from public.route_drafts d where client_sheet_key = 'SEC-D';
select public.confirm_shipping_amount('{"sheet_key":"SEC-D","ship_order":"50002","detected_amount":9000,"confirmed_amount":9000,"fingerprint":"f"}');
commit;
begin; select tst.u(:'O'); set local role authenticated;
do $$ begin perform public.release_orders('SEC-D', null); insert into tst.results(name, ok, detail) values ('SEC-02 Otro operador no libera el borrador ajeno', false, 'liberó');
exception when others then insert into tst.results(name, ok, detail) values ('SEC-02 Otro operador no libera el borrador ajeno', sqlerrm like 'FORBIDDEN_DRAFT%', sqlerrm); end $$;
do $$ begin perform public.confirm_shipping_amount('{"sheet_key":"SEC-D","ship_order":"50002","detected_amount":9000,"confirmed_amount":1,"fingerprint":"g","reason":"x"}');
  insert into tst.results(name, ok, detail) values ('SEC-03 Otro operador no confirma envío del borrador ajeno', false, 'confirmó');
exception when others then insert into tst.results(name, ok, detail) values ('SEC-03 Otro operador no confirma envío del borrador ajeno', sqlerrm like 'FORBIDDEN_DRAFT%', sqlerrm); end $$;
do $$ begin perform public.invalidate_shipping_confirmation('SEC-D', '50002', 'zzz'); insert into tst.results(name, ok, detail) values ('SEC-03b Otro operador no invalida confirmaciones ajenas', false, '');
exception when others then insert into tst.results(name, ok, detail) values ('SEC-03b Otro operador no invalida confirmaciones ajenas', sqlerrm like 'FORBIDDEN_DRAFT%', sqlerrm); end $$;
do $$ begin perform public.reserve_orders('SEC-D', array['50003']); insert into tst.results(name, ok, detail) values ('SEC-03c Otro operador no reserva en el borrador ajeno', false, '');
exception when others then insert into tst.results(name, ok, detail) values ('SEC-03c Otro operador no reserva en el borrador ajeno', sqlerrm like 'FORBIDDEN_DRAFT%', sqlerrm); end $$;
do $$ begin perform public.publish_route('{"sheet_key":"SEC-D","carrier_id":"CT-ESTE","responsable_id":"00000000-0000-0000-0000-000000000003","stops":[{"client_name":"X","zone":"ESTE","order_numbers":["50001"],"shipping_fee":13000,"ready":true}]}');
  insert into tst.results(name, ok, detail) values ('SEC-04 Otro operador no publica el borrador ajeno', false, 'publicó');
exception when others then insert into tst.results(name, ok, detail) values ('SEC-04 Otro operador no publica el borrador ajeno', sqlerrm like 'FORBIDDEN_DRAFT%', sqlerrm); end $$;
commit;
begin; select tst.u(:'D'); set local role authenticated;
select public.publish_route('{"sheet_key":"SEC-D","carrier_id":"CT-ESTE","responsable_id":"00000000-0000-0000-0000-000000000003","stops":[{"client_name":"X","zone":"ESTE","order_numbers":["50001"],"shipping_fee":13000,"ready":true}]}');
insert into tst.results(name, ok, detail) select 'SEC-04b Al publicar el borrador queda PUBLICADA con la hoja asociada', d.status = 'PUBLICADA' and d.route_id is not null, d.status from public.route_drafts d where client_sheet_key = 'SEC-D';
do $$ begin perform public.release_orders('SEC-D', null); insert into tst.results(name, ok, detail) values ('SEC-05 Hoja publicada no libera reservas como borrador', false, 'liberó');
exception when others then insert into tst.results(name, ok, detail) values ('SEC-05 Hoja publicada no libera reservas como borrador', sqlerrm like 'DRAFT_PUBLISHED%', sqlerrm); end $$;
commit;
begin; select tst.u(:'O'); set local role authenticated;
select public.reserve_orders('SEC-O', array['50010']);
commit;
begin; select tst.u(:'A'); set local role authenticated;
insert into tst.results(name, ok, detail) select 'SEC-06 Admin con permiso global opera el borrador de otro', public.release_orders('SEC-O', null) = 1, '';
commit;
-- ===== RUTA INTERNA =====
update public.internal_route_notification_settings set supervisor_user_id = null, copy_admin = true, extra_emails = array['ADMIN@ok.test','logistica@ok.test'], email_enabled = true;
begin; select tst.svc(); set local role service_role;
select public.admin_update_profile(:'G', null, null, null, null, null, true, :'A');
commit;
begin; select tst.u(:'D'); set local role authenticated;
create temp table t_int as select (public.publish_route('{"sheet_key":"INT-1","carrier_id":"INTERNO","responsable_id":"00000000-0000-0000-0000-000000000001","stops":[
 {"client_name":"Depósito Norte","order_numbers":["60001"],"ready":true,"bultos":2},{"client_name":"Sucursal Centro","order_numbers":["60002"],"ready":true,"bultos":1},{"client_name":"Proveedor Sur","order_numbers":["60003"],"ready":true}]}')).*;
grant select on t_int to public;
commit;
begin; select tst.u(:'G'); set local role authenticated;
select public.start_route((select id from t_int));
select public.set_stop_outcome((select id from public.route_stops where route_id = (select id from t_int) and seq = 1), 'ENTREGADO', null, null, 'i-op1', tst.ev());
select public.add_internal_stop((select id from t_int), '{"client_name":"Banco (retirar)","address":"San Martín 1100","action":"RETIRO","bultos":"1"}', 1, 'i-add1');
select public.add_internal_stop((select id from t_int), '{"client_name":"Banco (retirar)","address":"San Martín 1100","action":"RETIRO","bultos":"1"}', 1, 'i-add1');
insert into tst.results(name, ok, detail) select 'INT-01 Agrega una parada (DRIVER, versión, actor, hora); reintento no duplica', count(*) = 1 and bool_and(s.provenance = 'DRIVER' and s.added_by = :'G' and s.added_at is not null), count(*)::text
  from public.route_stops s where route_id = (select id from t_int) and provenance = 'DRIVER';
do $$ begin perform public.add_internal_stop((select id from t_int), '{"client_name":"Otro"}', 1, 'i-add2');
  insert into tst.results(name, ok, detail) values ('INT-06 Conflicto de versión rechazado', false, '');
exception when others then insert into tst.results(name, ok, detail) values ('INT-06 Conflicto de versión rechazado', sqlerrm like 'VERSION_CONFLICT%', sqlerrm); end $$;
create temp table t_ids as select (select id from public.route_stops where route_id = (select id from t_int) and seq = 1) s1, (select id from public.route_stops where route_id = (select id from t_int) and seq = 2) s2,
  (select id from public.route_stops where route_id = (select id from t_int) and seq = 3) s3, (select id from public.route_stops where route_id = (select id from t_int) and seq = 4) s4;
grant select on t_ids to public;
do $$ begin perform public.reorder_internal_stops((select id from t_int), array[(select s3 from t_ids), (select s2 from t_ids), (select s4 from t_ids)], 2, 'i-r0');
  insert into tst.results(name, ok, detail) values ('INT-03 La parada actual no se mueve', false, '');
exception when others then insert into tst.results(name, ok, detail) values ('INT-03 La parada actual no se mueve', sqlerrm like 'CURRENT_STOP_FIXED%', sqlerrm); end $$;
do $$ begin perform public.reorder_internal_stops((select id from t_int), array[(select s4 from t_ids), (select s1 from t_ids), (select s3 from t_ids)], 2, 'i-r0b');
  insert into tst.results(name, ok, detail) values ('INT-04 Una parada completada no se mueve', false, '');
exception when others then insert into tst.results(name, ok, detail) values ('INT-04 Una parada completada no se mueve', sqlerrm like 'COMPLETED_STOP_FIXED%', sqlerrm); end $$;
select public.reorder_internal_stops((select id from t_int), array[(select s4 from t_ids), (select s3 from t_ids)], 2, 'i-r1');
select public.reorder_internal_stops((select id from t_int), array[(select s4 from t_ids), (select s3 from t_ids)], 2, 'i-r1');
insert into tst.results(name, ok, detail) select 'INT-02/05 Reordena solo las futuras y persiste (actual y completadas fijas)',
  (select array_agg(seq order by sequence_number) from public.route_stops where route_id = (select id from t_int)) = array[1,2,4,3]
  and (select version from public.routes where id = (select id from t_int)) = 3, (select array_agg(seq order by sequence_number)::text from public.route_stops where route_id = (select id from t_int));
insert into tst.results(name, ok, detail) select 'INT-07 Reintento offline (mismo op_id) no duplica eventos', count(*) = 2, count(*)::text from public.route_change_events where route_id = (select id from t_int);
select public.set_stop_outcome((select s2 from t_ids), 'ENTREGADO', null, null, 'i-o2', tst.ev());
select public.set_stop_outcome((select s4 from t_ids), 'ENTREGADO', null, null, 'i-o4', tst.ev());
select public.set_stop_outcome((select s3 from t_ids), 'NO_ENTREGADO', null, 'Cerrado', 'i-o3', tst.ev());
select public.finalize_route((select id from t_int));
select public.finalize_route((select id from t_int));
commit;
insert into tst.results(name, ok, detail) select 'APR-01 Con cambios: COMPLETADA · PENDIENTE DE APROBACIÓN, una sola solicitud', r.operational_status = 'COMPLETADA' and r.approval_status = 'PENDIENTE'
  and (select count(*) from public.route_approval_requests where route_id = r.id) = 1, r.operational_status || ' · ' || r.approval_status from public.routes r where id = (select id from t_int);
insert into tst.results(name, ok, detail) select 'APR-02 La ruta publicada original sigue trazable (snapshot + seq original)', jsonb_array_length(r.sheet_snapshot->'stops') = 3, '' from public.routes r where id = (select id from t_int);
insert into tst.results(name, ok, detail) select 'MAIL-01/02/03 Emails al superior, Administración y adicionales, sin duplicados',
  array_agg(recipient order by recipient) = array['admin@ok.test','logistica@ok.test'], array_agg(recipient order by recipient)::text from public.approval_email_jobs where route_id = (select id from t_int) and kind = 'INTERNAL_ROUTE_APPROVAL_REQUEST';
insert into tst.results(name, ok, detail) select 'MAIL-01b Notificación in-app al superior', count(*) = 1, count(*)::text from public.notifications where route_id = (select id from t_int) and user_id = :'A' and type = 'INTERNAL_ROUTE_APPROVAL_REQUEST';
begin; select tst.svc(); set local role service_role;
insert into tst.results(name, ok, detail) select 'MAIL-06 Reintento no duplica emails ni solicitud', public.queue_route_emails((select id from t_int), 3, 'INTERNAL_ROUTE_APPROVAL_REQUEST') = 0, '';
commit;
-- Sin superior: no bloquea, avisa a Administración y a adicionales
begin; select tst.svc(); set local role service_role;
select public.admin_update_profile(:'G', null, null, null, null, null, true, null);
commit;
begin; select tst.u(:'D'); set local role authenticated;
create temp table t_int2 as select (public.publish_route('{"sheet_key":"INT-2","carrier_id":"INTERNO","responsable_id":"00000000-0000-0000-0000-000000000001","stops":[{"client_name":"A","order_numbers":["60011"],"ready":true},{"client_name":"B","order_numbers":["60012"],"ready":true}]}')).*;
grant select on t_int2 to public;
commit;
begin; select tst.u(:'G'); set local role authenticated;
select public.start_route((select id from t_int2));
select public.add_internal_stop((select id from t_int2), '{"client_name":"C nueva"}', 1, 'i2-a');
select public.set_stop_outcome(id, 'ENTREGADO', null, null, 'i2-' || seq, tst.ev()) from public.route_stops where route_id = (select id from t_int2);
select public.finalize_route((select id from t_int2));
commit;
insert into tst.results(name, ok, detail) select 'MAIL-04 Sin superior: la hoja se completa, avisa a Administración y a los adicionales', r.operational_status = 'COMPLETADA' and q.supervisor_missing
  and exists (select 1 from public.notifications where route_id = r.id and type = 'INTERNAL_ROUTE_NO_SUPERVISOR' and user_id = '00000000-0000-0000-0000-00000000000a')
  and (select count(*) from public.approval_email_jobs where route_id = r.id) = 2, '' from public.routes r join public.route_approval_requests q on q.route_id = r.id where r.id = (select id from t_int2);
-- Aprobación / aclaración
begin; select tst.u(:'A'); set local role authenticated;
select public.review_route_approval((select id from public.route_approval_requests where route_id = (select id from t_int2)), 'OBSERVED', 'Explicar la parada C');
select public.review_route_approval((select id from public.route_approval_requests where route_id = (select id from t_int)), 'APPROVED', null);
commit;
insert into tst.results(name, ok, detail) select 'APR-03 Aprobar: COMPLETADA · APROBADA', approval_status = 'APROBADA' and operational_status = 'COMPLETADA', approval_status from public.routes where id = (select id from t_int);
insert into tst.results(name, ok, detail) select 'MAIL-07 Aclaración: COMPLETADA · OBSERVADA y avisa al chofer (in-app + email)', r.approval_status = 'OBSERVADA' and r.operational_status = 'COMPLETADA'
  and exists (select 1 from public.notifications where user_id = :'G' and route_id = r.id and type = 'INTERNAL_ROUTE_OBSERVED')
  and exists (select 1 from public.approval_email_jobs where route_id = r.id and kind = 'INTERNAL_ROUTE_OBSERVED' and recipient = 'gabriel.nuevo@ok.test'), '' from public.routes r where id = (select id from t_int2);
-- Passkeys: solo clave pública; revocación
begin; select tst.svc(); set local role service_role;
insert into public.user_passkeys(id, user_id, credential_id, public_key, device_name) values ('77777777-0000-0000-0000-000000000001', :'G', 'cred-1', 'pk-spki-b64', 'Celular de Gabriel');
commit;
insert into tst.results(name, ok, detail) select 'PASSKEY-06 (SQL) La tabla guarda solo clave pública y contador (sin biometría)',
  not exists (select 1 from information_schema.columns where table_name = 'user_passkeys' and column_name ~* 'bio|finger|face|template|image'), '';
begin; select tst.u(:'G'); set local role authenticated;
select public.revoke_passkey('77777777-0000-0000-0000-000000000001');
commit;
insert into tst.results(name, ok, detail) select 'PASSKEY-05 (SQL) Revocación', revoked_at is not null, '' from public.user_passkeys where id = '77777777-0000-0000-0000-000000000001';
