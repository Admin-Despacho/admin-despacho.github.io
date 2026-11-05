"""V4.24.1 · Actualización de una PWA INSTALADA (perfil persistente con service worker y datos) entre versiones publicadas, servida desde la
MISMA dirección. Uso: python3 run_actualizacion_pwa.py <build_99ffd09> <build_V4.24> <build_V4.24.1>   ·   Exit 0 todo PASS · 1 alguna FAIL · 2 error."""
import asyncio, os, sys, subprocess, time, shutil, json, traceback
sys.path.insert(0, os.path.dirname(__file__))
import run_driver_perfiles as dp
from playwright.async_api import async_playwright
OLD, V24, V241 = sys.argv[1:4]; import re as _re; NEW = _re.search(r'okd-shell-([a-f0-9]+)', open(V241 + '/sw.js').read()).group(1); PORT = 4411; dp.PORT = PORT; SERVE = '/tmp/serve'; UD = '/tmp/okd_pwa_perfil'; R = []; SEL = os.environ.get('SCN', 'B0,U1,U2,U3,U4,U5').split(','); EXPECTED = len(SEL)
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:300])); print('..', ' | '.join(R[-1]), flush=True)
def use(b):
    if os.path.lexists(SERVE): os.unlink(SERVE)
    os.symlink(b, SERVE)
ST = '''async()=>({splash:!!document.getElementById("splash")&&!document.getElementById("splash").classList.contains("hide"), booted:!!window.OKD_BOOTED, panel:!!document.getElementById("okdBootFail"),
  login:!!(document.getElementById("loginEmail")||{}).offsetParent, pin:!!document.getElementById("pinGate"), driver:!!document.querySelector("[data-open],.drv-stop,#drvBack"),
  cache:(await caches.keys()).filter(k=>k.startsWith("okd-shell")).sort().join(",")})'''
LS = '()=>JSON.stringify(Object.keys(localStorage).sort().map(k=>[k,localStorage.getItem(k)]))'
async def scenario(p, name, a, b, mode, after):
    use(a); shutil.rmtree(UD, ignore_errors=True); env = dict(os.environ); env['STALE_INDEX'] = a + '/index.html'
    srv = subprocess.Popen([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'ghpages_server.py'), str(PORT), 'pages'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); time.sleep(1)
    try:
        mk = lambda: p.chromium.launch_persistent_context(UD, executable_path=os.environ.get('CHROMIUM_PATH'), viewport={'width': 412, 'height': 915}, is_mobile=True, has_touch=True,
                                                          geolocation={'latitude': -32.89, 'longitude': -68.84}, permissions=['geolocation'])
        ctx = await mk(); pg = ctx.pages[0] if ctx.pages else await ctx.new_page()
        await dp.login(pg, 'gabriel@okdespacho.demo'); await pg.evaluate('()=>navigator.serviceWorker.ready'); await pg.wait_for_timeout(1500)
        await pg.evaluate('()=>{localStorage.setItem("qa_cola_offline", JSON.stringify([{op:"outcome",stop:"st-qa",id:"op-qa-1"}])); localStorage.setItem("qa_dato","NO_BORRAR");}')
        ls0 = await pg.evaluate(LS); before = await pg.evaluate(ST)
        use(b)   # ===== se publica la versión nueva =====
        srv.terminate(); time.sleep(.5); srv = subprocess.Popen([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'ghpages_server.py'), str(PORT), mode], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); time.sleep(1)
        await ctx.close(); ctx = await mk(); pg = ctx.pages[0] if ctx.pages else await ctx.new_page(); navs = []
        pg.on('framenavigated', lambda f: navs.append(f.url) if f == pg.main_frame else None)
        out = await after(pg, ctx)
        out['ls_igual'] = (await pg.evaluate(LS)) == ls0 or json.loads(await pg.evaluate(LS)) == [x for x in json.loads(ls0)]
        out['recargas'] = len(navs); out['antes'] = before['cache']
        await pg.screenshot(path=f'/tmp/okd_pwa_{name}.png'); await ctx.close(); return out
    finally: srv.terminate()
async def reopen(pg, ctx, wait):
    await pg.goto(f'http://127.0.0.1:{PORT}/'); t0 = time.time(); st = None
    while time.time() - t0 < wait:
        await pg.wait_for_timeout(1500)
        try: st = await pg.evaluate(ST)
        except Exception: continue
    return st
