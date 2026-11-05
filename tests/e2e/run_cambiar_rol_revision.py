"""E2E (modo demo, Chromium) · revisión de "⇄ Cambiar rol": (1) no descartar trabajo del chofer sin advertir; (2) Solo Lectura con el permiso
consulta ubicaciones internas y agrega una visita a su hoja; (3) permiso quitado con la sesión abierta (sin acción y con cola sin conexión).
Usuarios SINTÉTICOS (Operario, Admin, Solo Lectura). Exit 0 todo PASS · 1 alguna FAIL · 2 error de preparación o casos faltantes."""
import asyncio, os, sys, traceback
sys.path.insert(0, os.path.dirname(__file__))
import run_cambiar_rol as cr
from playwright.async_api import async_playwright
cr.PORT = 4383; K = cr.K; R = []; EXPECTED = 11
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:260])); print('..', ' | '.join(R[-1]), flush=True)
# service_workers='block': esta prueba no evalúa el service worker (lo cubren run_actualizacion_pwa / run_recuperacion_pwa); así la recarga
# única de su primera instalación no se cruza con el ingreso ni con la preparación de datos.
FAST = 'window.OKD_REVOKE_CHECK_MS = 1500;'   # vigilante cada 1,5 s solo en la prueba (en la app: 30 s, foco, visibilidad, conexión)
class Dialogs:
    def __init__(self, pg):
        self.msgs = []; self.accept = True
        async def _h(d):   # un aviso puede quedar huérfano si la app navega en ese instante: se registra y se tolera
            self.msgs.append(d.message)
            try: await (d.accept() if self.accept else d.dismiss())
            except Exception as e: print('   aviso no atendido (la página ya navegó):', str(e)[:80], flush=True)
        pg.on('dialog', lambda d: asyncio.ensure_future(_h(d)))
async def open_ctx(b, kind, email):
    ctx = await b.new_context(**(cr.DESK if kind == 'desk' else cr.MOB), service_workers='block'); await ctx.add_init_script(FAST); pg = await ctx.new_page(); dl = Dialogs(pg)
    await pg.goto(f'http://127.0.0.1:{cr.PORT}/'); await pg.evaluate(f'(s)=>localStorage.setItem("{K}", s)', cr.DBSTATE[0]); await cr.login(pg, email); return ctx, pg, dl
async def to_transport(pg): await cr.choose(pg, 'TRANSPORTISTA')
async def start_route(pg, rid):
    await pg.locator(f'[data-open="{rid}"]').click(); await pg.wait_for_timeout(1000)
    km = await pg.evaluate(f'()=>{{const d=JSON.parse(localStorage.getItem("{K}")); return ((d.vehicles||[]).find(v=>v.id==="vh-1")||{{}}).current_km||50000}}')
    if await pg.locator('#drvKmIni').count(): await pg.fill('#drvKmIni', str(int(km) + 25)); await pg.click('#drvStart'); await pg.wait_for_timeout(1500)
