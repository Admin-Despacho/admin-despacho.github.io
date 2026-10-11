-- Pruebas de la migración Fase 1 sobre PostgreSQL 16 con simulación de auth de Supabase.
\set ON_ERROR_STOP on
create schema if not exists tst;
create table tst.results (id serial, name text, ok boolean, detail text);
grant usage on schema tst to public;
grant insert, select on tst.results to public;
grant usage on sequence tst.results_id_seq to public;

-- ---------- Datos de prueba (como superusuario) ----------
begin; -- en una transacción: la regla 'TRANSPORTISTA con carrier' se verifica al confirmar
insert into auth.users(id, email) values
 ('00000000-0000-0000-0000-00000000000a','admin@ok.test'),
 ('00000000-0000-0000-0000-00000000000d','despacho@ok.test'),
 ('00000000-0000-0000-0000-000000000001','gabriel@ok.test'),
 ('00000000-0000-0000-0000-000000000002','lucas@ok.test'),
 ('00000000-0000-0000-0000-000000000003','cristian@ok.test'),
 ('00000000-0000-0000-0000-000000000004','diego@ok.test'),
 ('00000000-0000-0000-0000-000000000005','uco@ok.test'),
 ('00000000-0000-0000-0000-000000000006','nuevo@ok.test');
insert into public.profiles(id, full_name, email, role, status) values
 ('00000000-0000-0000-0000-00000000000a','Administración','admin@ok.test','ADMIN','ACTIVO'),
 ('00000000-0000-0000-0000-00000000000d','Depósito','despacho@ok.test','DESPACHO','ACTIVO'),
 ('00000000-0000-0000-0000-000000000001','Gabriel Figueroa','gabriel@ok.test','TRANSPORTISTA_INTERNO','ACTIVO'),
 ('00000000-0000-0000-0000-000000000002','Lucas Méndez','lucas@ok.test','TRANSPORTISTA_INTERNO','DESHABILITADO'),
 ('00000000-0000-0000-0000-000000000003','Cristian Torres','cristian@ok.test','TRANSPORTISTA','ACTIVO'),
 ('00000000-0000-0000-0000-000000000004','Diego Ríos','diego@ok.test','TRANSPORTISTA','ACTIVO'),
 ('00000000-0000-0000-0000-000000000005','Transporte UCO','uco@ok.test','TRANSPORTISTA','ACTIVO'),
 ('00000000-0000-0000-0000-000000000006','Usuario Nuevo','nuevo@ok.test','SOLO_LECTURA','ACTIVO');
insert into public.user_carriers values
 ('00000000-0000-0000-0000-000000000003','CT-ESTE'),('00000000-0000-0000-0000-000000000003','CT-ALR'),
 ('00000000-0000-0000-0000-000000000004','CT-ALR'),('00000000-0000-0000-0000-000000000005','UCO');
commit;

-- Helper: ejecutar SQL como un usuario autenticado y registrar el resultado
create or replace function tst.as_user(p_uid text, p_role text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid, ''), true);
  perform set_config('request.jwt.claim.role', coalesce(p_role, ''), true);
end $$;
grant execute on function tst.as_user(text, text) to public;

-- ===== Selector de RESPONSABLE (servidor) =====
begin;
select tst.as_user('00000000-0000-0000-0000-00000000000d','authenticated'); set local role authenticated;
insert into tst.results(name, ok, detail)
  select 'S01 INTERNO → solo TRANSPORTISTA_INTERNO activos', array_agg(full_name order by full_name) = array['Gabriel Figueroa'], array_agg(full_name)::text from public.responsables_disponibles('INTERNO');
insert into tst.results(name, ok, detail)
  select 'S02 CT-ESTE → solo vinculados a CT-ESTE', array_agg(full_name order by full_name) = array['Cristian Torres'], array_agg(full_name)::text from public.responsables_disponibles('CT-ESTE');
insert into tst.results(name, ok, detail)
  select 'S03 CT-ALR → solo vinculados a CT-ALR', array_agg(full_name order by full_name) = array['Cristian Torres','Diego Ríos'], array_agg(full_name)::text from public.responsables_disponibles('CT-ALR');
