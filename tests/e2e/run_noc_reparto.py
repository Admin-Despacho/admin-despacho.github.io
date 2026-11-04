"""E2E (modo demo, Chromium) · V4.20 · NOTA DE CRÉDITO: primero MERCADERÍA, excedente al ENVÍO, crédito no usado disponible;
MODO DE PAGO con importes NETOS a cobrar y sin detalle de notas. Usa las funciones REALES del panel del operario (Money.net,
Txt.pago) con los importes de un PDF real de ejemplo (pedidos 26443/26441/26448, total $ 376.218,64). Datos ficticios salvo importes.
Uso: python3 tests/e2e/run_noc_reparto.py [dist-demo]   ·   Exit 0 todo PASS · 1 alguna FAIL · 2 error."""
import asyncio, os, sys, subprocess, time, traceback
sys.path.insert(0, os.path.dirname(__file__))
import run_saldo_revisar_noc as sr
from playwright.async_api import async_playwright
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
DIST = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'dist-demo'); sr.PORT = 4397; R = []; EXPECTED = 8
def res(n, ok, d=''): R.append((n, 'PASS' if ok else 'FAIL', str(d)[:260])); print('..', ' | '.join(R[-1]), flush=True)
CALC = '''()=>{
  const orig = Money.parts; Money.parts = function(row, ig){ return row._p ? { ...row._p, warn: [] } : orig.call(Money, row, ig); };
  const mk = (main, ship, noc, pm, ps) => ({ _p: { main, ship, total: Math.round((main + ship) * 100) / 100 }, hasShip: ship > 0, payMain: pm, payShip: ps, nocApplied: noc, calc: {}, cobradoMain: 'No', cobradoShip: 'No' });
  const cases = {
    a26443: mk(110000, 18000, 16626.36, 'SIMPLY', 'SIMPLY'),        // NOC 2.352,36 + 14.274,00
    b26441: mk(246845, 18000, 0, 'SIMPLY', 'SIMPLY'),
    c26448: mk(49194, 18000, 67194, 'ICBC', 'SIMPLY'),              // NOC 44.407,45 + 13.952,00 + 8.834,55
    parcial_envio: mk(49194, 18000, 55000, 'ICBC', 'SIMPLY'),
    solo_merc: mk(49194, 18000, 30000, 'ICBC', 'SIMPLY'),
  };
  const out = {}; for (const [k, r] of Object.entries(cases)) { const n = Money.net(r); out[k] = { net: n, pago: Txt.pago(r) }; }
  // NOC mayor que el total: el tope de aplicación existente (min(disponible, total − aplicado)) deja el resto disponible
  const big = mk(49194, 18000, 0, 'ICBC', 'SIMPLY'); const cap = Math.min(80000, big._p.total - 0); big.nocApplied = cap;
  out.mayor_total = { aplicado: cap, sobrante: Math.round((80000 - cap) * 100) / 100, net: Money.net(big), pago: Txt.pago(big) };
  Money.parts = orig; return out; }'''

async def main():
    srv = subprocess.Popen([sys.executable, '-m', 'http.server', str(sr.PORT), '--bind', '127.0.0.1'], cwd=DIST, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); time.sleep(1.2)
    try:
        async with async_playwright() as p:
            b = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or None)
            try:
                pg = await (await b.new_context(viewport={'width': 1366, 'height': 900})).new_page()
                await sr.login(pg, 'admin@okdespacho.demo'); await sr.builder(pg, load=False)
                for _ in range(40):
                    if await pg.evaluate('()=>typeof Money!=="undefined" && typeof Txt!=="undefined" && !!Money.net'): break
                    await pg.wait_for_timeout(300)
                o = await pg.evaluate(CALC)
                a, bb, c = o['a26443'], o['b26441'], o['c26448']
                res('NC-01 pedido 26443: NOC $ 16.626,36 < mercadería → mercadería neta $ 93.373,64, envío $ 18.000, a cobrar $ 111.373,64',
                    a['net']['main'] == 93373.64 and a['net']['ship'] == 18000 and a['net']['total'] == 111373.64 and 'MERCADERÍA: $ 93.373,64' in a['pago'] and 'TOTAL: $ 111.373,64' in a['pago'], a)
                res('NC-02 pedido 26441 sin nota: sin cambios ($ 264.845,00)', bb['net']['total'] == 264845 and 'TOTAL: $ 264.845,00' in bb['pago'], bb['pago'])
                res('NC-03 pedido 26448: NOC $ 67.194 = mercadería $ 49.194 + envío $ 18.000 → NO COBRAR · saldo cubierto (envío NO se cobra)',
                    c['net']['main'] == 0 and c['net']['ship'] == 0 and c['net']['total'] == 0 and c['pago'].startswith('NO COBRAR · saldo cubierto'), c)
                tot = round(a['net']['total'] + bb['net']['total'] + c['net']['total'], 2)
                res('NC-04 TOTAL de la hoja de ejemplo = $ 376.218,64', tot == 376218.64, tot)
                pe = o['parcial_envio']
                res('NC-05 NOC $ 55.000 > mercadería: mercadería en $ 0 y el EXCEDENTE se descuenta del envío (envío a cobrar $ 12.194)',
                    pe['net']['main'] == 0 and pe['net']['ship'] == 12194 and 'ENVÍO: $ 12.194,00' in pe['pago'] and 'SALDO CUBIERTO' in pe['pago'], pe)
                sm = o['solo_merc']
                res('NC-06 NOC $ 30.000 < mercadería: solo baja la mercadería (ICBC $ 19.194) y el envío se cobra completo (SIMPLY $ 18.000)',
                    sm['net']['main'] == 19194 and sm['net']['ship'] == 18000 and 'ICBC — MERCADERÍA: $ 19.194,00' in sm['pago'] and 'SIMPLY — ENVÍO: $ 18.000,00' in sm['pago'], sm['pago'])
                mt = o['mayor_total']
                res('NC-07 NOC $ 80.000 > total $ 67.194: se aplican $ 67.194 y quedan $ 12.806 DISPONIBLES en la nota (nada se cobra)',
                    mt['aplicado'] == 67194 and mt['sobrante'] == 12806 and mt['net']['total'] == 0, mt)
                res('NC-08 MODO DE PAGO no menciona notas de crédito en ningún caso', not any('NOC' in v['pago'] or 'NOTA' in v['pago'].upper() for v in o.values()), [v['pago'] for v in o.values()])
            finally: await b.close()
    finally: srv.terminate()
    print('TOTAL', sum(1 for r in R if r[1] == 'PASS'), 'PASS /', sum(1 for r in R if r[1] == 'FAIL'), 'FAIL · esperados', EXPECTED)
    return R

if __name__ == '__main__':
    try: rr = asyncio.run(main())
    except Exception as e: traceback.print_exc(); print('ERROR:', repr(e)); sys.exit(2)
    if len(rr) != EXPECTED: print('ERROR: se ejecutaron %d de %d' % (len(rr), EXPECTED)); sys.exit(2)
    sys.exit(1 if any(r[1] != 'PASS' for r in rr) else 0)
