-- SOLO PRUEBAS LOCALES · FINANCIACIÓN PROPIA CON CALENDARIO (001200). Aserciones exactas.
create temp table cu_checks(name text, ok boolean, detail text);
\set A  'e0000000-0000-0000-0000-00000000000a'
\set C1 'c0000000-0000-0000-0000-0000000000c1'
\set C2 'c0000000-0000-0000-0000-0000000000c2'
create or replace function pg_temp.cu_t(t jsonb, base date) returns text language plpgsql as $f$
  declare c public.com_clients; r jsonb; begin select * into c from public.com_clients where erp_id = '106';
  begin r := public._com_terms('FINANCIACION', t, c, base); return r::text; exception when others then return 'ERR ' || sqlerrm; end; end $f$;
create or replace function pg_temp.cu_dues(x text) returns text language sql as $f$
  select case when x like 'ERR%' then x else (select string_agg(to_char((e->>'due')::date, 'DD/MM/YYYY'), ' ' order by (e->>'n')::int) from jsonb_array_elements(x::jsonb->'schedule') e) end $f$;
create or replace function pg_temp.cu_u(u uuid, q text) returns text language plpgsql as $f$ declare o text; begin perform tst.u(u); set local role authenticated; begin execute q into o; exception when others then o := 'ERR ' || sqlerrm; end; reset role; return o; end $f$;
-- ===== casos acordados con Dirección (creación 16/11/2026 → límite 16/12/2026, día 30 incluido) =====
create temp table cu_dir as select
  pg_temp.cu_dues(pg_temp.cu_t('{"amount":100000,"installments":1,"first_due":"2026-11-23"}', '2026-11-16')) c1,
  pg_temp.cu_dues(pg_temp.cu_t('{"amount":100000,"installments":1,"first_due":"2026-12-16"}', '2026-11-16')) c2,
  pg_temp.cu_dues(pg_temp.cu_t('{"amount":100000,"installments":2,"frequency":"QUINCENAL","first_due":"2026-12-01"}', '2026-11-16')) c3,
  pg_temp.cu_dues(pg_temp.cu_t('{"amount":100000,"installments":4,"frequency":"SEMANAL","first_due":"2026-11-23"}', '2026-11-16')) c4,
  pg_temp.cu_t('{"amount":100000,"installments":2,"frequency":"MENSUAL","first_due":"2026-12-16"}', '2026-11-16') c5,
  pg_temp.cu_t('{"amount":100000,"installments":1,"first_due":"2026-12-17"}', '2026-11-16') c6;
insert into cu_checks select 'CU-01 1 cuota el 23/11 → se acepta el 23/11', c1 = '23/11/2026', c1 from cu_dir;
insert into cu_checks select 'CU-02 1 cuota el 16/12 (día 30, INCLUIDO) → se acepta', c2 = '16/12/2026', c2 from cu_dir;
insert into cu_checks select 'CU-03 2 quincenales desde el 01/12 → 01/12 y 16/12', c3 = '01/12/2026 16/12/2026', c3 from cu_dir;
insert into cu_checks select 'CU-04 4 semanales desde el 23/11 → 23/11, 30/11, 07/12 y 14/12', c4 = '23/11/2026 30/11/2026 07/12/2026 14/12/2026', c4 from cu_dir;
insert into cu_checks select 'CU-05 2 mensuales desde el 16/12 → se BLOQUEA indicando que la cuota 2 vencería el 16/01/2027 y el límite 16/12/2026', c5 like 'ERR BAD_SCHEDULE: la cuota 2 vence el 16/01/2027 y supera el límite del 16/12/2026%', c5 from cu_dir;
insert into cu_checks select 'CU-06 1 cuota el 17/12 → se RECHAZA aunque sea un único pago', c6 like 'ERR BAD_SCHEDULE: la cuota 1 vence el 17/12/2026 y supera el límite del 16/12/2026%', c6 from cu_dir;
-- ===== cambios de mes y año; fin de mes =====
create temp table cu_cal as select
  pg_temp.cu_dues(pg_temp.cu_t('{"amount":90000,"installments":3,"frequency":"SEMANAL","first_due":"2026-12-27"}', '2026-12-20')) anio,
  pg_temp.cu_dues(pg_temp.cu_t('{"amount":90000,"installments":2,"frequency":"MENSUAL","first_due":"2027-01-31"}', '2027-01-31')) febrero,
  pg_temp.cu_t('{"amount":90000,"installments":2,"frequency":"MENSUAL","first_due":"2027-01-30"}', '2027-01-01') feb_limite,
  pg_temp.cu_dues(pg_temp.cu_t('{"amount":90000,"installments":2,"frequency":"QUINCENAL","first_due":"2026-11-30"}', '2026-11-29')) mes;
