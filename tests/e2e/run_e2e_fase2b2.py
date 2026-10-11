"""E2E Fase 2B.2: borradores con dueño, passkeys (WebAuthn real con autenticador virtual de Chromium), ruta interna dinámica, aprobación y emails."""
import asyncio, json, os, subprocess, time, socket
from playwright.async_api import async_playwright
import sys; sys.path.insert(0, os.path.dirname(__file__)); from helpers import resolve
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
CHROME = os.environ.get('CHROMIUM_PATH', '/opt/pw-browsers/chromium-1194/chrome-linux/chrome')
URL = 'http://localhost:4176/'   # WebAuthn no admite IP como RP ID
R = []
def res(n, name, ok, det=''): R.append((n, name, 'PASS' if ok else 'FAIL', str(det)[:150]))
DB = '()=>JSON.parse(localStorage.getItem("okd_online_demo_v2"))'
async def login(pg, email, pw='demo'):
    await pg.goto(URL); await pg.wait_for_timeout(400)
    await pg.fill('#loginEmail', email); await pg.fill('#loginPass', pw); await pg.click('#loginBtn'); await pg.wait_for_timeout(1500)
async def main():
    server = subprocess.Popen(['npx', 'vite', 'preview', '--port', '4176', '--strictPort', '--host', 'localhost'], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(60):
            try: socket.create_connection(('localhost', 4176), 1).close(); break
            except OSError: time.sleep(0.3)
        async with async_playwright() as p:
            b = await p.chromium.launch(executable_path=CHROME); ctx = await b.new_context(viewport={'width': 1300, 'height': 900}, geolocation={'latitude': -32.89, 'longitude': -68.84}, permissions=['geolocation']); errs = []
            def page_setup(pg): pg.on('pageerror', lambda e: errs.append(str(e))); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
            ad = await ctx.new_page(); page_setup(ad); await ad.goto(URL); await ad.evaluate('()=>localStorage.clear()')
            await login(ad, 'admin@okdespacho.demo')
            api = 'window.OKD_ONLINE.api'
            # ===== SEGURIDAD (demo, mismas reglas que SQL) =====
            await ad.evaluate(f'()=>{api}.action("create",{{full_name:"Operador Dos",email:"op2@okdespacho.demo",role:"DESPACHO"}})')
            op = await ctx.new_page(); page_setup(op); await login(op, 'despacho@okdespacho.demo')
            key = await op.evaluate('()=>crypto.randomUUID()')
            await op.evaluate(f'(k)=>{api}.reserveOrders(k,["70001"])', key)
            o2 = await ctx.new_page(); page_setup(o2); await login(o2, 'op2@okdespacho.demo')
            async def tryit(pg, js, k):
                try: await pg.evaluate(js, k); return 'OK'
                except Exception as e: return str(e)
            r1 = await tryit(o2, f'(k)=>{api}.releaseOrders(k,null)', key)
            r2 = await tryit(o2, f'(k)=>{api}.shippingConfirm({{sheet_key:k,ship_order:"1",detected_amount:9000,confirmed_amount:9000,fingerprint:"f"}})', key)
            r3 = await tryit(o2, f'(k)=>{api}.publishRoute({{sheet_key:k,carrier_id:"CT-ESTE",responsable_id:"u-cristian",stops:[{{client_name:"X",order_numbers:["70001"],ready:true}}]}})', key)
            res('SEC-02/03/04 (demo)', 'Otro operador: no libera, no confirma envío y no publica el borrador ajeno', all('FORBIDDEN_DRAFT' in x for x in (r1, r2, r3)), r1[:60])
            res('SEC-06 (demo)', 'Admin con permiso global opera el borrador ajeno', await tryit(ad, f'(k)=>{api}.releaseOrders(k,["70001"])', key) == 'OK')
            await o2.close()
            # ===== Configuración de notificaciones y hoja interna =====
            await ad.evaluate(f'()=>{api}.setIrSettings({{supervisor_user_id:"u-admin",copy_admin:true,extra_emails:["LOGISTICA@ok.test","admin@okdespacho.demo"],email_enabled:true}})')
            ik = await op.evaluate('()=>crypto.randomUUID()')
            route = await op.evaluate(f'(k)=>{api}.publishRoute({{sheet_key:k,carrier_id:"INTERNO",responsable_id:"u-gabriel",stops:[{{client_name:"Depósito Norte",order_numbers:["80001"],ready:true,bultos:2}},{{client_name:"Sucursal Centro",order_numbers:["80002"],ready:true}},{{client_name:"Proveedor Sur",order_numbers:["80003"],ready:true}}]}})', ik)
            ga = await ctx.new_page(); page_setup(ga)
            cdp = await ctx.new_cdp_session(ga); await cdp.send('WebAuthn.enable')
            await cdp.send('WebAuthn.addVirtualAuthenticator', {'options': {'protocol': 'ctap2', 'transport': 'internal', 'hasResidentKey': True, 'hasUserVerification': True, 'isUserVerified': True, 'automaticPresenceSimulation': True}})
            await login(ga, 'gabriel@okdespacho.demo'); await ga.wait_for_timeout(500)
            await ga.click('[data-open]'); await ga.wait_for_timeout(500); await ga.click('#drvStart'); await ga.wait_for_timeout(600)
            await resolve(ga, 0, 'ENTREGADO')
            cur_has_move = await ga.locator('.drv-stop.cur [data-up]').count(); done_has_move = await ga.locator('.drv-stop >> nth=0 >> [data-up]').count()
            res('INT-03/04 (UI)', 'La parada actual y la completada no tienen controles para moverse', cur_has_move == 0 and done_has_move == 0)
            await ga.click('#drvAddOpen'); await ga.fill('#naName', 'Banco (retiro)'); await ga.select_option('#naAct', 'RETIRO'); await ga.fill('#naBul', '1'); await ga.click('#naSave'); await ga.wait_for_timeout(600)
            st = await ga.evaluate(DB); r = [x for x in st['routes2'] if x['id'] == route['id']][0]
            added = [s for s in r['stops'] if s['provenance'] == 'DRIVER']
            res('INT-01', 'Agregar parada: DRIVER, versión, actor y hora del servidor', len(added) == 1 and added[0]['added_by'] == 'u-gabriel' and r['version'] == 2 and r['events'][0]['type'] == 'INTERNAL_STOP_ADDED', f"v{r['version']}")
            names = lambda: ga.eval_on_selector_all('.drv-stop b', 'e=>e.map(x=>x.textContent)')
            before = await names()
            await ga.click('.drv-stop.fut >> nth=0 >> [data-down]'); await ga.wait_for_timeout(600)
            after = await names()
            res('INT-02 (↑↓)', 'Reordenar futuras con botones accesibles', before[2] == after[3] and before[3] == after[2] and before[:2] == after[:2], f'{before} → {after}')
            await ga.drag_and_drop('.drv-stop.fut >> nth=1', '.drv-stop.fut >> nth=0'); await ga.wait_for_timeout(700)
            after2 = await names()
            res('INT-02 (arrastrar)', 'Reordenar futuras arrastrando la tarjeta', after2[2] == after[3] and after2[3] == after[2], f'{after} → {after2}')
            await ga.reload(); await ga.wait_for_timeout(1200); await ga.click('[data-open]'); await ga.wait_for_timeout(500)
            res('INT-05', 'El nuevo orden persiste al recargar', await names() == after2, str(await names()))
            ver = (await ga.evaluate(DB))['routes2'][-1]['version']
            conf = await tryit(ga, f'(id)=>{api}.reorderInternalStops(id,[],1,"x-old")', route['id'])
            res('INT-06', 'Conflicto de versión rechazado', 'VERSION_CONFLICT' in conf, conf[:70])
            # offline: agregar y reordenar sin conexión
            await ga.evaluate('()=>{window.OKD_NET={offline:true};window.dispatchEvent(new Event("okd-net"))}'); await ga.wait_for_timeout(200)
            await ga.click('#drvAddOpen'); await ga.fill('#naName', 'Correo'); await ga.click('#naSave'); await ga.wait_for_timeout(400)
            await ga.click('.drv-stop.fut >> nth=0 >> [data-down]'); await ga.wait_for_timeout(400)
            q = await ga.evaluate('()=>JSON.parse(localStorage.getItem("okd_drv_queue:u-gabriel"))')
            await ga.evaluate('()=>{window.OKD_NET={offline:false};window.dispatchEvent(new Event("okd-net"))}'); await ga.wait_for_timeout(1800)
            r = [x for x in (await ga.evaluate(DB))['routes2'] if x['id'] == route['id']][0]
            ev = r['events']
            res('INT-07', 'Sin conexión: agregar y reordenar quedan en cola, sincronizan una sola vez y quedan marcados offline', len(q) == 2 and len(ev) == 5 and sum(1 for e in ev if e['offline']) == 2 and len([s for s in r['stops'] if s['provenance'] == 'DRIVER']) == 2, f'cola {len(q)} · eventos {len(ev)}')
            # resolver y finalizar con falla de email
            for _ in range(6):
                btn = ga.locator('.drv-stop:has(.drv-acts) >> nth=0')
                pend = await ga.evaluate('()=>document.querySelectorAll(".drv-stop .drv-out").length')
                if await ga.locator('.drv-stop').count() == pend: break
                stops = await ga.locator('.drv-stop').count()
                for i in range(stops):
                    if await ga.locator(f'.drv-stop >> nth={i} >> .drv-out').count() == 0:
                        await resolve(ga, i, 'ENTREGADO'); break
            await ga.evaluate('()=>{window.OKD_MAIL_FAIL=true}')
            await ga.click('#drvFin'); await ga.wait_for_timeout(900)
            r = [x for x in (await ga.evaluate(DB))['routes2'] if x['id'] == route['id']][0]; dbs = await ga.evaluate(DB)
            res('APR-01', 'Con cambios: COMPLETADA · PENDIENTE DE APROBACIÓN y el chofer no queda bloqueado', r['operational_status'] == 'COMPLETADA' and r['approval_status'] == 'PENDIENTE' and 'PENDIENTE DE APROBACIÓN' in await ga.inner_text('#drv'), r['approval_status'])
            jobs = [j for j in dbs['emailJobs'] if j['route_id'] == route['id']]
            res('MAIL-01/02/03 (demo)', 'Superior + Administración + adicionales sin duplicados', sorted(j['recipient'] for j in jobs) == ['admin@okdespacho.demo', 'logistica@ok.test'], str(sorted(j['recipient'] for j in jobs)))
            res('MAIL-05 (demo)', 'Falla del email: la hoja sigue COMPLETADA y el email queda en ERROR', all(j['status'] == 'ERROR' for j in jobs) and r['operational_status'] == 'COMPLETADA', str([j['status'] for j in jobs]))
            res('APR-00', 'Una sola solicitud de aprobación', len([a for a in dbs['approvals'] if a['route_id'] == route['id']]) == 1)
            await ga.evaluate('()=>{window.OKD_MAIL_FAIL=false}')
            # ===== Pantalla de aprobación =====
            await ad.reload(); await ad.wait_for_timeout(1500); await (ad.click('#btnApprovals') if not await ad.is_visible('#usersPanel') else ad.wait_for_timeout(1)); await ad.wait_for_timeout(800)
            t = await ad.inner_text('#apWrap')
            res('APR-02', 'Original vs ejecutada con cambios destacados', 'RUTA PUBLICADA ORIGINAL' in t and 'RUTA REAL EJECUTADA' in t and t.count('PARADA AGREGADA') == 2 and 'Agregadas: 2' in t, t[:90].replace('\n', ' '))
            await ad.click('#irCfg [data-retry] >> nth=0'); await ad.wait_for_timeout(500); await ad.click('#irCfg [data-retry] >> nth=0'); await ad.wait_for_timeout(500)
            dbs = await ad.evaluate(DB); jobs = [j for j in dbs['emailJobs'] if j['route_id'] == route['id']]
            res('MAIL-05b / MAIL-06', 'REINTENTAR EMAIL envía y no duplica', all(j['status'] == 'SENT' for j in jobs) and len([m for m in dbs['outboxIR'] if 'pendiente de aprobación' in m['subject']]) == 2 and dbs['outboxIR'][0]['subject'] == 'OK Despacho · Hoja ' + route['number'] + ' pendiente de aprobación', str(len(dbs['outboxIR'])))
            html = dbs['outboxIR'][0]['html']
            res('MAIL-CONT', 'Email: hoja, chofer, originales/ejecutadas, agregadas, botón; sin DNI/CUIL/GPS/firma', all(k in html for k in ('Gabriel Figueroa', 'Paradas originales', 'Agregadas', 'REVISAR CAMBIOS')) and not any(k in html for k in ('DNI', 'CUIL', 'GPS', 'irma')))
            await ad.click('.apr-item [data-obs]'); await ad.wait_for_timeout(200)
            res('APR-03', 'Solicitar aclaración exige motivo', 'motivo' in await ad.inner_text('.apr-item .shiperr'))
            await ad.fill('.apr-item [data-note]', 'Explicar la parada del banco'); await ad.click('.apr-item [data-obs]'); await ad.wait_for_timeout(700)
            dbs = await ad.evaluate(DB); r = [x for x in dbs['routes2'] if x['id'] == route['id']][0]
            res('APR-04', 'Aclaración: COMPLETADA · OBSERVADA (no vuelve a EN CURSO)', r['operational_status'] == 'COMPLETADA' and r['approval_status'] == 'OBSERVADA')
            await ga.reload(); await ga.wait_for_timeout(1200)
            res('MAIL-07', 'Aclaración avisa al chofer (in-app y email)', 'ACLARACIÓN SOLICITADA' in await ga.inner_text('#drv') and any(n['user_id'] == 'u-gabriel' and n['type'] == 'INTERNAL_ROUTE_OBSERVED' for n in dbs['notifs']) and any(m['to'] == 'gabriel@okdespacho.demo' for m in dbs['outboxIR']))
            # hoja interna sin cambios: cierre normal
            ik2 = await op.evaluate('()=>crypto.randomUUID()')
            r2 = await op.evaluate(f'(k)=>{api}.publishRoute({{sheet_key:k,carrier_id:"INTERNO",responsable_id:"u-gabriel",stops:[{{client_name:"Única",order_numbers:["80010"],ready:true}}]}})', ik2)
            await ga.evaluate(f'(id)=>{api}.startRoute(id)', r2['id']); sid = r2['stops'][0]['id']
            await ga.evaluate(f'(id)=>{api}.setStopOutcome(id,"ENTREGADO",null,null,"o-x",{{evidence:{{receiver_name:"R",signature_png_b64:"iVBORw0KGgo="}},location:{{lat:-32.9,lon:-68.8}}}})', sid); fin = await ga.evaluate(f'(id)=>{api}.finalizeRoute(id)', r2['id'])
            res('APR-05', 'Sin cambios: COMPLETADA y cierre normal (sin aprobación)', fin['approval_status'] == 'NO_REQUERIDA')
            # ===== PASSKEYS (WebAuthn real con autenticador virtual) =====
            await ga.click('#np-who'); await ga.wait_for_timeout(300); await ga.click('#pkAdd'); await ga.wait_for_timeout(1500)
            ok_txt = await ga.inner_text('#acOk') if await ga.is_visible('#acOk') else await ga.inner_text('#acErr')
            pks = (await ga.evaluate(DB)).get('passkeys', [])
            res('PASSKEY-01', 'Registro después de iniciar sesión (WebAuthn real)', 'activado' in ok_txt and len(pks) == 1, ok_txt)
            res('PASSKEY-06', 'Solo se guarda id de credencial, clave pública y contador', sorted(pks[0].keys()) == ['alg', 'created_at', 'credential_id', 'device_name', 'id', 'last_used_at', 'public_key', 'revoked_at', 'sign_count', 'user_id'] if pks else False, str(sorted(pks[0].keys())) if pks else '')
            await ga.click('#acLogout'); await ga.wait_for_timeout(1200)
            res('PASSKEY-UI', 'El acceso ofrece INGRESAR CON HUELLA / FACE ID y USAR CONTRASEÑA', await ga.is_visible('#loginPasskey') and await ga.is_visible('#loginEmail'))
            await ga.click('#loginPasskey'); await ga.wait_for_timeout(1500)
            res('PASSKEY-02', 'Ingreso con passkey (firma verificada)', await ga.is_visible('#noPanel') and 'MIS HOJAS PUBLICADAS' in await ga.inner_text('#drv'))
            await ga.click('#np-logout'); await ga.wait_for_timeout(1200)
            await ga.fill('#loginEmail', 'gabriel@okdespacho.demo'); await ga.fill('#loginPass', 'demo'); await ga.click('#loginBtn'); await ga.wait_for_timeout(1200)
            res('PASSKEY-03', 'La contraseña sigue funcionando', await ga.is_visible('#noPanel'))
            await ga.click('#np-logout'); await ga.wait_for_timeout(1000)
            await ad.evaluate(f'()=>{api}.action("reassign_routes",{{user_id:"u-gabriel",to_user:"u-gabriel2"}})')  # hoja de prueba de la demo
            await ad.evaluate(f'()=>{api}.action("disable",{{user_id:"u-gabriel"}})')
            await ga.reload(); await ga.wait_for_timeout(800); await ga.click('#loginPasskey'); await ga.wait_for_timeout(1500)
            res('PASSKEY-04', 'Usuario deshabilitado no entra aunque tenga passkey', 'sin acceso' in await ga.inner_text('#authErr') and not await ga.is_visible('#noPanel'))
            await ad.evaluate(f'()=>{api}.action("reactivate",{{user_id:"u-gabriel"}})')
            pid = (await ga.evaluate(DB))['passkeys'][0]['id']
            await login(ga, 'gabriel@okdespacho.demo'); await ga.evaluate(f'(id)=>{api}.revokePasskey(id)', pid); await ga.click('#np-logout'); await ga.wait_for_timeout(1000)
            await ga.click('#loginPasskey'); await ga.wait_for_timeout(1500)
            res('PASSKEY-05', 'Passkey revocada no entra', 'no está activo' in await ga.inner_text('#authErr'))
            res('E-ERR', 'Sin errores de consola', not errs, '; '.join(errs[:2]))
            await b.close()
    finally: server.terminate()
    for r_ in R: print(' | '.join(r_))
    print('TOTAL', sum(1 for x in R if x[2] == 'PASS'), 'PASS /', sum(1 for x in R if x[2] == 'FAIL'), 'FAIL')
asyncio.run(main())
