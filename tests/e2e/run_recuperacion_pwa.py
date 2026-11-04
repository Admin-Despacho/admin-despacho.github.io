"""V4.24.1 · Recuperación de la PWA INSTALADA (perfil persistente con service worker y datos) con builds REALES.
Uso: SCN=P1,P2,U5,O1,D1 python3 run_recuperacion_pwa.py <build_99ffd09> <build_V4.24.1>   ·   Exit 0 todo PASS · 1 alguna FAIL · 2 error."""
import asyncio, os, sys, subprocess, time, shutil, json, re, traceback
sys.path.insert(0, os.path.dirname(__file__))
import run_driver_perfiles as dp
from playwright.async_api import async_playwright
OLD, V241 = sys.argv[1:3]; V24 = sys.argv[3] if len(sys.argv) > 3 else None; PORT = 4413; dp.PORT = PORT; SERVE = '/tmp/serve'; UD = '/tmp/okd_rec_perfil'; R = []
SEL = os.environ.get('SCN', 'P1,P2,U5,O1,D1,A1,A2').split(','); EXPECTED = len(SEL) + (1 if 'A2' in SEL else 0)
NEW = re.search(r'okd-shell-([a-f0-9]+)', open(V241 + '/sw.js').read()).group(1)
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:320])); print('..', ' | '.join(R[-1]), flush=True)
def use(b):
    if os.path.lexists(SERVE): os.unlink(SERVE)
    os.symlink(b, SERVE)
def server(mode='pages'): s = subprocess.Popen([sys.executable, '/tmp/repro/ghpages_server.py', str(PORT), mode], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); time.sleep(1); return s
ST = '''async()=>({boot:window.OKD_BOOT||null, booted:!!window.OKD_BOOTED, splash:!!document.getElementById("splash")&&!document.getElementById("splash").classList.contains("hide"),
  panel:!!document.getElementById("okdBootFail"), pin:!!document.getElementById("pinGate"), login:!!(document.getElementById("loginEmail")||{}).offsetParent,
  cache:(await caches.keys()).filter(k=>k.startsWith("okd-shell")).sort().join(",")})'''
LS = '()=>JSON.stringify(Object.keys(localStorage).filter(k=>k!=="okd_boot_retry_at").sort().map(k=>[k,localStorage.getItem(k)]))'
def mk(p, **kw): return p.chromium.launch_persistent_context(UD, executable_path=os.environ.get('CHROMIUM_PATH'), viewport={'width': 412, 'height': 915}, is_mobile=True, has_touch=False,
                                                             geolocation={'latitude': -32.89, 'longitude': -68.84}, permissions=['geolocation'], **kw)
async def first(ctx): return ctx.pages[0] if ctx.pages else await ctx.new_page()

async def P1(p):   # arranque BLOQUEADO (el programa principal nunca termina de llegar)
    use(V241); shutil.rmtree(UD, ignore_errors=True); srv = server()
    try:
        ctx = await mk(p, service_workers='block'); pg = await first(ctx); await pg.goto(f'http://127.0.0.1:{PORT}/'); await pg.wait_for_timeout(1500)
        await pg.evaluate('()=>localStorage.setItem("qa_dato","NO_BORRAR")'); ls0 = await pg.evaluate(LS); navs = []
        pg.on('framenavigated', lambda f: navs.append(f.url) if f == pg.main_frame else None)
        await ctx.route(re.compile(r'.*/assets/index-[^/]+\.js$'), lambda route: None)   # queda PENDIENTE para siempre (no 404)
        await pg.reload(wait_until='commit'); t0 = time.time(); st = None
        while time.time() - t0 < 60:
            await pg.wait_for_timeout(2000)
            try: st = await pg.evaluate(ST)
            except Exception: continue
            if st['panel']: break
        await pg.wait_for_timeout(8000); st2 = await pg.evaluate(ST); n = len(navs)
        
        try: await pg.screenshot(path='/tmp/okd_rec_P1_panel.png', timeout=5000)
        except Exception: pass
        same = (await pg.evaluate(LS)) == ls0; await ctx.close()
        res('P1 ARRANQUE BLOQUEADO: no queda la carga infinita; UN reintento automático y después el PANEL (REINTENTAR / ACTUALIZAR); sin más recargas; datos intactos',
            st and st['panel'] and not st['booted'] and st2['panel'] and n <= 2 and same, {'estado': st, 'recargas': n, 'datos_iguales': same, 'tiempo_s': round(time.time() - t0)})
    finally: srv.terminate()

