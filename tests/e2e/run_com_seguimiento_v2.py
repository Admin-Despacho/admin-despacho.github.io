"""E2E BLOQUEANTE V2 (modo demo, Chromium REAL) · CORRECCIONES DE AUDITORÍA de la mejora visual y trazabilidad de autorizaciones:
A conexión (pérdida real, recuperación aparente y real, sin consultas concurrentes) · B comparación solicitado ↔ autorizado con IGUAL total
(cuotas, distribución, vencimientos, e-cheq y emisor) respetando permisos · C actualización automática en bandeja del aprobador, detalle desde
alarma, Seguimiento de Despacho y de Comercial, con sesiones simultáneas y formularios en edición · permisos y manipulación · sesión revocada
y vencida · Android · sin consultas ni temporizadores duplicados. Datos SINTÉTICOS de la demo; sin servidor, sin SQL y sin correos.
Uso: python3 tests/e2e/run_com_seguimiento_v2.py <dist-demo> <carpeta_evidencias>"""
import asyncio, os, sys, json, re, time, traceback
sys.path.insert(0, os.path.dirname(__file__))
import run_driver_perfiles as dp
from playwright.async_api import async_playwright
dp.PORT = 4533; R = []; EXPECTED = 20
if len(sys.argv) > 1: dp.DIST = sys.argv[1]
OUT = sys.argv[2] if len(sys.argv) > 2 else '/tmp/okd_com_v2'
K = 'okd_online_demo_v2'
URL = lambda: f'http://127.0.0.1:{dp.PORT}/'
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:700])); print('..', ' | '.join(R[-1]), flush=True)
OV = '()=>document.documentElement.scrollWidth-document.documentElement.clientWidth'
AR_PLUS = '(n)=>{const t=new Intl.DateTimeFormat("en-CA",{timeZone:"America/Argentina/Mendoza"}).format(new Date()); const d=new Date(t+"T12:00:00Z"); d.setUTCDate(d.getUTCDate()+n); return d.toISOString().slice(0,10)}'
INIT = r'''(()=>{const act=new Map(); const si=window.setInterval.bind(window), ci=window.clearInterval.bind(window);
  window.setInterval=function(f,d,...a){const id=si(f,d,...a); act.set(id,d); return id}; window.clearInterval=function(id){act.delete(id); return ci(id)};
  window.__iv=()=>{const o={}; for(const d of act.values()){o[d]=(o[d]||0)+1} return o};})()'''
API = '''async([fn,args])=>{try{return {ok:true, v:await window.OKD_ONLINE.api[fn](...args)}}catch(e){return {ok:false, code:e.code, msg:String(e.message)}}}'''
async def api(pg, fn, *args):
    r = await pg.evaluate(API, [fn, list(args)])
    if not r['ok']: raise RuntimeError(fn + ' ' + str(r))
    return r['v']
async def try_api(pg, fn, *args): return await pg.evaluate(API, [fn, list(args)])
async def db(pg, js, arg=None):
    return await pg.evaluate('''([js,arg])=>{const d=JSON.parse(localStorage.getItem("%s")); const r=(new Function("d","arg",js))(d,arg); localStorage.setItem("%s",JSON.stringify(d)); return r}''' % (K, K), [js, arg])
async def go(pg, hash_):
    await pg.evaluate('(h)=>{location.hash=h}', hash_); await pg.wait_for_selector('#comMain .heading, #comMain .az, #comMain .note', timeout=15000); await pg.wait_for_timeout(700)
async def select(pg, rid):
    await pg.evaluate('(id)=>{const b=document.querySelector(`#comMain [data-select="${id}"]`); if(b) b.click()}', rid); await pg.wait_for_timeout(600)
async def nudge(pg, ms=1200):   # dispara el ciclo de actualización (como al volver la conexión o la pestaña): NO es una recarga
    await pg.evaluate('()=>window.dispatchEvent(new Event("online"))'); await pg.wait_for_timeout(ms)
async def hist_open(pg, rid):
    await pg.evaluate('()=>{location.hash="#/autorizaciones?v=historial"}'); await pg.reload(); await pg.wait_for_selector('#comMain .heading, #hBack', timeout=15000); await pg.wait_for_timeout(500)
    if await pg.locator('#hBack').count(): await pg.click('#hBack'); await pg.wait_for_timeout(600)
    await pg.evaluate('(id)=>document.querySelector(`[data-hid="${id}"]`).click()', rid); await pg.wait_for_selector('#comMain .az', timeout=15000); await pg.wait_for_timeout(500)
async def shot(pg, name, full=False): await pg.screenshot(path=os.path.join(OUT, name), full_page=full)
async def detail_shot(pg, name, sel='#comMain .az'):
    vp = pg.viewport_size; el = pg.locator(sel).first
    h = await pg.evaluate('(s)=>{const e=document.querySelector(s); const r=e.getBoundingClientRect(); return Math.ceil(r.height + r.top + window.scrollY + 200)}', sel)
    await pg.set_viewport_size({'width': vp['width'], 'height': min(max(h, vp['height']), 7000)}); await pg.wait_for_timeout(250)
    await el.screenshot(path=os.path.join(OUT, name)); await pg.set_viewport_size(vp)
