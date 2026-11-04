"""E2E (modo demo, Chromium) · V4.23 · Configuración → J. EMAILS DE CLIENTES (padrón por CUIT validado) + integración con las entregas.
Archivos XLSX REALES generados con openpyxl. Datos FICTICIOS. Uso: python3 tests/e2e/run_emails_clientes.py [dist-demo]
Exit 0 todo PASS · 1 alguna FAIL · 2 error."""
import asyncio, os, sys, traceback, tempfile
sys.path.insert(0, os.path.dirname(__file__))
import run_driver_perfiles as dp
from playwright.async_api import async_playwright
from openpyxl import Workbook, load_workbook
dp.PORT = 4401; R = []; EXPECTED = 11
if len(sys.argv) > 1: dp.DIST = sys.argv[1]
TMP = tempfile.mkdtemp(prefix='okd_ce_')
MOB = dict(viewport={'width': 412, 'height': 915}, device_scale_factor=2.625, is_mobile=True, geolocation={'latitude': -32.89, 'longitude': -68.84}, permissions=['geolocation'])
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:260])); print('..', ' | '.join(R[-1]), flush=True)
def xlsx(name, rows, head=('CUIT', 'Nombre o razón social', 'Email')):
    wb = Workbook(); ws = wb.active
    if head: ws.append(list(head))
    for r in rows: ws.append(list(r))
    p = os.path.join(TMP, name); wb.save(p); return p
# CUIT válidos (dígito verificador) conocidos = figuran en la hoja publicada abajo; 27555555550 válido pero desconocido; 20123456781 inválido
PUB = '''async()=>{const A=window.OKD_ONLINE.api; const base={rules_version:1, routing_rules_version:1};
  const mk=(n,key,email)=>({ready:true, client_name:'CLIENTE CE '+n, client_key:key, customer_email:email, address:'Calle '+n+', Mendoza', zone:'ESTE', order_numbers:[String(n)], merchandise_amount:1000, shipping_fee:0, task:'ENTREGA', stop_type:'PEDIDO'});
  const r = await A.publishRoute(Object.assign({sheet_key:'qa-ce-'+Date.now(), carrier_id:'INTERNO', responsable_id:'u-gabriel', vehicle_id:'vh-1',
    stops:[mk(91001,'20333333334',null), mk(91002,'20444444445','hoja@cliente.test'), mk(91003,'20111111112',null), mk(91004,'20222222223',null), mk(91005,'20123456786',null)]}, base));
  return r.id; }'''
DB = '''()=>{const d=JSON.parse(localStorage.getItem("okd_online_demo_v2")||"{}"); return {padron:d.clientEmails||{}, imports:(d.clientEmailImports||[]).length}}'''
async def cfg_j(pg):
    await pg.evaluate('()=>{location.hash="#/configuracion"}'); await pg.wait_for_timeout(1500)
    b = pg.locator('[data-sec="emails_clientes"]')
    if await b.count(): await b.click(); await pg.wait_for_timeout(1000)
    return await b.count()
async def upload(pg, path):
    await pg.set_input_files('#ceFile', path); await pg.wait_for_timeout(1500)
    return await pg.evaluate('''()=>({err:(document.getElementById("ceErr")||{}).textContent||null, est:[...document.querySelectorAll("#cePrevT tbody tr")].map(t=>t.dataset.est),
      txt:(document.getElementById("cePrev")||{}).textContent||""})''')

