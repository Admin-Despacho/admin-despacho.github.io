"""E2E (demo, Chromium) · AVISOS EMERGENTES DE ALARMAS COMERCIALES — corrección del recuadro «trabado» abajo a la izquierda.
Datos SINTÉTICOS en el almacenamiento de la demo (alarmas ALR-9000x). Sin servidor real, sin push ni sonido reales.
Uso: python3 tests/e2e/run_com_alarma_avisos.py dist-demo [carpeta_capturas]"""
import asyncio, json, os, sys, time
sys.path.insert(0, os.path.dirname(__file__))
import run_driver_perfiles as dp
from playwright.async_api import async_playwright
DIST = sys.argv[1] if len(sys.argv) > 1 else 'dist-demo'; dp.DIST = DIST; dp.PORT = 4397
OUT = sys.argv[2] if len(sys.argv) > 2 else '/tmp/okd_alarma_avisos'
K = 'okd_online_demo_v2'; R = []; EXPECTED = 20
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:300])); print('..', ' | '.join(R[-1]), flush=True)
now_iso = lambda off=0: time.strftime('%Y-%m-%dT%H:%M:%S', time.gmtime(time.time() + off)) + '.000Z'
def alarm(n, status='PENDIENTE_ATENCION', attended=None):
    return {'id': 'al-qa-%d' % n, 'number': 'ALR-9%05d' % n, 'order_ref': '7%04d' % n, 'sheet_key': 'S-QA', 'client_name': 'CLIENTE SINTÉTICO %d' % n, 'reason': 'Motivo sintético de prueba %d' % n,
            'raised_by': 'u-operario', 'raised_at': now_iso(-3600 if attended else -30), 'initial_user': 'u-wilfredo', 'escalate_at': now_iso(36000), 'escalated_at': None, 'escalated_to': [],
            'status': status, 'attended_by': 'u-wilfredo' if attended else None, 'attended_at': attended, 'seconds_to_attend': 40 if attended else None, 'version': 1}
async def db(pg): return json.loads(await pg.evaluate('()=>localStorage.getItem("%s")' % K))
async def put(pg, fn):
    d = await db(pg); fn(d['com']); await pg.evaluate('(v)=>localStorage.setItem("%s", v)' % K, json.dumps(d))
async def poll(pg): await pg.evaluate('async()=>{ if(window.__okdComAlarm&&window.__okdComAlarm.poll) await window.__okdComAlarm.poll(); }'); await pg.wait_for_timeout(150)
async def toasts(pg): return await pg.evaluate('()=>[...document.querySelectorAll("[data-al-toast]")].map(e=>e.innerText.replace(/\\s+/g," "))')
async def mine(pg): return await pg.evaluate('()=>{const e=document.querySelector("[data-al-mine]"); return e?e.innerText.replace(/\\s+/g," "):""}')
def setst(ids, status, by='u-wilfredo'):
    def f(c):
        for a in c['alarms']:
            if a['id'] in ids: a['status'] = status; a['attended_by'] = by if status == 'ATENDIDA' else a.get('attended_by'); a['attended_at'] = now_iso(); a['version'] += 1
    return f
