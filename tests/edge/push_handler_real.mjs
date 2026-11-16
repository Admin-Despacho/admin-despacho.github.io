// N-V4-02 / N-V5-02 / N-V5-03 · ejecuta el index.ts REAL de push-notifications con dependencias simuladas (método del arnés de Work)
// y cuenta reclamos, verificaciones de vigencia, verificaciones de destinatario, envíos y estados finales. Ningún envío real.
import { registerHooks } from 'node:module';
import { writeFileSync } from 'node:fs';
registerHooks({ resolve(spec, ctx, next) {
  if (spec.startsWith('npm:@supabase/supabase-js')) return { url: 'audit:supabase', shortCircuit: true };
  if (spec.startsWith('npm:web-push')) return { url: 'audit:webpush', shortCircuit: true };
  return next(spec, ctx); },
  load(url, ctx, next) {
    if (url === 'audit:supabase') return { format: 'module', source: 'export const createClient=(...a)=>globalThis.auditCreateClient(...a);', shortCircuit: true };
    if (url === 'audit:webpush') return { format: 'module', source: 'export default globalThis.auditWebpush;', shortCircuit: true };
    return next(url, ctx); } });
const b64 = o => Buffer.from(JSON.stringify(o)).toString('base64url');
const tok = c => 'Bearer ' + b64({ alg: 'HS256' }) + '.' + b64(c) + '.firma';
const NOW = Math.floor(Date.now() / 1000), REVOKED = NOW - 60;
const T = { vigente: tok({ sub: 'u1', iat: NOW, session_id: 's1' }), revocado: tok({ sub: 'u1', iat: NOW - 3600, session_id: 's1' }), sin_iat: tok({ sub: 'u1', session_id: 's1' }),
  otro_sub: tok({ sub: 'u9', iat: NOW, session_id: 's1' }), borrada: tok({ sub: 'u1', iat: NOW, session_id: 'borrada' }), inactivo: tok({ sub: 'u2', iat: NOW, session_id: 's2' }),
  sin_session_id: tok({ sub: 'u1', iat: NOW }) };
const USERS = Object.fromEntries(Object.entries(T).map(([k, v]) => [v, k === 'inactivo' ? 'u2' : 'u1']));
// ---- estado simulado de cada escenario ----
let S;
const reset = (o = {}) => { S = { urgent: [], general: [], notifs: [], subs: {}, allowed: {}, allowedErr: false, failCheck: false, calls: [], sends: 0, jobUpd: {}, recipientChecks: 0, sessionChecks: 0, ...o }; };
globalThis.Deno = { env: { get: k => ({ SUPABASE_URL: 'https://audit.invalid', SUPABASE_ANON_KEY: 'anon', SUPABASE_SERVICE_ROLE_KEY: 'service', CRON_SECRET: 'synthetic-cron',
  VAPID_PUBLIC_KEY: 'p', VAPID_PRIVATE_KEY: 'k', VAPID_SUBJECT: 'mailto:a@b.c', APP_URL: 'https://app.invalid' })[k] }, serve: fn => { handler = fn; } };
let handler;
globalThis.auditWebpush = { setVapidDetails: () => {}, sendNotification: async () => { S.sends++; } };   // SOLO cuenta: no hay red
const q = (table) => { const st = { table, filters: {}, upd: null };
  const c = { select: () => c, eq: (k, v) => { st.filters[k] = v; return c; }, in: (k, v) => { st.filters[k] = v; return c; }, is: () => c, order: () => c, limit: () => c,
    update: (v) => { st.upd = v; return c; }, maybeSingle: async () => ({ data: null }), single: async () => ({ data: { public_key: 'p', private_key: 'k' }, error: null }),
    then: (r) => {
      if (st.upd && table === 'push_jobs') { S.jobUpd[st.filters.id] = st.upd.status; return r({ data: null, error: null }); }
      if (table === 'notifications') return r({ data: S.notifs.filter(n => (st.filters.id || []).includes(n.id)), error: null });
      if (table === 'push_subscriptions') return r({ data: S.subs[st.filters.user_id] || [], error: null });
      return r({ data: [], error: null }); } };
  return c; };
