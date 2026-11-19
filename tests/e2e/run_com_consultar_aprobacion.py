"""E2E BLOQUEANTE (demo + Constructor REAL) · AUTORIZACIONES COMERCIALES y PUBLICACIÓN DE HOJAS tras el HOTFIX 9c3240c (publicado):
el Comercial crea solicitudes para pedidos de una hoja (una PENDIENTE y una DEVUELTA); al publicar, la ventana NO muestra ni consulta autorizaciones
comerciales, no bloquea ni cambia importes; el estado se consulta en «Seguimiento» (DEVUELTA nunca como aprobada) y, sin conexión, el aviso de
conexión no se confunde con «sin solicitudes»; un usuario sin permisos del módulo no obtiene nada. Informes SINTÉTICOS (generate_synthetic_saldo_noc.py)."""
import asyncio, os, sys, subprocess, traceback
sys.path.insert(0, os.path.dirname(__file__))
import run_saldo_revisar_noc as base
import run_driver_perfiles as dp
from playwright.async_api import async_playwright
R = []; EXPECTED = 6
DIST = sys.argv[1] if len(sys.argv) > 1 else os.path.join(base.ROOT, 'dist-demo'); dp.DIST = DIST; dp.PORT = base.PORT = 4381
OUT = sys.argv[2] if len(sys.argv) > 2 else '/tmp/okd_com_ca'
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:340])); print('..', ' | '.join(R[-1]), flush=True)
BOX = '''()=>{const m=document.getElementById("publishModal"), t=m?m.innerText.replace(/\\s+/g," "):""; return {pubCom:!!document.getElementById("pubCom"), texto:t,
  com:/CONSULTAR APROBACI|AUTORIZACI[OÓ]N COMERCIAL|PENDIENTE DE APROBACI|DEVUELTA A COMERCIAL|AUT-\\d/i.test(t), llamadas:window.__brCalls}}'''
async def relog(pg, email):
    await pg.evaluate('async()=>{try{await window.OKD_ONLINE.api.signOut()}catch(e){}}'); await pg.goto(f'http://127.0.0.1:{dp.PORT}/'); await base.login(pg, email); await pg.wait_for_timeout(1200)
