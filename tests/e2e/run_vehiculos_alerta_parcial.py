"""E2E (modo demo, Chromium) · Restauración PARCIAL: resolución de alerta escrita → se revoca todo el acceso → se restituye → falla SOLO la consulta
de alertas → REINTENTAR → la resolución vuelve intacta, sin sobrescribir lo que el usuario siguió escribiendo. Datos FICTICIOS.
Exit 0 PASS · 1 FAIL · 2 error."""
import asyncio, os, sys, traceback, json
sys.path.insert(0, os.path.dirname(__file__))
import run_cambiar_rol as cr
from playwright.async_api import async_playwright
cr.PORT = 4391; K = cr.K; R = []; EXPECTED = 7
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:260])); print('..', ' | '.join(R[-1]), flush=True)
U = [('va', 'Operario Alertas QA', 'vala.qa@example.invalid', 'OPERARIO_DEPOSITO')]
ACCESS = ['vehicle_mileage.view', 'vehicles.view', 'vehicles.manage']
NOTE = 'Resolución escrita QA: el odómetro se cambió en el taller'
def db_js(body): return f'()=>{{ const d=JSON.parse(localStorage.getItem("{K}")); {body}; localStorage.setItem("{K}", JSON.stringify(d)); }}'
def revoke_all(uid): return db_js(f"const u=d.users.find(x=>x.id==='{uid}'); u.permission_overrides=u.permission_overrides||{{}}; " + ' '.join(f"u.permission_overrides['{p}']=false;" for p in ACCESS))
def restore(uid): return db_js(f"const u=d.users.find(x=>x.id==='{uid}'); u.permission_overrides['vehicles.manage']=true; u.permission_overrides['vehicle_mileage.view']=true; delete u.permission_overrides['vehicles.view'];")
DRAFT = '()=>{ const k=Object.keys(sessionStorage).find(k=>k.startsWith("okd_veh_draft:")); return k ? JSON.parse(sessionStorage.getItem(k)).vals : null; }'
async def main():
    srv = cr.serve()
    try:
        async with async_playwright() as p:
          b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
          try:
            ctx = await b.new_context(**cr.DESK); pg = await ctx.new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
            await pg.goto(f'http://127.0.0.1:{cr.PORT}/'); await pg.evaluate('()=>localStorage.clear()'); await cr.login(pg, 'admin@okdespacho.demo')
            ids = await pg.evaluate(cr.SETUP, U); uid = ids['va']
            for x in ('vehicles.manage', 'vehicle_mileage.view', 'vehicle_mileage.enter', 'vehicle_mileage.resolve_alerts'): await pg.evaluate(f'async()=>window.OKD_ONLINE.api.setUserPermission("{uid}", "{x}", "GRANT", "prueba")')
            await pg.evaluate(db_js("d.mileageAlerts = (d.mileageAlerts||[]).concat([{id:'al-parcial', vehicle_id:'vh-1', plate:'AB123CD', kind:'LOWER_THAN_LAST', km_from:50000, km_to:49000, status:'OPEN', created_at:new Date().toISOString()}])"))
            state = await pg.evaluate(f'()=>localStorage.getItem("{K}")'); await ctx.close()
            ctx = await b.new_context(**cr.DESK); await ctx.add_init_script('window.OKD_REVOKE_CHECK_MS = 1500;'); pg = await ctx.new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
            await pg.goto(f'http://127.0.0.1:{cr.PORT}/'); await pg.evaluate(f'(s)=>localStorage.setItem("{K}", s)', state); await cr.login(pg, 'vala.qa@example.invalid')
            await pg.evaluate('()=>{location.hash="#/vehiculos"}'); await pg.wait_for_timeout(1800); await cr.dismiss(pg)
            # 1) resolución escrita (y un formulario abierto con datos)
            await pg.fill('tr[data-aid="al-parcial"] [data-note]', NOTE)
            await pg.click('#vehNew'); await pg.wait_for_timeout(500); await pg.fill('#vfName', 'Formulario escrito QA'); await pg.fill('#vfPlate', 'QA888HH')
            # 2) se revoca todo el acceso → 3) se restituye con la consulta de ALERTAS fallando
            await pg.evaluate(revoke_all(uid)); await pg.wait_for_timeout(5000)
            blocked = await pg.evaluate('()=>!!document.getElementById("vehBlocked")')
            await pg.evaluate('()=>{ const A=window.OKD_ONLINE.api; A.__al=A.listMileageAlerts; A.listMileageAlerts=async()=>{ throw new Error("Failed to fetch (simulado)") }; }')
            await pg.evaluate(restore(uid)); await pg.wait_for_timeout(5000)
            st = await pg.evaluate('''()=>({alertas_error: !!document.getElementById("kmAlertsErr"), vehiculos: !!document.getElementById("vehTable"),
              form: (document.getElementById("vfName")||{}).value||null})'''); d1 = await pg.evaluate(DRAFT)
            res('AP-01 restitución con falla SOLO de alertas: vuelven los vehículos y el formulario, y la resolución NO se descarta (sigue en el respaldo)',
                blocked and st == {'alertas_error': True, 'vehiculos': True, 'form': 'Formulario escrito QA'} and d1 and d1['note'].get('al-parcial') == NOTE, {'pantalla': st, 'respaldo': d1})
            # 4) el usuario sigue escribiendo; además cambian otros permisos (el respaldo no pierde la resolución pendiente)
            await pg.fill('#vfName', 'Seguí escribiendo QA')
            await pg.evaluate(db_js(f"const u=d.users.find(x=>x.id==='{uid}'); u.permission_overrides['reports.view']=true")); await pg.wait_for_timeout(5000)
            d2 = await pg.evaluate(DRAFT); f2 = await pg.input_value('#vfName')
            res('AP-02 otro cambio de permisos mientras la resolución está pendiente: el respaldo la conserva y no pisa lo escrito', d2 and d2['note'].get('al-parcial') == NOTE and f2 == 'Seguí escribiendo QA', {'respaldo': d2, 'formulario': f2})
            # 5) se recupera la consulta y el usuario toca REINTENTAR
            await pg.evaluate('()=>{ const A=window.OKD_ONLINE.api; A.listMileageAlerts=A.__al; }'); await pg.locator('#kmAlertsErr [data-retry]').click(); await pg.wait_for_timeout(2000)
            note = await pg.evaluate('()=>(document.querySelector(\'tr[data-aid="al-parcial"] [data-note]\')||{}).value||null'); f3 = await pg.evaluate('()=>(document.getElementById("vfName")||{}).value||null')
            res('AP-03 REINTENTAR: la resolución vuelve INTACTA', note == NOTE, note)
            res('AP-04 y lo que el usuario siguió escribiendo NO se sobrescribe con el respaldo', f3 == 'Seguí escribiendo QA', f3)
            res('AP-05 recién con todo recuperado se limpia el respaldo', await pg.evaluate(DRAFT) is None, await pg.evaluate(DRAFT))
            await pg.click('tr[data-aid="al-parcial"] [data-res]'); await pg.wait_for_timeout(1800)
            solved = await pg.evaluate(f'()=>(JSON.parse(localStorage.getItem("{K}")).mileageAlerts||[]).find(a=>a.id==="al-parcial")')
            res('AP-06 la resolución recuperada se puede guardar', solved and solved['status'] != 'OPEN' and NOTE in json.dumps(solved, ensure_ascii=False), solved)
            # CARGAR KM con éxito: SOLO ese campo se vacía; lo escrito en OTRO vehículo se conserva en el redibujo
            await pg.evaluate(db_js("d.vehicles.push({id:'vh-qa2', name:'Otro QA', plate:'QA999II', active:true, current_km:1000, last_service_km:1000, service_interval_km:10000})"))
            await pg.evaluate('()=>{location.hash="#/"}'); await pg.wait_for_timeout(600); await pg.evaluate('()=>{location.hash="#/vehiculos"}'); await pg.wait_for_timeout(1800); await cr.dismiss(pg)
            km0 = await pg.evaluate('()=>{const v=(JSON.parse(localStorage.getItem("okd_online_demo_v2")).vehicles||[]).find(x=>x.id==="vh-1"); return v.current_km}')
            await pg.fill('tr[data-vid="vh-qa2"] [data-km]', '1234'); await pg.fill('tr[data-vid="vh-1"] [data-km]', str(int(km0) + 50))
            await pg.click('tr[data-vid="vh-1"] [data-rec]'); await pg.wait_for_timeout(1800)
            kk = await pg.evaluate('()=>({cargado: (document.querySelector(\'tr[data-vid="vh-1"] [data-km]\')||{}).value, otro: (document.querySelector(\'tr[data-vid="vh-qa2"] [data-km]\')||{}).value})')
            res('AP-07 CARGAR KM con éxito vacía SOLO ese campo; el km escrito en otro vehículo se conserva', kk == {'cargado': '', 'otro': '1234'}, kk)
            await ctx.close()
          finally: await b.close()
    finally:
        if srv.poll() is None: srv.terminate(); srv.wait(5)
    print('TOTAL', sum(1 for r in R if r[1] == 'PASS'), 'PASS /', sum(1 for r in R if r[1] == 'FAIL'), 'FAIL · esperados', EXPECTED)
    return R
if __name__ == '__main__':
    if len(sys.argv) > 1: cr.DIST = sys.argv[1]
    try: rr = asyncio.run(main())
    except Exception as e: traceback.print_exc(); print('ERROR:', repr(e)); sys.exit(2)
    if len(rr) != EXPECTED: print('ERROR: se ejecutaron %d de %d' % (len(rr), EXPECTED)); sys.exit(2)
    sys.exit(1 if any(r[1] != 'PASS' for r in rr) else 0)
