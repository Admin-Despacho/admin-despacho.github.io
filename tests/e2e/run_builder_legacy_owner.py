"""E2E (modo demo, Chromium): transición de hojas locales SIN dueño (creadas por V4.8) a V4.9.
Se sirven la versión anterior y la nueva desde el MISMO origen, así comparten el almacenamiento del navegador (como al actualizar).
V4.8: el Admin arma una hoja (sin dueño local; su borrador en el servidor sí tiene dueño) y queda una hoja local SIN borrador en el
servidor (dueño indeterminable). V4.9: entra el Operario (sintético) → no adopta hojas ajenas ni sin dueño, abre una propia; la del
Admin recupera su dueño desde el servidor; la indeterminable queda separada e intacta para recuperarla a mano; no se pierde nada.
Uso: OKD_PREV_DIST=<build demo de V4.8> python3 tests/e2e/run_builder_legacy_owner.py [dist-demo]
Código de salida: 0 todo PASS · 1 alguna FAIL · 2 error de preparación o casos faltantes."""
import asyncio, os, subprocess, sys, time, socket, traceback, json
from playwright.async_api import async_playwright
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
NEW = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'dist-demo'); PREV = os.environ.get('OKD_PREV_DIST', '')
FIX = os.environ.get('OKD_FIXTURES', '/tmp/okd_synth'); FILES = ['informe_pedidos__31_.xlsx', 'SALDO_COMPROBANTE__3_.xlsx', 'SALDO_CUENTA_CORRIENTE.xlsx']
PORT = 4368; R = []; EXPECTED = 8
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:220])); print('..', ' | '.join(R[-1]), flush=True)
def serve(d):
    p = subprocess.Popen([sys.executable, '-m', 'http.server', str(PORT), '--bind', '127.0.0.1'], cwd=d, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(60):
        try: socket.create_connection(('127.0.0.1', PORT), 1).close(); return p
        except OSError: time.sleep(0.2)
    raise RuntimeError('servidor no respondió')
def stop(p):
    if p and p.poll() is None: p.terminate(); p.wait(5)
async def login(pg, email):
    await pg.goto(f'http://127.0.0.1:{PORT}/'); await pg.wait_for_load_state('networkidle'); await pg.wait_for_timeout(500)
    if await pg.locator('#loginEmail').count() == 0 or not await pg.is_visible('#loginEmail'):
        await pg.evaluate('()=>window.OKD_LOGOUT && window.OKD_LOGOUT()'); await pg.wait_for_timeout(1500); await pg.goto(f'http://127.0.0.1:{PORT}/'); await pg.wait_for_timeout(600)
    for _ in range(4):
        await pg.fill('#loginEmail', email); await pg.fill('#loginPass', 'demo')
        if await pg.input_value('#loginEmail') == email: break
        await pg.wait_for_timeout(300)
    await pg.click('#loginBtn'); await pg.wait_for_timeout(2500)
    if await pg.locator('#pinA').count() and await pg.is_visible('#pinA'): await pg.fill('#pinA', '123456'); await pg.fill('#pinB', '123456'); await pg.click('#pinGo'); await pg.wait_for_timeout(900)
    await pg.wait_for_timeout(1200)
    if await pg.locator('#pushLater').count() and await pg.is_visible('#pushLater'): await pg.click('#pushLater'); await pg.wait_for_timeout(200)
async def builder(pg):
    await pg.evaluate('()=>{location.hash="#/despacho"}'); await pg.wait_for_timeout(1800)
    if not await pg.evaluate('()=>typeof OrderIndex!=="undefined" && OrderIndex.size()>0'):
        await pg.set_input_files('.file[data-kind="pedidos"] input', [os.path.join(FIX, f) for f in FILES])
        for _ in range(150):
            await pg.wait_for_timeout(400)
            if await pg.evaluate('()=>typeof OrderIndex!=="undefined" && OrderIndex.size()>0'): break
        await pg.wait_for_timeout(1200)
async def add(pg, ids):
    await pg.fill('#ids', ' '.join(ids)); await pg.click('#btnSearch'); await pg.wait_for_timeout(2200)
    return await pg.evaluate('()=>document.getElementById("log").innerText')
IDX = '''async()=>{const i=await DB.get("sheets_index"); return i.tabs.map(t=>({id:t.id,name:t.name,owner:t.owner||null,from:t.ownerFrom||null,closed:!!t.closed,orders:(t.orders||[]).slice()}))}'''
async def main():
    for d in (NEW, PREV):
        if not d or not os.path.isfile(os.path.join(d, 'index.html')): raise RuntimeError('falta un build demo: ' + repr(d) + ' (OKD_PREV_DIST = build demo de la versión anterior)')
    srv = None
    try:
        async with async_playwright() as p:
          b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
          try:
            ctx = await b.new_context(viewport={'width': 1366, 'height': 900}); pg = await ctx.new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
            # ================= VERSIÓN ANTERIOR (V4.8) =================
            srv = serve(PREV)
            await pg.goto(f'http://127.0.0.1:{PORT}/'); await pg.evaluate('()=>localStorage.clear()')
            await pg.evaluate('()=>new Promise(r=>{const q=indexedDB.deleteDatabase("ok_despacho"); q.onsuccess=q.onerror=q.onblocked=()=>r()})')
            await login(pg, 'admin@okdespacho.demo')
            await pg.evaluate('''async()=>{const A=window.OKD_ONLINE.api; await A.action("create",{full_name:"Operario QA",email:"op.qa@example.invalid",role:"OPERARIO_DEPOSITO",active:true});
              const k="okd_online_demo_v2",d=JSON.parse(localStorage.getItem(k)); d.users.forEach(u=>{ if(/@example\\.invalid$/.test(u.email)) u.status="ACTIVO"; }); localStorage.setItem(k,JSON.stringify(d));}''')
            await builder(pg)
            ids = await pg.evaluate('()=>{const o=[]; for (const [id,x] of OrderIndex.byId) { if (!x.isShipping && !(OrderIndex.mainToShips.get(id)||[]).length) { const r=ShippingMatcher.resolve(id); if (r&&r.main&&!r.shipPending) o.push(String(id)); } if (o.length>=4) break; } return o;}')
            A1, ORPH, OP1 = ids[0], ids[1], ids[2]
            await add(pg, [A1]); await pg.wait_for_timeout(1500)          # hoja del Admin (V4.8 no guarda dueño local; el borrador del servidor sí)
            admin_sheet = await pg.evaluate('()=>RouteStore.sheetId')
            # hoja local SIN borrador en el servidor (p. ej. armada sin conexión): dueño indeterminable
            orphan = await pg.evaluate(f'''async()=>{{const i=await DB.get("sheets_index"), id="orphan-"+Date.now(); i.tabs.push({{id, name:"Hoja vieja sin conexión", closed:true, orders:["{ORPH}"]}});
              await DB.set("sheets_index", i); await DB.set("sheet:"+id, {{sheetId:id, rows:[{{id:"r1", mainOrder:"{ORPH}", cliente:"CLIENTE SINTÉTICO", fecha:"2026-10-15"}}], sheetDate:"2026-10-15"}}); return id;}}''')
            prev = await pg.evaluate(IDX)
            ok_prev = all(t['owner'] is None for t in prev) and any(t['id'] == admin_sheet and A1 in t['orders'] for t in prev)
            await pg.evaluate('()=>window.OKD_LOGOUT && window.OKD_LOGOUT()'); await pg.wait_for_timeout(1500); stop(srv)
            res('MIG-00 almacenamiento generado por V4.8: hojas SIN dueño (la del Admin con su pedido y una sin borrador en el servidor)', ok_prev, prev)
            # ================= VERSIÓN NUEVA (V4.9), mismo navegador =================
            srv = serve(NEW)
            await login(pg, 'op.qa@example.invalid'); await builder(pg)
            st = await pg.evaluate('''async()=>({me:window.OKD_ME.id, active:RouteStore.sheetId, rows:RouteStore.rows.map(r=>String(r.mainOrder)),
              tabs:[...document.querySelectorAll("#sheetTabs .stab b:first-child")].map(b=>b.textContent.trim()),
              reopen:[...document.querySelectorAll("#tabReopen option")].map(o=>[o.value.slice(0,6)+(o.value.startsWith("adopt:")?o.value.slice(6,12):""),o.textContent.trim()])})''')
            idx = await pg.evaluate(IDX); t_admin = next(t for t in idx if t['id'] == admin_sheet); t_orph = next(t for t in idx if t['id'] == orphan)
            t_active = next(t for t in idx if t['id'] == st['active'])
            res('MIG-01 el Operario abre una hoja PROPIA nueva (no adopta ninguna hoja anterior)', t_active['owner'] == st['me'] and st['active'] not in (admin_sheet, orphan) and not st['rows'], st)
            # el Operario NO puede ver borradores del Admin (can_view_draft_of): no se determina el dueño → no se asigna ni se le ofrece
            res('MIG-02 la hoja del Admin NO se asigna al Operario ni se le ofrece recuperar (su borrador es de otro usuario)', t_admin['owner'] is None and A1 in t_admin['orders']
                and admin_sheet[:6] not in [v[6:12] for v, _ in st['reopen'] if v.startswith('adopt:')], {'t_admin': t_admin, 'reopen': st['reopen']})
            res('MIG-03 la hoja sin borrador en el servidor queda SIN dueño (separada), no se ve como pestaña y se ofrece recuperar', t_orph['owner'] is None and 'Hoja vieja sin conexión' not in ' '.join(st['tabs'])
                and any(v.startswith('adopt:') and 'Hoja vieja sin conexión' in txt for v, txt in st['reopen']), {'orph': t_orph, 'tabs': st['tabs'], 'reopen': st['reopen']})
            orph_content = await pg.evaluate(f'async()=>await DB.get("sheet:{orphan}")')
            res('MIG-04 su contenido se conserva intacto (no se perdió información)', orph_content and orph_content.get('rows', [{}])[0].get('mainOrder') == ORPH and orph_content.get('sheetDate') == '2026-10-15', orph_content)
            log = await add(pg, [OP1]); rows = await pg.evaluate('()=>RouteStore.rows.map(r=>String(r.mainOrder))')
            res('MIG-05 las hojas ajenas/sin dueño no bloquean al Operario y su pedido entra en SU hoja', OP1 in rows and 'OTRA HOJA (Hoja' not in log and 'no quedó en la hoja' not in log, log[:160])
            # recuperación EXPLÍCITA (con confirmación) de la hoja sin dueño
            await pg.select_option('#tabReopen', value='adopt:' + orphan); await pg.wait_for_timeout(1800)
            ad = await pg.evaluate('()=>({active:RouteStore.sheetId, rows:RouteStore.rows.map(r=>String(r.mainOrder))})'); idx2 = await pg.evaluate(IDX)
            t2 = next(t for t in idx2 if t['id'] == orphan)
            res('MIG-06 la hoja sin dueño se recupera SOLO a mano (con confirmación) y con su contenido', t2['owner'] == st['me'] and t2['from'] == 'recuperada' and ad['active'] == orphan and ORPH in ad['rows'], {'t': t2, 'ad': ad})
            # vuelve el Admin: su hoja sigue intacta y es suya
            await login(pg, 'admin@okdespacho.demo'); await builder(pg)
            adm = await pg.evaluate('()=>({active:RouteStore.sheetId, rows:RouteStore.rows.map(r=>String(r.mainOrder)), tabs:[...document.querySelectorAll("#sheetTabs .stab b:first-child")].map(b=>b.textContent.trim())})')
            idx3 = await pg.evaluate(IDX); ta = next(t for t in idx3 if t['id'] == admin_sheet)
            res('MIG-07 al entrar el Admin, su hoja recupera el dueño DESDE EL SERVIDOR y sigue intacta (sin la hoja que recuperó el Operario)', adm['active'] == admin_sheet and A1 in adm['rows'] and ORPH not in adm['rows']
                and ta['owner'] == 'u-admin' and ta['from'] == 'servidor', {'adm': adm, 'tab': ta})
          finally: await b.close()
    finally: stop(srv)
    print('TOTAL', sum(1 for r in R if r[1] == 'PASS'), 'PASS /', sum(1 for r in R if r[1] == 'FAIL'), 'FAIL · esperados', EXPECTED)
    return R
if __name__ == '__main__':
    try: rr = asyncio.run(main())
    except Exception as e: traceback.print_exc(); print('ERROR:', repr(e)); sys.exit(2)
    if len(rr) != EXPECTED: print('ERROR: se ejecutaron %d de %d' % (len(rr), EXPECTED)); sys.exit(2)
    sys.exit(1 if any(r[1] != 'PASS' for r in rr) else 0)
