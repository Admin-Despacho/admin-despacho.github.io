"""E2E (modo demo, Chromium, 390×844 emulado): menú del panel en celular para ADMIN, SUPERVISOR_DESPACHO y OPERARIO_DEPOSITO.
Superior y Operario son usuarios SINTÉTICOS creados en la demo (correo @example.invalid); no se cambia ningún permiso de producción.
Por rol: el menú debe tener EXACTAMENTE los ítems esperados (texto, orden y destino); barra compacta; menú cerrado por defecto;
abrir con MENÚ; al elegir cada ítem se cierra, va al destino esperado y el contenido queda arriba sin scroll horizontal;
acceso al constructor; "Cerrar sesión" desde el menú. Además (Admin): usuario dentro del menú, filtros y casillas táctiles.
Código de salida: 0 = todos los casos esperados en PASS · 1 = alguna FAIL · 2 = error de preparación o casos faltantes."""
import asyncio, os, subprocess, sys, time, socket, traceback
from playwright.async_api import async_playwright
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
DIST = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'dist-demo'); PORT = 4365
# Menús esperados (de roleNav() en src/online/rc4-ui.js y ROLE_PERMISSIONS en rules.js). Si cambian, actualizar acá a propósito.
EXPECTED_MENU = {
  'ADMIN': [('Dashboard', '#/dashboard'), ('Hojas de ruta', '#/historial'), ('Despacho', '#/despacho'), ('Borradores', '#/borradores'),
            ('Hojas publicadas', '#/historial'), ('Solicitudes', '#/solicitudes'), ('Aprobaciones de ruta interna', '#/aprobaciones'),
            ('Transportistas', '#/configuracion?sec=transportistas'), ('Vehículos / Service', '#/configuracion?sec=vehiculos'),
            ('NOC', '#/conciliacion-noc'), ('Informes', '#/informes'), ('Emails', '#/configuracion?sec=emails'), ('Auditoría', '#/auditoria'),
            ('Usuarios y permisos', '#/usuarios'), ('Backup / Archivo', '#/backup'), ('Configuración', '#/configuracion')],
  'SUPERVISOR_DESPACHO': [('Dashboard', '#/dashboard'), ('Nueva hoja de ruta', '#/nueva-hoja'), ('Despacho', '#/despacho'), ('Borradores del equipo', '#/borradores'),
            ('Hojas publicadas', '#/historial'), ('Solicitudes / Aprobaciones', '#/solicitudes'), ('Notificaciones', '#/notificaciones'),
            ('Vehículos', '#/vehiculos'), ('Configuración operativa', '#/config-operativa')],
  'OPERARIO_DEPOSITO': [('Dashboard', '#/dashboard'), ('Nueva hoja / Preparar hoja', '#/nueva-hoja'), ('Despacho', '#/despacho'), ('Borradores de despacho', '#/borradores'),
            ('Hojas publicadas', '#/historial'), ('Notificaciones', '#/notificaciones'), ('Solicitudes', '#/solicitudes'),
            ('Transportistas', '#/configuracion?sec=transportistas'), ('Vehículos / Kilometraje / Service', '#/vehiculos'), ('Columnas predeterminadas', '#/config-operativa')],
}
USERS = {'ADMIN': 'admin@okdespacho.demo', 'SUPERVISOR_DESPACHO': 'sup.qa@example.invalid', 'OPERARIO_DEPOSITO': 'op.qa@example.invalid'}
# Casos esperados: por rol 1 (barra/menú) + 1 (lista exacta) + N ítems + 1 (constructor) + 1 (cerrar sesión); Admin +3 extra
EXPECTED = sum(4 + len(v) for v in EXPECTED_MENU.values()) + 3
R = []
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:160])); print('..', ' | '.join(R[-1]), flush=True)
SCOPE = '()=>{const u=document.getElementById("usersPanel"); return (u&&!u.hidden)?"#usersPanel":"#operario"}'
STATE = '''()=>{const u=document.getElementById("usersPanel"); const inPanel=u&&!u.hidden; const c=inPanel?u:document.getElementById("operario");
  const h=[...c.querySelectorAll(".rc4main h1")].find(e=>e.offsetParent); const s=c.querySelector(".rc4side");
  return {hash:location.hash, open:!!c.querySelector(".rc4side.open"), top:Math.round(inPanel?u.scrollTop:scrollY), h1:h?Math.round(h.getBoundingClientRect().top):null,
          over:document.documentElement.scrollWidth-document.documentElement.clientWidth, bar:s?Math.round(s.getBoundingClientRect().height):999,
          builder:!!document.querySelector("#operario:not([hidden]) #ids")&&(!u||u.hidden)}}'''
