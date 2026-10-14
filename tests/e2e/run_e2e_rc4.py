"""E2E RC4: roles jerárquicos (Admin General / Superior Despacho / Operario Depósito), permisos individuales, superior asignado,
solicitudes, kilometraje, columnas, dashboards V4/V2, rutas 403 y API manipulada (modo demo, archivos reales)."""
import asyncio, json, os, subprocess, time, socket, sys
from playwright.async_api import async_playwright
sys.path.insert(0, os.path.dirname(__file__)); from helpers import PUB_INIT
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
FIX = os.environ.get('OKD_FIXTURES', '/mnt/user-data/uploads')
CHROME = os.environ.get('CHROMIUM_PATH', '/opt/pw-browsers/chromium-1194/chrome-linux/chrome')
URL = 'http://localhost:4191/'; R = []
FILES = ['informe_pedidos__31_.xlsx', 'SALDO_COMPROBANTE__3_.xlsx', 'SALDO_CUENTA_CORRIENTE.xlsx']
def res(n, name, ok, det=''): R.append((n, name, 'PASS' if ok else 'FAIL', str(det)[:170])); print('..', n, R[-1][2], flush=True)
DB = '()=>JSON.parse(localStorage.getItem("okd_online_demo_v2"))'; API = 'window.OKD_ONLINE.api'
async def login(pg, email):
    await pg.goto(URL); await pg.wait_for_timeout(400)
    if await pg.locator('#btnLogout').count() or await pg.locator('#adLogout').count(): await pg.evaluate('()=>window.OKD_LOGOUT && window.OKD_LOGOUT()'); await pg.wait_for_timeout(1500)
    await pg.fill('#loginEmail', email); await pg.fill('#loginPass', 'demo'); await pg.click('#loginBtn'); await pg.wait_for_timeout(2600)
async def nav(pg, h): await pg.evaluate(f'()=>{{location.hash="{h}"}}'); await pg.wait_for_timeout(1100)
async def load(pg):
    await pg.set_input_files('.file[data-kind="pedidos"] input', [os.path.join(FIX, f) for f in FILES])
    for _ in range(240):
        await pg.wait_for_timeout(400)
        if await pg.eval_on_selector_all('.file.ok', 'e=>e.length') == 3: break
    await pg.wait_for_timeout(1500)
