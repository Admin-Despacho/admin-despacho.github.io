"""E2E RC1.2: PDF automático al publicar (snapshot publicado, Storage, versión, descarga configurable, error/retry)."""
import asyncio, json, os, subprocess, time, socket
from playwright.async_api import async_playwright
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
FIX = os.environ.get('OKD_FIXTURES', '/mnt/user-data/uploads')
CHROME = os.environ.get('CHROMIUM_PATH', '/opt/pw-browsers/chromium-1194/chrome-linux/chrome')
OUT = os.path.join(ROOT, 'tests', 'e2e', 'out'); os.makedirs(OUT, exist_ok=True)
URL = 'http://localhost:4180/'; R = []
def res(n, name, ok, det=''): R.append((n, name, 'PASS' if ok else 'FAIL', str(det)[:150]))
DB = '()=>JSON.parse(localStorage.getItem("okd_online_demo_v2"))'; api = 'window.OKD_ONLINE.api'
def pdftext(p): return subprocess.run(['pdftotext', '-layout', p, '-'], capture_output=True, text=True).stdout
async def login(pg, email):
    await pg.goto(URL); await pg.wait_for_timeout(400); await pg.fill('#loginEmail', email); await pg.fill('#loginPass', 'demo'); await pg.click('#loginBtn'); await pg.wait_for_timeout(1800)
async def add(op, ids):
    await op.fill('#ids', ids); await op.click('#btnSearch'); await op.wait_for_timeout(1200)
async def publish(op):
    await op.click('#btnPublish'); await op.wait_for_timeout(700)
    await op.click('#pubGo'); await op.wait_for_timeout(2500)
