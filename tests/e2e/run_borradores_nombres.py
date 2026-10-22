"""E2E (modo demo, Chromium) · nombres claros de borradores (V4.16). Informes SINTÉTICOS (generate_synthetic_saldo_noc.py: estado
"Facturado ZONA ESTE" → Cristian Torres - Este). Código de salida: 0 todo PASS · 1 alguna FAIL · 2 error de preparación o casos faltantes."""
import asyncio, os, subprocess, sys, time, socket, traceback
from playwright.async_api import async_playwright
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
DIST = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'dist-demo'); PORT = 4376
FIX = os.environ.get('OKD_FIXTURES_SALDO', '/tmp/okd_synth_saldo'); FILES = ['informe_pedidos_qa.xlsx', 'saldo_comprobante_qa.xlsx', 'saldo_cuenta_corriente_qa.xlsx']
R = []; EXPECTED = 10
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:240])); print('..', ' | '.join(R[-1]), flush=True)
TABS = '()=>[...document.querySelectorAll("#sheetTabs .stab b:first-child")].map(b=>b.textContent.trim())'
REOPEN = '()=>[...document.querySelectorAll("#tabReopen option")].map(o=>o.textContent.trim())'
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
async def builder(pg):
    for _ in range(6):
        await pg.evaluate('()=>{ if (location.hash!=="#/despacho") location.hash="#/despacho"; }'); await pg.wait_for_timeout(1500); await dismiss(pg)
        if await pg.evaluate('()=>{const u=document.getElementById("usersPanel"); const o=document.getElementById("operario"); return (!u||u.hidden) && !!o && !o.hidden}'): break
    if not await pg.evaluate('()=>typeof OrderIndex!=="undefined" && OrderIndex.size()>0 && !!(RouteStore.data.sc && RouteStore.data.cc)'):
        await pg.set_input_files('.file[data-kind="pedidos"] input', [os.path.join(FIX, f) for f in FILES])
        for _ in range(150):
            await pg.wait_for_timeout(300)
            if await pg.evaluate('()=>typeof OrderIndex!=="undefined" && OrderIndex.size()>0 && !!(RouteStore.data.sc && RouteStore.data.cc)'): break
        await pg.wait_for_timeout(1500)
