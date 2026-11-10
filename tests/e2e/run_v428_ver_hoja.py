"""E2E BLOQUEANTE (modo demo, Chromium) · V4.28 · VER HOJA (ventana), RESOLVER PENDIENTE, campana e HISTORIAL DE CAMBIOS.
Hojas armadas con el FLUJO REAL (entregas con DNI / CUIT y un PARCIAL «Rodamiento Brasil»). Datos FICTICIOS. Uso: python3 run_v428_ver_hoja.py [dist-demo] [salida]"""
import asyncio, os, sys, json, hashlib, traceback
sys.path.insert(0, os.path.dirname(__file__))
import run_driver_perfiles as dp
from playwright.async_api import async_playwright
dp.PORT = 4490; R = []; EXPECTED = 11
if len(sys.argv) > 1: dp.DIST = sys.argv[1]
OUT = sys.argv[2] if len(sys.argv) > 2 else '/tmp/okd_v428'
K = 'okd_online_demo_v2'
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:340])); print('..', ' | '.join(R[-1]), flush=True)
SETUP = '''()=>{const d=JSON.parse(localStorage.getItem("%s")); const a=d.users.find(u=>u.role==="ADMIN");
  const add=(id,email,role,name,sup,ov)=>{ if(!d.users.some(u=>u.id===id)) d.users.push(Object.assign({}, a, {id, email, role, full_name:name, status:"ACTIVO", carriers:[], extra_perms:[], denied_perms:[], supervisor_user_id:sup||null, permission_overrides:ov||{}})); };
  add("u-leo","leonardo.qa@okdespacho.demo","SUPERVISOR_DESPACHO","Leonardo Cabañez QA",null,{can_approve_internal_route_changes:true});
  add("u-op8","guillermo.qa@okdespacho.demo","OPERARIO_DEPOSITO","Guillermo Castillo QA","u-leo");
  add("u-sup2","otro.superior.qa@okdespacho.demo","SUPERVISOR_DESPACHO","Otro Superior QA",null,{can_approve_internal_route_changes:true});
  add("u-ro","lectura.qa@okdespacho.demo","SOLO_LECTURA","Solo Lectura QA",null);
  localStorage.setItem("%s", JSON.stringify(d));}''' % (K, K)
PUB = '''async(k)=>{const A=window.OKD_ONLINE.api, st=(n,o)=>({ready:true, client_name:n, client_key:n.toUpperCase(), address:'Godoy Cruz '+o, zone:'ESTE', stop_type:'PEDIDO', order_numbers:[String(o)], merchandise_amount:1000, shipping_fee:0, task:'ENTREGA', expected_amount:1000});
  return (await A.publishRoute({sheet_key:k, carrier_id:'CT-ESTE', responsable_id:'u-cristian', rules_version:1, routing_rules_version:1, stops:[st('Montecaseros Casa Central',k.slice(-3)+'1'), st('Local San Juan',k.slice(-3)+'2'), st('Rodamiento Brasil',k.slice(-3)+'3')]})).id}'''
FLOW = '''async(id)=>{const A=window.OKD_ONLINE.api, db=()=>JSON.parse(localStorage.getItem("%s")), R=()=>db().routes2.find(x=>x.id===id), loc={lat:-32.9,lon:-68.8};
  const sig="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";
  await A.startRoute(id); const S=R().stops;
  const go=async(s,o,doc,note)=>{ try{await A.arriveStop(s.id, loc, "ar-"+s.id);}catch(e){} await A.setStopOutcome(s.id,o,note||null,null,"o-"+s.id,{evidence:Object.assign({receiver_name:"Receptor QA", signature_png_b64:sig}, doc), location:loc}); };
  await go(S[0],"ENTREGADO",{receiver_doc_type:"DNI", receiver_doc:"30111222"}); await go(S[1],"ENTREGADO",{receiver_doc_type:"CUIT", receiver_doc:"30500010912", cuil:"30500010912"});
  await go(S[2],"ENTREGA_PARCIAL",{receiver_doc_type:"CUIL", receiver_doc:"20123456786", cuil:"20123456786"},"Quedó una tarea pendiente de revisión");
  try{ await A.finalizeRoute(id); }catch(e){ return {err:String(e.message||e)}; }
  const r=R(); return {number:r.number, op:r.operational_status, ev:S.map(s=>{const e=db().evidence[s.id]||{}; return [e.receiver_doc_type||null, e.cuil||null, e.receiver_dni||null];})};}''' % K
