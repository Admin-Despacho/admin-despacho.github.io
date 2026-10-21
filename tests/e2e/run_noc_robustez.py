"""E2E (modo demo, Chromium) · robustez de la NOC automática: solicitudes en curso, rechazo definitivo (ok:false) y error transitorio.
Informes SINTÉTICOS: python3 tests/e2e/generate_synthetic_saldo_noc.py <carpeta> --decimales  (NOC $300,50 y $1.234,56, no reflejadas).
Se intercepta OKD_BRIDGE.noc.apply para registrar el importe ENVIADO y simular error de red y demora (sin tocar el servidor).
Código de salida: 0 todo PASS · 1 alguna FAIL · 2 error de preparación o casos faltantes."""
import asyncio, os, subprocess, sys, time, socket, traceback, json
from playwright.async_api import async_playwright
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
DIST = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'dist-demo'); PORT = 4372
FIX = os.environ.get('OKD_FIXTURES_DEC', '/tmp/okd_synth_dec')
FILES = ['informe_pedidos_qa.xlsx', 'saldo_comprobante_qa.xlsx', 'saldo_cuenta_corriente_qa.xlsx']
R = []; EXPECTED = 8
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:240])); print('..', ' | '.join(R[-1]), flush=True)
# interceptor: registra importes enviados; modo por comprobante: 'fail' (error de red), 'delay' (ms), 'ok'
HOOK = '''()=>{const b=window.OKD_BRIDGE.noc; if(!b.__orig) b.__orig=b.apply; window.__nocSent=window.__nocSent||[]; window.__nocMode=window.__nocMode||{};
  b.apply=async p=>{ window.__nocSent.push({comp:p.comp, amount:p.amount, op:p.op_id}); const k=Object.keys(window.__nocMode).find(c=>String(p.comp).includes(c)); const md=k?window.__nocMode[k]:'ok';
    if(md==='fail') throw new Error('Failed to fetch'); if(typeof md==='number') await new Promise(r=>setTimeout(r,md));
    if(md==='reject') return {ok:false, code:'NOC_CONSUMED', message:'La NOC ya fue utilizada en otra hoja', consumed:p.amount};
    return b.__orig(p); }; }'''
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
            await pg.evaluate('''async()=>{ RouteStore.rows.forEach(r=>{ r.acks=r.acks||{}; baseStatus(r).issues.filter(canAck).forEach(i=>{ r.acks[ackKey(i)]=new Date().toISOString(); });
              if(r.payMain==="REVISAR"){ r.payMain="EFECTIVO"; r.payMainManual=true; } }); CalculationEngine.computeAll(RouteStore.rows); await RouteStore.flush(); }''')
            sid = await pg.evaluate('()=>RouteStore.sheetId'); await pg.evaluate(HOOK)
            PUBLISHED = f'()=>{{const d=JSON.parse(localStorage.getItem("okd_online_demo_v2")); return !!(d.routes2||[]).find(x=>x.sheet_key==="{sid}")}}'
            # (1) error TRANSITORIO en las dos
            await pg.evaluate('()=>{ window.__nocMode={"0020-00000903":"fail","0020-00000905":"fail"}; }')
            await open_publish(pg); s1 = await pg.evaluate(STATE); r3, r5 = row(s1, '0020-00000903'), row(s1, '0020-00000905')
            res('ROB-01 error transitorio: PENDIENTE con REINTENTAR, importe CONSERVADO (300,50 / 1.234,56) y PUBLICAR bloqueado', r3.get('state') == 'failed' and r5.get('state') == 'failed'
                and r3.get('retry') and r5.get('retry') and r3.get('field') == '300,50' and r5.get('field') == '1.234,56' and not s1['go'], {'903': r3, '905': r5})
            # (2) reintento DEMORADO + intento de NO APLICAR + intento de cambiar el estado visual + intento de publicar
            await pg.evaluate('()=>{ window.__nocMode={"0020-00000903":2500,"0020-00000905":"reject"}; }')
            await pg.locator('.nocrow[data-comp*="0020-00000903"] [data-nocretry]').click(); await pg.wait_for_timeout(300)
            during = await pg.evaluate('''()=>{const e=document.querySelector('.nocrow[data-comp*="0020-00000903"]');
              const q=s=>{const x=e.querySelector(s); return x?x.disabled:null};
              const before={no:q("[data-nocno]"), ok:q("[data-nocok]"), amt:q("[data-nocamt]"), retry:!!e.querySelector("[data-nocretry]"), busy:!!e.dataset.nocbusy};
              e.querySelector("[data-nocno]").onclick();                                   // intento de NO APLICAR (llamada directa, aunque esté deshabilitado)
              e.dataset.nocstate="applied"; Publisher.nocGate(document.getElementById("publishModal"));   // cambio del estado VISUAL
              const g=document.getElementById("pubGo"); const goAfterVisual=!g.disabled; window.__pubTry=g.onclick({target:g});      // intento de publicar
              return {before, resText:e.querySelector("[data-nocres]").textContent, goAfterVisual}}''')
            await pg.wait_for_timeout(900); mid = await pg.evaluate(PUBLISHED)
            await pg.wait_for_timeout(3500); s2 = await pg.evaluate(STATE); after = await pg.evaluate(PUBLISHED)
            n3 = await pg.evaluate(NOCAPP, '72003')
            res('ROB-02 con la solicitud en curso: NO APLICAR, APLICAR e importe deshabilitados y sin REINTENTAR; el intento de NO APLICAR no tiene efecto',
                during['before'] == {'no': True, 'ok': True, 'amt': True, 'retry': False, 'busy': True} and 'NO SE APLICA' not in during['resText'] and n3 == 300.5, {'durante': during, 'nocApplied': n3})
            res('ROB-03 no se puede publicar con una solicitud en curso aunque cambie el estado visual; el intento espera y no publica', not during['goAfterVisual'] and not mid and not after, {'durante': mid, 'despues': after, 'goTrasCambioVisual': during['goAfterVisual']})
            res('ROB-04 reintento exitoso tras error transitorio: $300,50 exactos', row(s2, '0020-00000903').get('state') == 'applied' and n3 == 300.5, row(s2, '0020-00000903'))
            # (3) rechazo DEFINITIVO ok:false en la 905 (por la aplicación automática al reabrir)
            await pg.evaluate('async()=>{ document.getElementById("publishModal").remove(); await RouteStore.flush(); }')
            await open_publish(pg, 3000); s3 = await pg.evaluate(STATE); r5b = row(s3, '0020-00000905')
            n5 = await pg.evaluate(NOCAPP, '72005')
            amt5 = await pg.evaluate('()=>{const e=document.querySelector(\'.nocrow[data-comp*="0020-00000905"] [data-nocamt]\'); return e?{v:e.value, dis:e.disabled}:null}')
            res('ROB-05 rechazo ok:false: causa visible, sin REINTENTAR imposible, importe no borrado; no se aplica y no bloquea la publicación', r5b.get('state') == 'rejected' and not r5b.get('retry')
                and 'NO SE APLICA EN ESTA HOJA' in r5b.get('txt', '') and 'otra hoja' in r5b.get('txt', '') and amt5 and amt5['v'] == '1.234,56' and amt5['dis'] and n5 == 0 and s3['go'], {'905': r5b, 'campo': amt5, 'nocApplied': n5})
            apps = await pg.evaluate('()=>{const d=JSON.parse(localStorage.getItem("okd_online_demo_v2")); const A=d.nocApps||[]; return {n903:A.filter(a=>(a.op_id||"").includes("0020-00000903")).length, n905:A.filter(a=>(a.op_id||"").includes("0020-00000905")).length}}')
            n3b = await pg.evaluate(NOCAPP, '72003')
            res('ROB-06 reabrir: sin doble aplicación (una por NOC aplicada; la rechazada ninguna)', n3b == 300.5 and apps == {'n903': 1, 'n905': 0} and 'APLICADA' in row(s3, '0020-00000903').get('txt', ''), {'nocApplied': n3b, 'apps': apps})
            # (4) publicar con importes exactos
            await pg.click('#pubGo'); await pg.wait_for_timeout(5000)
            pub = await pg.evaluate(f'''()=>{{const d=JSON.parse(localStorage.getItem("okd_online_demo_v2")); const r=(d.routes2||[]).find(x=>x.sheet_key==="{sid}");
              return r?r.stops.map(s=>[(s.order_numbers||[])[0], s.merchandise_amount]):null}}''')
            sent = await pg.evaluate('()=>window.__nocSent.map(x=>x.amount)')
            res('ROB-07 hoja publicada: 1000 − 300,50 = 699,50 y la NOC rechazada no descuenta (2000)', pub is not None and sorted(pub) == [['72003', 699.5], ['72005', 2000]], pub)
            res('ROB-08 importes enviados siempre exactos en centavos (nunca 3005 ni 123456)', sent and all(a in (300.5, 1234.56) for a in sent), sent)
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
