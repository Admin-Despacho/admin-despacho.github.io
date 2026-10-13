import { handle, BACKUP_TABLES } from './handler.js';
const eq = (a, b, m) => { if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error((m || '') + ' ' + JSON.stringify(a) + ' ≠ ' + JSON.stringify(b)); };
const ok = (c, m) => { if (!c) throw new Error(m || 'falló'); };
const deps = (perm = true) => ({ getUserFromJwt: async t => t ? { id: 'adm' } : null, userHasPerm: async () => perm, dumpTable: async t => t === 'routes' ? [{ id: 'r1', number: '01-000001' }] : [],
  listStorage: async () => ({ 'route-pdfs': ['r1/v1/Hoja_01-000001_v1.pdf'], 'identity-docs': [] }), downloadObject: async () => new Uint8Array([37, 80, 68, 70]), audit: async () => {} });
const call = (d, tok = 'x', method = 'POST') => handle(new Request('https://x', { method, headers: tok ? { authorization: 'Bearer ' + tok } : {}, body: method === 'POST' ? '{}' : undefined }), d);
Deno.test('RC2-20 backup: datos de todas las tablas, manifest con hashes, Storage listado y README de restauración en prueba', async () => {
  const r = await call(deps()); eq(r.status, 200); const b = await r.json();
  eq(Object.keys(b.manifest.tables).length, BACKUP_TABLES.length); eq(b.manifest.tables.routes.rows, 1); ok(/^[0-9a-f]{64}$/.test(b.manifest.tables.routes.sha256)); ok(b.manifest.sha256);
  eq(b.manifest.storage['route-pdfs'].objects, 1); ok(b.readme.includes('PRUEBA') && !/drop|truncate|delete from/i.test(b.readme)); eq(b.data.routes[0].number, '01-000001');
});
Deno.test('RC2-20b backup solo con settings.manage; sin sesión 401; CORS en todo', async () => {
  const f = await call(deps(false)); eq(f.status, 403); eq(f.headers.get('access-control-allow-origin'), '*');
  eq((await call(deps(), null)).status, 401);
  const o = await call(deps(), 'x', 'OPTIONS'); eq(o.status, 200); ok(o.headers.get('access-control-allow-headers').includes('x-client-info'));
});

Deno.test('RC2-20c backup: descarga real de cada archivo de Storage con SHA-256; rechaza rutas inválidas', async () => {
  const req = body => handle(new Request('https://x', { method: 'POST', headers: { authorization: 'Bearer x' }, body: JSON.stringify(body) }), deps());
  const r = await (await req({ action: 'storage_file', bucket: 'route-pdfs', name: 'r1/v1/Hoja_01-000001_v1.pdf' })).json();
  eq(r.size, 4); eq(atob(r.base64), '%PDF'); ok(/^[0-9a-f]{64}$/.test(r.sha256));
  eq((await req({ action: 'storage_file', bucket: 'otro', name: 'x' })).status, 400); eq((await req({ action: 'storage_file', bucket: 'route-pdfs', name: '../x' })).status, 400);
});

Deno.test('P1-08 Storage: pagina con offset; >1000 objetos en el mismo prefijo entran todos (incluye subcarpetas)', async () => {
  const { listAllObjects } = await import('./handler.js');
  const root = Array.from({ length: 2345 }, (_, i) => ({ name: 'f' + String(i).padStart(5, '0') + '.pdf', id: 'x' + i })).concat([{ name: 'sub', id: null }]);
  const sub = Array.from({ length: 1001 }, (_, i) => ({ name: 's' + i + '.pdf', id: 'y' + i }));
  const calls = [];
  const listFn = async (b, prefix, o) => { calls.push([prefix, o.offset]); const src = prefix === '' ? root : sub; return src.slice(o.offset, o.offset + o.limit); };
  const all = await listAllObjects(listFn, 'route-pdfs');
  eq(all.length, 2345 + 1001); eq(new Set(all).size, all.length); ok(all.includes('f02344.pdf') && all.includes('sub/s1000.pdf'));
  eq(calls.filter(c => c[0] === '').map(c => c[1]), [0, 1000, 2000]);
});
Deno.test('P1-07 backup exporta identidades de Auth sin contraseñas', async () => {
  const { safeAuthUser } = await import('./handler.js');
  const u = safeAuthUser({ id: 'u1', email: 'a@b.c', encrypted_password: 'x', password: 'y', phone: null, email_confirmed_at: 't', app_metadata: {} });
  eq(Object.keys(u).sort(), ['created_at', 'email', 'email_confirmed_at', 'id', 'phone']); ok(!JSON.stringify(u).includes('"x"'));
});
