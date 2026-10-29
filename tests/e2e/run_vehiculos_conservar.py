"""E2E (modo demo, Chromium) · Vehículos: (1) lo escrito en NUEVO VEHÍCULO, EDITAR, km y resolución de alertas se CONSERVA cuando cambian los
permisos con la sesión abierta; lo revocado no se ejecuta ni se borra; (2) la edición no ofrece cambiar marca/modelo/tipo/año (el servidor no
los guarda) y lo guardado persiste al cerrar y reabrir. Computadora y celular. Datos FICTICIOS. Exit 0 PASS · 1 FAIL · 2 error."""
import asyncio, os, sys, traceback
sys.path.insert(0, os.path.dirname(__file__))
import run_cambiar_rol as cr
from playwright.async_api import async_playwright
cr.PORT = 4389; K = cr.K; R = []; EXPECTED = 10
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:260])); print('..', ' | '.join(R[-1]), flush=True)
U = [('vm', 'Operario Vehiculos QA', 'veh.qa@example.invalid', 'OPERARIO_DEPOSITO')]
PERMS = ['vehicles.manage', 'vehicle_mileage.view', 'vehicle_mileage.enter', 'vehicle_mileage.edit', 'vehicle_mileage.resolve_alerts', 'vehicles.service_manage']
NEW = {'vfName': 'Partner Conservado QA', 'vfPlate': 'QA444DD', 'vfBrand': 'Peugeot', 'vfModel': 'Partner', 'vfType': 'Utilitario', 'vfYear': '2021', 'vfInterval': '15000', 'vfKm': '7300', 'vfNotes': 'Nota escrita antes del cambio'}
def db_js(body): return f'()=>{{ const d=JSON.parse(localStorage.getItem("{K}")); {body}; localStorage.setItem("{K}", JSON.stringify(d)); }}'
def perm(uid, p, val): return db_js(f"const u=d.users.find(x=>x.id==='{uid}'); u.permission_overrides = u.permission_overrides || {{}}; " + (f"u.permission_overrides['{p}'] = {val}" if val is not None else f"delete u.permission_overrides['{p}']"))
async def form_vals(pg): return await pg.evaluate('()=>Object.fromEntries([...document.querySelectorAll("#vehForm input")].map(i=>[i.id, i.value]))')
async def ctx_for(b, kind):
    ctx = await b.new_context(**(cr.DESK if kind == 'desk' else cr.MOB)); await ctx.add_init_script('window.OKD_REVOKE_CHECK_MS = 1500;'); pg = await ctx.new_page(); dl = []
    pg.on('dialog', lambda d: (dl.append(d.message), asyncio.ensure_future(d.accept())))
    await pg.goto(f'http://127.0.0.1:{cr.PORT}/'); await pg.evaluate(f'(s)=>localStorage.setItem("{K}", s)', cr.DBSTATE[0]); await cr.login(pg, 'veh.qa@example.invalid'); return ctx, pg
