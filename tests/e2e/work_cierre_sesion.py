"""E2E · CORRECCIÓN DE CIERRE DE SESIÓN (demo + navegador REAL). Cada caso indica si es REAL (botón y flujo reales de la app) o SIMULADO
(falla de push/Auth INYECTADA en la página: no hay servidor real). Sin envíos reales."""
import asyncio, os, sys, time, json, traceback
sys.path.insert(0, os.path.dirname(__file__))
import run_driver_perfiles as dp
import run_saldo_revisar_noc as base
from playwright.async_api import async_playwright
R = []; EXPECTED = 14
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
async def click_logout(pg):   # el botón de salida que la persona VE AL FRENTE (visible y no tapado por otra capa); registra cuál
    sel = await pg.evaluate('''(sels)=>{ for (const s of sels) for (const e of document.querySelectorAll(s)) { const r=e.getBoundingClientRect();
        if (!r.width || !r.height) continue; const h=document.elementFromPoint(r.left+r.width/2, r.top+r.height/2);
        if (h && (h===e || e.contains(h))) { e.setAttribute('data-cs-hit','1'); return s; } } return null; }''', SALIDAS + ['#acLogout'])
    if not sel: raise RuntimeError('sin botón de salida al frente')
    await pg.click('[data-cs-hit="1"]'); return sel
async def click_front(pg, css):   # toca el elemento que coincide con css y está AL FRENTE (no tapado)
    ok = await pg.evaluate('''(css)=>{ for (const e of document.querySelectorAll(css)) { const r=e.getBoundingClientRect(); if (!r.width || !r.height) continue;
        const h=document.elementFromPoint(r.left+r.width/2, r.top+r.height/2); if (h && (h===e || e.contains(h))) { e.setAttribute('data-cs-front','1'); return true; } } return false; }''', css)
    if not ok: raise RuntimeError('nada al frente para ' + css)
    await pg.click('[data-cs-front="1"]'); await pg.evaluate('()=>document.querySelectorAll("[data-cs-front]").forEach(e=>e.removeAttribute("data-cs-front"))')
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
                try:
                    pg = await fresh('gabriel@okdespacho.demo', mob)
                    await pg.click('#drvPk'); await pg.wait_for_selector('#acLogout'); print('WORK_ACCOUNT_DIAG', await pg.evaluate('()=>({modals:document.querySelectorAll("#accountModal").length,buttons:[...document.querySelectorAll("#acLogout")].map(e=>{const r=e.getBoundingClientRect(),h=document.elementFromPoint(r.x+r.width/2,r.y+r.height/2);return {x:r.x,y:r.y,w:r.width,h:r.height,hit:h&&h.outerHTML.slice(0,100)}})})'), flush=True); await click_front(pg, '#acLogout'); t = await wait_login(pg)
                    res('CS-E02 [REAL] PANEL DE CUENTA (abierto desde la pantalla del transportista) · «Cerrar sesión»: vuelve al ingreso sin recuperar la cuenta al recargar', t is not None and not await logged_in_after_reload(pg), {'segundos': t})
                except Exception as ex:
                    res('CS-E02 [REAL] PANEL DE CUENTA móvil · botón físicamente accesible y cierre', False, str(ex))
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
                pg = await fresh('operario@okdespacho.demo'); await base.builder(pg, load=False); await pg.wait_for_timeout(800)
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
                await pg.evaluate('(sels)=>{const b=sels.map(s=>[...document.querySelectorAll(s)].find(e=>e.getClientRects().length)).find(Boolean); for(let i=0;i<5;i++) b.click(); if(window.OKD_LOGOUT) window.OKD_LOGOUT();}', SALIDAS)
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
            finally: await b.close()
    finally: srv.terminate()
    print('TOTAL', sum(1 for r in R if r[1] == 'PASS'), 'PASS /', sum(1 for r in R if r[1] == 'FAIL'), 'FAIL · esperados', EXPECTED)
    return R
if __name__ == '__main__':
    try: rr = asyncio.run(main())
    except Exception as e: traceback.print_exc(); print('ERROR:', repr(e)); sys.exit(2)
    if len(rr) != EXPECTED: print('ERROR: se ejecutaron %d de %d' % (len(rr), EXPECTED)); sys.exit(2)
    sys.exit(1 if any(r[1] != 'PASS' for r in rr) else 0)
