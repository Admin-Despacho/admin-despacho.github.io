"""Relevamiento REAL de diseño (modo demo, Chromium): por pantalla y resolución mide desplazamiento horizontal de la página, controles fuera de
pantalla, tablas con desplazamiento interno y qué queda visible (cabecera, pestañas, buscador, filtros) DESPUÉS de bajar por el listado.
Uso: python3 relevamiento_layout.py [dist-demo] [salida.json]"""
import asyncio, os, sys, json
sys.path.insert(0, os.path.dirname(__file__))
import run_driver_perfiles as dp
from playwright.async_api import async_playwright
dp.PORT = 4470
if len(sys.argv) > 1: dp.DIST = sys.argv[1]
OUT = sys.argv[2] if len(sys.argv) > 2 else '/tmp/relevamiento.json'
VPS = [('1366x768', 1366, 768, False), ('1280x720', 1280, 720, False), ('1024x768', 1024, 768, False), ('412x915', 412, 915, True), ('360x800', 360, 800, True)]
SCREENS = ['#/historial', '#/historial:detalle', '#/historial:buscar', '#/borradores', '#/recorridos', '#/solicitudes', '#/aprobaciones', '#/informes', '#/vehiculos', '#/auditoria', '#/usuarios', '#/inspecciones', '#/comunicaciones', '#/configuracion']
SEED = '''async()=>{const A=window.OKD_ONLINE.api; const st=(o,n)=>({ready:true, client_name:n, client_key:n.toUpperCase(), address:'Calle '+o+' · Godoy Cruz, Mendoza', zone:'ESTE', stop_type:'PEDIDO', order_numbers:[String(o)], merchandise_amount:1000, shipping_fee:0, task:'ENTREGA', expected_amount:1000});
  for(let i=0;i<40;i++){ try{ await A.publishRoute({sheet_key:'qa-lay-'+i+'-'+Date.now(), carrier_id:'CT-ESTE', responsable_id:'u-cristian', rules_version:1, routing_rules_version:1, stops:[st(70000+i*2,'Cliente de prueba con nombre largo '+i), st(70001+i*2,'Otro cliente '+i)]}); }catch(e){} } return true;}'''
MEASURE = '''()=>{const vw=document.documentElement.clientWidth, inScroll=el=>{for(let p=el.parentElement;p;p=p.parentElement){const o=getComputedStyle(p).overflowX; if(o==="auto"||o==="scroll") return p;} return null;};
  const vis=e=>{const r=e.getBoundingClientRect(), s=getComputedStyle(e); return r.width>0&&r.height>0&&s.visibility!=="hidden"&&s.display!=="none";};
  const ctl=[...document.querySelectorAll("button,input,select,textarea,a.btn")].filter(vis);
  const fuera=ctl.filter(e=>{const r=e.getBoundingClientRect(); return !inScroll(e)&&(r.right>vw+1||r.left<-1);}).map(e=>(e.textContent||e.placeholder||e.name||e.id||e.tagName).trim().slice(0,30));
  const scr=[...document.querySelectorAll("*")].filter(e=>{const s=getComputedStyle(e); return (s.overflowX==="auto"||s.overflowX==="scroll")&&e.scrollWidth>e.clientWidth+2&&vis(e)&&e.clientWidth>100;}).map(e=>({cls:(e.className||e.tagName).toString().slice(0,40), sw:e.scrollWidth, cw:e.clientWidth}));
  return {page_over:document.documentElement.scrollWidth-vw, fuera, internos:scr};}'''
VISIBLE = '''()=>{const inView=sel=>{const e=document.querySelector(sel); if(!e) return null; const r=e.getBoundingClientRect(); return r.bottom>0&&r.top<innerHeight&&r.height>0;};
  return {topbar:inView(".topbar")||inView(".rc4side .rc4brand")||inView("header.top"), tabs:inView("#hTabs")||inView(".v3-tabs")||inView(".htabs"), buscador:inView("#hList input[type=search], #hFold input, #ufSearch, #bsQ, .hfilters input, [data-filter] input, input[type=search]"), filtros:inView("#hFold")||inView(".v3-filters")||inView(".hfilters"), scrollY:Math.round(scrollY)}}'''
async def go(pg, scr):
    base = scr.split(':')[0]; await pg.evaluate(f'()=>{{location.hash="{base}"}}'); await pg.wait_for_timeout(1300)
    if scr.endswith(':detalle'):
        b = pg.locator('#hList [data-view]').first
        if await b.count(): await b.click(); await pg.wait_for_timeout(1300)
    if scr.endswith(':buscar'):
        await pg.click('[data-htab="search"]'); await pg.fill('#bsQ', '7000'); await pg.press('#bsQ', 'Enter'); await pg.wait_for_timeout(900)
async def main():
    srv = dp.serve(); rep = {}
    try:
        async with async_playwright() as p:
            b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
            seeded = None
            for tag, w, h, mob in VPS:
                ctx = await b.new_context(viewport={'width': w, 'height': h}, is_mobile=mob, has_touch=mob, device_scale_factor=2 if mob else 1, storage_state=seeded)
                pg = await ctx.new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept())); await pg.goto(f'http://127.0.0.1:{dp.PORT}/')
                if seeded is None: await pg.evaluate('()=>localStorage.clear()'); await dp.login(pg, 'admin@okdespacho.demo'); await pg.evaluate(SEED); seeded = await ctx.storage_state()
                else: await dp.login(pg, 'admin@okdespacho.demo')
                for scr in SCREENS:
                    try:
                        await go(pg, scr); m = await pg.evaluate(MEASURE); await pg.evaluate('()=>window.scrollTo(0,1500)'); await pg.wait_for_timeout(350); v = await pg.evaluate(VISIBLE); await pg.evaluate('()=>window.scrollTo(0,0)')
                        rep.setdefault(scr, {})[tag] = {**m, 'tras_bajar': v}
                    except Exception as e: rep.setdefault(scr, {})[tag] = {'error': str(e)[:120]}
                await ctx.close()
            await b.close()
    finally: srv.terminate()
    json.dump(rep, open(OUT, 'w'), ensure_ascii=False, indent=1)
    for scr, d in rep.items():
        print(scr); [print('  ', t, 'pág+%s' % v.get('page_over'), 'fuera:', len(v.get('fuera', [])), 'internos:', [(x['cls'][:22], x['sw'], x['cw']) for x in v.get('internos', [])][:2], 'tras bajar:', {k: x for k, x in v.get('tras_bajar', {}).items() if k != 'scrollY'}, v.get('error', '')) for t, v in d.items()]
if __name__ == '__main__':
    asyncio.run(main())
