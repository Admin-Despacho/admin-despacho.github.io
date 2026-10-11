"""E2E Fase 2B.1: publicar → recibir → ver → iniciar → resultados (con corte de conexión) → finalizar → informe; pestañas de hojas.
Operario y transportistas en pestañas del mismo navegador (modo demo, archivos reales)."""
import asyncio, json, os, subprocess, time, socket
from playwright.async_api import async_playwright
import sys; sys.path.insert(0, os.path.dirname(__file__)); from helpers import resolve
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
FIX = os.environ.get('OKD_FIXTURES', '/mnt/user-data/uploads')
CHROME = os.environ.get('CHROMIUM_PATH', '/opt/pw-browsers/chromium-1194/chrome-linux/chrome')
OUT = os.path.join(ROOT, 'tests', 'e2e', 'out'); os.makedirs(OUT, exist_ok=True)
URL = 'http://127.0.0.1:4175/'
R = []
def res(n, name, ok, det=''): R.append((n, name, 'PASS' if ok else 'FAIL', str(det)[:150]))
async def login(pg, email):
    await pg.goto(URL); await pg.wait_for_timeout(400)
    await pg.fill('#loginEmail', email); await pg.fill('#loginPass', 'demo'); await pg.click('#loginBtn'); await pg.wait_for_timeout(1800)
