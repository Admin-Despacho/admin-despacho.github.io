-- SOLO POSTGRESQL LOCAL: casos negativos adicionales con los usuarios sintéticos del paquete.
-- Un permiso de gestión de usuarios delegado no convierte a otro rol en Administrador General.
select tst.res('AUD-00 Admin puede delegar users.manage por RPC real (sin cambiar el rol)',pg_temp.as(:'A',format($q$select public.set_user_permission(%L,'users.manage','GRANT','QA aislado')$q$,:'S2'))='OK');
select tst.res('AUD-01 Superior ajeno con users.manage NO lee incidencias de otros transportistas',pg_temp.n(:'S2')='0',pg_temp.n(:'S2'));
select tst.res('AUD-02 Superior ajeno con users.manage NO corrige documento de otro equipo',pg_temp.cor(:'S2','84014') like 'FORBIDDEN%',pg_temp.cor(:'S2','84007'));
delete from public.user_permission_overrides where user_id=:'S2' and permission_code='users.manage';
-- La idempotencia no debe devolver una gestión ajena antes de comprobar su alcance.
select tst.res('AUD-03 op_id de otro equipo NO devuelve la gestión ajena',
 pg_temp.get(:'S2',format($q$select to_jsonb(public.add_stop_followup(%L,'GESTION','Reintento ajeno',null,'fu-1'))::text$q$,(select id from s9))) like 'ERR FORBIDDEN_ROUTE%',
 pg_temp.get(:'S2',format($q$select to_jsonb(public.add_stop_followup(%L,'GESTION','Reintento ajeno',null,'fu-1'))::text$q$,(select id from s9))));
-- CUIT histórico contaminado en padrón personal: tampoco debe salir como CUIL por búsqueda de DNI.
insert into public.customer_identity_docs(cuil,dni,full_name,email,registered_by) values ('30500010912','50001091','Empresa histórica QA','empresa@example.invalid',:'A') on conflict(cuil) do update set dni=excluded.dni;
select tst.res('AUD-04 buscar padrón por DNI NO devuelve CUIT histórico como CUIL personal',
 pg_temp.get(:'G',format($q$select ((public.delivery_identity_lookup(%L,null,'50001091')->>'cuil') is null)::text$q$,(select id from st where o='84010')))='true',
 pg_temp.get(:'G',format($q$select public.delivery_identity_lookup(%L,null,'50001091')::text$q$,(select id from st where o='84010'))));
