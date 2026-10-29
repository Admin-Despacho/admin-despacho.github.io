"""E2E (modo demo, Chromium) · Se revoca TODO el acceso a Vehículos con un formulario abierto: se bloquea sin mostrar datos, no se puede guardar
(ni forzando), lo escrito se recupera intacto al restituir el acceso, y nunca lo ve otro usuario de la misma computadora. Datos FICTICIOS.
Exit 0 PASS · 1 FAIL · 2 error."""
import asyncio, os, sys, traceback
sys.path.insert(0, os.path.dirname(__file__))
import run_cambiar_rol as cr
from playwright.async_api import async_playwright
cr.PORT = 4390; K = cr.K; R = []; EXPECTED = 9
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:260])); print('..', ' | '.join(R[-1]), flush=True)
U = [('va', 'Operario A QA', 'veha.qa@example.invalid', 'OPERARIO_DEPOSITO'), ('vb', 'Operario B QA', 'vehb.qa@example.invalid', 'OPERARIO_DEPOSITO')]
ACCESS = ['vehicle_mileage.view', 'vehicles.view', 'vehicles.manage']   # los que habilitan la pantalla (#/vehiculos)
NEW = {'vfName': 'Partner Bloqueo QA', 'vfPlate': 'QA777GG', 'vfBrand': 'Peugeot', 'vfModel': 'Partner', 'vfType': 'Utilitario', 'vfYear': '2022', 'vfInterval': '12000', 'vfKm': '3100', 'vfNotes': 'Escrito antes de perder el acceso'}
def db_js(body): return f'()=>{{ const d=JSON.parse(localStorage.getItem("{K}")); {body}; localStorage.setItem("{K}", JSON.stringify(d)); }}'
def revoke_all(uid): return db_js(f"const u=d.users.find(x=>x.id==='{uid}'); u.permission_overrides = u.permission_overrides||{{}}; " + ' '.join(f"u.permission_overrides['{p}']=false;" for p in ACCESS))
def restore(uid): return db_js(f"const u=d.users.find(x=>x.id==='{uid}'); u.permission_overrides = u.permission_overrides||{{}}; u.permission_overrides['vehicles.manage']=true; u.permission_overrides['vehicle_mileage.view']=true; delete u.permission_overrides['vehicles.view'];")
async def form_vals(pg): return await pg.evaluate('()=>Object.fromEntries([...document.querySelectorAll("#vehForm input")].map(i=>[i.id, i.value]))')
async def blocked(pg): return await pg.evaluate('''()=>({aviso: (document.getElementById("vehBlocked")||{}).innerText||"", tabla: !!document.getElementById("vehTable"), form: !!document.getElementById("vehForm"),
  datos: document.body.innerText.includes("AB123CD"), guardado: Object.keys(sessionStorage).filter(k=>k.startsWith("okd_veh_draft:")).length})''')
async def force_save(pg):
    return await pg.evaluate('''async()=>{ const b=document.getElementById("vfSave"); let click="sin botón"; if (b) { b.disabled=false; b.click(); click="forzado"; }
      try { await window.OKD_ONLINE.api.saveVehicle({ name:"Forzado QA", plate:"QA777GG", service_interval_km:10000 }); return click+" / aceptado"; } catch(e) { return click+" / "+(e.code||e.message); } }''')
