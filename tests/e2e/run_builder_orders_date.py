"""E2E (modo demo, Chromium): pedidos bloqueados por "otra hoja" y fecha automática de la hoja.
Reproduce el caso del Operario Depósito (20/10/2026): una hoja vieja CERRADA en el mismo navegador, o una hoja de OTRO usuario de esa
computadora, bloqueaban los pedidos en silencio ("PEDIDO YA AGREGADO A OTRA HOJA (Hoja 1)") y además se mostraba un ERROR falso.
Usuarios Superior/Operario SINTÉTICOS (@example.invalid); informes SINTÉTICOS (sin datos reales).
Código de salida: 0 todo PASS · 1 alguna FAIL · 2 error de preparación o casos faltantes."""
import asyncio, os, subprocess, sys, time, socket, traceback, json
from playwright.async_api import async_playwright
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
DIST = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'dist-demo'); PORT = 4367
FIX = os.environ.get('OKD_FIXTURES', '/tmp/okd_synth'); FILES = ['informe_pedidos__31_.xlsx', 'SALDO_COMPROBANTE__3_.xlsx', 'SALDO_CUENTA_CORRIENTE.xlsx']
R = []; EXPECTED = 13
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:200])); print('..', ' | '.join(R[-1]), flush=True)
async def login(pg, email):
    await pg.goto(f'http://127.0.0.1:{PORT}/'); await pg.wait_for_load_state('networkidle'); await pg.wait_for_timeout(500)
    for _ in range(4):
        await pg.fill('#loginEmail', email); await pg.fill('#loginPass', 'demo')
        if await pg.input_value('#loginEmail') == email: break
        await pg.wait_for_timeout(300)
    await pg.click('#loginBtn'); await pg.wait_for_timeout(2500)
    if await pg.locator('#pinA').count() and await pg.is_visible('#pinA'): await pg.fill('#pinA', '123456'); await pg.fill('#pinB', '123456'); await pg.click('#pinGo'); await pg.wait_for_timeout(900)
    await pg.wait_for_timeout(1200)
    if await pg.locator('#pushLater').count() and await pg.is_visible('#pushLater'): await pg.click('#pushLater'); await pg.wait_for_timeout(200)
async def builder(pg):
    await pg.evaluate('()=>{location.hash="#/despacho"}'); await pg.wait_for_timeout(1500)
    if await pg.evaluate('()=>typeof OrderIndex!=="undefined" && OrderIndex.size()>0'): return
    await pg.set_input_files('.file[data-kind="pedidos"] input', [os.path.join(FIX, f) for f in FILES])
    for _ in range(150):
        await pg.wait_for_timeout(400)
        if await pg.evaluate('()=>typeof OrderIndex!=="undefined" && OrderIndex.size()>0'): break
    await pg.wait_for_timeout(1200)
async def add(pg, ids):
    await pg.fill('#ids', ' '.join(ids)); await pg.click('#btnSearch'); await pg.wait_for_timeout(2200)
    return await pg.evaluate('()=>document.getElementById("log").innerText')
