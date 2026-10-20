"""Verificación en Chromium del service worker de Web Push (CDP ServiceWorker.deliverPushMessage). NO reemplaza la prueba en celular real."""
import asyncio, subprocess, time, json
from playwright.async_api import async_playwright
async def main():
    s = subprocess.Popen(['npx','vite','preview','--port','4197','--strictPort','--host','localhost'], cwd=__import__('os').path.abspath(__import__('os').path.join(__import__('os').path.dirname(__file__), '..', '..')), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); time.sleep(2.5)
    out = {}
    try:
        async with async_playwright() as p:
            b = await p.chromium.launch(executable_path='/opt/pw-browsers/chromium-1194/chrome-linux/chrome')
            ctx = await b.new_context(); await ctx.grant_permissions(['notifications'], origin='http://localhost:4197'); pg = await ctx.new_page()
            await pg.goto('http://localhost:4197/'); await pg.wait_for_timeout(2500)
            out['sw'] = await pg.evaluate('async()=>{const r=await navigator.serviceWorker.ready; return !!(r && r.active)}')
            out['perm'] = await pg.evaluate('()=>Notification.permission')
            out['caps'] = await pg.evaluate("()=>({sw:'serviceWorker' in navigator, push:'PushManager' in window, notif:'Notification' in window})")
            cdp = await ctx.new_cdp_session(pg)
            regs = []
            cdp.on('ServiceWorker.workerRegistrationUpdated', lambda e: regs.extend(e['registrations']))
            await cdp.send('ServiceWorker.enable'); await pg.wait_for_timeout(800)
            rid = regs[0]['registrationId'] if regs else None; out['registration'] = bool(rid)
            payload = json.dumps({'title':'NUEVA HOJA PUBLICADA','body':'Hoja 03-000123 · 3 entregas','tag':'okd-n1','data':{'url':'http://localhost:4197/#/mis-hojas?route=abc','type':'NUEVA_HOJA_PUBLICADA'}})
            await cdp.send('ServiceWorker.deliverPushMessage', {'origin':'http://localhost:4197','registrationId':rid,'data':payload})
            await pg.wait_for_timeout(1200)
            out['shown'] = await pg.evaluate('async()=>{const r=await navigator.serviceWorker.ready; const n=await r.getNotifications(); return n.map(x=>({t:x.title,b:x.body,tag:x.tag,url:x.data&&x.data.url}))}')
            await cdp.send('ServiceWorker.deliverPushMessage', {'origin':'http://localhost:4197','registrationId':rid,'data':payload}); await pg.wait_for_timeout(800)
            out['same_tag_count'] = await pg.evaluate('async()=>{const r=await navigator.serviceWorker.ready; return (await r.getNotifications({tag:"okd-n1"})).length}')
            await b.close()
    finally: s.terminate()
    R = [('PUSH-SW-01', 'Service worker activo con PushManager y Notification disponibles', out.get('sw') and all(out.get('caps', {}).values())),
         ('PUSH-SW-02', 'Un push entregado al service worker muestra la notificación con título, texto y URL de destino', out.get('shown') == [{'t': 'NUEVA HOJA PUBLICADA', 'b': 'Hoja 03-000123 · 3 entregas', 'tag': 'okd-n1', 'url': 'http://localhost:4197/#/mis-hojas?route=abc'}]),
         ('PUSH-SW-03', 'El mismo aviso recibido dos veces no se duplica en pantalla (misma etiqueta)', out.get('same_tag_count') == 1)]
    for n, t, ok in R: print(n, '|', t, '|', 'PASS' if ok else 'FAIL', '|', json.dumps(out, ensure_ascii=False)[:120] if not ok else '')
    print('TOTAL', sum(1 for r in R if r[2]), 'PASS /', sum(1 for r in R if not r[2]), 'FAIL')
    return R
EXPECTED = 3
OK = lambda r: bool(r[2])
if __name__ == '__main__':
    # 0 = todo PASS · 1 = alguna comprobación FAIL · 2 = excepción, preparación fallida o menos casos de los esperados
    import sys, traceback
    try: RR = asyncio.run(main())
    except SystemExit: raise
    except Exception as e: traceback.print_exc(); print('ERROR: la prueba no pudo completarse:', repr(e)); sys.exit(2)
    if not RR or len(RR) < EXPECTED: print('ERROR: se ejecutaron %d de %d comprobaciones esperadas' % (len(RR or []), EXPECTED)); sys.exit(2)
    sys.exit(1 if any(OK(r) is not True for r in RR) else 0)


