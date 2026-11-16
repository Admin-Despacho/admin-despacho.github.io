-- SOLO PRUEBAS LOCALES · KPI DE FACTURACIÓN (regla oficial de Dirección General) con DATOS CONTROLADOS cargados por la INGESTA REAL (com_ingest).
-- Valores ilustrativos: NO representan información real de Cianbox. WORK-K02 sigue abierto (semántica real de cuotas y saldos).
create temp table kpi_checks(name text, ok boolean, detail text);
create or replace function pg_temp.kq(u uuid, q text) returns text language plpgsql as $f$ declare o text; begin perform tst.u(u); set local role authenticated; begin execute q into o; exception when others then o := 'ERR ' || sqlerrm; end; reset role; return o; end $f$;
\set A  'e0000000-0000-0000-0000-00000000000a'
\set O  'e0000000-0000-0000-0000-000000000006'
\set C1 'c0000000-0000-0000-0000-0000000000c1'
-- primera carga (20/11): cliente A (30710000014) y cliente B (30710000022)
create temp table kpi_rows1 as select $j$[
 {"cuit":"30710000014","c":"CLIENTE KPI A","comp":"FAC A 0001-00000001","d":"2026-11-05","m":100000,"s":0},
 {"cuit":"30710000014","c":"CLIENTE KPI A","comp":"FAC A 0001-00000002","d":"2026-11-10","m":200000,"s":80000},
 {"cuit":"30710000014","c":"CLIENTE KPI A","comp":"FAC A 0001-00000003","d":"2026-11-30","m":50000,"s":50000},
 {"cuit":"30710000014","c":"CLIENTE KPI A","comp":"FAC A 0001-00000004","d":"2026-10-31","m":70000,"s":0},
 {"cuit":"30710000014","c":"CLIENTE KPI A","comp":"FAC A 0001-00000005","d":"2026-11-15","q":"1","m":90000,"s":45000},
 {"cuit":"30710000014","c":"CLIENTE KPI A","comp":"FAC A 0001-00000005","d":"2026-11-15","q":"2","m":90000,"s":45000},
 {"cuit":"30710000014","c":"CLIENTE KPI A","comp":"FAC A 0001-00000006","d":"2026-11-12","m":40000,"s":40000},
 {"cuit":"30710000014","c":"CLIENTE KPI A","comp":"NOC A 0001-00000009","d":"2026-11-20","m":10000,"s":0},
 {"cuit":"30710000014","c":"CLIENTE KPI A","comp":"ANU A 0001-00000010","d":"2026-11-21","m":5000,"s":0},
 {"cuit":"30710000022","c":"CLIENTE KPI B","comp":"FAC B 0002-00000001","d":"2026-11-07","m":30000,"s":30000}]$j$::jsonb r;
select pg_temp.kq(:'O', format($q$select public.com_ingest('SC', '{"hash":"kpi-h1","file_name":"saldo_comprobante_20261120.xlsx","loaded_at":"2026-11-20T12:00:00Z","batch":1,"batches":1}'::jsonb, %L::jsonb)::text$q$, (select r from kpi_rows1)));
-- la MISMA carga importada otra vez (mismo archivo): no debe duplicar
select pg_temp.kq(:'O', format($q$select public.com_ingest('SC', '{"hash":"kpi-h1","file_name":"saldo_comprobante_20261120.xlsx","loaded_at":"2026-11-20T12:00:00Z","batch":1,"batches":1}'::jsonb, %L::jsonb)::text$q$, (select r from kpi_rows1)));
create or replace function pg_temp.kj(t text) returns jsonb language sql as $f$ select case when t like '{%' or t like '[%' then t::jsonb else jsonb_build_object('error', t) end $f$;
create or replace function pg_temp.kb() returns jsonb language sql as $f$ select pg_temp.kj(pg_temp.kq('e0000000-0000-0000-0000-00000000000a', $q$select public.com_kpi_billing('2026-10-01', '2026-11-30')::text$q$)) $f$;
create or replace function pg_temp.km(j jsonb, mes text) returns jsonb language sql as $f$ select x from jsonb_array_elements(j->'meses') x where x->>'mes' = mes $f$;
create or replace function pg_temp.kd(comp text) returns jsonb language sql as $f$
  select x from jsonb_array_elements(coalesce(pg_temp.kj(pg_temp.kq('e0000000-0000-0000-0000-00000000000a', $q$select public.com_kpi_billing_detail('2026-11', '{}'::jsonb, 0, 500)::text$q$))->'items', '[]')) x where x->>'comp' = comp $f$;
