"""E2E (modo demo, Chromium) · Comunicaciones internas en COMPUTADORA y ANDROID emulado (Pixel 7). Controles reales, datos FICTICIOS y Gmail
SIMULADO (la demo nunca envía correos reales). Exit 0 todo PASS · 1 alguna FAIL · 2 error de preparación o casos faltantes."""
import asyncio, os, sys, json, traceback, datetime
sys.path.insert(0, os.path.dirname(__file__))
import run_cambiar_rol as cr
from playwright.async_api import async_playwright
cr.PORT = 4393; R = []; EXPECTED = 21; SHOTS = sys.argv[2] if len(sys.argv) > 2 else '/tmp/okd_comms_shots'; CK = 'okd_comms_demo_v1'
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:260])); print('..', ' | '.join(R[-1]), flush=True)
art_today = (datetime.datetime.utcnow() - datetime.timedelta(hours=3)).date()
MON = art_today + datetime.timedelta(days=(7 - art_today.weekday()) or 7)   # próximo lunes (como el ejemplo)
MON_0901 = int(datetime.datetime(MON.year, MON.month, MON.day, 12, 1, tzinfo=datetime.timezone.utc).timestamp() * 1000)   # 09:01 Buenos Aires
PDF = b'%PDF-1.4\n1 0 obj<<>>endobj\ntrailer<<>>\n%%EOF\n'; EXE = b'MZ\x90\x00' + b'\x00' * 60
async def comms(pg, sec=''):
    await pg.evaluate('()=>{location.hash="#/"}'); await pg.wait_for_timeout(500); await pg.evaluate(f'()=>{{location.hash="#/comunicaciones{sec}"}}'); await pg.wait_for_timeout(1800); await cr.dismiss(pg)
