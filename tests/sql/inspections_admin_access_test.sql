-- Prueba puntual, transaccional. Solo inspecciones de QA sobre el vehículo inactivo prueba/A121.
-- No envía correo. ROLLBACK conserva perfiles, inspecciones, eventos y datos comerciales.
-- nextval puede consumir números de inspección aunque la transacción se revierta; nunca resetear secuencias.
begin;
do $test$
declare
 a uuid; s uuid; o uuid; u uuid; v uuid; cid uuid:=gen_random_uuid(); oid uuid:=gen_random_uuid();
 i public.vehicle_inspections; rev public.vehicle_inspections; oi public.vehicle_inspections; si public.vehicle_inspections;
 items jsonb; checks jsonb:='[]'; before_events int; after_events int; mail_id bigint; original_hash text;
begin
 select id into strict a from public.profiles where role='ADMIN' and status='ACTIVO' order by id limit 1;
 select id into strict s from public.profiles where role='SUPERVISOR_DESPACHO' and status='ACTIVO' order by id limit 1;
 select id into strict o from public.profiles where role='OPERARIO_DEPOSITO' and status='ACTIVO' and supervisor_user_id=s order by id limit 1;
 select id into strict u from public.profiles where role='OPERARIO_DEPOSITO' and status='ACTIVO' and supervisor_user_id is null order by id limit 1;
 select id into strict v from public.vehicles where name='prueba' and plate='A121' and active=false;
 select jsonb_agg(jsonb_build_object('n',n,'result','BIEN')) into items from generate_series(1,30)n;
 perform set_config('request.jwt.claim.sub',a::text,true);
 perform set_config('request.jwt.claim.role','authenticated',true);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'role','authenticated')::text,true);
 execute 'set local role authenticated';
 i:=public.inspection_save_draft(jsonb_build_object('client_id',cid,'vehicle_id',v,'km',123,'general_observation','QA TRANSACCIONAL ADMIN - NO OPERATIVA'));
 if i.created_by<>a or i.status<>'BORRADOR' then raise exception 'TEST_FAILED: Admin create';end if;
 i:=public.inspection_save_draft(jsonb_build_object('client_id',cid,'vehicle_id',v,'km',124,'items',items));
 if i.km<>124 or (select count(*) from public.vehicle_inspection_items where inspection_id=i.id)<>30 then raise exception 'TEST_FAILED: save';end if;
 if not exists(select 1 from public.audit_log where target_id=i.id::text and action='INSPECTION_BORRADOR_GUARDADO' and actor_id=a) then raise exception 'TEST_FAILED: save audit';end if;
 checks:=checks||jsonb_build_array('Admin: crear, guardar y auditar borrador con 30 controles');
 i:=public.inspection_submit(i.id);
 if i.status<>'PENDIENTE' or i.team_supervisor_id is not null then raise exception 'TEST_FAILED: Admin requires supervisor';end if;
 select count(*) into before_events from public.vehicle_inspection_events where inspection_id=i.id;
 perform public.inspection_submit(i.id);
 select count(*) into after_events from public.vehicle_inspection_events where inspection_id=i.id;
 if before_events<>after_events then raise exception 'TEST_FAILED: duplicate submit';end if;
 i:=public.inspection_review(i.id,'APROBADA',null);
 if i.reviewed_by<>a or i.created_by<>a or i.reviewed_at is null then raise exception 'TEST_FAILED: self approve attribution';end if;
 perform public.inspection_review(i.id,'APROBADA',null);
 checks:=checks||jsonb_build_array('Admin: enviar sin Superior y autoaprobar; reintentos idempotentes; autor y aprobador');
 mail_id:=public.inspection_email_request(i.id,array['qa@example.invalid'],'QA sin envío','Solicitud transaccional; no despachar');
 if mail_id is null then raise exception 'TEST_FAILED: Admin email request';end if;
 checks:=checks||jsonb_build_array('Admin: solicitar correo (sin envío real, revertido)');
 select md5(to_jsonb(x)::text) into original_hash from public.vehicle_inspections x where id=i.id;
 rev:=public.inspection_new_revision(i.id,gen_random_uuid());
 if (public.inspection_new_revision(i.id,rev.client_id)).id<>rev.id then raise exception 'TEST_FAILED: revision idempotency';end if;
 if (select md5(to_jsonb(x)::text) from public.vehicle_inspections x where id=i.id)<>original_hash then raise exception 'TEST_FAILED: original changed';end if;
 rev:=public.inspection_submit(rev.id);
 begin perform public.inspection_review(rev.id,'RECHAZADA','');raise exception 'TEST_FAILED: missing reason';exception when check_violation then null;end;
 rev:=public.inspection_review(rev.id,'RECHAZADA','QA rechazo propio');
 if rev.reviewed_by<>a or rev.reject_reason<>'QA rechazo propio' then raise exception 'TEST_FAILED: self reject';end if;
 checks:=checks||jsonb_build_array('Admin: nueva revisión segura, original intacta y autorrechazo con motivo');

 execute 'reset role';
 perform set_config('request.jwt.claim.sub',s::text,true);perform set_config('request.jwt.claims',jsonb_build_object('sub',s,'role','authenticated')::text,true);
 execute 'set local role authenticated';
 if exists(select 1 from public.vehicle_inspections where id=i.id) then raise exception 'TEST_FAILED: Supervisor sees Admin team';end if;
 begin perform public.inspection_review(i.id,'APROBADA',null);raise exception 'TEST_FAILED: Supervisor foreign review';exception when insufficient_privilege then null;end;
 begin perform public.inspection_new_revision(i.id,rev.client_id);raise exception 'TEST_FAILED: foreign revision data leak';exception when insufficient_privilege then null;end;
 si:=public.inspection_save_draft(jsonb_build_object('client_id',gen_random_uuid(),'vehicle_id',v,'km',200,'items',items));
 si:=public.inspection_submit(si.id);si:=public.inspection_review(si.id,'APROBADA',null);
 if si.reviewed_by<>s then raise exception 'TEST_FAILED: Supervisor self review';end if;
 perform public.inspection_email_request(si.id,array['qa@example.invalid'],'QA sin envío','No despachar');
 checks:=checks||jsonb_build_array('Superior: crear, enviar, aprobar y solicitar correo intactos; equipo ajeno y revisión ajena denegados');

 execute 'reset role';
 perform set_config('request.jwt.claim.sub',o::text,true);perform set_config('request.jwt.claims',jsonb_build_object('sub',o,'role','authenticated')::text,true);
 execute 'set local role authenticated';
 oi:=public.inspection_save_draft(jsonb_build_object('client_id',oid,'vehicle_id',v,'km',300,'items',items));
 oi:=public.inspection_submit(oi.id);
 begin perform public.inspection_review(oi.id,'APROBADA',null);raise exception 'TEST_FAILED: Operator approves';exception when insufficient_privilege then null;end;
 begin perform public.inspection_email_request(si.id,array['qa@example.invalid'],'QA','No despachar');raise exception 'TEST_FAILED: Operator sends';exception when insufficient_privilege then null;end;
 begin perform public.inspection_new_revision(i.id,rev.client_id);raise exception 'TEST_FAILED: Operator foreign revision';exception when insufficient_privilege then null;end;
 begin update public.vehicle_inspections set status='APROBADA' where id=oi.id;raise exception 'TEST_FAILED: direct write';exception when insufficient_privilege then null;end;
 checks:=checks||jsonb_build_array('Operario: crear y enviar intactos; aprobación, correo, revisión ajena y escritura directa denegados');

 execute 'reset role';perform set_config('request.jwt.claim.sub',a::text,true);perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'role','authenticated')::text,true);
 execute 'set local role authenticated';
 if (select count(*) from public.vehicle_inspections where id in (i.id,si.id,oi.id))<>3 then raise exception 'TEST_FAILED: Admin global scope';end if;
 oi:=public.inspection_review(oi.id,'APROBADA',null);
 if oi.created_by<>o or oi.reviewed_by<>a then raise exception 'TEST_FAILED: Admin foreign author lost';end if;
 begin perform public.inspection_new_revision(si.id,cid);raise exception 'TEST_FAILED: client ID conflict leaked';exception when unique_violation then null;end;
 checks:=checks||jsonb_build_array('Admin: consulta y aprueba otros equipos sin cambiar autor; colisión de client_id denegada');

 execute 'reset role';perform set_config('request.jwt.claim.sub',u::text,true);perform set_config('request.jwt.claims',jsonb_build_object('sub',u,'role','authenticated')::text,true);
 execute 'set local role authenticated';
 oi:=public.inspection_save_draft(jsonb_build_object('client_id',gen_random_uuid(),'vehicle_id',v,'km',400,'items',items));
 begin perform public.inspection_submit(oi.id);raise exception 'TEST_FAILED: Operator without Supervisor submits';exception when check_violation then if sqlerrm not like 'SUPERVISOR_REQUIRED:%' then raise;end if;end;
 if not exists(select 1 from public.vehicle_inspections where id=oi.id and status='BORRADOR') then raise exception 'TEST_FAILED: draft lost';end if;
 checks:=checks||jsonb_build_array('Operario sin Superior: borrador conservado; envío denegado');

 execute 'reset role';perform set_config('okd.sync','on',true);
 update public.profiles set status='DESHABILITADO' where id=a;
 perform set_config('okd.sync','',true);
 perform set_config('request.jwt.claim.sub',a::text,true);perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'role','authenticated')::text,true);
 execute 'set local role authenticated';
 if exists(select 1 from public.vehicle_inspections) then raise exception 'TEST_FAILED: disabled reads';end if;
 begin perform public.inspection_save_draft(jsonb_build_object('client_id',gen_random_uuid(),'vehicle_id',v));raise exception 'TEST_FAILED: disabled saves';exception when insufficient_privilege then null;end;
 begin perform public.inspection_submit(i.id);raise exception 'TEST_FAILED: disabled submits';exception when insufficient_privilege then null;end;
 begin perform public.inspection_review(i.id,'APROBADA',null);raise exception 'TEST_FAILED: disabled reviews';exception when insufficient_privilege then null;end;
 begin perform public.inspection_new_revision(i.id,gen_random_uuid());raise exception 'TEST_FAILED: disabled revision';exception when insufficient_privilege then null;end;
 begin perform public.inspection_email_request(i.id,array['qa@example.invalid'],'QA','No despachar');raise exception 'TEST_FAILED: disabled email';exception when insufficient_privilege then null;end;
 checks:=checks||jsonb_build_array('Admin deshabilitado: RLS sin lecturas y las cinco RPC denegadas');
 execute 'reset role';
 perform set_config('okd.adminfix_test_results',checks::text,true);
end $test$;
select current_setting('okd.adminfix_test_results')::jsonb as results;
rollback;
