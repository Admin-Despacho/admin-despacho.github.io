"""E2E (modo demo, Chromium, ANDROID) · V4.24 · Cristian Torres (Transportista EXTERNO): entregas de hojas ANTIGUAS abiertas, parciales,
reprogramación + SEGUNDA VISITA y hojas nuevas, SIN fotografía del DNI (nombre + CUIL + firma obligatorios; email opcional). Datos ficticios.
Uso: python3 tests/e2e/run_cristian_sin_dni.py [dist-demo]   ·   Exit 0 todo PASS · 1 alguna FAIL · 2 error."""
import asyncio, os, sys, traceback
sys.path.insert(0, os.path.dirname(__file__))
import run_driver_perfiles as dp
from playwright.async_api import async_playwright
dp.PORT = 4405; R = []; EXPECTED = 4
if len(sys.argv) > 1: dp.DIST = sys.argv[1]
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:260])); print('..', ' | '.join(R[-1]), flush=True)
MOB = dict(viewport={'width': 412, 'height': 915}, device_scale_factor=2.625, is_mobile=True, geolocation={'latitude': -32.89, 'longitude': -68.84}, permissions=['geolocation'])   # la entrega registra el GPS
S = lambda sid, sel: f'.drv-stop[data-s="{sid}"] {sel}'
STOP = '''(sid)=>{const d=JSON.parse(localStorage.getItem("okd_online_demo_v2")); const r=d.routes2.find(x=>x.stops.some(s=>s.id===sid)); const s=r.stops.find(x=>x.id===sid); const e=(d.evidence||{})[sid]||{};
  return {out:s.outcome, name:e.receiver_name||null, cuil:e.cuil||null, sig:!!e.signature_png_b64, foto:!!((d.identity||{})[e.cuil]||{}).storage_path, ev:Object.keys(d.evidence||{}).filter(k=>k===sid).length,
    rc:(d.customerJobs||[]).filter(j=>j.stop_id===sid&&j.kind==="RECIBIDO_CONFORME").length}}'''
async def deliver(pg, sid, outcome='ENTREGADO', cuil='20123456786', note=None):
    if await pg.locator(S(sid, '[data-arrive]')).count(): await pg.locator(S(sid, '[data-arrive]')).click(); await pg.wait_for_timeout(900)
    await dp.choose(pg, sid, outcome)
    form = await pg.locator(S(sid, '.drv-form')).inner_text(); files = await pg.locator(S(sid, 'input[type=file]')).count()
    await pg.fill(S(sid, '[data-f="recv"]'), 'Receptor Cristian QA'); await pg.fill(S(sid, '[data-f="cuil"]'), cuil); await pg.press(S(sid, '[data-f="cuil"]'), 'Tab')
    if note: await pg.fill(S(sid, '[data-f="txt"]'), note)
    await dp.sign(pg, sid); err = await dp.save(pg, sid)
    if err: print('   error al guardar', sid, ':', err)
    await pg.wait_for_timeout(1500); toast = await pg.evaluate('()=>{const t=document.getElementById("drvToast"); return t&&!t.hidden?t.textContent:null}')
    if toast: print('   aviso del servidor', sid, ':', toast)
    if await pg.locator(S(sid, '[data-save]')).count() and await pg.locator(S(sid, '[data-save]')).is_visible():   # segundo toque: no debe duplicar
        try: await pg.locator(S(sid, '[data-save]')).click(timeout=2000)
        except Exception: pass
    await pg.wait_for_timeout(1200)
    return form, files

