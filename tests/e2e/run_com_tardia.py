"""Certificación de respuestas tardías con datos locales de la demo."""
import asyncio
import sys
from playwright.async_api import async_playwright, expect
import run_driver_perfiles as dp

async def main():
    dp.PORT = 4536
    dp.DIST = sys.argv[1]
    server = dp.serve()
    try:
        async with async_playwright() as p:
            browser = await p.chromium.launch()
            page = await browser.new_page()
            await dp.login(page, 'admin@okdespacho.demo')
            await page.evaluate("location.hash='#/autorizaciones?v=general'")
            await expect(page.locator('#sSave')).to_be_visible()
            await page.evaluate("""() => {
                const api = window.OKD_ONLINE.api;
                const report = api.comReport.bind(api);
                api.comReport = async (...args) => {
                    const result = await report(...args);
                    await new Promise(resolve => window.finishReport = resolve);
                    return result;
                };
            }""")
            await page.click('[data-tab="informes"]')
            await page.wait_for_function("typeof window.finishReport === 'function'")
            await page.click('[data-tab="general"]')
            await expect(page.locator('#sSave')).to_be_visible()
            await page.evaluate("window.finishReport()")
            await page.wait_for_timeout(300)
            await expect(page.locator('#sSave')).to_be_visible()
            await expect(page.locator('#iCsv')).to_have_count(0)
            print('PASS respuesta tardía de Informes al volver a Panel General')
            await page.evaluate("""() => {
                window.OKD_ONLINE.api.comMailSettings = async () => {
                    throw Object.assign(new Error('FORBIDDEN'), {code:'42501'});
                };
            }""")
            await page.click('[data-tab="general"]')
            await expect(page.locator('[data-az-locked]')).to_be_visible()
            await expect(page.locator('#comBell')).to_have_count(0)
            await expect(page.locator('#sSave')).to_have_count(0)
            print('PASS revocación en consulta secundaria oculta el panel y los avisos')
            await browser.close()
    finally:
        server.terminate()

if __name__ == '__main__':
    asyncio.run(main())