insert into cu_checks select 'CU-07 cambio de AÑO: 3 semanales desde el 27/12/2026 → 27/12/2026, 03/01/2027 y 10/01/2027', anio = '27/12/2026 03/01/2027 10/01/2027', anio from cu_cal;
insert into cu_checks select 'CU-08 FIN DE MES: mensual desde el 31/01/2027 → 28/02/2027 (ajuste de calendario, dentro del límite 02/03/2027); desde el 30/01 con creación 01/01 → la cuota 2 (28/02) supera el 31/01 y se bloquea',
  febrero = '31/01/2027 28/02/2027' and feb_limite like 'ERR BAD_SCHEDULE: la cuota 2 vence el 28/02/2027 y supera el límite del 31/01/2027%', febrero || ' | ' || left(feb_limite, 80) from cu_cal;
insert into cu_checks select 'CU-09 cambio de MES: 2 quincenales desde el 30/11 → 30/11 y 15/12', mes = '30/11/2026 15/12/2026', mes from cu_cal;
-- ===== cantidades y datos inválidos o manipulados =====
create temp table cu_bad as select
  pg_temp.cu_t('{"amount":1000,"installments":0,"first_due":"2026-11-20"}', '2026-11-16') cero,
  pg_temp.cu_t('{"amount":1000,"installments":-2,"first_due":"2026-11-20"}', '2026-11-16') negativo,
  pg_temp.cu_t('{"amount":1000,"installments":"abc","first_due":"2026-11-20"}', '2026-11-16') texto,
  pg_temp.cu_t('{"amount":1000,"installments":40,"frequency":"SEMANAL","first_due":"2026-11-20"}', '2026-11-16') muchas,
  pg_temp.cu_t('{"amount":1000,"installments":2,"first_due":"2026-11-20"}', '2026-11-16') sin_freq,
  pg_temp.cu_t('{"amount":1000,"installments":2,"frequency":"DIARIA","first_due":"2026-11-20"}', '2026-11-16') freq_mala,
  pg_temp.cu_t('{"amount":1000,"installments":1,"first_due":"2026-11-15"}', '2026-11-16') antes,
  pg_temp.cu_t('{"amount":1000,"installments":1,"first_due":"2026-13-45"}', '2026-11-16') fecha_mala,
  pg_temp.cu_t('{"amount":1000,"installments":1,"first_due":null}', '2026-11-16') fecha_nula,
  pg_temp.cu_t('{"amount":1000,"installments":1,"frequency":"MENSUAL","first_due":"2026-11-20"}', '2026-11-16') una_con_freq;
insert into cu_checks select 'CU-10 cantidades inválidas (0, negativa, texto, 40) → BAD_INSTALLMENTS o BAD_SCHEDULE (nunca se acepta ni falla sin explicación)',
  cero like 'ERR BAD_INSTALLMENTS%' and negativo like 'ERR BAD_INSTALLMENTS%' and texto like 'ERR BAD_INSTALLMENTS%' and muchas like 'ERR BAD_INSTALLMENTS%', left(texto, 60) || ' | ' || left(muchas, 60) from cu_bad;
insert into cu_checks select 'CU-11 frecuencia faltante o inexistente con 2+ cuotas → BAD_FREQUENCY; con 1 cuota la frecuencia se IGNORA (no se guarda)',
  sin_freq like 'ERR BAD_FREQUENCY%' and freq_mala like 'ERR BAD_FREQUENCY%' and una_con_freq::jsonb->>'frequency' is null, left(freq_mala, 60) from cu_bad;
insert into cu_checks select 'CU-12 primer vencimiento ANTERIOR a la creación, inválido o vacío → BAD_FIRST_DUE',
  antes like 'ERR BAD_FIRST_DUE%15/11/2026%16/11/2026%' and fecha_mala like 'ERR BAD_FIRST_DUE%' and fecha_nula like 'ERR BAD_FIRST_DUE%', left(antes, 100) from cu_bad;
