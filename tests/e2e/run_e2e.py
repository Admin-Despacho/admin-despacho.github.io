"""Pruebas E2E de la Fase 1 en navegador real (Chromium), sobre el BUILD de producción servido con `vite preview`.
Corren en MODO DEMO (sin proyecto Supabase): validan pantallas, flujo y reglas del cliente.
La seguridad del servidor (RLS, Edge Function) se prueba aparte: tests/sql y supabase/functions.

Uso: npm run build && python3 tests/e2e/run_e2e.py
Variables: OKD_FIXTURES (carpeta con los 3 Excel reales), CHROMIUM_PATH, OKD_OFFLINE_HTML (v15 para comparar).
"""
import asyncio, json, os, subprocess, sys, time, socket
from playwright.async_api import async_playwright

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
FIX = os.environ.get('OKD_FIXTURES', '/mnt/user-data/uploads')
CHROME = os.environ.get('CHROMIUM_PATH', '/opt/pw-browsers/chromium-1194/chrome-linux/chrome')
OFFLINE = os.environ.get('OKD_OFFLINE_HTML', '')
OUT = os.path.join(ROOT, 'tests', 'e2e', 'out'); os.makedirs(OUT, exist_ok=True)
URL = 'http://127.0.0.1:4173/'
R = []
def res(n, name, ok, det=''): R.append((n, name, 'PASS' if ok else 'FAIL', str(det)[:160]))
def skip(n, name, why): R.append((n, name, 'NOT RUN', why))

def wait_port(port, t=30):
    end = time.time() + t
    while time.time() < end:
        try: socket.create_connection(('127.0.0.1', port), 1).close(); return True
        except OSError: time.sleep(0.3)
    return False

async def login(pg, email, pw='demo'):
    await pg.fill('#loginEmail', email); await pg.fill('#loginPass', pw); await pg.click('#loginBtn'); await pg.wait_for_timeout(600)

