"""E2E BLOQUEANTE (demo + Constructor REAL) · AUTORIZACIONES COMERCIALES · «CONSULTAR APROBACIÓN»: el Comercial crea solicitudes para pedidos de
una hoja (una PENDIENTE y una DEVUELTA); al publicar, el Operario ve «CONSULTAR APROBACIÓN» con ambas, SIN bloqueo ni cambio de importes; un usuario
sin permisos del módulo no ve nada. Informes SINTÉTICOS (generate_synthetic_saldo_noc.py)."""
import asyncio, os, sys, subprocess, traceback
sys.path.insert(0, os.path.dirname(__file__))
import run_saldo_revisar_noc as base
import run_driver_perfiles as dp
from playwright.async_api import async_playwright
R = []; EXPECTED = 6
DIST = sys.argv[1] if len(sys.argv) > 1 else os.path.join(base.ROOT, 'dist-demo'); dp.DIST = DIST; dp.PORT = base.PORT = 4381
OUT = sys.argv[2] if len(sys.argv) > 2 else '/tmp/okd_com_ca'
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:340])); print('..', ' | '.join(R[-1]), flush=True)
BOX = '()=>{const e=document.getElementById("pubCom"); return e?e.innerText.replace(/\\s+/g," "):null}'
async def relog(pg, email):
    await pg.evaluate('async()=>{try{await window.OKD_ONLINE.api.signOut()}catch(e){}}'); await pg.goto(f'http://127.0.0.1:{dp.PORT}/'); await base.login(pg, email); await pg.wait_for_timeout(1200)
