"""E2E BLOQUEANTE (demo + Constructor REAL) · COMERCIAL + ALARMA V4 (auditoría Work sobre V3):
B-W06 intención estable y rechazos reales en REVISAR · B-W07 aviso contenido (1/3/6, textos largos, Android, teclado, zoom, minimizar sin atender)
B-W03 prioridad del PIN REAL y de formularios modales · O-W01 sin temporizadores tras destruir · HISTORIAL completo por vendedor · B-W04 módulo
COMERCIAL restringido desde la pantalla de Usuarios. Datos sintéticos. Sin envíos reales."""
import asyncio, os, sys, json, subprocess, traceback
sys.path.insert(0, os.path.dirname(__file__))
import run_saldo_revisar_noc as base
import run_driver_perfiles as dp
from playwright.async_api import async_playwright
R = []; EXPECTED = 11
DIST = sys.argv[1] if len(sys.argv) > 1 else os.path.join(base.ROOT, 'dist-demo'); dp.DIST = DIST; dp.PORT = base.PORT = 4385
OUT = sys.argv[2] if len(sys.argv) > 2 else '/tmp/okd_com_v4'
K = 'okd_online_demo_v2'
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:420])); print('..', ' | '.join(R[-1]), flush=True)
ST = '()=>{const s=window.__okdComAlarm||{}; return {ringing:!!s.ringing, beeps:s.beeps||0, supp:s.suppressed||null, min:!!s.minimized}}'
OV = '()=>{const e=document.getElementById("comAlarm"); return e?e.innerText.replace(/\\s+/g," ").trim():""}'
async def sync(src, dst): v = await src.evaluate('()=>localStorage.getItem("%s")' % K); await dst.evaluate('(v)=>localStorage.setItem("%s", v)' % K, v)
async def enter(pg, email): await pg.goto(f'http://127.0.0.1:{dp.PORT}/'); await base.login(pg, email); await pg.wait_for_timeout(1800)
async def poll(pg): await pg.evaluate('async()=>{ if(window.__okdComAlarm&&window.__okdComAlarm.poll) await window.__okdComAlarm.poll(); }'); await pg.wait_for_timeout(500)
def mutate(js): return '()=>{const d=JSON.parse(localStorage.getItem("%s")); %s; localStorage.setItem("%s", JSON.stringify(d));}' % (K, js, K)
LONG = 'Motivo extenso de prueba: el cliente solicita ampliar el plazo por demoras de cobranza de su propia cartera, con varias facturas vencidas y un pedido grande pendiente de carga; ' * 2
INJECT = '''(n)=>{const d=JSON.parse(localStorage.getItem("%s")); d.com.alarms=d.com.alarms||[]; d.com.alarms=d.com.alarms.filter(a=>!String(a.id).startsWith("inj-"));
  const now=Date.now(); for(let i=1;i<=n;i++){ d.com.alarms.push({id:"inj-"+i, number:"ALR-9"+String(i).padStart(5,"0"), order_ref:"P-"+(8000+i), sheet_key:"X", request_id:null, branch:"MONTECASEROS",
    client_name:"CLIENTE DE PRUEBA CON RAZÓN SOCIAL MUY LARGA NÚMERO "+i+" SOCIEDAD ANÓNIMA COMERCIAL INDUSTRIAL", client_cuit:null, client_source:"DECLARADO_POR_DESPACHO", reason:%s,
    raised_by:"u-op", raised_at:new Date(now-i*1000).toISOString(), initial_user:"u-wilfredo", escalate_at:new Date(now+600000).toISOString(), escalated_at:null, escalated_to:[],
    status:"PENDIENTE_ATENCION", attended_by:null, attended_at:null, op_id:"inj-op-"+i, version:1}); }
  localStorage.setItem("%s", JSON.stringify(d));}''' % (K, json.dumps(LONG), K)
GEO = '''()=>{const p=document.querySelector("#comAlarm [data-al-panel] .al-in")||document.querySelector("#comAlarm [data-al-panel]"), l=document.querySelector("#comAlarm [data-al-list]"), b=document.querySelector("#comAlarm [data-al-attend]");
  const r=p?p.getBoundingClientRect():null, br=b?b.getBoundingClientRect():null, cards=[...document.querySelectorAll("#comAlarm .al-card")];
  return {vh:innerHeight, alto:r?Math.round(r.height):0, lista_desplazable:l?l.scrollHeight>l.clientHeight+2:false, boton_visible:!!br&&br.top>=0&&br.bottom<=innerHeight&&br.width>0,
    desborde_h:document.documentElement.scrollWidth-document.documentElement.clientWidth, tarjetas_desbordan:cards.some(c=>c.scrollWidth>c.clientWidth+1), tarjetas:cards.length}}'''
