"""Revisión responsive en Chromium (viewports emulados, NO celular real): app del Transportista Interno (traslado con varios pedidos,
observación, recepción interna, TAREA, + AGREGAR PARADA) y constructor (ubicación interna, tabla, composer). Mide desborde horizontal,
elementos más anchos que la pantalla, botones fuera de pantalla y botones demasiado chicos. Guarda capturas en tests/e2e/out/responsive/."""
import asyncio, os, subprocess, time, socket, json
from playwright.async_api import async_playwright
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
OUT = os.path.join(ROOT, 'tests', 'e2e', 'out', 'responsive'); os.makedirs(OUT, exist_ok=True)
CHROME = os.environ.get('CHROMIUM_PATH', '/opt/pw-browsers/chromium-1194/chrome-linux/chrome')
PORT = 4198; URL = f'http://localhost:{PORT}/'; API = 'window.OKD_ONLINE.api'
MOBILE = [(390, 844)] if os.environ.get('ONE') else [(360, 800), (390, 844), (412, 915), (430, 932)]
DESKTOP = [] if os.environ.get('ONE') else [(1920, 1080), (1440, 900), (1366, 768), (1280, 720)]
ZOOMS = [1.0, 1.25, 1.5]
R = []
def res(n, name, ok, det=''): R.append((n, name, 'PASS' if ok else 'FAIL', str(det)[:200])); print('..', n, R[-1][2], det if not ok else '', flush=True)
MEASURE = """(sel)=>{const W=document.documentElement.clientWidth, over=document.documentElement.scrollWidth-W, root=sel?document.querySelector(sel):document.body;
  const wide=[...root.querySelectorAll('*')].filter(e=>{const r=e.getBoundingClientRect(), cs=getComputedStyle(e); if(!r.width||cs.position==='fixed'||cs.visibility==='hidden') return false;
     let p=e.parentElement; while(p){const o=getComputedStyle(p).overflowX; if(o==='auto'||o==='scroll') return false; p=p.parentElement;} return r.right>W+1||r.left<-1;}).slice(0,5).map(e=>(e.id||e.className||e.tagName)+'');
  const btns=[...root.querySelectorAll('button,.btn,input,select,textarea,[data-o]')].filter(e=>{const r=e.getBoundingClientRect(); return r.width>0&&r.height>0&&getComputedStyle(e).visibility!=='hidden';});
  const small=btns.filter(e=>{const r=e.getBoundingClientRect(); return e.tagName==='BUTTON'&&(r.height<30||r.width<30);}).map(e=>e.textContent.trim().slice(0,15)||e.className);
  const outside=btns.filter(e=>{const r=e.getBoundingClientRect(); return r.right>W+1||r.left<-1;}).map(e=>e.textContent.trim().slice(0,15)||e.id);
  const cut=[...root.querySelectorAll('.drv-obs span,.drv-locorders span,.drv-sh b,.drv-loc small')].filter(e=>e.scrollWidth>e.clientWidth+2&&getComputedStyle(e).overflow==='hidden').length;
  return {W, over, wide, small:[...new Set(small)].slice(0,6), outside:[...new Set(outside)].slice(0,6), cut};}"""
async def pin(pg):
    for _ in range(3):
        if await pg.locator('#pinA').count() and await pg.is_visible('#pinA'):
            await pg.fill('#pinA', '123456')
            if await pg.locator('#pinB').count() and await pg.is_visible('#pinB'): await pg.fill('#pinB', '123456')
            await pg.click('#pinGo'); await pg.wait_for_timeout(800)
            if await pg.locator('#pinB').count() and await pg.is_visible('#pinB'): await pg.fill('#pinB', '123456'); await pg.click('#pinGo'); await pg.wait_for_timeout(800)
        else: break
