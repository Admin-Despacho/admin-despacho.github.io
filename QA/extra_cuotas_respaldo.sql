-- SOLO PRUEBAS LOCALES · CUOTAS (WORK-K02, ambos formatos posibles) y RESPALDO PRIVADO (A-09). Datos FICTICIOS. Corre después de QA/extra.sql.
create temp table cr_checks(name text, ok boolean, detail text);
create or replace function pg_temp.cr_as(u uuid, q text) returns text language plpgsql as $f$ declare o text; begin perform tst.u(u); set local role authenticated; begin execute q into o; exception when others then o := 'ERR ' || sqlerrm; end; reset role; return o; end $f$;
create or replace function pg_temp.cr_ing(hash text, loaded text, rows_ jsonb, src uuid default null) returns text language sql as $f$
  select pg_temp.cr_as('e0000000-0000-0000-0000-000000000006', format('select public.com_ingest(''SC'', %L::jsonb, %L::jsonb)::text',
    jsonb_build_object('hash', hash, 'loaded_at', loaded, 'batch', 1, 'batches', 1) || case when src is null then '{}'::jsonb else jsonb_build_object('source_file_id', src) end, rows_)) $f$;
create or replace function pg_temp.cr_try(q text) returns text language plpgsql as $f$ begin execute q; return 'OK'; exception when others then return sqlerrm; end $f$;
create or replace function pg_temp.js(t text) returns jsonb language sql as $f$ select case when t like '{%' then t::jsonb end $f$;
create or replace function pg_temp.cr_rule(r text) returns void language sql as $f$ update public.com_settings set cuota_rule = r where id = 'DEFAULT' $f$;
create or replace function pg_temp.cr_sales(m date default '2026-08-01') returns jsonb language sql as $f$ select public._com_month_sales('30500010912', m) $f$;
create or replace function pg_temp.row_(comp text, d text, m numeric, q text default '', due text default '') returns jsonb language sql as $f$
  select jsonb_build_object('c', 'QA', 'cuit', '30500010912', 'comp', comp, 'd', d, 'm', m, 's', m, 'q', q, 'due', due) $f$;
delete from public.com_ingest_batches; delete from public.com_cc_balances; delete from public.com_reconciliation_issues; delete from public.com_sc_documents; delete from public.com_ingests;
-- ===== CUOTAS =====
select pg_temp.cr_ing('cr-1', '2026-08-20T09:00:00Z', jsonb_build_array(
  pg_temp.row_('FAC A 0001-00000501', '2026-08-10', 1000, '1'), pg_temp.row_('FAC A 0001-00000501', '2026-08-10', 1000, '2'),                     -- formato A posible: total repetido
  pg_temp.row_('FAC A 0001-00000502', '2026-08-11', 400, '1'), pg_temp.row_('FAC A 0001-00000502', '2026-08-11', 600, '2'),                       -- formato B: importe por cuota
  pg_temp.row_('FAC A 0001-00000503', '2026-08-12', 300, '1'), pg_temp.row_('FAC A 0001-00000503', '2026-08-12', 300, '2'), pg_temp.row_('FAC A 0001-00000503', '2026-08-12', 300, '3'),   -- 3 cuotas
  pg_temp.row_('FAC A 0001-00000504', '2026-08-13', 800, '', '2026-08-20'), pg_temp.row_('FAC A 0001-00000504', '2026-08-13', 800, '', '2026-08-27'),   -- partes SOLO por vencimiento
  pg_temp.row_('FAC A 0001-00000505', '2026-08-14', 500),                                                                                           -- factura simple
  pg_temp.row_('NOC A 0001-00000009', '2026-08-15', -100),                                                                                          -- nota de crédito
  pg_temp.row_('ANU 0001-00000001', '2026-08-16', 999)));                                                                                           -- anulación (no suma)
select pg_temp.cr_rule('POR_CONFIRMAR');
insert into cr_checks select 'CR-01 POR_CONFIRMAR (por defecto): un comprobante en CUOTAS NO entra al KPI ni se duplica; solo factura simple − NOC = 400; 4 comprobantes en cuotas «por confirmar»; ANU no suma',
  (x->>'amount')::numeric = 400 and (x->>'pend')::int = 4, x::text from (select pg_temp.cr_sales() x) t;
