import { CORS, json, preflight } from '../_shared/http.js';

const clean = (v: unknown) => String(v ?? '').trim().replace(/\s+/g, ' ');

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
        'User-Agent': 'OK-Despacho/1.0 (admin-despacho.github.io)'
      }
    });
    if (!r.ok) return json(502, { error: 'El servicio de mapas no respondió. Probá nuevamente.' });
    const rows = await r.json();
    const hit = Array.isArray(rows) ? rows[0] : null;
    if (!hit || hit.lat == null || hit.lon == null) return json(404, { error: 'No encontré ese domicilio. Agregá localidad/provincia y volvé a buscar.' });

    return json(200, { ok: true, result: {
      lat: Number(hit.lat).toFixed(7),
      lon: Number(hit.lon).toFixed(7),
      display_name: clean(hit.display_name),
      source: 'OpenStreetMap/Nominatim'
    }});
  } catch (e) {
    return json(500, { error: String((e as Error)?.message || e) });
  }
});