async def P2(p):   # actualización que FALLA: se conserva el shell que funciona
    use(V241); shutil.rmtree(UD, ignore_errors=True); srv = server()
    try:
        ctx = await mk(p); pg = await first(ctx); await pg.goto(f'http://127.0.0.1:{PORT}/'); await pg.wait_for_timeout(2500)
        await pg.evaluate('()=>navigator.serviceWorker.ready.then(()=>1)'); await pg.wait_for_timeout(1500); c0 = (await pg.evaluate(ST))['cache']; ls0 = await pg.evaluate(LS)
        broken = '/tmp/build_241_falla'; shutil.rmtree(broken, ignore_errors=True); shutil.copytree(V241, broken)
        sw = open(broken + '/sw.js').read().replace('okd-shell-' + NEW, 'okd-shell-roto000001'); open(broken + '/sw.js', 'w').write(sw); os.remove(broken + '/splash.webp')   # versión nueva INCOMPLETA
        use(broken)
        r = await pg.evaluate('()=>window.OKD_UPDATE_APP()'); await pg.wait_for_timeout(1500); c1 = (await pg.evaluate(ST))['cache']
        await ctx.set_offline(True); await pg.reload(); await pg.wait_for_timeout(5000); off = await pg.evaluate(ST); await ctx.set_offline(False)
        same = (await pg.evaluate(LS)) == ls0; await ctx.close()
        res('P2 ACTUALIZAR con una versión nueva que FALLA al instalarse: informa la falla, CONSERVA el shell que funciona (no borra cachés) y la app sigue arrancando SIN CONEXIÓN',
            r == 'FALLO' and c1 == c0 and NEW in c1 and 'roto' not in c1 and off['booted'] and not off['panel'] and same, {'resultado': r, 'antes': c0, 'despues': c1, 'sin_conexion': off})
    finally: srv.terminate()

async def U5(p):   # PIN configurado y vencido después de actualizar
    use(OLD); shutil.rmtree(UD, ignore_errors=True); srv = server()
    try:
        ctx = await mk(p); pg = await first(ctx); await dp.login(pg, 'gabriel@okdespacho.demo'); await pg.wait_for_timeout(1500)
        uid = await pg.evaluate('async()=>(await window.OKD_ONLINE.api.me()).id')
        await pg.evaluate('(uid)=>{localStorage.setItem("okd_pin_v1_"+uid+"_cfg", JSON.stringify({salt:"00", v:"x"})); localStorage.setItem("okd_pin_v1_"+uid+"_last", JSON.stringify({at:0, day:"2000-01-01"}));}', uid)
        use(V241); await pg.goto(f'http://127.0.0.1:{PORT}/'); await pg.wait_for_timeout(6000)
        await pg.reload(); await pg.wait_for_timeout(30000); st = await pg.evaluate(ST); await pg.screenshot(path='/tmp/okd_rec_U5_pin.png'); await ctx.close()
        res('U5 PIN configurado (y vencido) después de actualizar a V4.24.1: SESIÓN BLOQUEADA a la vista; el vigilante la toma como ESPERA LEGÍTIMA (estado PIN), sin panel ni recargas, aunque pasen 30 s',
            st['pin'] and not st['panel'] and st['boot'] == 'PIN' and NEW in st['cache'], st)
    finally: srv.terminate()

