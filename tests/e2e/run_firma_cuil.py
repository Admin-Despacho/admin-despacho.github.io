"""E2E (modo demo, Chromium, ANDROID emulado con TOQUES REALES vía CDP) · V4.19: entrega SIN foto del DNI, CUIL obligatorio y
firma a pantalla completa. Transportista EXTERNO (Cristian) e INTERNO (Gabriel), y recepción interna de traslados G2.
Uso: python3 tests/e2e/run_firma_cuil.py [dist-demo] [carpeta_capturas]
Exit 0 todo PASS · 1 alguna FAIL · 2 error de preparación o casos faltantes. Datos FICTICIOS."""
import asyncio, os, sys, base64, struct, traceback
sys.path.insert(0, os.path.dirname(__file__))
import run_driver_perfiles as dp
from playwright.async_api import async_playwright
dp.PORT = 4396; R = []; EXPECTED = 12
if len(sys.argv) > 1: dp.DIST = sys.argv[1]
SHOTS = sys.argv[2] if len(sys.argv) > 2 else '/tmp/okd_firma_shots'
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:240])); print('..', ' | '.join(R[-1]), flush=True)
MOB = dict(viewport={'width': 412, 'height': 915}, device_scale_factor=2.625, is_mobile=True, has_touch=True,
           geolocation={'latitude': -32.89, 'longitude': -68.84}, permissions=['geolocation'])   # Pixel 7
S = lambda sid, sel: f'.drv-stop[data-s="{sid}"] {sel}'
INK = '''()=>{const c=document.querySelector('.drv-sign-modal [data-sigpad]'); if(!c) return null; const x=c.getContext('2d'), d=x.getImageData(0,0,c.width,c.height).data;
  let n=0, minX=1e9, minY=1e9, maxX=-1, maxY=-1; for(let y=0;y<c.height;y+=3) for(let X=0;X<c.width;X+=3){ if(d[(y*c.width+X)*4+3]>0){ n++; if(X<minX)minX=X; if(X>maxX)maxX=X; if(y<minY)minY=y; if(y>maxY)maxY=y; } }
  return {n, w:c.width, h:c.height, cssW:c.getBoundingClientRect().width, cssH:c.getBoundingClientRect().height, aspect:n?(maxX-minX)/Math.max(1,maxY-minY):null}}'''

async def touch_draw(pg, cdp, rel_points):   # trazo con el DEDO: touchStart → touchMove… → touchEnd (eventos táctiles reales del navegador)
    b = await pg.locator('.drv-sign-modal [data-sigpad]').bounding_box()
    pts = [(b['x'] + b['width'] * x, b['y'] + b['height'] * y) for x, y in rel_points]
    await cdp.send('Input.dispatchTouchEvent', {'type': 'touchStart', 'touchPoints': [{'x': pts[0][0], 'y': pts[0][1]}]})
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        for k in range(1, 9): await cdp.send('Input.dispatchTouchEvent', {'type': 'touchMove', 'touchPoints': [{'x': x0 + (x1 - x0) * k / 8, 'y': y0 + (y1 - y0) * k / 8}]})
    await cdp.send('Input.dispatchTouchEvent', {'type': 'touchEnd', 'touchPoints': []}); await pg.wait_for_timeout(150)
async def tap(pg, cdp, sel):
    b = await pg.locator(sel).bounding_box(); x, y = b['x'] + b['width'] / 2, b['y'] + b['height'] / 2
    await cdp.send('Input.dispatchTouchEvent', {'type': 'touchStart', 'touchPoints': [{'x': x, 'y': y}]}); await cdp.send('Input.dispatchTouchEvent', {'type': 'touchEnd', 'touchPoints': []})
    await pg.wait_for_timeout(250)
def png_size(b64):
    raw = base64.b64decode(b64); return (struct.unpack('>II', raw[16:24]) if raw[:8] == b'\x89PNG\r\n\x1a\n' else None)
ZIG = [(.1, .6), (.25, .3), (.4, .7), (.55, .35), (.7, .65), (.88, .4)]