async def login(pg, email):
    await pg.goto(URL); await pg.wait_for_timeout(700)
    if await pg.locator('#loginEmail').count() == 0 or not await pg.is_visible('#loginEmail'):
        await pg.evaluate('()=>window.OKD_LOGOUT && window.OKD_LOGOUT()'); await pg.wait_for_timeout(1300); await pg.goto(URL); await pg.wait_for_timeout(700)
    for _ in range(3):   # el formulario puede volver a dibujarse al cargar: completar, verificar y reintentar
        await pg.wait_for_selector('#loginEmail', state='visible', timeout=10000); await pg.wait_for_timeout(300)
        await pg.fill('#loginEmail', email); await pg.fill('#loginPass', 'demo')
        if await pg.input_value('#loginEmail') == email: break
    await pg.click('#loginBtn'); await pg.wait_for_timeout(2600); await pin(pg)
    await pg.wait_for_timeout(900)
    if await pg.locator('#pushLater').count() and await pg.is_visible('#pushLater'): await pg.click('#pushLater'); await pg.wait_for_timeout(300)
async def main():
    server = subprocess.Popen(['npx', 'vite', 'preview', '--port', str(PORT), '--strictPort', '--host', 'localhost'], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(60):
            try: socket.create_connection(('localhost', PORT), 1).close(); break
            except OSError: time.sleep(0.3)
        async with async_playwright() as p:
            b = await p.chromium.launch(executable_path=CHROME)
            # ---- escenario: hoja interna publicada con traslado (3 pedidos + observación larga), TAREA y en curso
            ctx = await b.new_context(viewport={'width': 1440, 'height': 900}); ad = await ctx.new_page(); await ad.goto(URL); await ad.evaluate('()=>localStorage.clear()'); await login(ad, 'admin@okdespacho.demo')
            st = await ad.evaluate('()=>JSON.parse(localStorage.getItem("okd_online_demo_v2"))'); fr = (st.get('financialRules') or [{'version': 1}])[-1]['version']; rr = (st.get('routingRules') or [{'version': 1}])
            rr = rr[-1]['version'] if rr else 1
            route = await ad.evaluate(f'''()=>{API}.publishRoute({{sheet_key:"RESP-1",carrier_id:"INTERNO",responsable_id:"u-gabriel",vehicle_id:"vh-1",rules_version:{fr},routing_rules_version:{rr},stops:[
              {{client_name:"x",stop_type:"UBICACION_INTERNA",internal_location_key:"MONTECASEROS",order_numbers:["25384","25385","25390","25391","25392","25393"],instructions:"Dejar cajas vacías en el depósito del fondo y retirar las devoluciones firmadas por el encargado de turno antes de las 18 h",ready:true}},
              {{client_name:"Buscar bolsas en el mayorista de la esquina",address:"Avenida Las Heras 1234 esquina San Martín, Ciudad de Mendoza",stop_type:"TAREA",instructions:"Retirar 20 bolsas grandes",contact_name:"Kiosco Don Pepe",contact_phone:"261 555 1234",order_numbers:[],ready:true}},
              {{client_name:"Cliente Comercial SRL",address:"Belgrano 100, Godoy Cruz",order_numbers:["25400"],ready:true}}]}}).catch(e=>({{err:e.message}}))''')
            res('SETUP', 'Escenario publicado (traslado de 6 pedidos + TAREA + pedido)', bool(route.get('id')), route)
            state = await ctx.storage_state(); await ctx.close()
            # ---- celular: app del Transportista Interno
            for (w, h) in MOBILE:
                c = await b.new_context(viewport={'width': w, 'height': h}, device_scale_factor=2, is_mobile=True, has_touch=True, storage_state=state,
                                        geolocation={'latitude': -32.8901, 'longitude': -68.8401}, permissions=['geolocation'])
                pg = await c.new_page(); await login(pg, 'gabriel@okdespacho.demo'); tag = f'movil_{w}x{h}'
                await pg.screenshot(path=os.path.join(OUT, tag + '_1_mis_hojas.png'), full_page=True); m1 = await pg.evaluate(MEASURE, None)
                if w <= 380:
                    pk = await pg.evaluate("""()=>{const x=document.querySelector('.drv-pk'), b=x&&x.querySelector('.btn'); if(!x||!b) return null;
                      const xr=x.getBoundingClientRect(), br=b.getBoundingClientRect(), cs=getComputedStyle(x);
                      return {dir:cs.flexDirection, cardW:Math.round(xr.width), btnW:Math.round(br.width), textW:Math.round((x.querySelector('span')||x).getBoundingClientRect().width)};}""")
                    res('RESP-PK-' + str(w), f'Celular {w}: acceso rápido apilado y legible', bool(pk) and pk['dir'] == 'column' and pk['btnW'] >= pk['cardW'] - 24 and pk['textW'] >= pk['cardW'] - 24, json.dumps(pk))
                try: await pg.wait_for_selector(f'[data-open="{route["id"]}"]', timeout=8000)
                except Exception:
                    await pg.screenshot(path=os.path.join(OUT, tag + '_ERROR.png')); print('DBG', (await pg.inner_text('body'))[:300].replace('\n', ' | ')); raise
                await pg.click(f'[data-open="{route["id"]}"]'); await pg.wait_for_timeout(500)
                if await pg.locator('#drvKmIni').count(): await pg.fill('#drvKmIni', '60000')
                await pg.screenshot(path=os.path.join(OUT, tag + '_2_hoja_km_inicial.png'), full_page=True); m2 = await pg.evaluate(MEASURE, None)
                await pg.click('#drvStart'); await pg.wait_for_timeout(900)
                await pg.screenshot(path=os.path.join(OUT, tag + '_3_traslado_pedidos_observacion.png'), full_page=True); m3 = await pg.evaluate(MEASURE, None)
                card = pg.locator('.drv-stop', has_text='Montecaseros').first
                await card.locator('[data-o="ENTREGADO"]').click(); await pg.wait_for_timeout(400)
                await card.locator('.drv-form [data-f="recv"]').scroll_into_view_if_needed()
                await pg.screenshot(path=os.path.join(OUT, tag + '_4_recepcion_interna_firma.png'), full_page=True); m4 = await pg.evaluate(MEASURE, None)
                sig = await card.locator('[data-sig]').bounding_box()
                # el pie fijo (KM FINAL / FINALIZAR) no debe tapar la firma ni GUARDAR mientras se completa la parada
                await card.locator('[data-sig]').scroll_into_view_if_needed(); await pg.wait_for_timeout(200)
                ov = await pg.evaluate('''()=>{const f=document.querySelector('.drv-foot'); if(!f) return 0; const fr=f.getBoundingClientRect(), H=innerHeight;
                  return [...document.querySelectorAll('.drv-stop .drv-form:not([hidden]) [data-sig], .drv-stop .drv-form:not([hidden]) [data-save]')].filter(e=>{const r=e.getBoundingClientRect();
                    const vis=Math.min(r.bottom,H)>Math.max(r.top,0); return vis && !(r.bottom<=fr.top||r.top>=fr.bottom);}).length;}''')
                res('RESP-OVL-' + str(w), f'Celular {w}: el pie fijo no tapa la firma ni GUARDAR de la parada abierta', ov == 0, 'superpuestos=' + str(ov))
                await pg.click('#drvAddOpen'); await pg.wait_for_timeout(300); await pg.locator('#drvAdd').scroll_into_view_if_needed()
                await pg.screenshot(path=os.path.join(OUT, tag + '_5_agregar_parada.png'), full_page=True); m5 = await pg.evaluate(MEASURE, None)
                # selector nuevo: TIPO → UBICACIÓN INTERNA → búsqueda G2 → elegir → observación (y que el pie no tape nada)
                await pg.click('[data-ntype="UBICACION_INTERNA"]'); await pg.wait_for_timeout(600)
                await pg.locator('#naLocQ').scroll_into_view_if_needed(); await pg.fill('#naLocQ', 'mon'); await pg.wait_for_timeout(300)
                await pg.screenshot(path=os.path.join(OUT, tag + '_6_agregar_parada_tipo_y_busqueda_g2.png'), full_page=True); m6 = await pg.evaluate(MEASURE, None)
                await pg.click('#naLocList [data-lk="MONTECASEROS"]'); await pg.fill('#naIns', 'Retirar documentación firmada por el encargado de depósito'); await pg.locator('#naSave').scroll_into_view_if_needed(); await pg.wait_for_timeout(200)
                await pg.screenshot(path=os.path.join(OUT, tag + '_7_agregar_parada_g2_elegida.png'), full_page=True); m7 = await pg.evaluate(MEASURE, None)
                ov2 = await pg.evaluate('''()=>{const f=document.querySelector('.drv-foot'); if(!f||getComputedStyle(f).position!=='sticky') return 0; const fr=f.getBoundingClientRect(), H=innerHeight;
                  return ['#naSave','#naIns','#naLocPick','[data-ntype="UBICACION_INTERNA"]'].map(q=>document.querySelector(q)).filter(e=>{if(!e) return false; const r=e.getBoundingClientRect();
                    const vis=Math.min(r.bottom,H)>Math.max(r.top,0); return vis && !(r.bottom<=fr.top||r.top>=fr.bottom);}).length;}''')
                seg = await pg.locator('[data-ntype]').evaluate_all('e=>e.map(x=>{const r=x.getBoundingClientRect(); return [Math.round(r.width),Math.round(r.height)]})')
                res('RESP-ADD-' + str(w), f'Celular {w}: selector TAREA / UBICACIÓN INTERNA + búsqueda G2 cómodo (botones ≥ 44 px de alto, sin desborde ni superposición con el pie)',
                    all(m['over'] <= 0 and not m['wide'] and not m['outside'] for m in (m6, m7)) and ov2 == 0 and all(hh >= 44 for _, hh in seg), json.dumps({'m6': m6, 'm7': m7, 'ov': ov2, 'seg': seg})[:190])
                fin = await pg.locator('#drvFin').bounding_box() if await pg.locator('#drvFin').count() else None
                ms = [m1, m2, m3, m4, m5, m6, m7]
                ok = all(m['over'] <= 0 and not m['wide'] and not m['outside'] and m['cut'] == 0 for m in ms) and sig and sig['width'] <= w and (fin is None or fin['width'] <= w)
                res('RESP-MOV-' + str(w), f'Celular {w}x{h}: sin scroll horizontal, nada más ancho que la pantalla, sin controles afuera ni texto cortado (7 pantallas)', ok,
                    json.dumps([{k: v for k, v in m.items() if k != 'W' and v} for m in ms])[:190])
                smalls = sorted(set(sum([m['small'] for m in ms], [])))
                res('RESP-TAP-' + str(w), f'Celular {w}: botones con tamaño táctil ≥ 30 px', not smalls, smalls)
                await c.close()
            # ---- escritorio + zoom de Windows (zoom = viewport CSS más chico con más densidad): constructor con la ubicación interna
            for (w, h) in DESKTOP:
                for z in ZOOMS:
                    vw, vh = int(w / z), int(h / z)
                    c = await b.new_context(viewport={'width': vw, 'height': vh}, device_scale_factor=z, storage_state=state); pg = await c.new_page()
                    await login(pg, 'admin@okdespacho.demo'); await pg.evaluate('()=>{location.hash="#/despacho"}'); await pg.wait_for_timeout(1200)
                    m1 = await pg.evaluate(MEASURE, None)
                    if await pg.locator('#carriers input[value="TRANSPORTE INTERNO"]').count():
                        await pg.locator('#carriers label.carrier', has=pg.locator('input[value="TRANSPORTE INTERNO"]')).click(); await pg.wait_for_timeout(500)
                        await pg.fill('#ids', 'Montecaseros'); await pg.click('#btnSearch'); await pg.wait_for_timeout(900)
                    tag = f'escritorio_{w}x{h}_zoom{int(z*100)}'
                    await pg.screenshot(path=os.path.join(OUT, tag + '_constructor_ubicacion.png'), full_page=False); m2 = await pg.evaluate(MEASURE, None)
                    comp = await pg.locator('#internalLocationComposer').bounding_box() if await pg.locator('#internalLocationComposer').count() else None
                    ok = all(m['over'] <= 0 and not m['outside'] for m in (m1, m2)) and comp is not None and comp['x'] >= 0 and comp['x'] + comp['width'] <= vw + 1
                    res(f'RESP-DSK-{w}-{int(z*100)}', f'Escritorio {w}x{h} zoom {int(z*100)} % (viewport CSS {vw}x{vh}): constructor y composer de ubicación sin desborde', ok,
                        json.dumps([{k: v for k, v in m.items() if k != 'W' and v} for m in (m1, m2)] + [comp])[:190])
                    await c.close()
            await b.close()
    finally: server.terminate()
    for r_ in R: print(' | '.join(r_))
    print('TOTAL', sum(1 for x in R if x[2] == 'PASS'), 'PASS /', sum(1 for x in R if x[2] == 'FAIL'), 'FAIL')
asyncio.run(main())

