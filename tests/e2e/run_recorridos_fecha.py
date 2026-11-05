"""E2E (modo demo) · SALIDA Y RECORRIDO · columna FECHA (fecha programada de la hoja, del snapshot publicado) después de HOJA, en DD/MM/AAAA;
SIN REGISTRO si la hoja no tiene fecha (sin inventarla); no se confunde con SALIDA/REGRESO reales. Uso: python3 run_recorridos_fecha.py [dist-demo]"""
import asyncio, os, sys, traceback
sys.path.insert(0, os.path.dirname(__file__))
import run_driver_perfiles as dp
from playwright.async_api import async_playwright
dp.PORT = 4415; R = []; EXPECTED = 9
if len(sys.argv) > 1: dp.DIST = sys.argv[1]
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:260])); print('..', ' | '.join(R[-1]), flush=True)
PUB = '''async()=>{const A=window.OKD_ONLINE.api; const base={rules_version:1, routing_rules_version:1, carrier_id:'INTERNO', responsable_id:'u-gabriel', vehicle_id:'vh-1'};
  const st=n=>({ready:true, client_name:'Sucursal San Juan', address:'San Juan 500', stop_type:'UBICACION_INTERNA', internal_location_key:'SAN_JUAN', order_numbers:[String(n)]});
  const pdf=f=>({pdf_model:{data:[{r:{fecha:f, cliente:'Sucursal San Juan', pedidoWeb:'x'}}]}});
  const r1=await A.publishRoute(Object.assign({sheet_key:'qa-f1-'+Date.now(), stops:[st(95001)]}, base, pdf('2026-11-05')));
  const r2=await A.publishRoute(Object.assign({sheet_key:'qa-f2-'+Date.now(), stops:[st(95002)]}, base, pdf('2026-10-28')));
  const r3=await A.publishRoute(Object.assign({sheet_key:'qa-f3-'+Date.now(), stops:[st(95003)]}, base));   // hoja SIN fecha en su snapshot
  await A.cancelRoute(r2.id, 'prueba de fecha en hoja cancelada');
  return {r1:r1.id, r2:r2.id, r3:r3.id}; }'''
ROWS = '''()=>({head:[...document.querySelectorAll("#rcTable thead th")].map(t=>t.textContent), rows:Object.fromEntries([...document.querySelectorAll("#rcTable tr[data-rid]")].map(t=>[t.dataset.rid,
  {fecha:t.querySelector("[data-fecha]").textContent, cells:[...t.children].map(c=>c.textContent)}]))})'''