async def save_state(pg): cr.DBSTATE[0] = await pg.evaluate(f'()=>localStorage.getItem("{K}")')
def revoke_js(uid): return f'()=>{{ const d=JSON.parse(localStorage.getItem("{K}")); const u=d.users.find(x=>x.id==="{uid}"); delete u.permission_overrides["routes.receive_internal"]; localStorage.setItem("{K}", JSON.stringify(d)); }}'
async def main():
    os.makedirs('/tmp/okd_rev', exist_ok=True); srv = cr.serve()
    try:
        async with async_playwright() as p:
          b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
          try:
            ctx = await b.new_context(**cr.DESK, service_workers='block'); pg = await ctx.new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
            await pg.goto(f'http://127.0.0.1:{cr.PORT}/'); await pg.evaluate('()=>localStorage.clear()'); await cr.login(pg, 'admin@okdespacho.demo')
            ids = None
            for intento in range(3):   # preparación de datos de prueba: si la sesión de la demo todavía no está lista, se reingresa (no cambia ninguna comprobación)
                await pg.wait_for_function('async()=>{try{return !!(await window.OKD_ONLINE.api.me())}catch(e){return false}}', timeout=15000, polling=300)
                try: ids = await pg.evaluate(cr.SETUP, cr.USERS); break
                except Exception as e:
                    if 'Sesión inválida' not in str(e) or intento == 2: raise
                    print('   preparación: sesión todavía no lista, reingreso', flush=True); await pg.wait_for_timeout(1500); await cr.login(pg, 'admin@okdespacho.demo')
            for k in ('op', 'ad', 'ro'): await pg.evaluate(f'async()=>window.OKD_ONLINE.api.setUserPermission("{ids[k]}", "routes.receive_internal", "GRANT", "prueba")')
            rt = {k: await pg.evaluate(cr.PUB, ids[k]) for k in ('op', 'ad', 'ro')}; await save_state(pg); await ctx.close()
            # ===== (1) Operario · COMPUTADORA: "+ AGREGAR PARADA" con datos → advertencia; CANCELAR conserva =====
            ctx, pg, dl = await open_ctx(b, 'desk', 'op.qa@example.invalid'); await to_transport(pg); await start_route(pg, rt['op']['id'])
            await pg.click('#drvAddOpen'); await pg.fill('#naName', 'Banco QA sin guardar')
            dl.accept = False; await pg.locator('[data-rolesw-box]:visible [data-rolesw]').first.click(); await pg.wait_for_timeout(300)
            await pg.locator('#roleswMenu [data-rolesw-go="PERFIL"]').click(); await pg.wait_for_timeout(1500)
            kept = await pg.evaluate('()=>({vista: !document.getElementById("noPanel").hidden, nombre: (document.getElementById("naName")||{}).value})')
            res('RV-01 COMPUTADORA · Operario: con "Agregar parada" sin guardar se ADVIERTE; al cancelar sigue en Mis rutas con lo escrito',
                any('una parada nueva sin agregar' in m for m in dl.msgs) and kept == {'vista': True, 'nombre': 'Banco QA sin guardar'}, {'avisos': dl.msgs[-1:], 'estado': kept})
            await pg.click('#naCancel') if await pg.locator('#naCancel').count() else await pg.evaluate('()=>{const f=document.getElementById("drvAdd"); f.querySelectorAll("input,textarea").forEach(i=>i.value=""); f.hidden=true;}')
            n_before = await pg.evaluate(f'()=>JSON.parse(localStorage.getItem("{K}")).routes2.length'); dl.msgs.clear(); dl.accept = True
            await cr.choose(pg, 'PERFIL'); back = await pg.evaluate('()=>!document.getElementById("operario").hidden')
            res('RV-02 sin nada pendiente cambia sin avisos y vuelve a su panel; no se publicó ninguna hoja al cambiar', back and not dl.msgs
                and await pg.evaluate(f'()=>JSON.parse(localStorage.getItem("{K}")).routes2.length') == n_before, {'panel': back, 'avisos': dl.msgs})
            await save_state(pg); await ctx.close()
            # ===== (1) Admin · CELULAR: entrega con nombre y FIRMA sin guardar → advertencia; cancelar conserva =====
            ctx, pg, dl = await open_ctx(b, 'mob', 'ad.qa@example.invalid'); await to_transport(pg); await start_route(pg, rt['ad']['id'])
            sid = await pg.evaluate(f'()=>JSON.parse(localStorage.getItem("{K}")).routes2.find(r=>r.id==="{rt["ad"]["id"]}").stops[0].id')
            if await pg.locator(f'.drv-stop[data-s="{sid}"] [data-arrive]').count(): await pg.locator(f'.drv-stop[data-s="{sid}"] [data-arrive]').click(); await pg.wait_for_timeout(1500)
            await pg.locator(f'.drv-stop[data-s="{sid}"] [data-o="ENTREGADO"]').click(); await pg.locator(f'.drv-stop[data-s="{sid}"] [data-f="recv"]').fill('Receptor QA'); await cr.sign(pg, sid)
            dl.accept = False; await pg.locator('[data-rolesw-box]:visible [data-rolesw]').first.click(); await pg.wait_for_timeout(300)
            await pg.locator('#roleswMenu [data-rolesw-go="PERFIL"]').click(); await pg.wait_for_timeout(1500)
            still = await pg.evaluate(f'()=>({{vista: !document.getElementById("noPanel").hidden, nombre: (document.querySelector(\'.drv-stop[data-s="{sid}"] [data-f="recv"]\')||{{}}).value}})')
            res('RV-03 CELULAR · Admin: entrega con nombre y firma sin guardar → advertencia (con firma); al cancelar se conserva', any('entrega sin guardar (con firma)' in m for m in dl.msgs)
                and still == {'vista': True, 'nombre': 'Receptor QA'}, {'avisos': dl.msgs[-1:], 'estado': still})
            await pg.locator(f'.drv-stop[data-s="{sid}"] [data-save]').click(); await pg.wait_for_timeout(1800)
            # ===== (3) Admin · revocación con la sesión ABIERTA y SIN ninguna acción =====
            dl.accept = True; dl.msgs.clear(); await pg.evaluate(revoke_js(ids['ad'])); await pg.wait_for_timeout(6000)
            idle = await pg.evaluate('()=>({noPanel: !document.getElementById("noPanel").hidden, selector: !!document.querySelector("[data-rolesw-box]")})')
            o_ad = await cr.outcome(pg, rt['ad']['id'])
            res('RV-04 Admin en Mis rutas: se QUITA el permiso y, sin tocar nada, la app lo detecta y vuelve a su perfil; lo registrado se conserva',
                any('Se quitó tu permiso' in m for m in dl.msgs) and not idle['noPanel'] and not idle['selector'] and o_ad == 'ENTREGADO', {'avisos': dl.msgs[-1:], 'estado': idle, 'registrado': o_ad})
            await save_state(pg); await ctx.close()
            # ===== (2) Solo Lectura · CELULAR: recorrido completo con segunda visita desde "+ AGREGAR PARADA" =====
            ctx, pg, dl = await open_ctx(b, 'mob', 'ro.qa@example.invalid'); await to_transport(pg); await start_route(pg, rt['ro']['id'])
            sid = await pg.evaluate(f'()=>JSON.parse(localStorage.getItem("{K}")).routes2.find(r=>r.id==="{rt["ro"]["id"]}").stops[0].id')
            if await pg.locator(f'.drv-stop[data-s="{sid}"] [data-arrive]').count(): await pg.locator(f'.drv-stop[data-s="{sid}"] [data-arrive]').click(); await pg.wait_for_timeout(1500)
            await pg.locator(f'.drv-stop[data-s="{sid}"] [data-o="ENTREGADO"]').click(); await pg.locator(f'.drv-stop[data-s="{sid}"] [data-f="recv"]').fill('Encargado QA'); await cr.sign(pg, sid)
            await pg.locator(f'.drv-stop[data-s="{sid}"] [data-save]').click(); await pg.wait_for_timeout(1800)
            await pg.click('#drvAddOpen'); await pg.click('[data-ntype="UBICACION_INTERNA"]'); await pg.wait_for_timeout(900)
            locs = await pg.eval_on_selector_all('#naLocList [data-lk]', 'e=>e.map(x=>x.dataset.lk)')
            if 'MONTECASEROS' in locs: await pg.click('#naLocList [data-lk="MONTECASEROS"]'); await pg.fill('#naIns', 'Segunda visita QA'); await pg.click('#naSave'); await pg.wait_for_timeout(1800)
            new = await pg.evaluate(f'()=>JSON.parse(localStorage.getItem("{K}")).routes2.find(r=>r.id==="{rt["ro"]["id"]}").stops.filter(s=>s.internal_location_key==="MONTECASEROS"&&s.provenance==="DRIVER").map(s=>s.id)')
            res('RV-05 CELULAR · Solo Lectura con el permiso VE las ubicaciones internas y agrega la segunda visita a Montecaseros', len(locs) > 0 and 'MONTECASEROS' in locs and len(new) == 1, {'ubicaciones': locs, 'agregada': new})
            if new:
                ns = new[0]
                if await pg.locator(f'.drv-stop[data-s="{ns}"] [data-arrive]').count(): await pg.locator(f'.drv-stop[data-s="{ns}"] [data-arrive]').click(); await pg.wait_for_timeout(1500)
                await pg.locator(f'.drv-stop[data-s="{ns}"] [data-o="ENTREGADO"]').click(); await pg.locator(f'.drv-stop[data-s="{ns}"] [data-f="recv"]').fill('Encargado Montecaseros'); await cr.sign(pg, ns)
                await pg.locator(f'.drv-stop[data-s="{ns}"] [data-save]').click(); await pg.wait_for_timeout(1800)
            fin = await pg.evaluate(f'()=>JSON.parse(localStorage.getItem("{K}")).routes2.find(r=>r.id==="{rt["ro"]["id"]}").stops.filter(s=>s.provenance!=="DRIVER" || s.internal_location_key==="MONTECASEROS").map(s=>s.outcome)')
            res('RV-06 y registra la recepción de la visita agregada (recorrido completo de Solo Lectura en su ruta)', fin.count('ENTREGADO') >= 2, fin)
            # ===== (3) Solo Lectura · sin conexión: entrega guardada en la cola + permiso quitado → al volver la conexión NO se borra =====
            pend = await pg.evaluate(f'()=>JSON.parse(localStorage.getItem("{K}")).routes2.find(r=>r.id==="{rt["ro"]["id"]}").stops.find(s=>s.outcome==="PENDIENTE")?.id || null')
            await ctx.set_offline(True); await pg.evaluate('()=>window.dispatchEvent(new Event("offline"))'); await pg.wait_for_timeout(400)
            if pend:
                if await pg.locator(f'.drv-stop[data-s="{pend}"] [data-arrive]').count(): await pg.locator(f'.drv-stop[data-s="{pend}"] [data-arrive]').click(); await pg.wait_for_timeout(1200)
                await pg.locator(f'.drv-stop[data-s="{pend}"] [data-o="ENTREGADO"]').click(); await pg.locator(f'.drv-stop[data-s="{pend}"] [data-f="recv"]').fill('Sin conexión QA'); await cr.sign(pg, pend)
                await pg.locator(f'.drv-stop[data-s="{pend}"] [data-save]').click(); await pg.wait_for_timeout(1500)
            q0 = await pg.evaluate(f'()=>JSON.parse(localStorage.getItem("okd_drv_queue:{ids["ro"]}")||"[]").length')
            # RV-07: el aviso de la app aparece MIENTRAS navega de vuelta al perfil; un diálogo nativo en ese instante desprende la página del
            # control de Playwright (Chromium nuevo; idéntico en la versión publicada). Solo en esta fase, los alert() se REGISTRAN sin diálogo.
            await ctx.add_init_script('if (sessionStorage.getItem("qa_stub_alert")) window.alert = m => { const a = JSON.parse(sessionStorage.getItem("qa_alerts") || "[]"); a.push(String(m)); sessionStorage.setItem("qa_alerts", JSON.stringify(a)); };')
            await pg.evaluate('()=>{ sessionStorage.setItem("qa_stub_alert", "1"); sessionStorage.removeItem("qa_alerts"); window.alert = m => { const a = JSON.parse(sessionStorage.getItem("qa_alerts") || "[]"); a.push(String(m)); sessionStorage.setItem("qa_alerts", JSON.stringify(a)); }; }')
            dl.msgs.clear(); await pg.evaluate(revoke_js(ids['ro']))
            await ctx.set_offline(False)
            try: await pg.evaluate('()=>window.dispatchEvent(new Event("online"))')   # la app puede volver al perfil (navegar) en ese mismo instante: es lo esperado
            except Exception as e:
                if 'Execution context was destroyed' not in str(e): raise
            print('   [RV-07] conexión restablecida', flush=True); await pg.wait_for_timeout(7000); print('   [RV-07] leyendo cola y servidor', flush=True)
            # al perder el permiso la app VUELVE al perfil (navegación esperada): se lee recién cuando la página terminó de cargar
            async def settled(js):
                for k in range(12):
                    try:
                        await pg.wait_for_load_state('load', timeout=8000); return await asyncio.wait_for(pg.evaluate(js), 8)
                    except Exception as e:
                        print('   lectura reintentada (navegación en curso):', type(e).__name__, str(e)[:70], flush=True)
                        if k == 1:   # DIAGNÓSTICO del estado de la página trabada
                            try:
                                cdp = await pg.context.new_cdp_session(pg)
                                h = await asyncio.wait_for(cdp.send('Page.getNavigationHistory'), 5); print('   DIAG historial:', [e['url'][-40:] for e in h['entries']][-4:], 'actual', h['currentIndex'], flush=True)
                                try: r = await asyncio.wait_for(cdp.send('Runtime.evaluate', {'expression': 'document.readyState + "|" + location.href + "|" + (document.body?document.body.innerText.slice(0,160):"")', 'returnByValue': True}), 5); print('   DIAG página:', str(r.get('result', {}).get('value'))[:260], flush=True)
                                except Exception as e2: print('   DIAG Runtime.evaluate:', type(e2).__name__, str(e2)[:80], flush=True)
                                try: d2 = await asyncio.wait_for(cdp.send('Page.handleJavaScriptDialog', {'accept': True}), 5); print('   DIAG aviso abierto: SÍ (aceptado)', flush=True)
                                except Exception as e3: print('   DIAG aviso abierto:', str(e3)[:80], flush=True)
                                try: await pg.screenshot(path='/tmp/diag_rv07.png', timeout=5000); print('   DIAG captura guardada', flush=True)
                                except Exception as e4: print('   DIAG captura:', type(e4).__name__, flush=True)
                            except Exception as e1: print('   DIAG CDP:', type(e1).__name__, str(e1)[:100], flush=True)
                        await pg.wait_for_timeout(700)
                raise RuntimeError('la página no terminó de navegar en ~3 minutos')
            q1 = await settled(f'()=>JSON.parse(localStorage.getItem("okd_drv_queue:{ids["ro"]}")||"[]").length')
            srv_out = await settled(f'()=>JSON.parse(localStorage.getItem("{K}")).routes2.find(r=>r.id==="{rt["ro"]["id"]}").stops.find(s=>s.id==="{pend}").outcome') if pend else None
            stub_alerts = await settled('()=>JSON.parse(sessionStorage.getItem("qa_alerts") || "[]")'); await pg.evaluate('()=>sessionStorage.removeItem("qa_stub_alert")')
            res('RV-07 sin conexión: la entrega guardada en la cola NO se envía (rechazo), NO se borra ni se marca enviada; vuelve al perfil avisando',
                pend and q0 >= 1 and q1 == q0 and srv_out == 'PENDIENTE' and any('SIN sincronizar' in m for m in dl.msgs + stub_alerts) and await pg.evaluate('()=>document.getElementById("noPanel").hidden === false ? !document.querySelector("[data-rolesw-box]") : true'),
                {'cola_antes': q0, 'cola_despues': q1, 'servidor': srv_out, 'avisos': (dl.msgs + stub_alerts)[-1:]})
            direct = await pg.evaluate(f'''async()=>{{ try {{ await window.OKD_ONLINE.api.setStopOutcome("{pend}", "ENTREGADO", null, null, "rv-"+Date.now(), {{evidence:{{receiver_name:"X", signature_png_b64:"iVBORw0KGgo="}}}}); return "aceptada"; }} catch(e) {{ return e.code; }} }}''') if pend else None
            res('RV-08 el servidor sigue rechazando la operación no autorizada (también llamada directa)', direct == 'FORBIDDEN', direct)
            await save_state(pg); await ctx.close()
            # ===== (3) Operario · COMPUTADORA en su PERFIL: permiso quitado → desaparece el selector SIN recargar ni perder trabajo =====
            ctx, pg, dl = await open_ctx(b, 'desk', 'op.qa@example.invalid')
            await pg.evaluate('()=>{ window.__sinRecargar = 1; RouteStore.sheetDate = "2099-11-30"; }'); had = await cr.visible_switch(pg)
            await pg.evaluate(revoke_js(ids['op'])); await pg.wait_for_timeout(5000)
            st = await pg.evaluate('()=>({marca: window.__sinRecargar, fecha: RouteStore.sheetDate, selector: !!document.querySelector("[data-rolesw-box]"), panel: !document.getElementById("operario").hidden})')
            res('RV-09 Operario en su panel: al quitarle el permiso desaparece el selector sin recargar ni perder trabajo, con aviso',
                had is not None and st == {'marca': 1, 'fecha': '2099-11-30', 'selector': False, 'panel': True} and any('Se quitó tu permiso' in m for m in dl.msgs), {'antes': had, 'despues': st})
            await pg.evaluate('()=>{location.hash="#/mis-rutas"}'); await pg.wait_for_timeout(1500)
            res('RV-10 y entrar por URL directa a #/mis-rutas ya no le da acceso', await pg.evaluate('()=>!!document.getElementById("b403") && document.getElementById("noPanel").hidden'), '')
            await ctx.close()
            # ===== Transportista interno actual: sin cambios =====
            ctx, pg, dl = await open_ctx(b, 'mob', 'gabriel@okdespacho.demo')
            res('RV-11 el Transportista Interno actual no ve selector ni avisos', await cr.visible_switch(pg) is None and not dl.msgs and await pg.locator('[data-open]').count() >= 0, dl.msgs)
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
