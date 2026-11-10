"""E2E BLOQUEANTE (modo demo, Chromium Android) · V4.28 · documento del receptor DNI / CUIL / CUIT en el FORMULARIO REAL del chofer:
tipo + número, validación por tipo, firma con el dedo, Recibido Conforme y constancia. Datos FICTICIOS. Uso: python3 run_v428_documento.py [dist-demo] [salida]"""
import asyncio, os, sys, traceback
sys.path.insert(0, os.path.dirname(__file__))
import run_driver_perfiles as dp
from playwright.async_api import async_playwright
dp.PORT = 4491; R = []; EXPECTED = 11
if len(sys.argv) > 1: dp.DIST = sys.argv[1]
OUT = sys.argv[2] if len(sys.argv) > 2 else '/tmp/okd_v428_doc'
K = 'okd_online_demo_v2'
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:340])); print('..', ' | '.join(R[-1]), flush=True)
PUB = '''async(k)=>{const A=window.OKD_ONLINE.api, st=(n,o)=>({ready:true, client_name:n, client_key:n.toUpperCase(), address:'Godoy Cruz '+o, zone:'ESTE', stop_type:'PEDIDO', order_numbers:[String(o)], merchandise_amount:1000, shipping_fee:0, task:'ENTREGA', expected_amount:1000});
  return (await A.publishRoute({sheet_key:k, carrier_id:'CT-ESTE', responsable_id:'u-cristian', rules_version:1, routing_rules_version:1, stops:[st('Cliente DNI QA',9601), st('Persona CUIL QA',9602), st('Empresa CUIT QA',9603), st('Tipo equivocado QA',9604), st('Sin documento QA',9605), st('Documento válido QA',9606), st('Sin firma QA',9607), st('Alfanumérico QA',9608), st('Empresa CUIT válido QA',9609)]})).id}'''
async def deliver(q, sid, doctype, number, email=None, action='continuar', fix=None, sign=True):
    """elige ENTREGADO, completa nombre, tipo y número, firma y guarda; si aparece el aviso del documento: CONTINUAR o CORREGIR (fix=(tipo, número))"""
    f = q.locator(f'.drv-stop[data-s="{sid}"]')
    if not await f.locator('.drv-form[data-o="ENTREGADO"]:visible').count(): await f.locator('button.drv-result-btn[data-o="ENTREGADO"]').click(); await q.wait_for_timeout(500)
    await f.locator('[data-f="recv"]').fill('Receptor QA'); await f.locator('[data-f="doctype"]').select_option(doctype)
    if email: await f.locator('[data-f="email"]').fill(email)
    await f.locator('[data-f="cuil"]').fill(number); await f.locator('[data-f="cuil"]').press('Tab'); await q.wait_for_timeout(250)
    if sign: await dp.sign(q, sid)
    await f.locator('[data-save]').click(); await q.wait_for_timeout(1200)
    aviso = await f.locator('[data-docwarn]').count() > 0; txt = await f.locator('[data-docwarn]').inner_text() if aviso else ''
    botones = aviso and await f.locator('[data-docwarn] [data-docfix]').count() == 1 and await f.locator('[data-docwarn] [data-docgo]').count() == 1
    if aviso and action == 'continuar': await f.locator('[data-docgo]').click(); await q.wait_for_timeout(1700)
    if aviso and action == 'corregir':
        await f.locator('[data-docfix]').click(); await q.wait_for_timeout(200)
        await f.locator('[data-f="doctype"]').select_option(fix[0]); await f.locator('[data-f="cuil"]').fill(fix[1]); await f.locator('[data-save]').click(); await q.wait_for_timeout(1700)
    outcome = await q.evaluate('(sid)=>JSON.parse(localStorage.getItem("%s")).routes2.flatMap(r=>r.stops).find(s=>s.id===sid).outcome' % K, sid)
    err = await q.evaluate('(sid)=>{const b=document.querySelector(\'.drv-stop[data-s="\'+sid+\'"]\'); const m=b&&b.querySelector(".drv-ferr:not([hidden]),.drv-msg.err,.up-msg.err"); return m?m.textContent:""}', sid)
    pantalla = await q.evaluate('(sid)=>{const b=document.querySelector(\'.drv-stop[data-s="\'+sid+\'"]\'); return b?b.innerText.replace(/\\s+/g," "):""}', sid)
    return {'aviso': aviso, 'botones': botones, 'texto_aviso': txt.replace('\n', ' '), 'resultado': outcome, 'error': err[:120], 'falta_firma': 'Falta la firma' in pantalla, 'otro_aviso': await f.locator('[data-docwarn]').count() > 0 if outcome == 'PENDIENTE' else False}
