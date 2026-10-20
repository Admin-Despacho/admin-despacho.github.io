"""E2E (modo demo, Chromium): acceso a Configuración por permiso, incluida la URL directa.
Operario (carriers.manage) entra SOLO a Transportistas; otras secciones → 403. Superior (sin carriers.manage) → 403.
Admin conserva todas las secciones. La pantalla 403 usa el ícono aprobado. Usuarios Superior/Operario SINTÉTICOS (@example.invalid).
Código de salida: 0 todo PASS · 1 alguna FAIL · 2 error de preparación o casos faltantes."""
import asyncio, os, subprocess, sys, time, socket, traceback
from playwright.async_api import async_playwright
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
DIST = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'dist-demo'); PORT = 4366; R = []; EXPECTED = 12
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:160])); print('..', ' | '.join(R[-1]), flush=True)
async def login(pg, email):
    await pg.goto(f'http://127.0.0.1:{PORT}/'); await pg.wait_for_load_state('networkidle'); await pg.wait_for_timeout(500)
    for _ in range(4):
        await pg.fill('#loginEmail', email); await pg.fill('#loginPass', 'demo')
        if await pg.input_value('#loginEmail') == email: break
        await pg.wait_for_timeout(300)
    await pg.click('#loginBtn'); await pg.wait_for_timeout(2500)
    if await pg.locator('#pinA').count() and await pg.is_visible('#pinA'): await pg.fill('#pinA', '123456'); await pg.fill('#pinB', '123456'); await pg.click('#pinGo'); await pg.wait_for_timeout(900)
    await pg.wait_for_timeout(1200)
    if await pg.locator('#pushLater').count() and await pg.is_visible('#pushLater'): await pg.click('#pushLater'); await pg.wait_for_timeout(200)
async def visit(pg, h):
    await pg.evaluate('()=>{location.hash="#/dashboard"}'); await pg.wait_for_timeout(800)
    await pg.evaluate(f'()=>{{location.hash="{h}"}}'); await pg.wait_for_timeout(1500)
    return await pg.evaluate('''()=>({forbidden:!!document.getElementById("e403"), tabs:[...document.querySelectorAll("#cfgNav [data-sec]")].map(b=>b.dataset.sec),
      on:(document.querySelector("#cfgNav .on")||{}).dataset?.sec||null, body:!!document.querySelector("#cfgBody section"),
      logo403:(document.querySelector("#usersPanel header.top img")||{}).getAttribute?.("src")||null})''')
async def main():
    if not os.path.isfile(os.path.join(DIST, 'index.html')): raise RuntimeError('falta el build demo en ' + DIST)
    srv = subprocess.Popen([sys.executable, '-m', 'http.server', str(PORT), '--bind', '127.0.0.1'], cwd=DIST, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(60):
            try: socket.create_connection(('127.0.0.1', PORT), 1).close(); break
            except OSError: time.sleep(0.2)
        async with async_playwright() as p:
          b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
          try:
            ctx = await b.new_context(viewport={'width': 1280, 'height': 800}); pg = await ctx.new_page()
            await pg.goto(f'http://127.0.0.1:{PORT}/'); await pg.evaluate('()=>localStorage.clear()'); await login(pg, 'admin@okdespacho.demo')
            await pg.evaluate('''async()=>{const A=window.OKD_ONLINE.api;
              await A.action("create",{full_name:"Superior QA",email:"sup.qa@example.invalid",role:"SUPERVISOR_DESPACHO",active:true});
              await A.action("create",{full_name:"Operario QA",email:"op.qa@example.invalid",role:"OPERARIO_DEPOSITO",active:true});
              const k="okd_online_demo_v2",d=JSON.parse(localStorage.getItem(k)); d.users.forEach(u=>{ if(/@example\\.invalid$/.test(u.email)) u.status="ACTIVO"; }); localStorage.setItem(k,JSON.stringify(d));}''')
            # Admin: todas las secciones, sin cambios
            a = await visit(pg, '#/configuracion?sec=emails')
            res('CFG-01 Admin entra a Emails y ve todas las secciones', not a['forbidden'] and a['on'] == 'emails' and len(a['tabs']) >= 12 and {'transportistas', 'vehiculos', 'emails', 'backup'} <= set(a['tabs']), a)
            await pg.evaluate('()=>window.OKD_LOGOUT && window.OKD_LOGOUT()'); await pg.wait_for_timeout(1500)
            # Operario
            await login(pg, 'op.qa@example.invalid')
            o = await visit(pg, '#/configuracion?sec=transportistas')
            res('CFG-02 Operario abre Transportistas (antes: 403)', not o['forbidden'] and o['on'] == 'transportistas' and o['body'], o)
            res('CFG-03 Operario ve SOLO la pestaña Transportistas', o['tabs'] == ['transportistas'], o['tabs'])
            o2 = await visit(pg, '#/configuracion')
            res('CFG-04 Operario en #/configuracion sin sección → solo Transportistas', not o2['forbidden'] and o2['tabs'] == ['transportistas'], o2)
            for i, sec in enumerate(['emails', 'vehiculos', 'financieras']):
                x = await visit(pg, f'#/configuracion?sec={sec}')
                res(f'CFG-{5+i:02d} Operario por URL directa a ?sec={sec} → 403', x['forbidden'] and not x['tabs'], x)
            x = await visit(pg, '#/usuarios')
            res('CFG-08 Operario sigue sin acceso a Usuarios y permisos', x['forbidden'], x)
            res('CFG-09 La pantalla 403 usa el ícono aprobado (no el logo cian)', (x['logo403'] or '').startswith('/icons/icon-192.png') , x['logo403'])
            await pg.evaluate('()=>window.OKD_LOGOUT && window.OKD_LOGOUT()'); await pg.wait_for_timeout(1500)
            # Superior: sin carriers.manage
            await login(pg, 'sup.qa@example.invalid')
            s1 = await visit(pg, '#/configuracion?sec=transportistas')
            res('CFG-10 Superior (sin carriers.manage) por URL directa a Transportistas → 403', s1['forbidden'] and not s1['tabs'], s1)
            s2 = await visit(pg, '#/configuracion')
            res('CFG-11 Superior en #/configuracion → 403', s2['forbidden'], s2)
            s3 = await visit(pg, '#/configuracion?sec=emails')
            res('CFG-12 Superior por URL directa a Emails → 403', s3['forbidden'], s3)
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
