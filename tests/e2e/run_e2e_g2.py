"""E2E (modo demo, Chromium) · Revisión G2: ubicación interna con varios pedidos = UNA parada, sin duplicados, reserva atómica,
observación constructor → payload → DB → chofer, recepción interna con firma, TAREA sin firma, parada DRIVER, permisos de G2 y snapshot GPS."""
import asyncio, os, subprocess, time, socket, json
from playwright.async_api import async_playwright
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
FIX = os.environ.get('OKD_FIXTURES', '/mnt/user-data/uploads')
CHROME = os.environ.get('CHROMIUM_PATH', '/opt/pw-browsers/chromium-1194/chrome-linux/chrome')
PORT = 4195; URL = f'http://localhost:{PORT}/'; R = []
FILES = ['informe_pedidos__31_.xlsx', 'SALDO_COMPROBANTE__3_.xlsx', 'SALDO_CUENTA_CORRIENTE.xlsx']
DB = '()=>JSON.parse(localStorage.getItem("okd_online_demo_v2"))'; API = 'window.OKD_ONLINE.api'
def res(n, name, ok, det=''): R.append((n, name, 'PASS' if ok else 'FAIL', str(det)[:180])); print('..', n, R[-1][2], flush=True)
async def pin(pg):
    # bloqueo por PIN del dispositivo (función existente): se configura/desbloquea con 123456
    for _ in range(3):
        if await pg.locator('#pinA').count() and await pg.is_visible('#pinA'):
            await pg.fill('#pinA', '123456')
            if await pg.locator('#pinB').count() and await pg.is_visible('#pinB'): await pg.fill('#pinB', '123456')
            await pg.click('#pinGo'); await pg.wait_for_timeout(900)
            if await pg.locator('#pinB').count() and await pg.is_visible('#pinB'): await pg.fill('#pinB', '123456'); await pg.click('#pinGo'); await pg.wait_for_timeout(900)
        else: break
async def login(pg, email):
    await pg.goto(URL); await pg.wait_for_timeout(700)
    if await pg.locator('#loginEmail').count() == 0 or not await pg.is_visible('#loginEmail'):
        await pg.evaluate('()=>window.OKD_LOGOUT && window.OKD_LOGOUT()'); await pg.wait_for_timeout(1500); await pg.goto(URL); await pg.wait_for_timeout(700)
    for _ in range(3):   # el formulario puede volver a dibujarse al cargar: completar, verificar y reintentar
        await pg.wait_for_selector('#loginEmail', state='visible', timeout=10000); await pg.wait_for_timeout(300)
        await pg.fill('#loginEmail', email); await pg.fill('#loginPass', 'demo')
        if await pg.input_value('#loginEmail') == email: break
    await pg.click('#loginBtn'); await pg.wait_for_timeout(2600)
    await pin(pg)
async def sign(pg, sel):
    b = await pg.locator(sel).bounding_box(); await pg.mouse.move(b['x'] + 20, b['y'] + 30); await pg.mouse.down(); await pg.mouse.move(b['x'] + 120, b['y'] + 70, steps=6); await pg.mouse.up()