CONN = '()=>{const b=document.getElementById("comConn"); return {banner:!!b&&!b.hidden, kind:b&&b.dataset.kind||null, txt:b?b.innerText:"", off:document.querySelector(".com-app").classList.contains("az-offline"), sync:(document.querySelector("#comMain [data-az-sync]")||{}).innerText||""}}'
STATUS = '()=>{const a=document.querySelector("#comMain .az"); return a?{id:a.dataset.azId, st:a.dataset.azStatus, txt:a.innerText.replace(/\\s+/g," ")}:null}'
COUNT = '''()=>{const A=window.OKD_ONLINE.api; window.__cnt={}; window.__slow=0; for(const f of ["comTrack","comNotifications","comList","comRequestDetail","comAlarmRequestDetail"]){ if(A["__o_"+f]) continue; const o=A[f].bind(A); A["__o_"+f]=o;
  A[f]=async(...a)=>{window.__cnt[f]=(window.__cnt[f]||0)+1; if(window.__fail&&window.__fail[f]) throw Object.assign(new Error(window.__fail[f].msg),{code:window.__fail[f].code}); if(window.__slow) await new Promise(r=>setTimeout(r,window.__slow)); return o(...a)} } }'''

async def main():
    os.makedirs(OUT, exist_ok=True); srv = dp.serve()
    try:
        async with async_playwright() as p:
            b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
            try:
                ctx = await b.new_context(viewport={'width': 1366, 'height': 950}); await ctx.add_init_script(INIT)
                C = await ctx.new_page(); C.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
                await C.goto(URL()); await C.evaluate('()=>localStorage.clear()')
                await dp.login(C, 'admin@okdespacho.demo'); await C.wait_for_timeout(800)
                await api(C, 'comSetAlarmSettings', {'initial_user': 'u-wilfredo', 'escalation_users': ['u-franco', 'u-gabriela']})
                await C.evaluate('async()=>{try{await window.OKD_ONLINE.api.signOut()}catch(e){}}')
                await dp.login(C, 'comercial.montecaseros@okdespacho.demo'); await C.wait_for_selector('#cSearch', timeout=20000)
                d = {n: await C.evaluate(AR_PLUS, n) for n in (1, 3, 7, 8, 10, 14, 15, 20, 21, 25)}
                dmy = lambda iso: '/'.join(reversed(iso.split('-')))
                tec = [c for c in await api(C, 'comSearchClients', 'TECNO') if c['selectable']][0]
                cuy = [c for c in await api(C, 'comSearchClients', 'COMERCIAL CUYO') if c['selectable']][0]
                mk = lambda kind, cli, ref, t: api(C, 'comCreate', kind, cli['id'], ref, t, None, 'op-v2-' + ref)
                Q = {}
                Q['M1'] = await mk('FINANCIACION', tec, 'V2-M1', {'amount': 1800000, 'installments': 2, 'frequency': 'QUINCENAL', 'first_due': d[10]})
                Q['M2'] = await mk('FINANCIACION', cuy, 'V2-M2', {'amount': 1800000, 'installments': 2, 'frequency': 'SEMANAL', 'first_due': d[7]})
                Q['M3'] = await mk('ECHEQ', cuy, 'V2-M3', {'amount': 950000.5, 'due_date': d[20], 'issuer_name': '', 'issuer_cuit': ''})
                Q['X'] = await mk('FINANCIACION', tec, 'V2-X', {'amount': 700000, 'installments': 1, 'first_due': d[8]})
                Q['Y'] = await mk('FINANCIACION', cuy, 'V2-Y', {'amount': 500000, 'installments': 2, 'frequency': 'SEMANAL', 'first_due': d[3]})
                Q['Z'] = await mk('FINANCIACION', tec, 'V2-Z', {'amount': 300000, 'installments': 1, 'first_due': d[3]})
                Q['F'] = await mk('FINANCIACION', tec, 'V2-F', {'amount': 420000, 'installments': 1, 'first_due': d[3]})
                ids = {k: v['id'] for k, v in Q.items()}
                W = await ctx.new_page(); await dp.login(W, 'wilfredo@okdespacho.demo'); await W.wait_for_timeout(600)
                G = await ctx.new_page(); await dp.login(G, 'gabriela@okdespacho.demo'); await G.wait_for_timeout(600)
                D = await ctx.new_page(); await dp.login(D, 'operario@okdespacho.demo'); await D.wait_for_timeout(600)
                ver = lambda pg, k: try_api(pg, 'comRequestDetail', ids[k])
                # ================= B · COMPARACIÓN con IGUAL total =================
                vM1 = (await api(W, 'comRequestDetail', ids['M1']))['version']
                await api(W, 'comDecide', ids['M1'], vM1, 'APROBAR_CON_CAMBIOS', {'amount': 1800000, 'installments': 3, 'frequency': 'SEMANAL', 'first_due': d[7]}, 'Mismo total en 3 semanales')
                vM3 = (await api(W, 'comRequestDetail', ids['M3']))['version']
                await api(W, 'comDecide', ids['M3'], vM3, 'APROBAR_CON_CAMBIOS', {'amount': 950000.5, 'due_date': d[15], 'issuer_name': 'DISTRIBUIDORA CUYO S.R.L.', 'issuer_cuit': '30717102742'}, 'Mismo importe, otro vencimiento y emisor')
                vM2 = (await api(W, 'comRequestDetail', ids['M2']))['version']
                await api(W, 'comDecide', ids['M2'], vM2, 'APROBAR', None, None)
                # M2: condiciones REGISTRADAS con otra distribución (dato sintético equivalente a una aprobación con cambios del servidor: mismo total y fechas)
                await db(C, '''const q=d.com.requests.find(x=>x.id===arg); q.status="APROBADA_MOD"; q.final_terms=JSON.parse(JSON.stringify(q.original_terms));
                  q.final_terms.schedule[0].amount=1000000; q.final_terms.schedule[1].amount=800000; q.current_terms=q.final_terms; q.version++;''', ids['M2'])
                await hist_open(C, ids['M1'])
                m1 = await C.evaluate('''()=>({n:(document.querySelector("#comMain [data-cal-cambios]")||{dataset:{}}).dataset.calCambios, items:[...document.querySelectorAll("#comMain [data-cambio]")].map(e=>e.innerText.replace(/\\s+/g," ")),
                  mods:document.querySelectorAll("#comMain [data-cal-mod]").length, cajas:[...document.querySelectorAll("#comMain [data-cal-detalle] h4")].map(e=>e.innerText)})''')
                await detail_shot(C, 'B1_mismo_total_otras_cuotas.png')
                res('V2-B1 FINANCIACIÓN con el MISMO TOTAL ($ 1.800.000) en 3 semanales en vez de 2 quincenales: se listan cantidad de cuotas, frecuencia, cada vencimiento e importe y la cuota NUEVA; celdas modificadas marcadas; NO figura «Importe total»',
                    m1['n'] and int(m1['n']) >= 6 and any('Cantidad de cuotas' in x for x in m1['items']) and any('Frecuencia' in x for x in m1['items']) and any('Cuota 3' in x for x in m1['items'])
                    and any('Importe de la cuota 1' in x and '$ 900.000' in x and '$ 600.000' in x for x in m1['items']) and not any(x.startswith('Importe total') for x in m1['items']) and m1['mods'] >= 4
                    and any('SOLICITADO' in x.upper() for x in m1['cajas']) and any('AUTORIZADO' in x.upper() for x in m1['cajas']), m1)
                await hist_open(C, ids['M2'])
                m2 = await C.evaluate('''()=>({items:[...document.querySelectorAll("#comMain [data-cambio]")].map(e=>e.innerText.replace(/\\s+/g," ")), mods:[...document.querySelectorAll("#comMain [data-cal-mod]")].map(e=>e.dataset.calMod)})''')
                await detail_shot(C, 'B2_misma_fecha_otra_distribucion.png')
                res('V2-B2 misma cantidad, mismas fechas y mismo total con otra DISTRIBUCIÓN ($ 900.000/$ 900.000 → $ 1.000.000/$ 800.000): se detectan exactamente los dos importes por cuota',
                    len(m2['items']) == 2 and all('Importe de la cuota' in x for x in m2['items']) and m2['mods'] == ['IMPORTE', 'IMPORTE'], m2)
                await hist_open(C, ids['M3'])
                m3 = await C.evaluate('''()=>({items:[...document.querySelectorAll("#comMain [data-cambio]")].map(e=>e.innerText.replace(/\\s+/g," ")), cajas:[...document.querySelectorAll("#comMain [data-cal-detalle] h4")].map(e=>e.innerText),
                  tablas:[...document.querySelectorAll("#comMain [data-cal-echeq]")].map(e=>e.innerText.replace(/\\s+/g," "))})''')
                await detail_shot(C, 'B3_echeq_mismo_importe.png')
                res('V2-B3 E-CHEQ con el MISMO importe ($ 950.000,50): se detectan el nuevo vencimiento y el cambio de emisor y CUIT; solicitado y autorizado en tablas separadas',
                    [x.split(' ')[0] for x in m3['items']] == ['Vencimiento', 'Emisor', 'CUIT'] and dmy(d[20]) in m3['items'][0] and dmy(d[15]) in m3['items'][0] and 'DISTRIBUIDORA CUYO' in m3['items'][1]
                    and len(m3['tablas']) == 2 and '$ 950.000,50' in m3['tablas'][0] and 'DISTRIBUIDORA CUYO' in m3['tablas'][1], m3)
                await D.bring_to_front(); await go(D, '#/autorizaciones?v=despacho'); await select(D, ids['M1'])
                dm = await D.evaluate('''()=>({res:(document.querySelector("#comMain [data-cal-cambios]")||{dataset:{}}).dataset.calCambios, txt:document.querySelector("#comMain .az").innerText})''')
                raw = await try_api(D, 'comTrack', 'V2-M1', False); rawq = (raw.get('v') or [{}])[0]
                res('V2-B4 PERMISOS en la comparación: Despacho ve que hubo MODIFICACIONES y las condiciones autorizadas, pero NO lo solicitado (ni importes por cuota originales, ni calendario solicitado, ni motivo); el servidor tampoco lo envía',
                    dm['res'] == 'RESERVADO' and 'Calendario SOLICITADO' not in dm['txt'] and '900.000' not in dm['txt'] and 'Mismo total en 3 semanales' not in dm['txt']
                    and rawq.get('original_terms') is None and rawq.get('notes') is None and all(e.get('reason') is None and e.get('terms_after') is None for e in rawq.get('timeline', [])), {'nota': dm['res']})
                await detail_shot(D, 'B4_despacho_cambios_reservados.png')
                # ================= A · CONEXIÓN =================
                await select(D, ids['F']); await D.evaluate(COUNT)
                t0 = await D.evaluate('()=>document.querySelector("#comMain .az [data-wait-since]").textContent')
                await ctx.set_offline(True); await D.wait_for_timeout(2300)
                a1 = await D.evaluate(CONN); t1 = await D.evaluate('()=>document.querySelector("#comMain .az [data-wait-since]").textContent'); a1_play = await D.evaluate('()=>getComputedStyle(document.querySelector("#comMain [data-az-dots] i")).animationPlayState')
                await shot(D, 'A1_perdida_real.png')
                res('V2-A1 PÉRDIDA REAL de conexión: aviso rojo «Sin conexión con el servidor … podría estar desactualizada», independiente del bloque de espera (puntos en pausa con «Estado sin confirmar»); el contador sigue con la hora REAL',
                    a1['banner'] and a1['kind'] == 'RED' and 'Sin conexión con el servidor' in a1['txt'] and 'desactualizada' in a1['txt'] and a1['off'] and a1_play == 'paused' and t1 != t0 and (await D.evaluate(STATUS))['st'] == 'PENDIENTE', {'aviso': a1, 'contador': [t0, t1]})
                # recuperación APARENTE: el navegador vuelve a «online» pero el servidor sigue sin responder
                await D.evaluate('()=>{window.__fail={comTrack:{code:"OFFLINE",msg:"Failed to fetch"}, comNotifications:{code:"OFFLINE",msg:"Failed to fetch"}}}')
                await ctx.set_offline(False)
                samples = []
                for _ in range(8): samples.append((await D.evaluate(CONN))['banner']); await D.wait_for_timeout(250)
                await nudge(D, 800); a2 = await D.evaluate(CONN); a2n = await D.evaluate('()=>navigator.onLine')
                res('V2-A2 RECUPERACIÓN APARENTE: con el navegador «online» pero el servidor sin responder, el aviso NO se quita (2,8 s de muestras y nuevos intentos): el evento «online» no alcanza',
                    a2n and all(samples) and a2['banner'] and a2['off'], {'muestras': samples, 'aviso': a2['kind']})
                await D.evaluate('()=>{window.__fail={comTrack:{code:"ERROR",msg:"PGRST500: error interno del servidor"}}}'); await nudge(D, 900); a3 = await D.evaluate(CONN)
                res('V2-A3 FALLA DEL SERVIDOR con red disponible: aviso distinto («No se pudo confirmar el estado con el servidor») y se mantiene', a3['banner'] and a3['kind'] == 'SERVIDOR' and 'No se pudo confirmar' in a3['txt'], a3)
                await D.evaluate('()=>{window.__fail={}}'); await nudge(D, 1200); a4 = await D.evaluate(CONN)
                await shot(D, 'A4_recuperacion_confirmada.png')
                res('V2-A4 RECUPERACIÓN REAL: solo cuando una consulta al servidor RESPONDE se quita el aviso y vuelve «Última consulta al servidor …»; los puntos siguen animados',
                    not a4['banner'] and not a4['off'] and 'Última consulta al servidor' in a4['sync'] and await D.evaluate('()=>getComputedStyle(document.querySelector("#comMain [data-az-dots] i")).animationPlayState') == 'running', a4)
                # sin consultas concurrentes: ráfaga de eventos con un servidor lento
                await D.evaluate('()=>{window.__cnt={}; window.__slow=600}')
                await D.evaluate('()=>{for(let i=0;i<6;i++){window.dispatchEvent(new Event("online")); document.dispatchEvent(new Event("visibilitychange"))}}'); await D.wait_for_timeout(2600)
                a5 = await D.evaluate('()=>window.__cnt'); await D.evaluate('()=>{window.__slow=0}')
                res('V2-A5 SIN CONSULTAS CONCURRENTES: 12 eventos seguidos (online + visibilidad) con servidor lento → como máximo 2 ciclos (uno en curso + UNO pendiente), nunca 12',
                    1 <= a5.get('comTrack', 0) <= 2 and a5.get('comNotifications', 0) <= 2, a5)
                # ================= C · ACTUALIZACIÓN AUTOMÁTICA =================
                # C1 bandeja del aprobador: llega una solicitud NUEVA sin recargar; selección y posición se conservan
                await W.bring_to_front(); await go(W, '#/autorizaciones?v=gerencia'); await select(W, ids['Y']); await W.set_viewport_size({'width': 1366, 'height': 640}); await W.evaluate('()=>window.scrollTo(0,350)')
                y0 = await W.evaluate('()=>window.scrollY'); n0 = await W.evaluate('()=>document.querySelectorAll("#comMain [data-select]").length')
                NEW = await mk('FINANCIACION', tec, 'V2-NUEVA', {'amount': 250000, 'installments': 1, 'first_due': d[3]})
                await nudge(W, 1500)
                c1 = await W.evaluate('(n)=>({n:document.querySelectorAll("#comMain [data-select]").length, nueva:!!document.querySelector(`#comMain [data-select="${n}"]`), sel:document.querySelector("#comMain .az").dataset.azId, y:window.scrollY})', NEW['id'])
                await W.set_viewport_size({'width': 1366, 'height': 950})
                res('V2-C1 BANDEJA DEL APROBADOR: una solicitud nueva aparece sola; la solicitud elegida y la posición se conservan', c1['nueva'] and c1['n'] == n0 + 1 and c1['sel'] == ids['Y'] and abs(c1['y'] - y0) <= 2, {'antes': [n0, y0], 'despues': c1})
                # C2 SESIONES SIMULTÁNEAS: Wilfredo tiene ABIERTA la ventana de decisión de X y escribe; Gabriela (otra sesión) la aprueba
                await select(W, ids['X']); await W.click('[data-dec="RECHAZAR"]'); await W.fill('#dReason', 'Motivo que estaba escribiendo Wilfredo')
                vX = (await api(G, 'comRequestDetail', ids['X']))['version']; await api(G, 'comDecide', ids['X'], vX, 'APROBAR', None, None)
                await nudge(W, 1500)
                c2 = await W.evaluate('''()=>({modal:!!document.querySelector("#comModal [data-dec-for]"), aviso:(document.querySelector("#comModal [data-dec-stale]")||{}).innerText||"", go:(document.getElementById("dGo")||{}).disabled, texto:(document.getElementById("dReason")||{}).value})''')
                await shot(W, 'C2_ventana_decision_protegida.png')
                await W.click('#comModal [data-close]'); await W.wait_for_timeout(1500)
                c2b = await W.evaluate('''()=>({az:(document.querySelector("#comMain .az")||{dataset:{}}).dataset, lost:!!document.querySelector("#comMain [data-az-lost]"), txt:(document.querySelector("#comMain .az")||{}).innerText||"", botones:document.querySelectorAll("#comMain [data-dec]").length})''')
                await detail_shot(W, 'C2b_bandeja_actualizada_tras_cerrar.png')
                res('V2-C2 SESIONES SIMULTÁNEAS: con la ventana de decisión ABIERTA, la aprobación de OTRA sesión no la cierra ni borra lo escrito; avisa y BLOQUEA confirmar; al cerrarla, la bandeja muestra «Aprobada» (resolvió Gabriela) sin recargar ni navegar, sin botones de decisión',
                    c2['modal'] and 'cambió en el servidor' in c2['aviso'] and 'Aprobada' in c2['aviso'] and c2['go'] and c2['texto'] == 'Motivo que estaba escribiendo Wilfredo'
                    and c2b['az'].get('azId') == ids['X'] and c2b['az'].get('azStatus') == 'APROBADA' and c2b['lost'] and 'Gabriela' in c2b['txt'] and c2b['botones'] == 0, {'ventana': c2, 'despues': {k: c2b[k] for k in ('az', 'lost', 'botones')}})
                await select(W, NEW['id'])
                await W.click('[data-dec="APROBAR_CON_CAMBIOS"]')
                await W.select_option('#dInst', '2')
                await W.select_option('#dFreq', 'SEMANAL')
                await W.fill('#dReason', 'Cambio de cuotas en revisión')
                valid_before = await W.locator('#dGo').is_enabled()
                version = (await api(G, 'comRequestDetail', NEW['id']))['version']
                await api(G, 'comDecide', NEW['id'], version, 'APROBAR', None, None)
                await nudge(W)
                await W.wait_for_selector('[data-dec-stale]')
                await W.select_option('#dInst', '3')
                await W.fill('#dAmount', '275000')
                res('V3 calendario válido editado después de una decisión remota mantiene Confirmar bloqueado',
                    valid_before and await W.locator('#dGo').is_disabled()
                    and await W.input_value('#dReason') == 'Cambio de cuotas en revisión')
                await W.click('#comModal [data-close]')
                # C3 RECHAZO desde otra sesión: Despacho y Comercial (dos pantallas abiertas) lo ven con el temporizador REAL de 20 s
                await D.bring_to_front(); await go(D, '#/autorizaciones?v=despacho'); await select(D, ids['Y'])
                await C.bring_to_front(); await go(C, '#/autorizaciones?v=comercial'); await C.evaluate('(id)=>{const b=document.querySelector(`#cRecent [data-select="${id}"]`); if(b) b.click()}', ids['Y']); await C.wait_for_timeout(500)
                vY = (await api(G, 'comRequestDetail', ids['Y']))['version']; await api(G, 'comDecide', ids['Y'], vY, 'RECHAZAR', None, 'Rechazada desde otra sesión')
                t_0 = time.time(); doneD = doneC = None
                while time.time() - t_0 < 26 and (doneD is None or doneC is None):
                    if doneD is None and (await D.evaluate(STATUS) or {}).get('st') == 'RECHAZADA': doneD = round(time.time() - t_0, 1)
                    if doneC is None and await C.evaluate('()=>(document.querySelector("#cRecent .az")||{dataset:{}}).dataset.azStatus') == 'RECHAZADA': doneC = round(time.time() - t_0, 1)
                    await C.wait_for_timeout(500)
                await D.bring_to_front(); await detail_shot(D, 'C3_despacho_rechazo_otra_sesion.png')
                res('V2-C3 RECHAZO desde otra sesión: Seguimiento de DESPACHO y de COMERCIAL lo muestran solos (consulta periódica existente de 20 s), sin recargar ni navegar', doneD is not None and doneC is not None, {'despacho_s': doneD, 'comercial_s': doneC})
                # C4 DETALLE ABIERTO DESDE UNA ALARMA: atención y aprobación se reflejan solas
                al = await api(D, 'comAlarmRaiseRequest', ids['Z'], 'Cliente esperando en mostrador', 'v2-al-z-0001')
                await go(D, '#/autorizaciones?alarma_sol=' + al['id']); await D.wait_for_selector('#comMain [data-alarma-sol]', timeout=10000)
                c4a = await D.evaluate('()=>({al:(document.querySelector("#comMain [data-urg-estado]")||{dataset:{}}).dataset.urgEstado, st:document.querySelector("#comMain .az").dataset.azStatus})')
                alv = await api(W, 'comMyAlarms'); alw = [x for x in alv if x['id'] == al['id']][0]
                await api(W, 'comAlarmAttend', al['id'], alw['version']); await nudge(D, 1300)
                c4b = await D.evaluate('()=>({al:(document.querySelector("#comMain [data-urg-estado]")||{dataset:{}}).dataset.urgEstado})')
                vZ = (await api(W, 'comRequestDetail', ids['Z']))['version']; await api(W, 'comDecide', ids['Z'], vZ, 'APROBAR', None, None); await nudge(D, 1300)
                c4c = await D.evaluate('()=>({st:document.querySelector("#comMain .az").dataset.azStatus, puntos:!!document.querySelector("#comMain [data-az-dots]"), hash:location.hash})')
                await detail_shot(D, 'C4_detalle_desde_alarma_actualizado.png', '#comMain [data-alarma-sol]')
                res('V2-C4 DETALLE ABIERTO DESDE UNA ALARMA: pasa solo de «Pendiente de atención» a «Atendida» y luego a «Aprobada» (sin puntos), sin recargar ni salir de la vista',
                    c4a == {'al': 'PENDIENTE', 'st': 'PENDIENTE'} and c4b['al'] == 'ATENDIDA' and c4c['st'] == 'APROBADA' and not c4c['puntos'] and 'alarma_sol=' in c4c['hash'], {'inicio': c4a, 'atendida': c4b, 'aprobada': c4c})
                # C5 FORMULARIO EN EDICIÓN en Despacho: «Solicitar aprobación urgente» abierto con texto mientras llega un cambio
                await go(D, '#/autorizaciones?v=despacho'); await select(D, ids['F']); await D.click('#rUrgentBtn'); await D.fill('#uReason', 'Texto que el operario está escribiendo')
                vF = (await api(W, 'comRequestDetail', ids['F']))['version']; await api(W, 'comDecide', ids['F'], vF, 'APROBAR', None, None); await nudge(D, 1500)
                c5 = await D.evaluate('()=>({modal:!!document.querySelector("#comModal [data-urg-modal]"), texto:(document.getElementById("uReason")||{}).value, detras:document.querySelector("#comMain .az").dataset.azStatus})')
                await D.click('#uCancel'); await D.wait_for_timeout(300)
                res('V2-C5 FORMULARIO EN EDICIÓN: la actualización NO cierra la ventana «Solicitar aprobación urgente» ni borra lo escrito; el detalle de atrás pasa a «Aprobada»',
                    c5['modal'] and c5['texto'] == 'Texto que el operario está escribiendo' and c5['detras'] == 'APROBADA', c5)
                # ================= PERMISOS Y MANIPULACIÓN =================
                pm = {}
                pm['desp_detalle'] = (await try_api(D, 'comRequestDetail', ids['M1'])).get('code')
                pm['desp_list'] = [(await try_api(D, 'comList', s_)).get('code') for s_ in ('MIS', 'BANDEJA', 'TODAS')]
                pm['desp_decide'] = (await try_api(D, 'comDecide', ids['NUEVA'] if 'NUEVA' in ids else NEW['id'], 1, 'APROBAR', None, None)).get('code')
                S2 = await ctx.new_page(); await dp.login(S2, 'comercial.sanjuan@okdespacho.demo'); await S2.wait_for_timeout(600)
                pm['ajeno_detalle'] = (await try_api(S2, 'comRequestDetail', ids['M1'])).get('code')
                pm['ajeno_alarma'] = (await try_api(S2, 'comAlarmRequestDetail', al['id'])).get('code')
                await S2.evaluate('(h)=>{location.hash=h}', '#/autorizaciones?alarma_sol=' + al['id']); await S2.wait_for_timeout(1800)
                pm['ajeno_vista'] = await S2.evaluate('()=>({az:!!document.querySelector("#comMain .az"), txt:(document.getElementById("comMain")||{}).innerText||""})')
                await S2.close()
                await db(C, 'const q=d.com.requests.find(x=>x.id===arg); q.client.razon_social="<img src=x onerror=window.__xss=1>CLIENTE"; q.updated_at=new Date().toISOString()', NEW['id'])
                await go(W, '#/autorizaciones?v=gerencia'); await select(W, NEW['id']); await nudge(W, 1500); pm['xss'] = await W.evaluate('(n)=>({ejecutado:!!window.__xss, texto:document.querySelector("#comMain .az h2").innerText, id:document.querySelector("#comMain .az").dataset.azId, esta:!!document.querySelector(`#comMain [data-select="${n}"]`), db:JSON.parse(localStorage.getItem("okd_online_demo_v2")).com.requests.find(x=>x.id===n).client.razon_social})', NEW['id'])
                res('V2-P1 PERMISOS Y MANIPULACIÓN: Despacho no obtiene detalle, bandejas ni decide (FORBIDDEN); otro Comercial no accede a solicitud ni alarma ajenas aunque conozca el id o arme el enlace (no se dibuja nada); datos con código no se ejecutan',
                    pm['desp_detalle'] == 'FORBIDDEN' and pm['desp_list'] == ['FORBIDDEN'] * 3 and pm['desp_decide'] == 'FORBIDDEN' and pm['ajeno_detalle'] == 'FORBIDDEN' and pm['ajeno_alarma'] in ('FORBIDDEN', 'NOT_FOUND')
                    and not pm['ajeno_vista']['az'] and not pm['xss']['ejecutado'] and '<img' in pm['xss']['texto'], pm)
                # ================= ANDROID =================
                state_db = await C.evaluate('()=>localStorage.getItem("%s")' % K)
                m = await b.new_context(viewport={'width': 390, 'height': 844}, is_mobile=True, has_touch=True, device_scale_factor=2); await m.add_init_script(INIT)
                M = await m.new_page(); await M.goto(URL()); await M.evaluate('(v)=>localStorage.setItem("%s", v)' % K, state_db)
                await dp.login(M, 'operario@okdespacho.demo'); await M.wait_for_timeout(600); await go(M, '#/autorizaciones?v=despacho')
                await M.evaluate('(id)=>document.querySelector(`#comMain [data-select="${id}"]`).scrollIntoView()', NEW['id']); await M.tap(f'#comMain [data-select="{NEW["id"]}"]'); await M.wait_for_timeout(900)
                n1 = await M.evaluate('()=>{const r=document.getElementById("tDetail").getBoundingClientRect(); return {top:Math.round(r.top), sel:document.querySelector("#comMain .az").dataset.azId}}')
                await M.screenshot(path=os.path.join(OUT, 'N1_android_detalle_al_tocar.png'))
                ctxdb = await M.evaluate('()=>localStorage.getItem("%s")' % K)
                vN = await M.evaluate('(id)=>JSON.parse(localStorage.getItem("%s")).com.requests.find(x=>x.id===id).version' % K, NEW['id'])
                await M.evaluate('''([id,v])=>{const d=JSON.parse(localStorage.getItem("%s")); const q=d.com.requests.find(x=>x.id===id); const at=new Date().toISOString();
                  q.status="APROBADA"; q.decided_by="u-wilfredo"; q.decided_at=at; q.final_terms=q.current_terms; q.version=v+1; q.updated_at=at;
                  d.com.events.push({request_id:id, seq:d.com.events.filter(e=>e.request_id===id).length+1, kind:"APROBADA", actor_id:"u-wilfredo", actor_label:"Wilfredo Guzmán", assigned:"u-wilfredo", reason:null, terms_before:null, terms_after:q.final_terms, at});
                  localStorage.setItem("%s", JSON.stringify(d));}''' % (K, K), [NEW['id'], vN])   # equivale a la decisión de Wilfredo en el servidor
                await nudge(M, 1500)
                n2 = await M.evaluate('()=>({st:document.querySelector("#comMain .az").dataset.azStatus, ov:document.documentElement.scrollWidth-document.documentElement.clientWidth})')
                await M.evaluate('()=>document.getElementById("tSearch").scrollIntoView()'); await M.fill('#tSearch', 'V2-M'); await M.wait_for_timeout(1300)
                n3 = await M.evaluate('()=>({q:document.getElementById("tSearch").value, n:document.querySelectorAll("#comMain [data-select]").length, ov:document.documentElement.scrollWidth-document.documentElement.clientWidth})')
                await M.evaluate('(id)=>document.querySelector(`#comMain [data-select="${id}"]`).scrollIntoView()', ids['M1']); await M.tap(f'#comMain [data-select="{ids["M1"]}"]'); await M.wait_for_timeout(900)
                await M.screenshot(path=os.path.join(OUT, 'N2_android_cambios_reservados.png')); await m.close()
                res('V2-N1 ANDROID: al tocar una solicitud el detalle queda a la vista; se actualiza solo a «Aprobada»; la búsqueda filtra; sin desplazamiento horizontal',
                    -5 <= n1['top'] <= 200 and n1['sel'] == NEW['id'] and n2['st'] == 'APROBADA' and n2['ov'] <= 0 and n3['n'] == 3 and n3['ov'] <= 0, {'tocar': n1, 'actualiza': n2, 'busqueda': n3})
                # ================= SIN DUPLICADOS (reposo 45 s) =================
                await D.bring_to_front(); await go(D, '#/autorizaciones?v=despacho'); await D.evaluate(COUNT); await D.evaluate('()=>{window.__cnt={}}')
                iv = await D.evaluate('()=>window.__iv()'); await D.wait_for_timeout(45000); cnt = await D.evaluate('()=>window.__cnt'); iv2 = await D.evaluate('()=>window.__iv()')
                res('V2-D1 REPOSO 45 s en Seguimiento: 2 ciclos de 20 s = 2 consultas de seguimiento y 2 de avisos (nunca más); UN contador de 1 s y UNA consulta periódica de 20 s del módulo',
                    cnt.get('comTrack', 0) in (2, 3) and cnt.get('comNotifications', 0) in (2, 3) and iv.get('1000') == 1 == iv2.get('1000') and iv2.get('20000') == 1, {'consultas': cnt, 'intervalos': iv2})
                # ================= SESIÓN REVOCADA Y VENCIDA =================
                await select(D, ids['M1']); await db(D, 'const u=d.users.find(x=>x.id==="u-operario"); u.session_epoch=(u.session_epoch||0)+1')
                await nudge(D, 2000)
                r1 = await D.evaluate('()=>({az:!!document.querySelector("#comMain .az"), bloqueo:!!document.querySelector("[data-az-locked]"), login:!!document.getElementById("loginEmail"), iv:window.__iv()})')
                await shot(D, 'R1_sesion_revocada.png')
                res('V2-R1 SESIÓN REVOCADA por Administración: en el siguiente ciclo deja de mostrarse la información (sin detalle ni datos) y se detiene el contador',
                    not r1['az'] and (r1['bloqueo'] or r1['login']) and r1['iv'].get('1000', 0) == 0, r1)
                X2 = await ctx.new_page(); await dp.login(X2, 'operario@okdespacho.demo'); await X2.wait_for_timeout(600); await go(X2, '#/autorizaciones?v=despacho')
                pre = await X2.evaluate('()=>({az:!!document.querySelector("#comMain .az"), iv:window.__iv()})')
                await X2.evaluate('()=>window.dispatchEvent(new CustomEvent("okd-session-expired"))'); await X2.wait_for_timeout(1500)
                r2 = await X2.evaluate('()=>({app:!!document.querySelector(".com-app"), login:!!document.getElementById("loginEmail"), iv:window.__iv(), txt:document.body.innerText.slice(0,200)})')
                res('V2-R2 SESIÓN VENCIDA: vuelve al acceso con aviso; desaparecen la pantalla del módulo, el contador y la consulta periódica', pre['az'] and not r2['app'] and r2['login'] and r2['iv'].get('1000', 0) == 0 and r2['iv'].get('20000', 0) == 0, {'antes': pre, 'despues': r2})
            finally: await b.close()
    finally: srv.terminate()
    print('TOTAL', sum(1 for r in R if r[1] == 'PASS'), 'PASS /', sum(1 for r in R if r[1] == 'FAIL'), 'FAIL · esperados', EXPECTED)
    return R
if __name__ == '__main__':
    try: rr = asyncio.run(main())
    except Exception as e: traceback.print_exc(); print('ERROR:', repr(e)); sys.exit(2)
    if len(rr) != EXPECTED: print('ERROR: se ejecutaron %d de %d' % (len(rr), EXPECTED)); sys.exit(2)
    sys.exit(1 if any(r[1] != 'PASS' for r in rr) else 0)
