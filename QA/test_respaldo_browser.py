"""SOLO PRUEBAS LOCALES (demo + Constructor REAL) · Respaldo privado de ORIGINALES (A-09) en el navegador del Operario.
Sin pantalla nueva: el Operario carga como siempre; con el respaldo encendido el original se sube PRIVADO, se registra y la carga queda
vinculada; ante fallas la tarea se conserva CON su original; el mismo archivo no crea versiones ni duplica comprobantes."""
import asyncio, os, sys, json, socket, traceback
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tests/e2e'))
import run_driver_perfiles as dp
import run_com_ingesta_constructor as ic
from playwright.async_api import async_playwright
s = socket.socket(); s.bind(('127.0.0.1', 0)); dp.PORT = s.getsockname()[1]; s.close(); dp.DIST = str(Path(__file__).resolve().parents[1] / 'dist-demo')
K = 'okd_online_demo_v2'; R = []
def res(n, ok, d=''): R.append({'name': n, 'pass': bool(ok), 'detail': d}); print(('PASS' if ok else 'FAIL') + ' | ' + n + ' | ' + json.dumps(d, ensure_ascii=False)[:300], flush=True)
COM = '()=>{const c=(JSON.parse(localStorage.getItem("%s"))||{}).com||{}; const g=(c.ingests||[]).filter(i=>/_qa\\.xlsx$/.test(i.file_name||"")); return {ingestas:g.map(i=>({k:i.kind,st:i.status,src:i.source_file_id||null})), fuentes:(c.sources||[]).map(f=>f.kind+":v"+f.version+":"+f.sha256.slice(0,8)), guardados:Object.keys(c.storage||{}).length, docs:Object.keys(c.docs||{}).length}}' % K
PEND = 'async()=>new Promise(ok=>{const r=indexedDB.open("okd-com-ingest",1); r.onupgradeneeded=()=>r.result.createObjectStore("jobs",{keyPath:"hash"}); r.onsuccess=()=>{const t=r.result.transaction("jobs","readonly").objectStore("jobs").getAll(); t.onsuccess=()=>ok(t.result.map(j=>({kind:j.kind, original:!!j.original, size:j.originalSize, src:j.sourceFileId||null, err:(j.lastError||"").slice(0,60)})))}; r.onerror=()=>ok(-1)})'
async def settings(pg, p):
    await pg.evaluate('(p)=>{const d=JSON.parse(localStorage.getItem("%s")); d.com.settings=Object.assign(d.com.settings,p); localStorage.setItem("%s", JSON.stringify(d));}' % (K, K), p)