async def main():
    server = subprocess.Popen(['npx', 'vite', 'preview', '--port', str(PORT), '--strictPort', '--host', 'localhost'], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(60):
            try: socket.create_connection(('localhost', PORT), 1).close(); break
            except OSError: time.sleep(0.3)
        async with async_playwright() as p:
            b = await p.chromium.launch(executable_path=CHROME)
            ctx = await b.new_context(viewport={'width': 1440, 'height': 900}, geolocation={'latitude': -32.8901, 'longitude': -68.8401}, permissions=['geolocation']); errs = []
            def ps(pg): pg.on('pageerror', lambda e: errs.append(str(e))); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
            ad = await ctx.new_page(); ps(ad); await ad.goto(URL); await ad.evaluate('()=>localStorage.clear()'); await login(ad, 'admin@okdespacho.demo')
            # Operario Depósito y Superior Despacho (fixture: invitación ya aceptada)
            await ad.evaluate(f'''async()=>{{const A={API};
              await A.action("create",{{full_name:"Operario G2",email:"op.g2@okdespacho.demo",role:"OPERARIO_DEPOSITO",active:true}});
              await A.action("create",{{full_name:"Superior G2",email:"sup.g2@okdespacho.demo",role:"SUPERVISOR_DESPACHO",active:true}});}}''')
            await ad.evaluate('()=>{const k="okd_online_demo_v2",d=JSON.parse(localStorage.getItem(k)); d.users.forEach(u=>{ if (/op\\.g2|sup\\.g2/.test(u.email)) u.status="ACTIVO"; }); localStorage.setItem(k, JSON.stringify(d));}')
            # ===== Permisos G2 por rol =====
            op = await ctx.new_page(); ps(op); await login(op, 'op.g2@okdespacho.demo')
            sp = await ctx.new_page(); ps(sp); await login(sp, 'sup.g2@okdespacho.demo')
            r_op = await op.evaluate(f'async()=>{{const l=await {API}.listInternalLocations(); let w; try {{ await {API}.saveInternalLocation({{location_key:"MONTECASEROS",name:"X",lat:0,lon:0}}); w="OK"; }} catch(e) {{ w=e.message; }} return [l.length, w]; }}')
            r_sp = await sp.evaluate(f'async()=>{{const l=await {API}.listInternalLocations(); let w; try {{ await {API}.saveInternalLocation({{location_key:"MONTECASEROS",name:"X",lat:0,lon:0}}); w="OK"; }} catch(e) {{ w=e.message; }} return [l.length, w]; }}')
            res('G2-ROL-01', 'Operario y Superior LEEN G2 y NO lo modifican', r_op[0] == 2 and r_sp[0] == 2 and 'FORBIDDEN' in r_op[1] and 'FORBIDDEN' in r_sp[1], str(r_op) + str(r_sp))
            # ===== Constructor (Operario): Montecaseros + 3 pedidos = UNA parada =====
            await op.evaluate('()=>{location.hash="#/despacho"}'); await op.wait_for_timeout(1200)
            await op.set_input_files('.file[data-kind="pedidos"] input', [os.path.join(FIX, f) for f in FILES])
            for _ in range(200):
                await op.wait_for_timeout(400)
                if await op.evaluate('()=>typeof OrderIndex!=="undefined" && OrderIndex.size()>0') and await op.eval_on_selector_all('.file.ok', 'e=>e.length') >= 1: break
            await op.wait_for_timeout(1500)
            # 5 pedidos de mercadería sin envío asociado + 1 con envío (trazabilidad del par pedido/envío en UNA parada); se exige que existan
            orders = await op.evaluate('()=>{const out=[]; for (const [id,o] of OrderIndex.byId) { if (!o.isShipping && !(OrderIndex.mainToShips.get(id)||[]).length && !(RouteStore.usedOrders().has(String(id)))) { const r=ShippingMatcher.resolve(id); if (r && !r.shipPending && r.main) out.push(String(id)); } if (out.length>=5) break; } return out;}')
            withShip = await op.evaluate('()=>{for (const [id,o] of OrderIndex.byId) { const sh=OrderIndex.mainToShips.get(id)||[]; if (!o.isShipping && sh.length===1) { const r=ShippingMatcher.resolve(id); if (r && !r.shipPending && r.main && r.ship) return [String(id), String(r.ship.id)]; } } return null;}')
            if len(orders) < 5: raise SystemExit('FIXTURE: el informe de pedidos no tiene 5 pedidos simples (' + str(orders) + ')')
            await op.check('#carriers input[value="TRANSPORTE INTERNO"]'); await op.wait_for_timeout(600)
            await op.fill('#ids', 'Montecaseros'); await op.click('#btnSearch'); await op.wait_for_timeout(900)
            comp = await op.locator('#internalLocationComposer').count()
            await op.fill('#ilOrders', ' '.join(orders[:3])); await op.fill('#ilObs', 'Dejar cajas vacías'); await op.click('#ilAddStop'); await op.wait_for_timeout(1200)
            rows = await op.evaluate('()=>RouteStore.rows.map(r=>({t:r.stopType,k:r.internalLocationKey,o:(r.locationOrders||[]).map(x=>x.main),i:r.instructions,c:r.cliente,d:r.domicilio}))')
            loc = [r for r in rows if r['t'] == 'UBICACION_INTERNA']
            res('LOC-UI-01', 'Montecaseros + 3 pedidos → UNA sola fila UBICACION_INTERNA con los 3 pedidos (sin filas PEDIDO sueltas)', comp == 1 and len(loc) == 1 and loc[0]['o'] == orders[:3] and len(rows) == 1, json.dumps(rows)[:150])
            sk = await op.evaluate('()=>RouteStore.sheetId'); st = await op.evaluate(DB)
            res('RES-UI-01', 'Los 3 pedidos quedaron reservados para este borrador en UNA operación', all(st['reservations'].get(o, {}).get('sheet_key') == sk for o in orders[:3]))
            res('LOC-UI-02', 'Nombre y domicilio vienen de G2 y son de solo lectura en la tabla', loc[0]['c'] == 'Montecaseros - casa central' and loc[0]['d'] == 'Montecaseros 1234, Mendoza'
                and await op.locator('#tbody [data-ro="domicilio"]').count() == 1 and await op.locator('#tbody textarea[data-f="domicilio"]').count() == 0)
            # ===== Pedido con envío asociado: un solo elemento con ambos números, sin otra parada física =====
            if withShip:
                await op.fill('#ids', 'Montecaseros'); await op.click('#btnSearch'); await op.wait_for_timeout(900)
                await op.fill('#ilOrders', ' '.join(orders[:3] + [withShip[0]])); await op.click('#ilAddStop'); await op.wait_for_timeout(1200)
                lo = await op.evaluate('()=>RouteStore.rows.filter(r=>r.stopType==="UBICACION_INTERNA").map(r=>(r.locationOrders||[]).map(o=>[o.main,o.ship]))')
                st = await op.evaluate(DB)
                res('LOC-UI-03', 'Pedido con envío asociado: se conservan ambos números en la MISMA parada (y ambos reservados), sin otra parada física', len(lo) == 1 and [withShip[0], withShip[1]] in lo[0]
                    and st['reservations'].get(withShip[1], {}).get('sheet_key') == sk and await op.evaluate('()=>RouteStore.rows.length') == 1, json.dumps(lo)[:120])
                # se lo saca de nuevo para seguir con el escenario de 3 pedidos
                await op.fill('#ids', 'Montecaseros'); await op.click('#btnSearch'); await op.wait_for_timeout(900)
                await op.fill('#ilOrders', ' '.join(orders[:3])); await op.click('#ilAddStop'); await op.wait_for_timeout(1200)
                st = await op.evaluate(DB)
                res('LOC-UI-04', 'Quitar el pedido con envío libera AMBOS números', withShip[0] not in st['reservations'] and withShip[1] not in st['reservations'])
            else: res('LOC-UI-03', 'Pedido con envío asociado en la misma parada', False, 'FIXTURE: el informe no tiene un pedido con un único envío relacionado')
            # ===== Volver a escribir Montecaseros: edita la MISMA parada (quita uno, cambia observación) =====
            await op.fill('#ids', 'Montecaseros'); await op.click('#btnSearch'); await op.wait_for_timeout(900)
            head = await op.inner_text('#internalLocationComposer'); pre = await op.input_value('#ilOrders')
            await op.fill('#ilOrders', ' '.join([orders[0], orders[2]])); await op.fill('#ilObs', 'Dejar cajas vacías y retirar bolsas'); await op.click('#ilAddStop'); await op.wait_for_timeout(1200)
            rows = await op.evaluate('()=>RouteStore.rows.map(r=>({t:r.stopType,o:(r.locationOrders||[]).map(x=>x.main),i:RouteStore.stopInstructions(r)}))'); st = await op.evaluate(DB)
            res('DUP-UI-01', 'Volver a buscarla abre la parada existente (sin duplicar); quitar un pedido lo libera; editar observación', 'YA ESTÁ EN LA HOJA' in head and pre.split() == orders[:3] and len(rows) == 1
                and rows[0]['o'] == [orders[0], orders[2]] and rows[0]['i'] == 'Dejar cajas vacías y retirar bolsas' and orders[1] not in st['reservations'], json.dumps(rows)[:120])
            # ===== Reserva atómica: el 2º pedido está en otra hoja → no queda NINGUNO reservado =====
            await ad.evaluate(f'(o)=>{API}.reserveOrders("OTRA-HOJA-G2",[o])', orders[4])
            await op.fill('#ids', 'San Juan'); await op.click('#btnSearch'); await op.wait_for_timeout(900)
            await op.fill('#ilOrders', orders[3] + ' ' + orders[4]); await op.click('#ilAddStop'); await op.wait_for_timeout(1200)
            st = await op.evaluate(DB); rows = await op.evaluate('()=>RouteStore.rows.length')
            res('RES-UI-02', 'Pedido 2 ya reservado en otra hoja → el pedido 1 NO queda reservado (sin huérfanos) y no se agrega la parada', orders[3] not in st['reservations'] and rows == 1, str(st['reservations'].get(orders[3])))
            await op.click('#ilCancelStop')
            # ===== TAREA desde el constructor =====
            await op.fill('#ids', 'tarea'); await op.click('#btnSearch'); await op.wait_for_timeout(700)
            await op.wait_for_selector('#internalTaskComposer', timeout=5000)
            await op.fill('#itTitle', 'Buscar bolsas'); await op.fill('#itAddress', 'Las Heras 10, Mendoza'); await op.fill('#itInstructions', 'Retirar 20 bolsas'); await op.fill('#itContact', 'Kiosco'); await op.fill('#itPhone', '261555')
            await op.click('#itAdd'); await op.wait_for_timeout(900)
            rows = await op.evaluate('()=>RouteStore.rows.map(r=>({t:r.stopType,i:RouteStore.stopInstructions(r),pago:r.obsPago||""}))')
            res('TAR-UI-01', 'TAREA agregada con instrucciones en su campo propio (no en observación de pago)', any(r['t'] == 'TAREA' and r['i'] == 'Retirar 20 bolsas' and r['pago'] == '' for r in rows), json.dumps(rows)[:150])
            # ===== Payload publicado (observación → payload) y publicación =====
            pl = await op.evaluate('async()=>{const c={id:"INTERNO",kind:"INTERNO",name:"TRANSPORTE INTERNO"}; return await Publisher.payload(c,"u-gabriel");}')
            ploc = [s for s in pl['stops'] if s['stop_type'] == 'UBICACION_INTERNA']
            res('OBS-UI-01', 'Payload: UNA parada UBICACION_INTERNA con los pedidos agrupados, instructions = observación, sin montos ni email', len(ploc) == 1 and ploc[0]['order_numbers'] == [orders[0], orders[2]]
                and ploc[0]['instructions'] == 'Dejar cajas vacías y retirar bolsas' and ploc[0]['merchandise_amount'] == 0 and ploc[0]['customer_email'] is None, json.dumps(ploc)[:150])
            pl.update({'vehicle_id': 'vh-1', 'rules_version': 1, 'routing_rules_version': 1})
            route = await op.evaluate(f'(p)=>{API}.publishRoute(p).catch(e=>({{err:e.message}}))', pl)
            if route.get('err'):   # versiones de reglas vigentes de la demo
                st = await op.evaluate(DB); fr = st.get('financialRules') or [{'version': 1}]; rr = st.get('routingRules') or [{'version': 1}]
                pl.update({'rules_version': fr[-1]['version'], 'routing_rules_version': rr[-1]['version'] if rr else 1}); route = await op.evaluate(f'(p)=>{API}.publishRoute(p).catch(e=>({{err:e.message}}))', pl)
            st = await op.evaluate(DB); rt = [r for r in st['routes2'] if r['id'] == route.get('id')]
            sl = [x for x in (rt[0]['stops'] if rt else []) if x.get('stop_type') == 'UBICACION_INTERNA']
            res('PUB-UI-01', 'Publicada: UNA route_stop UBICACION_INTERNA con los pedidos, instructions, clave G2 y snapshot GPS', len(sl) == 1 and sl[0]['order_numbers'] == [orders[0], orders[2]]
                and sl[0]['instructions'] == 'Dejar cajas vacías y retirar bolsas' and sl[0]['internal_location_key'] == 'MONTECASEROS' and sl[0]['expected_lat'] == -32.89 and sl[0]['expected_radius_m'] == 200, str(route)[:120])
            # Admin mueve y desactiva Montecaseros DESPUÉS de publicar
            await ad.evaluate(f'()=>{API}.saveInternalLocation({{location_key:"MONTECASEROS",name:"Montecaseros - casa central",address:"otra",lat:-33.5,lon:-69.5,radius_m:50,active:false}})')
            # ===== Chofer (Transportista Interno) =====
            gb = await ctx.new_page(); ps(gb); await login(gb, 'gabriel@okdespacho.demo')
            await gb.click(f'[data-open="{route["id"]}"]'); await gb.wait_for_timeout(500)
            km = (await gb.evaluate(DB))['vehicles'][0]['current_km']
            if await gb.locator('#drvKmIni').count(): await gb.fill('#drvKmIni', str(int(km) + 5))
            await gb.click('#drvStart'); await gb.wait_for_timeout(900)
            card = gb.locator('.drv-stop', has_text='Montecaseros').first
            ctxt = await card.inner_text()
            res('DRV-UI-01', 'El chofer ve UNA tarjeta: nombre, domicilio, TODOS los pedidos y la OBSERVACIÓN', await gb.locator('.drv-stop', has_text='Montecaseros').count() == 1 and all(o in ctxt for o in [orders[0], orders[2]])
                and 'OBSERVACIÓN' in ctxt and 'Dejar cajas vacías y retirar bolsas' in ctxt and 'Montecaseros 1234' in ctxt and 'TRASLADO INTERNO' in ctxt, ctxt[:140].replace('\n', ' | '))
            await card.locator('[data-arrive]').click(); await gb.wait_for_timeout(1200)
            st = await gb.evaluate(DB); sl = [x for x in st['routes2'] if x['id'] == route['id']][0]['stops']; s0 = [x for x in sl if x.get('stop_type') == 'UBICACION_INTERNA'][0]
            al = s0.get('arrive_location') or {}
            res('GPS-UI-01', 'Llegada validada contra el SNAPSHOT de la publicación (G2 movido y desactivado después)', al.get('validation_source') == 'INTERNAL_SNAPSHOT' and al.get('expected_lat') == -32.89 and al.get('radius_m') == 200 and al.get('outside_m') is None, json.dumps(al)[:150])
            await card.locator('[data-o="ENTREGADO"]').click(); await gb.wait_for_timeout(500)
            ftxt = await card.locator('.drv-form').inner_text(); has_mail = await card.locator('.drv-form [data-f="email"]').count()
            await card.locator('[data-save]').click(); await gb.wait_for_timeout(700); e1 = await card.locator('.drv-form .shiperr').inner_text()
            await card.locator('.drv-form [data-f="recv"]').fill('Juan Pérez'); await sign(gb, '.drv-stop:has-text("Montecaseros") [data-sig]')
            await card.locator('[data-save]').click(); await gb.wait_for_timeout(1500)
            st = await gb.evaluate(DB); s0 = [x for x in [x for x in st['routes2'] if x['id'] == route['id']][0]['stops'] if x.get('stop_type') == 'UBICACION_INTERNA'][0]
            ev = st.get('evidence', {}).get(s0['id']) or {}; aud = [a for a in st['audit'] if a['action'] == 'INTERNAL_TRANSFER_RECEIVED']
            jobs = [j for j in st.get('customerJobs', []) if j['stop_id'] == s0['id']]
            res('REC-UI-01', 'Recepción interna: exige receptor + firma; guarda evidencia RECEPCION_INTERNA; sin email/RC comercial', 'RECEPCIÓN INTERNA DE TRASLADO' in ftxt and has_mail == 0 and 'sucursal' in e1.lower()
                and s0['outcome'] == 'ENTREGADO' and ev.get('evidence_kind') == 'RECEPCION_INTERNA' and ev.get('receiver_name') == 'Juan Pérez' and not jobs and s0['id'] not in (st.get('receipts') or {}), e1)
            res('REC-UI-02', 'Trazabilidad: sucursal, pedidos, quién recibió, quién trasladó, hoja y GPS', len(aud) == 1 and aud[0]['after']['order_numbers'] == [orders[0], orders[2]] and aud[0]['after']['receiver_name'] == 'Juan Pérez'
                and aud[0]['after']['internal_location_key'] == 'MONTECASEROS' and aud[0]['after']['gps'].get('validation_source') == 'INTERNAL_SNAPSHOT', json.dumps(aud[0]['after'] if aud else {})[:120])
            # ===== TAREA: REALIZADO sin firma =====
            tcard = gb.locator('.drv-stop', has_text='Buscar bolsas').first
            if await tcard.count():
                await tcard.locator('[data-arrive]').click() if await tcard.locator('[data-arrive]').count() else None; await gb.wait_for_timeout(800)
                await tcard.locator('[data-o="ENTREGADO"]').click(); await gb.wait_for_timeout(400)
                nosig = await tcard.locator('.drv-form [data-sig]').count() == 0
                await tcard.locator('[data-save]').click(); await gb.wait_for_timeout(1300)
                st = await gb.evaluate(DB); t0 = [x for x in [x for x in st['routes2'] if x['id'] == route['id']][0]['stops'] if x.get('stop_type') == 'TAREA'][0]
                res('TAR-UI-02', 'TAREA REALIZADA sin firma ni receptor; sin email ni Recibido Conforme', nosig and t0['outcome'] == 'ENTREGADO' and not [j for j in st.get('customerJobs', []) if j['stop_id'] == t0['id']], t0['outcome'])
            else: res('TAR-UI-02', 'TAREA REALIZADA sin firma', False, 'no se encontró la tarjeta de la TAREA')
            # ===== + AGREGAR PARADA (DRIVER) =====
            await gb.click('#drvAddOpen'); await gb.fill('#naName', 'Banco Nación'); await gb.fill('#naAddr', 'San Martín 1100, Mendoza'); await gb.fill('#naIns', 'Depositar efectivo'); await gb.fill('#naCon', 'Caja')
            await gb.click('#naSave'); await gb.wait_for_timeout(1300)
            st = await gb.evaluate(DB); rr = [x for x in st['routes2'] if x['id'] == route['id']][0]; d0 = [x for x in rr['stops'] if x.get('provenance') == 'DRIVER']
            res('DRV-UI-02', 'Parada agregada por el chofer: TAREA, DRIVER, al final, con instrucciones, versionada y auditada', len(d0) == 1 and d0[0]['stop_type'] == 'TAREA' and d0[0]['instructions'] == 'Depositar efectivo'
                and d0[0]['sequence_number'] == max(x['sequence_number'] for x in rr['stops']) and d0[0]['added_by'] == 'u-gabriel' and any(e['type'] == 'INTERNAL_STOP_ADDED' for e in rr['events'])
                and any(a['action'] == 'INTERNAL_STOP_ADDED' for a in st['audit']) and 'AGREGADA' in await gb.locator('.drv-stop', has_text='Banco Nación').inner_text())
            # ===== PARCHE: el chofer vuelve EXPLÍCITAMENTE a Montecaseros (segunda visita) desde + AGREGAR PARADA =====
            await ad.evaluate(f'()=>{API}.saveInternalLocation({{location_key:"MONTECASEROS",name:"Montecaseros - casa central",address:"Montecaseros 1529, Ciudad Mendoza",lat:-32.80,lon:-68.80,radius_m:120,active:true}})')
            await gb.reload(); await gb.wait_for_timeout(1500); await pin(gb)
            if await gb.locator(f'[data-open="{route["id"]}"]').count(): await gb.click(f'[data-open="{route["id"]}"]'); await gb.wait_for_timeout(600)
            head = await gb.inner_text('.drv-m'); foot = await gb.inner_text('.drv-foot')
            res('WORD-UI-01', 'Hoja interna: los contadores generales dicen PARADAS (no entregas)', 'paradas' in head and 'entregas' not in head and ('paradas por resolver' in foot or 'parada por resolver' in foot), head + ' / ' + foot.replace('\n', ' '))
            await gb.click('#drvAddOpen'); await gb.click('[data-ntype="UBICACION_INTERNA"]'); await gb.wait_for_timeout(700)
            await gb.fill('#naLocQ', 'monte'); await gb.wait_for_timeout(300)
            opts = await gb.eval_on_selector_all('#naLocList [data-lk]', 'e=>e.map(x=>x.dataset.lk)')
            await gb.click('#naLocList [data-lk="MONTECASEROS"]'); await gb.wait_for_timeout(200)
            pick = await gb.inner_text('#naLocPick'); ro = await gb.locator('#drvAdd [data-nt="UBICACION_INTERNA"] input:not(#naLocQ), #drvAdd [data-nt="UBICACION_INTERNA"] textarea').count()
            await gb.fill('#naIns', 'Retirar documentación'); await gb.click('#naSave'); await gb.wait_for_timeout(1400)
            st = await gb.evaluate(DB); rr = [x for x in st['routes2'] if x['id'] == route['id']][0]
            g2d = [x for x in rr['stops'] if x.get('provenance') == 'DRIVER' and x.get('stop_type') == 'UBICACION_INTERNA']
            orig = [x for x in rr['stops'] if x.get('provenance') != 'DRIVER' and x.get('stop_type') == 'UBICACION_INTERNA'][0]
            res('DRVLOC-UI-01', 'El chofer elige Montecaseros en + AGREGAR PARADA: nueva parada futura UBICACION_INTERNA, DRIVER, datos de G2 (solo lectura), GPS/radio de G2, sin pedidos',
                opts == ['MONTECASEROS'] and 'Montecaseros 1529' in pick and ro == 0 and len(g2d) == 1 and g2d[0]['internal_location_key'] == 'MONTECASEROS' and g2d[0]['client_name'] == 'Montecaseros - casa central'
                and g2d[0]['address'] == 'Montecaseros 1529, Ciudad Mendoza' and g2d[0]['expected_lat'] == -32.80 and g2d[0]['expected_radius_m'] == 120 and g2d[0]['order_numbers'] == []
                and g2d[0]['instructions'] == 'Retirar documentación' and g2d[0]['sequence_number'] == max(x['sequence_number'] for x in rr['stops']), json.dumps(g2d)[:150])
            res('DRVLOC-UI-02', 'La parada Montecaseros ORIGINAL no cambió (pedidos y snapshot)', orig['order_numbers'] == [orders[0], orders[2]] and orig['expected_lat'] == -32.89 and orig['outcome'] == 'ENTREGADO')
            # reintento del celular con el MISMO client_op_id → una sola parada
            ver = rr['version']
            await gb.evaluate(f'''async()=>{{const s={{id:"aaaaaaaa-0000-4000-8000-000000000001",stop_type:"UBICACION_INTERNA",internal_location_key:"SAN_JUAN",instructions:"reintento"}};
              await {API}.addInternalStop("{route['id']}", s, {ver}, "op-retry-1"); try {{ await {API}.addInternalStop("{route['id']}", s, {ver}, "op-retry-1"); }} catch(e) {{}} }}''')
            st = await gb.evaluate(DB); rr = [x for x in st['routes2'] if x['id'] == route['id']][0]
            res('DRVLOC-UI-03', 'Reintento con el mismo client_op_id → UNA sola parada', sum(1 for x in rr['stops'] if x.get('instructions') == 'reintento') == 1)
            # cerrar la segunda visita: firma obligatoria aunque no tenga pedidos
            await gb.reload(); await gb.wait_for_timeout(1500); await pin(gb)
            if await gb.locator(f'[data-open="{route["id"]}"]').count(): await gb.click(f'[data-open="{route["id"]}"]'); await gb.wait_for_timeout(600)
            c2 = gb.locator('.drv-stop', has_text='Retirar documentación').first
            ctext = await c2.inner_text()
            await c2.locator('[data-o="ENTREGADO"]').click(); await gb.wait_for_timeout(400)
            await c2.locator('[data-save]').click(); await gb.wait_for_timeout(600); e2 = await c2.locator('.drv-form .shiperr').inner_text()
            await c2.locator('.drv-form [data-f="recv"]').fill('Encargada turno tarde'); await sign(gb, '.drv-stop:has-text("Retirar documentación") [data-sig]')
            await c2.locator('[data-save]').click(); await gb.wait_for_timeout(1500)
            st = await gb.evaluate(DB); d2 = [x for x in [x for x in st['routes2'] if x['id'] == route['id']][0]['stops'] if x.get('instructions') == 'Retirar documentación'][0]
            res('DRVLOC-UI-04', 'Segunda visita sin pedidos: exige receptor + firma; queda RECEPCION_INTERNA sin email comercial', 'AGREGADA' in ctext and 'sucursal' in e2.lower() and d2['outcome'] == 'ENTREGADO'
                and (st.get('evidence', {}).get(d2['id']) or {}).get('evidence_kind') == 'RECEPCION_INTERNA' and not [j for j in st.get('customerJobs', []) if j['stop_id'] == d2['id']], e2)
            res('E-ERR', 'Sin errores de consola', not errs, '; '.join(errs[:2]))
            await b.close()
    finally: server.terminate()
    for r_ in R: print(' | '.join(r_))
    print('TOTAL', sum(1 for x in R if x[2] == 'PASS'), 'PASS /', sum(1 for x in R if x[2] == 'FAIL'), 'FAIL')
    return R
EXPECTED = 23
OK = lambda r: r[2] == 'PASS'
if __name__ == '__main__':
    # 0 = todo PASS · 1 = alguna comprobación FAIL · 2 = excepción, preparación fallida o menos casos de los esperados
    import sys, traceback
    try: RR = asyncio.run(main())
    except SystemExit: raise
    except Exception as e: traceback.print_exc(); print('ERROR: la prueba no pudo completarse:', repr(e)); sys.exit(2)
    if not RR or len(RR) < EXPECTED: print('ERROR: se ejecutaron %d de %d comprobaciones esperadas' % (len(RR or []), EXPECTED)); sys.exit(2)
    sys.exit(1 if any(OK(r) is not True for r in RR) else 0)


