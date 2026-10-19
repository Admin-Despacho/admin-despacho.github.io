"""QA visual de la pantalla de acceso (CHECKPOINT 36): notebook (incl. 799/800 px y zoom 125/150 %) y Android (incl. teclado abierto,
PWA y apaisado), en Chromium con viewports EMULADOS (no reemplaza un teléfono real). Usa el build de producción (modo online) con
Supabase bloqueado. Verifica: sin scroll horizontal, tarjeta dentro de la pantalla con margen, nada debajo de la imagen, imagen entera
(object-fit contain sin recorte del contenedor), botón alcanzable y formulario de recuperación. Capturas en tests/e2e/out/login/.
Uso: python3 tests/e2e/run_login_visual.py [dist]"""
import asyncio, subprocess, time, json, sys, os
from playwright.async_api import async_playwright
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
DIST = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'dist'); OUT = os.path.join(ROOT, 'tests', 'e2e', 'out', 'login'); os.makedirs(OUT, exist_ok=True)
PROBE = """()=>{const W=document.documentElement.clientWidth,H=innerHeight,card=document.querySelector('#authCard'),vis=document.querySelector('.login-visual'),
  img=[...document.querySelectorAll('.login-visual img')].find(i=>getComputedStyle(i).display!=='none'), r=e=>e?e.getBoundingClientRect():null;
  const cr=r(card), vr=vis&&getComputedStyle(vis).display!=='none'?r(vis):null;
  const ctrls=[...card.querySelectorAll('.login-brand strong,.login-brand span,.login-brand img,input,button,label,.auth-err,.forgot')].filter(e=>e.offsetParent);
  const underImg=vr?ctrls.filter(e=>{const a=r(e);return a.right>vr.left+1&&a.left<vr.right-1&&a.bottom>vr.top+1&&a.top<vr.bottom-1;}).map(e=>e.id||e.tagName+':'+(e.textContent||'').trim().slice(0,14)):[];
  const textOverflow=ctrls.filter(e=>e.scrollWidth>e.clientWidth+1&&getComputedStyle(e).overflow!=='visible').map(e=>e.id||e.tagName);
  const brandW=(()=>{const s=card.querySelector('.login-brand strong');return s?Math.round(r(s).right):null;})();
  let imgInfo=null; if(img){const b=r(img), ar=img.naturalWidth/img.naturalHeight, boxAr=b.width/b.height; const shownW=boxAr>ar?b.height*ar:b.width, shownH=boxAr>ar?b.height:b.width/ar;
    imgInfo={box:[Math.round(b.width),Math.round(b.height)],shown:[Math.round(shownW),Math.round(shownH)],fit:getComputedStyle(img).objectFit,clippedByParent:!!(vr&&(b.right>vr.right+1||b.bottom>vr.bottom+1||b.left<vr.left-1||b.top<vr.top-1))};}
  const offscreenX=ctrls.filter(e=>{const a=r(e);return a.right>W+1||a.left<-1;}).map(e=>e.id||e.tagName);
  const btn=r(document.getElementById('loginBtn'));
  return {W,H,hOverflow:document.documentElement.scrollWidth-W,card:cr&&[Math.round(cr.left),Math.round(cr.right),Math.round(cr.top),Math.round(cr.bottom)],cardOffscreen:cr&&(cr.left<0||cr.right>W),
    visual:vr&&[Math.round(vr.left),Math.round(vr.right)],underImg,textOverflow,offscreenX,img:imgInfo,brandRight:brandW,btnBottom:btn&&Math.round(btn.bottom),pageH:document.documentElement.scrollHeight,
    bodyOverflowY:getComputedStyle(document.body).overflowY,htmlOverflowY:getComputedStyle(document.documentElement).overflowY};}"""
CASES = [('nb_1366x768',1366,768,1,False),('nb_1366x768_z125',1093,614,1.25,False),('nb_1366x768_z150',911,512,1.5,False),('nb_1280x720',1280,720,1,False),
  ('nb_1280x720_z125',1024,576,1.25,False),('nb_1280x720_z150',853,480,1.5,False),('nb_1920x1080_z150',1280,720,1.5,False),('nb_800x700',800,700,1,False),('nb_799x700',799,700,1,False),
  ('nb_820x600',820,600,1,False),('nb_900x600',900,600,1,False),('nb_1024x600',1024,600,1,False),
  ('and_360x800',360,800,2.75,True),('and_393x851',393,851,2.75,True),('and_412x915',412,915,2.6,True),('and_360x640',360,640,3,True),
  ('and_393x851_teclado',393,430,2.75,True),('and_360x800_teclado',360,420,3,True),('and_pwa_393x780',393,780,2.75,True),('and_landscape_851x393',851,393,2.75,True)]
