import { json, preflight } from '../_shared/http.js';

const clean = (v: unknown) => String(v ?? '').trim().replace(/\s+/g, ' ');

async function nominatim(q: string) {
  const u = new URL('https://nominatim.openstreetmap.org/search');
  u.searchParams.set('format', 'jsonv2');
  u.searchParams.set('limit', '1');
  u.searchParams.set('countrycodes', 'ar');
  u.searchParams.set('addressdetails', '1');
  u.searchParams.set('q', q);
  const r = await fetch(u, {
    headers: {
      'Accept': 'application/json',
      'Accept-Language': 'es-AR,es;q=0.9',
      'User-Agent': 'OK-Despacho/1.0 (contact: despachoapp26@gmail.com)'
    }
  });
  if (!r.ok) return null;
  const rows = await r.json();
  const hit = Array.isArray(rows) ? rows[0] : null;
  if (!hit || hit.lat == null || hit.lon == null) return null;
  return {
    lat: Number(hit.lat).toFixed(7),
    lon: Number(hit.lon).toFixed(7),
    display_name: clean(hit.display_name),
    source: 'OpenStreetMap/Nominatim'
  };
}

async function arcgis(q: string) {
  const u = new URL('https://geocode.arcgis.com/arcgis/rest/services/World/GeocodeServer/findAddressCandidates');
  u.searchParams.set('f', 'json');
  u.searchParams.set('SingleLine', q);
  u.searchParams.set('countryCode', 'ARG');
  u.searchParams.set('maxLocations', '1');
  u.searchParams.set('outFields', 'Match_addr,Addr_type');
  const r = await fetch(u, { headers: { 'Accept': 'application/json' } });
  if (!r.ok) return null;
  const body = await r.json();
  const hit = body && Array.isArray(body.candidates) ? body.candidates[0] : null;
  if (!hit || !hit.location || hit.location.y == null || hit.location.x == null) return null;
  return {
    lat: Number(hit.location.y).toFixed(7),
    lon: Number(hit.location.x).toFixed(7),
    display_name: clean(hit.address || q),
    source: 'ArcGIS World Geocoding'
  };
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return preflight();
  if (req.method !== 'POST') return json(405, { error: 'Método no permitido.' });

  try {
    const body = await req.json().catch(() => ({}));
    const address = clean(body.address);
    const name = clean(body.name);
    if (!address) return json(400, { error: 'Ingresá un domicilio para buscar.' });

    const parts = [name, address];
    if (!/mendoza/i.test(address)) parts.push('Mendoza');
    if (!/argentina/i.test(address)) parts.push('Argentina');
    const q = parts.filter(Boolean).join(', ');

    let result = null;
    try { result = await nominatim(q); } catch (_) { result = null; }
    if (!result) {
      try { result = await arcgis(q); } catch (_) { result = null; }
    }

    if (!result) return json(404, { error: 'No encontré ese domicilio. Probá agregando localidad y provincia.' });
    return json(200, { ok: true, result });
  } catch (e) {
    return json(500, { error: String((e as Error)?.message || e) });
  }
});
