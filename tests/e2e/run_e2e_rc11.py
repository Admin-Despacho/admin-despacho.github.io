"""E2E RC1.1: usuarios, contraseñas (invitación, olvidé, restablecer), eliminar/archivar, módulos y 403."""
import asyncio, json, os, subprocess, time, socket
from playwright.async_api import async_playwright
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
CHROME = os.environ.get('CHROMIUM_PATH', '/opt/pw-browsers/chromium-1194/chrome-linux/chrome')
URL = 'http://localhost:4178/'; R = []
def res(n, name, ok, det=''): R.append((n, name, 'PASS' if ok else 'FAIL', str(det)[:150]))
DB = '()=>JSON.parse(localStorage.getItem("okd_online_demo_v2"))'; api = 'window.OKD_ONLINE.api'
async def login(pg, email, pw='demo'):
    await pg.goto(URL); await pg.wait_for_timeout(400); await pg.fill('#loginEmail', email); await pg.fill('#loginPass', pw); await pg.click('#loginBtn'); await pg.wait_for_timeout(1400)
async def tryit(pg, js):
    try: await pg.evaluate(js); return 'OK'
    except Exception as e: return str(e)
async def main():
    server = subprocess.Popen(['npx', 'vite', 'preview', '--port', '4178', '--strictPort', '--host', 'localhost'], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(60):
            try: socket.create_connection(('localhost', 4178), 1).close(); break
            except OSError: time.sleep(0.3)
        async with async_playwright() as p:
            b = await p.chromium.launch(executable_path=CHROME); ctx = await b.new_context(viewport={'width': 1300, 'height': 900}); errs = []
            def ps(pg): pg.on('pageerror', lambda e: errs.append(str(e))); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept('ELIMINAR') if d.type == 'prompt' else d.accept()))
            ad = await ctx.new_page(); ps(ad); await ad.goto(URL); await ad.evaluate('()=>localStorage.clear()'); await login(ad, 'admin@okdespacho.demo')
            await ad.click('#btnUsers'); await ad.wait_for_timeout(500); await ad.click('#upNew')
            await ad.select_option('#nuRole', 'TRANSPORTISTA_INTERNO'); acc_t = await ad.inner_text('#nuAccess'); adv_open = await ad.evaluate('()=>document.querySelector("#nuAdv").open')
            await ad.select_option('#nuRole', 'DESPACHO'); acc_d = await ad.inner_text('#nuAccess')
            res('USR-ACC', 'Transportista: ACCESO DEL USUARIO resumido (avanzados cerrados); otros roles: MÓDULOS HABILITADOS', 'ACCESO DEL USUARIO' in acc_t and 'Ver Usuarios ❌' in acc_t and 'solo verá las hojas' in acc_t and adv_open is False and 'MÓDULOS HABILITADOS' in acc_d, '')
            await ad.fill('#nuName', 'Usuario Prueba'); await ad.fill('#nuEmail', 'prueba@okdespacho.demo'); await ad.click('#umSave'); await ad.wait_for_timeout(600)
            row = await ad.inner_text('#usersPanel tr:has-text("Usuario Prueba")'); st = await ad.evaluate(DB)
            inv = [m for m in st['authMails'] if m['to'] == 'prueba@okdespacho.demo' and m['type'] == 'INVITACION']
            res('USR-01', 'Admin crea usuario (INVITACIÓN PENDIENTE, sin contraseña en texto plano)', 'INVITACIÓN PENDIENTE' in row and len(inv) == 1 and 'demo' not in json.dumps(inv[0]).replace('okdespacho.demo', ''))
            # invitación: el usuario define su contraseña
            us = await ctx.new_page(); ps(us); await us.goto(URL + inv[0]['link']); await us.wait_for_timeout(800)
            await us.fill('#np1', 'Clave-Nueva-1'); await us.fill('#np2', 'Clave-Nueva-1'); await us.click('#npGo'); await us.wait_for_timeout(800)
            note = await us.inner_text('#authNote') if await us.locator('#authNote').count() else ''
            await us.fill('#loginEmail', 'prueba@okdespacho.demo'); await us.fill('#loginPass', 'Clave-Nueva-1'); await us.click('#loginBtn'); await us.wait_for_timeout(1500)
            res('USR-02', 'Invitación: define su contraseña, vuelve al acceso y entra (ACTIVO)', 'Contraseña actualizada' in note and await us.is_visible('#operario') and [u for u in (await us.evaluate(DB))['users'] if u['email'] == 'prueba@okdespacho.demo'][0]['status'] == 'ACTIVO')
            # olvidé mi contraseña (también cierra la sesión abierta)
            fp = await ctx.new_page(); ps(fp); await fp.goto(URL); await fp.wait_for_timeout(500)
            await fp.click('#forgotOpen'); await fp.fill('#forgotEmail', 'prueba@okdespacho.demo'); await fp.click('#forgotGo'); await fp.wait_for_timeout(400); m1 = await fp.inner_text('#forgotMsg')
            n_before = len((await fp.evaluate(DB))['authMails'])
            await fp.fill('#forgotEmail', 'noexiste@okdespacho.demo'); await fp.click('#forgotGo'); await fp.wait_for_timeout(400); m2 = await fp.inner_text('#forgotMsg')
            res('USR-05', 'La respuesta no revela si el email existe', m1 == m2 and 'Si el email está registrado' in m1 and len((await fp.evaluate(DB))['authMails']) == n_before)
            link = [m for m in (await fp.evaluate(DB))['authMails'] if m['to'] == 'prueba@okdespacho.demo' and m['type'] == 'RECUPERACION'][-1]['link']
            res('USR-03', '¿OLVIDASTE TU CONTRASEÑA? envía enlace de recuperación', link.startswith('#/nueva-contrasena?token='))
            await fp.goto(URL + link); await fp.wait_for_timeout(700); await fp.fill('#np1', 'Otra-Clave-2'); await fp.fill('#np2', 'Otra-Clave-2'); await fp.click('#npGo'); await fp.wait_for_timeout(700)
            await fp.fill('#loginEmail', 'prueba@okdespacho.demo'); await fp.fill('#loginPass', 'Clave-Nueva-1'); await fp.click('#loginBtn'); await fp.wait_for_timeout(700); old = await fp.inner_text('#authErr')
            await fp.fill('#loginPass', 'Otra-Clave-2'); await fp.click('#loginBtn'); await fp.wait_for_timeout(1500)
            await us.reload(); await us.wait_for_timeout(1200)
            res('USR-04', 'Nueva contraseña permite entrar; la anterior no; la sesión abierta anterior se cierra', 'incorrectos' in old and await fp.is_visible('#operario') and await us.is_visible('#loginEmail'))
            again = await tryit(fp, f'()=>{api}.completePasswordReset("x-12345678","{link.split("token=")[1]}")')
            res('USR-03b', 'El enlace de recuperación es de un solo uso', 'venció o ya se usó' in again)
            # restablecer desde Administración
            await ad.reload(); await ad.wait_for_timeout(1500)
            if not await ad.is_visible('#usersPanel'): await ad.click('#btnUsers'); await ad.wait_for_timeout(500)  # la URL #/usuarios reabre el módulo
            await ad.click('#usersPanel tr:has-text("Usuario Prueba") [data-act="reset_password"]'); await ad.wait_for_timeout(500)
            lk = [m for m in (await ad.evaluate(DB))['authMails'] if m['to'] == 'prueba@okdespacho.demo' and m['type'] == 'RECUPERACION'][-1]['link']
            rp = await ctx.new_page(); ps(rp); await rp.goto(URL + lk); await rp.wait_for_timeout(600); await rp.fill('#np1', 'Tercera-Clave-3'); await rp.fill('#np2', 'Tercera-Clave-3'); await rp.click('#npGo'); await rp.wait_for_timeout(600)
            await rp.fill('#loginEmail', 'prueba@okdespacho.demo'); await rp.fill('#loginPass', 'Tercera-Clave-3'); await rp.click('#loginBtn'); await rp.wait_for_timeout(1300)
            res('USR-06', 'RESTABLECER CONTRASEÑA desde Administración envía enlace y funciona (Admin no ve la contraseña)', lk != link and await rp.is_visible('#operario') and 'Tercera' not in await ad.inner_text('#usersPanel'))
            await rp.close(); await us.close(); await fp.close()
            # Despacho: solo módulos permitidos y 403 por URL
            de = await ctx.new_page(); ps(de); await login(de, 'despacho@okdespacho.demo')
            btns = [x for x in ('#btnUsers', '#btnReports', '#btnApprovals') if await de.locator(x).count()]
            await de.goto(URL + '#/usuarios'); await de.wait_for_timeout(1500); t403 = await de.inner_text('#usersPanel') if await de.is_visible('#usersPanel') else ''
            res('USR-07', 'Despacho ve Despacho general y no Usuarios/Informes/Aprobaciones', await de.is_visible('#operario') and btns == [])
            res('USR-11', 'URL directa a un módulo no autorizado → 403 ACCESO NO AUTORIZADO', '403 · ACCESO NO AUTORIZADO' in t403)
            # Transportista
            cr = await ctx.new_page(); ps(cr); await login(cr, 'cristian@okdespacho.demo')
            only = await cr.is_visible('#drv') and not await cr.is_visible('#operario') and await cr.locator('#noPanel .top .tbtn').count() == 1
            blocked = []
            for h in ('#/usuarios', '#/informes', '#/despacho', '#/aprobaciones', '#/configuracion'):
                await cr.evaluate(f'()=>{{location.hash="{h}"}}'); await cr.wait_for_timeout(500)
                blocked.append('403' in (await cr.inner_text('#usersPanel') if await cr.is_visible('#usersPanel') else '')); await cr.click('#b403') if await cr.locator('#b403').count() else None
            res('USR-08', 'Transportista ve solo MIS HOJAS (sin otros módulos) y las URLs prohibidas dan 403', only and all(blocked), str(blocked))
            r1 = await tryit(cr, f'()=>{api}.listUsers()'); r2 = await tryit(cr, f'()=>{api}.responsables("CT-ESTE")'); r3 = await tryit(cr, f'()=>{api}.reports("preview",{{sel:{{kind:"7D"}}}})')
            res('USR-12', 'API/RPC no autorizada bloqueada para el transportista', all(x != 'OK' for x in (r1, r2, r3)), r1[:50])
            gi = await ctx.new_page(); ps(gi); await login(gi, 'gabriel@okdespacho.demo')
            res('USR-09', 'Transportista interno: interfaz resumida (Mis hojas, sin módulos)', await gi.is_visible('#drv') and 'MIS HOJAS PUBLICADAS' in await gi.inner_text('#drv') and await gi.locator('#noPanel .top .tbtn').count() == 1)
            await gi.close()
            # Solo lectura
            await ad.evaluate(f'()=>{api}.action("create",{{full_name:"Lectura",email:"lectura@okdespacho.demo",role:"SOLO_LECTURA"}})')
            lec = await ctx.new_page(); ps(lec); await login(lec, 'lectura@okdespacho.demo')
            w = await tryit(lec, f'()=>{api}.publishRoute({{sheet_key:"x",carrier_id:"UCO",responsable_id:"u-cristian",stops:[{{client_name:"X",order_numbers:["1"],ready:true}}]}})')
            res('USR-10', 'Solo lectura: ve hojas sin acciones y no puede publicar/modificar', 'HOJAS · SOLO LECTURA' in await lec.inner_text('#drv') and await lec.locator('[data-o], #drvStart, #drvFin').count() == 0 and w != 'OK', w[:60])
            # Admin restringe módulo DESPACHO a Depósito
            await ad.click('#usersPanel tr[data-uid="u-deposito"] [data-act="edit"]'); await ad.uncheck('#editModal [data-mod="DESPACHO"]'); await ad.click('#editModal #umSave'); await ad.wait_for_timeout(500)
            await de.reload(); await de.wait_for_timeout(1500)
            w2 = await tryit(de, f'()=>{api}.reserveOrders(crypto.randomUUID(),["555"])')
            res('USR-13', 'Admin restringe módulos: sin DESPACHO no ve el panel y el servidor rechaza', not await de.is_visible('#operario') and w2 != 'OK', w2[:60])
            await ad.click('#usersPanel tr[data-uid="u-deposito"] [data-act="edit"]'); await ad.check('#editModal [data-mod="DESPACHO"]'); await ad.click('#editModal #umSave'); await ad.wait_for_timeout(500)
            # eliminar / archivar
            await ad.click('#usersPanel tr:has-text("Usuario Prueba") [data-act="remove"]'); await ad.wait_for_timeout(700)
            res('USR-14', 'Usuario de prueba sin historial (aceptó invitación, cambió contraseña) se ELIMINA definitivamente', await ad.locator('#usersPanel tr:has-text("Usuario Prueba")').count() == 0)
            k = await ad.evaluate('()=>crypto.randomUUID()')
            await de.evaluate(f'(k)=>{api}.publishRoute({{sheet_key:k,carrier_id:"CT-ESTE",responsable_id:"u-diego",stops:[{{client_name:"Z",zone:"ESTE",order_numbers:["555001"],ready:true}}]}})', k) if False else None
            await ad.click('#usersPanel tr[data-uid="u-cristian"] [data-act="remove"]'); await ad.wait_for_timeout(700)
            res('USR-15', 'Usuario con historial se ARCHIVA (no se borra)', 'ARCHIVADO' in await ad.inner_text('#usersPanel tr[data-uid="u-cristian"]'))
            r = await tryit(ad, f'()=>{api}.action("delete",{{user_id:"u-admin"}})')
            res('USR-16', 'El último Admin activo no se elimina', r != 'OK' and await ad.locator('#usersPanel tr[data-uid="u-admin"] [data-act="remove"]').count() == 0, r[:60])
            await ad.click('#usersPanel tr[data-uid="u-diego"] [data-act="disable"]'); await ad.wait_for_timeout(600)
            dz = await ctx.new_page(); ps(dz); await login(dz, 'diego@okdespacho.demo')
            res('USR-17', 'Usuario deshabilitado no entra con contraseña (passkey: PASSKEY-04 en E2E 2B.2)', 'sin acceso' in await dz.inner_text('#authErr'))
            res('E-ERR', 'Sin errores de consola', not errs, '; '.join(errs[:2]))
            await b.close()
    finally: server.terminate()
    for r_ in R: print(' | '.join(r_))
    print('TOTAL', sum(1 for x in R if x[2] == 'PASS'), 'PASS /', sum(1 for x in R if x[2] == 'FAIL'), 'FAIL')
asyncio.run(main())
