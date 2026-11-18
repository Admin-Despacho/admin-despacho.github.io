"""E2E · CORRECCIÓN DE CIERRE DE SESIÓN (demo + navegador REAL). Cada caso indica si es REAL (botón y flujo reales de la app) o SIMULADO
(falla de push/Auth INYECTADA en la página: no hay servidor real). Sin envíos reales."""
import asyncio, os, sys, time, json, traceback
sys.path.insert(0, os.path.dirname(__file__))
import run_driver_perfiles as dp
import run_saldo_revisar_noc as base
from playwright.async_api import async_playwright
R = []; EXPECTED = 15
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
                # ---- botones REALES de salida ----
                pg = await fresh('operario@okdespacho.demo')
                boton = await click_logout(pg); t = await wait_login(pg)
                res('CS-E01 [REAL] OPERARIO · «Cerrar sesión» de su cabecera principal: vuelve al ingreso y una RECARGA posterior NO recupera la cuenta anterior',
                    t is not None and not await logged_in_after_reload(pg) and not await pg.evaluate(SESSION), {'segundos': t, 'boton': boton})
                pg = await fresh('gabriel@okdespacho.demo', mob)
                await physical_click(pg, '#drvPk'); await pg.wait_for_selector('#acLogout'); await pg.wait_for_timeout(300)
                geo = await pg.evaluate('()=>{const r=document.getElementById("acLogout").getBoundingClientRect(); return {x:Math.round(r.left*100)/100, ancho:Math.round(r.width*100)/100}}')
                await physical_click(pg, '#acLogout'); t = await wait_login(pg)
                res('CS-E02 [REAL · clic FÍSICO] MI CUENTA del transportista (móvil 390×844) · «Cerrar sesión» visible y al frente: vuelve al ingreso y la recarga no recupera la cuenta',
                    t is not None and geo['x'] >= 0 and not await logged_in_after_reload(pg), {'segundos': t, 'boton': geo})
                pg = await fresh('admin@okdespacho.demo')
                boton = await click_logout(pg); t = await wait_login(pg)
                res('CS-E03 [REAL] ADMINISTRACIÓN escritorio · «Cerrar sesión»', t is not None and not await logged_in_after_reload(pg), {'segundos': t})
                pg = await fresh('admin@okdespacho.demo', mob)
                await click_front(pg, '.rc4menu'); await pg.wait_for_timeout(400); boton = await click_logout(pg); t = await wait_login(pg)
                await pg.screenshot(path=os.path.join(OUT, '1_movil_tras_salir.png'))
                res('CS-E04 [REAL] VISTA MÓVIL · menú → «Cerrar sesión»', t is not None and not await logged_in_after_reload(pg), {'segundos': t, 'boton': boton})
                pg = await fresh('gabriel@okdespacho.demo', mob)
                boton = await click_logout(pg); t = await wait_login(pg)
                res('CS-E05 [REAL] TRANSPORTISTA (móvil, con GPS) · «Cerrar sesión» de su pantalla', t is not None and not await logged_in_after_reload(pg), {'segundos': t, 'boton': boton})
                pg = await fresh('operario@okdespacho.demo'); await base.builder(pg, load=False); await pg.wait_for_timeout(800)   # sin importación preparatoria (no depende de archivos)
                boton = await click_logout(pg); t = await wait_login(pg)
                res('CS-E14 [REAL] CONSTRUCTOR abierto · «Cerrar sesión» de su cabecera', t is not None and not await logged_in_after_reload(pg), {'segundos': t, 'boton': boton})
                # ---- push SIMULADO: cada operación pendiente ----
                tiempos = {}
                for cual in ('getRegistration', 'getSubscription', 'unsubscribe', 'revoke'):
                    pg = await fresh('operario@okdespacho.demo'); await pg.evaluate(PUSH_STUB, cual)
                    await click_logout(pg); tiempos[cual] = await wait_login(pg)
                    tiempos[cual + '_aviso'] = await note(pg)   # se muestra UNA vez, en el primer ingreso (texto COMPLETO; se compara sin recortar)
                    tiempos[cual + '_recupera'] = await logged_in_after_reload(pg)
                ok = all(tiempos[c] is not None and tiempos[c] <= 8 and not tiempos[c + '_recupera'] for c in ('getRegistration', 'getSubscription', 'unsubscribe', 'revoke')) \
                    and all('baja de notificaciones' in tiempos[c + '_aviso'] for c in ('getRegistration', 'getSubscription', 'unsubscribe'))   # baja NO confirmada → se avisa
                res('CS-E06 [SIMULADO] push: getRegistration / getSubscription / unsubscribe / revocación PENDIENTES para siempre → el cierre termina igual (≤ 8 s) y no recupera la cuenta', ok, tiempos)
                # la marca se deja ANTES de recargar y el reintento corre en la carga siguiente: se observa con el simulador AÚN activo (la baja sigue sin responder)
                pg = await fresh('operario@okdespacho.demo'); await pg.add_init_script('window.__csKeepStub=1')
                await pg.evaluate(PUSH_STUB, 'unsubscribe'); await pg.evaluate('()=>{window.__csMarca=null; const o=localStorage.setItem.bind(localStorage); localStorage.setItem=(k,v)=>{ if(k==="okd_push_unsub_pending") sessionStorage.setItem("cs_marca", v); return o(k,v); }}')
                await click_logout(pg); await wait_login(pg); av = await note(pg); marca = await pg.evaluate('()=>sessionStorage.getItem("cs_marca")')
                res('CS-E07 [SIMULADO] baja de notificaciones NO confirmada: se deja la MARCA para reintentar y el ingreso lo AVISA (no se presenta como hecha)',
                    marca == '1' and 'baja de notificaciones' in av, {'marca_registrada': marca, 'aviso': av[:150]})
                # ---- Auth SIMULADO ----
                pg = await fresh('operario@okdespacho.demo')
                await pg.evaluate('()=>{const A=window.OKD_ONLINE.api; A.signOut=()=>new Promise(()=>{})}')
                await click_logout(pg); t = await wait_login(pg); av = await note(pg)
                res('CS-E08 [SIMULADO] Auth PENDIENTE para siempre: el límite máximo cierra la sesión EN ESTE DISPOSITIVO (≤ 10 s), no la recupera al recargar y AVISA que el servidor no lo confirmó',
                    t is not None and t <= 10.5 and 'no confirmó' in av and not await logged_in_after_reload(pg), {'segundos': t, 'aviso': av[:140]})
                pg = await fresh('operario@okdespacho.demo')
                await pg.evaluate('()=>{const A=window.OKD_ONLINE.api, real=A.signOut.bind(A); A.signOut=async()=>{await real(); return {remote:"ERROR", detail:"simulado"}}}')
                await click_logout(pg); t = await wait_login(pg); av = await note(pg)
                pg2 = await fresh('operario@okdespacho.demo')
                await pg2.evaluate('()=>{const A=window.OKD_ONLINE.api; A.signOut=async()=>{throw new Error("rechazado")}}')
                await click_logout(pg2); t2 = await wait_login(pg2); av2 = await note(pg2)
                res('CS-E09 [SIMULADO] Auth con {error} y Auth RECHAZADO: vuelve al ingreso, sin recuperar la cuenta, AVISANDO que el servidor no confirmó (error)',
                    t is not None and 'no confirmó' in av and 'error' in av and t2 is not None and 'no confirmó' in av2 and not await logged_in_after_reload(pg) and not await logged_in_after_reload(pg2),
                    {'error': [t, av[:90]], 'rechazado': [t2, av2[:90]]})
                # ---- sin conexión (REAL: la red del navegador se corta) ----
                pg = await fresh('operario@okdespacho.demo'); await pg.context.set_offline(True)
                await click_logout(pg); t = await wait_login(pg); await pg.context.set_offline(False)
                res('CS-E10 [REAL red cortada · demo] SIN CONEXIÓN: el cierre termina y no recupera la cuenta', t is not None and not await logged_in_after_reload(pg), {'segundos': t})
                # ---- clics repetidos (REAL) ----
                pg = await fresh('operario@okdespacho.demo')
                await pg.evaluate('()=>{const A=window.OKD_ONLINE.api, real=A.signOut.bind(A); sessionStorage.setItem("cs_so","0"); A.signOut=async()=>{sessionStorage.setItem("cs_so", String(+sessionStorage.getItem("cs_so")+1)); await new Promise(r=>setTimeout(r,800)); return real()}}')
                # cinco clics FÍSICOS de ratón sobre el botón visible + una llamada directa a OKD_LOGOUT (prueba de reentrada de la lógica, no de accesibilidad)
                xy = None
                for sel in SALIDAS:
                    for h in await pg.query_selector_all(sel):
                        xy = xy or await h.evaluate(HIT)
                for _ in range(5): await pg.mouse.click(xy[0], xy[1])
                await pg.evaluate('()=>window.OKD_LOGOUT && window.OKD_LOGOUT()')
                t = await wait_login(pg); n = await pg.evaluate('()=>+sessionStorage.getItem("cs_so")')   # contado en sessionStorage: sobrevive a la recarga
                res('CS-E11 [REAL] CLICS REPETIDOS (5 + llamada directa): UNA sola ejecución del cierre', n == 1 and t is not None, {'ejecuciones': n})
                # ---- cambio entre dos cuentas (REAL) ----
                c = await b.new_context(**desk); pg = await c.new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
                await pg.goto(f'http://127.0.0.1:{dp.PORT}/'); await dp.login(pg, 'comercial.montecaseros@okdespacho.demo'); await pg.wait_for_timeout(1500)
                await pg.evaluate('()=>{location.hash="#/autorizaciones?v=historial"}'); await pg.wait_for_timeout(1800)
                nombre_a = await pg.evaluate('async()=>(await window.OKD_ONLINE.api.me()).full_name')
                await pg.evaluate('()=>window.OKD_LOGOUT()'); await wait_login(pg)
                await dp.login(pg, 'wilfredo@okdespacho.demo'); await pg.wait_for_timeout(2000)
                cambio = await pg.evaluate('''async(a)=>({yo:(await window.OKD_ONLINE.api.me()).full_name, nombre_anterior_visible: document.body.innerText.includes(a),
                  alarma_de:(window.__okdComAlarm&&window.__okdComAlarm.me)||null, aviso_cierre:!!document.getElementById("okdLogoutCover")})''', nombre_a)
                res('CS-E12 [REAL] CAMBIO DE CUENTA: tras salir la comercial e ingresar el aprobador, la sesión es la NUEVA, no se ve el nombre ni datos de la cuenta anterior y no queda la tapa de cierre',
                    cambio['yo'] != nombre_a and not cambio['nombre_anterior_visible'] and not cambio['aviso_cierre'], cambio)
                # ---- conservación del trabajo offline (REAL) ----
                pg = await fresh('gabriel@okdespacho.demo', mob)
                await pg.evaluate('''async()=>{ await new Promise((ok,ko)=>{const r=indexedDB.open("okd_prueba_offline",1); r.onupgradeneeded=()=>r.result.createObjectStore("cola"); r.onsuccess=()=>{const tx=r.result.transaction("cola","readwrite"); tx.objectStore("cola").put({firma:"data:x",gps:[-32.9,-68.8]},"pendiente-1"); tx.oncomplete=()=>{r.result.close(); ok()}}; r.onerror=ko});
                  localStorage.setItem("okd_borrador_prueba","{\\"receptor\\":\\"Juan\\"}"); }''')
                antes = await pg.evaluate('async()=>({ls:Object.keys(localStorage).sort(), idb:(indexedDB.databases? (await indexedDB.databases()).map(d=>d.name).sort():[])})')
                await click_logout(pg); await wait_login(pg)
                despues = await pg.evaluate('''async()=>({ls:Object.keys(localStorage).sort(), idb:(indexedDB.databases? (await indexedDB.databases()).map(d=>d.name).sort():[]),
                  registro: await new Promise(ok=>{const r=indexedDB.open("okd_prueba_offline",1); r.onsuccess=()=>{const g=r.result.transaction("cola").objectStore("cola").get("pendiente-1"); g.onsuccess=()=>{ok(g.result||null); r.result.close()}}; r.onerror=()=>ok(null)}),
                  borrador: localStorage.getItem("okd_borrador_prueba"), sw: navigator.serviceWorker && navigator.serviceWorker.controller ? "activo" : "sin controlador"})''')
                perdidas = [k for k in antes['ls'] if k not in despues['ls'] and not __import__('re').search(r'session|auth-token', k)]
                res('CS-E13 [REAL] TRABAJO OFFLINE conservado: IndexedDB (bases y registro pendiente con firma y GPS), borradores y claves de la app (PIN, cola) INTACTOS; solo se retira la sesión',
                    despues['registro'] is not None and despues['borrador'] and not perdidas and set(antes['idb']) <= set(despues['idb']), {'claves_perdidas': perdidas, 'bases': despues['idb'], 'sw': despues['sw']})
                # ===== CS-E15 · pie de MI CUENTA: los TRES botones visibles, al frente y sin desborde en 320/360/390/480, escritorio y zoom =====
                # Los casos anteriores ya terminaron: liberar contextos, timers y workers de prueba.
                for previous_context in list(b.contexts):
                    await previous_context.close()
                geos = {}
                for name, vp, mobile in [('320', (320, 640), True), ('360', (360, 740), True), ('390', (390, 844), True), ('480', (480, 900), True),
                                         ('escritorio_1366', (1366, 900), False), ('zoom_200_1366', (683, 450), False), ('zoom_150_390', (260, 563), True), ('teclado_390x420', (390, 420), True)]:
                    ctx = dict(viewport={'width': vp[0], 'height': vp[1]}, is_mobile=mobile, has_touch=mobile, geolocation={'latitude': -32.89, 'longitude': -68.84}, permissions=['geolocation'])
                    print('CS-E15 viewport:', name, vp, flush=True)
                    pg = await fresh('gabriel@okdespacho.demo', ctx)
                    try:
                        await physical_click(pg, '#drvPk')
                        await pg.wait_for_selector('#acLogout')
                        await pg.wait_for_timeout(300)
                    except Exception as ex:
                        diagnostic = await pg.evaluate('()=>({viewport:[innerWidth,innerHeight], account:!!document.getElementById("accountModal"), trigger:!!document.getElementById("drvPk"), logout:!!document.getElementById("acLogout"), modals:[...document.querySelectorAll(".umodal")].map(e=>e.id)})')
                        print('CS-E15 FAIL', name, repr(ex), diagnostic, flush=True)
                        geos[name] = {'apertura_mi_cuenta': False}
                        await pg.screenshot(path=os.path.join(OUT, 'fallo_mi_cuenta_' + name + '.png'))
                        await pg.context.close()
                        continue
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
