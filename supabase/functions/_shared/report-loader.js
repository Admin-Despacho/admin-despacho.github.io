// =====================================================================
// INFORME CRISTIAN TORRES · carga COMPLETA de hojas para el informe (sin omisiones por el límite de filas del servidor)
// Lo usa la Edge Function commercial-reports (index.ts). Se prueba con una base simulada (tests/unit/report-loader.test.js).
//
//  · Paginación por CURSOR (id > último id, orden estable por id), no por desplazamiento: una fila borrada o insertada durante la
//    carga no hace saltear otra.
//  · El bucle sigue hasta recibir una página VACÍA: si el servidor devuelve menos filas que las pedidas (su límite máximo), no se corta.
//  · Hojas: de Cristian (report_group CRISTIAN_TORRES), que no sean BORRADOR ni CANCELADA (el motor vuelve a filtrar).
//  · Paradas y fechas históricas de publicación (audit_log ROUTE_PUBLISHED) con la misma técnica, por lotes de hojas.
//  · Sin duplicados: hojas y paradas se indexan por id; de la auditoría se toma la PRIMERA publicación de cada hoja.
//
// db (lo implementa index.ts con Supabase; cada método devuelve filas ordenadas por id ascendente, con id > after, hasta `limit`):
//   cristianCarrierIds() → [id]
//   routesAfter(carrierIds, after, limit) · stopsAfter(routeIds, after, limit) · auditAfter(routeIds, after, limit)
// =====================================================================
export const PAGE = 1000, CHUNK = 200;

// orden de ids igual que Postgres: numérico para bigint (audit_log), texto hexadecimal para uuid
const gt = (a, b) => (typeof a === 'number' && typeof b === 'number') ? a > b : String(a) > String(b);
async function all(fetchAfter, limit) {
  const out = []; let after = null;
  for (let guard = 0; guard < 100000; guard++) {
    const page = await fetchAfter(after, limit);
    if (!page || !page.length) return out;   // fin: página vacía
    out.push(...page);
    const last = page.reduce((m, r) => (m === null || gt(r.id, m) ? r.id : m), null);   // el MAYOR id de la página (robusto ante filas repetidas)
    if (after !== null && !gt(last, after)) throw new Error('Paginación sin avance (orden inestable)');
    after = last;
  }
  throw new Error('Paginación demasiado larga');
}

export async function loadCristianRoutes(db, { pageSize = PAGE, chunk = CHUNK } = {}) {
  const carriers = await db.cristianCarrierIds();
  if (!carriers.length) return [];
  const byId = new Map();
  for (const r of await all((after, limit) => db.routesAfter(carriers, after, limit), pageSize))
    if (!byId.has(String(r.id))) byId.set(String(r.id), { ...r, stops: [], published_at_hist: null });
  const ids = [...byId.keys()];
  // paradas de todas las hojas (sin duplicar por id), en orden de recorrido
  const seen = new Set();
  for (let i = 0; i < ids.length; i += chunk) {
    for (const s of await all((after, limit) => db.stopsAfter(ids.slice(i, i + chunk), after, limit), pageSize)) {
      const r = byId.get(String(s.route_id)); if (!r || seen.has(String(s.id))) continue;
      seen.add(String(s.id)); r.stops.push(s);
    }
  }
  for (const r of byId.values()) r.stops.sort((a, b) => (a.seq ?? 0) - (b.seq ?? 0) || String(a.id).localeCompare(String(b.id)));
  // hojas antiguas sin fecha de publicación: PRIMERA publicación registrada en audit_log (nunca la finalización)
  const missing = ids.filter(id => { const r = byId.get(id); return !r.published_at && !(r.dispatch_mode === 'EXTERNAL' && r.dispatched_at); });
  for (let i = 0; i < missing.length; i += chunk) {
    for (const e of await all((after, limit) => db.auditAfter(missing.slice(i, i + chunk), after, limit), pageSize)) {
      const r = byId.get(String(e.target_id)); if (!r) continue;
      if (!r.published_at_hist || Date.parse(e.at) < Date.parse(r.published_at_hist)) r.published_at_hist = e.at;
    }
  }
  return [...byId.values()];
}
