"""E2E BLOQUEANTE (demo + pantallas REALES) · COMERCIAL + ALARMA V5 (auditoría Work sobre V4, 15/11):
N-V4-04 consultas simultáneas del historial · N-V4-06 formulario de entrega REAL del chofer y firma con alarma entrante · aceptación visual
(pantalla chica y teclado abierto con 1/3/6) · N-V4-01 restricciones en pantalla · N-V4-03 KPI deshabilitado desde el inicio y fotos previas
ocultas · N-V4-05 día argentino. Datos sintéticos. Sin envíos reales."""
import asyncio, os, sys, json, traceback, base64
sys.path.insert(0, os.path.dirname(__file__))
import run_driver_perfiles as dp
from playwright.async_api import async_playwright
R = []; EXPECTED = 6
DIST = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), '..', '..', 'dist-demo'); dp.DIST = DIST; dp.PORT = 4387
OUT = sys.argv[2] if len(sys.argv) > 2 else '/tmp/okd_com_v5'
K = 'okd_online_demo_v2'
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:420])); print('..', ' | '.join(R[-1]), flush=True)
ST = '()=>{const s=window.__okdComAlarm||{}; return {ringing:!!s.ringing, supp:s.suppressed||null, min:!!s.minimized}}'
def mutate(js): return '()=>{const d=JSON.parse(localStorage.getItem("%s")); %s; localStorage.setItem("%s", JSON.stringify(d));}' % (K, js, K)
async def sync(src, dst): v = await src.evaluate('()=>localStorage.getItem("%s")' % K); await dst.evaluate('(v)=>localStorage.setItem("%s", v)' % K, v)
async def poll(pg): await pg.evaluate('async()=>{ if(window.__okdComAlarm&&window.__okdComAlarm.poll) await window.__okdComAlarm.poll(); }'); await pg.wait_for_timeout(500)
async def enter(pg, email): await pg.goto(f'http://127.0.0.1:{dp.PORT}/'); await dp.login(pg, email); await pg.wait_for_timeout(1500)
LONG = 'Motivo extenso de prueba: el cliente solicita ampliar el plazo por demoras de cobranza de su propia cartera, con varias facturas vencidas y un pedido grande pendiente; ' * 2
def INJECT(user):
    return '''(n)=>{const d=JSON.parse(localStorage.getItem("%s")); d.com.alarms=(d.com.alarms||[]).filter(a=>!String(a.id).startsWith("inj-")); const now=Date.now();
  for(let i=1;i<=n;i++) d.com.alarms.push({id:"inj-"+i, number:"ALR-9"+String(i).padStart(5,"0"), order_ref:"P-"+(8000+i), sheet_key:"X", request_id:null, branch:"MONTECASEROS",
    client_name:"CLIENTE DE PRUEBA CON RAZÓN SOCIAL MUY LARGA NÚMERO "+i+" SOCIEDAD ANÓNIMA", client_cuit:null, client_source:"DECLARADO_POR_DESPACHO", reason:%s, raised_by:"u-op",
    raised_at:new Date(now-i*1000).toISOString(), initial_user:"%s", escalate_at:new Date(now+600000).toISOString(), escalated_at:null, escalated_to:[], status:"PENDIENTE_ATENCION",
    attended_by:null, attended_at:null, op_id:"inj-op-"+i, version:1});
  localStorage.setItem("%s", JSON.stringify(d));}''' % (K, json.dumps(LONG), user, K)
GEO = '''()=>{const p=document.querySelector("#comAlarm [data-al-panel] .al-in"), l=document.querySelector("#comAlarm [data-al-list]"), b=document.querySelector("#comAlarm [data-al-attend]");
  const r=p?p.getBoundingClientRect():null, br=b?b.getBoundingClientRect():null, cards=[...document.querySelectorAll("#comAlarm .al-card")];
  return {vh:innerHeight, alto:r?Math.round(r.height):0, desplazable:l?l.scrollHeight>l.clientHeight+2:false, boton_visible:!!br&&br.top>=0&&br.bottom<=innerHeight&&br.width>0,
    desborde_h:document.documentElement.scrollWidth-document.documentElement.clientWidth, tarjetas_desbordan:cards.some(c=>c.scrollWidth>c.clientWidth+1)}}'''
