"""E2E (modo demo, Chromium) · NOC automática con centavos, respuesta demorada, error de red con reintento y reapertura sin doble descuento.
Informes SINTÉTICOS: python3 tests/e2e/generate_synthetic_saldo_noc.py <carpeta> --decimales  (NOC $300,50 y $1.234,56, no reflejadas).
Se intercepta OKD_BRIDGE.noc.apply para registrar el importe ENVIADO y simular error de red y demora (sin tocar el servidor).
Código de salida: 0 todo PASS · 1 alguna FAIL · 2 error de preparación o casos faltantes."""
import asyncio, os, subprocess, sys, time, socket, traceback, json
from playwright.async_api import async_playwright
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
DIST = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'dist-demo'); PORT = 4370
FIX = os.environ.get('OKD_FIXTURES_DEC', '/tmp/okd_synth_dec')
FILES = ['informe_pedidos_qa.xlsx', 'saldo_comprobante_qa.xlsx', 'saldo_cuenta_corriente_qa.xlsx']
R = []; EXPECTED = 8
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:240])); print('..', ' | '.join(R[-1]), flush=True)
# interceptor: registra importes enviados; modo por comprobante: 'fail' (error de red), 'delay' (ms), 'ok'
HOOK = '''()=>{const b=window.OKD_BRIDGE.noc; if(!b.__orig) b.__orig=b.apply; window.__nocSent=window.__nocSent||[]; window.__nocMode=window.__nocMode||{};
  b.apply=async p=>{ window.__nocSent.push({comp:p.comp, amount:p.amount, op:p.op_id}); const k=Object.keys(window.__nocMode).find(c=>String(p.comp).includes(c)); const md=k?window.__nocMode[k]:'ok';
    if(md==='fail') throw new Error('Failed to fetch'); if(typeof md==='number') await new Promise(r=>setTimeout(r,md)); return b.__orig(p); }; }'''
STATE = '''()=>{const m=document.getElementById("publishModal"); if(!m) return null; const rows=[...m.querySelectorAll(".nocrow")].map(e=>({comp:e.dataset.comp, state:e.dataset.nocstate||null,
  txt:(e.querySelector("[data-nocres]")||e).innerText.replace(/\\s+/g," ").slice(0,90), retry:!!e.querySelector("[data-nocretry]"), okDisabled:(e.querySelector("[data-nocok]")||{disabled:null}).disabled,
  noDisabled:(e.querySelector("[data-nocno]")||{disabled:null}).disabled, field:(e.querySelector("[data-nocamt]")||{}).value||null}));
  return {go:!m.querySelector("#pubGo").disabled, wait:(m.querySelector("#pubNocWait")||{hidden:true}).hidden?null:m.querySelector("#pubNocWait").textContent, rows,
          title:(m.querySelector("#pubNoc b")||{}).textContent||"", err:(m.querySelector("#pubErr")||{hidden:true}).hidden?null:m.querySelector("#pubErr").textContent}}'''
NOCAPP = '(id)=>{const r=RouteStore.rows.find(x=>String(x.mainOrder)===id); return r?(r.nocApplied||0):null}'
def row(st, comp): return next((x for x in (st or {}).get('rows', []) if comp in (x['comp'] or '')), {})
async def login(pg, email):
    await pg.goto(f'http://127.0.0.1:{PORT}/'); await pg.wait_for_load_state('networkidle'); await pg.wait_for_timeout(500)
    for _ in range(4):
        await pg.fill('#loginEmail', email); await pg.fill('#loginPass', 'demo')
        if await pg.input_value('#loginEmail') == email: break
        await pg.wait_for_timeout(300)
    await pg.click('#loginBtn'); await pg.wait_for_timeout(2500)
    if await pg.locator('#pinA').count() and await pg.is_visible('#pinA'): await pg.fill('#pinA', '123456'); await pg.fill('#pinB', '123456'); await pg.click('#pinGo'); await pg.wait_for_timeout(900)
    await pg.wait_for_timeout(1500)
async def dismiss(pg):
    for _ in range(3):
        if await pg.locator('#pushLater').count() and await pg.is_visible('#pushLater'): await pg.click('#pushLater'); await pg.wait_for_timeout(300)
        else: break