async def login(pg, email):
    await pg.goto(f'http://127.0.0.1:{PORT}/'); await pg.wait_for_load_state('networkidle'); await pg.wait_for_timeout(500)
    for _ in range(4):
        await pg.fill('#loginEmail', email); await pg.fill('#loginPass', 'demo')
        if await pg.input_value('#loginEmail') == email: break
        await pg.wait_for_timeout(300)
    await pg.click('#loginBtn'); await pg.wait_for_timeout(2500)
    if await pg.locator('#pinA').count() and await pg.is_visible('#pinA'): await pg.fill('#pinA', '123456'); await pg.fill('#pinB', '123456'); await pg.click('#pinGo'); await pg.wait_for_timeout(900)
    await pg.wait_for_timeout(1500)
    if await pg.locator('#pushLater').count() and await pg.is_visible('#pushLater'): await pg.click('#pushLater'); await pg.wait_for_timeout(200)
async def role_checks(b, role, state):
    tag = role.split('_')[0]
    ctx = await b.new_context(viewport={'width': 390, 'height': 844}, is_mobile=True, has_touch=True, storage_state=state); pg = await ctx.new_page()
    await login(pg, USERS[role])
    sc = await pg.evaluate(SCOPE); side = f'{sc} .rc4side'
    bar = await pg.evaluate(f'()=>{{const s=document.querySelector("{side}"); return s?Math.round(s.getBoundingClientRect().height):999}}')
    closed = not await pg.is_visible(f'{side} .nav')
    res(f'{tag}-01 barra compacta y menú cerrado por defecto', bar <= 80 and closed, f'alto={bar} cerrado={closed}')
    got = await pg.evaluate(f'()=>[...document.querySelectorAll("{side} .nav a")].map(a=>[a.textContent.trim(), a.getAttribute("href")])')
    exp = EXPECTED_MENU[role]
    res(f'{tag}-02 menú con EXACTAMENTE los {len(exp)} ítems esperados (texto, orden y destino)', [tuple(x) for x in got] == exp,
        'faltan=' + str([e for e in exp if list(e) not in got]) + ' sobran=' + str([g for g in got if tuple(g) not in exp]))
    for i, (label, href) in enumerate(exp):
        sc = await pg.evaluate(SCOPE)
        await pg.click(f'{sc} .rc4menu'); await pg.wait_for_timeout(200); opened = await pg.is_visible(f'{sc} .rc4side .nav')
        link = pg.locator(f'{sc} .rc4side .nav a[href="{href}"]', has_text=label).first
        if not await link.count(): res(f'{tag}-{i+3:02d} {label}', False, 'el ítem no está en el menú visible'); continue
        await link.click(); await pg.wait_for_timeout(1300)
        m = await pg.evaluate(STATE)
        dest_ok = m['hash'] == href or (href in ('#/nueva-hoja', '#/despacho') and m['builder'])   # Nueva hoja / Despacho abren el constructor
        ok = opened and dest_ok and not m['open'] and m['top'] == 0 and m['over'] <= 0 and m['bar'] <= 80 and (m['h1'] is not None and m['h1'] < 200 or m['builder'])
        if m['bar'] == 999:   # el destino se abrió SIN el marco del panel (p. ej. 403): se informa y se vuelve al inicio para seguir
            forb = await pg.evaluate('()=>/ACCESO NO AUTORIZADO/i.test(document.body.innerText)')
            m = {**m, 'motivo': '403 · ACCESO NO AUTORIZADO' if forb else 'pantalla sin menú'}
            await pg.evaluate('()=>{location.hash="#/dashboard"}'); await pg.wait_for_timeout(1500)
        res(f'{tag}-{i+3:02d} {label} → {href}', ok, m)
    # acceso al constructor desde el menú
    sc = await pg.evaluate(SCOPE); await pg.click(f'{sc} .rc4menu'); await pg.wait_for_timeout(200)
    await pg.locator(f'{sc} .rc4side .nav a[href="#/despacho"]').first.click(); await pg.wait_for_timeout(1500)
    m = await pg.evaluate(STATE)
    res(f'{tag}-B acceso al constructor (Despacho)', m['builder'] and m['over'] <= 0, m)
    extra = []
    if role == 'ADMIN':   # comprobaciones de las mejoras aprobadas (V4.3)
        await pg.evaluate('()=>{location.hash="#/historial"}'); await pg.wait_for_timeout(1500)
        chip = await pg.evaluate('()=>{const c=document.querySelector("#usersPanel .rc4main .userchip"); return !!c && c.offsetParent!==null}')
        await pg.click('#usersPanel .rc4menu'); await pg.wait_for_timeout(200)
        who = await pg.evaluate('()=>{const w=document.querySelector("#usersPanel .rc4side .rc4who"); const b=w&&w.querySelector(".rc4logout"); return !!w&&w.offsetParent!==null&&!!b&&b.getBoundingClientRect().height>=44}')
        await pg.click('#usersPanel .rc4menu'); await pg.wait_for_timeout(200)
        res('ADMIN-U usuario y "Cerrar sesión" dentro del menú (no arriba del contenido)', who and not chip, f'en menú={who} arriba={chip}')
        f = await pg.evaluate('''()=>{const W=document.documentElement.clientWidth; const els=[...document.querySelectorAll("#hFilters input,#hFilters select,#hFilters button")];
          return {n:els.length, fuera:els.filter(e=>e.getBoundingClientRect().right>W+0.5).length, chicos:els.filter(e=>e.getBoundingClientRect().height<44).length}}''')
        res('ADMIN-F filtros de Hojas publicadas dentro de la pantalla y de 44 px', f['n'] >= 10 and f['fuera'] == 0 and f['chicos'] == 0, f)
        await pg.evaluate('()=>{location.hash="#/configuracion?sec=vehiculos"}'); await pg.wait_for_timeout(1500)
        c = await pg.evaluate('''()=>{const ls=[...document.querySelectorAll("#usersPanel .rc4main label")].filter(l=>l.querySelector(":scope > input[type=checkbox]")&&l.offsetParent);
          return {n:ls.length, chicas:ls.filter(l=>l.getBoundingClientRect().height<44).length}}''')
        res('ADMIN-C casillas con fila táctil de 44 px', c['n'] >= 1 and c['chicas'] == 0, c)
    # cerrar sesión desde el MENÚ
    sc = await pg.evaluate(SCOPE); await pg.click(f'{sc} .rc4menu'); await pg.wait_for_timeout(200)
    await pg.locator(f'{sc} .rc4side .rc4logout').first.click(); await pg.wait_for_timeout(2500)
    out = await pg.locator('#loginForm').count() and await pg.is_visible('#loginForm')
    res(f'{tag}-L "Cerrar sesión" desde el menú vuelve a la pantalla de acceso', out, '')
    await ctx.close()
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
            # usuarios SINTÉTICOS de prueba (solo en el almacenamiento de la demo de este navegador)
            ctx = await b.new_context(viewport={'width': 390, 'height': 844}, is_mobile=True); pg = await ctx.new_page()
            await pg.goto(f'http://127.0.0.1:{PORT}/'); await pg.evaluate('()=>localStorage.clear()'); await login(pg, USERS['ADMIN'])
            await pg.evaluate('''async()=>{const A=window.OKD_ONLINE.api;
              await A.action("create",{full_name:"Superior QA",email:"sup.qa@example.invalid",role:"SUPERVISOR_DESPACHO",active:true});
              await A.action("create",{full_name:"Operario QA",email:"op.qa@example.invalid",role:"OPERARIO_DEPOSITO",active:true});
              const k="okd_online_demo_v2",d=JSON.parse(localStorage.getItem(k)); d.users.forEach(u=>{ if(/@example\\.invalid$/.test(u.email)) u.status="ACTIVO"; }); localStorage.setItem(k,JSON.stringify(d));}''')
            await pg.evaluate('()=>window.OKD_LOGOUT && window.OKD_LOGOUT()'); await pg.wait_for_timeout(1500)
            state = await ctx.storage_state(); await ctx.close()
            for role in ('ADMIN', 'SUPERVISOR_DESPACHO', 'OPERARIO_DEPOSITO'): await role_checks(b, role, state)
          finally: await b.close()
    finally:
        if srv.poll() is None: srv.terminate(); srv.wait(5)
    for r in R: print(' | '.join(r))
    print('TOTAL', sum(1 for r in R if r[1] == 'PASS'), 'PASS /', sum(1 for r in R if r[1] == 'FAIL'), 'FAIL', '· esperados', EXPECTED)
    return R
if __name__ == '__main__':
    try: rr = asyncio.run(main())
    except Exception as e: traceback.print_exc(); print('ERROR:', repr(e)); sys.exit(2)
    if len(rr) != EXPECTED: print('ERROR: se ejecutaron %d comprobaciones y se esperaban %d' % (len(rr), EXPECTED)); sys.exit(2)
    sys.exit(1 if any(r[1] != 'PASS' for r in rr) else 0)
