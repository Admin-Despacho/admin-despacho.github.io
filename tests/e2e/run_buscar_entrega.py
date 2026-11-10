"""E2E (modo demo, Chromium) · V4.26 · HOJAS PUBLICADAS → BUSCAR ENTREGA: pedido / factura / NDP / hoja, intentos de entrega, constancia y firma
original SOLO con permiso de firmas, alcance por equipo, constancia imprimible, notebook y Android. Uso: python3 run_buscar_entrega.py [dist-demo] [salida]"""
import asyncio, os, sys, traceback
sys.path.insert(0, os.path.dirname(__file__))
import run_driver_perfiles as dp
from playwright.async_api import async_playwright
dp.PORT = 4422; R = []; EXPECTED = 7
if len(sys.argv) > 1: dp.DIST = sys.argv[1]
OUT = sys.argv[2] if len(sys.argv) > 2 else '/tmp/okd_be'
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:300])); print('..', ' | '.join(R[-1]), flush=True)
PNG = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='
SETUP = '''async(png)=>{const A=window.OKD_ONLINE.api, k="okd_online_demo_v2";
  const st=(o,n)=>({ready:true, client_name:n, client_key:n.toUpperCase(), address:'Godoy Cruz '+o, zone:'ESTE', stop_type:'PEDIDO', order_numbers:[String(o)], merchandise_amount:1000, shipping_fee:0, task:'ENTREGA', expected_amount:1000});
  const pdf=rows=>({pdf_model:{data:rows.map(r=>({r}))}});
  const r1=await A.publishRoute(Object.assign({sheet_key:'qa-be1-'+Date.now(), carrier_id:'CT-ESTE', responsable_id:'u-cristian', rules_version:1, routing_rules_version:1,
     stops:[st(26340,'Comercial del Valle QA'), st(26355,'Ferretería Norte QA')]}, pdf([{fecha:'2026-11-04', mainOrder:'26340', mainDoc:'FCB 0002-00012345'}, {fecha:'2026-11-04', mainOrder:'26355', mainDoc:'NDP 0001-00000777'}])));
  // primera visita: 26340 entregado, 26355 REPROGRAMADO y la hoja cerrada → recién entonces el pedido puede ir a otra hoja (como en la realidad)
  let d=JSON.parse(localStorage.getItem(k)); let R1=d.routes2.find(x=>x.id===r1.id);
  R1.stops[0].outcome='ENTREGADO'; R1.stops[1].outcome='REPROGRAMAR'; R1.stops[1].outcome_note='Cliente cerrado'; R1.operational_status='COMPLETADA';
  localStorage.setItem(k, JSON.stringify(d));
  const r2=await A.publishRoute(Object.assign({sheet_key:'qa-be2-'+Date.now(), carrier_id:'CT-ESTE', responsable_id:'u-cristian', rules_version:1, routing_rules_version:1,
     stops:[st(26355,'Ferretería Norte QA')]}, pdf([{fecha:'2026-11-05', mainOrder:'26355', mainDoc:'NDP 0001-00000777'}])));
  d=JSON.parse(localStorage.getItem(k)); const a=d.users.find(u=>u.role==="ADMIN");
  const add=(id,email,role,name,sup)=>{ if(!d.users.some(u=>u.id===id)) d.users.push(Object.assign({}, a, {id, email, role, full_name:name, status:"ACTIVO", carriers:[], extra_perms:[], denied_perms:[], supervisor_user_id:sup||null})); };
  add("u-be-sup","qa.besup@okdespacho.demo","SUPERVISOR_DESPACHO","QA Superior Equipo",null); add("u-be-op","qa.beop@okdespacho.demo","OPERARIO_DEPOSITO","QA Operario Equipo","u-be-sup");
  add("u-be-sup2","qa.besup2@okdespacho.demo","SUPERVISOR_DESPACHO","QA Superior Otro",null);
  R1=d.routes2.find(x=>x.id===r1.id); const R2=d.routes2.find(x=>x.id===r2.id); [R1,R2].forEach(R=>{ R.published_by='u-be-op'; R.operational_status='COMPLETADA'; R.started_at=new Date(Date.now()-5*3600e3).toISOString(); R.completed_at=new Date().toISOString(); });
  const s1=R1.stops[0], s2=R1.stops[1], s3=R2.stops[0]; const now=new Date().toISOString();
  s1.outcome='ENTREGADO'; s2.outcome='REPROGRAMAR'; s2.outcome_note='Cliente cerrado'; s3.outcome='ENTREGADO';
  d.evidence=d.evidence||{}; d.receipts=d.receipts||{};
  d.evidence[s1.id]={receiver_name:'María Pérez QA', cuil:'27111111110', signature_png_b64:png, created_at:now, created_by:'u-cristian'}; d.receipts[s1.id]={receipt_number:'RC-000123', generated_at:now};
  d.evidence[s3.id]={receiver_name:'Juan Gómez QA', cuil:'20123456786', signature_png_b64:png, created_at:now, created_by:'u-cristian'};
  localStorage.setItem(k, JSON.stringify(d)); return {r1:r1.id, r1n:R1.number, r2:r2.id, s1:s1.id};}'''
