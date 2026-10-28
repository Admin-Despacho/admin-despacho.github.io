"""E2E (modo demo, Chromium) · REENVÍOS con CONTROLES REALES del constructor: importar informes ficticios (selector de archivos) →
agregar pedidos (#ids + BUSCAR) → PUBLICAR HOJA (#btnPublish) → resolver REVISAR (casillas, importes, forma de pago) → PUBLICAR (#pubGo);
luego + NUEVA HOJA → volver a cargar el pedido NO ENTREGADO → publicar → el informe de Cristian no lo duplica. El pendiente y el
entregado siguen bloqueados. Informes SINTÉTICOS (generate_synthetic_saldo_noc.py). Exit 0 PASS · 1 FAIL · 2 error."""
import asyncio, os, sys, re, traceback
sys.path.insert(0, os.path.dirname(__file__))
import run_cambiar_rol as cr
from playwright.async_api import async_playwright
cr.PORT = 4387; K = cr.K; R = []; EXPECTED = 7
FIX = os.environ.get('OKD_FIXTURES_SALDO', '/tmp/okd_synth_saldo'); FILES = ['informe_pedidos_qa.xlsx', 'saldo_comprobante_qa.xlsx', 'saldo_cuenta_corriente_qa.xlsx']
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:260])); print('..', ' | '.join(R[-1]), flush=True)
def num(t): return int(re.sub(r'[^0-9]', '', t) or 0)
async def builder(pg):
    await pg.evaluate('()=>{location.hash="#/despacho"}'); await pg.wait_for_timeout(1800); await cr.dismiss(pg)
    if not await pg.evaluate('()=>typeof OrderIndex!=="undefined" && OrderIndex.size()>0 && !!(RouteStore.data.sc && RouteStore.data.cc)'):
        await pg.set_input_files('.file[data-kind="pedidos"] input', [os.path.join(FIX, f) for f in FILES])   # selector de archivos real
        for _ in range(150):
            await pg.wait_for_timeout(300)
            if await pg.evaluate('()=>typeof OrderIndex!=="undefined" && OrderIndex.size()>0 && !!(RouteStore.data.sc && RouteStore.data.cc)'): break
        await pg.wait_for_timeout(1500)
async def add(pg, oid):
    await pg.fill('#ids', oid); await pg.click('#btnSearch'); await pg.wait_for_timeout(2500)
async def rows(pg): return await pg.evaluate('()=>RouteStore.rows.map(r=>String(r.mainOrder))')
async def publish(pg):
    """PUBLICAR HOJA (botón real) → resolver REVISAR con sus controles → PUBLICAR (#pubGo). Devuelve el número publicado o None."""
    await cr.dismiss(pg); await pg.locator('#btnPublish').click(); await pg.wait_for_selector('#publishModal', timeout=15000); await pg.wait_for_timeout(2500)
    for _ in range(20):
        if await pg.evaluate('()=>document.querySelectorAll("#pubPend .pendrow").length') == 0: break
        arow = pg.locator('#pubPend .pendrow', has=pg.locator('[data-pamt]')).first   # filtro RELATIVO a la fila
        if await arow.count() and not (await arow.locator('[data-pamt]').input_value()).strip():
            await arow.locator('[data-pamt]').fill('1000'); await arow.locator('[data-psave]').click(); await pg.wait_for_timeout(2300); continue
        cb = pg.locator('#pubPend [data-pack]:not(:checked)').first
        if await cb.count(): await cb.click(); await pg.wait_for_timeout(2300); continue
        pay = pg.locator('#pubPend [data-ppay]').first
        if await pay.count():
            row = pg.locator('#pubPend .pendrow', has=pg.locator('[data-ppay]')).first; await row.locator('[data-ppay]').fill('EFECTIVO')
            if await row.locator('[data-ppayship]').count(): await row.locator('[data-ppayship]').fill('EFECTIVO')
            await row.locator('[data-psavepay]').click(); await pg.wait_for_timeout(2300); continue
        break
    for i in range(await pg.locator('[data-bul]').count()): await pg.locator('[data-bul]').nth(i).fill('')
    if await pg.evaluate('()=>(document.getElementById("pubGo")||{disabled:true}).disabled'): return None
    await pg.click('#pubGo'); await pg.wait_for_timeout(5000)
    sid = await pg.evaluate('()=>RouteStore.sheetId')
    return await pg.evaluate(f'()=>{{const r=(JSON.parse(localStorage.getItem("{K}")).routes2||[]).find(x=>x.sheet_key==="{sid}"); return r?{{id:r.id, number:r.number}}:null}}')
async def informe(pg):
    await pg.evaluate('()=>{location.hash="#/"}'); await pg.wait_for_timeout(600); await pg.evaluate('()=>{location.hash="#/informes"}'); await pg.wait_for_timeout(2500); await cr.dismiss(pg)
    t = await pg.locator('#rpTotal').inner_text(); retr = await pg.locator('#rpRetries').inner_text() if await pg.locator('#rpRetries').count() else ''
    return num(re.search(r'([\d.]+)\s*envíos', t).group(1)), num(re.findall(r'\$\s*[\d.]+', t)[0]), retr
