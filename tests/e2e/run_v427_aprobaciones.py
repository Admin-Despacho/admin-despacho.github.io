"""E2E BLOQUEANTE (modo demo, Chromium) · V4.27 · Aprobación de cambios de RUTA INTERNA en «Solicitudes / Aprobaciones».
Gabriel (Transportista Interno) genera la solicitud con el FLUJO REAL (agrega y reordena paradas y finaliza); Leonardo (Superior Despacho
asignado) la ve en PARA RESOLVER, la revisa y la resuelve por review_route_approval. Datos FICTICIOS. Uso: python3 run_v427_aprobaciones.py [dist-demo] [salida]"""
import asyncio, os, sys, json, traceback
sys.path.insert(0, os.path.dirname(__file__))
import run_driver_perfiles as dp
from playwright.async_api import async_playwright
dp.PORT = 4482; R = []; EXPECTED = 12
if len(sys.argv) > 1: dp.DIST = sys.argv[1]
OUT = sys.argv[2] if len(sys.argv) > 2 else '/tmp/okd_v427_apr'
K = 'okd_online_demo_v2'
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:320])); print('..', ' | '.join(R[-1]), flush=True)
SETUP = '''()=>{const d=JSON.parse(localStorage.getItem("%s")); const a=d.users.find(u=>u.role==="ADMIN");
  const add=(id,email,name)=>{ if(!d.users.some(u=>u.id===id)) d.users.push(Object.assign({}, a, {id, email, role:"SUPERVISOR_DESPACHO", full_name:name, status:"ACTIVO", carriers:[], extra_perms:[], denied_perms:[], supervisor_user_id:null, permission_overrides:{can_approve_internal_route_changes:true}})); };
  add("u-leo","leonardo.qa@okdespacho.demo","Leonardo Cabañez QA"); add("u-sup2","otro.superior.qa@okdespacho.demo","Otro Superior QA");
  d.users.find(u=>u.id==="u-gabriel").supervisor_user_id="u-leo"; localStorage.setItem("%s", JSON.stringify(d));}''' % (K, K)
PUB = '''async(k)=>(await window.OKD_ONLINE.api.publishRoute({sheet_key:k, carrier_id:"INTERNO", responsable_id:"u-gabriel", vehicle_id:"vh-1", rules_version:1, routing_rules_version:1,
  stops:[{client_name:"Depósito Norte QA", order_numbers:["91"+k.slice(-4)], ready:true, bultos:2}, {client_name:"Sucursal Centro QA", order_numbers:["92"+k.slice(-4)], ready:true}, {client_name:"Proveedor Sur QA", order_numbers:["93"+k.slice(-4)], ready:true}]})).id'''
# FLUJO REAL del Transportista Interno con la API de la app (sesión de Gabriel): iniciar, AGREGAR parada, REORDENAR, entregar, LLEGUÉ A DIAMANTE, FINALIZAR
FLOW = '''async(id)=>{const A=window.OKD_ONLINE.api, db=()=>JSON.parse(localStorage.getItem("%s")), R=()=>db().routes2.find(x=>x.id===id), loc={lat:-32.9,lon:-68.8};
  const km0=db().vehicles.find(v=>v.id==="vh-1").current_km; await A.startRoute(id, km0); const s0=R().stops[0].id; try{await A.arriveStop(s0, loc, "ar-"+s0);}catch(e){}
  await A.setStopOutcome(s0,"ENTREGADO",null,null,"o-"+s0,{evidence:{receiver_name:"Receptor QA", receiver_cuil:"20123456786", cuil:"20123456786", signature_png_b64:"iVBORw0KGgo="}, location:loc});
  await A.addInternalStop(id, {client_name:"Banco (retiro) QA", action:"RETIRO", bultos:1}, R().version, "add-"+id);
  const pend=R().stops.filter(s=>s.outcome==="PENDIENTE").sort((x,y)=>x.sequence_number-y.sequence_number).map(s=>s.id), fut=pend.slice(1); await A.reorderInternalStops(id, fut.slice().reverse(), R().version, "ord-"+id);   // la parada ACTUAL no se incluye (CURRENT_STOP_FIXED): solo las futuras
  for(const s of R().stops.filter(x=>x.outcome==="PENDIENTE")){ try{await A.arriveStop(s.id, loc, "ar-"+s.id);}catch(e){}
    await A.setStopOutcome(s.id,"ENTREGADO",null,null,"o-"+s.id,{evidence:{receiver_name:"Receptor QA", receiver_cuil:"20123456786", cuil:"20123456786", signature_png_b64:"iVBORw0KGgo="}, location:loc}); }
  await A.arriveDepot(id, loc, "dep-"+id); await A.finalizeRoute(id, km0+12);
  const r=R(); return {number:r.number, op:r.operational_status, apr:r.approval_status, version:r.version, approvals:(db().approvals||[]).filter(a=>a.route_id===id)};}''' % K
