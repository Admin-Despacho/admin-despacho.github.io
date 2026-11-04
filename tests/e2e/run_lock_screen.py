"""E2E (modo demo, Chromium) · V4.24 · Fondo nuevo SOLO para SESIÓN BLOQUEADA (notebook y Android); CONFIGURÁ TU PIN, el INICIO DE SESIÓN y la
RECUPERACIÓN DE CONTRASEÑA quedan idénticos a la versión publicada (comparación píxel a píxel).
Uso: python3 tests/e2e/run_lock_screen.py <dist-nuevo> <dist-publicado> [capturas]   ·   Exit 0 todo PASS · 1 alguna FAIL · 2 error."""
import asyncio, os, sys, subprocess, time, traceback
sys.path.insert(0, os.path.dirname(__file__))
import run_driver_perfiles as dp
dp.PORT = 4403   # el ingreso estándar navega al build NUEVO
from playwright.async_api import async_playwright
from PIL import Image, ImageChops
NEW, OLD = sys.argv[1], sys.argv[2]; SHOTS = sys.argv[3] if len(sys.argv) > 3 else '/tmp/okd_lock_shots'; R = []; EXPECTED = 5
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:240])); print('..', ' | '.join(R[-1]), flush=True)
def serve(d, port): p = subprocess.Popen([sys.executable, '-m', 'http.server', str(port), '--bind', '127.0.0.1'], cwd=d, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); time.sleep(1.2); return p
LOCK = '''()=>{const g=document.getElementById("pinGate"); if(!g) return null; return {title:(g.querySelector("header b")||{}).textContent, cls:g.className,
  bg:!!g.querySelector(".pin-lock-bg svg"), logo:(g.querySelector(".pin-lock-brand img")||{}).naturalWidth||0, brand:(g.querySelector(".pin-lock-brand span")||{}).textContent||"",
  pin:!!g.querySelector("#pinA"), pw:(g.querySelector("#pinPassword")||{}).textContent, go:(g.querySelector("#pinGo")||{}).textContent,
  fuera:[...g.querySelectorAll("button,#pinA")].filter(b=>{const r=b.getBoundingClientRect(); return r.right>innerWidth||r.left<0||r.bottom>innerHeight;}).length}}'''
async def login_and_lock(b, port, vp, mobile=False):
    ctx = await b.new_context(viewport=vp, is_mobile=mobile, device_scale_factor=2.625 if mobile else 1); pg = await ctx.new_page()
    await pg.goto(f'http://127.0.0.1:{port}/'); await pg.evaluate('()=>{localStorage.clear(); sessionStorage.clear();}'); await pg.reload(); await pg.wait_for_timeout(1500)
    await dp.login(pg, 'admin@okdespacho.demo')
    uid = await pg.evaluate('async()=>(await window.OKD_ONLINE.api.me()).id')
    # PIN configurado + última actividad vencida (más de 4 h, política del Administrador) → al volver, SESIÓN BLOQUEADA (como un usuario real)
    await pg.evaluate('''(uid)=>{localStorage.setItem("okd_pin_v1_"+uid+"_cfg", JSON.stringify({salt:"00", v:"x"})); localStorage.setItem("okd_pin_v1_"+uid+"_last", JSON.stringify({at:0, day:"2000-01-01"})); sessionStorage.removeItem("okd_fresh_login");}''', uid)
    await pg.reload(); await pg.wait_for_selector('#pinGate', timeout=15000); await pg.wait_for_timeout(1200)
    return ctx, pg, uid
async def shot_login(b, port, path, hash_=''):
    ctx = await b.new_context(viewport={'width': 1366, 'height': 900}); pg = await ctx.new_page()
    await pg.goto(f'http://127.0.0.1:{port}/' + hash_); await pg.evaluate('()=>{localStorage.clear(); sessionStorage.clear();}'); await pg.reload(); await pg.wait_for_timeout(2500)
    await pg.add_style_tag(content='*{caret-color:transparent!important;animation:none!important;transition:none!important}'); await pg.wait_for_timeout(300)
    await pg.screenshot(path=path); await ctx.close()
def same(a, b):
    A, B = Image.open(a).convert('RGB'), Image.open(b).convert('RGB')
    if A.size != B.size: return False, 'tamaños distintos'
    bbox = ImageChops.difference(A, B).getbbox(); return bbox is None, bbox