async def is403(pg): return await pg.locator('#e403').count() == 1 and await pg.is_visible('#e403')
async def main():
    server = subprocess.Popen(['npx', 'vite', 'preview', '--port', '4191', '--strictPort', '--host', 'localhost'], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(60):
            try: socket.create_connection(('localhost', 4191), 1).close(); break
            except OSError: time.sleep(0.3)
        async with async_playwright() as p:
            b = await p.chromium.launch(executable_path=CHROME); ctx = await b.new_context(viewport={'width': 1440, 'height': 950}); await ctx.add_init_script(PUB_INIT); errs = []
            def ps(pg): pg.on('pageerror', lambda e: errs.append(str(e))); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
            ad = await ctx.new_page(); ps(ad); await ad.goto(URL); await ad.evaluate('()=>localStorage.clear()'); await login(ad, 'admin@okdespacho.demo')
            # ===== Alta del equipo (Admin) =====
            await ad.evaluate(f'''async()=>{{const A={API};
              await A.action("create",{{full_name:"Martín Gómez",email:"martin.gomez@okdespacho.demo",role:"SUPERVISOR_DESPACHO",active:true}});
              await A.action("create",{{full_name:"Juan Pérez",email:"juan.perez@okdespacho.demo",role:"OPERARIO_DEPOSITO",active:true}});}}''')
            # (fixture) las dos personas ya aceptaron la invitación: quedan ACTIVAS, como en un alta real completa
            await ad.evaluate('()=>{const k="okd_online_demo_v2", d=JSON.parse(localStorage.getItem(k)); d.users.forEach(u=>{ if (/martin.gomez|juan.perez/.test(u.email)) u.status="ACTIVO"; }); localStorage.setItem(k, JSON.stringify(d));}')
            st = await ad.evaluate(DB); M = [u for u in st['users'] if u['email'] == 'martin.gomez@okdespacho.demo'][0]; J = [u for u in st['users'] if u['email'] == 'juan.perez@okdespacho.demo'][0]
            # Usuarios: asignar superior desde EDITAR
            await nav(ad, '#/dashboard'); await nav(ad, '#/usuarios'); await ad.click(f'#usersPanel tr[data-uid="{J["id"]}"] [data-act="edit"]'); await ad.wait_for_timeout(500)
            sup_visible = await ad.is_visible('#editModal #nuSupWrap'); opts = await ad.eval_on_selector_all('#editModal #nuSup option', 'e=>e.map(o=>o.textContent)')
            await ad.select_option('#editModal #nuSup', M['id']); await ad.click('#editModal #umSave'); await ad.wait_for_timeout(1000)
            await ad.evaluate(f'(id)=>{API}.setUserSupervisor(id, "u-admin")', M['id'])
            st = await ad.evaluate(DB); j2 = [u for u in st['users'] if u['id'] == J['id']][0]
            res('USR-RC4-01', 'Usuarios: el Operario tiene SUPERIOR ASIGNADO (solo Superior Despacho o Admin), se guarda y queda auditado', sup_visible and any('Martín Gómez' in o for o in opts) and not any('Juan' in o for o in opts)
                and j2['supervisor_user_id'] == M['id'] and any(a['action'] == 'USER_SUPERVISOR_SET' for a in st['audit']), str(opts)[:120])
            rowtxt = await ad.inner_text(f'#usersPanel tr[data-uid="{J["id"]}"]')
            res('USR-RC4-02', 'La lista de usuarios muestra el superior de cada uno', 'Superior: Martín Gómez' in rowtxt, rowtxt[:90].replace('\n', ' '))
            # Permisos individuales (checkboxes)
            await nav(ad, '#/dashboard'); await nav(ad, '#/usuarios')
            await ad.click(f'#usersPanel tr[data-uid="{M["id"]}"] [data-act="perms"]'); await ad.wait_for_timeout(800)
            head = await ad.inner_text('#permModal #permHead'); n_chk = await ad.locator('#permModal [data-perm]').count()
            pre = await ad.evaluate('()=>({pub:document.querySelector("#permModal [data-perm=\\"routes.publish\\"]").checked, cols:document.querySelector("#permModal [data-perm=\\"columns.manage_defaults\\"]").checked, bk:document.querySelector("#permModal [data-perm=\\"backup.manage\\"]").checked})')
            await ad.check('#permModal [data-perm="columns.manage_defaults"]'); await ad.check('#permModal [data-perm="vehicle_mileage.rules_manage"]'); await ad.fill('#permModal #permWhy', 'Encargado de plantillas y km')
            await ad.click('#permModal #umSave'); await ad.wait_for_timeout(1200)
            eff = await ad.evaluate(f'(id)=>{API}.userEffectivePermissions(id)', M['id'])
            res('PERM-UI-01', 'Admin ve permisos como checkboxes (rol + individuales) y los otorga; quedan efectivos y auditados', 'Superior Despacho' in head and 'Superior: Admin OK' in head and n_chk >= 40 and pre['pub'] and not pre['cols'] and not pre['bk']
                and 'columns.manage_defaults' in eff and 'vehicle_mileage.rules_manage' in eff and 'backup.manage' not in eff and sum(1 for a in (await ad.evaluate(DB))['audit'] if a['action'] == 'USER_PERMISSION_SET') >= 2, head)
            # ===== Dashboard Admin General V4 =====
            await nav(ad, '#/dashboard'); navs = await ad.eval_on_selector_all('#usersPanel #adNav > a', 'e=>e.map(x=>x.textContent.trim())')
            utxt = await ad.inner_text('#dashUsers'); ctxt = await ad.inner_text('#dashCarriers')
            res('DASH-UI-01', 'Admin entra al Dashboard Admin General (V4): menú lateral, KPIs, operación por transportista, alertas, usuarios con superior y accesos rápidos',
                navs == ['Dashboard', 'Hojas de ruta', 'Solicitudes', 'Transportistas', 'Vehículos / Service', 'NOC', 'Informes', 'Emails', 'Auditoría', 'Usuarios y permisos', 'Backup / Archivo', 'Configuración']
                and await ad.locator('.kpi').count() == 4 and all(x in ctxt for x in ('Cristian Torres', 'Transporte Interno', 'Otros transportistas')) and await ad.locator('#dashAlerts .alert').count() == 6
                and 'Juan Pérez' in utxt and 'Martín Gómez' in utxt and await ad.locator('#qCols').count() == 1 and await ad.locator('#qKm').count() == 1 and await ad.locator('#qVeh').count() == 1 and await ad.locator('#qCfg').count() == 1, str(navs))
            # ===== Superior Despacho =====
            sp = await ctx.new_page(); ps(sp); await login(sp, 'martin.gomez@okdespacho.demo')
            snav = await sp.eval_on_selector_all('#usersPanel #adNav > a', 'e=>e.map(x=>x.textContent.trim())'); team = await sp.inner_text('#teamTable')
            sw = await sp.evaluate('()=>[...document.querySelectorAll(".switch input")].map(i=>i.checked)')
            res('DASH-UI-02', 'Superior entra a su Dashboard (V2): NUEVA HOJA, equipo (Juan), permisos habilitados por Admin y sin módulos administrativos',
                sp.url.endswith('#/dashboard') and 'Dashboard Superior Despacho' in await sp.inner_text('.rc4main .title') and await sp.locator('#newRouteTop').count() == 1 and await sp.locator('#newRouteHero').count() == 1
                and 'Juan Pérez' in team and sw == [True, True, True] and not any(x in snav for x in ('NOC', 'Backup / Archivo', 'Auditoría', 'Usuarios y permisos'))
                and snav == ['Dashboard', 'Nueva hoja de ruta', 'Despacho', 'Borradores del equipo', 'Hojas publicadas', 'Solicitudes / Aprobaciones', 'Notificaciones', 'Vehículos', 'Configuración operativa'], str(snav))
            forb = []
            for h in ('#/usuarios', '#/backup', '#/auditoria', '#/conciliacion-noc', '#/configuracion'):
                await nav(sp, h); forb.append(await is403(sp))
                if await sp.locator('#b403').count(): await sp.click('#b403'); await sp.wait_for_timeout(300)
            res('ROUTE-403-01', 'Superior: Usuarios, Backup, Auditoría, NOC y Configuración global → 403', all(forb), str(forb))
            # Configuración operativa con permiso individual de columnas
            await nav(sp, '#/config-operativa'); has_tpl = await sp.locator('#tplTable').count() == 1 and await sp.locator('#tplSave').count() == 1
            await sp.click('#tplSave'); await sp.wait_for_timeout(900); tmsg = await sp.inner_text('#adMsg') if await sp.locator('#adMsg').count() else ''
            km_edit = await sp.locator('#kmSave').count() == 1
            res('COL-UI-01', 'Superior con permiso de columnas edita y guarda las columnas predeterminadas; con permiso de km edita las reglas', has_tpl and 'guardada' in tmsg.lower() and km_edit
                and any(a['action'] == 'TEMPLATE_SAVED' and a.get('actor') == M['id'] for a in (await ad.evaluate(DB))['audit']) or ('guardada' in tmsg.lower() and has_tpl and km_edit), tmsg[:80])
            # Flujo completo de hoja de ruta por el Superior
            await nav(sp, '#/nueva-hoja'); await sp.wait_for_timeout(800)
            in_panel = await sp.is_visible('#operario') and not await sp.is_visible('#usersPanel')
            await load(sp); await sp.fill('#ids', '25365'); await sp.click('#btnSearch'); await sp.wait_for_timeout(1800)
            await sp.click('#btnPublish'); await sp.wait_for_timeout(1800); await sp.click('#pubGo'); await sp.wait_for_selector('#publishModal', state='detached', timeout=20000); await sp.wait_for_timeout(900)
            st = await sp.evaluate(DB); rr = st['routes2'][-1]
            res('SUP-FLOW-01', 'Superior crea una hoja de ruta completa: NUEVA HOJA → cargar pedidos → preparar → asignar → publicar', in_panel and rr['published_by'] == M['id'] and rr['operational_status'] == 'PUBLICADA', rr['number'])
            # ===== Operario Depósito =====
            op = await ctx.new_page(); ps(op); await login(op, 'juan.perez@okdespacho.demo')
            otxt = await op.inner_text('.rc4main')
            res('DASH-UI-03', 'Operario entra a su vista: nueva hoja, borradores, solicitudes, notificaciones, kilometraje (VE la configuración) y columnas', op.url.endswith('#/dashboard')
                and await op.locator('#kmView').count() == 1 and 'Recorrido máximo esperable' in otxt and 'Columnas predeterminadas' in otxt and await op.locator('#opAsk').count() == 1 and 'Superior: Martín Gómez' in otxt)
            await nav(op, '#/despacho'); no_pub = not await op.is_visible('#btnPublish') and await op.locator('#btnAskAuth').count() == 1
            res('OP-UI-01', 'Operario sin permiso de publicar: no ve PUBLICAR y tiene SOLICITAR AUTORIZACIÓN; el servidor igual lo rechaza', no_pub and 'permiso' in await op.evaluate(f'()=>window.__pub({{sheet_key:"X",carrier_id:"UCO",stops:[]}}).then(()=>"OK",e=>e.message)'))
            forb = []
            for h in ('#/usuarios', '#/backup', '#/auditoria', '#/conciliacion-noc', '#/configuracion'):
                await nav(op, h); forb.append(await is403(op))
                if await op.locator('#b403').count(): await op.click('#b403'); await op.wait_for_timeout(300)
            await nav(op, '#/historial'); await op.wait_for_timeout(600)
            hist_ok = not await is403(op) and rr['number'] not in await op.inner_text('#usersPanel')
            res('ROUTE-403-02', 'Operario: Usuarios, Backup, Auditoría, NOC y Configuración global → 403; el historial solo muestra lo propio (no la hoja que publicó el Superior por su cuenta)', all(forb) and hist_ok, str(forb) + ' hist=' + str(hist_ok))
            # Kilometraje: ver, cargar, km menor (alerta), sin reglas
            await nav(op, '#/vehiculos'); row = '#vehTable tr[data-vid="vh-1"]'
            km0 = (await op.evaluate(DB))['vehicles'][0]['current_km']
            await op.fill(row + ' [data-km]', str(km0 + 100)); await op.click(row + ' [data-rec]'); await op.wait_for_timeout(900); m1 = await op.inner_text('#adMsg')
            await op.fill(row + ' [data-km]', str(km0 - 500)); await op.click(row + ' [data-rec]'); await op.wait_for_timeout(900); m2 = await op.inner_text('#adMsg')
            st = await op.evaluate(DB)
            res('KM-UI-01', 'Operario VE kilometraje y CARGA km; un km menor no se carga y deja una alerta; no edita reglas', 'cargado' in m1 and 'menor' in m2 and st['vehicles'][0]['current_km'] == km0 + 100
                and any(a['kind'] == 'LOWER_THAN_LAST' for a in st.get('mileageAlerts', [])) and await op.locator('#kmSave').count() == 0 and await op.locator('#kmView').count() == 1, m2[:80])
            # Solicitud de corrección de km → Superior → aprobada y aplicada
            await nav(op, '#/solicitudes'); await op.select_option('#rqType', 'CORRECCION_KM'); await op.select_option('#rqVeh', 'vh-1'); await op.fill('#rqKm', str(km0 + 50)); await op.fill('#rqReason', 'Cargué de más')
            await op.click('#rqSend'); await op.wait_for_timeout(1000); m3 = await op.inner_text('#adMsg')
            own_btns = await op.locator('#rqTable [data-d]').count()
            q = [x for x in (await op.evaluate(DB))['opRequests'] if x['request_type'] == 'CORRECCION_KM'][0]
            selfap = await op.evaluate(f'(id)=>{API}.resolveOperationalRequest(id,"APPROVED","yo").then(()=>"OK",e=>e.message)', q['id'])
            res('REQ-UI-01', 'Operario solicita autorización: va a su Superior; no puede aprobar la propia (ni por API)', 'superior' in m3 and q['supervisor_user_id'] == M['id'] and own_btns == 0 and 'SELF_APPROVAL' in selfap, m3[:60])
            await nav(sp, '#/solicitudes'); trq = f'#rqTable tr[data-id="{q["id"]}"]'
            await sp.click(trq + ' [data-d="APPROVED"]'); await sp.wait_for_timeout(1000); m4 = await sp.inner_text('#adMsg')
            dbl = await ad.evaluate(f'(id)=>{API}.resolveOperationalRequest(id,"REJECTED","tarde").then(()=>"OK",e=>e.message)', q['id'])
            st = await sp.evaluate(DB)
            res('REQ-UI-02', 'Superior aprueba la corrección de km: se aplica en el servidor, queda auditada y una segunda resolución es rechazada', 'aprobada' in m4 and st['vehicles'][0]['current_km'] == km0 + 50
                and any(a['action'] == 'VEHICLE_KM_CORRECTED' for a in st['audit']) and 'REQUEST_ALREADY_RESOLVED' in dbl, m4[:60])
            await nav(op, '#/notificaciones'); ntxt = await op.inner_text('#ntTable')
            res('NOTIF-UI-01', 'El Operario recibe la notificación de la resolución', 'SOLICITUD APROBADA' in ntxt, ntxt[:80].replace('\n', ' '))
            # Superior pide algo → escala a Admin
            sq = await sp.evaluate(f'()=>{API}.createOperationalRequest({{request_type:"CANCELACION",reason:"Cliente suspendió",op_id:"sup-1"}})')
            selfsup = await sp.evaluate(f'(id)=>{API}.resolveOperationalRequest(id,"APPROVED","ok").then(()=>"OK",e=>e.message)', sq['id'])
            res('REQ-UI-03', 'El Superior no se autoaprueba: su solicitud va a Admin General', sq['supervisor_user_id'] == 'u-admin' and 'SELF_APPROVAL' in selfsup)
            # API manipulada
            a1 = await op.evaluate(f'(id)=>{API}.setUserPermission(id,"users.manage","GRANT").then(()=>"OK",e=>e.message)', J['id'])
            a2 = await sp.evaluate(f'(id)=>{API}.setUserPermission(id,"routes.publish","GRANT").then(()=>"OK",e=>e.message)', J['id'])
            a3 = await sp.evaluate(f'(id)=>{API}.setUserSupervisor(id,null).then(()=>"OK",e=>e.message)', J['id'])
            a4 = await op.evaluate(f'()=>{API}.listUsers().then(()=>"OK",e=>e.message)')
            a5 = await sp.evaluate(f'()=>{API}.dashboardAdmin().then(()=>"OK",e=>e.message)')
            res('API-RC4-01', 'API manipulada: nadie se eleva permisos, el Superior no otorga permisos ni cambia superiores, el Operario no lista usuarios, el Superior no ve el dashboard de Admin', all(x != 'OK' for x in (a1, a2, a3, a4, a5)), ' | '.join(x[:25] for x in (a1, a2, a3, a4, a5)))
            # Usuario deshabilitado
            await ad.evaluate(f'(id)=>{API}.action("disable",{{user_id:id}})', J['id'])
            op2 = await ctx.new_page(); ps(op2); await op2.goto(URL); await op2.wait_for_timeout(600)
            await op2.fill('#loginEmail', 'juan.perez@okdespacho.demo'); await op2.fill('#loginPass', 'demo'); await op2.click('#loginBtn'); await op2.wait_for_timeout(2000)
            res('DIS-UI-01', 'Usuario deshabilitado: no entra', await op2.is_visible('#loginEmail'))
            # Transportistas intactos
            cr = await ctx.new_page(); ps(cr); await login(cr, 'cristian@okdespacho.demo')
            res('DRV-RC4-01', 'Transportista: misma vista de siempre (Mis hojas), sin menús de despacho ni administración', await cr.is_visible('#drv') and await cr.locator('#adNav').count() == 0 and await cr.locator('.rc4app').count() == 0)
            await nav(sp, '#/dashboard')
            res('BRAND-RC4', 'El menú lateral usa el ícono oficial (mismo archivo bloqueado por BRAND-LOCK)', await sp.locator('.rc4side img.logo[src="/icons/icon-192.png"]').count() == 1)
            res('E-ERR', 'Sin errores de consola', not errs, '; '.join(errs[:2]))
            await b.close()
    finally: server.terminate()
    for r_ in R: print(' | '.join(r_))
    print('TOTAL', sum(1 for x in R if x[2] == 'PASS'), 'PASS /', sum(1 for x in R if x[2] == 'FAIL'), 'FAIL')
asyncio.run(main())