async def O1(p):   # entrega hecha SIN CONEXIÓN en 99ffd09 → se publica V4.24.1 → se reabre con conexión: sincroniza UNA vez, sin duplicar
    use(OLD); shutil.rmtree(UD, ignore_errors=True); srv = server()
    try:
        ctx = await mk(p); pg = await first(ctx); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
        await dp.login(pg, 'admin@okdespacho.demo'); ids = await pg.evaluate(dp.PUB); await pg.evaluate('async()=>{try{await window.OKD_ONLINE.api.signOut()}catch(e){}}')
        await dp.login(pg, 'gabriel@okdespacho.demo'); await dp.open_route(pg, ids['gb'], km=50100)
        # en 99ffd09 la entrega comercial exige foto del DNI: se usa la RECEPCIÓN INTERNA (Montecaseros: nombre + firma en el lienzo de esa versión)
        sc = await dp.stop_id(pg, ids['gb'], 0); sid = await dp.stop_id(pg, ids['gb'], 1)
        await dp.choose(pg, sc, 'NO_ENTREGADO'); await pg.fill(f'.drv-stop[data-s="{sc}"] [data-f="txt"]', 'cliente ausente (QA)'); await dp.save(pg, sc)
        await ctx.set_offline(True)
        await dp.choose(pg, sid, 'ENTREGADO'); await pg.fill(f'.drv-stop[data-s="{sid}"] [data-f="recv"]', 'Encargada Offline QA')
        cv = pg.locator(f'.drv-stop[data-s="{sid}"] [data-sig]'); await cv.scroll_into_view_if_needed(); bb = await cv.bounding_box()
        await pg.mouse.move(bb['x'] + 20, bb['y'] + 20); await pg.mouse.down()
        for k in range(1, 12): await pg.mouse.move(bb['x'] + 20 + k * 18, bb['y'] + 20 + (k % 3) * 14)
        await pg.mouse.up(); await pg.wait_for_timeout(200)
        await pg.locator(f'.drv-stop[data-s="{sid}"] [data-save]').click(); await pg.wait_for_timeout(2500)
        q0 = await pg.evaluate('()=>Object.keys(localStorage).filter(k=>/outbox|queue/i.test(k)).map(k=>[k,(JSON.parse(localStorage.getItem(k)||"[]")||[]).length])')
        db0 = await pg.evaluate('(sid)=>{const d=JSON.parse(localStorage.getItem("okd_online_demo_v2")); return d.routes2.flatMap(r=>r.stops).find(s=>s.id===sid).outcome}', sid)
        await ctx.close()   # el chofer cierra la app SIN haber sincronizado
        use(V241)           # ===== se publica V4.24.1 =====
        ctx = await mk(p); pg = await first(ctx); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
        await dp.login(pg, 'gabriel@okdespacho.demo'); await pg.wait_for_timeout(6000)
        for _ in range(3):
            await pg.evaluate('()=>window.dispatchEvent(new Event("online"))'); await pg.wait_for_timeout(2500)
        await pg.goto(f'http://127.0.0.1:{PORT}/'); await pg.wait_for_timeout(5000)   # se vuelve a abrir: no debe duplicar
        db1 = await pg.evaluate('''(sid)=>{const d=JSON.parse(localStorage.getItem("okd_online_demo_v2")); const s=d.routes2.flatMap(r=>r.stops).find(s=>s.id===sid);
          return {out:s.outcome, ev:Object.keys(d.evidence||{}).filter(k=>k===sid).length, rc:(d.customerJobs||[]).filter(j=>j.stop_id===sid&&j.kind==="RECIBIDO_CONFORME").length}}''', sid)
        q1 = await pg.evaluate('()=>Object.keys(localStorage).filter(k=>/outbox|queue/i.test(k)).map(k=>[k,(JSON.parse(localStorage.getItem(k)||"[]")||[]).length])')
        st = await pg.evaluate(ST); await ctx.close()
        res('O1 RECEPCIÓN SIN CONEXIÓN pendiente en 99ffd09 (firma en el lienzo de esa versión) → V4.24.1 → reconexión: la cola se CONSERVA, sincroniza UNA vez (1 evidencia) y al reabrir NO se duplica',
            db0 == 'PENDIENTE' and any(n > 0 for _, n in q0) and db1 == {'out': 'ENTREGADO', 'ev': 1, 'rc': 0} and all(n == 0 for _, n in q1) and NEW in st['cache'],
            {'antes_servidor': db0, 'cola_antes': q0, 'despues': db1, 'cola_despues': q1})
    finally: srv.terminate()

