"""Corrección puntual Admin General en Inspecciones. Solo datos DEMO, sin correos reales."""
import asyncio
import os
import sys
from pathlib import Path
import openpyxl
from playwright.async_api import async_playwright
sys.path.insert(0, os.path.dirname(__file__))
import run_inspecciones as ins
dp = ins.dp
dp.PORT = 4461
dp.DIST = sys.argv[1] if len(sys.argv) > 1 else 'dist-demo'
OUT = Path('/tmp/okd-admin-inspections-excel')


async def main():
    OUT.mkdir(exist_ok=True)
    srv = dp.serve()
    try:
        async with async_playwright() as p:
            browser = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH'))
            ctx = await browser.new_context(**ins.MOB)
            page = await ctx.new_page()
            page.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
            await dp.login(page, 'admin@okdespacho.demo')
            await page.evaluate(ins.USERS)
            await ins.go(page, '#/inspecciones')
            tabs = await page.locator('#inTabs').inner_text()
            assert all(x in tabs for x in ['NUEVA INSPECCIÓN', 'MIS INSPECCIONES', 'PENDIENTES', 'HISTORIAL'])
            await page.select_option('#inVeh', 'vh-1')
            await page.fill('#inKm', '50123')
            for _, n, _ in ins.ALL:
                await ins.answer(page, n, 'BIEN')
            await page.reload()
            await ins.go(page, '#/inspecciones')
            assert await page.locator('.in-b.on').count() == 30
            assert await page.input_value('#inKm') == '50123'
            await page.locator('#inSend').tap()
            await page.wait_for_timeout(1200)
            data = await page.evaluate(ins.DB)
            own = data['insp'][0]
            assert own['status'] == 'PENDIENTE' and own['team_supervisor_id'] is None
            await ins.go(page, '#/inspecciones?id=' + own['id'])
            await page.locator('#inOk').tap()
            await page.wait_for_timeout(800)
            approved = (await page.evaluate(ins.DB))['insp'][0]
            assert approved['reviewed_by'] == approved['created_by']
            assert approved['reviewed_at']
            print('PASS Admin: four tabs, 30 controls, saved draft restored, submit without Supervisor, self approval', flush=True)

            await page.locator('#inMail').tap()
            assert await page.locator('#inMailGo').count() == 1
            assert len((await page.evaluate(ins.DB))['emails']) == 0
            await page.fill('#inTo', 'qa@example.invalid')
            await page.locator('#inMailGo').tap()
            await page.wait_for_timeout(700)
            assert len((await page.evaluate(ins.DB))['emails']) == 1
            assert 'simulado' in await page.inner_text('#inMsg')
            print('PASS Admin: email request and confirmation, DEMO only', flush=True)
            async with page.expect_download() as dl:
                await page.locator('#inXls').tap()
            file = OUT / (await dl.value).suggested_filename
            await (await dl.value).save_as(file)
            book = openpyxl.load_workbook(file)
            text = str(list(book.active.values))
            assert approved['number'] in text and approved['created_by_name'] in text and 'APROBADA' in text
            await page.locator('[data-intab="hist"]').tap()
            await page.wait_for_timeout(500)
            async with page.expect_download() as dl:
                await page.locator('#hfX').tap()
            file = OUT / (await dl.value).suggested_filename
            await (await dl.value).save_as(file)
            assert openpyxl.load_workbook(file).sheetnames == ['RESUMEN', 'DETALLE', 'AUDITORÍA']
            print('PASS Admin: individual Excel and history Excel with RESUMEN/DETALLE/AUDITORÍA', flush=True)

            rev = await page.evaluate('''async id=>{const a=window.OKD_ONLINE.api;const r=await a.inspNewRevision(id,crypto.randomUUID());await a.inspSubmit(r.id);return r;}''', own['id'])
            await ins.go(page, '#/inspecciones?id=' + rev['id'])
            await page.locator('#inNo').tap()
            await page.fill('#inWhy', 'QA rechazo propio')
            await page.locator('#inNoGo').tap()
            await page.wait_for_timeout(700)
            assert any(i['id'] == rev['id'] and i['status'] == 'RECHAZADA' for i in (await page.evaluate(ins.DB))['insp'])
            print('PASS Admin: self rejection through UI with reason', flush=True)

            await ins.relog(page, 'qa.sup1@okdespacho.demo')
            await ins.go(page, '#/inspecciones')
            assert await page.locator('[data-intab="pend"]').count() == 1
            ids = await page.evaluate('async()=> (await window.OKD_ONLINE.api.inspList({})).map(i=>i.id)')
            assert own['id'] not in ids
            await ins.relog(page, 'qa.op1@okdespacho.demo')
            await ins.go(page, '#/inspecciones')
            assert await page.locator('[data-intab="nueva"]').count() == 1
            assert await page.locator('[data-intab="pend"]').count() == 0
            denied = await page.evaluate('''async id=>{try{await window.OKD_ONLINE.api.inspReview(id,'APROBADA',null);return false;}catch(e){return e.code==='FORBIDDEN';}}''', own['id'])
            assert denied
            # An isolated DEMO profile is disabled; no production profile/session is changed.
            disabled = await page.evaluate('''async()=>{const a=window.OKD_ONLINE.api;const me=await a.me();const k='okd_online_demo_v2',d=JSON.parse(localStorage.getItem(k));d.users.find(u=>u.id===me.id).status='DESHABILITADO';localStorage.setItem(k,JSON.stringify(d));try{await a.inspSaveDraft({client_id:crypto.randomUUID(),vehicle_id:'vh-1'});return false;}catch(e){return true;}}''')
            assert disabled
            print('PASS Superior and Operator unchanged; disabled profile denied', flush=True)
            await browser.close()
    finally:
        srv.terminate()


if __name__ == '__main__':
    asyncio.run(main())