async def main():
    srv = dp.serve()
    try:
        async with async_playwright() as p:
            b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
            try:
                pg = await (await b.new_context(viewport={'width': 1366, 'height': 900})).new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
                await pg.goto(f'http://127.0.0.1:{dp.PORT}/'); await pg.evaluate('()=>localStorage.clear()'); await dp.login(pg, 'admin@okdespacho.demo')
                ids = await pg.evaluate(PUB); state = await pg.context.storage_state(); await pg.context.close()
                c = await b.new_context(storage_state=state, viewport={'width': 412, 'height': 915}, is_mobile=True, geolocation={'latitude': -32.9, 'longitude': -68.8}, permissions=['geolocation'])
                q = await c.new_page(); q.on('dialog', lambda d: asyncio.ensure_future(d.accept())); await dp.login(q, 'gabriel@okdespacho.demo'); await dp.open_route(q, ids['r1'], km=50100)   # SALIDA real de R1
                state = await c.storage_state(); await c.close()
                ctx = await b.new_context(storage_state=state, viewport={'width': 1366, 'height': 900}); pg = await ctx.new_page(); await pg.goto(f'http://127.0.0.1:{dp.PORT}/'); await dp.login(pg, 'admin@okdespacho.demo')
                await pg.evaluate('()=>{location.hash="#/recorridos"}'); await pg.wait_for_timeout(1800); t = await pg.evaluate(ROWS); rr = t['rows']
                res('RF-01 la columna FECHA está inmediatamente después de HOJA', t['head'][:2] == ['HOJA', 'FECHA'], t['head'])
                res('RF-02 cada hoja muestra SU fecha programada (DD/MM/AAAA): 05/11/2026 · 28/10/2026 (CANCELADA, sigue visible) · SIN REGISTRO (hoja sin fecha, no se inventa)',
                    rr[ids['r1']]['fecha'] == '05/11/2026' and rr[ids['r2']]['fecha'] == '28/10/2026' and 'CANCELADA' in ' '.join(rr[ids['r2']]['cells']) and rr[ids['r3']]['fecha'] == 'SIN REGISTRO',
                    {k: (v['fecha'], v['cells'][6]) for k, v in rr.items() if k in ids.values()})
                today = await pg.evaluate("()=>new Intl.DateTimeFormat('es-AR',{timeZone:'America/Argentina/Mendoza',day:'2-digit',month:'2-digit',year:'numeric'}).format(new Date())")
                r1 = rr[ids['r1']]['cells']
                res('RF-03 la FECHA de la hoja NO se confunde con la SALIDA real ni con el día de publicación (R1: fecha 05/11/2026; salida registrada hoy; R3 sin fecha aunque se publicó hoy)',
                    r1[1] == '05/11/2026' and r1[4] != 'SIN REGISTRO' and r1[4].startswith(today) and rr[ids['r3']]['fecha'] == 'SIN REGISTRO', {'fecha': r1[1], 'salida': r1[4], 'hoy': today})
                await pg.fill('#rcFrom', await pg.input_value('#rcFrom')); f0 = [await pg.input_value('#rcFrom'), await pg.input_value('#rcTo')]
                await pg.locator(f'#rcTable tr[data-rid="{ids["r1"]}"] [data-rcview]').click(); await pg.wait_for_timeout(1300); det = await pg.locator('#rcRoute').count()
                await pg.click('[data-rctab="list"]'); await pg.wait_for_timeout(600)
                back = await pg.evaluate(ROWS); f1 = [await pg.input_value('#rcFrom'), await pg.input_value('#rcTo')]
                res('RF-04 VER RECORRIDO abre el detalle y LISTADO vuelve a la lista con los mismos filtros y fechas', det == 1 and f0 == f1 and back['rows'][ids['r1']]['fecha'] == '05/11/2026', {'filtros': f1})
                # RF-06: ERROR de la consulta (conexión / permisos) → aviso y NO DISPONIBLE (nunca SIN REGISTRO)
                await pg.evaluate('()=>{window.OKD_ONLINE.api.routesListInfo = async()=>{throw new Error("permission denied for table routes")}}')
                await pg.click('#rcGo'); await pg.wait_for_timeout(1200); e = await pg.evaluate(ROWS)
                warn = await pg.evaluate('()=>{const w=document.getElementById("rcInfoErr"); return w?w.textContent:null}')
                cells = [v['cells'] for k, v in e['rows'].items() if k in ids.values()]
                res('RF-06 ERROR de consulta: se AVISA (con el motivo) y las celdas dicen NO DISPONIBLE — no se confunde con SIN REGISTRO',
                    bool(warn) and 'permission denied' in warn and all(c[1] == 'NO DISPONIBLE' and c[4] == 'NO DISPONIBLE' and c[5] == 'NO DISPONIBLE' for c in cells) and not any('SIN REGISTRO' in ' '.join(c) for c in cells), {'aviso': warn and warn[:90], 'fila': cells[0]})
                await ctx.close()
                # RF-07: un SUPERIOR DESPACHO solo obtiene datos de las hojas que SU listado autorizado incluye
                ctx = await b.new_context(storage_state=state, viewport={'width': 1366, 'height': 900}); pg = await ctx.new_page(); await pg.goto(f'http://127.0.0.1:{dp.PORT}/'); await dp.login(pg, 'admin@okdespacho.demo')
                await pg.evaluate('''()=>{const k="okd_online_demo_v2", d=JSON.parse(localStorage.getItem(k)); const a=d.users.find(u=>u.role==="ADMIN");
                  if(!d.users.some(u=>u.email==="qa.superior.rf@okdespacho.demo")) d.users.push(Object.assign({}, a, {id:"u-sup-rf", email:"qa.superior.rf@okdespacho.demo", role:"SUPERVISOR_DESPACHO", full_name:"QA Superior RF", extra_perms:[], denied_perms:[]}));
                  localStorage.setItem(k, JSON.stringify(d));}''')
                await pg.evaluate('async()=>{try{await window.OKD_ONLINE.api.signOut()}catch(e){}}'); await dp.login(pg, 'qa.superior.rf@okdespacho.demo')
                sc = await pg.evaluate('''async(all)=>{const A=window.OKD_ONLINE.api; const s=await A.searchRoutes({}); const ok=(s.rows||s||[]).map(r=>r.id);
                  const info=await A.routesListInfo(all); return {autorizadas:ok, devueltas:info.map(x=>x.id)};}''', list(ids.values()))
                res('RF-07 SUPERIOR DESPACHO: routesListInfo solo devuelve hojas que su listado autorizado incluye (pidió las 3; ninguna ajena se filtra)',
                    set(sc['devueltas']) <= set(sc['autorizadas']), {'autorizadas_de_las_3': len(set(sc['autorizadas']) & set(ids.values())), 'devueltas': len(sc['devueltas'])})
                await ctx.close()
                # ===== RF-08 / RF-09: conjunto EQUIVALENTE al verificado en producción (15 hojas: 15 con fecha, 12 con salida, 14 con patente, 0 con regreso) =====
                ctx = await b.new_context(viewport={'width': 1366, 'height': 900}); pg = await ctx.new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
                await pg.goto(f'http://127.0.0.1:{dp.PORT}/'); await pg.evaluate('()=>localStorage.clear()'); await dp.login(pg, 'admin@okdespacho.demo')
                plan = await pg.evaluate('''async()=>{const A=window.OKD_ONLINE.api, out=[];
                  for(let i=0;i<15;i++){ const f='2026-11-'+String(10+i).padStart(2,'0');
                    const r=await A.publishRoute({rules_version:1, routing_rules_version:1, carrier_id:'INTERNO', responsable_id:'u-gabriel', vehicle_id:'vh-1', sheet_key:'qa-p'+i+'-'+Date.now(),
                      stops:[{ready:true, client_name:'Sucursal San Juan', address:'San Juan 500', stop_type:'UBICACION_INTERNA', internal_location_key:'SAN_JUAN', order_numbers:[String(96000+i)]}], pdf_model:{data:[{r:{fecha:f}}]}});
                    out.push({id:r.id, fecha:f}); }
                  const k="okd_online_demo_v2", d=JSON.parse(localStorage.getItem(k)); const adm=d.users.find(u=>u.role==="ADMIN");
                  const add=(id,email,role,name,sup)=>{ if(!d.users.some(u=>u.id===id)) d.users.push(Object.assign({}, adm, {id, email, role, full_name:name, status:"ACTIVO", carriers:[], extra_perms:[], denied_perms:[], supervisor_user_id:sup||null})); };
                  add("u-supx","qa.supx@okdespacho.demo","SUPERVISOR_DESPACHO","QA Superior X",null); add("u-tm1","qa.tm1@okdespacho.demo","OPERARIO_DEPOSITO","QA Equipo X",'u-supx'); add("u-ot1","qa.ot1@okdespacho.demo","OPERARIO_DEPOSITO","QA Otro Equipo",null);
                  out.forEach((o,i)=>{ const r=d.routes2.find(x=>x.id===o.id); r.published_by = i<9 ? 'u-tm1' : 'u-ot1';   // 9 del equipo del Superior X, 6 de otro equipo
                    if(i<12){ r.started_at=new Date(Date.now()-3600e3*(i+1)).toISOString(); r.operational_status='EN_CURSO'; }   // 12 con SALIDA
                    if(i===14) r.vehicle_id=null; r.depot_arrived_at=null; });                                            // 14 con patente · 0 con REGRESO
                  localStorage.setItem(k, JSON.stringify(d)); return out; }''')
                byid = {o['id']: o for o in plan}; dm = lambda f: f[8:10] + '/' + f[5:7] + '/' + f[0:4]
                await pg.evaluate('()=>{location.hash="#/recorridos"}'); await pg.wait_for_timeout(1800); t = await pg.evaluate(ROWS)
                mine = {k: v['cells'] for k, v in t['rows'].items() if k in byid}
                cnt = {'fechas': sum(1 for k, c in mine.items() if c[1] == dm(byid[k]['fecha'])), 'salidas': sum(1 for c in mine.values() if c[4] not in ('SIN REGISTRO', 'NO DISPONIBLE')),
                       'patentes': sum(1 for c in mine.values() if c[3] == 'AB123CD'), 'regresos_sin_registro': sum(1 for c in mine.values() if c[5] == 'SIN REGISTRO'),
                       'no_disponible': sum(1 for c in mine.values() if 'NO DISPONIBLE' in c)}
                res('RF-08 ADMINISTRADOR · conjunto equivalente a producción (15 hojas): 15 fechas correctas por hoja · 12 salidas reales · 14 patentes · 15 regresos SIN REGISTRO · ningún NO DISPONIBLE',
                    len(mine) == 15 and cnt == {'fechas': 15, 'salidas': 12, 'patentes': 14, 'regresos_sin_registro': 15, 'no_disponible': 0}, cnt)
                await pg.evaluate('async()=>{try{await window.OKD_ONLINE.api.signOut()}catch(e){}}'); await dp.login(pg, 'qa.supx@okdespacho.demo')
                await pg.evaluate('()=>{location.hash="#/recorridos"}'); await pg.wait_for_timeout(1800); t = await pg.evaluate(ROWS)
                seen = {k: v['cells'] for k, v in t['rows'].items()}; team = [o['id'] for o in plan[:9]]
                okd = all(k in seen and seen[k][1] == dm(byid[k]['fecha']) for k in team)
                res('RF-09 SUPERIOR DESPACHO: ve EXACTAMENTE las 9 hojas de su equipo, cada una con SU fecha programada y sus datos reales; ninguna de las 6 de otro equipo',
                    set(seen) == set(team) and okd and not any('NO DISPONIBLE' in ' '.join(c) for c in seen.values()), {'ve': len(seen), 'de_su_equipo': len(set(seen) & set(team)), 'fechas_ok': okd})
                await ctx.close()
                ctx = await b.new_context(storage_state=state, viewport={'width': 412, 'height': 915}, is_mobile=True, device_scale_factor=2.625); pg = await ctx.new_page(); await pg.goto(f'http://127.0.0.1:{dp.PORT}/'); await dp.login(pg, 'admin@okdespacho.demo')
                await pg.evaluate('()=>{location.hash="#/recorridos"}'); await pg.wait_for_timeout(1800)
                a = await pg.evaluate('''()=>{const inScroll=el=>{for(let p=el.parentElement;p;p=p.parentElement){const o=getComputedStyle(p).overflowX; if(o==="auto"||o==="scroll") return true;} return false;};
                  const bad=[...document.querySelectorAll("button,input,select")].filter(el=>{const r=el.getBoundingClientRect(); return r.width>0 && !inScroll(el) && (r.right>innerWidth+1||r.left<-1);}).length;
                  return {over:document.documentElement.scrollWidth-document.documentElement.clientWidth, fuera:bad, filas:document.querySelectorAll("#rcTable tr[data-rid]").length}}''')
                await pg.screenshot(path='/tmp/rf_android.png', full_page=True)
                res('RF-05 ANDROID: la tabla con FECHA sigue usable (desplazamiento solo dentro de la tabla; sin botones cortados ni desplazamiento lateral de la página)', a['over'] <= 0 and a['fuera'] == 0 and a['filas'] >= 3, a)
                await ctx.close()
            finally: await b.close()
    finally: srv.terminate()
    print('TOTAL', sum(1 for r in R if r[1] == 'PASS'), 'PASS /', sum(1 for r in R if r[1] == 'FAIL'), 'FAIL · esperados', EXPECTED)
    return R
if __name__ == '__main__':
    try: rr = asyncio.run(main())
    except Exception as e: traceback.print_exc(); print('ERROR:', repr(e)); sys.exit(2)
    if len(rr) != EXPECTED: print('ERROR: se ejecutaron %d de %d' % (len(rr), EXPECTED)); sys.exit(2)
    sys.exit(1 if any(r[1] != 'PASS' for r in rr) else 0)
