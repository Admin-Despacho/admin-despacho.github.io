"""E2E (demo, navegador REAL, vista MÓVIL 390×844, toques FÍSICOS) · ALARMA URGENTE DESDE LA SOLICITUD COMERCIAL.
Caso de la captura: un Operario Depósito abre una autorización PENDIENTE sin pedido ni hoja, genera la alarma desde su detalle, el destinatario
abre la autorización correcta desde el aviso y la atiende; el operario ve la atención y la solicitud conserva su estado comercial.
Además: cancelar no avisa, doble toque, respuesta perdida con reintento, resolución antes de confirmar, escalamiento, dos solicitudes del mismo
cliente. Datos de prueba de la demo; ningún envío real (la demo no tiene push ni correo)."""
import asyncio, os, sys, traceback
sys.path.insert(0, os.path.dirname(__file__))
import run_driver_perfiles as dp
import run_com_circuito as cc
from playwright.async_api import async_playwright
R = []; EXPECTED = 10
DIST = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), '..', '..', 'dist-demo'); dp.DIST = DIST; dp.PORT = 4530
OUT = sys.argv[2] if len(sys.argv) > 2 else '/tmp/okd_com_alarma_sol'
K = 'okd_online_demo_v2'
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:420])); print('..', ' | '.join(R[-1]), flush=True)
HIT = '''(e)=>{ const r=e.getBoundingClientRect(); const x=r.left+r.width/2, y=r.top+r.height/2;
  if (!r.width || !r.height || x<0 || x>innerWidth || y<0 || y>innerHeight) return null; const h=document.elementFromPoint(x,y); return h && (h===e || e.contains(h)) ? [x,y] : null; }'''
async def tap(pg, css):   # toque FÍSICO: lleva el elemento a la vista con la RUEDA (gesto real) y toca sus coordenadas si está al frente
    h = await pg.wait_for_selector(css, timeout=15000)
    for _ in range(12):
        xy = await h.evaluate(HIT)
        if xy: await pg.mouse.click(xy[0], xy[1]); return True
        r = await h.evaluate('(e)=>e.getBoundingClientRect().top'); await pg.mouse.move(195, 400); await pg.mouse.wheel(0, 300 if r > 400 else -300); await pg.wait_for_timeout(150)
    raise RuntimeError('no se pudo tocar físicamente ' + css)
DB = '(id)=>{const d=JSON.parse(localStorage.getItem("okd_online_demo_v2")); return {alarmas:(d.com.alarms||[]).filter(a=>a.request_id===id).map(a=>({id:a.id,status:a.status,sheet:a.sheet_key,ref:a.order_ref,attended_by:a.attended_by})), estado:(d.com.requests.find(q=>q.id===id)||{}).status}}'
ESTADO = '()=>{const e=document.querySelector("#rUrgent [data-urg-estado]"); return {estado:e?e.dataset.urgEstado:null, texto:e?e.innerText.replace(/\\s+/g," "):"", boton:!!document.getElementById("rUrgentBtn")}}'
async def nueva(pg, op, cliente='TECNO'):   # el Comercial carga una autorización SIN pedido (API real de la demo)
    return await pg.evaluate('''async(a)=>{const A=window.OKD_ONLINE.api, cl=(await A.comSearchClients(a.cl)).find(c=>c.selectable);
      const t=new Intl.DateTimeFormat("en-CA",{timeZone:"America/Argentina/Mendoza"}).format(new Date()); const d=new Date(t+"T12:00:00Z"); d.setUTCDate(d.getUTCDate()+7);
      const r=await A.comCreate("FINANCIACION", cl.id, "", {amount:250000, installments:1, first_due:d.toISOString().slice(0,10)}, null, a.op); return {id:r.id, number:r.number, cliente:cl.razon_social}}''', {'op': op, 'cl': cliente})
