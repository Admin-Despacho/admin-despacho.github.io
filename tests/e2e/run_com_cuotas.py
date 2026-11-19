"""E2E (demo, navegador REAL, vista MÓVIL 390×844) · FINANCIACIÓN PROPIA CON CALENDARIO DE CUOTAS.
Comercial: campos en orden, calendario y fecha límite antes de enviar, cuota que excede (cuál), corrección SIN perder lo cargado.
Aprobador: ve y modifica el MISMO calendario; devuelve; Comercial ve original y propuesto; aprobación; historial; solicitud histórica intacta;
solicitud manipulada rechazada. Las fechas se calculan desde HOY en Argentina, como la app. Datos de prueba de la demo; sin envíos reales."""
import asyncio, os, sys, json, traceback
sys.path.insert(0, os.path.dirname(__file__))
import run_driver_perfiles as dp
import run_com_circuito as cc
from playwright.async_api import async_playwright
R = []; EXPECTED = 7
DIST = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), '..', '..', 'dist-demo'); dp.DIST = DIST; dp.PORT = 4520
OUT = sys.argv[2] if len(sys.argv) > 2 else '/tmp/okd_com_cuotas'
K = 'okd_online_demo_v2'
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:420])); print('..', ' | '.join(R[-1]), flush=True)
AR = cc.AR_PLUS
DMY = lambda iso: '/'.join(reversed(iso.split('-')))
LABELS = '()=>[...document.querySelectorAll("#comMain .fg .field > span")].map(e=>e.closest(".field").hidden?null:e.textContent.trim()).filter(Boolean)'
PREVIEW = '''()=>({limite:(document.querySelector("#cSched [data-cal-limit]")||{}).innerText||"", items:[...document.querySelectorAll("#cSched [data-cal-due]")].map(e=>e.innerText),
  error:(document.querySelector("#cSched [data-cal-error]")||{}).innerText||"", excede:!!document.querySelector("#cSched [data-cal-excede]"),
  enviar:!document.getElementById("cSend").disabled, freq_visible:!document.getElementById("cFreqW").hidden, etiqueta:document.getElementById("cFirstL").textContent})'''
