"""E2E BLOQUEANTE (modo demo, Chromium) · V4.27 · REVISAR HOJA temporal · sin desplazamiento horizontal · cabecera/buscador/filtros fijos.
Datos FICTICIOS (40 hojas; una EN CURSO y otra FINALIZADA). Desplazamiento e interacción REALES. Uso: python3 run_v427_navegacion.py [dist-demo] [salida]"""
import asyncio, os, sys, json, hashlib, traceback
sys.path.insert(0, os.path.dirname(__file__))
import run_driver_perfiles as dp
from playwright.async_api import async_playwright
dp.PORT = 4475; R = []
if len(sys.argv) > 1: dp.DIST = sys.argv[1]
OUT = sys.argv[2] if len(sys.argv) > 2 else '/tmp/okd_v427'
VPS = [('1366x768', 1366, 768, False), ('1280x720', 1280, 720, False), ('1024x768', 1024, 768, False), ('412x915', 412, 915, True), ('360x800', 360, 800, True)]
EXPECTED = 7 + len(VPS) * 3 + 1
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:320])); print('..', ' | '.join(R[-1]), flush=True)
SEED = '''async()=>{const A=window.OKD_ONLINE.api, k="okd_online_demo_v2"; const st=(o,n)=>({ready:true, client_name:n, client_key:n.toUpperCase(), address:'Calle '+o+' · Godoy Cruz, Mendoza', zone:'ESTE', stop_type:'PEDIDO', order_numbers:[String(o)], merchandise_amount:1000, shipping_fee:0, task:'ENTREGA', expected_amount:1000});
  for(let i=0;i<40;i++){ await A.publishRoute({sheet_key:'qa-v427-'+i+'-'+Date.now(), carrier_id:'CT-ESTE', responsable_id:'u-cristian', rules_version:1, routing_rules_version:1, stops:[st(81000+i*2,'Cliente de prueba con nombre largo '+i), st(81001+i*2,'Otro cliente '+i)]}); }
  const d=JSON.parse(localStorage.getItem(k)); const rs=d.routes2.filter(r=>/qa-v427/.test(r.sheet_key||'')||true).slice(-40);
  rs[0].operational_status='EN_CURSO'; rs[0].started_at=new Date(Date.now()-3600e3).toISOString();
  rs[1].operational_status='COMPLETADA'; rs[1].started_at=new Date(Date.now()-7200e3).toISOString(); rs[1].completed_at=new Date().toISOString(); rs[1].stops.forEach(s=>s.outcome='ENTREGADO');
  localStorage.setItem(k, JSON.stringify(d)); return {encurso:rs[0].number, fin:rs[1].number, otra:rs[5].number, orden_otra:rs[5].stops[0].order_numbers[0]};}'''
