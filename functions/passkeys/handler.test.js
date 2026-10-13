import { handle, validateConfig } from './handler.js';
const eq = (a, b, m) => { if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error((m || '') + ' ' + JSON.stringify(a) + ' ≠ ' + JSON.stringify(b)); };
function setup() {
  const users = { gab: { id: 'gab', email: 'g@ok.test', full_name: 'Gabriel', role: 'TRANSPORTISTA_INTERNO', status: 'ACTIVO' } };
  const db = { ch: [], pk: [], audit: [], sessions: [] }; let n = 0;
  const deps = { rpID: 'okdespacho.example', rpName: 'OK Despacho', origin: 'https://okdespacho.example',
    getUserFromJwt: async t => users[t] ? { id: t } : null, getProfile: async id => users[id] || null, findProfileByEmail: async e => Object.values(users).find(u => u.email === e) || null,
    newChallenge: () => 'ch' + (++n), saveChallenge: async c => db.ch.push({ ...c }), takeChallenge: async (c, k) => { const x = db.ch.find(y => y.challenge === c && y.kind === k && !y.used); if (x) x.used = true; return x || null; },
    listPasskeys: async uid => db.pk.filter(p => p.user_id === uid), findPasskey: async id => db.pk.find(p => p.credential_id === id) || null,
    savePasskey: async p => { const x = { id: 'pk' + db.pk.length, created_at: 'now', ...p }; db.pk.push(x); return x; }, updatePasskey: async (id, patch) => Object.assign(db.pk.find(p => p.id === id), patch),
    verifyRegistration: async a => ({ verified: a.response.ok === true, credentialId: 'cred-1', publicKey: 'spki', counter: 0 }),
    verifyAuthentication: async a => ({ verified: a.response.sig === 'ok', newCounter: 1 }),
    issueSession: async p => { db.sessions.push(p.id); return { email: p.email, token_hash: 'th' }; }, audit: async e => db.audit.push(e) };
  return { users, db, deps };
}
const call = (deps, token, body) => handle(new Request('https://x', { method: 'POST', headers: token ? { authorization: 'Bearer ' + token } : {}, body: JSON.stringify(body) }), deps).then(async r => ({ status: r.status, body: await r.json() }));
async function register(s) { const o = await call(s.deps, 'gab', { action: 'register_options' }); return call(s.deps, 'gab', { action: 'register_verify', challenge: o.body.options.challenge, response: { ok: true }, device_name: 'Celular' }); }
async function login(s, sig = 'ok', cred = 'cred-1') { const o = await call(s.deps, null, { action: 'login_options', email: 'g@ok.test' }); return call(s.deps, null, { action: 'login_verify', challenge: o.body.options.challenge, response: { id: cred, sig } }); }

Deno.test('PASSKEY-01 (lógica) registro solo después de iniciar sesión', async () => {
  const s = setup(); eq((await call(s.deps, null, { action: 'register_options' })).status, 401);
  const r = await register(s); eq(r.status, 200); eq(s.db.pk.length, 1); eq(s.db.audit.at(-1).action, 'PASSKEY_REGISTERED');
});
Deno.test('PASSKEY-02 (lógica) ingreso con passkey emite sesión; el desafío es de un solo uso', async () => {
  const s = setup(); await register(s); const o = await call(s.deps, null, { action: 'login_options', email: 'g@ok.test' });
  eq(o.body.options.allowCredentials.map(x => x.id), ['cred-1']);
  const r = await call(s.deps, null, { action: 'login_verify', challenge: o.body.options.challenge, response: { id: 'cred-1', sig: 'ok' } });
  eq(r.status, 200); eq(r.body.session.email, 'g@ok.test');
  eq((await call(s.deps, null, { action: 'login_verify', challenge: o.body.options.challenge, response: { id: 'cred-1', sig: 'ok' } })).status, 400, 'reuso del desafío');
});
Deno.test('PASSKEY-04 (lógica) usuario desactivado/archivado no entra aunque tenga passkey', async () => {
  const s = setup(); await register(s); s.users.gab.status = 'DESHABILITADO'; eq((await login(s)).status, 403);
  s.users.gab.status = 'ARCHIVADO'; eq((await login(s)).status, 403); eq(s.db.sessions.length, 0);
});
Deno.test('PASSKEY-05 (lógica) passkey revocada no entra', async () => {
  const s = setup(); await register(s); s.db.pk[0].revoked_at = 'now'; eq((await login(s)).status, 401); eq(s.db.sessions.length, 0);
});
Deno.test('PASSKEY-06 (lógica) se guarda solo id de credencial, clave pública y contador', async () => {
  const s = setup(); await register(s); eq(Object.keys(s.db.pk[0]).sort(), ['created_at', 'credential_id', 'device_name', 'id', 'public_key', 'sign_count', 'transports', 'user_id']);
});
Deno.test('Firma inválida no entra', async () => { const s = setup(); await register(s); eq((await login(s, 'mala')).status, 401); });

Deno.test('PKCFG-01 configuración válida (dominio + https del mismo dominio)', () => {
  eq(validateConfig({ rpID: 'okdespacho.pages.dev', origin: 'https://okdespacho.pages.dev' }), null);
  eq(validateConfig({ rpID: 'okaccesorios.com.ar', origin: 'https://despacho.okaccesorios.com.ar' }), null);
});
Deno.test('PKCFG-02 errores claros: vacío, con https, IP, APP_URL inválida, http, con ruta o de otro dominio', () => {
  const bad = [[{ rpID: '', origin: 'https://a.com' }, 'falta WEBAUTHN_RP_ID'], [{ rpID: 'https://a.com', origin: 'https://a.com' }, 'solo el dominio'], [{ rpID: '10.0.0.1', origin: 'https://a.com' }, 'no una IP'],
    [{ rpID: 'a.com', origin: '' }, 'APP_URL inválida'], [{ rpID: 'a.com', origin: 'http://a.com' }, 'https'], [{ rpID: 'a.com', origin: 'https://a.com/app' }, 'sin ruta'], [{ rpID: 'a.com', origin: 'https://b.com' }, 'no corresponde']];
  for (const [c, t] of bad) { const e = validateConfig(c); if (!e || !e.includes(t)) throw new Error(JSON.stringify(c) + ' → ' + e); }
});
Deno.test('PKCFG-03 sin configuración la función responde error claro (no falla en silencio)', async () => {
  const s = setup(); s.deps.rpID = ''; const r = await call(s.deps, 'gab', { action: 'register_options' });
  eq(r.status, 500); eq(r.body.code, 'PASSKEY_CONFIG'); if (!r.body.error.includes('WEBAUTHN_RP_ID')) throw new Error(r.body.error);
});
