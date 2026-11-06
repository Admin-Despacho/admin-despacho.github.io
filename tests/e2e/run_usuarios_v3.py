"""E2E (modo demo, Chromium) · V4.26 · USUARIOS Y PERMISOS · diseño V3: pestañas uniformes, búsqueda FIJA, tarjetas sin desplazamiento lateral,
panel con TODAS las acciones (mismas condiciones que antes) y editor integrado; notebook y Android. Uso: python3 run_usuarios_v3.py [dist-demo] [salida]"""
import asyncio, os, sys, traceback
sys.path.insert(0, os.path.dirname(__file__))
import run_driver_perfiles as dp
from playwright.async_api import async_playwright
dp.PORT = 4421; R = []; EXPECTED = 6
if len(sys.argv) > 1: dp.DIST = sys.argv[1]
OUT = sys.argv[2] if len(sys.argv) > 2 else '/tmp/okd_uv3'
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:300])); print('..', ' | '.join(R[-1]), flush=True)
ADD = '''()=>{const k="okd_online_demo_v2", d=JSON.parse(localStorage.getItem(k)); const a=d.users.find(u=>u.role==="ADMIN");
  const add=(id,email,role,name,st,ph)=>{ if(!d.users.some(u=>u.id===id)) d.users.push(Object.assign({}, a, {id, email, role, full_name:name, status:st, phone:ph, carriers:[], extra_perms:[], denied_perms:[], supervisor_user_id:null})); };
  add("u-op-v3","qa.opv3@okdespacho.demo","OPERARIO_DEPOSITO","Lucía Fernández QA","ACTIVO","261 555-0104"); add("u-inv-v3","qa.inv@okdespacho.demo","SOLO_LECTURA","Invitada QA","INVITACION_PENDIENTE","");
  localStorage.setItem(k, JSON.stringify(d));}'''
SIDE = '()=>({acts:[...document.querySelectorAll("#upSide [data-act]")].map(b=>b.dataset.act), editor:!!document.querySelector("#upSide #editModal"), sup:!!document.querySelector("#upSide #nuSup")})'
OVER = '''()=>{const inScroll=el=>{for(let p=el.parentElement;p;p=p.parentElement){const o=getComputedStyle(p).overflowX; if(o==="auto"||o==="scroll") return true;} return false;};
  return {over:document.documentElement.scrollWidth-document.documentElement.clientWidth, fuera:[...document.querySelectorAll("button,input,select")].filter(e=>{const r=e.getBoundingClientRect(); return r.width>0&&!inScroll(e)&&(r.right>innerWidth+1||r.left<-1);}).length}}'''