CARDS = '()=>[...document.querySelectorAll("#bsRes .bs-res")].map(c=>({stop:c.dataset.stop, txt:c.innerText.replace(/\\s+/g," "), print:!!c.querySelector("[data-bs-print]"), view:(c.querySelector("[data-bs-view]")||{}).textContent||null}))'
async def search(pg, q): await pg.fill('#bsQ', q); await pg.press('#bsQ', 'Enter'); await pg.wait_for_timeout(900); return await pg.evaluate(CARDS)
async def open_tab(pg): await pg.evaluate('()=>{location.hash="#/historial"}'); await pg.wait_for_timeout(1500); await pg.click('[data-htab="search"]'); await pg.wait_for_timeout(400)
async def relog(pg, email): await pg.evaluate('async()=>{try{await window.OKD_ONLINE.api.signOut()}catch(e){}}'); await dp.login(pg, email)
async def main():
    os.makedirs(OUT, exist_ok=True); srv = dp.serve()
    try:
        async with async_playwright() as p:
            b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
            try:
                ctx = await b.new_context(viewport={'width': 1366, 'height': 900}); pg = await ctx.new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
                await pg.goto(f'http://127.0.0.1:{dp.PORT}/'); await pg.evaluate('()=>localStorage.clear()'); await dp.login(pg, 'admin@okdespacho.demo'); ids = await pg.evaluate(SETUP, PNG)
                await open_tab(pg); c = await search(pg, '26340'); await pg.screenshot(path=os.path.join(OUT, 'buscar_entrega_notebook.png'))
                ov = await pg.evaluate('()=>document.documentElement.scrollWidth-document.documentElement.clientWidth')
                res('BE-01 ADMINISTRADOR · pedido 26340: cliente, hoja, transportista, ENTREGADO, receptor y CUIL, constancia N.º y botones IMPRIMIR / VER CONSTANCIA Y FIRMA; sin desplazamiento lateral',
                    len(c) == 1 and all(t in c[0]['txt'] for t in ['Comercial del Valle QA', ids['r1n'], 'Entregado', 'María Pérez QA', 'CUIL 27111111110', 'RC-000123']) and c[0]['print'] and 'CONSTANCIA' in (c[0]['view'] or '') and ov <= 0, c and c[0]['txt'][:200])
                f = {q: len(await search(pg, q)) for q in ['12345', '0002-00012345', 'FCB 0002-00012345', '0003-00012345', ids['r1n']]}
                res('BE-02 FACTURA (12345 · 0002-00012345 · FCB 0002-00012345) y HOJA encuentran la entrega; otro punto de venta (0003-…) no', f['12345'] == 1 and f['0002-00012345'] == 1 and f['FCB 0002-00012345'] == 1 and f['0003-00012345'] == 0 and f[ids['r1n']] == 2, f)
                c = await search(pg, 'NDP 0001-00000777'); t = sorted(x['txt'] for x in c)
                res('BE-03 INTENTOS: el pedido 26355 (NDP) reprogramado y entregado en una segunda hoja muestra «INTENTO 1 de 2» (Reprogramado · Cliente cerrado) y «INTENTO 2 de 2» (Entregado)',
                    len(c) == 2 and any('INTENTO 1 de 2' in x and 'Reprogramado' in x and 'Cliente cerrado' in x for x in t) and any('INTENTO 2 de 2' in x and 'Entregado' in x for x in t), [x[:120] for x in t])
                await search(pg, '26340'); await pg.click('#bsRes [data-bs-view]'); await pg.wait_for_timeout(2200)
                tr = await pg.evaluate('()=>{const b=document.getElementById("deliveryTraceBox"); return b?{img:[...b.querySelectorAll("img")].some(i=>i.src.startsWith("data:image")), txt:b.innerText}:null}')
                res('BE-04 VER CONSTANCIA Y FIRMA abre la hoja y el panel VER ENTREGA de esa parada con la FIRMA ORIGINAL', bool(tr) and tr['img'] and 'María Pérez QA' in tr['txt'] and '27111111110' in tr['txt'], tr and {'firma': tr['img'], 'receptor': 'María Pérez QA' in tr['txt']})
                await pg.click('#vhClose'); await pg.wait_for_timeout(400)   # V4.28: VER CONSTANCIA abre VER HOJA; CERRAR vuelve a BUSCAR ENTREGA
                assert await pg.evaluate('()=>!document.querySelector("#hSearch").hidden'), 'CERRAR debía volver a BUSCAR ENTREGA'
                await search(pg, '26340'); await pg.click('#bsRes [data-bs-print]'); await pg.wait_for_timeout(900)
                pr = await pg.evaluate('()=>{const p=document.querySelector(".bs-paper"); return p?{txt:p.innerText.replace(/\\s+/g," "), img:!!p.querySelector("figure img")}:null}')
                await pg.screenshot(path=os.path.join(OUT, 'constancia_imprimible.png')); await pg.evaluate('()=>{const c=document.getElementById("bsC"); if(c) c.click()}')
                res('BE-05 CONSTANCIA IMPRIMIBLE: pedido, comprobante, cliente, hoja, receptor, CUIL, fecha y firma original', bool(pr) and all(x in pr['txt'] for x in ['26340', 'FCB 0002-00012345', 'Comercial del Valle QA', 'María Pérez QA', '27111111110']) and pr['img'], pr and pr['txt'][:160])
                perm = {}
                for who, em in [('operario_sin_firmas', 'qa.beop@okdespacho.demo'), ('superior_otro_equipo', 'qa.besup2@okdespacho.demo'), ('superior_del_equipo', 'qa.besup@okdespacho.demo')]:
                    await relog(pg, em); await open_tab(pg); c = await search(pg, '26340'); perm[who] = {'n': len(c), 'cuil': bool(c) and 'CUIL' in c[0]['txt'] and '27111111110' in c[0]['txt'], 'print': bool(c) and c[0]['print'], 'estado': bool(c) and 'Entregado' in c[0]['txt']}
                res('BE-06 PERMISOS: el Operario (sin permiso de firmas) ve el ESTADO pero NO receptor/CUIL/impresión; el Superior de OTRO equipo no ve nada; el Superior del EQUIPO ve todo',
                    perm['operario_sin_firmas'] == {'n': 1, 'cuil': False, 'print': False, 'estado': True} and perm['superior_otro_equipo']['n'] == 0 and perm['superior_del_equipo'] == {'n': 1, 'cuil': True, 'print': True, 'estado': True}, perm)
                state = await ctx.storage_state(); await ctx.close()
                m = await (await b.new_context(storage_state=state, viewport={'width': 412, 'height': 915}, is_mobile=True, device_scale_factor=2.625)).new_page(); m.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
                await m.goto(f'http://127.0.0.1:{dp.PORT}/'); await dp.login(m, 'admin@okdespacho.demo'); await open_tab(m); await search(m, '26355')
                a = await m.evaluate('''()=>{const inScroll=el=>{for(let p=el.parentElement;p;p=p.parentElement){const o=getComputedStyle(p).overflowX; if(o==="auto"||o==="scroll") return true;} return false;};
                  return {over:document.documentElement.scrollWidth-document.documentElement.clientWidth, sticky:getComputedStyle(document.querySelector(".bs-sticky")).position,
                    fuera:[...document.querySelectorAll("#hSearch button,#hSearch input")].filter(e=>{const r=e.getBoundingClientRect(); return r.width>0&&!inScroll(e)&&(r.right>innerWidth+1||r.left<-1);}).length, tarjetas:document.querySelectorAll(".bs-res").length}}''')
                await m.screenshot(path=os.path.join(OUT, 'buscar_entrega_android.png'), full_page=True)
                res('BE-07 ANDROID: buscador fijo (sticky), resultados compactos, sin desplazamiento lateral ni botones cortados', a['over'] <= 0 and a['sticky'] == 'sticky' and a['fuera'] == 0 and a['tarjetas'] == 2, a)
            finally: await b.close()
    finally: srv.terminate()
    print('TOTAL', sum(1 for r in R if r[1] == 'PASS'), 'PASS /', sum(1 for r in R if r[1] == 'FAIL'), 'FAIL · esperados', EXPECTED)
    return R
if __name__ == '__main__':
    try: rr = asyncio.run(main())
    except Exception as e: traceback.print_exc(); print('ERROR:', repr(e)); sys.exit(2)
    if len(rr) != EXPECTED: print('ERROR: se ejecutaron %d de %d' % (len(rr), EXPECTED)); sys.exit(2)
    sys.exit(1 if any(r[1] != 'PASS' for r in rr) else 0)
