"""E2E (Chromium) · Política de privacidad PÚBLICA de OK Despacho (sin iniciar sesión) y enlaces desde la app.
Uso: python3 tests/e2e/run_privacidad.py <carpeta del build> [carpeta de capturas]
Exit 0 todo PASS · 1 alguna FAIL · 2 error de preparación o casos faltantes."""
import asyncio, os, sys, traceback
sys.path.insert(0, os.path.dirname(__file__))
import run_cambiar_rol as cr
from playwright.async_api import async_playwright
cr.PORT = 4394; R = []; EXPECTED = 5; SHOTS = sys.argv[2] if len(sys.argv) > 2 else '/tmp/okd_priv_shots'
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:260])); print('..', ' | '.join(R[-1]), flush=True)
REQUIRED = ['Comunicaciones', 'nombre, correo electrónico, celular, sucursal, sector', 'https://www.googleapis.com/auth/gmail.send', 'openid', 'Supabase Vault',
            'El navegador nunca recibe tokens', 'almacenamiento privado', 'Historial de envíos', 'no elimina automáticamente', 'DESCONECTAR',
            'despachoapp26@gmail.com', 'Uso Limitado', 'WhatsApp']

async def main():
    os.makedirs(SHOTS, exist_ok=True); srv = cr.serve(); base = f'http://127.0.0.1:{cr.PORT}'
    try:
        async with async_playwright() as p:
            b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
            try:
                # PR-01: navegador LIMPIO (sin sesión ni almacenamiento): la página se sirve sola, sin cargar la aplicación
                ctx = await b.new_context(viewport={'width': 1366, 'height': 900}); pg = await ctx.new_page(); errs = []; scripts = []
                pg.on('pageerror', lambda e: errs.append(str(e))); pg.on('request', lambda r: scripts.append(r.url) if r.resource_type == 'script' else None)
                r = await pg.goto(base + '/privacidad.html'); await pg.wait_for_timeout(600)
                title = await pg.title(); body = await pg.locator('body').inner_text()
                res('PR-01 /privacidad.html se abre SIN iniciar sesión (200), sin cargar la aplicación ni errores', r.status == 200 and title.startswith('Política de privacidad')
                    and 'INGRESAR' not in body and not scripts and not errs, {'estado': r.status, 'titulo': title, 'scripts': scripts[:2], 'errores': errs[:2]})
                # PR-02: describe cada punto pedido
                missing = [x for x in REQUIRED if x not in body]
                mail = await pg.locator('a[href="mailto:despachoapp26@gmail.com"]').count()
                perm = await pg.locator('a[href="https://myaccount.google.com/permissions"]').count()
                res('PR-02 describe colaboradores, Gmail API y permisos, tokens en el servidor, adjuntos, historial, conservación, desconexión, eliminación y contacto',
                    not missing and mail >= 2 and perm == 1, {'faltan': missing, 'enlaces_mailto': mail, 'enlace_permisos_google': perm})
                await pg.screenshot(path=os.path.join(SHOTS, 'privacidad_computadora.png'), full_page=True); await ctx.close()
                # PR-03: el enlace de la pantalla de ingreso lleva a la página
                ctx = await b.new_context(viewport={'width': 1366, 'height': 900}); pg = await ctx.new_page()
                await pg.goto(base + '/'); await pg.evaluate('()=>localStorage.clear()'); await pg.reload(); await pg.wait_for_timeout(1500)
                link = pg.locator('.login-legal a', has_text='Política de privacidad'); n = await link.count()
                async with ctx.expect_page() as newp: await link.first.click()
                pp = await newp.value; await pp.wait_for_load_state(); dest = pp.url; h1 = await pp.locator('h1').inner_text()
                res('PR-03 la pantalla de ingreso tiene el enlace "Política de privacidad" y abre la página pública', n == 1 and dest.endswith('/privacidad.html') and h1 == 'Política de privacidad',
                    {'enlaces': n, 'destino': dest}); await ctx.close()
                # PR-04: celular, sin desplazamiento horizontal
                ctx = await b.new_context(**cr.MOB); pg = await ctx.new_page(); await pg.goto(base + '/privacidad.html'); await pg.wait_for_timeout(500)
                over = await pg.evaluate('()=>document.documentElement.scrollWidth - document.documentElement.clientWidth')
                await pg.screenshot(path=os.path.join(SHOTS, 'privacidad_celular.png'))
                res('PR-04 en celular se lee sin desplazamiento horizontal', over <= 0, {'exceso_px': over}); await ctx.close()
                # PR-05: demo · Conexión Gmail enlaza la política y, al desconectar, informa si Google confirmó la revocación
                ctx = await b.new_context(**cr.DESK); pg = await ctx.new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
                await pg.goto(base + '/'); await pg.evaluate('()=>localStorage.clear()'); await cr.login(pg, 'admin@okdespacho.demo')
                await pg.evaluate('async()=>{ await window.OKD_ONLINE.api.commsGmailConnect(); }')
                await pg.evaluate('()=>{location.hash="#/comunicaciones?sec=gmail"}'); await pg.wait_for_timeout(1800); await cr.dismiss(pg) if hasattr(cr, 'dismiss') else None
                plink = await pg.locator('.rp-note a[href="privacidad.html"]', has_text='Política de privacidad').count()   # (sin contar el de la pantalla de ingreso)
                await pg.click('#gmDisconnect'); await pg.wait_for_timeout(500); await pg.click('.comms-modal [data-mok]'); await pg.wait_for_timeout(1200)
                msg = await pg.locator('#cmMsg').inner_text()
                res('PR-05 Conexión Gmail enlaza la política; al desconectar informa la revocación (en la demo, simulada)', plink == 1 and 'Google confirmó la revocación' in msg and 'SIMULADO' in msg,
                    {'enlace': plink, 'mensaje': msg[:140]}); await ctx.close()
            finally: await b.close()
    finally: srv.terminate()
    print('TOTAL', sum(1 for r in R if r[1] == 'PASS'), 'PASS /', sum(1 for r in R if r[1] == 'FAIL'), 'FAIL · esperados', EXPECTED)
    return R

if __name__ == '__main__':
    if len(sys.argv) > 1: cr.DIST = sys.argv[1]
    try: rr = asyncio.run(main())
    except Exception as e: traceback.print_exc(); print('ERROR:', repr(e)); sys.exit(2)
    if len(rr) != EXPECTED: print('ERROR: se ejecutaron %d de %d' % (len(rr), EXPECTED)); sys.exit(2)
    sys.exit(1 if any(r[1] != 'PASS' for r in rr) else 0)