ROWS = '()=>[...document.querySelectorAll("#rqTable tbody tr[data-id]")].map(t=>({id:t.dataset.id, internal:t.dataset.internal==="1", txt:t.innerText.replace(/\\s+/g," "), revisar:!!t.querySelector("[data-irv]"), decidir:!!t.querySelector("[data-d],[data-irok]"), cancelar:!!t.querySelector("[data-cancel]")}))'
async def relog(pg, email): await pg.evaluate('async()=>{try{await window.OKD_ONLINE.api.signOut()}catch(e){}}'); await dp.login(pg, email); await pg.wait_for_timeout(500)
async def tab(pg, f):
    await pg.evaluate('()=>{location.hash="#/solicitudes"}'); await pg.wait_for_timeout(1300)
    if not await pg.locator(f'#rqFilters [data-f="{f}"]').count(): return None   # el rol no tiene esa pantalla / pestaña
    await pg.click(f'#rqFilters [data-f="{f}"]'); await pg.wait_for_timeout(700); return await pg.evaluate(ROWS)
BELL = '()=>{const b=document.querySelector(".apb"); if(!b) return null; const n=b.querySelector(".apb-n"); return {n:n?Number(n.dataset.n):0, items:[...b.querySelectorAll(".apb-it span")].map(x=>x.textContent)}}'
async def bell(pg):
    await pg.evaluate('()=>dispatchEvent(new Event("okd:approvals-changed"))'); await pg.wait_for_timeout(900); return await pg.evaluate(BELL)
async def review(pg, aid):   # resolver por la API de la app (mismo circuito que el botón)
    return await pg.evaluate('async([id])=>{try{await window.OKD_ONLINE.api.reviewApproval(id,"APPROVED","x"); return "PERMITIDO"}catch(e){return e.code||e.message}}', [aid])
