"""E2E (modo demo, Chromium) · Contexto del formulario de vehículos: lo escrito al EDITAR un vehículo nunca pasa a otro vehículo ni a un alta; cambiar
de contexto con cambios pendientes avisa y permite cancelar; un refresco del mismo vehículo conserva lo escrito. Se verifica el CONTENIDO ENVIADO
a saveVehicle (no solo el texto visible). Datos FICTICIOS. Exit 0 PASS · 1 FAIL · 2 error."""
import asyncio, os, sys, traceback
sys.path.insert(0, os.path.dirname(__file__))
import run_cambiar_rol as cr
from playwright.async_api import async_playwright
cr.PORT = 4392; K = cr.K; R = []; EXPECTED = 8
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:260])); print('..', ' | '.join(R[-1]), flush=True)
U = [('vc', 'Operario Contexto QA', 'vctx.qa@example.invalid', 'OPERARIO_DEPOSITO')]
def db_js(body): return f'()=>{{ const d=JSON.parse(localStorage.getItem("{K}")); {body}; localStorage.setItem("{K}", JSON.stringify(d)); }}'
SPY = '()=>{ const A=window.OKD_ONLINE.api; if (A.__spy) return; A.__spy=1; window.__sent=[]; const o=A.saveVehicle.bind(A); A.saveVehicle=async p=>{ window.__sent.push(JSON.parse(JSON.stringify(p))); return o(p); }; }'
async def form(pg): return await pg.evaluate('()=>{ const f=document.getElementById("vehForm"); return f ? { ctx: f.dataset.ctx, v: Object.fromEntries([...f.querySelectorAll("input")].map(i=>[i.id, i.value])) } : null }')
async def sent(pg): return await pg.evaluate('()=>window.__sent.slice(-1)[0]||null')
async def edit(pg, vid): await pg.locator(f'tr[data-vid="{vid}"] [data-vedit]').click(); await pg.wait_for_timeout(900)
async def veh(pg, vid): return await pg.evaluate(f'()=>(JSON.parse(localStorage.getItem("{K}")).vehicles||[]).find(v=>v.id==="{vid}")')
async def main():
    srv = cr.serve()
    try:
        async with async_playwright() as p:
          b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
          try:
            ctx = await b.new_context(**cr.DESK); pg = await ctx.new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
            await pg.goto(f'http://127.0.0.1:{cr.PORT}/'); await pg.evaluate('()=>localStorage.clear()'); await cr.login(pg, 'admin@okdespacho.demo')
            ids = await pg.evaluate(cr.SETUP, U); uid = ids['vc']
            for x in ('vehicles.manage', 'vehicle_mileage.view', 'vehicle_mileage.enter', 'vehicle_mileage.resolve_alerts'): await pg.evaluate(f'async()=>window.OKD_ONLINE.api.setUserPermission("{uid}", "{x}", "GRANT", "prueba")')
            await pg.evaluate(db_js("d.vehicles.push({id:'vh-B', name:'Berlingo QA', plate:'QA101BB', active:true, notes:'notas propias de B', current_km:20000, last_service_km:20000, service_interval_km:15000}); "
                                    "d.mileageAlerts=(d.mileageAlerts||[]).concat([{id:'al-ctx', vehicle_id:'vh-1', plate:'AB123CD', kind:'LOWER_THAN_LAST', km_from:50000, km_to:49000, status:'OPEN', created_at:new Date().toISOString()}])"))
            state = await pg.evaluate(f'()=>localStorage.getItem("{K}")'); await ctx.close()
            ctx = await b.new_context(**cr.DESK); await ctx.add_init_script('window.OKD_REVOKE_CHECK_MS = 1500;'); pg = await ctx.new_page(); dlg = {'accept': True, 'msgs': []}
            pg.on('dialog', lambda d: (dlg['msgs'].append(d.message), asyncio.ensure_future(d.accept() if dlg['accept'] else d.dismiss())))
            await pg.goto(f'http://127.0.0.1:{cr.PORT}/'); await pg.evaluate(f'(s)=>localStorage.setItem("{K}", s)', state); await cr.login(pg, 'vctx.qa@example.invalid')
            await pg.evaluate('()=>{location.hash="#/vehiculos"}'); await pg.wait_for_timeout(1800); await cr.dismiss(pg); await pg.evaluate(SPY)
            a0 = await veh(pg, 'vh-1')
            # km y resolución escritos (deben quedar en SU fila durante todo el recorrido)
            await pg.fill('tr[data-vid="vh-B"] [data-km]', '20100'); await pg.fill('tr[data-aid="al-ctx"] [data-note]', 'Resolución por id QA')
            # EDITAR A → escribir → EDITAR B → CANCELAR el cambio
            await edit(pg, 'vh-1'); await pg.fill('#vfName', 'A EDITADO QA'); await pg.fill('#vfNotes', 'NOTA ESCRITA EN A')
            dlg['accept'] = False; dlg['msgs'].clear(); await edit(pg, 'vh-B'); f1 = await form(pg)
            res('CX-01 EDITAR A con cambios → EDITAR B: avisa; al CANCELAR sigue en A con lo escrito intacto', len(dlg['msgs']) == 1 and 'cambios sin guardar' in dlg['msgs'][0]
                and f1['ctx'] == 'edit:vh-1' and f1['v']['vfName'] == 'A EDITADO QA' and f1['v']['vfNotes'] == 'NOTA ESCRITA EN A', {'aviso': dlg['msgs'][-1:], 'form': f1})
            # aceptar el cambio → B muestra SUS datos y guarda SU id con SUS datos
            dlg['accept'] = True; await edit(pg, 'vh-B'); f2 = await form(pg)
            res('CX-02 al aceptar, EDITAR B muestra SUS propios datos (nada de A)', f2['ctx'] == 'edit:vh-B' and f2['v']['vfName'] == 'Berlingo QA' and f2['v']['vfPlate'] == 'QA101BB'
                and f2['v']['vfNotes'] == 'notas propias de B' and f2['v']['vfInterval'] == '15000', f2)
            await pg.click('#vfSave'); await pg.wait_for_timeout(1800); s2 = await sent(pg); a1 = await veh(pg, 'vh-1')
            res('CX-03 GUARDAR envía id=B con los datos de B (verificado en el contenido enviado) y A queda sin cambios', s2 and s2['id'] == 'vh-B' and s2['name'] == 'Berlingo QA'
                and s2['notes'] == 'notas propias de B' and s2['plate'] == 'QA101BB' and a1['name'] == a0['name'] and (a1.get('notes') or '') == (a0.get('notes') or ''), {'enviado': s2, 'A': [a1['name'], a1.get('notes')]})
            # EDITAR → NUEVO VEHÍCULO: el alta no hereda nada
            await edit(pg, 'vh-1'); await pg.fill('#vfName', 'NO DEBE PASAR AL ALTA'); await pg.fill('#vfNotes', 'TAMPOCO ESTO')
            dlg['msgs'].clear(); await pg.click('#vehNew'); await pg.wait_for_timeout(900); f3 = await form(pg)
            res('CX-04 EDITAR con cambios → NUEVO VEHÍCULO: avisa y el alta abre VACÍA (no hereda datos de la edición)', len(dlg['msgs']) == 1 and f3['ctx'] == 'new'
                and f3['v']['vfName'] == '' and f3['v']['vfNotes'] == '' and f3['v']['vfPlate'] == '' and f3['v']['vfInterval'] == '10000', {'aviso': dlg['msgs'][-1:], 'form': f3})
            await pg.fill('#vfName', 'Alta Contexto QA'); await pg.fill('#vfPlate', 'QA202CC'); await pg.click('#vfSave'); await pg.wait_for_timeout(1800); s3 = await sent(pg)
            res('CX-05 el alta envía SOLO sus datos (sin id ni datos de la edición)', s3 and 'id' not in s3 and s3['name'] == 'Alta Contexto QA' and s3['notes'] == '' and s3['plate'] == 'QA202CC', s3)
            # refresco del MISMO vehículo (cambio de permisos con la sesión abierta) → se conserva y se guarda con SU id
            await edit(pg, 'vh-B'); await pg.fill('#vfNotes', 'Nota B tras refresco QA')
            await pg.evaluate(db_js(f"const u=d.users.find(x=>x.id==='{uid}'); u.permission_overrides['reports.view']=true")); await pg.wait_for_timeout(5000); f4 = await form(pg)
            await pg.click('#vfSave'); await pg.wait_for_timeout(1800); s4 = await sent(pg)
            res('CX-06 un refresco del MISMO vehículo conserva lo escrito y GUARDAR envía id=B con eso', f4['ctx'] == 'edit:vh-B' and f4['v']['vfNotes'] == 'Nota B tras refresco QA'
                and s4['id'] == 'vh-B' and s4['notes'] == 'Nota B tras refresco QA', {'form': f4['v']['vfNotes'], 'enviado': s4})
            # sin cambios pendientes no hay aviso
            dlg['msgs'].clear(); await edit(pg, 'vh-1'); await edit(pg, 'vh-B'); f5 = await form(pg)
            res('CX-07 sin cambios pendientes se cambia de vehículo SIN aviso', not dlg['msgs'] and f5['ctx'] == 'edit:vh-B', dlg['msgs'])
            kn = await pg.evaluate('()=>({km: (document.querySelector(\'tr[data-vid="vh-B"] [data-km]\')||{}).value, nota: (document.querySelector(\'tr[data-aid="al-ctx"] [data-note]\')||{}).value})')
            res('CX-08 km y resolución siguen en SU fila (por identificador) durante todos los cambios de formulario', kn == {'km': '20100', 'nota': 'Resolución por id QA'}, kn)
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
