"""E2E (modo demo, Chromium) · saldo ausente + importe manual, panel REVISAR al publicar, NOC automática y bultos opcionales.
Informes SINTÉTICOS (tests/e2e/generate_synthetic_saldo_noc.py): misma forma que el caso real (pedidos facturados después de exportar
la cuenta corriente), sin datos reales. Recorrido: agregar → importe manual → reabrir → PUBLICAR → REVISAR → resolver → continuar.
Código de salida: 0 todo PASS · 1 alguna FAIL · 2 error de preparación o casos faltantes."""
import asyncio, os, subprocess, sys, time, socket, traceback, json
from playwright.async_api import async_playwright
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
DIST = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'dist-demo'); PORT = 4369
FIX = os.environ.get('OKD_FIXTURES_SALDO', '/tmp/okd_synth_saldo')
FILES = ['informe_pedidos_qa.xlsx', 'saldo_comprobante_qa.xlsx', 'saldo_cuenta_corriente_qa.xlsx']
ABSENT = ['SALDO NO ENCONTRADO', 'SALDO NO INFORMADO — REVISAR', 'SIN COMPROBANTE EN INFORME', 'SIN COMPROBANTE / NO ENCONTRADO', 'SIN COMPROBANTE / NO FACTURADO']
R = []; EXPECTED = 14
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:230])); print('..', ' | '.join(R[-1]), flush=True)
ROW = '''(id)=>{const r=RouteStore.rows.find(x=>String(x.mainOrder)===id); if(!r) return null; const st=baseStatus(r);
  return {monto:r.monto, manual:!!r.montoManual, mm:r.montoMercaderiaManual==null?null:r.montoMercaderiaManual, rev:!!r.saldoRevisado, codes:st.issues.map(i=>i.level+":"+i.code),
          blocked:Publisher.problems().includes(r), noc:r.nocApplied||0, bultos:r.bultos==null?null:r.bultos}}'''
async def login(pg, email):
    await pg.goto(f'http://127.0.0.1:{PORT}/'); await pg.wait_for_load_state('networkidle'); await pg.wait_for_timeout(500)
    for _ in range(4):
        await pg.fill('#loginEmail', email); await pg.fill('#loginPass', 'demo')
        if await pg.input_value('#loginEmail') == email: break
        await pg.wait_for_timeout(300)
    await pg.click('#loginBtn'); await pg.wait_for_timeout(2500)
    if await pg.locator('#pinA').count() and await pg.is_visible('#pinA'): await pg.fill('#pinA', '123456'); await pg.fill('#pinB', '123456'); await pg.click('#pinGo'); await pg.wait_for_timeout(900)
    await pg.wait_for_timeout(1200)
    if await pg.locator('#pushLater').count() and await pg.is_visible('#pushLater'): await pg.click('#pushLater'); await pg.wait_for_timeout(200)
async def builder(pg, load=True):
    await pg.evaluate('()=>{location.hash="#/despacho"}'); await pg.wait_for_timeout(1800)
    if load and not await pg.evaluate('()=>typeof OrderIndex!=="undefined" && OrderIndex.size()>0 && !!(RouteStore.data.sc && RouteStore.data.cc)'):
        await pg.set_input_files('.file[data-kind="pedidos"] input', [os.path.join(FIX, f) for f in FILES])
        for _ in range(150):
            await pg.wait_for_timeout(300)
            if await pg.evaluate('()=>typeof OrderIndex!=="undefined" && OrderIndex.size()>0 && !!(RouteStore.data.sc && RouteStore.data.cc)'): break
        await pg.wait_for_timeout(1500)
async def type_amount(pg, oid, txt):
    rid = await pg.evaluate(f'()=>RouteStore.rows.find(r=>String(r.mainOrder)==="{oid}").id')
    inp = pg.locator(f'tr.main-row[data-id="{rid}"] input[data-f="monto"]').first
    await inp.click(); await inp.fill(txt); await inp.press('Tab'); await pg.wait_for_timeout(700)
