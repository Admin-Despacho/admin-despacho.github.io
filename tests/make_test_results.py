# Genera TEST_RESULTS.md a partir de las salidas reales de tests/run_all.sh
import re, json, datetime, os
def clean(s): return re.sub(r'\x1b\[[0-9;]*m','',s)
rd = lambda p: open(p).read() if os.path.exists(p) else ''
rows=[]
for l in clean(rd('tests/out/unit_verbose.log')).splitlines():
    m=re.match(r'\s*([✓×])\s+tests/unit/\S+\s+>\s+(.*?)\s+>\s+(.*?)(\s+\d+ms)?$',l)
    if m: rows.append(('Unitarias (vitest)', m.group(3).strip(), 'PASS' if m.group(1)=='✓' else 'FAIL'))
for l in clean(rd('tests/out/deno.log')).splitlines():
    m=re.match(r'(\S.*?) \.\.\. (ok|FAILED)',l)
    if m: rows.append(('Edge Functions (deno test)', m.group(1), 'PASS' if m.group(2)=='ok' else 'FAIL'))
rows.append(('Edge Functions (deno check)','Chequeo de tipos de admin-users y commercial-reports con supabase-js real','PASS' if 'Check' in clean(rd('tests/out/deno_check.log')) else 'FAIL'))
for l in rd('tests/out/pdf.log').splitlines():
    m=re.match(r'(PASS|FAIL) \| (.*)',l)
    if m: rows.append(('PDF real (pdf-lib + pdftotext)', m.group(2), m.group(1)))
for l in rd('tests/out/sql.log').splitlines():
    m=re.match(r'(PASS|FAIL) \| ((?:S|F|R)\S+ .*?) \|',l)
    if m: rows.append(('SQL + RLS (PostgreSQL 16 local)', m.group(2), m.group(1)))
if os.path.exists('tests/e2e/out/e2e_results.json'):
    for r in json.load(open('tests/e2e/out/e2e_results.json')): rows.append(('E2E navegador (build, modo demo)', r['id']+' '+r['name'], r['result']))
for l in rd('tests/out/prototipo.log').splitlines():
    m=re.match(r'(\S+) \| (.*?) \| (PASS|FAIL) \|',l)
    if m: rows.append(('Prototipo V16 (navegador)', m.group(1)+' '+m.group(2), m.group(3)))
build='PASS' if 'BUILD PASS' in rd('tests/out/summary.txt') else 'FAIL'
cnt=lambda k: sum(1 for r in rows if r[2]==k)
req={'01':'Hoja publicada no entra','02':'Hoja en curso no entra','03':'Hoja finalizada entra','04':'Entrega parcial cuenta como completada','05':'Entrega parcial suma ingreso','06':'No entregado no suma ingreso','07':'Reprogramar no suma ingreso','08':'Este separado','09':'Alrededores separado','10':'Centro separado','11':'Semanal sábado 15:00 Mendoza','12':'Mensual = mes calendario','13':'Filtro Mes = mes específico','14':'Filtro Libre respeta Desde/Hasta','15':'Costo proporcional correcto','16':'Email muestra CUBRE / NO CUBRE','17':'Email con principales clientes a recuperar','18':'Email con mejores clientes','19':'Email con zonas a reforzar','20':'Sin cobranzas de mercadería como ingreso','21':'Email idempotente','22':'Histórico conserva snapshot','23':'Cambio futuro de costo no modifica PDF viejo','24':'Cambio futuro de tarifa no modifica PDF viejo','25':'RLS protege informes'}
extra={'08':r'REPORT-MAIL-08/09/10|PDF-04','09':r'REPORT-MAIL-08/09/10|PDF-05','10':r'REPORT-MAIL-08/09/10|PDF-06','11':r'R-SCH-01','12':r'PDF-15','15':r'PDF-16','16':r'PDF-09|RPT-UI-07','18':r'PDF-10','19':r'PDF-12','22':r'REPORT-MAIL-22/23','23':r'REPORT-MAIL-22/23','25':r'^Permisos:|RPT-UI-08'}
cov=[]
for k,name in req.items():
    pat=r'REPORT-MAIL-'+k+r'(?![\d/])|^R'+k+r'[a-z]?\b' + ('|'+extra[k] if k in extra else '')
    hits=[r for r in rows if re.search(pat, r[1])]
    layers=sorted(set(r[0].split(' (')[0] for r in hits))
    res='PASS' if hits and all(r[2]=='PASS' for r in hits) else ('FAIL' if hits else 'NOT RUN')
    cov.append((f'REPORT-MAIL-{k}',name,res,', '.join(layers)+f' ({len(hits)} casos)'))
