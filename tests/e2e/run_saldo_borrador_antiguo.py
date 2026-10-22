"""E2E (modo demo, Chromium) · caso real "saldo no encontrado" en un borrador ANTERIOR a V4.11, resuelto con clics y campos reales.
NO se asigna saldoRevisado en la prueba: todo pasa por la interfaz (tabla, botón PUBLICAR, panel REVISAR, GUARDAR IMPORTE, casillas).
Versión anterior y nueva se sirven desde el MISMO origen (comparten almacenamiento, como al actualizar).
Uso: OKD_PREV_DIST=<build demo anterior a V4.11> python3 tests/e2e/run_saldo_borrador_antiguo.py [dist-demo]
Informes SINTÉTICOS: python3 tests/e2e/generate_synthetic_saldo_noc.py /tmp/okd_synth_saldo
Código de salida: 0 todo PASS · 1 alguna FAIL · 2 error de preparación o casos faltantes."""
import asyncio, os, subprocess, sys, time, socket, traceback
from playwright.async_api import async_playwright
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
NEW = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'dist-demo'); PREV = os.environ.get('OKD_PREV_DIST', '')
FIX = os.environ.get('OKD_FIXTURES_SALDO', '/tmp/okd_synth_saldo'); FILES = ['informe_pedidos_qa.xlsx', 'saldo_comprobante_qa.xlsx', 'saldo_cuenta_corriente_qa.xlsx']
PORT = 4373; R = []; EXPECTED = 11
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:240])); print('..', ' | '.join(R[-1]), flush=True)
def serve(d):
    p = subprocess.Popen([sys.executable, '-m', 'http.server', str(PORT), '--bind', '127.0.0.1'], cwd=d, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(60):
        try: socket.create_connection(('127.0.0.1', PORT), 1).close(); return p
        except OSError: time.sleep(0.2)
    raise RuntimeError('servidor no respondió')
def stop(p):
    if p and p.poll() is None: p.terminate(); p.wait(5)
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
    # espera a que el CONSTRUCTOR quede visible (el panel/Dashboard no debe taparlo); reintenta la navegación si la sesión tardó
    for _ in range(8):
        await pg.evaluate('()=>{ if (location.hash!=="#/despacho") location.hash="#/despacho"; else window.dispatchEvent(new HashChangeEvent("hashchange")); }'); await pg.wait_for_timeout(1500); await dismiss(pg)
        if await pg.evaluate('()=>{const u=document.getElementById("usersPanel"); const o=document.getElementById("operario"); return (!u||u.hidden) && !!o && !o.hidden}'): break
    if not await pg.evaluate('()=>typeof OrderIndex!=="undefined" && OrderIndex.size()>0 && !!(RouteStore.data.sc && RouteStore.data.cc)'):
        await pg.set_input_files('.file[data-kind="pedidos"] input', [os.path.join(FIX, f) for f in FILES])
        for _ in range(150):
            await pg.wait_for_timeout(300)
            if await pg.evaluate('()=>typeof OrderIndex!=="undefined" && OrderIndex.size()>0 && !!(RouteStore.data.sc && RouteStore.data.cc)'): break
        await pg.wait_for_timeout(1500)
async def type_amount(pg, oid, txt):
    rid = await pg.evaluate(f'()=>RouteStore.rows.find(r=>String(r.mainOrder)==="{oid}").id')
    inp = pg.locator(f'tr.main-row[data-id="{rid}"] input[data-f="monto"]').first
    await inp.click(); await inp.fill(txt); await inp.press('Tab'); await pg.wait_for_timeout(800)
async def open_sheet(pg, sid):
    if await pg.evaluate('()=>RouteStore.sheetId') != sid: await pg.evaluate(f'async()=>{{ await SheetTabs.switchTo("{sid}"); }}'); await pg.wait_for_timeout(1500)
async def click_publish(pg):
    await dismiss(pg); await pg.locator('#btnPublish').click(); await pg.wait_for_selector('#publishModal', timeout=15000); await pg.wait_for_timeout(2500)
STATUS = '''(id)=>{const r=RouteStore.rows.find(x=>String(x.mainOrder)===id); if(!r) return null; const st=baseStatus(r);
  return {mm:r.montoMercaderiaManual==null?null:r.montoMercaderiaManual, codes:st.issues.filter(i=>i.level!=="info").map(i=>i.code), blocked:Publisher.problems().includes(r)}}'''
PANEL = '''()=>{const m=document.getElementById("publishModal"); if(!m) return null; const pp=m.querySelector("#pubPend");
  return {marker:m.dataset.qa||null, open:!!pp&&!pp.hidden, ready:(m.querySelector("#pubReady b")||{}).textContent, go:!m.querySelector("#pubGo").disabled,
    items:[...m.querySelectorAll("#pubReady li.err")].map(li=>li.textContent), block:(m.querySelector("#pubBlock")||{hidden:true}).hidden?null:m.querySelector("#pubBlock").textContent,
    rows:[...m.querySelectorAll("#pubPend .pendrow")].map(el=>({id:(el.querySelector(".pendhead b")||{}).textContent, motivos:[...el.querySelectorAll("li")].map(li=>li.textContent),
      field:!!el.querySelector("[data-pamt]"), value:(el.querySelector("[data-pamt]")||{}).value||"", save:!!el.querySelector("[data-psave]")}))}}'''
def prow(p, oid): return next((x for x in (p or {}).get('rows', []) if x['id'] == oid), None)
async def resolve_others(pg):
    for _ in range(14):
        cb = pg.locator('#pubPend [data-pack]:not(:checked)').first
        if await cb.count(): await cb.click(); await pg.wait_for_timeout(700); continue
        pay = pg.locator('#pubPend .pendrow', has=pg.locator('[data-ppay]')).first
        if await pay.count():
            await pay.locator('[data-ppay]').fill('EFECTIVO')
            if await pay.locator('[data-ppayship]').count(): await pay.locator('[data-ppayship]').fill('EFECTIVO')
            await pay.locator('[data-psavepay]').click(); await pg.wait_for_timeout(700); continue
        break
async def main():
    for d in (NEW, PREV):
        if not d or not os.path.isfile(os.path.join(d, 'index.html')): raise RuntimeError('falta un build demo: ' + repr(d) + ' (OKD_PREV_DIST = build demo anterior a V4.11)')
    if not all(os.path.isfile(os.path.join(FIX, f)) for f in FILES): raise RuntimeError('faltan los informes sintéticos en ' + FIX)
    srv = None
    try:
        async with async_playwright() as p:
          b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
          try:
            pg = await (await b.new_context(viewport={'width': 1366, 'height': 900})).new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
            # ===== VERSIÓN ANTERIOR: borrador con 72001 SIN importe (saldo no encontrado) y 72002 con importe escrito en la tabla =====
            srv = serve(PREV)
            await pg.goto(f'http://127.0.0.1:{PORT}/'); await pg.evaluate('()=>localStorage.clear()')
            await pg.evaluate('()=>new Promise(r=>{const q=indexedDB.deleteDatabase("ok_despacho"); q.onsuccess=q.onerror=q.onblocked=()=>r()})')
            await login(pg, 'admin@okdespacho.demo'); await builder(pg)
            await pg.fill('#ids', '72001 72002'); await pg.click('#btnSearch'); await pg.wait_for_timeout(2500)
            await type_amount(pg, '72002', '1800')
            sid = await pg.evaluate('()=>RouteStore.sheetId'); await pg.evaluate('async()=>{ await RouteStore.flush(); }'); await pg.wait_for_timeout(1200)
            old2 = await pg.evaluate('(id)=>{const r=RouteStore.rows.find(x=>String(x.mainOrder)===id); return {manual:!!r.montoManual, mm:r.montoMercaderiaManual, marca:("saldoRevisado" in r)}}', '72002')
            stop(srv)
            # ===== VERSIÓN NUEVA (mismo navegador) =====
            srv = serve(NEW)
            await pg.goto(f'http://127.0.0.1:{PORT}/'); await pg.wait_for_timeout(2500); await dismiss(pg); await builder(pg); await open_sheet(pg, sid)
            s2 = await pg.evaluate(STATUS, '72002')
            res('ANT-01 borrador anterior: el importe escrito en la tabla con la versión vieja se reconoce como saldo revisado al reabrir', old2['manual'] and old2['mm'] == 1800 and not old2['marca']
                and s2['mm'] == 1800 and not any(c.startswith('SALDO NO') or c.startswith('SIN COMPROBANTE') for c in s2['codes']), {'viejo': old2, 'nuevo': s2})
            # (A) PUBLICAR (botón real) → panel REVISAR DESPLEGADO con el motivo y el campo de importe
            await click_publish(pg); await pg.evaluate('()=>{ document.getElementById("publishModal").dataset.qa="misma-ventana"; }')
            p1 = await pg.evaluate(PANEL); r1 = prow(p1, '72001')
            res('ANT-02 al publicar, el panel REVISAR está DESPLEGADO con "saldo no encontrado", el campo de importe actual y GUARDAR IMPORTE', p1['open'] and r1 and r1['field'] and r1['save']
                and any('SALDO NO ENCONTRADO' in t for t in r1['motivos']), {'abierto': p1['open'], '72001': r1})
            res('ANT-03 resumen y bloqueo con motivos concretos (sin el genérico de montos/documentos/financiación/NOC)', not any('montos/documentos' in t for t in p1['items'])
                and any('saldo no encontrado' in t and '72001' in t for t in p1['items']) and p1['block'] and 'saldo no encontrado' in p1['block'], {'items': p1['items'], 'bloqueo': p1['block']})
            # inválido → no se aprueba
            row = pg.locator('#pubPend .pendrow', has=pg.locator('.pendhead b', has_text='72001'))
            await row.locator('[data-pamt]').fill('abc'); await row.locator('[data-psave]').click(); await pg.wait_for_timeout(500)
            err = await row.locator('[data-perr]').inner_text(); s_bad = await pg.evaluate(STATUS, '72001')
            res('ANT-04 importe inválido desde REVISAR no se aprueba (sigue "saldo no encontrado")', 'válido' in err and 'SALDO NO ENCONTRADO' in s_bad['codes'] and s_bad['blocked'], {'msg': err, 'codes': s_bad['codes']})
            # válido → saldo revisado, motivo y contador quitados AL INSTANTE, en la misma ventana
            await row.locator('[data-pamt]').fill('1.500'); await row.locator('[data-psave]').click(); await pg.wait_for_timeout(900)
            p2 = await pg.evaluate(PANEL); s1 = await pg.evaluate(STATUS, '72001'); r2 = prow(p2, '72001')
            res('ANT-05 GUARDAR IMPORTE válido: saldo revisado sin otra casilla; el motivo y su contador desaparecen en la MISMA ventana', p2['marker'] == 'misma-ventana' and s1['mm'] == 1500
                and 'SALDO NO ENCONTRADO' not in s1['codes'] and not any('saldo no encontrado' in t for t in p2['items']) and (r2 is None or not any('SALDO NO' in t for t in r2['motivos'])), {'items': p2['items'], '72001': s1})
            res('ANT-06 queda el motivo concreto de lo independiente (envío no encontrado) y cómo resolverlo', any('envío no encontrado' in t.lower() and 'revisado' in t.lower() for t in p2['items']), p2['items'])
            # resolver lo independiente con las casillas y la forma de pago → PUBLICAR habilitado sin cerrar la ventana
            await resolve_others(pg); p3 = await pg.evaluate(PANEL)
            res('ANT-07 sin otros pendientes se habilita PUBLICAR sin cerrar ni reabrir la ventana', p3['marker'] == 'misma-ventana' and p3['go'] and not p3['rows'] and p3['ready'] != 'REVISAR', p3)
            await pg.locator('#pubGo').click(); await pg.wait_for_timeout(5000)
            pub = await pg.evaluate(f'''()=>{{const d=JSON.parse(localStorage.getItem("okd_online_demo_v2")); const r=(d.routes2||[]).find(x=>x.sheet_key==="{sid}");
              return r?r.stops.map(s=>[(s.order_numbers||[])[0], s.merchandise_amount]):null}}''')
            res('ANT-08 la hoja se publica con los importes guardados (1.500 y 1.800)', pub is not None and sorted(pub) == [['72001', 1500], ['72002', 1800]], pub)
            # ===== (B) mismo resultado editando desde la TABLA, y persistencia al reabrir =====
            # 72001 ya quedó PUBLICADO en (A) y no puede ir a otra hoja: (B) arranca con el almacenamiento de la demo limpio
            await pg.evaluate('()=>window.OKD_LOGOUT && window.OKD_LOGOUT()'); await pg.wait_for_timeout(1500)
            await pg.evaluate('()=>localStorage.clear()')
            await pg.evaluate('()=>new Promise(r=>{const q=indexedDB.deleteDatabase("ok_despacho"); q.onsuccess=q.onerror=q.onblocked=()=>r()})')
            await login(pg, 'admin@okdespacho.demo'); await builder(pg)
            await pg.fill('#ids', '72001'); await pg.click('#btnSearch'); await pg.wait_for_timeout(2500); sid2 = await pg.evaluate('()=>RouteStore.sheetId')
            await type_amount(pg, '72001', ''); e0 = await pg.evaluate(STATUS, '72001')
            await type_amount(pg, '72001', '2.500'); t1 = await pg.evaluate(STATUS, '72001')
            res('ANT-09 desde la TABLA: vacío no se aprueba; un importe válido produce el mismo resultado que REVISAR', 'SALDO NO ENCONTRADO' in e0['codes'] and t1['mm'] == 2500
                and 'SALDO NO ENCONTRADO' not in t1['codes'], {'vacio': e0['codes'], 'valido': t1})
            await pg.evaluate('async()=>{ await RouteStore.flush(); }'); await pg.reload(); await pg.wait_for_timeout(2500); await builder(pg); await open_sheet(pg, sid2)
            t2 = await pg.evaluate(STATUS, '72001')
            await click_publish(pg); p4 = await pg.evaluate(PANEL); r4 = prow(p4, '72001')
            res('ANT-10 al reabrir el borrador se conservan importe y revisión (sin "saldo no encontrado")', t2['mm'] == 2500 and 'SALDO NO ENCONTRADO' not in t2['codes'], t2)
            res('ANT-11 al publicar de nuevo, REVISAR no vuelve a pedir el saldo', not any('saldo no encontrado' in t for t in p4['items']) and (r4 is None or not any('SALDO NO' in t for t in r4['motivos'])), {'items': p4['items'], '72001': r4})
          finally: await b.close()
    finally: stop(srv)
    print('TOTAL', sum(1 for r in R if r[1] == 'PASS'), 'PASS /', sum(1 for r in R if r[1] == 'FAIL'), 'FAIL · esperados', EXPECTED)
    return R
if __name__ == '__main__':
    try: rr = asyncio.run(main())
    except Exception as e: traceback.print_exc(); print('ERROR:', repr(e)); sys.exit(2)
    if len(rr) != EXPECTED: print('ERROR: se ejecutaron %d de %d' % (len(rr), EXPECTED)); sys.exit(2)
    sys.exit(1 if any(r[1] != 'PASS' for r in rr) else 0)
