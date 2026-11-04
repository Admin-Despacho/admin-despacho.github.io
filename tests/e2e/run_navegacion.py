"""E2E (modo demo, Chromium) · V4.20 · Navegación: menú lateral con íconos, PLEGABLE y OCULTABLE (notebook); VER HOJA en pestaña
interna (sin desplazarse al final); filtros plegables y conservados al cambiar de vista; celular sin cambios; constructor intacto.
Uso: python3 tests/e2e/run_navegacion.py [dist-demo]   ·   Exit 0 todo PASS · 1 alguna FAIL · 2 error. Datos ficticios."""
import asyncio, os, sys, traceback
sys.path.insert(0, os.path.dirname(__file__))
import run_driver_perfiles as dp
from playwright.async_api import async_playwright
dp.PORT = 4398; R = []; EXPECTED = 10
if len(sys.argv) > 1: dp.DIST = sys.argv[1]
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:240])); print('..', ' | '.join(R[-1]), flush=True)
SIDE = '''()=>{const s=document.querySelector("#usersPanel .rc4side"), r=s&&s.getBoundingClientRect(); const lbl=[...document.querySelectorAll("#usersPanel .rc4side .nav > a .nlbl")];
  return {w:r?Math.round(r.width):0, shown:!!s&&getComputedStyle(s).display!=="none", icons:document.querySelectorAll("#usersPanel .rc4side .nav > a svg.nico").length,
    links:document.querySelectorAll("#usersPanel .rc4side .nav > a").length, lblVisible:lbl.filter(l=>l.offsetParent!==null).length,
    show:(()=>{const b=document.querySelector("[data-sideshow]"); return !!b&&getComputedStyle(b).display!=="none";})()}}'''
async def goto(pg, h): await pg.evaluate(f'()=>{{location.hash="{h}"}}'); await pg.wait_for_timeout(1500)

