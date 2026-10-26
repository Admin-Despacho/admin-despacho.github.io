// Carga COMPLETA de hojas de Cristian (report-loader): más registros que el tamaño de página, límite del servidor menor que lo pedido,
// orden estable, sin pérdidas ni duplicados, fecha histórica = primera publicación. Base SIMULADA (datos ficticios).
import { describe, it, expect } from 'vitest';
import { loadCristianRoutes } from '../../supabase/functions/_shared/report-loader.js';

const hex = n => n.toString(16).padStart(8, '0') + '-0000-4000-8000-' + (n * 7919 % 1e12).toString(16).padStart(12, '0');
function fakeDb({ cap = 5, routes = 53, stopsPer = 5, onPage } = {}) {
  const R = [], S = [], A = []; let aid = 0;
  for (let i = 0; i < routes; i++) {
    const id = hex((i * 2654435761) % 4294967291);   // ids "desordenados" respecto de la creación
    const status = i % 17 === 0 ? 'BORRADOR' : i % 19 === 0 ? 'CANCELADA' : ['PUBLICADA', 'EN_CURSO', 'COMPLETADA'][i % 3];
    const old = i % 4 === 0;   // hojas antiguas sin published_at
    R.push({ id, number: '01-' + String(i).padStart(6, '0'), carrier_id: i % 2 ? 'CT-ESTE' : 'CT-ALR', operational_status: status,
      published_at: old ? null : new Date(Date.UTC(2025, 0, 1 + i)).toISOString(), dispatched_at: null, dispatch_mode: 'APP' });
    for (let k = 0; k < stopsPer; k++) S.push({ id: hex(1e6 + i * 100 + k), route_id: id, seq: stopsPer - k, shipping_fee: 1000 });
    if (old) { A.push({ id: ++aid, target_id: id, at: new Date(Date.UTC(2024, 5, 1 + i)).toISOString() });            // primera publicación
               A.push({ id: ++aid, target_id: id, at: new Date(Date.UTC(2024, 6, 1 + i)).toISOString() }); }         // re-publicación posterior
  }
  R.push({ id: hex(999999999), number: 'OTRO-1', carrier_id: 'UCO', operational_status: 'PUBLICADA', published_at: '2025-01-01T12:00:00Z' });   // de otro transportista
  const gt = (a, b) => (typeof a === 'number' ? a > b : String(a) > String(b));
  const page = (rows, after, limit) => { onPage && onPage(); return rows.filter(r => after == null || gt(r.id, after)).sort((a, b) => (gt(a.id, b.id) ? 1 : -1)).slice(0, Math.min(limit, cap)); };
  const calls = { routes: 0, stops: 0, audit: 0 };
  return { R, S, A, calls, db: {
    async cristianCarrierIds() { return ['CT-ALR', 'CT-ESTE']; },
    async routesAfter(ids, after, limit) { calls.routes++; return page(R.filter(r => ids.includes(r.carrier_id) && !['BORRADOR', 'CANCELADA'].includes(r.operational_status)), after, limit); },
    async stopsAfter(ids, after, limit) { calls.stops++; return page(S.filter(s => ids.includes(s.route_id)), after, limit); },
    async auditAfter(ids, after, limit) { calls.audit++; return page(A.filter(a => ids.includes(a.target_id)), after, limit); } } };
}
describe('Carga paginada de hojas de Cristian', () => {
  it('LOAD-01 más registros que la página y servidor con límite MENOR que lo pedido: carga TODO, sin pérdidas ni duplicados', async () => {
    const f = fakeDb({ cap: 5 }); const out = await loadCristianRoutes(f.db, { pageSize: 7, chunk: 6 });
    const expected = f.R.filter(r => r.carrier_id !== 'UCO' && !['BORRADOR', 'CANCELADA'].includes(r.operational_status));
    expect(expected.length).toBeGreaterThan(7 * 3);
    expect(out.map(r => r.id).sort()).toEqual(expected.map(r => r.id).sort());
    expect(new Set(out.map(r => r.id)).size).toBe(out.length);
    const stops = out.flatMap(r => r.stops); expect(stops.length).toBe(expected.length * 5); expect(new Set(stops.map(s => s.id)).size).toBe(stops.length);
    expect(f.calls.routes).toBeGreaterThan(Math.ceil(expected.length / 5));   // varias páginas reales
  });
  it('LOAD-02 orden estable: paradas en orden de recorrido; dos cargas dan el mismo resultado', async () => {
    const a = await loadCristianRoutes(fakeDb().db, { pageSize: 7, chunk: 6 }), b = await loadCristianRoutes(fakeDb().db, { pageSize: 7, chunk: 6 });
    expect(a.every(r => r.stops.every((s, i) => i === 0 || r.stops[i - 1].seq <= s.seq))).toBe(true);
    expect(JSON.stringify(a)).toBe(JSON.stringify(b));
  });
  it('LOAD-03 hojas antiguas sin published_at: fecha = PRIMERA publicación de audit_log (también si hay más de una página de auditoría)', async () => {
    const f = fakeDb({ cap: 3 }); const out = await loadCristianRoutes(f.db, { pageSize: 4, chunk: 5 });
    const old = out.filter(r => !r.published_at); expect(old.length).toBeGreaterThan(4);
    for (const r of old) { const first = f.A.filter(a => a.target_id === r.id).map(a => a.at).sort()[0]; expect(r.published_at_hist).toBe(first); }
    expect(out.filter(r => r.published_at).every(r => r.published_at_hist === null)).toBe(true);   // no se pisa la fecha real
  });
  it('LOAD-04 si se BORRA una hoja durante la carga, no se saltea ninguna otra (cursor, no desplazamiento)', async () => {
    let n = 0; const f = fakeDb({ cap: 5, onPage: () => { if (++n === 3) { const i = f.R.findIndex(r => r.number === '01-000001'); if (i >= 0) f.R.splice(i, 1); } } });
    const out = await loadCristianRoutes(f.db, { pageSize: 7, chunk: 6 });
    const survivors = f.R.filter(r => r.carrier_id !== 'UCO' && !['BORRADOR', 'CANCELADA'].includes(r.operational_status) && r.number !== '01-000001');
    for (const r of survivors) expect(out.some(x => x.id === r.id)).toBe(true);
  });
  it('LOAD-05 filas repetidas devueltas por el servidor no se duplican', async () => {
    const f = fakeDb({ cap: 5 }); const orig = f.db.stopsAfter;
    f.db.stopsAfter = async (ids, after, limit) => { const p = await orig(ids, after, limit); return p.length ? p.concat([p[0]]) : p; };   // repite una fila
    const out = await loadCristianRoutes(f.db, { pageSize: 7, chunk: 6 }); const stops = out.flatMap(r => r.stops);
    expect(new Set(stops.map(s => s.id)).size).toBe(stops.length);
  });
});