SNAP = '()=>{const d=JSON.parse(localStorage.getItem("okd_online_demo_v2")); return JSON.stringify((d.routes2||[]).map(r=>[r.id,r.number,r.operational_status,r.started_at||null,r.completed_at||null,r.version||null,(r.stops||[]).map(s=>[s.id,s.outcome])]))}'
TAB = '()=>{const o=document.querySelector(".vh-ovl"), v=!!o&&!o.hidden; return {visible:v, texto:v?document.getElementById("vhTitle").textContent:"", cerrar:v&&!!document.getElementById("vhClose"), detalle_vacio:!(document.querySelector("#vhSum")||{}).innerHTML, lista:!document.querySelector("#hList").hidden, busqueda:!document.querySelector("#hSearch").hidden, pestanas_revision:document.querySelectorAll(".vh-ovl:not([hidden])").length+document.querySelectorAll("[data-htab=\\"detail\\"]:not([hidden])").length}}'   # V4.28: VER HOJA es una VENTANA
SCREENS = ['#/historial', '#/historial:revisar', '#/historial:buscar', '#/recorridos', '#/auditoria', '#/configuracion', '#/usuarios']
MEASURE = '''(mob)=>{const vw=document.documentElement.clientWidth, sc=el=>{for(let p=el.parentElement;p;p=p.parentElement){const o=getComputedStyle(p).overflowX; if(o==="auto"||o==="scroll") return p;} return null;};
  const vis=e=>{const r=e.getBoundingClientRect(), s=getComputedStyle(e); return r.width>0&&r.height>0&&s.visibility!=="hidden"&&s.display!=="none";};
  const fuera=[...document.querySelectorAll("button,input,select,textarea")].filter(vis).filter(e=>{const r=e.getBoundingClientRect(); return !sc(e)&&(r.right>vw+1||r.left<-1);}).map(e=>(e.textContent||e.placeholder||e.id).trim().slice(0,24));
  const internos=[...document.querySelectorAll(".utable-wrap,.tscroll")].filter(e=>vis(e)&&e.scrollWidth>e.clientWidth+2).map(w=>{const t=w.querySelector("table"); const wr=w.getBoundingClientRect();
     const acc=[...w.querySelectorAll("td:last-child button")].slice(0,3).map(b=>{const r=b.getBoundingClientRect(); return r.right<=wr.right+1&&r.left>=wr.left-1;});
     const fila=w.querySelector("tbody tr"); let primera_libre=true, ancho_fijo=0;
     if(fila&&fila.cells.length>1){const c0=fila.cells[0].getBoundingClientRect(), last=fila.cells[fila.cells.length-1]; if(getComputedStyle(last).position==="sticky"){const l=last.getBoundingClientRect(); ancho_fijo=Math.round(l.width); primera_libre=l.left>=c0.right-1;}}
     return {tabla:t?String(t.className):"", analisis:!!(t&&t.classList.contains("rp-table")), acciones_visibles:acc.every(Boolean), con_acciones:acc.length>0, primera_columna_libre:primera_libre, ancho_columna_fija:ancho_fijo};});
  return {pagina:document.documentElement.scrollWidth-vw, fuera, internos};}'''
SCROLLER = '()=>{const u=document.getElementById("usersPanel"); return (u&&u.scrollHeight>u.clientHeight)?u.scrollTop:Math.round(scrollY)}'
STICKY = '''(mob)=>{const q=s=>document.querySelector(s), R=e=>e&&e.getBoundingClientRect(); const up=document.getElementById("usersPanel"); const sy=(up&&up.scrollHeight>up.clientHeight)?up.scrollTop:scrollY; const hdr=parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--okd-hdr"))||0;
  const head=mob?q("#usersPanel .rc4side")||q(".rc4side"):q("#usersPanel .rc4main .topbar")||q(".rc4main .topbar"), hs=q(".hstick"), hr=R(hs), hd=R(head);
  const below=hr?document.elementFromPoint(Math.round(innerWidth/2), Math.round(hr.bottom+10)):null;
  return {scrollY:Math.round(sy), cabecera_visible:!!hd&&hd.top>=-1&&hd.bottom>0, bloque_top:hr&&Math.round(hr.top), hdr:Math.round(hdr), bloque_pegado:!!hr&&Math.abs(hr.top-hdr)<=2,
    buscador_visible:(()=>{const e=mob&&!q("#hFold").open?q("#hFold>summary"):q("#hfOrder"); const r=R(e); return !!r&&r.height>0&&r.top>=hr.top-1&&r.bottom<=hr.bottom+1;})(), pestanas_visibles:(()=>{const r=R(q("#hTabs")); return !!r&&r.top>=0&&r.bottom<=innerHeight;})(),
    debajo_es_lista:!!below&&!!below.closest("#hList"), debajo:below&&(below.tagName+"."+String(below.className).slice(0,16))}}'''
