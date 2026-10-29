"""E2E (modo demo, Chromium) · Vehículos y permisos: Operario con permisos individuales (alta, edición, activación/desactivación, inactivos),
mismo rol sin esos permisos, errores de carga con REINTENTAR, permisos que cambian con la sesión abierta, fallo de carga de permisos y
"Cambiar rol". Computadora (1366) y celular (390). Usuarios y vehículos FICTICIOS. Exit 0 PASS · 1 FAIL · 2 error."""
import asyncio, os, sys, traceback
sys.path.insert(0, os.path.dirname(__file__))
import run_cambiar_rol as cr
from playwright.async_api import async_playwright
cr.PORT = 4388; K = cr.K; R = []; EXPECTED = 13; SHOTS = '/tmp/okd_vehiculos'
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:260])); print('..', ' | '.join(R[-1]), flush=True)
FAST = 'window.OKD_REVOKE_CHECK_MS = 1500;'
U = [('vm', 'Operario Vehiculos QA', 'veh.qa@example.invalid', 'OPERARIO_DEPOSITO'), ('vr', 'Operario Sin Permisos QA', 'veh2.qa@example.invalid', 'OPERARIO_DEPOSITO')]
VPERMS = ['vehicles.manage', 'vehicle_mileage.enter', 'vehicle_mileage.edit', 'vehicle_mileage.resolve_alerts', 'vehicles.service_manage', 'routes.receive_internal']
def db_js(body): return f'()=>{{ const d=JSON.parse(localStorage.getItem("{K}")); {body}; localStorage.setItem("{K}", JSON.stringify(d)); }}'
async def ctx_for(b, kind, email):
    ctx = await b.new_context(**(cr.DESK if kind == 'desk' else cr.MOB)); await ctx.add_init_script(FAST); pg = await ctx.new_page(); dl = []
    pg.on('dialog', lambda d: (dl.append(d.message), asyncio.ensure_future(d.accept())))
    await pg.goto(f'http://127.0.0.1:{cr.PORT}/'); await pg.evaluate(f'(s)=>localStorage.setItem("{K}", s)', cr.DBSTATE[0]); await cr.login(pg, email); return ctx, pg, dl
async def vehicles(pg):
    await pg.evaluate('()=>{location.hash="#/vehiculos"}'); await pg.wait_for_timeout(1800); await cr.dismiss(pg)
async def state(pg): return await pg.evaluate('''()=>{ const t=document.getElementById("vehTable"); const rows=t?[...t.querySelectorAll("tbody tr[data-vid]")].map(r=>({plate:r.children[1].textContent, txt:r.innerText.replace(/\\s+/g," ")})):[];
  return { nuevo: !!document.getElementById("vehNew"), tag: (document.querySelector("#vehTable")?.closest("section")?.querySelector(".tag")||{}).textContent||"", tabs: [...document.querySelectorAll("[data-vtab]")].map(b=>b.textContent),
    rows, vacio: (document.getElementById("vehEmpty")||{}).textContent||"", err: (document.getElementById("vehErr")||{}).textContent||"", aerr: (document.getElementById("kmAlertsErr")||{}).textContent||"",
    edit: document.querySelectorAll("[data-vedit]").length, on: document.querySelectorAll("[data-von]").length, off: document.querySelectorAll("[data-voff]").length, km: document.querySelectorAll("[data-rec]").length,
    body: document.body.innerText } }''')
