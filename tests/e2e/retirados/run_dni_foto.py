"""E2E (modo demo, Chromium EMULANDO un celular 390×844; NO es un Android físico) · foto del DNI sin picos de memoria (V4.16).
Imágenes FICTICIAS generadas al vuelo (ruido, 4000×3000 y 3000×4000): no hay fotos reales. Se informa peso original/final, tamaño y tiempo.
Código de salida: 0 todo PASS · 1 alguna FAIL · 2 error de preparación o casos faltantes.
Uso: python3 tests/e2e/run_dni_foto.py [dist-demo] [carpeta_trabajo]"""
import asyncio, os, subprocess, sys, time, socket, traceback, io, json
from playwright.async_api import async_playwright
from PIL import Image
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
DIST = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'dist-demo'); WORK = sys.argv[2] if len(sys.argv) > 2 else '/tmp/okd_dni_foto'
PORT = 4375; R = []; EXPECTED = 8; INFO = {}
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:260])); print('..', ' | '.join(R[-1]), flush=True)
def big(path, w, h):
    im = Image.frombytes('RGB', (w, h), os.urandom(w * h * 3)); im.save(path, 'JPEG', quality=92); return os.path.getsize(path)
PUB = '''async()=>{const A=window.OKD_ONLINE.api; const mk=n=>({ready:true, client_name:'CLIENTE FOTO '+n, client_key:'qa-'+n, address:'Calle '+n+', Mendoza', zone:'ESTE', order_numbers:[String(n)], merchandise_amount:1000, shipping_fee:0, task:'ENTREGA', stop_type:'PEDIDO'});
  const r = await A.publishRoute({sheet_key:'qa-foto-'+Date.now(), rules_version:1, routing_rules_version:1, carrier_id:'CT-ESTE', responsable_id:'u-cristian', stops:[mk(82001), mk(82002), mk(82003)]}); return r.id;}'''
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
    L = os.path.join(WORK, 'dni_ficticio_4000x3000.jpg'); P = os.path.join(WORK, 'dni_ficticio_3000x4000.jpg'); BAD = os.path.join(WORK, 'no_es_imagen.jpg')
    INFO['original_paisaje'] = big(L, 4000, 3000); INFO['original_retrato'] = big(P, 3000, 4000); open(BAD, 'wb').write(b'esto no es una imagen' * 100)
    srv = serve()
    try:
        async with async_playwright() as p:
          b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
          try:
            adm = await (await b.new_context()).new_page(); await adm.goto(f'http://127.0.0.1:{PORT}/'); await adm.evaluate('()=>localStorage.clear()')
            await login(adm, 'admin@okdespacho.demo'); rid = await adm.evaluate(PUB); state = await adm.context.storage_state(); await adm.context.close()
            ctx = await b.new_context(storage_state=state, viewport={'width': 390, 'height': 844}, device_scale_factor=2, is_mobile=True, geolocation={'latitude': -32.89, 'longitude': -68.84}, permissions=['geolocation'])
            await ctx.add_init_script(INIT); pg = await ctx.new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
            await login(pg, 'cristian@okdespacho.demo')
            sids = await pg.evaluate(f'()=>JSON.parse(localStorage.getItem("okd_online_demo_v2")).routes2.find(r=>r.id==="{rid}").stops.map(s=>s.id)')
            s1, s2, s3 = sids
            # ---- 1) foto grande → liviana; GUARDAR bloqueado mientras procesa ----
            await open_form(pg, rid, s1); await fill_base(pg, s1, '20444444445')
            busy, ms, st = await photo(pg, s1, L)
            INFO['paisaje'] = {'original_bytes': INFO['original_paisaje'], 'estado': st, 'ms_hasta_lista': ms}
            res('FOT-01 foto grande ficticia 4000×3000 → JPEG liviano, lado mayor 1600 px', '1600×1200' in st and st.startswith('✓'), INFO['paisaje'])
            res('FOT-02 GUARDAR bloqueado mientras se procesa la foto (evita acciones duplicadas)', busy is True, busy)
            # ---- 2) reemplazos consecutivos: solo vale el último y se liberan las vistas previas ----
            await pg.locator(S(s1, '[data-dnifile]')).set_input_files(L); busy2, ms2, st2 = await photo(pg, s1, P)
            urls = await pg.evaluate('()=>window.__urls()'); INFO['retrato'] = {'original_bytes': INFO['original_retrato'], 'estado': st2, 'ms_hasta_lista': ms2, 'urls': urls}
            res('FOT-03 reemplazos consecutivos: queda solo la última foto (retrato 1200×1600) y las vistas previas anteriores se liberan', '1200×1600' in st2
                and urls['creadas'] - urls['liberadas'] <= 1, INFO['retrato'])
            # ---- 3) cancelar: se quita la foto y no se completa la entrega sin evidencia ----
            await pg.locator(S(s1, '[data-dnifile]')).set_input_files([]); await pg.wait_for_timeout(300)
            u3 = await pg.evaluate('()=>window.__urls()'); e_c = await save(pg, s1)
            res('FOT-04 cancelar la foto: se libera y la entrega NO se completa sin la evidencia obligatoria', e_c and 'obligatoria' in e_c and u3['creadas'] - u3['liberadas'] == 0, {'error': e_c, 'urls': u3})
            # ---- 4) fallo al procesar: se conservan nombre, email, CUIL y firma; se reintenta con otra foto ----
            busy4, ms4, st4 = await photo(pg, s1, BAD); e4 = await pg.evaluate(f'()=>{{const e=document.querySelector(\'{S(s1, ".shiperr")}\'); return e&&!e.hidden?e.textContent:null}}')
            v4 = await form_vals(pg, s1); _, _, st4b = await photo(pg, s1, L); e4b = await save(pg, s1)
            out1 = await pg.evaluate(f'()=>JSON.parse(localStorage.getItem("okd_online_demo_v2")).routes2.find(r=>r.id==="{rid}").stops[0].outcome')
            res('FOT-05 si la foto falla: aviso, se conservan nombre, email, CUIL y firma, y se reintenta con éxito', e4 and 'volvé a sacar la foto' in e4 and v4 == {'recv': 'Receptor Foto QA', 'email': 'foto@ejemplo.test', 'cuil': '20444444445', 'firma': True}
                and st4b.startswith('✓') and e4b is None and out1 == 'ENTREGADO', {'aviso': e4, 'datos': v4, 'reintento': st4b, 'resultado': out1})
            # ---- 5) recarga de la página (p. ej. Android cerró la pestaña al abrir la cámara): los datos vuelven ----
            await open_form(pg, rid, s2); await fill_base(pg, s2, '20555555556'); await pg.wait_for_timeout(300)
            await pg.reload(); await pg.wait_for_timeout(2500); await login(pg, 'cristian@okdespacho.demo'); await open_form(pg, rid, s2); await pg.wait_for_timeout(1500)
            v5 = await form_vals(pg, s2)
            res('FOT-06 tras recargar la página se recuperan nombre, email, CUIL y firma', v5 == {'recv': 'Receptor Foto QA', 'email': 'foto@ejemplo.test', 'cuil': '20555555556', 'firma': True}, v5)
            # ---- 6) sin conexión: la foto va a IndexedDB (no a localStorage) y se sincroniza al volver ----
            _, _, st6 = await photo(pg, s2, P)
            await ctx.set_offline(True); await pg.evaluate('()=>window.dispatchEvent(new Event("offline"))'); await pg.wait_for_timeout(400)
            e6 = await save(pg, s2)
            q = await pg.evaluate('''async()=>{const k=Object.keys(localStorage).find(k=>k.startsWith('okd_drv_queue:')); const raw=k?localStorage.getItem(k):'';
              const ops=raw?JSON.parse(raw):[]; const ev=(((ops[0]||{}).args||{}).extra||{}).evidence||{};
              const blob = ev.dni_blob ? await new Promise(ok=>{const q=indexedDB.open('okd_drv_blobs'); q.onsuccess=()=>{const g=q.result.transaction('b').objectStore('b').get(ev.dni_blob.key); g.onsuccess=()=>ok(g.result?g.result.size:null);};}) : null;
              return {ops:ops.length, bytes_cola_localStorage:raw.length, ref:!!ev.dni_blob, sin_b64:!JSON.stringify(ops).includes('"b64"'), blob_indexeddb:blob}}''')
            await ctx.set_offline(False); await pg.evaluate('()=>window.dispatchEvent(new Event("online"))'); await pg.wait_for_timeout(4500)
            sync = await pg.evaluate(f'''()=>{{const d=JSON.parse(localStorage.getItem("okd_online_demo_v2")); const st=d.routes2.find(r=>r.id==="{rid}").stops[1]; const e=(d.evidence||{{}})[st.id]||{{}};
              const idn=(d.identity||{{}})[e.cuil]||{{}}; return {{outcome:st.outcome, cuil:e.cuil, dni:!!(idn.storage_path&&(d.storage||{{}})[idn.storage_path])}}}}''')
            INFO['sin_conexion'] = {'cola': q, 'sync': sync}
            res('FOT-07 sin conexión: la cola guarda solo la referencia (foto en IndexedDB, sin base64 en localStorage)', e6 is None and q['ops'] == 1 and q['ref'] and q['sin_b64'] and q['blob_indexeddb'] and q['bytes_cola_localStorage'] < 60000, q)
            res('FOT-08 al volver la conexión se sincroniza: entrega guardada y foto del DNI vinculada', sync == {'outcome': 'ENTREGADO', 'cuil': '20555555556', 'dni': True}, sync)
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
