"""E2E BLOQUEANTE (demo, Chromium) · AUTORIZACIONES COMERCIALES · integración con las cargas DIARIAS de Depósito en el Constructor REAL:
el Operario carga como siempre → las hojas se preparan igual → el historial Comercial se actualiza SOLO (sin pasos extra) → la misma
carga otra vez NO duplica comprobantes. Informes SINTÉTICOS (tests/e2e/generate_synthetic_saldo_noc.py)."""
import asyncio, os, sys, subprocess, traceback
sys.path.insert(0, os.path.dirname(__file__))
import run_driver_perfiles as dp
from playwright.async_api import async_playwright
dp.PORT = 4511; R = []; EXPECTED = 3
if len(sys.argv) > 1: dp.DIST = sys.argv[1]
K = 'okd_online_demo_v2'; FIX = os.environ.get('OKD_FIXTURES_SALDO', '/tmp/okd_synth_saldo'); HERE = os.path.dirname(os.path.abspath(__file__))
FILES = ['informe_pedidos_qa.xlsx', 'saldo_comprobante_qa.xlsx', 'saldo_cuenta_corriente_qa.xlsx']
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:420])); print('..', ' | '.join(R[-1]), flush=True)
COM = '()=>{const c=(JSON.parse(localStorage.getItem("%s"))||{}).com||{}; const g=(c.ingests||[]).filter(i=>/_qa\\.xlsx$/.test(i.file_name||"")); return {ingestas:g.map(i=>i.kind+":"+i.status+":"+i.file_name), docs:Object.values(c.docs||{}).filter(d=>(c.ingests||[]).some(i=>i.id===d.first&&/_qa\\.xlsx$/.test(i.file_name||""))).length, vistos:Object.values(c.docs||{}).reduce((t,d)=>t+(d.seen||0),0), cc:(c.cc||[]).length}}' % K
PEND = 'async()=>new Promise(ok=>{const r=indexedDB.open("okd-com-ingest",1); r.onupgradeneeded=()=>r.result.createObjectStore("jobs",{keyPath:"hash"}); r.onsuccess=()=>{const t=r.result.transaction("jobs","readonly").objectStore("jobs").count(); t.onsuccess=()=>ok(t.result)}; r.onerror=()=>ok(-1)})'
async def load(pg):
    await pg.evaluate('()=>{location.hash="#/despacho"}'); await pg.wait_for_timeout(2000)
    await pg.set_input_files('.file[data-kind="pedidos"] input', [os.path.join(FIX, f) for f in FILES])
    for _ in range(150):
        await pg.wait_for_timeout(300)
        if await pg.evaluate('()=>typeof OrderIndex!=="undefined" && OrderIndex.size()>0 && !!(RouteStore.data.sc && RouteStore.data.cc)'): break
    await pg.wait_for_timeout(4000)
def cuit_valido(base10):
    w = [5, 4, 3, 2, 7, 6, 5, 4, 3, 2]; v = 11 - sum(int(c) * w[i] for i, c in enumerate(base10)) % 11
    return None if v == 10 else base10 + str(0 if v == 11 else v)
def preparar():   # copia de los informes sintéticos con los MISMOS datos, cambiando solo los CUIT por otros VÁLIDOS (verificables)
    global FIX
    if not all(os.path.isfile(os.path.join(FIX, f)) for f in FILES): subprocess.run(['python3', os.path.join(HERE, 'generate_synthetic_saldo_noc.py'), FIX], check=True)
    import openpyxl, shutil
    dst = FIX + '_cuit_valido'; os.makedirs(dst, exist_ok=True); mapa = {}
    for f in FILES:
        wb = openpyxl.load_workbook(os.path.join(FIX, f))
        for ws in wb.worksheets:
            for row in ws.iter_rows():
                for c in row:
                    v = str(c.value or '').strip()
                    if v.startswith('2099007') and len(v) == 11 and v.isdigit():
                        if v not in mapa: mapa[v] = next(x for x in (cuit_valido('3071' + v[4:10][:2] + '%04d' % i) for i in range(1, 9999)) if x and x not in mapa.values())
                        c.value = mapa[v]
        wb.save(os.path.join(dst, f))
    FIX = dst; return mapa
async def main():
    mapa = preparar(); print('CUIT sintéticos → válidos:', mapa)
    srv = dp.serve()
    try:
        async with async_playwright() as p:
            b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
            try:
                pg = await (await b.new_context(viewport={'width': 1366, 'height': 860})).new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
                await pg.goto(f'http://127.0.0.1:{dp.PORT}/'); await pg.evaluate('()=>localStorage.clear()'); await dp.login(pg, 'operario@okdespacho.demo')
                await pg.evaluate('async()=>{await window.OKD_ONLINE.api.comConfig()}')   # la demo crea su base Comercial (en línea: ya existe en el servidor)
                await load(pg)
                hojas = await pg.evaluate('()=>({pedidos:OrderIndex.size(), sc:(RouteStore.data.sc||{}).meta&&RouteStore.data.sc.meta.count, cc:(RouteStore.data.cc||{}).meta&&RouteStore.data.cc.meta.count})')
                c1 = await pg.evaluate(COM); p1 = await pg.evaluate(PEND)
                res('IC-01 el Operario carga «Saldo comprobante» y «Saldo cuenta corriente» en el Constructor COMO SIEMPRE: la preparación de hojas funciona igual (pedidos, saldos y cuenta corriente indexados)',
                    hojas['pedidos'] > 0 and (hojas['sc'] or 0) > 0 and (hojas['cc'] or 0) > 0, hojas)
                res('IC-02 SIN PASOS EXTRA: el historial Comercial recibió las DOS cargas (OK) automáticamente, con sus comprobantes y la foto de cuenta corriente; nada quedó pendiente',
                    any(x.startswith('SC:OK:saldo_comprobante_qa.xlsx') for x in c1['ingestas']) and any(x.startswith('CC:OK:saldo_cuenta_corriente_qa.xlsx') for x in c1['ingestas']) and c1['docs'] > 0 and c1['cc'] > 0 and p1 == 0, {**c1, 'pendientes': p1})
                await pg.evaluate('()=>{location.hash="#/dashboard"}'); await pg.wait_for_timeout(800); await load(pg)
                c2 = await pg.evaluate(COM)
                res('IC-03 la MISMA carga otra vez (como al día siguiente con los mismos comprobantes): NO se duplica ningún comprobante; cada nueva carga conserva su fecha',
                    c2['docs'] == c1['docs'] and len(c2['ingestas']) == 2 * len(c1['ingestas']), {'antes': c1['docs'], 'despues': c2['docs'], 'ingestas': [len(c1['ingestas']), len(c2['ingestas'])]})
            finally: await b.close()
    finally: srv.terminate()
    print('TOTAL', sum(1 for r in R if r[1] == 'PASS'), 'PASS /', sum(1 for r in R if r[1] == 'FAIL'), 'FAIL · esperados', EXPECTED)
    return R
if __name__ == '__main__':
    try: rr = asyncio.run(main())
    except Exception as e: traceback.print_exc(); print('ERROR:', repr(e)); sys.exit(2)
    if len(rr) != EXPECTED: print('ERROR: se ejecutaron %d de %d' % (len(rr), EXPECTED)); sys.exit(2)
    sys.exit(1 if any(r[1] != 'PASS' for r in rr) else 0)