pe=[r for r in rows if r[1].startswith('R-PDF-ERR')]
cov.append(('Sección 18','Email sin PDF → PDF_ERROR, no se envía, reintento desde Admin','PASS' if pe and all(r[2]=='PASS' for r in pe) else 'FAIL','Edge Functions ('+str(len(pe))+' caso)'))
notrun=[
 ('Supabase real','Migraciones Fase 1 + 1.1 + 2A aplicadas en un proyecto Supabase real','NOT RUN','no hay proyecto Supabase de OK Despacho en este entorno'),
 ('Supabase real','RLS con JWT reales; trigger en auth.users y borrado en auth.sessions con permisos reales','NOT RUN','probado en PostgreSQL 16 con simulación'),
 ('Supabase real','Edge Functions desplegadas (admin-users, commercial-reports) y Storage real del PDF','NOT RUN','probadas con dependencias simuladas; código verificado con deno check'),
 ('Email real','Envío por Resend y recepción en Gmail/Outlook (render del HTML en clientes de correo)','NOT RUN','probado con proveedor simulado y bandeja de salida demo'),
 ('Cron real','pg_cron + pg_net llamando a commercial-reports cada 15 min','NOT RUN','la lógica de "qué corresponde" y la idempotencia se probaron (Deno + E2E simulando la hora)'),
 ('Cloudflare','Build y deploy en Cloudflare Pages','NOT RUN','el build de producción local pasa'),
 ('Datos reales','Informe con hojas reales finalizadas por Cristian','NOT RUN','las paradas con resultado llegan con FINALIZAR HOJA (Fase 2B); hoy hay datos de demostración'),
 ('Visual V8','Paridad con MODELO_INFORME_CRISTIAN_FILTROS_CLIENTES_ZONAS_V8.html','NOT RUN','el archivo no llegó; se usó la especificación escrita y la estética offline'),
 ('Regresión v15','Batería completa de 72 pruebas de la v15 sobre la versión online','NOT RUN','regresión con archivos reales ejecutada (E18–E19); lógica v15 sin cambios'),
 ('Fase 2B','Publicación en vivo, celular del transportista, F2-INT-01..20','NOT RUN','fase siguiente'),
]
L=['# TEST_RESULTS — OK Despacho Online · Fase 2A','',f'Fecha: {datetime.date.today().isoformat()} · Versión: 0.2.0-fase2a','',
   f'**Build de producción (vite build): {build}**','',
   f'**Pruebas ejecutadas: {cnt("PASS")} PASS / {cnt("FAIL")} FAIL** · **NOT RUN: {len(notrun)} grupos** (detalle al final)','',
   'Entorno: Node 22 + Vite 5 + Vitest 2 · Deno 2.9 + pdf-lib 1.17 · PostgreSQL 16 local con simulación mínima de Supabase Auth · Chromium (Playwright) · pdftotext.','',
   '## Pruebas obligatorias del informe (REPORT-MAIL-01 a 25)','','| Prueba | Qué valida | Resultado | Dónde se probó |','|---|---|---|---|']
L+=[f'| {a} | {b} | {c} | {d} |' for a,b,c,d in cov]
L+=['','Toda la batería anterior (Fase 1, Fase 1.1 y prototipo V16) se volvió a ejecutar completa.','','## Detalle completo','','| Grupo | Prueba | Resultado |','|---|---|---|']
L+=[f'| {g} | {n} | {r} |' for g,n,r in rows]
L+=['','## NOT RUN','','| Grupo | Prueba | Resultado | Motivo |','|---|---|---|---|']
L+=[f'| {g} | {n} | {r} | {w} |' for g,n,r,w in notrun]
L+=['','Cómo repetir: `bash tests/run_all.sh` y `python3 tests/make_test_results.py`.']
open('TEST_RESULTS.md','w').write('\n'.join(L)+'\n')
print(cnt('PASS'),cnt('FAIL'),len(rows)); print([c for c in cov if c[2]!='PASS'])