async def sign_with_finger(pg, cdp, sid):
    await tap(pg, cdp, S(sid, '[data-sigopen]')); await pg.wait_for_selector('.drv-sign-modal [data-sigpad]'); await pg.wait_for_timeout(200)
    await touch_draw(pg, cdp, ZIG); await tap(pg, cdp, '.drv-sign-modal [data-sigok]'); await pg.wait_for_selector('.drv-sign-modal', state='detached')

async def main():
    os.makedirs(SHOTS, exist_ok=True); srv = dp.serve()
    try:
        async with async_playwright() as p:
            b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
            try:
                adm = await (await b.new_context(viewport={'width': 1280, 'height': 900})).new_page()
                await adm.goto(f'http://127.0.0.1:{dp.PORT}/'); await adm.evaluate('()=>localStorage.clear()'); await dp.login(adm, 'admin@okdespacho.demo')
                ids = await adm.evaluate(dp.PUB); state = await adm.context.storage_state(); await adm.context.close()
                # ================= EXTERNO (Cristian) =================
                ctx = await b.new_context(storage_state=state, **MOB); pg = await ctx.new_page(); cdp = await ctx.new_cdp_session(pg)
                await dp.login(pg, 'cristian@okdespacho.demo'); await dp.open_route(pg, ids['ct']); s1 = await dp.stop_id(pg, ids['ct'], 0)
                await dp.choose(pg, s1, 'ENTREGADO'); form = await pg.locator(S(s1, '.drv-form')).inner_text()
                files = await pg.locator(S(s1, 'input[type=file]')).count()
                res('FC-01 EXTERNO: el formulario pide nombre, CUIL (obligatorio), email y FIRMAR; NINGÚN campo ni texto de foto del DNI',
                    files == 0 and 'DNI' not in form and await pg.locator(S(s1, '[data-f="recv"]')).count() == 1 and await pg.locator(S(s1, '[data-f="cuil"]')).count() == 1
                    and await pg.locator(S(s1, '[data-sigopen]')).count() == 1 and '*' in (await pg.inner_text(S(s1, '[data-field="cuil"] .drv-lbl'))) and 'OPCIONAL' in (await pg.inner_text(S(s1, '[data-field="email"] .drv-lbl'))), {'archivos': files})   # V4.24: etiqueta fija (CUIL *, email OPCIONAL)
                errs = []
                errs.append(await dp.save(pg, s1))
                await pg.fill(S(s1, '[data-f="recv"]'), 'Receptora QA Uno'); errs.append(await dp.save(pg, s1))
                await pg.fill(S(s1, '[data-f="email"]'), 'receptora.uno@ejemplo.test')
                # ---- firma a pantalla completa ----
                await tap(pg, cdp, S(s1, '[data-sigopen]')); await pg.wait_for_selector('.drv-sign-modal [data-sigpad]'); await pg.wait_for_timeout(250)
                geo = await pg.evaluate('''()=>{const m=document.querySelector('.drv-sign-modal').getBoundingClientRect(), c=document.querySelector('.drv-sign-modal [data-sigpad]');
                  const out=[...document.querySelectorAll('.drv-sign-controls button')].filter(b=>{const r=b.getBoundingClientRect(); return r.left<0||r.right>innerWidth||r.bottom>innerHeight;}).length;
                  return {cover:(m.width*m.height)/(innerWidth*innerHeight), overflow:getComputedStyle(document.body).overflow, dpr:devicePixelRatio, cw:c.width, ccss:c.getBoundingClientRect().width,
                    stageH:c.getBoundingClientRect().height, ok:document.querySelector('[data-sigok]').disabled, fuera:out}}''')
                await pg.screenshot(path=os.path.join(SHOTS, 'android_firma_pantalla_completa_vacia.png'))
                res('FC-03 FIRMAR abre la firma a PANTALLA COMPLETA, lienzo en alta resolución (× densidad del celular), página bloqueada, botones dentro de la pantalla y CONFIRMAR deshabilitado sin firma',
                    geo['cover'] >= .97 and geo['overflow'] == 'hidden' and geo['cw'] >= geo['ccss'] * 2.5 and geo['stageH'] >= 500 and geo['ok'] and geo['fuera'] == 0, geo)
                y0 = await pg.evaluate('()=>[scrollY, document.scrollingElement.scrollTop]')
                await touch_draw(pg, cdp, ZIG); ink1 = await pg.evaluate(INK); y1 = await pg.evaluate('()=>[scrollY, document.scrollingElement.scrollTop]')
                okd = await pg.evaluate('()=>document.querySelector("[data-sigok]").disabled')
                await pg.screenshot(path=os.path.join(SHOTS, 'android_firma_con_dedo.png'))
                res('FC-04 se firma con el DEDO (toques reales) y la página NO se desplaza mientras se firma', ink1 and ink1['n'] > 200 and y0 == y1 and not okd, {'tinta': ink1 and ink1['n'], 'scroll': [y0, y1]})
                await tap(pg, cdp, '.drv-sign-modal [data-sigclear]'); ink2 = await pg.evaluate(INK)
                res('FC-05 BORRAR FIRMA limpia el lienzo y vuelve a deshabilitar CONFIRMAR', ink2['n'] == 0 and await pg.evaluate('()=>document.querySelector("[data-sigok]").disabled'), ink2['n'])
                # ---- orientación: vertical → horizontal sin deformar ni perder la firma ----
                await touch_draw(pg, cdp, [(.2, .3), (.5, .7), (.8, .3)]); before = await pg.evaluate(INK)
                await pg.set_viewport_size({'width': 915, 'height': 412}); await pg.wait_for_timeout(500); after = await pg.evaluate(INK)
                fuera_h = await pg.evaluate('()=>[...document.querySelectorAll(".drv-sign-controls button")].filter(b=>{const r=b.getBoundingClientRect(); return r.left<0||r.right>innerWidth||r.bottom>innerHeight;}).length')
                await pg.screenshot(path=os.path.join(SHOTS, 'android_firma_horizontal.png'))
                res('FC-06 al girar a HORIZONTAL el lienzo se adapta (más ancho que alto), los botones siguen visibles y la firma se conserva SIN deformarse',
                    after['cssW'] > after['cssH'] and after['n'] > 50 and abs(after['aspect'] - before['aspect']) / before['aspect'] < .12 and fuera_h == 0,
                    {'antes': [round(before['cssW']), round(before['cssH']), round(before['aspect'], 2)], 'despues': [round(after['cssW']), round(after['cssH']), round(after['aspect'], 2)]})
                await pg.set_viewport_size({'width': 412, 'height': 915}); await pg.wait_for_timeout(400)
                # ---- CANCELAR: no guarda una firma incompleta y no pierde los datos del formulario ----
                await tap(pg, cdp, '.drv-sign-modal [data-sigcancel]'); await pg.wait_for_selector('.drv-sign-modal', state='detached')
                keep = [await pg.input_value(S(s1, '[data-f="recv"]')), await pg.input_value(S(s1, '[data-f="email"]'))]
                prev_hidden = await pg.evaluate(f'()=>document.querySelector(\'{S(s1, "[data-sigprev]")}\').hidden')
                res('FC-07 CANCELAR cierra sin guardar la firma incompleta y CONSERVA los datos del formulario', keep == ['Receptora QA Uno', 'receptora.uno@ejemplo.test'] and prev_hidden
                    and await pg.inner_text(S(s1, '[data-sigopen]')) == 'FIRMAR', keep)
                errs.append(await dp.save(pg, s1))   # sin firma
                # ---- CONFIRMAR: vuelve al formulario con la firma; un CANCELAR posterior no la pierde ----
                await sign_with_finger(pg, cdp, s1)
                src1 = await pg.get_attribute(S(s1, '[data-sigprev]'), 'src'); dims = await pg.evaluate(f'''()=>new Promise(r=>{{const i=new Image(); i.onload=()=>r([i.naturalWidth,i.naturalHeight]); i.src=document.querySelector('{S(s1, "[data-sigprev]")}').src;}})''')
                await tap(pg, cdp, S(s1, '[data-sigopen]')); await pg.wait_for_selector('.drv-sign-modal [data-sigpad]'); await touch_draw(pg, cdp, [(.3, .3), (.4, .6)])
                await tap(pg, cdp, '.drv-sign-modal [data-sigcancel]'); await pg.wait_for_selector('.drv-sign-modal', state='detached')
                src2 = await pg.get_attribute(S(s1, '[data-sigprev]'), 'src')
                await pg.screenshot(path=os.path.join(SHOTS, 'android_formulario_con_firma.png'))
                res('FC-08 CONFIRMAR FIRMA vuelve a la entrega con la firma visible (1200×480, sin deformar); cancelar después NO la pierde',
                    src1 and src1.startswith('data:image/png') and dims == [1200, 480] and src2 == src1 and await pg.inner_text(S(s1, '[data-sigopen]')) == 'FIRMAR DE NUEVO', dims)
                errs.append(await dp.save(pg, s1))   # sin CUIL
                await pg.fill(S(s1, '[data-f="cuil"]'), '2012345678'); await pg.press(S(s1, '[data-f="cuil"]'), 'Tab'); errs.append(await dp.save(pg, s1))   # CUIL corto
                await pg.fill(S(s1, '[data-f="cuil"]'), '20-12345678-6'); await pg.fill(S(s1, '[data-f="email"]'), 'receptora.uno@'); errs.append(await dp.save(pg, s1))   # email mal escrito
                await pg.fill(S(s1, '[data-f="email"]'), 'receptora.uno@ejemplo.test')
                res('FC-02 validaciones: sin nombre / sin firma / sin CUIL / CUIL incompleto / email MAL ESCRITO → no guarda y explica qué corregir (el email se corrige o se borra)',
                    'nombre' in (errs[0] or '') and 'firma' in (errs[1] or '').lower() and 'firma' in (errs[2] or '').lower() and 'CUIL' in (errs[3] or '') and 'obligatorio' in (errs[3] or '')
                    and '11 dígitos' in (errs[4] or '') and 'no es válido' in (errs[5] or '') and 'borralo' in (errs[5] or ''), errs)
                # ---- firma conservada al recargar (borrador) ----
                await pg.fill(S(s1, '[data-f="cuil"]'), '20-12345678-6'); await pg.press(S(s1, '[data-f="cuil"]'), 'Tab'); await pg.wait_for_timeout(300)
                await pg.reload(); await pg.wait_for_timeout(2500); await dp.dismiss(pg)
                if await pg.locator(f'[data-open="{ids["ct"]}"]').count(): await dp.open_route(pg, ids['ct'])
                await dp.choose(pg, s1, 'ENTREGADO')
                rsrc = await pg.get_attribute(S(s1, '[data-sigprev]'), 'src'); rname = await pg.input_value(S(s1, '[data-f="recv"]'))
                res('FC-12 al recargar la página (p. ej. Android la cierra) se recuperan nombre, CUIL y la FIRMA confirmada', rsrc == src1 and rname == 'Receptora QA Uno'
                    and (await pg.input_value(S(s1, '[data-f="cuil"]'))).replace('-', '') == '20123456786', rname)
                # ---- guardar: una sola confirmación, evidencia completa, sin foto del DNI ----
                await pg.locator(S(s1, '[data-save]')).dblclick(); await pg.wait_for_timeout(2200)
                db = await pg.evaluate('''(sid)=>{const d=JSON.parse(localStorage.getItem("okd_online_demo_v2")); const e=(d.evidence||{})[sid]||{};
                  return {e, out:(d.routes2||[]).flatMap(r=>r.stops).find(s=>s.id===sid).outcome, jobs:(d.customerJobs||[]).filter(j=>j.stop_id===sid).length,
                    ident:((d.identity||{})["20123456786"]||{}).storage_path||null, store:Object.keys(d.storage||{}).filter(k=>k.startsWith("20123456786/")).length}}''', s1)
                e = db['e']; sz = png_size(e.get('signature_png_b64') or '')
                res('FC-09 EXTERNO con EMAIL: guarda la entrega UNA vez (doble toque en GUARDAR): nombre + CUIL + firma PNG 1200×480, SIN foto del DNI, Recibido Conforme encolado',
                    db['out'] == 'ENTREGADO' and e.get('receiver_name') == 'Receptora QA Uno' and e.get('cuil') == '20123456786' and sz == (1200, 480) and not db['ident'] and db['store'] == 0 and db['jobs'] == 1,
                    {'salida': db['out'], 'png': sz, 'foto': db['ident'], 'avisos': db['jobs']})
                await ctx.close()
                # ================= INTERNO (Gabriel): llegada a destino + entrega comercial + recepción interna G2 =================
                ctx = await b.new_context(storage_state=state, **MOB); pg = await ctx.new_page(); cdp = await ctx.new_cdp_session(pg); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
                await dp.login(pg, 'gabriel@okdespacho.demo'); await dp.open_route(pg, ids['gb'], km=50100)   # km inicial válido para el vehículo de la demo
                sc = await dp.stop_id(pg, ids['gb'], 0); sm = await dp.stop_id(pg, ids['gb'], 1)
                arrive = await pg.locator(S(sc, '[data-arrive]')).count()
                if arrive: await pg.locator(S(sc, '[data-arrive]')).click(); await pg.wait_for_timeout(1500)
                await dp.choose(pg, sc, 'ENTREGADO'); f_int = await pg.locator(S(sc, '.drv-form')).inner_text()
                await pg.fill(S(sc, '[data-f="recv"]'), 'Receptor QA Dos')   # V4.21: SIN email (opcional)
                await pg.fill(S(sc, '[data-f="cuil"]'), '20987654321'); await pg.press(S(sc, '[data-f="cuil"]'), 'Tab'); await sign_with_finger(pg, cdp, sc)
                e_int = await dp.save(pg, sc); ag = await pg.evaluate(dp.ASSOC, sc); st_gb = await pg.evaluate(dp.DB, ids['gb'])
                res('FC-10 INTERNO SIN EMAIL: conserva LLEGADA A DESTINO y confirma con nombre + CUIL + firma, SIN foto del DNI y SIN Recibido Conforme (no hay a quién enviarlo)',
                    arrive == 1 and 'DNI' not in f_int and await pg.locator(S(sc, 'input[type=file]')).count() == 0 and e_int is None and st_gb[0]['outcome'] == 'ENTREGADO'
                    and ag['cuil'] == '20987654321' and not ag['dniStored'] and not ag['email'] and not ag['receipt'] and ag['job'] != 'RECIBIDO_CONFORME', {'llegada': arrive, 'error': e_int, 'asoc': ag})
                if await pg.locator(S(sm, '[data-arrive]')).count(): await pg.locator(S(sm, '[data-arrive]')).click(); await pg.wait_for_timeout(1500)
                await dp.choose(pg, sm, 'ENTREGADO')
                g2 = {'cuil': await pg.locator(S(sm, '[data-f="cuil"]')).count(), 'email': await pg.locator(S(sm, '[data-f="email"]')).count(), 'firmar': await pg.locator(S(sm, '[data-sigopen]')).count()}
                await pg.fill(S(sm, '[data-f="recv"]'), 'Encargada Sucursal QA'); await sign_with_finger(pg, cdp, sm); e_g2 = await dp.save(pg, sm)
                st_gb = await pg.evaluate(dp.DB, ids['gb'])
                res('FC-11 G2 · recepción interna de traslado: solo nombre + firma (sin CUIL ni email) y se guarda como siempre',
                    g2 == {'cuil': 0, 'email': 0, 'firmar': 1} and e_g2 is None and st_gb[1]['outcome'] == 'ENTREGADO', {'campos': g2, 'error': e_g2})
                await ctx.close()
            finally: await b.close()
    finally: srv.terminate()
    print('TOTAL', sum(1 for r in R if r[1] == 'PASS'), 'PASS /', sum(1 for r in R if r[1] == 'FAIL'), 'FAIL · esperados', EXPECTED)
    return R

if __name__ == '__main__':
    try: rr = asyncio.run(main())
    except Exception as e: traceback.print_exc(); print('ERROR:', repr(e)); sys.exit(2)
    if len(rr) != EXPECTED: print('ERROR: se ejecutaron %d de %d' % (len(rr), EXPECTED)); sys.exit(2)
    sys.exit(1 if any(r[1] != 'PASS' for r in rr) else 0)