-- ===== a través de la RPC REAL del Comercial (fecha de creación = hoy argentino) =====
create temp table cu_hoy as select (now() at time zone 'America/Argentina/Mendoza')::date d;
create temp table cu_rpc as select
  pg_temp.cu_u(:'C1', format($q$select public.com_create_request('FINANCIACION', %L, 'CU-OK', %L::jsonb, null, 'cu-op-ok')::text$q$, (select id from public.com_clients where erp_id = '106'),
    jsonb_build_object('amount', 300000, 'installments', 2, 'frequency', 'QUINCENAL', 'first_due', (select d + 5 from cu_hoy),
      'schedule', jsonb_build_array(jsonb_build_object('n', 1, 'due', '2099-01-01', 'amount', 1))))) ok,   -- calendario MANIPULADO por el cliente: el servidor lo ignora
  pg_temp.cu_u(:'C1', format($q$select public.com_create_request('FINANCIACION', %L, 'CU-MAL', %L::jsonb, null, 'cu-op-mal')::text$q$, (select id from public.com_clients where erp_id = '106'),
    jsonb_build_object('amount', 300000, 'installments', 1, 'first_due', (select d + 31 from cu_hoy)))) mal;
create temp table cu_req as select * from public.com_requests where op_id = 'cu-op-ok';
insert into cu_checks select 'CU-13 RPC real: el calendario se calcula y guarda en el SERVIDOR (un calendario enviado por el cliente se ignora); 31 días desde hoy se RECHAZA y no se crea nada',
  (select (original_terms->'schedule'->0->>'due')::date = (select d + 5 from cu_hoy) and (original_terms->'schedule'->1->>'due')::date = (select d + 20 from cu_hoy)
     and original_terms->>'frequency' = 'QUINCENAL' and (original_terms->>'limit_date')::date = (select d + 30 from cu_hoy) from cu_req)
  and (select mal like 'ERR BAD_SCHEDULE%' from cu_rpc) and not exists (select 1 from public.com_requests where op_id = 'cu-op-mal'),
  (select left(mal, 90) from cu_rpc) from (select 1) z;
insert into cu_checks select 'CU-14 aislamiento: otro Comercial NO ve la solicitud ni su calendario',
  pg_temp.cu_u(:'C2', format('select public.com_request_detail(%L)::text', (select id from cu_req))) like 'ERR FORBIDDEN%', '' from (select 1) z;
-- ===== formato ANTERIOR (app sin actualizar) =====
create temp table cu_leg as select pg_temp.cu_dues(pg_temp.cu_t('{"amount":90000,"installments":3}', '2026-11-16')) tres, pg_temp.cu_t('{"amount":90000,"installments":5}', '2026-11-16') cinco;
insert into cu_checks select 'CU-15 formato ANTERIOR (sin primer vencimiento): semanal desde el día 7 como antes; 5 cuotas → mismo error BAD_INSTALLMENTS de siempre',
  tres = '23/11/2026 30/11/2026 07/12/2026' and cinco like 'ERR BAD_INSTALLMENTS: cuotas semanales%', tres || ' | ' || left(cinco, 50) from cu_leg;
-- ===== el APROBADOR modifica/devuelve con la fecha de creación ORIGINAL (simulamos una solicitud creada hace 20 días) =====
update public.com_requests set created_at = now() - interval '20 days' where op_id = 'cu-op-ok';
create temp table cu_base as select ((created_at at time zone 'America/Argentina/Mendoza')::date) b from public.com_requests where op_id = 'cu-op-ok';
create temp table cu_dec as select
  pg_temp.cu_u(:'A', format($q$select public.com_decide(%L, %s, 'APROBAR_CON_CAMBIOS', %L::jsonb, 'probando el límite')::text$q$, (select id from cu_req), (select version from public.com_requests where op_id = 'cu-op-ok'),
    jsonb_build_object('amount', 300000, 'installments', 2, 'frequency', 'SEMANAL', 'first_due', (select b + 25 from cu_base)))) excede;