async def main():
    os.makedirs(OUT, exist_ok=True); srv = dp.serve()
    try:
        async with async_playwright() as p:
            b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
            try:
                pg = await (await b.new_context(viewport={'width': 1366, 'height': 768})).new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
                await pg.goto(f'http://127.0.0.1:{dp.PORT}/'); await pg.evaluate('()=>localStorage.clear()'); await dp.login(pg, 'admin@okdespacho.demo'); await pg.evaluate(SETUP)
                ids = [await pg.evaluate(PUB, f'qa-apr-{i}-{1000 + i}') for i in range(3)]
                await relog(pg, 'gabriel@okdespacho.demo'); fl = [await pg.evaluate(FLOW, i) for i in ids]
                a0 = fl[0]['approvals']
                res('AP-01 Gabriel termina la hoja con cambios: UNA solicitud PENDIENTE, dirigida a Leonardo, 2 modificaciones; la hoja queda COMPLETADA · PENDIENTE de aprobación',
                    len(a0) == 1 and a0[0]['status'] == 'PENDING' and a0[0]['supervisor_user_id'] == 'u-leo' and a0[0]['modification_count'] == 2 and fl[0]['op'] == 'COMPLETADA' and fl[0]['apr'] == 'PENDIENTE',
                    {'hoja': fl[0]['number'], 'solicitudes': len(a0), 'modificaciones': a0 and a0[0]['modification_count'], 'estado_hoja': (fl[0]['op'], fl[0]['apr'])})
                # Gabriel: la ve en MIS SOLICITUDES, sin decidir ni cancelar; el servidor no le deja aprobar
                mias = await tab(pg, 'mias'); gm = [x for x in (mias or []) if x['internal']]; g_api = await review(pg, a0[0]['id']); bg = await bell(pg)
                res('AP-06 Gabriel NO puede aprobar sus propios cambios: el servidor lo rechaza y la pantalla no le ofrece decidir ni cancelar (su rol no tiene la pantalla Solicitudes)',
                    g_api != 'PERMITIDO' and not any(x['revisar'] or x['decidir'] or x['cancelar'] for x in gm) and bg is None, {'pantalla_solicitudes': mias is not None, 'filas': len(gm), 'aprobar_propia': g_api, 'campana': bg})
                # Leonardo: PARA RESOLVER → REVISAR CAMBIOS
                await relog(pg, 'leonardo.qa@okdespacho.demo'); await pg.evaluate('()=>{location.hash="#/dashboard"}'); await pg.wait_for_timeout(1200); b0 = await bell(pg)
                await pg.screenshot(path=os.path.join(OUT, 'campana_leonardo.png'))
                await pg.click('.apb-btn'); await pg.wait_for_timeout(300); await pg.click(f'.apb-it[data-apr="{fl[1]["approvals"][0]["id"]}"]'); await pg.wait_for_timeout(2200)
                opened = await pg.evaluate('()=>{const b=document.querySelector(".irv-box"); const tr=b&&b.closest("tr").previousElementSibling; return {hash:location.hash, abierta:tr&&tr.dataset.id, txt:b&&b.innerText.slice(0,40)}}')
                nleida = await pg.evaluate('(rid)=>(JSON.parse(localStorage.getItem("%s")).notifs||[]).filter(n=>n.user_id==="u-leo"&&n.route_id===rid&&n.type==="INTERNAL_ROUTE_APPROVAL_REQUEST").map(n=>!!(n.read_at||n.read))' % K, ids[1])
                res('AP-09 CAMPANA de Leonardo: contador 3 (sus pendientes) con hoja y transportista en cada aviso',
                    bool(b0) and b0['n'] == 3 and len(b0['items']) == 3 and all('Gabriel' in t for t in b0['items']) and any(fl[0]['number'] in t for t in b0['items']), b0)
                res('AP-10 tocar un aviso ABRE directamente esa solicitud (REVISAR CAMBIOS desplegado) y marca LEÍDA su notificación existente',
                    opened['abierta'] == fl[1]['approvals'][0]['id'] and 'apr=' in opened['hash'] and nleida == [True], {**opened, 'notificacion_leida': nleida})
                pr = await tab(pg, 'asignadas'); mine = [x for x in pr if x['internal']]
                row0 = next((x for x in mine if fl[0]['number'] in x['txt']), None)
                await pg.click(f'#rqTable tr[data-id="{a0[0]["id"]}"] [data-irv]'); await pg.wait_for_timeout(900)
                box = await pg.evaluate('()=>{const b=document.querySelector(".irv-box"); return b&&{txt:b.innerText.replace(/\\s+/g," "), marcas:[...b.querySelectorAll(".apr-mark")].map(m=>m.textContent), aprobar:!!b.querySelector("[data-irok]"), observar:!!b.querySelector("[data-irobs]")}}')
                await pg.screenshot(path=os.path.join(OUT, 'leonardo_para_resolver_revision.png'), full_page=True)
                res('AP-02 Leonardo la encuentra en PARA RESOLVER (Cambios de ruta interna · Gabriel · hoja) y REVISAR CAMBIOS muestra hoja, transportista, COMPLETADA · PENDIENTE, 2 modificaciones y la parada agregada',
                    len(mine) == 3 and bool(row0) and 'Cambios de ruta interna' in row0['txt'] and 'Gabriel' in row0['txt'] and row0['revisar'] and bool(box)
                    and all(t in box['txt'] for t in ['HOJA ' + fl[0]['number'], 'Gabriel', 'COMPLETADA · PENDIENTE DE APROBACIÓN', '2 modificación']) and any('PARADA AGREGADA' in m for m in box['marcas']) and box['aprobar'] and box['observar'],
                    {'fila': row0 and row0['txt'][:120], 'revision': box and box['txt'][:160], 'marcas': box and box['marcas']})
                # OBSERVAR: sin motivo → no; con motivo → OBSERVED + hoja OBSERVADA + motivo + auditoría
                await pg.click('.irv-box [data-irobs]'); await pg.wait_for_timeout(600)
                st_sin = await pg.evaluate(f'()=>JSON.parse(localStorage.getItem("{K}")).approvals.find(a=>a.id==="{a0[0]["id"]}").status'); msg_sin = await pg.evaluate('()=>(document.querySelector(".up-msg.err,.msg.err,[class*=err]")||{}).textContent||""')
                await pg.click(f'#rqTable tr[data-id="{a0[0]["id"]}"] [data-irv]'); await pg.wait_for_timeout(800)
                if not await pg.locator('.irv-box').count(): await pg.click(f'#rqTable tr[data-id="{a0[0]["id"]}"] [data-irv]'); await pg.wait_for_timeout(800)
                await pg.fill('.irv-box [data-irnote]', 'Falta justificar la parada agregada en el banco'); await pg.click('.irv-box [data-irobs]'); await pg.wait_for_timeout(900)
                d = await pg.evaluate(f'()=>{{const d=JSON.parse(localStorage.getItem("{K}")); const a=d.approvals.find(x=>x.id==="{a0[0]["id"]}"), r=d.routes2.find(x=>x.id==="{ids[0]}"); return {{st:a.status, nota:a.review_note, por:a.reviewed_by, hoja:r.approval_status, op:r.operational_status, audit:(d.audit||[]).filter(x=>x.target_id==="{ids[0]}"&&/INTERNAL_ROUTE_OBSERVED/.test(x.action)).length}}}}')
                res('AP-03 OBSERVAR sin motivo NO resuelve; con motivo: solicitud OBSERVED, hoja OBSERVADA (sigue COMPLETADA), motivo y auditoría registrados',
                    st_sin == 'PENDING' and d['st'] == 'OBSERVED' and d['nota'].startswith('Falta justificar') and d['por'] == 'u-leo' and d['hoja'] == 'OBSERVADA' and d['op'] == 'COMPLETADA' and d['audit'] >= 1, {'sin_motivo': st_sin, **d})
                b1 = await bell(pg)
                # APROBAR la segunda (desde la pantalla) y DOBLE resolución rechazada
                a1 = fl[1]['approvals'][0]['id']; await tab(pg, 'asignadas'); await pg.click(f'#rqTable tr[data-id="{a1}"] [data-irv]'); await pg.wait_for_timeout(800); await pg.click('.irv-box [data-irok]'); await pg.wait_for_timeout(900)
                d1 = await pg.evaluate(f'()=>{{const d=JSON.parse(localStorage.getItem("{K}")); const a=d.approvals.find(x=>x.id==="{a1}"), r=d.routes2.find(x=>x.id==="{ids[1]}"); return {{st:a.status, por:a.reviewed_by, hoja:r.approval_status}}}}')
                twice = await review(pg, a1); pr2 = await tab(pg, 'asignadas'); b2 = await bell(pg)
                res('AP-04 APROBAR: solicitud APPROVED por Leonardo, hoja APROBADA; una SEGUNDA resolución se rechaza (NOT_PENDING) y deja de figurar en PARA RESOLVER',
                    d1 == {'st': 'APPROVED', 'por': 'u-leo', 'hoja': 'APROBADA'} and twice == 'NOT_PENDING' and not any(x['id'] == a1 for x in pr2), {**d1, 'segunda': twice})
                # OTRO Superior: no la ve en ninguna pestaña y no puede resolverla
                a2 = fl[2]['approvals'][0]['id']; await relog(pg, 'otro.superior.qa@okdespacho.demo'); bo = await bell(pg)
                vis = {f: [x for x in (await tab(pg, f) or []) if x['internal']] for f in ('asignadas', 'pendientes', 'todas')}; o_api = await review(pg, a2)
                res('AP-05 OTRO Superior (aun con permiso de aprobar) NO ve la solicitud ajena en PARA RESOLVER / PENDIENTES DEL EQUIPO / TODAS y el servidor le RECHAZA resolverla',
                    all(len(v) == 0 for v in vis.values()) and o_api in ('FORBIDDEN', 'Sin permiso.') or (all(len(v) == 0 for v in vis.values()) and 'FORBIDDEN' in str(o_api)), {'visibles': {k: len(v) for k, v in vis.items()}, 'resolver': o_api})
                # ADMINISTRADOR GENERAL: acceso completo (la ve y la resuelve)
                await relog(pg, 'admin@okdespacho.demo'); ba = await bell(pg); todas = [x for x in await tab(pg, 'todas') if x['internal']]
                await pg.click(f'#rqTable tr[data-id="{a2}"] [data-irv]'); await pg.wait_for_timeout(800); await pg.click('.irv-box [data-irok]'); await pg.wait_for_timeout(900)
                d2 = await pg.evaluate(f'()=>{{const d=JSON.parse(localStorage.getItem("{K}")); const a=d.approvals.find(x=>x.id==="{a2}"); return {{st:a.status, por:a.reviewed_by}}}}')
                ba2 = await bell(pg)
                res('AP-07 el ADMINISTRADOR GENERAL conserva acceso completo: ve las 3 solicitudes en TODAS, revisa y APRUEBA la pendiente', len(todas) == 3 and d2['st'] == 'APPROVED' and d2['por'].startswith('u-admin'), {'en_todas': len(todas), **d2})
                # SIN duplicados: finalizar otra vez no crea otra solicitud
                await relog(pg, 'gabriel@okdespacho.demo'); again = await pg.evaluate('async(id)=>{await window.OKD_ONLINE.api.finalizeRoute(id, 999999); return (JSON.parse(localStorage.getItem("%s")).approvals||[]).filter(a=>a.route_id===id).length}' % K, ids[0])
                tot = await pg.evaluate('()=>{const a=JSON.parse(localStorage.getItem("%s")).approvals||[]; const c={}; a.forEach(x=>{c[x.route_id+"|"+x.route_version]=(c[x.route_id+"|"+x.route_version]||0)+1}); return Math.max(...Object.values(c))}' % K)
                drv = await pg.evaluate('()=>{const d=JSON.parse(localStorage.getItem("%s")); return {notifs:(d.notifs||[]).filter(n=>n.user_id==="u-gabriel"&&/INTERNAL_ROUTE_(APPROVED|OBSERVED)/.test(n.type)).length, correos:(d.outboxIR||[]).filter(m=>/INTERNAL_ROUTE_(APPROVED|OBSERVED)/.test(m.kind||m.type||"")).length, avisos_superior:(d.notifs||[]).filter(n=>n.type==="INTERNAL_ROUTE_APPROVAL_REQUEST").length}}' % K)
                res('AP-11 el CONTADOR baja al resolver: Leonardo 3 → 2 (observada) → 1 (aprobada); otro Superior sin avisos ajenos; Administrador 1 → 0',
                    b1 and b1['n'] == 2 and b2 and b2['n'] == 1 and (bo is None or bo['n'] == 0) and ba and ba['n'] == 1 and ba2 and ba2['n'] == 0, {'tras_observar': b1 and b1['n'], 'tras_aprobar': b2 and b2['n'], 'otro_superior': bo, 'admin': [ba and ba['n'], ba2 and ba2['n']]})
                res('AP-12 SIN avisos al TRANSPORTISTA por aprobar u observar (ni notificación ni correo); un solo aviso al Superior por hoja', drv['notifs'] == 0 and drv['correos'] == 0 and drv['avisos_superior'] == 3, drv)
                res('AP-08 SIN duplicados: volver a finalizar no crea otra solicitud (máximo 1 por hoja y versión)', again == 1 and tot == 1, {'tras_refinalizar': again, 'max_por_hoja_version': tot})
            finally: await b.close()
    finally: srv.terminate()
    print('TOTAL', sum(1 for r in R if r[1] == 'PASS'), 'PASS /', sum(1 for r in R if r[1] == 'FAIL'), 'FAIL · esperados', EXPECTED)
    return R
if __name__ == '__main__':
    try: rr = asyncio.run(main())
    except Exception as e: traceback.print_exc(); print('ERROR:', repr(e)); sys.exit(2)
    if len(rr) != EXPECTED: print('ERROR: se ejecutaron %d de %d' % (len(rr), EXPECTED)); sys.exit(2)
    sys.exit(1 if any(r[1] != 'PASS' for r in rr) else 0)