async def main():
    os.makedirs(OUT, exist_ok=True)
    png = os.path.join(OUT, 'doc.png'); open(png, 'wb').write(base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='))
    srv = dp.serve()
    try:
        async with async_playwright() as p:
            b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
            try:
                mk = lambda w=1366, h=900, mob=False: b.new_context(viewport={'width': w, 'height': h}, is_mobile=mob, has_touch=mob)
                ad = await (await mk()).new_page(); ad.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
                await ad.goto(f'http://127.0.0.1:{dp.PORT}/'); await ad.evaluate('()=>localStorage.clear()'); await dp.login(ad, 'admin@okdespacho.demo'); await ad.wait_for_timeout(1200)
                kpi0 = await ad.evaluate('async()=>{const c=await window.OKD_ONLINE.api.comConfig(); return c.settings.kpi_mode||null}')   # demo NUEVA: modo del KPI desde el primer acceso
                ids = await ad.evaluate(dp.PUB)
                await ad.evaluate(mutate('d.users.find(u=>u.id==="u-gabriel").permission_overrides={...(d.users.find(u=>u.id==="u-gabriel").permission_overrides||{}), "com.approve": true}'))
                await ad.evaluate('async()=>{await window.OKD_ONLINE.api.comSetAlarmSettings({initial_user:"u-wilfredo", escalation_users:["u-franco","u-gabriela"]})}')
                state = await ad.context.storage_state()
                # ===== E01 · N-V4-04 · consultas simultáneas del historial =====
                co = await (await mk()).new_page(); await co.goto(f'http://127.0.0.1:{dp.PORT}/'); await sync(ad, co); await enter(co, 'comercial.montecaseros@okdespacho.demo')
                await co.evaluate('async()=>{await window.OKD_ONLINE.api.comCreate("FINANCIACION","cli-101","H-0",{amount:150000,installments:2},null,"v5-base")}')
                await co.evaluate(mutate('''const t=d.com.requests.find(q=>q.op_id==="v5-base");
                  for(const [pref,nom] of [["A","CLIENTE A SA"],["B","CLIENTE B SRL"]]) for(let i=1;i<=30;i++){ const q=JSON.parse(JSON.stringify(t)); q.id="v5-"+pref+i; q.number="AUT-"+pref+String(i).padStart(4,"0");
                    q.op_id="v5-op-"+pref+i; q.order_ref=pref+"-"+i; q.client.razon_social=nom; q.created_at=new Date(Date.parse("2026-09-01T10:00:00Z")+(pref==="A"?0:1e9)+i*3600e3).toISOString(); q.updated_at=q.created_at; d.com.requests.push(q); }'''))
                await co.evaluate('()=>{location.hash="#/autorizaciones?v=historial"}'); await co.reload(); await co.wait_for_timeout(2200)
                await co.evaluate('''()=>{const A=window.OKD_ONLINE.api, orig=A.comHistory.bind(A); window.__hCalls=[]; window.__hSlow=null;
                  A.comHistory=(scope,f,cur,lim)=>{ window.__hCalls.push({q:(f&&f.q)||"", cur:!!cur}); const p=orig(scope,f,cur,lim); const slow=window.__hSlow && window.__hSlow(f,cur);
                    return slow ? new Promise(r=>setTimeout(()=>r(p),1500)) : p; };}''')
                LIST = '()=>({clientes:[...new Set([...document.querySelectorAll("[data-hid] .hist-cli")].map(e=>e.textContent))], n:document.querySelectorAll("[data-hid]").length, campo:document.querySelector("#hQ").value})'
                # (a) A lenta, B rápida → al final SOLO B
                await co.evaluate('()=>{window.__hSlow=(f)=>f&&f.q==="CLIENTE A"}')
                await co.fill('#hQ', 'CLIENTE A'); await co.click('#hGo'); await co.wait_for_timeout(150); await co.fill('#hQ', 'CLIENTE B'); await co.click('#hGo'); await co.wait_for_timeout(2600)
                ab = await co.evaluate(LIST)
                # (b) «Cargar más» LENTO de B y, mientras tanto, nueva búsqueda A rápida → solo A, sin mezclar cursores
                await co.evaluate('()=>{window.__hSlow=(f,cur)=>!!cur}')
                await co.click('#hMore'); await co.wait_for_timeout(150); await co.fill('#hQ', 'CLIENTE A'); await co.click('#hGo'); await co.wait_for_timeout(2600)
                ba = await co.evaluate(LIST)
                # (c) doble clic en «Cargar más» → UNA sola carga de esa página
                await co.evaluate('()=>{window.__hSlow=(f,cur)=>!!cur; window.__hCalls=[]}')
                await co.evaluate('()=>{const b=document.querySelector("#hMore"); b.click(); b.click();}'); await co.wait_for_timeout(2600)
                dbl = await co.evaluate('()=>({cargas:window.__hCalls.filter(x=>x.cur).length, n:document.querySelectorAll("[data-hid]").length, ids:new Set([...document.querySelectorAll("[data-hid]")].map(b=>b.dataset.hid)).size})')
                res('E01 (N-V4-04) HISTORIAL con respuestas INVERTIDAS: buscar A (lenta) y luego B (rápida) muestra SOLO B; «Cargar más» lento de B durante una nueva búsqueda A no mezcla filas ni cursores; doble clic en «Cargar más» = UNA carga sin duplicados',
                    ab['clientes'] == ['CLIENTE B SRL'] and ab['campo'] == 'CLIENTE B' and ab['n'] == 25 and ba['clientes'] == ['CLIENTE A SA'] and ba['n'] == 25
                    and dbl['cargas'] == 1 and dbl['n'] == 30 and dbl['ids'] == 30, {'A_luego_B': ab, 'mas_B_luego_A': ba, 'doble_clic': dbl})
                # ===== E02 · N-V4-06 · formulario de entrega REAL del chofer + firma con alarma entrante =====
                # mismo contexto móvil CON ubicación GPS que las pruebas del chofer (el recorrido real exige ubicación al salir del depósito)
                gctx = await b.new_context(storage_state=state, viewport={'width': 412, 'height': 915}, device_scale_factor=2.625, is_mobile=True, has_touch=True,
                                           geolocation={'latitude': -32.89, 'longitude': -68.84}, permissions=['geolocation'])
                g = await gctx.new_page(); g.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
                await g.goto(f'http://127.0.0.1:{dp.PORT}/'); await sync(ad, g); await dp.login(g, 'gabriel@okdespacho.demo'); await dp.open_route(g, ids['gb'], km=50100)
                sc = await dp.stop_id(g, ids['gb'], 0)
                if await g.locator(f'.drv-stop[data-s="{sc}"] [data-arrive]').count(): await g.locator(f'.drv-stop[data-s="{sc}"] [data-arrive]').click(); await g.wait_for_timeout(1500)
                await dp.choose(g, sc, 'ENTREGADO')
                recv = g.locator(f'.drv-stop[data-s="{sc}"] [data-f="recv"]'); await recv.click(); await recv.fill('Receptor con alarma entrante')
                await g.evaluate(INJECT('u-gabriel'), 2); await poll(g)
                en_form = await g.evaluate('''(sid)=>{const s=window.__okdComAlarm||{}, f=document.querySelector('.drv-stop[data-s="'+sid+'"] [data-f="recv"]');
                  return {supp:s.suppressed||null, pill:!!document.querySelector("#comAlarm [data-al-pill]"), panel:!!document.querySelector("#comAlarm [data-al-panel]"), botones:document.querySelectorAll("#comAlarm [data-al-attend]").length,
                    texto:(document.getElementById("comAlarm")||{}).innerText||"", valor:f&&f.value, foco:document.activeElement===f,
                    sin_toques:(()=>{const p=document.querySelector("#comAlarm [data-al-pill]"); return !p || getComputedStyle(p).pointerEvents==='none'})(),
                    guardar_libre:(()=>{const b=document.querySelector('.drv-stop[data-s="'+sid+'"] [data-save]'); if(!b) return false; b.scrollIntoView({block:"center"}); const r=b.getBoundingClientRect(); const t=document.elementFromPoint(r.left+r.width/2, r.top+r.height/2); return t===b||b.contains(t)})()}}''', sc)
                await g.screenshot(path=os.path.join(OUT, '1_entrega_chofer_con_alarma.png'))
                await g.locator(f'.drv-stop[data-s="{sc}"] [data-sigopen]').click(); await g.wait_for_selector('.drv-sign-modal [data-sigpad]'); await poll(g)
                en_firma = await g.evaluate('''()=>({supp:(window.__okdComAlarm||{}).suppressed||null, panel:!!document.querySelector("#comAlarm [data-al-panel]"), botones:document.querySelectorAll("#comAlarm [data-al-attend]").length,
                  nada:((document.getElementById("comAlarm")||{}).innerText||"").trim()==="",
                  confirmar_libre:(()=>{const b=document.querySelector(".drv-sign-modal [data-sigok]"); if(!b) return false; const r=b.getBoundingClientRect(); const t=document.elementFromPoint(r.left+r.width/2, r.top+r.height/2); return t===b||b.contains(t)})()})''')
                bb = await g.locator('.drv-sign-modal [data-sigpad]').bounding_box()
                await g.mouse.move(bb['x'] + bb['width'] * .2, bb['y'] + bb['height'] * .5); await g.mouse.down(); await g.mouse.move(bb['x'] + bb['width'] * .7, bb['y'] + bb['height'] * .4, steps=8); await g.mouse.up()
                await g.click('.drv-sign-modal [data-sigok]'); await g.wait_for_selector('.drv-sign-modal', state='detached')
                await dp.fill_id(g, sc, '20987654326', png); await g.locator(f'.drv-stop[data-s="{sc}"] [data-save]').click(); await g.wait_for_timeout(2200); await poll(g)
                fin = await g.evaluate('''(a)=>{const d=JSON.parse(localStorage.getItem("%s")); const r=d.routes2.find(x=>x.id===a.rid); const s=r.stops.find(x=>x.id===a.sid);
                  return {estado:s.outcome, receptor:(s.evidence&&s.evidence.receiver_name)||s.receiver_name||null, panel:!!document.querySelector("#comAlarm [data-al-panel]")||!!document.querySelector("#comAlarm [data-al-bar]"), supp:(window.__okdComAlarm||{}).suppressed||null}}''' % K, {'rid': ids['gb'], 'sid': sc})
                res('E02 (N-V4-06) CHOFER que también es destinatario: con el FORMULARIO DE ENTREGA real abierto y datos escritos, la alarma entrante queda como indicador SIN datos ni botones, que NO captura toques (GUARDAR libre); no cambia lo escrito ni quita el FOCO; con la FIRMA abierta NO se ve nada y CONFIRMAR FIRMA queda libre; la entrega se guarda INTACTA y, al cerrarse el formulario, vuelve el aviso',
                    en_form['supp'] == 'CRITICO' and en_form['pill'] and not en_form['panel'] and en_form['botones'] == 0 and 'CLIENTE DE PRUEBA' not in en_form['texto']
                    and en_form['valor'] == 'Receptor con alarma entrante' and en_form['foco'] and en_form['sin_toques'] and en_form['guardar_libre']
                    and en_firma['supp'] == 'FIRMA' and not en_firma['panel'] and en_firma['botones'] == 0 and en_firma['nada'] and en_firma['confirmar_libre']
                    and fin['estado'] == 'ENTREGADO' and fin['receptor'] == 'Receptor con alarma entrante' and fin['panel'] and fin['supp'] is None,
                    {'formulario': {k: en_form[k] for k in ('supp', 'pill', 'panel', 'valor', 'foco')}, 'firma': en_firma, 'final': fin})
                # ===== E03 · aceptación visual: pantalla CHICA y TECLADO ABIERTO con 1/3/6 =====
                geo = {}
                wi = await (await mk(320, 568, True)).new_page(); await wi.goto(f'http://127.0.0.1:{dp.PORT}/'); await sync(ad, wi); await enter(wi, 'wilfredo@okdespacho.demo')
                for n in (1, 3, 6):
                    await wi.evaluate(INJECT('u-wilfredo'), n); await poll(wi); geo['chica_320x568_' + str(n)] = await wi.evaluate(GEO)
                await wi.screenshot(path=os.path.join(OUT, '2_seis_alarmas_320.png'))
                await wi.set_viewport_size({'width': 390, 'height': 420}); await wi.wait_for_timeout(400)   # TECLADO ABIERTO: la vista visible se reduce a ~420 px
                for n in (1, 3, 6):
                    await wi.evaluate(INJECT('u-wilfredo'), n); await poll(wi); geo['teclado_390x420_' + str(n)] = await wi.evaluate(GEO)
                await wi.screenshot(path=os.path.join(OUT, '3_seis_alarmas_teclado.png'))
                okg = all(x['alto'] <= x['vh'] * 0.62 + 30 and x['boton_visible'] and x['desborde_h'] <= 0 and not x['tarjetas_desbordan'] for x in geo.values()) and geo['chica_320x568_6']['desplazable'] and geo['teclado_390x420_6']['desplazable']
                res('E03 aceptación visual: pantalla CHICA (320×568) y TECLADO ABIERTO (vista 390×420) con 1, 3 y 6 alarmas: aviso contenido (≤ ~60 %), desplazamiento interno, primer ATENDER visible, sin desbordes',
                    okg, geo)
                # ===== E04 · N-V4-01 en pantalla =====
                await wi.set_viewport_size({'width': 390, 'height': 844}); await wi.evaluate(INJECT('u-wilfredo'), 1); await poll(wi); antes = await wi.evaluate(ST)
                await wi.evaluate(mutate('d.users.find(u=>u.id==="u-wilfredo").disabled_modules=["COMERCIAL"]')); await poll(wi)
                restr = await wi.evaluate('()=>({ringing:!!(window.__okdComAlarm||{}).ringing, texto:(document.getElementById("comAlarm")||{}).innerText||"", botones:document.querySelectorAll("#comAlarm [data-al-attend]").length})')
                await wi.evaluate(mutate('d.users.find(u=>u.id==="u-wilfredo").disabled_modules=[]')); await poll(wi); despues = await wi.evaluate(ST)
                fr = await (await mk()).new_page(); await fr.goto(f'http://127.0.0.1:{dp.PORT}/'); await sync(wi, fr)
                await fr.evaluate(mutate('d.users.find(u=>u.id==="u-franco").disabled_modules=["COMERCIAL"]')); await enter(fr, 'franco@okdespacho.demo')
                adm_r = await fr.evaluate('async()=>{const A=window.OKD_ONLINE.api, t=async f=>{try{await f(); return "OK"}catch(e){return e.code}}; return {cfg: await t(()=>A.comConfig()), todas: await t(()=>A.comHistory("TODAS",{},null,25)), alarmas: (await A.comMyAlarms()).length}}')
                res('E04 (N-V4-01) en pantalla: el aprobador con COMERCIAL restringido deja de ver la alarma (sin datos ni botones, sin sonido); al restaurarlo vuelve; el ADMINISTRADOR con COMERCIAL restringido no accede a la configuración, al historial TODAS ni a alarmas',
                    antes['ringing'] and not restr['ringing'] and restr['botones'] == 0 and 'CLIENTE DE PRUEBA' not in restr['texto'] and despues['ringing']
                    and adm_r['cfg'] == 'FORBIDDEN' and adm_r['todas'] == 'FORBIDDEN' and adm_r['alarmas'] == 0, {'restringido': restr, 'admin': adm_r})
                # ===== E05 · N-V4-03 · KPI deshabilitado desde el inicio y foto anterior oculta en la bandeja =====
                ap = await (await mk()).new_page(); await ap.goto(f'http://127.0.0.1:{dp.PORT}/'); await sync(co, ap)
                await ap.evaluate(mutate('const q=d.com.requests.find(x=>x.op_id==="v5-base"); q.kpi={status:"OK", average:1000, floor:1250, ceiling:1500, months:3}'))
                await enter(ap, 'wilfredo@okdespacho.demo'); await ap.evaluate('()=>{location.hash="#/autorizaciones?v=gerencia"}'); await ap.wait_for_timeout(2200)
                await ap.evaluate('()=>{const b=[...document.querySelectorAll("[data-select]")].find(x=>x.textContent.includes("CLIENTE")||x.textContent.includes("AUT-")); if(b) b.click()}'); await ap.wait_for_timeout(1200)
                bandeja = await ap.evaluate('()=>document.querySelector("#comMain").innerText.replace(/\\s+/g," ")')
                import re as _re   # cifras del KPI viejo como importes COMPLETOS ($ 1.000 / $ 1.250 / $ 1.500), no como parte del saldo «$ 1.250.000» de cuenta corriente
                kpi_vals = [m.group(0) for m in _re.finditer(r'\$\s?1\.(000|250|500)(?![.\d])', bandeja)]
                det_api = await ap.evaluate('async()=>{const L=await window.OKD_ONLINE.api.comList("BANDEJA"); const q=L.find(x=>x.number&&x.order_ref==="H-0"); return q?q.kpi:null}')
                res('E05 (N-V4-03) KPI DESHABILITADO desde el PRIMER acceso a una demo nueva; en la bandeja del aprobador una foto ANTERIOR con cifras (promedio/piso/techo) se muestra como «KPI DESHABILITADO» y no expone las cifras',
                    kpi0 == 'DESHABILITADO' and 'KPI DESHABILITADO' in bandeja and not kpi_vals
                    and det_api and det_api.get('status') == 'DESHABILITADO' and 'floor' not in det_api, {'modo_inicial': kpi0, 'kpi_api': det_api, 'bandeja_tiene_KPI_DESHABILITADO': 'KPI DESHABILITADO' in bandeja, 'cifras_kpi_en_pantalla': kpi_vals})
                # ===== E06 · N-V4-05 · día ARGENTINO en el filtro de la pantalla =====
                await co.evaluate(mutate('''const t=d.com.requests.find(q=>q.op_id==="v5-base"); for(const [k,ts] of [["a","2026-11-14T02:59:59Z"],["b","2026-11-14T03:00:00Z"],["c","2026-11-15T01:30:00Z"],["d","2026-11-15T02:59:59Z"],["e","2026-11-15T03:00:00Z"]]){
                    const q=JSON.parse(JSON.stringify(t)); q.id="fec-"+k; q.number="FEC-"+k; q.op_id="fec-op-"+k; q.order_ref="F-"+k; q.client.razon_social="CLIENTE FECHAS"; q.created_at=ts; q.updated_at=ts; d.com.requests.push(q); }'''))
                await co.reload(); await co.wait_for_timeout(2200); await co.click('#hClear'); await co.wait_for_timeout(800)
                await co.fill('#hQ', 'CLIENTE FECHAS'); await co.fill('#hFrom', '2026-11-14'); await co.fill('#hTo', '2026-11-14'); await co.click('#hGo'); await co.wait_for_timeout(1200)
                dias = await co.evaluate('()=>[...document.querySelectorAll("[data-hid]")].map(b=>b.dataset.hid).sort()')
                res('E06 (N-V4-05) filtro del 14/11 en la PANTALLA = día argentino: incluye 00:00 AR (03:00 UTC), 22:30 AR (01:30 UTC del 15) y 23:59:59 AR; excluye 13/11 23:59:59 AR y 15/11 00:00 AR',
                    dias == ['fec-b', 'fec-c', 'fec-d'], dias)
            finally: await b.close()
    finally: srv.terminate()
    print('TOTAL', sum(1 for r in R if r[1] == 'PASS'), 'PASS /', sum(1 for r in R if r[1] == 'FAIL'), 'FAIL · esperados', EXPECTED)
    return R
if __name__ == '__main__':
    try: rr = asyncio.run(main())
    except Exception as e: traceback.print_exc(); print('ERROR:', repr(e)); sys.exit(2)
    if len(rr) != EXPECTED: print('ERROR: se ejecutaron %d de %d' % (len(rr), EXPECTED)); sys.exit(2)
    sys.exit(1 if any(r[1] != 'PASS' for r in rr) else 0)