async def main():
    async with async_playwright() as p:
        async def b0(pg, ctx): st = await reopen(pg, ctx, 30); return {'st': st}
        if 'B0' in SEL:
          o = await scenario(p, 'B0', OLD, V24, 'stale1', b0)
          res('B0 LÍNEA BASE (el problema, con la página vieja de la caché de Pages): 99ffd09 → V4.24 queda en la pantalla de carga para siempre', o['st'] and o['st']['splash'] and not o['st']['login'] and not o['st']['driver'], o)
        async def u1(pg, ctx): st = await reopen(pg, ctx, 25); return {'st': st}
        if 'U1' in SEL:
          o = await scenario(p, 'U1', OLD, V241, 'pages', u1)
          res('U1 99ffd09 → V4.24.1 (caché como GitHub Pages): reabre y ARRANCA la versión nueva (shell nuevo activo, el anterior se conserva); localStorage y cola IGUALES',
              o['st'] and o['st']['booted'] and not o['st']['splash'] and (o['st']['driver'] or o['st']['pin'] or o['st']['login']) and NEW in o['st']['cache'] and o['ls_igual'], o)
        async def u2(pg, ctx): st = await reopen(pg, ctx, 45); return {'st': st}
        if 'U2' in SEL:
          o = await scenario(p, 'U2', V24, V241, 'stale1', u2)
          res('U2 V4.24 (PUBLICADA) → V4.24.1 con la página vieja de la caché de Pages (el caso que TRABA): la instalación se RECUPERA SOLA (sin borrar datos ni reinstalar) y queda en la versión nueva',
              o['st'] and not o['st']['splash'] and (o['st']['driver'] or o['st']['pin'] or o['st']['login']) and NEW in o['st']['cache'] and o['ls_igual'] and o['recargas'] <= 4, o)
        broken = '/tmp/build_241_roto'; shutil.rmtree(broken, ignore_errors=True); shutil.copytree(V241, broken)
        for f in os.listdir(broken + '/assets'):
            if f.startswith('index-') and f.endswith('.js'): os.remove(broken + '/assets/' + f)
        async def u3(pg, ctx):
            await ctx.route('**/assets/index-*.js', lambda r: r.fulfill(status=404, body='no existe'))   # el programa principal no carga (ni de caché)
            st = await reopen(pg, ctx, 50); return {'st': st}
        if 'U3' in SEL:
          o = await scenario(p, 'U3', V241, broken, 'pages', u3)
          res('U3 V4.24.1 con el programa principal FALTANTE: UN reintento automático y después el PANEL (REINTENTAR / ACTUALIZAR); sin bucle; datos iguales',
              o['st'] and o['st']['panel'] and o['recargas'] <= 3 and o['ls_igual'], o)
        async def u4(pg, ctx):
            st1 = await reopen(pg, ctx, 15); await ctx.set_offline(True); await pg.reload(); await pg.wait_for_timeout(6000); st2 = await pg.evaluate(ST); await ctx.set_offline(False); return {'st': st2, 'online': st1}
        if 'U4' in SEL:
          o = await scenario(p, 'U4', OLD, V241, 'pages', u4)
          res('U4 SIN CONEXIÓN después de actualizar: arranca desde la caché (sin panel) y conserva datos y cola', o['st'] and o['st']['booted'] and not o['st']['panel'] and not o['st']['splash'] and o['ls_igual'], o)
        async def u5(pg, ctx):
            uid = await pg.evaluate('async()=>{try{return (await window.OKD_ONLINE.api.me()).id}catch(e){return null}}')
            await pg.evaluate('(uid)=>{localStorage.setItem("okd_pin_v1_"+uid+"_cfg", JSON.stringify({salt:"00", v:"x"})); localStorage.setItem("okd_pin_v1_"+uid+"_last", JSON.stringify({at:0, day:"2000-01-01"}));}', uid)
            await pg.reload(); await pg.wait_for_timeout(26000); return {'st': await pg.evaluate(ST)}
        if 'U5' in SEL:
          o = await scenario(p, 'U5', OLD, V241, 'pages', u5)
          res('U5 PIN configurado y vencido después de actualizar: muestra SESIÓN BLOQUEADA y el vigilante NO interfiere (sin panel) aunque pasen más de 20 s',
              o['st'] and o['st']['pin'] and not o['st']['panel'], o)
    print('TOTAL', sum(1 for r in R if r[1] == 'PASS'), 'PASS /', sum(1 for r in R if r[1] == 'FAIL'), 'FAIL · esperados', EXPECTED)
    return R
if __name__ == '__main__':
    try: rr = asyncio.run(main())
    except Exception as e: traceback.print_exc(); print('ERROR:', repr(e)); sys.exit(2)
    if len(rr) != EXPECTED: print('ERROR: se ejecutaron %d de %d' % (len(rr), EXPECTED)); sys.exit(2)
    sys.exit(1 if any(r[1] != 'PASS' for r in rr) else 0)
