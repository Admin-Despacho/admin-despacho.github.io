"""E2E · CORRECCIÓN DE CIERRE DE SESIÓN (demo + navegador REAL). Cada caso indica si es REAL (botón y flujo reales de la app) o SIMULADO
(falla de push/Auth INYECTADA en la página: no hay servidor real). Sin envíos reales."""
import asyncio, os, sys, time, json, traceback
sys.path.insert(0, os.path.dirname(__file__))
import run_driver_perfiles as dp
import run_saldo_revisar_noc as base
from playwright.async_api import async_playwright
R = []; EXPECTED = 1
DIST = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), '..', '..', 'dist-demo'); dp.DIST = DIST; dp.PORT = 4391
OUT = sys.argv[2] if len(sys.argv) > 2 else '/tmp/okd_cierre'
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:400])); print('..', ' | '.join(R[-1]), flush=True)
LOGIN = '()=>{const a=document.getElementById("auth"); return !!a && !a.hidden && a.getClientRects().length>0 && !!document.getElementById("authCard")}'
SESSION = '()=>Object.keys(localStorage).filter(k=>/session|auth-token/i.test(k)).map(k=>k+"="+String(localStorage.getItem(k)).slice(0,20))'
async def wait_login(pg, max_s=14):
    t0 = time.time()
    while time.time() - t0 < max_s:
        try:
            if await pg.evaluate(LOGIN): return round(time.time() - t0, 1)
        except Exception: pass
        await asyncio.sleep(0.25)
    return None
async def logged_in_after_reload(pg):
    await pg.reload(); await pg.wait_for_timeout(1800); return not await pg.evaluate(LOGIN)
SALIDAS = ['#btnLogout', '#legacyRc4Logout', '#adLogout', '#np-logout', '.rc4logout']
HIT = '''(e)=>{ const r=e.getBoundingClientRect(); const x=r.left+r.width/2, y=r.top+r.height/2;
  if (!r.width || !r.height || x<0 || x>innerWidth || y<0 || y>innerHeight) return null; const h=document.elementFromPoint(x,y); return h && (h===e || e.contains(h)) ? [x,y] : null; }'''
async def physical_click(pg, css, label=None):   # interacción FÍSICA: mouse en las coordenadas reales del botón visible (sin page.click, sin force, sin desplazar el contenedor)
    for _ in range(6):
        for h in await pg.query_selector_all(css):
            xy = await h.evaluate(HIT)
            if xy: await pg.mouse.click(xy[0], xy[1]); return label or css
        # si el diálogo es más alto que la pantalla, la persona desplaza VERTICALMENTE con la rueda (gesto real); nunca en horizontal
        await pg.mouse.move(195, 400); await pg.mouse.wheel(0, 300); await pg.wait_for_timeout(200)
    raise RuntimeError('sin elemento físicamente accesible para ' + css)
async def click_logout(pg):   # el botón de salida que la persona VE AL FRENTE; registra cuál
    for sel in SALIDAS + ['#acLogout']:
        for h in await pg.query_selector_all(sel):
            xy = await h.evaluate(HIT)
            if xy: await pg.mouse.click(xy[0], xy[1]); return sel
    raise RuntimeError('sin botón de salida físicamente accesible')
async def click_front(pg, css): await physical_click(pg, css)
async def note(pg): return await pg.evaluate('()=>{const n=document.getElementById("authNote"); return n?n.textContent:""}')
# SIMULACIÓN de push en la página: Notification/PushManager presentes y un service worker cuya operación indicada NUNCA responde
PUSH_STUB = '''(cual)=>{ const never=()=>new Promise(()=>{}); window.__pushOps=[];
  const sub={endpoint:"https://push.invalid/e", unsubscribe:()=>{window.__pushOps.push("unsubscribe"); return cual==="unsubscribe"?never():Promise.resolve(true)}};
  const reg={pushManager:{getSubscription:()=>{window.__pushOps.push("getSubscription"); return cual==="getSubscription"?never():Promise.resolve(sub)}}};
  if(!window.PushManager) window.PushManager=function(){}; if(!window.Notification) window.Notification=function(){};
  Object.defineProperty(navigator.serviceWorker,"getRegistration",{configurable:true,value:()=>{window.__pushOps.push("getRegistration"); return cual==="getRegistration"?never():Promise.resolve(reg)}});
  const A=window.OKD_ONLINE.api; A.revokePushSubscription=()=>{window.__pushOps.push("revoke"); return cual==="revoke"?never():Promise.resolve(true)}; }'''