async def main():
    srv = dp.serve()
    try:
        async with async_playwright() as p:
            b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
            try:
                adm = await (await b.new_context(viewport={'width': 1280, 'height': 900})).new_page()
                await adm.goto(f'http://127.0.0.1:{dp.PORT}/'); await adm.evaluate('()=>localStorage.clear()'); await dp.login(adm, 'admin@okdespacho.demo')
                ids = await adm.evaluate(dp.PUB); state = await adm.context.storage_state()
                ctx = await b.new_context(storage_state=state, **MOB); pg = await ctx.new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
                await dp.login(pg, 'cristian@okdespacho.demo'); await dp.open_route(pg, ids['ctOld'])
                s1 = await dp.stop_id(pg, ids['ctOld'], 0); s2 = await dp.stop_id(pg, ids['ctOld'], 1)
                f1, n1 = await deliver(pg, s1); r1 = await pg.evaluate(STOP, s1)
                res('CT-01 HOJA ANTIGUA abierta (ENTREGA + cobranza): ENTREGADO con nombre + CUIL + firma, SIN foto del DNI y sin email; una sola confirmación (doble toque)',
                    r1['out'] == 'ENTREGADO' and r1['name'] and r1['cuil'] == '20123456786' and r1['sig'] and not r1['foto'] and r1['ev'] == 1 and n1 == 0 and 'DNI' not in f1, r1)
                f2, n2 = await deliver(pg, s2, 'ENTREGA_PARCIAL', '27555555550', note='faltaron 2 cajas (QA)'); r2 = await pg.evaluate(STOP, s2)
                res('CT-02 ENTREGA PARCIAL de la hoja antigua sin DNI (observación obligatoria como siempre)', r2['out'] == 'ENTREGA_PARCIAL' and r2['sig'] and not r2['foto'] and n2 == 0, r2)
                await pg.locator('#drvBack').click(); await pg.wait_for_timeout(800); await dp.open_route(pg, ids['ct'])   # volver a la lista y abrir la otra hoja
                s3 = await dp.stop_id(pg, ids['ct'], 0)
                await dp.choose(pg, s3, 'REPROGRAMAR'); await pg.fill(S(s3, '[data-f="txt"]'), 'cliente cerrado (QA)'); e3 = await dp.save(pg, s3)
                state_c = await ctx.storage_state(); await ctx.close()   # la demo guarda por navegador: el administrador parte de lo que hizo Cristian
                # SEGUNDA VISITA: el pedido reprogramado vuelve en una hoja NUEVA
                ctx = await b.new_context(storage_state=state_c, viewport={'width': 1280, 'height': 900}); a2 = await ctx.new_page(); await a2.goto(f'http://127.0.0.1:{dp.PORT}/'); await dp.login(a2, 'admin@okdespacho.demo')
                order = await a2.evaluate('''(rid)=>JSON.parse(localStorage.getItem("okd_online_demo_v2")).routes2.find(r=>r.id===rid).stops[0].order_numbers''', ids['ct'])
                try:
                    pub = await a2.evaluate('''async(o)=>{const A=window.OKD_ONLINE.api; return (await A.publishRoute({sheet_key:'qa-ct2-'+Date.now(), carrier_id:'CT-ESTE', responsable_id:'u-cristian', rules_version:1, routing_rules_version:1,
                      stops:[{ready:true, client_name:'CLIENTE QA SEGUNDA VISITA', client_key:'qa-2v', address:'Calle Falsa 2, Mendoza', zone:'ESTE', order_numbers:o, merchandise_amount:1000, shipping_fee:0, task:'ENTREGA', stop_type:'PEDIDO', expected_amount:1000}]})).id}''', order)
                except Exception as ex: pub = None; print('segunda visita no publicada:', ex)
                state2 = await ctx.storage_state(); await ctx.close()
                ctx = await b.new_context(storage_state=state2, **MOB); pg = await ctx.new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
                await dp.login(pg, 'cristian@okdespacho.demo'); await dp.open_route(pg, pub); s4 = await dp.stop_id(pg, pub, 0)
                f4, n4 = await deliver(pg, s4); r4 = await pg.evaluate(STOP, s4)
                res('CT-03 REPROGRAMAR y SEGUNDA VISITA en una hoja nueva: se entrega SIN DNI (nombre + CUIL + firma)', e3 is None and r4['out'] == 'ENTREGADO' and r4['sig'] and not r4['foto'] and n4 == 0, {'reprogramar': e3, 'segunda': r4})
                # hoja NUEVA común
                ctx2 = await b.new_context(storage_state=await ctx.storage_state(), viewport={'width': 1280, 'height': 900}); a3 = await ctx2.new_page(); await a3.goto(f'http://127.0.0.1:{dp.PORT}/'); await dp.login(a3, 'admin@okdespacho.demo')
                pub2 = await a3.evaluate('''async()=>{const A=window.OKD_ONLINE.api; return (await A.publishRoute({sheet_key:'qa-ct3-'+Date.now(), carrier_id:'CT-ESTE', responsable_id:'u-cristian', rules_version:1, routing_rules_version:1,
                  stops:[{ready:true, client_name:'CLIENTE QA NUEVA', client_key:'qa-nueva', address:'Calle Nueva 1, Mendoza', zone:'ESTE', order_numbers:['93001'], merchandise_amount:500, shipping_fee:0, task:'ENTREGA', stop_type:'PEDIDO', expected_amount:500}]})).id}''')
                st3 = await ctx2.storage_state(); await ctx2.close(); await ctx.close()
                ctx = await b.new_context(storage_state=st3, **MOB); pg = await ctx.new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
                await dp.login(pg, 'cristian@okdespacho.demo'); await dp.open_route(pg, pub2); s5 = await dp.stop_id(pg, pub2, 0); f5, n5 = await deliver(pg, s5); r5 = await pg.evaluate(STOP, s5)
                res('CT-04 HOJA NUEVA: entrega SIN DNI con nombre + CUIL + firma; email opcional (vacío → sin Recibido Conforme)', r5['out'] == 'ENTREGADO' and r5['sig'] and not r5['foto'] and r5['rc'] == 0 and n5 == 0 and 'OPCIONAL' in f5, r5)
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
