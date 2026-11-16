-- =====================================================================================================================
-- PROPUESTA · AUTORIZACIONES COMERCIALES · KPI DE FACTURACIÓN (regla oficial de Dirección General, 15/11) · NO APLICADA. Después de 001000.
-- REGLA: las facturas PERMANECEN en «Saldo comprobante» aunque estén abonadas. Facturación del mes = importe ORIGINAL de las facturas por
-- FECHA DE EMISIÓN (abonadas incluidas); el saldo NO sustituye al original; el pago no reduce la facturación.
-- SIN INVENTAR SEMÁNTICA (WORK-K02 abierto): con varias filas por comprobante el original se toma según cuota_rule (vigente) y el saldo según
-- saldo_rule (nueva); ambas POR_CONFIRMAR por defecto → el comprobante se EXCLUYE de la facturación o su saldo queda «no determinado».
-- USO: SOLO Administrador, rotulado «VALIDACIÓN — NO OPERATIVO» mientras el KPI esté deshabilitado. No modifica cobranzas ni aplica notas de
-- crédito en OK DESPACHO (HOTFIX NOC V5 aparte). Lectura pura: no cambia datos.
-- Punto 4: com_client_finance informa ORIGEN (corte, archivo, carga) y VERIFICACIÓN del saldo importado (NO_VERIFICADO por defecto).
-- =====================================================================================================================
BEGIN;
SET LOCAL lock_timeout = '5s'; SET LOCAL statement_timeout = '60s';
DO $guard$ BEGIN
  IF to_regclass('public.com_install_state') IS NULL THEN RAISE EXCEPTION 'DEPENDENCIA_FALTANTE: aplicar antes 000100 a 001000. No se modificó nada.'; END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'com_settings' AND column_name = 'saldo_rule') THEN
    RAISE EXCEPTION 'YA_APLICADA. No se modificó nada.'; END IF;
END $guard$;

-- regla EXPLÍCITA del saldo cuando un comprobante tiene varias filas (cuotas): POR_PARTE (cada fila trae el pendiente de su parte → se suman),
-- REPETIDO (cada fila repite el saldo del comprobante → se toma una vez) o POR_CONFIRMAR (predeterminado: saldo no determinado)
alter table public.com_settings add column saldo_rule text not null default 'POR_CONFIRMAR' check (saldo_rule in ('POR_CONFIRMAR', 'POR_PARTE', 'REPETIDO'));

-- ---------- un registro POR COMPROBANTE (clave estable: CUIT | comprobante normalizado) con su trazabilidad ----------
create or replace function public._com_billing_docs(p_from date, p_to date) returns setof jsonb language sql stable security definer set search_path = public as $$
  with s as (select cuota_rule cr, saldo_rule sr from public.com_settings where id = 'DEFAULT'),
  rows_ as (select * from public.com_sc_documents d where d.class in ('VENTA', 'NOTA_CREDITO', 'ANULACION')
              and d.doc_date >= coalesce(p_from, '-infinity'::date) and d.doc_date <= coalesce(p_to, 'infinity'::date)),
  g as (select r.comp_group k, min(r.cuit) cuit, min(r.client_name) cliente, min(r.class) clase, min(r.prefix) prefijo, min(r.comp) comp,
               min(r.doc_date) emision, count(*) partes, count(*) filter (where r.status <> 'OK') malas, array_agg(distinct r.status) filter (where r.status <> 'OK') motivos,
               min(r.amount) mn, max(r.amount) mx, sum(r.amount) tot, count(r.last_saldo) con_saldo, sum(r.last_saldo) saldo_sum, min(r.last_saldo) smn, max(r.last_saldo) smx,
               min(r.first_ingest_id) primera, max(r.last_ingest_id) ultima
          from rows_ r group by r.comp_group),
  c as (select g.*, s.cr, s.sr,
          case when g.malas > 0 then null
               when g.partes = 1 then g.mx
               when s.cr = 'MONTO_ES_TOTAL' and g.mn = g.mx then g.mx
               when s.cr = 'MONTO_ES_CUOTA' then g.tot end original,
          case when g.malas > 0 or g.con_saldo < g.partes then null
               when g.partes = 1 then g.saldo_sum
               when s.sr = 'POR_PARTE' then g.saldo_sum
               when s.sr = 'REPETIDO' and g.smn = g.smx then g.smx end saldo
        from g, s)
  select jsonb_build_object('comprobante', c.k, 'cuit', c.cuit, 'cliente', c.cliente, 'clase', c.clase, 'prefijo', c.prefijo, 'comp', c.comp,
    'emision', c.emision, 'mes', to_char(c.emision, 'YYYY-MM'), 'partes', c.partes, 'original', abs(c.original), 'saldo', c.saldo,
    'estado_pago', case when c.clase <> 'VENTA' then null when c.original is null then null when c.saldo is null then 'SALDO_NO_DETERMINADO'
                        when c.saldo = 0 then 'ABONADA' when c.saldo > 0 and c.saldo < c.original then 'PARCIAL' when c.saldo = c.original then 'PENDIENTE' else 'A_REVISAR' end,
    'abonado', case when c.clase = 'VENTA' and c.original is not null and c.saldo is not null and c.saldo >= 0 and c.saldo <= c.original then c.original - c.saldo end,
    'excluido', case when c.malas > 0 then 'DATOS_DEL_COMPROBANTE: ' || array_to_string(c.motivos, ',') when c.original is null then 'ORIGINAL_POR_CONFIRMAR (varias partes; regla de cuotas ' || c.cr || ')' end,
    'interpretacion', jsonb_build_object('regla_cuotas', case when c.partes > 1 then c.cr end, 'regla_saldo', case when c.partes > 1 then c.sr end),
    'carga_primera', c.primera, 'carga_ultima', c.ultima,
    'archivo', (select jsonb_build_object('carga', i.id, 'archivo', i.file_name, 'huella', left(i.content_hash, 16), 'cargado', i.loaded_at, 'corte', i.date_max) from public.com_ingests i where i.id = c.ultima))
  from c order by c.emision, c.k;