async def main():
    os.makedirs(OUT, exist_ok=True); srv = dp.serve()
    try:
        async with async_playwright() as p:
            b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
            try:
                ctx = await b.new_context(viewport={'width': 1366, 'height': 900}); pg = await ctx.new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
                await pg.goto(f'http://127.0.0.1:{dp.PORT}/'); await pg.evaluate('()=>localStorage.clear()'); await dp.login(pg, 'admin@okdespacho.demo'); await pg.evaluate(ADD)
                await pg.evaluate('()=>{location.hash="#/usuarios"}'); await pg.wait_for_timeout(1800)
                tabs = await pg.evaluate('()=>[...document.querySelectorAll("[data-v3tab]")].map(b=>b.textContent)'); sticky = await pg.evaluate('()=>getComputedStyle(document.querySelector(".v3-sticky")).position')
                await pg.fill('#ufSearch', '555-0104'); await pg.wait_for_timeout(300); byphone = await pg.evaluate('()=>[...document.querySelectorAll(".v3-row b")].map(b=>b.textContent)'); await pg.fill('#ufSearch', ''); await pg.wait_for_timeout(300)
                o = await pg.evaluate(OVER)
                res('UV-01 4 pestañas uniformes · búsqueda FIJA (sticky) · busca también por TELÉFONO · sin desplazamiento lateral ni controles cortados (notebook)',
                    len(tabs) == 4 and tabs[0].startswith('Usuarios') and sticky == 'sticky' and byphone == ['Lucía Fernández QA'] and o['over'] <= 0 and o['fuera'] == 0, {'pestañas': tabs, 'sticky': sticky, 'por_tel': byphone, **o})
                await pg.click('[data-pick="u-op-v3"]'); await pg.wait_for_timeout(700); s1 = await pg.evaluate(SIDE); await pg.screenshot(path=os.path.join(OUT, 'usuarios_v3_notebook.png'))
                res('UV-02 panel de un usuario ACTIVO: TODAS las acciones visibles (editar, restablecer, cerrar sesiones, permisos, deshabilitar, eliminar/archivar) y el editor (con Superior asignado) en el mismo panel',
                    set(['edit', 'reset_password', 'revoke_sessions', 'perms', 'disable', 'remove']) <= set(s1['acts']) and s1['editor'] and s1['sup'], s1)
                await pg.click('#upSide [data-act="disable"]'); await pg.wait_for_timeout(1500)
                st1 = await pg.evaluate('()=>JSON.parse(localStorage.getItem("okd_online_demo_v2")).users.find(u=>u.id==="u-op-v3").status'); s2 = await pg.evaluate(SIDE)
                await pg.click('#upSide [data-act="reactivate"]'); await pg.wait_for_timeout(1500)
                st2 = await pg.evaluate('()=>JSON.parse(localStorage.getItem("okd_online_demo_v2")).users.find(u=>u.id==="u-op-v3").status')
                res('UV-03 las acciones FUNCIONAN desde el panel (con confirmación): DESHABILITAR → aparece REACTIVAR → REACTIVAR', st1 == 'DESHABILITADO' and 'reactivate' in s2['acts'] and st2 == 'ACTIVO', {'tras_deshabilitar': st1, 'acciones': s2['acts'], 'tras_reactivar': st2})
                await pg.click('[data-pick="u-inv-v3"]'); await pg.wait_for_timeout(600); s3 = await pg.evaluate(SIDE)
                res('UV-04 invitación pendiente: REENVIAR y CANCELAR invitación disponibles en el panel', 'resend_invite' in s3['acts'] and 'cancel_invite' in s3['acts'], s3['acts'])
                info = {}
                for t in ('roles', 'jerarquia', 'actividad'):
                    await pg.click(f'[data-v3tab="{t}"]'); await pg.wait_for_timeout(500); info[t] = await pg.evaluate('()=>({cajas:document.querySelectorAll(".v3-box").length, filas:document.querySelectorAll(".v3-row").length, sticky:!!document.querySelector(".v3-sticky")})')
                await pg.screenshot(path=os.path.join(OUT, 'usuarios_v3_jerarquia_notebook.png'))
                res('UV-05 pestañas Roles y permisos (6 roles) · Jerarquía y equipos · Actividad: mismo diseño (encabezado fijo) y datos reales', info['roles']['cajas'] == 6 and info['jerarquia']['cajas'] >= 1 and info['actividad']['filas'] >= 3 and all(v['sticky'] for v in info.values()), info)
                await ctx.close()
                c2 = await b.new_context(viewport={'width': 412, 'height': 915}, is_mobile=True, device_scale_factor=2.625); m = await c2.new_page(); m.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
                await m.goto(f'http://127.0.0.1:{dp.PORT}/'); await m.evaluate('()=>localStorage.clear()'); await dp.login(m, 'admin@okdespacho.demo'); await m.evaluate(ADD)
                await m.evaluate('()=>{location.hash="#/usuarios"}'); await m.wait_for_timeout(1800); await m.click('[data-pick="u-op-v3"]'); await m.wait_for_timeout(1200)
                o2 = await m.evaluate(OVER); top = await m.evaluate('()=>Math.round(document.getElementById("upSide").getBoundingClientRect().top)'); await m.screenshot(path=os.path.join(OUT, 'usuarios_v3_android.png'))
                # No excluir contenedores con overflow: verificar recorte real y oclusión por el buscador.
                accessible = []
                for act in ['edit', 'reset_password', 'revoke_sessions', 'perms', 'disable', 'remove']:
                    btn = m.locator('#upSide [data-act="'+act+'"]')
                    await btn.evaluate('(e)=>e.scrollIntoView({block:"center"})'); await m.wait_for_timeout(200)
                    accessible.append(await btn.evaluate('''e=>{const r=e.getBoundingClientRect(), hit=document.elementFromPoint(r.x+r.width/2,r.y+r.height/2);
                      return r.left>=0&&r.right<=innerWidth&&r.top>=0&&r.bottom<=innerHeight&&e.contains(hit)&&e.scrollWidth<=e.clientWidth+1;}'''))
                    await btn.click(); await m.wait_for_timeout(600)
                    if act == 'perms':
                        assert await m.locator('#permModal').count() == 1
                        await m.locator('#permModal #umCancel').click()
                    if act == 'disable':
                        assert await m.evaluate('()=>JSON.parse(localStorage.getItem("okd_online_demo_v2")).users.find(u=>u.id==="u-op-v3").status') == 'DESHABILITADO'
                        await m.locator('#upSide [data-act="reactivate"]').click(); await m.wait_for_timeout(600)
                widths = await m.evaluate('()=>[...document.querySelectorAll("#upSide,.v3-actions,#upSide .udialog")].every(e=>e.scrollWidth<=e.clientWidth+1)')
                saved = await m.evaluate('()=>JSON.parse(localStorage.getItem("okd_online_demo_v2")).users.find(u=>u.id==="u-op-v3").status==="ACTIVO"')
                res('UV-06 ANDROID: editor visible bajo buscador, seis acciones accesibles y utilizables, sin recortes ni desplazamiento horizontal', o2['over'] <= 0 and o2['fuera'] == 0 and 0 <= top < 400 and all(accessible) and widths and saved, {**o2, 'panel_top': top,'acciones_accesibles':accessible,'sin_recortes':widths,'usuario_conservado':saved})
                await c2.close()
            finally: await b.close()
    finally: srv.terminate()
    print('TOTAL', sum(1 for r in R if r[1] == 'PASS'), 'PASS /', sum(1 for r in R if r[1] == 'FAIL'), 'FAIL · esperados', EXPECTED)
    return R
if __name__ == '__main__':
    try: rr = asyncio.run(main())
    except Exception as e: traceback.print_exc(); print('ERROR:', repr(e)); sys.exit(2)
    if len(rr) != EXPECTED: print('ERROR: se ejecutaron %d de %d' % (len(rr), EXPECTED)); sys.exit(2)
    sys.exit(1 if any(r[1] != 'PASS' for r in rr) else 0)
