"""E2E (modo demo, Chromium) · V4.17: hojas locales SIN dueño. Solo se pueden recuperar cuando el servidor CONFIRMA (draft_content = null);
ante error o sin conexión quedan SIN VERIFICAR; al confirmar se REVALIDA. Fallos simulados interceptando drafts.list / drafts.content.
Usuario Operario SINTÉTICO. Código de salida: 0 todo PASS · 1 alguna FAIL · 2 error de preparación o casos faltantes."""
import asyncio, os, subprocess, sys, time, socket, traceback, json
from playwright.async_api import async_playwright
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
DIST = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'dist-demo'); PORT = 4378; R = []; EXPECTED = 7
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:240])); print('..', ' | '.join(R[-1]), flush=True)
HOOK = '''(()=>{ let _b; window.__qa={list:0, content:0};
  Object.defineProperty(window, 'OKD_BRIDGE', {configurable:true, get(){ return _b; }, set(v){ _b=v;
    if (v && v.drafts && !v.drafts.__qa) { const d=v.drafts, L=d.list, C=d.content;
      d.list=async(...a)=>{ window.__qa.list++; if (localStorage.getItem('qa_list_fail')==='1') throw new Error('Failed to fetch'); return L(...a); };
      d.content=async(...a)=>{ window.__qa.content++; if (localStorage.getItem('qa_content_fail')==='1') throw new Error('Failed to fetch'); return C(...a); }; d.__qa=true; } } }); })()'''
OPTS = '''()=>[...document.querySelectorAll("#tabReopen option")].map(o=>({v:o.value, t:o.textContent.trim(), dis:o.disabled, unv:o.dataset.unverified||null}))'''
STATE = '''async()=>{ const i=await DB.get("sheets_index"); const t=k=>i.tabs.find(x=>x.id===k)||{};
  return {huerfana:{owner:t('qa-huerfana').owner||null, from:t('qa-huerfana').ownerFrom||null, name:t('qa-huerfana').name, orders:(t('qa-huerfana').orders||[]).join(',')},
          ajena:{owner:t('qa-ajena').owner||null, name:t('qa-ajena').name, orders:(t('qa-ajena').orders||[]).join(',')},
          c1:((await DB.get("sheet:qa-huerfana"))||{}).marca||null, c2:((await DB.get("sheet:qa-ajena"))||{}).marca||null}}'''
async def dismiss(pg):
    for _ in range(3):
        if await pg.locator('#pushLater').count() and await pg.is_visible('#pushLater'): await pg.click('#pushLater'); await pg.wait_for_timeout(300)
        else: break
async def login(pg, email):
    await pg.goto(f'http://127.0.0.1:{PORT}/'); await pg.wait_for_load_state('networkidle'); await pg.wait_for_timeout(500)
    for _ in range(4):
        await pg.fill('#loginEmail', email); await pg.fill('#loginPass', 'demo')
        if await pg.input_value('#loginEmail') == email: break
        await pg.wait_for_timeout(300)
    await pg.click('#loginBtn'); await pg.wait_for_timeout(2500)
    if await pg.locator('#pinA').count() and await pg.is_visible('#pinA'): await pg.fill('#pinA', '123456'); await pg.fill('#pinB', '123456'); await pg.click('#pinGo'); await pg.wait_for_timeout(900)
    await pg.wait_for_timeout(1500); await dismiss(pg)
async def builder(pg):
    for _ in range(6):
        await pg.evaluate('()=>{ if (location.hash!=="#/despacho") location.hash="#/despacho"; }'); await pg.wait_for_timeout(1500); await dismiss(pg)
        if await pg.evaluate('()=>{const u=document.getElementById("usersPanel"); const o=document.getElementById("operario"); return (!u||u.hidden) && !!o && !o.hidden && !!document.getElementById("sheetTabs")}'): break
    await pg.wait_for_timeout(1200)