create temp table kpi_dbg as select pg_temp.kb()->>'error' e_kpi, pg_temp.kj(pg_temp.kq('e0000000-0000-0000-0000-00000000000a', $q$select public.com_kpi_billing_detail('2026-11', '{}'::jsonb, 0, 5)::text$q$))->>'error' e_det;
insert into kpi_checks select 'K-00 diagnóstico: com_kpi_billing y su detalle responden sin error', e_kpi is null and e_det is null, coalesce(e_kpi, '') || ' | ' || coalesce(e_det, '') from kpi_dbg;
create temp table kpi_1 as select pg_temp.kb() j, pg_temp.kd('FAC A 0001-00000001') f1, pg_temp.kd('FAC A 0001-00000002') f2;
insert into kpi_checks select 'K-01 EJEMPLO de Dirección: factura de $100.000 con saldo 0 → facturada 100.000 y ABONADA; factura de $200.000 con saldo $80.000 → facturada 200.000, PARCIAL, abonado inferido 120.000',
  (f1->>'original')::numeric = 100000 and f1->>'estado_pago' = 'ABONADA' and (f1->>'abonado')::numeric = 100000
  and (f2->>'original')::numeric = 200000 and (f2->>'saldo')::numeric = 80000 and f2->>'estado_pago' = 'PARCIAL' and (f2->>'abonado')::numeric = 120000,
  (f1->>'estado_pago') || ' / ' || (f2->>'estado_pago') || ' abonado ' || (f2->>'abonado') from kpi_1;
insert into kpi_checks select 'K-02 NOVIEMBRE · 1.ª carga (cuotas POR_CONFIRMAR): facturación = importe ORIGINAL por mes de EMISIÓN, abonadas incluidas = 420.000 (100+200+50+40+30 mil); 5 facturas; 2 clientes; ticket 84.000; saldo 200.000; abonado 220.000; NC 10.000; neta 410.000; 1 anulación; 1 excluida (la de 2 cuotas)',
  (m->>'facturacion_bruta')::numeric = 420000 and (m->>'facturas')::int = 5 and (m->>'clientes')::int = 2 and (m->>'ticket_promedio')::numeric = 84000
  and (m->>'saldo_pendiente')::numeric = 200000 and (m->>'abonado_inferido')::numeric = 220000 and (m->>'notas_credito')::numeric = 10000
  and (m->>'facturacion_neta')::numeric = 410000 and (m->>'anuladas')::int = 1 and (m->>'facturas_excluidas')::int = 1, m::text
  from (select pg_temp.km(j, '2026-11') m from kpi_1) z;
insert into kpi_checks select 'K-03 CAMBIO DE MES por fecha de EMISIÓN: la factura del 31/10 cuenta en OCTUBRE (70.000) y la del 30/11 en NOVIEMBRE',
  (pg_temp.km(j, '2026-10')->>'facturacion_bruta')::numeric = 70000 and (pg_temp.km(j, '2026-10')->>'facturas')::int = 1 and pg_temp.kd('FAC A 0001-00000003')->>'mes' = '2026-11', '' from kpi_1;
insert into kpi_checks select 'K-04 IMPORTAR DOS VECES el mismo archivo NO duplica: una sola carga registrada y cada comprobante una vez',
  (select count(*) from public.com_ingests where content_hash = 'kpi-h1') = 1 and (select count(*) from public.com_sc_documents where cuit = '30710000014' and comp_n like '%00000002%') = 1, '' from (select 1) z;
insert into kpi_checks select 'K-05 CUOTAS no son facturas adicionales: con la regla POR_CONFIRMAR el comprobante de 2 cuotas queda EXCLUIDO (con motivo) y NO se suma 180.000',
  (select x->>'excluido' like 'ORIGINAL_POR_CONFIRMAR%' and (x->>'partes')::int = 2 from (select pg_temp.kd('FAC A 0001-00000005') x) q), (select pg_temp.kd('FAC A 0001-00000005')->>'excluido') from (select 1) z;