async def flush(pg): await pg.evaluate('()=>window.dispatchEvent(new Event("okd-com-captured"))'); await pg.wait_for_timeout(3500)
async def main():
    ic.preparar(); srv = dp.serve()
    try:
        async with async_playwright() as p:
            b = await p.chromium.launch(executable_path=os.environ['CHROMIUM_PATH'])
            try:
                pg = await (await b.new_context(viewport={'width': 1366, 'height': 860})).new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
                await pg.goto(f'http://127.0.0.1:{dp.PORT}/'); await pg.evaluate('()=>localStorage.clear()'); await dp.login(pg, 'operario@okdespacho.demo')
                await pg.evaluate('async()=>{await window.OKD_ONLINE.api.comConfig()}')
                await ic.load(pg); c0 = await pg.evaluate(COM); p0 = await pg.evaluate(PEND)
                res('RB-01 respaldo APAGADO (por defecto): la carga del Constructor llega al historial SIN subir originales; nada pendiente', len(c0['ingestas']) == 2 and all(x['st'] == 'OK' and not x['src'] for x in c0['ingestas']) and c0['guardados'] == 0 and p0 == [], {**c0, 'pendientes': p0})
                await pg.evaluate('()=>{const d=JSON.parse(localStorage.getItem("%s")); d.com.ingests=[]; d.com.docs={}; d.com.cc=[]; localStorage.setItem("%s", JSON.stringify(d));}' % (K, K))
                await settings(pg, {'source_backup_enabled': True}); await pg.evaluate('()=>{location.hash="#/dashboard"}'); await pg.wait_for_timeout(600)
                await ic.load(pg); c1 = await pg.evaluate(COM); p1 = await pg.evaluate(PEND)
                res('RB-02 respaldo ENCENDIDO: el Operario carga IGUAL; cada original (SC y CC) se sube PRIVADO, queda registrado como versión 1 y su carga VINCULADA; la tarea se borra solo tras confirmar',
                    len(c1['ingestas']) == 2 and all(x['st'] == 'OK' and x['src'] for x in c1['ingestas']) and sorted(f[:5] for f in c1['fuentes']) == ['CC:v1', 'SC:v1'] and c1['guardados'] == 2 and p1 == [], {**c1, 'pendientes': p1})
                # sin conexión: la tarea se conserva CON su original; al volver, se completa
                await pg.evaluate('()=>{const d=JSON.parse(localStorage.getItem("%s")); d.com.ingests=[]; d.com.docs={}; d.com.cc=[]; localStorage.setItem("%s", JSON.stringify(d));}' % (K, K))
                await pg.evaluate('()=>{window.OKD_COM_INGEST_FAIL=true}'); await pg.evaluate('()=>{location.hash="#/dashboard"}'); await pg.wait_for_timeout(600)
                await pg.evaluate('()=>{RouteStore.data.sc.meta.loadedAt=new Date().toISOString()}')
                await ic.load(pg); p2 = await pg.evaluate(PEND)
                await pg.evaluate('()=>{window.OKD_COM_INGEST_FAIL=false}'); await flush(pg); p3 = await pg.evaluate(PEND); c3 = await pg.evaluate(COM)
                res('RB-03 SIN CONEXIÓN: la tarea queda PENDIENTE con su ORIGINAL (no se pierde ni se borra); al volver la conexión se completa y RECIÉN entonces se borra; sin versiones nuevas (mismo contenido)',
                    len(p2) >= 1 and all(j['original'] for j in p2) and p3 == [] and all(x['st'] == 'OK' and x['src'] for x in c3['ingestas']) and sorted(f[:5] for f in c3['fuentes']) == ['CC:v1', 'SC:v1'], {'pendientes': p2, 'despues': p3, 'fuentes': c3['fuentes']})
                d4 = c3['docs']; await pg.evaluate('()=>{location.hash="#/dashboard"}'); await pg.wait_for_timeout(600); await ic.load(pg); c4 = await pg.evaluate(COM)
                res('RB-04 el MISMO archivo otra vez (otro día): ninguna versión nueva del original y ningún comprobante duplicado', c4['docs'] == d4 and sorted(f[:5] for f in c4['fuentes']) == ['CC:v1', 'SC:v1'], {'docs': [d4, c4['docs']], 'fuentes': c4['fuentes']})
                await settings(pg, {'source_max_mb': 1}); await pg.evaluate('()=>{location.hash="#/dashboard"}'); await pg.wait_for_timeout(600)
                big = await pg.evaluate('async()=>{const blob=new Blob([new Uint8Array(2*1048576)],{type:"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"}); const f=new File([blob],"saldo_comprobante_grande.xlsx",{type:blob.type});'
                    'await window.OKD_COM_INGEST("sc",{meta:{fileName:"saldo_comprobante_grande.xlsx",loadedAt:new Date().toISOString()},records:[{c:"QA",cuit:"30710000014",comp:"FAC A 0099-00000001",d:"2026-11-01",m:10,s:10}]},f); return 1}')
                await flush(pg); p5 = await pg.evaluate(PEND)
                res('RB-05 ORIGINAL DEMASIADO GRANDE: la tarea queda PENDIENTE con su original y el motivo (FILE_TOO_LARGE); nunca se descarta en silencio', any(j['original'] and 'FILE_TOO_LARGE' in j['err'] for j in p5), p5)
            finally: await b.close()
    finally: srv.terminate()
    ok = sum(r['pass'] for r in R); print('TOTAL', ok, '/', len(R)); Path('QA/results').mkdir(parents=True, exist_ok=True); Path('QA/results/respaldo_browser.json').write_text(json.dumps(R, ensure_ascii=False, indent=1))
    sys.exit(0 if ok == len(R) == 5 else 1)
try: asyncio.run(main())
except Exception: traceback.print_exc(); sys.exit(2)