async def vehicles(pg): await pg.evaluate('()=>{location.hash="#/vehiculos"}'); await pg.wait_for_timeout(1800); await cr.dismiss(pg)
async def main():
    srv = cr.serve()
    try:
        async with async_playwright() as p:
          b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
          try:
            ctx = await b.new_context(**cr.DESK); pg = await ctx.new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
            await pg.goto(f'http://127.0.0.1:{cr.PORT}/'); await pg.evaluate('()=>localStorage.clear()'); await cr.login(pg, 'admin@okdespacho.demo')
            ids = await pg.evaluate(cr.SETUP, U); uid = ids['vm']
            for x in PERMS: await pg.evaluate(f'async()=>window.OKD_ONLINE.api.setUserPermission("{uid}", "{x}", "GRANT", "prueba")')
            await pg.evaluate(db_js("d.mileageAlerts = (d.mileageAlerts||[]).concat([{id:'al-qa', vehicle_id:'vh-1', plate:'AB123CD', kind:'LOWER_THAN_LAST', km_from:50000, km_to:49000, status:'OPEN', created_at:new Date().toISOString()}])"))
            cr.DBSTATE[0] = await pg.evaluate(f'()=>localStorage.getItem("{K}")'); await ctx.close()
            # ===== COMPUTADORA =====
            ctx, pg = await ctx_for(b, 'desk'); await vehicles(pg)
            await pg.click('#vehNew'); await pg.wait_for_timeout(600)
            for k, v in NEW.items(): await pg.fill('#' + k, v)
            await pg.evaluate(perm(uid, 'reports.view', 'true')); await pg.wait_for_timeout(5000)   # cambio de permisos NO relacionado
            v1 = await form_vals(pg)
            res('VC-01 NUEVO VEHÍCULO con todos los campos escritos: un cambio de permisos con la sesión abierta NO borra nada', v1 == NEW, {'despues': v1})
            await pg.evaluate(perm(uid, 'vehicles.manage', 'false')); await pg.wait_for_timeout(5000)   # se REVOCA la acción con el formulario abierto
            v2 = await form_vals(pg); st2 = await pg.evaluate('()=>({aviso: (document.getElementById("vfNoPerm")||{}).textContent||"", guardar_deshabilitado: !!(document.getElementById("vfSave")||{}).disabled})')
            await pg.evaluate('()=>{ const b=document.getElementById("vfSave"); if (b) { b.disabled=false; b.click(); } }'); await pg.wait_for_timeout(1500)   # aun forzando el botón
            saved = await pg.evaluate(f'()=>(JSON.parse(localStorage.getItem("{K}")).vehicles||[]).some(v=>v.plate==="QA444DD")')
            res('VC-02 al REVOCAR "administrar vehículos" con el formulario abierto: lo escrito se ve, NO se puede guardar (ni forzando el botón) y no se guarda nada',
                v2 == NEW and 'Lo que escribiste se conserva' in st2['aviso'] and st2['guardar_deshabilitado'] and not saved, {'estado': st2, 'guardado': saved})
            await pg.evaluate(perm(uid, 'vehicles.manage', 'true')); await pg.wait_for_timeout(5000)
            v3 = await form_vals(pg); await pg.click('#vfSave'); await pg.wait_for_timeout(1800)
            nv = await pg.evaluate(f'()=>(JSON.parse(localStorage.getItem("{K}")).vehicles||[]).find(v=>v.plate==="QA444DD")||null')
            res('VC-03 al volver a otorgarlo, el mismo formulario (intacto) se guarda con todos sus datos', v3 == NEW and nv and nv['brand'] == 'Peugeot' and nv['year'] == 2021 and nv['current_km'] == 7300 and nv['notes'] == NEW['vfNotes'], nv)
            # EDITAR: lo escrito se conserva; marca/modelo/tipo/año de solo lectura
            await pg.locator('tr[data-vid]', has_text='QA444DD').locator('[data-vedit]').click(); await pg.wait_for_timeout(700)
            await pg.fill('#vfName', 'Partner Editado QA'); await pg.fill('#vfNotes', 'Observación editada'); await pg.fill('#vfInterval', '20000')
            ro = await pg.evaluate('()=>({ro: ["vfBrand","vfModel","vfType","vfYear"].map(id=>document.getElementById(id).readOnly), nota: (document.getElementById("vfRoNote")||{}).textContent||""})')
            await pg.locator('#vfBrand').type('XXX'); brand_typed = await pg.input_value('#vfBrand')
            await pg.evaluate(perm(uid, 'reports.view', 'false')); await pg.wait_for_timeout(5000); ve = await form_vals(pg)
            res('VC-04 EDITAR: lo escrito se conserva al cambiar permisos; marca/modelo/tipo/año son de solo lectura, con aclaración', all(ro['ro']) and 'el servidor no guarda' in ro['nota']
                and brand_typed == 'Peugeot' and ve['vfName'] == 'Partner Editado QA' and ve['vfNotes'] == 'Observación editada' and ve['vfInterval'] == '20000', {'solo_lectura': ro, 'despues': ve})
            await pg.click('#vfSave'); await pg.wait_for_timeout(1800); okmsg = await pg.evaluate('()=>document.body.innerText.includes("Vehículo actualizado")')
            # persistencia: cerrar y reabrir (otra pantalla y vuelta, y recarga)
            await pg.evaluate('()=>{location.hash="#/"}'); await pg.wait_for_timeout(800); await pg.reload(); await pg.wait_for_timeout(2500); await vehicles(pg)
            row = await pg.locator('tr[data-vid]', has_text='QA444DD').inner_text()
            await pg.locator('tr[data-vid]', has_text='QA444DD').locator('[data-vedit]').click(); await pg.wait_for_timeout(700); re_ = await form_vals(pg)
            res('VC-05 al cerrar y reabrir persiste lo que el servidor guarda (nombre, intervalo, observaciones) y marca/año siguen como en el alta',
                okmsg and 'Partner Editado QA' in row and re_['vfName'] == 'Partner Editado QA' and re_['vfInterval'] == '20000' and re_['vfNotes'] == 'Observación editada' and re_['vfBrand'] == 'Peugeot' and re_['vfYear'] == '2021', re_)
            await pg.click('#vfCancel'); await pg.wait_for_timeout(600)
            direct = await pg.evaluate('''async()=>{ const A=window.OKD_ONLINE.api; const v=(await A.vehicleStatus()).find(x=>x.plate==="QA444DD");
              await A.saveVehicle({ id:v.id, name:v.name, plate:v.plate, brand:'OTRA', model:'OTRO', type:'OTRO', year:'1999', service_interval_km:v.service_interval_km, notes:v.notes, active:true });
              const w=(await A.vehicleStatus()).find(x=>x.plate==="QA444DD"); return [w.brand, w.model, w.year]; }''')
            res('VC-06 la demo hace lo mismo que producción: una edición que manda marca/modelo/año los IGNORA', direct == ['Peugeot', 'Partner', 2021], direct)
            # km y resolución de alerta escritos → se revoca "cargar km": se conservan (deshabilitados), sin botón
            vid = await pg.evaluate('()=>[...document.querySelectorAll("#vehTable tr[data-vid]")].find(r=>r.innerText.includes("QA444DD")).dataset.vid')
            await pg.fill(f'tr[data-vid="{vid}"] [data-km]', '7450'); await pg.fill('tr[data-aid="al-qa"] [data-note]', 'Resolución escrita QA')
            await pg.evaluate(perm(uid, 'vehicle_mileage.enter', 'false')); await pg.wait_for_timeout(5000)
            k2 = await pg.evaluate(f'''()=>{{ const i=document.querySelector('tr[data-vid="{vid}"] [data-km]'); return {{valor: i?i.value:null, deshabilitado: !!(i&&i.disabled), boton: !!document.querySelector('tr[data-vid="{vid}"] [data-rec]'),
              aviso: !!document.querySelector('tr[data-vid="{vid}"] [data-kmnoperm]'), nota: (document.querySelector('tr[data-aid="al-qa"] [data-note]')||{{}}).value||null}} }}''')
            res('VC-07 km y resolución de alerta escritos: al revocar "cargar km" el km queda visible y deshabilitado con aviso (sin botón); la resolución se conserva',
                k2 == {'valor': '7450', 'deshabilitado': True, 'boton': False, 'aviso': True, 'nota': 'Resolución escrita QA'}, k2)
            # otra pantalla: NO se reconstruye sola; aviso para actualizar
            await pg.evaluate('()=>{location.hash="#/historial"}'); await pg.wait_for_timeout(2000); await cr.dismiss(pg)
            await pg.evaluate('()=>{ const m=document.querySelector("#usersPanel input, #usersPanel select"); if (m) { m.dataset.qa="1"; if (m.tagName==="INPUT") m.value="texto QA"; } }')
            await pg.evaluate(perm(uid, 'vehicle_mileage.enter', 'true')); await pg.wait_for_timeout(5000)
            oth = await pg.evaluate('()=>({aviso: !!document.getElementById("permChanged"), conservado: !!document.querySelector("[data-qa=\\"1\\"]")})')
            res('VC-08 en otra pantalla, un cambio de permisos NO la reconstruye: aparece "ACTUALIZAR PANTALLA" y lo escrito sigue', oth == {'aviso': True, 'conservado': True}, oth)
            await ctx.close()
            # ===== CELULAR =====
            ctx, pg = await ctx_for(b, 'mob'); await vehicles(pg); await pg.click('#vehNew'); await pg.wait_for_timeout(600)
            mob = dict(NEW, vfPlate='QA555EE', vfName='Kangoo Celular QA')
            for k, v in mob.items(): await pg.fill('#' + k, v)
            await pg.evaluate(perm(uid, 'reports.view', 'true')); await pg.wait_for_timeout(5000); m1 = await form_vals(pg)
            over = await pg.evaluate('()=>document.scrollingElement.scrollWidth - window.innerWidth')
            res('VC-09 CELULAR: el formulario NUEVO VEHÍCULO conserva todo lo escrito al cambiar permisos', m1 == mob and over <= 1, {'desborde_px': over})
            await pg.click('#vfSave'); await pg.wait_for_timeout(1800)
            res('VC-10 CELULAR: y se guarda después', await pg.evaluate(f'()=>(JSON.parse(localStorage.getItem("{K}")).vehicles||[]).some(v=>v.plate==="QA555EE")'), '')
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
