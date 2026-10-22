"""E2E (modo demo, Chromium, celular 390×844) · recorrido del chofer (V4.16; contrato de la demo: V4.16-PROPUESTA salvo donde se indica VIGENTE).
Transportista EXTERNO (Cristian) y TRANSPORTISTA INTERNO (Gabriel) según la CONFIGURACIÓN del transportista (carriers.kind), no por nombres:
al transportista de Cristian se le cambia el nombre antes de la prueba. Todo con controles reales (abrir hoja, INICIAR, LLEGUÉ, ENTREGADO,
nombre, CUIL, foto del DNI, firma dibujada, GUARDAR, sin conexión). Las hojas se publican con la función de publicación de la demo.
Datos SINTÉTICOS. Código de salida: 0 todo PASS · 1 alguna FAIL · 2 error de preparación o casos faltantes.
Uso: python3 tests/e2e/run_driver_perfiles.py [dist-demo] [carpeta_capturas]"""
import asyncio, os, subprocess, sys, time, socket, traceback, base64
from playwright.async_api import async_playwright
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
DIST = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'dist-demo'); SHOTS = sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, 'tests', 'e2e', 'out', 'driver')
PORT = 4374; R = []; EXPECTED = 16
PNG = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==')
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:230])); print('..', ' | '.join(R[-1]), flush=True)
PUB = '''async()=>{const A=window.OKD_ONLINE.api;
  const mk=(n,extra)=>Object.assign({ready:true, client_name:'CLIENTE QA '+n, client_key:'qa-'+n, address:'Calle Falsa '+n+', Mendoza', zone:'ESTE', order_numbers:[String(n)], merchandise_amount:1000, shipping_fee:0, bultos:null, task:'ENTREGA', stop_type:'PEDIDO'}, extra||{});
  const base={rules_version:1, routing_rules_version:1};
  const loc=(k,name,addr)=>({ready:true, stop_type:'UBICACION_INTERNA', internal_location_key:k, client_name:name, address:addr, order_numbers:[], task:'ENTREGA'});
  const ct = await A.publishRoute(Object.assign({sheet_key:'qa-ct-'+Date.now(), carrier_id:'CT-ESTE', responsable_id:'u-cristian', stops:[mk(81001,{expected_amount:1000})]}, base));
  const ctOld = await A.publishRoute(Object.assign({sheet_key:'qa-ctold-'+Date.now(), carrier_id:'CT-ALR', responsable_id:'u-cristian', stops:[mk(81009,{task:'AMBAS', expected_amount:1000}), mk(81010,{task:'AMBAS', expected_amount:1000})]}, base));
  const gb = await A.publishRoute(Object.assign({sheet_key:'qa-gb-'+Date.now(), carrier_id:'INTERNO', responsable_id:'u-gabriel', vehicle_id:'vh-1',
    stops:[mk(81002), loc('MONTECASEROS','Montecaseros - casa central','Montecaseros 1234, Mendoza'), loc('SAN_JUAN','Sucursal San Juan','San Juan 500, Mendoza')]}, base));
  // el transportista de Cristian se renombra: el perfil sale de la CONFIGURACIÓN (kind), no del nombre
  const d=JSON.parse(localStorage.getItem("okd_online_demo_v2")); (d.carriers||[]).forEach(c=>{ if(c.id==='CT-ESTE'||c.id==='CT-ALR') c.name='TRANSPORTE QA EXTERNO'; });
  d.routes2.forEach(r=>{ if(r.carrier_id==='CT-ESTE'||r.carrier_id==='CT-ALR') r.carrier_name='TRANSPORTE QA EXTERNO'; });
  const old=d.routes2.find(r=>r.id===ctOld.id); Object.assign(old.stops[0], {collection_status:'COBRO_PARCIAL', collected_amount:400, payment_mode:'EFECTIVO', collection_note:'registrada antes'});   // cobranza previa
  localStorage.setItem("okd_online_demo_v2", JSON.stringify(d));
  return {ct:ct.id, ctOld:ctOld.id, gb:gb.id};}'''
