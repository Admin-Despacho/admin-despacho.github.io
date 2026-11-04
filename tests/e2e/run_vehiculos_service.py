"""E2E (modo demo, Chromium) · V4.22 · Service de vehículos: próximo = último service + intervalo DEL VEHÍCULO; faltan = próximo − km
actual; el intervalo NO es el kilometraje. Datos reales del caso (Kangoo II · AD629SA: km 231.390, último service 231.290) y ficticios.
Uso: python3 tests/e2e/run_vehiculos_service.py [dist-demo]   ·   Exit 0 todo PASS · 1 alguna FAIL · 2 error."""
import asyncio, os, sys, traceback
sys.path.insert(0, os.path.dirname(__file__))
import run_driver_perfiles as dp
from playwright.async_api import async_playwright
dp.PORT = 4399; R = []; EXPECTED = 7
if len(sys.argv) > 1: dp.DIST = sys.argv[1]
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:260])); print('..', ' | '.join(R[-1]), flush=True)
CARD = '''(plate)=>{const c=[...document.querySelectorAll('.vcard')].find(x=>x.textContent.includes(plate)); if(!c) return null;
  return {state:c.dataset.svcstate, next:(c.querySelector('[data-next]')||{}).textContent, left:(c.querySelector('[data-left]')||{}).textContent, txt:c.textContent}}'''
async def config_c(pg):
    await pg.evaluate('()=>{location.hash="#/configuracion"}'); await pg.wait_for_timeout(1600)
    await pg.locator('button', has_text='C. VEHÍCULOS').first.click(); await pg.wait_for_timeout(1200)