async def main():
    if not all(os.path.isfile(os.path.join(FIX, f)) for f in FILES): raise RuntimeError('faltan los informes sintéticos: python3 tests/e2e/generate_synthetic_saldo_noc.py ' + FIX)
    srv = cr.serve()
    try:
        async with async_playwright() as p:
          b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
          try:
            pg = await (await b.new_context(viewport={'width': 1366, 'height': 900})).new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
            await pg.goto(f'http://127.0.0.1:{cr.PORT}/'); await pg.evaluate('()=>localStorage.clear()')
            await pg.evaluate('()=>new Promise(r=>{const q=indexedDB.deleteDatabase("ok_despacho"); q.onsuccess=q.onerror=q.onblocked=()=>r()})')
            await cr.login(pg, 'admin@okdespacho.demo'); n0, m0, _ = await informe(pg)
            # ===== 1.ª hoja: importar informes y agregar 72002, 72003 y 72004 con los controles reales; publicar =====
            await builder(pg)
            for o in ('72002', '72003', '72004'): await add(pg, o)
            r_first = await rows(pg); h1 = await publish(pg)
            res('RC-01 controles reales: informes importados, pedidos agregados y PRIMERA hoja publicada', sorted(r_first) == ['72002', '72003', '72004'] and h1 is not None, {'filas': r_first, 'hoja': h1})
            if not h1: return R
            # resultados del primer intento (los registra Cristian; acá se fijan como dato de prueba): 72003 no entregado, 72004 entregado, 72002 pendiente
            await pg.evaluate(f'''()=>{{ const d=JSON.parse(localStorage.getItem("{K}")); const r=d.routes2.find(x=>x.id==="{h1['id']}"); r.operational_status='EN_CURSO';
              r.stops.forEach(s=>{{ if (s.order_numbers.map(String).includes('72003')) s.outcome='NO_ENTREGADO'; if (s.order_numbers.map(String).includes('72004')) s.outcome='ENTREGADO'; }}); localStorage.setItem("{K}", JSON.stringify(d)); }}''')
            n1, m1, _ = await informe(pg)
            # ===== + NUEVA HOJA: volver a cargar el NO ENTREGADO; el pendiente y el entregado siguen bloqueados =====
            await builder(pg); await cr.dismiss(pg); await pg.locator('#tabNew').click(); await pg.wait_for_timeout(1500)
            await add(pg, '72003'); after3 = await rows(pg)
            res('RC-02 + NUEVA HOJA → el pedido NO ENTREGADO (72003) se vuelve a cargar con #ids + BUSCAR', after3 == ['72003'], after3)
            msgs = {}
            for o in ('72002', '72004'):
                await add(pg, o); msgs[o] = await pg.evaluate('()=>[...document.querySelectorAll("#log .msg, .msg.warn, .msg.err")].map(e=>e.textContent).filter(t=>/PEDIDO|otra hoja|No se duplica/i.test(t)).slice(-1)[0]||""')
            after_bad = await rows(pg)
            res('RC-03 el PENDIENTE (72002) y el ENTREGADO (72004) NO se agregan: el constructor muestra el bloqueo', after_bad == ['72003']
                and all(h1['number'] in msgs[o] and 'No se duplica' in msgs[o] for o in msgs), {'filas': after_bad, 'avisos': msgs})
            h2 = await publish(pg)
            old = await pg.evaluate(f'()=>JSON.parse(localStorage.getItem("{K}")).routes2.find(r=>r.id==="{h1["id"]}").stops.map(s=>[String(s.order_numbers[0]), s.outcome])')
            res('RC-04 se publica la hoja del reintento con PUBLICAR HOJA; la hoja anterior conserva sus resultados', h2 is not None and h2['number'] != h1['number']
                and sorted(old) == [['72002', 'PENDIENTE'], ['72003', 'NO_ENTREGADO'], ['72004', 'ENTREGADO']], {'reintento': h2, 'anterior': old})
            await pg.evaluate(f'''()=>{{ const d=JSON.parse(localStorage.getItem("{K}")); const r=d.routes2.find(x=>x.id==="{(h2 or {}).get('id')}"); if(r){{ r.operational_status='COMPLETADA'; r.stops[0].outcome='ENTREGADO'; }} localStorage.setItem("{K}", JSON.stringify(d)); }}''')
            n2, m2, retr = await informe(pg)
            res('RC-05 la primera hoja sumó sus 3 envíos', n1 - n0 == 3, {'antes': [n0, m0], 'despues': [n1, m1]})
            res('RC-06 informe de Cristian: el reintento NO suma otro envío ni otro importe', (n2, m2) == (n1, m1), {'antes': [n1, m1], 'despues': [n2, m2]})
            res('RC-07 el informe muestra el reenvío del 72003 con sus dos hojas', '72003' in retr and h1['number'] in retr and (h2 or {}).get('number', '?') in retr, retr[:220])
          finally: await b.close()
    finally:
        if srv.poll() is None: srv.terminate(); srv.wait(5)
    print('TOTAL', sum(1 for r in R if r[1] == 'PASS'), 'PASS /', sum(1 for r in R if r[1] == 'FAIL'), 'FAIL · esperados', EXPECTED)
    return R
if __name__ == '__main__':
    if len(sys.argv) > 1: cr.DIST = sys.argv[1]
    try: rr = asyncio.run(main())
    except Exception as e: traceback.print_exc(); print('ERROR:', repr(e)); sys.exit(2)
    if len(rr) != EXPECTED: print('ERROR: se ejecutaron %d de %d' % (len(rr), EXPECTED)); sys.exit(2)
    sys.exit(1 if any(r[1] != 'PASS' for r in rr) else 0)
