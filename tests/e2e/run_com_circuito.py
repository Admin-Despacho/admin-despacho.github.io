"""E2E BLOQUEANTE (modo demo, Chromium notebook y Android) · AUTORIZACIONES COMERCIALES: circuito completo
COMERCIAL ENVÍA → WILFREDO O ADMINISTRADOR RESUELVE → COMERCIAL RECIBE RESPUESTA → DESPACHO VE EL ESTADO; permisos, suplencia, Panel,
informes, ingesta sin pérdidas (IndexedDB + reintento) y correos solo preparados. Datos FICTICIOS; sin envíos reales."""
import asyncio, os, sys, json, traceback
sys.path.insert(0, os.path.dirname(__file__))
import run_driver_perfiles as dp
from playwright.async_api import async_playwright
dp.PORT = 4510; R = []; EXPECTED = 11
if len(sys.argv) > 1: dp.DIST = sys.argv[1]
OUT = sys.argv[2] if len(sys.argv) > 2 else '/tmp/okd_com'
K = 'okd_online_demo_v2'
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:420])); print('..', ' | '.join(R[-1]), flush=True)
DB = '()=>JSON.parse(localStorage.getItem("%s")).com' % K
OV = '()=>document.documentElement.scrollWidth-document.documentElement.clientWidth'
async def relog(pg, email):
    await pg.evaluate('async()=>{try{await window.OKD_ONLINE.api.signOut()}catch(e){}}'); await pg.goto(f'http://127.0.0.1:{dp.PORT}/'); await dp.login(pg, email); await pg.wait_for_timeout(800)
    try: await pg.wait_for_selector('#comMain .heading, #comMain .note, .dash, #rc4LegacyNav, nav', timeout=15000)
    except Exception: pass
    await pg.wait_for_timeout(500)
async def sync(src, dst):   # en la DEMO cada navegador tiene su propia base local: se copia para simular el servidor común
    v = await src.evaluate('()=>localStorage.getItem("%s")' % K); await dst.evaluate('(v)=>localStorage.setItem("%s", v)' % K, v)
async def admin_tab(pg, v):
    await pg.evaluate('(v)=>{location.hash="#/autorizaciones?v="+v}', v); await pg.wait_for_selector('#comMain .heading', timeout=15000); await pg.wait_for_timeout(600)
async def pick_client(pg, q, name):
    await pg.fill('#cSearch', q); await pg.wait_for_timeout(900)
    await pg.locator('#cSugg button', has_text=name).first.click(); await pg.wait_for_timeout(900)