async def go(pg, scr):
    if await pg.locator('.vh-ovl:not([hidden]) #vhClose').count(): await pg.click('.vh-ovl:not([hidden]) #vhClose'); await pg.wait_for_timeout(300)   # V4.28: como una persona, cierra VER HOJA antes de navegar
    await pg.evaluate(f'()=>{{location.hash="{scr.split(":")[0]}"}}'); await pg.wait_for_timeout(1300)
    if scr.endswith(':revisar'): await pg.locator('#hList [data-view]').first.click(); await pg.wait_for_timeout(1300)
    if scr.endswith(':buscar'): await pg.click('[data-htab="search"]'); await pg.fill('#bsQ', '81001'); await pg.press('#bsQ', 'Enter'); await pg.wait_for_timeout(900)
async def main():
    os.makedirs(OUT, exist_ok=True); srv = dp.serve()
    try:
        async with async_playwright() as p:
            b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
            try:
                ctx = await b.new_context(viewport={'width': 1366, 'height': 768}); pg = await ctx.new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
                await pg.goto(f'http://127.0.0.1:{dp.PORT}/'); await pg.evaluate('()=>localStorage.clear()'); await dp.login(pg, 'admin@okdespacho.demo'); ids = await pg.evaluate(SEED)
                snap0 = await pg.evaluate(SNAP)
                # ---------- NAVEGACIÓN ----------
                await go(pg, '#/historial'); first = await pg.evaluate('()=>document.querySelector("#hList tr[data-rid] td").textContent.trim()')
                await pg.locator('#hList [data-view]').first.click(); await pg.wait_for_timeout(1400); t1 = await pg.evaluate(TAB)
                await pg.screenshot(path=os.path.join(OUT, 'revisar_hoja_1366.png'))
                res('N-01 VER HOJA abre UNA ventana «VER HOJA <número real>» con CERRAR; el listado sigue detrás (V4.28)', t1['visible'] and t1['texto'] == 'VER HOJA ' + first and t1['cerrar'] and t1['pestanas_revision'] == 1 and t1['lista'], t1)
                await pg.click('#vhClose'); await pg.wait_for_timeout(500); t2 = await pg.evaluate(TAB)
                res('N-02 CERRAR cierra la ventana (sin pestaña, sin contenido) y deja el listado', not t2['visible'] and t2['texto'] == '' and t2['detalle_vacio'] and t2['lista'] and not t2['cerrar'], t2)
                await pg.locator('#hList [data-view]').first.click(); await pg.wait_for_timeout(1200); await pg.click('#vhClose'); await pg.wait_for_timeout(400)
                await pg.click('[data-htab="search"]'); await pg.wait_for_timeout(300); t3a = await pg.evaluate(TAB)
                await pg.fill('#bsQ', ids['orden_otra']); await pg.press('#bsQ', 'Enter'); await pg.wait_for_timeout(900); found = await pg.locator('#bsRes .bs-res').count()
                await pg.click('#bsRes [data-bs-view]'); await pg.wait_for_timeout(1500); t3 = await pg.evaluate(TAB)
                res('N-03 UNA sola ventana: tras cerrar, abrir OTRA hoja (desde BUSCAR ENTREGA) muestra SOLO la nueva',
                    not t3a['visible'] and t3['visible'] and t3['texto'] == 'VER HOJA ' + ids['otra'] and t3['pestanas_revision'] == 1, {'al_ir_a_buscar': t3a['visible'], 'ahora': t3['texto']})
                await pg.click('#vhClose'); await pg.wait_for_timeout(500); t4 = await pg.evaluate(TAB); kept = await pg.locator('#bsRes .bs-res').count()
                res('N-04 CERRAR la ventana VUELVE al contexto de origen (BUSCAR ENTREGA, con los resultados intactos)', not t4['visible'] and t4['busqueda'] and kept == found == 1, {'origen_busqueda': t4['busqueda'], 'resultados': kept})
                await pg.click('[data-htab="list"]'); await pg.locator('#hList [data-view]').nth(2).click(); await pg.wait_for_timeout(1200)
                await pg.evaluate('()=>{location.hash="#/usuarios"}'); await pg.wait_for_timeout(1300); await pg.evaluate('()=>{location.hash="#/historial"}'); await pg.wait_for_timeout(1500); t5 = await pg.evaluate(TAB)
                res('N-05 cambiar de MÓDULO con la ventana abierta y volver: SIN ventana ni pestaña residual, en el listado', not t5['visible'] and t5['lista'] and t5['detalle_vacio'], t5)
                await pg.click('[data-htab="search"]'); await pg.fill('#bsQ', ids['orden_otra']); await pg.press('#bsQ', 'Enter'); await pg.wait_for_timeout(900); n6 = await pg.locator('#bsRes .bs-res').count()
                res('N-06 BUSCAR ENTREGA funciona como pestaña INDEPENDIENTE (busca y muestra la entrega)', n6 == 1, n6)
                for rn in (ids['encurso'], ids['fin']):   # se REVISAN y se CIERRAN también la hoja EN CURSO y la FINALIZADA
                    await pg.click('[data-htab="list"]'); await pg.fill('#hfNumber', rn); await pg.click('#hfGo'); await pg.wait_for_timeout(900)
                    await pg.locator('#hList [data-view]').first.click(); await pg.wait_for_timeout(1200); await pg.click('#vhClose'); await pg.wait_for_timeout(400)
                await pg.fill('#hfNumber', ''); await pg.click('#hfGo'); await pg.wait_for_timeout(600)
                snap1 = await pg.evaluate(SNAP); st = {x[1]: x[2] for x in json.loads(snap1)}
                res('N-07 consultar y cerrar NO modifica NINGUNA hoja (estados, fechas, versión y resultados idénticos; EN CURSO sigue EN CURSO y FINALIZADA sigue FINALIZADA)',
                    snap0 == snap1 and st[ids['encurso']] == 'EN_CURSO' and st[ids['fin']] == 'COMPLETADA', {'hash_antes': hashlib.sha1(snap0.encode()).hexdigest()[:10], 'hash_despues': hashlib.sha1(snap1.encode()).hexdigest()[:10], 'en_curso': st[ids['encurso']], 'finalizada': st[ids['fin']]})
                state = await ctx.storage_state(); await ctx.close()
                # ---------- RESOLUCIONES ----------
                for tag, w, h, mob in VPS:
                    c = await b.new_context(viewport={'width': w, 'height': h}, is_mobile=mob, has_touch=mob, device_scale_factor=2 if mob else 1, storage_state=state); q = await c.new_page(); q.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
                    await q.goto(f'http://127.0.0.1:{dp.PORT}/'); await dp.login(q, 'admin@okdespacho.demo'); med = {}
                    for scr in SCREENS: await go(q, scr); med[scr] = await q.evaluate(MEASURE, mob)
                    bad_int = {s: [i for i in m['internos'] if not (mob or i['analisis'])] for s, m in med.items()}
                    bad_int = {s: v for s, v in bad_int.items() if v}; acc_ocultas = {s: [i for i in m['internos'] if i['con_acciones'] and not i['acciones_visibles']] for s, m in med.items()}; acc_ocultas = {s: v for s, v in acc_ocultas.items() if v}; tapadas = {s: [i for i in m['internos'] if not i['primera_columna_libre']] for s, m in med.items()}; tapadas = {s: v for s, v in tapadas.items() if v}
                    res(f'L-{tag} SIN desplazamiento horizontal de la página en {len(SCREENS)} pantallas, sin controles fuera de pantalla; desplazamiento interno solo justificado' + (' (tablas anchas en Android, con ACCIONES fijas visibles que NO tapan la 1.ª columna)' if mob else ' (ninguno en Hojas)'),
                        all(m['pagina'] <= 0 and not m['fuera'] for m in med.values()) and not bad_int and not acc_ocultas and not tapadas, {'columna_fija_tapa_la_primera': tapadas, 'pagina': {s: m['pagina'] for s, m in med.items() if m['pagina'] > 0}, 'fuera': {s: m['fuera'] for s, m in med.items() if m['fuera']}, 'internos_no_justificados': bad_int, 'acciones_ocultas': acc_ocultas})
                    # cabecera fija con DESPLAZAMIENTO REAL (rueda / dedo) por el listado largo
                    await go(q, '#/historial'); samples = []
                    for step in range(4):   # desplazamiento REAL con la rueda, con el puntero SOBRE las filas del listado
                        pt = await q.evaluate('()=>{const rows=[...document.querySelectorAll("#hList tr[data-rid]")]; const hs=document.querySelector(".hstick").getBoundingClientRect(); const r=rows.map(x=>x.getBoundingClientRect()).find(b=>b.top>hs.bottom+4&&b.bottom<innerHeight-4)||{left:innerWidth/2-10,width:20,top:innerHeight-80,height:20}; return [Math.round(r.left+Math.min(r.width/2,120)), Math.round(r.top+r.height/2)]}')
                        await q.mouse.move(pt[0], pt[1]); await q.mouse.wheel(0, 450); await q.wait_for_timeout(400); samples.append(await q.evaluate(STICKY, mob))
                    if mob:   # variante móvil: con un toque se abren los FILTROS DENTRO del bloque fijo, estando abajo, y son usables
                        await q.click('#hFold>summary'); await q.wait_for_timeout(400)
                        samples.append(await q.evaluate(STICKY, mob)); samples[-1]['filtros_abiertos_abajo'] = await q.evaluate('()=>{const e=document.getElementById("hfOrder").getBoundingClientRect(), h=document.querySelector(".hstick").getBoundingClientRect(); return e.height>0&&e.top>=h.top-1&&e.bottom<=Math.min(h.bottom,innerHeight)+1}')
                    if tag in ('1366x768', '412x915'): await q.screenshot(path=os.path.join(OUT, f'cabecera_fija_{tag}.png'))
                    last = samples[-1]
                    res(f'S-{tag} al BAJAR por el listado: cabecera/navegación, pestañas, buscador y filtros quedan VISIBLES pegados debajo de la cabecera, y la fila de abajo NO queda tapada',
                        last['scrollY'] > 600 and (not mob or last.get('filtros_abiertos_abajo')) and all(s['cabecera_visible'] for s in samples) and last['bloque_pegado'] and last['buscador_visible'] and last['pestanas_visibles'] and last['debajo_es_lista'], samples[-1])
                    # INTERACCIÓN estando abajo: filtrar con el buscador fijo y abrir VER HOJA de una fila; luego una VENTANA por encima de la cabecera
                    await q.fill('#hfOrder', '81011'); await q.click('#hfGo'); await q.wait_for_timeout(900); filas = await q.locator('#hList tr[data-rid]').count()
                    vb = q.locator('#hList [data-view]').first; await vb.scroll_into_view_if_needed()
                    hit = await vb.evaluate('b=>{const r=b.getBoundingClientRect(); const e=document.elementFromPoint(r.left+r.width/2, r.top+r.height/2); return e===b||b.contains(e);}')
                    await vb.click(); await q.wait_for_timeout(1200); rev = await q.evaluate(TAB)
                    await q.click('#vhClose'); await q.wait_for_timeout(300); await q.fill('#hfOrder', ''); await q.click('#hfGo'); await q.wait_for_timeout(700)
                    await q.evaluate('()=>{location.hash="#/usuarios"}'); await q.wait_for_timeout(1500); await q.mouse.wheel(0, 900); await q.wait_for_timeout(300)
                    nu = q.locator('#upNew'); modal = None
                    if await nu.count():
                        await nu.click(); await q.wait_for_timeout(700)
                        modal = await q.evaluate('()=>{const s=document.querySelector(".umodal:not(.up-inpanel) #umSave"); if(!s) return null; s.scrollIntoView({block:"center"}); const r=s.getBoundingClientRect(); const e=document.elementFromPoint(r.left+r.width/2,r.top+r.height/2); return {sobre_cabecera:e===s||s.contains(e), dentro:r.right<=innerWidth&&r.left>=0}}')
                    menu = None
                    if mob:
                        await q.keyboard.press('Escape'); await q.evaluate('()=>{const m=document.querySelector(".umodal:not(.up-inpanel)"); if(m) m.remove()}')
                        await q.click('#usersPanel .rc4side .rc4menu'); await q.wait_for_timeout(500)
                        menu = await q.evaluate('()=>{const n=document.querySelector("#usersPanel .rc4side"); const a=n&&[...n.querySelectorAll("a[href^=\\"#/\\"]")].filter(x=>x.getBoundingClientRect().height>0);   /* navegación AGRUPADA visible (la lista .nav antigua está oculta en Android) */ return {abierto:!!a&&a.length>5, toque_min:a?Math.min(...a.map(x=>Math.round(x.getBoundingClientRect().height))):0}}')
                    tx = await q.evaluate('()=>{const t=[...document.querySelectorAll("[data-htab]")]; return t.length?Math.min(...t.filter(b=>!b.hidden).map(b=>Math.round(b.getBoundingClientRect().height))):99}') if False else None
                    if tag == '360x800': await q.screenshot(path=os.path.join(OUT, 'menu_android_360.png'))
                    await c.close()
                    res(f'I-{tag} USO REAL estando abajo: el buscador fijo filtra, VER HOJA se toca sin que la cabecera lo tape y abre la revisión; la ventana «Nuevo usuario» queda POR ENCIMA de la cabecera' + (' · menú de navegación abre y es táctil' if mob else ''),
                        filas >= 1 and hit and rev['visible'] and bool(modal) and modal['sobre_cabecera'] and modal['dentro'] and (not mob or (menu['abierto'] and menu['toque_min'] >= 36)), {'filas': filas, 'boton_libre': hit, 'revision': rev['texto'], 'ventana': modal, 'menu': menu})
                # ---------- tamaño táctil en Android de pestañas y cierre de revisión ----------
                c = await b.new_context(viewport={'width': 360, 'height': 800}, is_mobile=True, has_touch=True, storage_state=state); q = await c.new_page(); await q.goto(f'http://127.0.0.1:{dp.PORT}/'); await dp.login(q, 'admin@okdespacho.demo')
                await go(q, '#/historial:revisar')
                tt = await q.evaluate('()=>[...document.querySelectorAll("#vhX, #vhClose")].map(b=>({t:b.textContent.trim().slice(0,22)||"×", h:Math.round(b.getBoundingClientRect().height), w:Math.round(b.getBoundingClientRect().width), dentro:b.getBoundingClientRect().right<=innerWidth&&b.getBoundingClientRect().bottom<=innerHeight}))')
                await q.screenshot(path=os.path.join(OUT, 'ver_hoja_360.png')); await q.click('#vhClose'); await q.wait_for_timeout(300)
                tt += await q.evaluate('()=>[...document.querySelectorAll("#hTabs button")].filter(b=>!b.hidden).map(b=>({t:b.textContent.trim().slice(0,22), h:Math.round(b.getBoundingClientRect().height), w:Math.round(b.getBoundingClientRect().width), dentro:b.getBoundingClientRect().right<=innerWidth}))'); await c.close()
                res('T-360 Android: × y CERRAR de VER HOJA y pestañas LISTADO / BUSCAR ENTREGA dentro de la pantalla y con tamaño táctil (≥ 36 px)', all(x['h'] >= 36 and x['w'] >= 36 and x['dentro'] for x in tt) and len(tt) == 4, tt)
            finally: await b.close()
    finally: srv.terminate()
    print('TOTAL', sum(1 for r in R if r[1] == 'PASS'), 'PASS /', sum(1 for r in R if r[1] == 'FAIL'), 'FAIL · esperados', EXPECTED)
    return R
if __name__ == '__main__':
    try: rr = asyncio.run(main())
    except Exception as e: traceback.print_exc(); print('ERROR:', repr(e)); sys.exit(2)
    if len(rr) != EXPECTED: print('ERROR: se ejecutaron %d de %d' % (len(rr), EXPECTED)); sys.exit(2)
    sys.exit(1 if any(r[1] != 'PASS' for r in rr) else 0)