$$;

-- ---------- indicadores por MES (emisión), con fecha de corte y archivos de origen ----------
create or replace function public.com_kpi_billing(p_from date, p_to date) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare docs jsonb; meses jsonb; s public.com_settings;
begin
  perform public._com_require_session();
  if not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into s from public.com_settings where id = 'DEFAULT';
  select coalesce(jsonb_agg(x), '[]') into docs from public._com_billing_docs(p_from, p_to) x;
  with d as (select x from jsonb_array_elements(docs) x),
  m as (select x->>'mes' mes,
          sum((x->>'original')::numeric) filter (where x->>'clase' = 'VENTA' and x->>'excluido' is null) bruta,
          sum((x->>'original')::numeric) filter (where x->>'clase' = 'NOTA_CREDITO' and x->>'excluido' is null) nc,
          count(*) filter (where x->>'clase' = 'NOTA_CREDITO' and x->>'excluido' is not null) nc_excl,
          count(*) filter (where x->>'clase' = 'VENTA' and x->>'excluido' is null) facturas,
          count(distinct x->>'cuit') filter (where x->>'clase' = 'VENTA' and x->>'excluido' is null) clientes,
          sum((x->>'saldo')::numeric) filter (where x->>'clase' = 'VENTA' and x->>'excluido' is null and x->>'estado_pago' <> 'SALDO_NO_DETERMINADO') saldo,
          sum((x->>'abonado')::numeric) filter (where x->>'clase' = 'VENTA' and x->>'excluido' is null) abonado,
          count(*) filter (where x->>'estado_pago' = 'ABONADA') abonadas, count(*) filter (where x->>'estado_pago' = 'PARCIAL') parciales,
          count(*) filter (where x->>'estado_pago' = 'PENDIENTE') pendientes, count(*) filter (where x->>'estado_pago' = 'A_REVISAR') a_revisar,
          count(*) filter (where x->>'estado_pago' = 'SALDO_NO_DETERMINADO') saldo_nd,
          count(*) filter (where x->>'clase' = 'ANULACION') anuladas,
          count(*) filter (where x->>'clase' = 'VENTA' and x->>'excluido' is not null) excluidas,
          jsonb_object_agg(coalesce(x->>'prefijo', '?'), 1) filter (where x->>'clase' = 'VENTA' and x->>'excluido' is null) tipos_obj
        from d group by x->>'mes'),
  m2 as (select m.*, lag(m.bruta) over (order by m.mes) prev from m)   -- la variación mensual se calcula ANTES de agregar
  select coalesce(jsonb_agg(jsonb_build_object('mes', m.mes,
      'facturacion_bruta', coalesce(m.bruta, 0), 'notas_credito', coalesce(m.nc, 0),
      'facturacion_neta', case when m.nc_excl = 0 then coalesce(m.bruta, 0) - coalesce(m.nc, 0) end,   -- solo si TODAS las notas de crédito del mes son determinables
      'facturas', m.facturas, 'clientes', m.clientes, 'ticket_promedio', case when m.facturas > 0 then round(coalesce(m.bruta, 0) / m.facturas, 2) end,
      'saldo_pendiente', coalesce(m.saldo, 0), 'abonado_inferido', coalesce(m.abonado, 0),
      'estados', jsonb_build_object('ABONADA', m.abonadas, 'PARCIAL', m.parciales, 'PENDIENTE', m.pendientes, 'A_REVISAR', m.a_revisar, 'SALDO_NO_DETERMINADO', m.saldo_nd),
      'anuladas', m.anuladas, 'facturas_excluidas', m.excluidas,
      'variacion_vs_mes_anterior', case when m.prev > 0 then round((coalesce(m.bruta, 0) / m.prev - 1) * 100, 1) end)
    order by m.mes), '[]') into meses from m2 m;
  return jsonb_build_object(
    'uso', case when s.kpi_mode = 'PROVISORIO' then 'PROVISORIO — NO CERTIFICADO (WORK-K02)' else 'VALIDACIÓN — NO OPERATIVO (KPI deshabilitado; WORK-K02 abierto)' end,
    'regla', 'Facturación = importe ORIGINAL por comprobante y mes de EMISIÓN (facturas abonadas incluidas); el saldo no sustituye al original.',
    'regla_cuotas', s.cuota_rule, 'regla_saldo', s.saldo_rule,
    'corte', (select jsonb_build_object('ultima_carga', max(i.loaded_at), 'fecha_max_datos', max(i.date_max)) from public.com_ingests i where i.kind = 'SC' and i.status = 'OK'),
    'archivos', (select coalesce(jsonb_agg(jsonb_build_object('carga', i.id, 'archivo', i.file_name, 'huella', left(i.content_hash, 16), 'cargado', i.loaded_at, 'filas', i.rows) order by i.id), '[]')
                   from public.com_ingests i where i.kind = 'SC' and i.status = 'OK'),
    'meses', meses,
    'por_cliente', (select coalesce(jsonb_agg(jsonb_build_object('cuit', t.cuit, 'cliente', t.cliente, 'facturado', t.tot, 'facturas', t.n) order by t.tot desc), '[]')
                      from (select x->>'cuit' cuit, min(x->>'cliente') cliente, sum((x->>'original')::numeric) tot, count(*) n from jsonb_array_elements(docs) x
                             where x->>'clase' = 'VENTA' and x->>'excluido' is null group by x->>'cuit') t));