async def main():
    os.makedirs(OUT, exist_ok=True); srv = dp.serve()
    try:
        async with async_playwright() as p:
            b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
            try:
                c0 = await b.new_context(viewport={'width': 1366, 'height': 768}); pg = await c0.new_page()
                await pg.goto(f'http://127.0.0.1:{dp.PORT}/'); await pg.evaluate('()=>localStorage.clear()'); await dp.login(pg, 'admin@okdespacho.demo'); rid = await pg.evaluate(PUB, 'qa-v428-doc'); state = await c0.storage_state(); await c0.close()
                c = await b.new_context(storage_state=state, viewport={'width': 412, 'height': 915}, is_mobile=True, has_touch=True, geolocation={'latitude': -32.9, 'longitude': -68.8}, permissions=['geolocation'])
                q = await c.new_page(); q.on('dialog', lambda d: asyncio.ensure_future(d.accept())); await dp.login(q, 'cristian@okdespacho.demo'); await dp.open_route(q, rid)
                S = [await dp.stop_id(q, rid, i) for i in range(9)]; s0 = S[0]
                ev = lambda sid: q.evaluate('(sid)=>{const d=JSON.parse(localStorage.getItem("%s")); const e=d.evidence[sid]||{}, v=(d.docReviews||{})[sid]; return {tipo:e.receiver_doc_type||null, declarado:e.receiver_doc_declared||null, valido:e.receiver_doc_valid, cuil:e.cuil||null, cuit:e.receiver_cuit||null, dni:e.receiver_dni||null, firma:!!e.signature_png_b64, incidencia:v?v.issue:null}}' % K, sid)
                AV = 'necesita revisión'
                r0 = await deliver(q, S[0], 'DNI', '123', email='compras@cliente.qa'); e0 = await ev(S[0]); await q.screenshot(path=os.path.join(OUT, 'aviso_documento_android.png'))
                res('DOC-01 DNI INVÁLIDO («123»): aparece el aviso con CORREGIR / CONTINUAR; al CONTINUAR la entrega queda CONFIRMADA con su incidencia; el DNI NO se guarda como verificado',
                    r0['aviso'] and r0['botones'] and AV in r0['texto_aviso'] and 'Administración recibirá una alerta' in r0['texto_aviso'] and r0['resultado'] == 'ENTREGADO' and e0['declarado'] == '123' and e0['valido'] is False and not e0['dni'] and e0['incidencia'] == 'DNI CON CANTIDAD DE DÍGITOS INCORRECTA', {**r0, 'evidencia': e0})
                r1 = await deliver(q, S[1], 'CUIL', '20-12345678-7'); e1 = await ev(S[1])
                res('DOC-02 CUIL con VERIFICADOR INCORRECTO: aviso → CONTINUAR → entrega CONFIRMADA + incidencia; declarado tal cual, sin CUIL verificado', r1['aviso'] and r1['resultado'] == 'ENTREGADO' and e1['declarado'] == '20-12345678-7' and not e1['cuil'] and e1['incidencia'] == 'CUIL CON DÍGITO VERIFICADOR INVÁLIDO', {**r1, 'evidencia': e1})
                r2 = await deliver(q, S[2], 'CUIT', '3050001091'); e2 = await ev(S[2])
                res('DOC-03 CUIT INVÁLIDO (10 dígitos): aviso → CONTINUAR → entrega CONFIRMADA + incidencia', r2['aviso'] and r2['resultado'] == 'ENTREGADO' and e2['incidencia'] == 'CUIT CON CANTIDAD DE DÍGITOS INCORRECTA', {**r2, 'evidencia': e2})
                r3 = await deliver(q, S[3], 'DNI', '20123456786', action='corregir', fix=('CUIL', '20123456786')); e3 = await ev(S[3])
                res('DOC-04 TIPO EQUIVOCADO (DNI con 11 dígitos): advertencia SIN bloqueo; CORREGIR DOCUMENTO → CUIL → entrega confirmada SIN incidencia y sin repetir la firma', r3['aviso'] and 'CUIL o CUIT' in r3['texto_aviso'] and r3['resultado'] == 'ENTREGADO' and e3['tipo'] == 'CUIL' and e3['valido'] is True and not e3['incidencia'] and e3['firma'], {**r3, 'evidencia': e3})
                r4 = await deliver(q, S[4], 'DNI', ''); e4 = await ev(S[4])
                res('DOC-05 documento FALTANTE: aviso → CONTINUAR → entrega CONFIRMADA + incidencia «DOCUMENTO FALTANTE»', r4['aviso'] and r4['resultado'] == 'ENTREGADO' and e4['incidencia'] == 'DOCUMENTO FALTANTE', {**r4, 'evidencia': e4})
                r5 = await deliver(q, S[5], 'DNI', '30.111.222'); e5 = await ev(S[5])
                res('DOC-06 documento VÁLIDO: SIN aviso, entrega confirmada SIN incidencia (DNI verificado)', not r5['aviso'] and r5['resultado'] == 'ENTREGADO' and e5['valido'] is True and e5['dni'] == '30111222' and not e5['incidencia'], {**r5, 'evidencia': e5})
                r6 = await deliver(q, S[6], 'DNI', '30111222', sign=False)
                res('DOC-07 la FIRMA sigue OBLIGATORIA: sin firma la entrega NO se confirma (aunque el documento sea válido)', r6['resultado'] == 'PENDIENTE' and r6['falta_firma'] and not r6['aviso'], r6)
                r8 = await deliver(q, S[7], 'DNI', '30.111.222A'); e8 = await ev(S[7])
                res('DOC-09 ALFANUMÉRICO «30.111.222A»: aviso (letras u otros caracteres) → CONTINUAR → entrega CONFIRMADA + incidencia «DOCUMENTO CON CARACTERES NO VÁLIDOS»; declarado guardado TAL CUAL',
                    r8['aviso'] and 'solo números' in r8['texto_aviso'] and r8['resultado'] == 'ENTREGADO' and e8['declarado'] == '30.111.222A' and e8['valido'] is False and not e8['dni'] and e8['incidencia'] == 'DOCUMENTO CON CARACTERES NO VÁLIDOS', {**r8, 'evidencia': e8})
                r9 = await deliver(q, S[8], 'CUIT', '30-50001091-2'); e9 = await ev(S[8])
                ids = await q.evaluate('()=>Object.keys(JSON.parse(localStorage.getItem("%s")).identity||{})' % K)
                res('DOC-10 CUIT VÁLIDO de empresa: sin aviso, confirmado y guardado en SU campo (nunca como CUIL); NO crea un perfil de identidad PERSONAL (el CUIL válido de DOC-04 sí)',
                    not r9['aviso'] and r9['resultado'] == 'ENTREGADO' and e9['tipo'] == 'CUIT' and e9['valido'] is True and e9['cuit'] == '30500010912' and not e9['cuil'] and '30500010912' not in ids and '20123456786' in ids, {**r9, 'evidencia': e9, 'padron_identidad': ids})
                state = await c.storage_state(); await c.close()   # la base de la demo DESPUÉS de las entregas
                # firma y comprobantes: firma guardada, Recibido Conforme encolado con el email, constancia con «DNI 30111222»
                c3 = await b.new_context(storage_state=state, viewport={'width': 1366, 'height': 768}); a = await c3.new_page(); await a.goto(f'http://127.0.0.1:{dp.PORT}/'); await dp.login(a, 'admin@okdespacho.demo')
                jobs = await a.evaluate('(sid)=>(JSON.parse(localStorage.getItem("%s")).customerJobs||[]).filter(j=>j.stop_id===sid).map(j=>({kind:j.kind, to:j.recipient||j.to}))' % K, s0)
                tr = await a.evaluate('async(sid)=>{const t=await window.OKD_ONLINE.api.deliveryTrace(sid); return {firma:!!(t.evidence&&t.evidence.signature_png), valido:t.evidence&&t.evidence.receiver_doc_valid, declarado:t.evidence&&t.evidence.receiver_doc_declared}}', s0)
                await a.evaluate('()=>{location.hash="#/historial"}'); await a.wait_for_timeout(1300); await a.click('[data-htab="search"]'); await a.fill('#bsQ', '9601'); await a.press('#bsQ', 'Enter'); await a.wait_for_timeout(900)
                card = await a.evaluate('()=>(document.querySelector("#bsRes .bs-res")||{}).innerText||""')
                await a.fill('#bsQ', '9609'); await a.press('#bsQ', 'Enter'); await a.wait_for_timeout(900); card_cuit = await a.evaluate('()=>(document.querySelector("#bsRes .bs-res")||{}).innerText||""'); await c3.close()
                res('DOC-08 COMPROBANTES: firma guardada, Recibido Conforme encolado al email y la constancia/buscador muestran el documento «DNI 123 (A REVISAR)», nunca como verificado',
                    tr['firma'] and tr['valido'] is False and any(j['to'] == 'compras@cliente.qa' for j in jobs) and 'DNI 123 (A REVISAR)' in card, {'traza': tr, 'recibido_conforme': jobs, 'tarjeta': card.replace(chr(10), ' ')[:170]})
                res('DOC-11 RÓTULOS: el buscador muestra la entrega con CUIT como «CUIT 30500010912» (nunca como CUIL)', 'CUIT 30500010912' in card_cuit and 'CUIL 30500010912' not in card_cuit, card_cuit.replace(chr(10), ' ')[:170])
            finally: await b.close()
    finally: srv.terminate()
    print('TOTAL', sum(1 for r in R if r[1] == 'PASS'), 'PASS /', sum(1 for r in R if r[1] == 'FAIL'), 'FAIL · esperados', EXPECTED)
    return R
if __name__ == '__main__':
    try: rr = asyncio.run(main())
    except Exception as e: traceback.print_exc(); print('ERROR:', repr(e)); sys.exit(2)
    if len(rr) != EXPECTED: print('ERROR: se ejecutaron %d de %d' % (len(rr), EXPECTED)); sys.exit(2)
    sys.exit(1 if any(r[1] != 'PASS' for r in rr) else 0)