insert into tst.results(name, ok, detail)
  select 'S04 UCO → solo vinculados a UCO', array_agg(full_name order by full_name) = array['Transporte UCO'], array_agg(full_name)::text from public.responsables_disponibles('UCO');
commit;

begin;
select tst.as_user('00000000-0000-0000-0000-000000000001','authenticated'); set local role authenticated;
do $$ begin
  perform * from public.responsables_disponibles('INTERNO');
  insert into tst.results(name, ok, detail) values ('S05 Sin routes.assign no puede pedir la lista', false, 'devolvió datos');
exception when others then
  insert into tst.results(name, ok, detail) values ('S05 Sin routes.assign no puede pedir la lista', sqlerrm like 'FORBIDDEN%', sqlerrm);
end $$;
commit;

-- Inserciones forzadas (el servidor rechaza aunque la pantalla se saltee)
begin;
select tst.as_user('00000000-0000-0000-0000-00000000000d','authenticated'); set local role authenticated;
do $$
declare cases text[][] := array[
  ['S06 INTERNO con Cristian Torres → rechazado','INTERNO','00000000-0000-0000-0000-000000000003'],
  ['S07 CT-ESTE con Gabriel Figueroa → rechazado','CT-ESTE','00000000-0000-0000-0000-000000000001'],
  ['S08 CT-ESTE con Diego Ríos (solo ALR) → rechazado','CT-ESTE','00000000-0000-0000-0000-000000000004'],
  ['S09 INTERNO con usuario DESHABILITADO → rechazado','INTERNO','00000000-0000-0000-0000-000000000002'],
  ['S10 UCO con Cristian Torres → rechazado','UCO','00000000-0000-0000-0000-000000000003']];
  i int;
begin
  for i in 1..array_length(cases,1) loop
    begin
      insert into public.routes(number, carrier_id, responsable_id) values ('T', cases[i][2], cases[i][3]::uuid);
      insert into tst.results(name, ok, detail) values (cases[i][1], false, 'se insertó');
    exception when others then
      insert into tst.results(name, ok, detail) values (cases[i][1], sqlerrm like 'RESPONSABLE_INCOMPATIBLE%', sqlerrm);
    end;
  end loop;
end $$;
insert into public.routes(id, number, carrier_id, responsable_id) values ('11111111-1111-1111-1111-111111111111','03-02','INTERNO','00000000-0000-0000-0000-000000000001');
insert into tst.results(name, ok, detail) values ('S11 INTERNO con Gabriel Figueroa → aceptado', true, 'insert ok');
insert into public.routes(id, number, carrier_id, responsable_id) values ('22222222-2222-2222-2222-222222222222','CTE-01','CT-ESTE','00000000-0000-0000-0000-000000000003');
insert into tst.results(name, ok, detail) values ('S12 CT-ESTE con Cristian Torres → aceptado', true, 'insert ok');
do $$ begin
  update public.routes set responsable_id = '00000000-0000-0000-0000-000000000003' where id = '11111111-1111-1111-1111-111111111111';
  insert into tst.results(name, ok, detail) values ('S13 Cambiar responsable a uno incompatible → rechazado', false, 'se actualizó');
exception when others then
  insert into tst.results(name, ok, detail) values ('S13 Cambiar responsable a uno incompatible → rechazado', sqlerrm like 'RESPONSABLE_INCOMPATIBLE%', sqlerrm);
end $$;
do $$ begin
  update public.routes set carrier_id = 'CT-ESTE' where id = '11111111-1111-1111-1111-111111111111';
  insert into tst.results(name, ok, detail) values ('S14 Cambiar carrier dejando responsable incompatible → rechazado', false, 'se actualizó');
exception when others then
  insert into tst.results(name, ok, detail) values ('S14 Cambiar carrier dejando responsable incompatible → rechazado', sqlerrm like 'RESPONSABLE_INCOMPATIBLE%', sqlerrm);
end $$;
commit;

-- ===== RLS de hojas =====
begin;
select tst.as_user('00000000-0000-0000-0000-000000000001','authenticated'); set local role authenticated;
do $$ begin
  insert into public.routes(number, carrier_id, responsable_id) values ('X','INTERNO','00000000-0000-0000-0000-000000000001');
  insert into tst.results(name, ok, detail) values ('S15 Transportista no puede crear hojas', false, 'insertó');
