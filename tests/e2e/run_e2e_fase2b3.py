"""E2E Fase 2B.3: firma/DNI, ubicación, cobranzas, emails al cliente, vehículo/km/service, PDF, historial, devolución y cancelación."""
import asyncio, json, os, subprocess, time, socket, sys
from playwright.async_api import async_playwright
sys.path.insert(0, os.path.dirname(__file__)); from helpers import resolve, sign
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
CHROME = os.environ.get('CHROMIUM_PATH', '/opt/pw-browsers/chromium-1194/chrome-linux/chrome')
OUT = os.path.join(ROOT, 'tests', 'e2e', 'out'); os.makedirs(OUT, exist_ok=True)
URL = 'http://localhost:4177/'; R = []
def res(n, name, ok, det=''): R.append((n, name, 'PASS' if ok else 'FAIL', str(det)[:150]))
DB = '()=>JSON.parse(localStorage.getItem("okd_online_demo_v2"))'; api = 'window.OKD_ONLINE.api'
async def login(pg, email):
    await pg.goto(URL); await pg.wait_for_timeout(400); await pg.fill('#loginEmail', email); await pg.fill('#loginPass', 'demo'); await pg.click('#loginBtn'); await pg.wait_for_timeout(1400)
async def main():
    server = subprocess.Popen(['npx', 'vite', 'preview', '--port', '4177', '--strictPort', '--host', 'localhost'], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(60):
            try: socket.create_connection(('localhost', 4177), 1).close(); break
            except OSError: time.sleep(0.3)
        async with async_playwright() as p:
            b = await p.chromium.launch(executable_path=CHROME)
            ctx = await b.new_context(viewport={'width': 1200, 'height': 900}, accept_downloads=True, geolocation={'latitude': -32.89, 'longitude': -68.84}, permissions=['geolocation']); errs = []
            def ps(pg): pg.on('pageerror', lambda e: errs.append(str(e))); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
            op = await ctx.new_page(); ps(op); await op.goto(URL); await op.evaluate('()=>localStorage.clear()'); await login(op, 'despacho@okdespacho.demo')
            k = await op.evaluate('()=>crypto.randomUUID()')
            rc = await op.evaluate('(a)=>window.OKD_ONLINE.api.publishRoute(a)', {'sheet_key': k, 'carrier_id': 'CT-ALR', 'responsable_id': 'u-cristian', 'stops': [
                {'client_name': 'Cliente Uno', 'zone': 'ALREDEDORES', 'order_numbers': ['95001'], 'shipping_fee': 9000, 'ready': True, 'task': 'AMBAS', 'expected_amount': 50000, 'customer_email': 'uno@cliente.com'},
                {'client_name': 'Cliente Dos', 'zone': 'CENTRO', 'order_numbers': ['95002'], 'shipping_fee': 7000, 'ready': True, 'task': 'AMBAS', 'expected_amount': 30000, 'customer_email': 'dos@cliente.com'},
                {'client_name': 'Cliente Tres', 'zone': 'CENTRO', 'order_numbers': ['95003'], 'shipping_fee': 7000, 'ready': True}]})
            cr = await ctx.new_page(); ps(cr); await login(cr, 'cristian@okdespacho.demo')
            await cr.click('[data-open]'); await cr.wait_for_timeout(400); await cr.click('#drvStart'); await cr.wait_for_timeout(600)
            st = await cr.evaluate(DB)
            res('MAILC-01 (UI)', '"Va en camino" solo a la parada actual al iniciar', [m['to'] for m in st.get('outboxCustomer', [])] == ['uno@cliente.com'] and st['outboxCustomer'][0]['subject'].endswith('va en camino'))
            # llegada con ubicación
            await cr.click('[data-arrive]'); await cr.wait_for_timeout(700)
            s0 = (await cr.evaluate(DB))['routes2'][0]['stops'][0]
            res('LOC-01 (UI)', 'LLEGUÉ A LA PARADA guarda lat/lon, precisión y hora (puntual, sin GPS continuo)', s0['arrive_location']['lat'] == -32.89 and 'at' in s0['arrive_location'] and 'Llegada registrada' in await cr.inner_text('#drv'))
            # firma / CUIL / DNI
            await cr.click('.drv-stop >> nth=0 >> [data-o="ENTREGADO"]'); await cr.fill('.drv-stop >> nth=0 >> [data-f="recv"]', 'Juan Pérez'); await cr.click('.drv-stop >> nth=0 >> [data-save]'); await cr.wait_for_timeout(200)
            e1 = await cr.inner_text('.drv-stop >> nth=0 >> .shiperr')
            await sign(cr, '.drv-stop >> nth=0 >> [data-sig]'); await cr.fill('.drv-stop >> nth=0 >> [data-f="cuil"]', '20-12345678-6'); await cr.dispatch_event('.drv-stop >> nth=0 >> [data-f="cuil"]', 'change'); await cr.wait_for_timeout(300)
            dni_txt = await cr.inner_text('.drv-stop >> nth=0 >> [data-dni]')
            res('FIRMA-01', 'Sin firma no se guarda; CUIL nuevo ofrece foto del DNI desde el celular', 'firma' in e1 and 'foto del DNI' in dni_txt and await cr.locator('.drv-stop >> nth=0 >> [data-dnifile]').count() == 1, e1)
            await cr.set_input_files('.drv-stop >> nth=0 >> [data-dnifile]', files=[{'name': 'dni.jpg', 'mimeType': 'image/jpeg', 'buffer': b'\xff\xd8\xff\xe0DNI-FALSO'}]); await cr.wait_for_timeout(300)
            await cr.select_option('.drv-stop >> nth=0 >> [data-f="cst"]', 'COBRO_PARCIAL'); await cr.fill('.drv-stop >> nth=0 >> [data-f="camt"]', '20000'); await cr.select_option('.drv-stop >> nth=0 >> [data-f="cmode"]', 'TRANSFERENCIA')
            await cr.click('.drv-stop >> nth=0 >> [data-save]'); await cr.wait_for_timeout(200)
            res('COB-02 (UI)', 'Cobro parcial exige observación', 'observación' in await cr.inner_text('.drv-stop >> nth=0 >> .shiperr'))
            await cr.fill('.drv-stop >> nth=0 >> [data-f="cnote"]', 'Resto el lunes'); await cr.click('.drv-stop >> nth=0 >> [data-save]'); await cr.wait_for_timeout(900)
            st = await cr.evaluate(DB); s0 = st['routes2'][0]['stops'][0]
            res('COB-03 (UI)', 'Cobranza guardada (parcial, importe, modo, nota) sin tocar el esperado', s0['collection_status'] == 'COBRO_PARCIAL' and s0['collected_amount'] == 20000 and s0['payment_mode'] == 'TRANSFERENCIA' and s0['expected_amount'] == 50000)
            ev = st['evidence'][s0['id']]
            res('FIRMA-02', 'Receptor + firma + CUIL en evidencia privada; la parada no lleva CUIL ni firma', ev['receiver_name'] == 'Juan Pérez' and ev['signature_png_b64'] and ev['cuil'] == '20123456786' and 'cuil' not in json.dumps(s0).lower() and 'signature' not in json.dumps(s0), '')
            res('FIRMA-03', 'DNI registrado para ese CUIL', '20123456786' in st.get('identity', {}))
            idn = st['identity']['20123456786']; obj = st['storage'][idn['storage_path']]
            try: await cr.evaluate(f'()=>{api}.identityDocUrl("20123456786")'); drv_url = 'OK'
            except Exception as e: drv_url = str(e)
            res('DNI-UI-01', 'RC1: la foto va a Storage privado (ruta CUIL/uuid.jpg) y el chofer no obtiene URL', 'dni_photo_b64' not in idn and idn['storage_path'].startswith('20123456786/') and obj['mime'] == 'image/jpeg' and 'Sin permiso' in drv_url, idn['storage_path'])
            res('MAILC-02 (UI)', 'Confirmación de entrega + "va en camino" a la nueva actual; sin CUIL/firma/notas', [m['to'] + '|' + m['subject'] for m in st['outboxCustomer']][1:] == ['uno@cliente.com|OK Accesorios · Tu pedido fue entregado', 'dos@cliente.com|OK Accesorios · Tu pedido va en camino'] and not any(x in json.dumps(st['outboxCustomer']) for x in ('20123456786', 'Resto el lunes', 'CUIL')), str([m['subject'] for m in st['outboxCustomer']]))
            # segundo cliente con el mismo CUIL → DNI ya registrado; falla de email
            await cr.click('.drv-stop >> nth=1 >> [data-o="ENTREGA_PARCIAL"]'); await cr.fill('.drv-stop >> nth=1 >> [data-f="cuil"]', '20123456786'); await cr.dispatch_event('.drv-stop >> nth=1 >> [data-f="cuil"]', 'change'); await cr.wait_for_timeout(300)
            res('FIRMA-04', 'CUIL con DNI ya registrado: ✓ DNI YA REGISTRADO y no pide otra foto', '✓ DNI YA REGISTRADO' in await cr.inner_text('.drv-stop >> nth=1 >> [data-dni]') and await cr.locator('.drv-stop >> nth=1 >> [data-dnifile]').count() == 0)
            await cr.evaluate('()=>{window.OKD_MAIL_FAIL=true}')
            await resolve(cr, 1, 'ENTREGA_PARCIAL', note='Faltó una caja')
            st = await cr.evaluate(DB); s1 = st['routes2'][0]['stops'][1]; jobs = [j for j in st['customerJobs'] if j['stop_id'] == s1['id']]
            res('MAILC-03 (UI)', 'Falla del email no revierte la entrega parcial (queda ERROR para reintentar)', s1['outcome'] == 'ENTREGA_PARCIAL' and any(j['kind'] == 'PARTIAL' and j['status'] == 'ERROR' for j in jobs), str([(j['kind'], j['status']) for j in jobs]))
            await cr.evaluate('()=>{window.OKD_MAIL_FAIL=false}')
            # sin ubicación → motivo
            await cr.evaluate('()=>{navigator.geolocation.getCurrentPosition=(ok,err)=>err({code:1})}')
            await resolve(cr, 2, 'NO_ENTREGADO', note='Cerrado'); await cr.wait_for_timeout(300)
            noloc = await cr.locator('.drv-stop >> nth=2 >> .drv-noloc').count()
            await cr.click('.drv-stop >> nth=2 >> [data-nl]'); await cr.wait_for_timeout(200)
            msg = await cr.inner_text('.drv-stop >> nth=2 >> .drv-noloc .shiperr')
            await cr.fill('.drv-stop >> nth=2 >> [data-f="noloc"]', 'Sin señal en la zona'); await cr.click('.drv-stop >> nth=2 >> [data-nl]'); await cr.wait_for_timeout(800)
            s2 = (await cr.evaluate(DB))['routes2'][0]['stops'][2]
            res('LOC-02 (UI)', 'Sin ubicación: REGISTRAR SIN UBICACIÓN exige motivo y no inventa coordenadas', noloc == 1 and 'motivo' in msg and s2['finish_location'].get('missing_reason') == 'Sin señal en la zona' and 'lat' not in s2['finish_location'], json.dumps(s2['finish_location']))
            await cr.click('#drvFin'); await cr.wait_for_timeout(800)
            # PDF + historial + devolución
            async with cr.expect_download() as d: await cr.click('#drvPdf')
            dl = await d.value; pth = os.path.join(OUT, dl.suggested_filename); await dl.save_as(pth)
            txt = subprocess.run(['pdftotext', '-layout', pth, '-'], capture_output=True, text=True).stdout
            res('PDF-01 (UI)', 'PDF final de la hoja con original, ejecutada, resultados y cobranza; sin DNI/CUIL/GPS/firma', 'RUTA PUBLICADA ORIGINAL' in txt and 'RUTA REAL EJECUTADA' in txt and 'ENTREGA PARCIAL' in txt and 'Cobranza' in txt and not any(x in txt for x in ('20123456786', 'CUIL', 'DNI', '-32.89')), dl.suggested_filename)
            await cr.click('#drvRet'); await cr.click('#drvRetGo'); await cr.wait_for_timeout(200)
            e = await cr.inner_text('#drvRetForm .shiperr'); await cr.fill('#drvRetWhy', 'Cargué mal la parada 2'); await cr.click('#drvRetGo'); await cr.wait_for_timeout(500)
            st = await cr.evaluate(DB)
            res('RET-01 (UI)', 'DEVOLVER HOJA: motivo obligatorio, es solicitud y la hoja no cambia', 'motivo' in e and len(st['returns']) == 1 and st['routes2'][0]['operational_status'] == 'COMPLETADA')
            await cr.click('#drvBack'); await cr.wait_for_timeout(300); await cr.fill('#drvSearch', 'cliente dos'); await cr.wait_for_timeout(300)
            c1 = await cr.locator('.drv-card').count(); await cr.fill('#drvSearch', 'zzzz'); await cr.wait_for_timeout(300); c2 = await cr.locator('.drv-card').count()
            res('HIST-01', 'Historial: búsqueda por cliente/hoja y hoja finalizada visible', c1 == 1 and c2 == 0)
            # ruta interna con vehículo, km y service
            k2 = await op.evaluate('()=>crypto.randomUUID()')
            ri = await op.evaluate(f'(k)=>{api}.publishRoute({{sheet_key:k,carrier_id:"INTERNO",responsable_id:"u-gabriel",vehicle_id:"vh-1",stops:[{{client_name:"Banco",order_numbers:["96001"],ready:true}}]}})', k2)
            ga = await ctx.new_page(); ps(ga); await login(ga, 'gabriel@okdespacho.demo')
            await ga.click(f'[data-open="{ri["id"]}"]'); await ga.wait_for_timeout(400); await ga.click('#drvStart'); await ga.wait_for_timeout(500)
            await resolve(ga, 0, 'ENTREGADO')
            await ga.click('#drvFin'); await ga.wait_for_timeout(300); t1 = await ga.inner_text('#drvToast')
            await ga.fill('#drvKm', '49000'); await ga.click('#drvFin'); await ga.wait_for_timeout(300); t2 = await ga.inner_text('#drvToast')
            await ga.fill('#drvKm', '51200'); await ga.click('#drvFin'); await ga.wait_for_timeout(800)
            st = await ga.evaluate(DB); r = [x for x in st['routes2'] if x['id'] == ri['id']][0]; v = st['vehicles'][0]
            res('VEH-01 (UI)', 'Km final obligatorio, no puede bajar; al cerrar actualiza el vehículo', 'kilometraje' in t1 and 'no puede ser menor' in t2 and r['km_start'] == 50000 and r['km_end'] == 51200 and v['current_km'] == 51200, f'{t1} / {t2}')
            ad = await ctx.new_page(); ps(ad); await login(ad, 'admin@okdespacho.demo'); await (ad.click('#btnApprovals') if not await ad.is_visible('#usersPanel') else ad.wait_for_timeout(1)); await ad.wait_for_timeout(900)
            url = await ad.evaluate(f'()=>{api}.identityDocUrl("20123456786")')
            res('DNI-UI-02', 'Admin (identity_docs.view) obtiene una URL temporal', url.startswith('blob:'), url[:30])
            vt = await ad.inner_text('#opsVeh')
            await ad.fill('#opsVeh [data-vkm]', '51200'); await ad.click('#opsVeh [data-vsvc]'); await ad.wait_for_timeout(800)
            vt2 = await ad.inner_text('#opsVeh')
            res('VEH-02 (UI)', 'Alerta SERVICE VENCIDO y REGISTRAR SERVICE REALIZADO la quita', 'SERVICE VENCIDO' in vt and 'SERVICE VENCIDO' not in vt2)
            await ad.fill('#opsVeh [data-vkm]', '51000'); await ad.click('#opsVeh [data-vfix]'); await ad.wait_for_timeout(500)
            e = await ad.inner_text('#apMsg'); await ad.fill('#opsVeh [data-vkm]', '51150'); await ad.fill('#opsVeh [data-vwhy]', 'Error de carga'); await ad.click('#opsVeh [data-vfix]'); await ad.wait_for_timeout(600)
            res('VEH-03 (UI)', 'Corrección de km por Admin con motivo obligatorio y auditoría', 'motivo' in e and (await ad.evaluate(DB))['vehicles'][0]['current_km'] == 51150 and any(a['action'] == 'VEHICLE_KM_CORRECTED' for a in (await ad.evaluate(DB))['audit']))
            await ad.fill('#opsRet [data-rnote]', 'Se corrige con versión 2'); await ad.click('#opsRet [data-rres="RESOLVED"]'); await ad.wait_for_timeout(600)
            res('RET-02 (UI)', 'Administración resuelve la devolución', (await ad.evaluate(DB))['returns'][0]['status'] == 'RESOLVED')
            if await ad.locator('#opsCust [data-cretry]').count(): await ad.click('#opsCust [data-cretry]'); await ad.wait_for_timeout(600)
            res('MAILC-04 (UI)', 'El email que falló se reintenta (automático o REINTENTAR EMAIL) y sale una sola vez', all(j['status'] == 'SENT' for j in (await ad.evaluate(DB))['customerJobs']) and sum(1 for m in (await ad.evaluate(DB))['outboxCustomer'] if 'parte' in m['subject']) == 1)
            # cancelar hoja activa
            k3 = await op.evaluate('()=>crypto.randomUUID()')
            rx = await op.evaluate(f'(k)=>{api}.publishRoute({{sheet_key:k,carrier_id:"CT-ESTE",responsable_id:"u-cristian",stops:[{{client_name:"X",zone:"ESTE",order_numbers:["97001"],ready:true}}]}})', k3)
            await ad.reload(); await ad.wait_for_timeout(1200); await (ad.click('#btnApprovals') if not await ad.is_visible('#usersPanel') else ad.wait_for_timeout(1)); await ad.wait_for_timeout(900)
            await ad.select_option('#cxRoute', rx['id']); await ad.fill('#cxWhy', 'Cliente suspendió'); await ad.click('#cxGo'); await ad.wait_for_timeout(700)
            k4 = await op.evaluate('()=>crypto.randomUUID()')
            ry = await op.evaluate(f'(k)=>{api}.publishRoute({{sheet_key:k,carrier_id:"CT-ESTE",responsable_id:"u-cristian",stops:[{{client_name:"X",zone:"ESTE",order_numbers:["97001"],ready:true}}]}})', k4)
            st = await op.evaluate(DB)
            res('CAN-01 (UI)', 'Cancelar hoja activa libera los pedidos; el correlativo no se reutiliza', [x for x in st['routes2'] if x['id'] == rx['id']][0]['operational_status'] == 'CANCELADA' and int(ry['number'][-6:]) == int(rx['number'][-6:]) + 1, rx['number'] + ' → ' + ry['number'])
            res('E-ERR', 'Sin errores de consola', not errs, '; '.join(errs[:2]))
            await b.close()
    finally: server.terminate()
    for r_ in R: print(' | '.join(r_))
    print('TOTAL', sum(1 for x in R if x[2] == 'PASS'), 'PASS /', sum(1 for x in R if x[2] == 'FAIL'), 'FAIL')
asyncio.run(main())