select pg_temp.cr_rule('MONTO_ES_TOTAL');
insert into cr_checks select 'CR-02 MONTO_ES_TOTAL: el monto repetido en las cuotas se cuenta UNA vez (1000 + 300 + 800 + 500 − 100 = 2500); la factura con importes DISTINTOS por cuota queda por confirmar',
  (x->>'amount')::numeric = 2500 and (x->>'pend')::int = 1, x::text from (select pg_temp.cr_sales() x) t;
select pg_temp.cr_rule('MONTO_ES_CUOTA');
insert into cr_checks select 'CR-03 MONTO_ES_CUOTA: se suman las partes (2000 + 1000 + 900 + 1600 + 500 − 100 = 5900); ninguna por confirmar',
  (x->>'amount')::numeric = 5900 and (x->>'pend')::int = 0, x::text from (select pg_temp.cr_sales() x) t;
insert into cr_checks select 'CR-04 partes distinguidas SOLO por vencimiento (sin número de cuota) se reconocen como 2 partes, igual que el Constructor (no se colapsan ni se descartan)',
  count(*) = 2 and count(distinct part_key) = 2, string_agg(part_key, ',') from public.com_sc_documents where comp = 'FAC A 0001-00000504';
-- repetición diaria del MISMO archivo (otra fecha de carga): ningún comprobante nuevo, mismos totales
create temp table cr_before as select count(*) n from public.com_sc_documents;
select pg_temp.cr_ing('cr-1', '2026-08-21T09:00:00Z', jsonb_build_array(pg_temp.row_('FAC A 0001-00000501', '2026-08-10', 1000, '1'), pg_temp.row_('FAC A 0001-00000501', '2026-08-10', 1000, '2'), pg_temp.row_('FAC A 0001-00000505', '2026-08-14', 500)));
insert into cr_checks select 'CR-05 REPETICIÓN DIARIA (misma carga otro día): ningún comprobante nuevo; los mismos totales (cada cuota vista dos veces, contada una)',
  (select count(*) from public.com_sc_documents) = (select n from cr_before) and (select seen_count from public.com_sc_documents where comp = 'FAC A 0001-00000505') = 2 and (pg_temp.cr_sales()->>'amount')::numeric = 5900, '';
-- cambio de importe de una cuota ya contada → conflicto y fuera del KPI
select pg_temp.cr_ing('cr-3', '2026-08-22T09:00:00Z', jsonb_build_array(pg_temp.row_('FAC A 0001-00000502', '2026-08-11', 650, '2')));
insert into cr_checks select 'CR-06 CAMBIO DE IMPORTE de una cuota: ese comprobante queda EN CONFLICTO y FUERA del KPI (no se suma ni se reemplaza en silencio)',
  (select status from public.com_sc_documents where comp = 'FAC A 0001-00000502' and part_key = '2') = 'CONFLICTO' and (pg_temp.cr_sales()->>'amount')::numeric = 5900 - 600, (pg_temp.cr_sales())::text;
select pg_temp.cr_rule('POR_CONFIRMAR');
insert into cr_checks select 'CR-07 NOTA DE CRÉDITO resta por valor absoluto y ANULACIÓN no suma (su relación con el comprobante anulado queda PENDIENTE del archivo real)',
  (select class from public.com_sc_documents where comp = 'NOC A 0001-00000009') = 'NOTA_CREDITO' and (select class from public.com_sc_documents where comp = 'ANU 0001-00000001') = 'ANULACION', '';
