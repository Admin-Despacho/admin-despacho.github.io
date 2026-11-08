"""V4.27 · ACCESO COMPLETO del Administrador General: mismos destinos de navegación que la versión publicada y cada módulo abre sin error.
Uso: python3 run_v427_admin_acceso.py <dist-publicado> <dist-parche>"""
import asyncio, os, sys
sys.path.insert(0, os.path.dirname(__file__))
import run_driver_perfiles as dp
from playwright.async_api import async_playwright
async def navs(b, dist, port):
    dp.PORT = port; dp.DIST = dist; srv = dp.serve()
    try:
        pg = await (await b.new_context(viewport={'width': 1366, 'height': 768})).new_page(); errs = []; pg.on('pageerror', lambda e: errs.append(str(e)[:120]))
        await pg.goto(f'http://127.0.0.1:{port}/'); await pg.evaluate('()=>localStorage.clear()'); await dp.login(pg, 'admin@okdespacho.demo'); await pg.wait_for_timeout(800)
        hrefs = sorted(set(await pg.evaluate('()=>[...document.querySelectorAll(".rc4side a[href^=\\"#/\\"]")].map(a=>a.getAttribute("href"))')))
        abre = {}
        for h in hrefs:
            await pg.evaluate(f'()=>{{location.hash="{h}"}}'); await pg.wait_for_timeout(1100)
            abre[h] = await pg.evaluate('()=>{const t=document.body.innerText; return !/Sin permiso|FORBIDDEN|no tenés permiso/i.test(t) && t.length>200}')
        return hrefs, abre, errs
    finally: srv.terminate()
async def main():
    async with async_playwright() as p:
        b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
        h0, a0, e0 = await navs(b, sys.argv[1], 4480); h1, a1, e1 = await navs(b, sys.argv[2], 4481); await b.close()
    ok = h0 == h1 and all(a1.values()) and not e1
    print('destinos publicados', len(h0), '· parche', len(h1), '· iguales', h0 == h1, '· todos abren', all(a1.values()), '· errores de página', len(e1))
    print('no abren:', [h for h, v in a1.items() if not v], 'errores:', e1[:3])
    print('PASS' if ok else 'FAIL', 'AD-01 el Administrador General conserva TODOS los destinos y cada módulo abre sin error ni rechazo')
    sys.exit(0 if ok else 1)
asyncio.run(main())
