"""E2E (modo demo, Chromium) · "Permitir asignación de hojas de ruta" + "⇄ Cambiar rol" en computadora (1366) y celular (390).
Usuarios SINTÉTICOS (Operario, Admin y Solo Lectura). Controles reales: editor de permisos, selector de vista, Mis rutas (INICIAR, ENTREGADO,
nombre, firma, GUARDAR). Código de salida: 0 todo PASS · 1 alguna FAIL · 2 error de preparación o casos faltantes."""
import asyncio, os, subprocess, sys, time, socket, traceback, re, json
from playwright.async_api import async_playwright
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
DIST = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'dist-demo'); SHOTS = sys.argv[2] if len(sys.argv) > 2 else '/tmp/okd_cambiar_rol'
PORT = 4382; R = []; EXPECTED = 16; K = 'okd_online_demo_v2'
DESK = dict(viewport={'width': 1366, 'height': 900}, geolocation={'latitude': -32.895, 'longitude': -68.845}, permissions=['geolocation'])
MOB = dict(viewport={'width': 390, 'height': 844}, device_scale_factor=2, is_mobile=True, geolocation={'latitude': -32.895, 'longitude': -68.845}, permissions=['geolocation'])
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:260])); print('..', ' | '.join(R[-1]), flush=True)
USERS = [('op', 'Operario QA', 'op.qa@example.invalid', 'OPERARIO_DEPOSITO'), ('ad', 'Admin Dos QA', 'ad.qa@example.invalid', 'ADMIN'),
         ('ro', 'Lectura QA', 'ro.qa@example.invalid', 'SOLO_LECTURA'), ('sp', 'Sin Permiso QA', 'sp.qa@example.invalid', 'OPERARIO_DEPOSITO')]
SETUP = '''async(users)=>{const A=window.OKD_ONLINE.api;
  for (const [k,n,e,r] of users) await A.action("create",{full_name:n,email:e,role:r,active:true});
  const d=JSON.parse(localStorage.getItem("%s")); d.users.forEach(u=>{ if(/@example\\.invalid$/.test(u.email)) u.status="ACTIVO"; }); localStorage.setItem("%s",JSON.stringify(d));
  const ids={}; for (const [k,n,e] of users) ids[k]=d.users.find(u=>u.email===e).id; return ids;}''' % (K, K)
PUB = '''async(resp)=>{const A=window.OKD_ONLINE.api;
  return await A.publishRoute({sheet_key:'qa-cr-'+resp+'-'+Date.now()+Math.random(), rules_version:1, routing_rules_version:1, carrier_id:'INTERNO', responsable_id:resp, vehicle_id:'vh-1',
    stops:[{ready:true, stop_type:'UBICACION_INTERNA', internal_location_key:'SAN_JUAN', client_name:'Sucursal San Juan', address:'San Juan 500', order_numbers:[], task:'ENTREGA'},
           {ready:true, stop_type:'UBICACION_INTERNA', internal_location_key:'MONTECASEROS', client_name:'Montecaseros - casa central', address:'Montecaseros 1234', order_numbers:[], task:'ENTREGA'}]}).then(r=>({id:r.id, number:r.number})).catch(e=>({error:e.message}));}'''