DB = '''(rid)=>{const d=JSON.parse(localStorage.getItem("okd_online_demo_v2")); const r=(d.routes2||[]).find(x=>x.id===rid);
  return r?r.stops.map(s=>({type:s.stop_type||'PEDIDO', name:s.client_name, outcome:s.outcome, col:s.collection_status||null, amt:s.collected_amount==null?null:s.collected_amount, mode:s.payment_mode||null})):null}'''
ASSOC = '''(sid)=>{const d=JSON.parse(localStorage.getItem("okd_online_demo_v2")); const e=(d.evidence||{})[sid]||{}; const idn=e.cuil?((d.identity||{})[e.cuil]||{}):{};
  const job=(d.customerJobs||[]).find(j=>j.stop_id===sid); return {cuil:e.cuil||null, email:e.receiver_email||null, name:e.receiver_name||null, dni:idn.storage_path||null,
  dniStored:!!(idn.storage_path&&(d.storage||{})[idn.storage_path]), receipt:!!(d.receipts||{})[sid], job:job?job.kind:null}}'''
FORM = '''(sid)=>{const f=document.querySelector('.drv-stop[data-s="'+sid+'"] .drv-form'); if(!f||f.hidden) return null; const has=s=>!!f.querySelector(s);
  return {recv:has('[data-f="recv"]'), sign:has('[data-sig]'), cuil:has('[data-f="cuil"]'), email:has('[data-f="email"]'), cob:has('[data-f="cst"]')||has('[data-f="cmode"]')||has('[data-f="cnote"]'),
          cobText:(f.querySelector('.drv-cob')||{}).innerText||'', save:(f.querySelector('[data-save]')||{}).textContent||''}}'''