async def db(pg): return await pg.evaluate(f'()=>JSON.parse(localStorage.getItem("{CK}"))')
async def item(pg, name): return pg.locator('.comms-item', has_text=name).first
async def main():
    os.makedirs(SHOTS, exist_ok=True)
    for n, b in (('nota.pdf', PDF), ('factura.pdf', EXE)): open(os.path.join(SHOTS, n), 'wb').write(b)
    srv = cr.serve()
    try:
        async with async_playwright() as p:
          b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
          try:
            ctx = await b.new_context(**cr.DESK); await ctx.grant_permissions(['clipboard-read', 'clipboard-write'], origin=f'http://127.0.0.1:{cr.PORT}')
            pg = await ctx.new_page(); dlg = []; pg.on('dialog', lambda d: (dlg.append(d.message), asyncio.ensure_future(d.accept())))
            await pg.goto(f'http://127.0.0.1:{cr.PORT}/'); await pg.evaluate('()=>localStorage.clear()'); await cr.login(pg, 'admin@okdespacho.demo')
            menu = await pg.evaluate('()=>[...document.querySelectorAll("a[href=\\"#/comunicaciones\\"]")].length')
            await comms(pg); ej = await (await item(pg, 'EJEMPLO')).inner_text()
            await pg.screenshot(path=os.path.join(SHOTS, 'computadora_comunicados.png'))
            res('CM-01 menú "Comunicaciones" y ejemplo FICTICIO en BORRADOR (lunes 9:00, con infografía); aviso de Gmail sin conectar', menu >= 1 and 'Borrador' in ej and 'Cada lunes a las 09:00' in ej
                and '1 adjunto' in ej and await pg.locator('#cmNoGmail').count() == 1, ej[:160])
            # ----- colaboradores con controles reales -----
            await pg.click('[data-ctab="COLAB"]'); await pg.wait_for_timeout(800); await pg.click('#colNew')
            for k, v in {'cfName': 'Nueva Persona QA', 'cfEmail': 'nueva.qa@ejemplo.test', 'cfPhone': '+54 9 261 555-0199', 'cfBranch': 'San Juan', 'cfSector': 'Cobranzas'}.items(): await pg.fill('#' + k, v)
            await pg.click('#cfSave'); await pg.wait_for_timeout(1000); await pg.click('#colNew')
            for k, v in {'cfName': 'Duplicada QA', 'cfEmail': 'LAURA.GOMEZ@ejemplo.test'}.items(): await pg.fill('#' + k, v)
            await pg.click('#cfSave'); await pg.wait_for_timeout(800); dup = await pg.locator('#cmMsg').inner_text()
            res('CM-02 colaborador nuevo con controles reales; correo repetido rechazado', await pg.locator('#colTable tr', has_text='Nueva Persona QA').count() == 1 and 'Ya hay un colaborador' in dup, dup)
            # ----- editor: destinatarios, programación, sanitización, adjuntos -----
            await pg.click('[data-ctab="MSGS"]'); await pg.wait_for_timeout(800); await (await item(pg, 'EJEMPLO')).locator('[data-act="edit"]').click(); await pg.wait_for_timeout(900)
            await pg.check('[data-branch][value="Mendoza"]'); await pg.locator('details.comms-sel summary').click(); await pg.check('[data-person][value="col-1"]'); await pg.wait_for_timeout(300)
            fin = await pg.evaluate('()=>[...document.querySelectorAll("#edFinalList li")].map(l=>l.textContent)'); fin_txt = await pg.locator('#edFinal').inner_text()
            res('CM-03 lista final: cada persona UNA vez aunque coincidan varios criterios; el inactivo queda fuera con motivo', len(fin) == len(set(f.split(' · ')[1].split(' ')[0] for f in fin)) and len(fin) == 6
                and 'Pablo Díaz (ficticio, inactivo) (Inactivo)' in fin_txt and any('Laura Gómez' in f and 'individual' in f and 'sucursal Mendoza' in f for f in fin), {'n': len(fin), 'excluidos': fin_txt[-80:]})
            nxt = await pg.evaluate('()=>[...document.querySelectorAll("#edNextList li")].map(l=>l.textContent)')
            res('CM-04 programación: próximas ejecuciones los LUNES 09:00 (hora de Argentina)', len(nxt) == 5 and all(x.startswith('lunes ') and x.endswith(' 09:00') for x in nxt) and MON.strftime('%d/%m/%Y') in nxt[0], nxt[:2])
            await pg.evaluate('()=>{ document.getElementById("edBody").innerHTML = "<p onclick=\\"robar()\\">Texto <b>importante</b></p><img src=x onerror=alert(1)><script>alert(2)</script><a href=\\"javascript:alert(3)\\">enlace</a>"; }')
            await pg.set_input_files('#edFile', os.path.join(SHOTS, 'factura.pdf')); await pg.wait_for_timeout(1200); bad = await pg.locator('#cmMsg').inner_text()
            await pg.set_input_files('#edFile', os.path.join(SHOTS, 'nota.pdf')); await pg.wait_for_timeout(1500)
            atts = await pg.evaluate('()=>[...document.querySelectorAll("#edAtts li")].map(l=>l.textContent)'); size = await pg.locator('#edSize').inner_text()
            res('CM-05 adjuntos: un ejecutable renombrado a .pdf se RECHAZA; el PDF real se agrega; límites y tamaño final visibles', 'no coincide con el tipo' in bad and any('nota.pdf' in a for a in atts)
                and not any('factura' in a for a in atts) and 'de 25 MB' in size and '8,0 MB cada uno' in await pg.locator('#edLimits').inner_text(), {'error': bad[:80], 'adjuntos': atts})
            await pg.evaluate('()=>{ document.getElementById("edBody").innerHTML = "<p onclick=\\"robar()\\">Texto <b>importante</b></p><img src=x onerror=alert(1)><script>alert(2)</script><a href=\\"javascript:alert(3)\\">enlace</a>"; }')
            await pg.click('#edSave'); await pg.wait_for_timeout(1200); m = next(x for x in (await db(pg))['messages'] if x['id'] == 'msg-ejemplo')
            res('CM-06 texto con formato SANITIZADO al guardar (sin scripts, eventos ni javascript:)', '<b>importante</b>' in m['body_html'] and not any(k in m['body_html'] for k in ('script', 'onerror', 'onclick', 'javascript', '<img')), m['body_html'])
            await pg.click('#edPreview'); await pg.wait_for_timeout(900)
            pv = await pg.evaluate('()=>{ const f=document.getElementById("pvFrame"); return {sandbox: f.getAttribute("sandbox"), doc: f.getAttribute("srcdoc"), wa: document.getElementById("pvWa").textContent} }')
            await pg.click('.comms-modal [data-mcancel]')
            res('CM-07 vista previa AISLADA (iframe sandbox) con el contenido sanitizado y el texto para WhatsApp', pv['sandbox'] == '' and 'importante' in pv['doc'] and 'script' not in pv['doc'] and '*Recordatorio: normas de cobro*' in pv['wa'], pv['wa'][:80])
            # ----- prueba: en cola; sin Gmail no sale; con Gmail (simulado) sí -----
            await pg.click('#edBack'); await pg.wait_for_timeout(800); await (await item(pg, 'EJEMPLO')).locator('[data-act="test"]').click(); await pg.wait_for_timeout(400)
            await pg.fill('#tmEmail', 'prueba.autorizada@ejemplo.test'); await pg.click('.comms-modal [data-mok]'); await pg.wait_for_timeout(900)
            t0 = await pg.evaluate('async()=>window.OKD_ONLINE.api.commsDemoTick()'); await pg.click('[data-ctab="GMAIL"]'); await pg.wait_for_timeout(700)
            auto0 = await pg.locator('#autoCard').inner_text(); await pg.click('#gmConnect'); await pg.wait_for_timeout(900); await pg.click('#gmTick'); await pg.wait_for_timeout(900)
            d1 = await db(pg); pr = [d for d in d1['deliveries'] if d.get('email') == 'prueba.autorizada@ejemplo.test']
            res('CM-08 ENVIAR PRUEBA: queda en cola; sin Gmail NO sale (SIN_CONEXION); conectado (simulado) sale UNA copia [PRUEBA] con id de Gmail', t0['status'] == 'SIN_CONEXION'
                and 'Simulada (demo)' in auto0 and len(pr) == 1 and pr[0]['status'] == 'ENVIADO' and pr[0]['gmail_message_id'].startswith('simulado-'), {'sin_conexion': t0['status'], 'prueba': pr})
            # ----- programar con lista final y próximas ejecuciones; lunes 9:00 → un correo por persona -----
            await pg.click('[data-ctab="MSGS"]'); await pg.wait_for_timeout(800); await (await item(pg, 'EJEMPLO')).locator('[data-act="activate"]').click(); await pg.wait_for_timeout(700)
            conf = await pg.evaluate('()=>({next: [...document.querySelectorAll("#actNext li")].length, list: [...document.querySelectorAll("#actList li")].length})')
            await pg.click('.comms-modal [data-mok]'); await pg.wait_for_timeout(1000); st = await (await item(pg, 'EJEMPLO')).inner_text()
            msg9 = await pg.evaluate('()=>{ const e=document.getElementById("cmMsg"); return e && !e.hidden ? e.textContent : "" }')
            res('CM-09 PROGRAMAR muestra próximas ejecuciones y la LISTA FINAL antes de confirmar; queda "Programado"', conf == {'next': 5, 'list': 6} and 'Programado' in st and 'próximo: lunes' in ' '.join(st.split()), {'conf': conf, 'item': st[:260], 'mensaje': msg9})
            tick = await pg.evaluate(f'async()=>window.OKD_ONLINE.api.commsDemoTick({MON_0901})')
            d2 = await db(pg); run = [r for r in d2['runs'] if r['kind'] == 'PROGRAMADO']; dl = [x for x in d2['deliveries'] if run and x['run_id'] == run[0]['id'] and x['status'] == 'ENVIADO']
            res('CM-10 lunes 09:01: el programador (simulado) envía UN correo individual por destinatario activo, con la copia del contenido', tick['created'] == 1 and tick['sent'] == 6 and len(dl) == 6
                and len({x['email'] for x in dl}) == 6 and run[0]['snapshot']['attachments'] and 'importante' in run[0]['snapshot']['body_html'], {'resumen': {k: tick[k] for k in ('created', 'sent', 'status')}})
            await (await item(pg, 'EJEMPLO')).locator('[data-act="detail"]').click(); await pg.wait_for_timeout(1000); hist = await pg.locator('.comms-run').first.inner_text()
            await pg.screenshot(path=os.path.join(SHOTS, 'computadora_historial.png'))
            res('CM-11 historial por destinatario: "Enviado — aceptado por Gmail" con id; aclara que no significa entregado ni leído', 'Enviado — aceptado por Gmail' in hist and 'Id Gmail: simulado-' in hist
                and 'no significa entregado ni leído' in await pg.locator('#usersPanel').inner_text(), hist[:120])
            # ----- editar un comunicado ACTIVO: confirmación con impacto; lo enviado no cambia -----
            snap = json.dumps(run[0]['snapshot'], sort_keys=True); await pg.click('#cmBack'); await pg.wait_for_timeout(700)
            await (await item(pg, 'EJEMPLO')).locator('[data-act="edit"]').click(); await pg.wait_for_timeout(900)
            await pg.uncheck('[data-sector][value="Ventas"]'); await pg.fill('#edSubject', 'Recordatorio (v2): normas de cobro'); await pg.click('#edSave'); await pg.wait_for_timeout(900)
            imp = await pg.locator('#impact').inner_text(); await pg.click('.comms-modal [data-mok]'); await pg.wait_for_timeout(1000)
            d3 = await db(pg); m3 = next(x for x in d3['messages'] if x['id'] == 'msg-ejemplo'); r3 = next(r for r in d3['runs'] if r['id'] == run[0]['id'])
            res('CM-12 editar un comunicado PROGRAMADO pide confirmación mostrando el impacto; lo ya enviado (copia) NO cambia', 'Cambia el contenido' in imp and 'se quitan' in imp
                and m3['subject'].startswith('Recordatorio (v2)') and json.dumps(r3['snapshot'], sort_keys=True) == snap, imp[:160])
            # ----- pausa / reanudación sin enviar lo vencido; cancelación -----
            # reloj de la demo ajustable SOLO en pruebas (window.OKD_COMMS_NOW) para recorrer semanas
            await pg.click('#edBack'); await pg.wait_for_timeout(700)
            await pg.evaluate(f'()=>{{ window.OKD_COMMS_NOW = {MON_0901 + 864e5} }}'); await (await item(pg, 'EJEMPLO')).locator('[data-act="pause"]').click(); await pg.wait_for_timeout(800)   # pausa el martes
            tp = await pg.evaluate(f'async()=>window.OKD_ONLINE.api.commsDemoTick({MON_0901 + 7 * 864e5})')                                                                 # lunes siguiente, en pausa
            await pg.evaluate(f'()=>{{ window.OKD_COMMS_NOW = {MON_0901 + 7 * 864e5 + 3 * 3600e3} }}'); await (await item(pg, 'EJEMPLO')).locator('[data-act="resume"]').click(); await pg.wait_for_timeout(800)
            tr = await pg.evaluate(f'async()=>window.OKD_ONLINE.api.commsDemoTick({MON_0901 + 7 * 864e5 + 3 * 3600e3 + 60e3})')
            tn = await pg.evaluate(f'async()=>window.OKD_ONLINE.api.commsDemoTick({MON_0901 + 14 * 864e5})')
            dates = sorted(r['scheduled_for'][:10] for r in (await db(pg))['runs'] if r['kind'] == 'PROGRAMADO')
            res('CM-13 PAUSAR y REANUDAR: el lunes vencido en pausa NO se envía ni se marca perdido; sigue el lunes siguiente', tp['created'] == 0 and tr['created'] == 0 and tr['missed'] == 0
                and tn['created'] == 1 and dates == [MON.isoformat(), (MON + datetime.timedelta(days=14)).isoformat()], {'pausa': tp['created'], 'reanudar': [tr['created'], tr['missed']], 'fechas': dates})
            await (await item(pg, 'EJEMPLO')).locator('[data-act="cancel"]').click(); await pg.wait_for_timeout(400); await pg.click('.comms-modal [data-mok]'); await pg.wait_for_timeout(900)
            tc = await pg.evaluate(f'async()=>window.OKD_ONLINE.api.commsDemoTick({MON_0901 + 21 * 864e5})')
            res('CM-14 CANCELAR: estado Cancelado y no hay más envíos', 'Cancelado' in await (await item(pg, 'EJEMPLO')).inner_text() and tc['created'] == 0 and tc['sent'] == 0, tc)
            await pg.evaluate('()=>{ delete window.OKD_COMMS_NOW; }')
            # ----- WhatsApp en COMPUTADORA (sin compartir nativo): copiar/descargar; registrar es manual y separado -----
            await pg.evaluate('()=>{ try { delete Navigator.prototype.share; delete Navigator.prototype.canShare; } catch(e){} }')
            before = await db(pg); await (await item(pg, 'EJEMPLO')).locator('[data-act="wa"]').click(); await pg.wait_for_timeout(1000)
            caps = await pg.locator('#waCaps').inner_text(); await pg.click('#waCopy'); await pg.wait_for_timeout(500)
            clip = await pg.evaluate('()=>navigator.clipboard.readText()')
            async with pg.expect_download() as dwn: await pg.click('#waDownload')
            fname = (await dwn.value).suggested_filename
            mid = await db(pg)
            await pg.click('#waRegister'); await pg.wait_for_timeout(900); after = await db(pg)
            await pg.screenshot(path=os.path.join(SHOTS, 'computadora_whatsapp.png'))
            res('CM-15 COMPUTADORA: sin compartir nativo → COPIAR y DESCARGAR; copiar NO registra; REGISTRAR (con confirmación) es manual y NO toca los correos',
                'compartir texto ✗' in caps and clip.startswith('*Recordatorio (v2)') and fname.endswith(('.png', '.pdf')) and len(mid['shares']) == 0 and len(after['shares']) == 1
                and any('NO confirma que lo hayan recibido' in m for m in dlg) and len(after['deliveries']) == len(before['deliveries']) and len(after['runs']) == len(before['runs']), {'caps': caps, 'registros': len(after['shares'])})
            await ctx.close()
            # ----- ANDROID emulado: compartir texto + archivos juntos (cuando el dispositivo lo permite) -----
            dev = p.devices['Pixel 7']; share_js = '''window.__shared = []; Navigator.prototype.share = async function(d){ window.__shared.push({text: d.text || null, files: (d.files||[]).map(f=>f.name)}); };
              Navigator.prototype.canShare = function(d){ return %s; };'''
            for case, can_js in (('juntos', 'true'), ('separado', '!(d && d.files && d.text)')):
                ctx = await b.new_context(**dev); await ctx.add_init_script(share_js % can_js); pg = await ctx.new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
                await pg.goto(f'http://127.0.0.1:{cr.PORT}/'); await pg.evaluate('()=>localStorage.clear()'); await cr.login(pg, 'admin@okdespacho.demo'); await comms(pg)
                await (await item(pg, 'EJEMPLO')).locator('[data-act="wa"]').click(); await pg.wait_for_timeout(1200)
                if case == 'juntos':
                    await pg.screenshot(path=os.path.join(SHOTS, 'android_whatsapp.png')); await pg.click('#waShare'); await pg.wait_for_timeout(600)
                    sh = await pg.evaluate('()=>window.__shared'); reg = len((await db(pg))['shares'])
                    res('CM-16 ANDROID: COMPARTIR POR WHATSAPP abre el diálogo nativo con TEXTO + INFOGRAFÍA juntos; compartir NO lo registra', len(sh) == 1 and sh[0]['text'].startswith('*Recordatorio: normas de cobro*')
                        and sh[0]['files'] == ['infografia-normas-de-cobro.png'] and reg == 0, sh)
                else:
                    split = await pg.locator('#waSplit').count(); await pg.click('#waShare'); await pg.wait_for_timeout(400); await pg.click('#waShareFiles'); await pg.wait_for_timeout(400)
                    sh = await pg.evaluate('()=>window.__shared')
                    res('CM-17 ANDROID sin texto+archivos juntos: lo explica y los comparte POR SEPARADO sin perder información', split == 1 and len(sh) == 2 and sh[0]['text'] and not sh[0]['files']
                        and sh[1]['files'] == ['infografia-normas-de-cobro.png'], sh)
                    await pg.screenshot(path=os.path.join(SHOTS, 'android_whatsapp_separado.png'))
                await ctx.close()
            # ----- permisos: Operario sin permisos y con solo "consultar" -----
            ctx = await b.new_context(**cr.DESK); pg = await ctx.new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
            await pg.goto(f'http://127.0.0.1:{cr.PORT}/'); await pg.evaluate('()=>localStorage.clear()'); await cr.login(pg, 'admin@okdespacho.demo')
            ids = await pg.evaluate(cr.SETUP, [('op', 'Operario Com QA', 'opcom.qa@example.invalid', 'OPERARIO_DEPOSITO'), ('vw', 'Lector Com QA', 'vwcom.qa@example.invalid', 'OPERARIO_DEPOSITO')])
            await pg.evaluate(f'async()=>window.OKD_ONLINE.api.setUserPermission("{ids["vw"]}", "comms.view", "GRANT", "prueba")'); await cr.logout(pg)
            await cr.login(pg, 'opcom.qa@example.invalid'); no_menu = await pg.evaluate('()=>!document.querySelector("a[href=\\"#/comunicaciones\\"]")')
            await pg.evaluate('()=>{location.hash="#/comunicaciones"}'); await pg.wait_for_timeout(1200); blocked = await pg.evaluate('()=>!!document.getElementById("b403")'); await cr.logout(pg)
            await cr.login(pg, 'vwcom.qa@example.invalid'); await comms(pg); it = await item(pg, 'EJEMPLO')
            btns = await it.evaluate('e=>[...e.querySelectorAll("[data-act]")].map(b=>b.dataset.act)')
            direct = await pg.evaluate('async()=>{ try { await window.OKD_ONLINE.api.commsActivate("msg-ejemplo"); return "aceptado"; } catch(e) { return e.code; } }')
            await pg.screenshot(path=os.path.join(SHOTS, 'computadora_solo_consulta.png'))
            res('CM-18 permisos: sin permiso no hay menú y la URL directa se rechaza; con solo "consultar" ve pero NO puede editar/programar (rechazado aun llamando directo)',
                no_menu and blocked and sorted(btns) == ['detail', 'preview', 'wa'] and direct == 'FORBIDDEN', {'botones': btns, 'directo': direct})
            await ctx.close()
            # ----- CM-19: adjuntos en un comunicado PROGRAMADO (confirmación, versión, auditoría) · CM-20: VENCIDO visible en el historial -----
            ctx = await b.new_context(**cr.DESK); pg = await ctx.new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
            await pg.goto(f'http://127.0.0.1:{cr.PORT}/'); await pg.evaluate('()=>localStorage.clear()'); await cr.login(pg, 'admin@okdespacho.demo')
            await pg.evaluate(f'async()=>{{ const A=window.OKD_ONLINE.api; await A.commsGmailConnect(); window.OKD_COMMS_NOW = {MON_0901 - 2 * 864e5}; await A.commsActivate("msg-ejemplo"); delete window.OKD_COMMS_NOW; }}')
            await comms(pg); v0 = next(x for x in (await db(pg))['messages'] if x['id'] == 'msg-ejemplo')['version']
            await (await item(pg, 'EJEMPLO')).locator('[data-act="edit"]').click(); await pg.wait_for_timeout(900)
            await pg.set_input_files('#edFile', os.path.join(SHOTS, 'nota.pdf')); await pg.wait_for_timeout(700)
            ask = await pg.locator('.comms-modal').inner_text(); await pg.click('.comms-modal [data-mcancel]'); await pg.wait_for_timeout(500)
            n_cancel = await pg.evaluate('()=>document.querySelectorAll("#edAtts li").length')
            await pg.set_input_files('#edFile', os.path.join(SHOTS, 'nota.pdf')); await pg.wait_for_timeout(700); await pg.click('.comms-modal [data-mok]'); await pg.wait_for_timeout(1500)
            n_ok = await pg.evaluate('()=>document.querySelectorAll("#edAtts li").length'); m19 = next(x for x in (await db(pg))['messages'] if x['id'] == 'msg-ejemplo')
            aud = [a for a in (await db(pg))['audit'] if a['entity'] == 'ADJUNTO' and a['action'] == 'AGREGADO']
            res('CM-19 agregar un adjunto a un comunicado PROGRAMADO pide confirmación: al cancelar NO se agrega; al confirmar se agrega, sube la versión y queda auditado',
                'afecta los próximos envíos' in ask and n_cancel == 1 and n_ok == 2 and m19['version'] == v0 + 1 and aud and aud[-1]['detail'].get('confirmado') is True, {'cancelado': n_cancel, 'confirmado': n_ok, 'version': [v0, m19['version']]})
            await pg.click('#edBack'); await pg.wait_for_timeout(600)
            await pg.evaluate(f'async()=>{{ window.OKD_COMMS_FAKE = Array(20).fill({{status: 503}}); await window.OKD_ONLINE.api.commsDemoTick({MON_0901}); window.OKD_COMMS_FAKE = []; await window.OKD_ONLINE.api.commsDemoTick({MON_0901 + 8 * 3600e3}); }}')
            await (await item(pg, 'EJEMPLO')).locator('[data-act="detail"]').click(); await pg.wait_for_timeout(1000)
            h20 = await pg.locator('.comms-run').first.inner_text(); late = await pg.locator('[data-vlate]').count()
            sent20 = [x for x in (await db(pg))['deliveries'] if x['status'] == 'ENVIADO']
            await pg.screenshot(path=os.path.join(SHOTS, 'computadora_vencidos.png'))
            res('CM-20 lo que no salió dentro de la ventana queda VENCIDO en el historial (con motivo y "ENVIAR IGUAL"), sin enviarse', 'Vencido — no se envió (revisar)' in h20
                and 'Queda para revisión' in h20 and late >= 1 and not sent20, {'vencidos_con_boton': late, 'enviados': len(sent20)})
            # ----- CM-21: confirmación MANUAL de un "Por verificar": hora de envío estimada y confirmación, por separado -----
            await pg.click('#cmBack'); await pg.wait_for_timeout(600)
            await pg.evaluate(f'''async()=>{{ const A=window.OKD_ONLINE.api; window.OKD_COMMS_NOW = {MON_0901 + 9 * 3600e3}; await A.commsRequestTest("msg-ejemplo", "verificar@ejemplo.test");
              window.OKD_COMMS_FAKE = ["LOST"]; await A.commsDemoTick({MON_0901 + 9 * 3600e3 + 1000}); window.OKD_COMMS_FAKE = []; }}''')
            await (await item(pg, 'EJEMPLO')).locator('[data-act="detail"]').click(); await pg.wait_for_timeout(900)
            row = pg.locator('tr[data-did]', has_text='verificar@ejemplo.test').first; before21 = await row.inner_text()
            await row.locator('[data-vok]').click(); await pg.wait_for_timeout(1000)
            after21 = await pg.locator('tr[data-did]', has_text='verificar@ejemplo.test').first.inner_text()
            d21 = next(x for x in (await db(pg))['deliveries'] if x.get('email') == 'verificar@ejemplo.test')
            res('CM-21 "FIGURA EN ENVIADOS": queda Enviado con hora ESTIMADA (inicio del intento) y la confirmación manual por separado', 'Por verificar' in before21
                and 'Envío estimado (inicio del intento)' in after21 and 'Confirmado manualmente' in after21 and d21['sent_at'] == d21['claimed_at'] and d21['sent_at_source'] == 'ESTIMADA_INICIO_INTENTO',
                after21.replace('\n', ' ')[:200])
            await pg.evaluate('()=>{ delete window.OKD_COMMS_NOW; }')
            await ctx.close()
          finally: await b.close()
    finally:
        if srv.poll() is None: srv.terminate(); srv.wait(5)
    print('TOTAL', sum(1 for r in R if r[1] == 'PASS'), 'PASS /', sum(1 for r in R if r[1] == 'FAIL'), 'FAIL · esperados', EXPECTED)
    return R
if __name__ == '__main__':
    if len(sys.argv) > 1: cr.DIST = sys.argv[1]
    try: rr = asyncio.run(main())
    except Exception as e: traceback.print_exc(); print('ERROR:', repr(e)); sys.exit(2)
    if len(rr) != EXPECTED: print('ERROR: se ejecutaron %d de %d' % (len(rr), EXPECTED)); sys.exit(2)
    sys.exit(1 if any(r[1] != 'PASS' for r in rr) else 0)
