"""E2E (modo demo, Chromium) · V4.18.1: un transportista creado por el Operario aparece en el constructor (catálogo del servidor).
Operario SINTÉTICO e informes SINTÉTICOS (generate_synthetic_saldo_noc.py). Controles reales: Configuración → Transportistas (alta y edición),
constructor (selector, agregar pedido, DESPACHAR E IMPRIMIR). Código de salida: 0 todo PASS · 1 alguna FAIL · 2 error de preparación."""
import asyncio, os, subprocess, sys, time, socket, traceback
from playwright.async_api import async_playwright
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
DIST = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'dist-demo'); PORT = 4379
FIX = os.environ.get('OKD_FIXTURES_SALDO', '/tmp/okd_synth_saldo'); FILES = ['informe_pedidos_qa.xlsx', 'saldo_comprobante_qa.xlsx', 'saldo_cuenta_corriente_qa.xlsx']
R = []; EXPECTED = 8
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:240])); print('..', ' | '.join(R[-1]), flush=True)
CARR = '()=>[...document.querySelectorAll("#carriers label.carrier")].map(l=>({t:l.textContent.trim(), dis:l.querySelector("input").disabled, on:l.querySelector("input").checked}))'
async def dismiss(pg):
    for _ in range(3):
        if await pg.locator('#pushLater').count() and await pg.is_visible('#pushLater'): await pg.click('#pushLater'); await pg.wait_for_timeout(300)
        else: break
async def login(pg, email):
    await pg.goto(f'http://127.0.0.1:{PORT}/'); await pg.wait_for_load_state('networkidle'); await pg.wait_for_timeout(500)
    for _ in range(4):
        await pg.fill('#loginEmail', email); await pg.fill('#loginPass', 'demo')
        if await pg.input_value('#loginEmail') == email: break
        await pg.wait_for_timeout(300)
    await pg.click('#loginBtn'); await pg.wait_for_timeout(2500)
    if await pg.locator('#pinA').count() and await pg.is_visible('#pinA'): await pg.fill('#pinA', '123456'); await pg.fill('#pinB', '123456'); await pg.click('#pinGo'); await pg.wait_for_timeout(900)
    await pg.wait_for_timeout(1500); await dismiss(pg)
async def go(pg, h):
    for _ in range(6):
        await pg.evaluate(f'()=>{{ if (location.hash!=="{h}") location.hash="{h}"; }}'); await pg.wait_for_timeout(1500); await dismiss(pg)
        if h != '#/despacho' or await pg.evaluate('()=>{const u=document.getElementById("usersPanel"); const o=document.getElementById("operario"); return (!u||u.hidden) && !!o && !o.hidden}'): break
