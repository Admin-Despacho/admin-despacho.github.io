"""E2E (modo demo, Chromium) · la pantalla del chofer NO cierra ni borra un formulario abierto ("+ AGREGAR PARADA" o resultado de una parada)
cuando llega una actualización automática; y sin formulario abierto sigue actualizándose. Datos ficticios. Exit 0 PASS · 1 FAIL · 2 error."""
import asyncio, subprocess, sys, time, json, os
from playwright.async_api import async_playwright
DIST = sys.argv[1] if len(sys.argv) > 1 else 'dist-demo'; PORT = 4391; K = 'okd_online_demo_v2'
async def login(pg, email):
    await pg.goto(f'http://127.0.0.1:{PORT}/'); await pg.wait_for_timeout(800)
    await pg.fill('#loginEmail', email); await pg.fill('#loginPass', 'demo'); await pg.click('#loginBtn'); await pg.wait_for_timeout(2500)
    if await pg.locator('#pinA').count() and await pg.is_visible('#pinA'): await pg.fill('#pinA','123456'); await pg.fill('#pinB','123456'); await pg.click('#pinGo'); await pg.wait_for_timeout(900)
    await pg.wait_for_timeout(1500)
    for _ in range(3):
        if await pg.locator('#pushLater').count() and await pg.is_visible('#pushLater'): await pg.click('#pushLater'); await pg.wait_for_timeout(300)
R = []; EXPECTED = 4
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:220])); print('..', ' | '.join(R[-1]), flush=True)
PUBG = """async(n)=>{ const out=[]; for (let i=0;i<n;i++){ const r=await window.OKD_ONLINE.api.publishRoute({sheet_key:'ap-'+Date.now()+i, rules_version:1, routing_rules_version:1, carrier_id:'INTERNO', responsable_id:'u-gabriel', vehicle_id:'vh-1',
   stops:[{ready:true, stop_type:'UBICACION_INTERNA', internal_location_key:'SAN_JUAN', client_name:'Sucursal San Juan', address:'San Juan 500', order_numbers:[], task:'ENTREGA'}]}); out.push(r.id);} return out; }"""
async def main():
    srv = subprocess.Popen([sys.executable,'-m','http.server',str(PORT),'--bind','127.0.0.1'], cwd=DIST, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); time.sleep(1.2)
    try:
      async with async_playwright() as p:
        b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
        ctx = await b.new_context(viewport={'width':390,'height':844}, geolocation={'latitude':-32.89,'longitude':-68.84}, permissions=['geolocation']); pg = await ctx.new_page()
        pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
        await pg.goto(f'http://127.0.0.1:{PORT}/'); await pg.evaluate('()=>localStorage.clear()')
        await login(pg, 'admin@okdespacho.demo'); rid, rid2 = await pg.evaluate(PUBG, 2)
        await pg.evaluate('()=>window.OKD_LOGOUT && window.OKD_LOGOUT()'); await pg.wait_for_timeout(1200)
        await login(pg, 'gabriel@okdespacho.demo')
        await pg.click(f'[data-open="{rid}"]'); await pg.wait_for_timeout(800); await pg.fill('#drvKmIni', '50300'); await pg.click('#drvStart'); await pg.wait_for_timeout(1500)
        # (1) "+ AGREGAR PARADA" abierto con datos durante dos avisos automáticos (cada 5 s)
        await pg.click('#drvAddOpen'); await pg.fill('#naName', 'Banco Nación QA'); await pg.fill('#naIns', 'Depositar QA'); await pg.wait_for_timeout(11000)
        st = await pg.evaluate('()=>({abierto: !document.getElementById("drvAdd").hidden, nombre: document.getElementById("naName").value, instr: document.getElementById("naIns").value})')
        res('AP-01 "Agregar parada" sigue abierto y conserva lo escrito durante dos actualizaciones automáticas', st == {'abierto': True, 'nombre': 'Banco Nación QA', 'instr': 'Depositar QA'}, st)
        await pg.click('#naSave'); await pg.wait_for_timeout(2000)
        added = await pg.locator('.drv-stop', has_text='Banco Nación QA').count()
        res('AP-02 al tocar AGREGAR PARADA la parada se guarda y aparece en el recorrido', added == 1, added)
        # (2) formulario de resultado de una parada abierto durante una actualización automática
        sid = await pg.evaluate(f'()=>JSON.parse(localStorage.getItem("{K}")).routes2.find(r=>r.id==="{rid}").stops[0].id')
        if await pg.locator(f'.drv-stop[data-s="{sid}"] [data-arrive]').count(): await pg.locator(f'.drv-stop[data-s="{sid}"] [data-arrive]').click(); await pg.wait_for_timeout(1500)
        await pg.locator(f'.drv-stop[data-s="{sid}"] [data-o="ENTREGADO"]').click(); await pg.locator(f'.drv-stop[data-s="{sid}"] [data-f="recv"]').fill('Encargado QA'); await pg.wait_for_timeout(6500)
        f2 = await pg.evaluate(f'()=>{{const f=document.querySelector(\'.drv-stop[data-s="{sid}"] .drv-form\'); return {{abierto: !!f && !f.hidden, nombre: (f&&f.querySelector("[data-f=recv]")||{{}}).value||""}}}}')
        res('AP-03 el formulario de resultado de una parada también se mantiene con lo escrito', f2 == {'abierto': True, 'nombre': 'Encargado QA'}, f2)
        # (3) sin formulario abierto, la pantalla SÍ se actualiza sola: una hoja nueva asignada aparece sin recargar
        await pg.click('#drvBack'); await pg.wait_for_timeout(800)
        n0 = await pg.locator('[data-open]').count()
        await pg.evaluate(f"""()=>{{ const d=JSON.parse(localStorage.getItem("{K}")); const r=JSON.parse(JSON.stringify(d.routes2.find(x=>x.id==="{rid2}")));
            r.id='rt-ap-nueva'; r.number='03-999999'; r.sheet_key='ap-nueva'; d.routes2.push(r); localStorage.setItem("{K}", JSON.stringify(d)); }}""")
        await pg.wait_for_timeout(6500); n1 = await pg.locator('[data-open]').count()
        res('AP-04 sin formulario abierto la actualización automática sigue funcionando (aparece una hoja nueva sin recargar)', n1 == n0 + 1, {'antes': n0, 'despues': n1})
        await b.close()
    finally: srv.terminate()
    print('TOTAL', sum(1 for r in R if r[1] == 'PASS'), 'PASS /', sum(1 for r in R if r[1] == 'FAIL'), 'FAIL · esperados', EXPECTED)
    return R
if __name__ == '__main__':
    import traceback
    try: rr = asyncio.run(main())
    except Exception as e: traceback.print_exc(); print('ERROR:', repr(e)); sys.exit(2)
    if len(rr) != EXPECTED: print('ERROR: se ejecutaron %d de %d' % (len(rr), EXPECTED)); sys.exit(2)
    sys.exit(1 if any(r[1] != 'PASS' for r in rr) else 0)
