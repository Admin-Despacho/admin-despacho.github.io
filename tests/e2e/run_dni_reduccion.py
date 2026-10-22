"""E2E (modo demo, Chromium EMULANDO un celular; NO Android físico) · V4.17: la foto NUNCA se abre a resolución completa si la reducción falla.
Imágenes FICTICIAS generadas al vuelo (ruido, 4000×3000 y 3000×4000): no hay fotos reales. Se informa peso original/final, tamaño y tiempo.
Código de salida: 0 todo PASS · 1 alguna FAIL · 2 error de preparación o casos faltantes.
Uso: python3 tests/e2e/run_dni_foto.py [dist-demo] [carpeta_trabajo]"""
import asyncio, os, subprocess, sys, time, socket, traceback, io, json
from playwright.async_api import async_playwright
from PIL import Image
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
DIST = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'dist-demo'); WORK = sys.argv[2] if len(sys.argv) > 2 else '/tmp/okd_dni_foto'
PORT = 4377; R = []; EXPECTED = 6; INFO = {}
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:260])); print('..', ' | '.join(R[-1]), flush=True)
def big(path, w, h):
    im = Image.frombytes('RGB', (w, h), os.urandom(w * h * 3)); im.save(path, 'JPEG', quality=92); return os.path.getsize(path)
PUB = '''async()=>{const A=window.OKD_ONLINE.api; const mk=n=>({ready:true, client_name:'CLIENTE FOTO '+n, client_key:'qa-'+n, address:'Calle '+n+', Mendoza', zone:'ESTE', order_numbers:[String(n)], merchandise_amount:1000, shipping_fee:0, task:'ENTREGA', stop_type:'PEDIDO'});
  const r = await A.publishRoute({sheet_key:'qa-foto-'+Date.now(), rules_version:1, routing_rules_version:1, carrier_id:'CT-ESTE', responsable_id:'u-cristian', stops:[mk(82001), mk(82002), mk(82003)]}); return r.id;}'''
INIT_CIB = '''(()=>{ window.__cib=[]; const orig=window.createImageBitmap.bind(window);
  window.createImageBitmap=async (src, ...rest)=>{ const o=rest.find(x=>x&&typeof x==='object'&&!(x instanceof Blob))||null; const red=!!(o&&(o.resizeWidth||o.resizeHeight));
    window.__cib.push({reducida:red, w:o?o.resizeWidth||null:null, h:o?o.resizeHeight||null:null});
    if (localStorage.getItem('qa_fail_reduced')==='1' && red) throw new Error('reducción no disponible (simulada)');
    return orig(src, ...rest); }; })()'''
INIT = '''(()=>{ let c=0, r=0; const oc=URL.createObjectURL.bind(URL), orv=URL.revokeObjectURL.bind(URL);
  URL.createObjectURL=o=>{ if(o instanceof Blob && o.type==='image/jpeg') c++; return oc(o); }; URL.revokeObjectURL=u=>{ r++; return orv(u); };
  window.__urls=()=>({creadas:c, liberadas:r}); })()'''
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
    if not await pg.locator('#loginEmail').count() or not await pg.is_visible('#loginEmail'): return
    for _ in range(4):
        await pg.fill('#loginEmail', email); await pg.fill('#loginPass', 'demo')
        if await pg.input_value('#loginEmail') == email: break
        await pg.wait_for_timeout(300)
    await pg.click('#loginBtn'); await pg.wait_for_timeout(2500)
    if await pg.locator('#pinA').count() and await pg.is_visible('#pinA'): await pg.fill('#pinA', '123456'); await pg.fill('#pinB', '123456'); await pg.click('#pinGo'); await pg.wait_for_timeout(900)
    await pg.wait_for_timeout(1500); await dismiss(pg)
def S(sid, sel): return f'.drv-stop[data-s="{sid}"] {sel}'
async def open_form(pg, rid, sid):
    await dismiss(pg)
    if await pg.locator(f'[data-open="{rid}"]').count(): await pg.locator(f'[data-open="{rid}"]').click(); await pg.wait_for_timeout(1200)
    if await pg.locator('#drvStart').count(): await pg.click('#drvStart'); await pg.wait_for_timeout(1500)
    await pg.locator(S(sid, '[data-o="ENTREGADO"]')).click(); await pg.wait_for_timeout(500)
