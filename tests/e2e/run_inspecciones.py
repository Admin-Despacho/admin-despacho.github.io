"""E2E (modo demo, Chromium) · V4.25 · INSPECCIONES DE VEHÍCULOS: formulario táctil en ANDROID con los 30 controles EXACTOS del Excel R SE 4.5.1-05,
validación de anomalías, borrador recuperable, envío SIN CONEXIÓN sin duplicados, notificación y alcance por equipo, rechazo/revisión/aprobación,
email solo explícito, Excel individual y Excel del historial (RESUMEN · DETALLE · AUDITORÍA) verificados con openpyxl contra los registros guardados.
Uso: python3 tests/e2e/run_inspecciones.py [dist-demo] [carpeta-salida]   ·   Exit 0 todo PASS · 1 alguna FAIL · 2 error."""
import asyncio, os, sys, json, traceback
sys.path.insert(0, os.path.dirname(__file__))
import run_driver_perfiles as dp
from playwright.async_api import async_playwright
import openpyxl
dp.PORT = 4416; R = []; EXPECTED = 10
if len(sys.argv) > 1: dp.DIST = sys.argv[1]
OUT = sys.argv[2] if len(sys.argv) > 2 else '/tmp/okd_insp_out'
CTRL = json.load(open(os.path.join(os.path.dirname(__file__), '..', '..', 'src', 'online', 'inspection-controls.json'), encoding='utf-8'))
ALL = [(c['categoria'], x['n'], x['control']) for c in CTRL['categorias'] for x in c['controles']]
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:280])); print('..', ' | '.join(R[-1]), flush=True)
MOB = dict(viewport={'width': 412, 'height': 915}, device_scale_factor=2.625, is_mobile=True, has_touch=True, accept_downloads=True)
USERS = '''()=>{const k="okd_online_demo_v2", d=JSON.parse(localStorage.getItem(k)); const a=d.users.find(u=>u.role==="ADMIN");
  const add=(id,email,role,name,sup)=>{ if(!d.users.some(u=>u.id===id)) d.users.push(Object.assign({}, a, {id, email, role, full_name:name, status:"ACTIVO", carriers:[], carrier_ids:[], extra_perms:[], denied_perms:[], supervisor_user_id:sup||null})); };
  add("u-sup1","qa.sup1@okdespacho.demo","SUPERVISOR_DESPACHO","QA Superior Equipo 1",null); add("u-sup2","qa.sup2@okdespacho.demo","SUPERVISOR_DESPACHO","QA Superior Equipo 2",null);
  add("u-op1","qa.op1@okdespacho.demo","OPERARIO_DEPOSITO","QA Operario 1","u-sup1"); add("u-op2","qa.op2@okdespacho.demo","OPERARIO_DEPOSITO","QA Operario Sin Superior",null); localStorage.setItem(k, JSON.stringify(d)); }'''
DB = '()=>{const d=JSON.parse(localStorage.getItem("okd_online_demo_v2")); return {insp:d.insp||[], items:d.inspItems||{}, ev:d.inspEvents||[], notifs:(d.notifs||[]).filter(n=>n.inspection_id), emails:d.inspEmails||[]}}'
async def relog(pg, email): await pg.evaluate('async()=>{try{await window.OKD_ONLINE.api.signOut()}catch(e){}}'); await dp.login(pg, email)
async def go(pg, h): await pg.evaluate(f'()=>{{location.hash="{h}"}}'); await pg.wait_for_timeout(1500); await push_later(pg)
async def push_later(pg):   # el aviso ACTIVAR NOTIFICACIONES (modal de V4.24.1) se responde como lo haría el usuario
    if await pg.locator('#pushLater').count() and await pg.locator('#pushLater').is_visible(): await pg.locator('#pushLater').tap(); await pg.wait_for_timeout(300)
