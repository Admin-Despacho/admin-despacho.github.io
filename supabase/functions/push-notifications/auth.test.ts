// Deno · autenticación del handler de push (B-W05 + N-V4-02): servicio, usuario con VIGENCIA de sesión, y denegaciones.
import { authorize, readClaims, sameSecret } from './auth.ts';
const b64 = (o: unknown) => btoa(JSON.stringify(o)).replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');
const tok = (claims: Record<string, unknown>) => 'Bearer ' + b64({ alg: 'HS256' }) + '.' + b64(claims) + '.firma';
const NOW = Math.floor(Date.now() / 1000);
const T = { bueno: tok({ sub: 'u1', iat: NOW, session_id: 's1' }), revocado: tok({ sub: 'u1', iat: NOW - 3600, session_id: 's1' }), sin_iat: tok({ sub: 'u1', session_id: 's1' }),
  otro_sub: tok({ sub: 'u9', iat: NOW, session_id: 's9' }), inactivo: tok({ sub: 'u2', iat: NOW, session_id: 's2' }), sin_sesion: tok({ sub: 'u1', iat: NOW, session_id: 'borrada' }), roto: 'Bearer no.es-un-jwt',
  sin_session_id: tok({ sub: 'u1', iat: NOW }), session_vacia: tok({ sub: 'u1', iat: NOW, session_id: '  ' }), session_no_texto: tok({ sub: 'u1', iat: NOW, session_id: 42 }) };
const usuarios: Record<string, string> = { [T.bueno]: 'u1', [T.revocado]: 'u1', [T.sin_iat]: 'u1', [T.otro_sub]: 'u1', [T.inactivo]: 'u2', [T.sin_sesion]: 'u1', [T.roto]: 'u1', [T.sin_session_id]: 'u1', [T.session_vacia]: 'u1', [T.session_no_texto]: 'u1' };
const REVOCADO_EN = NOW - 60;   // sessions_revoked_at del usuario u1
const deps = {
  getUser: async (a: string) => usuarios[a] ? { id: usuarios[a] } : null,
  checkSession: async (id: string, iat: number, sid: string | null) => id === 'u2' ? { ok: false, motivo: 'PERFIL_NO_ACTIVO' }
    : iat <= REVOCADO_EN ? { ok: false, motivo: 'SESION_REVOCADA' } : sid === 'borrada' ? { ok: false, motivo: 'SESION_INEXISTENTE' } : { ok: true } };
const H = (o: Record<string, string>) => new Headers(o);
const ok = (c: boolean, m: string) => { if (!c) throw new Error(m); };
const no = async (h: Record<string, string>, st: number, d = deps) => { const r = await authorize(H(h), 's3cr3t', d); ok(!r.ok && r.status === st, JSON.stringify(r)); };
Deno.test('PA-01 programada con el secreto correcto → pasa (vía CRON, sin JWT)', async () => { const r = await authorize(H({ 'x-cron-secret': 's3cr3t' }), 's3cr3t', deps); ok(r.ok && r.via === 'CRON', JSON.stringify(r)); });
Deno.test('PA-02 sin credenciales → 401', () => no({}, 401));
Deno.test('PA-03 secreto ERRÓNEO sin JWT → 401', () => no({ 'x-cron-secret': 'otro' }, 401));
Deno.test('PA-04 CRON_SECRET no configurado: la vía programada queda APAGADA', async () => {
  ok(!(await authorize(H({ 'x-cron-secret': '' }), '', deps)).ok, 'vacío'); ok(!(await authorize(H({ 'x-cron-secret': 'x' }), '', deps)).ok, 'cualquiera'); });
Deno.test('PA-05 JWT inválido (getUser lo rechaza) → 401', () => no({ authorization: 'Bearer desconocido.x.y' }, 401));
Deno.test('PA-06 perfil NO activo → 403', () => no({ authorization: T.inactivo }, 403));
Deno.test('PA-07 sesión VIGENTE (sub e iat correctos, posterior a la revocación, sesión existente) → pasa (vía USER)', async () => { const r = await authorize(H({ authorization: T.bueno }), 's3cr3t', deps); ok(r.ok && r.via === 'USER' && r.userId === 'u1', JSON.stringify(r)); });
Deno.test('PA-08 secreto erróneo CON JWT vigente → vía USER (no se confunde con la programada)', async () => { const r = await authorize(H({ 'x-cron-secret': 'otro', authorization: T.bueno }), 's3cr3t', deps); ok(r.ok && r.via === 'USER', JSON.stringify(r)); });
Deno.test('PA-09 falla de la verificación de usuario (excepción) → 401, nunca acceso', () => no({ authorization: T.bueno }, 401, { getUser: async () => { throw new Error('red'); }, checkSession: deps.checkSession }));
Deno.test('PA-10 comparación de secretos: igual, distinto y distinta longitud', () => { ok(sameSecret('abc', 'abc') && !sameSecret('abc', 'abd') && !sameSecret('abc', 'abcd'), 'sameSecret'); });
Deno.test('PA-11 (N-V4-02) token ANTERIOR a sessions_revoked_at, aunque getUser lo acepte y el perfil esté ACTIVO → 401', () => no({ authorization: T.revocado }, 401));
Deno.test('PA-12 (N-V4-02) claims INCOMPLETOS (sin iat) → 401', () => no({ authorization: T.sin_iat }, 401));
Deno.test('PA-13 (N-V4-02) claim sub DISTINTO del usuario validado → 401', () => no({ authorization: T.otro_sub }, 401));
Deno.test('PA-14 (N-V4-02) sesión INEXISTENTE (borrada por revoke_user_sessions) → 401', () => no({ authorization: T.sin_sesion }, 401));
Deno.test('PA-15 (N-V4-02) token MAL FORMADO aunque getUser responda → 401', () => no({ authorization: T.roto }, 401));
Deno.test('PA-16 (N-V4-02) la verificación de vigencia FALLA (excepción) → 401, nunca acceso', () => no({ authorization: T.bueno }, 401, { getUser: deps.getUser, checkSession: async () => { throw new Error('base'); } }));
Deno.test('PA-17 lectura de claims: válidos, sin parte central y JSON inválido', () => { ok(readClaims(T.bueno)?.sub === 'u1' && readClaims('Bearer x') === null && readClaims('Bearer a.!!!.c') === null, 'readClaims'); });
Deno.test('PA-18 (N-V5-02) SIN session_id, session_id VACÍO o que NO es texto → 401 y la verificación de vigencia NI SE CONSULTA (no se aprueba a ciegas)', async () => {
  let consultas = 0; const d = { getUser: deps.getUser, checkSession: async (...a: [string, number, string | null]) => { consultas++; return deps.checkSession(...a); } };
  for (const k of ['sin_session_id', 'session_vacia', 'session_no_texto'] as const) { const r = await authorize(H({ authorization: T[k] }), 's3cr3t', d); ok(!r.ok && r.status === 401, k + ' ' + JSON.stringify(r)); }
  ok(consultas === 0, 'consultas=' + consultas); });
