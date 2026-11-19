"""E2E BLOQUEANTE (modo demo, Chromium REAL) · MEJORA VISUAL, ANIMACIÓN Y TRAZABILIDAD DE AUTORIZACIONES COMERCIALES.
Cubre las pruebas 1-25 y 28 del requerimiento (las 26, 27, 29 y 30 se ejecutan con sus suites propias). Datos SINTÉTICOS de la demo
(localStorage del navegador); sin servidor, sin SQL y sin correos reales. Las páginas de Comercial, Aprobador y Despacho comparten la
misma «base» (mismo contexto del navegador) como si fuera el servidor común; cada una tiene su propia sesión.
Uso: python3 tests/e2e/run_com_seguimiento_visual.py <dist-demo> <carpeta_evidencias>"""
import asyncio, os, sys, json, re, time, traceback
sys.path.insert(0, os.path.dirname(__file__))
import run_driver_perfiles as dp
from playwright.async_api import async_playwright
dp.PORT = 4531; R = []; EXPECTED = 32
if len(sys.argv) > 1: dp.DIST = sys.argv[1]
OUT = sys.argv[2] if len(sys.argv) > 2 else '/tmp/okd_com_visual'
K = 'okd_online_demo_v2'
URL = lambda: f'http://127.0.0.1:{dp.PORT}/'
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:600])); print('..', ' | '.join(R[-1]), flush=True)
OV = '()=>document.documentElement.scrollWidth-document.documentElement.clientWidth'
AR_PLUS = '(n)=>{const t=new Intl.DateTimeFormat("en-CA",{timeZone:"America/Argentina/Mendoza"}).format(new Date()); const d=new Date(t+"T12:00:00Z"); d.setUTCDate(d.getUTCDate()+n); return d.toISOString().slice(0,10)}'
LONG_COM = 'María Fernanda de los Ángeles Etcheverry Larrañaga Montes de Oca (Cartera Gran Mendoza y Valle de Uco)'
LONG_CLI = 'DISTRIBUIDORA INTEGRAL DE ACCESORIOS Y REPUESTOS DEL CENTRO OESTE ARGENTINO SOCIEDAD ANÓNIMA COMERCIAL E INDUSTRIAL'
LONG_NOTE = ('Cliente histórico con pagos regulares. Solicita financiación por compra estacional de accesorios; adjunta compromiso de pago firmado por el '
             'responsable de compras. Se aclara que el pedido se retira en dos etapas y que el saldo anterior fue cancelado el mes pasado sin demoras. ') * 2
LONG_REASON = ('No se autoriza: el cliente registra comprobantes vencidos sin conciliar y el importe supera el techo vigente. Regularizar el saldo vencido, '
               'enviar el comprobante de pago y volver a solicitar con un plan de cuotas más corto. Observación extensa para verificar saltos de línea.')
# instrumentación: temporizadores (1 s contador, 20 s actualización) y oyentes online/offline/visibilidad activos
INIT = r'''(()=>{const act=new Map(); const si=window.setInterval.bind(window), ci=window.clearInterval.bind(window);
  window.setInterval=function(f,d,...a){const id=si(f,d,...a); act.set(id,d); return id}; window.clearInterval=function(id){act.delete(id); return ci(id)};
  window.__iv=()=>{const o={}; for(const d of act.values()){o[d]=(o[d]||0)+1} return o};
  const L={online:0,offline:0,visibilitychange:0}; const ae=EventTarget.prototype.addEventListener, re=EventTarget.prototype.removeEventListener;
  EventTarget.prototype.addEventListener=function(t,...a){if(t in L&&(this===window||this===document))L[t]++; return ae.call(this,t,...a)};
  EventTarget.prototype.removeEventListener=function(t,...a){if(t in L&&(this===window||this===document))L[t]--; return re.call(this,t,...a)};
  window.__ls=()=>({...L});})()'''
NOCLIP = r'''(sel)=>{const root=document.querySelector(sel); if(!root) return {err:'sin '+sel}; const bad=[];
  root.querySelectorAll('*').forEach(e=>{ if(!e.childNodes.length) return; const cs=getComputedStyle(e); if(cs.display==='none'||cs.visibility==='hidden') return;
    const hasText=[...e.childNodes].some(n=>n.nodeType===3&&n.textContent.trim()); if(!hasText) return;
    if(cs.textOverflow==='ellipsis'&&cs.overflow!=='visible'&&e.scrollWidth>e.clientWidth+1) bad.push('ELIPSIS '+e.className+': '+e.textContent.trim().slice(0,40));
    else if(cs.overflowX!=='visible'&&e.scrollWidth>e.clientWidth+1&&!e.matches('.az-tblwrap')) bad.push('RECORTE '+e.tagName+'.'+e.className+': '+e.textContent.trim().slice(0,40));
    const r=e.getBoundingClientRect(), rr=root.getBoundingClientRect(); if(r.width&&(r.right>rr.right+1||r.left<rr.left-1)) bad.push('FUERA '+e.tagName+'.'+e.className+': '+e.textContent.trim().slice(0,30)); });
  return {bad:bad.slice(0,8), n:bad.length}}'''
STATE = '''()=>{const a=document.querySelector("#comMain .az"); if(!a) return null; const s=a.querySelector(".az-state"); const dots=a.querySelector("[data-az-dots]");
  return {id:a.dataset.azId, status:a.dataset.azStatus, cls:s&&s.className, h3:s&&s.querySelector("h3").innerText, info:s?[...s.querySelectorAll("dt")].map(e=>e.innerText):[],
    dots:!!dots, anims:dots?dots.getAnimations({subtree:true}).length:0, timer:(a.querySelector("[data-wait-since]")||{}).textContent||null, since:(a.querySelector("[data-wait-since]")||{dataset:{}}).dataset.waitSince||null,
    total:(a.querySelector("[data-wait-total]")||{}).textContent||null, text:a.innerText.replace(/\\s+/g," ")}}'''
API = '''async([fn,args])=>{try{return {ok:true, v:await window.OKD_ONLINE.api[fn](...args)}}catch(e){return {ok:false, code:e.code, msg:String(e.message)}}}'''
async def api(pg, fn, *args):
    r = await pg.evaluate(API, [fn, list(args)])
    if not r['ok']: raise RuntimeError(fn + ' ' + str(r))
    return r['v']