async def main():
    server = subprocess.Popen(['npx', 'vite', 'preview', '--port', '4180', '--strictPort', '--host', 'localhost'], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(60):
            try: socket.create_connection(('localhost', 4180), 1).close(); break
            except OSError: time.sleep(0.3)
        async with async_playwright() as p:
            b = await p.chromium.launch(executable_path=CHROME); ctx = await b.new_context(viewport={'width': 1440, 'height': 950}, accept_downloads=True); errs = []
            op = await ctx.new_page(); op.on('pageerror', lambda e: errs.append(str(e))); op.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
            await op.goto(URL); await op.evaluate('()=>localStorage.clear()'); await login(op, 'despacho@okdespacho.demo')
            await op.set_input_files('.file[data-kind="pedidos"] input', [os.path.join(FIX, f) for f in ('informe_pedidos__31_.xlsx', 'SALDO_COMPROBANTE__3_.xlsx', 'SALDO_CUENTA_CORRIENTE.xlsx')])
            for _ in range(200):
                await op.wait_for_timeout(500)
                if await op.eval_on_selector_all('.file.ok', 'e=>e.length') == 3: break
            await op.fill('#sheetDate', '01/10/2026'); await op.press('#sheetDate', 'Tab')
            # 1) auto ON: publica, genera, guarda y descarga
            await add(op, '25384')
            async with op.expect_download(timeout=15000) as d: await publish(op)
            dl = await d.value; p1 = os.path.join(OUT, 'pub_' + dl.suggested_filename); await dl.save_as(p1)
            st = await op.evaluate(DB); pub = await op.evaluate('()=>OKD.RouteStore.published'); rec = st['routePdfs'][pub['id'] + '|1']
            bar = await op.inner_text('#pdfBar')
            res('PDFPUB-01/06', 'Publicar genera el PDF y lo descarga (auto ON)', rec['status'] == 'OK' and dl.suggested_filename == 'Hoja_' + pub['number'] + '_v1.pdf' and '✓ HOJA PUBLICADA · ✓ PDF GENERADO' in bar, dl.suggested_filename)
            res('PDFPUB-03/04', 'PDF guardado con hoja, versión, correlativo, fecha y usuario', rec['route_id'] == pub['id'] and rec['route_version'] == 1 and rec['file_name'] == 'Hoja_' + pub['number'] + '_v1.pdf' and rec['storage_path'] == pub['id'] + '/v1/' + rec['file_name'] and rec['generated_by'] == 'u-deposito' and rec['generated_at'])
            t1 = pdftext(p1)
            res('PDFPUB-13', 'El PDF de la hoja no tiene DNI/CUIL/firma/GPS', 'HERNANDEZ' in t1.upper() and not any(x in t1.upper() for x in ('CUIL', 'DNI', 'FIRMA', 'LATITUD', '-32.')), '')
            # 2) falla de generación → pendiente → la hoja viva cambia → reintento desde snapshot
            await op.click('#tabNew'); await op.wait_for_timeout(800); await add(op, '25385')
            await op.evaluate('()=>{window.OKD_PDF_FAIL=true}'); await publish(op)
            pub2 = await op.evaluate('()=>OKD.RouteStore.published'); st = await op.evaluate(DB)
            bar = await op.inner_text('#pdfBar'); r2 = [x for x in st['routes2'] if x['id'] == pub2['id']][0]
            res('PDFPUB-09', 'Falla de generación/Storage: hoja PUBLICADA, PDF PENDIENTE con REINTENTAR PDF', r2['operational_status'] == 'PUBLICADA' and 'HOJA PUBLICADA · PDF PENDIENTE' in bar and await op.locator('#pdfRetry').count() == 1 and st['routePdfs'][pub2['id'] + '|1']['status'] == 'PDF_ERROR')
            await op.evaluate('()=>{OKD.RouteStore.rows.forEach(r=>{r.cliente="CAMBIADO DESPUES"});}')  # datos vivos posteriores
            await op.evaluate('()=>{window.OKD_PDF_FAIL=false}'); await op.click('#pdfRetry'); await op.wait_for_timeout(1500); await op.click('#pdfRetry') if await op.locator('#pdfRetry').count() else None
            st = await op.evaluate(DB); rec2 = st['routePdfs'][pub2['id'] + '|1']
            async with op.expect_download() as d2: await op.click('#pdfDl')
            f2 = os.path.join(OUT, 'retry.pdf'); await (await d2.value).save_as(f2); t2 = pdftext(f2)
            res('PDFPUB-02', 'El reintento usa el snapshot publicado (no los datos vivos posteriores)', 'GODOY' in t2.upper() and 'CAMBIADO DESPUES' not in t2.upper())
            res('PDFPUB-10', 'Reintento idempotente: un solo PDF lógico por hoja+versión', rec2['status'] == 'OK' and len([k for k in st['routePdfs'] if k.startswith(pub2['id'])]) == 1 and len([k for k in st['pdfStore'] if k.startswith(pub2['id'])]) == 1, f"intentos {rec2['attempts']}")
            # 3) descarga bloqueada por el navegador
            await op.click('#tabNew'); await op.wait_for_timeout(800); await add(op, '25378')
            await op.evaluate('()=>{window.OKD_DL_FAIL=true}'); await publish(op)
            pub3 = await op.evaluate('()=>OKD.RouteStore.published'); st = await op.evaluate(DB)
            res('PDFPUB-08', 'Si el navegador bloquea la descarga: la hoja sigue publicada, el PDF guardado y aparece DESCARGAR PDF', pub3['pdf']['status'] == 'OK' and pub3['pdf']['downloaded'] is False and await op.locator('#pdfDl').count() == 1 and [x for x in st['routes2'] if x['id'] == pub3['id']][0]['operational_status'] == 'PUBLICADA')
            await op.evaluate('()=>{window.OKD_DL_FAIL=false}')
            # 4) configuración: Despacho no cambia; Admin desactiva la descarga automática
            w = 'OK'
            try: await op.evaluate(f'()=>{api}.setDispatchSettings(true,false)')
            except Exception as e: w = str(e)
            res('PDFPUB-12', 'Despacho no cambia la configuración (sí la lee)', w != 'OK' and (await op.evaluate(f'()=>{api}.dispatchSettings()'))['pdf_auto_download'] is True, w[:60])
            ad = await ctx.new_page(); await login(ad, 'admin@okdespacho.demo')
            await ad.goto(URL + '#/configuracion'); await ad.wait_for_timeout(1500); await ad.uncheck('#pcDl'); await ad.click('#pcSave'); await ad.wait_for_timeout(600)
            cfg_txt = await ad.inner_text('#pdfCfg') if await ad.locator('#pdfCfg').count() else ''
            res('PDFPUB-CFG', 'CONFIGURACIÓN → DESPACHO → PDF (generar y descargar, con el texto explicativo)', 'GENERAR PDF AUTOMÁTICAMENTE AL PUBLICAR' in cfg_txt and 'también intenta descargarlo' in cfg_txt and (await ad.evaluate(f'()=>{api}.dispatchSettings()'))['pdf_auto_download'] is False)
            await op.click('#tabNew'); await op.wait_for_timeout(800); await add(op, '25370 25371 25372 25373 25374 25375 25376 25377 25379 25380')
            # deja solo pedidos listos de un mismo transportista (la prueba es del PDF, no de la revisión)
            await op.evaluate('''()=>{const bad=new Set(Publisher.problems()); const ok=OKD.RouteStore.rows.filter(r=>r.sale&&!bad.has(r)); const t=ok[0]&&ok[0].transportista;
              OKD.RouteStore.rows=OKD.RouteStore.rows.filter(r=>ok.includes(r)).slice(0,2); OKD.RouteStore.rows.forEach(r=>{r.transportista="CRISTIAN TORRES - ESTE"}); CalculationEngine.computeAll(OKD.RouteStore.rows); OKD.RouteStore.save(); UI.renderTable();}''')
            got = []
            op.on('download', lambda d: got.append(d))
            await publish(op); await op.wait_for_timeout(1500)
            pub4 = await op.evaluate('()=>OKD.RouteStore.published')
            res('PDFPUB-07', 'Auto-descarga OFF: genera y guarda pero no descarga; muestra DESCARGAR PDF', pub4['pdf']['status'] == 'OK' and not got and await op.locator('#pdfDl').count() == 1 and '✓ PDF GENERADO' in await op.inner_text('#pdfBar'))
            # 5) hoja histórica: la primera pestaña descarga su versión
            await op.click('.stab >> nth=0'); await op.wait_for_timeout(1200)
            async with op.expect_download() as d3: await op.click('#pdfDl')
            res('PDFPUB-14', 'Hoja histórica descarga su PDF (versión correspondiente)', (await d3.value).suggested_filename == 'Hoja_' + pub['number'] + '_v1.pdf')
            res('E-ERR', 'Sin errores de consola', not errs, '; '.join(errs[:2]))
            await b.close()
    finally: server.terminate()
    for r_ in R: print(' | '.join(r_))
    print('TOTAL', sum(1 for x in R if x[2] == 'PASS'), 'PASS /', sum(1 for x in R if x[2] == 'FAIL'), 'FAIL')
asyncio.run(main())