globalThis.auditCreateClient = (url, key, opts) => key === 'service'
  ? { rpc: async (name, args) => { S.calls.push(name);
        if (name === 'push_session_valid') { S.sessionChecks++; if (S.failCheck) return { data: null, error: { message: 'falla' } };
          const r = args.p_user === 'u2' ? { ok: false, motivo: 'PERFIL_NO_ACTIVO' } : args.p_iat <= REVOKED ? { ok: false, motivo: 'SESION_REVOCADA' } : args.p_session === 'borrada' ? { ok: false, motivo: 'SESION_INEXISTENTE' } : { ok: true };
          return { data: r, error: null }; }
        if (name === 'claim_com_alarm_push_jobs') return { data: S.urgent, error: null };
        if (name === 'claim_push_jobs') return { data: S.general, error: null };
        if (name === 'push_recipient_allowed') { S.recipientChecks++; if (S.allowedErr) return { data: null, error: { message: 'base caída' } }; return { data: S.allowed[args.p_notification] || { ok: false }, error: null }; }
        return { data: null, error: null }; }, from: (t) => q(t) }
  : { auth: { getUser: async () => { const a = opts?.global?.headers?.Authorization; return USERS[a] ? { data: { user: { id: USERS[a] } }, error: null } : { data: { user: null }, error: { message: 'invalid' } }; } } };