exception when others then
  insert into tst.results(name, ok, detail) values ('S15 Transportista no puede crear hojas', sqlerrm like '%row-level security%', sqlerrm);
end $$;
insert into tst.results(name, ok, detail) select 'S16 Gabriel ve solo sus hojas', count(*) = 1 and bool_and(number = '03-02'), count(*)::text from public.routes;
commit;
begin;
select tst.as_user('00000000-0000-0000-0000-000000000004','authenticated'); set local role authenticated;
insert into tst.results(name, ok, detail) select 'S17 Diego no ve hojas de otros', count(*) = 0, count(*)::text from public.routes;
commit;
begin;
select tst.as_user('00000000-0000-0000-0000-00000000000d','authenticated'); set local role authenticated;
insert into tst.results(name, ok, detail) select 'S18 Despacho (routes.view_all) ve todas', count(*) = 2, count(*)::text from public.routes;
commit;

-- ===== RLS de usuarios =====
begin;
select tst.as_user('00000000-0000-0000-0000-000000000001','authenticated'); set local role authenticated;
insert into tst.results(name, ok, detail) select 'S19 Transportista ve solo su perfil', count(*) = 1, count(*)::text from public.profiles;
do $$ begin
  update public.profiles set role = 'ADMIN' where id = '00000000-0000-0000-0000-000000000001';
  insert into tst.results(name, ok, detail) values ('S20 Nadie cambia su propio rol', false, 'cambió');
exception when others then
  insert into tst.results(name, ok, detail) values ('S20 Nadie cambia su propio rol', sqlerrm like '%permission denied%' or sqlerrm like 'FORBIDDEN%', sqlerrm);
end $$;
update public.profiles set phone = '261-555-0101' where id = '00000000-0000-0000-0000-000000000001';
insert into tst.results(name, ok, detail) select 'S21 Puede editar su propio teléfono', phone = '261-555-0101', phone from public.profiles where id = '00000000-0000-0000-0000-000000000001';
do $$ declare n int; begin
  update public.profiles set phone = 'X' where id = '00000000-0000-0000-0000-000000000003';
  get diagnostics n = row_count;
  insert into tst.results(name, ok, detail) values ('S22 No puede editar el perfil de otro', n = 0, n || ' filas');
end $$;
insert into tst.results(name, ok, detail) select 'S23 Transportista no ve auditoría', count(*) = 0, count(*)::text from public.audit_log;
commit;

begin;
select tst.as_user('00000000-0000-0000-0000-00000000000a','authenticated'); set local role authenticated;
insert into tst.results(name, ok, detail) select 'S24 Admin (users.view) ve todos los perfiles', count(*) = 8, count(*)::text from public.profiles;
do $$ begin
  update public.profiles set role = 'DESPACHO' where id = '00000000-0000-0000-0000-00000000000a';
  insert into tst.results(name, ok, detail) values ('S25 Admin no cambia su propio rol desde la app', false, 'cambió');
exception when others then
  insert into tst.results(name, ok, detail) values ('S25 Admin no cambia su propio rol desde la app', sqlerrm like '%permission denied%' or sqlerrm like 'FORBIDDEN%', sqlerrm);
end $$;
do $$ begin
  update public.profiles set full_name = 'Hackeo' where id = '00000000-0000-0000-0000-000000000003';
  insert into tst.results(name, ok, detail) values ('S26 Admin tampoco edita perfiles ajenos sin pasar por el servidor', (select full_name from public.profiles where id='00000000-0000-0000-0000-000000000003') <> 'Hackeo', 'sin cambios');
exception when others then
  insert into tst.results(name, ok, detail) values ('S26 Admin tampoco edita perfiles ajenos sin pasar por el servidor', true, sqlerrm);
end $$;
commit;

begin;
set local role anon;
do $$ begin
  perform * from public.profiles;
  insert into tst.results(name, ok, detail) values ('S27 Sin sesión no se leen usuarios', false, 'leyó');