async def add(pg, ids): await pg.fill('#ids', ids); await pg.click('#btnSearch'); await pg.wait_for_timeout(2500)
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
            pg = await (await b.new_context(viewport={'width': 1366, 'height': 900})).new_page(); dlg = {'answer': None}
            pg.on('dialog', lambda d: asyncio.ensure_future(d.accept(dlg['answer']) if d.type == 'prompt' and dlg['answer'] else d.accept()))
            await pg.goto(f'http://127.0.0.1:{PORT}/'); await pg.evaluate('()=>localStorage.clear()')
            await pg.evaluate('()=>new Promise(r=>{const q=indexedDB.deleteDatabase("ok_despacho"); q.onsuccess=q.onerror=q.onblocked=()=>r()})')
            await login(pg, 'admin@okdespacho.demo'); await builder(pg)
            t0 = await pg.evaluate(TABS)
            res('NOM-01 hoja vacía (sin transportista): "Borrador sin asignar" (no "Hoja N")', t0 == ['Borrador sin asignar'], t0)
            await add(pg, '72003'); await pg.wait_for_timeout(800); t1 = await pg.evaluate(TABS); first = await pg.evaluate('()=>RouteStore.sheetId')
            res('NOM-02 con pedidos de Cristian: "Borrador · Cristian Torres — Este" (una sola pestaña, sin número)', t1 == ['Borrador · Cristian Torres — Este'], t1)
            # segundo borrador del MISMO transportista: identificador breve y estable
            await pg.evaluate('async()=>{ await SheetTabs.create(); }'); await pg.wait_for_timeout(800); await add(pg, '72004'); await pg.wait_for_timeout(800)
            t2 = await pg.evaluate(TABS); sid2 = await pg.evaluate('()=>RouteStore.sheetId')
            short = lambda sid: ''.join(ch for ch in sid if ch.isalnum())[-4:].upper()
            ok2 = sorted(t2) == sorted(['Borrador · Cristian Torres — Este · ' + short(first), 'Borrador · Cristian Torres — Este · ' + short(sid2)])
            await pg.evaluate(f'async()=>{{ await SheetTabs.close("{first}"); }}'); await pg.wait_for_timeout(800); t2b = await pg.evaluate(TABS); r2 = await pg.evaluate(REOPEN)
            res('NOM-03 dos del mismo transportista: identificador breve y ESTABLE, sin renumerar al cerrar otro', ok2 and t2b == ['Borrador · Cristian Torres — Este · ' + short(sid2)], {'antes': t2, 'despues_de_cerrar': t2b})
            res('NOM-04 "Reabrir borrador…" muestra el mismo nombre claro', ('Borrador · Cristian Torres — Este · ' + short(first)) in r2, r2)
            # cambio de transportista (nombre automático se actualiza)
            await pg.evaluate('()=>{ RouteStore.rows.forEach(r=>{ r.transportista="UCO"; }); RouteStore.save(); SheetTabs.render(); }'); await pg.wait_for_timeout(600)
            t3 = await pg.evaluate(TABS)
            res('NOM-05 al cambiar el transportista, el nombre automático se actualiza ("Borrador · Uco")', t3 == ['Borrador · Uco'], t3)
            # nombre PERSONALIZADO: se conserva (aunque cambie el transportista) y se guarda en el servidor
            dlg['answer'] = 'Reparto especial jueves'; await pg.evaluate(f'()=>SheetTabs.rename("{sid2}")'); await pg.wait_for_timeout(1500)
            await pg.evaluate('()=>{ RouteStore.rows.forEach(r=>{ r.transportista="CRISTIAN TORRES - ESTE"; }); RouteStore.save(); SheetTabs.render(); }'); await pg.wait_for_timeout(1500)
            t4 = await pg.evaluate(TABS); srvname = await pg.evaluate(f'()=>{{const d=JSON.parse(localStorage.getItem("okd_online_demo_v2")); const x=Object.values(d.drafts||{{}}).find(x=>x.client_sheet_key==="{sid2}"); return x?x.name:null}}')
            res('NOM-06 nombre personalizado: se conserva al cambiar el transportista y queda igual en el servidor', t4 == ['Reparto especial jueves'] and srvname == 'Reparto especial jueves', {'pestaña': t4, 'servidor': srvname})
            # listado de BORRADORES: el automático llega con su nombre claro
            await pg.evaluate(f'async()=>{{ await SheetTabs.switchTo("{first}"); }}'); await pg.wait_for_timeout(1800)
            await pg.evaluate('()=>{location.hash="#/borradores"}'); await pg.wait_for_timeout(2000)
            lst = await pg.evaluate('()=>[...document.querySelectorAll("#usersPanel table tbody tr td:first-child")].map(td=>td.textContent.trim())')
            await builder(pg); lbl = await pg.evaluate(f'()=>SheetTabs.label(SheetTabs.tab("{first}"))')
            # el identificador breve aparece solo si hay VARIOS automáticos del mismo transportista (el otro ahora es personalizado)
            res('NOM-07 listado de Borradores: el automático con el MISMO nombre claro que la pestaña y el personalizado tal cual', lbl.startswith('Borrador · Cristian Torres — Este') and lbl in lst
                and 'Reparto especial jueves' in lst and not any(x.startswith('Hoja ') for x in lst), {'listado': lst, 'pestaña': lbl})
            # número OFICIAL después de publicar
            await builder(pg); await pg.evaluate(f'async()=>{{ await SheetTabs.switchTo("{first}"); RouteStore.published = {{id:"r-qa", number:"01-000123", at:new Date().toISOString(), carrier:"CRISTIAN TORRES - ESTE", responsable:"", mode:"APP"}}; SheetTabs.touch(); SheetTabs.render(); }}'); await pg.wait_for_timeout(800)
            t5 = await pg.evaluate(TABS)
            res('NOM-08 después de publicar se muestra el número oficial ("Hoja 01-000123")', 'Hoja 01-000123' in t5, t5)
            # pestañas ANTIGUAS (sin nameMode): se adaptan SOLO si el origen se comprueba; IDs/dueños/pedidos intactos
            me = await pg.evaluate('()=>window.OKD_ME.id')
            # la activa es 'leg-b' (vacía): el contenido de la hoja ACTIVA define sus pedidos; acá se prueba solo la adaptación de NOMBRES
            await pg.evaluate(f'''async()=>{{ const i={{active:'leg-b', tabs:[
                {{id:'leg-a', name:'Hoja 1', closed:false, orders:['72003'], owner:'{me}', carrier:'CRISTIAN TORRES - ESTE'}},
                {{id:'leg-b', name:'Hoja 21', closed:false, orders:[], owner:'{me}'}},
                {{id:'leg-c', name:'Mi hoja especial', closed:false, orders:['72004'], owner:'{me}', carrier:'CRISTIAN TORRES - ESTE'}}]}};
              await DB.set('sheets_index', i); await DB.set('sheet:leg-b', {{sheetId:'leg-b', rows:[]}}); }}''')
            await pg.reload(); await pg.wait_for_timeout(2500); await builder(pg)
            t6 = await pg.evaluate(TABS); idx = await pg.evaluate('async()=>(await DB.get("sheets_index")).tabs.map(t=>[t.id,t.name,t.owner,(t.orders||[]).join(",")])')
            res('NOM-09 antiguas: "Hoja 1" en el lugar 1 (origen comprobado) se adapta; "Hoja 21" (origen no comprobable) y "Mi hoja especial" se CONSERVAN',
                'Hoja 21' in t6 and 'Mi hoja especial' in t6 and 'Hoja 1' not in t6 and 'Borrador · Cristian Torres — Este' in t6, t6)
            res('NOM-10 la adaptación no cambia IDs, dueños, pedidos ni nombres guardados', [x[0] for x in idx[:3]] == ['leg-a', 'leg-b', 'leg-c'] and [x[1] for x in idx[:3]] == ['Hoja 1', 'Hoja 21', 'Mi hoja especial']
                and all(x[2] == me for x in idx[:3]) and idx[0][3] == '72003' and idx[2][3] == '72004', idx[:3])
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