async def main():
    srv = dp.serve()
    try:
        async with async_playwright() as p:
            b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
            try:
                ctx = await b.new_context(viewport={'width': 1366, 'height': 900}, accept_downloads=True); pg = await ctx.new_page()
                await pg.goto(f'http://127.0.0.1:{dp.PORT}/'); await pg.evaluate('()=>{localStorage.clear(); sessionStorage.clear();}'); await dp.login(pg, 'admin@okdespacho.demo')
                rid = await pg.evaluate(PUB); state = await ctx.storage_state()
                ok_admin = await cfg_j(pg)
                # ===== permisos =====
                c2 = await b.new_context(storage_state=state, viewport={'width': 1366, 'height': 900}); p2 = await c2.new_page(); await p2.goto(f'http://127.0.0.1:{dp.PORT}/'); await p2.wait_for_timeout(1500)
                users = await p2.evaluate('()=>JSON.parse(localStorage.getItem("okd_online_demo_v2")).users.map(u=>({e:u.email, r:u.role}))')
                sup = next((u['e'] for u in users if u['r'] in ('SUPERVISOR_DESPACHO', 'SUPERVISOR')), None)
                seen_sup = None
                if sup: await dp.login(p2, sup); seen_sup = await cfg_j(p2)
                await dp.login(p2, 'gabriel@okdespacho.demo')
                drv = await p2.evaluate('async()=>{try{await window.OKD_ONLINE.api.clientEmailsList(""); return "VE"}catch(e){return e.code||e.message}}')
                await c2.close()
                res('EC-01 PERMISOS: el Administrador General ve "J. EMAILS DE CLIENTES" y el transportista NO puede leer el padrón' + (' ni el supervisor verla' if sup else ' (la demo no tiene supervisor: ese rol se prueba en SQL)'), ok_admin == 1 and (sup is None or seen_sup == 0) and drv == 'FORBIDDEN',
                    {'admin': ok_admin, 'supervisor': (sup, seen_sup), 'chofer': drv})
                # ===== plantilla =====
                async with pg.expect_download() as dl: await pg.click('#ceTpl')
                d = await dl.value; tp = os.path.join(TMP, d.suggested_filename); await d.save_as(tp)
                head = [c.value for c in load_workbook(tp).active[1]]
                res('EC-02 DESCARGAR PLANTILLA EXCEL: .xlsx con CUIT · Nombre o razón social · Email', d.suggested_filename.endswith('.xlsx') and head == ['CUIT', 'Nombre o razón social', 'Email'], {'archivo': d.suggested_filename, 'columnas': head})
                # ===== archivos con problemas =====
                r_empty = await upload(pg, xlsx('vacio.xlsx', []))
                res('EC-03 archivo VACÍO (solo encabezados) → "no tiene filas" y no guarda nada', r_empty['err'] and 'no tiene filas' in r_empty['err'], r_empty['err'])
                await cfg_j(pg); r_cols = await upload(pg, xlsx('sin_email.xlsx', [('20333333334', 'X')], head=('CUIT', 'Nombre')))
                res('EC-04 COLUMNAS FALTANTES (sin Email) → avisa qué falta', r_cols['err'] and 'Faltan columnas obligatorias: Email' in r_cols['err'], r_cols['err'])
                # ===== vista previa =====
                await pg.evaluate('()=>window.OKD_ONLINE.api.clientEmailUpsert("20123456786","Cliente Existente SA","pagos@existente.test")')
                await pg.evaluate('()=>window.OKD_ONLINE.api.clientEmailUpsert("20222222223","Cliente Conservar","viejo@conservar.test")')
                good = xlsx('emails.xlsx', [('20-12345678-6', 'Cliente Existente SA', 'nuevo@existente.test'), ('20123456781', 'CUIT mal', 'a@b.test'), ('27555555550', 'Desconocido', 'x@y.test'),
                    ('20111111112', 'Duplicado', 'd1@d.test'), ('20111111112', 'Duplicado', 'd2@d.test'), ('20444444445', 'Email malo', 'no-es-email'),
                    ('20333333334', 'Nuevo SA', 'compras@nuevo.test'), ('20222222223', 'Cliente Conservar', '')])
                await cfg_j(pg); before = (await pg.evaluate(DB))['padron']; pv = await upload(pg, good); after_pv = (await pg.evaluate(DB))['padron']
                res('EC-05 VISTA PREVIA sin guardar: A actualizar · CUIT inválido (dígito verificador) · no identificado · duplicado ×2 · email inválido · nuevo · sin email (no borra)',
                    pv['est'] == ['ACTUALIZAR', 'CUIT_INVALIDO', 'DESCONOCIDO', 'DUPLICADO', 'DUPLICADO', 'EMAIL_INVALIDO', 'NUEVO', 'SIN_EMAIL'] and before == after_pv and 'Total de filas: 8' in pv['txt'], pv['est'])
                await pg.click('#ceApply'); await pg.wait_for_timeout(1500); db1 = await pg.evaluate(DB)
                pdn = db1['padron']
                res('EC-06 CONSERVAR: agrega SOLO el nuevo; el existente no cambia; la celda vacía NO borra; no se crean desconocidos ni inválidos; queda registrada la importación',
                    pdn.get('20333333334', {}).get('email') == 'compras@nuevo.test' and pdn['20123456786']['email'] == 'pagos@existente.test' and pdn['20222222223']['email'] == 'viejo@conservar.test'
                    and set(pdn) == {'20123456786', '20222222223', '20333333334'} and db1['imports'] == 1, sorted(pdn))
                await cfg_j(pg); await upload(pg, good); await pg.check('[name="ceMode"][value="REEMPLAZAR"]'); await pg.click('#ceApply'); await pg.wait_for_timeout(1500); db2 = (await pg.evaluate(DB))['padron']
                res('EC-07 REEMPLAZAR: el existente pasa al email del Excel; la celda vacía sigue sin borrar', db2['20123456786']['email'] == 'nuevo@existente.test' and db2['20222222223']['email'] == 'viejo@conservar.test', db2['20123456786']['email'])
                # ===== edición manual =====
                await cfg_j(pg); await pg.fill('#ceQ', 'Nuevo SA'); await pg.click('#ceGo'); await pg.wait_for_timeout(700)
                found = await pg.locator('#ceT tbody tr[data-cuit]').count(); await pg.locator('#ceT [data-ceedit]').first.click()
                pre = await pg.input_value('#ceCuit'); await pg.fill('#ceMail', 'pagos@nuevo.test'); await pg.click('#ceSave'); await pg.wait_for_timeout(1200)
                await cfg_j(pg); await pg.fill('#ceCuit', '20123456781'); await pg.fill('#ceMail', 'a@b.test'); await pg.click('#ceSave'); await pg.wait_for_timeout(900)
                bad = await pg.evaluate('()=>[...document.querySelectorAll(".up-msg.err, .err")].map(e=>e.textContent).join(" | ")')
                db3 = (await pg.evaluate(DB))['padron']
                res('EC-08 EDICIÓN MANUAL: buscar por nombre → EDITAR → GUARDAR (con fecha de actualización); un CUIT inválido se rechaza',
                    found == 1 and pre == '20333333334' and db3['20333333334']['email'] == 'pagos@nuevo.test' and db3['20333333334']['source'] == 'MANUAL' and db3['20333333334'].get('updated_at') and 'CUIT' in bad, {'error': bad[:80]})
                state = await ctx.storage_state(); await ctx.close()   # la demo guarda por navegador: el chofer parte del estado con el padrón cargado
                # ===== entregas (Transportista Interno) =====
                ctx = await b.new_context(storage_state=state, **MOB); pg = await ctx.new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
                await dp.login(pg, 'gabriel@okdespacho.demo'); await dp.open_route(pg, rid, km=50100)
                sids = [await dp.stop_id(pg, rid, i) for i in range(5)]
                async def open_ent(sid):
                    if await pg.locator(f'.drv-stop[data-s="{sid}"] [data-arrive]').count(): await pg.locator(f'.drv-stop[data-s="{sid}"] [data-arrive]').click(); await pg.wait_for_timeout(1100)
                    await dp.choose(pg, sid, 'ENTREGADO'); await pg.wait_for_timeout(900)
                    return await pg.input_value(f'.drv-stop[data-s="{sid}"] [data-f="email"]')
                e1 = await open_ent(sids[0])
                await pg.fill(f'.drv-stop[data-s="{sids[0]}"] [data-f="recv"]', 'Receptor CE'); await pg.fill(f'.drv-stop[data-s="{sids[0]}"] [data-f="cuil"]', '20333333334')
                await pg.fill(f'.drv-stop[data-s="{sids[0]}"] [data-f="email"]', 'otro@escrito.test'); await dp.sign(pg, sids[0])
                await pg.locator(f'.drv-stop[data-s="{sids[0]}"] [data-save]').dblclick(); await pg.wait_for_timeout(2200)
                e2 = await open_ent(sids[1])
                res('EC-09 PRECARGA en la entrega: si la hoja no trae email se sugiere el del PADRÓN (por CUIT); si la hoja trae uno, manda ese', e1 == 'pagos@nuevo.test' and e2 == 'hoja@cliente.test', {'padron': e1, 'hoja': e2})
                st = await pg.evaluate('''(sid)=>{const d=JSON.parse(localStorage.getItem("okd_online_demo_v2")); const ev=(d.evidence||{})[sid]||{};
                  return {mail:ev.email||ev.receiver_email||null, jobs:(d.customerJobs||[]).filter(j=>j.stop_id===sid&&j.kind==="RECIBIDO_CONFORME").length, padron:(d.clientEmails||{})["20333333334"].email}}''', sids[0])
                res('EC-10 el chofer ESCRIBE otro email: se usa en ESA entrega, UN solo Recibido Conforme (doble toque en GUARDAR) y el PADRÓN NO cambia',
                    st['mail'] == 'otro@escrito.test' and st['jobs'] == 1 and st['padron'] == 'pagos@nuevo.test', st)
                await pg.fill(f'.drv-stop[data-s="{sids[1]}"] [data-f="recv"]', 'Receptor Sin Mail'); await pg.fill(f'.drv-stop[data-s="{sids[1]}"] [data-f="cuil"]', '20444444445')
                await pg.fill(f'.drv-stop[data-s="{sids[1]}"] [data-f="email"]', ''); await dp.sign(pg, sids[1]); e_save = await dp.save(pg, sids[1])
                st2 = await pg.evaluate('''(sid)=>{const d=JSON.parse(localStorage.getItem("okd_online_demo_v2")); const r=d.routes2.find(x=>x.stops.some(s=>s.id===sid));
                  return {out:r.stops.find(s=>s.id===sid).outcome, jobs:(d.customerJobs||[]).filter(j=>j.stop_id===sid&&j.kind==="RECIBIDO_CONFORME").length,
                    otros:(d.customerJobs||[]).filter(j=>j.stop_id===sid&&j.kind!=="RECIBIDO_CONFORME").map(j=>j.kind+"→"+(j.recipient||j.to||""))}}''', sids[1])
                res('EC-11 el chofer BORRA el email sugerido: la entrega se confirma igual y NO se genera Recibido Conforme (los avisos al email del cliente cargado en la hoja siguen la regla existente)',
                    e_save is None and st2['out'] == 'ENTREGADO' and st2['jobs'] == 0, {'error': e_save, 'estado': st2})
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
