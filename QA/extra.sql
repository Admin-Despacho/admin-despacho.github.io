-- Independent Work audit: disposable PostgreSQL only.
create temp table work_checks(name text,ok boolean,detail text);
insert into work_checks select 'WORK-S01 Operario no consulta KPI directo', x like 'ERR FORBIDDEN%', x from (select pg_temp.get('e0000000-0000-0000-0000-000000000006',format('select public.com_kpi_for_client(%L)::text',pg_temp.cid('101'))) x) t;
insert into work_checks select 'WORK-S02 op_id ajeno no revela solicitud', x like 'ERR FORBIDDEN%' or x like 'ERR OP_ID%',x from (select pg_temp.get('c0000000-0000-0000-0000-0000000000c2',format($q$select public.com_create_request('FINANCIACION',%L,'x','{"amount":100,"installments":1}',null,'op-r1')::text$q$,pg_temp.cid('101'))) x) t;
select set_config('okd.sync','on',false);
update profiles set status='DESHABILITADO' where id='c0000000-0000-0000-0000-0000000000c1';
insert into work_checks select 'WORK-S03 deshabilitado no consulta KPI',x like 'ERR FORBIDDEN%',x from (select pg_temp.get('c0000000-0000-0000-0000-0000000000c1',format('select public.com_kpi_for_client(%L)::text',pg_temp.cid('101'))) x) t;
insert into work_checks select 'WORK-S04 deshabilitado no consulta notificaciones',x like 'ERR FORBIDDEN%' or x='[]',x from (select pg_temp.get('c0000000-0000-0000-0000-0000000000c1','select public.com_my_notifications()::text') x) t;
update profiles set status='ACTIVO' where id='c0000000-0000-0000-0000-0000000000c1';
select set_config('okd.sync','',false);
select pg_temp.get('e0000000-0000-0000-0000-000000000006',$q$select public.com_ingest('SC','{"hash":"work-same-file","loaded_at":"2026-11-10T09:00:00Z","batch":1,"batches":1}','[{"c":"QA","cuit":"30500010912","comp":"FAC A 0200-000001","d":"2026-10-01","m":100,"s":100}]')::text$q$);
select pg_temp.get('e0000000-0000-0000-0000-000000000006',$q$select public.com_ingest('SC','{"hash":"work-same-file","loaded_at":"2026-11-11T09:00:00Z","batch":1,"batches":1}','[{"c":"QA","cuit":"30500010912","comp":"FAC A 0200-000001","d":"2026-10-01","m":100,"s":100}]')::text$q$);
insert into work_checks select 'WORK-I01 misma carga dos dias registra ambas fechas', count(*)=2 and (select count(*) from com_sc_documents where comp='FAC A 0200-000001')=1, count(*)::text from com_ingests where content_hash='work-same-file';
insert into work_checks select 'WORK-I02 lote cero rechazado',x like 'BAD_INGEST%' or x like 'BAD_BATCH%',x from (select pg_temp.as('e0000000-0000-0000-0000-000000000006',$q$select public.com_ingest('SC','{"hash":"work-invalid-batch","batch":0,"batches":1}','[]')$q$) x)t;
insert into work_checks select 'WORK-S05 todas las tablas privadas sin acceso directo',bool_and(not has_table_privilege(r.role,c.oid,'SELECT,INSERT,UPDATE,DELETE')),'RLS y ACL' from pg_class c join pg_namespace n on n.oid=c.relnamespace cross join (values('anon'),('authenticated'))r(role) where n.nspname='public' and left(c.relname,4)='com_' and c.relkind='r';
insert into work_checks select 'WORK-S06 ninguna funcion comercial ejecutable por anon',bool_and(not has_function_privilege('anon',p.oid,'EXECUTE')),'EXECUTE' from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and (left(p.proname,4)='com_' or left(p.proname,5)='_com_');
create temp table work_nullver as select (pg_temp.get('c0000000-0000-0000-0000-0000000000c1',format($q$select public.com_create_request('FINANCIACION',%L,'QA-NULLVERSION','{"amount":100,"installments":1}',null,'work-null-version')::text$q$,pg_temp.cid('101')))::jsonb->>'id')::uuid id;
insert into work_checks select 'WORK-S07 version nula no crea decision fantasma',x like 'BAD_VERSION%' and (select status='PENDIENTE' from com_requests where id=(select id from work_nullver)),x from (select pg_temp.as('c0000000-0000-0000-0000-0000000000a1',format($q$select public.com_decide(%L,null,'APROBAR',null,null)$q$,(select id from work_nullver))) x)t;
-- Mismo comprobante, dos filas de cuota con el MISMO Monto original del documento.
select pg_temp.get('e0000000-0000-0000-0000-000000000006',$q$select public.com_ingest('SC','{"hash":"work-cuotas","loaded_at":"2026-11-12T09:00:00Z","batch":1,"batches":1}','[{"c":"QA","cuit":"30500010912","comp":"FAC A 0200-002222","q":"1","d":"2026-10-01","m":1000,"s":500},{"c":"QA","cuit":"30500010912","comp":"FAC A 0200-002222","q":"2","d":"2026-10-01","m":1000,"s":500}]')::text$q$);
insert into work_checks select 'WORK-K02 Monto original de una factura no se duplica por cuotas',sum(amount)=1000,jsonb_build_object('filas',count(*),'total_contado',sum(amount),'total_original',1000)::text from com_sc_documents where comp='FAC A 0200-002222' and status='OK';
-- Empty periods must not be inferred from a load before and another after them.
begin;
delete from com_ingest_batches; delete from com_cc_balances; delete from com_reconciliation_issues; delete from com_sc_documents; delete from com_ingests;
insert into com_ingests(kind,content_hash,at,by_user,status) values('SC','early','2025-01-01','e0000000-0000-0000-0000-000000000006','OK'),('SC','late','2025-04-01','e0000000-0000-0000-0000-000000000006','OK');
insert into work_checks select 'WORK-K01 mes sin cargas no tiene cobertura',not public._com_month_covered('2025-02-01'),public._com_month_covered('2025-02-01')::text;
-- Keep result outside rollback using a temp copy is impossible; restore the fixture with SAVEPOINT instead in harness.
commit;
select name,ok,detail from work_checks;
