"""E2E (modo demo, Chromium) del incidente "usuario creado pero no puede ingresar": primer ingreso, misma contraseña,
reintento y acceso posterior. La demo replica las reglas del servidor (el login NO activa la invitación; la activa el ruteo).
No envía correos ni toca credenciales reales. Uso: python3 tests/e2e/run_invite_access.py [dist-demo]"""
import asyncio, os, subprocess, sys, time, json
from playwright.async_api import async_playwright
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
DIST = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'dist-demo')
URL = 'http://127.0.0.1:4322/'; DB = '()=>JSON.parse(localStorage.getItem("okd_online_demo_v2"))'; R = []
def res(n, name, ok, d=''): R.append((n, name, 'PASS' if ok else 'FAIL', str(d)[:160]))
async def pin(pg):
    for _ in range(3):
        if await pg.locator('#pinA').count() and await pg.is_visible('#pinA'):
            await pg.fill('#pinA', '123456')
            if await pg.locator('#pinB').count() and await pg.is_visible('#pinB'): await pg.fill('#pinB', '123456')
            await pg.click('#pinGo'); await pg.wait_for_timeout(800)
        else: break
async def login(pg, email, pw):
    await pg.wait_for_load_state('networkidle'); await pg.wait_for_timeout(600)
    for _ in range(4):   # la pantalla de acceso puede volver a dibujarse al cargar: completar, verificar y reintentar
        await pg.wait_for_selector('#loginEmail', state='visible', timeout=10000)
        await pg.fill('#loginEmail', email); await pg.fill('#loginPass', pw); await pg.wait_for_timeout(250)
        if await pg.input_value('#loginEmail') == email and await pg.input_value('#loginPass') == pw: break
    await pg.click('#loginBtn'); await pg.wait_for_timeout(2200)