async def db(pg, js, arg=None):   # lectura/edición SINTÉTICA de la base de la demo (equivale a datos de prueba en el servidor)
    return await pg.evaluate('''([js,arg])=>{const d=JSON.parse(localStorage.getItem("%s")); const r=(new Function("d","arg",js))(d,arg); localStorage.setItem("%s",JSON.stringify(d)); return r}''' % (K, K), [js, arg])
async def open_tab(pg, v):
    await pg.evaluate('(v)=>{location.hash="#/autorizaciones?v="+v}', v); await pg.wait_for_selector('#comMain .heading', timeout=15000); await pg.wait_for_timeout(700)
async def select(pg, rid):
    await pg.evaluate('(id)=>{const b=document.querySelector(`#comMain [data-select="${id}"]`); if(b) b.click()}', rid); await pg.wait_for_timeout(500)
async def wait_status(pg, rid, status, timeout=30):
    t0 = time.time()
    while time.time() - t0 < timeout:
        s = await pg.evaluate(STATE)
        if s and s['id'] == rid and s['status'] == status: return s, time.time() - t0
        await pg.wait_for_timeout(500)
    return await pg.evaluate(STATE), None
async def hist_open(pg, rid):   # Historial → detalle de la solicitud (como lo haría el usuario)
    await pg.evaluate('()=>{location.hash="#/autorizaciones?v=historial"}'); await pg.reload(); await pg.wait_for_selector('#comMain .heading, #hBack', timeout=15000); await pg.wait_for_timeout(500)
    if await pg.locator('#hBack').count(): await pg.click('#hBack'); await pg.wait_for_timeout(600)
    await pg.evaluate('(id)=>document.querySelector(`[data-hid="${id}"]`).click()', rid); await pg.wait_for_selector('#comMain .az', timeout=15000); await pg.wait_for_timeout(500)
async def shot(pg, name, full=True):
    await pg.screenshot(path=os.path.join(OUT, name), full_page=full)
async def detail_shot(pg, name):   # evidencia: la ventana se agranda para que el detalle entre completo (sin capas de la app por debajo)
    vp = pg.viewport_size; el = pg.locator('#comMain .az').first
    h = await pg.evaluate('()=>{const e=document.querySelector("#comMain .az"); return Math.ceil(e.getBoundingClientRect().height + window.scrollY + e.getBoundingClientRect().top + 200)}')
    await pg.set_viewport_size({'width': vp['width'], 'height': min(max(h, vp['height']), 7000)}); await pg.wait_for_timeout(250)
    await el.screenshot(path=os.path.join(OUT, name)); await pg.set_viewport_size(vp)