async def reboot(pg, list_fail, content_fail):
    await pg.evaluate(f'()=>{{ localStorage.setItem("qa_list_fail","{1 if list_fail else 0}"); localStorage.setItem("qa_content_fail","{1 if content_fail else 0}"); }}')
    await pg.reload(); await pg.wait_for_timeout(2500); await dismiss(pg); await builder(pg)
async def main():
    if not os.path.isfile(os.path.join(DIST, 'index.html')): raise RuntimeError('falta el build demo en ' + DIST)
    srv = subprocess.Popen([sys.executable, '-m', 'http.server', str(PORT), '--bind', '127.0.0.1'], cwd=DIST, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(60):
            try: socket.create_connection(('127.0.0.1', PORT), 1).close(); break
            except OSError: time.sleep(0.2)
        async with async_playwright() as p:
          b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
          try:
            ctx = await b.new_context(viewport={'width': 1366, 'height': 900}); await ctx.add_init_script(HOOK); pg = await ctx.new_page(); toasts = []
            pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
            await pg.goto(f'http://127.0.0.1:{PORT}/'); await pg.evaluate('()=>localStorage.clear()')
            await pg.evaluate('()=>new Promise(r=>{const q=indexedDB.deleteDatabase("ok_despacho"); q.onsuccess=q.onerror=q.onblocked=()=>r()})')
            await login(pg, 'admin@okdespacho.demo')
            # el Admin tiene un borrador en el servidor ('qa-ajena'); 'qa-huerfana' no tiene borrador en el servidor
            await pg.evaluate('''async()=>{const A=window.OKD_ONLINE.api;
              await A.action("create",{full_name:"Operario QA",email:"op.qa@example.invalid",role:"OPERARIO_DEPOSITO",active:true});
              const k="okd_online_demo_v2",d=JSON.parse(localStorage.getItem(k)); d.users.forEach(u=>{ if(/@example\\.invalid$/.test(u.email)) u.status="ACTIVO"; }); localStorage.setItem(k,JSON.stringify(d));
              await A.touchDraft('qa-ajena','Borrador del Admin','CRISTIAN TORRES - ESTE',1,['72001'],{rows:[]}); }''')
            await pg.evaluate('()=>window.OKD_LOGOUT && window.OKD_LOGOUT()'); await pg.wait_for_timeout(1500)
            await login(pg, 'op.qa@example.invalid'); await builder(pg)
            me = await pg.evaluate('()=>window.OKD_ME.id')
            await pg.evaluate(f'''async()=>{{ const i={{active:'qa-propia', tabs:[
                {{id:'qa-propia', name:'Hoja 1', closed:false, orders:[], owner:'{me}', nameMode:'auto'}},
                {{id:'qa-huerfana', name:'Hoja vieja sin conexión', closed:true, orders:['9001']}},
                {{id:'qa-ajena', name:'Hoja del Admin', closed:true, orders:['72001']}}]}};
              await DB.set('sheets_index', i); await DB.set('sheet:qa-propia', {{sheetId:'qa-propia', rows:[]}});
              await DB.set('sheet:qa-huerfana', {{sheetId:'qa-huerfana', rows:[], marca:'contenido-huerfana'}}); await DB.set('sheet:qa-ajena', {{sheetId:'qa-ajena', rows:[], marca:'contenido-ajena'}}); }}''')
            st0 = await pg.evaluate(STATE)
            # (1) FALLA EL LISTADO: todo SIN VERIFICAR, nada recuperable (ni siquiera llamando adopt directamente)
            await reboot(pg, True, False); o1 = await pg.evaluate(OPTS)
            await pg.evaluate('async()=>{ await SheetTabs.adopt("qa-huerfana"); }'); await pg.wait_for_timeout(500); s1 = await pg.evaluate(STATE)
            res('SD-01 falla el listado: las hojas quedan SIN VERIFICAR (deshabilitadas) y no se pueden adoptar, ni siquiera forzando adopt()',
                not any(x['v'].startswith('adopt:') for x in o1) and any(x['unv'] == 'qa-huerfana' and x['dis'] for x in o1) and s1['huerfana']['owner'] is None, {'opciones': o1, 'huerfana': s1['huerfana']})
            # (2) FALLA LA CONSULTA INDIVIDUAL: también SIN VERIFICAR
            await reboot(pg, False, True); o2 = await pg.evaluate(OPTS); s2 = await pg.evaluate(STATE)
            res('SD-02 falla la consulta individual (draft_content): SIN VERIFICAR, no recuperable', not any(x['v'].startswith('adopt:') for x in o2)
                and any(x['unv'] == 'qa-huerfana' and x['dis'] for x in o2) and s2['huerfana']['owner'] is None, o2)
            # (3) respuestas válidas: la AJENA no se ofrece; la huérfana sí
            await reboot(pg, False, False); o3 = await pg.evaluate(OPTS)
            res('SD-03 borrador AJENO (FORBIDDEN_DRAFT): no se ofrece ni se asigna', not any('qa-ajena' in (x['v'] + str(x['unv'])) for x in o3), o3)
            res('SD-04 hoja sin borrador en el servidor (draft_content = null): habilitada para recuperar', any(x['v'] == 'adopt:qa-huerfana' and not x['dis'] for x in o3), o3)
            # (4) al CONFIRMAR se revalida: si en ese momento falla la consulta, no se adopta
            await pg.evaluate('()=>localStorage.setItem("qa_content_fail","1")'); q0 = await pg.evaluate('()=>({...window.__qa})')
            await pg.select_option('#tabReopen', value='adopt:qa-huerfana'); await pg.wait_for_timeout(1200)
            q1 = await pg.evaluate('()=>({...window.__qa})'); s4 = await pg.evaluate(STATE)
            res('SD-05 al confirmar se REVALIDA con el servidor; si falla, la hoja queda sin cambios y sin dueño', q1['list'] > q0['list'] and q1['content'] > q0['content'] and s4['huerfana']['owner'] is None, {'llamadas_antes': q0, 'despues': q1, 'huerfana': s4['huerfana']})
            # (5) recuperación VÁLIDA (revalidada)
            await reboot(pg, False, False); q2 = await pg.evaluate('()=>({...window.__qa})')
            await pg.select_option('#tabReopen', value='adopt:qa-huerfana'); await pg.wait_for_timeout(1500)
            q3 = await pg.evaluate('()=>({...window.__qa})'); s5 = await pg.evaluate(STATE)
            res('SD-06 recuperación válida: revalidada al confirmar, la hoja pasa a ser propia con su contenido', q3['content'] > q2['content'] and s5['huerfana']['owner'] == me and s5['huerfana']['from'] == 'recuperada'
                and s5['c1'] == 'contenido-huerfana', s5['huerfana'])
            res('SD-07 borradores intactos en todo el recorrido (nombres, pedidos, contenido; la ajena nunca cambia de dueño)', s5['ajena'] == st0['ajena'] and s5['ajena']['owner'] is None
                and s5['huerfana']['name'] == st0['huerfana']['name'] and s5['huerfana']['orders'] == st0['huerfana']['orders'] and s5['c2'] == 'contenido-ajena', {'antes': st0, 'despues': s5})
          finally: await b.close()
    finally:
        if srv.poll() is None: srv.terminate(); srv.wait(5)
    print('TOTAL', sum(1 for r in R if r[1] == 'PASS'), 'PASS /', sum(1 for r in R if r[1] == 'FAIL'), 'FAIL · esperados', EXPECTED)
    return R
if __name__ == '__main__':
    try: rr = asyncio.run(main())
    except Exception as e: traceback.print_exc(); print('ERROR:', repr(e)); sys.exit(2)
    if len(rr) != EXPECTED: print('ERROR: se ejecutaron %d de %d' % (len(rr), EXPECTED)); sys.exit(2)
    sys.exit(1 if any(r[1] != 'PASS' for r in rr) else 0)