async def open_publish(pg, wait=2500):
    await dismiss(pg)
    if await pg.locator('#publishModal').count(): await pg.evaluate('()=>document.getElementById("publishModal").remove()')
    await pg.evaluate('()=>{ Publisher.open(); }'); await pg.wait_for_selector('#publishModal', timeout=15000); await pg.wait_for_timeout(wait)
async def main():
    if not os.path.isfile(os.path.join(DIST, 'index.html')): raise RuntimeError('falta el build demo en ' + DIST)
    if not all(os.path.isfile(os.path.join(FIX, f)) for f in FILES): raise RuntimeError('faltan los informes: python3 tests/e2e/generate_synthetic_saldo_noc.py ' + FIX + ' --decimales')
    srv = subprocess.Popen([sys.executable, '-m', 'http.server', str(PORT), '--bind', '127.0.0.1'], cwd=DIST, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(60):
            try: socket.create_connection(('127.0.0.1', PORT), 1).close(); break
            except OSError: time.sleep(0.2)
        async with async_playwright() as p:
          b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
          try:
            pg = await (await b.new_context(viewport={'width': 1366, 'height': 900})).new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
            await pg.goto(f'http://127.0.0.1:{PORT}/'); await pg.evaluate('()=>localStorage.clear()'); await login(pg, 'admin@okdespacho.demo'); await dismiss(pg)
            await pg.evaluate('()=>{location.hash="#/despacho"}'); await pg.wait_for_timeout(1800)
            await pg.set_input_files('.file[data-kind="pedidos"] input', [os.path.join(FIX, f) for f in FILES])
            for _ in range(150):
                await pg.wait_for_timeout(300)
                if await pg.evaluate('()=>typeof OrderIndex!=="undefined" && OrderIndex.size()>0 && !!(RouteStore.data.sc && RouteStore.data.cc)'): break
            await pg.wait_for_timeout(1500)
            await pg.fill('#ids', '72003 72005'); await pg.click('#btnSearch'); await pg.wait_for_timeout(2500)
            # preparación: revisiones independientes marcadas (no es lo que se prueba acá) para que solo las NOC decidan si se puede publicar
            await pg.evaluate('''async()=>{ RouteStore.rows.forEach(r=>{ r.acks=r.acks||{}; baseStatus(r).issues.filter(canAck).forEach(i=>{ r.acks[ackKey(i)]=new Date().toISOString(); });
              if(r.payMain==="REVISAR"){ r.payMain="EFECTIVO"; r.payMainManual=true; } }); CalculationEngine.computeAll(RouteStore.rows); await RouteStore.flush(); }''')
            sid = await pg.evaluate('()=>RouteStore.sheetId')
            await pg.evaluate(HOOK)
            # (1) error de red en las dos NOC
            await pg.evaluate('()=>{ window.__nocMode={"0020-00000903":"fail","0020-00000905":"fail"}; }')
            await open_publish(pg); s1 = await pg.evaluate(STATE); sent1 = await pg.evaluate('()=>window.__nocSent.map(x=>x.amount)')
            r3, r5 = row(s1, '0020-00000903'), row(s1, '0020-00000905')
            res('DEC-01 error de red: las dos NOC quedan PENDIENTES con REINTENTAR, controles habilitados y PUBLICAR bloqueado; importe enviado exacto (300,50 / 1.234,56)',
                r3.get('state') == 'failed' and r5.get('state') == 'failed' and r3.get('retry') and r5.get('retry') and r3.get('okDisabled') is False and r3.get('noDisabled') is False
                and not s1['go'] and s1['wait'] and sorted(sent1) == [300.5, 1234.56] and r3.get('field') == '300,50' and r5.get('field') == '1.234,56', {'s': s1, 'enviado': sent1})
            # (2) REINTENTAR con respuesta DEMORADA e intento de publicar mientras tanto
            await pg.evaluate('()=>{ window.__nocMode={"0020-00000903":2500,"0020-00000905":"fail"}; }')
            await pg.locator('.nocrow[data-comp*="0020-00000903"] [data-nocretry]').click(); await pg.wait_for_timeout(300)
            s2a = await pg.evaluate(STATE)
            await pg.evaluate('()=>{ const g=document.getElementById("pubGo"); window.__pubTry = g.onclick({target:g}); }')   # intento de publicar en plena demora
            await pg.wait_for_timeout(900)
            mid = await pg.evaluate(f'()=>{{const d=JSON.parse(localStorage.getItem("okd_online_demo_v2")); return !!(d.routes2||[]).find(x=>x.sheet_key==="{sid}")}}')
            await pg.wait_for_timeout(3200); s2b = await pg.evaluate(STATE)
            after = await pg.evaluate(f'()=>{{const d=JSON.parse(localStorage.getItem("okd_online_demo_v2")); return !!(d.routes2||[]).find(x=>x.sheet_key==="{sid}")}}')
            res('DEC-02 respuesta demorada: PUBLICAR bloqueado mientras se aplica; el intento de publicar espera y NO publica con otra NOC sin resolver', row(s2a, '0020-00000903').get('state') == 'pending'
                and not s2a['go'] and not mid and not after and s2b['err'] and 'pendientes' in s2b['err'], {'durante': row(s2a, '0020-00000903'), 'publicada_durante': mid, 'publicada_despues': after, 'err': s2b['err']})
            n3 = await pg.evaluate(NOCAPP, '72003')
            res('DEC-03 reintento exitoso: NOC $300,50 aplicada automáticamente con el importe exacto (no 3005)', row(s2b, '0020-00000903').get('state') == 'applied' and n3 == 300.5
                and 'APLICADA AUTOMÁTICAMENTE' in row(s2b, '0020-00000903').get('txt', ''), {'nocApplied': n3, 'fila': row(s2b, '0020-00000903')})
            # (3) entrada MANUAL con formato argentino
            await pg.evaluate('()=>{ window.__nocMode={}; }')
            await pg.locator('.nocrow[data-comp*="0020-00000905"] [data-nocamt]').fill('1.234,56')
            await pg.locator('.nocrow[data-comp*="0020-00000905"] [data-nocok]').click(); await pg.wait_for_timeout(1500)
            s3 = await pg.evaluate(STATE); n5 = await pg.evaluate(NOCAPP, '72005'); last = await pg.evaluate('()=>window.__nocSent[window.__nocSent.length-1].amount')
            res('DEC-04 importe escrito a mano en formato argentino "1.234,56" se envía como 1234.56 y se aplica', last == 1234.56 and n5 == 1234.56 and row(s3, '0020-00000905').get('state') == 'applied', {'enviado': last, 'nocApplied': n5})
            res('DEC-05 con todas las NOC resueltas se habilita PUBLICAR', s3['go'] and not s3['wait'], s3)
            # (4) reabrir: sin doble descuento
            await pg.evaluate('async()=>{ document.getElementById("publishModal").remove(); await RouteStore.flush(); }')
            await open_publish(pg); s4 = await pg.evaluate(STATE)
            apps = await pg.evaluate('()=>{const d=JSON.parse(localStorage.getItem("okd_online_demo_v2")); const A=d.nocApps||[]; return {n903:A.filter(a=>(a.op_id||"").includes("0020-00000903")).length, n905:A.filter(a=>(a.op_id||"").includes("0020-00000905")).length}}')
            n3b, n5b = await pg.evaluate(NOCAPP, '72003'), await pg.evaluate(NOCAPP, '72005')
            res('DEC-06 reabrir no vuelve a descontar: una aplicación por NOC y mismos importes', n3b == 300.5 and n5b == 1234.56 and apps == {'n903': 1, 'n905': 1} and s4['go'], {'nocApplied': [n3b, n5b], 'apps': apps})
            res('DEC-07 los textos ya no dicen "solo si las aceptás" (indican aplicación automática)', 'solo si las acept' not in (s4['title'] + s1['title']) and 'automáticamente' in s4['title'], s4['title'])
            # (5) publicar: importe final con el descuento exacto, una sola vez
            await pg.click('#pubGo'); await pg.wait_for_timeout(5000)
            pub = await pg.evaluate(f'''()=>{{const d=JSON.parse(localStorage.getItem("okd_online_demo_v2")); const r=(d.routes2||[]).find(x=>x.sheet_key==="{sid}");
              return r?r.stops.map(s=>[(s.order_numbers||[])[0], s.merchandise_amount]):null}}''')
            sent = await pg.evaluate('()=>window.__nocSent.map(x=>x.amount)')
            res('DEC-08 hoja publicada: 1000 − 300,50 = 699,50 y 2000 − 1.234,56 = 765,44; nunca se envió 3005 ni 123456', pub is not None and sorted(pub) == [['72003', 699.5], ['72005', 765.44]]
                and not any(a in (3005, 123456) for a in sent), {'publicada': pub, 'enviados': sent})
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
