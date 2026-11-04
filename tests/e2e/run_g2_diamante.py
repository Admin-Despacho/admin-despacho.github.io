"""E2E (modo demo, Chromium, ANDROID emulado con GPS) · V4.23 · LLEGUÉ / TERMINÉ EN MONTECASEROS y SAN JUAN; LLEGUÉ A DIAMANTE → KM FINAL →
FINALIZAR HOJA (interno), con GPS fuera de radio y SIN CONEXIÓN; el externo no cambia. Datos ficticios.
Uso: python3 tests/e2e/run_g2_diamante.py [dist-demo]   ·   Exit 0 todo PASS · 1 alguna FAIL · 2 error."""
import asyncio, os, sys, traceback
sys.path.insert(0, os.path.dirname(__file__))
import run_driver_perfiles as dp
from playwright.async_api import async_playwright
dp.PORT = 4400; R = []; EXPECTED = 11
if len(sys.argv) > 1: dp.DIST = sys.argv[1]
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:260])); print('..', ' | '.join(R[-1]), flush=True)
MOB = dict(viewport={'width': 412, 'height': 915}, device_scale_factor=2.625, is_mobile=True, has_touch=False,
           geolocation={'latitude': -32.8900, 'longitude': -68.8400}, permissions=['geolocation'])
S = lambda sid, sel: f'.drv-stop[data-s="{sid}"] {sel}'
ROUTE = '''(rid)=>{const d=JSON.parse(localStorage.getItem("okd_online_demo_v2")); const r=(d.routes2||[]).find(x=>x.id===rid);
  return {status:r.operational_status, depot:r.depot_arrived_at||null, depotLoc:r.depot_location||null, km:r.km_end??null,
    stops:r.stops.map(s=>({id:s.id, type:s.stop_type, outcome:s.outcome, arrived:!!s.arrived_at, fin:s.location_finished_at||null, dep:s.location_departed_at||null, depLoc:s.location_departed_location||null})),
    vkm:((d.vehicles||[]).find(v=>v.id===r.vehicle_id)||{}).current_km}}'''
async def resolve_internal(pg, sid, outcome, sign_name):
    await dp.choose(pg, sid, outcome); await pg.wait_for_timeout(300)
    for sel, val in (('[data-f="recv"]', sign_name), ('[data-f="txt"]', 'faltó una caja / sucursal cerrada (QA)')):   # observación o motivo (campo real: txt)
        loc = pg.locator(S(sid, sel))
        if await loc.count() and await loc.first.is_visible():
            try: await loc.first.fill(val)
            except Exception: await loc.first.select_option(index=1)
    if await pg.locator(S(sid, '[data-sigopen]')).count() and await pg.locator(S(sid, '[data-sigopen]')).first.is_visible(): await dp.sign(pg, sid)
    return await dp.save(pg, sid)