async def veh_db(pg, plate): return await pg.evaluate(f'()=>(JSON.parse(localStorage.getItem("{K}")).vehicles||[]).find(v=>v.plate==="{plate}")||null')
async def main():
    os.makedirs(SHOTS, exist_ok=True); srv = cr.serve()
    try:
        async with async_playwright() as p:
          b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
          try:
            ctx = await b.new_context(**cr.DESK); pg = await ctx.new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
            await pg.goto(f'http://127.0.0.1:{cr.PORT}/'); await pg.evaluate('()=>localStorage.clear()'); await cr.login(pg, 'admin@okdespacho.demo')
            ids = await pg.evaluate(cr.SETUP, U)
            for perm in VPERMS: await pg.evaluate(f'async()=>window.OKD_ONLINE.api.setUserPermission("{ids["vm"]}", "{perm}", "GRANT", "prueba")')
            await pg.evaluate(f'async()=>window.OKD_ONLINE.api.setUserPermission("{ids["vr"]}", "vehicle_mileage.enter", "REVOKE", "prueba: revocación explícita")')
            await pg.evaluate(db_js("d.vehicles.push({id:'vh-inact', name:'Fiorino QA', plate:'QA111AA', active:false, brand:'Fiat', model:'Fiorino', type:'Utilitario', year:2018, notes:'', current_km:12000, last_service_km:10000, service_interval_km:10000, habitual_driver_id:null})"))
            cr.DBSTATE[0] = await pg.evaluate(f'()=>localStorage.getItem("{K}")'); await ctx.close()
            # ===== Operario CON permisos · COMPUTADORA =====
            ctx, pg, dl = await ctx_for(b, 'desk', 'veh.qa@example.invalid'); await vehicles(pg); s0 = await state(pg)
            await pg.click('[data-vtab="INACTIVOS"]'); await pg.wait_for_timeout(1200); s1 = await state(pg); fi = await veh_db(pg, 'QA111AA')
            await pg.screenshot(path=os.path.join(SHOTS, 'computadora_inactivos.png'))
            res('VP-01 Operario con permisos individuales: NUEVO VEHÍCULO y administración; el inactivo se ve en INACTIVOS, sin activarse solo y sin CARGAR KM',
                s0['nuevo'] and 'Administrás vehículos' in s0['tag'] and any('INACTIVOS (1)' in t for t in s0['tabs']) and any(r['plate'] == 'QA111AA' and 'Inactivo' in r['txt'] for r in s1['rows'])
                and s1['on'] == 1 and s1['km'] == 0 and fi['active'] is False, {'tabs': s0['tabs'], 'inactivos': s1['rows'], 'db_activo': fi['active']})
            await pg.click('[data-vtab="ACTIVOS"]'); await pg.wait_for_timeout(1000); await pg.click('#vehNew'); await pg.wait_for_timeout(600)
            await pg.fill('#vfName', 'Partner QA'); await pg.fill('#vfPlate', 'qa222bb'); await pg.fill('#vfBrand', 'Peugeot'); await pg.fill('#vfYear', '2020'); await pg.fill('#vfKm', '5000')
            await pg.click('#vfSave'); await pg.wait_for_timeout(1800); s2 = await state(pg); nv = await veh_db(pg, 'QA222BB')
            res('VP-02 ALTA con el formulario: aparece en ACTIVOS con sus datos', any(r['plate'] == 'QA222BB' for r in s2['rows']) and nv and nv['active'] is True and nv['brand'] == 'Peugeot' and nv['current_km'] == 5000, nv)
            await pg.locator('tr[data-vid]', has_text='QA222BB').locator('[data-vedit]').click(); await pg.wait_for_timeout(600)
            await pg.fill('#vfName', 'Partner QA Editado'); await pg.click('#vfSave'); await pg.wait_for_timeout(1800); ed = await veh_db(pg, 'QA222BB')
            res('VP-03 EDICIÓN: guarda los cambios sin alterar el estado activo', ed['name'] == 'Partner QA Editado' and ed['active'] is True, ed)
            await pg.click('[data-vtab="INACTIVOS"]'); await pg.wait_for_timeout(1000); await pg.locator('tr[data-vid]', has_text='QA111AA').locator('[data-von]').click(); await pg.wait_for_timeout(1800)
            re_ = await veh_db(pg, 'QA111AA'); await pg.click('[data-vtab="ACTIVOS"]'); await pg.wait_for_timeout(1000); s3 = await state(pg)
            await pg.locator('tr[data-vid]', has_text='QA222BB').locator('[data-voff]').click(); await pg.wait_for_timeout(1800); off = await veh_db(pg, 'QA222BB')
            res('VP-04 REACTIVACIÓN y desactivación con confirmación (solo al tocar el botón)', re_['active'] is True and any(r['plate'] == 'QA111AA' for r in s3['rows']) and off['active'] is False
                and sum('ACTIVAR' in m or 'DESACTIVAR' in m for m in dl) >= 2, {'reactivado': re_['active'], 'desactivado': off['active'], 'confirmaciones': dl[-2:]})
            # error al cargar: distinguible de una lista vacía, con REINTENTAR
            await pg.evaluate('()=>{ const A=window.OKD_ONLINE.api; A.__vs=A.vehicleStatus; A.__al=A.listMileageAlerts; A.vehicleStatus=async()=>{ throw new Error("Failed to fetch") }; A.listMileageAlerts=async()=>{ throw new Error("Failed to fetch") }; }')
            await pg.evaluate('()=>{location.hash="#/"}'); await pg.wait_for_timeout(600); await vehicles(pg); s4 = await state(pg)
            await pg.evaluate('()=>{ const A=window.OKD_ONLINE.api; A.vehicleStatus=A.__vs; A.listMileageAlerts=A.__al; }'); await pg.locator('#vehErr [data-retry]').click(); await pg.wait_for_timeout(1800); s5 = await state(pg)
            res('VP-05 si falla la carga de vehículos o alertas: error con REINTENTAR (no "No hay vehículos" ni "Sin alertas"); al reintentar se recupera',
                'No se pudieron cargar los vehículos' in s4['err'] and 'REINTENTAR' in s4['err'] and 'No se pudieron cargar las alertas' in s4['aerr'] and not s4['vacio']
                and 'Sin vehículos' not in s4['body'] and 'Sin alertas' not in s4['body'] and not s5['err'] and len(s5['rows']) >= 1, {'error': s4['err'][:80], 'recuperado': len(s5['rows'])})
            # "No hay vehículos activos" (sin afirmar que no existen)
            await pg.evaluate(db_js("d.vehicles.forEach(v=>{ v.__was = v.active; v.active=false; })")); await pg.locator('[data-vtab="ACTIVOS"]').click(); await pg.wait_for_timeout(1500); s6 = await state(pg)
            await pg.evaluate(db_js("d.vehicles.forEach(v=>{ v.active = v.__was; delete v.__was; })"))
            res('VP-06 sin activos: "No hay vehículos activos" indicando los inactivos (no "Sin vehículos")', s6['vacio'].startswith('No hay vehículos activos') and 'inactivo' in s6['vacio'] and 'Sin vehículos' not in s6['body'], s6['vacio'])
            cr.DBSTATE[0] = await pg.evaluate(f'()=>localStorage.getItem("{K}")'); await ctx.close()
            # ===== mismo rol SIN esos permisos (y con revocación explícita) · COMPUTADORA; luego se le OTORGA con la sesión abierta =====
            ctx, pg, dl = await ctx_for(b, 'desk', 'veh2.qa@example.invalid'); await vehicles(pg); r0 = await state(pg)
            res('VP-07 mismo rol sin permisos individuales y con "cargar km" revocado: sin alta, edición, activación ni CARGAR KM', not r0['nuevo'] and r0['edit'] == 0 and r0['on'] == 0 and r0['off'] == 0
                and r0['km'] == 0 and 'Solo lectura' in r0['tag'], {'tag': r0['tag'], 'km': r0['km']})
            await pg.evaluate('()=>{ window.__marca = 1; }')
            await pg.evaluate(db_js(f"const u=d.users.find(x=>x.id==='{ids['vr']}'); u.permission_overrides = Object.assign(u.permission_overrides||{{}}, {{'vehicles.manage': true}})")); await pg.wait_for_timeout(5000)
            r1 = await state(pg); marca = await pg.evaluate('()=>window.__marca')
            res('VP-08 permiso OTORGADO con la sesión abierta: aparece NUEVO VEHÍCULO sin recargar (el trabajo se conserva)', r1['nuevo'] and r1['edit'] >= 1 and marca == 1, {'nuevo': r1['nuevo'], 'marca': marca})
            await pg.evaluate(db_js(f"const u=d.users.find(x=>x.id==='{ids['vr']}'); u.permission_overrides['vehicles.manage'] = false")); await pg.wait_for_timeout(5000); r2 = await state(pg)
            res('VP-09 y al REVOCARLO con la sesión abierta, desaparecen las acciones', not r2['nuevo'] and r2['edit'] == 0, {'nuevo': r2['nuevo']})
            await ctx.close()
            # ===== fallo al cargar permisos → error con REINTENTAR, sin panel ni acciones =====
            ctx, pg, dl = await ctx_for(b, 'desk', 'veh.qa@example.invalid')
            await pg.evaluate('()=>localStorage.setItem("okd_demo_fail_perms","1")'); await pg.reload(); await pg.wait_for_timeout(2500)
            fail = await pg.evaluate('()=>({retry: !!document.getElementById("permRetry"), msg: (document.getElementById("np-msg")||{}).textContent||"", operario: !document.getElementById("operario").hidden, panel: !!(document.getElementById("usersPanel") && !document.getElementById("usersPanel").hidden && document.querySelector("#usersPanel #adNav, #usersPanel .rc4main"))})')
            await pg.evaluate('()=>localStorage.removeItem("okd_demo_fail_perms")'); await pg.click('#permRetry'); await pg.wait_for_timeout(3500); await cr.dismiss(pg)
            ok = await pg.evaluate('()=>!document.getElementById("permRetry") || document.getElementById("noPanel").hidden')
            res('VP-10 si fallan los permisos al entrar: error con REINTENTAR y NINGÚN panel ni acción; REINTENTAR recupera (misma sesión)',
                fail['retry'] and 'permisos' in fail['msg'] and not fail['operario'] and not fail['panel'] and ok, {'fallo': fail, 'recupera': ok})
            # "Cambiar rol" con routes.receive_internal; al revocarlo desaparece
            sw = await cr.visible_switch(pg)
            await pg.evaluate(db_js(f"const u=d.users.find(x=>x.id==='{ids['vm']}'); delete u.permission_overrides['routes.receive_internal']")); await pg.wait_for_timeout(5000)
            res('VP-11 "Cambiar rol" aparece con routes.receive_internal y desaparece al revocarlo con la sesión abierta', sw is not None and await cr.visible_switch(pg) is None, {'antes': sw})
            await ctx.close()
            # ===== CELULAR: alta y vista de vehículos sin desbordar =====
            ctx, pg, dl = await ctx_for(b, 'mob', 'veh.qa@example.invalid'); await vehicles(pg); m0 = await state(pg)
            await pg.click('#vehNew'); await pg.wait_for_timeout(600); await pg.fill('#vfName', 'Kangoo Celular QA'); await pg.fill('#vfPlate', 'QA333CC'); await pg.click('#vfSave'); await pg.wait_for_timeout(1800)
            m1 = await state(pg); over = await pg.evaluate('()=>document.scrollingElement.scrollWidth - window.innerWidth')
            await pg.screenshot(path=os.path.join(SHOTS, 'celular_vehiculos.png'))
            res('VP-12 CELULAR: NUEVO VEHÍCULO y alta funcionan; la página no se desborda a lo ancho', m0['nuevo'] and any(r['plate'] == 'QA333CC' for r in m1['rows']) and over <= 1, {'desborde_px': over})
            km_tabs = await pg.evaluate('()=>[...document.querySelectorAll("[data-vtab]")].map(b=>b.getBoundingClientRect().width>0)')
            res('VP-13 CELULAR: filtro ACTIVOS / INACTIVOS visible', len(km_tabs) == 2 and all(km_tabs), km_tabs)
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
