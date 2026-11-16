"""Chromium + demo. No SMTP, Auth real, correos ni push reales."""
import asyncio,os,sys
sys.path.insert(0,os.path.dirname(__file__))
import run_driver_perfiles as dp
from playwright.async_api import async_playwright
DIST=sys.argv[1] if len(sys.argv)>1 else 'dist-demo';dp.DIST=DIST;dp.PORT=4394
async def main():
 srv=dp.serve()
 try:
  async with async_playwright() as p:
   b=await p.chromium.launch()
   try:
    c=await b.new_context(viewport={'width':390,'height':844},is_mobile=True,has_touch=True)
    pg=await c.new_page();await dp.login(pg,'admin@okdespacho.demo')
    await pg.evaluate('location.hash="#/autorizaciones?v=general"');await pg.wait_for_selector('#comMailCopies')
    await pg.fill('#comMailCopies',' COPY@qa.invalid,copy@qa.invalid\nsegunda@qa.invalid');await pg.click('#comMailSave')
    await pg.wait_for_function('document.querySelector("#comMailResult").textContent.includes("guardados")')
    result=await pg.evaluate('window.OKD_ONLINE.api.comMailSettings()');assert result['copies']==['copy@qa.invalid','segunda@qa.invalid'];assert result['author_always'] is True
    print('UI-01 PASS: edición móvil, normalización, guardado y autor obligatorio',flush=True)
    await pg.reload();await pg.wait_for_selector('#comMailCopies');assert 'segunda@qa.invalid' in await pg.input_value('#comMailCopies')
    print('UI-02 PASS: configuración persiste al recargar',flush=True)
    await pg.fill('#comMailCopies','correo-mal-formado');await pg.click('#comMailSave');await pg.wait_for_function('document.querySelector("#comMailResult").textContent.includes("Revisá las direcciones")')
    result=await pg.evaluate('window.OKD_ONLINE.api.comMailSettings()');assert len(result['copies'])==2
    print('UI-03 PASS: dirección inválida rechazada sin perder guardado',flush=True)
    await pg.fill('#comMailCopies','');await pg.click('#comMailSave');await pg.wait_for_function('document.querySelector("#comMailResult").textContent.includes("guardados")');result=await pg.evaluate('window.OKD_ONLINE.api.comMailSettings()');assert result['copies']==[] and result['author_always'] is True
    print('UI-04 PASS: quitar copias no quita al autor',flush=True)
    request_id='11111111-2222-4333-8444-555555555555'
    number=await pg.evaluate('(id)=>{const a=window.OKD_ONLINE.api,c=a._com();const q=c.requests[0];if(!q)throw Error("QA_REQUEST_MISSING");q.id=id;a._save();return q.number;}',request_id)
    await pg.goto('http://127.0.0.1:'+str(dp.PORT)+'/#/autorizaciones?v=historial&solicitud='+request_id);await pg.reload();await pg.wait_for_selector('#hBack');assert number in await pg.inner_text('#comMain')
    await pg.click('#hBack');await pg.wait_for_selector('#hNum')
    print('UI-05 PASS: enlace del correo abre el detalle y permite volver al historial',flush=True)

   finally:await b.close()
 finally:srv.terminate()
asyncio.run(main())