async def sign(pg, sid):
    cv = pg.locator(S(sid, '[data-sig]')); await cv.scroll_into_view_if_needed(); bb = await cv.bounding_box()
    await pg.mouse.move(bb['x'] + 20, bb['y'] + 20); await pg.mouse.down()
    for i in range(1, 12): await pg.mouse.move(bb['x'] + 20 + i * 18, bb['y'] + 20 + (i % 3) * 14)
    await pg.mouse.up(); await pg.wait_for_timeout(200)
async def fill_base(pg, sid, cuil):
    await pg.locator(S(sid, '[data-f="recv"]')).fill('Receptor Foto QA'); await pg.locator(S(sid, '[data-f="email"]')).fill('foto@ejemplo.test')
    f = pg.locator(S(sid, '[data-f="cuil"]')); await f.fill(cuil); await f.press('Tab'); await pg.wait_for_timeout(900); await sign(pg, sid)
async def photo(pg, sid, path, wait=True):
    t0 = time.time(); await pg.locator(S(sid, '[data-dnifile]')).set_input_files(path)
    busy = await pg.evaluate(f'()=>document.querySelector(\'{S(sid, "[data-save]")}\').disabled')
    if wait:   # espera a que TERMINE el procesamiento (botón habilitado y estado distinto de "Procesando…")
        await pg.wait_for_timeout(150)
        for _ in range(300):
            st = await pg.locator(S(sid, '[data-dnist]')).inner_text()
            dis = await pg.evaluate(f'()=>document.querySelector(\'{S(sid, "[data-save]")}\').disabled')
            if not dis and not st.startswith('Procesando'): break
            await pg.wait_for_timeout(100)
    return busy, round((time.time() - t0) * 1000), await pg.locator(S(sid, '[data-dnist]')).inner_text()
async def form_vals(pg, sid):
    return await pg.evaluate(f'''()=>{{const q=s=>document.querySelector('.drv-stop[data-s="{sid}"] '+s); const cv=q('[data-sig]');
      const px=cv?cv.getContext('2d').getImageData(0,0,cv.width,cv.height).data:[]; let ink=0; for(let i=3;i<px.length;i+=4) if(px[i]) {{ink++; if(ink>20) break;}}
      return {{recv:(q('[data-f="recv"]')||{{}}).value, email:(q('[data-f="email"]')||{{}}).value, cuil:(q('[data-f="cuil"]')||{{}}).value, firma:ink>20}}}}''')
async def save(pg, sid):
    await pg.locator(S(sid, '[data-save]')).click(); await pg.wait_for_timeout(1800)
    return await pg.evaluate(f'()=>{{const e=document.querySelector(\'{S(sid, ".shiperr")}\'); return e&&!e.hidden?e.textContent:null}}')
