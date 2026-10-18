// geocode-location · lógica pura (testeable). index.ts solo conecta sesión, permisos, red y caché.
// Reglas (negocio): las ubicaciones G2 son de MENDOZA. "San Juan" es la CALLE San Juan de Mendoza, nunca la provincia.
// - No se antepone el nombre del punto a la dirección (un nombre como "Montecaseros" también es un distrito).
// - Contexto por defecto: Mendoza, Argentina, y la búsqueda se limita a la provincia de Mendoza.
// - No se acepta a ciegas el primer resultado: se devuelven candidatos con precisión y puntaje, y se avisa si es ambiguo o impreciso.
import { json, preflight } from '../_shared/http.js';

export const MENDOZA_VIEWBOX = '-70.7,-32.0,-66.4,-37.6';   // lon_min,lat_max,lon_max,lat_min (provincia de Mendoza)
export const clean = v => String(v ?? '').trim().replace(/\s+/g, ' ');
export function buildQuery(address) {
  const a = clean(address);
  return /mendoza/i.test(a) ? (/argentina/i.test(a) ? a : a + ', Argentina') : a + ', Mendoza, Argentina';
}
const inMendoza = (lat, lon) => lat <= -32.0 && lat >= -37.6 && lon >= -70.7 && lon <= -66.4;
// Precisión: ADDRESS (número de puerta), STREET (calle), AREA (barrio/localidad/distrito: no sirve para validar GPS de 200 m)
export function nominatimCandidates(rows) {
  return (Array.isArray(rows) ? rows : []).filter(h => h && h.lat != null && h.lon != null).map(h => {
    const ad = h.address || {}, lat = Number(h.lat), lon = Number(h.lon);
    const precision = ad.house_number ? 'ADDRESS' : (ad.road || ['road', 'street'].includes(h.addresstype) || h.class === 'highway') ? 'STREET' : 'AREA';
    return { lat: +lat.toFixed(7), lon: +lon.toFixed(7), display_name: clean(h.display_name), source: 'OpenStreetMap/Nominatim', precision,
      score: Math.round(Number(h.importance || 0) * 100), in_mendoza: inMendoza(lat, lon) };
  });
}
export function arcgisCandidates(body) {
  return ((body && body.candidates) || []).filter(c => c && c.location && c.location.y != null).map(c => {
    const t = (c.attributes && c.attributes.Addr_type) || '', lat = Number(c.location.y), lon = Number(c.location.x);
    const precision = ['PointAddress', 'Subaddress', 'StreetAddress', 'StreetAddressExt'].includes(t) ? 'ADDRESS' : ['StreetName', 'StreetInt', 'StreetMidBlock'].includes(t) ? 'STREET' : 'AREA';
    return { lat: +lat.toFixed(7), lon: +lon.toFixed(7), display_name: clean((c.attributes && c.attributes.Match_addr) || c.address), source: 'ArcGIS World Geocoding', precision,
      score: Math.round(Number(c.score || 0)), in_mendoza: inMendoza(lat, lon) };
  });
}
const RANK = { ADDRESS: 0, STREET: 1, AREA: 2 };
const dist = (a, b) => Math.hypot((a.lat - b.lat) * 111000, (a.lon - b.lon) * 94000);
// Ordena, descarta fuera de Mendoza y duplicados (< 30 m) y decide si hace falta que la persona elija
export function analyze(cands) {
  const list = cands.filter(c => c.in_mendoza).sort((a, b) => (RANK[a.precision] - RANK[b.precision]) || (b.score - a.score));
  const uniq = []; list.forEach(c => { if (!uniq.some(u => dist(u, c) < 30)) uniq.push(c); });
  const top = uniq.slice(0, 5), best = top[0] || null;
  const precise = top.filter(c => c.precision === 'ADDRESS');
  const ambiguous = top.length > 1 && (precise.length !== 1 || precise.some((c, i) => i > 0 && dist(c, best) > 150));
  const warning = !best ? null : best.precision === 'AREA' ? 'El resultado es aproximado (barrio/localidad): revisá o cargá las coordenadas a mano.'
    : best.precision === 'STREET' ? 'Se encontró la calle pero no la altura exacta: revisá el punto antes de guardar.' : ambiguous ? 'Hay varias coincidencias: elegí la correcta.' : null;
  return { candidates: top, best, ambiguous, needs_review: !best || ambiguous || best.precision !== 'ADDRESS', warning };
}
// Límite por usuario (ventana deslizante) y caché por consulta normalizada: protegen a Nominatim (máx. 1 req/s) y a la función
export function makeLimiter({ max = 10, windowMs = 60000, now = () => Date.now() } = {}) {
  const hits = new Map();
  return uid => { const t = now(), arr = (hits.get(uid) || []).filter(x => t - x < windowMs); if (arr.length >= max) { hits.set(uid, arr); return false; } arr.push(t); hits.set(uid, arr); return true; };
}
export function makeCache({ ttlMs = 24 * 3600 * 1000, max = 500, now = () => Date.now() } = {}) {
  const m = new Map();
  return { get: k => { const e = m.get(k); if (!e) return null; if (now() - e.t > ttlMs) { m.delete(k); return null; } return e.v; },
    set: (k, v) => { if (m.size >= max) m.delete(m.keys().next().value); m.set(k, { t: now(), v }); } };
}
/** deps: { getUser(jwt) → {id}|null, canManage(jwt) → bool, nominatim(q) → rows, arcgis(q) → body, limiter, cache } */
export async function handle(req, deps) {
  if (req.method === 'OPTIONS') return preflight();
  if (req.method !== 'POST') return json(405, { error: 'Método no permitido.' });
  const jwt = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  const user = jwt ? await deps.getUser(jwt) : null;
  if (!user) return json(401, { error: 'Iniciá sesión para buscar coordenadas.' });
  if (!(await deps.canManage(jwt))) return json(403, { error: 'Solo quien administra ubicaciones (G2) puede buscar coordenadas.' });
  if (!deps.limiter(user.id)) return json(429, { error: 'Demasiadas búsquedas seguidas. Esperá un minuto.' });
  const body = await req.json().catch(() => ({}));
  const address = clean(body.address);
  if (!address) return json(400, { error: 'Ingresá un domicilio para buscar.' });
  if (address.length > 200) return json(400, { error: 'Domicilio demasiado largo.' });
  const q = buildQuery(address), key = q.toLowerCase();
  const cached = deps.cache.get(key); if (cached) return json(200, { ok: true, cached: true, query: q, ...cached });
  let cands = [];
  try { cands = nominatimCandidates(await deps.nominatim(q)); } catch (_) { cands = []; }
  if (!analyze(cands).best || analyze(cands).best.precision !== 'ADDRESS') { try { cands = cands.concat(arcgisCandidates(await deps.arcgis(q))); } catch (_) { /* sin respaldo */ } }
  const out = analyze(cands);
  if (!out.best) return json(404, { error: 'No encontré ese domicilio en Mendoza. Probá con calle y altura, o cargá las coordenadas a mano.' });
  const res = { ...out, result: out.best };   // "result" se mantiene por compatibilidad con la pantalla anterior
  deps.cache.set(key, res);
  return json(200, { ok: true, query: q, ...res });
}