alter table cu_dec add column devuelve text;
update cu_dec set devuelve = pg_temp.cu_u(:'A', format($q$select public.com_decide(%L, %s, 'DEVOLVER', %L::jsonb, 'propongo 3 semanales')::text$q$, (select id from cu_req), (select version from public.com_requests where op_id = 'cu-op-ok'),
    jsonb_build_object('amount', 280000, 'installments', 3, 'frequency', 'SEMANAL', 'first_due', (select b + 10 from cu_base))));
insert into cu_checks select 'CU-16 APROBADOR: el límite se cuenta desde la CREACIÓN ORIGINAL (hace 20 días): 2 semanales desde creación+25 → la cuota 2 (creación+32) se bloquea; la DEVOLUCIÓN con 3 semanales desde creación+10 se registra',
  excede like 'ERR BAD_SCHEDULE: la cuota 2%' and (select status = 'DEVUELTA' and (current_terms->'schedule'->2->>'due')::date = (select b + 24 from cu_base) and (current_terms->>'limit_date')::date = (select b + 30 from cu_base) from public.com_requests where op_id = 'cu-op-ok'),
  left(excede, 80) from cu_dec;
select pg_temp.cu_u(:'C1', format($q$select public.com_respond(%L, %s, true, 'acepto')::text$q$, (select id from cu_req), (select version from public.com_requests where op_id = 'cu-op-ok')));
insert into cu_checks select 'CU-17 el Comercial ACEPTA la propuesta: la solicitud vuelve a pendiente con el calendario PROPUESTO tal cual (sin recalcular) y lo SOLICITADO original se conserva',
  (select status = 'PENDIENTE' and current_terms->'schedule' = (select terms_after->'schedule' from public.com_request_events e where e.request_id = q.id and e.kind = 'DEVUELTA_CON_MODIFICACIONES')
     and (original_terms->>'installments')::int = 2 and original_terms->>'frequency' = 'QUINCENAL' from public.com_requests q where op_id = 'cu-op-ok'), '' from (select 1) z;
select pg_temp.cu_u(:'A', format($q$select public.com_decide(%L, %s, 'APROBAR', null, null)::text$q$, (select id from cu_req), (select version from public.com_requests where op_id = 'cu-op-ok')));
create temp table cu_det as select pg_temp.cu_u(:'C1', format('select public.com_request_detail(%L)::text', (select id from cu_req)))::jsonb d;
insert into cu_checks select 'CU-18 HISTORIAL: el detalle muestra lo SOLICITADO (2 quincenales), lo PROPUESTO en la devolución y lo AUTORIZADO (3 semanales, importe 280.000), con cada calendario en la trazabilidad',
  (d->'original_terms'->>'frequency') = 'QUINCENAL' and (d->'final_terms'->>'installments')::int = 3 and (d->'final_terms'->>'amount')::numeric = 280000
  and (select count(*) from jsonb_array_elements(d->'timeline') e where jsonb_array_length(coalesce(e->'terms_after'->'schedule', '[]')) > 0) >= 2, (d->>'status') from cu_det;
-- ===== solicitud HISTÓRICA (formato anterior guardado): se muestra como se registró, sin reinterpretar =====
create temp table cu_hist as select id, original_terms from public.com_requests where op_id = 'hi-op-1';
insert into cu_checks select 'CU-19 solicitud HISTÓRICA: sus condiciones guardadas (formato anterior) se devuelven INTACTAS en el detalle',
  (select (pg_temp.cu_u('c0000000-0000-0000-0000-0000000000d1', format('select public.com_request_detail(%L)::text', h.id))::jsonb->'original_terms') = h.original_terms from cu_hist h)
  or (select pg_temp.cu_u(:'A', format('select public.com_request_detail(%L)::text', h.id))::jsonb->'original_terms' = h.original_terms from cu_hist h), '' from (select 1) z;
-- ===== e-cheq SIN cambios =====
create temp table cu_eq as select
  (select r from (select public._com_terms('ECHEQ', '{"amount":5000,"due_date":"2026-12-10"}'::jsonb, c, '2026-11-16') r from public.com_clients c where erp_id = '106') x) ok,
  (select pg_temp.cu_t('{"amount":1}'::jsonb, '2026-11-16')) dummy;
insert into cu_checks select 'CU-20 E-CHEQ sin cambios: vencimiento dentro del plazo aceptado con emisor = el mismo cliente',
  (ok->>'due_date') = '2026-12-10' and (ok->>'issuer_is_client')::boolean, (ok->>'days') from cu_eq;