-- segunda carga (25/11): la factura 2 ya PAGADA (saldo 0) y la factura 6 con su importe ORIGINAL cambiado (conflicto)
select pg_temp.kq(:'O', $q$select public.com_ingest('SC', '{"hash":"kpi-h2","file_name":"saldo_comprobante_20261125.xlsx","loaded_at":"2026-11-25T12:00:00Z","batch":1,"batches":1}'::jsonb,
  '[{"cuit":"30710000014","c":"CLIENTE KPI A","comp":"FAC A 0001-00000002","d":"2026-11-10","m":200000,"s":0},
    {"cuit":"30710000014","c":"CLIENTE KPI A","comp":"FAC A 0001-00000006","d":"2026-11-12","m":41000,"s":41000}]'::jsonb)::text$q$);
create temp table kpi_2 as select pg_temp.kb() j, pg_temp.kd('FAC A 0001-00000002') f2, pg_temp.kd('FAC A 0001-00000006') f6;
insert into kpi_checks select 'K-06 ACTUALIZACIÓN DE SALDO: la factura de 200.000 pagada en la 2.ª carga queda ABONADA y la facturación NO cambia por el pago (sigue 200.000); la traza muestra la ÚLTIMA carga y su archivo',
  (f2->>'original')::numeric = 200000 and f2->>'estado_pago' = 'ABONADA' and (f2->>'saldo')::numeric = 0 and f2->'archivo'->>'archivo' = 'saldo_comprobante_20261125.xlsx', f2::text from kpi_2;
insert into kpi_checks select 'K-07 IMPORTE ORIGINAL CAMBIADO entre cargas: el comprobante queda EXCLUIDO como conflicto (no se sobrescribe el original ni se suma dos veces)',
  f6->>'excluido' like 'DATOS_DEL_COMPROBANTE%CONFLICTO%', f6->>'excluido' from kpi_2;
insert into kpi_checks select 'K-08 NOVIEMBRE · 2.ª carga: facturación 380.000 (sale la de 40.000 en conflicto; el PAGO no la reduce); 4 facturas; saldo 80.000 (50+30 mil); abonado 300.000; 2 excluidas; corte = carga del 25/11 y 2 archivos de origen',
  (m->>'facturacion_bruta')::numeric = 380000 and (m->>'facturas')::int = 4 and (m->>'saldo_pendiente')::numeric = 80000 and (m->>'abonado_inferido')::numeric = 300000
  and (m->>'facturas_excluidas')::int = 2 and (j->'corte'->>'ultima_carga')::timestamptz = timestamptz '2026-11-25T12:00:00Z' and jsonb_array_length(j->'archivos') >= 2, m::text
  from (select j, pg_temp.km(j, '2026-11') m from kpi_2) z;
-- reglas de cuotas y de saldo
update public.com_settings set cuota_rule = 'MONTO_ES_TOTAL' where id = 'DEFAULT';
create temp table kpi_3 as select pg_temp.kd('FAC A 0001-00000005') f5, pg_temp.kb() j,
  pg_temp.kq(:'A', $q$select public.com_set_saldo_rule('POR_PARTE', null)::text$q$) sin_fund;
select pg_temp.kq(:'A', $q$select public.com_set_saldo_rule('POR_PARTE', 'Archivo real de Cianbox (prueba local, no real)')::text$q$);
alter table kpi_3 add column f5b jsonb; update kpi_3 set f5b = pg_temp.kd('FAC A 0001-00000005');
select pg_temp.kq(:'A', $q$select public.com_set_saldo_rule('REPETIDO', 'Archivo real de Cianbox (prueba local, no real)')::text$q$);
alter table kpi_3 add column f5c jsonb; update kpi_3 set f5c = pg_temp.kd('FAC A 0001-00000005');
insert into kpi_checks select 'K-09 VARIAS CUOTAS con la regla MONTO_ES_TOTAL: el original se cuenta UNA vez (90.000, nunca 180.000); saldo: POR_CONFIRMAR → no determinado; POR_PARTE → 90.000 PENDIENTE; REPETIDO → 45.000 PARCIAL (abonado 45.000)',
  (f5->>'original')::numeric = 90000 and f5->>'excluido' is null and f5->>'estado_pago' = 'SALDO_NO_DETERMINADO'
  and (f5b->>'saldo')::numeric = 90000 and f5b->>'estado_pago' = 'PENDIENTE' and (f5c->>'saldo')::numeric = 45000 and f5c->>'estado_pago' = 'PARCIAL' and (f5c->>'abonado')::numeric = 45000
  and (pg_temp.km(j, '2026-11')->>'facturacion_bruta')::numeric = 470000,
  (f5->>'estado_pago') || ' | ' || (f5b->>'estado_pago') || ' | ' || (f5c->>'estado_pago') || ' | bruta ' || (pg_temp.km(j, '2026-11')->>'facturacion_bruta') from kpi_3;
insert into kpi_checks select 'K-10 la regla de saldo exige FUNDAMENTO (archivo real que la respalda) y queda AUDITADA',
  sin_fund like 'ERR FUNDAMENTO_REQUERIDO%' and exists (select 1 from public.audit_log where action = 'COM_SALDO_RULE' and after->>'fundamento' like 'Archivo real%'), left(sin_fund, 40) from kpi_3;
update public.com_settings set cuota_rule = 'POR_CONFIRMAR', saldo_rule = 'POR_CONFIRMAR' where id = 'DEFAULT';
-- saldo NEGATIVO o mayor al original: A_REVISAR (se conserva el signo; no se asume deuda)
select pg_temp.kq(:'O', $q$select public.com_ingest('SC', '{"hash":"kpi-h3","file_name":"saldo_comprobante_20261126.xlsx","loaded_at":"2026-11-26T12:00:00Z","batch":1,"batches":1}'::jsonb,
  '[{"cuit":"30710000022","c":"CLIENTE KPI B","comp":"FAC B 0002-00000002","d":"2026-11-08","m":10000,"s":-500},
    {"cuit":"30710000022","c":"CLIENTE KPI B","comp":"FAC B 0002-00000003","d":"2026-11-09","m":10000,"s":12000}]'::jsonb)::text$q$);
insert into kpi_checks select 'K-11 SALDO NEGATIVO o MAYOR que el original: estado A_REVISAR, se CONSERVA el signo y NO se infiere ningún abonado',
  (select x->>'estado_pago' = 'A_REVISAR' and (x->>'saldo')::numeric = -500 and x->>'abonado' is null from (select pg_temp.kd('FAC B 0002-00000002') x) a)
  and (select x->>'estado_pago' = 'A_REVISAR' and x->>'abonado' is null from (select pg_temp.kd('FAC B 0002-00000003') x) b), '' from (select 1) z;
insert into kpi_checks select 'K-12 TRAZABILIDAD de cada cifra: comprobante, cliente, CUIT, emisión, partes, original, saldo, estado, carga primera/última, archivo y corte',
  (select x ?& array['comprobante', 'cliente', 'cuit', 'emision', 'partes', 'original', 'saldo', 'estado_pago', 'carga_primera', 'carga_ultima', 'archivo'] and x->'archivo' ?& array['archivo', 'huella', 'cargado', 'corte']
     from (select pg_temp.kd('FAC A 0001-00000003') x) q), '' from (select 1) z;
insert into kpi_checks select 'K-13 USO: SOLO el Administrador (Comercial → FORBIDDEN) y rotulado «VALIDACIÓN — NO OPERATIVO» con el KPI deshabilitado',
  pg_temp.kq(:'C1', $q$select public.com_kpi_billing('2026-10-01', '2026-11-30')::text$q$) like 'ERR FORBIDDEN%'
  and pg_temp.kq(:'C1', $q$select public.com_kpi_billing_detail('2026-11', '{}'::jsonb, 0, 10)::text$q$) like 'ERR FORBIDDEN%'
  and (select (case when (select kpi_mode from public.com_settings) = 'PROVISORIO' then true else (pg_temp.kb()->>'uso') like 'VALIDACIÓN — NO OPERATIVO%' end)), '' from (select 1) z;
-- ===== punto 4 · saldo de cuenta corriente con ORIGEN y VERIFICACIÓN (cliente EXISTENTE del padrón de prueba) =====
create temp table kpi_cc as select id cid, cuit from public.com_clients where cuit is not null and public._cuit_valid(cuit) order by erp_id limit 1;
select pg_temp.kq(:'O', format($q$select public.com_ingest('CC', '{"hash":"kpi-cc1","file_name":"cuenta_corriente_20261126.xlsx","loaded_at":"2026-11-26T12:00:00Z","batch":1,"batches":1}'::jsonb, %L::jsonb)::text$q$,
  jsonb_build_array(jsonb_build_object('cuit', (select cuit from kpi_cc), 'c', 'CLIENTE CC', 'saldo', 1250000))));
create temp table kpi_cc2 as select pg_temp.kj(pg_temp.kq(:'A', format('select public.com_client_finance(%L)::text', (select cid from kpi_cc)))) f,
  pg_temp.kq(:'A', $q$select public.com_set_cc_verificacion(true, null)::text$q$) sin_fund;
insert into kpi_checks select 'K-14 (punto 4) el saldo de CUENTA CORRIENTE importado se informa como NO_VERIFICADO por defecto, con fecha de CORTE, ARCHIVO y carga de origen (también el saldo por comprobante); marcarlo verificado exige FUNDAMENTO',
  f->>'cc_verificacion' = 'NO_VERIFICADO' and f->>'pendientes_verificacion' = 'NO_VERIFICADO' and f->>'cc_archivo' = 'cuenta_corriente_20261126.xlsx' and f ? 'cc_fecha_corte' and f ? 'cc_carga'
  and (f->>'cc_saldo')::numeric = 1250000 and sin_fund like 'ERR FUNDAMENTO_REQUERIDO%', left(f::text, 300) || ' | ' || left(sin_fund, 40) from kpi_cc2;