await import('../../supabase/functions/push-notifications/index.ts');
const call = async (headers) => (await handler(new Request('https://audit.invalid/functions/v1/push-notifications', { method: 'POST', headers, body: '{}' }))).status;
const claims = () => S.calls.filter(n => n.startsWith('claim_')).length;
const out = []; const add = (caso, ok, det) => { out.push({ caso, pass: !!ok, det }); };
// ---- AUTENTICACIÓN: ninguna denegación reclama trabajos ----
for (const [name, h, st] of [['SIN_CREDENCIALES', {}, 401], ['CRON_ERRONEO', { 'x-cron-secret': 'malo' }, 401], ['JWT_INVALIDO', { authorization: 'Bearer x.y.z' }, 401],
  ['PERFIL_INACTIVO', { authorization: T.inactivo }, 403], ['SESION_REVOCADA (perfil ACTIVO)', { authorization: T.revocado }, 401], ['CLAIMS_SIN_IAT', { authorization: T.sin_iat }, 401],
  ['SUB_DISTINTO', { authorization: T.otro_sub }, 401], ['SESION_BORRADA', { authorization: T.borrada }, 401], ['SIN_SESSION_ID (N-V5-02)', { authorization: T.sin_session_id }, 401]]) {
  reset(); const s = await call(h); add(name, s === st && claims() === 0, `status ${s} (esperado ${st}) · reclamos ${claims()} · vigencia ${S.sessionChecks}`);
}
reset({ failCheck: true }); { const s = await call({ authorization: T.vigente }); add('FALLA_DE_VERIFICACION_DE_SESION', s === 401 && claims() === 0, `status ${s} · reclamos ${claims()}`); }
reset(); { const s = await call({ authorization: T.vigente }); add('USUARIO_VIGENTE procesa', s === 200 && claims() === 2, `status ${s} · reclamos ${claims()}`); }
reset(); { const s = await call({ 'x-cron-secret': 'synthetic-cron' }); add('CRON_VALIDO procesa', s === 200 && claims() === 2 && S.sessionChecks === 0, `status ${s} · reclamos ${claims()}`); }
// ---- DESPACHO (N-V5-03) ----
const job = (id, nid, user) => ({ id, notification_id: nid, user_id: user, status: 'SENDING' });
const sub = [{ id: 'sb1', endpoint: 'https://push.invalid/x', p256dh: 'p', auth: 'a' }];
reset({ urgent: [job('j1', 'n1', 'uX')], notifs: [{ id: 'n1', type: 'COM_ALARMA', title: 'Alarma', body: 'Cliente X' }], subs: { uX: sub }, allowed: { n1: { ok: false, motivo: 'DESTINATARIO_SIN_ACCESO_ACTUAL' } } });
{ const s = await call({ 'x-cron-secret': 'synthetic-cron' }); add('N-V5-03 ALARMA a destinatario que PERDIÓ el acceso (con suscripción ACTIVA): se OMITE, 0 envíos', s === 200 && S.sends === 0 && S.jobUpd.j1 === 'SKIPPED' && S.recipientChecks === 1, `envíos ${S.sends} · estado ${S.jobUpd.j1} · verificaciones ${S.recipientChecks}`); }
reset({ urgent: [job('j2', 'n2', 'uW')], notifs: [{ id: 'n2', type: 'COM_ALARMA', title: 'Alarma', body: 'Cliente Y' }], subs: { uW: sub }, allowed: { n2: { ok: true } } });
{ const s = await call({ 'x-cron-secret': 'synthetic-cron' }); add('N-V5-03 ALARMA a destinatario AUTORIZADO: se envía', s === 200 && S.sends === 1 && S.recipientChecks === 1, `envíos ${S.sends} · verificaciones ${S.recipientChecks}`); }
reset({ urgent: [job('j3', 'n3', 'uW')], notifs: [{ id: 'n3', type: 'COM_ALARMA', title: 'Alarma', body: 'Z' }], subs: { uW: sub }, allowedErr: true });
{ const s = await call({ 'x-cron-secret': 'synthetic-cron' }); add('N-V5-03 falla TÉCNICA al verificar el destinatario: NO se envía y queda para REINTENTO (ERROR)', s === 200 && S.sends === 0 && S.jobUpd.j3 === 'ERROR', `envíos ${S.sends} · estado ${S.jobUpd.j3}`); }
reset({ general: [job('j4', 'n4', 'uD')], notifs: [{ id: 'n4', type: 'NUEVA_HOJA_PUBLICADA', title: 'Hoja', body: 'H' }], subs: { uD: sub } });
{ const s = await call({ 'x-cron-secret': 'synthetic-cron' }); add('Avisos de OTROS tipos (hoja publicada): se envían como siempre, SIN verificar acceso comercial', s === 200 && S.sends === 1 && S.recipientChecks === 0, `envíos ${S.sends} · verificaciones ${S.recipientChecks}`); }
reset({ urgent: [job('j5', 'n5', 'uW')], general: [job('j5', 'n5', 'uW'), job('j6', 'n6', 'uD')], notifs: [{ id: 'n5', type: 'COM_ALARMA', title: 'A', body: 'a' }, { id: 'n6', type: 'REQUEST_CREATED', title: 'S', body: 's' }], subs: { uW: sub, uD: sub }, allowed: { n5: { ok: true } } });
{ const s = await call({ 'x-cron-secret': 'synthetic-cron' }); const ci = S.calls.indexOf('claim_com_alarm_push_jobs'), cg = S.calls.indexOf('claim_push_jobs');
  add('PRIORIDAD: las alarmas se toman ANTES que la cola general y un trabajo devuelto por ambas se procesa UNA vez', s === 200 && ci >= 0 && ci < cg && S.sends === 2 && S.recipientChecks === 1, `orden ${ci}<${cg} · envíos ${S.sends} · verificaciones ${S.recipientChecks}`); }
for (const x of out) console.log((x.pass ? 'PASS' : 'FAIL') + ' | ' + x.caso + ' | ' + x.det);
console.log('TOTAL ' + out.filter(x => x.pass).length + ' / ' + out.length);
writeFileSync('/tmp/push_handler_real.json', JSON.stringify(out, null, 2));
process.exit(out.every(x => x.pass) ? 0 : 1);
