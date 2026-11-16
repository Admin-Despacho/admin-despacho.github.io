import asyncio,sys,os,json,tempfile,socket
from pathlib import Path
sys.path.insert(0,str(Path(__file__).parent/'repo/tests/e2e'))
import run_driver_perfiles as dp
import run_com_ingesta_constructor as ic
from playwright.async_api import async_playwright
sock=socket.socket();sock.bind(('127.0.0.1',0));dp.PORT=sock.getsockname()[1];sock.close();dp.DIST=str(Path(__file__).parent/'repo'/os.environ.get('DIST','dist-demo-original'));ic.preparar();OUT=Path(__file__).parent/'results'
COUNT='''async()=>new Promise(ok=>{const r=indexedDB.open('okd-com-ingest',1);r.onupgradeneeded=()=>r.result.createObjectStore('jobs',{keyPath:'hash'});r.onsuccess=()=>{const d=r.result,t=d.transaction('jobs','readonly'),q=t.objectStore('jobs').count();q.onsuccess=()=>{ok(q.result);d.close()}}})'''
async def main():
 srv=dp.serve();checks=[]
 try:
  async with async_playwright() as p:
   profile=tempfile.mkdtemp(prefix='com-browser-audit-');ctx=await p.chromium.launch_persistent_context(profile,executable_path=os.environ['CHROMIUM_PATH'],viewport={'width':390,'height':844},is_mobile=True,has_touch=True,service_workers='block')
   pg=await ctx.new_page();gate=asyncio.Event();blocked=[]
   async def delay(r):
    blocked.append(r.request.url);response=await r.fetch();body=await response.text();await r.fulfill(response=response,body='await new Promise(r=>window.__comRelease=r);\n'+body)
   await pg.route('**/assets/com-ingest-*.js',delay)
   await pg.goto(f'http://127.0.0.1:{dp.PORT}/');await dp.login(pg,'operario@okdespacho.demo');await pg.evaluate('()=>{window.OKD_COM_INGEST_FAIL=true}')
   await ic.load(pg)
   before=await pg.evaluate(COUNT);ready=await pg.evaluate('()=>OrderIndex.size()>0&&!!RouteStore.data.sc&&!!RouteStore.data.cc')
   checks.append({'case':'D/F Constructor real, emisor no inicializado: hojas operativas y dos cargas durables','pass':ready and before==2,'ready':ready,'pending':before,'blocked_sender':len(blocked)})
   await pg.evaluate('()=>window.__comRelease()');await pg.wait_for_timeout(4000)
   if before==0: await ic.load(pg)
   pending=await pg.evaluate(COUNT)
   session=await pg.evaluate("()=>localStorage.getItem('okd_online_demo_session')")
   await ctx.close()
   ctx=await p.chromium.launch_persistent_context(profile,executable_path=os.environ['CHROMIUM_PATH'],viewport={'width':390,'height':844},service_workers='block')
   pg=await ctx.new_page();await pg.add_init_script('window.OKD_COM_INGEST_FAIL=true');await pg.goto(f'http://127.0.0.1:{dp.PORT}/');await pg.wait_for_timeout(4000)
   after=await pg.evaluate(COUNT)
   checks.append({'case':'E cierre y reapertura de proceso Chromium: IndexedDB pendiente conservada','pass':pending==2 and after==2,'before':pending,'after':after})
   if await pg.locator('#loginBtn').is_visible(): await dp.login(pg,'operario@okdespacho.demo')
   await pg.evaluate('()=>{window.OKD_COM_INGEST_FAIL=false;window.dispatchEvent(new Event("online"))}');await pg.wait_for_timeout(4500)
   final=await pg.evaluate(COUNT)
   checks.append({'case':'E recuperacion tras reinicio y confirmacion: cola final vacia','pass':pending==2 and after==2 and final==0,'pending':final})
   await ctx.close()
 finally:srv.terminate()
 tag=os.environ.get('TAG','original');(OUT/(tag+'_constructor_audit.json')).write_text(json.dumps(checks,indent=2));print(json.dumps(checks,indent=2))
asyncio.run(main())