async def push_later(pg):   # el ofrecimiento de notificaciones de la app (modal): la persona toca «Más tarde» (no hay push real)
    for _ in range(3):
        b = await pg.query_selector('#pushLater')
        if not b: return
        xy = await b.evaluate(HIT)
        if xy: await pg.mouse.click(xy[0], xy[1]); await pg.wait_for_timeout(400); return
        await pg.wait_for_timeout(300)
async def relog(pg, email): await cc.relog(pg, email); await pg.wait_for_timeout(600); await push_later(pg)
async def abrir(pg, rid):   # Operario: Seguimiento → seleccionar la autorización
    await push_later(pg); await pg.evaluate('()=>{location.hash="#/autorizaciones?v=despacho"}'); await pg.wait_for_timeout(1500); await push_later(pg)
    await tap(pg, f'[data-select="{rid}"]'); await pg.wait_for_timeout(900)
async def main():
    os.makedirs(OUT, exist_ok=True); srv = dp.serve()
    try:
        async with async_playwright() as p:
            b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
            try:
                ctx = await b.new_context(viewport={'width': 390, 'height': 844}, is_mobile=True, has_touch=True); pg = await ctx.new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
                await pg.goto(f'http://127.0.0.1:{dp.PORT}/'); await pg.evaluate('()=>localStorage.clear()')
                await dp.login(pg, 'admin@okdespacho.demo'); await pg.wait_for_timeout(1000)
                await pg.evaluate('async()=>{await window.OKD_ONLINE.api.comSetAlarmSettings({initial_user:"u-wilfredo", escalation_users:["u-franco","u-gabriela"]})}')
                await relog(pg, 'comercial.montecaseros@okdespacho.demo')
                s1 = await nueva(pg, 'e2e-sol-1'); s2 = await nueva(pg, 'e2e-sol-2'); s3 = await nueva(pg, 'e2e-sol-3'); s4 = await nueva(pg, 'e2e-sol-4')
                await relog(pg, 'operario@okdespacho.demo')
                # ===== E01 · botón junto al estado; abrir y CANCELAR no genera avisos =====
                await abrir(pg, s1['id']); e0 = await pg.evaluate(ESTADO)
                junto = await pg.evaluate('()=>{const s=document.getElementById("rUrgent"); const h=s&&s.previousElementSibling; return !!h && h.classList.contains("sectionhead") && !!h.querySelector(".pill")}')
                await tap(pg, '#rUrgentBtn'); await pg.wait_for_selector('#uReason'); await pg.fill('#uReason', 'Cliente esperando en mostrador'); await tap(pg, '#uCancel'); await pg.wait_for_timeout(400)
                tras_cancelar = await pg.evaluate(DB, s1['id'])
                res('E01 [móvil · toque físico] AUTORIZACIÓN PENDIENTE SIN pedido ni hoja: el botón «Solicitar aprobación urgente» está junto al ESTADO; abrir y CANCELAR NO genera ningún aviso',
                    e0['boton'] and junto and tras_cancelar['alarmas'] == [], {'estado': e0, 'tras_cancelar': tras_cancelar})
                # ===== E02 · confirmar: «Alarma enviada · Pendiente de atención»; al reabrir se ve el estado vigente =====
                await tap(pg, '#rUrgentBtn'); await pg.wait_for_selector('#uReason'); await pg.fill('#uReason', 'El cliente espera la aprobación para retirar la mercadería')
                await pg.screenshot(path=os.path.join(OUT, '1_motivo_movil.png'))
                await tap(pg, '#uGo'); await pg.wait_for_timeout(1500)
                toast = await pg.evaluate('()=>[...document.querySelectorAll("#comToast .toast")].map(t=>t.textContent).join(" | ")')
                e2 = await pg.evaluate(ESTADO); await pg.screenshot(path=os.path.join(OUT, '2_alarma_enviada_movil.png'))
                await pg.reload(); await pg.wait_for_timeout(1200); await abrir(pg, s1['id']); e2b = await pg.evaluate(ESTADO); db2 = await pg.evaluate(DB, s1['id'])
                res('E02 [móvil] confirmar → «Alarma enviada · Pendiente de atención» (solo con el registro del servidor); al REABRIR se ve el estado vigente y ya no se ofrece otra; vinculada a la AUTORIZACIÓN (AUT-…)',
                    'Alarma enviada · Pendiente de atención' in toast and e2['estado'] == 'PENDIENTE' and 'Alarma enviada · Pendiente de atención' in e2['texto'] and e2b['estado'] == 'PENDIENTE' and not e2b['boton']
                    and len(db2['alarmas']) == 1 and db2['alarmas'][0]['sheet'] == 'AUTORIZACION' and db2['alarmas'][0]['ref'] == s1['number'], {'toast': toast[:80], 'reabierta': e2b, 'db': db2})
                # ===== E03 · DOBLE TOQUE =====
                await abrir(pg, s2['id']); await tap(pg, '#rUrgentBtn'); await pg.wait_for_selector('#uReason'); await pg.fill('#uReason', 'Doble toque sobre confirmar en el celular')
                xy = await (await pg.query_selector('#uGo')).evaluate(HIT); await pg.mouse.click(xy[0], xy[1]); await pg.mouse.click(xy[0], xy[1]); await pg.wait_for_timeout(1500)
                db3 = await pg.evaluate(DB, s2['id'])
                res('E03 [móvil] DOBLE TOQUE en confirmar: UNA sola alarma', len(db3['alarmas']) == 1, db3)
                # ===== E04 · respuesta PERDIDA: el motivo se conserva y el reintento NO duplica =====
                await abrir(pg, s3['id'])
                await pg.evaluate('()=>{const A=window.OKD_ONLINE.api, orig=A.comAlarmRaiseRequest.bind(A); window.__lose=1; A.comAlarmRaiseRequest=async(...x)=>{const r=await orig(...x); if(window.__lose>0){window.__lose--; throw new Error("Failed to fetch");} return r;}}')
                await tap(pg, '#rUrgentBtn'); await pg.wait_for_selector('#uReason'); await pg.fill('#uReason', 'Se cortó la conexión al confirmar la alarma')
                await tap(pg, '#uGo'); await pg.wait_for_timeout(1000)
                perdida = await pg.evaluate('()=>({msg:(document.getElementById("uMsg")||{}).innerText||"", motivo:(document.getElementById("uReason")||{}).value||""})')
                await tap(pg, '#uGo'); await pg.wait_for_timeout(1300); db4 = await pg.evaluate(DB, s3['id']); e4 = await pg.evaluate(ESTADO)
                res('E04 [móvil] RESPUESTA PERDIDA: se informa «sin respuesta», el MOTIVO se conserva; el reintento usa la MISMA operación → una sola alarma y recién ahí «Pendiente de atención»',
                    'SIN RESPUESTA' in perdida['msg'] and perdida['motivo'] == 'Se cortó la conexión al confirmar la alarma' and len(db4['alarmas']) == 1 and e4['estado'] == 'PENDIENTE', {'perdida': perdida['msg'][:90], 'db': db4})
                # ===== E05 · la autorización se RESOLVIÓ mientras escribía el motivo =====
                await abrir(pg, s4['id']); await tap(pg, '#rUrgentBtn'); await pg.wait_for_selector('#uReason'); await pg.fill('#uReason', 'Motivo escrito mientras otro la aprobaba')
                await pg.evaluate('(id)=>{const d=JSON.parse(localStorage.getItem("okd_online_demo_v2")); const q=d.com.requests.find(x=>x.id===id); q.status="APROBADA"; q.final_terms=q.current_terms; localStorage.setItem("okd_online_demo_v2", JSON.stringify(d));}', s4['id'])
                await tap(pg, '#uGo'); await pg.wait_for_timeout(1000)
                m5 = await pg.evaluate('()=>(document.getElementById("uMsg")||{}).innerText||""'); db5 = await pg.evaluate(DB, s4['id'])
                await tap(pg, '#uSee'); await pg.wait_for_timeout(900); pill5 = await pg.evaluate('()=>(document.querySelector("#comMain .sectionhead .pill")||{}).innerText||""')
                res('E05 [móvil] la autorización se RESOLVIÓ antes de confirmar: NO se envía; se informa el estado vigente (APROBADA) y se puede ver',
                    'ya no está pendiente' in m5 and 'APROBADA' in m5 and db5['alarmas'] == [] and pill5 != '', {'mensaje': m5[:120], 'estado': pill5})
                # ===== E06 · el DESTINATARIO abre la autorización CORRECTA desde el aviso y la ATIENDE =====
                await relog(pg, 'wilfredo@okdespacho.demo'); await pg.wait_for_timeout(1500)
                await pg.evaluate('async()=>{ if(window.__okdComAlarm&&window.__okdComAlarm.poll) await window.__okdComAlarm.poll(); }'); await pg.wait_for_timeout(600)
                card = await pg.evaluate('(n)=>{const c=[...document.querySelectorAll("#comAlarm .al-card")].find(x=>x.innerText.includes(n)); return c?c.innerText.replace(/\\s+/g," "):null}', s1['number'])
                await pg.screenshot(path=os.path.join(OUT, '3_aviso_destinatario_movil.png'))
                alarm1 = (await pg.evaluate(DB, s1['id']))['alarmas'][0]['id']
                await tap(pg, f'[data-al-open-req="{alarm1}"]'); await pg.wait_for_timeout(1500)
                abierta = await pg.evaluate('()=>{const s=document.querySelector("[data-alarma-sol]"); return s?{id:s.dataset.alarmaSol, txt:s.innerText.replace(/\\s+/g," ").slice(0,160)}:null}')
                await pg.screenshot(path=os.path.join(OUT, '4_autorizacion_desde_alarma_movil.png'))
                await pg.evaluate('()=>{const x=document.querySelector("#comAlarm [data-al-expand]"); if(x) x.click()}'); await pg.wait_for_timeout(400)
                await tap(pg, f'#comAlarm [data-al-attend="{alarm1}"]'); await pg.wait_for_timeout(1500); db6 = await pg.evaluate(DB, s1['id'])
                res('E06 [móvil] el DESTINATARIO configurado ve el aviso que nombra la AUTORIZACIÓN, abre ESA autorización desde el aviso y la ATIENDE (queda registrado quién)',
                    card and ('autorización ' + s1['number']) in card and abierta and abierta['id'] == s1['id'] and db6['alarmas'][0]['status'] == 'ATENDIDA' and db6['alarmas'][0]['attended_by'] == 'u-wilfredo',
                    {'aviso': (card or '')[:120], 'abierta': abierta, 'db': db6})
                # ===== E07 · el OPERARIO ve la atención registrada; la solicitud CONSERVA su estado comercial =====
                await relog(pg, 'operario@okdespacho.demo'); await abrir(pg, s1['id']); e7 = await pg.evaluate(ESTADO)
                pill7 = await pg.evaluate('()=>(document.querySelector("#comMain .sectionhead .pill")||{}).innerText||""'); db7 = await pg.evaluate(DB, s1['id'])
                await pg.screenshot(path=os.path.join(OUT, '5_operario_ve_atencion_movil.png'))
                res('E07 [móvil] al volver al detalle el OPERARIO ve «Alarma atendida · por Wilfredo · fecha y hora»; la autorización CONSERVA su estado comercial (pendiente: atender no es aprobar)',
                    e7['estado'] == 'ATENDIDA' and 'Wilfredo' in e7['texto'] and db7['estado'] == 'PENDIENTE' and pill7 != '', {'estado': e7, 'comercial': db7['estado']})
                # ===== E08 · ESCALAMIENTO por falta de atención (visible en el detalle) =====
                await pg.evaluate('(id)=>{const d=JSON.parse(localStorage.getItem("okd_online_demo_v2")); (d.com.alarms||[]).filter(a=>a.request_id===id).forEach(a=>{a.escalate_at=new Date(Date.now()-1000).toISOString()}); localStorage.setItem("okd_online_demo_v2", JSON.stringify(d));}', s2['id'])
                await abrir(pg, s2['id']); e8 = await pg.evaluate(ESTADO)
                esc8 = await pg.evaluate('(id)=>{const d=JSON.parse(localStorage.getItem("okd_online_demo_v2")); const a=(d.com.alarms||[]).find(x=>x.request_id===id); return {escalada:!!a.escalated_at, a:a.escalated_to, avisos:(d.com.alarmNotifs||[]).filter(n=>n.type==="COM_ALARMA_ESCALADA").map(n=>n.body).filter(b=>b.includes(a.order_ref))}}', s2['id'])
                res('E08 sin atención: el ESCALAMIENTO vigente la escala a los destinatarios configurados con avisos que nombran la AUTORIZACIÓN; el detalle lo muestra',
                    'ESCALADA' in e8['texto'] and esc8['escalada'] and set(esc8['a']) >= {'u-franco', 'u-gabriela'} and esc8['avisos'] and all(x.startswith('Autorización ') for x in esc8['avisos']), {'detalle': e8['texto'][:120], 'escalamiento': esc8})
                # ===== E09 · dos autorizaciones del MISMO cliente: alarmas distintas, cada una con su número =====
                d9 = [await pg.evaluate(DB, s['id']) for s in (s1, s2, s3)]
                ids = [x['alarmas'][0]['id'] for x in d9]; refs = [x['alarmas'][0]['ref'] for x in d9]
                res('E09 tres autorizaciones del MISMO cliente: alarmas DISTINTAS, cada una con su número AUT-… (se identifican y se atienden por separado)',
                    len(set(ids)) == 3 and refs == [s1['number'], s2['number'], s3['number']] and len({s1['cliente'], s2['cliente'], s3['cliente']}) == 1, {'refs': refs})
                # ===== E10 · CASO DE WORK en el navegador: A (REVISAR) y B (Seguimiento) COMPARTEN pedido y cliente =====
                await relog(pg, 'comercial.montecaseros@okdespacho.demo')
                ped = '27999'
                sB = await pg.evaluate('''async(p)=>{const A=window.OKD_ONLINE.api, cl=(await A.comSearchClients("TECNO")).find(c=>c.selectable); const t=new Intl.DateTimeFormat("en-CA",{timeZone:"America/Argentina/Mendoza"}).format(new Date()); const d=new Date(t+"T12:00:00Z"); d.setUTCDate(d.getUTCDate()+7);
                  const r=await A.comCreate("FINANCIACION", cl.id, p, {amount:300000, installments:1, first_due:d.toISOString().slice(0,10)}, null, "e2e-sol-B"); return {id:r.id, number:r.number}}''', ped)
                sA = await pg.evaluate('''async(p)=>{const A=window.OKD_ONLINE.api, cl=(await A.comSearchClients("TECNO")).find(c=>c.selectable); const t=new Intl.DateTimeFormat("en-CA",{timeZone:"America/Argentina/Mendoza"}).format(new Date()); const d=new Date(t+"T12:00:00Z"); d.setUTCDate(d.getUTCDate()+7);
                  const r=await A.comCreate("FINANCIACION", cl.id, p, {amount:300000, installments:1, first_due:d.toISOString().slice(0,10)}, null, "e2e-sol-A"); return {id:r.id, number:r.number}}''', ped)
                await relog(pg, 'operario@okdespacho.demo')
                await pg.evaluate('(p)=>{const d=JSON.parse(localStorage.getItem("okd_online_demo_v2")); d.reservations=d.reservations||{}; d.reservations[p]={sheet_key:"HOJA-E2E"}; localStorage.setItem("okd_online_demo_v2", JSON.stringify(d));}', ped)
                await pg.reload(); await pg.wait_for_timeout(1200); await push_later(pg)
                rev = await pg.evaluate('async(p)=>await window.OKD_ONLINE.api.comAlarmRaise(p, "HOJA-E2E", "", "", "REVISAR desde la hoja para el pedido compartido", "e2e-rev-A")', ped)
                await abrir(pg, sB['id']); await tap(pg, '#rUrgentBtn'); await pg.wait_for_selector('#uReason'); await pg.fill('#uReason', 'Seguimiento para la otra autorización del mismo pedido'); await tap(pg, '#uGo'); await pg.wait_for_timeout(1500)
                eB = await pg.evaluate(ESTADO); dA = await pg.evaluate(DB, sA['id']); dB = await pg.evaluate(DB, sB['id'])
                aA, aB = (dA['alarmas'] or [{}])[0].get('id'), (dB['alarmas'] or [{}])[0].get('id')
                await relog(pg, 'wilfredo@okdespacho.demo'); await pg.wait_for_timeout(1200)
                await pg.evaluate('async()=>{ if(window.__okdComAlarm&&window.__okdComAlarm.poll) await window.__okdComAlarm.poll(); }'); await pg.wait_for_timeout(600)
                await pg.screenshot(path=os.path.join(OUT, '6_caso_AB_dos_avisos_movil.png'))
                abre = {}
                for quien, al in (('A', aA), ('B', aB)):
                    await pg.evaluate('()=>{const x=document.querySelector("#comAlarm [data-al-expand]"); if(x) x.click()}'); await pg.wait_for_timeout(400)
                    await tap(pg, f'[data-al-open-req="{al}"]'); await pg.wait_for_timeout(1300)
                    abre[quien] = await pg.evaluate('()=>(document.querySelector("[data-alarma-sol]")||{dataset:{}}).dataset.alarmaSol||null')
                await pg.evaluate('()=>{const x=document.querySelector("#comAlarm [data-al-expand]"); if(x) x.click()}'); await pg.wait_for_timeout(400)
                await tap(pg, f'#comAlarm [data-al-attend="{aA}"]'); await pg.wait_for_timeout(1300)
                fA = (await pg.evaluate(DB, sA['id']))['alarmas'][0]['status']; fB = (await pg.evaluate(DB, sB['id']))['alarmas'][0]['status']
                evid = {'pedido': ped, 'A': {'request_id': sA['id'], 'numero': sA['number'], 'alarma': aA, 'origen': 'REVISAR', 'abre': abre.get('A'), 'estado': fA},
                        'B': {'request_id': sB['id'], 'numero': sB['number'], 'alarma': aB, 'origen': 'Seguimiento', 'abre': abre.get('B'), 'estado': fB}}
                open(os.path.join(OUT, 'evidencia_caso_AB_navegador.json'), 'w').write(__import__('json').dumps(evid, indent=2, ensure_ascii=False))
                res('E10 [móvil] CASO DE WORK: A (REVISAR) y B (Seguimiento) con el MISMO pedido y cliente → dos alarmas DISTINTAS; el aviso de A abre A y el de B abre B; atender A deja B PENDIENTE',
                    bool(aA and aB) and aA != aB and dA['alarmas'][0]['sheet'] == 'HOJA-E2E' and dB['alarmas'][0]['sheet'] == 'AUTORIZACION' and eB['estado'] == 'PENDIENTE'
                    and abre.get('A') == sA['id'] and abre.get('B') == sB['id'] and fA == 'ATENDIDA' and fB == 'PENDIENTE_ATENCION', evid)
            finally: await b.close()
    finally: srv.terminate()
    print('TOTAL', sum(1 for r in R if r[1] == 'PASS'), 'PASS /', sum(1 for r in R if r[1] == 'FAIL'), 'FAIL · esperados', EXPECTED)
    return R
if __name__ == '__main__':
    try: rr = asyncio.run(main())
    except Exception as e: traceback.print_exc(); print('ERROR:', repr(e)); sys.exit(2)
    if len(rr) != EXPECTED: print('ERROR: se ejecutaron %d de %d' % (len(rr), EXPECTED)); sys.exit(2)
    sys.exit(1 if any(r[1] != 'PASS' for r in rr) else 0)