async def main():
    srv = subprocess.Popen(['npx', 'vite', 'preview', '--port', '4173', '--strictPort', '--host', '127.0.0.1'], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        if not wait_port(4173): print('No levantó vite preview'); sys.exit(2)
        async with async_playwright() as p:
            b = await p.chromium.launch(executable_path=CHROME)
            ctx = await b.new_context(viewport={'width': 1440, 'height': 950}, accept_downloads=True)
            pg = await ctx.new_page(); errs = []
            pg.on('pageerror', lambda e: errs.append(str(e)))
            pg.on('console', lambda m: errs.append(m.text) if m.type == 'error' and 'favicon' not in m.text else None)
            async def on_dialog(d):
                await (d.accept('ELIMINAR') if d.type == 'prompt' else d.accept())
            pg.on('dialog', lambda d: asyncio.ensure_future(on_dialog(d)))
            await pg.goto(URL); await pg.evaluate('()=>localStorage.clear()'); await pg.reload(); await pg.wait_for_timeout(500)

            res('E01', 'Pantalla de acceso con la estética offline y aviso de MODO DEMO', await pg.is_visible('#auth .top') and await pg.is_visible('#demoBanner') and await pg.is_visible('#loginEmail'))
            await login(pg, 'admin@okdespacho.demo', 'mal')
            res('E02', 'Contraseña incorrecta no entra', 'incorrectos' in await pg.inner_text('#authErr'))
            await login(pg, 'lucas@okdespacho.demo')
            res('E03', 'Usuario DESHABILITADO no entra', 'sin acceso' in await pg.inner_text('#authErr'))

            await login(pg, 'admin@okdespacho.demo'); await pg.wait_for_timeout(1500)
            op = await pg.is_visible('#operario') and await pg.is_visible('#operario .top')
            hdr = await pg.inner_text('#operario .top')
            res('E04', 'Admin entra al panel del Operario (v15) con usuario, Usuarios y Cerrar sesión', op and 'Administración' in hdr and await pg.is_visible('#btnUsers') and await pg.is_visible('#btnLogout'), hdr.replace('\n', ' · '))
            v15 = await pg.evaluate('()=>!!(window.OKD && window.OKD.RouteStore)')
            res('E05', 'La lógica v15 se carga intacta (motor, hoja, exportación)', v15 and await pg.is_visible('#btnSearch') and await pg.is_visible('#btnExport') and await pg.is_visible('#btnPdf'))
            await pg.screenshot(path=os.path.join(OUT, 'online_operario.png'))

            await (pg.click('#btnUsers') if not await pg.is_visible('#usersPanel') else pg.wait_for_timeout(1)); await pg.wait_for_timeout(500)
            rows = await pg.eval_on_selector_all('#usersPanel tbody tr', 'e=>e.map(r=>r.innerText)')
            heads = await pg.eval_on_selector_all('#usersPanel thead th', 'e=>e.map(t=>t.innerText)')
            res('E06', 'USUARIOS lista nombre, email, teléfono, rol, transportista, estado, último acceso y creación', len(rows) == 8 and heads[:8] == ['NOMBRE', 'EMAIL', 'TELÉFONO', 'ROL', 'TRANSPORTISTA / EMPRESA', 'ESTADO', 'ÚLTIMO ACCESO', 'CREADO'], str(heads))
            await pg.click('#usersPanel tr[data-uid="u-admin"] [data-act="edit"]'); await pg.wait_for_timeout(200)
            res('E07', 'El propio rol no se puede cambiar (control bloqueado en EDITAR)', await pg.get_attribute('#editModal #nuRole', 'disabled') is not None)
            await pg.click('#editModal #umCancel')
            await pg.screenshot(path=os.path.join(OUT, 'online_usuarios.png'))

            # nuevo transportista sin carrier → error; con carrier → creado
            await pg.click('#upNew'); await pg.fill('#nuName', 'Mario Paz'); await pg.fill('#nuEmail', 'mario@okdespacho.demo'); await pg.select_option('#nuRole', 'TRANSPORTISTA')
            await pg.click('#umSave'); await pg.wait_for_timeout(200)
            e = await pg.inner_text('#umErr')
            res('E08', 'Transportista sin carrier vinculado no se crea', 'carrier' in e, e)
            await pg.check('.umodal .carr input[value="CT-ESTE"]'); await pg.click('#umSave'); await pg.wait_for_timeout(500)
            row = await pg.inner_text('#usersPanel tr:has-text("Mario Paz")')
            res('E09', 'NUEVO USUARIO queda con INVITACIÓN PENDIENTE y su carrier', 'INVITACIÓN PENDIENTE' in row and 'CRISTIAN TORRES - ESTE' in row, row.replace('\n', ' | '))
            # cambio de rol (desde EDITAR)
            await pg.click('#usersPanel tr[data-uid="u-diego"] [data-act="edit"]'); await pg.select_option('#editModal #nuRole', 'TRANSPORTISTA_INTERNO'); await pg.click('#editModal #umSave'); await pg.wait_for_timeout(500)
            row = await pg.inner_text('#usersPanel tr[data-uid="u-diego"]')
            res('E10', 'Cambiar rol desde EDITAR se aplica y se informa', 'Transportista interno' in row and 'actualizado' in await pg.inner_text('#upMsg'))
            # deshabilitar / reactivar (usuario sin hojas activas)
            await pg.click('#usersPanel tr[data-uid="u-gabriel2"] [data-act="disable"]'); await pg.wait_for_timeout(500)
            st1 = await pg.inner_text('#usersPanel tr[data-uid="u-gabriel2"] .ust')
            await pg.click('#usersPanel tr[data-uid="u-gabriel2"] [data-act="reactivate"]'); await pg.wait_for_timeout(500)
            st2 = await pg.inner_text('#usersPanel tr[data-uid="u-gabriel2"] .ust')
            res('E11', 'DESHABILITAR y REACTIVAR', st1 == 'DESHABILITADO' and st2 == 'ACTIVO', st1 + ' → ' + st2)
            await pg.click('#usersPanel tr[data-uid="u-cristian"] [data-act="remove"]'); await pg.wait_for_timeout(500)
            row = await pg.inner_text('#usersPanel tr[data-uid="u-cristian"]')
            res('E12', 'Usuario con historial se ARCHIVA (no se borra) y conserva su nombre', 'ARCHIVADO' in row and 'Cristian Torres' in row)
            uid = await pg.get_attribute('#usersPanel tr:has-text("Mario Paz")', 'data-uid')
            await pg.click(f'#usersPanel tr[data-uid="{uid}"] [data-act="remove"]'); await pg.wait_for_timeout(500)
            res('E13', 'Usuario sin historial se ELIMINA DEFINITIVAMENTE con confirmación fuerte', await pg.locator('#usersPanel tr:has-text("Mario Paz")').count() == 0)

            # ===================== Fase 1.1 =====================
            api = 'window.OKD_ONLINE.api'
            await pg.click('#usersPanel tr[data-uid="u-gabriel"] [data-act="reset_password"]'); await pg.wait_for_timeout(400)
            m = await pg.inner_text('#upMsg'); a = await pg.evaluate(f'()=>{api}.auditLog().at(-1)')
            res('F1.1-01', 'Admin solicita restablecer contraseña (link al email, auditado)', 'gabriel@okdespacho.demo' in m and a['action'] == 'PASSWORD_RESET_REQUESTED' and a['actor_id'] == 'u-admin' and a['target_id'] == 'u-gabriel' and a['after']['result'] == 'ENVIADO', m)
            page_txt = await pg.inner_text('#usersPanel')
            res('F1.1-02', 'Restablecer no muestra ninguna contraseña (ni actual ni nueva)', 'demo' not in m.lower().replace('okdespacho.demo', '') and 'contraseña actual' not in page_txt.lower() and not any(k in json.dumps(a) for k in ('password', 'token')), m)
            # búsqueda y filtros
            await pg.fill('#ufSearch', 'gabr'); await pg.wait_for_timeout(150)
            names = await pg.eval_on_selector_all('#upBody tr', 'e=>e.map(r=>r.querySelector("td b")&&r.querySelector("td b").innerText)')
            res('F1.1-17', 'Buscar usuario por nombre', names == ['Gabriel Figueroa'], str(names))
            await pg.fill('#ufSearch', ''); await pg.select_option('#ufRole', 'TRANSPORTISTA_INTERNO'); await pg.wait_for_timeout(150)
            roles = await pg.eval_on_selector_all('#upBody tr td:nth-child(4)', 'e=>[...new Set(e.map(t=>t.innerText))]')
            res('F1.1-18', 'Filtrar por rol', roles == ['Transportista interno'], str(roles))
            await pg.select_option('#ufRole', ''); await pg.select_option('#ufStatus', 'DESHABILITADO'); await pg.wait_for_timeout(150)
            sts = await pg.eval_on_selector_all('#upBody tr .ust', 'e=>[...new Set(e.map(t=>t.innerText))]')
            res('F1.1-19', 'Filtrar por estado', sts == ['DESHABILITADO'], str(sts))
            await pg.select_option('#ufStatus', ''); await pg.select_option('#ufCarrier', 'CT-ALR'); await pg.wait_for_timeout(150)
            cn = await pg.eval_on_selector_all('#upBody tr td:nth-child(5)', 'e=>e.map(t=>t.innerText)')
            res('F1.1-19b', 'Filtrar por transportista/carrier', len(cn) >= 1 and all('ALREDEDORES' in x for x in cn), str(cn))
            await pg.select_option('#ufCarrier', '')
            # editar nombre, teléfono y email
            await pg.click('#usersPanel tr[data-uid="u-gabriel2"] [data-act="edit"]')
            await pg.fill('#editModal #nuName', 'Martín A. Sosa'); await pg.fill('#editModal #nuPhone', '261 555-0303'); await pg.fill('#editModal #nuEmail', 'martin.sosa@okdespacho.demo')
            await pg.click('#editModal #umSave'); await pg.wait_for_timeout(400)
            row = await pg.inner_text('#usersPanel tr[data-uid="u-gabriel2"]'); a = await pg.evaluate(f'()=>{api}.auditLog().at(-1)')
            res('F1.1-05', 'Admin edita nombre y teléfono (auditoría antes/después)', 'Martín A. Sosa' in row and '261 555-0303' in row and a['action'] == 'USER_UPDATED' and a['before']['full_name'] == 'Martín Sosa', row.replace('\n', ' | '))
            res('F1.1-06', 'Admin cambia el email (es el mismo para entrar y en el perfil)', 'martin.sosa@okdespacho.demo' in row)
            # rol TRANSPORTISTA exige carrier
            await pg.click('#usersPanel tr[data-uid="u-deposito"] [data-act="edit"]'); await pg.select_option('#editModal #nuRole', 'TRANSPORTISTA')
            await pg.click('#editModal #umSave'); await pg.wait_for_timeout(300)
            e = await pg.inner_text('#editModal #umErr')
            res('F1.1-07', 'DESPACHO → TRANSPORTISTA sin carrier: RECHAZADO', 'transportista/empresa' in e.lower() or 'carrier' in e.lower(), e)
            await pg.check('#editModal .carr input[value="CT-ESTE"]'); await pg.click('#editModal #umSave'); await pg.wait_for_timeout(400)
            row = await pg.inner_text('#usersPanel tr[data-uid="u-deposito"]')
            res('F1.1-08', 'DESPACHO → TRANSPORTISTA con CT-ESTE: ACEPTADO', 'Transportista' in row and 'CRISTIAN TORRES - ESTE' in row, row.replace('\n', ' | '))
            await pg.click('#usersPanel tr[data-uid="u-deposito"] [data-act="edit"]'); await pg.select_option('#editModal #nuRole', 'DESPACHO'); await pg.click('#editModal #umSave'); await pg.wait_for_timeout(400)
            # hojas activas
            await pg.click('#usersPanel tr[data-uid="u-gabriel"] [data-act="remove"]'); await pg.wait_for_timeout(500)
            dlg = await pg.locator('#activeRoutesModal').count() and await pg.inner_text('#activeRoutesModal')
            st = await pg.inner_text('#usersPanel tr[data-uid="u-gabriel"] .ust')
            res('F1.1-14', 'Usuario con hoja activa no se ARCHIVA en silencio (aviso con la hoja)', bool(dlg) and 'ESTE USUARIO TIENE HOJAS ACTIVAS' in dlg and '03-02' in dlg and st == 'ACTIVO', (dlg or '').replace('\n', ' | ')[:120])
            await pg.click('#activeRoutesModal #umCancel')
            await pg.click('#usersPanel tr[data-uid="u-gabriel"] [data-act="disable"]'); await pg.wait_for_timeout(500)
            dlg = await pg.locator('#activeRoutesModal').count() and await pg.inner_text('#activeRoutesModal')
            res('F1.1-13', 'Usuario con hoja activa no se DESHABILITA en silencio (aviso con la hoja)', bool(dlg) and '03-02' in dlg and await pg.inner_text('#usersPanel tr[data-uid="u-gabriel"] .ust') == 'ACTIVO')
            opts = await pg.eval_on_selector_all('#activeRoutesModal #arTo option', 'e=>e.map(o=>o.textContent)')
            await pg.click('#activeRoutesModal #umSave'); await pg.wait_for_timeout(500)
            st = await pg.inner_text('#usersPanel tr[data-uid="u-gabriel"] .ust'); m = await pg.inner_text('#upMsg')
            res('F1.1-13b', 'Reasignar a un usuario compatible y recién ahí deshabilitar', st == 'DESHABILITADO' and 'reasignadas' in m and all('Cristian' not in o for o in opts), str(opts) + ' · ' + m)
            await pg.click('#usersPanel tr[data-uid="u-gabriel"] [data-act="reactivate"]'); await pg.wait_for_timeout(400)
            # invitaciones
            n0 = await pg.locator('#upBody tr').count()
            await pg.click('#usersPanel tr[data-uid="u-invitada"] [data-act="resend_invite"]'); await pg.wait_for_timeout(400)
            res('F1.1-15', 'Reenviar invitación no crea otro usuario', 'reenviada' in await pg.inner_text('#upMsg') and await pg.locator('#upBody tr').count() == n0 and await pg.locator('#upBody tr:has-text("paula@okdespacho.demo")').count() == 1)
            await pg.click('#usersPanel tr[data-uid="u-invitada"] [data-act="cancel_invite"]'); await pg.wait_for_timeout(400)
            res('F1.1-16a', 'Cancelar invitación deja el usuario DESHABILITADO', await pg.inner_text('#usersPanel tr[data-uid="u-invitada"] .ust') == 'DESHABILITADO')
            # cerrar sesiones abiertas (sobre el propio admin, para verlo en este navegador)
            await pg.click('#usersPanel tr[data-uid="u-admin"] [data-act="revoke_sessions"]'); await pg.wait_for_timeout(1500)
            note = await pg.locator('#authNote').count() and await pg.inner_text('#authNote')
            a = await pg.evaluate(f'()=>{api}.auditLog().at(-1)')
            res('F1.1-03', 'Cerrar sesiones abiertas: auditado y la sesión abierta deja de valer', a['action'] == 'SESSIONS_REVOKED' and await pg.is_visible('#loginEmail') and bool(note) and 'cerrada por Administración' in note, note or '')
            await login(pg, 'paula@okdespacho.demo')
            res('F1.1-16', 'Cancelar invitación bloquea el acceso', 'sin acceso' in await pg.inner_text('#authErr'))
            # último acceso real
            await login(pg, 'admin@okdespacho.demo'); await pg.wait_for_timeout(1200)
            await (pg.click('#btnUsers') if not await pg.is_visible('#usersPanel') else pg.wait_for_timeout(1)); await pg.wait_for_timeout(400)
            la = (await pg.inner_text('#usersPanel tr[data-uid="u-admin"] td:nth-child(7)')).strip()
            res('F1.1-04', 'ÚLTIMO ACCESO se actualiza al iniciar sesión', la not in ('', '—'), la)
            await pg.click('#upClose'); await pg.wait_for_timeout(200)

            # ===================== Fase 2A: Informe comercial Cristian Torres (modo demo) =====================
            await (pg.click('#btnReports') if not await pg.is_visible('#usersPanel') else pg.wait_for_timeout(1)); await pg.wait_for_timeout(2500)
            titles = await pg.eval_on_selector_all('#rpBody .rp-step h2', 'e=>e.map(h=>h.innerText.replace(/\\s+/g," ").trim())')
            exp_order = ['PERÍODO A ANALIZAR', 'CUANTIFICACIÓN POR ZONA · ENVÍOS + INGRESOS', '¿EL TRANSPORTE SE PAGA SOLO?', 'MEJORES CLIENTES', 'CLIENTES A RECUPERAR', 'ZONAS A REFORZAR']
            res('RPT-UI-01', 'Orden de pantalla aprobado (1 a 6)', [t.split(' ', 1)[1].split('Ingreso solo')[0].strip() for t in titles] == exp_order, ' | '.join(titles))
            zones = await pg.eval_on_selector_all('.rp-zrow:not(.head) b', 'e=>e.map(x=>x.innerText)')
            body_txt = await pg.inner_text('#rpBody')
            res('RPT-UI-02', 'Este, Alrededores y Centro en tarjetas separadas + TOTAL GENERAL (nunca Alrededores + Centro)', zones == ['ZONA ESTE', 'ALREDEDORES', 'CENTRO'] and 'TOTAL GENERAL' in body_txt and 'ALREDEDORES + CENTRO' not in body_txt.upper(), str(zones))
            v = await pg.inner_text('#rpVerdict')
            res('RPT-UI-03', '¿Se paga solo?: CUBRE / NO CUBRE con Sobran / Faltan', ('CUBRE EL COSTO' in v) and ('Sobran' in v or 'Faltan' in v), v.replace('\n', ' · '))
            p7 = await pg.inner_text('#rpPeriod')
            await pg.click('.rp-seg [data-k="15D"]'); await pg.wait_for_timeout(700); p15 = await pg.inner_text('#rpPeriod')
            res('RPT-UI-04', 'Filtros 7 DÍAS y 15 DÍAS', '7 días' in p7 and '15 días' in p15, p7.split('\n')[0] + ' / ' + p15.split('\n')[0])
            await pg.click('.rp-seg [data-k="MONTH"]'); await pg.wait_for_timeout(700)
            await pg.select_option('#rpMonth', '2026-9'); await pg.wait_for_timeout(700); pm = await pg.inner_text('#rpPeriod')
            res('REPORT-MAIL-13 (UI)', 'Filtro MES elige un mes calendario específico', 'Septiembre 2026' in pm and '01/09/2026 al 30/09/2026' in pm and '30 días' in pm, pm.split('\n')[0])
            await pg.click('.rp-seg [data-k="FREE"]'); await pg.wait_for_timeout(500)
            await pg.fill('#rpFrom', '2026-09-10'); await pg.dispatch_event('#rpFrom', 'change'); await pg.wait_for_timeout(400)
            await pg.fill('#rpTo', '2026-09-24'); await pg.dispatch_event('#rpTo', 'change'); await pg.wait_for_timeout(700); pf = await pg.inner_text('#rpPeriod')
            res('REPORT-MAIL-14 (UI)', 'Filtro LIBRE respeta Desde/Hasta y muestra los días', '10/09/2026 al 24/09/2026' in pf and '15 días' in pf, pf.split('\n')[0])
            await pg.click('.rp-seg [data-k="MONTH"]'); await pg.wait_for_timeout(500); await pg.select_option('#rpMonth', '2026-9'); await pg.wait_for_timeout(700)
            await pg.screenshot(path=os.path.join(OUT, 'online_informe.png'), full_page=True)
            await pg.click('#rpGenerate'); await pg.wait_for_timeout(2500)
            hist = await pg.inner_text('#rpBody')
            res('RPT-UI-05', 'GENERAR INFORME Y PDF queda en HISTORIAL (Manual, PDF OK)', 'Manual' in hist and 'OK' in hist and '01/09/2026 al 30/09/2026' in hist, (await pg.inner_text('#rpMsg')))
            async with pg.expect_download() as d: await pg.click('#rpBody tr [data-a="pdf"]')
            dl = await d.value; pth = os.path.join(OUT, dl.suggested_filename); await dl.save_as(pth)
            txt = subprocess.run(['pdftotext', '-layout', pth, '-'], capture_output=True, text=True).stdout
            res('RPT-UI-06', 'DESCARGAR PDF del historial (contenido real)', dl.suggested_filename.startswith('Informe_Cristian_Torres_Manual_') and 'ZONAS A REFORZAR' in txt and 'Zona Este' in txt, dl.suggested_filename)
            # cambio futuro de costo no altera el histórico
            await pg.click('.rp-tabs [data-tab="CONFIGURACIÓN"]'); await pg.wait_for_timeout(600)
            await pg.fill('#cfgCost', '2000000'); await pg.fill('#cfgFrom', '2026-09-01'); await pg.click('#cfgCostSave'); await pg.wait_for_timeout(700)
            await pg.click('.rp-tabs [data-tab="HISTORIAL"]'); await pg.wait_for_timeout(600)
            await pg.click('#rpBody tr [data-a="view"]'); await pg.wait_for_timeout(900)
            saved = await pg.inner_text('#rpSaved'); cov_saved = await pg.inner_text('#rpStep3')
            await pg.click('#rpBack'); await pg.wait_for_timeout(500); await pg.click('.rp-seg [data-k="MONTH"]'); await pg.wait_for_timeout(500); await pg.select_option('#rpMonth', '2026-9'); await pg.wait_for_timeout(800)
            cov_now = await pg.inner_text('#rpStep3')
            res('REPORT-MAIL-23 (UI)', 'Cambio futuro de costo: el informe guardado sigue con $ 1.600.000; la vista nueva usa $ 2.000.000', '1.600.000' in saved and '1.600.000' in cov_saved and '2.000.000' in cov_now, saved[:90])
            # programación y email (demo)
            await pg.click('.rp-tabs [data-tab="CONFIGURACIÓN"]'); await pg.wait_for_timeout(600)
            await pg.fill('#simAt', '2026-10-10T15:00'); await pg.click('#simRun'); await pg.wait_for_timeout(3000)
            m1 = await pg.inner_text('#rpMsg'); box1 = await pg.evaluate(f'()=>{api}.outbox()')
            await pg.fill('#simAt', '2026-10-10T15:30'); await pg.click('#simRun'); await pg.wait_for_timeout(1500)
            box2 = await pg.evaluate(f'()=>{api}.outbox()')
            res('REPORT-MAIL-11 (UI)', 'Sábado 15:00: se envía el semanal con su asunto y PDF adjunto', len(box1) == 1 and box1[0]['subject'] == 'OK Despacho · Informe semanal Cristian Torres · cierre 10/10/2026 15:00' and box1[0]['attachment'] == 'Informe_Cristian_Torres_Semanal_2026-10-10.pdf', m1)
            res('REPORT-MAIL-21 (UI)', 'Volver a correr la programación no duplica el email', len(box2) == 1, str(len(box2)))
            await pg.fill('#simAt', '2026-10-09T15:00'); await pg.click('#simRun'); await pg.wait_for_timeout(1200)
            res('REPORT-MAIL-11b (UI)', 'Otro día a las 15:00 no se envía nada', 'no corresponde' in await pg.inner_text('#rpMsg'))
            await pg.click('#outbox [data-mail="0"]'); await pg.wait_for_timeout(500)
            frame = pg.frame_locator('#mailPreview iframe')
            mail_txt = await frame.locator('body').inner_text()
            res('RPT-UI-07', 'Vista del email: encabezado, resumen, zonas, cobertura, decisiones, clientes y adjunto', all(k.lower() in mail_txt.lower() for k in ('OK ACCESORIOS · INFORME AUTOMÁTICO', 'Informe semanal · Cristian Torres', 'Ventana analizada', 'Envíos completados', 'Zona Este', 'Alrededores', 'Centro', 'CUBRE EL COSTO', 'Decisiones sugeridas', 'Clientes a recuperar', 'Mejores clientes', 'Zonas a reforzar')), '')
            await pg.screenshot(path=os.path.join(OUT, 'online_email.png'))
            await pg.click('#mpClose'); await pg.click('#rpClose'); await pg.wait_for_timeout(200)
            # sesión persiste al recargar
            await pg.reload(); await pg.wait_for_timeout(1500)
            res('E14', 'La sesión se mantiene al recargar', await pg.is_visible('#operario') and await pg.is_visible('#btnLogout'))
            await pg.click('#btnLogout'); await pg.wait_for_timeout(1200)
            res('E15', 'Cerrar sesión vuelve al acceso', await pg.is_visible('#loginEmail'))

            # transportista: no ve el panel del Operario
            await login(pg, 'gabriel@okdespacho.demo'); await pg.wait_for_timeout(800)
            res('E16', 'Transportista interno no accede al panel del Operario (ve MIS HOJAS PUBLICADAS)', await pg.is_visible('#noPanel') and not await pg.is_visible('#operario') and 'MIS HOJAS PUBLICADAS' in await pg.inner_text('#noPanel'))
            await pg.click('#np-logout'); await pg.wait_for_timeout(1200)

            # autogestión: el transportista cambia su propia contraseña
            await login(pg, 'gabriel@okdespacho.demo'); await pg.wait_for_timeout(800)
            await pg.click('#np-who'); await pg.fill('#acP1', 'nueva-clave-123'); await pg.fill('#acP2', 'nueva-clave-123'); await pg.click('#acSave'); await pg.wait_for_timeout(300)
            okmsg = await pg.inner_text('#acOk')
            await pg.click('#acLogout'); await pg.wait_for_timeout(1200)
            await login(pg, 'gabriel@okdespacho.demo', 'demo'); bad = 'incorrectos' in await pg.inner_text('#authErr')
            await login(pg, 'gabriel@okdespacho.demo', 'nueva-clave-123'); await pg.wait_for_timeout(600)
            res('F1.1-20', 'Usuario cambia su propia contraseña (la vieja deja de servir)', 'actualizada' in okmsg and bad and await pg.is_visible('#noPanel'))
            await pg.click('#np-logout'); await pg.wait_for_timeout(1200)

            # despacho: panel sí, Usuarios no
            await login(pg, 'despacho@okdespacho.demo'); await pg.wait_for_timeout(1500)
            res('E17', 'Despacho entra al panel y no ve Usuarios', await pg.is_visible('#operario') and await pg.locator('#btnUsers').count() == 0)
            res('RPT-UI-08', 'Despacho (sin permiso comercial) no ve INFORMES', await pg.locator('#btnReports').count() == 0)

            # regresión v15 con los archivos reales
            files = [os.path.join(FIX, f) for f in ('informe_pedidos__31_.xlsx', 'SALDO_COMPROBANTE__3_.xlsx', 'SALDO_CUENTA_CORRIENTE.xlsx')]
            if all(os.path.exists(f) for f in files):
                await pg.set_input_files('.file[data-kind="pedidos"] input', files)
                for _ in range(120):
                    await pg.wait_for_timeout(500)
                    if await pg.eval_on_selector_all('.file.ok', 'e=>e.length') == 3: break
                await pg.fill('#sheetDate', '01/10/2026'); await pg.press('#sheetDate', 'Tab')
                await pg.fill('#ids', '25384 25385 25378'); await pg.click('#btnSearch'); await pg.wait_for_timeout(1500)
                m = await pg.evaluate('()=>Object.fromEntries(OKD.RouteStore.rows.map(r=>[r.mainOrder,r.monto]))')
                res('E18', 'Regresión v15 con archivos reales: Hernández $178.612,65 · Godoy $54.610,35 · Mansur $73.481,52',
                    abs(m.get('25381', 0) - 178612.65) < .01 and abs(m.get('25382', 0) - 54610.35) < .01 and abs(m.get('25365', 0) - 73481.52) < .01, json.dumps(m))
                async with pg.expect_download() as d: await pg.click('#btnPdf')
                pdf = await d.value; await pdf.save_as(os.path.join(OUT, 'hoja.pdf'))
                async with pg.expect_download() as d: await pg.click('#btnExport')
                xls = await d.value; await xls.save_as(os.path.join(OUT, 'hoja.xlsx'))
                res('E19', 'PDF y Excel de la hoja se descargan desde la versión online', os.path.getsize(os.path.join(OUT, 'hoja.pdf')) > 5000 and os.path.getsize(os.path.join(OUT, 'hoja.xlsx')) > 5000)
                await pg.screenshot(path=os.path.join(OUT, 'online_hoja.png'))
            else:
                skip('E18', 'Regresión v15 con archivos reales', 'faltan los Excel en OKD_FIXTURES'); skip('E19', 'Exportación PDF/Excel', 'faltan los Excel')

            # paridad visual con la offline (captura lado a lado del mismo panel)
            if OFFLINE and os.path.exists(OFFLINE):
                pg2 = await ctx.new_page(); await pg2.goto('file://' + OFFLINE); await pg2.wait_for_timeout(1200)
                await pg2.screenshot(path=os.path.join(OUT, 'offline_v15.png'))
                same = await pg2.evaluate('()=>[getComputedStyle(document.querySelector(".top")).backgroundColor, getComputedStyle(document.querySelector(".top")).borderBottomColor, getComputedStyle(document.body).backgroundColor]')
                on = await pg.evaluate('()=>[getComputedStyle(document.querySelector("#operario .top")).backgroundColor, getComputedStyle(document.querySelector("#operario .top")).borderBottomColor, getComputedStyle(document.body).backgroundColor]')
                res('E20', 'Paridad visual: mismos colores de cabecera, línea cyan y fondo que la offline', same == on, json.dumps({'offline': same, 'online': on}))
            else:
                skip('E20', 'Paridad visual automática', 'sin OKD_OFFLINE_HTML')
            res('E21', 'Sin errores de consola durante toda la prueba', not errs, '; '.join(errs[:3]))
            await b.close()
    finally:
        srv.terminate()
    for r in R: print(' | '.join(r))
    c = {k: sum(1 for r in R if r[2] == k) for k in ('PASS', 'FAIL', 'NOT RUN')}
    print('TOTAL', c['PASS'], 'PASS /', c['FAIL'], 'FAIL /', c['NOT RUN'], 'NOT RUN')
    json.dump([dict(zip(('id', 'name', 'result', 'detail'), r)) for r in R], open(os.path.join(OUT, 'e2e_results.json'), 'w'), ensure_ascii=False, indent=1)
    sys.exit(1 if c['FAIL'] else 0)

asyncio.run(main())