async def main():
    os.makedirs(OUT, exist_ok=True); srv = dp.serve()
    try:
        async with async_playwright() as p:
            b = await p.chromium.launch()
            try:
                desk = await b.new_context(viewport={'width': 1366, 'height': 900}); op = await desk.new_page()
                await op.goto(f'http://127.0.0.1:{dp.PORT}/'); await op.evaluate('()=>localStorage.clear()'); await dp.login(op, 'operario@okdespacho.demo')
                # alarmas históricas ATENDIDAS (como ALR-000001/000002 de AUT-000003) + dos pendientes
                await put(op, lambda c: c.__setitem__('alarms', [alarm(1, 'ATENDIDA', now_iso(-1800)), alarm(2, 'ATENDIDA', now_iso(-1700)), alarm(3), alarm(4)]))
                hist_before = (await db(op))['com']['alarms']
                await op.reload(); await op.wait_for_timeout(2500); await poll(op)
                m = await mine(op); t = await toasts(op)
                res('AV-01 alarmas PENDIENTES propias visibles mientras estén pendientes', 'ALR-900003' in m and 'ALR-900004' in m and 'PENDIENTE' in m, m)
                res('AV-06 las ATENDIDAS históricas (como ALR-000001/000002) NO se muestran al cargar ni quedan trabadas', 'ALR-900001' not in m + ''.join(t) and 'ALR-900002' not in m + ''.join(t) and not t, {'mine': m, 'toasts': t})
                # ---- 2 · 8 · atendida: confirmación 5 s; las consultas periódicas NO reinician el temporizador ----
                await put(op, setst(['al-qa-3'], 'ATENDIDA')); t0 = time.time(); await poll(op); t1 = await toasts(op)
                await op.wait_for_timeout(2500); await poll(op); await poll(op); t2 = await toasts(op)
                await op.wait_for_timeout(max(0, 5300 - int((time.time() - t0) * 1000))); t3 = await toasts(op); m3 = await mine(op)
                res('AV-02 alarma ATENDIDA: confirmación con quién y cuándo, desaparece sola a los 5 s', len(t1) == 1 and 'ALR-900003' in t1[0] and 'ATENDIDA por Wilfredo' in t1[0] and t3 == [] and 'ALR-900003' not in m3, {'t1': t1, 't3': t3})
                res('AV-08 consultas periódicas durante la confirmación no reinician el temporizador ni la duplican', len(t2) == 1 and t3 == [], {'a_2_5s': t2})
                await poll(op); await poll(op)
                res('AV-05 una confirmación ya cerrada (vencida) no reaparece en consultas siguientes', await toasts(op) == [])
                # ---- 3 · cancelada (permanece en la lista) y desaparición de la lista ----
                await put(op, setst(['al-qa-4'], 'CANCELADA')); await poll(op); tc = await toasts(op)
                await op.wait_for_timeout(5300); tc2 = await toasts(op)
                res('AV-03 alarma CANCELADA: confirmación «CANCELADA» que desaparece sola', len(tc) == 1 and 'CANCELADA' in tc[0] and tc2 == [], {'antes': tc, 'despues': tc2})
                await put(op, lambda c: c['alarms'].append(alarm(5))); await poll(op)
                await put(op, lambda c: c.__setitem__('alarms', [a for a in c['alarms'] if a['id'] != 'al-qa-5'])); await poll(op); tg = await toasts(op)
                res('AV-03b alarma pendiente que sale de la lista (cancelada sin fecha) → «YA NO ESTÁ PENDIENTE», también temporal', len(tg) == 1 and 'YA NO ESTÁ PENDIENTE' in tg[0], tg)
                await op.wait_for_timeout(5300)
                # ---- 4 · 9 · 10 · varias simultáneas, X individual, pendientes y atendidas coexistiendo ----
                await put(op, lambda c: c['alarms'].extend([alarm(6), alarm(7), alarm(8)])); await poll(op)
                await put(op, setst(['al-qa-6', 'al-qa-7'], 'ATENDIDA')); await poll(op); tm = await toasts(op); mm = await mine(op)
                await op.screenshot(path=os.path.join(OUT, '1_escritorio_confirmaciones_y_pendiente.png'))
                res('AV-09 varias alarmas simultáneas: una confirmación por alarma', len(tm) == 2 and any('ALR-900006' in x for x in tm) and any('ALR-900007' in x for x in tm), tm)
                res('AV-10 pendientes y atendidas coexistiendo: la pendiente sigue en su recuadro', 'ALR-900008' in mm and 'PENDIENTE' in mm, mm)
                await op.click('[data-al-toast-close="al-qa-6"]'); await op.wait_for_timeout(150); tx = await toasts(op)
                res('AV-04 cierre manual con X inmediato e individual (la otra conserva su propio temporizador)', len(tx) == 1 and 'ALR-900007' in tx[0], tx)
                await poll(op); await poll(op)
                res('AV-05b la cerrada con X no reaparece', not any('ALR-900006' in x for x in await toasts(op)))
                # ---- 7 · navegación entre módulos ----
                for h in ['#/autorizaciones', '#/', '#/autorizaciones?v=historial']:
                    await op.evaluate('(h)=>{location.hash=h}', h); await op.wait_for_timeout(500); await poll(op)
                tn = await toasts(op); await op.wait_for_timeout(5000); tn2 = await toasts(op)
                res('AV-07 navegación entre módulos: no duplica ni reinicia; vence a su tiempo', len(tn) <= 1 and tn2 == [], {'durante': tn, 'despues': tn2})
                # ---- 6 · recarga: nada histórico vuelve ----
                await op.reload(); await op.wait_for_timeout(2500); await poll(op); await poll(op); tr = await toasts(op); mr = await mine(op)
                res('AV-06b recarga de página: no reaparece ninguna confirmación ni alarma histórica; la pendiente sigue', tr == [] and 'ALR-900008' in mr and 'ALR-900006' not in mr and 'ALR-900003' not in mr, {'toasts': tr, 'mine': mr})
                # ---- 11 · historial intacto (solo visual) ----
                alarms_now = (await db(op))['com']['alarms']
                same = all(any(x['id'] == a['id'] and x['status'] == a['status'] and x.get('attended_by') == a.get('attended_by') and x.get('attended_at') == a.get('attended_at') for x in alarms_now) for a in hist_before[:2])
                res('AV-11 historial intacto: ninguna alarma borrada ni modificada por ocultar avisos (estados, responsables y fechas)', same and len(alarms_now) == 7, len(alarms_now))
                # ---- 15 · PIN / firmas / formularios críticos: la pila no se muestra ----
                await put(op, lambda c: c['alarms'].append(alarm(9))); await poll(op)
                await put(op, setst(['al-qa-9'], 'ATENDIDA')); await op.evaluate('()=>{const d=document.createElement("div"); d.id="pinGate"; d.style.cssText="position:fixed;inset:0;background:#fff"; document.body.appendChild(d);}')
                await op.wait_for_timeout(200); await poll(op); pin = await op.evaluate('()=>!!document.querySelector("[data-al-stack]")')
                await op.evaluate('()=>{document.getElementById("pinGate").remove(); const f=document.createElement("div"); f.className="drv-form"; f.style.cssText="position:fixed;inset:0;background:#fff"; document.body.appendChild(f);}')
                await op.wait_for_timeout(300); crit = await op.evaluate('()=>!!document.querySelector("[data-al-stack]")')
                await op.evaluate('()=>document.querySelector(".drv-form").remove()'); await op.wait_for_timeout(300); back = await op.evaluate('()=>!!document.querySelector("[data-al-stack]")')
                res('AV-15 con PIN o firma/formulario del transportista abierto NO se muestra nada; al cerrarlos vuelve (sin tapar operaciones)', not pin and not crit and back, {'pin': pin, 'critico': crit, 'despues': back})
                # ---- 12 · cierre de sesión y cambio de usuario: temporizadores y avisos limpios ----
                await op.evaluate('async()=>{try{await window.OKD_ONLINE.api.signOut()}catch(e){}; window.dispatchEvent(new Event("okd-com-cleanup"))}'); await op.wait_for_timeout(400)
                gone = await op.evaluate('()=>!document.getElementById("comAlarm") && !window.__okdComAlarm')
                await dp.login(op, 'wilfredo@okdespacho.demo'); await op.wait_for_timeout(1200); await poll(op); tw = await toasts(op); ring = await op.evaluate('()=>!!(window.__okdComAlarm||{}).ringing || !!document.querySelector("[data-al-panel],[data-al-bar]")')
                res('AV-12 cierre de sesión y cambio de usuario: se limpian avisos y temporizadores; el nuevo usuario no hereda confirmaciones', gone and tw == [], {'limpio': gone, 'toasts_nuevo_usuario': tw})
                res('AV-16 regresión: al destinatario la alarma PENDIENTE le sigue apareciendo (panel urgente / sonido según el navegador)', ring)
                # el destinatario atiende: su confirmación también dura 5 s
                await op.click('[data-al-attend]'); await op.wait_for_timeout(600); ta = await toasts(op); await op.wait_for_timeout(5200); ta2 = await toasts(op)
                res('AV-02b quien ATIENDE ve la confirmación (con la aclaración de Autorizaciones) y se oculta a los 5 s', len(ta) >= 1 and 'Autorizaciones' in ''.join(ta) and ta2 == [], {'antes': ta, 'despues': ta2})
                # ---- 13 · 14 · Android y escritorio ----
                an = await b.new_context(viewport={'width': 390, 'height': 844}, is_mobile=True, has_touch=True); ap = await an.new_page()
                await ap.goto(f'http://127.0.0.1:{dp.PORT}/'); await ap.evaluate('(v)=>localStorage.setItem("%s", v)' % K, await op.evaluate('()=>localStorage.getItem("%s")' % K))
                await put(ap, lambda c: c['alarms'].extend([alarm(10), alarm(11)])); await dp.login(ap, 'operario@okdespacho.demo'); await poll(ap)
                await put(ap, setst(['al-qa-10'], 'ATENDIDA')); await poll(ap)
                geo = await ap.evaluate('()=>{const s=document.querySelector("[data-al-stack]"); const r=s?s.getBoundingClientRect():null; return {stack:!!s, left:r&&r.left, right:r&&r.right, bottom:r&&r.bottom, w:innerWidth, h:innerHeight, ovf:document.documentElement.scrollWidth-document.documentElement.clientWidth, x:!!document.querySelector("[data-al-toast-close]")}}')
                await ap.screenshot(path=os.path.join(OUT, '2_android_confirmacion_y_pendiente.png'))
                res('AV-13 Android 390×844: pila dentro de la pantalla, sin desplazamiento horizontal, X táctil disponible', geo['stack'] and geo['left'] >= 0 and geo['right'] <= geo['w'] and geo['bottom'] <= geo['h'] and geo['ovf'] <= 0 and geo['x'], geo)
                await ap.wait_for_timeout(5300); await ap.screenshot(path=os.path.join(OUT, '3_android_tras_5_segundos.png'))
                dg = await op.evaluate('()=>({ovf:document.documentElement.scrollWidth-document.documentElement.clientWidth})')
                res('AV-14 escritorio 1366×900: sin desplazamiento horizontal', dg['ovf'] <= 0, dg)
            finally: await b.close()
    finally: srv.terminate()
    ok = sum(1 for r in R if r[1] == 'PASS'); print('TOTAL %d PASS / %d FAIL · esperados %d' % (ok, len(R) - ok, EXPECTED)); sys.exit(0 if ok == EXPECTED == len(R) else 1)
asyncio.run(main())