async def main():
    os.makedirs(OUT, exist_ok=True); srv = dp.serve()
    try:
        async with async_playwright() as p:
            b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
            try:
                nb = await b.new_context(viewport={'width': 1366, 'height': 1000}); pg = await nb.new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
                await pg.goto(f'http://127.0.0.1:{dp.PORT}/'); await pg.evaluate('()=>localStorage.clear()')
                an = await b.new_context(viewport={'width': 390, 'height': 844}, is_mobile=True, has_touch=True); q = await an.new_page()
                # ---- CO-01 Comercial (Android): buscar → elegir → CUIT y KPI automáticos → enviar ----
                # V5 (N-V4-03): el KPI arranca DESHABILITADO; este circuito verifica el CÁLCULO, así que el Administrador lo ACTIVA por el camino real y auditado
                await dp.login(pg, 'admin@okdespacho.demo'); await pg.wait_for_timeout(1200)
                await pg.evaluate('async()=>{await window.OKD_ONLINE.api.comSetKpiMode("PROVISORIO", "Prueba local: activación AUTORIZADA (simulada) por Dirección General")}')
                await pg.evaluate('async()=>{try{await window.OKD_ONLINE.api.signOut()}catch(e){}}')
                await q.goto(f'http://127.0.0.1:{dp.PORT}/'); await sync(pg, q); await dp.login(q, 'comercial.montecaseros@okdespacho.demo'); await q.wait_for_selector('#cSearch', timeout=20000); await q.wait_for_timeout(400)
                tabs = await q.evaluate('()=>[...document.querySelectorAll("#comHome [data-tab]")].map(b=>b.dataset.tab)')
                await q.fill('#cSearch', 'TECNO'); await q.wait_for_timeout(900)
                sug = await q.evaluate('()=>[...document.querySelectorAll("#cSugg button")].map(b=>({t:b.innerText.replace(/\\s+/g," "), dis:b.disabled}))')
                await q.locator('#cSugg button', has_text='TECNOLOGIA DEL NORTE').first.click(); await q.wait_for_timeout(900)
                cuit = await q.input_value('#cCuit'); kpi = await q.evaluate('()=>document.getElementById("cKpi").innerText.replace(/\\s+/g," ")')
                await q.fill('#cOrder', '26764'); await q.fill('#cAmount', '2750000'); await q.select_option('#cInst', '4'); await q.wait_for_timeout(300)
                sched = await q.locator('.scheditem').count(); ov1 = await q.evaluate(OV)
                await q.screenshot(path=os.path.join(OUT, '01_comercial_nueva_solicitud_android.png'), full_page=True)
                await q.click('#cSend'); await q.wait_for_timeout(1500)
                mine = await q.evaluate('()=>[...document.querySelectorAll(".requests [data-select]")].map(b=>b.innerText.replace(/\\s+/g," "))')
                res('CO-01 COMERCIAL (Android): entra DIRECTO a Autorizaciones; «TECNO» sugiere clientes (el CUIT duplicado NO seleccionable); al elegir, CUIT y KPI AUTOMÁTICOS (provisorio: $2.000.000 / piso $2.500.000 / techo $3.000.000); cronograma de 4 cuotas; ENVIAR → pendiente para Wilfredo; sin desplazamiento horizontal',
                    tabs == ['comercial', 'historial'] and any('TECNOCASA' in s['t'] and s['dis'] and 'EN REVISIÓN' in s['t'] for s in sug) and cuit == '30500010912' and '$ 2.000.000' in kpi and '$ 3.000.000' in kpi and '$ 2.500.000' in kpi
                    and 'RECOMENDACIÓN PROVISORIA' in kpi and sched == 4 and ov1 <= 0 and mine and 'Pendiente de aprobación' in mine[0] and '26764' in mine[0], {'tabs': tabs, 'cuit': cuit, 'kpi': kpi[:200], 'mis': mine[:1]})
                await q.fill('#cSearch', 'ZZZZZZ'); await q.wait_for_timeout(900); nf = await q.evaluate('()=>document.getElementById("cSugg").innerText')
                await q.fill('#cSearch', 'TECNOLOGIA'); await q.wait_for_timeout(200); await q.fill('#cAmount', '1000'); await q.click('#cSend'); await q.wait_for_timeout(600)
                tst = await q.evaluate('()=>[...document.querySelectorAll("#comToast .toast")].map(t=>t.textContent).join(" | ")')
                res('CO-02 CLIENTE NO ENCONTRADO con el procedimiento; escribir un nombre SIN elegirlo de la lista NO permite enviar (nombre y CUIT siempre vinculados al registro)', 'CLIENTE NO ENCONTRADO' in nf and 'Elegí el cliente de la lista' in tst, {'no': nf[:120], 'toast': tst[:120]})
                # ---- CO-03 Wilfredo aprueba con cambios ----
                await sync(q, pg); await relog(pg, 'wilfredo@okdespacho.demo')
                wt = await pg.evaluate('()=>[...document.querySelectorAll("#comHome [data-tab]")].map(b=>b.dataset.tab)'); det = await pg.evaluate('()=>document.querySelector("#comMain .grid.two section:last-child").innerText.replace(/\\s+/g," ")')
                await pg.screenshot(path=os.path.join(OUT, '02_wilfredo_bandeja_notebook.png'))
                await pg.click('[data-dec="APROBAR_CON_CAMBIOS"]'); await pg.wait_for_timeout(400); await pg.fill('#dAmount', '2500000'); await pg.select_option('#dInst', '3'); await pg.fill('#dReason', 'Se ajusta al techo sugerido'); await pg.click('#dGo'); await pg.wait_for_timeout(1300)
                d1 = await pg.evaluate(DB); r1 = d1['requests'][0]
                res('CO-03 WILFREDO: su bandeja muestra la solicitud con la FOTO del KPI, la cuenta corriente INFORMADA por Cianbox rotulada NO VERIFICADA con su corte (punto 4) y la trazabilidad; APRUEBA CON CAMBIOS ($2.500.000 · 3 cuotas) con motivo', wt == ['gerencia', 'historial'] and 'KPI al momento de la solicitud' in det and 'SALDO DE CUENTA CORRIENTE INFORMADO POR CIANBOX' in det and 'NO VERIFICADO' in det and 'corte' in det and '$ 1.250.000' in det
                    and r1['status'] == 'APROBADA_MOD' and r1['final_terms']['amount'] == 2500000 and r1['original_terms']['amount'] == 2750000 and r1['decided_as'] == 'APROBADOR', {'tabs': wt, 'estado': r1['status']})
                # ---- CO-04 SUPLENCIA: e-cheq de San Juan (asignado a Wilfredo) resuelto por Gabriela ----
                await relog(pg, 'comercial.sanjuan@okdespacho.demo'); await pg.wait_for_selector('[data-type="ECHEQ"]', timeout=15000); await pg.click('[data-type="ECHEQ"]'); await pg.wait_for_timeout(500)
                await pick_client(pg, 'COMERCIAL CUYO', 'COMERCIAL CUYO'); await pg.fill('#cOrder', 'P-55'); await pg.fill('#cAmount', '900000')
                await pg.evaluate('()=>{const i=document.getElementById("cDue"); const d=new Date(Date.now()+20*864e5); i.value=d.toISOString().slice(0,10);}'); await pg.click('#cSend'); await pg.wait_for_timeout(1400)
                await relog(pg, 'gabriela@okdespacho.demo'); await admin_tab(pg, 'gerencia')
                gd = await pg.evaluate('()=>document.querySelector("#comMain").innerText.replace(/\\s+/g," ")')
                await pg.screenshot(path=os.path.join(OUT, '03_gabriela_suplencia_notebook.png'))
                await pg.click('[data-dec="APROBAR"]'); await pg.wait_for_timeout(300); await pg.click('#dGo'); await pg.wait_for_timeout(1300)
                d2 = await pg.evaluate(DB); e1 = [x for x in d2['requests'] if x['kind'] == 'ECHEQ'][0]
                late = await pg.evaluate('async(a)=>{try{await window.OKD_ONLINE.api.signOut()}catch(e){} return 1}', None)
                await relog(pg, 'wilfredo@okdespacho.demo'); wl = await pg.evaluate('async(id)=>{try{await window.OKD_ONLINE.api.comDecide(id, 1, "RECHAZAR", null, "Llego tarde")}catch(e){return e.message} return "DECIDIÓ"}', e1['id'])
                wbell = await pg.evaluate('()=>document.getElementById("comBellN").textContent')
                tl = [x for x in d2['events'] if x['request_id'] == e1['id']]
                res('CO-04 SUPLENCIA: Gabriela (Administradora General) ve la pendiente «asignada a Wilfredo Guzmán» con el aviso de suplencia y la APRUEBA; queda asignada a Wilfredo y resuelta por Gabriela; Wilfredo ya NO puede decidir (una sola decisión) y recibe el aviso',
                    'Vas a resolver como Administrador General (suplencia)' in gd and 'Wilfredo Guzmán' in gd and e1['status'] == 'APROBADA' and e1['assigned_approver_id'] == 'u-wilfredo' and e1['decided_by'] == 'u-gabriela' and e1['decided_as'] == 'SUPLENTE_ADMIN'
                    and [x['kind'] for x in tl] == ['ENVIADA', 'PENDIENTE', 'APROBADA'] and tl[-1]['actor_label'] == 'Gabriela Brandani — Administrador General' and wl.startswith('CONFLICT') and int(wbell or 0) >= 1, {'tardío': wl[:80], 'campana_w': wbell})
                # ---- CO-05 Comercial recibe la respuesta ----
                await sync(pg, q); await q.evaluate('()=>location.reload()'); await q.wait_for_timeout(2500)
                await q.locator('.requests [data-select]').first.click(); await q.wait_for_timeout(900)
                cr = await q.evaluate('()=>({bell:document.getElementById("comBellN").textContent, det:document.querySelector("#comMain").innerText.replace(/\\s+/g," ")})')
                await q.screenshot(path=os.path.join(OUT, '04_comercial_respuesta_android.png'), full_page=True)
                res('CO-05 COMERCIAL RECIBE LA RESPUESTA: aviso en la campana y su solicitud «Aprobada con modificaciones» con las condiciones AUTORIZADAS y quién resolvió', int(cr['bell'] or 0) >= 1 and 'Aprobada con modificaciones' in cr['det'] and '$ 2.500.000' in cr['det'] and 'Wilfredo Guzmán' in cr['det'], {'campana': cr['bell']})
                # ---- CO-06 Despacho ve el estado ----
                await relog(pg, 'operario@okdespacho.demo'); await admin_tab(pg, 'despacho')
                await pg.fill('#tSearch', '30500010912'); await pg.wait_for_timeout(1500)
                dd = await pg.evaluate('()=>document.querySelector("#comMain").innerText.replace(/\\s+/g," ")')
                await pg.screenshot(path=os.path.join(OUT, '05_despacho_seguimiento_notebook.png'))
                await pg.select_option('#tFilter', '1'); await pg.wait_for_timeout(1200); en_curso = await pg.evaluate('()=>[...document.querySelectorAll(".requests [data-select]")].length')
                res('CO-06 DESPACHO: busca por CUIT y ve estado, línea de tiempo y condiciones FINALES; NO ve el KPI ni notas internas; «en curso» filtra', all(k in dd.upper() for k in ['APROBADA CON MODIFICACIONES', 'SOLICITUD ENVIADA A ADMINISTRACIÓN', 'CONDICIONES AUTORIZADAS'])
                    and not any(k in dd.upper() for k in ['KPI AL MOMENTO', 'CUENTA CORRIENTE']) and en_curso == 0, {'en_curso': en_curso, 'chequeos': {k: (k in dd.upper()) for k in ['APROBADA CON MODIFICACIONES', 'SOLICITUD ENVIADA A ADMINISTRACIÓN', 'CONDICIONES AUTORIZADAS', 'KPI AL MOMENTO', 'CUENTA CORRIENTE']}})
                # ---- CO-07 Devolución (cartera → Franco) ----
                await relog(pg, 'hernan@okdespacho.demo'); await pick_client(pg, 'COMERCIAL CUYO', 'COMERCIAL CUYO'); await pg.fill('#cAmount', '1800000'); await pg.select_option('#cInst', '2'); await pg.click('#cSend'); await pg.wait_for_timeout(1300)
                await relog(pg, 'franco@okdespacho.demo'); await admin_tab(pg, 'gerencia')
                await pg.locator('.requests [data-select]', has_text='Cartera').first.click(); await pg.wait_for_timeout(900)
                await pg.click('[data-dec="DEVOLVER"]'); await pg.wait_for_timeout(300); await pg.fill('#dAmount', '1500000'); await pg.fill('#dReason', 'Bajar el importe'); await pg.click('#dGo'); await pg.wait_for_timeout(1200)
                await relog(pg, 'hernan@okdespacho.demo'); await pg.locator('.requests [data-select]').first.click(); await pg.wait_for_timeout(900)
                hv = await pg.evaluate('()=>document.querySelector("#comMain").innerText.replace(/\\s+/g," ")')
                await pg.click('#rAccept'); await pg.wait_for_timeout(1200)
                d3 = await pg.evaluate(DB); h = [x for x in d3['requests'] if x['channel'] == 'CARTERA'][0]
                res('CO-07 DEVOLUCIÓN (cartera → Franco): «devuelta» NO es aprobación; Hernán ve la propuesta y ACEPTA → vuelve PENDIENTE a Franco con las condiciones aceptadas', 'NO es una aprobación' in hv and '$ 1.500.000' in hv and h['assigned_approver_id'] == 'u-franco'
                    and h['status'] == 'PENDIENTE' and h['current_terms']['amount'] == 1500000, {'estado': h['status']})
                # ---- CO-08 Panel General e informes ----
                await relog(pg, 'admin@okdespacho.demo'); await admin_tab(pg, 'general')
                gp = await pg.evaluate('()=>document.querySelector("#comMain").innerText.replace(/\\s+/g," ")')
                await pg.screenshot(path=os.path.join(OUT, '06_panel_general_notebook.png'))
                await pg.select_option('#sMonths', '6'); await pg.click('#sSave'); await pg.wait_for_timeout(800)
                k6 = await pg.evaluate('async()=>{const A=window.OKD_ONLINE.api; return await A.comKpi("cli-101")}')
                await pg.select_option('#sMonths', '3'); await pg.click('#sSave'); await pg.wait_for_timeout(600)
                await admin_tab(pg, 'informes'); ip = await pg.evaluate('()=>document.querySelector("#comMain").innerText.replace(/\\s+/g," ")')
                await pg.screenshot(path=os.path.join(OUT, '07_informes_notebook.png'))
                res('CO-08 PANEL GENERAL: estado de las cargas (última Saldo comprobante y cuenta corriente, meses con cargas), asignaciones, aprobadores, padrón y tipos; con 6 meses → «SIN HISTORIAL SUFICIENTE · 3 de 6 meses con cargas»; INFORMES con la suplencia y despachos por transportista/zona',
                    all(k.upper() in gp.upper() for k in ['Última «Saldo comprobante»', 'Saldo cuenta corriente', 'Meses con cargas', 'Comercial Montecaseros', 'Vendedores de cartera'])
                    and k6['status'] == 'SIN_HISTORIAL' and '3 de 6 meses con cargas' in k6['detail'] and all(k.upper() in ip.upper() for k in ['Suplencia (Administrador General)', 'Despachos por transportista y zona', 'Concretado']), {'kpi6': k6.get('detail'), 'panel': [k for k in ['Última «Saldo comprobante»','Saldo cuenta corriente','Meses con cargas','Comercial Montecaseros','Vendedores de cartera'] if k not in gp], 'informes': [k for k in ['Suplencia (Administrador General)','Despachos por transportista y zona','Concretado'] if k not in ip]})
                # ---- CO-09 Permisos por rol ----
                await relog(pg, 'cristian@okdespacho.demo')
                pc = await pg.evaluate('async()=>{const A=window.OKD_ONLINE.api; const t=async f=>{try{await f(); return "OK"}catch(e){return e.message.split(":")[0]}}; return {lista:await t(()=>A.comList("TODAS")), track:await t(()=>A.comTrack("x")), cli:await t(()=>A.comSearchClients("TECNO"))}}')
                await relog(pg, 'comercial.montecaseros@okdespacho.demo')
                pm = await pg.evaluate('async()=>{const A=window.OKD_ONLINE.api; const t=async f=>{try{await f(); return "OK"}catch(e){return e.message.split(":")[0]}}; return {panel:await t(()=>A.comSetSettings({floor_pct:50})), todas:await t(()=>A.comList("TODAS")), decidir:await t(()=>A.comDecide("aut-3",2,"APROBAR",null,null)), finanzas:await t(()=>A.comClientFinance("cli-101"))}}')
                res('CO-09 PERMISOS: el transportista no accede al módulo; el Comercial no configura, no ve todas, no decide ni ve la cuenta corriente', all(v == 'FORBIDDEN' for v in pc.values()) and all(v == 'FORBIDDEN' for v in pm.values()), {'transportista': pc, 'comercial': pm})
                # ---- CO-10 Ingesta sin pérdidas (IndexedDB + reintento + sin duplicar) ----
                await relog(pg, 'operario@okdespacho.demo'); await pg.wait_for_timeout(3500)
                payload = {'meta': {'fileName': 'Saldo comprobante prueba.xlsx', 'loadedAt': '2026-11-12T10:00:00Z'}, 'records': [{'c': 'TECNICA INTEGRAL SAS', 'cuit': '30717322637', 'comp': 'FAC A 0009-00000001', 'd': '2026-11-10', 'm': 123456, 's': 123456}]}
                await pg.evaluate('()=>{window.OKD_COM_INGEST_FAIL=true}'); await pg.evaluate('(p)=>window.OKD_COM_INGEST("sc", p)', payload); await pg.wait_for_timeout(2000)
                cnt = 'async()=>new Promise(ok=>{const r=indexedDB.open("okd-com-ingest",1); r.onsuccess=()=>{const t=r.result.transaction("jobs","readonly").objectStore("jobs").count(); t.onsuccess=()=>ok(t.result)}; r.onerror=()=>ok(-1)})'
                pend = await pg.evaluate(cnt); err0 = await pg.evaluate('()=>JSON.parse(localStorage.getItem("%s")).com.ingests.filter(i=>i.status==="ERROR").length' % K); docs0 = await pg.evaluate('()=>Object.keys(JSON.parse(localStorage.getItem("%s")).com.docs).filter(k=>k.startsWith("30717322637|FAC")).length' % K)
                await pg.evaluate('()=>{window.OKD_COM_INGEST_FAIL=false; window.dispatchEvent(new Event("online"))}'); await pg.wait_for_timeout(2500)
                pend2 = await pg.evaluate(cnt); await pg.evaluate('(p)=>window.OKD_COM_INGEST("sc", p)', payload); await pg.wait_for_timeout(2000)
                docs1 = await pg.evaluate('()=>Object.values(JSON.parse(localStorage.getItem("%s")).com.docs).filter(d=>d.key.startsWith("30717322637|FAC")).map(d=>d.seen)' % K)
                errs = await pg.evaluate('()=>JSON.parse(localStorage.getItem("%s")).com.ingests.filter(i=>i.status==="ERROR").length' % K)
                res('CO-10 INGESTA SIN PÉRDIDAS: sin conexión la carga queda GUARDADA en IndexedDB (no se pierde) y el error queda registrado; al volver la conexión se envía y SOLO ENTONCES se borra; la misma carga otra vez NO duplica el comprobante',
                    pend == 1 and docs0 == 0 and err0 >= 1 and pend2 == 0 and docs1 == [1] and errs == 0, {'pendientes': [pend, pend2], 'comprobante_visto': docs1, 'error_al_fallar': err0, 'errores_tras_completar': errs, 'ultimo_error': await pg.evaluate('()=>(JSON.parse(localStorage.getItem("%s")).com.ingests.filter(i=>i.status==="ERROR").pop()||{}).error' % K)})
                # ---- CO-11 Notificaciones simuladas ----
                d4 = await pg.evaluate(DB)
                keys = [(e['request_id'], e['seq'], e['user_id']) for e in d4['emails']]
                res('CO-11 NOTIFICACIONES SIMULADAS: cada aviso genera alerta interna y correo PREPARADO (sin envío real), una sola vez por usuario y evento', len(keys) == len(set(keys)) and all(e['status'] in ('PREPARADO', 'SIN_CORREO') for e in d4['emails']) and len(d4['notifs']) >= 6,
                    {'correos': len(keys), 'avisos': len(d4['notifs'])})
            finally: await b.close()
    finally: srv.terminate()
    print('TOTAL', sum(1 for r in R if r[1] == 'PASS'), 'PASS /', sum(1 for r in R if r[1] == 'FAIL'), 'FAIL · esperados', EXPECTED)
    return R
if __name__ == '__main__':
    try: rr = asyncio.run(main())
    except Exception as e: traceback.print_exc(); print('ERROR:', repr(e)); sys.exit(2)
    if len(rr) != EXPECTED: print('ERROR: se ejecutaron %d de %d' % (len(rr), EXPECTED)); sys.exit(2)
    sys.exit(1 if any(r[1] != 'PASS' for r in rr) else 0)