async def main():
    server = subprocess.Popen(['npx', 'vite', 'preview', '--port', '4175', '--strictPort', '--host', '127.0.0.1'], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(60):
            try: socket.create_connection(('127.0.0.1', 4175), 1).close(); break
            except OSError: time.sleep(0.3)
        async with async_playwright() as p:
            b = await p.chromium.launch(executable_path=CHROME)
            ctx = await b.new_context(viewport={'width': 1440, 'height': 950}, accept_downloads=True, geolocation={'latitude': -32.89, 'longitude': -68.84}, permissions=['geolocation']); errs = []
            op = await ctx.new_page(); op.on('pageerror', lambda e: errs.append(str(e))); op.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
            await op.goto(URL); await op.evaluate('()=>localStorage.clear()')
            await login(op, 'despacho@okdespacho.demo')
            await op.set_input_files('.file[data-kind="pedidos"] input', [os.path.join(FIX, f) for f in ('informe_pedidos__31_.xlsx', 'SALDO_COMPROBANTE__3_.xlsx', 'SALDO_CUENTA_CORRIENTE.xlsx')])
            for _ in range(200):
                await op.wait_for_timeout(500)
                if await op.eval_on_selector_all('.file.ok', 'e=>e.length') == 3: break
            await op.fill('#sheetDate', '01/10/2026'); await op.press('#sheetDate', 'Tab')
            await op.fill('#ids', '25384 25385'); await op.click('#btnSearch'); await op.wait_for_timeout(1200)
            # pestañas
            await op.click('#tabNew'); await op.wait_for_timeout(800)
            await op.fill('#ids', '25384 25386'); await op.click('#btnSearch'); await op.wait_for_timeout(1200)
            log = await op.inner_text('#log'); rows2 = await op.evaluate('()=>OKD.RouteStore.rows.map(r=>r.mainOrder)')
            res('2B1-20', 'Pedido ya cargado en otra hoja borrador: bloqueado', 'PEDIDO YA AGREGADO A OTRA HOJA' in log and rows2 == ['25386'], str(rows2))
            await op.click('.stab >> nth=0'); await op.wait_for_timeout(1000)
            rows1 = await op.evaluate('()=>OKD.RouteStore.rows.map(r=>r.mainOrder).sort()')
            await op.click('.stab >> nth=1'); await op.wait_for_timeout(1000)
            rows2b = await op.evaluate('()=>OKD.RouteStore.rows.map(r=>r.mainOrder)')
            await op.click('.stab >> nth=1 >> .stx'); await op.wait_for_timeout(800)
            reopen = await op.locator('#tabReopen option').count()
            await op.select_option('#tabReopen', index=1); await op.wait_for_timeout(1000)
            rows2c = await op.evaluate('()=>OKD.RouteStore.rows.map(r=>r.mainOrder)')
            res('2B1-18', 'Pestañas con hojas separadas, autosave, cerrar no borra y se reabre', rows1 == ['25381', '25382'] and rows2b == ['25386'] and reopen == 2 and rows2c == ['25386'], f'{rows1} / {rows2b} / {rows2c}')
            await op.click('.stab >> nth=0'); await op.wait_for_timeout(1000)
            # publicar la pestaña activa
            await op.click('#btnPublish'); await op.wait_for_timeout(800)
            resp = await op.eval_on_selector_all('#pubResp option', 'e=>e.map(o=>o.textContent)')
            await op.click('#pubGo'); await op.wait_for_timeout(1200)
            pub = await op.evaluate('()=>OKD.RouteStore.published')
            st_txt = await op.inner_text('#pubStatus') if pub else ''
            res('2B1-01 (UI)', 'PUBLICAR HOJA: correlativo, responsable compatible y estado PUBLICADA', pub and pub['number'] and resp == ['Cristian Torres'] and 'PUBLICADA' in st_txt, json.dumps(pub)[:120])
            tabs = await op.eval_on_selector_all('.stab', 'e=>e.map(t=>t.innerText)')
            res('2B1-19', 'Publicar la pestaña activa no publica las otras', len(tabs) == 2 and pub['number'] in tabs[0] and pub['number'] not in tabs[1], str(tabs))
            res('C-UI', 'Correlativo por transportista: CT Este = 01-000001', pub['number'] == '01-000001', pub['number'])
            # Reserva server-side: otra sesión ya tiene el pedido → no se agrega en esta hoja
            await op.click('.stab >> nth=1'); await op.wait_for_timeout(800)
            await op.evaluate('()=>window.OKD_ONLINE.api.reserveOrders("OTRA-SESION",["25365","25378"])')
            await op.fill('#ids', '25378'); await op.click('#btnSearch'); await op.wait_for_timeout(1200)
            log = await op.inner_text('#log'); rows2d = await op.evaluate('()=>OKD.RouteStore.rows.map(r=>r.mainOrder)')
            res('R-UI-01', 'Pedido reservado por otra sesión: PEDIDO YA AGREGADO A OTRA HOJA y no se agrega', 'PEDIDO YA AGREGADO A OTRA HOJA' in log and 'otra hoja borrador' in log and '25365' not in rows2d, log.replace('\n', ' ')[:110])
            await op.fill('#ids', '25384'); await op.click('#btnSearch'); await op.wait_for_timeout(1000)
            res('R-UI-02', 'Pedido de una hoja publicada no se puede volver a cargar', 'PEDIDO YA AGREGADO A OTRA HOJA' in await op.inner_text('#log') and '25381' not in await op.evaluate('()=>OKD.RouteStore.rows.map(r=>r.mainOrder)'))
            await op.click('.stab >> nth=0'); await op.wait_for_timeout(800)
            n_route = await op.evaluate('()=>JSON.parse(localStorage.getItem("okd_online_demo_v2")).routes2.length')
            await op.click('#btnPublish', force=True); await op.wait_for_timeout(300)
            res('2B1-03b', 'No se publica dos veces la misma hoja', n_route == 1 and await op.evaluate('()=>JSON.parse(localStorage.getItem("okd_online_demo_v2")).routes2.length') == 1)
            # transportistas
            cr = await ctx.new_page(); cr.on('pageerror', lambda e: errs.append(str(e))); cr.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
            await login(cr, 'cristian@okdespacho.demo'); await cr.wait_for_timeout(800)
            card = await cr.inner_text('#drv')
            notif = await cr.evaluate('()=>JSON.parse(localStorage.getItem("okd_online_demo_v2")).notifs')
            res('2B1-04', 'Notificación persistente creada (una)', len(notif) == 1 and notif[0]['title'] == 'NUEVA HOJA PUBLICADA', str(len(notif)))
            res('2B1-05', 'Cristian recibe la hoja (NUEVA) en MIS HOJAS PUBLICADAS', 'MIS HOJAS PUBLICADAS' in card and 'HOJA ' + pub['number'] in card and 'NUEVA' in card and '2 entregas' in card, card.replace('\n', ' | ')[:120])
            di = await ctx.new_page(); await login(di, 'diego@okdespacho.demo'); await di.wait_for_timeout(600)
            res('2B1-06 (UI)', 'Otro transportista no la ve', 'HOJA ' + pub['number'] not in await di.inner_text('#drv'))
            await di.close()
            await op.wait_for_timeout(600); await op.evaluate('()=>Publisher.render()'); await op.wait_for_timeout(400)
            res('2B1-04b', 'Operario ve NOTIFICADA cuando llegó al celular', await op.locator('#pubStatus [data-st="NOTIFICADA"].on').count() == 1)
            await cr.click('[data-open]'); await cr.wait_for_timeout(600)
            r = await cr.evaluate('()=>JSON.parse(localStorage.getItem("okd_online_demo_v2")).routes2[0]')
            res('2B1-07', 'Abrir la hoja registra VISTA y NO inicia', r['viewed_at'] and not r['started_at'] and r['operational_status'] == 'PUBLICADA' and await cr.locator('#drvStart').count() == 1)
            await cr.click('#drvStart'); await cr.wait_for_timeout(600)
            r = await cr.evaluate('()=>JSON.parse(localStorage.getItem("okd_online_demo_v2")).routes2[0]')
            res('2B1-08', 'INICIAR RECORRIDO: EN CURSO', r['operational_status'] == 'EN_CURSO' and r['started_at'])
            await op.evaluate('()=>Publisher.render()'); await op.wait_for_timeout(500)
            res('2B1-08b', 'Operario ve VISTA e INICIADA en vivo', await op.locator('#pubStatus [data-st="VISTA"].on').count() == 1 and await op.locator('#pubStatus [data-st="INICIADA"].on').count() == 1)
            await cr.click('#drvFin', timeout=2000) if await cr.is_enabled('#drvFin') else None
            res('2B1-13 (UI)', 'FINALIZAR deshabilitado con entregas pendientes', await cr.is_disabled('#drvFin'))
            await resolve(cr, 0, 'ENTREGADO')  # 2B.3: receptor + firma + CUIL + cobranza + ubicación
            await cr.click('.drv-stop >> nth=1 >> [data-o="ENTREGA_PARCIAL"]'); await cr.click('.drv-stop >> nth=1 >> [data-save]'); await cr.wait_for_timeout(300)
            e = await cr.inner_text('.drv-stop >> nth=1 >> .shiperr')
            res('2B1-10 (UI)', 'ENTREGA PARCIAL exige observación', 'observación' in e, e)
            await cr.click('.drv-stop >> nth=1 >> [data-o="NO_ENTREGADO"]'); await cr.click('.drv-stop >> nth=1 >> [data-save]'); await cr.wait_for_timeout(300)
            res('2B1-11 (UI)', 'NO ENTREGADO exige motivo', 'motivo' in await cr.inner_text('.drv-stop >> nth=1 >> .shiperr'))
            await cr.click('.drv-stop >> nth=1 >> [data-o="REPROGRAMAR"]'); await cr.click('.drv-stop >> nth=1 >> [data-save]'); await cr.wait_for_timeout(300)
            res('2B1-12 (UI)', 'REPROGRAMAR exige motivo', 'motivo' in await cr.inner_text('.drv-stop >> nth=1 >> .shiperr'))
            r = await cr.evaluate('()=>JSON.parse(localStorage.getItem("okd_online_demo_v2")).routes2[0].stops[0]')
            res('2B1-09', 'ENTREGADO guardado con hora y actor', r['outcome'] == 'ENTREGADO' and r['outcome_by'] == 'u-cristian' and r['outcome_at'], r['outcome'])
            # corte de conexión
            await cr.evaluate('()=>{window.OKD_NET={offline:true};window.dispatchEvent(new Event("okd-net"))}'); await cr.wait_for_timeout(300)
            live1 = await cr.inner_text('#drvLive')
            await resolve(cr, 1, 'ENTREGA_PARCIAL', note='Faltó una caja')
            q = await cr.evaluate('()=>JSON.parse(localStorage.getItem("okd_drv_queue:u-cristian"))')
            srv_before = await cr.evaluate('()=>JSON.parse(localStorage.getItem("okd_online_demo_v2")).routes2[0].stops[1].outcome')
            await cr.evaluate('()=>{window.OKD_NET={offline:false};window.dispatchEvent(new Event("okd-net"))}'); await cr.wait_for_timeout(1500)
            live2 = await cr.inner_text('#drvLive'); srv = await cr.evaluate('()=>JSON.parse(localStorage.getItem("okd_online_demo_v2"))')
            opid = q[0]['op_id'] if q else None
            again = await cr.evaluate('(id)=>window.OKD_ONLINE.api.setStopOutcome(JSON.parse(localStorage.getItem("okd_online_demo_v2")).routes2[0].stops[1].id,"NO_ENTREGADO",null,"otro",id).then(s=>s.outcome)', opid)
            res('2B1-17', 'Sin conexión: queda en cola (SIN CONEXIÓN), sincroniza al volver y un reintento no duplica', live1 == 'SIN CONEXIÓN' and len(q) == 1 and srv_before == 'PENDIENTE' and srv['routes2'][0]['stops'][1]['outcome'] == 'ENTREGA_PARCIAL' and live2 == 'EN VIVO' and again == 'ENTREGA_PARCIAL' and list(srv['ops'].values()).count(srv['routes2'][0]['stops'][1]['id']) == 1, f'{live1} → {live2}, cola {len(q)}, reintento {again}')
            await cr.click('#drvFin'); await cr.wait_for_timeout(800)
            r = await cr.evaluate('()=>JSON.parse(localStorage.getItem("okd_online_demo_v2")).routes2[0]')
            res('2B1-14 (UI)', 'FINALIZAR HOJA: COMPLETADA, resumen y solo lectura', r['operational_status'] == 'COMPLETADA' and r['final_summary'] == {'ENTREGADO': 1, 'ENTREGA_PARCIAL': 1} and 'solo lectura' in await cr.inner_text('#drv') and await cr.locator('[data-o]').count() == 0, json.dumps(r['final_summary']))
            # informe
            ad = await ctx.new_page(); await login(ad, 'admin@okdespacho.demo')
            rep = await ad.evaluate('()=>window.OKD_ONLINE.api.reports("preview",{sel:{kind:"7D"}}).then(x=>x.report)')
            fees = [f for f in rep['inputs']['fees_used'] if f['route'] == pub['number']]
            res('2B1-15', 'El informe de Cristian recibe la hoja finalizada (Zona Este, 2 completados)', pub['number'] in rep['inputs']['routes_counted'] and len(fees) == 2 and all(f['zone'] == 'ESTE' for f in fees), str(fees))
            res('2B1-16', 'La mercadería no suma ingreso (solo $13.000 + $13.000 de envío)', sum(f['fee'] for f in fees) == 26000, str(sum(f['fee'] for f in fees)))
            # smoke
            await (ad.click('#btnUsers') if not await ad.is_visible('#usersPanel') else ad.wait_for_timeout(1)); await ad.wait_for_timeout(500)
            res('SMOKE-01', 'Login y Usuarios', await ad.locator('#usersPanel tbody tr').count() >= 6)
            await ad.click('#upClose'); await (ad.click('#btnReports') if not await ad.is_visible('#usersPanel') else ad.wait_for_timeout(1)); await ad.wait_for_timeout(2500)
            res('SMOKE-02', 'Informe abre con sus 6 bloques', await ad.locator('#rpBody .rp-step').count() >= 6)
            res('E-ERR', 'Sin errores de consola', not errs, '; '.join(errs[:2]))
            await b.close()
    finally: server.terminate()
    for r_ in R: print(' | '.join(r_))
    print('TOTAL', sum(1 for x in R if x[2] == 'PASS'), 'PASS /', sum(1 for x in R if x[2] == 'FAIL'), 'FAIL')
asyncio.run(main())