async def main():
    os.makedirs(OUT, exist_ok=True)
    if not all(os.path.isfile(os.path.join(base.FIX, f)) for f in base.FILES): subprocess.run(['python3', os.path.join(os.path.dirname(__file__), 'generate_synthetic_saldo_noc.py'), base.FIX], check=True)
    srv = dp.serve()
    try:
        async with async_playwright() as p:
            b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
            try:
                mk = lambda w=1366, h=900, mob=False: b.new_context(viewport={'width': w, 'height': h}, is_mobile=mob, has_touch=mob)
                op = await (await mk()).new_page(); op.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
                await op.goto(f'http://127.0.0.1:{dp.PORT}/'); await op.evaluate('()=>localStorage.clear()')
                await base.login(op, 'admin@okdespacho.demo'); await op.wait_for_timeout(1200)
                await op.evaluate('async()=>{await window.OKD_ONLINE.api.comSetAlarmSettings({initial_user:"u-wilfredo", escalation_users:["u-franco","u-gabriela"]})}')
                await op.evaluate('async()=>{try{await window.OKD_ONLINE.api.signOut()}catch(e){}}'); await op.goto(f'http://127.0.0.1:{dp.PORT}/')
                await base.login(op, 'operario@okdespacho.demo'); await base.builder(op)
                await op.fill('#ids', '72001 72002 72003 72004'); await op.click('#btnSearch'); await op.wait_for_timeout(2500)
                await base.type_amount(op, '72001', '1500'); await base.type_amount(op, '72002', '2000'); await op.evaluate('async()=>{ await RouteStore.flush(); }')
                # ===== E01 · B-W06 sobre el camino VIGENTE (hotfix 9c3240c: PUBLICAR HOJA ya no muestra autorizaciones ni el formulario de alarma) =====
                await op.evaluate('()=>{const B=window.OKD_BRIDGE&&window.OKD_BRIDGE.com; window.__brCalls={bridge:!!(B&&B.alerts&&B.alarm), n:0}; if(B){for(const k of ["alerts","alarm"]){const o=B[k]; B[k]=async(...a)=>{window.__brCalls.n++; return o(...a)}}}}')
                await base.open_publish(op); await op.wait_for_timeout(2500)
                hot = await op.evaluate('''()=>({pubCom:!!document.getElementById("pubCom"), form:!!document.querySelector("[data-al-order],[data-al-go],.comalarmform"), llamadas:window.__brCalls})''')
                await op.evaluate('()=>{const b=document.getElementById("pubCancel"); if(b) b.click()}')
                # el Comercial crea 5 solicitudes PENDIENTES (misma base de la demo = servidor común)
                cm = await op.context.new_page(); await base.login(cm, 'comercial.sanjuan@okdespacho.demo'); await cm.wait_for_timeout(1200)
                reqs = await cm.evaluate('''async()=>{const A=window.OKD_ONLINE.api, out=[]; for(const [i,ref] of ["U-A","U-B","U-C","U-D","U-E"].entries()){ out.push(await A.comCreate("ECHEQ","cli-101",ref,{amount:100000+i, due_date:new Date(Date.now()+10*864e5).toISOString().slice(0,10), issuer_name:"", issuer_cuit:""},null,"u-op-"+ref)); } return out.map(x=>x.id)}''')
                await cm.close()
                await op.evaluate('()=>{location.hash="#/autorizaciones?v=despacho"}'); await op.wait_for_selector('#comMain .az', timeout=20000); await op.wait_for_timeout(600)
                await op.evaluate('''()=>{const A=window.OKD_ONLINE.api, orig=A.comAlarmRaiseRequest.bind(A); window.__alCalls=0; window.__alLose=0; window.__alOps=[];
                  A.comAlarmRaiseRequest=async(...a)=>{window.__alCalls++; window.__alOps.push(a[2]); const r=await orig(...a); if(window.__alLose>0){window.__alLose--; throw new Error("Failed to fetch");} return r;};}''')
                MSG = '()=>{const e=document.getElementById("uMsg"); return e&&!e.hidden?e.innerText:""}'
                TOASTS = '()=>[...document.querySelectorAll("#comToast .toast")].map(t=>t.textContent).join(" | ")'
                async def open_req(rid):
                    await op.evaluate('()=>{const m=document.getElementById("comModal"); if(m) m.innerHTML=""; const t=document.getElementById("comToast"); if(t) t.innerHTML=""}')   # cada paso lee SOLO sus avisos
                    await op.evaluate('(id)=>document.querySelector(`#comMain [data-select="${id}"]`).click()', rid); await op.wait_for_timeout(700)
                    await op.wait_for_selector('#rUrgentBtn', timeout=8000); await op.click('#rUrgentBtn'); await op.wait_for_selector('#uReason', timeout=5000)
                n_alarms = lambda rid: op.evaluate('(id)=>(JSON.parse(localStorage.getItem("%s")).com.alarms||[]).filter(a=>a.request_id===id).length' % K, rid)
                # (a) doble clic → UNA llamada
                await open_req(reqs[0]); await op.fill('#uReason', 'Cliente pide financiación antes de cargar'); await op.evaluate('()=>{const g=document.getElementById("uGo"); g.click(); g.click();}')
                await op.wait_for_timeout(1500); a_calls = await op.evaluate('()=>window.__alCalls'); a_res = await op.evaluate(TOASTS); a_n = await n_alarms(reqs[0])
                # (b) respuesta PERDIDA → «sin respuesta» y reintento con el MISMO op_id, sin duplicar
                await open_req(reqs[1]); await op.fill('#uReason', 'Segundo pedido urgente con respuesta perdida'); await op.evaluate('()=>{window.__alLose=1}')
                await op.click('#uGo'); await op.wait_for_timeout(1200); b1 = await op.evaluate(MSG)
                await op.click('#uGo'); await op.wait_for_timeout(1500); b2 = await op.evaluate(TOASTS); ops_b = await op.evaluate('()=>window.__alOps.slice(-2)'); n_b = await n_alarms(reqs[1])
                # (c) ATENCIÓN entre intentos: perdida → se atiende → reintento: mismo resultado, NO crea otra alarma
                await open_req(reqs[2]); await op.fill('#uReason', 'Tercer pedido urgente atendido entre intentos'); await op.evaluate('()=>{window.__alLose=1}')
                await op.click('#uGo'); await op.wait_for_timeout(1200); c1 = await op.evaluate(MSG)
                await op.evaluate(mutate('d.com.alarms.filter(a=>a.request_id===%s).forEach(a=>{a.status="ATENDIDA"; a.attended_by="u-wilfredo"; a.attended_at=new Date().toISOString(); a.version++;})' % json.dumps(reqs[2])))
                await op.click('#uGo'); await op.wait_for_timeout(1500); c2 = await op.evaluate(TOASTS); n_c = await n_alarms(reqs[2])
                # (d) CONFLICTO: la intención guardada reutiliza el op_id de OTRA operación → «NO SE ENVIÓ», nunca «enviada», sin alarma
                await op.evaluate('([id,o])=>sessionStorage.setItem("okd_com_urgent:"+id, JSON.stringify({reason:"Intento con identificador reutilizado", op:o}))', [reqs[3], ops_b[0]])
                await open_req(reqs[3]); calls_d0 = await op.evaluate('()=>window.__alCalls'); await op.click('#uGo'); await op.wait_for_timeout(1200)
                d1 = await op.evaluate(MSG); d_toast = await op.evaluate(TOASTS); n_d = await n_alarms(reqs[3])
                # (e) DESCONEXIÓN: sin conexión → «sin respuesta»; al volver, reintento con el MISMO op_id → enviada
                await open_req(reqs[4]); await op.fill('#uReason', 'Quinto pedido urgente sin conexión'); await op.evaluate('()=>{window.OKD_NET={offline:true}}')
                await op.click('#uGo'); await op.wait_for_timeout(1000); e1 = await op.evaluate(MSG); op_e1 = await op.evaluate('(id)=>JSON.parse(sessionStorage.getItem("okd_com_urgent:"+id)).op', reqs[4])
                await op.evaluate('()=>{window.OKD_NET={offline:false}}'); await op.click('#uGo'); await op.wait_for_timeout(1500); e2 = await op.evaluate(TOASTS)
                ops_e = await op.evaluate('()=>window.__alOps.slice(-2)'); n_e = await n_alarms(reqs[4])
                await op.screenshot(path=os.path.join(OUT, '1_alarma_desde_solicitud_intencion_estable.png'))
                res('E01 (B-W06) HOTFIX: PUBLICAR HOJA sin autorizaciones ni formulario de alarma (y sin consultarlas) · en «Solicitar aprobación urgente»: doble clic = UNA llamada · respuesta PERDIDA → «sin respuesta» y el reintento usa el MISMO op_id (una sola alarma) · ATENCIÓN entre intentos: el reintento devuelve el mismo resultado sin crear otra · CONFLICTO → «NO SE ENVIÓ» (nunca enviada, sin alarma) · DESCONEXIÓN → reintento con el mismo op_id',
                    not hot['pubCom'] and not hot['form'] and hot['llamadas']['bridge'] and hot['llamadas']['n'] == 0
                    and a_calls == 1 and 'Alarma enviada' in a_res and a_n == 1 and 'SIN RESPUESTA' in b1 and 'Alarma enviada' in b2 and ops_b[0] == ops_b[1] and n_b == 1
                    and 'SIN RESPUESTA' in c1 and n_c == 1 and 'NO SE ENVIÓ' in d1 and d_toast == '' and n_d == 0
                    and 'SIN RESPUESTA' in e1 and ops_e[0] == ops_e[1] == op_e1 and n_e == 1 and 'Alarma enviada' in e2,
                    {'ventana': hot, 'llamadas_doble_clic': a_calls, 'perdida': [b1[:40], ops_b], 'atendida_entre': [c1[:30], n_c], 'conflicto': d1[:90], 'desconexion': [e1[:30], ops_e, n_e]})
                # ===== E02-E04 · B-W07 · alarmas múltiples para Wilfredo =====
                wi = await (await mk()).new_page(); await wi.goto(f'http://127.0.0.1:{dp.PORT}/'); await sync(op, wi); await enter(wi, 'wilfredo@okdespacho.demo')
                await wi.evaluate(mutate('d.com.alarms.forEach(a=>{if(a.status==="PENDIENTE_ATENCION"){a.status="ATENDIDA"; a.attended_by="u-wilfredo"; a.attended_at=new Date().toISOString();}})'))
                geo = {}
                for n in (1, 3, 6):
                    await wi.evaluate(INJECT, n); await poll(wi); await wi.mouse.click(5, 880); geo['notebook_' + str(n)] = await wi.evaluate(GEO)
                await wi.screenshot(path=os.path.join(OUT, '2_seis_alarmas_notebook.png'))
                an = await (await mk(390, 844, True)).new_page(); await an.goto(f'http://127.0.0.1:{dp.PORT}/'); await sync(wi, an); await enter(an, 'wilfredo@okdespacho.demo')
                for n in (1, 3, 6):
                    await an.evaluate(INJECT, n); await poll(an); geo['android_' + str(n)] = await an.evaluate(GEO)
                await an.screenshot(path=os.path.join(OUT, '3_seis_alarmas_android.png'))
                okg = all(g['alto'] <= g['vh'] * 0.62 + 30 and g['boton_visible'] and g['desborde_h'] <= 0 and not g['tarjetas_desbordan'] for g in geo.values()) \
                    and geo['notebook_6']['lista_desplazable'] and geo['android_6']['lista_desplazable'] and geo['android_3']['lista_desplazable']
                res('E02 (B-W07) 1, 3 y 6 alarmas con textos LARGOS, en notebook y Android: aviso con altura LIMITADA (≤ ~60 % de la pantalla), lista con desplazamiento interno, primer ATENDER visible, sin desbordes horizontales',
                    okg, geo)
                # E03 · minimizar SIN registrar atención · Escape · una alarma NUEVA vuelve a abrir el aviso
                await an.click('[data-al-min]'); await an.wait_for_timeout(400)
                bar = await an.evaluate('()=>{const e=document.querySelector("#comAlarm [data-al-bar]"); if(!e) return {alto:0}; const r=e.getBoundingClientRect(); return {alto:Math.round(r.height), abajo:r.top>innerHeight/2}}'); st_min = await an.evaluate(ST)
                pend = await an.evaluate('()=>JSON.parse(localStorage.getItem("%s")).com.alarms.filter(a=>String(a.id).startsWith("inj-")).every(a=>a.status==="PENDIENTE_ATENCION"&&!a.attended_by)' % K)
                await an.click('[data-al-expand]'); await an.wait_for_timeout(300); await an.keyboard.press('Escape'); await an.wait_for_timeout(300); esc_min = (await an.evaluate(ST))['min']
                await an.evaluate(mutate('const a=JSON.parse(JSON.stringify(d.com.alarms.find(x=>x.id==="inj-1"))); a.id="inj-7"; a.number="ALR-900007"; a.op_id="inj-op-7"; d.com.alarms.push(a)'))
                await poll(an); reopened = not (await an.evaluate(ST))['min'] and bool(await an.evaluate('()=>!!document.querySelector("#comAlarm [data-al-panel]")'))
                res('E03 (B-W07) MINIMIZAR libera la pantalla (barra compacta ABAJO: encabezado y navegación libres) SIN registrar atención (todas siguen PENDIENTES, sin atendedor) y sigue sonando espaciado; Escape minimiza; una alarma NUEVA vuelve a abrir el aviso',
                    0 < bar['alto'] <= 80 and bar['abajo'] and st_min['min'] and st_min['ringing'] and pend and esc_min and reopened, {'alto_barra': bar, 'estado': st_min, 'escape': esc_min, 'reabre_con_nueva': reopened})
                # E04 · teclado y zoom
                await wi.evaluate(INJECT, 3); await poll(wi); await wi.evaluate('()=>document.activeElement&&document.activeElement.blur()')
                tabs = 0; found = False
                for i in range(60):
                    await wi.keyboard.press('Tab'); tabs += 1
                    if await wi.evaluate('()=>!!(document.activeElement&&document.activeElement.matches("#comAlarm [data-al-attend], #comAlarm [data-al-min]"))'): found = True; break
                await wi.set_viewport_size({'width': 780, 'height': 514}); await wi.wait_for_timeout(500); gz = await wi.evaluate(GEO)   # zoom 175 % del navegador = vista de 780 × 514 px CSS
                await wi.set_viewport_size({'width': 1366, 'height': 900}); await wi.wait_for_timeout(300)
                res('E04 (B-W07) TECLADO: con Tab se llega a los botones de la alarma · ZOOM 175 % del navegador (vista de 780 × 514 px): el aviso sigue contenido, con su primer ATENDER visible y sin desbordes',
                    found and gz['boton_visible'] and gz['desborde_h'] <= 0 and gz['alto'] <= gz['vh'] * 0.62 + 30, {'tabs': tabs, 'zoom': gz})
                # ===== E05 · B-W03 · bloqueo PIN REAL (Franco, Administrador) =====
                fr = await (await mk()).new_page(); await fr.goto(f'http://127.0.0.1:{dp.PORT}/'); await sync(wi, fr); await enter(fr, 'franco@okdespacho.demo')
                await fr.evaluate(mutate('d.com.alarms.forEach(a=>{ if(String(a.id).startsWith("inj-")){ a.escalated_at=new Date().toISOString(); a.escalated_to=["u-franco","u-gabriela"]; } })'))
                await poll(fr); await fr.mouse.click(5, 880); pre = await fr.evaluate(ST); pre_btn = await fr.evaluate('()=>document.querySelectorAll("#comAlarm [data-al-attend]").length')
                await fr.evaluate('()=>{localStorage.setItem("okd_pin_v1_u-franco_last", JSON.stringify({at: Date.now()-5*3600000, day:"2000-01-01"})); document.dispatchEvent(new Event("visibilitychange"));}')
                for _ in range(20):
                    await fr.wait_for_timeout(300)
                    if await fr.evaluate('()=>{const g=document.getElementById("pinGate"); return !!g && g.getClientRects().length>0}'): break
                await fr.wait_for_timeout(500)
                locked = await fr.evaluate('()=>({pin:!!document.getElementById("pinGate"), texto:(document.getElementById("comAlarm")||{}).innerText||"", botones:document.querySelectorAll("#comAlarm [data-al-attend]").length})')
                st_lock = await fr.evaluate(ST); beeps_a = st_lock['beeps']; await fr.wait_for_timeout(2600); beeps_b = (await fr.evaluate(ST))['beeps']
                await fr.screenshot(path=os.path.join(OUT, '4_pin_bloqueo_sin_alarma.png'))
                await fr.fill('#pinA', '123456'); await fr.click('#pinGo'); await fr.wait_for_timeout(2000); await poll(fr)
                after = await fr.evaluate('()=>({pin:!!document.getElementById("pinGate"), botones:document.querySelectorAll("#comAlarm [data-al-attend]").length})'); st_un = await fr.evaluate(ST)
                res('E05 (B-W03) PIN REAL: con el bloqueo abierto la alarma NO muestra NADA (ni datos ni botones: no se puede ATENDER) y el sonido se PAUSA; al desbloquear con el PIN vuelve el aviso',
                    pre['ringing'] and pre_btn > 0 and locked['pin'] and locked['texto'].strip() == '' and locked['botones'] == 0 and st_lock['supp'] == 'PIN' and not st_lock['ringing'] and beeps_b == beeps_a
                    and not after['pin'] and after['botones'] > 0 and st_un['ringing'], {'antes': pre, 'bloqueado': locked, 'pitidos': [beeps_a, beeps_b], 'desbloqueado': after})
                # ===== E06 · B-W03 · formulario MODAL abierto → indicador compacto SIN datos =====
                await fr.evaluate('()=>{location.hash="#/autorizaciones?v=historial"}'); await fr.wait_for_timeout(2200)
                await fr.click('#comAlarm [data-al-min]'); await fr.wait_for_timeout(400)
                await fr.click('#comBell', timeout=5000); await fr.wait_for_timeout(700)   # con la alarma MINIMIZADA, la navegación del módulo queda libre
                modal = await fr.evaluate('()=>({pill:!!document.querySelector("#comAlarm [data-al-pill]"), panel:!!document.querySelector("#comAlarm [data-al-panel]"), botones:document.querySelectorAll("#comAlarm [data-al-attend]").length, texto:(document.getElementById("comAlarm")||{}).innerText||""})')
                await fr.click('#comModal [data-close]'); await fr.wait_for_timeout(700)
                back = await fr.evaluate('()=>!!document.querySelector("#comAlarm [data-al-panel]") || !!document.querySelector("#comAlarm [data-al-bar]")')
                res('E06 (B-W03/B-W07) MINIMIZADA, la navegación queda libre (se usa la campana del módulo); con un formulario MODAL abierto la alarma se reduce a un indicador compacto SIN datos ni botones; al cerrarlo vuelve',
                    modal['pill'] and not modal['panel'] and modal['botones'] == 0 and 'P-80' not in modal['texto'] and 'CLIENTE DE PRUEBA' not in modal['texto'] and back, modal)
                # ===== E07 · O-W01 · destruir DURANTE una consulta en curso: nada se reprograma ni reaparece =====
                o7 = await wi.evaluate('''async()=>{const A=window.OKD_ONLINE.api, orig=A.comMyAlarmsPage.bind(A); let soltar; A.comMyAlarmsPage=(...a)=>new Promise(r=>{soltar=()=>orig(...a).then(r);});
                  const st=window.setTimeout; const tras=[]; let destruida=false; window.setTimeout=(f,ms,...x)=>{ if(destruida) tras.push(ms); return st(f,ms,...x); };
                  const p=window.__okdComAlarm.poll(); window.dispatchEvent(new Event("okd-com-cleanup")); destruida=true; soltar(); await p; await new Promise(r=>st(r,1500));
                  window.setTimeout=st; A.comMyAlarmsPage=orig; return {reprogramados: tras.filter(ms=>ms>=10000).length, estado: typeof window.__okdComAlarm, vista: !!document.getElementById("comAlarm")}}''')
                res('E07 (O-W01) DESTRUIR la alarma mientras una consulta está en curso: al llegar la respuesta NO se reprograma ningún temporizador ni reaparece estado o vista',
                    o7['reprogramados'] == 0 and o7['estado'] == 'undefined' and not o7['vista'], o7)
                # ===== E08 · HISTORIAL completo por vendedor =====
                co = await (await mk()).new_page(); await co.goto(f'http://127.0.0.1:{dp.PORT}/'); await sync(wi, co); await enter(co, 'comercial.montecaseros@okdespacho.demo')
                await co.evaluate('async()=>{const A=window.OKD_ONLINE.api; await A.comCreate("FINANCIACION","cli-101","H-0",{amount:150000,installments:2},null,"hist-base")}')
                await co.evaluate(mutate('''const t=d.com.requests.find(q=>q.op_id==="hist-base"); const S=["PENDIENTE","APROBADA","APROBADA_MOD","RECHAZADA","DEVUELTA","CANCELADA"];
                  for(let i=1;i<=44;i++){ const q=JSON.parse(JSON.stringify(t)); q.id="hist-"+i; q.number="AUT-H"+String(i).padStart(4,"0"); q.op_id="hist-op-"+i; q.order_ref="H-"+i; q.status=S[i%6];
                    q.created_at=new Date(Date.parse("2026-09-01T10:00:00Z")+i*3600e3).toISOString(); q.updated_at=q.created_at; d.com.requests.push(q); }'''))
                total = await co.evaluate('()=>JSON.parse(localStorage.getItem("%s")).com.requests.filter(q=>q.requested_by==="u-com-mc").length' % K)
                await co.evaluate('()=>{location.hash="#/autorizaciones?v=historial"}'); await co.reload(); await co.wait_for_timeout(2500)
                h1 = await co.evaluate('()=>({n:document.querySelectorAll("[data-hid]").length, txt:document.querySelector("#hCount").innerText})')
                while await co.locator('#hMore').count(): await co.click('#hMore'); await co.wait_for_timeout(700)
                ids = await co.evaluate('()=>[...document.querySelectorAll("[data-hid]")].map(b=>b.dataset.hid)')
                await co.select_option('#hSt', 'RECHAZADA'); await co.click('#hGo'); await co.wait_for_timeout(900)
                while await co.locator('#hMore').count(): await co.click('#hMore'); await co.wait_for_timeout(600)
                n_rech = await co.evaluate('()=>document.querySelectorAll("[data-hid]").length')
                exp_rech = await co.evaluate('()=>JSON.parse(localStorage.getItem("%s")).com.requests.filter(q=>q.requested_by==="u-com-mc"&&q.status==="RECHAZADA").length' % K)
                await co.evaluate('()=>window.scrollTo(0, 300)'); y0 = await co.evaluate('()=>Math.round(scrollY)')
                await co.click('[data-hid] >> nth=1'); await co.wait_for_timeout(900); det = await co.evaluate('()=>document.querySelector("#comMain").innerText.replace(/\\s+/g," ")')
                await co.click('#hBack'); await co.wait_for_timeout(900)
                vuelta = await co.evaluate('()=>({estado:document.querySelector("#hSt").value, n:document.querySelectorAll("[data-hid]").length, y:Math.round(scrollY)})')
                await co.reload(); await co.wait_for_timeout(2500); recarga = await co.evaluate('()=>({estado:(document.querySelector("#hSt")||{}).value, n:document.querySelectorAll("[data-hid]").length})')
                await co.click('#hClear'); await co.wait_for_timeout(900); limpio = await co.evaluate('()=>document.querySelectorAll("[data-hid]").length')
                ajeno = await co.evaluate('async()=>{const A=window.OKD_ONLINE.api; await A.signOut().catch(()=>{}); return null}')
                cs = await (await mk(390, 844, True)).new_page(); await cs.goto(f'http://127.0.0.1:{dp.PORT}/'); await sync(co, cs); await enter(cs, 'comercial.sanjuan@okdespacho.demo')
                aj = await cs.evaluate('async()=>{const A=window.OKD_ONLINE.api, t=async f=>{try{await f(); return "VE"}catch(e){return e.code}}; return {ajena: await t(()=>A.comRequestDetail("hist-3")), inexistente: await t(()=>A.comRequestDetail("no-existe")), mis: (await A.comHistory("MIS",{},null,100)).items.filter(x=>String(x.id).startsWith("hist-")).length, todas: await t(()=>A.comHistory("TODAS",{},null,25))}}')
                await cs.evaluate('()=>{location.hash="#/autorizaciones?v=historial"}'); await cs.wait_for_timeout(2000)
                hs = await cs.evaluate('()=>document.documentElement.scrollWidth-document.documentElement.clientWidth'); await cs.screenshot(path=os.path.join(OUT, '5_historial_android.png'))
                res('E08 HISTORIAL (45 solicitudes): 25 por página con «quedan más» · «Cargar más» completa las 45 sin duplicados · filtro de estado exacto · detalle con trazabilidad · VOLVER conserva filtros, listado y posición · RECARGAR conserva filtros · LIMPIAR recupera todo · otro vendedor: ajena = inexistente (FORBIDDEN), no la ve en su historial ni accede a TODAS · Android sin desplazamiento horizontal',
                    h1['n'] == 25 and 'quedan más' in h1['txt'] and len(ids) == total == 45 and len(set(ids)) == 45 and n_rech == exp_rech and 'Volver al listado' in det
                    and vuelta['estado'] == 'RECHAZADA' and vuelta['n'] == n_rech and abs(vuelta['y'] - y0) <= 40 and recarga['estado'] == 'RECHAZADA' and limpio == 25
                    and aj['ajena'] == 'FORBIDDEN' and aj['inexistente'] == 'FORBIDDEN' and aj['mis'] == 0 and aj['todas'] == 'FORBIDDEN' and hs <= 0,
                    {'primera': h1, 'cargadas': len(ids), 'rechazadas': [n_rech, exp_rech], 'vuelta': vuelta, 'y0': y0, 'recarga': recarga, 'limpio': limpio, 'ajeno': aj, 'desborde': hs})
                # ===== E09 · B-W04 · restringir COMERCIAL desde la pantalla de USUARIOS =====
                ad = await (await mk()).new_page(); ad.on('dialog', lambda d: asyncio.ensure_future(d.accept('Prueba local: activación AUTORIZADA (simulada) por Dirección General') if d.type == 'prompt' else d.accept())); await ad.goto(f'http://127.0.0.1:{dp.PORT}/'); await sync(cs, ad); await enter(ad, 'admin@okdespacho.demo')
                async def toggle_comercial(want_checked):
                    await ad.evaluate('()=>{location.hash="#/usuarios"}'); await ad.wait_for_timeout(1800); await ad.click('[data-pick="u-com-mc"]'); await ad.wait_for_timeout(700)
                    await ad.click('#upSide [data-act="edit"]'); await ad.wait_for_timeout(700)
                    box = ad.locator('[data-mod="COMERCIAL"]'); now = await box.is_checked()
                    if now != want_checked: await box.click()
                    await ad.click('#umSave'); await ad.wait_for_timeout(1500)
                await toggle_comercial(False)
                await sync(ad, co); await co.goto(f'http://127.0.0.1:{dp.PORT}/'); await base.login(co, 'comercial.montecaseros@okdespacho.demo'); await co.wait_for_timeout(1500)
                m1 = await co.evaluate('async()=>{const A=window.OKD_ONLINE.api, t=async f=>{try{await f(); return "OK"}catch(e){return e.code}}; return {cfg: await t(()=>A.comConfig()), hist: await t(()=>A.comHistory("MIS",{},null,25))}}')
                dmods = await ad.evaluate('()=>JSON.parse(localStorage.getItem("%s")).users.find(u=>u.id==="u-com-mc").disabled_modules' % K)
                await toggle_comercial(True); await sync(ad, co); await co.goto(f'http://127.0.0.1:{dp.PORT}/'); await co.wait_for_timeout(1500)
                m2 = await co.evaluate('async()=>{const A=window.OKD_ONLINE.api, t=async f=>{try{await f(); return "OK"}catch(e){return e.code}}; return {cfg: await t(()=>A.comConfig()), hist: await t(()=>A.comHistory("MIS",{},null,25))}}')
                res('E09 (B-W04) USUARIOS: restringir el módulo COMERCIAL desde la pantalla se guarda y el usuario pierde el acceso real (configuración e historial → FORBIDDEN); al restaurarlo, vuelve a funcionar',
                    dmods == ['COMERCIAL'] and m1['cfg'] == 'FORBIDDEN' and m1['hist'] == 'FORBIDDEN' and m2['cfg'] == 'OK' and m2['hist'] == 'OK', {'restringido': m1, 'modulos': dmods, 'restaurado': m2})
                # ===== E10 · actualización de la app con un formulario comercial a medio escribir: la recarga se POSTERGA =====
                u = await (await mk()).new_page(); await u.goto(f'http://127.0.0.1:{dp.PORT}/'); await sync(ad, u); await enter(u, 'comercial.montecaseros@okdespacho.demo')
                await u.evaluate('()=>{location.hash="#/autorizaciones?v=comercial"}'); await u.wait_for_timeout(2200)
                await u.fill('#cOrder', 'PEDIDO A MEDIO ESCRIBIR'); await u.evaluate('()=>{window.__marca="viva"; navigator.serviceWorker && navigator.serviceWorker.dispatchEvent(new Event("controllerchange"));}')
                await u.wait_for_timeout(4000); sigue = await u.evaluate('()=>({marca: window.__marca||null, pedido: (document.querySelector("#cOrder")||{}).value||null})')
                await u.fill('#cOrder', ''); await u.wait_for_timeout(4500)
                recargo = await u.evaluate('()=>window.__marca===undefined')
                res('E10 ACTUALIZACIÓN de la app con un formulario comercial a medio escribir: la recarga se POSTERGA y lo escrito no se pierde; al vaciar el formulario, la actualización se aplica',
                    sigue['marca'] == 'viva' and sigue['pedido'] == 'PEDIDO A MEDIO ESCRIBIR' and recargo, {'durante': sigue, 'recargo_despues': recargo})
                # ===== E11 · sección 5: KPI DESHABILITADO desde el Panel General =====
                await ad.evaluate('()=>{location.hash="#/autorizaciones?v=general"}'); await ad.wait_for_timeout(2200)
                await ad.select_option('#kMode', 'DESHABILITADO'); await ad.click('#kSave'); await ad.wait_for_timeout(1500)
                modo = await ad.evaluate('()=>JSON.parse(localStorage.getItem("%s")).com.settings.kpi_mode' % K)
                await sync(ad, u); await u.goto(f'http://127.0.0.1:{dp.PORT}/'); await u.wait_for_timeout(1500); await u.evaluate('()=>{location.hash="#/autorizaciones?v=comercial"}'); await u.wait_for_timeout(2200)
                await u.fill('#cSearch', 'TECNO'); await u.wait_for_timeout(1500); await u.click('#cSugg [data-cli] >> nth=0'); await u.wait_for_timeout(1200)
                kpi_txt = await u.evaluate('()=>(document.querySelector("#cKpi")||{}).innerText||""')
                await ad.select_option('#kMode', 'PROVISORIO'); await ad.click('#kSave'); await ad.wait_for_timeout(1200)   # reactivación con la referencia a la autorización (pedido respondido)
                reactivado = await ad.evaluate('()=>{const d=JSON.parse(localStorage.getItem("%s")); return {modo:d.com.settings.kpi_mode, aut:((d.auditLog||[]).filter(a=>a.action==="COM_KPI_MODE").pop()||{}).autorizacion||null}}' % K)
                res('E11 (sección 5 / N-V4-03) KPI DESHABILITADO (predeterminado): el vendedor ve «KPI DESHABILITADO» (sin cifras) y puede seguir cargando; la REACTIVACIÓN desde el Panel exige y guarda la referencia a la autorización',
                    modo == 'DESHABILITADO' and reactivado['modo'] == 'PROVISORIO' and (reactivado['aut'] or '').startswith('Prueba local') and 'KPI DESHABILITADO' in kpi_txt and not any(x in kpi_txt for x in ('PISO', 'TECHO', 'PROMEDIO MENSUAL')) and bool(await u.evaluate('()=>!!document.querySelector("#cSend")')),
                    {'modo': modo, 'kpi': kpi_txt[:160]})
            finally: await b.close()
    finally: srv.terminate()
    print('TOTAL', sum(1 for r in R if r[1] == 'PASS'), 'PASS /', sum(1 for r in R if r[1] == 'FAIL'), 'FAIL · esperados', EXPECTED)
    return R
if __name__ == '__main__':
    try: rr = asyncio.run(main())
    except Exception as e: traceback.print_exc(); print('ERROR:', repr(e)); sys.exit(2)
    if len(rr) != EXPECTED: print('ERROR: se ejecutaron %d de %d' % (len(rr), EXPECTED)); sys.exit(2)
    sys.exit(1 if any(r[1] != 'PASS' for r in rr) else 0)
