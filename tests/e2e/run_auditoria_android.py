"""Auditoría (modo demo, Chromium, ANDROID Pixel 7 · 412 px) · V4.24 · por pantalla operativa: desplazamiento lateral de la página, botones/campos
FUERA de pantalla (sin contar tablas con desplazamiento horizontal propio) y DÓNDE aparece el detalle al tocar VER HOJA / VER ENTREGA /
VER RECORRIDO (debe quedar a la vista, sin desplazarse al final). Uso: python3 tests/e2e/run_auditoria_android.py [dist-demo] [capturas]"""
import asyncio, os, sys, traceback
sys.path.insert(0, os.path.dirname(__file__))
import run_driver_perfiles as dp
from playwright.async_api import async_playwright
dp.PORT = 4406; R = []; EXPECTED = 9
if len(sys.argv) > 1: dp.DIST = sys.argv[1]
SHOTS = sys.argv[2] if len(sys.argv) > 2 else '/tmp/okd_audit_shots'
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:260])); print('..', ' | '.join(R[-1]), flush=True)
MOB = dict(viewport={'width': 412, 'height': 915}, device_scale_factor=2.625, is_mobile=True, has_touch=True, geolocation={'latitude': -32.89, 'longitude': -68.84}, permissions=['geolocation'])
AUDIT = '''()=>{const vw=innerWidth; const inScroll=el=>{for(let p=el.parentElement;p;p=p.parentElement){const o=getComputedStyle(p).overflowX; if(o==="auto"||o==="scroll") return true;} return false;};
  const vis=el=>{const r=el.getBoundingClientRect(), cs=getComputedStyle(el); return r.width>0&&r.height>0&&cs.visibility!=="hidden"&&cs.display!=="none";};
  const bad=[...document.querySelectorAll("button,a.btn,input:not([type=hidden]),select,textarea")].filter(el=>vis(el)&&!inScroll(el)).filter(el=>{const r=el.getBoundingClientRect(); return r.right>vw+1||r.left<-1;})
    .map(el=>(el.id||el.dataset.sec||el.textContent||el.name||el.tagName).trim().slice(0,30));
  return {over:document.documentElement.scrollWidth-document.documentElement.clientWidth, fuera:bad.slice(0,6), n:bad.length}}'''
async def go(pg, h): await pg.evaluate(f'()=>{{location.hash="{h}"}}'); await pg.wait_for_timeout(1700)
async def check(pg, name, extra_ok=True, extra=None):
    a = await pg.evaluate(AUDIT); await pg.screenshot(path=os.path.join(SHOTS, name.split(' ')[0] + '.png'))
    res(name, a['over'] <= 0 and a['n'] == 0 and extra_ok, {**a, **(extra or {})})
async def top_of(pg, sel):
    return await pg.evaluate(f'()=>{{const e=document.querySelector("{sel}"); if(!e) return null; const r=e.getBoundingClientRect(); return {{top:Math.round(r.top), vh:innerHeight}}}}')

async def main():
    os.makedirs(SHOTS, exist_ok=True); srv = dp.serve()
    try:
        async with async_playwright() as p:
            b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
            try:
                adm = await (await b.new_context(viewport={'width': 1280, 'height': 900})).new_page()
                await adm.goto(f'http://127.0.0.1:{dp.PORT}/'); await adm.evaluate('()=>localStorage.clear()'); await dp.login(adm, 'admin@okdespacho.demo')
                ids = await adm.evaluate(dp.PUB); state = await adm.context.storage_state(); await adm.context.close()
                # ===== chofer interno (hoja en curso) y externo =====
                c = await b.new_context(storage_state=state, **MOB); pg = await c.new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
                await dp.login(pg, 'gabriel@okdespacho.demo'); await dp.open_route(pg, ids['gb'], km=50100)
                await check(pg, 'AU-01 chofer INTERNO (hoja en curso, SALÍ/LLEGUÉ/TERMINÉ, pie fijo): sin desplazamiento lateral ni botones fuera de pantalla')
                await pg.locator('#drvBack').click(); await pg.wait_for_timeout(700); state = await c.storage_state(); await c.close()
                c = await b.new_context(storage_state=state, **MOB); pg = await c.new_page(); await dp.login(pg, 'cristian@okdespacho.demo'); await dp.open_route(pg, ids['ct'])
                await check(pg, 'AU-02 chofer EXTERNO: sin desplazamiento lateral ni botones fuera de pantalla'); await c.close()
                # ===== administración en Android =====
                c = await b.new_context(storage_state=state, **MOB); pg = await c.new_page(); await pg.goto(f'http://127.0.0.1:{dp.PORT}/'); await dp.login(pg, 'admin@okdespacho.demo')
                await go(pg, '#/historial'); await check(pg, 'AU-03 HISTORIAL (listado y filtros plegables)')
                await pg.evaluate('()=>window.scrollTo(0, document.body.scrollHeight)'); await pg.wait_for_timeout(300)
                await pg.locator(f'#histTable tr[data-rid="{ids["gb"]}"] [data-view]').click(); await pg.wait_for_timeout(1500); t = await top_of(pg, '#hSheet')
                await check(pg, 'AU-04 VER HOJA desde el FINAL de la lista: el detalle aparece ARRIBA, a la vista, en su pestaña (sin bajar)', bool(t) and 0 <= t['top'] < t['vh'] * .5, {'detalle': t})
                rows = pg.locator('#hSheet [data-delivery-detail]'); await rows.nth(1).click(); await pg.wait_for_timeout(1600); t2 = await top_of(pg, '#deliveryTraceBox .dt')
                await check(pg, 'AU-05 VER ENTREGA: el panel queda a la vista junto a la parada (sin buscarlo al final de la página)', bool(t2) and 0 <= t2['top'] < t2['vh'], {'panel': t2})
                await go(pg, '#/recorridos'); await pg.locator(f'#rcTable tr[data-rid="{ids["gb"]}"] [data-rcview]').click(); await pg.wait_for_timeout(1500); t3 = await top_of(pg, '#rcRoute')
                await check(pg, 'AU-06 SALIDA Y RECORRIDO: VER RECORRIDO abre el detalle ARRIBA en su pestaña', bool(t3) and 0 <= t3['top'] < t3['vh'] * .5, {'detalle': t3})
                await pg.click('[data-rctab="list"]'); await pg.wait_for_timeout(500); back = await pg.evaluate('()=>!document.getElementById("rcList").hidden')
                res('AU-07 volver al LISTADO desde el detalle conserva la lista (y los filtros)', back, back)
                await go(pg, '#/configuracion?sec=emails_clientes'); await pg.wait_for_timeout(500)
                if await pg.locator('[data-sec="emails_clientes"]').count(): await pg.locator('[data-sec="emails_clientes"]').click(); await pg.wait_for_timeout(900)
                await check(pg, 'AU-08 Configuración → J. EMAILS DE CLIENTES en Android')
                await go(pg, '#/despacho'); await pg.wait_for_timeout(1500); a = await pg.evaluate(AUDIT); await pg.screenshot(path=os.path.join(SHOTS, 'AU-09.png'))
                res('AU-09 CONSTRUCTOR en Android (medición; NO se rediseña): se informa el resultado', True, a)
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
