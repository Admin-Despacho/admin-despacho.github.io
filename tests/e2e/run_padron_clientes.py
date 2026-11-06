"""E2E (modo demo, Chromium) · V4.26 · PADRÓN DE CLIENTES: importación desde Configuración → J con un padrón SINTÉTICO (mismos casos borde que el
real), vista previa sin escribir, APLICAR en modo CONSERVAR, sin correos encolados, y sugerencia de correo en la entrega (DNI / nombre exacto).
Uso: python3 tests/e2e/run_padron_clientes.py [dist-demo] [salida]   ·   Exit 0 todo PASS · 1 alguna FAIL · 2 error."""
import asyncio, os, sys, json, traceback, openpyxl
sys.path.insert(0, os.path.dirname(__file__))
import run_driver_perfiles as dp
from playwright.async_api import async_playwright
dp.PORT = 4420; R = []; EXPECTED = 4
if len(sys.argv) > 1: dp.DIST = sys.argv[1]
OUT = sys.argv[2] if len(sys.argv) > 2 else '/tmp/okd_padron_out'
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:300])); print('..', ' | '.join(R[-1]), flush=True)
def synth(path):   # padrón SINTÉTICO (datos ficticios) con los casos borde del real
    wb = openpyxl.Workbook(); ws = wb.active; ws.title = 'Clientes'; ws.append(['Razón Social', 'Nombre', 'Tipo Doc.', 'Número', 'eMail'])
    for r in [['CLIENTE MANUAL SA', '', 'CUIT', '20123456786', 'otro@padron.test'],           # ya tiene correo MANUAL → se conserva
              ['5TA INFORMATICA SAS', 'NUÑEZ NORBERTO', 'CUIT', '30717780406', 'sac@5ta.test'],    # CUIT nuevo
              ['CUIT DIGITO DIEZ SA', '', 'CUIT', '30716111089', 'diez@padron.test'],            # dígito 10: inválido (AFIP) → por nombre
              ['ABEL CALLE', '', 'DNI', '42935147', 'abel@padron.test'],                         # DNI + nombre único
              ['Gómez Hnos S.A.', '', 'CUIT', '', 'gomez@padron.test'],                          # sin documento: nombre único
              ['PEREZ JUAN', '', 'DNI', '30111222', 'perez1@padron.test'], ['Pérez Juan', '', 'DNI', '30111223', 'perez2@padron.test'],   # nombre AMBIGUO
              ['DOBLE UNO', '', 'DNI', '28999888', 'uno@padron.test'], ['DOBLE DOS', '', 'DNI', '28999888', 'dos@padron.test'],          # DNI con 2 correos
              ['SIN CORREO SRL', '', 'CUIT', '30500010912', ''], ['CORREO MALO SRL', '', 'CUIT', '30500010912', 'no-es-correo'], ['', '', '', '', '']]:
        ws.append(r)
    wb.save(path)
