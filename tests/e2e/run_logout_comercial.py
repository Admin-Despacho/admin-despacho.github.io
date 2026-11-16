import asyncio, sys
import run_driver_perfiles as dp
from playwright.async_api import async_playwright
dp.DIST=sys.argv[1];dp.PORT=4391
async def main():
 srv=dp.serve()
 try:
  async with async_playwright() as p:
   b=await p.chromium.launch()
   pg=await b.new_page(viewport={'width':390,'height':844},is_mobile=True,has_touch=True)
   await dp.login(pg,'comercial.montecaseros@okdespacho.demo')
   await pg.locator('#comMain').wait_for()
   await pg.locator('#np-logout').tap()
   await pg.locator('#authCard').wait_for(timeout=14000)
   await pg.reload()
   await pg.locator('#authCard').wait_for()
   assert not await pg.locator('#np-logout').is_visible()
   print('PASS cierre desde cabecera Comercial y recarga')
   await b.close()
 finally:srv.terminate()
asyncio.run(main())