async def main():
    os.makedirs(OUT, exist_ok=True)
    if not all(os.path.isfile(os.path.join(base.FIX, f)) for f in base.FILES): subprocess.run(['python3', os.path.join(os.path.dirname(__file__), 'generate_synthetic_saldo_noc.py'), base.FIX], check=True)
    srv = dp.serve()
    try:
        async with async_playwright() as p:
            b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
            try:
                pg = await (await b.new_context(viewport={'width': 1366, 'height': 900})).new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
                await pg.goto(f'http://127.0.0.1:{dp.PORT}/'); await pg.evaluate('()=>localStorage.clear()')
                await base.login(pg, 'comercial.montecaseros@okdespacho.demo'); await pg.wait_for_timeout(1500)
                mk = await pg.evaluate('''async()=>{const A=window.OKD_ONLINE.api; const a=await A.comCreate("FINANCIACION","cli-101","72003",{amount:500000,installments:2},null,"ca-1");
                  const b=await A.comCreate("FINANCIACION","cli-106","72001",{amount:300000,installments:2},null,"ca-2"); return [a.number,b.number]}''')
                await relog(pg, 'wilfredo@okdespacho.demo')
                dv = await pg.evaluate('''async(n)=>{const A=window.OKD_ONLINE.api; const L=await A.comList("BANDEJA"); const q=L.find(x=>x.number===n);
                  const r=await A.comDecide(q.id, q.version, "DEVOLVER", {amount:250000, installments:2}, "Bajar el importe"); return r.status}''', mk[1])
                await relog(pg, 'admin@okdespacho.demo'); await base.builder(pg)
                await pg.fill('#ids', '72001 72002 72003 72004'); await pg.click('#btnSearch'); await pg.wait_for_timeout(2500)
                await base.type_amount(pg, '72001', '1500'); await base.type_amount(pg, '72002', '2000'); await pg.evaluate('async()=>{ await RouteStore.flush(); }')
                montos0 = await pg.evaluate('()=>RouteStore.rows.map(r=>[String(r.mainOrder), r.monto])')
                await pg.evaluate('()=>{const B=window.OKD_BRIDGE&&window.OKD_BRIDGE.com; window.__brCalls={bridge:!!(B&&B.alerts), n:0}; if(B&&B.alerts){const o=B.alerts; B.alerts=async(...a)=>{window.__brCalls.n++; return o(...a)}}}')
                await base.open_publish(pg); await pg.wait_for_timeout(2500)
                box = await pg.evaluate(BOX); montos1 = await pg.evaluate('()=>RouteStore.rows.map(r=>[String(r.mainOrder), r.monto])')
                await pg.screenshot(path=os.path.join(OUT, 'publicacion_sin_autorizaciones_hotfix.png'))
                res('CA-E1 (HOTFIX) con una solicitud PENDIENTE y otra DEVUELTA para pedidos de la hoja, la ventana PUBLICAR NO muestra autorizaciones comerciales (ni recuadro, ni números AUT, ni estados) y NO las consulta',
                    dv == 'DEVUELTA' and not box['pubCom'] and not box['com'] and mk[0] not in box['texto'] and mk[1] not in box['texto'] and box['llamadas']['bridge'] and box['llamadas']['n'] == 0,
                    {'recuadro': box['pubCom'], 'texto_comercial': box['com'], 'llamadas': box['llamadas'], 'solicitudes': mk})
                res('CA-E2 el recuadro es INFORMATIVO: no cambia ningún importe de la hoja', montos0 == montos1, {'antes': montos0, 'despues': montos1})
                for _ in range(12):
                    cur = await base.pend(pg)
                    if cur['n'] == 0: break
                    cb = pg.locator('#pubPend [data-pack]:not(:checked)').first
                    if await cb.count(): await cb.click(); await pg.wait_for_timeout(2300); continue
                    pay = pg.locator('#pubPend .pendrow', has=pg.locator('[data-ppay]')).first
                    if await pay.count():
                        await pay.locator('[data-ppay]').fill('EFECTIVO')
                        if await pay.locator('[data-ppayship]').count(): await pay.locator('[data-ppayship]').fill('EFECTIVO')
                        await pay.locator('[data-psavepay]').click(); await pg.wait_for_timeout(2300); continue
                    break
                sid = await pg.evaluate('()=>RouteStore.sheetId'); await pg.click('#pubGo'); await pg.wait_for_timeout(5000)
                pub = await pg.evaluate(f'()=>(JSON.parse(localStorage.getItem("okd_online_demo_v2")).routes2||[]).filter(x=>x.sheet_key==="{sid}").length')
                res('CA-E3 NO BLOQUEA: la hoja se publica normalmente con las solicitudes en curso', pub == 1, {'hojas_publicadas': pub})
                # el estado se consulta donde corresponde: «Seguimiento»; sin conexión AVISA (el silencio nunca significa «sin solicitudes»)
                await pg.evaluate('()=>{location.hash="#/autorizaciones?v=despacho"}'); await pg.wait_for_selector('#comMain #tSearch', timeout=20000)
                await pg.fill('#tSearch', '7200'); await pg.wait_for_timeout(1500)
                seg = await pg.evaluate('()=>[...document.querySelectorAll("#comMain [data-select]")].map(b=>({t:b.innerText.replace(/\\s+/g," "), st:b.dataset.st}))')
                await pg.evaluate('()=>{const A=window.OKD_ONLINE.api; window.__ct=A.comTrack; A.comTrack=async()=>{throw Object.assign(new Error("Sin conexión"),{code:"OFFLINE"})}}')
                await pg.evaluate('()=>window.dispatchEvent(new Event("online"))'); await pg.wait_for_timeout(1200)
                off = await pg.evaluate('()=>({banner:!document.getElementById("comConn").hidden, txt:document.getElementById("comConn").innerText, kind:document.getElementById("comConn").dataset.kind, filas:document.querySelectorAll("#comMain [data-select]").length})')
                await pg.evaluate('()=>{window.OKD_ONLINE.api.comTrack=window.__ct}')
                byn = {x['t'].split(' ')[0]: x for x in seg}
                res('CA-E5 (O-01) el estado vive en SEGUIMIENTO: PENDIENTE y DEVUELTA («NO es aprobación», nunca aprobada); SIN CONEXIÓN el aviso dice «Sin conexión con el servidor … podría estar desactualizada» y la lista NO se vacía (no se confunde con «sin solicitudes»)',
                    byn.get(mk[0], {}).get('st') == 'PENDIENTE' and byn.get(mk[1], {}).get('st') == 'DEVUELTA' and 'Devuelta a Comercial' in byn.get(mk[1], {}).get('t', '') and 'Aprobada' not in byn.get(mk[1], {}).get('t', '')
                    and off['banner'] and off['kind'] == 'RED' and 'Sin conexión con el servidor' in off['txt'] and 'desactualizada' in off['txt'] and off['filas'] == len(seg) >= 2, {'seguimiento': seg, 'sin_conexion': off})
                await relog(pg, 'comercial.sanjuan@okdespacho.demo')
                ajeno = await pg.evaluate('async()=>{try{return await window.OKD_ONLINE.api.comOrderAlerts(["72003","72001"],["30500010912"])}catch(e){return e.code||e.message}}')
                res('CA-E6 (B-02) COMERCIAL AJENO por invocación directa: no obtiene las solicitudes de otro Comercial aunque conozca pedido y CUIT', ajeno == [], ajeno)
                await relog(pg, 'despacho@okdespacho.demo')
                sinperm = await pg.evaluate('async()=>{try{await window.OKD_ONLINE.api.comOrderAlerts(["72003"],[]); return "VE"}catch(e){return e.code||e.message}}')
                res('CA-E4 un usuario SIN permisos del módulo no obtiene alertas (FORBIDDEN): el recuadro no se muestra', sinperm == 'FORBIDDEN', sinperm)
            finally: await b.close()
    finally: srv.terminate()
    print('TOTAL', sum(1 for r in R if r[1] == 'PASS'), 'PASS /', sum(1 for r in R if r[1] == 'FAIL'), 'FAIL · esperados', EXPECTED)
    return R
if __name__ == '__main__':
    try: rr = asyncio.run(main())
    except Exception as e: traceback.print_exc(); print('ERROR:', repr(e)); sys.exit(2)
    if len(rr) != EXPECTED: print('ERROR: se ejecutaron %d de %d' % (len(rr), EXPECTED)); sys.exit(2)
    sys.exit(1 if any(r[1] != 'PASS' for r in rr) else 0)
