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
    await pg.evaluate('location.hash="#/autorizaciones?v=general"');await pg.wait_for_selector('#comMailNew')
    await pg.fill('#comMailNew',' COPY@qa.invalid,copy@qa.invalid\nsegunda@qa.invalid');await pg.click('#comMailAuthorize')
    await pg.wait_for_function('document.querySelector("#comMailResult").textContent.includes("confirmar")')
    result=await pg.evaluate('window.OKD_ONLINE.api.comMailSettings()');assert result['copies']==[]
    print('UI-00 PASS: sin la confirmación de autorización no se agrega ninguna copia',flush=True)
    await pg.check('#comMailAuth');await pg.click('#comMailAuthorize')
    await pg.wait_for_selector('[data-copy="segunda@qa.invalid"]')
    result=await pg.evaluate('window.OKD_ONLINE.api.comMailSettings()');assert result['copies']==['copy@qa.invalid','segunda@qa.invalid'];assert result['author_always'] is True
    assert all(r['status']=='AUTORIZADA' for r in result['recipients'])
    print('UI-01 PASS: alta móvil con confirmación, normalización, autorización y autor obligatorio',flush=True)
    await pg.reload();await pg.wait_for_selector('[data-copy="segunda@qa.invalid"]');assert 'Autorizada' in await pg.inner_text('#comMailRecipients')
    print('UI-02 PASS: configuración y estado de autorización persisten al recargar',flush=True)
    await pg.fill('#comMailNew','correo-mal-formado');await pg.check('#comMailAuth');await pg.click('#comMailAuthorize');await pg.wait_for_function('document.querySelector("#comMailResult").textContent.includes("Revisá las direcciones")')
    result=await pg.evaluate('window.OKD_ONLINE.api.comMailSettings()');assert len(result['copies'])==2
    print('UI-03 PASS: dirección inválida rechazada sin perder lo guardado',flush=True)
    await pg.check('#comMailAll');await pg.click('#comMailRevoke');await pg.wait_for_function('!document.querySelector("[data-copy]")')
    result=await pg.evaluate('window.OKD_ONLINE.api.comMailSettings()');assert result['copies']==[] and result['author_always'] is True
    print('UI-04 PASS: revocar copias no quita al autor',flush=True)
    sw=await pg.evaluate('document.documentElement.scrollWidth<=innerWidth+1');assert sw
    print('UI-06 PASS: panel sin desborde horizontal en 390 px',flush=True)
    request_id='11111111-2222-4333-8444-555555555555'
    cp=await (await b.new_context()).new_page();await dp.login(cp,'comercial.montecaseros@okdespacho.demo')
    await cp.evaluate('async()=>{await window.OKD_ONLINE.api.comCreate("FINANCIACION","cli-101","MAIL-UI-1",{amount:150000,installments:2},null,"mail-ui-1")}')
    fixture=await cp.evaluate('(id)=>{const a=window.OKD_ONLINE.api,c=a._com(),q=c.requests[0],old=q.id;q.id=id;c.events.forEach(e=>{if(e.request_id===old)e.request_id=id});return {q,events:c.events};}',request_id)
    number=fixture['q']['number'];await pg.evaluate('(f)=>{const a=window.OKD_ONLINE.api,c=a._com();c.requests.push(f.q);c.events.push(...f.events);a._save();}',fixture)
    await pg.goto('http://127.0.0.1:'+str(dp.PORT)+'/#/autorizaciones?v=historial&solicitud='+request_id);await pg.reload();await pg.wait_for_selector('#hBack');assert number in await pg.inner_text('#comMain')
    await pg.click('#hBack');await pg.wait_for_selector('#hNum')
    print('UI-05 PASS: enlace del correo abre el detalle y permite volver al historial',flush=True)

   finally:await b.close()
 finally:srv.terminate()
asyncio.run(main())