async def main():
    os.makedirs(SHOTS, exist_ok=True); s1, s2 = serve(NEW, 4403), serve(OLD, 4404)
    try:
        async with async_playwright() as p:
            b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
            try:
                ctx, pg, uid = await login_and_lock(b, 4403, {'width': 1366, 'height': 900}); k = await pg.evaluate(LOCK)
                await pg.screenshot(path=os.path.join(SHOTS, 'sesion_bloqueada_notebook.png'))
                res('LK-01 NOTEBOOK: SESIÓN BLOQUEADA con el fondo de logística (rutas, ubicaciones, logo oficial en negro, DESPACHO ONLINE); PIN y botones intactos y visibles',
                    k and k['title'] == 'SESIÓN BLOQUEADA' and 'pin-lock' in k['cls'] and k['bg'] and k['logo'] > 0 and k['brand'] == 'DESPACHO ONLINE' and k['pin']
                    and k['pw'] == 'INGRESAR CON CONTRASEÑA' and k['go'] == 'CONTINUAR' and k['fuera'] == 0, k)
                # CONFIGURÁ TU PIN (sin PIN guardado): sin el fondo nuevo
                await pg.evaluate('(uid)=>{localStorage.removeItem("okd_pin_v1_"+uid+"_cfg"); localStorage.removeItem("okd_pin_v1_"+uid+"_last");}', uid)
                await pg.reload(); await pg.wait_for_selector('#pinGate', timeout=15000); await pg.wait_for_timeout(800); c = await pg.evaluate(LOCK)
                res('LK-03 "CONFIGURÁ TU PIN" queda como estaba (sin el fondo nuevo)', c and c['title'] == 'CONFIGURÁ TU PIN' and 'pin-lock' not in c['cls'] and not c['bg'], c and {'titulo': c['title'], 'clase': c['cls']})
                await ctx.close()
                ctx, pg, uid = await login_and_lock(b, 4403, {'width': 412, 'height': 915}, mobile=True); k = await pg.evaluate(LOCK)
                over = await pg.evaluate('()=>document.documentElement.scrollWidth-document.documentElement.clientWidth')
                await pg.screenshot(path=os.path.join(SHOTS, 'sesion_bloqueada_android.png'))
                res('LK-02 ANDROID: SESIÓN BLOQUEADA con el fondo nuevo; PIN y botones dentro de la pantalla, sin desplazamiento lateral',
                    k and 'pin-lock' in k['cls'] and k['logo'] > 0 and k['fuera'] == 0 and over <= 0, {'fuera': k and k['fuera'], 'desborde': over})
                await ctx.close()
                # inicio de sesión y recuperación de contraseña: idénticos a la versión publicada
                a1, a2 = os.path.join(SHOTS, 'login_v424.png'), os.path.join(SHOTS, 'login_99ffd09.png')
                await shot_login(b, 4403, a1); await shot_login(b, 4404, a2); eq, bb = same(a1, a2)
                res('LK-04 INICIO DE SESIÓN idéntico píxel a píxel a la versión publicada (99ffd09)', eq, bb)
                r1, r2 = os.path.join(SHOTS, 'recuperar_v424.png'), os.path.join(SHOTS, 'recuperar_99ffd09.png')
                for port, path in ((4403, r1), (4404, r2)):
                    c2 = await b.new_context(viewport={'width': 1366, 'height': 900}); q = await c2.new_page(); await q.goto(f'http://127.0.0.1:{port}/'); await q.evaluate('()=>{localStorage.clear(); sessionStorage.clear();}')
                    await q.reload(); await q.wait_for_timeout(2000); lk = q.locator('a,button', has_text='Olvid')
                    if await lk.count(): await lk.first.click(); await q.wait_for_timeout(1200)
                    await q.add_style_tag(content='*{caret-color:transparent!important;animation:none!important;transition:none!important}'); await q.wait_for_timeout(300); await q.screenshot(path=path); await c2.close()
                eq2, bb2 = same(r1, r2)
                res('LK-05 RECUPERACIÓN DE CONTRASEÑA idéntica píxel a píxel a la versión publicada', eq2, bb2)
            finally: await b.close()
    finally: s1.terminate(); s2.terminate()
    print('TOTAL', sum(1 for r in R if r[1] == 'PASS'), 'PASS /', sum(1 for r in R if r[1] == 'FAIL'), 'FAIL · esperados', EXPECTED)
    return R

if __name__ == '__main__':
    try: rr = asyncio.run(main())
    except Exception as e: traceback.print_exc(); print('ERROR:', repr(e)); sys.exit(2)
    if len(rr) != EXPECTED: print('ERROR: se ejecutaron %d de %d' % (len(rr), EXPECTED)); sys.exit(2)
    sys.exit(1 if any(r[1] != 'PASS' for r in rr) else 0)
