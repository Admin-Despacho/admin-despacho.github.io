"""E2E (modo demo, Chromium) · V4.24 · VER ENTREGA (pestañas por ubicación, línea de tiempo, SIN REGISTRO, firma; permiso signatures.view para
Administrador General y Superior Despacho) y SALIDA Y RECORRIDO (módulo independiente). El recorrido lo hace el chofer REAL en Android con GPS.
Uso: python3 tests/e2e/run_ver_entrega_recorrido.py [dist-demo] [capturas]   ·   Exit 0 todo PASS · 1 alguna FAIL · 2 error. Datos FICTICIOS."""
import asyncio, os, sys, traceback
sys.path.insert(0, os.path.dirname(__file__))
import run_driver_perfiles as dp, run_g2_diamante as gd
from playwright.async_api import async_playwright
dp.PORT = 4402; R = []; EXPECTED = 9
if len(sys.argv) > 1: dp.DIST = sys.argv[1]
SHOTS = sys.argv[2] if len(sys.argv) > 2 else '/tmp/okd_ve_shots'
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:260])); print('..', ' | '.join(R[-1]), flush=True)
S = gd.S
ROLES = {'SUPERVISOR_DESPACHO': 'qa.superior@okdespacho.demo', 'OPERARIO_DEPOSITO': 'qa.operario@okdespacho.demo', 'SOLO_LECTURA': 'qa.lectura@okdespacho.demo'}
ADD_USERS = '''(roles)=>{const k="okd_online_demo_v2", d=JSON.parse(localStorage.getItem(k)); const base=d.users.find(u=>u.role==="ADMIN");
  Object.entries(roles).forEach(([role,email],i)=>{ if(!d.users.some(u=>u.email===email)) d.users.push(Object.assign({}, base, {id:"u-qa-"+i, email, role, full_name:"QA "+role, status:"ACTIVO", carrier_ids:[], extra_perms:[], denied_perms:[]})); });
  localStorage.setItem(k, JSON.stringify(d)); return d.users.length; }'''
TRACE = '''()=>{const p=document.querySelector("#deliveryTraceBox .dt"); if(!p) return null;
  return {tabs:[...p.querySelectorAll("[data-dtab]")].map(b=>b.textContent), sel:(p.querySelector('[data-dtab][aria-selected="true"]')||{}).textContent,
    ev:[...p.querySelectorAll(".dt-ev")].map(e=>({k:e.dataset.ev, none:e.classList.contains("none"), map:!!e.querySelector(".dt-map")})),
    sig:!!p.querySelector(".dt-sig img"), txt:p.textContent, edit:p.querySelectorAll("input,textarea,select,button:not([data-dtab])").length}}'''
async def open_trace(pg, rid, stop_index, tab=None):
    await pg.evaluate('()=>{location.hash="#/historial"}'); await pg.wait_for_timeout(1500)
    if await pg.locator('[data-htab="list"]').count() and await pg.locator('#hList').is_hidden(): await pg.click('[data-htab="list"]'); await pg.wait_for_timeout(500)   # V4.20: Historial reabre la hoja abierta
    if not await pg.locator(f'#histTable tr[data-rid="{rid}"] [data-view]').count():
        return {'norow': await pg.evaluate('()=>[...document.querySelectorAll("#histTable tbody tr")].map(t=>t.textContent.slice(0,60))'), 'hash': await pg.evaluate('()=>location.hash')}
    await pg.locator(f'#histTable tr[data-rid="{rid}"] [data-view]').click(); await pg.wait_for_timeout(1500)
    rows = pg.locator('#hSheet tr[data-stop]')
    if not await pg.locator('#hSheet [data-delivery-detail]').count(): return None
    await rows.nth(stop_index).locator('[data-delivery-detail]').click(); await pg.wait_for_timeout(1500)
    if tab: await pg.locator('#deliveryTraceBox [data-dtab]', has_text=tab).click(); await pg.wait_for_timeout(900)
    return await pg.evaluate(TRACE)

