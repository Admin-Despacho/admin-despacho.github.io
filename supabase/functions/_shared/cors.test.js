// RC2-15: CORS en TODAS las Edge Functions (OPTIONS, 4xx y excepción → 500 JSON legible)
import { handle as users } from '../admin-users/handler.js';
import { handle as reports } from '../commercial-reports/handler.js';
import { handle as approvals } from '../internal-approvals/handler.js';
import { handle as passkeys } from '../passkeys/handler.js';
import { handle as backup } from '../backup/handler.js';
const ok = (c, m) => { if (!c) throw new Error(m || 'falló'); };
const boom = { get: () => { throw new Error('dependencia rota'); } };
const brokenDeps = new Proxy({ rpID: 'okdespacho.example', origin: 'https://okdespacho.example', cronSecret: 's' }, { get: (t, k) => k in t ? t[k] : async () => { throw new Error('dependencia rota'); } });
for (const [name, h] of Object.entries({ users, reports, approvals, passkeys, backup })) {
  Deno.test('RC2-15 ' + name + ': OPTIONS con authorization/apikey/x-client-info/content-type', async () => {
    const r = await h(new Request('https://x', { method: 'OPTIONS' }), brokenDeps); ok(r.status === 200);
    const hd = r.headers.get('access-control-allow-headers'); ['authorization', 'apikey', 'x-client-info', 'content-type'].forEach(k => ok(hd.includes(k), k));
  });
  Deno.test('RC2-15 ' + name + ': una excepción interna devuelve JSON legible con CORS', async () => {
    const r = await h(new Request('https://x', { method: 'POST', headers: { authorization: 'Bearer t', 'x-cron-secret': 's' }, body: JSON.stringify({ action: 'list' }) }), brokenDeps);
    ok(r.headers.get('access-control-allow-origin') === '*', 'CORS'); const b = await r.json(); ok(b.error && b.code, JSON.stringify(b)); ok(r.status >= 400);
  });
}
