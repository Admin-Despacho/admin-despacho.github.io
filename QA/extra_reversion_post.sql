insert into rv_checks select 'RV-01 con un usuario con COMERCIAL restringido la reversión se DETIENE sin modificar nada', err like 'USUARIOS_CON_COMERCIAL_RESTRINGIDO%'
  and (select priv and perms from rv_a_estado), err from rv_a;
-- (b) reversión funcional
create or replace function pg_temp.rv_try(q text) returns text language plpgsql as $f$ begin perform set_config('okd.sync', 'on', true); execute q; return 'OK'; exception when others then return sqlerrm; end $f$;
insert into rv_checks select 'RV-02 el módulo queda INERTE: ninguna función comercial ejecutable por usuarios autenticados ni anónimos',
  not exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace and (p.proname like 'com\_%' or p.proname like '\_com\_%') and (has_function_privilege('authenticated', p.oid, 'EXECUTE') or has_function_privilege('anon', p.oid, 'EXECUTE'))), '' from (select 1) z;
insert into rv_checks select 'RV-03 objetos previos restaurados EXACTAMENTE: restricción de módulos sin COMERCIAL (conserva los demás), sin permisos COMERCIAL en module_permissions, queue_notification_push con sus 6 tipos originales',
  (select pg_get_constraintdef(oid) !~ 'COMERCIAL' and pg_get_constraintdef(oid) ~ 'DESPACHO' and pg_get_constraintdef(oid) ~ 'AUDITORIA' from pg_constraint where conname = 'profiles_disabled_modules_valid')
  and not exists (select 1 from public.module_permissions where module = 'COMERCIAL')
  and pg_get_functiondef('public.queue_notification_push()'::regprocedure) !~ 'COM_ALARMA' and pg_get_functiondef('public.queue_notification_push()'::regprocedure) ~ 'REQUEST_OBSERVED',
  (select pg_get_constraintdef(oid) from pg_constraint where conname = 'profiles_disabled_modules_valid') || ' · module_permissions COMERCIAL: ' || (select count(*) from public.module_permissions where module = 'COMERCIAL')
  || ' (' || coalesce((select string_agg(permission_code, ',') from public.module_permissions where module = 'COMERCIAL'), '') || ') · push con COM_ALARMA: ' || (pg_get_functiondef('public.queue_notification_push()'::regprocedure) ~ 'COM_ALARMA')::text from (select 1) z;
insert into rv_checks select 'RV-04 los DATOS y el HISTORIAL se CONSERVAN (solicitudes, alarmas y eventos) y la reversión queda auditada',
  (select count(*) from public.com_requests) = (select sol from rv_antes) and (select count(*) from public.com_alarms) = (select alr from rv_antes)
  and (select count(*) from public.com_alarm_events) = (select ev from rv_antes) and exists (select 1 from public.audit_log where action = 'COM_MODULE_REVERTED'),
  (select sol || ' solicitudes · ' || alr || ' alarmas' from rv_antes) from (select 1) z;
-- (c) lo existente sigue funcionando: un aviso de solicitud de hoja (tipo original) sigue yendo a la cola push; un aviso COM_ALARMA ya no
insert into public.notifications(user_id, type, title, body) values ('e0000000-0000-0000-0000-000000000006', 'REQUEST_CREATED', 'prueba', 'reversión');
insert into public.notifications(user_id, type, title, body) values ('e0000000-0000-0000-0000-000000000006', 'COM_ALARMA', 'prueba', 'reversión');
insert into rv_checks select 'RV-05 tras revertir, los avisos EXISTENTES siguen yendo a la cola push y los de la alarma ya no',
  exists (select 1 from public.notifications n join public.push_jobs j on j.notification_id = n.id where n.type = 'REQUEST_CREATED' and n.body = 'reversión')
  and not exists (select 1 from public.notifications n join public.push_jobs j on j.notification_id = n.id where n.type = 'COM_ALARMA' and n.body = 'reversión'), '' from (select 1) z;
insert into rv_checks select 'RV-06 la restricción restaurada SIGUE VIGENTE: rechaza un módulo inexistente y también COMERCIAL (no quedó vacía ni nula)',
  (select pg_get_constraintdef(oid) !~ 'NULL' from pg_constraint where conname = 'profiles_disabled_modules_valid')
  and pg_temp.rv_try($q$update public.profiles set disabled_modules = array['NO_EXISTE'] where id = 'c0000000-0000-0000-0000-0000000000c1'$q$) like '%profiles_disabled_modules_valid%'
  and pg_temp.rv_try($q$update public.profiles set disabled_modules = array['COMERCIAL'] where id = 'c0000000-0000-0000-0000-0000000000c1'$q$) like '%profiles_disabled_modules_valid%'
  and pg_temp.rv_try($q$update public.profiles set disabled_modules = array['INFORMES'] where id = 'c0000000-0000-0000-0000-0000000000c1'$q$) = 'OK', '' from (select 1) z;