def serve():
    p = subprocess.Popen([sys.executable, '-m', 'http.server', str(PORT), '--bind', '127.0.0.1'], cwd=DIST, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(60):
        try: socket.create_connection(('127.0.0.1', PORT), 1).close(); return p
        except OSError: time.sleep(0.2)
    raise RuntimeError('servidor no respondió')
async def dismiss(pg):
    for _ in range(3):
        if await pg.locator('#pushLater').count() and await pg.is_visible('#pushLater'): await pg.click('#pushLater'); await pg.wait_for_timeout(300)
        else: break
async def login(pg, email):
    await pg.goto(f'http://127.0.0.1:{PORT}/'); await pg.wait_for_load_state('networkidle'); await pg.wait_for_timeout(600)
    if await pg.locator('#loginEmail').count() and await pg.is_visible('#loginEmail'):
        for _ in range(4):
            await pg.fill('#loginEmail', email); await pg.fill('#loginPass', 'demo')
            if await pg.input_value('#loginEmail') == email: break
            await pg.wait_for_timeout(300)
        await pg.click('#loginBtn'); await pg.wait_for_timeout(2500)
        if await pg.locator('#pinA').count() and await pg.is_visible('#pinA'): await pg.fill('#pinA', '123456'); await pg.fill('#pinB', '123456'); await pg.click('#pinGo'); await pg.wait_for_timeout(900)
    await pg.wait_for_timeout(1800); await dismiss(pg)
async def logout(pg):
    await pg.evaluate('()=>{ try { sessionStorage.clear(); } catch(e){} return window.OKD_LOGOUT && window.OKD_LOGOUT(); }'); await pg.wait_for_timeout(1500)
async def visible_switch(pg):   # el bloque visible (menú lateral en computadora / encabezado en celular)
    # el del panel que está AL FRENTE (el tablero #usersPanel se dibuja encima del constructor), como lo ve la persona
    return await pg.evaluate('''()=>{ const up=document.getElementById('usersPanel'), root=(up && !up.hidden) ? up : document;
      const vis=[...root.querySelectorAll('[data-rolesw-box]')].filter(b=>b.offsetParent!==null && b.getBoundingClientRect().width>0), v=vis[0];
      return v ? {txt:v.innerText.replace(/\\s+/g,' ').trim(), enLateral: !!v.closest('.rc4side, .rc4who'), visibles: vis.length, x: Math.round(v.getBoundingClientRect().x)} : null }''')
async def choose(pg, mode):
    front = '#usersPanel:not([hidden]) ' if await pg.evaluate('()=>{const u=document.getElementById("usersPanel"); return !!u && !u.hidden && !!u.querySelector("[data-rolesw-box]")}') else ''
    await pg.locator(front + '[data-rolesw-box]:visible [data-rolesw]').first.click(); await pg.wait_for_timeout(300)
    opts = await pg.evaluate('()=>[...document.querySelectorAll("#roleswMenu [data-rolesw-go]")].map(b=>b.innerText.trim())')
    await pg.locator(f'#roleswMenu [data-rolesw-go="{mode}"]').click(); await pg.wait_for_timeout(3500); await dismiss(pg); return opts
async def sign(pg, sid):
    cv = pg.locator(f'.drv-stop[data-s="{sid}"] [data-sig]'); await cv.scroll_into_view_if_needed(); bb = await cv.bounding_box()
    await pg.mouse.move(bb['x'] + 20, bb['y'] + 20); await pg.mouse.down()
    for i in range(1, 10): await pg.mouse.move(bb['x'] + 20 + i * 18, bb['y'] + 20 + (i % 3) * 12)
    await pg.mouse.up(); await pg.wait_for_timeout(200)
async def deliver_first(pg, rid):
    """Mis rutas: abrir la hoja, INICIAR (km), LLEGUÉ, ENTREGADO, nombre + firma, GUARDAR en la 1.ª parada. Devuelve (sid, error_formulario)."""
    await pg.locator(f'[data-open="{rid}"]').click(); await pg.wait_for_timeout(1200)
    km = await pg.evaluate(f'()=>{{const d=JSON.parse(localStorage.getItem("{K}")); return ((d.vehicles||[]).find(v=>v.id==="vh-1")||{{}}).current_km||50000}}')
    if await pg.locator('#drvKmIni').count(): await pg.fill('#drvKmIni', str(int(km) + 25))   # mayor que el odómetro actual (control existente)
    if await pg.locator('#drvStart').count(): await pg.click('#drvStart'); await pg.wait_for_timeout(1500)
    sid = await pg.evaluate(f'()=>JSON.parse(localStorage.getItem("{K}")).routes2.find(r=>r.id==="{rid}").stops[0].id')
    if await pg.locator(f'.drv-stop[data-s="{sid}"] [data-arrive]').count(): await pg.locator(f'.drv-stop[data-s="{sid}"] [data-arrive]').click(); await pg.wait_for_timeout(1500)
    await pg.locator(f'.drv-stop[data-s="{sid}"] [data-o="ENTREGADO"]').click(); await pg.wait_for_timeout(400)
    await pg.locator(f'.drv-stop[data-s="{sid}"] [data-f="recv"]').fill('Encargado Sucursal QA'); await sign(pg, sid)
    await pg.locator(f'.drv-stop[data-s="{sid}"] [data-save]').click(); await pg.wait_for_timeout(1800)
    return sid
async def outcome(pg, rid, i=0): return await pg.evaluate(f'()=>JSON.parse(localStorage.getItem("{K}")).routes2.find(r=>r.id==="{rid}").stops[{i}].outcome')
async def mine(pg): return await pg.evaluate('()=>[...document.querySelectorAll("[data-open]")].map(b=>b.dataset.open)')
async def main():
    if not os.path.isfile(os.path.join(DIST, 'index.html')): raise RuntimeError('falta el build demo en ' + DIST)
    os.makedirs(SHOTS, exist_ok=True); srv = serve()
    try:
        async with async_playwright() as p:
          b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
          try:
            ctx = await b.new_context(**DESK); pg = await ctx.new_page(); dialogs = []
            pg.on('dialog', lambda d: (dialogs.append(d.message), asyncio.ensure_future(d.accept())))
            await pg.goto(f'http://127.0.0.1:{PORT}/'); await pg.evaluate('()=>localStorage.clear()')
            await pg.evaluate('()=>new Promise(r=>{const q=indexedDB.deleteDatabase("ok_despacho"); q.onsuccess=q.onerror=q.onblocked=()=>r()})')
            await login(pg, 'admin@okdespacho.demo'); ids = await pg.evaluate(SETUP, USERS)
            # ---- SIN el permiso: no es candidato ni se le puede publicar ----
            cand0 = await pg.evaluate('async()=>(await window.OKD_ONLINE.api.responsables("INTERNO")).map(x=>x.id)'); pub0 = await pg.evaluate(PUB, ids['op'])
            res('CR-01 sin el permiso NO aparece como candidato y el servidor rechaza asignarle una hoja interna', ids['op'] not in cand0 and 'error' in pub0, pub0)
            # ---- se HABILITA con el editor de permisos real (Usuarios → PERMISOS) ----
            await pg.evaluate('()=>{location.hash="#/usuarios"}'); await pg.wait_for_timeout(2000); await dismiss(pg)
            label = None
            for k in ('op', 'ad', 'ro'):
                row = pg.locator('tr', has_text=[u for u in USERS if u[0] == k][0][1]).first
                await row.locator('[data-a="perms"], [data-act="perms"], button:has-text("PERMISOS"), button:has-text("Permisos")').first.click(); await pg.wait_for_timeout(900)
                box = pg.locator('#permModal [data-perm="routes.receive_internal"]'); label = label or (await pg.locator('#permModal label:has([data-perm="routes.receive_internal"])').inner_text()).strip()
                await box.check(); await pg.locator('#permModal button', has_text='GUARDAR PERMISOS').click(); await pg.wait_for_timeout(1300)
            st = await pg.evaluate(f'()=>{{const d=JSON.parse(localStorage.getItem("{K}")); return Object.fromEntries(d.users.filter(u=>/@example\\.invalid$/.test(u.email)).map(u=>[u.email.split("@")[0], {{role:u.role, ov:u.permission_overrides||{{}}}}]))}}')
            cand1 = await pg.evaluate('async()=>(await window.OKD_ONLINE.api.responsables("INTERNO")).map(x=>x.id)')
            res('CR-02 habilitado con el editor real a Operario, Admin y Solo Lectura: aparecen como candidatos, conservan su rol, sin transportista nuevo',
                label and 'Permitir asignación de hojas de ruta' in label and all(st[k]['ov'].get('routes.receive_internal') is True for k in ('op.qa', 'ad.qa', 'ro.qa'))
                and [st[k]['role'] for k in ('op.qa', 'ad.qa', 'ro.qa')] == ['OPERARIO_DEPOSITO', 'ADMIN', 'SOLO_LECTURA'] and all(ids[k] in cand1 for k in ('op', 'ad', 'ro'))
                and ids['sp'] not in cand1 and not await pg.evaluate('async()=>(await window.OKD_ONLINE.api.listCarriers()).some(c=>/QA/.test(c.name))'), {'etiqueta': label, 'estado': st})
            rt = {k: await pg.evaluate(PUB, ids[k]) for k in ('op', 'ad', 'ro')}; rt['gb'] = await pg.evaluate(PUB, 'u-gabriel')
            res('CR-03 se les publican hojas del Transporte Interno con el flujo existente (numeración normal del Interno)', all('id' in rt[k] and rt[k]['number'].startswith('03-') for k in rt), rt)
            DBSTATE[0] = await pg.evaluate(f'()=>localStorage.getItem("{K}")')   # estado del "servidor" de la demo, para los siguientes navegadores
            await logout(pg); await ctx.close()
            # ================= OPERARIO · COMPUTADORA =================
            ctx = await b.new_context(**DESK); pg = await ctx.new_page(); pg.on('dialog', lambda d: (dialogs.append(d.message), asyncio.ensure_future(d.accept())))
            # (la demo guarda su "servidor" en localStorage del origen: se comparte copiando el estado del navegador anterior)
            await pg.goto(f'http://127.0.0.1:{PORT}/'); await pg.evaluate(f'(s)=>localStorage.setItem("{K}", s)', DBSTATE[0]); await login(pg, 'op.qa@example.invalid')
            sw = await visible_switch(pg); perms0 = await pg.evaluate('async()=>(await window.OKD_ONLINE.api.me()).permission_overrides')
            await pg.evaluate('()=>{ RouteStore.sheetDate = "2099-12-31"; }')   # trabajo SIN guardar en el constructor
            await pg.screenshot(path=os.path.join(SHOTS, 'computadora_operario_panel.png'))
            opts = await choose(pg, 'TRANSPORTISTA'); sw2 = await visible_switch(pg); ttl = await pg.locator('#noPanel .ttl span').inner_text(); own = await mine(pg)
            await pg.screenshot(path=os.path.join(SHOTS, 'computadora_operario_mis_rutas.png'))
            res('CR-04 COMPUTADORA · Operario: "ESTÁS COMO" en el menú lateral; opciones = su perfil y Transportista; pasa a "Mis rutas" solo con SU hoja',
                sw and 'ESTÁS COMO: Operario Depósito' in sw['txt'] and sw['enLateral'] and sw['visibles'] == 1 and opts[0].startswith('Operario Depósito') and opts[1].startswith('Transportista')
                and sw2 and 'ESTÁS COMO: Transportista' in sw2['txt'] and ttl == 'Mis rutas' and own == [rt['op']['id']], {'antes': sw, 'opciones': opts, 'despues': sw2, 'hojas': own})
            await deliver_first(pg, rt['op']['id']); o1 = await outcome(pg, rt['op']['id'])
            res('CR-05 realiza SU hoja con el recorrido del Transportista Interno (inicio, llegada, recepción con nombre y firma)', o1 == 'ENTREGADO', o1)
            ajena = await pg.evaluate(f'''async()=>{{ const d=JSON.parse(localStorage.getItem("{K}")); const s=d.routes2.find(r=>r.id==="{rt['gb']['id']}").stops[0].id;
              try {{ await window.OKD_ONLINE.api.startRoute("{rt['gb']['id']}", 1); return 'aceptada'; }} catch(e) {{ try {{ await window.OKD_ONLINE.api.setStopOutcome(s, 'ENTREGADO', null, null, 'x-'+Date.now(), {{evidence:{{receiver_name:'X', signature_png_b64:'iVBORw0KGgo='}}}}); return 'aceptada'; }} catch(e2) {{ return e.code+'/'+e2.code; }} }} }}''')
            res('CR-06 NO puede operar la hoja de otro chofer (el "servidor" lo rechaza aunque se llame directo)', ajena != 'aceptada' and 'FORBIDDEN' in ajena, ajena)
            await choose(pg, 'PERFIL'); sw3 = await visible_switch(pg)
            back = await pg.evaluate('()=>({operario: !document.getElementById("operario").hidden, nav: document.querySelectorAll("#rc4LegacyNav a, .nav a").length, fecha: RouteStore.sheetDate})')
            perms1 = await pg.evaluate('async()=>(await window.OKD_ONLINE.api.me()).permission_overrides')
            res('CR-07 COMPUTADORA · vuelve a su panel y menú de siempre SIN perder el trabajo sin guardar; rol y permisos intactos', back['operario'] and back['nav'] > 0 and back['fecha'] == '2099-12-31'
                and sw3 and 'ESTÁS COMO: Operario Depósito' in sw3['txt'] and perms0 == perms1, {'panel': back, 'selector': sw3})
            DBSTATE[0] = await pg.evaluate(f'()=>localStorage.getItem("{K}")'); await ctx.close()
            # ================= OPERARIO · CELULAR =================
            ctx = await b.new_context(**MOB); pg = await ctx.new_page(); pg.on('dialog', lambda d: (dialogs.append(d.message), asyncio.ensure_future(d.accept())))
            await pg.goto(f'http://127.0.0.1:{PORT}/'); await pg.evaluate(f'(s)=>localStorage.setItem("{K}", s)', DBSTATE[0]); await login(pg, 'op.qa@example.invalid')
            swm = await visible_switch(pg); await pg.screenshot(path=os.path.join(SHOTS, 'celular_operario_panel.png'))
            await choose(pg, 'TRANSPORTISTA'); swm2 = await visible_switch(pg); ownm = await mine(pg); await pg.screenshot(path=os.path.join(SHOTS, 'celular_operario_mis_rutas.png'))
            await choose(pg, 'PERFIL'); backm = await pg.evaluate('()=>!document.getElementById("operario").hidden')
            res('CR-08 CELULAR · Operario: "ESTÁS COMO" visible debajo del nombre en el encabezado, cambia a Mis rutas (solo su hoja) y vuelve a su panel', swm and 'Operario Depósito' in swm['txt'] and not swm['enLateral'] and swm['visibles'] == 1
                and swm2 and 'Transportista' in swm2['txt'] and ownm == [rt['op']['id']] and backm, {'antes': swm, 'despues': swm2})
            DBSTATE[0] = await pg.evaluate(f'()=>localStorage.getItem("{K}")'); await ctx.close()
            # ================= ADMIN · COMPUTADORA =================
            ctx = await b.new_context(**DESK); pg = await ctx.new_page(); pg.on('dialog', lambda d: (dialogs.append(d.message), asyncio.ensure_future(d.accept())))
            await pg.goto(f'http://127.0.0.1:{PORT}/'); await pg.evaluate(f'(s)=>localStorage.setItem("{K}", s)', DBSTATE[0]); await login(pg, 'ad.qa@example.invalid')
            swa = await visible_switch(pg); await choose(pg, 'TRANSPORTISTA'); owna = await mine(pg); await deliver_first(pg, rt['ad']['id']); oa = await outcome(pg, rt['ad']['id'])
            await choose(pg, 'PERFIL'); backa = await pg.evaluate('()=>({panel: !!document.querySelector(".rc4who, #adNav, #rc4LegacyNav"), hash: location.hash})')
            res('CR-09 COMPUTADORA · Admin: cambia a Transportista, ve SOLO su hoja (no todas), la realiza y vuelve a su panel de Admin',
                swa and 'Admin General' in swa['txt'] and owna == [rt['ad']['id']] and oa == 'ENTREGADO' and backa['panel'], {'selector': swa, 'hojas': owna, 'vuelta': backa})
            DBSTATE[0] = await pg.evaluate(f'()=>localStorage.getItem("{K}")'); await ctx.close()
            # ================= SOLO LECTURA · CELULAR =================
            ctx = await b.new_context(**MOB); pg = await ctx.new_page(); pg.on('dialog', lambda d: (dialogs.append(d.message), asyncio.ensure_future(d.accept())))
            await pg.goto(f'http://127.0.0.1:{PORT}/'); await pg.evaluate(f'(s)=>localStorage.setItem("{K}", s)', DBSTATE[0]); await login(pg, 'ro.qa@example.invalid')
            swr = await visible_switch(pg); ro_actions = await pg.evaluate('()=>document.querySelectorAll("#drvStart, [data-o]").length')
            await choose(pg, 'TRANSPORTISTA'); ownr = await mine(pg); await deliver_first(pg, rt['ro']['id']); orr = await outcome(pg, rt['ro']['id'])
            ajena_ro = await pg.evaluate(f'''async()=>{{ try {{ await window.OKD_ONLINE.api.startRoute("{rt['gb']['id']}", 1); return 'aceptada'; }} catch(e) {{ return e.code; }} }}''')
            await choose(pg, 'PERFIL'); swr2 = await visible_switch(pg)
            res('CR-10 CELULAR · Solo Lectura: su vista sin edición; como Transportista registra entregas SOLO en su ruta; nada sobre rutas ajenas',
                swr and 'Solo lectura' in swr['txt'] and ownr == [rt['ro']['id']] and orr == 'ENTREGADO' and ajena_ro == 'FORBIDDEN' and swr2 and 'Solo lectura' in swr2['txt'], {'selector': swr, 'hojas': ownr, 'ajena': ajena_ro})
            DBSTATE[0] = await pg.evaluate(f'()=>localStorage.getItem("{K}")'); await ctx.close()
            # ================= URL directa sin el permiso =================
            ctx = await b.new_context(**DESK); pg = await ctx.new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
            await pg.goto(f'http://127.0.0.1:{PORT}/'); await pg.evaluate(f'(s)=>localStorage.setItem("{K}", s)', DBSTATE[0]); await login(pg, 'sp.qa@example.invalid')
            nosw = await visible_switch(pg); await pg.evaluate('()=>{location.hash="#/mis-rutas"}'); await pg.wait_for_timeout(1500)
            blocked = await pg.evaluate('()=>!!document.getElementById("b403") && document.getElementById("noPanel").hidden')
            res('CR-11 sin el permiso: no ve el selector y entrar por URL directa a #/mis-rutas da "acceso no autorizado"', nosw is None and blocked, {'selector': nosw, 'bloqueado': blocked})
            await ctx.close()
            # ================= REVOCACIÓN con la sesión ABIERTA =================
            ctx = await b.new_context(**MOB); pg = await ctx.new_page(); alerts = []
            pg.on('dialog', lambda d: (alerts.append(d.message), asyncio.ensure_future(d.accept())))
            await pg.goto(f'http://127.0.0.1:{PORT}/'); await pg.evaluate(f'(s)=>localStorage.setItem("{K}", s)', DBSTATE[0]); await login(pg, 'op.qa@example.invalid')
            await choose(pg, 'TRANSPORTISTA'); await pg.locator(f'[data-open="{rt["op"]["id"]}"]').click(); await pg.wait_for_timeout(1000)
            # el administrador quita el permiso mientras el operador tiene la app abierta (cambio en el "servidor" de la demo)
            await pg.evaluate(f'()=>{{ const d=JSON.parse(localStorage.getItem("{K}")); const u=d.users.find(x=>x.id==="{ids['op']}"); delete u.permission_overrides["routes.receive_internal"]; localStorage.setItem("{K}", JSON.stringify(d)); }}')
            sid2 = await pg.evaluate(f'()=>JSON.parse(localStorage.getItem("{K}")).routes2.find(r=>r.id==="{rt["op"]["id"]}").stops[1].id')
            if await pg.locator(f'.drv-stop[data-s="{sid2}"] [data-arrive]').count(): await pg.locator(f'.drv-stop[data-s="{sid2}"] [data-arrive]').click(); await pg.wait_for_timeout(2500)
            if await pg.locator(f'.drv-stop[data-s="{sid2}"] [data-o="ENTREGADO"]').count():
                await pg.locator(f'.drv-stop[data-s="{sid2}"] [data-o="ENTREGADO"]').click(); await pg.locator(f'.drv-stop[data-s="{sid2}"] [data-f="recv"]').fill('No debería guardarse'); await sign(pg, sid2)
                await pg.locator(f'.drv-stop[data-s="{sid2}"] [data-save]').click()
            await pg.wait_for_timeout(4000); await dismiss(pg)
            after = await pg.evaluate(f'''()=>({{ s2: JSON.parse(localStorage.getItem("{K}")).routes2.find(r=>r.id==="{rt['op']['id']}").stops[1].outcome,
              s1: JSON.parse(localStorage.getItem("{K}")).routes2.find(r=>r.id==="{rt['op']['id']}").stops[0].outcome, operario: !document.getElementById("operario").hidden,
              selector: !!document.querySelector("[data-rolesw-box]") }})''')
            res('CR-12 se QUITA el permiso con la app abierta: la acción se rechaza, vuelve a su perfil, sin selector, y lo registrado se conserva',
                after['s2'] == 'PENDIENTE' and after['s1'] == 'ENTREGADO' and after['operario'] and not after['selector'] and any('permiso' in a for a in alerts), {'estado': after, 'avisos': alerts[-2:]})
            DBSTATE[0] = await pg.evaluate(f'()=>localStorage.getItem("{K}")'); await ctx.close()
            # ---- el administrador ve sus hojas pendientes para reasignarlas (sin reasignación automática) y no se le puede asignar otra ----
            ctx = await b.new_context(**DESK); pg = await ctx.new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
            await pg.goto(f'http://127.0.0.1:{PORT}/'); await pg.evaluate(f'(s)=>localStorage.setItem("{K}", s)', DBSTATE[0]); await login(pg, 'admin@okdespacho.demo')
            pub2 = await pg.evaluate(PUB, ids['op'])
            await pg.evaluate('()=>{location.hash="#/usuarios"}'); await pg.wait_for_timeout(2000); await dismiss(pg)
            await pg.locator('tr', has_text='Operario QA').first.locator('[data-a="perms"], [data-act="perms"], button:has-text("PERMISOS"), button:has-text("Permisos")').first.click(); await pg.wait_for_timeout(1200)
            pend = await pg.evaluate('()=>(document.getElementById("permPending")||{}).innerText||""')
            still = await pg.evaluate(f'()=>JSON.parse(localStorage.getItem("{K}")).routes2.find(r=>r.id==="{rt["op"]["id"]}").responsable_id')
            res('CR-13 sin el permiso se rechaza una nueva asignación', 'error' in pub2, pub2)
            res('CR-14 el administrador ve las hojas pendientes del usuario para reasignarlas con el flujo existente (no se reasignan solas)',
                rt['op']['number'] in pend and 'Reasignar' in pend and still == ids['op'], pend)
            await ctx.close()
            # ================= TRANSPORTISTA ACTUAL (Gabriel) =================
            ctx = await b.new_context(**MOB); pg = await ctx.new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
            await pg.goto(f'http://127.0.0.1:{PORT}/'); await pg.evaluate(f'(s)=>localStorage.setItem("{K}", s)', DBSTATE[0]); await login(pg, 'gabriel@okdespacho.demo')
            gsw = await visible_switch(pg); gown = rt['gb']['id'] in await mine(pg)
            await deliver_first(pg, rt['gb']['id']); og = await outcome(pg, rt['gb']['id'])
            res('CR-15 el Transportista Interno actual: sin selector, ve y realiza su hoja como siempre', gsw is None and gown and og == 'ENTREGADO', {'selector': gsw, 'resultado': og})
            res('CR-16 no se crearon usuarios ni transportistas duplicados', await pg.evaluate(f'''()=>{{ const d=JSON.parse(localStorage.getItem("{K}"));
              const em=d.users.map(u=>u.email); return em.length === new Set(em).size && (d.carriers||[]).filter(c=>c.id==='INTERNO').length <= 1; }}'''), '')
            await ctx.close()
          finally: await b.close()
    finally:
        if srv.poll() is None: srv.terminate(); srv.wait(5)
    print('TOTAL', sum(1 for r in R if r[1] == 'PASS'), 'PASS /', sum(1 for r in R if r[1] == 'FAIL'), 'FAIL · esperados', EXPECTED)
    return R
DBSTATE = ['']
if __name__ == '__main__':
    try: rr = asyncio.run(main())
    except Exception as e: traceback.print_exc(); print('ERROR:', repr(e)); sys.exit(2)
    if len(rr) != EXPECTED: print('ERROR: se ejecutaron %d de %d' % (len(rr), EXPECTED)); sys.exit(2)
    sys.exit(1 if any(r[1] != 'PASS' for r in rr) else 0)