async def D1(p):   # instalación que estuvo VARIOS DÍAS sin abrirse (caché del navegador vencida)
    use(OLD); shutil.rmtree(UD, ignore_errors=True); srv = server()
    try:
        ctx = await mk(p); pg = await first(ctx); await dp.login(pg, 'gabriel@okdespacho.demo'); await pg.evaluate('()=>localStorage.setItem("qa_dato","NO_BORRAR")'); ls0 = await pg.evaluate(LS); await ctx.close()
        use(V241); ctx = await mk(p); pg = await first(ctx); cdp = await ctx.new_cdp_session(pg); await cdp.send('Network.clearBrowserCache')   # días después: caché HTTP vencida
        await pg.goto(f'http://127.0.0.1:{PORT}/'); await pg.wait_for_timeout(15000); st = await pg.evaluate(ST); same = (await pg.evaluate(LS)) == ls0; await ctx.close()
        res('D1 instalación SIN ABRIR varios días (caché vencida) → V4.24.1: arranca la versión nueva, sin panel, datos intactos', st['booted'] and not st['panel'] and NEW in st['cache'] and same, st)
    finally: srv.terminate()

DBQ = '''(sid)=>{const d=JSON.parse(localStorage.getItem("okd_online_demo_v2")); const s=d.routes2.flatMap(r=>r.stops).find(s=>s.id===sid); return s?s.outcome:null}'''
QUEUE = '()=>Object.keys(localStorage).filter(k=>/okd_drv_queue/.test(k)).map(k=>(JSON.parse(localStorage.getItem(k)||"[]")||[]).length).reduce((a,b)=>a+b,0)'
async def A1(p):   # PÁGINA ANTIGUA OPERATIVA (V4.24 publicada) con cola pendiente y una entrega abierta sin guardar → se publica V4.24.1
    use(V24); shutil.rmtree(UD, ignore_errors=True); srv = server()
    try:
        ctx = await mk(p); pg = await first(ctx); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
        await dp.login(pg, 'admin@okdespacho.demo'); ids = await pg.evaluate(dp.PUB); await pg.evaluate('async()=>{try{await window.OKD_ONLINE.api.signOut()}catch(e){}}')
        await dp.login(pg, 'gabriel@okdespacho.demo'); await dp.open_route(pg, ids['gb'], km=50100)
        sc = await dp.stop_id(pg, ids['gb'], 0); sm = await dp.stop_id(pg, ids['gb'], 1)
        await ctx.set_offline(True)
        await dp.choose(pg, sc, 'NO_ENTREGADO'); await pg.fill(f'.drv-stop[data-s="{sc}"] [data-f="txt"]', 'cliente ausente (QA)'); await dp.save(pg, sc)
        await dp.choose(pg, sm, 'ENTREGADO'); await pg.fill(f'.drv-stop[data-s="{sm}"] [data-f="recv"]', 'Encargada Borrador QA'); await pg.wait_for_timeout(500)
        q0 = await pg.evaluate(QUEUE); s0 = await pg.evaluate(DBQ, sc)
        navs = []; pg.on('framenavigated', lambda f: navs.append(f.url) if f == pg.main_frame else None)
        use(V241); await ctx.set_offline(False)
        await pg.evaluate('()=>{Object.defineProperty(document,"visibilityState",{value:"visible",configurable:true}); document.dispatchEvent(new Event("visibilitychange")); window.dispatchEvent(new Event("online"));}')
        await pg.wait_for_timeout(25000); n_upd = len(navs)
        st = await pg.evaluate(ST); await pg.wait_for_timeout(4000)
        for _ in range(3): await pg.evaluate('()=>window.dispatchEvent(new Event("online"))'); await pg.wait_for_timeout(2000)
        if await pg.locator(f'[data-open="{ids["gb"]}"]').count(): await pg.locator(f'[data-open="{ids["gb"]}"]').click(); await pg.wait_for_timeout(1200)
        await dp.choose(pg, sm, 'ENTREGADO'); draft = await pg.input_value(f'.drv-stop[data-s="{sm}"] [data-f="recv"]')
        q1 = await pg.evaluate(QUEUE); s1 = await pg.evaluate(DBQ, sc)
        await ctx.close()
        res('A1 PÁGINA ANTIGUA OPERATIVA (V4.24) con cola pendiente y una entrega ABIERTA: al publicar V4.24.1 hay UNA sola recarga (la propia de esa página) y NINGUNA navegación forzada; la operación pendiente se sincroniza UNA vez; lo escrito se RECUPERA',
            q0 == 1 and s0 == 'PENDIENTE' and n_upd == 1 and st['booted'] and NEW in st['cache'] and q1 == 0 and s1 == 'NO_ENTREGADO' and draft == 'Encargada Borrador QA',
            {'cola_antes': q0, 'navegaciones_al_actualizar': n_upd, 'estado': st['boot'], 'cola_despues': q1, 'resultado': s1, 'borrador': draft})
    finally: srv.terminate()