async def main():
    srv = dp.serve()
    try:
        async with async_playwright() as p:
            b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
            try:
                ctx = await b.new_context(viewport={'width': 1366, 'height': 800}); pg = await ctx.new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
                await pg.goto(f'http://127.0.0.1:{dp.PORT}/'); await pg.evaluate('()=>{localStorage.clear(); sessionStorage.clear();}'); await dp.login(pg, 'admin@okdespacho.demo')
                ids = await pg.evaluate(dp.PUB); await goto(pg, '#/historial')
                s0 = await pg.evaluate(SIDE)
                res('NV-01 menú lateral con ÍCONOS en cada destino principal (los submenús van indentados debajo)', s0['links'] > 5 and s0['icons'] == s0['links'] and s0['lblVisible'] == s0['links'], s0)
                await pg.click('#usersPanel [data-sidefold]'); await pg.wait_for_timeout(400); s1 = await pg.evaluate(SIDE)
                await pg.locator('#usersPanel .rc4side .nav > a[data-nav="#/informes"]').click(); await pg.wait_for_timeout(1300); h1 = await pg.evaluate('()=>location.hash')
                res('NV-02 PLEGADO: queda una columna angosta solo con íconos y se navega igual (clic en el ícono de Informes)', s1['w'] <= 90 and s1['icons'] == s1['links'] and s1['lblVisible'] == 0 and h1.startswith('#/informes'), {'ancho': s1['w'], 'hash': h1})
                await pg.reload(); await pg.wait_for_timeout(2500); await dp.dismiss(pg); s2 = await pg.evaluate(SIDE)
                res('NV-03 la elección (plegado) se RECUERDA al recargar', s2['w'] <= 90 and s2['lblVisible'] == 0, s2['w'])
                await pg.click('#usersPanel [data-sidefold]'); await pg.wait_for_timeout(300); await pg.click('#usersPanel [data-sidehide]'); await pg.wait_for_timeout(400); s3 = await pg.evaluate(SIDE)
                await pg.click('#usersPanel [data-sideshow]'); await pg.wait_for_timeout(400); s4 = await pg.evaluate(SIDE)
                res('NV-04 OCULTAR el menú: desaparece y aparece ☰; ☰ lo vuelve a mostrar completo', not s3['shown'] and s3['show'] and s4['shown'] and s4['lblVisible'] == s4['links'] and not s4['show'], {'oculto': s3, 'mostrado': s4['w']})
                # ===== Historial: filtros plegables, VER HOJA en pestaña, estado conservado =====
                await goto(pg, '#/historial')
                fold = await pg.evaluate('()=>{const d=document.getElementById("hFold"); return !!d && d.tagName==="DETAILS" && d.contains(document.getElementById("hFilters"))}')
                await pg.click('#hFold > summary'); await pg.wait_for_timeout(200); closed = await pg.evaluate('()=>!document.getElementById("hFold").open')
                await pg.click('#hFold > summary'); await pg.wait_for_timeout(200)
                res('NV-05 los FILTROS están en un bloque plegable (se pliega y se despliega)', fold and closed, {'plegable': fold, 'cerró': closed})
                await pg.fill('#hfClient', 'CLIENTE'); await pg.click('#hfGo'); await pg.wait_for_timeout(1200)
                await pg.evaluate('()=>window.scrollTo(0, document.body.scrollHeight)'); await pg.wait_for_timeout(200)
                await pg.locator('#histTable [data-view]').first.click(); await pg.wait_for_timeout(1600)
                v = await pg.evaluate('''()=>{const d=document.getElementById("hDetail"), t=document.querySelector('[data-htab="detail"]'), s=document.getElementById("hSheet");
                  return {det:!d.hidden, lista:!document.getElementById("hList").hidden, tab:t&&!t.hidden&&t.getAttribute("aria-selected")==="true", label:t&&t.textContent,
                    top:s?Math.round(s.getBoundingClientRect().top):9999, vh:innerHeight}}''')
                res('NV-06 VER HOJA abre la hoja en una PESTAÑA interna, arriba y visible sin desplazarse (la lista queda oculta)', v['det'] and not v['lista'] and v['tab'] and v['label'].startswith('HOJA ') and 0 <= v['top'] < v['vh'] * .6, v)
                await pg.click('[data-htab="list"]'); await pg.wait_for_timeout(500)
                back = await pg.evaluate('()=>({lista:!document.getElementById("hList").hidden, det:!document.getElementById("hDetail").hidden, cliente:document.getElementById("hfClient").value})')
                res('NV-07 LISTADO vuelve a la lista con los filtros intactos', back['lista'] and not back['det'] and back['cliente'] == 'CLIENTE', back)
                await pg.locator('#histTable [data-view]').first.click(); await pg.wait_for_timeout(1300)
                await goto(pg, '#/informes'); await goto(pg, '#/historial'); await pg.wait_for_timeout(1200)
                ret = await pg.evaluate('()=>({cliente:document.getElementById("hfClient").value, det:!document.getElementById("hDetail").hidden, tab:(document.querySelector(\'[data-htab="detail"]\')||{}).textContent||""})')
                res('NV-08 al CAMBIAR de vista y volver se conservan los filtros y se reabre la hoja que estaba abierta', ret['cliente'] == 'CLIENTE' and ret['det'] and ret['tab'].startswith('HOJA '), ret)
                # ===== constructor intacto =====
                await goto(pg, '#/despacho'); await pg.wait_for_timeout(1500)
                bld = await pg.evaluate('()=>({rs:typeof RouteStore!=="undefined", tabla:!!document.querySelector("#mainTable, table.sheet, .sheet-table, #tbl"), side:!!document.querySelector(".rc4side")})')
                res('NV-10 el CONSTRUCTOR (#/despacho) sigue cargando igual', bld['rs'], bld)
                await ctx.close()
                # ===== celular: el menú móvil de siempre; sin botones de plegar/ocultar =====
                ctx = await b.new_context(viewport={'width': 412, 'height': 915}, is_mobile=True, has_touch=True, device_scale_factor=2.625); pg = await ctx.new_page()
                await pg.goto(f'http://127.0.0.1:{dp.PORT}/'); await dp.login(pg, 'admin@okdespacho.demo'); await goto(pg, '#/historial')
                mob = await pg.evaluate('''()=>{const vis=s=>{const e=document.querySelector(s); return !!e&&getComputedStyle(e).display!=="none"&&e.getBoundingClientRect().width>0;};
                  return {fold:vis("[data-sidefold]"), hide:vis("[data-sidehide]"), show:vis("[data-sideshow]"), menu:vis(".rc4menu"), over:document.documentElement.scrollWidth-document.documentElement.clientWidth}}''')
                res('NV-09 CELULAR: conserva su menú (☰ de siempre) y no muestra los controles de plegar/ocultar; sin desplazamiento lateral',
                    mob['menu'] and not mob['fold'] and not mob['hide'] and not mob['show'] and mob['over'] <= 0, mob)
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
