"""Genera propuestas/comercial/20261201000200_comercial_cuotas_respaldo.sql a partir del TEXTO EXACTO de las funciones corregidas por Work
(20261201000100). Cada reemplazo verifica que el original aparezca UNA sola vez: si no, falla (nunca se pierde una corrección)."""
import re, sys
SRC = 'propuestas/comercial/20261201000100_comercial_autorizaciones.sql'
OUT = 'propuestas/comercial/20261201000200_comercial_cuotas_respaldo.sql'
s = open(SRC, encoding='utf-8').read()
def fn(name):
    i = s.index('create or replace function public.' + name + '('); j = s.index('$$;', s.index('$$', i) + 2) + 3; return s[i:j]
def rep(body, a, b, label):
    n = body.count(a)
    if n != 1: sys.exit('REEMPLAZO FALLIDO (' + label + '): encontrado ' + str(n) + ' veces')
    return body.replace(a, b)
kpi = fn('_com_kpi_raw')
kpi = rep(kpi, """coalesce((select sum(case d.class when 'VENTA' then d.amount when 'NOTA_CREDITO' then -abs(d.amount) else 0 end)
              from public.com_sc_documents d where d.cuit = c.cuit and d.status = 'OK' and d.class in ('VENTA', 'NOTA_CREDITO') and date_trunc('month', d.doc_date) = g.m), 0)""",
  """((public._com_month_sales(c.cuit, g.m::date))->>'amount')::numeric""", 'suma mensual por comprobante')
kpi = rep(kpi, """  select count(*) into excl from public.com_sc_documents where cuit = c.cuit and status <> 'OK' and doc_date between m0 and (m1 + interval '1 month' - interval '1 day')::date;""",
  """  select count(*) into excl from public.com_sc_documents where cuit = c.cuit and status <> 'OK' and doc_date between m0 and (m1 + interval '1 month' - interval '1 day')::date;
  -- WORK-K02: comprobantes en CUOTAS cuyo importe no se puede asignar con la regla vigente → excluidos y CONTADOS como pendientes
  select coalesce(sum(((public._com_month_sales(c.cuit, gg::date))->>'pend')::int), 0) into cpend from generate_series(m0, m1, interval '1 month') gg;
  excl := excl + cpend;""", 'pendientes por cuotas')
kpi = rep(kpi, "declare s public.com_settings; c public.com_clients; m0 date; m1 date; months jsonb; cov int; tot numeric; avg_ numeric; excl int; last_sc timestamptz;",
  "declare s public.com_settings; c public.com_clients; m0 date; m1 date; months jsonb; cov int; tot numeric; avg_ numeric; excl int; last_sc timestamptz; cpend int := 0;", 'declaración')
kpi = rep(kpi, """    'source', 'Historial automático de «Saldo comprobante» (cargas diarias de Depósito)', 'scope', 'Comprobantes disponibles en «Saldo comprobante»');""",
  """    'source', 'Historial automático de «Saldo comprobante» (cargas diarias de Depósito)', 'scope', 'Comprobantes disponibles en «Saldo comprobante»',
    'cuota_rule', s.cuota_rule, 'cuotas_por_confirmar', cpend, 'sources', public._com_kpi_sources(c.cuit, m0, (m1 + interval '1 month' - interval '1 day')::date));""", 'retorno con fuentes')
ing = fn('com_ingest')
ing = rep(ing, """    k := cu || '|' || coalesce(nullif(r->>'n', ''), upper(regexp_replace(coalesce(r->>'comp', ''), '[\\s\\[\\]\\-_.()]', '', 'g'))) || '|' || coalesce(nullif(btrim(r->>'q'), ''), '-');""",
  """    -- WORK-K02: la PARTE se identifica como en el Constructor (financing.js partKey): número de cuota y, si no hay, vencimiento
    k := cu || '|' || coalesce(nullif(r->>'n', ''), upper(regexp_replace(coalesce(r->>'comp', ''), '[\\s\\[\\]\\-_.()]', '', 'g'))) || '|'
      || coalesce(nullif(btrim(r->>'q'), ''), case when nullif(btrim(r->>'due'), '') is not null then 'V' || btrim(r->>'due') end, '-');""", 'identidad de parte')
ing = rep(ing, """    insert into public.com_ingests(kind, content_hash, file_name, loaded_at, by_user, batches) values (p_kind, p_meta->>'hash', left(p_meta->>'file_name', 200), (p_meta->>'loaded_at')::timestamptz, auth.uid(), nb) returning * into g;""",
  """    insert into public.com_ingests(kind, content_hash, file_name, loaded_at, by_user, batches) values (p_kind, p_meta->>'hash', left(p_meta->>'file_name', 200), (p_meta->>'loaded_at')::timestamptz, auth.uid(), nb) returning * into g;
    perform public._com_link_source(g.id, p_kind, p_meta);   -- respaldo privado: con el respaldo ACTIVO exige el archivo original ya recibido""", 'vínculo con el original')
ss = fn('com_set_settings')
ss = rep(ss, """    kpi_source_verified = coalesce((p->>'kpi_source_verified')::boolean, kpi_source_verified), updated_by = auth.uid(), updated_at = now() where id = 'DEFAULT' returning * into s;""",
  """    kpi_source_verified = coalesce((p->>'kpi_source_verified')::boolean, kpi_source_verified), cuota_rule = coalesce(p->>'cuota_rule', cuota_rule),
    source_backup_enabled = coalesce((p->>'source_backup_enabled')::boolean, source_backup_enabled), source_max_mb = coalesce((p->>'source_max_mb')::int, source_max_mb),
    updated_by = auth.uid(), updated_at = now() where id = 'DEFAULT' returning * into s;""", 'parámetros nuevos')
head = open('tools/cuotas_respaldo_head.sql', encoding='utf-8').read(); tail = open('tools/cuotas_respaldo_tail.sql', encoding='utf-8').read()
open(OUT, 'w', encoding='utf-8').write(head + '\n-- ===== funciones corregidas por Work, con reemplazos mínimos verificados =====\n' + kpi + '\n\n' + ing + '\n\n' + ss + '\n\n' + tail)
print('generado', OUT)