def serve():
    p = subprocess.Popen([sys.executable, '-m', 'http.server', str(PORT), '--bind', '127.0.0.1'], cwd=DIST, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(60):
        try: socket.create_connection(('127.0.0.1', PORT), 1).close(); return p
        except OSError: time.sleep(0.2)
    raise RuntimeError('servidor no respondió')
async def dismiss(pg):
    for _ in range(3):
        if await pg.locator('#pushLater').count() and await pg.is_visible('#pushLater'): await pg.click('#pushLater'); await pg.wait_for_timeout(300)
        else: break
async def login(pg, email):
    await pg.goto(f'http://127.0.0.1:{PORT}/'); await pg.wait_for_load_state('networkidle'); await pg.wait_for_timeout(500)
    for _ in range(4):
        await pg.fill('#loginEmail', email); await pg.fill('#loginPass', 'demo')
        if await pg.input_value('#loginEmail') == email: break
        await pg.wait_for_timeout(300)
    await pg.click('#loginBtn'); await pg.wait_for_timeout(2500)
    if await pg.locator('#pinA').count() and await pg.is_visible('#pinA'): await pg.fill('#pinA', '123456'); await pg.fill('#pinB', '123456'); await pg.click('#pinGo'); await pg.wait_for_timeout(900)
    await pg.wait_for_timeout(1500); await dismiss(pg)
async def open_route(pg, rid, km=None):
    await dismiss(pg); await pg.locator(f'[data-open="{rid}"]').click(); await pg.wait_for_timeout(1200)
    if km is not None and await pg.locator('#drvKmIni').count(): await pg.fill('#drvKmIni', str(km))
    if await pg.locator('#drvStart').count(): await pg.click('#drvStart'); await pg.wait_for_timeout(1500)
async def stop_id(pg, rid, idx): return await pg.evaluate(f'()=>{{const r=(JSON.parse(localStorage.getItem("okd_online_demo_v2")).routes2||[]).find(x=>x.id==="{rid}"); return r.stops[{idx}].id}}')
async def choose(pg, sid, o): await pg.locator(f'.drv-stop[data-s="{sid}"] [data-o="{o}"]').click(); await pg.wait_for_timeout(500)
async def sign(pg, sid):
    cv = pg.locator(f'.drv-stop[data-s="{sid}"] [data-sig]'); await cv.scroll_into_view_if_needed(); bb = await cv.bounding_box()
    await pg.mouse.move(bb['x'] + 20, bb['y'] + 20); await pg.mouse.down()
    for i in range(1, 12): await pg.mouse.move(bb['x'] + 20 + i * 18, bb['y'] + 20 + (i % 3) * 14)
    await pg.mouse.up(); await pg.wait_for_timeout(200)
async def fill_id(pg, sid, cuil, png):
    f = pg.locator(f'.drv-stop[data-s="{sid}"] [data-f="cuil"]'); await f.fill(cuil); await f.press('Tab'); await pg.wait_for_timeout(900)   # un solo "change", como una persona
    fi = pg.locator(f'.drv-stop[data-s="{sid}"] [data-dnifile]')
    if await fi.count(): await fi.set_input_files(png); await pg.wait_for_timeout(900)
async def save(pg, sid):
    await pg.locator(f'.drv-stop[data-s="{sid}"] [data-save]').click(); await pg.wait_for_timeout(1800)
    return await pg.evaluate(f'()=>{{const e=document.querySelector(\'.drv-stop[data-s="{sid}"] .shiperr\'); return e&&!e.hidden?e.textContent:null}}')
async def main():
    if not os.path.isfile(os.path.join(DIST, 'index.html')): raise RuntimeError('falta el build demo en ' + DIST)
    os.makedirs(SHOTS, exist_ok=True); png = os.path.join(SHOTS, '_dni_sintetico.png'); open(png, 'wb').write(PNG)
    srv = serve()
    try:
        async with async_playwright() as p:
          b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
          try:
            mob = dict(viewport={'width': 390, 'height': 844}, device_scale_factor=2, is_mobile=True, has_touch=False, geolocation={'latitude': -32.89, 'longitude': -68.84}, permissions=['geolocation'])
            adm = await (await b.new_context(viewport={'width': 1280, 'height': 900})).new_page()
            await adm.goto(f'http://127.0.0.1:{PORT}/'); await adm.evaluate('()=>localStorage.clear()'); await login(adm, 'admin@okdespacho.demo')
            ids = await adm.evaluate(PUB); state = await adm.context.storage_state(); await adm.context.close()
            # ================= CRISTIAN · transportista EXTERNO =================
            cctx = await b.new_context(storage_state=state, **mob); pg = await cctx.new_page(); dialogs = []
            pg.on('dialog', lambda d: (dialogs.append(d.message), asyncio.ensure_future(d.accept())))
            await login(pg, 'cristian@okdespacho.demo'); await open_route(pg, ids['ct'])
            s1 = await stop_id(pg, ids['ct'], 0)
            arrive = await pg.locator(f'.drv-stop[data-s="{s1}"] [data-arrive]').count()
            await choose(pg, s1, 'ENTREGADO'); f1 = await pg.evaluate(FORM, s1)
            res('DRV-01 Cristian (configuración EXTERNO, transportista renombrado): sin LLEGADA A DESTINO ni cobranza; pide email', arrive == 0 and f1 and not f1['cob'] and f1['email'], {'llegada': arrive, 'form': f1})
            await pg.locator(f'.drv-stop[data-s="{s1}"] [data-f="recv"]').fill('Responsable QA Uno'); await fill_id(pg, s1, '20123456786', png); await sign(pg, s1)
            e_nomail = await save(pg, s1)
            await pg.locator(f'.drv-stop[data-s="{s1}"] [data-f="email"]').fill('receptor.uno@ejemplo.test')
            await pg.locator(f'.drv-stop[data-s="{s1}"] [data-save]').scroll_into_view_if_needed(); await pg.screenshot(path=os.path.join(SHOTS, 'cristian_entregado.png'))
            e1 = await save(pg, s1); st1 = await pg.evaluate(DB, ids['ct'])
            res('DRV-02 Cristian: ENTREGADO elegido una sola vez → nombre + CUIL + foto del DNI + firma → GUARDAR (sin otra confirmación)', f1['recv'] and f1['sign'] and f1['cuil'] and 'GUARDAR' in f1['save']
                and e1 is None and st1[0]['outcome'] == 'ENTREGADO' and not dialogs, {'error': e1, 'parada': st1[0], 'dialogos': dialogs})
            # sin cobro = la cobranza queda como se publicó (PENDIENTE, valor por defecto del servidor) sin importe ni medio de pago
            res('DRV-03 guardar la entrega NO registra un cobro', st1[0]['col'] in (None, 'PENDIENTE') and st1[0]['amt'] is None and st1[0]['mode'] is None, st1[0])
            a1 = await pg.evaluate(ASSOC, s1)
            res('DRV-14 Cristian: email obligatorio; entrega ↔ receptor ↔ email ↔ CUIL ↔ foto del DNI vinculada y recuperable; Recibido Conforme encolado (simulado)',
                e_nomail and 'email' in e_nomail.lower() and a1['cuil'] == '20123456786' and a1['email'] == 'receptor.uno@ejemplo.test' and a1['dni'] and a1['dniStored'] and a1['receipt'] and a1['job'] == 'RECIBIDO_CONFORME', {'sin_email': e_nomail, 'asoc': a1})
            # hoja publicada ANTES del cambio con task AMBAS: el servidor vigente exige cobranza → bloque de compatibilidad explicado
            await pg.locator('#drvBack').click(); await pg.wait_for_timeout(800); await open_route(pg, ids['ctOld']); s9 = await stop_id(pg, ids['ctOld'], 0)
            await choose(pg, s9, 'ENTREGADO'); f9 = await pg.evaluate(FORM, s9)
            await pg.locator(f'.drv-stop[data-s="{s9}"] [data-f="recv"]').fill('Responsable QA Viejo'); await pg.locator(f'.drv-stop[data-s="{s9}"] [data-f="email"]').fill('viejo@ejemplo.test')
            await fill_id(pg, s9, '20123456786', png); await sign(pg, s9); e9 = await save(pg, s9); so = await pg.evaluate(DB, ids['ctOld'])
            res('DRV-04 hoja ANTIGUA (AMBAS): sin cobranza en el formulario; se guarda y la cobranza registrada antes se CONSERVA (contrato propuesto)', f9 and not f9['cob'] and e9 is None
                and so[0]['outcome'] == 'ENTREGADO' and so[0]['col'] == 'COBRO_PARCIAL' and so[0]['amt'] == 400 and so[0]['mode'] == 'EFECTIVO', {'form': f9, 'error': e9, 'parada': so[0]})
            # mismo caso con el servidor VIGENTE (sin la propuesta): lo rechaza → depende del cambio pendiente
            await pg.evaluate('()=>localStorage.setItem("okd_demo_contract","VIGENTE")'); s10 = await stop_id(pg, ids['ctOld'], 1)
            await choose(pg, s10, 'ENTREGADO'); await pg.locator(f'.drv-stop[data-s="{s10}"] [data-f="recv"]').fill('Responsable QA Viejo'); await pg.locator(f'.drv-stop[data-s="{s10}"] [data-f="email"]').fill('viejo@ejemplo.test')
            await fill_id(pg, s10, '20123456786', png); await sign(pg, s10); e10 = await save(pg, s10)
            if not e10: e10 = await pg.evaluate('()=>{const t=document.getElementById("drvToast"); return t&&!t.hidden?t.textContent:null}')   # rechazo del servidor → aviso flotante
            await pg.evaluate('()=>localStorage.removeItem("okd_demo_contract")')
            res('DRV-15 con el servidor VIGENTE la hoja antigua sin cobranza es RECHAZADA (COLLECTION_REQUIRED): requiere aplicar la propuesta antes de publicar V4.16',
                bool(e10) and 'cobranza' in e10.lower() and (await pg.evaluate(DB, ids['ctOld']))[1]['outcome'] == 'PENDIENTE', e10)
            await cctx.close()
            # ================= GABRIEL · transportista INTERNO =================
            gctx = await b.new_context(storage_state=state, **mob); pg = await gctx.new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
            await login(pg, 'gabriel@okdespacho.demo'); await open_route(pg, ids['gb'], km=50100)
            sc, sm, ss = [await stop_id(pg, ids['gb'], i) for i in range(3)]
            arr = await pg.locator(f'.drv-stop[data-s="{sc}"] [data-arrive]').count()
            res('DRV-05 Gabriel conserva LLEGADA A DESTINO', arr == 1, arr)
            await pg.locator(f'.drv-stop[data-s="{sc}"] [data-arrive]').click(); await pg.wait_for_timeout(1500)
            # entrega COMERCIAL: nombre + CUIL + foto del DNI + firma
            await choose(pg, sc, 'ENTREGADO'); fc = await pg.evaluate(FORM, sc)
            await pg.locator(f'.drv-stop[data-s="{sc}"] [data-f="recv"]').fill('Responsable QA Dos'); await sign(pg, sc)
            await pg.locator(f'.drv-stop[data-s="{sc}"] [data-f="email"]').fill('receptor.dos@ejemplo.test')
            e_no_cuil = await save(pg, sc)
            await fill_id(pg, sc, '20987654321', png)
            await pg.locator(f'.drv-stop[data-s="{sc}"] [data-save]').scroll_into_view_if_needed(); await pg.screenshot(path=os.path.join(SHOTS, 'gabriel_entrega_cliente.png'))
            e_c = await save(pg, sc); stg = await pg.evaluate(DB, ids['gb'])
            ag = await pg.evaluate(ASSOC, sc)
            res('DRV-06 entrega comercial de Gabriel: exige email, CUIL y foto del DNI (además de nombre y firma) y guarda', fc and fc['cuil'] and fc['email'] and fc['recv'] and fc['sign'] and not fc['cob'] and e_no_cuil and 'CUIL' in e_no_cuil
                and e_c is None and stg[0]['outcome'] == 'ENTREGADO', {'form': fc, 'sin_cuil': e_no_cuil, 'parada': stg[0]})
            res('DRV-16 Gabriel (INTERNO): foto del DNI VINCULADA y recuperable desde la entrega, email y Recibido Conforme encolado (simulado)',
                ag['cuil'] == '20987654321' and ag['email'] == 'receptor.dos@ejemplo.test' and ag['dni'] and ag['dniStored'] and ag['receipt'] and ag['job'] == 'RECIBIDO_CONFORME', ag)
            # MONTECASEROS (ubicación interna): solo nombre y apellido + firma
            if await pg.locator(f'.drv-stop[data-s="{sm}"] [data-arrive]').count(): await pg.locator(f'.drv-stop[data-s="{sm}"] [data-arrive]').click(); await pg.wait_for_timeout(1500)
            await choose(pg, sm, 'ENTREGADO'); fm = await pg.evaluate(FORM, sm)
            e_m0 = await save(pg, sm)
            await pg.locator(f'.drv-stop[data-s="{sm}"] [data-f="recv"]').fill('Encargado Sucursal QA'); await sign(pg, sm)
            await pg.locator(f'.drv-stop[data-s="{sm}"] [data-save]').scroll_into_view_if_needed(); await pg.screenshot(path=os.path.join(SHOTS, 'gabriel_sucursal_montecaseros.png'))
            e_m = await save(pg, sm); stg = await pg.evaluate(DB, ids['gb'])
            res('DRV-07 Montecaseros: solo nombre y apellido + firma (sin CUIL, DNI ni cobranza)', fm and fm['recv'] and fm['sign'] and not fm['cuil'] and not fm['cob'] and not fm['email']
                and e_m0 and e_m is None and stg[1]['outcome'] == 'ENTREGADO', {'form': fm, 'vacio': e_m0, 'parada': stg[1]})
            # SAN JUAN + SIN CONEXIÓN: se guarda en el celular y se sincroniza al volver
            if await pg.locator(f'.drv-stop[data-s="{ss}"] [data-arrive]').count(): await pg.locator(f'.drv-stop[data-s="{ss}"] [data-arrive]').click(); await pg.wait_for_timeout(1500)
            await choose(pg, ss, 'ENTREGADO'); fs = await pg.evaluate(FORM, ss)
            await pg.locator(f'.drv-stop[data-s="{ss}"] [data-f="recv"]').fill('Encargado San Juan QA'); await sign(pg, ss)
            res('DRV-08 San Juan: solo nombre y apellido + firma', fs and fs['recv'] and fs['sign'] and not fs['cuil'] and not fs['cob'], fs)
            await gctx.set_offline(True); await pg.evaluate('()=>window.dispatchEvent(new Event("offline"))'); await pg.wait_for_timeout(500)
            e_s = await save(pg, ss); q = await pg.evaluate('()=>{const k=Object.keys(localStorage).find(k=>/drv.*q|queue/i.test(k)); try{return k?JSON.parse(localStorage.getItem(k)).length:null}catch(e){return null}}')
            off_srv = (await pg.evaluate(DB, ids['gb']))[2]['outcome']
            await gctx.set_offline(False); await pg.evaluate('()=>window.dispatchEvent(new Event("online"))'); await pg.wait_for_timeout(4000)
            on_srv = (await pg.evaluate(DB, ids['gb']))[2]['outcome']
            res('DRV-09 sin conexión: se guarda en el celular y al volver se sincroniza igual', e_s is None and off_srv == 'PENDIENTE' and on_srv == 'ENTREGADO', {'cola': q, 'offline': off_srv, 'online': on_srv})
            # TAREA agregada por el chofer: sin receptor ni firma
            await pg.locator('#drvAddOpen').click(); await pg.wait_for_timeout(300); await pg.fill('#naName', 'Retirar documentación QA'); await pg.click('#naSave'); await pg.wait_for_timeout(1800)
            tid = await pg.evaluate(f'()=>{{const r=(JSON.parse(localStorage.getItem("okd_online_demo_v2")).routes2||[]).find(x=>x.id==="{ids["gb"]}"); const t=r.stops.find(s=>s.stop_type==="TAREA"); return t?t.id:null}}')
            if tid and await pg.locator(f'.drv-stop[data-s="{tid}"] [data-arrive]').count(): await pg.locator(f'.drv-stop[data-s="{tid}"] [data-arrive]').click(); await pg.wait_for_timeout(1500)
            ft = None; e_t = 'sin TAREA'
            if tid: await choose(pg, tid, 'ENTREGADO'); ft = await pg.evaluate(FORM, tid); e_t = await save(pg, tid)
            stg = await pg.evaluate(DB, ids['gb']); tarea = next((x for x in stg if x['type'] == 'TAREA'), {})
            res('DRV-10 TAREA sigue funcionando (sin receptor ni firma)', ft is not None and not ft['recv'] and not ft['sign'] and e_t is None and tarea.get('outcome') == 'ENTREGADO', {'form': ft, 'tarea': tarea})
            res('DRV-11 ningún flujo (hojas nuevas y antiguas) pide cobranza, medio de pago ni motivo de cobranza', not any(x and x['cob'] for x in (f1, f9, fc, fm, fs, ft)), [bool(x and x['cob']) for x in (f1, f9, fc, fm, fs, ft)])
            res('DRV-12 ninguna entrega de Gabriel registró un cobro', all(x['col'] in (None, 'PENDIENTE') and x['amt'] is None and x['mode'] is None for x in stg), stg)
            ui_txt = await pg.evaluate('()=>document.body.innerText')
            res('DRV-13 botón final GUARDAR en todos los formularios', all(x and 'GUARDAR' in x['save'] for x in (f1, fc, fm, fs, ft)) and 'COBRANZA' not in ui_txt.upper(), [x and x['save'] for x in (f1, fc, fm, fs, ft)])
            await gctx.close()
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