async def main():
    os.makedirs(OUT, exist_ok=True); srv = dp.serve()
    try:
        async with async_playwright() as p:
            b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
            try:
                ctx = await b.new_context(viewport={'width': 1366, 'height': 950}, device_scale_factor=1); await ctx.add_init_script(INIT)
                C = await ctx.new_page(); await C.goto(URL()); await C.evaluate('()=>localStorage.clear()')
                await dp.login(C, 'admin@okdespacho.demo'); await C.wait_for_timeout(800)   # siembra la demo
                await db(C, 'd.users.find(u=>u.id==="u-com-mc").full_name=arg', LONG_COM)
                await C.evaluate('async()=>{try{await window.OKD_ONLINE.api.signOut()}catch(e){}}')
                await dp.login(C, 'comercial.montecaseros@okdespacho.demo'); await C.wait_for_selector('#cSearch', timeout=20000)
                d = {n: await C.evaluate(AR_PLUS, n) for n in (1, 3, 5, 7, 8, 10, 14, 15, 20, 21, 25, 29, 30)}
                tec = [c for c in await api(C, 'comSearchClients', 'TECNO') if c['selectable']][0]
                cuy = [c for c in await api(C, 'comSearchClients', 'COMERCIAL CUYO') if c['selectable']][0]
                mk = lambda kind, cli, ref, t, notes=None: api(C, 'comCreate', kind, cli['id'], ref, t, notes, 'op-vis-' + ref)
                A = await mk('FINANCIACION', tec, 'VIS-A', {'amount': 2500000, 'installments': 4, 'frequency': 'SEMANAL', 'first_due': d[3]}, LONG_NOTE)
                B = await mk('FINANCIACION', cuy, 'VIS-B', {'amount': 1000000, 'installments': 3, 'frequency': 'SEMANAL', 'first_due': d[7]})
                Cc = await mk('FINANCIACION', tec, 'VIS-C', {'amount': 1800000, 'installments': 2, 'frequency': 'QUINCENAL', 'first_due': d[10]})
                E = await mk('ECHEQ', cuy, 'VIS-E', {'amount': 950000.5, 'due_date': d[20], 'issuer_name': '', 'issuer_cuit': ''})
                F = await mk('FINANCIACION', tec, 'VIS-F', {'amount': 600000, 'installments': 1, 'first_due': d[8]})
                G = await mk('FINANCIACION', cuy, 'VIS-G', {'amount': 3000000, 'installments': 5, 'frequency': 'SEMANAL', 'first_due': d[1]})
                H = await mk('FINANCIACION', tec, 'VIS-H', {'amount': 400000, 'installments': 2, 'frequency': 'SEMANAL', 'first_due': d[5]})
                ids = {k: v['id'] for k, v in dict(A=A, B=B, C=Cc, E=E, F=F, G=G, H=H).items()}
                # datos SINTÉTICOS: A lleva 7 min 24 s esperando; razón social extensa en B
                ago = int(time.time() * 1000) - (7 * 60 + 24) * 1000
                await db(C, '''const iso=new Date(arg.t).toISOString(); const q=d.com.requests.find(x=>x.id===arg.id); q.created_at=iso; q.updated_at=iso;
                  d.com.events.filter(e=>e.request_id===arg.id).forEach(e=>e.at=iso);''', {'id': ids['A'], 't': ago})
                await db(C, 'd.com.requests.find(x=>x.id===arg.id).client.razon_social=arg.n', {'id': ids['B'], 'n': LONG_CLI})
                # ---------- páginas: Aprobador (Wilfredo) y Despacho (operario) en el MISMO «servidor» ----------
                W = await ctx.new_page(); await dp.login(W, 'wilfredo@okdespacho.demo'); await W.wait_for_timeout(600)
                D = await ctx.new_page(); await dp.login(D, 'operario@okdespacho.demo'); await D.wait_for_timeout(600)
                iv0 = await D.evaluate('()=>window.__iv()')
                await open_tab(D, 'despacho'); await select(D, ids['A'])
                # ===== 8 · solicitud pendiente: bloque amarillo completo =====
                s8 = await D.evaluate(STATE)
                need = ['Autorización', 'Estado actual', 'Responsable asignado', 'Enviada', 'Último cambio de estado', 'Tiempo de espera']
                res('VT-08 PENDIENTE: bloque amarillo «Esperando aprobación de Administración» + «Solicitud enviada correctamente. Aún no está autorizada.» con N.º, estado, responsable, envío, último cambio y tiempo de espera',
                    s8 and 'pending' in s8['cls'] and 'Esperando aprobación de Administración' in s8['h3'] and 'Aún no está autorizada' in s8['text'] and all(k in s8['info'] for k in need)
                    and A['number'] in s8['text'] and 'Wilfredo' in s8['text'], s8 and {'info': s8['info'], 'h3': s8['h3']})
                await shot(D, 'E01_despacho_pendiente_escritorio.png', False); await detail_shot(D, 'E02_detalle_pendiente_escritorio.png')
                # ===== 12 · contador con datos REALES (último ingreso a pendiente, 7 min 24 s antes) =====
                ev_at = await db(D, 'return d.com.events.filter(e=>e.request_id===arg&&e.kind==="PENDIENTE").pop().at', ids['A'])
                await D.wait_for_timeout(1200); s12 = await D.evaluate(STATE)
                mm = re.match(r'(\d+) min (\d+) seg', s12['timer'] or ''); secs = int(mm.group(1)) * 60 + int(mm.group(2)) if mm else -1
                res('VT-12 el contador usa la fecha REAL del último ingreso a pendiente (servidor) y avanza solo: «07 min 2x seg»',
                    s12['since'] == ev_at and 444 <= secs <= 470 and s12['timer'].startswith('07 min'), {'contador': s12['timer'], 'desde': s12['since'], 'evento': ev_at})
                # ===== 9 y 10 · animación secuencial continua, sin desplazar contenido =====
                anim = await D.evaluate('''()=>{const ds=[...document.querySelectorAll("#comMain [data-az-dots] i")]; return ds.map(e=>{const c=getComputedStyle(e); return {name:c.animationName, dur:c.animationDuration, delay:c.animationDelay, iter:c.animationIterationCount}})}''')
                samples = []
                for i in range(14):
                    samples.append(await D.evaluate('''()=>{const ds=[...document.querySelectorAll("#comMain [data-az-dots] i")]; const h=document.querySelector("#comMain .az-state h3"), p=document.querySelector("#comMain .az-state p"), w=document.querySelector("#comMain .az-waitinfo");
                      return {o:ds.map(e=>+getComputedStyle(e).opacity), box:document.querySelector("#comMain [data-az-dots]").getBoundingClientRect().toJSON(), h:h.getBoundingClientRect().toJSON(), p:p.getBoundingClientRect().toJSON(), w:w.getBoundingClientRect().top}}'''))
                    await D.wait_for_timeout(100)
                peaks = [max(range(3), key=lambda k: s['o'][k]) for s in samples]
                seq = [x for i, x in enumerate(peaks) if i == 0 or x != peaks[i - 1]]
                res('VT-09 los tres puntos se animan en SECUENCIA (1 → 2 → 3 → vuelve) con CSS/keyframes: ciclo 1,35 s, desfase 0 / 0,2 / 0,4 s, infinito',
                    all(a['name'] == 'azDot' and a['dur'] == '1.35s' and a['iter'] == 'infinite' for a in anim) and [a['delay'] for a in anim] == ['0s', '0.2s', '0.4s']
                    and any(seq[i:i + 3] == [0, 1, 2] for i in range(len(seq))), {'anim': anim, 'secuencia_de_picos': seq})
                dsz = await D.evaluate('()=>[...document.querySelectorAll("#comMain [data-az-dots] i")].map(e=>[e.offsetWidth,e.offsetHeight])')
                stable = lambda k: len({json.dumps(s[k]) for s in samples}) == 1
                res('VT-10 animación continua SIN desplazamiento: el contenedor de los puntos, el título, el texto y los datos no se mueven durante 1,4 s (solo cambian opacidad/escala)',
                    dsz == [[7, 7]] * 3 and stable('box') and stable('h') and stable('p') and stable('w') and len({tuple(s['o']) for s in samples}) > 3, {'variaciones_opacidad': len({tuple(s['o']) for s in samples}), 'tamano_puntos_px': dsz})
                # cuadros para el GIF de evidencia (animación + contador)
                fr = os.path.join(OUT, '_frames'); os.makedirs(fr, exist_ok=True)
                box = await D.locator('#comMain .az-state').bounding_box()
                for i in range(36):
                    await D.screenshot(path=os.path.join(fr, 'f%03d.png' % i), clip={'x': box['x'] - 4, 'y': box['y'] - 4, 'width': box['width'] + 8, 'height': box['height'] + 8}); await D.wait_for_timeout(85)
                # ===== 13 · el contador NO se reinicia al recargar ni al navegar =====
                before = (await D.evaluate(STATE))['timer']
                await D.reload(); await D.wait_for_timeout(1500); await open_tab(D, 'despacho'); await select(D, ids['A']); s13 = await D.evaluate(STATE)
                tosec = lambda t: (lambda m: int(m.group(1)) * 60 + int(m.group(2)) if m else -1)(re.match(r'(\d+) min (\d+) seg', t or ''))
                res('VT-13 al RECARGAR y volver a la solicitud el contador continúa (no vuelve a cero): mismo instante de origen y valor mayor o igual',
                    s13['since'] == ev_at and tosec(s13['timer']) >= tosec(before) >= 444, {'antes': before, 'despues': s13['timer']})
                # ===== 19 · varias pendientes a la vez: cada una con su contador en la lista, UN solo temporizador =====
                await D.wait_for_timeout(300)
                pend = await D.evaluate('()=>[...document.querySelectorAll("#comMain .az-req[data-st=PENDIENTE]")].map(b=>({n:b.innerText.split("\\n")[0], t:(b.querySelector("[data-wait-since]")||{}).textContent||null}))')
                iv = await D.evaluate('()=>window.__iv()')
                res('VT-19 VARIAS solicitudes pendientes simultáneas: cada una muestra su franja amarilla y su propio tiempo de espera; un ÚNICO temporizador de 1 s actualiza todos',
                    len(pend) >= 6 and all(x['t'] for x in pend) and iv.get('1000') == 1, {'pendientes': len(pend), 'intervalos': iv, 'ej': pend[:3]})
                # ===== 1, 2, 3, 4, 5 · importes, fechas, nombres y observaciones COMPLETOS; calendarios de 1 a 5 cuotas =====
                await C.bring_to_front(); await open_tab(C, 'historial')
                cal_ok, details = True, {}
                for k, n in (('F', 1), ('H', 2), ('B', 3), ('A', 4), ('G', 5)):
                    rows = None
                    await hist_open(C, ids[k])
                    rows = await C.evaluate('''()=>({rows:[...document.querySelectorAll("#comMain [data-cal-detalle] tbody tr")].map(t=>[...t.cells].map(c=>c.innerText.trim())), total:(document.querySelector("#comMain [data-cal-detalle] tfoot")||{}).innerText||""})''')
                    clip = await C.evaluate(NOCLIP, '#comMain .az')
                    details[k] = {'n': n, 'filas': len(rows['rows']), 'primera': rows['rows'][:1], 'total': rows['total'].replace('\t', ' | '), 'recortes': clip}
                    cal_ok = cal_ok and len(rows['rows']) == n and all(r[0] == f'{i + 1} de {n}' and re.fullmatch(r'\d{2}/\d{2}/\d{4}', r[1]) and r[2].startswith('$ ') for i, r in enumerate(rows['rows'])) and clip['n'] == 0
                    if k == 'B': await detail_shot(C, 'E03_calendario_3_cuotas_decimales.png')
                    if k == 'G': await detail_shot(C, 'E04_calendario_5_cuotas.png')
                res('VT-05 calendarios de 1, 2, 3, 4 y 5 cuotas en TABLA: «n de k», vencimiento dd/mm/aaaa, importe y total; sin recortes', cal_ok, details)
                await hist_open(C, ids['B'])
                tb = await C.evaluate('()=>[...document.querySelectorAll("#comMain [data-cal-detalle] tbody td:last-child, #comMain [data-cal-detalle] tfoot td:last-child, #comMain .az-amounts b")].map(e=>({t:e.innerText, w:e.scrollWidth<=e.clientWidth+1}))')
                res('VT-01 importes COMPLETOS con formato argentino y decimales cuando corresponden ($ 333.333,33 · $ 333.333,34 · total $ 1.000.000), sin recortes',
                    [x['t'] for x in tb] == ['$ 1.000.000', '$ 333.333,33', '$ 333.333,33', '$ 333.333,34', '$ 1.000.000'] and all(x['w'] for x in tb), tb)
                dues = await C.evaluate('()=>[...document.querySelectorAll("#comMain [data-cal-due]")].map(e=>({t:e.innerText, w:e.scrollWidth<=e.clientWidth+1}))')
                meta = await C.evaluate('()=>document.querySelector("#comMain .az-calmeta").innerText')
                dmy = lambda iso: '/'.join(reversed(iso.split('-')))
                res('VT-02 fechas de vencimiento COMPLETAS (dd/mm/aaaa) y fecha límite, cantidad, frecuencia y total visibles',
                    [x['t'] for x in dues] == [dmy(d[7]), dmy(d[14]), dmy(d[21])] and all(x['w'] for x in dues)
                    and all(k in meta for k in ['CUOTAS', 'FRECUENCIA', 'FECHA LÍMITE', 'TOTAL', 'Semanal']), dues)
                txt = await C.evaluate('()=>document.querySelector("#comMain .az").innerText')
                clipB = await C.evaluate(NOCLIP, '#comMain .az')
                res('VT-03 nombres EXTENSOS (Comercial de 104 caracteres y razón social de 112) completos, con saltos de línea, sin puntos suspensivos ni superposición',
                    LONG_COM in txt and LONG_CLI in txt and clipB['n'] == 0 and '…' not in txt, clipB)
                # observaciones extensas: notas del Comercial + motivo de rechazo (ver VT-16)
                await hist_open(C, ids['A'])
                txtA = await C.evaluate('()=>document.querySelector("#comMain .az").innerText.replace(/\\s+/g," ")')
                # ===== 14 y 15 · APROBACIÓN durante la espera: Despacho la ve SIN recargar (temporizador real de 20 s) =====
                await D.bring_to_front(); await open_tab(D, 'despacho'); await select(D, ids['A']); y0 = await D.evaluate('()=>window.scrollY')
                vA = (await api(W, 'comRequestDetail', ids['A']))['version']; await api(W, 'comDecide', ids['A'], vA, 'APROBAR', None, None)
                s15, secs15 = await wait_status(D, ids['A'], 'APROBADA', 30)
                res('VT-14 el estado se actualiza SIN recargar: la página de Despacho no se toca y en ≤ 20 s (consulta periódica existente) muestra la aprobación del servidor',
                    secs15 is not None and secs15 <= 24, {'segundos': secs15 and round(secs15, 1)})
                res('VT-15 APROBACIÓN durante la espera: verde «Solicitud aprobada», resolvió Wilfredo con fecha y hora, tiempo total pendiente; puntos y contador DETENIDOS',
                    s15 and 'approved' in s15['cls'] and 'Solicitud aprobada' in s15['h3'] and 'Wilfredo' in s15['text'] and not s15['dots'] and s15['anims'] == 0 and s15['timer'] is None and s15['total'] and re.match(r'0[789] min', s15['total']),
                    s15 and {'h3': s15['h3'], 'total': s15['total'], 'puntos': s15['dots']})
                res('VT-11 la animación se DETIENE apenas el servidor confirma la resolución (sin elementos animados ni contador vivo en el detalle)',
                    s15 and not s15['dots'] and s15['anims'] == 0 and await D.evaluate('()=>document.querySelectorAll("#comMain .az [data-wait-since]").length') == 0, s15 and s15['status'])
                await shot(D, 'E05_despacho_aprobada_escritorio.png', False); await detail_shot(D, 'E06_detalle_aprobada.png')
                # ===== 16 · RECHAZO durante la espera, con motivo extenso =====
                await select(D, ids['B']); vB = (await api(W, 'comRequestDetail', ids['B']))['version']; await api(W, 'comDecide', ids['B'], vB, 'RECHAZAR', None, LONG_REASON)
                s16, secs16 = await wait_status(D, ids['B'], 'RECHAZADA', 30)
                res('VT-16 RECHAZO durante la espera: rojo «Solicitud rechazada», responsable, fecha y hora; sin animación. (Despacho no ve el motivo: permisos vigentes, el servidor no lo envía)',
                    s16 and 'rejected' in s16['cls'] and 'Solicitud rechazada' in s16['h3'] and not s16['dots'] and secs16 is not None and LONG_REASON not in s16['text'], s16 and {'h3': s16['h3'], 's': secs16})
                await detail_shot(D, 'E07_detalle_rechazada_despacho.png')
                await C.bring_to_front(); await hist_open(C, ids['B'])
                rb = await C.evaluate('()=>({t:(document.querySelector("#comMain .az-resol")||{}).innerText||"", ev:(document.querySelector("#comMain .az-ev[data-ev=RECHAZADA] .az-evnote")||{}).innerText||""})')
                clipR = await C.evaluate(NOCLIP, '#comMain .az')
                res('VT-04 OBSERVACIONES extensas completas: notas del Comercial (550+ caracteres) y motivo de rechazo en «Resolución administrativa» y en la trazabilidad, para quien tiene permiso; sin recortes',
                    LONG_NOTE.strip()[:300] in txtA and LONG_REASON in rb['t'] and LONG_REASON in rb['ev'] and clipR['n'] == 0, {'recortes': clipR})
                await detail_shot(C, 'E08_detalle_rechazada_comercial_motivo.png')
                # ===== 7 · APROBACIÓN CON CAMBIOS: calendario solicitado y autorizado por separado =====
                vC = (await api(W, 'comRequestDetail', ids['C']))['version']
                await api(W, 'comDecide', ids['C'], vC, 'APROBAR_CON_CAMBIOS', {'amount': 1500000, 'installments': 3, 'frequency': 'SEMANAL', 'first_due': d[7]}, 'Se reduce el importe y se acorta el plazo')
                await hist_open(C, ids['C'])
                c7 = await C.evaluate('()=>[...document.querySelectorAll("#comMain [data-cal-detalle] .az-calbox")].map(b=>({t:b.querySelector("h4").innerText, n:b.querySelectorAll("tbody tr").length, total:(b.querySelector("tfoot")||{}).innerText||""}))')
                s7 = await C.evaluate(STATE)
                res('VT-07 APROBADA CON CAMBIOS (azul): calendario SOLICITADO (2 quincenales, $ 1.800.000) y AUTORIZADO (3 semanales, $ 1.500.000) por separado; importe autorizado destacado',
                    len(c7) == 2 and 'SOLICITADO' in c7[0]['t'].upper() and c7[0]['n'] == 2 and '1.800.000' in c7[0]['total'] and 'AUTORIZADO' in c7[1]['t'].upper() and c7[1]['n'] == 3 and '1.500.000' in c7[1]['total']
                    and 'changed' in s7['cls'] and 'IMPORTE AUTORIZADO' in s7['text'].upper(), c7)
                await detail_shot(C, 'E09_detalle_aprobada_con_cambios.png')
                # ===== 6 · FINANCIACIÓN y E-CHEQ =====
                await hist_open(C, ids['E'])
                e6 = await C.evaluate('()=>({t:(document.querySelector("#comMain [data-cal-echeq]")||{}).innerText||"", eyebrow:document.querySelector("#comMain .az .eyebrow").innerText})')
                res('VT-06 FINANCIACIÓN PROPIA (tabla de cuotas) y E-CHEQ (instrumento, vencimiento completo, importe con decimales $ 950.000,50 y emisor)',
                    cal_ok and 'E-cheq' in e6['t'] and dmy(d[20]) in e6['t'] and '$ 950.000,50' in e6['t'] and 'Emisor' in e6['t'] and 'E-CHEQ' in e6['eyebrow'].upper(), e6)
                await detail_shot(C, 'E10_detalle_echeq_pendiente.png')
                # ===== 17 · DEVOLUCIÓN y CANCELACIÓN, vistas por Despacho sin recargar =====
                await D.bring_to_front(); await select(D, ids['E'])
                vE = (await api(W, 'comRequestDetail', ids['E']))['version']
                await api(W, 'comDecide', ids['E'], vE, 'DEVOLVER', {'amount': 800000, 'due_date': d[15], 'issuer_name': '', 'issuer_cuit': ''}, 'Bajar el importe a $ 800.000')
                s17a, _ = await wait_status(D, ids['E'], 'DEVUELTA', 30); await detail_shot(D, 'E11_detalle_devuelta.png')
                vE2 = (await api(C, 'comRequestDetail', ids['E']))['version']; await api(C, 'comRespond', ids['E'], vE2, False, 'El cliente desiste')
                s17b, _ = await wait_status(D, ids['E'], 'CANCELADA', 30); await detail_shot(D, 'E12_detalle_cancelada.png')
                res('VT-17 DEVOLUCIÓN (naranja ↩, «NO es una aprobación») y CANCELACIÓN (gris ⊘, «Retirada por Comercial») actualizadas solas en Despacho',
                    s17a and 'returned' in s17a['cls'] and 'NO es una aprobación' in s17a['text'] and s17b and 'neutral' in s17b['cls'] and 'Retirada por Comercial' in s17b['h3'] and not s17b['dots'],
                    {'devuelta': s17a and s17a['h3'], 'cancelada': s17b and s17b['h3']})
                # trazabilidad: solo eventos registrados, con fecha, hora, usuario y rol; paso futuro rotulado
                await select(D, ids['F']); tlF = await D.evaluate('()=>[...document.querySelectorAll("#comMain .az-ev")].map(e=>({k:e.dataset.ev, cls:e.className, t:e.innerText.replace(/\\s+/g," ")}))')
                await select(D, ids['C']); tlC = await D.evaluate('()=>[...document.querySelectorAll("#comMain .az-ev")].map(e=>({k:e.dataset.ev, cls:e.className, t:e.innerText.replace(/\\s+/g," ")}))')
                evF = await db(D, 'return d.com.events.filter(e=>e.request_id===arg).map(e=>e.kind)', ids['F']); evC = await db(D, 'return d.com.events.filter(e=>e.request_id===arg).map(e=>e.kind)', ids['C'])
                tl_ok = [x['k'] for x in tlF] == evF + ['FUTURO'] and 'current' in tlF[-2]['cls'] and 'future' in tlF[-1]['cls'] and [x['k'] for x in tlC] == evC and 'Revisi' not in json.dumps(tlF + tlC)
                tl_ok = tl_ok and all(re.search(r'\d{2}/\d{2}/\d{4} \d{2}:\d{2}', x['t']) for x in tlF[:-1] + tlC) and 'Comercial' in tlC[0]['t'] and 'Responsable de aprobación' in tlC[-1]['t'] and 'Wilfredo' in tlC[-1]['t']
                res('VT-08b TRAZABILIDAD vertical: SOLO los eventos registrados (✓ enviada, ◉ pendiente, ○ resolución pendiente rotulada), cada uno con fecha, hora, usuario y rol; nunca «En revisión»',
                    tl_ok, {'pendiente': [(x['k'], x['cls']) for x in tlF], 'resuelta': [x['t'][:90] for x in tlC]})
                await detail_shot(D, 'E13_trazabilidad_resuelta.png')
                # ===== 18 · pérdida y recuperación de conexión =====
                await select(D, ids['F'])
                await ctx.set_offline(True); await D.wait_for_timeout(600)
                o1 = await D.evaluate('()=>({banner:!document.getElementById("comConn").hidden, txt:document.getElementById("comConn").innerText, off:document.querySelector(".com-app").classList.contains("az-offline"), stale:getComputedStyle(document.querySelector("#comMain .az-stale")).display, play:getComputedStyle(document.querySelector("#comMain [data-az-dots] i")).animationPlayState, sync:document.querySelector("#comMain [data-az-sync]").innerText, state:document.querySelector("#comMain .az").dataset.azStatus})')
                await shot(D, 'E14_sin_conexion.png', False)
                await ctx.set_offline(False); await D.wait_for_timeout(1500)
                o2 = await D.evaluate('()=>({banner:!document.getElementById("comConn").hidden, off:document.querySelector(".com-app").classList.contains("az-offline"), play:getComputedStyle(document.querySelector("#comMain [data-az-dots] i")).animationPlayState, sync:document.querySelector("#comMain [data-az-sync]").innerText})')
                # falla del SERVIDOR (no de la red): la consulta periódica falla → aviso; se recupera sola
                await D.evaluate('()=>{const A=window.OKD_ONLINE.api; window.__ct=A.comTrack; A.comTrack=async()=>{throw new Error("NETWORK: Failed to fetch")}}')
                await D.evaluate('()=>window.dispatchEvent(new Event("online"))'); await D.wait_for_timeout(800)
                o3 = await D.evaluate('()=>({banner:!document.getElementById("comConn").hidden, state:document.querySelector("#comMain .az").dataset.azStatus})')
                await D.evaluate('()=>{window.OKD_ONLINE.api.comTrack=window.__ct}'); await D.evaluate('()=>window.dispatchEvent(new Event("online"))'); await D.wait_for_timeout(800)
                o4 = await D.evaluate('()=>!document.getElementById("comConn").hidden')
                res('VT-18 SIN CONEXIÓN: aviso rojo «la información podría estar desactualizada», puntos en pausa con «Estado sin confirmar» (distinto de la espera) y SIN cambiar el estado; al volver la red o el servidor el aviso desaparece solo',
                    o1['banner'] and 'desactualizada' in o1['txt'] and o1['off'] and o1['stale'] != 'none' and o1['play'] == 'paused' and o1['state'] == 'PENDIENTE' and 'Sin confirmar' in o1['sync']
                    and not o2['banner'] and not o2['off'] and o2['play'] == 'running' and 'Última consulta' in o2['sync'] and o3['banner'] and o3['state'] == 'PENDIENTE' and not o4, {'sin_red': o1, 'vuelve': o2, 'falla_servidor': o3})
                # ===== 20 · búsqueda, filtro, selección, foco y posición se conservan en la actualización automática =====
                await D.set_viewport_size({'width': 1366, 'height': 700})
                await D.fill('#tSearch', 'TECNO'); await D.wait_for_timeout(900); await D.select_option('#tFilter', '1'); await D.wait_for_timeout(900)
                await select(D, ids['H']); await D.evaluate('()=>window.scrollTo(0,400)'); y1 = await D.evaluate('()=>window.scrollY')
                vH = (await api(W, 'comRequestDetail', ids['F']))['version']; await api(W, 'comDecide', ids['F'], vH, 'APROBAR', None, None)   # cambia OTRA solicitud de la lista
                await D.evaluate('()=>window.dispatchEvent(new Event("online"))'); await D.wait_for_timeout(1500)
                n20 = await D.evaluate('''()=>({q:document.getElementById("tSearch").value, f:document.getElementById("tFilter").value, sel:document.querySelector("#comMain .az").dataset.azId, y:window.scrollY,
                   lista:[...document.querySelectorAll("#comMain [data-select]")].map(b=>b.dataset.select)})''')
                await open_tab(D, 'despacho'); n20b = await D.evaluate('()=>({q:document.getElementById("tSearch").value, sel:document.querySelector("#comMain .az").dataset.azId})')
                res('VT-20 la actualización automática CONSERVA búsqueda, filtro «en curso», solicitud elegida y posición; la aprobada sale del filtro sin saltos; al volver a la pestaña se mantienen búsqueda y selección',
                    n20['q'] == 'TECNO' and n20['f'] == '1' and n20['sel'] == ids['H'] and abs(n20['y'] - y1) <= 2 and ids['F'] not in n20['lista'] and n20b['q'] == 'TECNO' and n20b['sel'] == ids['H'], {'despues': n20, 'y_antes': y1, 'volver': n20b})
                await D.set_viewport_size({'width': 1366, 'height': 950}); await D.fill('#tSearch', ''); await D.wait_for_timeout(900); await D.select_option('#tFilter', '0'); await D.wait_for_timeout(900)
                # ===== 21 · permisos por rol =====
                p21 = {}
                p21['despacho_tabs'] = await D.evaluate('()=>[...document.querySelectorAll("#comNav [data-tab]")].map(b=>b.dataset.tab)')
                p21['despacho_botones'] = await D.evaluate('()=>document.querySelectorAll("#comMain [data-dec], #rAccept, #rWithdraw").length')
                p21['despacho_decide'] = await D.evaluate(API, ['comDecide', [ids['G'], 1, 'APROBAR', None, None]])
                p21['comercial_tabs'] = await C.evaluate('()=>[...document.querySelectorAll("#comNav [data-tab]")].map(b=>b.dataset.tab)')
                p21['aprobador_tabs'] = await W.evaluate('()=>(location.hash="#/autorizaciones?v=gerencia", new Promise(r=>setTimeout(()=>r([...document.querySelectorAll("#comNav [data-tab]")].map(b=>b.dataset.tab)),1500)))')
                X = await ctx.new_page(); await dp.login(X, 'cristian@okdespacho.demo'); await X.wait_for_timeout(800)
                p21['transportista_track'] = await X.evaluate(API, ['comTrack', ['', False]])
                await X.evaluate('()=>{location.hash="#/autorizaciones"}'); await X.wait_for_timeout(1200); p21['transportista_ve_modulo'] = await X.evaluate('()=>!!document.querySelector(".com-app #comMain .az")')
                await X.close()
                res('VT-21 PERMISOS sin cambios: Despacho solo seguimiento (sin botones de decisión; decidir → FORBIDDEN); Comercial sin «Seguimiento»; aprobador con su bandeja; transportista sin acceso',
                    'despacho' in p21['despacho_tabs'] and 'gerencia' not in p21['despacho_tabs'] and p21['despacho_botones'] == 0 and not p21['despacho_decide']['ok'] and 'FORBIDDEN' in str(p21['despacho_decide'])
                    and 'despacho' not in p21['comercial_tabs'] and 'gerencia' in p21['aprobador_tabs'] and not p21['transportista_track']['ok'] and not p21['transportista_ve_modulo'], p21)
                # ===== 25 · sin temporizadores ni suscripciones duplicadas (cambios de pestaña y re-montajes) =====
                for v in ('despacho', 'despacho', 'despacho'):
                    await D.evaluate('()=>{location.hash="#/"}'); await D.wait_for_timeout(500); await open_tab(D, v)
                ivN = await D.evaluate('()=>window.__iv()'); lsN = await D.evaluate('()=>window.__ls()')
                res('VT-25 tras salir y volver al módulo 3 veces sigue habiendo UN contador (1 s), UNA consulta periódica (20 s) y UN oyente online/offline/visibilidad del módulo: sin duplicados',
                    ivN.get('1000') == 1 and ivN.get('20000', 0) == 1 and lsN['offline'] == 1, {'inicio': iv0, 'ahora': ivN, 'oyentes': lsN})
                # ===== 28 · cierre de sesión: se limpian temporizadores, oyentes y la pantalla =====
                await D.evaluate('()=>window.dispatchEvent(new Event("okd-com-cleanup"))'); await D.wait_for_timeout(400)
                ivL = await D.evaluate('()=>window.__iv()'); lsL = await D.evaluate('()=>window.__ls()'); gone = await D.evaluate('()=>!document.querySelector(".com-app")')
                res('VT-28 CIERRE DE SESIÓN (evento oficial okd-com-cleanup): se eliminan el contador, la consulta periódica, los oyentes y la pantalla del módulo',
                    gone and ivL.get('1000', 0) == 0 and ivL.get('20000', 0) == 0 and lsL['offline'] == 0 and lsL['online'] < lsN['online'], {'intervalos': ivL, 'oyentes': lsL})
                # ===== 22 · ANDROID (390×844 y 360×740) =====
                state_db = await C.evaluate('()=>localStorage.getItem("%s")' % K)
                mob_ok, mob = True, {}
                for (w, h) in ((390, 844), (360, 740)):
                    m = await b.new_context(viewport={'width': w, 'height': h}, is_mobile=True, has_touch=True, device_scale_factor=2); await m.add_init_script(INIT)
                    M = await m.new_page(); await M.goto(URL()); await M.evaluate('(v)=>localStorage.setItem("%s", v)' % K, state_db)
                    await dp.login(M, 'operario@okdespacho.demo'); await M.wait_for_timeout(600); await open_tab(M, 'despacho')
                    for k, lab in (('G', 'pendiente'), ('A', 'aprobada'), ('B', 'rechazada'), ('C', 'aprobada_con_cambios'), ('E', 'cancelada'), ('H', 'pendiente_2')):
                        await select(M, ids[k]); await M.wait_for_timeout(250)
                        ov, clip = await M.evaluate(OV), await M.evaluate(NOCLIP, '#comMain .az')
                        mob[f'{w}_{lab}'] = {'ov': ov, 'recortes': clip['n']}; mob_ok = mob_ok and ov <= 0 and clip['n'] == 0
                        if w == 390: await detail_shot(M, f'A{len(mob):02d}_android_{lab}.png')
                    if w == 390:
                        await select(M, ids['G']); await shot(M, 'A00_android_seguimiento_pantalla.png', False)
                    await m.close()
                res('VT-22 ANDROID 390×844 y 360×740: todos los estados sin desplazamiento horizontal, sin recortes; tabla de cuotas, estado y trazabilidad apilados en vertical', mob_ok, mob)
                # ===== 23 · escritorio y niveles de zoom (100 %, 125 %, 150 %, 200 % equivalentes) =====
                zoom_ok, zz = True, {}
                await D.evaluate('async()=>{try{await window.OKD_ONLINE.api.signOut()}catch(e){}}'); await dp.login(D, 'operario@okdespacho.demo'); await D.wait_for_timeout(600)
                for z in (100, 125, 150, 200):
                    await D.set_viewport_size({'width': int(1366 * 100 / z), 'height': int(950 * 100 / z)}); await open_tab(D, 'despacho'); await select(D, ids['C'])
                    ov, clip = await D.evaluate(OV), await D.evaluate(NOCLIP, '#comMain .az'); zz[z] = {'ov': ov, 'recortes': clip}; zoom_ok = zoom_ok and ov <= 0 and clip['n'] == 0
                    await shot(D, f'Z{z}_zoom_{z}_aprobada_con_cambios.png', False)
                await D.set_viewport_size({'width': 1366, 'height': 950})
                res('VT-23 ESCRITORIO con zoom 100/125/150/200 % (anchos efectivos 1366/1092/910/683 px): sin desplazamiento horizontal ni recortes', zoom_ok, zz)
                # ===== 24 · accesibilidad y reducción de movimiento =====
                rm = await b.new_context(viewport={'width': 1366, 'height': 950}, reduced_motion='reduce'); RM = await rm.new_page(); await RM.goto(URL())
                await RM.evaluate('(v)=>localStorage.setItem("%s", v)' % K, state_db); await dp.login(RM, 'operario@okdespacho.demo'); await RM.wait_for_timeout(500); await open_tab(RM, 'despacho'); await select(RM, ids['G'])
                a24 = await RM.evaluate('''()=>{const d=document.querySelector("#comMain [data-az-dots]"); const p=document.querySelector("#comMain .az .pill");
                  return {anim:[...d.querySelectorAll("i")].map(e=>getComputedStyle(e).animationName), aria:d.getAttribute("aria-hidden"), pill:p.innerText, timer_role:(document.querySelector("#comMain .az [data-wait-since]")||{getAttribute:()=>null}).getAttribute("role"),
                   live:!!document.querySelector("#comLive[aria-live=polite]"), steps:!!document.querySelector("#comMain .az-steps [aria-current=step]"), tl:document.querySelector("#comMain .az-tl").getAttribute("aria-label"),
                   table_th:document.querySelectorAll("#comMain .az-tbl th[scope]").length}}''')
                await RM.locator('#comMain .az-state').screenshot(path=os.path.join(OUT, 'E15_movimiento_reducido.png')); await rm.close()
                res('VT-24 ACCESIBILIDAD: con «reducir movimiento» los puntos quedan quietos; los estados se distinguen por TEXTO e ICONO además del color; contador role=timer; avisos aria-live; paso actual aria-current; tabla con encabezados',
                    all(x == 'none' for x in a24['anim']) and a24['aria'] == 'true' and 'Pendiente de aprobación' in a24['pill'] and '◷' in a24['pill'] and a24['timer_role'] == 'timer' and a24['live'] and a24['steps'] and a24['tl'] and a24['table_th'] >= 3, a24)
                # ===== 14b · el Comercial ve el cambio sin tocar su formulario =====
                await C.bring_to_front(); await open_tab(C, 'comercial'); await C.fill('#cOrder', 'NO-SE-PIERDE'); await C.fill('#cAmount', '777')
                await C.evaluate('(id)=>{const b=document.querySelector(`#cRecent [data-select="${id}"]`); if(b) b.click()}', ids['G']); await C.wait_for_timeout(400)
                vG = (await api(W, 'comRequestDetail', ids['G']))['version']; await api(W, 'comDecide', ids['G'], vG, 'APROBAR', None, None)
                await C.evaluate('()=>window.dispatchEvent(new Event("online"))'); await C.wait_for_timeout(1500)
                c14 = await C.evaluate('()=>({st:(document.querySelector("#cRecent .az")||{dataset:{}}).dataset.azStatus, order:document.getElementById("cOrder").value, amount:document.getElementById("cAmount").value})')
                res('VT-14b COMERCIAL: su solicitud elegida pasa a «Aprobada» sin recargar y el formulario de nueva solicitud CONSERVA lo escrito',
                    c14['st'] == 'APROBADA' and c14['order'] == 'NO-SE-PIERDE' and c14['amount'] == '777', c14)
                # ===== 26-27-29-30 (suites propias) · aquí: sin errores de consola del módulo en todo el recorrido =====
                res('VT-26 (marcador) regresión de avisos emergentes: ver run_com_alarma_avisos.py y run_com_alarma.py', True, 'se ejecutan aparte')
                res('VT-27 (marcador) regresión de correos V3: ver pruebas unitarias commercial-* y QA/run_correo_autorizaciones.mjs', True, 'se ejecutan aparte')
                res('VT-29 (marcador) flujo de transportistas: ver run_transportista_nuevo.py y run_driver_perfiles.py', True, 'se ejecutan aparte')
                res('VT-30 (marcador) compilación y verificación del artefacto: npm run build + scripts/verify_production_build.mjs', True, 'se ejecutan aparte')
            finally: await b.close()
    finally: srv.terminate()
    print('TOTAL', sum(1 for r in R if r[1] == 'PASS'), 'PASS /', sum(1 for r in R if r[1] == 'FAIL'), 'FAIL · esperados', EXPECTED)
    return R
if __name__ == '__main__':
    try: rr = asyncio.run(main())
    except Exception as e: traceback.print_exc(); print('ERROR:', repr(e)); sys.exit(2)
    if len(rr) != EXPECTED: print('ERROR: se ejecutaron %d de %d' % (len(rr), EXPECTED)); sys.exit(2)
    sys.exit(1 if any(r[1] != 'PASS' for r in rr) else 0)
