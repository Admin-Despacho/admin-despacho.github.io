"""Actualización real con Chromium, SW, HTTP/ETag e IndexedDB; datos comerciales exclusivamente DEMO locales.
No mocks de service worker, cachés, PIN ni DriverApp. No accede a producción ni borra almacenamiento para actualizar.
Uso: run_v426_pwa_upgrade.py build_base_demo build_nuevo_demo salida
"""
import asyncio,json,os,re,sys,threading
from pathlib import Path
from http.server import ThreadingHTTPServer
from playwright.async_api import async_playwright
import run_driver_perfiles as dp
import ghpages_server as gh
OLD,NEW,OUT=map(lambda x:Path(x).resolve(),sys.argv[1:4]);OUT.mkdir(parents=True,exist_ok=True)
LINK=OUT/'served';gh.ROOT=str(LINK);gh.MODE='pages'
NEW_CACHE=re.search(r'okd-shell-([a-f0-9]+)',(NEW/'sw.js').read_text())[0]
def use(p):
 if LINK.is_symlink():LINK.unlink()
 LINK.symlink_to(p,target_is_directory=True)
async def state(pg):
 return await pg.evaluate('''async()=>({url:location.href,build:window.OKD_BUILD,boot:window.OKD_BOOT,me:(await window.OKD_ONLINE.api.me())?.id,session:sessionStorage.getItem('okd_online_session'),cache:await caches.keys(),pin:!!document.querySelector('#pinGate'),cfg:Object.fromEntries(Object.keys(localStorage).filter(k=>k.endsWith('_cfg')).map(k=>[k,localStorage.getItem(k)]))})''')
async def ready(pg):
 await pg.wait_for_function('()=>window.OKD_ONLINE&&window.OKD_BOOTED',timeout=30000)
 await pg.evaluate('()=>navigator.serviceWorker.ready.then(()=>true)')
 await pg.wait_for_timeout(1500)
async def newid(pg):
 await pg.wait_for_function('async k=>(await caches.keys()).includes(k)&&window.OKD_BUILD==="V4.26"',arg=NEW_CACHE,timeout=45000)
async def blob(pg,write=False):
 return await pg.evaluate('''write=>new Promise((ok,ko)=>{const q=indexedDB.open('okd_drv_blobs',1);q.onupgradeneeded=()=>q.result.createObjectStore('b');q.onerror=()=>ko(q.error);q.onsuccess=()=>{const d=q.result,t=d.transaction('b',write?'readwrite':'readonly'),s=t.objectStore('b');if(write){s.put(new Blob(['PENDIENTE-QA-NO-BORRAR']),'v426-qa');t.oncomplete=()=>{d.close();ok(true)}}else{const r=s.get('v426-qa');r.onsuccess=async()=>{const text=await r.result?.text();d.close();ok(text)}}}})''',write)