async def main():
    if not os.path.isfile(os.path.join(DIST, 'index.html')): raise RuntimeError('no existe el build en ' + DIST + ' (correr npm run build)')
    srv = subprocess.Popen([sys.executable,'-m','http.server','4321','--bind','127.0.0.1'], cwd=DIST, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    out={}; b=None
    try:
        _wait_port(4321, srv)
        async with async_playwright() as p:
          b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
          try:
            for name,w,h,dpr,mob in CASES:
                pg = await b.new_page(viewport={'width':w,'height':h}, device_scale_factor=dpr, is_mobile=mob, has_touch=mob)
                await pg.route('**/*.supabase.co/**', lambda r: r.abort())
                await pg.goto('http://127.0.0.1:4321/'); await pg.wait_for_selector('#loginForm', timeout=15000); await pg.wait_for_load_state('networkidle'); await pg.wait_for_timeout(800)
                await pg.evaluate("()=>Promise.all([...document.images].map(i=>i.decode().catch(()=>null)))")
                if 'teclado' in name: await pg.focus('#loginPass')
                if name == 'and_360x800':   # el formulario de recuperación también entra en pantalla (reintenta si la pantalla se volvió a dibujar)
                    for _ in range(5):
                        await pg.click('#forgotOpen')
                        try: await pg.wait_for_selector('#forgotForm', state='visible', timeout=1500); break
                        except Exception: await pg.wait_for_timeout(300)
                    await pg.wait_for_timeout(300)
                out[name]=await pg.evaluate(PROBE); await pg.screenshot(path=os.path.join(OUT,name+'.png'), full_page=True); await pg.close()
          finally: await b.close()
    finally: _stop(srv)
    R=[]
    for k,v in out.items():
        bad=[]
        if v['hOverflow']>0: bad.append('scroll horizontal %dpx' % v['hOverflow'])
        if v['card'][0] < 8 or v['card'][1] > v['W'] - 8: bad.append('tarjeta pegada/cortada en el borde ' + str(v['card'][:2]))
        if v['underImg']: bad.append('debajo de la imagen: ' + ','.join(v['underImg']))
        if v['textOverflow']: bad.append('texto cortado: ' + ','.join(v['textOverflow']))
        if v['offscreenX']: bad.append('fuera de pantalla: ' + ','.join(v['offscreenX']))
        if not v['img'] or v['img']['clippedByParent'] or v['img']['fit'] != 'contain': bad.append('imagen recortada por el contenedor')
        if v['bodyOverflowY'] == 'hidden' or v['htmlOverflowY'] == 'hidden': bad.append('sin scroll vertical')
        R.append((k, not bad, '; '.join(bad)))
    R.append(('teclado', all(out[k]['btnBottom'] <= out[k]['pageH'] for k in out if 'teclado' in k), 'con teclado abierto se puede llegar al botón (scroll vertical)'))
    for k, ok, d in R: print('LOGIN-VIS', k, '|', 'PASS' if ok else 'FAIL', '|', d)
    print('TOTAL', sum(1 for r in R if r[1]), 'PASS /', sum(1 for r in R if not r[1]), 'FAIL')
    return [(k, d, 'PASS' if ok else 'FAIL') for k, ok, d in R]


def _wait_port(port, srv, timeout=15):
    import socket
    t0 = time.time()
    while time.time() - t0 < timeout:
        if srv.poll() is not None: raise RuntimeError('el servidor estático terminó al arrancar (código %s)' % srv.returncode)
        try: socket.create_connection(('127.0.0.1', port), 1).close(); return
        except OSError: time.sleep(0.2)
    raise RuntimeError('el servidor estático no respondió en el puerto %d' % port)

def _stop(srv):
    if srv and srv.poll() is None:
        srv.terminate()
        try: srv.wait(5)
        except Exception: srv.kill()

def _exit_with(main, expected):
    """0 = todos los casos esperados ejecutados y en PASS · 1 = alguna comprobación FAIL · 2 = excepción / preparación / casos faltantes."""
    import traceback
    try:
        results = asyncio.run(main())
    except Exception as e:
        traceback.print_exc(); print('ERROR: la prueba no pudo completarse:', repr(e)); sys.exit(2)
    ran = len(results); fails = [r for r in results if r[2] != 'PASS']
    if ran < expected:
        print('ERROR: se ejecutaron %d de %d comprobaciones esperadas' % (ran, expected)); sys.exit(2)
    sys.exit(1 if fails else 0)

if __name__ == '__main__':
    _exit_with(main, expected=len(CASES) + 1)
