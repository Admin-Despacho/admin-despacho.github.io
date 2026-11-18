"""E2E BLOQUEANTE (demo + Constructor REAL) · ALARMA COMERCIAL URGENTE: Despacho la pide desde REVISAR → Wilfredo la ve y SUENA en cualquier
pantalla → a los 3 minutos (reloj del servidor, simulado en la demo) se ESCALA a Franco y Gabriela → uno la ATIENDE (no aprueba) → se detiene
en los demás y quien la pidió ve ATENDIDA. Permisos, duplicados, CONFLICT, reconexión, Android e historial. Sin envíos reales."""
import asyncio, os, sys, json, subprocess, traceback
sys.path.insert(0, os.path.dirname(__file__))
import run_saldo_revisar_noc as base
import run_driver_perfiles as dp
from playwright.async_api import async_playwright
R = []; EXPECTED = 17
DIST = sys.argv[1] if len(sys.argv) > 1 else os.path.join(base.ROOT, 'dist-demo'); dp.DIST = DIST; dp.PORT = base.PORT = 4383
OUT = sys.argv[2] if len(sys.argv) > 2 else '/tmp/okd_com_alarma'
K = 'okd_online_demo_v2'
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:360])); print('..', ' | '.join(R[-1]), flush=True)
ALM = '()=>JSON.parse(localStorage.getItem("%s")).com.alarms||[]' % K
OV = '()=>{const e=document.getElementById("comAlarm"); return e?e.innerText.replace(/\\s+/g," "):""}'
ST = '()=>{const s=window.__okdComAlarm||{}; return {ringing:!!s.ringing, beeps:s.beeps||0, blocked:!!s.soundBlocked, err:s.lastError||null}}'
async def sync(src, dst): v = await src.evaluate('()=>localStorage.getItem("%s")' % K); await dst.evaluate('(v)=>localStorage.setItem("%s", v)' % K, v)
async def enter(pg, email):
    await pg.goto(f'http://127.0.0.1:{dp.PORT}/'); await base.login(pg, email); await pg.wait_for_timeout(1800)
