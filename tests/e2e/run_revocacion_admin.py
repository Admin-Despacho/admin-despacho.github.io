"""E2E (modo demo) · Admin con "Permitir asignación de hojas de ruta": opera su hoja interna; al QUITARLE el permiso, las operaciones
reales como chofer se rechazan (aunque su rol tenga routes.view_assigned), y conserva sus funciones de Admin. Usuarios ficticios.
Exit 0 PASS · 1 FAIL · 2 error."""
import asyncio, os, sys, traceback
sys.path.insert(0, os.path.dirname(__file__))
import run_cambiar_rol as cr
from playwright.async_api import async_playwright
cr.PORT = 4386; K = cr.K; R = []; EXPECTED = 4
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:220])); print('..', ' | '.join(R[-1]), flush=True)
OP = '''async(a)=>{ const [kind, rid] = a; const A = window.OKD_ONLINE.api; const d = JSON.parse(localStorage.getItem("%s")); const r = d.routes2.find(x=>x.id===rid);
  try { if (kind === 'start') await A.startRoute(rid, 60000 + Math.floor(Math.random()*1000));
        else await A.setStopOutcome(r.stops[0].id, 'ENTREGADO', null, null, 'rev-'+Date.now(), {evidence:{receiver_name:'Encargado', signature_png_b64:'iVBORw0KGgo='}, location:{lat:-32.895, lon:-68.845}});
        return 'aceptada'; } catch(e) { return e.code || e.message; } }''' % K
async def main():
    srv = cr.serve()
    try:
        async with async_playwright() as p:
          b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
          try:
            ctx = await b.new_context(**cr.DESK); pg = await ctx.new_page(); pg.on('dialog', lambda d: asyncio.ensure_future(d.accept()))
            await pg.goto(f'http://127.0.0.1:{cr.PORT}/'); await pg.evaluate('()=>localStorage.clear()'); await cr.login(pg, 'admin@okdespacho.demo')
            ids = await pg.evaluate(cr.SETUP, cr.USERS)
            await pg.evaluate(f'async()=>window.OKD_ONLINE.api.setUserPermission("{ids["ad"]}", "routes.receive_internal", "GRANT", "prueba")')
            r1 = await pg.evaluate(cr.PUB, ids['ad']); r2 = await pg.evaluate(cr.PUB, ids['ad'])
            await cr.logout(pg); await cr.login(pg, 'ad.qa@example.invalid')
            ok1 = await pg.evaluate(OP, ['start', r1['id']])
            res('RA-01 Admin con el permiso opera su hoja interna (inicia el recorrido)', ok1 == 'aceptada', ok1)
            await pg.evaluate(f'()=>{{ const d=JSON.parse(localStorage.getItem("{K}")); const u=d.users.find(x=>x.id==="{ids["ad"]}"); delete u.permission_overrides["routes.receive_internal"]; localStorage.setItem("{K}", JSON.stringify(d)); }}')
            out = await pg.evaluate(OP, ['outcome', r1['id']]); st = await pg.evaluate(OP, ['start', r2['id']])
            res('RA-02 QUITADO el permiso: registrar una entrega en su hoja interna se RECHAZA (aunque el rol tenga routes.view_assigned)', out == 'FORBIDDEN', out)
            res('RA-03 QUITADO el permiso: iniciar otra hoja interna que tenía asignada se RECHAZA', st == 'FORBIDDEN', st)
            adm = await pg.evaluate('''async()=>{ const A=window.OKD_ONLINE.api; const me=await A.me(); let users=null; try { users=(await A.listUsers()).length; } catch(e) { users=e.code; }
              return { rol: me.role, usuarios: users }; }''')
            res('RA-04 conserva su rol y sus funciones de Admin (lista de usuarios)', adm['rol'] == 'ADMIN' and isinstance(adm['usuarios'], int) and adm['usuarios'] > 0, adm)
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