end; $$;

-- ---------- detalle trazable de cada cifra (por mes y, opcionalmente, estado / clase / exclusión) ----------
create or replace function public.com_kpi_billing_detail(p_month text, p_filter jsonb default '{}'::jsonb, p_offset int default 0, p_limit int default 100) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare m0 date; items jsonb; total int;
begin
  perform public._com_require_session();
  if not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  m0 := to_date(p_month || '-01', 'YYYY-MM-DD');
  with d as (select x from public._com_billing_docs(m0, (m0 + interval '1 month' - interval '1 day')::date) x
              where (p_filter->>'estado' is null or x->>'estado_pago' = p_filter->>'estado') and (p_filter->>'clase' is null or x->>'clase' = p_filter->>'clase')
                and (p_filter->>'excluidos' is null or ((p_filter->>'excluidos')::boolean = (x->>'excluido' is not null))))
  select count(*), coalesce(jsonb_agg(x) filter (where rn > greatest(0, p_offset) and rn <= greatest(0, p_offset) + least(greatest(1, p_limit), 500)), '[]')
    into total, items from (select x, row_number() over () rn from d) z;
  return jsonb_build_object('mes', p_month, 'total', total, 'items', items);
end; $$;

-- ---------- configuración de la regla de saldo (Administrador, auditada; documentar la evidencia de Cianbox que la respalda) ----------
create or replace function public.com_set_saldo_rule(p_rule text, p_fundamento text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._com_active(); antes text;
begin
  if me.id is null or not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_rule not in ('POR_CONFIRMAR', 'POR_PARTE', 'REPETIDO') then raise exception 'BAD_RULE' using errcode = '22023'; end if;
  if p_rule <> 'POR_CONFIRMAR' and length(btrim(coalesce(p_fundamento, ''))) < 20 then
    raise exception 'FUNDAMENTO_REQUERIDO: indicá qué archivo real de Cianbox respalda la interpretación' using errcode = '23514'; end if;
  select saldo_rule into antes from public.com_settings where id = 'DEFAULT';
  update public.com_settings set saldo_rule = p_rule where id = 'DEFAULT';
  insert into public.audit_log(actor_id, action, target_type, target_id, before, after) values (me.id, 'COM_SALDO_RULE', 'com_settings', 'DEFAULT',
    jsonb_build_object('saldo_rule', antes), jsonb_build_object('saldo_rule', p_rule, 'fundamento', nullif(btrim(coalesce(p_fundamento, '')), '')));
  return jsonb_build_object('saldo_rule', p_rule);
end; $$;

-- ---------- punto 4 · saldo de cuenta corriente: origen y estado de verificación (texto EXACTO vigente de com_client_finance + campos nuevos) ----------
alter table public.com_settings add column cc_verificado boolean not null default false;
create or replace function public.com_client_finance(p_client uuid) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare c public.com_clients; i public.com_ingests; b public.com_cc_balances; ls bigint;
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if (public._com_active()).id is null or not (public._com_admin() or public.user_has_perm(auth.uid(), 'com.approve')) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if not public._com_admin() and not exists(select 1 from public.com_requests where client_id=p_client and assigned_approver_id=auth.uid()) then raise exception 'FORBIDDEN_CLIENT' using errcode='42501'; end if;
  select * into c from public.com_clients where id = p_client; if not found or c.cuit is null then return jsonb_build_object('status', 'SIN_CUIT'); end if;
  select * into i from public.com_ingests where kind = 'CC' and status = 'OK' order by at desc limit 1;
  if found then select * into b from public.com_cc_balances where ingest_id = i.id and cuit = c.cuit; end if;
  select id into ls from public.com_ingests where kind = 'SC' and status = 'OK' order by at desc, id desc limit 1;   -- la carga MÁS RECIENTE por fecha
  return jsonb_build_object('cc_saldo', b.saldo, 'cc_fecha', i.at, 'cc_disponible', b.cuit is not null,
    -- punto 4 de la orden: el saldo IMPORTADO se presenta con su ORIGEN y su estado de VERIFICACIÓN (nunca como saldo conciliado por defecto)
    'cc_verificacion', case when (select cc_verificado from public.com_settings where id = 'DEFAULT') then 'VERIFICADO' else 'NO_VERIFICADO' end,
    'cc_fecha_corte', coalesce(i.date_max::text, (i.loaded_at at time zone 'America/Argentina/Mendoza')::date::text), 'cc_archivo', i.file_name, 'cc_carga', i.id,
    'pendientes_verificacion', case when (select cc_verificado from public.com_settings where id = 'DEFAULT') then 'VERIFICADO' else 'NO_VERIFICADO' end,
    'pendientes', coalesce((select jsonb_agg(jsonb_build_object('comprobante', comp, 'fecha', doc_date, 'vence', due, 'saldo', last_saldo) order by due nulls last, doc_date)
       from public.com_sc_documents where cuit = c.cuit and last_ingest_id = ls and coalesce(last_saldo, 0) > 0.004 and class = 'VENTA'), '[]'::jsonb),
    'sc_fecha', (select at from public.com_ingests where id = ls));
end; $$;

create or replace function public.com_set_cc_verificacion(p_verificado boolean, p_fundamento text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._com_active(); antes boolean;
begin
  if me.id is null or not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_verificado and length(btrim(coalesce(p_fundamento, ''))) < 20 then
    raise exception 'FUNDAMENTO_REQUERIDO: indicá la conciliación con Cianbox que respalda presentar el saldo como verificado' using errcode = '23514'; end if;
  select cc_verificado into antes from public.com_settings where id = 'DEFAULT';
  update public.com_settings set cc_verificado = coalesce(p_verificado, false) where id = 'DEFAULT';
  insert into public.audit_log(actor_id, action, target_type, target_id, before, after) values (me.id, 'COM_CC_VERIFICACION', 'com_settings', 'DEFAULT',
    jsonb_build_object('cc_verificado', antes), jsonb_build_object('cc_verificado', coalesce(p_verificado, false), 'fundamento', nullif(btrim(coalesce(p_fundamento, '')), '')));
  return jsonb_build_object('cc_verificado', coalesce(p_verificado, false));
end; $$;
revoke all on function public.com_set_cc_verificacion(boolean, text) from public, anon; grant execute on function public.com_set_cc_verificacion(boolean, text) to authenticated;

revoke all on function public._com_billing_docs(date, date) from public, anon, authenticated;
revoke all on function public.com_kpi_billing(date, date) from public, anon; grant execute on function public.com_kpi_billing(date, date) to authenticated;
revoke all on function public.com_kpi_billing_detail(text, jsonb, int, int) from public, anon; grant execute on function public.com_kpi_billing_detail(text, jsonb, int, int) to authenticated;
revoke all on function public.com_set_saldo_rule(text, text) from public, anon; grant execute on function public.com_set_saldo_rule(text, text) to authenticated;
COMMIT;
