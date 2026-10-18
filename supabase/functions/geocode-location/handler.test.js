import { handle, buildQuery, analyze, nominatimCandidates, arcgisCandidates, makeLimiter, makeCache } from './handler.js';
const eq = (a, b, m) => { if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error((m || '') + ' ' + JSON.stringify(a) + ' ≠ ' + JSON.stringify(b)); };
const ok = (c, m) => { if (!c) throw new Error(m || 'falló'); };
const req = (body, jwt = 'tok') => new Request('http://x', { method: 'POST', headers: { authorization: 'Bearer ' + jwt, 'content-type': 'application/json' }, body: JSON.stringify(body) });
const NOM_HOUSE = [{ lat: '-32.8901', lon: '-68.8401', display_name: 'San Juan 500, Ciudad, Mendoza', importance: 0.4, address: { house_number: '500', road: 'San Juan' } }];
const deps = (over = {}) => ({ getUser: async j => j === 'tok' ? { id: 'u1' } : null, canManage: async () => true, nominatim: async () => NOM_HOUSE, arcgis: async () => ({ candidates: [] }),
  limiter: makeLimiter({ max: 3 }), cache: makeCache(), ...over });

Deno.test('GEO-01 "San Juan" es la calle de Mendoza: contexto Mendoza, Argentina por defecto y sin anteponer el nombre del punto', () => {
  eq(buildQuery('San Juan 500'), 'San Juan 500, Mendoza, Argentina');
  eq(buildQuery('  Montecaseros   1234 , Mendoza '), 'Montecaseros 1234 , Mendoza, Argentina');
});
Deno.test('GEO-02 Exige sesión y permiso de administrar G2', async () => {
  eq((await handle(req({ address: 'x' }, ''), deps())).status, 401);
  eq((await handle(req({ address: 'x' }, 'otro'), deps())).status, 401);
  eq((await handle(req({ address: 'x' }), deps({ canManage: async () => false }))).status, 403);
});
Deno.test('GEO-03 Límite por usuario (429) y caché (no vuelve a consultar al proveedor)', async () => {
  let calls = 0; const d = deps({ nominatim: async () => { calls++; return NOM_HOUSE; } });
  const r1 = await (await handle(req({ address: 'San Juan 500' }), d)).json(); const r2 = await (await handle(req({ address: 'san juan 500' }), d)).json();
  ok(r1.ok && r2.cached && calls === 1, 'caché');
  await handle(req({ address: 'otra 1' }), d); eq((await handle(req({ address: 'otra 2' }), d)).status, 429);
});
Deno.test('GEO-04 Una sola dirección con altura: lista sin ambigüedad; resultado y fuente para guardar', async () => {
  const r = await (await handle(req({ address: 'San Juan 500' }), deps())).json();
  ok(r.ok && !r.ambiguous && !r.needs_review && r.best.precision === 'ADDRESS' && r.result.lat === -32.8901 && r.best.source.includes('Nominatim') && r.best.display_name);
});
Deno.test('GEO-05 No acepta a ciegas el primero: varias alturas distintas → ambiguo, candidatos para elegir', () => {
  const c = nominatimCandidates([{ lat: '-32.89', lon: '-68.84', importance: 0.3, address: { house_number: '500', road: 'San Juan' } },
    { lat: '-32.95', lon: '-68.80', importance: 0.5, address: { house_number: '500', road: 'San Juan' } }]);
  const a = analyze(c); ok(a.ambiguous && a.needs_review && a.candidates.length === 2 && /elegí/.test(a.warning));
});
Deno.test('GEO-06 Resultado de nivel barrio/localidad o solo calle → marcado como impreciso', () => {
  const area = analyze(nominatimCandidates([{ lat: '-33.08', lon: '-68.47', importance: 0.6, addresstype: 'suburb', address: { suburb: 'Montecaseros' } }]));
  ok(area.best.precision === 'AREA' && area.needs_review && /aproximado/.test(area.warning));
  const st = analyze(arcgisCandidates({ candidates: [{ location: { x: -68.84, y: -32.89 }, score: 90, attributes: { Addr_type: 'StreetName', Match_addr: 'San Juan, Mendoza' } }] }));
  ok(st.best.precision === 'STREET' && st.needs_review);
});
Deno.test('GEO-07 Descarta resultados fuera de Mendoza (p. ej. provincia de San Juan)', () => {
  const a = analyze(nominatimCandidates([{ lat: '-31.53', lon: '-68.52', importance: 0.9, address: { house_number: '500', road: 'X', state: 'San Juan' } }]));
  ok(!a.best && a.candidates.length === 0);
});
Deno.test('GEO-08 Si Nominatim no da altura exacta, usa ArcGIS como respaldo; sin resultados → 404 claro', async () => {
  const d = deps({ nominatim: async () => [], arcgis: async () => ({ candidates: [{ location: { x: -68.84, y: -32.89 }, score: 98, attributes: { Addr_type: 'PointAddress', Match_addr: 'San Juan 500, Mendoza' } }] }) });
  const r = await (await handle(req({ address: 'San Juan 500' }), d)).json(); ok(r.ok && r.best.source.includes('ArcGIS') && r.best.precision === 'ADDRESS');
  eq((await handle(req({ address: 'zzz 1' }), deps({ nominatim: async () => [], arcgis: async () => ({ candidates: [] }) }))).status, 404);
});