async def main():
    srv = cr.serve()
    try:
        async with async_playwright() as p:
          b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
          try:
            ctx = await b.new_context(**cr.DESK); pg = await ctx.new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
            await pg.goto(f'http://127.0.0.1:{cr.PORT}/'); await pg.evaluate('()=>localStorage.clear()'); await cr.login(pg, 'admin@okdespacho.demo')
            ids = await pg.evaluate(cr.SETUP, U)
            for k in ('va', 'vb'):
                for x in ('vehicles.manage', 'vehicle_mileage.view', 'vehicle_mileage.enter'): await pg.evaluate(f'async()=>window.OKD_ONLINE.api.setUserPermission("{ids[k]}", "{x}", "GRANT", "prueba")')
            state = await pg.evaluate(f'()=>localStorage.getItem("{K}")'); await ctx.close()
            ctx = await b.new_context(**cr.DESK); await ctx.add_init_script('window.OKD_REVOKE_CHECK_MS = 1500;'); pg = await ctx.new_page(); dl = []
            pg.on('dialog', lambda d: (dl.append(d.message), asyncio.ensure_future(d.accept())))
            await pg.goto(f'http://127.0.0.1:{cr.PORT}/'); await pg.evaluate(f'(s)=>localStorage.setItem("{K}", s)', state); await cr.login(pg, 'veha.qa@example.invalid')
            await pg.evaluate('()=>{location.hash="#/vehiculos"}'); await pg.wait_for_timeout(1800); await cr.dismiss(pg)
            # 1) NUEVO VEHÍCULO con datos escritos  2) se revocan TODOS los permisos que habilitan la pantalla
            await pg.click('#vehNew'); await pg.wait_for_timeout(600)
            for k, v in NEW.items(): await pg.fill('#' + k, v)
            await pg.evaluate(revoke_all(ids['va'])); await pg.wait_for_timeout(5000); bl = await blocked(pg)
            res('VB-01 sin acceso: aviso de acceso quitado, SIN la tabla, el formulario ni datos de vehículos', 'SE QUITÓ TU ACCESO' in bl['aviso'] and 'quedó guardado' in bl['aviso']
                and not bl['tabla'] and not bl['form'] and not bl['datos'] and bl['guardado'] == 1, bl)
            # 3) no se puede guardar, ni forzando
            fz = await force_save(pg); exists = await pg.evaluate(f'()=>(JSON.parse(localStorage.getItem("{K}")).vehicles||[]).some(v=>v.plate==="QA777GG")')
            res('VB-02 no permite guardar, ni forzando el botón ni llamando directo: rechazado y nada guardado', fz.endswith('FORBIDDEN') and not exists, fz)
            # 4) se restituye el acceso → vuelve el formulario intacto
            await pg.evaluate(restore(ids['va'])); await pg.wait_for_timeout(5000); v4 = await form_vals(pg)
            left = await pg.evaluate('()=>Object.keys(sessionStorage).filter(k=>k.startsWith("okd_veh_draft:")).length')
            res('VB-03 al restituir el acceso se recupera el formulario NUEVO VEHÍCULO intacto (y se borra lo guardado)', v4 == NEW and left == 0, {'formulario': v4, 'guardado_restante': left})
            await pg.click('#vfSave'); await pg.wait_for_timeout(1800)
            res('VB-04 y recién ahí se guarda', await pg.evaluate(f'()=>(JSON.parse(localStorage.getItem("{K}")).vehicles||[]).some(v=>v.plate==="QA777GG")'), '')
            # 5) EDITAR: lo mismo
            await pg.locator('tr[data-vid]', has_text='QA777GG').locator('[data-vedit]').click(); await pg.wait_for_timeout(700)
            await pg.fill('#vfName', 'Partner Bloqueo Editado'); await pg.fill('#vfNotes', 'Edición escrita antes de perder el acceso'); ed0 = await form_vals(pg)
            await pg.evaluate(revoke_all(ids['va'])); await pg.wait_for_timeout(5000); bl2 = await blocked(pg)
            await pg.evaluate(restore(ids['va'])); await pg.wait_for_timeout(5000); ed1 = await form_vals(pg)
            ro = await pg.evaluate('()=>["vfBrand","vfModel","vfType","vfYear"].every(id=>document.getElementById(id) && document.getElementById(id).readOnly)')
            res('VB-05 EDITAR: bloqueado sin datos al revocar; al restituir vuelve el MISMO vehículo con lo escrito (marca/año siguen de solo lectura)',
                not bl2['tabla'] and not bl2['form'] and ed1 == ed0 and ro and 'Editar vehículo' in await pg.locator('#vehForm h3').inner_text(), {'antes': ed0['vfName'], 'despues': ed1.get('vfName'), 'solo_lectura': ro})
            # aislamiento: queda lo escrito guardado (bloqueado) → se cierra sesión → entra OTRO usuario en la misma computadora
            await pg.fill('#vfNotes', 'SECRETO DEL USUARIO A'); await pg.evaluate(revoke_all(ids['va'])); await pg.wait_for_timeout(5000)
            before = await pg.evaluate('()=>Object.keys(sessionStorage).filter(k=>k.startsWith("okd_veh_draft:"))')
            await pg.evaluate('()=>window.OKD_LOGOUT && window.OKD_LOGOUT()'); await pg.wait_for_timeout(2500)
            after = await pg.evaluate('()=>Object.keys(sessionStorage).filter(k=>k.startsWith("okd_veh_draft:"))')
            res('VB-06 al cerrar sesión se borra lo guardado de ese usuario', len(before) == 1 and after == [], {'antes': before, 'despues': after})
            await cr.login(pg, 'vehb.qa@example.invalid'); await pg.evaluate('()=>{location.hash="#/vehiculos"}'); await pg.wait_for_timeout(1800); await cr.dismiss(pg)
            iso = await pg.evaluate('()=>({form: !!document.getElementById("vehForm"), secreto: document.body.innerText.includes("SECRETO DEL USUARIO A")})')
            res('VB-07 OTRO usuario en la misma computadora no ve ningún formulario ni texto del anterior', iso == {'form': False, 'secreto': False}, iso)
            # aun si quedara un borrador de A en la pestaña (p. ej. cierre abrupto), B nunca lo lee: la clave es por usuario
            await pg.evaluate(f'''()=>sessionStorage.setItem("okd_veh_draft:{ids['va']}", JSON.stringify({{tab:"ACTIVOS", form:{{mode:"new", vid:null}}, vals:{{form:{{vfName:"SECRETO DEL USUARIO A"}}, km:{{}}, note:{{}}}}}}))''')
            await pg.evaluate('()=>{location.hash="#/"}'); await pg.wait_for_timeout(800); await pg.evaluate('()=>{location.hash="#/vehiculos"}'); await pg.wait_for_timeout(1800)
            iso2 = await pg.evaluate('()=>({form: !!document.getElementById("vehForm"), secreto: document.body.innerText.includes("SECRETO DEL USUARIO A") || [...document.querySelectorAll("input")].some(i=>i.value.includes("SECRETO"))})')
            res('VB-08 aunque quedara un borrador del usuario A en la pestaña, el usuario B no lo ve (clave por usuario)', iso2 == {'form': False, 'secreto': False}, iso2)
            res('VB-09 el usuario B conserva su acceso normal (ve la tabla y NUEVO VEHÍCULO)', await pg.evaluate('()=>!!document.getElementById("vehTable") && !!document.getElementById("vehNew")'), '')
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