async def main():
    if not os.path.isfile(os.path.join(DIST, 'index.html')): raise RuntimeError('falta el build demo en ' + DIST)
    os.makedirs(WORK, exist_ok=True)
    L = os.path.join(WORK, 'dni_ficticio_4000x3000.jpg'); HUGE = os.path.join(WORK, 'liviana_8000x8000.png'); SM = os.path.join(WORK, 'chica_800x600.jpg')
    INFO['grande_bytes'] = big(L, 4000, 3000)
    Image.new('RGB', (8000, 8000), (230, 230, 230)).save(HUGE, 'PNG', optimize=True); INFO['liviana_8000_bytes'] = os.path.getsize(HUGE)
    Image.frombytes('RGB', (800, 600), os.urandom(800 * 600 * 3)).save(SM, 'JPEG', quality=85)
    srv = serve()
    try:
        async with async_playwright() as p:
          b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
          try:
            adm = await (await b.new_context()).new_page(); await adm.goto(f'http://127.0.0.1:{PORT}/'); await adm.evaluate('()=>localStorage.clear()')
            await login(adm, 'admin@okdespacho.demo'); rid = await adm.evaluate(PUB); state = await adm.context.storage_state(); await adm.context.close()
            ctx = await b.new_context(storage_state=state, viewport={'width': 390, 'height': 844}, device_scale_factor=2, is_mobile=True, geolocation={'latitude': -32.89, 'longitude': -68.84}, permissions=['geolocation'])
            await ctx.add_init_script(INIT_CIB); pg = await ctx.new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
            await login(pg, 'cristian@okdespacho.demo')
            s1 = (await pg.evaluate(f'()=>JSON.parse(localStorage.getItem("okd_online_demo_v2")).routes2.find(r=>r.id==="{rid}").stops.map(s=>s.id)'))[0]
            await open_form(pg, rid, s1); await fill_base(pg, s1, '20666666667')
            calls = lambda: pg.evaluate('()=>{const c=window.__cib.slice(); window.__cib.length=0; return c}')
            err = lambda: pg.evaluate(f'()=>{{const e=document.querySelector(\'{S(s1, ".shiperr")}\'); return e&&!e.hidden?e.textContent:null}}')
            await calls(); await pg.evaluate('()=>localStorage.setItem("qa_fail_reduced","1")')
            # (1) foto GRANDE con la reducción fallando: error claro, NUNCA se abre la original completa
            _, _, st1 = await photo(pg, s1, L); c1 = await calls(); e1 = await err(); v1 = await form_vals(pg, s1)
            res('RED-01 foto grande (4000×3000) y la reducción falla: aviso claro y NO se intenta abrir la original sin límites', e1 and 'no se abre la original completa' in e1 and c1 and all(x['reducida'] for x in c1) and not st1.startswith('✓'), {'llamadas': c1, 'aviso': e1})
            res('RED-02 tras el fallo se conservan nombre, email, CUIL y firma', v1 == {'recv': 'Receptor Foto QA', 'email': 'foto@ejemplo.test', 'cuil': '20666666667', 'firma': True}, v1)
            # (2) imagen de POCOS KB con dimensiones enormes: tampoco se abre completa (no decide el peso)
            _, _, st2 = await photo(pg, s1, HUGE); c2 = await calls(); e2 = await err()
            res('RED-03 imagen liviana (%d KB) de 8000×8000 con la reducción fallando: NO se abre completa (el peso no decide)' % (INFO['liviana_8000_bytes'] // 1024), e2 and c2 and all(x['reducida'] for x in c2) and not st2.startswith('✓'), {'llamadas': c2, 'bytes': INFO['liviana_8000_bytes']})
            # (3) imagen chica con tamaño CONOCIDO (800×600): se decodifica entera aunque la reducción no esté disponible
            _, _, st3 = await photo(pg, s1, SM); c3 = await calls()
            res('RED-04 imagen chica (800×600, dimensiones leídas del encabezado): se procesa sin necesidad de reducir', st3.startswith('✓') and '800×600' in st3 and c3 and not any(x['reducida'] for x in c3), {'estado': st3, 'llamadas': c3})
            # (4) reducción disponible: la imagen de 8000×8000 se decodifica REDUCIDA a 1600×1600
            await pg.evaluate('()=>localStorage.removeItem("qa_fail_reduced")')
            _, _, st4 = await photo(pg, s1, HUGE); c4 = await calls()
            res('RED-05 con reducción: 8000×8000 se decodifica ya reducida (1600×1600), nunca completa', st4.startswith('✓') and '1600×1600' in st4 and c4 and all(x['reducida'] and x['w'] == 1600 and x['h'] == 1600 for x in c4), {'estado': st4, 'llamadas': c4})
            # (5) reintento con la foto grande y guardado
            _, _, st5 = await photo(pg, s1, L); c5 = await calls(); e5 = await save(pg, s1)
            out = await pg.evaluate(f'()=>JSON.parse(localStorage.getItem("okd_online_demo_v2")).routes2.find(r=>r.id==="{rid}").stops[0].outcome')
            res('RED-06 reintento: la foto grande se procesa reducida (1600×1200) y la entrega se guarda', st5.startswith('✓') and '1600×1200' in st5 and all(x['reducida'] for x in c5) and e5 is None and out == 'ENTREGADO', {'estado': st5, 'llamadas': c5, 'resultado': out})
          finally: await b.close()
    finally:
        if srv.poll() is None: srv.terminate(); srv.wait(5)
    print('INFO', json.dumps(INFO, ensure_ascii=False))
    print('TOTAL', sum(1 for r in R if r[1] == 'PASS'), 'PASS /', sum(1 for r in R if r[1] == 'FAIL'), 'FAIL · esperados', EXPECTED)
    return R
if __name__ == '__main__':
    try: rr = asyncio.run(main())
    except Exception as e: traceback.print_exc(); print('ERROR:', repr(e)); sys.exit(2)
    if len(rr) != EXPECTED: print('ERROR: se ejecutaron %d de %d' % (len(rr), EXPECTED)); sys.exit(2)
    sys.exit(1 if any(r[1] != 'PASS' for r in rr) else 0)