async def main():
    os.makedirs(OUT, exist_ok=True)
    if not all(os.path.isfile(os.path.join(base.FIX, f)) for f in base.FILES): subprocess.run(['python3', os.path.join(os.path.dirname(__file__), 'generate_synthetic_saldo_noc.py'), base.FIX], check=True)
    srv = dp.serve()
    try:
        async with async_playwright() as p:
            b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
            try:
                pg = await (await b.new_context(viewport={'width': 1366, 'height': 900})).new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
                await pg.goto(f'http://127.0.0.1:{dp.PORT}/'); await pg.evaluate('()=>localStorage.clear()')
                await base.login(pg, 'comercial.montecaseros@okdespacho.demo'); await pg.wait_for_timeout(1500)
                mk = await pg.evaluate('''async()=>{const A=window.OKD_ONLINE.api; const a=await A.comCreate("FINANCIACION","cli-101","72003",{amount:500000,installments:2},null,"ca-1");
                  const b=await A.comCreate("FINANCIACION","cli-106","72001",{amount:300000,installments:2},null,"ca-2"); return [a.number,b.number]}''')
                await relog(pg, 'wilfredo@okdespacho.demo')
                dv = await pg.evaluate('''async(n)=>{const A=window.OKD_ONLINE.api; const L=await A.comList("BANDEJA"); const q=L.find(x=>x.number===n);
                  const r=await A.comDecide(q.id, q.version, "DEVOLVER", {amount:250000, installments:2}, "Bajar el importe"); return r.status}''', mk[1])
                await relog(pg, 'admin@okdespacho.demo'); await base.builder(pg)
                await pg.fill('#ids', '72001 72002 72003 72004'); await pg.click('#btnSearch'); await pg.wait_for_timeout(2500)
                await base.type_amount(pg, '72001', '1500'); await base.type_amount(pg, '72002', '2000'); await pg.evaluate('async()=>{ await RouteStore.flush(); }')
                montos0 = await pg.evaluate('()=>RouteStore.rows.map(r=>[String(r.mainOrder), r.monto])')
                await base.open_publish(pg); await pg.wait_for_timeout(2500)
                box = await pg.evaluate(BOX); montos1 = await pg.evaluate('()=>RouteStore.rows.map(r=>[String(r.mainOrder), r.monto])')
                await pg.locator('#pubCom').scroll_into_view_if_needed(); await pg.screenshot(path=os.path.join(OUT, 'consultar_aprobacion_publicacion.png'))
                res('CA-E1 al PUBLICAR, la sección REVISAR muestra «CONSULTAR APROBACIÓN» con la solicitud PENDIENTE y la DEVUELTA de los pedidos de la hoja (DEVUELTA nunca como aprobada)',
                    dv == 'DEVUELTA' and box and 'CONSULTAR APROBACIÓN' in box and mk[0] in box and mk[1] in box and 'PENDIENTE DE APROBACIÓN' in box and 'DEVUELTA A COMERCIAL (NO es aprobación)' in box, {'recuadro': box, 'solicitudes': mk})
                res('CA-E2 el recuadro es INFORMATIVO: no cambia ningún importe de la hoja', montos0 == montos1, {'antes': montos0, 'despues': montos1})
                for _ in range(12):
                    cur = await base.pend(pg)
                    if cur['n'] == 0: break
                    cb = pg.locator('#pubPend [data-pack]:not(:checked)').first
                    if await cb.count(): await cb.click(); await pg.wait_for_timeout(2300); continue
                    pay = pg.locator('#pubPend .pendrow', has=pg.locator('[data-ppay]')).first
                    if await pay.count():
                        await pay.locator('[data-ppay]').fill('EFECTIVO')
                        if await pay.locator('[data-ppayship]').count(): await pay.locator('[data-ppayship]').fill('EFECTIVO')
                        await pay.locator('[data-psavepay]').click(); await pg.wait_for_timeout(2300); continue
                    break
                sid = await pg.evaluate('()=>RouteStore.sheetId'); await pg.click('#pubGo'); await pg.wait_for_timeout(5000)
                pub = await pg.evaluate(f'()=>(JSON.parse(localStorage.getItem("okd_online_demo_v2")).routes2||[]).filter(x=>x.sheet_key==="{sid}").length')
                res('CA-E3 NO BLOQUEA: la hoja se publica normalmente con las solicitudes en curso', pub == 1, {'hojas_publicadas': pub})
                # O-01: sin conexión, el recuadro AVISA que no se pudo verificar (el silencio no significa «sin solicitudes»)
                off = await pg.evaluate('''async()=>{window.OKD_NET={offline:true}; const m=document.createElement("div"); m.innerHTML='<div id="pubCom"></div>'; document.body.appendChild(m);
                  await ComAlerts.fill(m, [{mainOrder:"72003", calc:{cuit:"30500010912"}}]); const t=m.innerText.replace(/\\s+/g," "); m.remove(); window.OKD_NET={offline:false}; return t}''')
                res('CA-E5 (O-01) SIN CONEXIÓN: el recuadro avisa «NO SE PUDO VERIFICAR LAS AUTORIZACIONES COMERCIALES» y aclara que es informativo (no bloquea)',
                    'NO SE PUDO VERIFICAR LAS AUTORIZACIONES COMERCIALES' in off and 'no bloquea' in off, off)
                await relog(pg, 'comercial.sanjuan@okdespacho.demo')
                ajeno = await pg.evaluate('async()=>{try{return await window.OKD_ONLINE.api.comOrderAlerts(["72003","72001"],["30500010912"])}catch(e){return e.code||e.message}}')
                res('CA-E6 (B-02) COMERCIAL AJENO por invocación directa: no obtiene las solicitudes de otro Comercial aunque conozca pedido y CUIT', ajeno == [], ajeno)
                await relog(pg, 'despacho@okdespacho.demo')
                sinperm = await pg.evaluate('async()=>{try{await window.OKD_ONLINE.api.comOrderAlerts(["72003"],[]); return "VE"}catch(e){return e.code||e.message}}')
                res('CA-E4 un usuario SIN permisos del módulo no obtiene alertas (FORBIDDEN): el recuadro no se muestra', sinperm == 'FORBIDDEN', sinperm)
            finally: await b.close()
    finally: srv.terminate()
    print('TOTAL', sum(1 for r in R if r[1] == 'PASS'), 'PASS /', sum(1 for r in R if r[1] == 'FAIL'), 'FAIL · esperados', EXPECTED)
    return R
if __name__ == '__main__':
    try: rr = asyncio.run(main())
    except Exception as e: traceback.print_exc(); print('ERROR:', repr(e)); sys.exit(2)
    if len(rr) != EXPECTED: print('ERROR: se ejecutaron %d de %d' % (len(rr), EXPECTED)); sys.exit(2)
    sys.exit(1 if any(r[1] != 'PASS' for r in rr) else 0)
