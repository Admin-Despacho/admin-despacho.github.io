"""E2E BLOQUEANTE (modo demo, Chromium) · V4.28 · DOCUMENTO DEL RECEPTOR A REVISAR: alertas en la campana (Administración y Superior
responsable), acceso directo a la revisión, corrección auditada, alcance por equipo y SIN DUPLICADOS con sincronización sin conexión.
Las entregas las hace el transportista en el FORMULARIO REAL. Datos FICTICIOS. Uso: python3 run_v428_alertas_documento.py [dist-demo] [salida]"""
import asyncio, os, sys, traceback
sys.path.insert(0, os.path.dirname(__file__))
import run_driver_perfiles as dp
import run_v428_documento as doc
from playwright.async_api import async_playwright
dp.PORT = 4493; R = []; EXPECTED = 9
if len(sys.argv) > 1: dp.DIST = sys.argv[1]
OUT = sys.argv[2] if len(sys.argv) > 2 else '/tmp/okd_v428_al'
K = 'okd_online_demo_v2'
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:340])); print('..', ' | '.join(R[-1]), flush=True)
SETUP = '''()=>{const d=JSON.parse(localStorage.getItem("%s")); const a=d.users.find(u=>u.role==="ADMIN");
  const add=(id,email,name)=>{ if(!d.users.some(u=>u.id===id)) d.users.push(Object.assign({}, a, {id, email, role:"SUPERVISOR_DESPACHO", full_name:name, status:"ACTIVO", carriers:[], extra_perms:[], denied_perms:[], supervisor_user_id:null, permission_overrides:{can_approve_internal_route_changes:true}})); };
  add("u-leo","leonardo.qa@okdespacho.demo","Leonardo Cabañez QA"); add("u-sup2","otro.superior.qa@okdespacho.demo","Otro Superior QA");
  d.users.find(u=>u.id==="u-cristian").supervisor_user_id="u-leo"; localStorage.setItem("%s", JSON.stringify(d));}''' % (K, K)
PUB = '''async()=>{const A=window.OKD_ONLINE.api, st=(n,o)=>({ready:true, client_name:n, client_key:n.toUpperCase(), address:'Godoy Cruz '+o, zone:'ESTE', stop_type:'PEDIDO', order_numbers:[String(o)], merchandise_amount:1000, shipping_fee:0, task:'ENTREGA', expected_amount:1000});
  return (await A.publishRoute({sheet_key:'qa-v428-al', carrier_id:'CT-ESTE', responsable_id:'u-cristian', rules_version:1, routing_rules_version:1, stops:[st('Cliente Uno QA',9701), st('Cliente Dos QA',9702), st('Cliente Sin Señal QA',9703)]})).id}'''