ROWS = '()=>RouteStore.rows.map(r=>String(r.mainOrder))'
async def main():
    if not os.path.isfile(os.path.join(DIST, 'index.html')): raise RuntimeError('falta el build demo en ' + DIST)
    if not all(os.path.isfile(os.path.join(FIX, f)) for f in FILES): raise RuntimeError('faltan los informes sintéticos en ' + FIX + ' (python3 tests/e2e/generate_synthetic_excel.py ' + FIX + ')')
    srv = subprocess.Popen([sys.executable, '-m', 'http.server', str(PORT), '--bind', '127.0.0.1'], cwd=DIST, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(60):
            try: socket.create_connection(('127.0.0.1', PORT), 1).close(); break
            except OSError: time.sleep(0.2)
        async with async_playwright() as p:
          b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
          try:
            # UN solo navegador compartido (misma computadora): Admin y Operario usan el mismo almacenamiento local
            ctx = await b.new_context(viewport={'width': 1366, 'height': 900}); pg = await ctx.new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
            await pg.goto(f'http://127.0.0.1:{PORT}/'); await pg.evaluate('()=>localStorage.clear()'); await login(pg, 'admin@okdespacho.demo')
            await pg.evaluate('''async()=>{const A=window.OKD_ONLINE.api;
              await A.action("create",{full_name:"Operario QA",email:"op.qa@example.invalid",role:"OPERARIO_DEPOSITO",active:true});
              const k="okd_online_demo_v2",d=JSON.parse(localStorage.getItem(k)); d.users.forEach(u=>{ if(/@example\\.invalid$/.test(u.email)) u.status="ACTIVO"; }); localStorage.setItem(k,JSON.stringify(d));}''')
            await builder(pg)
            ids = await pg.evaluate('()=>{const o=[]; for (const [id,x] of OrderIndex.byId) { if (!x.isShipping && !(OrderIndex.mainToShips.get(id)||[]).length) { const r=ShippingMatcher.resolve(id); if (r&&r.main&&!r.shipPending) o.push(String(id)); } if (o.length>=6) break; } return o;}')
            if len(ids) < 6: raise RuntimeError('informe sintético sin pedidos suficientes: ' + str(ids))
            A1, A2, OP1, OP2, OP3, OP4 = ids
            # Admin deja una hoja ABIERTA con A1 en esta computadora y sale
            await add(pg, [A1])
            await pg.evaluate('()=>window.OKD_LOGOUT && window.OKD_LOGOUT()'); await pg.wait_for_timeout(1500)
            # ---- Operario en la misma computadora ----
            await login(pg, 'op.qa@example.invalid'); await builder(pg)
            # (0) el Operario NO entra a trabajar en la hoja del Admin que quedó en este navegador
            st0 = await pg.evaluate('''()=>{const me=window.OKD_ME.id, t=SheetTabs.tab(); return {owner:t&&t.owner, me, rows:RouteStore.rows.map(r=>String(r.mainOrder)),
              tabs:[...document.querySelectorAll("#sheetTabs .stab b:first-child")].map(b=>b.textContent.trim()), admin_tab_owner:SheetTabs.idx.tabs.find(x=>(x.orders||[]).length && x.owner && x.owner!==me)?.owner||null}}''')
            res('ORD-00 En una computadora compartida, el Operario abre una hoja PROPIA y no ve ni usa la hoja del Admin', st0['owner'] == st0['me'] and A1 not in st0['rows'] and st0['admin_tab_owner'] is not None
                and len(st0['tabs']) == 1, st0)
            # (1) hoja propia CERRADA con la "×" que todavía tiene el pedido
            await add(pg, [OP1]); first = await pg.evaluate('()=>RouteStore.sheetId')
            await pg.evaluate('async()=>{ await SheetTabs.create(); }'); await pg.wait_for_timeout(800)
            await pg.evaluate(f'async()=>{{ await SheetTabs.close("{first}"); }}'); await pg.wait_for_timeout(800)
            log1 = await add(pg, [OP1]); rows1 = await pg.evaluate(ROWS)
            res('ORD-01 Hoja propia CERRADA ya no bloquea en silencio: el servidor avisa en qué borrador está y ofrece liberarlo',
                'PEDIDO YA AGREGADO A OTRA HOJA (Hoja' not in log1 and 'PEDIDO RESERVADO EN BORRADOR' in log1 and await pg.locator('#log [data-deldraft]').count() > 0, log1[:180])
            res('ORD-02 Sin ERROR falso ("no quedó en la hoja") cuando el motivo ya está avisado', 'no quedó en la hoja' not in log1, log1[:180])
            await pg.locator('#log [data-deldraft]').first.click(); await pg.wait_for_timeout(2000)
            log1b = await add(pg, [OP1]); rows1b = await pg.evaluate(ROWS)
            res('ORD-03 Al liberar ese borrador, el pedido entra en la hoja actual', OP1 in rows1b and 'no quedó en la hoja' not in log1b, log1b[:150])
            # (2) hoja ABIERTA de OTRO usuario de esta computadora (Admin, con A1)
            log2 = await add(pg, [A1]); rows2 = await pg.evaluate(ROWS)
            res('ORD-04 Hoja de OTRO usuario en esta computadora: no bloquea en silencio; el aviso dice el borrador y el operador',
                'PEDIDO YA AGREGADO A OTRA HOJA (Hoja' not in log2 and 'PEDIDO RESERVADO EN BORRADOR' in log2 and 'OPERADOR' in log2 and A1 not in rows2, log2[:180])
            res('ORD-05 Sin ERROR falso en ese caso', 'no quedó en la hoja' not in log2, log2[:150])
            # (3) hoja PROPIA ABIERTA en otra pestaña: se avisa, se indica que está en las pestañas y sin ERROR
            await add(pg, [OP2]); cur = await pg.evaluate('()=>RouteStore.sheetId')
            await pg.evaluate('async()=>{ await SheetTabs.create(); }'); await pg.wait_for_timeout(800)
            log3 = await add(pg, [OP2])
            res('ORD-06 Hoja propia ABIERTA: aviso "ya agregado a otra hoja (abierta en las pestañas)" sin ERROR', 'PEDIDO YA AGREGADO A OTRA HOJA' in log3 and 'abierta en las pestañas' in log3 and 'no quedó en la hoja' not in log3, log3[:180])
            # (4) pedido nuevo normal entra sin avisos de error
            log4 = await add(pg, [OP3]); rows4 = await pg.evaluate(ROWS)
            res('ORD-07 Pedido libre se agrega normalmente', OP3 in rows4 and 'ERROR' not in log4, log4[:120])
            # (5) FECHA AUTOMÁTICA: una hoja no publicada con fecha de ayer pasa sola a hoy (también sus pedidos)
            sid = await pg.evaluate('()=>RouteStore.sheetId')
            await pg.evaluate('''async()=>{const d=new Date(); d.setDate(d.getDate()-1); const y=d.getFullYear()+"-"+String(d.getMonth()+1).padStart(2,"0")+"-"+String(d.getDate()).padStart(2,"0");
              RouteStore.sheetDate=y; RouteStore.rows.forEach(r=>r.fecha=y); await RouteStore.flush(); }''')
            saved_y = await pg.evaluate(f'async()=>((await DB.get("sheet:{sid}"))||{{}}).sheetDate')   # quedó guardada la fecha de AYER
            await pg.reload(); await pg.wait_for_timeout(2500); await builder(pg)
            await pg.evaluate(f'async()=>{{ await SheetTabs.switchTo("{sid}"); }}'); await pg.wait_for_timeout(1500)
            d5 = await pg.evaluate('()=>({sheet:RouteStore.sheetDate, today:todayISO(), input:document.getElementById("sheetDate").value, rows:RouteStore.rows.map(r=>r.fecha)})')
            d5['guardada_antes'] = saved_y
            res('ORD-08 Fecha de ayer → se actualiza sola a hoy (campo, hoja y pedidos)', saved_y is not None and saved_y < d5['today'] and d5['sheet'] == d5['today'] and d5['input'] == '/'.join(reversed(d5['today'].split('-'))) and all(x == d5['today'] for x in d5['rows']), d5)
            # (6) una fecha FUTURA puesta a propósito se respeta
            await pg.evaluate('''async()=>{const d=new Date(); d.setDate(d.getDate()+2); const f=d.getFullYear()+"-"+String(d.getMonth()+1).padStart(2,"0")+"-"+String(d.getDate()).padStart(2,"0");
              RouteStore.sheetDate=f; await RouteStore.flush(); }''')
            saved_f = await pg.evaluate(f'async()=>((await DB.get("sheet:{sid}"))||{{}}).sheetDate')
            await pg.reload(); await pg.wait_for_timeout(2500); await builder(pg)
            await pg.evaluate(f'async()=>{{ await SheetTabs.switchTo("{sid}"); }}'); await pg.wait_for_timeout(1500)
            d6 = await pg.evaluate('()=>({sheet:RouteStore.sheetDate, today:todayISO()})'); d6['guardada_antes'] = saved_f
            res('ORD-09 Fecha FUTURA puesta a propósito se respeta', saved_f is not None and saved_f > d6['today'] and d6['sheet'] == saved_f, d6)
            YD = '(()=>{const d=new Date(); d.setDate(d.getDate()-1); return d.getFullYear()+"-"+String(d.getMonth()+1).padStart(2,"0")+"-"+String(d.getDate()).padStart(2,"0")})()'
            # (7) hoja PUBLICADA con fecha vieja: NO se modifica
            pub = await pg.evaluate('async()=>{ await SheetTabs.create(); return RouteStore.sheetId; }'); await pg.wait_for_timeout(800)
            # se marca publicada en el índice EN USO (no solo en el almacenamiento, porque el constructor lo vuelve a guardar)
            # se simula la publicación como la registra la app: en el CONTENIDO de la hoja (RouteStore.published); la pestaña lo copia al guardar
            await pg.evaluate(f'''async()=>{{const y={YD}; RouteStore.sheetDate=y; RouteStore.published={{id:"r-test", number:"03-000999", at:new Date().toISOString(), carrier:"TRANSPORTE INTERNO", responsable:"", mode:"APP"}}; await RouteStore.flush(); }}''')
            other = await pg.evaluate('async()=>{ await SheetTabs.create(); return RouteStore.sheetId; }'); await pg.wait_for_timeout(800)
            prep = await pg.evaluate(f'async()=>({{pub:(((await DB.get("sheet:{pub}"))||{{}}).published||{{}}).number||null, tab:((await DB.get("sheets_index")).tabs.find(x=>x.id==="{pub}")||{{}}).published||null, date:((await DB.get("sheet:{pub}"))||{{}}).sheetDate}})')
            await pg.reload(); await pg.wait_for_timeout(2500); await builder(pg)
            await pg.evaluate(f'async()=>{{ await SheetTabs.switchTo("{pub}"); }}'); await pg.wait_for_timeout(1500)
            d7 = await pg.evaluate(f'async()=>({{sheet:RouteStore.sheetDate, saved:((await DB.get("sheet:{pub}"))||{{}}).sheetDate, today:todayISO()}})')
            d7['preparado'] = prep
            res('ORD-10 Hoja PUBLICADA con fecha anterior: la fecha NO se modifica', prep['pub'] == '03-000999' and prep['date'] < d7['today'] and d7['sheet'] == prep['date'] and d7['saved'] == prep['date'], d7)
            # (8) al CAMBIAR DE PESTAÑA a una hoja no publicada con fecha de ayer, se actualiza
            await pg.evaluate(f'async()=>{{ await SheetTabs.switchTo("{other}"); }}'); await pg.wait_for_timeout(1200)
            await pg.evaluate(f'async()=>{{ RouteStore.sheetDate={YD}; await RouteStore.flush(); }}')
            await pg.evaluate(f'async()=>{{ await SheetTabs.switchTo("{sid}"); }}'); await pg.wait_for_timeout(1200)
            await pg.evaluate(f'async()=>{{ await SheetTabs.switchTo("{other}"); }}'); await pg.wait_for_timeout(1500)
            d8 = await pg.evaluate('()=>({sheet:RouteStore.sheetDate, today:todayISO(), input:document.getElementById("sheetDate").value})')
            res('ORD-11 Al cambiar de pestaña a una hoja con fecha de ayer, se actualiza a hoy', d8['sheet'] == d8['today'] and d8['input'] == '/'.join(reversed(d8['today'].split('-'))), d8)
            # (9) CAMBIO DE DÍA con la app abierta (reloj simulado de Chromium: 23:59 → 00:02)
            import datetime as _dt
            c2 = await b.new_context(viewport={'width': 1366, 'height': 900}, storage_state=await ctx.storage_state()); p2 = await c2.new_page()
            base = _dt.datetime.now().replace(hour=23, minute=59, second=0, microsecond=0)
            await p2.clock.install(time=base)
            await login(p2, 'op.qa@example.invalid'); await builder(p2)
            before = await p2.evaluate('()=>({sheet:RouteStore.sheetDate, today:todayISO()})')
            await p2.clock.run_for(4 * 60 * 1000); await p2.wait_for_timeout(800)
            after = await p2.evaluate('()=>({sheet:RouteStore.sheetDate, today:todayISO(), input:document.getElementById("sheetDate").value})')
            res('ORD-12 Con la app abierta al pasar la medianoche, la hoja no publicada pasa sola al día nuevo', before['today'] < after['today'] and before['sheet'] == before['today']
                and after['sheet'] == after['today'] and after['input'] == '/'.join(reversed(after['today'].split('-'))), {'antes': before, 'despues': after})
            await c2.close()
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