async def main():
    os.makedirs(OUT, exist_ok=True); srv = dp.serve()
    try:
        async with async_playwright() as p:
            b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
            try:
                ctx = await b.new_context(viewport={'width': 390, 'height': 844}, is_mobile=True, has_touch=True); pg = await ctx.new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
                await pg.goto(f'http://127.0.0.1:{dp.PORT}/'); await pg.evaluate('()=>localStorage.clear()')
                await dp.login(pg, 'comercial.montecaseros@okdespacho.demo'); await pg.wait_for_selector('#cSearch', timeout=20000); await pg.wait_for_timeout(500)
                hoy = await pg.evaluate(AR, 0); d = {n: await pg.evaluate(AR, n) for n in (7, 15, 20, 30, 31)}
                # ===== CU-E01 · campos en orden; 1 cuota: sin frecuencia, «fecha de vencimiento», límite y calendario antes de enviar =====
                await cc.pick_client(pg, 'TECNO', 'TECNOLOGIA DEL NORTE'); await pg.fill('#cOrder', 'CU-1'); await pg.fill('#cAmount', '600000')
                orden = await pg.evaluate(LABELS)
                await pg.fill('#cFirst', d[7]); await pg.wait_for_timeout(300); p1 = await pg.evaluate(PREVIEW)
                await pg.screenshot(path=os.path.join(OUT, '1_una_cuota_movil.png'), full_page=True)
                i_inst, i_first = orden.index('CANTIDAD DE CUOTAS'), orden.index('FECHA DE VENCIMIENTO')
                res('CU-E01 [móvil] campos en orden (cantidad → vencimiento; con 1 cuota NO hay frecuencia); antes de enviar se ven la FECHA LÍMITE (hoy+30, incluido) y el calendario con fecha concreta',
                    i_inst < i_first and 'FRECUENCIA DE PAGO' not in orden and not p1['freq_visible'] and DMY(d[30]) in p1['limite'] and p1['items'] == [DMY(d[7])] and p1['enviar'],
                    {'orden': orden, 'vista': p1})
                # ===== CU-E02 · 2 cuotas: frecuencia visible; mensual que EXCEDE → se indica cuál, se bloquea y lo cargado se CONSERVA =====
                await pg.select_option('#cInst', '2'); await pg.wait_for_timeout(200); orden2 = await pg.evaluate(LABELS)
                await pg.select_option('#cFreq', 'MENSUAL'); await pg.fill('#cFirst', d[20]); await pg.wait_for_timeout(300); p2 = await pg.evaluate(PREVIEW)
                seg = await pg.evaluate('(f)=>{const [y,m,dd]=f.split("-").map(Number); const last=new Date(Date.UTC(y,m+1,0)).getUTCDate(); return new Date(Date.UTC(y,m,Math.min(dd,last))).toISOString().slice(0,10)}', d[20])
                conserva = await pg.evaluate('()=>({pedido:document.getElementById("cOrder").value, importe:document.getElementById("cAmount").value, cliente:document.getElementById("cSearch").value, primero:document.getElementById("cFirst").value, cuotas:document.getElementById("cInst").value, frecuencia:document.getElementById("cFreq").value})')
                await pg.screenshot(path=os.path.join(OUT, '2_cuota_excede_movil.png'), full_page=True)
                res('CU-E02 [móvil] con 2 cuotas aparece FRECUENCIA (entre cantidad y primer vencimiento); 2 MENSUALES desde hoy+20 → «la cuota 2 vence el … y supera el límite», marcada, ENVÍO BLOQUEADO, nada se recorta y lo cargado se CONSERVA',
                    orden2.index('CANTIDAD DE CUOTAS') < orden2.index('FRECUENCIA DE PAGO') < orden2.index('PRIMER VENCIMIENTO') and ('cuota 2 vence el ' + DMY(seg)) in p2['error']
                    and DMY(d[30]) in p2['error'] and p2['excede'] and not p2['enviar'] and 'TECNOLOGIA DEL NORTE' in conserva['cliente']
                    and {k: conserva[k] for k in ('pedido', 'importe', 'primero', 'cuotas', 'frecuencia')} == {'pedido': 'CU-1', 'importe': '600000', 'primero': d[20], 'cuotas': '2', 'frecuencia': 'MENSUAL'},
                    {'error': p2['error'][:140], 'conserva': conserva})
                # ===== CU-E03 · se CORRIGE (quincenal desde hoy+15 → hoy+15 y hoy+30, día 30 incluido) y se ENVÍA; el servidor guarda ESE calendario =====
                await pg.select_option('#cFreq', 'QUINCENAL'); await pg.fill('#cFirst', d[15]); await pg.wait_for_timeout(300); p3 = await pg.evaluate(PREVIEW)
                await pg.click('#cSend'); await pg.wait_for_timeout(1500)
                guardada = await pg.evaluate('''()=>{const d=JSON.parse(localStorage.getItem("okd_online_demo_v2")); const q=d.com.requests.filter(x=>x.order_ref==="CU-1").pop(); return q?{id:q.id, dues:q.original_terms.schedule.map(s=>s.due), freq:q.original_terms.frequency, limite:q.original_terms.limit_date}:null}''')
                res('CU-E03 [móvil] corregido a 2 QUINCENALES desde hoy+15 → hoy+15 y hoy+30 (día 30 incluido): se habilita el envío y la solicitud guarda EXACTAMENTE ese calendario y su fecha límite',
                    p3['enviar'] and p3['items'] == [DMY(d[15]), DMY(d[30])] and guardada and guardada['dues'] == [d[15], d[30]] and guardada['freq'] == 'QUINCENAL' and guardada['limite'] == d[30], {'guardada': guardada})
                # ===== CU-E04 · APROBADOR: ve lo solicitado y modifica el MISMO calendario; un cambio que excede se bloquea; DEVUELVE con 3 semanales =====
                await cc.relog(pg, 'wilfredo@okdespacho.demo'); await pg.evaluate('()=>{location.hash="#/autorizaciones?v=gerencia"}'); await pg.wait_for_timeout(1800)
                await pg.evaluate('(id)=>{const b=document.querySelector(`[data-select="${id}"]`); if(b) b.click()}', guardada['id']); await pg.wait_for_timeout(900)
                await pg.click('[data-dec="DEVOLVER"]'); await pg.wait_for_timeout(500)
                modal = await pg.evaluate('()=>({solicitado:[...((document.querySelector("#comModal .spanall:not(#dSched)")||document).querySelectorAll("[data-cal-due]"))].map(e=>e.innerText), cuotas:document.getElementById("dInst").value, frecuencia:document.getElementById("dFreq").value, primero:document.getElementById("dFirst").value})')
                await pg.select_option('#dInst', '3'); await pg.select_option('#dFreq', 'SEMANAL'); await pg.fill('#dFirst', d[20]); await pg.wait_for_timeout(300)
                bloqueado = await pg.evaluate('()=>({go:document.getElementById("dGo").disabled, error:(document.querySelector("#dSched [data-cal-error]")||{}).innerText||""})')
                await pg.fill('#dFirst', d[7]); await pg.wait_for_timeout(300); await pg.fill('#dReason', 'Propongo 3 semanales')
                await pg.screenshot(path=os.path.join(OUT, '3_aprobador_modifica_movil.png'), full_page=True)
                await pg.click('#dGo'); await pg.wait_for_timeout(1300)
                st = await pg.evaluate('(id)=>{const q=JSON.parse(localStorage.getItem("okd_online_demo_v2")).com.requests.find(x=>x.id===id); return {status:q.status, dues:q.current_terms.schedule.map(s=>s.due)}}', guardada['id'])
                res('CU-E04 [móvil] APROBADOR: ve el calendario SOLICITADO y edita el MISMO (precargado: 2 quincenales desde hoy+15); 3 semanales desde hoy+20 se BLOQUEA (cuota 3); desde hoy+7 se DEVUELVE',
                    modal['solicitado'] == [DMY(d[15]), DMY(d[30])] and modal['cuotas'] == '2' and modal['frecuencia'] == 'QUINCENAL' and modal['primero'] == d[15]
                    and bloqueado['go'] and 'cuota 3' in bloqueado['error'].lower() and st['status'] == 'DEVUELTA' and st['dues'] == [d[7], await pg.evaluate(AR, 14), await pg.evaluate(AR, 21)], {'modal': modal, 'bloqueo': bloqueado['error'][:90], 'estado': st})
                # ===== CU-E05 · el COMERCIAL ve el calendario ORIGINAL y el PROPUESTO antes de aceptar; acepta =====
                await cc.relog(pg, 'comercial.montecaseros@okdespacho.demo'); await pg.wait_for_timeout(800)
                await pg.evaluate('(id)=>{const b=document.querySelector(`[data-select="${id}"]`); if(b) b.click()}', guardada['id']); await pg.wait_for_timeout(900)
                cmp = await pg.evaluate('()=>{const c=document.querySelector("[data-cal-detalle]"); return c?[...c.children].map(x=>({titulo:(x.querySelector(".label")||{}).innerText, fechas:[...x.querySelectorAll("[data-cal-due]")].map(e=>e.innerText)})):null}')
                await pg.screenshot(path=os.path.join(OUT, '4_comercial_original_y_propuesto_movil.png'), full_page=True)
                await pg.click('#rAccept'); await pg.wait_for_timeout(1200)
                res('CU-E05 [móvil] el COMERCIAL ve el calendario SOLICITADO y el PROPUESTO lado a lado ANTES de aceptar o retirar; acepta',
                    cmp and len(cmp) == 2 and 'SOLICITADO' in cmp[0]['titulo'] and cmp[0]['fechas'] == [DMY(d[15]), DMY(d[30])] and 'PROPUESTO' in cmp[1]['titulo'] and len(cmp[1]['fechas']) == 3, cmp)
                # ===== CU-E06 · aprobación e HISTORIAL (solicitado, propuesto y autorizado con su calendario en cada paso) =====
                await cc.relog(pg, 'wilfredo@okdespacho.demo'); await pg.evaluate('()=>{location.hash="#/autorizaciones?v=gerencia"}'); await pg.wait_for_timeout(1800)
                await pg.evaluate('(id)=>{const b=document.querySelector(`[data-select="${id}"]`); if(b) b.click()}', guardada['id']); await pg.wait_for_timeout(800)
                await pg.click('[data-dec="APROBAR"]'); await pg.wait_for_timeout(400); await pg.click('#dGo'); await pg.wait_for_timeout(1300)
                await pg.select_option('#gFilter', 'TODAS'); await pg.wait_for_timeout(1200)   # la aprobada ya no está entre las pendientes
                await pg.evaluate('(id)=>{const b=document.querySelector(`[data-select="${id}"]`); if(b) b.click()}', guardada['id']); await pg.wait_for_timeout(900)
                hist = await pg.evaluate('()=>({bloques:[...document.querySelectorAll("[data-cal-detalle] > div .label")].map(e=>e.innerText), pasos:[...document.querySelectorAll("[data-cal-paso]")].map(e=>e.innerText)})')
                await pg.screenshot(path=os.path.join(OUT, '5_historial_autorizado_movil.png'), full_page=True)
                res('CU-E06 [móvil] aprobada: el detalle muestra el calendario SOLICITADO y el AUTORIZADO, y la trazabilidad conserva el calendario de cada paso (solicitado, propuesto, reenviado)',
                    any('SOLICITADO' in x for x in hist['bloques']) and any('AUTORIZADO' in x for x in hist['bloques']) and len(hist['pasos']) >= 3, hist)
                # ===== CU-E07 · solicitud HISTÓRICA intacta + solicitud MANIPULADA rechazada =====
                await pg.evaluate('''()=>{const d=JSON.parse(localStorage.getItem("okd_online_demo_v2")); const t=d.com.requests.find(x=>x.order_ref==="CU-1"); const q=JSON.parse(JSON.stringify(t));
                  q.id="hist-vieja"; q.number="AUT-VIEJA"; q.order_ref="VIEJA"; q.op_id="op-vieja"; q.status="PENDIENTE";
                  q.original_terms=q.current_terms={amount:500000, installments:2, schedule:[{n:1,due:"2026-01-08",amount:250000},{n:2,due:"2026-01-15",amount:250000}], last_due:"2026-01-15", days:14}; q.final_terms=null;
                  d.com.requests.push(q); localStorage.setItem("okd_online_demo_v2", JSON.stringify(d));}''')
                await pg.reload(); await pg.evaluate('()=>{location.hash="#/autorizaciones?v=gerencia"}'); await pg.wait_for_timeout(1800)
                await pg.evaluate('()=>{const b=document.querySelector(`[data-select="hist-vieja"]`); if(b) b.click()}'); await pg.wait_for_timeout(800)
                vieja = await pg.evaluate('()=>[...document.querySelectorAll("[data-cal-detalle] [data-cal-due]")].map(e=>e.innerText)')
                await cc.relog(pg, 'comercial.montecaseros@okdespacho.demo')
                manip = await pg.evaluate('''async(f)=>{const A=window.OKD_ONLINE.api, cl=(await A.comSearchClients("TECNO")).find(c=>c.selectable);
                  try{ await A.comCreate("FINANCIACION", cl.id, "MANIP", {amount:100000, installments:1, first_due:f, schedule:[{n:1,due:"2026-11-20",amount:1}]}, null, "op-manip"); return "ACEPTADA"; }catch(e){ return e.code+" "+e.message }}''', d[31])
                res('CU-E07 una solicitud HISTÓRICA (formato anterior) se muestra con SUS fechas registradas, sin reinterpretar; una solicitud MANIPULADA a hoy+31 (con calendario falso) se RECHAZA',
                    vieja == ['08/01/2026', '15/01/2026'] and manip.startswith('BAD_SCHEDULE'), {'historica': vieja, 'manipulada': manip[:120]})
            finally: await b.close()
    finally: srv.terminate()
    print('TOTAL', sum(1 for r in R if r[1] == 'PASS'), 'PASS /', sum(1 for r in R if r[1] == 'FAIL'), 'FAIL · esperados', EXPECTED)
    return R
if __name__ == '__main__':
    try: rr = asyncio.run(main())
    except Exception as e: traceback.print_exc(); print('ERROR:', repr(e)); sys.exit(2)
    if len(rr) != EXPECTED: print('ERROR: se ejecutaron %d de %d' % (len(rr), EXPECTED)); sys.exit(2)
    sys.exit(1 if any(r[1] != 'PASS' for r in rr) else 0)