async def main():
 use(OLD);srv=ThreadingHTTPServer(('127.0.0.1',0),gh.H);threading.Thread(target=srv.serve_forever,daemon=True).start();dp.PORT=srv.server_port;url=f'http://127.0.0.1:{dp.PORT}/';results=[]
 async with async_playwright() as p:
  async def mk(name):
   return await p.chromium.launch_persistent_context(str(OUT/name),executable_path=os.environ['CHROMIUM_PATH'],viewport={'width':412,'height':915},is_mobile=True,has_touch=True,permissions=['geolocation'],geolocation={'latitude':-32.89,'longitude':-68.84})
  try:
   ctx=await mk('profile-offline');pg=ctx.pages[0];pg.on('dialog',lambda d:asyncio.ensure_future(d.accept()))
   await dp.login(pg,'admin@okdespacho.demo');ids=await pg.evaluate(dp.PUB)
   await pg.evaluate('()=>window.OKD_ONLINE.api.signOut()');await dp.login(pg,'cristian@okdespacho.demo');await ready(pg)
   await dp.open_route(pg,ids['ct']);sid=await dp.stop_id(pg,ids['ct'],0);before=await state(pg);await blob(pg,True)
   await ctx.set_offline(True);await dp.choose(pg,sid,'NO_ENTREGADO');await pg.fill(f'.drv-stop[data-s="{sid}"] [data-f="txt"]','QA offline sin entrega comercial');await dp.save(pg,sid)
   q=await pg.evaluate('()=>JSON.parse(localStorage.getItem("okd_drv_queue:u-cristian")||"[]")');assert len(q)==1,q
   old_db=await pg.evaluate('(sid)=>JSON.parse(localStorage.getItem("okd_online_demo_v2")).routes2.flatMap(r=>r.stops).find(s=>s.id===sid).outcome',sid);assert old_db=='PENDIENTE',old_db
   use(NEW);await pg.reload();await pg.wait_for_timeout(3000)
   assert await pg.evaluate('()=>JSON.parse(localStorage.getItem("okd_drv_queue:u-cristian")||"[]")')==q
   assert await blob(pg)=='PENDIENTE-QA-NO-BORRAR'
   await ctx.set_offline(False);await pg.reload();await newid(pg)
   await pg.wait_for_function('()=>JSON.parse(localStorage.getItem("okd_drv_queue:u-cristian")||"[]").length===0',timeout=30000)
   after=await state(pg)
   assert after['me']==before['me'] and after['cfg']==before['cfg'] and not after['pin'],(before,after)
   assert await blob(pg)=='PENDIENTE-QA-NO-BORRAR'
   def ops_expr():return '''sid=>{const d=JSON.parse(localStorage.getItem('okd_online_demo_v2'));return {outcome:d.routes2.flatMap(r=>r.stops).find(s=>s.id===sid).outcome,ops:Object.entries(d.ops||{}).filter(([k,v])=>v===sid).map(([k])=>k)}}'''
   applied=await pg.evaluate(ops_expr(),sid);assert applied['outcome']=='NO_ENTREGADO' and applied['ops']==[q[0]['op_id']],applied
   for _ in range(2):await pg.evaluate('()=>window.dispatchEvent(new Event("online"))');await pg.wait_for_timeout(700)
   assert await pg.evaluate(ops_expr(),sid)==applied
   await pg.screenshot(path=str(OUT/'updated-offline-queue.png'));results.append({'test':'actual update preserves PIN/session/IDB; native offline queue sync exactly once','pass':True,'before':before,'after':after,'applied':applied});print('PASS OFFLINE: real queued UI operation, same user/PIN, IndexedDB preserved, exactly one application',flush=True);await ctx.close()
   use(OLD);ctx=await mk('profile-pin');pg=ctx.pages[0];await dp.login(pg,'gabriel@okdespacho.demo');await ready(pg)
   before=await state(pg);assert before['cfg'],before
   await pg.evaluate('()=>localStorage.setItem("okd_pin_v1_u-gabriel_last",JSON.stringify({at:0,day:"2000-01-01"}))')
   await pg.reload();await pg.wait_for_selector('#pinGate');use(NEW);await pg.reload();await newid(pg);await pg.wait_for_timeout(22000)
   during=await state(pg);assert during['pin'] and during['boot']=='PIN' and during['cfg']==before['cfg'] and during['me']==before['me'],during
   await pg.fill('#pinA','123456');await pg.click('#pinGo');await pg.wait_for_function('()=>!document.querySelector("#pinGate")&&window.OKD_BOOTED',timeout=15000)
   after=await state(pg);assert after['me']==before['me'] and after['cfg']==before['cfg'],after
   results.append({'test':'valid original PIN survives update, gate waits, unlock succeeds without password/login','pass':True,'before':before,'during':during,'after':after});print('PASS PIN: original PBKDF2 config preserved; valid PIN unlocks after update; session intact',flush=True);await pg.screenshot(path=str(OUT/'updated-pin-unlocked.png'));await ctx.close()
  finally:srv.shutdown()
 (OUT/'results.json').write_text(json.dumps(results,indent=2));print('TOTAL 2/2 real browser upgrade scenarios PASS',flush=True)
if __name__=='__main__':asyncio.run(main())