async def A2(p):   # PÁGINA V4.24.1 OCUPADA cuando se activa una versión MÁS NUEVA + conservación de la caché en uso (A3)
    use(V241); shutil.rmtree(UD, ignore_errors=True); srv = server()
    nxt = '/tmp/build_242_sim'; shutil.rmtree(nxt, ignore_errors=True); shutil.copytree(V241, nxt)
    gone = sorted(f for f in os.listdir(nxt + '/assets') if f.startswith('admin-ui-'))[0]; os.remove(nxt + '/assets/' + gone)
    sw = open(nxt + '/sw.js').read().replace('okd-shell-' + NEW, 'okd-shell-sim000000242').replace('"/assets/' + gone + '",', ''); open(nxt + '/sw.js', 'w').write(sw)
    try:
        ctx = await mk(p); pg = await first(ctx); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
        await dp.login(pg, 'admin@okdespacho.demo'); ids = await pg.evaluate(dp.PUB); await pg.evaluate('async()=>{try{await window.OKD_ONLINE.api.signOut()}catch(e){}}')
        await dp.login(pg, 'gabriel@okdespacho.demo'); await dp.open_route(pg, ids['gb'], km=50100); sc = await dp.stop_id(pg, ids['gb'], 0)
        await dp.choose(pg, sc, 'ENTREGADO'); await pg.fill(f'.drv-stop[data-s="{sc}"] [data-f="recv"]', 'Receptor En Curso QA')
        navs = []; pg.on('framenavigated', lambda f: navs.append(f.url) if f == pg.main_frame else None)
        use(nxt)
        await pg.evaluate('async()=>{const r=await navigator.serviceWorker.getRegistration(); await r.update();}'); await pg.wait_for_timeout(15000)
        busy_navs = len(navs); caches_now = (await pg.evaluate(ST))['cache']; still = await pg.input_value(f'.drv-stop[data-s="{sc}"] [data-f="recv"]')
        code = await pg.evaluate(f'async()=>(await fetch("/assets/{gone}")).status')
        await pg.evaluate('()=>document.querySelectorAll(".drv-form").forEach(f=>f.hidden=true)'); await pg.wait_for_timeout(8000); idle_navs = len(navs)
        await ctx.close()
        res('A2 PÁGINA V4.24.1 OCUPADA (entrega abierta) cuando se activa una versión más nueva: NO se recarga mientras se trabaja (lo escrito sigue ahí); al terminar, recarga UNA vez',
            busy_navs == 0 and still == 'Receptor En Curso QA' and idle_navs == 1 and 'sim000000242' in caches_now, {'durante': busy_navs, 'despues': idle_navs, 'texto': still})
        res('A3 CACHÉS: tras activarse la versión nueva se CONSERVA la caché de la versión en uso, y un archivo suyo que ya no está en el servidor se sigue sirviendo (200)',
            NEW in caches_now and code == 200, {'caches': caches_now, 'archivo': gone, 'http': code})
    finally: srv.terminate()

async def main():
    async with async_playwright() as p:
        for n in SEL: await {'P1': P1, 'P2': P2, 'U5': U5, 'O1': O1, 'D1': D1, 'A1': A1, 'A2': A2}[n](p)
    print('TOTAL', sum(1 for r in R if r[1] == 'PASS'), 'PASS /', sum(1 for r in R if r[1] == 'FAIL'), 'FAIL · esperados', EXPECTED)
    return R
if __name__ == '__main__':
    try: rr = asyncio.run(main())
    except Exception as e: traceback.print_exc(); print('ERROR:', repr(e)); sys.exit(2)
    if len(rr) != EXPECTED: print('ERROR: se ejecutaron %d de %d' % (len(rr), EXPECTED)); sys.exit(2)
    sys.exit(1 if any(r[1] != 'PASS' for r in rr) else 0)