async def dismiss(pg):
    for _ in range(3):
        if await pg.locator('#pushLater').count() and await pg.is_visible('#pushLater'): await pg.click('#pushLater'); await pg.wait_for_timeout(300)
        else: break
async def open_publish(pg):
    await pg.wait_for_timeout(1500); await dismiss(pg)
    if await pg.locator('#publishModal').count(): await pg.evaluate('()=>document.getElementById("publishModal").remove()')
    await pg.evaluate('()=>Publisher.open()'); await pg.wait_for_selector('#publishModal', timeout=15000); await pg.wait_for_timeout(1800)
async def pend(pg):
    return await pg.evaluate('''()=>({ready:(document.querySelector("#pubReady b")||{}).textContent||null, n:document.querySelectorAll("#pubPend .pendrow").length,
      open:!!document.querySelector("#pubPend:not([hidden])"), go:!(document.getElementById("pubGo")||{disabled:true}).disabled,
      bultosItem:[...document.querySelectorAll("#pubReady li")].some(li=>/bultos/i.test(li.textContent)),
      rows:[...document.querySelectorAll("#pubPend .pendrow")].map(el=>({id:(el.querySelector(".pendhead b")||{}).textContent, motivos:[...el.querySelectorAll("li")].map(li=>li.textContent.slice(0,60))}))})''')
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
            await pg.goto(f'http://127.0.0.1:{PORT}/'); await pg.evaluate('()=>localStorage.clear()'); await login(pg, 'admin@okdespacho.demo'); await builder(pg)
            await pg.fill('#ids', '72001 72002 72003 72004'); await pg.click('#btnSearch'); await pg.wait_for_timeout(2500)
            a0 = await pg.evaluate(ROW, '72001')
            res('SAL-01 saldo ausente detectado y bloqueante (pedido facturado después de exportar)', a0 and 'error:SALDO NO ENCONTRADO' in a0['codes'] and a0['blocked'] and a0['monto'] is None, a0)
            # (1) importe manual válido en la fila → saldo REVISADO automáticamente (sin otro botón)
            await type_amount(pg, '72001', '1500'); a1 = await pg.evaluate(ROW, '72001')
            res('SAL-02 importe manual válido → revisión de saldo automática; sin avisos de saldo ausente', a1['manual'] and a1['rev'] and a1['mm'] == 1500 and a1['monto'] is not None
                and not any(c.split(':', 1)[1] in ABSENT for c in a1['codes']) and 'info:SALDO REVISADO · IMPORTE MANUAL' in a1['codes'], a1)
            # (3) vacío o inválido → NO aprobado
            await type_amount(pg, '72002', ''); e1 = await pg.evaluate(ROW, '72002')
            await type_amount(pg, '72002', 'abc'); e2 = await pg.evaluate(ROW, '72002')
            res('SAL-03 importe vacío o inválido NO queda aprobado (sigue el aviso de saldo ausente y el bloqueo)', not e1['rev'] and not e2['rev'] and e2['blocked']
                and any(c.split(':', 1)[1] in ABSENT for c in e2['codes']), {'vacio': e1['codes'], 'invalido': e2['codes']})
            # (2) se conserva al recalcular, cambiar de hoja, guardar y recargar
            await pg.evaluate('async()=>{ CalculationEngine.computeAll(RouteStore.rows); await RouteStore.flush(); }'); sid = await pg.evaluate('()=>RouteStore.sheetId')
            await pg.evaluate('async()=>{ await SheetTabs.create(); }'); await pg.wait_for_timeout(800)
            await pg.evaluate(f'async()=>{{ await SheetTabs.switchTo("{sid}"); }}'); await pg.wait_for_timeout(1000)
            await pg.reload(); await pg.wait_for_timeout(2500); await builder(pg)
            if await pg.evaluate('()=>RouteStore.sheetId') != sid: await pg.evaluate(f'async()=>{{ await SheetTabs.switchTo("{sid}"); }}'); await pg.wait_for_timeout(1200)
            a2 = await pg.evaluate(ROW, '72001')
            res('SAL-04 importe manual y revisión se conservan al recalcular, cambiar de hoja y recargar', a2 and a2['manual'] and a2['rev'] and a2['mm'] == 1500
                and not any(c.split(':', 1)[1] in ABSENT for c in a2['codes']), a2)
            # (5) otros problemas reales siguen detectándose
            ind = 'warn:ENVÍO NO ENCONTRADO' in a2['codes'] and a2['blocked']
            await pg.evaluate('()=>{const r=RouteStore.rows.find(x=>String(x.mainOrder)==="72003"); r.compConflict="FAC [B] 0020-09999999"; }')
            cf = await pg.evaluate(ROW, '72003')
            await pg.evaluate('()=>{const r=RouteStore.rows.find(x=>String(x.mainOrder)==="72003"); delete r.compConflict; }')
            res('SAL-05 otros problemas reales siguen: envío no encontrado (independiente) y comprobante distinto (error)', ind and 'error:COMPROBANTE DIFERENTE AL VINCULADO' in cf['codes'] and cf['blocked'], {'72001': a2['codes'], '72003': cf['codes']})
            # ===== PUBLICAR → REVISAR → resolver → continuar =====
            await open_publish(pg); p0 = await pend(pg); p1 = p0
            # V4.14: el panel REVISAR se abre DESPLEGADO al intentar publicar (antes había que tocarlo)
            res('REV-01 REVISAR al publicar: el panel aparece desplegado con los pedidos pendientes y su motivo', p0['ready'] == 'REVISAR' and p0['open'] and p1['n'] == 4 and not p1['go']
                and all(r['motivos'] for r in p1['rows']), {'n': p1['n'], 'filas': p1['rows'][:2]})
            # NOC: se aplica sola una vez; la ya reflejada no
            noc_txt = await pg.evaluate('()=>[...document.querySelectorAll(".nocrow")].map(e=>e.innerText.replace(/\\s+/g," "))')
            n1 = (await pg.evaluate(ROW, '72003'))['noc']
            res('NOC-01 NOC no reflejada se aplica AUTOMÁTICAMENTE (sin seleccionarla); la ya contemplada en el saldo no', n1 == 300
                and any('APLICADA AUTOMÁTICAMENTE' in t and '0020-00000903' in t for t in noc_txt) and any('YA CONTEMPLADA EN EL SALDO' in t and '0020-00000904' in t for t in noc_txt), {'72003': n1, 'noc': noc_txt})
            # importe del 72002 desde el panel: inválido → error; válido → saldo revisado sin otra marca
            el = pg.locator('#pubPend .pendrow', has=pg.locator('.pendhead b', has_text='72002'))
            await el.locator('[data-pamt]').fill('xx'); await el.locator('[data-psave]').click(); await pg.wait_for_timeout(400)
            bad_msg = await el.locator('[data-perr]').inner_text()
            await el.locator('[data-pamt]').fill('2000'); await el.locator('[data-psave]').click(); await pg.wait_for_timeout(2500)
            b2 = await pg.evaluate(ROW, '72002'); p2 = await pend(pg)
            res('REV-02 importe desde el panel: inválido se rechaza; válido marca la revisión de saldo solo y actualiza el panel', 'válido' in bad_msg and b2['rev'] and b2['mm'] == 2000
                and not any(c.split(':', 1)[1] in ABSENT for c in b2['codes']) and p2['open'], {'msg': bad_msg, '72002': b2['codes']})
            # resolver el resto: tildar revisiones y completar forma de pago, hasta que no quede nada
            counts = [p2['n']]
            for _ in range(12):
                cur = await pend(pg)
                if cur['n'] == 0: break
                cb = pg.locator('#pubPend [data-pack]:not(:checked)').first
                if await cb.count(): await cb.click(); await pg.wait_for_timeout(2300); counts.append((await pend(pg))['n']); continue   # el panel se redibuja con el estado nuevo
                pay = pg.locator('#pubPend [data-ppay]').first
                if await pay.count():
                    row = pg.locator('#pubPend .pendrow', has=pg.locator('[data-ppay]')).first; await row.locator('[data-ppay]').fill('EFECTIVO')
                    if await row.locator('[data-ppayship]').count(): await row.locator('[data-ppayship]').fill('EFECTIVO')
                    await row.locator('[data-psavepay]').click(); await pg.wait_for_timeout(2300); counts.append((await pend(pg))['n']); continue
                break
            p3 = await pend(pg)
            res('REV-03 al resolver, el contador baja y se habilita continuar con la publicación', p3['n'] == 0 and p3['go'] and p3['ready'] != 'REVISAR' and counts[-1] == 0
                and all(counts[i] >= counts[i + 1] for i in range(len(counts) - 1)), {'contador': counts, 'estado': p3['ready']})
            res('BUL-01 bultos vacíos no son error ni revisión obligatoria (no figuran en REVISAR)', not p0['bultosItem'] and not p3['bultosItem'], {'antes': p0['bultosItem'], 'despues': p3['bultosItem']})
            # las decisiones se guardan: cerrar, recargar y volver a abrir
            await pg.evaluate('async()=>{ document.getElementById("publishModal").remove(); await RouteStore.flush(); }')
            await pg.reload(); await pg.wait_for_timeout(2500); await builder(pg)
            if await pg.evaluate('()=>RouteStore.sheetId') != sid: await pg.evaluate(f'async()=>{{ await SheetTabs.switchTo("{sid}"); }}'); await pg.wait_for_timeout(1200)
            await open_publish(pg); p4 = await pend(pg)
            n2 = (await pg.evaluate(ROW, '72003'))['noc']
            apps = await pg.evaluate('()=>{const d=JSON.parse(localStorage.getItem("okd_online_demo_v2")); return (d.nocApps||[]).filter(a=>a.comp && a.comp.includes("0020-00000903") || (a.op_id||"").includes("0020-00000903")).length}')
            res('REV-04 las decisiones se conservan al cerrar y reabrir: sin pendientes', p4['n'] == 0 and p4['go'], p4)
            res('NOC-02 la NOC se aplicó UNA sola vez (reabrir varias veces no la duplica)', n2 == 300 and apps == 1, {'nocApplied': n2, 'aplicaciones': apps})
            # publicar con bultos vacíos (y uno informado, que se conserva)
            await pg.locator('[data-bul]').nth(0).fill('3')
            for i in range(1, await pg.locator('[data-bul]').count()): await pg.locator('[data-bul]').nth(i).fill('')
            await pg.click('#pubGo'); await pg.wait_for_timeout(5000)
            pub = await pg.evaluate(f'''()=>{{const d=JSON.parse(localStorage.getItem("okd_online_demo_v2")); const r=(d.routes2||[]).find(x=>x.sheet_key==="{sid}");
              return r?{{n:r.stops.length, bultos:r.stops.map(s=>s.bultos==null?null:s.bultos), noc:r.stops.filter(s=>(s.order_numbers||[]).includes("72003")).map(s=>s.merchandise_amount)}}:null}}''')
            err = await pg.evaluate('()=>{const e=document.getElementById("pubErr"); return e&&!e.hidden?e.textContent:null}')
            res('BUL-02 se publica con bultos vacíos (sin completar 0 ficticio) y el informado se conserva', pub is not None and pub['n'] == 4 and pub['bultos'][0] == 3 and all(x is None for x in pub['bultos'][1:]), {'pub': pub, 'err': err})
            res('NOC-03 la hoja publicada descuenta la NOC una sola vez (1000 − 300 = 700)', pub is not None and pub['noc'] == [700], pub)
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