insert into cr_checks select 'CR-08 la regla por defecto queda POR_CONFIRMAR (la migración lo verifica al aplicarse)', cuota_rule = 'POR_CONFIRMAR', cuota_rule from public.com_settings where id = 'DEFAULT';
-- ===== RESPALDO PRIVADO DE ORIGINALES =====
insert into cr_checks select 'CR-09 respaldo APAGADO por defecto: registrar un original se rechaza (BACKUP_DISABLED) y las cargas siguen funcionando sin original',
  pg_temp.cr_as('e0000000-0000-0000-0000-000000000006', $q$select public.com_register_source_file('SC', repeat('a', 64), 1000, 'saldo.xlsx', 'application/vnd.ms-excel', 'SC/' || repeat('a', 64) || '.xlsx')::text$q$) like 'ERR BACKUP_DISABLED%'
  and pg_temp.cr_ing('cr-nos', '2026-08-23T09:00:00Z', jsonb_build_array(pg_temp.row_('FAC A 0001-00000506', '2026-08-15', 100))) not like 'ERR%', '';
update public.com_settings set source_backup_enabled = true where id = 'DEFAULT';
create temp table cr_st as select
  pg_temp.cr_as('e0000000-0000-0000-0000-000000000006', $q$insert into storage.objects(bucket_id, name) values ('com-sources', 'SC/' || repeat('b', 64) || '.xlsx') returning 'OK'$q$) op_ok,
  pg_temp.cr_as('e0000000-0000-0000-0000-000000000006', $q$insert into storage.objects(bucket_id, name) values ('com-sources', 'otra/carpeta/archivo.xlsx') returning 'OK'$q$) op_mala,
  pg_temp.cr_as('c0000000-0000-0000-0000-0000000000c1', $q$insert into storage.objects(bucket_id, name) values ('com-sources', 'SC/' || repeat('c', 64) || '.xlsx') returning 'OK'$q$) comercial,
  pg_temp.cr_as('e0000000-0000-0000-0000-000000000006', $q$select count(*)::text from storage.objects where bucket_id = 'com-sources'$q$) op_lee,
  pg_temp.cr_as('e0000000-0000-0000-0000-00000000000a', $q$select count(*)::text from storage.objects where bucket_id = 'com-sources'$q$) admin_lee,
  pg_temp.cr_as('e0000000-0000-0000-0000-00000000000a', $q$with u as (update storage.objects set name = 'SC/x.xlsx' where bucket_id = 'com-sources' returning 1) select count(*)::text from u$q$) admin_modifica,
  pg_temp.cr_as('e0000000-0000-0000-0000-00000000000a', $q$with u as (delete from storage.objects where bucket_id = 'com-sources' returning 1) select count(*)::text from u$q$) admin_borra;
insert into cr_checks select 'CR-10 ACCESO A ORIGINALES PRIVADOS: Depósito sube solo con la ruta por contenido; otra ruta y el Comercial se RECHAZAN; Depósito NO lee; solo el Administrador General lee; NADIE modifica ni borra',
  op_ok = 'OK' and op_mala like 'ERR%' and comercial like 'ERR%' and op_lee = '0' and admin_lee = '1' and admin_modifica = '0' and admin_borra = '0', row_to_json(cr_st)::text from cr_st;
create temp table cr_reg as select
  pg_temp.cr_as('e0000000-0000-0000-0000-000000000006', $q$select public.com_register_source_file('SC', repeat('b', 64), 2048, 'Saldo comprobante.xlsx', 'application/vnd.ms-excel', 'SC/' || repeat('d', 64) || '.xlsx')::text$q$) mala_ruta,
  pg_temp.cr_as('e0000000-0000-0000-0000-000000000006', $q$select public.com_register_source_file('SC', repeat('b', 64), 99999999, 'Saldo comprobante.xlsx', 'application/vnd.ms-excel', 'SC/' || repeat('b', 64) || '.xlsx')::text$q$) grande,
  pg_temp.cr_as('e0000000-0000-0000-0000-000000000006', $q$select public.com_register_source_file('SC', repeat('e', 64), 2048, 'Saldo comprobante.xlsx', 'application/vnd.ms-excel', 'SC/' || repeat('e', 64) || '.xlsx')::text$q$) no_subido,
  pg_temp.cr_as('e0000000-0000-0000-0000-000000000006', $q$select public.com_register_source_file('SC', repeat('b', 64), 2048, 'Saldo comprobante.xlsx', 'application/vnd.ms-excel', 'SC/' || repeat('b', 64) || '.xlsx')::text$q$) ok,
  pg_temp.cr_as('e0000000-0000-0000-0000-000000000006', $q$select public.com_register_source_file('SC', repeat('b', 64), 2048, 'Saldo comprobante.xlsx', 'application/vnd.ms-excel', 'SC/' || repeat('b', 64) || '.xlsx')::text$q$) repetido,
  pg_temp.cr_as('c0000000-0000-0000-0000-0000000000c1', $q$select public.com_register_source_file('SC', repeat('b', 64), 2048, 'Saldo comprobante.xlsx', 'application/vnd.ms-excel', 'SC/' || repeat('b', 64) || '.xlsx')::text$q$) comercial;