async def answer(pg, n, res_, defect=None, obs=None):
    el = pg.locator(f'.in-ctrl[data-n="{n}"]')
    if not await el.is_visible():   # abrir su categoría (plegable)
        await pg.evaluate(f'()=>{{const c=document.querySelector(\'.in-ctrl[data-n="{n}"]\').closest("details"); c.open=true; c.dispatchEvent(new Event("toggle"));}}'); await pg.wait_for_timeout(150)
    await push_later(pg); await pg.locator(f'.in-ctrl[data-n="{n}"] [data-res="{res_}"]').tap(); await pg.wait_for_timeout(80)
    if defect: await pg.locator(f'.in-ctrl[data-n="{n}"] [data-def="{defect}"]').tap(); await pg.wait_for_timeout(80)
    if obs is not None: await pg.locator(f'.in-ctrl[data-n="{n}"] [data-obs]').fill(obs); await pg.wait_for_timeout(80)
async def main():
    os.makedirs(OUT, exist_ok=True); srv = dp.serve()
    try:
        async with async_playwright() as p:
            b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
            try:
                ctx = await b.new_context(**MOB); pg = await ctx.new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
                await pg.goto(f'http://127.0.0.1:{dp.PORT}/'); await pg.evaluate('()=>localStorage.clear()'); await dp.login(pg, 'admin@okdespacho.demo'); await pg.evaluate(USERS)
                await relog(pg, 'qa.op1@okdespacho.demo'); await go(pg, '#/inspecciones')
                shown = await pg.evaluate('()=>[...document.querySelectorAll("details.in-cat")].map(d=>({cat:d.dataset.cat, items:[...d.querySelectorAll(".in-ctrl")].map(c=>[+c.dataset.n, c.querySelector(".in-q").textContent.replace(/^\\d+\\.\\s*/,"")])}))')
                flat = [(c['cat'], n, t) for c in shown for n, t in c['items']]
                prog = await pg.inner_text('.in-progt'); await pg.screenshot(path=os.path.join(OUT, 'android_formulario.png'))
                res('IN-01 ANDROID: el formulario muestra los 30 controles EXACTOS del Excel R SE 4.5.1-05 en sus 4 categorías plegables; avance 0 de 30', flat == ALL and prog.startswith('0 de 30'), {'controles': len(flat), 'iguales': flat == ALL, 'avance': prog[:30]})
                # IN-02: completar con TOQUES; MAL exige tipo y observación; ENVIAR recién con 30
                await pg.select_option('#inVeh', 'vh-1'); await pg.wait_for_timeout(200)
                for _, n, _t in ALL[:15]: await answer(pg, n, 'BIEN')
                await answer(pg, 7, 'MAL')   # MAL sin tipo ni observación
                dis1 = await pg.locator('#inSend').is_disabled()
                for _, n, _t in ALL[15:]: await answer(pg, n, 'NO_APLICA' if n == 18 else 'BIEN')
                dis2 = await pg.locator('#inSend').is_disabled(); await pg.locator('#inSend').tap(); await pg.wait_for_timeout(500)
                blocked = await pg.inner_text('#inMsg'); none = await pg.evaluate(DB)
                res('IN-02 completar con TOQUES: ENVIAR deshabilitado hasta los 30; un MAL sin FALTANTE/MAL ESTADO y observación BLOQUEA el envío (nada se envía)',
                    dis1 and not dis2 and 'FALTANTE o MAL ESTADO' in blocked and len(none['insp']) == 0, {'mensaje': blocked[:90]})
                await answer(pg, 7, 'MAL', 'FALTANTE', 'No hay botiquín en el vehículo'); await answer(pg, 24, 'MAL', 'MAL_ESTADO', 'Cubierta trasera izquierda gastada')
                await pg.fill('#inKm', '50750'); await pg.wait_for_timeout(300)
                # IN-03: se cierra la app → el borrador vuelve completo
                await pg.reload(); await pg.wait_for_timeout(1800); await go(pg, '#/inspecciones'); await pg.wait_for_timeout(500)
                back = await pg.evaluate('()=>({n:document.querySelectorAll(".in-b.on").length, d:document.querySelectorAll(".in-d.on").length, km:document.getElementById("inKm").value, veh:document.getElementById("inVeh").value})')
                res('IN-03 BORRADOR: al cerrar y reabrir la app vuelven las 30 respuestas, los tipos de anomalía, el vehículo y el km', back == {'n': 30, 'd': 2, 'km': '50750', 'veh': 'vh-1'}, back)
                # IN-04: envío SIN CONEXIÓN → cola; al volver la señal, UN solo registro
                await push_later(pg)
                tapable = await pg.evaluate('()=>{const b=document.getElementById("inSend"); const r=b.getBoundingClientRect(); const t=document.elementFromPoint(r.left+r.width/2, r.top+r.height/2); return b.contains(t)}')   # nada tapa ENVIAR (aviso de notificaciones visible)
                await ctx.set_offline(True); await pg.locator('#inSend').tap(); await pg.wait_for_timeout(1500); off_msg = await pg.inner_text('#inMsg'); q_off = await pg.evaluate('()=>JSON.parse(localStorage.getItem("okd_insp_queue:u-op1")||"[]").length')
                await ctx.set_offline(False); await pg.evaluate('()=>window.dispatchEvent(new Event("online"))'); await pg.wait_for_timeout(2500); await pg.evaluate('()=>window.dispatchEvent(new Event("online"))'); await pg.wait_for_timeout(1500)
                db = await pg.evaluate(DB); i1 = db['insp'][0] if db['insp'] else {}
                res('IN-04 ENVIAR queda accesible (sin nada encima) · SIN CONEXIÓN: queda en la cola del celular y al volver la señal se registra UNA sola inspección PENDIENTE (2 anomalías, km 50750, responsable del sistema)',
                    tapable and 'Sin conexión' in off_msg and q_off == 2 and len(db['insp']) == 1 and i1.get('status') == 'PENDIENTE' and i1.get('anomalies') == 2 and i1.get('km') == 50750 and i1.get('created_by') == 'u-op1',
                    {'tapable': tapable, 'mensaje': off_msg[:70], 'cola': q_off, 'registros': len(db['insp']), 'estado': i1.get('status'), 'anomalias': i1.get('anomalies'), 'km': i1.get('km'), 'por': i1.get('created_by')})
                # IN-05: notificación al Superior del EQUIPO con acceso directo; el Superior de OTRO equipo no ve la inspección
                await relog(pg, 'qa.sup2@okdespacho.demo'); await go(pg, '#/inspecciones'); await pg.locator('[data-intab="hist"]').tap(); await pg.wait_for_timeout(900)
                other = await pg.locator('#inTable tr[data-iid]').count()
                await relog(pg, 'qa.sup1@okdespacho.demo'); await go(pg, '#/notificaciones'); await pg.wait_for_timeout(800)
                await pg.locator('[data-insp]').first.tap(); await pg.wait_for_timeout(1500)
                det = await pg.evaluate('()=>({h:(document.querySelector(".dt-head h3")||{}).textContent, ok:!!document.getElementById("inOk")})')
                res('IN-05 el Superior del EQUIPO recibe la notificación y ABRIR INSPECCIÓN lo lleva DIRECTO al registro (con APROBAR/RECHAZAR); el Superior de OTRO equipo no la ve',
                    other == 0 and det['h'] and i1['number'] in det['h'] and det['ok'], {'otro_equipo_ve': other, 'detalle': det})
                # IN-06: rechazo (motivo obligatorio) → notificación al Operario → nueva revisión → aprobación → email SOLO explícito
                await pg.locator('#inNo').tap(); await pg.locator('#inNoGo').tap(); await pg.wait_for_timeout(300); need = await pg.inner_text('#inMsg')
                await pg.fill('#inWhy', 'Reponer botiquín antes de circular'); await pg.locator('#inNoGo').tap(); await pg.wait_for_timeout(1200)
                await relog(pg, 'qa.op1@okdespacho.demo'); await go(pg, f'#/inspecciones?id={i1["id"]}'); await pg.wait_for_timeout(800)
                await pg.locator('#inRev').tap(); await pg.wait_for_timeout(1500); db = await pg.evaluate(DB); rev = [x for x in db['insp'] if x.get('revision') == 2][0]
                # el Operario corrige la revisión (botiquín repuesto) y la envía
                await pg.evaluate('''(rid)=>{const d=JSON.parse(localStorage.getItem("okd_online_demo_v2")); return rid}''', rev['id'])
                await pg.evaluate('async(c)=>{const A=window.OKD_ONLINE.api; await A.inspSaveDraft({client_id:c.client_id, vehicle_id:c.vehicle_id, km:c.km, items:[{n:7,result:"BIEN"}]}); await A.inspSubmit(c.id);}', rev)
                await relog(pg, 'qa.sup1@okdespacho.demo'); await go(pg, f'#/inspecciones?id={rev["id"]}'); await pg.wait_for_timeout(800)
                await pg.locator('#inOk').tap(); await pg.wait_for_timeout(1300); em0 = len((await pg.evaluate(DB))['emails'])
                await pg.locator('#inMail').tap(); await pg.wait_for_timeout(300); draft = await pg.input_value('#inBody'); em1 = len((await pg.evaluate(DB))['emails'])
                await pg.fill('#inTo', 'gerencia@okdespacho.test'); await pg.locator('#inMailGo').tap(); await pg.wait_for_timeout(1000); db = await pg.evaluate(DB)
                orig = [x for x in db['insp'] if x['id'] == i1['id']][0]; rv = [x for x in db['insp'] if x['id'] == rev['id']][0]
                res('IN-06 RECHAZO con motivo obligatorio → notificación al Operario → NUEVA REVISIÓN (original intacta) → APROBADA; el email NO se genera al aprobar, se prepara para revisar y se registra SOLO al confirmarlo',
                    'motivo' in need.lower() and orig['status'] == 'RECHAZADA' and orig['reject_reason'] == 'Reponer botiquín antes de circular' and any(n['user_id'] == 'u-op1' and n['type'] == 'INSPECTION_RECHAZADA' for n in db['notifs'])
                    and rv['status'] == 'APROBADA' and rv['number'] == orig['number'] and rv['reviewed_by'] == 'u-sup1' and em0 == 0 and em1 == 0 and len(db['emails']) == 1 and rv['plate'] in draft and 'Kilometraje' in draft,
                    {'original': orig['status'], 'revision': (rv['revision'], rv['status']), 'emails_al_aprobar': em0, 'emails_al_confirmar': len(db['emails'])})
                # IN-07: Excel INDIVIDUAL (de la original rechazada: muestra anomalías y motivo) → verificado con openpyxl contra los registros
                await go(pg, f'#/inspecciones?id={i1["id"]}'); await pg.wait_for_timeout(800)
                async with pg.expect_download() as dl: await pg.locator('#inXls').tap()
                f1 = os.path.join(OUT, (await dl.value).suggested_filename); await (await dl.value).save_as(f1)
                ws = openpyxl.load_workbook(f1).active; cells = [[c for c in r] for r in ws.iter_rows(values_only=True)]
                txt = '\n'.join(' | '.join('' if c is None else str(c) for c in r) for r in cells)
                ctl_rows = [r for r in cells if isinstance(r[0], (int, float)) and r[1] in [t for _, _, t in ALL]]
                res('IN-07 EXCEL INDIVIDUAL abre con openpyxl: encabezado OK DESPACHO + R SE 4.5.1-05, número, patente, km, responsable, estado, Superior y motivo; los 30 controles agrupados por categoría con resultado, anomalía y observación; resumen de anomalías',
                    'OK DESPACHO' in txt and 'R SE 4.5.1-05' in txt and i1['number'] in txt and 'AB123CD' in txt and 'QA Operario 1' in txt and 'RECHAZADA' in txt and 'QA Superior Equipo 1' in txt and 'Reponer botiquín' in txt
                    and all(c in txt for c in ['DOCUMENTACIÓN', 'ELEMENTOS DE SEGURIDAD', 'LUCES Y SEÑALES', 'MECÁNICA Y ESTADO GENERAL']) and len([r for r in ctl_rows if r[2] in ('BIEN', 'MAL', 'NO APLICA')]) >= 30
                    and 'FALTANTE' in txt and 'MAL ESTADO' in txt and 'RESUMEN DE ANOMALÍAS: 2' in txt, {'archivo': os.path.basename(f1), 'filas_control': len(ctl_rows)})
                # IN-08: Excel del HISTORIAL FILTRADO (estado APROBADA) → 3 hojas que coinciden con los registros guardados
                await pg.locator('[data-intab="hist"]').tap(); await pg.wait_for_timeout(900); await pg.select_option('#hfS', 'APROBADA'); await pg.locator('#hfGo').tap(); await pg.wait_for_timeout(800)
                async with pg.expect_download() as dl: await pg.locator('#hfX').tap()
                f2 = os.path.join(OUT, (await dl.value).suggested_filename); await (await dl.value).save_as(f2)
                wb = openpyxl.load_workbook(f2); db = await pg.evaluate(DB); apr = [x for x in db['insp'] if x['status'] == 'APROBADA']
                s1 = list(wb['RESUMEN'].iter_rows(values_only=True)); s2 = list(wb['DETALLE'].iter_rows(values_only=True)); s3 = list(wb['AUDITORÍA'].iter_rows(values_only=True))
                ev_apr = [e for e in db['ev'] if e['inspection_id'] in {x['id'] for x in apr}]
                res('IN-08 EXCEL DEL HISTORIAL (filtro APROBADA): hojas RESUMEN · DETALLE · AUDITORÍA; 1 fila por inspección, 30 por control y 1 por evento, coincidiendo con los registros guardados (no incluye la rechazada)',
                    wb.sheetnames == ['RESUMEN', 'DETALLE', 'AUDITORÍA'] and len(s1) - 1 == len(apr) == 1 and len(s2) - 1 == 30 * len(apr) and len(s3) - 1 == len(ev_apr) and s1[1][7] == 'APROBADA'
                    and all(r[0] == apr[0]['number'] for r in s2[1:]) and not any('RECHAZADA' == r[7] for r in s1[1:]),
                    {'hojas': wb.sheetnames, 'resumen': len(s1) - 1, 'detalle': len(s2) - 1, 'auditoria': len(s3) - 1, 'eventos_guardados': len(ev_apr)})
                await pg.screenshot(path=os.path.join(OUT, 'android_historial.png')); await ctx.close()
                # IN-09: NOTEBOOK
                c2 = await b.new_context(viewport={'width': 1366, 'height': 900}, storage_state=await ctx.storage_state() if False else None)
                n = await c2.new_page(); await n.goto(f'http://127.0.0.1:{dp.PORT}/'); await n.evaluate('()=>localStorage.clear()'); await dp.login(n, 'admin@okdespacho.demo'); await n.evaluate(USERS)
                await relog(n, 'qa.op1@okdespacho.demo'); await go(n, '#/inspecciones')
                a = await n.evaluate('''()=>{const inScroll=el=>{for(let p=el.parentElement;p;p=p.parentElement){const o=getComputedStyle(p).overflowX; if(o==="auto"||o==="scroll") return true;} return false;};
                  return {over:document.documentElement.scrollWidth-document.documentElement.clientWidth, fuera:[...document.querySelectorAll("button,input,select")].filter(el=>{const r=el.getBoundingClientRect(); return r.width>0&&!inScroll(el)&&(r.right>innerWidth+1||r.left<-1);}).length, ctrls:document.querySelectorAll(".in-ctrl").length}}''')
                await n.screenshot(path=os.path.join(OUT, 'notebook_formulario.png'))
                res('IN-09 NOTEBOOK: el formulario de inspección se ve completo (30 controles), sin desplazamiento lateral ni botones cortados', a['over'] <= 0 and a['fuera'] == 0 and a['ctrls'] == 30, a)
                await c2.close()
                # IN-10: Operario SIN Superior asignado → aviso, ENVIAR deshabilitado, el servidor rechaza; ningún Superior la ve; el Administrador sí
                c3 = await b.new_context(**MOB); q = await c3.new_page(); q.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
                await q.goto(f'http://127.0.0.1:{dp.PORT}/'); await q.evaluate('()=>localStorage.clear()'); await dp.login(q, 'admin@okdespacho.demo'); await q.evaluate(USERS)
                await relog(q, 'qa.op2@okdespacho.demo'); await go(q, '#/inspecciones'); await q.select_option('#inVeh', 'vh-1'); await q.fill('#inKm', '50900')
                for _, n, _t in ALL: await answer(q, n, 'BIEN')
                banner = await q.evaluate('()=>{const b=document.getElementById("inNoSup"); return b&&b.offsetParent?b.textContent:null}'); dis = await q.locator('#inSend').is_disabled()
                await q.screenshot(path=os.path.join(OUT, 'android_sin_superior.png'))
                srv_err = await q.evaluate('''async()=>{const A=window.OKD_ONLINE.api, c=crypto.randomUUID(); const r=await A.inspSaveDraft({client_id:c, vehicle_id:'vh-1', km:50900, items:Array.from({length:30},(_, i)=>({n:i+1, result:'BIEN'}))});
                  try{ await A.inspSubmit(r.id); return 'ENVIADA'; }catch(e){ return e.code || e.message; } }''')
                vis = {}
                for who in ('qa.sup1@okdespacho.demo', 'qa.sup2@okdespacho.demo', 'admin@okdespacho.demo'):
                    await relog(q, who); vis[who.split('@')[0]] = await q.evaluate('async()=>(await window.OKD_ONLINE.api.inspList({})).filter(i=>i.created_by==="u-op2").length')
                notis = await q.evaluate('()=>{const d=JSON.parse(localStorage.getItem("okd_online_demo_v2")); const ids=(d.insp||[]).filter(i=>i.created_by==="u-op2").map(i=>i.id); return (d.notifs||[]).filter(n=>ids.includes(n.inspection_id)).length}')
                await c3.close()
                res('IN-10 Operario SIN Superior asignado: aviso visible y ENVIAR deshabilitado (borrador sí); el servidor rechaza el envío (SUPERVISOR_REQUIRED); NINGÚN Superior la ve ni recibe notificación; el Administrador General sí la ve',
                    bool(banner) and 'Superior Despacho asignado' in banner and dis and srv_err == 'SUPERVISOR_REQUIRED' and vis.get('qa.sup1') == 0 and vis.get('qa.sup2') == 0 and vis.get('admin', 0) >= 1 and notis == 0,
                    {'aviso': bool(banner), 'enviar_deshabilitado': dis, 'servidor': srv_err, 'visibles': vis, 'notificaciones': notis})
            finally: await b.close()
    finally: srv.terminate()
    print('TOTAL', sum(1 for r in R if r[1] == 'PASS'), 'PASS /', sum(1 for r in R if r[1] == 'FAIL'), 'FAIL · esperados', EXPECTED)
    return R
if __name__ == '__main__':
    try: rr = asyncio.run(main())
    except Exception as e: traceback.print_exc(); print('ERROR:', repr(e)); sys.exit(2)
    if len(rr) != EXPECTED: print('ERROR: se ejecutaron %d de %d' % (len(rr), EXPECTED)); sys.exit(2)
    sys.exit(1 if any(r[1] != 'PASS' for r in rr) else 0)