async def main():
    os.makedirs(OUT, exist_ok=True)
    srv = dp.serve()
    try:
        async with async_playwright() as p:
            b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
            try:
                desk = dict(viewport={'width': 1366, 'height': 900})
                mob = dict(viewport={'width': 390, 'height': 844}, is_mobile=True, has_touch=True, geolocation={'latitude': -32.89, 'longitude': -68.84}, permissions=['geolocation'])
                async def fresh(email, ctx=desk):
                    c = await b.new_context(**ctx); pg = await c.new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
                    await pg.goto(f'http://127.0.0.1:{dp.PORT}/'); await dp.login(pg, email); await pg.wait_for_timeout(1500); return pg
                # ===== CS-E15 · pie de MI CUENTA: los TRES botones visibles, al frente y sin desborde en 320/360/390/480, escritorio y zoom =====
                geos = {}
                for name, vp, mobile in [('320', (320, 640), True), ('360', (360, 740), True), ('390', (390, 844), True), ('480', (480, 900), True),
                                         ('escritorio_1366', (1366, 900), False), ('zoom_200_1366', (683, 450), False), ('zoom_150_390', (260, 563), True), ('teclado_390x420', (390, 420), True)]:
                    ctx = dict(viewport={'width': vp[0], 'height': vp[1]}, is_mobile=mobile, has_touch=mobile, geolocation={'latitude': -32.89, 'longitude': -68.84}, permissions=['geolocation'])
                    print('Pantalla', name, flush=True); pg = await fresh('gabriel@okdespacho.demo', ctx); opener=pg.locator('#drvPk'); await (opener.tap() if mobile else opener.click()); await pg.wait_for_selector('#acLogout'); await pg.wait_for_timeout(300)
                    g = {}
                    for bid in ('acLogout', 'acClose', 'acSave'):
                        try:
                            h = await pg.query_selector('#' + bid); xy = await h.evaluate(HIT)   # SIN desplazar nada: el pie debe estar a la vista de entrada
                            r = await h.evaluate('(e)=>{const r=e.getBoundingClientRect(); return [r.left, r.right]}')
                            g[bid] = bool(xy) and r[0] >= 0 and r[1] <= vp[0]
                        except Exception as ex: g[bid] = 'ERROR ' + str(ex)[:60]
                    g['pie_sin_desborde'] = await pg.evaluate('()=>{const f=document.querySelector("#acLogout").closest("footer"); return f.scrollWidth<=f.clientWidth+1}')
                    g['dialogo_sin_desborde'] = await pg.evaluate('()=>{const m=document.querySelector(".umodal"), d=document.querySelector(".ac-dialog"), r=d.getBoundingClientRect(); return m.scrollWidth<=m.clientWidth+1 && r.left>=0 && r.right<=innerWidth+1}')
                    obs_fondo = await pg.evaluate('()=>document.documentElement.scrollWidth-document.documentElement.clientWidth')   # OBSERVACIÓN (pantalla de fondo, fuera de este ajuste)
                    if obs_fondo > 0: geos.setdefault('_observacion_fondo_desborda_px', {})[name] = obs_fondo
                    if name == 'zoom_150_390':   # pantalla más baja: un ARRASTRE TÁCTIL real (como un dedo) desplaza el CUERPO del diálogo sin mover la página de fondo
                        cdp = await pg.context.new_cdp_session(pg); bx = await pg.evaluate('()=>{const r=document.querySelector(".ac-dialog>.body").getBoundingClientRect(); return [Math.round(r.left+r.width/2), Math.round(r.top+r.height/2)]}')
                        fondo0 = await pg.evaluate('()=>window.scrollY')
                        await cdp.send('Input.dispatchTouchEvent', {'type': 'touchStart', 'touchPoints': [{'x': bx[0], 'y': bx[1] + 60}]})
                        for k in range(1, 11): await cdp.send('Input.dispatchTouchEvent', {'type': 'touchMove', 'touchPoints': [{'x': bx[0], 'y': bx[1] + 60 - k * 15}]}); await pg.wait_for_timeout(16)
                        await cdp.send('Input.dispatchTouchEvent', {'type': 'touchEnd', 'touchPoints': []}); await pg.wait_for_timeout(600)
                        mv = await pg.evaluate('()=>({cuerpo:document.querySelector(".ac-dialog>.body").scrollTop, pagina:window.scrollY})')
                        g['cuerpo_desplazable_sin_mover_fondo'] = mv['cuerpo'] > 0 and mv['pagina'] == fondo0
                    geos[name] = g
                    if name == '320': await pg.screenshot(path=os.path.join(OUT, '2_mi_cuenta_320.png'))
                    await pg.context.close()
                res('CS-E15 [REAL] MI CUENTA: «Cerrar sesión», «Cerrar» y «CAMBIAR CONTRASEÑA» visibles y AL FRENTE SIN desplazar, sin desborde horizontal, en 320 / 360 / 390 / 480 px, escritorio, zoom (200 % escritorio = 683×450; 150 % móvil = 260×563) y teclado abierto (390×420); el cuerpo se desplaza con gesto táctil sin arrastrar el fondo',
                    all(v is True for k, g in geos.items() if not k.startswith('_') for v in g.values()), {'entornos': len([k for k in geos if not k.startswith('_')]), 'observacion': geos.get('_observacion_fondo_desborda_px'), 'fallas': {k: {kk: vv for kk, vv in g.items() if vv is not True} for k, g in geos.items() if not k.startswith('_') and any(vv is not True for vv in g.values())}})
            finally: await b.close()
    finally: srv.terminate()
    print('TOTAL', sum(1 for r in R if r[1] == 'PASS'), 'PASS /', sum(1 for r in R if r[1] == 'FAIL'), 'FAIL · esperados', EXPECTED)
    return R
if __name__ == '__main__':
    try: rr = asyncio.run(main())
    except Exception as e: traceback.print_exc(); print('ERROR:', repr(e)); sys.exit(2)
    if len(rr) != EXPECTED: print('ERROR: se ejecutaron %d de %d' % (len(rr), EXPECTED)); sys.exit(2)
    sys.exit(1 if any(r[1] != 'PASS' for r in rr) else 0)