insert into cr_checks select 'CR-11 REGISTRO del original: ruta que no coincide con el hash, tamaño excesivo o archivo no subido se RECHAZAN; el correcto queda como versión 1; el mismo contenido no crea otra versión; el Comercial no registra',
  mala_ruta like 'ERR BAD_SOURCE%' and grande like 'ERR FILE_TOO_LARGE%' and no_subido like 'ERR SOURCE_NOT_UPLOADED%' and coalesce((pg_temp.js(ok)->>'version')::int = 1, false) and coalesce((pg_temp.js(repetido)->>'repeated')::boolean, false) and comercial like 'ERR FORBIDDEN%',
  mala_ruta || ' · ' || grande || ' · ' || no_subido || ' · OK=' || ok || ' · REP=' || repetido from cr_reg;
create temp table cr_link as select
  pg_temp.cr_ing('cr-sin-original', '2026-08-24T09:00:00Z', jsonb_build_array(pg_temp.row_('FAC A 0001-00000507', '2026-08-16', 100))) sin_original,
  pg_temp.cr_ing('cr-con-original', '2026-08-24T10:00:00Z', jsonb_build_array(pg_temp.row_('FAC A 0001-00000508', '2026-08-16', 200)), (pg_temp.js((select ok from cr_reg))->>'id')::uuid) con_original;
insert into cr_checks select 'CR-12 RESPALDO ACTIVO: una carga SIN su original se RECHAZA entera (SOURCE_REQUIRED, nada se guarda; el cliente la conserva y reintenta); CON su original queda vinculada',
  sin_original like 'ERR SOURCE_REQUIRED%' and not exists (select 1 from public.com_ingests where content_hash = 'cr-sin-original')
  and coalesce((select source_file_id from public.com_ingests where content_hash = 'cr-con-original') = (pg_temp.js((select ok from cr_reg))->>'id')::uuid, false), sin_original || ' · ' || con_original from cr_link;
insert into cr_checks select 'CR-13 FUENTES DEL KPI: el cálculo informa de qué carga, archivo, VERSIÓN y HASH salió cada comprobante (trazabilidad para la foto de la solicitud)',
  x::text like '%"file_version": 1%' and x::text like '%' || repeat('b', 64) || '%' and x::text like '%cr-con-original%', left(x::text, 300) from (select public._com_kpi_sources('30500010912', '2026-08-01', '2026-08-31') x) t;
insert into cr_checks select 'CR-14 los originales y sus versiones son INMUTABLES (ni el superusuario de la base los modifica o borra por SQL directo)',
  pg_temp.cr_try($q$update public.com_source_files set size_bytes = 1$q$) like 'IMMUTABLE%' and pg_temp.cr_try($q$delete from public.com_source_files$q$) like 'IMMUTABLE%', '' from (select 1) z;
insert into cr_checks select 'CR-15 privilegios: anon no registra originales; las funciones internas y la tabla de originales no son accesibles por usuarios',
  not has_function_privilege('anon', 'public.com_register_source_file(text,text,bigint,text,text,text)', 'EXECUTE') and not has_function_privilege('authenticated', 'public._com_month_sales(text,date)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public._com_link_source(bigint,text,jsonb)', 'EXECUTE') and not has_table_privilege('authenticated', 'public.com_source_files', 'SELECT'), '';
update public.com_settings set source_backup_enabled = false where id = 'DEFAULT';