SNAP = '()=>{const d=JSON.parse(localStorage.getItem("%s")); return JSON.stringify((d.routes2||[]).map(r=>[r.id,r.operational_status,r.approval_status||null,r.version||null,(r.stops||[]).map(s=>[s.id,s.outcome,s.outcome_note||null])]))}' % K
async def relog(pg, email): await pg.evaluate('async()=>{try{await window.OKD_ONLINE.api.signOut()}catch(e){}}'); await dp.login(pg, email); await pg.wait_for_timeout(400)
async def hist_list(pg, number):
    await pg.evaluate('()=>{location.hash="#/historial"}'); await pg.wait_for_timeout(1300)
    await pg.fill('#hfNumber', ''); await pg.click('#hfGo'); await pg.wait_for_timeout(700)
async def open_vh(pg, number):
    await pg.locator('#hList tr[data-rid]', has_text=number).locator('[data-view]').click(); await pg.wait_for_timeout(1500)
VH = '''()=>{const o=document.querySelector(".vh-ovl"); const v=o&&!o.hidden; return {abierta:v, titulo:v?document.getElementById("vhTitle").textContent:null, paradas:v?document.querySelectorAll(".vh-stop").length:0, lista_visible:!!document.querySelector("#hList")&&!document.querySelector("#hList").hidden&&document.querySelector("#hList").offsetHeight>0, pestana_revisar:!!document.querySelector("[data-htab=\\"detail\\"]:not([hidden])")}}'''
async def main():
    os.makedirs(OUT, exist_ok=True); srv = dp.serve()
    try:
        async with async_playwright() as p:
            b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
            try:
                pg = await (await b.new_context(viewport={'width': 1366, 'height': 768})).new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
                await pg.goto(f'http://127.0.0.1:{dp.PORT}/'); await pg.evaluate('()=>localStorage.clear()'); await dp.login(pg, 'admin@okdespacho.demo'); await pg.evaluate(SETUP)
                await relog(pg, 'guillermo.qa@okdespacho.demo'); rid = await pg.evaluate(PUB, 'qa-v428-901')
                for i in range(30): await pg.evaluate(PUB, 'qa-v428-%03d' % (100 + i))   # listado largo para probar la posición
                await relog(pg, 'cristian@okdespacho.demo'); fl = await pg.evaluate(FLOW, rid)
                assert 'err' not in fl, fl
                num = fl['number']; snap0 = await pg.evaluate(SNAP)
                # ---- VH-01..03 (Operario del equipo de Leonardo) ----
                await relog(pg, 'guillermo.qa@okdespacho.demo'); await hist_list(pg, num)
                await pg.fill('#hfNumber', num); await pg.click('#hfGo'); await pg.wait_for_timeout(800)
                filtro0 = await pg.input_value('#hfNumber')
                await open_vh(pg, num); v1 = await pg.evaluate(VH); await pg.screenshot(path=os.path.join(OUT, 'ver_hoja_notebook.png'))
                res('VH-01 VER HOJA abre una VENTANA superpuesta «VER HOJA <número>» con 3 paradas; el listado sigue VISIBLE detrás y NO aparece la pestaña temporal',
                    v1['abierta'] and v1['titulo'] == 'VER HOJA ' + num and v1['paradas'] == 3 and v1['lista_visible'] and not v1['pestana_revisar'], v1)
                await pg.locator('.vh-stop', has_text='Rodamiento Brasil').locator('summary').click(); await pg.wait_for_timeout(400)
                await pg.locator('.vh-stop', has_text='Local San Juan').locator('summary').click(); await pg.wait_for_timeout(400)
                st = await pg.evaluate('''()=>[...document.querySelectorAll(".vh-stop")].map(d=>({n:d.querySelector(".vh-who b").textContent, abierta:d.open, txt:d.innerText.replace(/\\s+/g," "), resolver:!!d.querySelector("[data-vhres]")}))''')
                rb = next(x for x in st if x['n'] == 'Rodamiento Brasil'); ls = next(x for x in st if x['n'] == 'Local San Juan')
                res('VH-02 expandir paradas: Rodamiento Brasil muestra PARCIAL y su observación con RESOLVER PENDIENTE; Local San Juan (realizada) se expande sin RESOLVER',
                    rb['abierta'] and 'Parcial' in rb['txt'] and 'Quedó una tarea pendiente de revisión' in rb['txt'] and rb['resolver'] and ls['abierta'] and not ls['resolver'], {'rodamiento': rb['txt'][:120], 'san_juan_resolver': ls['resolver']})
                # ---- VH-04/05: RESOLVER PENDIENTE (gestión y reprogramación) ----
                await pg.locator('.vh-stop', has_text='Rodamiento Brasil').locator('[data-vhres]').click(); await pg.wait_for_timeout(300)
                await pg.fill('.vh-stop:has-text("Rodamiento Brasil") [data-vhnote]', 'Se coordinó con el cliente la entrega del faltante'); await pg.click('.vh-stop:has-text("Rodamiento Brasil") [data-vhok]'); await pg.wait_for_timeout(1000)
                m4 = await pg.inner_text('.vh-stop:has-text("Rodamiento Brasil") [data-vhmsg]')
                d4 = await pg.evaluate('(rid)=>{const d=JSON.parse(localStorage.getItem("%s")); const r=d.routes2.find(x=>x.id===rid), s=r.stops.find(x=>x.client_name==="Rodamiento Brasil"); return {outcome:s.outcome, nota:s.outcome_note, fu:(d.stopFollowups||[]).filter(f=>f.stop_id===s.id).map(f=>f.kind)}}' % K, rid)
                fuUI = await pg.inner_text('.vh-stop:has-text("Rodamiento Brasil") [data-vhfu]')
                res('VH-04 REGISTRAR GESTIÓN: queda en el servidor (demo) y en GESTIONES de la parada; el resultado sigue PARCIAL con su observación original',
                    'no se modificó' in m4 and d4['outcome'] == 'ENTREGA_PARCIAL' and d4['nota'] == 'Quedó una tarea pendiente de revisión' and d4['fu'] == ['GESTION'] and 'Se coordinó con el cliente' in fuUI, {**d4, 'msg': m4})
                await pg.check('.vh-stop:has-text("Rodamiento Brasil") input[value="REPROGRAMACION"]'); await pg.fill('.vh-stop:has-text("Rodamiento Brasil") [data-vhnote]', 'Reprogramar el faltante para el lunes')
                await pg.click('.vh-stop:has-text("Rodamiento Brasil") [data-vhok]'); await pg.wait_for_timeout(1000); m5 = await pg.inner_text('.vh-stop:has-text("Rodamiento Brasil") [data-vhmsg]')
                q5 = await pg.evaluate('(rid)=>{const d=JSON.parse(localStorage.getItem("%s")); const q=(d.opRequests||[]).filter(x=>x.route_id===rid); return q.map(x=>({id:x.id, t:x.request_type, st:x.status, sup:x.supervisor_user_id, acc:(x.payload||{}).accion, origen:(x.payload||{}).origen}))}' % K, rid)
                res('VH-05 SOLICITAR REPROGRAMACIÓN: solicitud PENDIENTE DE APROBACIÓN por el circuito existente (OTRO, sin efectos automáticos), dirigida a Leonardo (Superior del equipo)',
                    'PENDIENTE DE APROBACIÓN' in m5 and len(q5) == 1 and q5[0]['t'] == 'OTRO' and q5[0]['st'] == 'PENDING' and q5[0]['sup'] == 'u-leo' and q5[0]['origen'] == 'VER_HOJA', {'solicitudes': q5, 'msg': m5})
                # cerrar: filtro y posición conservados; ninguna hoja cambia de estado por consultar
                await pg.click('#vhClose'); await pg.wait_for_timeout(500); v3 = await pg.evaluate(VH); filtro1 = await pg.input_value('#hfNumber')
                await pg.fill('#hfNumber', ''); await pg.click('#hfGo'); await pg.wait_for_timeout(800)
                up = await pg.evaluate('()=>{const u=document.getElementById("usersPanel"); const s=u&&u.scrollHeight>u.clientHeight?u:document.scrollingElement; s.scrollTop=600; return s.scrollTop}')
                await pg.locator('#hList [data-view]').nth(12).click(); await pg.wait_for_timeout(1200); await pg.click('#vhX'); await pg.wait_for_timeout(500)
                up2 = await pg.evaluate('()=>{const u=document.getElementById("usersPanel"); const s=u&&u.scrollHeight>u.clientHeight?u:document.scrollingElement; return s.scrollTop}')
                snap1 = await pg.evaluate(SNAP); st0 = {x[0]: x[1:] for x in json.loads(snap0)}; st1 = {x[0]: x[1:] for x in json.loads(snap1)}
                res('VH-03 CERRAR vuelve EXACTO al listado: filtro conservado, misma posición de desplazamiento, sin ventana ni pestaña residual; consultar no cambió el estado de ninguna hoja',
                    not v3['abierta'] and not v3['pestana_revisar'] and filtro1 == filtro0 == num and abs(up2 - up) <= 2 and all(st0[k][:3] == st1[k][:3] for k in st0), {'filtro': filtro1, 'posicion': [up, up2]})
                # ---- VH-06: sin permiso (Solo lectura) ----
                await relog(pg, 'lectura.qa@okdespacho.demo'); await hist_list(pg, num); await pg.fill('#hfNumber', num); await pg.click('#hfGo'); await pg.wait_for_timeout(800); await open_vh(pg, num)
                ro = await pg.evaluate('()=>({abierta:!document.querySelector(".vh-ovl").hidden, resolver:document.querySelectorAll("[data-vhres]").length})')
                ro_api = await pg.evaluate('async()=>{const d=JSON.parse(localStorage.getItem("%s")); const s=d.routes2.flatMap(r=>r.stops).find(x=>x.client_name==="Rodamiento Brasil"); try{await window.OKD_ONLINE.api.addStopFollowup(s.id,"OBSERVACION","intento sin permiso"); return "PERMITIDO"}catch(e){return e.code||e.message}}' % K)
                res('VH-06 SIN PERMISO (Solo lectura): puede CONSULTAR la hoja pero NO ve RESOLVER PENDIENTE y la API le rechaza registrar gestiones', ro['abierta'] and ro['resolver'] == 0 and ro_api != 'PERMITIDO', {**ro, 'api': ro_api})
                # ---- VH-07: campana de Leonardo → abrir → aprobar ----
                await relog(pg, 'leonardo.qa@okdespacho.demo'); await pg.evaluate('()=>{location.hash="#/dashboard"}'); await pg.wait_for_timeout(1200)
                await pg.evaluate('()=>dispatchEvent(new Event("okd:approvals-changed"))'); await pg.wait_for_timeout(900)
                b0 = await pg.evaluate('()=>{const b=document.querySelector(".apb"); if(!b) return null; const n=b.querySelector(".apb-n"); return {n:n?+n.dataset.n:0, items:[...b.querySelectorAll(".apb-it")].map(a=>a.dataset.apr)}}')
                await pg.click('.apb-btn'); await pg.wait_for_timeout(300); await pg.click(f'.apb-it[data-apr="{q5[0]["id"]}"]'); await pg.wait_for_timeout(1800)
                row = await pg.evaluate('(id)=>{const t=document.querySelector("#rqTable tr[data-id=\\""+id+"\\"]"); return t&&{resaltada:t.classList.contains("rq-focus"), txt:t.innerText.replace(/\\s+/g," ")}}', q5[0]['id'])
                await pg.fill(f'#rqTable tr[data-id="{q5[0]["id"]}"] [data-note]', 'Reprogramar el lunes 16'); await pg.click(f'#rqTable tr[data-id="{q5[0]["id"]}"] [data-d="APPROVED"]'); await pg.wait_for_timeout(1200)
                await pg.evaluate('()=>dispatchEvent(new Event("okd:approvals-changed"))'); await pg.wait_for_timeout(900)
                b1 = await pg.evaluate('()=>{const b=document.querySelector(".apb"); const n=b&&b.querySelector(".apb-n"); return n?+n.dataset.n:0}')
                q7 = await pg.evaluate('(id)=>{const q=JSON.parse(localStorage.getItem("%s")).opRequests.find(x=>x.id===id); return {st:q.status, por:q.resolved_by||q.reviewed_by}}' % K, q5[0]['id'])
                res('VH-07 CAMPANA de Leonardo: muestra la solicitud de VER HOJA, abre la fila RESALTADA («SOLICITAR REPROGRAMACIÓN (VER HOJA)»), la APRUEBA y el contador BAJA',
                    bool(b0) and q5[0]['id'] in b0['items'] and bool(row) and row['resaltada'] and 'SOLICITAR REPROGRAMACIÓN (VER HOJA)' in row['txt'] and q7['st'] == 'APPROVED' and b1 == b0['n'] - 1, {'campana': b0, 'tras_aprobar': b1, **q7})
                # ---- VH-08/09: otro Superior · autoaprobación · doble resolución ----
                await relog(pg, 'otro.superior.qa@okdespacho.demo'); await pg.evaluate('()=>dispatchEvent(new Event("okd:approvals-changed"))'); await pg.wait_for_timeout(900)
                o_items = await pg.evaluate('()=>[...document.querySelectorAll(".apb-it")].map(a=>a.dataset.apr)')
                await relog(pg, 'guillermo.qa@okdespacho.demo')
                rq2 = await pg.evaluate('async(rid)=>{const d=JSON.parse(localStorage.getItem("%s")); const s=d.routes2.find(r=>r.id===rid).stops.find(x=>x.client_name==="Rodamiento Brasil"); return (await window.OKD_ONLINE.api.requestFromViewSheet({route_id:rid, stop_id:s.id, parada:s.client_name, accion:"REVISIÓN DE CORRECCIÓN", reason:"Revisar la observación", resultado_actual:s.outcome, propuesta:"sin cambio hasta aprobar", op_id:"qa-v428-corr"})).id}' % K, rid)
                own = await pg.evaluate('async(id)=>{try{await window.OKD_ONLINE.api.resolveOperationalRequest(id,"APPROVED","propia"); return "PERMITIDO"}catch(e){return e.code||e.message}}', rq2)
                await relog(pg, 'otro.superior.qa@okdespacho.demo')
                ajena = await pg.evaluate('async(id)=>{try{await window.OKD_ONLINE.api.resolveOperationalRequest(id,"APPROVED","ajena"); return "PERMITIDO"}catch(e){return e.code||e.message}}', rq2)
                await relog(pg, 'leonardo.qa@okdespacho.demo')
                dup = await pg.evaluate('async(id)=>{try{await window.OKD_ONLINE.api.resolveOperationalRequest(id,"APPROVED","otra vez"); return "PERMITIDO"}catch(e){return e.code||e.message}}', q5[0]['id'])
                res('VH-08 OTRO Superior no ve en su campana la solicitud ajena y el servidor (demo) le rechaza resolverla', q5[0]['id'] not in o_items and ajena != 'PERMITIDO', {'campana_otro': o_items, 'resolver_ajena': ajena})
                res('VH-09 SIN AUTOAPROBACIÓN (Guillermo no resuelve su propia solicitud) y SIN DOBLE RESOLUCIÓN (la ya aprobada se rechaza)', own != 'PERMITIDO' and dup != 'PERMITIDO', {'propia': own, 'doble': dup})
                # ---- VH-10: historial ----
                await relog(pg, 'guillermo.qa@okdespacho.demo'); await hist_list(pg, num); await pg.fill('#hfNumber', num); await pg.click('#hfGo'); await pg.wait_for_timeout(800); await open_vh(pg, num)
                await pg.click('#vhHistSec > summary'); await pg.wait_for_timeout(700); h = await pg.inner_text('#vhHist')
                res('VH-10 HISTORIAL DE CAMBIOS: resultado ORIGINAL parcial y su motivo, la GESTIÓN, la SOLICITUD de reprogramación APROBADA y QUIÉN la aprobó (con su respuesta)',
                    all(t in h for t in ['RESULTADO ORIGINAL', 'Parcial', 'Quedó una tarea pendiente de revisión', 'GESTION', 'Se coordinó con el cliente', 'SOLICITAR REPROGRAMACIÓN', 'APROBADA', 'Leonardo Cabañez QA', 'Reprogramar el lunes 16']), h.replace('\n', ' | ')[:330])
                # ---- VH-11: notebook y Android sin desbordes; CERRAR visible ----
                lay = {}
                for tag, w, hh, mob in [('1366x768', 1366, 768, False), ('1024x768', 1024, 768, False), ('412x915', 412, 915, True), ('360x800', 360, 800, True)]:
                    await pg.set_viewport_size({'width': w, 'height': hh}); await pg.wait_for_timeout(400)
                    lay[tag] = await pg.evaluate('''()=>{const c=document.getElementById("vhClose").getBoundingClientRect(), x=document.getElementById("vhX").getBoundingClientRect(), d=document.querySelector(".vh-dlg");
                      const out=[...document.querySelectorAll(".vh-dlg button, .vh-dlg summary")].filter(e=>{const r=e.getBoundingClientRect(); return r.width>0&&(r.right>innerWidth+1||r.left<-1);}).length;
                      return {pagina:document.documentElement.scrollWidth-document.documentElement.clientWidth, dialogo:d.scrollWidth-d.clientWidth, fuera:out, cerrar_visible:c.bottom<=innerHeight+1&&c.top>=0&&c.height>=40, x_visible:x.top>=0&&x.height>=40}}''')
                    if tag == '360x800': await pg.screenshot(path=os.path.join(OUT, 'ver_hoja_android_360.png'))
                res('VH-11 VER HOJA en notebook (1366, 1024) y Android (412, 360): sin desplazamiento horizontal, sin controles cortados, CERRAR y × visibles y táctiles',
                    all(v['pagina'] <= 0 and v['dialogo'] <= 0 and v['fuera'] == 0 and v['cerrar_visible'] and v['x_visible'] for v in lay.values()), lay)
            finally: await b.close()
    finally: srv.terminate()
    print('TOTAL', sum(1 for r in R if r[1] == 'PASS'), 'PASS /', sum(1 for r in R if r[1] == 'FAIL'), 'FAIL · esperados', EXPECTED)
    return R
if __name__ == '__main__':
    try: rr = asyncio.run(main())
    except Exception as e: traceback.print_exc(); print('ERROR:', repr(e)); sys.exit(2)
    if len(rr) != EXPECTED: print('ERROR: se ejecutaron %d de %d' % (len(rr), EXPECTED)); sys.exit(2)
    sys.exit(1 if any(r[1] != 'PASS' for r in rr) else 0)