async def main():
    if not os.path.isfile(os.path.join(DIST, 'index.html')): raise RuntimeError('falta el build demo en ' + DIST)
    if not all(os.path.isfile(os.path.join(FIX, f)) for f in FILES): raise RuntimeError('faltan los informes sintéticos: python3 tests/e2e/generate_synthetic_saldo_noc.py ' + FIX)
    srv = subprocess.Popen([sys.executable, '-m', 'http.server', str(PORT), '--bind', '127.0.0.1'], cwd=DIST, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(60):
            try: socket.create_connection(('127.0.0.1', PORT), 1).close(); break
            except OSError: time.sleep(0.2)
        async with async_playwright() as p:
          b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
          try:
            pg = await (await b.new_context(viewport={'width': 1366, 'height': 900})).new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
            await pg.goto(f'http://127.0.0.1:{PORT}/'); await pg.evaluate('()=>localStorage.clear()')
            await pg.evaluate('()=>new Promise(r=>{const q=indexedDB.deleteDatabase("ok_despacho"); q.onsuccess=q.onerror=q.onblocked=()=>r()})')
            await login(pg, 'admin@okdespacho.demo')
            await pg.evaluate('''async()=>{const A=window.OKD_ONLINE.api; await A.action("create",{full_name:"Operario QA",email:"op.qa@example.invalid",role:"OPERARIO_DEPOSITO",active:true});
              const k="okd_online_demo_v2",d=JSON.parse(localStorage.getItem(k)); d.users.forEach(u=>{ if(/@example\\.invalid$/.test(u.email)) u.status="ACTIVO"; }); localStorage.setItem(k,JSON.stringify(d));}''')
            await pg.evaluate('()=>window.OKD_LOGOUT && window.OKD_LOGOUT()'); await pg.wait_for_timeout(1500)
            # ---- el Operario abre el constructor y carga el informe (la lista todavía no tiene MAKERS) ----
            await login(pg, 'op.qa@example.invalid'); await go(pg, '#/despacho')
            await pg.set_input_files('.file[data-kind="pedidos"] input', [os.path.join(FIX, f) for f in FILES])
            for _ in range(150):
                await pg.wait_for_timeout(300)
                if await pg.evaluate('()=>typeof OrderIndex!=="undefined" && OrderIndex.size()>0 && !!(RouteStore.data.sc && RouteStore.data.cc)'): break
            await pg.wait_for_timeout(1500); c0 = await pg.evaluate(CARR)
            # ---- crea MAKERS en Configuración → Transportistas (controles reales) ----
            await go(pg, '#/configuracion?sec=transportistas'); await pg.wait_for_timeout(1000)
            await pg.fill('#ncId', 'MAKERS'); await pg.fill('#ncName', 'MAKERS'); await pg.select_option('#ncKind', 'EXTERNO'); await pg.click('#ncSave'); await pg.wait_for_timeout(1800)
            cat = await pg.evaluate('async()=>(await window.OKD_ONLINE.api.listCarriers()).filter(c=>c.id==="MAKERS")')
            # ---- vuelve al constructor: aparece con 0 pedidos, sin cerrar sesión ni volver a importar ----
            await go(pg, '#/despacho'); await pg.wait_for_timeout(1500); c1 = await pg.evaluate(CARR)
            mk = next((x for x in c1 if x['t'].startswith('MAKERS')), None)
            res('MK-01 MAKERS creado y activo (código correlativo asignado)', len(cat) == 1 and cat[0]['active'] is not False and bool(cat[0].get('sequence_code')), cat)
            res('MK-02 al volver al constructor MAKERS aparece con 0 pedidos (sin cerrar sesión, borrar caché ni reimportar)', not any(x['t'].startswith('MAKERS') for x in c0) and mk is not None
                and mk['t'] in ('MAKERS0', 'MAKERS 0') and not mk['dis'] and await pg.evaluate('()=>OrderIndex.size()>0'), {'antes': [x['t'] for x in c0], 'despues': [x['t'] for x in c1]})
            # ---- seleccionarlo, agregar un pedido, despachar e imprimir ----
            await pg.locator('#carriers label.carrier', has_text='MAKERS').locator('input').check(); await pg.wait_for_timeout(500)
            await pg.fill('#ids', '72003'); await pg.click('#btnSearch'); await pg.wait_for_timeout(2500)
            # regla existente: un pedido del informe conserva el transportista del informe; el operario lo cambia EN LA FILA (selector del catálogo)
            rid = await pg.evaluate('()=>RouteStore.rows[0].id'); opts = await pg.evaluate(f'()=>[...document.querySelectorAll(\'tr.main-row[data-id="{rid}"] select[data-f="transportista"] option\')].map(o=>o.textContent)')
            await pg.locator(f'tr.main-row[data-id="{rid}"] select[data-f="transportista"]').select_option(label='MAKERS'); await pg.wait_for_timeout(800)
            rows = await pg.evaluate('()=>RouteStore.rows.map(r=>({o:String(r.mainOrder), t:r.transportista}))'); sid = await pg.evaluate('()=>RouteStore.sheetId')
            res('MK-03 el selector de la fila ofrece MAKERS (catálogo) y el pedido queda asignado a MAKERS', 'MAKERS' in opts and rows == [{'o': '72003', 't': 'MAKERS'}], {'opciones': opts, 'filas': rows})
            # persistencia: recargar conserva la selección (por ID)
            await pg.evaluate('async()=>{ await RouteStore.flush(); }'); await pg.reload(); await pg.wait_for_timeout(2500); await go(pg, '#/despacho'); await pg.wait_for_timeout(1500)
            if await pg.evaluate('()=>RouteStore.sheetId') != sid: await pg.evaluate(f'async()=>{{ await SheetTabs.switchTo("{sid}"); }}'); await pg.wait_for_timeout(1200)
            per = await pg.evaluate('()=>({sel:[...RouteStore.selected], id:RouteStore.selectedCarrierId, rows:RouteStore.rows.length})')
            res('MK-04 el borrador conserva la selección (por ID) y el pedido al recargar', per == {'sel': ['MAKERS'], 'id': 'MAKERS', 'rows': 1}, per)
            # renombrar (Configuración) → sin duplicar y sin perder la selección
            await go(pg, '#/configuracion?sec=transportistas'); await pg.wait_for_timeout(1000)
            tr = pg.locator('#carrTable tr[data-cid="MAKERS"]'); await tr.locator('[data-f="name"]').fill('MAKERS LOGÍSTICA'); await tr.locator('[data-save]').click(); await pg.wait_for_timeout(1500)
            await go(pg, '#/despacho'); await pg.wait_for_timeout(1500)
            if await pg.evaluate('()=>RouteStore.sheetId') != sid: await pg.evaluate(f'async()=>{{ await SheetTabs.switchTo("{sid}"); }}'); await pg.wait_for_timeout(1200)
            c2 = await pg.evaluate(CARR); ren = await pg.evaluate('()=>({sel:[...RouteStore.selected], rows:RouteStore.rows.map(r=>r.transportista)})')
            res('MK-05 renombrado: un solo MAKERS (con el nombre nuevo), la selección y el pedido siguen', sum(1 for x in c2 if x['t'].startswith('MAKERS')) == 1
                and any(x['t'].startswith('MAKERS LOGÍSTICA') and x['on'] for x in c2) and ren == {'sel': ['MAKERS LOGÍSTICA'], 'rows': ['MAKERS LOGÍSTICA']}, {'lista': [x['t'] for x in c2], 'hoja': ren})
            # DESPACHAR E IMPRIMIR → hoja despachada y PDF guardado
            await pg.evaluate('''async()=>{ RouteStore.rows.forEach(r=>{ r.acks=r.acks||{}; baseStatus(r).issues.filter(canAck).forEach(i=>{ r.acks[ackKey(i)]=new Date().toISOString(); });
              if(r.payMain==="REVISAR"){ r.payMain="EFECTIVO"; r.payMainManual=true; } }); CalculationEngine.computeAll(RouteStore.rows); await RouteStore.flush(); }''')
            await pg.evaluate('()=>Publisher.open()'); await pg.wait_for_selector('#publishModal', timeout=15000); await pg.wait_for_timeout(1500)
            btn = (await pg.locator('#pubGo').inner_text()).strip(); await pg.click('#pubGo'); await pg.wait_for_timeout(5000)
            perr = await pg.evaluate('()=>{const m=document.getElementById("publishModal"); if(!m) return null; const e=m.querySelector("#pubErr"); return {abierto:true, error:e&&!e.hidden?e.textContent:null, bloqueo:(m.querySelector("#pubBlock")||{}).textContent||null}}')
            if perr: await pg.evaluate('()=>{const m=document.getElementById("publishModal"); if(m) m.remove();}')   # si el despacho falló, se informa en MK-06 y se cierra el modal
            out = await pg.evaluate(f'''()=>{{const d=JSON.parse(localStorage.getItem("okd_online_demo_v2")); const r=(d.routes2||[]).find(x=>x.sheet_key==="{sid}");
              const p=r?Object.values(d.routePdfs||{{}}).find(x=>x.route_id===r.id):null; return r?{{mode:r.dispatch_mode, carrier:r.carrier_id, number:r.number, pdf:p?p.status:null}}:null}}''')
            res('MK-06 DESPACHAR E IMPRIMIR con MAKERS: hoja despachada (EXTERNAL) con su PDF guardado', btn == 'DESPACHAR E IMPRIMIR' and out and out['mode'] == 'EXTERNAL' and out['carrier'] == 'MAKERS' and out['pdf'] == 'OK', {'boton': btn, 'hoja': out, 'modal': perr})
            # inactivo: no se puede elegir para hojas nuevas
            await go(pg, '#/configuracion?sec=transportistas'); await pg.wait_for_timeout(1000)
            tr = pg.locator('#carrTable tr[data-cid="MAKERS"]'); await tr.locator('[data-f="active"]').uncheck(); await tr.locator('[data-save]').click(); await pg.wait_for_timeout(1500)
            await go(pg, '#/despacho'); await pg.evaluate('async()=>{ await SheetTabs.create(); }'); await pg.wait_for_timeout(1500); c3 = await pg.evaluate(CARR)
            res('MK-07 inactivo: no aparece para elegir en una hoja nueva', not any(x['t'].startswith('MAKERS') for x in c3), [x['t'] for x in c3])
            # fallo de carga del catálogo → aviso + REINTENTAR
            await pg.evaluate('()=>{ const b=window.OKD_BRIDGE.routes; b.__c=b.carriers; b.carriers=async()=>{ throw new Error("Failed to fetch"); }; return CarrierCatalog.load(); }'); await pg.wait_for_timeout(600)
            err = await pg.evaluate('()=>!!document.getElementById("carrierErr") && !!document.getElementById("carrierRetry")')
            await pg.evaluate('()=>{ const b=window.OKD_BRIDGE.routes; b.carriers=b.__c; }'); await pg.click('#carrierRetry'); await pg.wait_for_timeout(1200)
            ok8 = await pg.evaluate('()=>!document.getElementById("carrierErr") && document.querySelectorAll("#carriers label.carrier").length > 0')
            res('MK-08 si falla la carga del catálogo: aviso con REINTENTAR, y al reintentar vuelve la lista', err and ok8, {'aviso': err, 'reintento': ok8})
          finally: await b.close()
    finally:
        if srv.poll() is None: srv.terminate(); srv.wait(5)
    print('TOTAL', sum(1 for r in R if r[1] == 'PASS'), 'PASS /', sum(1 for r in R if r[1] == 'FAIL'), 'FAIL · esperados', EXPECTED)
    return R
if __name__ == '__main__':
    try: rr = asyncio.run(main())
    except Exception as e: traceback.print_exc(); print('ERROR:', repr(e)); sys.exit(2)
    if len(rr) != EXPECTED: print('ERROR: se ejecutaron %d de %d' % (len(rr), EXPECTED)); sys.exit(2)
    sys.exit(1 if any(r[1] != 'PASS' for r in rr) else 0)
