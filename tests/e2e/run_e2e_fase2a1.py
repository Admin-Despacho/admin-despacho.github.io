"""E2E Fase 2A.1 (financiación propia + envío provisorio) con los archivos REALES del caso Elisa Moran.
Uso: npm run build && python3 tests/e2e/run_e2e_fase2a1.py"""
import asyncio, json, os, subprocess, sys, time, socket, openpyxl
from playwright.async_api import async_playwright
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
FIX = os.environ.get('OKD_FIXTURES', '/mnt/user-data/uploads')
CHROME = os.environ.get('CHROMIUM_PATH', '/opt/pw-browsers/chromium-1194/chrome-linux/chrome')
OUT = os.path.join(ROOT, 'tests', 'e2e', 'out'); os.makedirs(OUT, exist_ok=True)
FILES = ['informe_pedidos__40_.xlsx', 'informe_ctacte_clientes_-_2026-10-08T160623_262.xlsx', 'informe_ctacte_clientes_-_2026-10-08T160435_253.xlsx']
R = []
def res(n, name, ok, det=''): R.append((n, name, 'PASS' if ok else 'FAIL', str(det)[:150]))

async def main():
    srv = subprocess.Popen(['npx', 'vite', 'preview', '--port', '4174', '--strictPort', '--host', '127.0.0.1'], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(60):
            try: socket.create_connection(('127.0.0.1', 4174), 1).close(); break
            except OSError: time.sleep(0.3)
        async with async_playwright() as p:
            b = await p.chromium.launch(executable_path=CHROME)
            ctx = await b.new_context(viewport={'width': 1440, 'height': 950}, accept_downloads=True); pg = await ctx.new_page(); errs = []
            pg.on('pageerror', lambda e: errs.append(str(e)))
            async def dlg(d): await (d.accept('ELIMINAR') if d.type == 'prompt' else d.accept())
            pg.on('dialog', lambda d: asyncio.ensure_future(dlg(d)))
            await pg.goto('http://127.0.0.1:4174/'); await pg.evaluate('()=>localStorage.clear()'); await pg.reload(); await pg.wait_for_timeout(500)
            await pg.fill('#loginEmail', 'despacho@okdespacho.demo'); await pg.fill('#loginPass', 'demo'); await pg.click('#loginBtn'); await pg.wait_for_timeout(2000)
            await pg.set_input_files('.file[data-kind="pedidos"] input', [os.path.join(FIX, f) for f in FILES])
            for _ in range(240):
                await pg.wait_for_timeout(500)
                if await pg.eval_on_selector_all('.file.ok', 'e=>e.length') == 3: break
            await pg.fill('#sheetDate', '09/10/2026'); await pg.press('#sheetDate', 'Tab')
            await pg.fill('#ids', '25537'); await pg.click('#btnSearch'); await pg.wait_for_timeout(1500)
            row = '()=>{const r=OKD.RouteStore.rows.find(x=>x.mainOrder==="25537");const c=r.calc||{};return {monto:r.monto,ship:r.shipOrder,main:c.mainDue,fin:c.finGroup&&{st:c.finGroup.status,parts:c.finGroup.parts,total:c.finGroup.total},prov:c.shipProv||null,pago:OKD.Txt.pago(r).replace(/\\n/g," | "),st:OKD.rowStatus(r).label,sline:statusLines(r)}}'
            r = await pg.evaluate(row)
            res('FP-ON-10', 'Elisa Moran: 6 partes agrupadas = $ 5.165.598,86', r['fin'] and r['fin']['st'] == 'FINANCIACION_PROPIA_VIGENTE' and r['fin']['parts'] == 6 and abs(r['main'] - 5165598.86) < .01, json.dumps(r['fin']))
            res('FP-ON-07 (UI)', 'Se muestra FINANCIACIÓN PROPIA · DEUDA VIGENTE con las partes', any('FINANCIACIÓN PROPIA · DEUDA VIGENTE' in x and '6 partes' in x for x in r['sline']), ' / '.join(r['sline']))
            res('ENV-ON-02/03', 'NDP de envío faltante + costo conocido → $ 10.000 A CONFIRMAR', r['ship'] == '25610' and r['prov'] and r['prov']['status'] == 'PENDING_CONFIRMATION' and r['prov']['amount'] == 10000, json.dumps(r['prov']))
            res('ENV-ON-06 / FP-ON-11', 'Total = mercadería + $ 10.000 (no PENDIENTE, no se pierde el saldo principal)', abs((r['monto'] or 0) - 5175598.86) < .01, r['pago'])
            res('ENV-ON-04/05', 'No usa $0 y la línea dice A CONFIRMAR', 'ENVÍO: $ 10.000,00 · A CONFIRMAR' in r['pago'] and 'MERCADERÍA: $ 5.165.598,86' in r['pago'], r['pago'])
            bar = await pg.inner_text('#shipBar')
            res('ENV-ON-13a', 'Contador "1 ENVÍO PARA CONFIRMAR" y REVISAR AHORA (sin bloquear)', '1 ENVÍO PARA CONFIRMAR' in bar and await pg.is_visible('#shipReview') and await pg.is_enabled('#btnSearch'), bar.split('\n')[0])
            # PDF / Excel / Imprimir abren el asistente
            tarifa_txt = ''
            await pg.click('#btnPublish'); await pg.wait_for_timeout(400)
            pt = await pg.inner_text('#shipModal') if await pg.locator('#shipModal').count() else ''
            res('ENV-ON-07 / 2B1-02 (UI)', 'PUBLICAR HOJA abre el asistente y no publica con el envío sin confirmar', 'REVISÁ LOS COSTOS DE ENVÍO' in pt and await pg.locator('#publishModal').count() == 0, pt[:60].replace('\n', ' '))
            await pg.click('#shipBack'); await pg.wait_for_timeout(200)
            for btn, n in [('#btnPdf', 'ENV-ON-08'), ('#btnExport', 'ENV-ON-09')]:
                await pg.click(btn); await pg.wait_for_timeout(400)
                txt = await pg.inner_text('#shipModal') if await pg.locator('#shipModal').count() else ''; tarifa_txt = txt
                res(n, ('PDF' if btn == '#btnPdf' else 'Excel') + ' final abre el asistente y no sale', 'REVISÁ LOS COSTOS DE ENVÍO' in txt and 'El pedido de envío 25610 tiene un costo de $ 10.000,00' in txt and 'no aparece en Saldo Comprobante' in txt, txt[:80].replace('\n', ' '))
                await pg.click('#shipBack'); await pg.wait_for_timeout(200)
            # cambiar importe sin motivo → error
            await pg.click('#btnExport'); await pg.wait_for_timeout(300)
            await pg.click('#shipModal [data-a="edit"]'); await pg.fill('#shipModal [data-f="amt"]', '12.000'); await pg.click('#shipModal [data-a="save"]'); await pg.wait_for_timeout(300)
            e = await pg.inner_text('#shipModal .shiperr')
            res('ENV-ON-12 (UI)', 'Cambiar importe exige motivo', 'motivo' in e, e)
            go_disabled = await pg.is_disabled('#shipGo')
            res('ENV-ON-14 (UI)', 'Con envíos pendientes la salida final sigue bloqueada', go_disabled)
            await pg.dblclick('#shipModal [data-a="ok"]'); await pg.wait_for_timeout(800)
            recs = await pg.evaluate('()=>(window.OKD_ONLINE.api.db.shipping||[]).filter(x=>x.status!=="INVALIDATED")')
            res('ENV-ON-10 / ENV-ON-15', 'Confirmar funciona y queda guardado del lado del servidor (usuario y hora)', len(recs) == 1 and recs[0]['status'] == 'CONFIRMED' and recs[0]['confirmed_by'] == 'u-deposito' and recs[0]['confirmed_at'], json.dumps(recs[0] if recs else None)[:120])
            res('ENV-ON-23 (UI)', 'Doble clic: una sola confirmación', len(await pg.evaluate('()=>window.OKD_ONLINE.api.db.shipping')) == 1)
            res('ENV-ON-15b', 'La confirmación queda asociada a la hoja (sheet_key)', bool(recs and recs[0].get('sheet_key')), str(recs[0].get('sheet_key') if recs else None))
            async with pg.expect_download() as d: await pg.click('#shipGo')
            x = await d.value; xp = os.path.join(OUT, 'elisa.xlsx'); await x.save_as(xp)
            ws = openpyxl.load_workbook(xp).active
            montos = [rr[6] for rr in ws.iter_rows(min_row=6, values_only=True) if rr[3] and 'MORAN' in str(rr[3]).upper()]
            res('FP-ON-19', 'Excel: la fila de Elisa sale una sola vez con el total correcto', montos == [5175598.86], str(montos))
            r = await pg.evaluate(row)
            res('ENV-ON-10b', 'Confirmado: ya no dice A CONFIRMAR y el contador desaparece', 'A CONFIRMAR' not in r['pago'] and await pg.locator('#shipBar[hidden]').count() == 1, r['pago'])
            # invalidación por cambio de transportista
            i = await pg.evaluate('()=>OKD.RouteStore.rows.findIndex(x=>x.mainOrder==="25537")')
            cur = await pg.evaluate('()=>OKD.RouteStore.rows.find(x=>x.mainOrder==="25537").transportista')
            opts = await pg.eval_on_selector_all(f'#tbody tr.main-row >> nth={i} >> select[data-f=transportista] option', 'e=>e.map(o=>o.value).filter(Boolean)')
            other = [o for o in opts if o != cur][0]
            await pg.select_option(f'#tbody tr.main-row >> nth={i} >> select[data-f=transportista]', other); await pg.wait_for_timeout(600)
            r = await pg.evaluate(row)
            res('ENV-ON-16 (UI)', 'Cambiar el transportista invalida la confirmación (vuelve a A CONFIRMAR)', r['prov']['status'] == 'PENDING_CONFIRMATION' and await pg.is_visible('#shipBar'), json.dumps(r['prov']))
            await pg.select_option(f'#tbody tr.main-row >> nth={i} >> select[data-f=transportista]', cur); await pg.wait_for_timeout(400)
            # modificar con motivo
            await pg.click('#shipReview'); await pg.click('#shipModal [data-a="edit"]'); await pg.fill('#shipModal [data-f="amt"]', '12.000'); await pg.fill('#shipModal [data-f="reason"]', 'Tarifa nueva'); await pg.click('#shipModal [data-a="save"]'); await pg.wait_for_timeout(800)
            r = await pg.evaluate(row); recs = await pg.evaluate('()=>(window.OKD_ONLINE.api.db.shipping||[]).filter(x=>x.status!=="INVALIDATED")')
            res('ENV-ON-11 (UI)', 'Cambiar importe: guarda anterior, nuevo y motivo; total con el nuevo', recs and recs[0]['status'] == 'MODIFIED_CONFIRMED' and recs[0]['confirmed_amount'] == 12000 and recs[0]['reason'] == 'Tarifa nueva' and abs(r['monto'] - 5177598.86) < .01, str(r['monto']))
            # la NDP real aparece después
            inject = '''(saldo)=>{const C=OKD.RouteStore.rows.find(x=>x.mainOrder==="25537");const n=Normalizer.comp(C.shipDoc);const main=FinancialIndex.findComp(C.mainDoc,C.cliente);
              FinancialIndex.comps.set(n,[Object.assign({},main,{comp:C.shipDoc,n,s:saldo,m:saldo,fin:null})]);CalculationEngine.computeAll(OKD.RouteStore.rows);UI.renderTable();}'''
            await pg.evaluate(inject, 12000); r = await pg.evaluate(row)
            res('ENV-ON-17/18', 'La NDP aparece con el mismo importe: se usa el saldo real sin pedir nada', r['prov'] is None and abs(r['monto'] - 5177598.86) < .01, r['st'])
            await pg.evaluate(inject, 13000); r = await pg.evaluate(row)
            res('ENV-ON-19', 'La NDP aparece con otro importe: DIFERENCIA · REVISAR, sin pisar el confirmado', r['st'].startswith('DIFERENCIA ENTRE COSTO DE ENVÍO') and abs(r['monto'] - 5177598.86) < .01, r['st'])
            # sin costo / sin NDP: no inventa
            await pg.evaluate('''()=>{const C=OKD.RouteStore.rows.find(x=>x.mainOrder==="25537");FinancialIndex.comps.delete(Normalizer.comp(C.shipDoc));C.shipConfirm=null;C.shipProvSeen=false;C.shipCostOrig=0;C.shipCost=0;CalculationEngine.computeAll(OKD.RouteStore.rows);}''')
            r = await pg.evaluate(row)
            res('ENV-ON-21', 'Sin costo de envío no inventa importe (queda pendiente)', r['monto'] is None and r['st'] == 'SALDO NO ENCONTRADO', r['st'])
            await pg.evaluate('''()=>{const C=OKD.RouteStore.rows.find(x=>x.mainOrder==="25537");C.shipCostOrig=10000;C.shipDoc='';CalculationEngine.computeAll(OKD.RouteStore.rows);}''')
            r = await pg.evaluate(row)
            res('ENV-ON-22', 'Sin NDP no inventa importe', r['monto'] is None and r['st'].startswith('SIN COMPROBANTE'), r['st'])
            # Cuenta corriente sigue aplicando después de agrupar
            await pg.evaluate('''()=>{const C=OKD.RouteStore.rows.find(x=>x.mainOrder==="25537");C.shipDoc='NDP [X] 0014-00009186';const cc=FinancialIndex.findCC(C.calc.cuit,C.cliente);cc.s=3000000;CalculationEngine.computeAll(OKD.RouteStore.rows);}''')
            r = await pg.evaluate(row)
            res('FP-ON-12', 'La cuenta corriente sigue siendo el tope después de agrupar', abs((r['monto'] or 0) - 3000000) < .01, str(r['monto']))
            res('ENV-ON-20', 'El asistente muestra la tarifa configurada para comparar', 'Tarifa configurada para la zona' in tarifa_txt, [l for l in tarifa_txt.split('\n') if 'Tarifa' in l][:1])
            res('E-ERR', 'Sin errores de consola', not errs, '; '.join(errs[:2]))
            await b.close()
    finally: srv.terminate()
    for r_ in R: print(' | '.join(r_))
    print('TOTAL', sum(1 for x in R if x[2] == 'PASS'), 'PASS /', sum(1 for x in R if x[2] == 'FAIL'), 'FAIL')
    json.dump([dict(zip(('id', 'name', 'result', 'detail'), x)) for x in R], open(os.path.join(OUT, 'e2e_fase2a1.json'), 'w'), ensure_ascii=False, indent=1)
asyncio.run(main())