async def poll(pg): await pg.evaluate('async()=>{ if(window.__okdComAlarm&&window.__okdComAlarm.poll) await window.__okdComAlarm.poll(); }'); await pg.wait_for_timeout(400)
async def main():
    os.makedirs(OUT, exist_ok=True)
    if not all(os.path.isfile(os.path.join(base.FIX, f)) for f in base.FILES): subprocess.run(['python3', os.path.join(os.path.dirname(__file__), 'generate_synthetic_saldo_noc.py'), base.FIX], check=True)
    srv = dp.serve()
    try:
        async with async_playwright() as p:
            b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
            try:
                mk = lambda: b.new_context(viewport={'width': 1366, 'height': 900})
                op = await (await mk()).new_page(); op.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
                await op.goto(f'http://127.0.0.1:{dp.PORT}/'); await op.evaluate('()=>localStorage.clear()')
                await base.login(op, 'admin@okdespacho.demo'); await op.wait_for_timeout(1500)
                await op.evaluate('async()=>{await window.OKD_ONLINE.api.comSetAlarmSettings({initial_user:"u-wilfredo", escalation_users:["u-franco","u-gabriela"]})}')
                await op.evaluate('async()=>{try{await window.OKD_ONLINE.api.signOut()}catch(e){}}'); await op.goto(f'http://127.0.0.1:{dp.PORT}/')
                await base.login(op, 'operario@okdespacho.demo'); await base.builder(op)
                await op.fill('#ids', '72001 72002 72003 72004'); await op.click('#btnSearch'); await op.wait_for_timeout(2500)
                await base.type_amount(op, '72001', '1500'); await base.type_amount(op, '72002', '2000'); await op.evaluate('async()=>{ await RouteStore.flush(); await window.OKD_ONLINE.api.comConfig(); }')
                await base.open_publish(op); await op.wait_for_timeout(2500)
                idx = await op.evaluate('()=>[...document.querySelectorAll("[data-al-order] option")].findIndex(o=>o.textContent.startsWith("72003"))')
                await op.select_option('[data-al-order]', str(idx)); await op.fill('[data-al-reason]', 'Cliente pide financiación antes de cargar el pedido')
                await op.click('[data-al-go]'); await op.wait_for_timeout(1200); r1 = await op.evaluate('()=>document.querySelector("[data-al-res]").innerText')
                await op.click('[data-al-go]'); await op.wait_for_timeout(1200); r1b = await op.evaluate('()=>document.querySelector("[data-al-res]").innerText')   # misma intención: muestra el resultado, no reenvía
                await op.click('[data-al-new]'); await op.fill('[data-al-reason]', 'Cliente pide financiación antes de cargar el pedido'); await op.click('[data-al-go]'); await op.wait_for_timeout(1200)
                r2 = await op.evaluate('()=>document.querySelector("[data-al-res]").innerText')   # NUEVA operación para el mismo pedido activo → la existente
                al = await op.evaluate(ALM)
                await op.locator('.comalarmform').scroll_into_view_if_needed(); await op.screenshot(path=os.path.join(OUT, '1_revisar_solicitar_aprobacion_urgente.png'))
                res('AL-E01 REVISAR: «SOLICITAR APROBACIÓN URGENTE» por pedido (explícito) → ALARMA ENVIADA · PENDIENTE DE ATENCIÓN, vinculada a pedido, hoja y solicitante; repetir la MISMA intención muestra el resultado y una NUEVA operación recibe la existente: NO duplica',
                    'ENVIADA' in r1 and 'PENDIENTE DE ATENCIÓN' in r1 and r1b == r1 and 'Ya hay una alarma ACTIVA' in r2 and len(al) == 1 and al[0]['order_ref'] == '72003' and al[0]['status'] == 'PENDIENTE_ATENCION'
                    and al[0]['sheet_key'] == await op.evaluate('()=>RouteStore.sheetId'), {'r1': r1, 'r1b': r1b, 'r2': r2})
                # Wilfredo en OTRA pantalla (no el módulo Comercial): Dashboard/Despacho
                wi = await (await mk()).new_page(); await wi.goto(f'http://127.0.0.1:{dp.PORT}/'); await sync(op, wi); await enter(wi, 'wilfredo@okdespacho.demo')
                await poll(wi); ov = await wi.evaluate(OV); st0 = await wi.evaluate(ST)
                await wi.mouse.click(5, 600); await wi.wait_for_timeout(2600); st1 = await wi.evaluate(ST)
                await wi.screenshot(path=os.path.join(OUT, '2_wilfredo_alarma_notebook.png'))
                res('AL-E02 WILFREDO: aviso destacado en cualquier pantalla con solicitante, pedido, cliente y motivo + ATENDER SOLICITUD; SUENA (tras el gesto que exige Chrome) y ofrece activar notificaciones',
                    'APROBACIÓN COMERCIAL URGENTE' in ov and '72003' in ov and 'Operario Depósito' in ov and 'financiación antes de cargar' in ov and 'ATENDER SOLICITUD' in ov
                    and st1['ringing'] and st1['beeps'] > st0['beeps'] and ('ACTIVAR NOTIFICACIONES' in ov or 'no admite notificaciones' in ov or 'BLOQUEADAS' in ov), {'antes': st0, 'despues': st1})
                fr = await (await mk()).new_page(); await fr.goto(f'http://127.0.0.1:{dp.PORT}/'); await sync(op, fr); await enter(fr, 'franco@okdespacho.demo'); await poll(fr)
                res('AL-E03 ANTES DE LOS 3 MINUTOS: Franco (Administrador General) NO recibe la alarma sonora (solo el destinatario inicial)', not (await fr.evaluate(ST))['ringing'], await fr.evaluate(ST))
                # pasan los 3 minutos (reloj del servidor; en la demo se adelanta el vencimiento)
                await wi.evaluate('()=>{const d=JSON.parse(localStorage.getItem("%s")); d.com.alarms[0].escalate_at=new Date(Date.now()-1000).toISOString(); localStorage.setItem("%s", JSON.stringify(d));}' % (K, K))
                await sync(wi, fr); await poll(fr); ovf = await fr.evaluate(OV); stf = await fr.evaluate(ST); alx = await fr.evaluate(ALM)
                ga = await (await mk()).new_page(); await ga.goto(f'http://127.0.0.1:{dp.PORT}/'); await sync(fr, ga); await enter(ga, 'gabriela@okdespacho.demo'); await poll(ga); ovg = await ga.evaluate(OV)
                await fr.screenshot(path=os.path.join(OUT, '3_franco_alarma_escalada.png'))
                res('AL-E04 ESCALAMIENTO A LOS 3 MINUTOS: Franco y Gabriela reciben la alarma «ESCALADA» (con hora y destinatarios) y suena; se registra UNA vez',
                    'ESCALADA' in ovf and 'ESCALADA' in ovg and stf['ringing'] and alx[0]['escalated_at'] and len(alx[0]['escalated_to']) >= 2
                    and sorted(alx[0]['escalated_to']) == ['u-franco', 'u-gabriela']
                    and sum(1 for e in await fr.evaluate('()=>JSON.parse(localStorage.getItem("%s")).com.alarmEvents' % K) if e['kind'] == 'ESCALADA') == 1, {'escalada_a': alx[0]['escalated_to']})
                v_old = alx[0]['version']
                await ga.click('[data-al-attend]'); await ga.wait_for_timeout(1500); att = await ga.evaluate(ALM); msg_g = await ga.evaluate(OV)
                res('AL-E05 ATENDER (Gabriela): queda ATENDIDA con quién, cuándo y tiempo; el mensaje aclara que ATENDER no es APROBAR; la solicitud comercial no cambia',
                    att[0].get('status') == 'ATENDIDA' and att[0].get('attended_by') == 'u-gabriela' and att[0].get('attended_as') == 'ESCALAMIENTO' and att[0].get('seconds_to_attend') is not None and 'Autorizaciones' in msg_g, {'alarma': {k: att[0].get(k) for k in ('status','attended_by','attended_as','version')}, 'mensaje': msg_g[-220:]})
                await sync(ga, fr); conf = await fr.evaluate('async(a)=>{try{await window.OKD_ONLINE.api.comAlarmAttend(a.id, a.v); return "TOMÓ"}catch(e){return e.code||e.message}}', {'id': att[0]['id'], 'v': v_old})
                res('AL-E06 DOS RESPONSABLES: Franco intenta tomarla con la versión anterior → CONFLICT; queda atendida por Gabriela', conf == 'CONFLICT', conf)
                await sync(ga, wi); await poll(wi); stw = await wi.evaluate(ST); await poll(fr); stf2 = await fr.evaluate(ST)
                res('AL-E07 al ATENDER se detiene la alarma en los demás (Wilfredo y Franco dejan de sonar)', not stw['ringing'] and not stf2['ringing'], {'wilfredo': stw, 'franco': stf2})
                await sync(ga, op); await poll(op); chip = await op.evaluate('()=>{const e=document.querySelector("[data-al-stack]"); return e?e.innerText.replace(/\\s+/g," "):""}')
                res('AL-E08 quien la pidió (Despacho) ve que fue ATENDIDA y por quién', 'ATENDIDA' in chip and 'Gabriela' in chip, chip)
                co = await (await mk()).new_page(); await co.goto(f'http://127.0.0.1:{dp.PORT}/'); await sync(ga, co); await enter(co, 'comercial.montecaseros@okdespacho.demo')
                pc = await co.evaluate('async(id)=>{const A=window.OKD_ONLINE.api, t=async f=>{try{const r=await f(); return r&&r.code?r.code:(Array.isArray(r)?"LISTA:"+r.length:"OK")}catch(e){return e.code||e.message.split(":")[0]}};'
                    'return {ver:await t(()=>A.comMyAlarms()), atender:await t(()=>A.comAlarmAttend(id,1)), emitir:await t(()=>A.comAlarmRaise("72001","x","x","","motivo suficiente","x"))}}', att[0]['id'])
                res('AL-E09 PERMISOS: el Comercial no ve alarmas ajenas, no puede atender (rechazo registrado) ni emitir', pc['ver'] == 'LISTA:0' and pc['atender'] == 'FORBIDDEN' and pc['emitir'] == 'FORBIDDEN', pc)
                # RECONEXIÓN: nueva alarma mientras Wilfredo está sin internet
                await sync(ga, op); await op.evaluate('async()=>{await window.OKD_ONLINE.api.comAlarmRaise("72001", RouteStore.sheetId, "x", "", "Segundo pedido urgente de prueba", "re-1")}'); await sync(op, wi)
                await wi.evaluate('()=>{window.OKD_NET={offline:true}}'); await poll(wi); off = await wi.evaluate(ST)
                await wi.evaluate('()=>{window.OKD_NET={offline:false}; window.dispatchEvent(new Event("online"))}'); await wi.wait_for_timeout(1200); on = await wi.evaluate(ST)
                res('AL-E10 RECONEXIÓN: sin internet la consulta falla sin perder estado; al volver la conexión recibe la alarma nueva y suena', bool(off['err']) and on['ringing'] and not on['err'], {'sin_conexion': off, 'reconectado': on})
                an = await b.new_context(viewport={'width': 390, 'height': 844}, is_mobile=True, has_touch=True); wa = await an.new_page()
                await wa.goto(f'http://127.0.0.1:{dp.PORT}/'); await sync(wi, wa); await enter(wa, 'wilfredo@okdespacho.demo'); await poll(wa)
                ova = await wa.evaluate(OV); hs = await wa.evaluate('()=>document.documentElement.scrollWidth-document.documentElement.clientWidth')
                await wa.screenshot(path=os.path.join(OUT, '4_wilfredo_alarma_android.png'))
                res('AL-E11 ANDROID (emulación 390×844): aviso legible con ATENDER SOLICITUD y sin desplazamiento horizontal', 'APROBACIÓN COMERCIAL URGENTE' in ova and 'ATENDER SOLICITUD' in ova and hs <= 0, {'desborde': hs})
                ad = await (await mk()).new_page(); await ad.goto(f'http://127.0.0.1:{dp.PORT}/'); await sync(wi, ad); await enter(ad, 'admin@okdespacho.demo')
                await ad.evaluate('()=>{location.hash="#/autorizaciones?v=informes"}'); await ad.wait_for_timeout(2500)
                inf = await ad.evaluate('()=>document.querySelector("#comMain").innerText.replace(/\\s+/g," ")')
                cfg = await ad.evaluate('async()=>{const A=window.OKD_ONLINE.api; const t=async f=>{try{return JSON.stringify(await f())}catch(e){return e.code}}; return {mal:await t(()=>A.comSetAlarmSettings({initial_user:"u-wilfredo", escalation_users:["u-com-mc"]})), bien:await t(()=>A.comSetAlarmSettings({initial_user:"u-wilfredo", escalation_users:["u-franco","u-gabriela"]}))}}')
                await ad.screenshot(path=os.path.join(OUT, '5_informes_alarmas.png'))
                res('AL-E12 HISTORIAL (Informes) con activación, escalamiento, atención y tiempos; la configuración solo admite Administradores Generales activos para escalar',
                    'Alarmas urgentes'.upper() in inf.upper() and 'ALR-000001' in inf and 'Gabriela' in inf and cfg['mal'] == 'BAD_RECIPIENT' and 'Franco' in cfg['bien'], cfg)
                # ===== auditoría independiente 14/11 (alarma) =====
                # AL-E13 · B-AL-01: sesión A (Wilfredo) con alarma ACTIVA → vencimiento SIN recargar → ingreso B (Gabriela) en la MISMA página
                pre = await wi.evaluate(ST)
                await wi.evaluate('()=>{ window.__marcaSinRecarga = "A-" + Date.now(); window.dispatchEvent(new Event("okd-session-expired")); }'); await wi.wait_for_timeout(1500)
                tras = await wi.evaluate('()=>({estado: typeof window.__okdComAlarm, instalada: !!window.__okdComAlarmInstalled, vista: !!document.getElementById("comAlarm"), login: !!document.querySelector("#loginEmail") && document.querySelector("#loginEmail").offsetParent!==null, misma_pagina: !!window.__marcaSinRecarga})')
                await wi.wait_for_timeout(3000); sigue = await wi.evaluate('()=>({vista: !!document.getElementById("comAlarm"), estado: typeof window.__okdComAlarm})')
                await sync(op, wi); await wi.fill('#loginEmail', 'gabriela@okdespacho.demo'); await wi.fill('#loginPass', 'demo'); await wi.click('#loginBtn'); await wi.wait_for_timeout(3000)
                if await wi.locator('#pinA').count() and await wi.is_visible('#pinA'): await wi.fill('#pinA', '123456'); await wi.fill('#pinB', '123456'); await wi.click('#pinGo'); await wi.wait_for_timeout(1200)
                await poll(wi); b13 = await wi.evaluate('()=>{const s=window.__okdComAlarm||{}; const e=document.getElementById("comAlarm"); return {usuario:s.userId, consultas:s.polls||0, suena:!!s.ringing, misma_pagina: !!window.__marcaSinRecarga, texto:e?e.innerText.replace(/\\s+/g," "):""}}')
                res('AL-E13 (B-AL-01) VENCIMIENTO SIN RECARGA: con la alarma sonando, al vencer la sesión se borra TODO al instante (vista, sonido, estado, guardián) y no reaparece; el siguiente usuario en la MISMA página recibe SU instalación y nada del anterior',
                    pre['ringing'] and tras['misma_pagina'] and tras['estado'] == 'undefined' and not tras['instalada'] and not tras['vista'] and tras['login'] and not sigue['vista'] and sigue['estado'] == 'undefined'
                    and b13['misma_pagina'] and b13['usuario'] == 'u-gabriela' and b13['consultas'] > 0 and not b13['suena'] and 'ALR-000002' not in b13['texto'] and 'Segundo pedido urgente' not in b13['texto'], {'antes': pre, 'tras': tras, 'nuevo': b13})
                # AL-E14 · B-AL-02: enlace directo del push (#/autorizaciones?alarma_n=<aviso>) con la ventana CERRADA y ABIERTA
                nid = await op.evaluate('()=>{const d=JSON.parse(localStorage.getItem("%s")); const n=(d.com.alarmNotifs||[]).find(x=>x.user_id==="u-wilfredo" && x.type==="COM_ALARMA"); return n&&n.id}' % K)
                w2 = await (await mk()).new_page(); await w2.goto(f'http://127.0.0.1:{dp.PORT}/'); await sync(op, w2); await enter(w2, 'wilfredo@okdespacho.demo')
                await w2.goto(f'http://127.0.0.1:{dp.PORT}/#/autorizaciones?alarma_n={nid}'); await w2.reload(); await w2.wait_for_timeout(3500)
                cerrada = await w2.evaluate('()=>{const e=document.querySelector("[data-al-focus]"); return e?e.innerText.replace(/\\s+/g," "):""}')
                await w2.evaluate('()=>{location.hash="#/despacho"}'); await w2.wait_for_timeout(800); await w2.evaluate('()=>{const b=document.querySelector("[data-al-close]"); if(b) b.click()}')
                await w2.evaluate('(n)=>{location.hash="#/autorizaciones?alarma_n="+n}', nid); await w2.wait_for_timeout(2500)
                abierta = await w2.evaluate('()=>{const e=document.querySelector("[data-al-focus]"); return e?e.innerText.replace(/\\s+/g," "):""}')
                visible = await w2.evaluate('''() => { const e = document.querySelector("[data-al-focus]"); if (!e) return false; e.scrollIntoView({block: "center"}); const r = e.getBoundingClientRect(); const x = r.left + r.width / 2, y = r.top + Math.min(r.height / 2, 30); const top = document.elementFromPoint(x, y); return !!top && (top === e || e.contains(top)); }''')   # el recuadro se VE (nada encima en su centro), aunque otra alarma esté sonando
                if await w2.locator('[data-al-focus]').count(): await w2.locator('[data-al-focus]').screenshot(path=os.path.join(OUT, '6_enlace_directo_alarma.png'))
                c2 = await (await mk()).new_page(); await c2.goto(f'http://127.0.0.1:{dp.PORT}/'); await sync(op, c2); await enter(c2, 'operario@okdespacho.demo')
                await c2.evaluate('(n)=>{location.hash="#/autorizaciones?alarma_n="+n}', nid); await c2.wait_for_timeout(2500)
                ajeno = await c2.evaluate('()=>{const e=document.querySelector("[data-al-focus]"); return e?e.innerText.replace(/\\s+/g," "):""}')
                res('AL-E14 (B-AL-02) ENLACE DIRECTO del push: con la ventana CERRADA (arranque con el enlace) y ABIERTA (cambio de dirección) abre la alarma ESPECÍFICA (ALR-000001, atendida por Gabriela) VISIBLE aunque otra alarma esté sonando; otro usuario con el mismo enlace no la obtiene',
                    'ALR-000001' in cerrada and 'ATENDIDA' in cerrada and 'Gabriela' in cerrada and 'ALR-000001' in abierta and visible and 'No se encontró la alarma' in ajeno, {'cerrada': cerrada[:120], 'abierta': abierta[:80], 'visible_sin_tapar': visible, 'ajeno': ajeno[:80]})
                # AL-E15 · B-AL-03: el Panel muestra lo GUARDADO; guardar sin cambios no modifica; destinatario deshabilitado → advertencia y SIN ampliación
                await ad.evaluate('()=>{location.hash="#/autorizaciones?v=general"}'); await ad.wait_for_timeout(2500)
                sel = await ad.evaluate('()=>({ini: document.querySelector("#alIni").value, esc: [...document.querySelector("#alEsc").selectedOptions].map(o=>o.value).sort()})')
                await ad.click('#alSave'); await ad.wait_for_timeout(1200)
                cfg2 = await ad.evaluate('()=>JSON.parse(localStorage.getItem("%s")).com.alarmCfg' % K)
                await ad.evaluate('()=>{const d=JSON.parse(localStorage.getItem("%s")); d.users.find(u=>u.id==="u-gabriela").status="DESHABILITADO"; localStorage.setItem("%s", JSON.stringify(d));}' % (K, K))
                await ad.evaluate('()=>{location.hash="#/autorizaciones?v=informes"}'); await ad.wait_for_timeout(1200); await ad.evaluate('()=>{location.hash="#/autorizaciones?v=general"}'); await ad.wait_for_timeout(2500)
                prob = await ad.evaluate('()=>{const e=document.querySelector("#alProb"); return e?e.innerText:""}'); eff = await ad.evaluate('()=>document.querySelector("#alEff").innerText')
                sec = ad.locator('#comMain section.card', has=ad.locator('#alSave')); await sec.scroll_into_view_if_needed(); await sec.screenshot(path=os.path.join(OUT, '7_panel_destinatarios.png'))
                await sync(ad, op); await op.evaluate('async()=>{await window.OKD_ONLINE.api.comAlarmRaise("72004", RouteStore.sheetId, "x", "", "Pedido urgente con un destinatario deshabilitado", "e15")}')
                await op.evaluate('()=>{const d=JSON.parse(localStorage.getItem("%s")); const a=d.com.alarms.find(x=>x.op_id==="e15"); a.escalate_at=new Date(Date.now()-1000).toISOString(); localStorage.setItem("%s", JSON.stringify(d));}' % (K, K))
                await op.evaluate('async()=>{await window.OKD_ONLINE.api.comMyAlarms()}'); e15 = await op.evaluate('()=>JSON.parse(localStorage.getItem("%s")).com.alarms.find(x=>x.op_id==="e15").escalated_to' % K)
                res('AL-E15 (B-AL-03) PANEL: muestra seleccionados los destinatarios GUARDADOS; guardar sin cambios no modifica nada; con Gabriela deshabilitada lo ADVIERTE y el escalamiento va SOLO a Franco (no se amplía a otros administradores)',
                    sel['ini'] == 'u-wilfredo' and sel['esc'] == ['u-franco', 'u-gabriela'] and cfg2 == {'initial_user': 'u-wilfredo', 'escalation_users': ['u-franco', 'u-gabriela']}
                    and 'NO está activo' in prob and 'Franco' in eff and 'Gabriela' not in eff and e15 == ['u-franco'], {'seleccion': sel, 'problema': prob[:120], 'escalado_a': e15})
                await op.evaluate('()=>{const d=JSON.parse(localStorage.getItem("%s")); d.users.find(u=>u.id==="u-gabriela").status="ACTIVO"; localStorage.setItem("%s", JSON.stringify(d));}' % (K, K))   # en la base del Operario (contiene la alarma e15)
                # AL-E16 · O-AL-05: ATENDER con la versión ANTERIOR justo después del escalamiento
                await sync(op, w2); o16 = await w2.evaluate('''async()=>{const A=window.OKD_ONLINE.api, d=JSON.parse(localStorage.getItem("%s")); const a=d.com.alarms.find(x=>x.op_id==="e15");
                  const r1=await A.comAlarmAttend(a.id, 1); let r2; try{ r2=await A.comAlarmAttend(a.id, 1); r2="TOMÓ"; }catch(e){ r2=e.code; } return {primera:r1.status, como:r1.attended_as, segunda:r2}}''' % K)
                res('AL-E16 (O-AL-05) ATENDER con la versión anterior al escalamiento (nadie la había atendido): Wilfredo la atiende SIN falso conflicto; una segunda atención recibe CONFLICT',
                    o16['primera'] == 'ATENDIDA' and o16['como'] == 'DESTINATARIO_INICIAL' and o16['segunda'] == 'CONFLICT', o16)
                # AL-E17 · B-AL-06: idempotencia de la emisión (op_id vinculado a pedido, hoja y usuario) por llamada DIRECTA
                e17 = await op.evaluate('''async()=>{const A=window.OKD_ONLINE.api, h=RouteStore.sheetId;
                  const a=await A.comAlarmRaise("72002", h, "x", "", "Pedido para idempotencia en la demo", "op-e17");
                  const b=await A.comAlarmRaise("72002", h, "x", "", "Pedido para idempotencia en la demo", "op-e17");
                  const c=await A.comAlarmRaise("72001", h, "x", "", "Mismo op_id para otro pedido", "op-e17"); return {a, b, c, hoja: h}}''')
                await co.evaluate('async()=>{try{await window.OKD_ONLINE.api.signOut()}catch(e){}}'); await sync(op, co); await enter(co, 'franco@okdespacho.demo')   # otro usuario con permiso de emitir (en la demo no hay Supervisor)
                e17u = await co.evaluate('async(h)=>{try{return await window.OKD_ONLINE.api.comAlarmRaise("72002", h, "x", "", "Mismo op_id desde otro usuario", "op-e17")}catch(e){return {code:e.code}}}', e17['hoja'])
                ev17 = await co.evaluate('()=>{const d=JSON.parse(localStorage.getItem("%s")); const a=d.com.alarms.find(x=>x.op_id==="op-e17"); return {n:d.com.alarms.filter(x=>x.op_id==="op-e17").length, rech:(d.com.alarmEvents||[]).filter(e=>e.alarm_id===a.id && e.kind==="OP_ID_REUTILIZADO_RECHAZADO").length}}' % K)
                res('AL-E17 (B-AL-06) IDEMPOTENCIA en la demo: repetir la misma operación devuelve la misma alarma; reutilizar el op_id para OTRO pedido o desde OTRO usuario → OP_ID_CONFLICT sin datos; intentos registrados; una sola alarma',
                    e17['b'].get('id') == e17['a'].get('id') and e17['b'].get('repeated') and e17['c'].get('code') == 'OP_ID_CONFLICT' and 'number' not in e17['c']
                    and e17u.get('code') == 'OP_ID_CONFLICT' and 'number' not in e17u and ev17 == {'n': 1, 'rech': 2}, {'otro_pedido': e17['c'], 'otro_usuario': e17u, 'registro': ev17})
            finally: await b.close()
    finally: srv.terminate()
    print('TOTAL', sum(1 for r in R if r[1] == 'PASS'), 'PASS /', sum(1 for r in R if r[1] == 'FAIL'), 'FAIL · esperados', EXPECTED)
    return R
if __name__ == '__main__':
    try: rr = asyncio.run(main())
    except Exception as e: traceback.print_exc(); print('ERROR:', repr(e)); sys.exit(2)
    if len(rr) != EXPECTED: print('ERROR: se ejecutaron %d de %d' % (len(rr), EXPECTED)); sys.exit(2)
    sys.exit(1 if any(r[1] != 'PASS' for r in rr) else 0)