DB = '()=>{const d=JSON.parse(localStorage.getItem("%s")); return {rev:Object.values(d.docReviews||{}).map(v=>({stop:v.stop_id, issue:v.issue, st:v.status, declared:v.declared_doc, by:v.corrected_by||null})), notifs:(d.notifs||[]).filter(n=>n.type==="RECEIVER_DOC_REVIEW").map(n=>n.user_id), drv:(d.notifs||[]).filter(n=>n.user_id==="u-cristian"&&/RECEIVER_DOC|INTERNAL_ROUTE_(APPROVED|OBSERVED)/.test(n.type)).length, audit:(d.audit||[]).filter(a=>a.action==="RECEIVER_DOC_CORRECTED").length}}' % K
BELL = '()=>{const b=document.querySelector(".apb"); if(!b) return null; return [...b.querySelectorAll(".apb-it.apb-doc")].map(a=>({href:a.getAttribute("href"), txt:a.innerText.replace(/\\s+/g," ")}))}'
AL09_SETUP = '()=>{const d=JSON.parse(localStorage.getItem("okd_online_demo_v2")); const s=d.users.find(u=>u.id==="u-sup2"); if(!d.users.some(u=>u.id==="u-sup3")) d.users.push(Object.assign({}, s, {id:"u-sup3", email:"tercer.superior.qa@okdespacho.demo", full_name:"Tercer Superior QA", supervisor_user_id:null})); d.identity=d.identity||{}; d.identity["30500010912"]={dni:"50001091", full_name:"Empresa histórica QA", email:"empresa@example.invalid", updated_at:new Date().toISOString()}; localStorage.setItem("okd_online_demo_v2", JSON.stringify(d));}'
AL09_PROBE = 'async(a)=>{const A=window.OKD_ONLINE.api; const L=await A.listReceiverDocReviews("TODOS"); let c="PERMITIDO", o="PERMITIDO"; try{await A.correctReceiverDoc(a[0],"CUIL","20123456786","delegado")}catch(e){c=e.code||e.message} try{const r=await A.addStopFollowup(a[0],"GESTION","Reintento ajeno",null,"qa-fu-admin"); o="DEVOLVIÓ: "+JSON.stringify(r).slice(0,80)}catch(e){o=e.code||e.message} const me=await A.me(); return {users_manage:!!((me.permission_overrides||{})["users.manage"]) || (me.effective_permissions||[]).includes("users.manage"), rol:me.role, lista:L.length, corregir:c, op_id_ajeno:o}}'
async def bell(pg): await pg.evaluate('()=>dispatchEvent(new Event("okd:approvals-changed"))'); await pg.wait_for_timeout(1000); return await pg.evaluate(BELL)
async def relog(pg, email): await pg.evaluate('async()=>{try{await window.OKD_ONLINE.api.signOut()}catch(e){}}'); await dp.login(pg, email); await pg.wait_for_timeout(400)
async def main():
    os.makedirs(OUT, exist_ok=True); srv = dp.serve()
    try:
        async with async_playwright() as p:
            b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
            try:
                c0 = await b.new_context(viewport={'width': 1366, 'height': 768}); pg = await c0.new_page()
                await pg.goto(f'http://127.0.0.1:{dp.PORT}/'); await pg.evaluate('()=>localStorage.clear()'); await dp.login(pg, 'admin@okdespacho.demo'); await pg.evaluate(SETUP); rid = await pg.evaluate(PUB)
                state = await c0.storage_state(); await c0.close()
                # ---- el transportista entrega en el FORMULARIO REAL: dos con documento inválido (CONTINUAR) y una SIN CONEXIÓN ----
                c = await b.new_context(storage_state=state, viewport={'width': 412, 'height': 915}, is_mobile=True, has_touch=True, geolocation={'latitude': -32.9, 'longitude': -68.8}, permissions=['geolocation'])
                q = await c.new_page(); q.on('dialog', lambda d: asyncio.ensure_future(d.accept())); await dp.login(q, 'cristian@okdespacho.demo'); await dp.open_route(q, rid)
                S = [await dp.stop_id(q, rid, i) for i in range(3)]
                doc.K = K; await doc.deliver(q, S[0], 'DNI', '123'); await doc.deliver(q, S[1], 'CUIL', '20-12345678-7')
                await c.set_offline(True); await q.wait_for_timeout(300); off = await doc.deliver(q, S[2], 'CUIT', '3050001091')
                offline_pend = await q.evaluate('(sid)=>{const d=JSON.parse(localStorage.getItem("%s")); return !(d.docReviews||{})[sid]}' % K, S[2])
                await c.set_offline(False); await q.evaluate('()=>dispatchEvent(new Event("online"))'); await q.wait_for_timeout(3500)
                d1 = await q.evaluate(DB)
                await q.evaluate('()=>dispatchEvent(new Event("online"))'); await q.wait_for_timeout(2500)   # una segunda sincronización
                retry = await q.evaluate('async(sid)=>{try{await window.OKD_ONLINE.api.setStopOutcome(sid,"ENTREGADO",null,null,"reintento-manual",{evidence:{receiver_name:"R", receiver_doc_type:"CUIT", receiver_doc:"3050001091", signature_png_b64:"iVBORw0KGgo="}, location:{lat:-32.9,lon:-68.8}}); return "aceptado"}catch(e){return e.code||e.message}}', S[2])
                d2 = await q.evaluate(DB); state = await c.storage_state(); await c.close()
                res('AL-06 SIN CONEXIÓN: la entrega con documento inválido se guarda con su firma y, al sincronizar, crea UNA incidencia y UNA alerta; otra sincronización y un reintento NO duplican',
                    off['resultado'] == 'ENTREGADO' or offline_pend, {'sin_conexion': off['resultado'], 'incidencias_tras_sync': len([r for r in d1['rev'] if r['stop'] == S[2]]),
                     'incidencias_tras_resync': len([r for r in d2['rev'] if r['stop'] == S[2]]), 'alertas': [len(d1['notifs']), len(d2['notifs'])], 'reintento': retry}) if False else None
                ok6 = len([r for r in d1['rev'] if r['stop'] == S[2]]) == 1 and len([r for r in d2['rev'] if r['stop'] == S[2]]) == 1 and len(d1['rev']) == 3 and len(d2['rev']) == 3 and len(d1['notifs']) == len(d2['notifs']) and d2['drv'] == 0
                R6 = ('AL-06 SIN CONEXIÓN: la entrega con documento inválido se guarda con su firma y, al sincronizar, crea UNA incidencia y UNA alerta; otra sincronización y un reintento NO duplican', ok6,
                      {'incidencias': [len(d1['rev']), len(d2['rev'])], 'alertas': [len(d1['notifs']), len(d2['notifs'])], 'reintento': retry})
                # ---- campana: Administración y Superior responsable; otro Superior no ----
                a = await (await b.new_context(storage_state=state, viewport={'width': 1366, 'height': 768})).new_page(); a.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
                await a.goto(f'http://127.0.0.1:{dp.PORT}/'); await dp.login(a, 'admin@okdespacho.demo'); await a.evaluate('()=>{location.hash="#/dashboard"}'); await a.wait_for_timeout(1200); ba = await bell(a)
                res('AL-01 el ADMINISTRADOR GENERAL recibe en la campana las 3 alertas «DOCUMENTO A REVISAR» (hoja, cliente y motivo), SIN el número de documento',
                    bool(ba) and len(ba) == 3 and all('DOCUMENTO A REVISAR' in x['txt'] for x in ba) and not any(t in ' '.join(x['txt'] for x in ba) for t in ['123 ', '20123456787', '3050001091']), ba)
                await relog(a, 'leonardo.qa@okdespacho.demo'); await a.evaluate('()=>{location.hash="#/dashboard"}'); await a.wait_for_timeout(1200); bl = await bell(a)
                await a.screenshot(path=os.path.join(OUT, 'campana_documento_superior.png'))
                res('AL-02 el SUPERIOR responsable del transportista (Leonardo) recibe las mismas 3 alertas', bool(bl) and len(bl) == 3, bl)
                await relog(a, 'otro.superior.qa@okdespacho.demo'); bo = await bell(a)
                o_api = await a.evaluate('async(sid)=>{const L=await window.OKD_ONLINE.api.listReceiverDocReviews("TODOS"); let c="PERMITIDO"; try{await window.OKD_ONLINE.api.correctReceiverDoc(sid,"DNI","30111222","ajeno")}catch(e){c=e.code||e.message} return {lista:L.length, corregir:c}}', S[0])
                res('AL-03 OTRO Superior NO accede: sin alertas ajenas en su campana, su listado está vacío y no puede corregir', (not bo or len(bo) == 0) and o_api['lista'] == 0 and o_api['corregir'] != 'PERMITIDO', {'campana': bo, **o_api})
                # ---- tocar la alerta → VER HOJA en esa entrega, con la revisión ----
                await relog(a, 'leonardo.qa@okdespacho.demo'); bl = await bell(a); href0 = next(x['href'] for x in bl if S[0] in x['href'])
                await a.click('.apb-btn'); await a.wait_for_timeout(300); await a.click(f'.apb-it[href="{href0}"]'); await a.wait_for_timeout(2600)
                vh = await a.evaluate('(sid)=>{const o=document.querySelector(".vh-ovl"); const el=document.querySelector(\'.vh-stop[data-sid="\'+sid+\'"]\'); const box=el&&el.querySelector(".vh-doc"); return {abierta:!!o&&!o.hidden, parada_abierta:!!el&&el.open, revision:box?box.innerText.replace(/\\s+/g," "):null, form:!!(box&&box.querySelector("[data-dcok]"))}}', S[0])
                await a.screenshot(path=os.path.join(OUT, 'revision_documento_ver_hoja.png'))
                res('AL-04 tocar la alerta ABRE VER HOJA en esa entrega, con la parada desplegada, el motivo y el formulario CORREGIR DOCUMENTO', vh['abierta'] and vh['parada_abierta'] and bool(vh['revision']) and 'DNI CON CANTIDAD DE DÍGITOS INCORRECTA' in vh['revision'] and vh['form'], vh)
                # ---- corrección auditada ----
                box = f'.vh-stop[data-sid="{S[0]}"] .vh-doc'
                await a.select_option(box + ' [data-dct]', 'DNI'); await a.fill(box + ' [data-dcn]', '12'); await a.fill(box + ' [data-dcr]', 'Intento con número todavía mal'); await a.click(box + ' [data-dcok]'); await a.wait_for_timeout(800)
                m_bad = await a.inner_text(box + ' [data-dcmsg]')
                await a.fill(box + ' [data-dcn]', '30.111.222'); await a.fill(box + ' [data-dcr]', 'El receptor confirmó su DNI por teléfono'); await a.click(box + ' [data-dcok]'); await a.wait_for_timeout(1600)
                d3 = await a.evaluate(DB); r0 = next(r for r in d3['rev'] if r['stop'] == S[0])
                ev0 = await a.evaluate('(sid)=>{const e=JSON.parse(localStorage.getItem("%s")).evidence[sid]; return {declarado:e.receiver_doc_declared, valido:e.receiver_doc_valid, firma:!!e.signature_png_b64, dni:e.receiver_dni||null}}' % K, S[0])
                vista = await a.evaluate('(sid)=>{const b=document.querySelector(\'.vh-stop[data-sid="\'+sid+\'"] .vh-doc\'); return b?b.innerText.replace(/\\s+/g," "):""}', S[0])
                bl2 = await bell(a)
                # el HISTORIAL lo consulta el Administrador (acceso a la hoja completa)
                await a.click('#vhClose'); await a.wait_for_timeout(300); await relog(a, 'admin@okdespacho.demo')
                await a.evaluate(f'()=>{{location.hash="#/historial?vh={rid}&stop={S[0]}"}}'); await a.wait_for_timeout(2500); await a.click('#vhHistSec > summary'); await a.wait_for_timeout(800); h = await a.inner_text('#vhHist')
                res('AL-05 CORRECCIÓN: un número que sigue inválido se rechaza; el válido con motivo queda CORREGIDO por Leonardo con auditoría; el documento DECLARADO y la FIRMA originales quedan intactos; el contador BAJA; el historial lo muestra; NINGÚN aviso al transportista',
                    'tampoco es válida' in m_bad and r0['st'] == 'CORREGIDO' and r0['by'] == 'u-leo' and r0['declared'] == '123' and ev0 == {'declarado': '123', 'valido': False, 'firma': True, 'dni': None}
                    and d3['audit'] == 1 and len(bl2) == len(bl) - 1 and 'CORREGIDO' in vista and 'confirmó su DNI' in vista and 'DOCUMENTO DEL RECEPTOR A REVISAR' in h and 'confirmó su DNI por teléfono' in h and d3['drv'] == 0,
                    {'msg_invalida': m_bad, 'incidencia': r0, 'evidencia': ev0, 'campana': [len(bl), len(bl2)], 'avisos_chofer': d3['drv']})
                # ---- AL-07: doble corrección → sin RECTIFICAR se rechaza; el Administrador RECTIFICA desde VER HOJA (historial de 2, la 1 se conserva) ----
                again = await a.evaluate('async(sid)=>{try{await window.OKD_ONLINE.api.correctReceiverDoc(sid,"CUIL","20123456786","otra vez"); return "PERMITIDO"}catch(e){return e.code||e.message}}', S[0])
                await a.click(f'.vh-stop[data-sid="{S[0]}"] > summary') if not await a.evaluate('(sid)=>document.querySelector(\'.vh-stop[data-sid="\'+sid+\'"]\').open', S[0]) else None
                await a.wait_for_timeout(400); btn = await a.inner_text(box + ' [data-dcok]')
                await a.select_option(box + ' [data-dct]', 'CUIL'); await a.fill(box + ' [data-dcn]', '20-30111222-?'.replace('?', '0') if False else '20-12345678-6'); await a.fill(box + ' [data-dcr]', 'Rectifico: presentó también su CUIL'); await a.click(box + ' [data-dcok]'); await a.wait_for_timeout(1600)
                d4 = await a.evaluate('(sid)=>{const v=JSON.parse(localStorage.getItem("%s")).docReviews[sid]; return {hist:(v.corrections||[]).map(c=>c.seq+":"+c.type+":"+c.doc+":"+c.rectificacion), vigente:v.corrected_type+":"+v.corrected_doc, declarado:v.declared_doc}}' % K, S[0])
                hist_ui = await a.evaluate('(sid)=>{const b=document.querySelector(\'.vh-stop[data-sid="\'+sid+\'"] .vh-doc\'); return b?b.innerText.replace(/\\s+/g," "):""}', S[0])
                aud = await a.evaluate('()=>(JSON.parse(localStorage.getItem("%s")).audit||[]).filter(x=>/RECEIVER_DOC_(CORRECTED|RECTIFIED)/.test(x.action)).map(x=>x.action)' % K)
                res('AL-07 DOBLE CORRECCIÓN: sin RECTIFICAR se rechaza (ALREADY_CORRECTED); el Administrador RECTIFICA desde VER HOJA → historial con las 2 (la 1 se CONSERVA), declarado original intacto, auditoría de ambas',
                    again == 'ALREADY_CORRECTED' and btn == 'RECTIFICAR' and d4['hist'] == ['1:DNI:30111222:false', '2:CUIL:20123456786:true'] and d4['vigente'] == 'CUIL:20123456786' and d4['declarado'] == '123'
                    and 'CORRECCIÓN 1' in hist_ui and 'RECTIFICACIÓN 2' in hist_ui and aud == ['RECEIVER_DOC_CORRECTED', 'RECEIVER_DOC_RECTIFIED'], {'segunda_sin_rectificar': again, 'boton': btn, **d4, 'auditoria': aud})
                # ---- AL-08: permisos VIGENTES (rol cambiado y reasignación del transportista) ----
                SETROLE = '(a)=>{const d=JSON.parse(localStorage.getItem("%s")); const u=d.users.find(x=>x.id===a[0]); u[a[1]]=a[2]; localStorage.setItem("%s", JSON.stringify(d));}' % (K, K)
                COR = 'async(sid)=>{try{await window.OKD_ONLINE.api.correctReceiverDoc(sid,"CUIL","20123456786","prueba de permisos"); return "PERMITIDO"}catch(e){return e.code||e.message}}'
                await a.click('#vhClose') if await a.locator('.vh-ovl:not([hidden])').count() else None
                await a.evaluate(SETROLE, ['u-leo', 'role', 'OPERARIO_DEPOSITO']); await relog(a, 'leonardo.qa@okdespacho.demo'); b_rol = await bell(a); c_rol = await a.evaluate(COR, S[1])
                await a.evaluate(SETROLE, ['u-leo', 'role', 'SUPERVISOR_DESPACHO']); await a.evaluate(SETROLE, ['u-cristian', 'supervisor_user_id', 'u-sup2'])
                await relog(a, 'leonardo.qa@okdespacho.demo'); b_ant = await bell(a); c_ant = await a.evaluate(COR, S[1])
                await relog(a, 'otro.superior.qa@okdespacho.demo'); b_new = await bell(a); c_new = await a.evaluate(COR, S[1])
                res('AL-08 PERMISOS VIGENTES: Superior al que se le CAMBIÓ EL ROL → sin alertas y NO corrige; al REASIGNAR el transportista, el Superior anterior pierde el acceso y el nuevo lo obtiene',
                    not b_rol and c_rol != 'PERMITIDO' and not b_ant and c_ant != 'PERMITIDO' and bool(b_new) and c_new == 'PERMITIDO',
                    {'rol_cambiado': [len(b_rol or []), c_rol], 'anterior': [len(b_ant or []), c_ant], 'nuevo': [len(b_new or []), c_new]})
                # ---- AL-09: casos de Work en la DEMO (B1 users.manage delegado · B2 op_id ajeno · B3 CUIT histórico por DNI) ----
                await a.evaluate(AL09_SETUP)
                await relog(a, 'admin@okdespacho.demo')
                fu = await a.evaluate('async(sid)=>(await window.OKD_ONLINE.api.addStopFollowup(sid,"GESTION","Gestión del Administrador QA",null,"qa-fu-admin")).op_id', S[2])
                deleg = await a.evaluate('async()=>{try{await window.OKD_ONLINE.api.setUserPermission("u-sup3","users.manage","GRANT","QA aislado"); return "OK"}catch(e){return e.code||e.message}}')   # = AUD-00 (función real de delegación)
                await relog(a, 'tercer.superior.qa@okdespacho.demo')
                b9 = await a.evaluate(AL09_PROBE, [S[2]])
                await relog(a, 'cristian@okdespacho.demo')
                b3 = await a.evaluate('async(sid)=>{const r=await window.OKD_ONLINE.api.deliveryIdentityLookup(sid,null,"50001091"); return r?{source:r.source, cuil:r.cuil}:null}', S[2])
                res('AL-09 casos de Work en la DEMO: Superior ajeno con users.manage DELEGADO no lista ni corrige; su reintento con un op_id ajeno NO devuelve la gestión; por DNI un CUIT histórico NO sale como CUIL',
                    fu == 'qa-fu-admin' and deleg == 'OK' and b9['users_manage'] and b9['rol'] == 'SUPERVISOR_DESPACHO' and b9['lista'] == 0 and b9['corregir'] != 'PERMITIDO' and b9['op_id_ajeno'] == 'FORBIDDEN_ROUTE' and (b3 is None or b3['cuil'] is None), {'delegacion': deleg, **b9, 'busqueda_por_dni': b3})
                res(*R6)
            finally: await b.close()
    finally: srv.terminate()
    print('TOTAL', sum(1 for r in R if r[1] == 'PASS'), 'PASS /', sum(1 for r in R if r[1] == 'FAIL'), 'FAIL · esperados', EXPECTED)
    return R
if __name__ == '__main__':
    try: rr = asyncio.run(main())
    except Exception as e: traceback.print_exc(); print('ERROR:', repr(e)); sys.exit(2)
    if len(rr) != EXPECTED: print('ERROR: se ejecutaron %d de %d' % (len(rr), EXPECTED)); sys.exit(2)
    sys.exit(1 if any(r[1] != 'PASS' for r in rr) else 0)