exception when others then
  insert into tst.results(name, ok, detail) values ('S27 Sin sesión no se leen usuarios', true, sqlerrm);
end $$;
commit;

-- ===== Operaciones del servidor (service_role, como la Edge Function) =====
begin;
select tst.as_user(null,'service_role'); set local role service_role;
do $$ begin
  update public.profiles set role = 'DESPACHO' where id = '00000000-0000-0000-0000-00000000000a';
  insert into tst.results(name, ok, detail) values ('S28 No se puede quitar el último ADMIN activo', false, 'cambió');
exception when others then
  insert into tst.results(name, ok, detail) values ('S28 No se puede quitar el último ADMIN activo', sqlerrm like 'LAST_ADMIN%', sqlerrm);
end $$;
do $$ begin
  update public.profiles set status = 'DESHABILITADO' where id = '00000000-0000-0000-0000-00000000000a';
  insert into tst.results(name, ok, detail) values ('S29 No se puede deshabilitar el último ADMIN activo', false, 'cambió');
exception when others then
  insert into tst.results(name, ok, detail) values ('S29 No se puede deshabilitar el último ADMIN activo', sqlerrm like 'LAST_ADMIN%', sqlerrm);
end $$;
update public.profiles set role = 'TRANSPORTISTA_INTERNO' where id = '00000000-0000-0000-0000-000000000006';
insert into tst.results(name, ok, detail) select 'S30 El servidor cambia rol de otro usuario', role = 'TRANSPORTISTA_INTERNO', role from public.profiles where id = '00000000-0000-0000-0000-000000000006';
do $$ begin
  delete from auth.users where id = '00000000-0000-0000-0000-000000000001';
  insert into tst.results(name, ok, detail) values ('S31 Usuario con historial no se elimina (se archiva)', false, 'se eliminó');
exception when others then
  insert into tst.results(name, ok, detail) values ('S31 Usuario con historial no se elimina (se archiva)', sqlerrm like 'HAS_HISTORY%', sqlerrm);
end $$;
-- Fase 1.1: con hojas activas no se archiva; primero se finaliza la hoja de prueba
update public.routes set operational_status = 'COMPLETADA' where responsable_id = '00000000-0000-0000-0000-000000000001';
update public.profiles set status = 'ARCHIVADO', archived_at = now() where id = '00000000-0000-0000-0000-000000000001';
insert into tst.results(name, ok, detail) select 'S32 Archivar conserva la hoja y el nombre del responsable', p.status = 'ARCHIVADO' and r.responsable_id = p.id and p.full_name = 'Gabriel Figueroa', p.status from public.profiles p join public.routes r on r.responsable_id = p.id where p.id = '00000000-0000-0000-0000-000000000001';
insert into tst.results(name, ok, detail) select 'S33 Usuario archivado ya no es responsable compatible', not public.can_be_responsable('00000000-0000-0000-0000-000000000001','INTERNO'), '';
delete from auth.users where id = '00000000-0000-0000-0000-000000000006';
insert into tst.results(name, ok, detail) select 'S34 Usuario sin historial se elimina definitivamente', not exists (select 1 from public.profiles where id = '00000000-0000-0000-0000-000000000006'), '';
update public.profiles set status = 'ACTIVO' where id = '00000000-0000-0000-0000-000000000001';
insert into tst.results(name, ok, detail) select 'S35 Reactivar conserva el mismo id e historial', exists (select 1 from public.routes where responsable_id = '00000000-0000-0000-0000-000000000001') and public.can_be_responsable('00000000-0000-0000-0000-000000000001','INTERNO'), '';
commit;

begin;
select tst.as_user('00000000-0000-0000-0000-00000000000d','authenticated'); set local role authenticated;
do $$ begin
  insert into public.carriers(id, name, kind) values ('NUEVO','NUEVO','EXTERNO');
  insert into tst.results(name, ok, detail) values ('S36 Despacho sin settings.manage no edita carriers', false, 'insertó');
exception when others then
  insert into tst.results(name, ok, detail) values ('S36 Despacho sin settings.manage no edita carriers', sqlerrm like '%row-level security%', sqlerrm);
end $$;
commit;

