import { createClient } from 'npm:@supabase/supabase-js@2';
import { handle, makeLimiter, makeCache, MENDOZA_VIEWBOX } from './handler.js';

const url = Deno.env.get('SUPABASE_URL') ?? '', anon = Deno.env.get('SUPABASE_ANON_KEY') ?? '', service = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const admin = createClient(url || 'http://invalid', service || 'invalid', { auth: { persistSession: false, autoRefreshToken: false } });
const limiter = makeLimiter({ max: 10, windowMs: 60000 }), cache = makeCache();
let lastNominatim = 0;   // Nominatim: como máximo 1 pedido por segundo por instancia

Deno.serve(req => handle(req, {
  async getUser(jwt: string) { const { data, error } = await admin.auth.getUser(jwt); return error || !data?.user ? null : { id: data.user.id }; },
  async canManage(jwt: string) {
    const u = createClient(url, anon, { global: { headers: { Authorization: 'Bearer ' + jwt } }, auth: { persistSession: false } });
    const a = await u.rpc('auth_has_perm', { p_perm: 'locations.manage' }), b = await u.rpc('auth_has_perm', { p_perm: 'settings.manage' });
    return a.data === true || b.data === true;
  },
  async nominatim(q: string) {
    const wait = 1100 - (Date.now() - lastNominatim); if (wait > 0) await new Promise(r => setTimeout(r, wait)); lastNominatim = Date.now();
    const u = new URL('https://nominatim.openstreetmap.org/search');
    u.searchParams.set('format', 'jsonv2'); u.searchParams.set('limit', '5'); u.searchParams.set('countrycodes', 'ar'); u.searchParams.set('addressdetails', '1');
    u.searchParams.set('viewbox', MENDOZA_VIEWBOX); u.searchParams.set('bounded', '1'); u.searchParams.set('q', q);
    const r = await fetch(u, { headers: { 'Accept': 'application/json', 'Accept-Language': 'es-AR,es;q=0.9', 'User-Agent': 'OK-Despacho/1.0 (contact: despachoapp26@gmail.com)' } });
    if (!r.ok) throw new Error('nominatim ' + r.status); return await r.json();
  },
  async arcgis(q: string) {
    const u = new URL('https://geocode.arcgis.com/arcgis/rest/services/World/GeocodeServer/findAddressCandidates');
    u.searchParams.set('f', 'json'); u.searchParams.set('SingleLine', q); u.searchParams.set('countryCode', 'ARG'); u.searchParams.set('maxLocations', '5');
    u.searchParams.set('outFields', 'Match_addr,Addr_type'); u.searchParams.set('searchExtent', '-70.7,-37.6,-66.4,-32.0');   // xmin,ymin,xmax,ymax (Mendoza)
    const r = await fetch(u, { headers: { 'Accept': 'application/json' } }); if (!r.ok) throw new Error('arcgis ' + r.status); return await r.json();
  },
  limiter, cache
}));