async def main():
    srv = dp.serve()
    try:
        async with async_playwright() as p:
            b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
            try:
                pg = await (await b.new_context(viewport={'width': 1366, 'height': 900})).new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
                await pg.goto(f'http://127.0.0.1:{dp.PORT}/'); await pg.evaluate('()=>{localStorage.clear(); sessionStorage.clear();}'); await dp.login(pg, 'admin@okdespacho.demo')
                # el caso real: intervalo guardado = kilometraje (231.390) por el campo sin rótulo
                await pg.evaluate('''async()=>{const A=window.OKD_ONLINE.api;
                  await A.saveVehicle({name:'Kangoo II', plate:'AD629SA', current_km:231390, last_service_km:231290, service_interval_km:231390});
                  await A.saveVehicle({name:'Furgón QA', plate:'QA111AA', current_km:10500, last_service_km:1000, service_interval_km:10000});
                  await A.saveVehicle({name:'Utilitario QA', plate:'QA222BB', current_km:52000, last_service_km:40000, service_interval_km:15000});
                  await A.saveVehicle({name:'Camioneta QA', plate:'QA333CC', current_km:12000, last_service_km:1000, service_interval_km:10000}); }''')
                await config_c(pg); k0 = await pg.evaluate(CARD, 'AD629SA')
                res('VS-01 Kangoo con el kilometraje cargado como intervalo (231.390): se DETECTA y pide corregirlo (ya no muestra 462.680 / faltan 231.290 como válido)',
                    k0 and k0['state'] == 'REVISAR' and 'REVISÁ EL INTERVALO' in k0['left'], k0 and {'estado': k0['state'], 'aviso': k0['left'][:90]})
                card = pg.locator('.vcard', has_text='AD629SA')
                await card.locator('[data-edit]').click(); await pg.wait_for_timeout(400)
                lbl = await card.locator('.vform').inner_text()
                await card.locator('[data-e="int"]').fill('231390'); await card.locator('[data-esave]').click(); await pg.wait_for_timeout(900)
                err = await pg.evaluate('()=>[...document.querySelectorAll(".up-msg.err, .msg.err, .err")].map(e=>e.textContent).join(" | ")')
                res('VS-02 EDITAR: el intervalo tiene RÓTULO ("cada cuántos km se hace") y NO acepta el kilometraje como intervalo', 'Intervalo de service (km)' in lbl and 'cada cuántos km' in lbl
                    and 'No es el kilometraje' in err, {'error': err[:150]})
                await config_c(pg); card = pg.locator('.vcard', has_text='AD629SA'); await card.locator('[data-edit]').click(); await pg.wait_for_timeout(400)
                await card.locator('[data-e="int"]').fill('10000'); await card.locator('[data-esave]').click(); await pg.wait_for_timeout(1300)
                await config_c(pg); k1 = await pg.evaluate(CARD, 'AD629SA')
                res('VS-03 Kangoo con intervalo 10.000: próximo service 241.290 y FALTAN 9.900 km (último 231.290, actual 231.390)',
                    k1['state'] == 'OK' and k1['next'].replace('.', '').startswith('241290') and '9.900' in k1['left'] and 'cada 10.000 km' in k1['txt'], {'proximo': k1['next'], 'faltan': k1['left']})
                u = await pg.evaluate(CARD, 'QA222BB')
                res('VS-04 cada vehículo usa SU intervalo (15.000): próximo 55.000, faltan 3.000', u['next'].replace('.', '').startswith('55000') and '3.000' in u['left'] and u['state'] == 'OK', u['next'])
                f, c = await pg.evaluate(CARD, 'QA111AA'), await pg.evaluate(CARD, 'QA333CC')
                res('VS-05 alertas visuales: faltan 500 (≤ "avisar cuando falten" 1.000) → PRÓXIMO; 1.000 km pasado → VENCIDO',
                    f['state'] == 'PROXIMO' and 'SERVICE PRÓXIMO' in f['left'] and '500' in f['left'] and c['state'] == 'VENCIDO' and 'VENCIDO hace 1.000' in c['left'], {'proximo': f['left'], 'vencido': c['left']})
                card = pg.locator('.vcard', has_text='AD629SA'); await card.locator('[data-svc]').click(); await pg.wait_for_timeout(400)
                await card.locator('[data-s="km"]').fill('231390'); await card.locator('[data-ssave]').click(); await pg.wait_for_timeout(1300)
                await config_c(pg); k2 = await pg.evaluate(CARD, 'AD629SA')
                hist = await pg.evaluate('()=>{const d=JSON.parse(localStorage.getItem("okd_online_demo_v2")||"{}"); const v=(d.vehicles||[]).find(x=>x.plate==="AD629SA"); return v?{last:v.last_service_km, iv:v.service_interval_km, cur:v.current_km}:null}')
                res('VS-06 REGISTRAR SERVICE en 231.390: el último service pasa a 231.390, próximo 241.390, faltan 10.000; el intervalo y el km no se tocan',
                    hist == {'last': 231390, 'iv': 10000, 'cur': 231390} and k2['next'].replace('.', '').startswith('241390') and '10.000' in k2['left'], {'datos': hist, 'proximo': k2['next']})
                await pg.evaluate('()=>{location.hash="#/vehiculos"}'); await pg.wait_for_timeout(1800)
                row = await pg.evaluate('()=>{const r=[...document.querySelectorAll("tr[data-vid]")].find(x=>x.textContent.includes("AD629SA")); return r?r.textContent:null}')
                row2 = await pg.evaluate('()=>{const r=[...document.querySelectorAll("tr[data-vid]")].find(x=>x.textContent.includes("QA333CC")); return r?r.textContent:null}')
                res('VS-07 la pantalla VEHÍCULOS usa el MISMO cálculo (próximo 241.390 · faltan 10.000 · cada 10.000; el vencido figura como Service vencido)',
                    row and '241.390' in row and 'faltan 10.000' in row and 'cada 10.000' in row and row2 and 'Service vencido' in row2, (row or '')[:160])
            finally: await b.close()
    finally: srv.terminate()
    print('TOTAL', sum(1 for r in R if r[1] == 'PASS'), 'PASS /', sum(1 for r in R if r[1] == 'FAIL'), 'FAIL · esperados', EXPECTED)
    return R

if __name__ == '__main__':
    try: rr = asyncio.run(main())
    except Exception as e: traceback.print_exc(); print('ERROR:', repr(e)); sys.exit(2)
    if len(rr) != EXPECTED: print('ERROR: se ejecutaron %d de %d' % (len(rr), EXPECTED)); sys.exit(2)
    sys.exit(1 if any(r[1] != 'PASS' for r in rr) else 0)