async def main():
    if not os.path.isfile(os.path.join(DIST, 'index.html')): raise RuntimeError('no existe el build DEMO en ' + DIST + ' (npx vite build --outDir dist-demo)')
    srv = subprocess.Popen([sys.executable, '-m', 'http.server', '4322', '--bind', '127.0.0.1'], cwd=DIST, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        _wait_port(4322, srv)
        async with async_playwright() as p:
          b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
          try:
            pg = await (await b.new_context()).new_page(); errs = []; pg.on('pageerror', lambda e: errs.append(str(e)))
            await pg.goto(URL); await pg.evaluate('()=>localStorage.clear()'); await pg.goto(URL)
            # 1) contraseña equivocada: mensaje genérico, no revela nada
            await login(pg, 'paula@okdespacho.demo', 'otra-cosa'); e1 = await pg.inner_text('#authErr')
            res('INV-UI-01', 'Contraseña incorrecta → "Email o contraseña incorrectos."', e1.strip() == 'Email o contraseña incorrectos.', e1)
            # 2) invitada con contraseña ya guardada entra con ella: se activa sola, NO se le pide crearla otra vez
            await login(pg, 'paula@okdespacho.demo', 'demo'); await pin(pg)
            st = await pg.evaluate(DB); u = [x for x in st['users'] if x['email'] == 'paula@okdespacho.demo'][0]
            set_pw = await pg.locator('#passForm').count() and await pg.is_visible('#passForm')
            res('INV-UI-02', 'Invitada que entra con su contraseña: queda ACTIVA y entra a la app sin volver a "CREAR CONTRASEÑA"', u['status'] == 'ACTIVO' and not set_pw
                and any(a['action'] == 'INVITE_ACCEPTED' for a in st['audit']), u['status'])
            # 3) enlace de invitación (#/crear-contrasena) con la MISMA contraseña ya guardada: no queda atrapada
            await pg.evaluate('''()=>{const k="okd_online_demo_v2",d=JSON.parse(localStorage.getItem(k)); d.users.find(x=>x.email==="paula@okdespacho.demo").status="INVITACION_PENDIENTE"; localStorage.setItem(k,JSON.stringify(d)); sessionStorage.removeItem("okd_fresh_login");}''')
            await pg.evaluate('()=>{location.hash="#/crear-contrasena"}'); await pg.reload(); await pg.wait_for_timeout(1500)
            shown = await pg.locator('#passForm').count() and await pg.is_visible('#passForm')
            if shown:
                await pg.fill('#p1', 'demo-demo'); await pg.fill('#p2', 'demo-demo'); await pg.click('#passBtn'); await pg.wait_for_timeout(1500); await pin(pg)
                await pg.evaluate('()=>{location.hash="#/crear-contrasena"}'); await pg.wait_for_timeout(1200)
                if await pg.locator('#passForm').count() and await pg.is_visible('#passForm'):
                    await pg.fill('#p1', 'demo-demo'); await pg.fill('#p2', 'demo-demo'); await pg.click('#passBtn'); await pg.wait_for_timeout(1500)
            err2 = (await pg.inner_text('#authErr')) if await pg.locator('#authErr').count() and await pg.is_visible('#authErr') else ''
            st = await pg.evaluate(DB); u = [x for x in st['users'] if x['email'] == 'paula@okdespacho.demo'][0]
            res('INV-UI-03', 'Enlace de invitación: crea la contraseña y entra; repetir con la MISMA no muestra "should be different" ni la deja atrapada', shown and u['status'] == 'ACTIVO' and 'different' not in err2, err2 or u['status'])
            # 4) acceso posterior con la contraseña creada
            await pg.evaluate('()=>window.OKD_LOGOUT && window.OKD_LOGOUT()'); await pg.wait_for_timeout(1500); await pg.goto(URL)
            await login(pg, 'paula@okdespacho.demo', 'demo-demo'); await pin(pg)
            ok4 = not (await pg.locator('#loginForm').count() and await pg.is_visible('#loginForm')) and not (await pg.locator('#passForm').count() and await pg.is_visible('#passForm'))
            res('INV-UI-04', 'Acceso posterior con la contraseña creada: entra directo', ok4)
            SETDB = '''(m)=>{const k="okd_online_demo_v2",d=JSON.parse(localStorage.getItem(k)); const u=d.users.find(x=>x.email==="paula@okdespacho.demo");
              if(m.status) u.status=m.status; if("fail" in m) d.demoFailAcceptInvite=m.fail; localStorage.setItem(k,JSON.stringify(d)); sessionStorage.removeItem("okd_fresh_login");}'''
            async def logout_home():
                await pg.evaluate('()=>window.OKD_LOGOUT && window.OKD_LOGOUT()'); await pg.wait_for_timeout(1300); await pg.goto(URL)
            async def prepare(m):   # estado de prueba en el almacenamiento de la demo + recarga (la app relee el estado, como al abrirla)
                await pg.evaluate(SETDB, m); await pg.reload(); await pg.wait_for_timeout(600)
            # 5) la activación FALLA al ingresar: mensaje visible + "Reintentar activación"; reintentar (ya sin falla) entra activo
            await logout_home(); await prepare({'status': 'INVITACION_PENDIENTE', 'fail': True})
            await login(pg, 'paula@okdespacho.demo', 'demo-demo'); await pg.wait_for_timeout(500)
            msg5 = (await pg.inner_text('#authErr')) if await pg.locator('#authErr').count() else ''
            retry_vis = await pg.locator('#retryAccept').count() and await pg.is_visible('#retryAccept')
            await pg.evaluate(SETDB, {'fail': False}); await pg.click('#retryAccept'); await pg.wait_for_timeout(1500); await pin(pg)
            st = await pg.evaluate(DB); u = [x for x in st['users'] if x['email'] == 'paula@okdespacho.demo'][0]
            res('INV-UI-05', 'Activación fallida: el error se ve, aparece "Reintentar activación" y al reintentar queda ACTIVA', 'no se pudo activar' in msg5 and retry_vis and u['status'] == 'ACTIVO', msg5[:90] or u['status'])
            # 6) recuperación con invitación pendiente y activación fallida: aviso REAL (no "activada"), y el ingreso posterior lo resuelve
            await logout_home(); await prepare({'status': 'INVITACION_PENDIENTE', 'fail': True})
            await pg.evaluate("()=>window.OKD_ONLINE.api.requestPasswordReset('paula@okdespacho.demo')")
            link = await pg.evaluate('()=>{const d=JSON.parse(localStorage.getItem("okd_online_demo_v2")); return d.authMails.filter(m=>m.to==="paula@okdespacho.demo").pop().link}')
            await pg.evaluate('(l)=>{location.hash=l.replace(/^#/,"")}', link); await pg.reload(); await pg.wait_for_selector('#np1', timeout=8000)
            await pg.fill('#np1', 'Nueva-Clave-9'); await pg.fill('#np2', 'Nueva-Clave-9'); await pg.click('#npGo'); await pg.wait_for_timeout(1500)
            note6 = (await pg.inner_text('#authNote')) if await pg.locator('#authNote').count() else ''
            st = await pg.evaluate(DB); u6 = [x for x in st['users'] if x['email'] == 'paula@okdespacho.demo'][0]
            await prepare({'fail': False}); await login(pg, 'paula@okdespacho.demo', 'Nueva-Clave-9'); await pin(pg)
            st = await pg.evaluate(DB); u6b = [x for x in st['users'] if x['email'] == 'paula@okdespacho.demo'][0]
            set6 = await pg.locator('#passForm').count() and await pg.is_visible('#passForm')
            res('INV-UI-06', 'Recuperación con invitación pendiente y activación fallida: dice que NO se activó; al ingresar se activa sin volver a "CREAR CONTRASEÑA"',
                'todavía no se activó' in note6 and 'Contraseña actualizada' not in note6 and u6['status'] == 'INVITACION_PENDIENTE' and u6b['status'] == 'ACTIVO' and not set6, note6[:100])
            # 7) deshabilitado y archivado: siguen sin acceso
            out7 = []
            for stt in ('DESHABILITADO', 'ARCHIVADO'):
                await logout_home(); await prepare({'status': stt, 'fail': False})
                await login(pg, 'paula@okdespacho.demo', 'Nueva-Clave-9')
                e7 = (await pg.inner_text('#authErr')) if await pg.locator('#authErr').count() else ''
                st = await pg.evaluate(DB); out7.append((stt, e7.strip(), [x for x in st['users'] if x['email'] == 'paula@okdespacho.demo'][0]['status']))
            res('INV-UI-07', 'Usuarios DESHABILITADO y ARCHIVADO siguen sin acceso (y no se activan)', all(e == 'Usuario sin acceso. Consultá con Administración.' and s_ == stt for stt, e, s_ in out7), str(out7)[:150])
            res('E-ERR', 'Sin errores de consola', not errs, '; '.join(errs[:2]))
          finally: await b.close()
    finally: _stop(srv)
    for r in R: print(' | '.join(r))
    print('TOTAL', sum(1 for r in R if r[2] == 'PASS'), 'PASS /', sum(1 for r in R if r[2] == 'FAIL'), 'FAIL')
    return R


def _wait_port(port, srv, timeout=15):
    import socket
    t0 = time.time()
    while time.time() - t0 < timeout:
        if srv.poll() is not None: raise RuntimeError('el servidor estático terminó al arrancar (código %s)' % srv.returncode)
        try: socket.create_connection(('127.0.0.1', port), 1).close(); return
        except OSError: time.sleep(0.2)
    raise RuntimeError('el servidor estático no respondió en el puerto %d' % port)

def _stop(srv):
    if srv and srv.poll() is None:
        srv.terminate()
        try: srv.wait(5)
        except Exception: srv.kill()

def _exit_with(main, expected):
    """0 = todos los casos esperados ejecutados y en PASS · 1 = alguna comprobación FAIL · 2 = excepción / preparación / casos faltantes."""
    import traceback
    try:
        results = asyncio.run(main())
    except Exception as e:
        traceback.print_exc(); print('ERROR: la prueba no pudo completarse:', repr(e)); sys.exit(2)
    ran = len(results); fails = [r for r in results if r[2] != 'PASS']
    if ran < expected:
        print('ERROR: se ejecutaron %d de %d comprobaciones esperadas' % (ran, expected)); sys.exit(2)
    sys.exit(1 if fails else 0)

EXPECTED = 8   # comprobaciones que DEBEN ejecutarse (si se agregan casos, actualizar)
if __name__ == '__main__':
    _exit_with(main, expected=EXPECTED)