async def main():
    os.makedirs(SHOTS, exist_ok=True); srv = dp.serve()
    try:
        async with async_playwright() as p:
            b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
            try:
                adm = await (await b.new_context(viewport={'width': 1366, 'height': 900})).new_page()
                await adm.goto(f'http://127.0.0.1:{dp.PORT}/'); await adm.evaluate('()=>localStorage.clear()'); await dp.login(adm, 'admin@okdespacho.demo')
                ids = await adm.evaluate(dp.PUB); await adm.evaluate(ADD_USERS, ROLES); state = await adm.context.storage_state(); await adm.context.close()
                # ===== recorrido REAL del chofer interno (Android con GPS) =====
                ctx = await b.new_context(storage_state=state, **gd.MOB); pg = await ctx.new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
                await dp.login(pg, 'gabriel@okdespacho.demo')
                await pg.locator(f'[data-open="{ids["gb"]}"]').click(); await pg.wait_for_timeout(1200)
                start_lbl = await pg.locator('#drvStart').inner_text()
                await pg.fill('#drvKmIni', '50100'); await pg.click('#drvStart'); await pg.wait_for_timeout(2000)
                st = await pg.evaluate(gd.ROUTE, ids['gb']); sc, sm, ss = [x['id'] for x in st['stops']]
                await pg.locator(S(sc, '[data-arrive]')).click(); await pg.wait_for_timeout(1100)
                await dp.choose(pg, sc, 'ENTREGADO'); await pg.fill(S(sc, '[data-f="recv"]'), 'Receptor VE'); await pg.fill(S(sc, '[data-f="cuil"]'), '20987654321')
                await pg.press(S(sc, '[data-f="cuil"]'), 'Tab'); await dp.sign(pg, sc); await dp.save(pg, sc)
                await pg.locator(S(sm, '[data-arrive]')).click(); await pg.wait_for_timeout(1100)
                await gd.resolve_internal(pg, sm, 'ENTREGADO', 'Encargada Montecaseros'); await pg.locator(S(sm, '[data-locfinish]')).click(); await pg.wait_for_timeout(1100)
                await pg.locator(S(sm, '[data-locdepart]')).click(); await pg.wait_for_timeout(1100)   # SALÍ DE MONTECASEROS (opción B)
                await gd.resolve_internal(pg, ss, 'ENTREGADO', 'Encargado San Juan')     # SAN JUAN: recepción SIN tocar LLEGUÉ (caso real reportado)
                await pg.click('#drvDepot'); await pg.wait_for_timeout(1500); await pg.fill('#drvKm', '50250'); await pg.click('#drvFin'); await pg.wait_for_timeout(2000)
                fin = await pg.evaluate('''(rid)=>{const r=JSON.parse(localStorage.getItem("okd_online_demo_v2")).routes2.find(x=>x.id===rid); return {s:r.operational_status, start:r.start_location, depot:!!r.depot_arrived_at}}''', ids['gb'])
                # la hoja interna la PUBLICÓ el Superior de prueba (equipo); la del externo NO (fuera de su equipo)
                await pg.evaluate('''(rid)=>{const k="okd_online_demo_v2", d=JSON.parse(localStorage.getItem(k)); d.routes2.find(r=>r.id===rid).published_by="u-qa-0"; localStorage.setItem(k, JSON.stringify(d));}''', ids['gb'])
                state = await ctx.storage_state(); await ctx.close()
                res('SR-01 SALÍ DEL DEPÓSITO DIAMANTE: el botón de inicio del interno lo dice; reutiliza el inicio (km 50100) y guarda el GPS de la salida; el recorrido llega al cierre',
                    start_lbl == 'SALÍ DEL DEPÓSITO DIAMANTE' and fin['s'] == 'COMPLETADA' and fin['start'] and fin['start'].get('lat') is not None and fin['depot'], {'boton': start_lbl, 'salida': fin['start']})
                # ===== VER ENTREGA (Administrador General) =====
                ctx = await b.new_context(storage_state=state, viewport={'width': 1366, 'height': 900}); pg = await ctx.new_page()
                await pg.goto(f'http://127.0.0.1:{dp.PORT}/'); await dp.login(pg, 'admin@okdespacho.demo')
                m = await open_trace(pg, ids['gb'], 1)
                await pg.screenshot(path=os.path.join(SHOTS, 'ver_entrega_montecaseros.png'), full_page=True)
                res('VE-01 VER ENTREGA (Administrador General): pestañas SOLO de las ubicaciones de la hoja (Montecaseros, San Juan, Depósito Diamante); Montecaseros con LLEGADA, RECEPCIÓN y TERMINÉ registrados, con mapa',
                    m and len(m['tabs']) == 3 and 'MONTECASEROS' in m['tabs'][0] and 'SAN JUAN' in m['tabs'][1] and m['tabs'][2] == 'DEPÓSITO DIAMANTE'
                    and [e['k'] for e in m['ev']] == ['arrive', 'finish', 'locfin', 'locdep'] and not any(e['none'] for e in m['ev']) and all(e['map'] for e in m['ev']), m and {'pestañas': m['tabs'], 'eventos': m['ev']})
                await pg.locator('#deliveryTraceBox [data-dtab]', has_text='SAN JUAN').click(); await pg.wait_for_timeout(1000); sj = await pg.evaluate(TRACE)
                res('VE-02 SAN JUAN recibido SIN tocar LLEGUÉ: la LLEGADA figura SIN REGISTRO (no se usa la hora de recepción); la RECEPCIÓN sí; TERMINÉ SIN REGISTRO',
                    sj['ev'][0]['none'] and not sj['ev'][1]['none'] and sj['ev'][2]['none'] and sj['ev'][3]['none'] and 'SIN REGISTRO' in sj['txt'], sj['ev'])
                await pg.locator('#deliveryTraceBox [data-dtab]', has_text='DEPÓSITO DIAMANTE').click(); await pg.wait_for_timeout(800); dd = await pg.evaluate(TRACE)
                await pg.screenshot(path=os.path.join(SHOTS, 'ver_entrega_deposito_diamante.png'), full_page=True)
                res('VE-03 pestaña DEPÓSITO DIAMANTE: SALIDA (km 50100, GPS), REGRESO (GPS) y CIERRE (km 50250 · 150 km recorridos)',
                    [e['k'] for e in dd['ev']] == ['start', 'depot', 'close'] and not any(e['none'] for e in dd['ev']) and '150 km' in dd['txt'] and '50100' in dd['txt'], dd['ev'])
                e = await open_trace(pg, ids['gb'], 0)
                await pg.screenshot(path=os.path.join(SHOTS, 'ver_entrega_comercial.png'), full_page=True)
                res('VE-04 entrega COMERCIAL: receptor, CUIL, email usado, firma visible, pedidos; SOLO LECTURA (ningún campo ni botón que modifique)',
                    e and e['tabs'][0] == 'ENTREGA' and e['sig'] and 'Receptor VE' in e['txt'] and '20987654321' in e['txt'] and 'SOLO LECTURA' in e['txt'] and e['edit'] == 0, e and {'pestañas': e['tabs'], 'controles': e['edit']})
                # ===== SALIDA Y RECORRIDO (Administrador General) =====
                await pg.evaluate('()=>{location.hash="#/recorridos"}'); await pg.wait_for_timeout(1600)
                await pg.locator(f'#rcTable tr[data-rid="{ids["gb"]}"] [data-rcview]').click(); await pg.wait_for_timeout(1300)
                rc = await pg.evaluate('''()=>[...document.querySelectorAll("#rcTimeline .dt-ev")].map(e=>({t:e.querySelector("b").textContent, none:e.classList.contains("none"), map:!!e.querySelector(".dt-map")}))''')
                await pg.screenshot(path=os.path.join(SHOTS, 'salida_y_recorrido.png'), full_page=True)
                order = [x['t'].split(' · ')[0] for x in rc]
                res('RC-01 SALIDA Y RECORRIDO (módulo propio): salida → Montecaseros (llegada, recepción, finalización, SALIDA) → San Juan (llegada SIN REGISTRO, recepción, finalización y salida SIN REGISTRO) → regreso → cierre; mapa',
                    order[:1] == ['SALIDA DEL DEPÓSITO DIAMANTE'] and order[-2:] == ['REGRESO A DEPÓSITO DIAMANTE', 'CIERRE DE LA HOJA'] and len(rc) == 11 and order[4].startswith('SALIDA DE MONTECASEROS')
                    and [x['none'] for x in rc] == [False, False, False, False, False, True, False, True, True, False, False] and rc[0]['map'], order)
                await ctx.close()
                # ===== permisos por rol =====
                acc = {}
                for role, email in list(ROLES.items()) + [('TRANSPORTISTA_INTERNO', 'gabriel@okdespacho.demo'), ('TRANSPORTISTA_EXTERNO', 'cristian@okdespacho.demo')]:
                    c = await b.new_context(storage_state=state, viewport={'width': 1366, 'height': 900}); q = await c.new_page(); await q.goto(f'http://127.0.0.1:{dp.PORT}/'); await dp.login(q, email)
                    api = await q.evaluate(f'''async()=>{{try{{await window.OKD_ONLINE.api.deliveryTrace("{sc}"); return "VE"}}catch(e){{return e.code||e.message}}}}''')
                    menu = await q.evaluate('()=>!!document.querySelector(\'[data-nav="#/recorridos"]\')')
                    ext_stop = await q.evaluate('''(rid)=>JSON.parse(localStorage.getItem("okd_online_demo_v2")).routes2.find(r=>r.id===rid).stops[0].id''', ids['ct'])
                    other = await q.evaluate(f'''async()=>{{try{{await window.OKD_ONLINE.api.deliveryTrace("{ext_stop}"); return "VE"}}catch(e){{return e.code||e.message}}}}''')
                    btn = None
                    if role == 'SUPERVISOR_DESPACHO':
                        t = await open_trace(q, ids['gb'], 0); btn = bool(t and t.get('sig') and 'Receptor VE' in t.get('txt', '')) or t
                    acc[role] = (api, menu, btn, other); await c.close()
                res('VE-05 SUPERIOR DESPACHO: abre VER ENTREGA de las hojas de SU EQUIPO (firma, receptor, CUIL) y ve SALIDA Y RECORRIDO; una hoja FUERA de su equipo se rechaza (como el servidor)',
                    acc['SUPERVISOR_DESPACHO'] == ('VE', True, True, 'FORBIDDEN_ROUTE'), acc['SUPERVISOR_DESPACHO'])
                res('VE-06 SIN acceso: Operario Depósito, Solo lectura, Transportista Interno y Externo (sin datos de la entrega ni el módulo)',
                    all(acc[k][0] == 'FORBIDDEN' and not acc[k][1] for k in ('OPERARIO_DEPOSITO', 'SOLO_LECTURA', 'TRANSPORTISTA_INTERNO', 'TRANSPORTISTA_EXTERNO')), {k: v[:2] for k, v in acc.items()})
                # ===== Android =====
                c = await b.new_context(storage_state=state, viewport={'width': 412, 'height': 915}, is_mobile=True, device_scale_factor=2.625); q = await c.new_page(); await q.goto(f'http://127.0.0.1:{dp.PORT}/')
                await dp.login(q, 'admin@okdespacho.demo'); t = await open_trace(q, ids['gb'], 1)
                over = await q.evaluate('()=>document.documentElement.scrollWidth-document.documentElement.clientWidth')
                await q.locator('#deliveryTraceBox .dt').screenshot(path=os.path.join(SHOTS, 'ver_entrega_android.png'))
                res('VE-07 ANDROID: VER ENTREGA con pestañas y línea de tiempo sin desplazamiento lateral de la página', t and len(t['tabs']) == 3 and over <= 0, {'desborde': over})
                await c.close()
            finally: await b.close()
    finally: srv.terminate()
    print('TOTAL', sum(1 for r in R if r[1] == 'PASS'), 'PASS /', sum(1 for r in R if r[1] == 'FAIL'), 'FAIL · esperados', EXPECTED)
    return R

if __name__ == '__main__':
    try: rr = asyncio.run(main())
    except Exception as e: traceback.print_exc(); print('ERROR:', repr(e)); sys.exit(2)
    if len(rr) != EXPECTED: print('ERROR: se ejecutaron %d de %d' % (len(rr), EXPECTED)); sys.exit(2)
    sys.exit(1 if any(r[1] != 'PASS' for r in rr) else 0)