async def main():
    os.makedirs(OUT, exist_ok=True); fx = os.path.join(OUT, 'padron_sintetico.xlsx'); synth(fx); srv = dp.serve()
    try:
        async with async_playwright() as p:
            b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
            try:
                ctx = await b.new_context(viewport={'width': 1366, 'height': 900}, accept_downloads=True); pg = await ctx.new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
                await pg.goto(f'http://127.0.0.1:{dp.PORT}/'); await pg.evaluate('()=>localStorage.clear()'); await dp.login(pg, 'admin@okdespacho.demo')
                await pg.evaluate("async()=>window.OKD_ONLINE.api.clientEmailUpsert('20123456786','CLIENTE MANUAL SA','manual@cliente.test')")   # uno de los correos actuales (MANUAL)
                await pg.evaluate('()=>{location.hash="#/configuracion?sec=emails_clientes"}'); await pg.wait_for_timeout(1500)
                if await pg.locator('[data-sec="emails_clientes"]').count(): await pg.locator('[data-sec="emails_clientes"]').first.click(); await pg.wait_for_timeout(800)
                jobs0 = await pg.evaluate('()=>(JSON.parse(localStorage.getItem("okd_online_demo_v2")).customerJobs||[]).length')
                await pg.set_input_files('#cpFile', fx); await pg.wait_for_selector('.cp-res', timeout=15000); prev = await pg.evaluate('()=>Object.fromEntries([...document.querySelectorAll(".cp-res tr")].map(t=>[t.cells[0].textContent.trim(), t.cells[1].textContent.trim()]))')
                db0 = await pg.evaluate('()=>{const d=JSON.parse(localStorage.getItem("okd_online_demo_v2")); return {al:d.clientEmailAliases||null, ce:Object.keys(d.clientEmails||{}).length}}')
                await pg.screenshot(path=os.path.join(OUT, 'padron_vista_previa.png'), full_page=False)
                res('PC-01 VISTA PREVIA: 11 clientes (la fila vacía no cuenta) · 2 por CUIT y 3 por DNI (los dos «Pérez Juan» tienen DNI propios; solo su NOMBRE es ambiguo) · 1 existente se CONSERVA · ambiguos y dudosos NO · y NO escribe nada',
                    prev.get('Clientes del padrón') == '11' and prev.get('Con correo válido / sin correo / correo inválido') == '9 / 1 / 1' and prev.get('Asociables por CUIT/CUIL · por DNI') == '2 · 3'
                    and prev.get('Ya existentes que se CONSERVAN sin cambios') == '1' and prev.get('Rechazadas por el servidor') == '0' and db0 == {'al': None, 'ce': 1}, prev)
                await pg.locator('#cpApply').click(); await pg.wait_for_timeout(1500)
                db = await pg.evaluate('()=>{const d=JSON.parse(localStorage.getItem("okd_online_demo_v2")); return {ce:d.clientEmails, al:d.clientEmailAliases, jobs:(d.customerJobs||[]).length}}')
                al = db['al'] or {'DNI': {}, 'NOMBRE': {}}
                res('PC-02 APLICAR (CONSERVAR): el correo MANUAL queda igual; se agregan CUIT, DNI y nombres únicos; NO se asocian el nombre ambiguo, el DNI con 2 correos ni el CUIT con dígito 10; NO se encola ningún correo',
                    db['ce']['20123456786']['email'] == 'manual@cliente.test' and db['ce'].get('30717780406', {}).get('email') == 'sac@5ta.test' and '30716111089' not in db['ce']
                    and al['DNI'].get('42935147', {}).get('email') == 'abel@padron.test' and al['NOMBRE'].get('GOMEZ HNOS S A', {}).get('email') == 'gomez@padron.test'
                    and al['NOMBRE'].get('CUIT DIGITO DIEZ SA', {}).get('email') == 'diez@padron.test' and 'PEREZ JUAN' not in al['NOMBRE'] and '28999888' not in al['DNI']
                    and 'DOBLE UNO' not in al['NOMBRE'] and db['jobs'] == jobs0, {'cuit': sorted(db['ce']), 'dni': sorted(al['DNI']), 'nombres': sorted(al['NOMBRE'])[:6], 'correos_encolados': db['jobs'] - jobs0})
                # PC-03: sugerencia durante la ENTREGA (chofer): DNI y nombre exacto desde el padrón; nombre ambiguo → nada
                rid = await pg.evaluate('''async()=>{const A=window.OKD_ONLINE.api; const st=(n,k,o)=>({ready:true, client_name:n, client_key:k, address:'Calle '+o, zone:'ESTE', stop_type:'PEDIDO', order_numbers:[String(o)], merchandise_amount:1000, shipping_fee:0, task:'ENTREGA', expected_amount:1000});
                  return (await A.publishRoute({sheet_key:'qa-padron-'+Date.now(), carrier_id:'CT-ESTE', responsable_id:'u-cristian', rules_version:1, routing_rules_version:1,
                    stops:[st('ABEL CALLE','42935147',97001), st('Gómez Hnos S.A.','GOMEZ HNOS S A',97002), st('PEREZ JUAN','PEREZ JUAN',97003)]})).id}''')
                state = await ctx.storage_state(); await ctx.close()
                c2 = await b.new_context(storage_state=state, viewport={'width': 412, 'height': 915}, is_mobile=True, geolocation={'latitude': -32.9, 'longitude': -68.8}, permissions=['geolocation'])
                q = await c2.new_page(); q.on('dialog', lambda d: asyncio.ensure_future(d.accept())); await dp.login(q, 'cristian@okdespacho.demo'); await dp.open_route(q, rid)
                sug = {}
                for i in range(3):
                    sid = await dp.stop_id(q, rid, i); await dp.choose(q, sid, 'ENTREGADO'); await q.wait_for_timeout(900)
                    sug[i] = await q.input_value(f'.drv-stop[data-s="{sid}"] [data-f="email"]')
                    await q.evaluate(f'()=>document.querySelector(\'.drv-stop[data-s="{sid}"] .drv-form\').hidden=true')
                await q.screenshot(path=os.path.join(OUT, 'padron_sugerencia_entrega.png')); await c2.close()
                res('PC-03 ENTREGA: el formulario del chofer trae el correo SUGERIDO del padrón por DNI (abel@) y por nombre exacto (gomez@); el nombre AMBIGUO no sugiere nada',
                    sug == {0: 'abel@padron.test', 1: 'gomez@padron.test', 2: ''}, sug)
                # PC-04: un NO Administrador General no importa (servidor de la demo; la sección J tampoco le aparece)
                c3 = await b.new_context(storage_state=state, viewport={'width': 1366, 'height': 900}); r = await c3.new_page(); await r.goto(f'http://127.0.0.1:{dp.PORT}/')
                await r.evaluate('''()=>{const k="okd_online_demo_v2", d=JSON.parse(localStorage.getItem(k)); const a=d.users.find(u=>u.role==="ADMIN");
                  if(!d.users.some(u=>u.id==="u-supq")) d.users.push(Object.assign({}, a, {id:"u-supq", email:"qa.supq@okdespacho.demo", role:"SUPERVISOR_DESPACHO", full_name:"QA Superior", carriers:[], extra_perms:["settings.manage"], denied_perms:[]}));
                  localStorage.setItem(k, JSON.stringify(d));}''')
                await r.evaluate('async()=>{try{await window.OKD_ONLINE.api.signOut()}catch(e){}}'); await dp.login(r, 'qa.supq@okdespacho.demo')
                api_err = await r.evaluate('async()=>{try{await window.OKD_ONLINE.api.clientPadronImport([{fila:1,tipo:"DNI",clave:"11222333",email:"x@y.test"}], true); return "PERMITIDO"}catch(e){return e.code||e.message}}')
                await r.evaluate('()=>{location.hash="#/configuracion?sec=emails_clientes"}'); await r.wait_for_timeout(1500); file_in = await r.locator('#cpFile').count(); await c3.close()
                res('PC-04 un Superior (aun con permiso de configuración) NO importa el padrón: la API lo rechaza y la pantalla no le muestra la importación', api_err != 'PERMITIDO' and file_in == 0, {'api': api_err, 'control_visible': file_in})
            finally: await b.close()
    finally: srv.terminate()
    print('TOTAL', sum(1 for r in R if r[1] == 'PASS'), 'PASS /', sum(1 for r in R if r[1] == 'FAIL'), 'FAIL · esperados', EXPECTED)
    return R
if __name__ == '__main__':
    try: rr = asyncio.run(main())
    except Exception as e: traceback.print_exc(); print('ERROR:', repr(e)); sys.exit(2)
    if len(rr) != EXPECTED: print('ERROR: se ejecutaron %d de %d' % (len(rr), EXPECTED)); sys.exit(2)
    sys.exit(1 if any(r[1] != 'PASS' for r in rr) else 0)
