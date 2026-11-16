import asyncio,json,os,threading,tempfile
from pathlib import Path
from http.server import ThreadingHTTPServer,SimpleHTTPRequestHandler
from playwright.async_api import async_playwright
ROOT=Path(__file__).resolve().parents[1]
class H(SimpleHTTPRequestHandler):
 def __init__(self,*a,**kw):super().__init__(*a,directory=str(ROOT),**kw)
 def log_message(self,*a):pass
async def main():
 srv=ThreadingHTTPServer(('127.0.0.1',0),H);threading.Thread(target=srv.serve_forever,daemon=True).start();checks=[]
 module=os.environ.get('INGEST_MODULE','/commercialaudit/original/com-ingest.js')
 async with async_playwright() as p:
  b=await p.chromium.launch(executable_path=os.environ['CHROMIUM_PATH'])
  for mode in ['network','forbidden','session','two_dates']:
   ctx=await b.new_context();pg=await ctx.new_page();await pg.goto(f'http://127.0.0.1:{srv.server_port}/commercialaudit/')
   result=await pg.evaluate('''async ({module,mode})=>{
    const {installComIngest}=await import(module);let user='user-a',fail=true,calls=[];
    const api={me:async()=>({id:user,status:'ACTIVO'}),comIngest:async(k,m,r)=>{calls.push({user,hash:m.hash,date:m.loaded_at});if(fail)throw Object.assign(new Error(mode==='forbidden'?'FORBIDDEN':'NETWORK'),{code:mode==='forbidden'?'42501':'OFFLINE'});return {status:'OK'};},comIngestError:async()=>{}};
    const inst=installComIngest(api);const data={meta:{fileName:'same.xlsx',loadedAt:'2026-11-10T12:00:00Z'},records:[{c:'QA',cuit:'30500010912',comp:'FAC A 1-1',n:'FACA11',d:'2026-10-01',m:100,s:100}]};
    if(mode==='two_dates'){fail=false;await inst.ingest('sc',data);data.meta.loadedAt='2026-11-11T12:00:00Z';await inst.ingest('sc',data);return {calls,distinct:new Set(calls.map(x=>x.hash)).size};}
    await inst.ingest('sc',data);let before=(await inst.storage.keys()).length;
    if(mode==='session'){user='user-b';fail=false;await inst.flush();return {before,after:(await inst.storage.keys()).length,sentAs:calls.at(-1).user};}
    if(mode==='restart')return {before};
    fail=false;await inst.flush();return {before,after:(await inst.storage.keys()).length};
   }''',{'module':module,'mode':mode})
   ok=result.get('distinct')==2 if mode=='two_dates' else result.get('before')==1 and (result.get('after')==1 if mode=='session' else result.get('after',0)==0)
   checks.append({'case':mode,'pass':ok,'result':result});await ctx.close()
  await b.close()
 srv.shutdown();tag=os.environ.get('TAG','original');(ROOT/f'commercialaudit/results/{tag}_ingest_browser.json').write_text(json.dumps(checks,indent=2));print(json.dumps(checks,indent=2))
asyncio.run(main())