async def main():
    srv = dp.serve()
    try:
        async with async_playwright() as p:
            b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
            try:
                adm = await (await b.new_context(viewport={'width': 1280, 'height': 900})).new_page()
                await adm.goto(f'http://127.0.0.1:{dp.PORT}/'); await adm.evaluate('()=>localStorage.clear()'); await dp.login(adm, 'admin@okdespacho.demo')
                ids = await adm.evaluate(dp.PUB); state = await adm.context.storage_state(); await adm.context.close()
                ctx = await b.new_context(storage_state=state, **MOB); pg = await ctx.new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
                await dp.login(pg, 'gabriel@okdespacho.demo'); await dp.open_route(pg, ids['gb'], km=50100)
                st = await pg.evaluate(ROUTE, ids['gb']); sc, sm, ss = st['stops'][0]['id'], st['stops'][1]['id'], st['stops'][2]['id']
                if await pg.locator(S(sc, '[data-arrive]')).count(): await pg.locator(S(sc, '[data-arrive]')).click(); await pg.wait_for_timeout(1200)
                await dp.choose(pg, sc, 'ENTREGADO'); await pg.fill(S(sc, '[data-f="recv"]'), 'Receptor QA'); await pg.fill(S(sc, '[data-f="cuil"]'), '20987654321')
                await pg.press(S(sc, '[data-f="cuil"]'), 'Tab'); await dp.sign(pg, sc); e0 = await dp.save(pg, sc)
                # ===== MONTECASEROS =====
                lbl_m = await pg.locator(S(sm, '[data-arrive]')).inner_text() if await pg.locator(S(sm, '[data-arrive]')).count() else None
                await pg.locator(S(sm, '[data-arrive]')).click(); await pg.wait_for_timeout(1300)
                fin_before = await pg.locator(S(sm, '[data-locfinish]')).count()
                res('GD-01 MONTECASEROS: el botón dice "LLEGUÉ A MONTECASEROS"; registra la llegada (GPS); TERMINÉ todavía NO aparece (falta resolver la recepción)',
                    e0 is None and lbl_m == 'LLEGUÉ A MONTECASEROS' and (await pg.evaluate(ROUTE, ids['gb']))['stops'][1]['arrived'] and fin_before == 0, {'boton': lbl_m, 'entrega': e0})
                e_m = await resolve_internal(pg, sm, 'ENTREGA_PARCIAL', 'Encargada QA Montecaseros')
                lbl_fin = await pg.locator(S(sm, '[data-locfinish]')).inner_text() if await pg.locator(S(sm, '[data-locfinish]')).count() else None
                dep_before = await pg.locator(S(sm, '[data-locdepart]')).count()   # SALÍ no aparece antes de TERMINÉ
                res('GD-02 RECEPCIÓN PARCIAL en Montecaseros (nombre + firma, sin CUIL ni email) y aparece "TERMINÉ EN MONTECASEROS"', e_m is None and lbl_fin == 'TERMINÉ EN MONTECASEROS', {'error': e_m, 'boton': lbl_fin})
                await pg.locator(S(sm, '[data-locfinish]')).click(); await pg.wait_for_timeout(1300)
                st = await pg.evaluate(ROUTE, ids['gb']); note = await pg.locator(S(sm, '.drv-note')).last.inner_text()
                res('GD-03 TERMINÉ EN MONTECASEROS registra hora y GPS; la recepción sigue PARCIAL y la hoja sigue EN CURSO (el chofer continúa)',
                    st['stops'][1]['fin'] and st['stops'][1]['outcome'] == 'ENTREGA_PARCIAL' and st['status'] == 'EN_CURSO' and 'Terminado en MONTECASEROS' in note, note)
                lbl_dep = await pg.locator(S(sm, '[data-locdepart]')).inner_text() if await pg.locator(S(sm, '[data-locdepart]')).count() else None
                await pg.locator(S(sm, '[data-locdepart]')).click(); await pg.wait_for_timeout(1300); st = await pg.evaluate(ROUTE, ids['gb'])
                notes = await pg.locator(S(sm, '.drv-note')).all_inner_texts()
                res('GD-10 SALÍ DE MONTECASEROS: NO aparece antes de TERMINÉ; después sí, y registra su PROPIA hora y GPS (distinta de TERMINÉ), sin cambiar la recepción ni cerrar la hoja',
                    dep_before == 0 and lbl_dep == 'SALÍ DE MONTECASEROS' and st['stops'][1]['dep'] and st['stops'][1]['depLoc'] and st['stops'][1]['dep'] != st['stops'][1]['fin']
                    and st['stops'][1]['outcome'] == 'ENTREGA_PARCIAL' and st['status'] == 'EN_CURSO' and any('Salida de MONTECASEROS' in n for n in notes), {'boton': lbl_dep, 'antes': dep_before, 'notas': notes})
                # ===== SAN JUAN =====
                lbl_s = await pg.locator(S(ss, '[data-arrive]')).inner_text() if await pg.locator(S(ss, '[data-arrive]')).count() else None
                await pg.locator(S(ss, '[data-arrive]')).click(); await pg.wait_for_timeout(1300)
                e_s = await resolve_internal(pg, ss, 'REPROGRAMAR', 'Encargado QA San Juan')
                res('GD-04 SAN JUAN: "LLEGUÉ A SAN JUAN" y REPROGRAMAR (se conserva la reprogramación)', lbl_s == 'LLEGUÉ A SAN JUAN' and e_s is None
                    and (await pg.evaluate(ROUTE, ids['gb']))['stops'][2]['outcome'] == 'REPROGRAMAR', {'boton': lbl_s, 'error': e_s})
                await pg.locator(S(ss, '[data-locfinish]')).click(); await pg.wait_for_timeout(1300); st = await pg.evaluate(ROUTE, ids['gb'])
                res('GD-05 "TERMINÉ EN SAN JUAN" registra el fin sin cambiar la reprogramación ni cerrar la hoja', st['stops'][2]['fin'] and st['stops'][2]['outcome'] == 'REPROGRAMAR' and st['status'] == 'EN_CURSO', st['stops'][2])
                await ctx.set_offline(True); await pg.locator(S(ss, '[data-locdepart]')).click(); await pg.wait_for_timeout(1200)
                off_note = ' '.join(await pg.locator(S(ss, '.drv-note')).all_inner_texts()); off_db = (await pg.evaluate(ROUTE, ids['gb']))['stops'][2]['dep']
                await ctx.set_offline(False); await pg.evaluate('()=>window.dispatchEvent(new Event("online"))'); await pg.wait_for_timeout(3500); on_db = (await pg.evaluate(ROUTE, ids['gb']))['stops'][2]
                res('GD-11 SALÍ DE SAN JUAN SIN CONEXIÓN: queda en el celular (pendiente) y al volver la conexión se sincroniza UNA vez; la reprogramación se conserva',
                    'Salida de SAN JUAN' in off_note and off_db is None and on_db['dep'] and on_db['outcome'] == 'REPROGRAMAR', {'antes': off_db, 'despues': on_db['dep']})
                # ===== DIAMANTE =====
                foot = {'depot': await pg.locator('#drvDepot').count(), 'fin': await pg.locator('#drvFin').count(), 'km': await pg.locator('#drvKm').count()}
                res('GD-06 sin LLEGUÉ A DIAMANTE no se puede finalizar: solo aparece "LLEGUÉ A DIAMANTE" (ni KM FINAL ni FINALIZAR HOJA)', foot == {'depot': 1, 'fin': 0, 'km': 0}, foot)
                await ctx.set_geolocation({'latitude': -32.9200, 'longitude': -68.8000})   # ~2,2 km del depósito (radio 150 m)
                await ctx.set_offline(True); await pg.locator('#drvDepot').click(); await pg.wait_for_timeout(1500)
                off_ui = await pg.locator('#drvDepotOk').inner_text() if await pg.locator('#drvDepotOk').count() else ''
                off_db = (await pg.evaluate(ROUTE, ids['gb']))['depot']
                await ctx.set_offline(False); await pg.evaluate('()=>window.dispatchEvent(new Event("online"))'); await pg.wait_for_timeout(4000)
                on = await pg.evaluate(ROUTE, ids['gb'])
                res('GD-07 LLEGUÉ A DIAMANTE SIN CONEXIÓN y FUERA DEL RADIO: se registra en el celular (pendiente, no informado como enviado) y al volver la conexión se sincroniza UNA vez con la advertencia',
                    'Llegada a Diamante' in off_ui and off_db is None and on['depot'] and on['depotLoc'] and (on['depotLoc'].get('outside_m') or 0) > 1000, {'pantalla': off_ui, 'antes': off_db, 'despues': on['depotLoc']})
                await pg.fill('#drvKm', '50050'); await pg.click('#drvFin'); await pg.wait_for_timeout(1500)
                low = await pg.evaluate('()=>[...document.querySelectorAll(".shiperr,.msg.err,.drv-err,.toast")].map(e=>e.textContent).join(" | ")')
                st_low = (await pg.evaluate(ROUTE, ids['gb']))['status']
                await pg.fill('#drvKm', '50300'); await pg.click('#drvFin'); await pg.wait_for_timeout(2000); fin = await pg.evaluate(ROUTE, ids['gb'])
                res('GD-08 KM FINAL menor al inicial NO finaliza; con KM válido FINALIZA y actualiza el km del vehículo', st_low == 'EN_CURSO' and fin['status'] == 'COMPLETADA' and fin['km'] == 50300 and fin['vkm'] == 50300, {'aviso': low[:120], 'final': fin['status'], 'km': fin['vkm']})
                await ctx.close()
                # ===== EXTERNO: sin cambios =====
                ctx = await b.new_context(storage_state=state, **MOB); pg = await ctx.new_page(); await dp.login(pg, 'cristian@okdespacho.demo'); await dp.open_route(pg, ids['ct'])
                ext = {'depot': await pg.locator('#drvDepot').count(), 'fin': await pg.locator('#drvFin').count(), 'locfin': await pg.locator('[data-locfinish]').count()}
                res('GD-09 TRANSPORTISTA EXTERNO sin cambios: FINALIZAR HOJA como siempre, sin Diamante ni TERMINÉ', ext == {'depot': 0, 'fin': 1, 'locfin': 0}, ext)
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
