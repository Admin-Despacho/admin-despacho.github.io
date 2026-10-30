// Comunicaciones · funciones del servidor con Google y Supabase SIMULADOS: OAuth de Gmail, proveedor Gmail API y almacenamiento.
import { describe, it, expect } from 'vitest';
import { handle, GMAIL_SCOPES } from '../../supabase/functions/comm-gmail-oauth/handler.js';
import { gmailProvider, pgStore } from '../../supabase/functions/comm-dispatcher/adapters.js';
import { classifyGmailError } from '../../supabase/functions/_shared/comms-core.js';

const ENV = { clientId: 'client-qa.apps.googleusercontent.com', clientSecret: 'SECRETO-CLIENTE-QA', redirectUri: 'https://proyecto.supabase.co/functions/v1/comm-gmail-oauth?action=callback', appUrl: 'https://despacho.ejemplo.test/' };
const REFRESH = 'REFRESH-TOKEN-QA-NO-DEBE-VERSE';
const idToken = p => 'x.' + Buffer.from(JSON.stringify(p)).toString('base64url') + '.y';
function fakeSupabase({ canManage = true, stateOk = true } = {}) {
  const calls = [];
  const rpc = async (fn, args) => { calls.push([fn, args]);
    if (fn === 'comm_oauth_begin') return canManage ? { data: 'estado-unico-qa', error: null } : { data: null, error: { message: 'FORBIDDEN: falta el permiso comms.gmail_manage' } };
    if (fn === 'comm_oauth_consume') return stateOk ? { data: 'u-admin', error: null } : { data: null, error: { message: 'OAUTH_STATE_INVALIDO' } };
    if (fn === 'comm_can') return { data: canManage, error: null };
    if (fn === 'comm_gmail_secret') return { data: REFRESH, error: null };
    return { data: null, error: null }; };
  return { calls, client: { rpc, auth: { getUser: async () => ({ data: { user: { id: 'u-admin' } } }) } } };
}
function fakeFetch(handler) { const calls = []; const f = async (url, init) => { calls.push({ url: String(url), init }); return handler(String(url), init, calls.length); }; f.calls = calls; return f; }
const resp = (status, body) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
const visible = async r => JSON.stringify([...r.headers.entries()]) + (r.status === 302 ? '' : await r.clone().text());

describe('OAuth de Gmail (servidor)', () => {
  it('OA-01 conectar: solo con permiso (validado en el servidor); permisos mínimos; sin el secreto del cliente en la URL', async () => {
    const no = fakeSupabase({ canManage: false });
    const r0 = await handle(new Request('https://f/?action=start', { method: 'POST' }), { env: ENV, userClient: () => no.client, serviceClient: () => no.client });
    expect(r0.status).toBe(403);
    const ok = fakeSupabase(), r = await handle(new Request('https://f/?action=start', { method: 'POST' }), { env: ENV, userClient: () => ok.client, serviceClient: () => ok.client });
    const u = new URL((await r.json()).url);
    expect(u.origin + u.pathname).toBe('https://accounts.google.com/o/oauth2/v2/auth');
    expect(u.searchParams.get('scope')).toBe('https://www.googleapis.com/auth/gmail.send openid email');
    expect(GMAIL_SCOPES.some(s => /gmail\.(readonly|modify|compose)|mail\.google\.com/.test(s))).toBe(false);   // nada de leer el buzón
    expect(Object.fromEntries(u.searchParams)).toMatchObject({ access_type: 'offline', prompt: 'consent', state: 'estado-unico-qa', response_type: 'code' });
    expect(u.toString()).not.toContain(ENV.clientSecret);
  });
  it('OA-02 vuelta de Google: el código se canjea EN EL SERVIDOR, el token va a Vault y la app solo recibe "ok"', async () => {
    const sb = fakeSupabase(), f = fakeFetch(() => resp(200, { access_token: 'AT', refresh_token: REFRESH, scope: 'https://www.googleapis.com/auth/gmail.send openid email', id_token: idToken({ email: 'comunicados.qa@gmail.com', email_verified: true }) }));
    const r = await handle(new Request('https://f/?action=callback&code=CODIGO&state=estado-unico-qa'), { env: ENV, fetch: f, userClient: () => sb.client, serviceClient: () => sb.client });
    expect(r.status).toBe(302); expect(r.headers.get('Location')).toBe('https://despacho.ejemplo.test/#/comunicaciones?sec=gmail&r=ok');
    expect(await visible(r)).not.toContain(REFRESH);
    expect(sb.calls.find(c => c[0] === 'comm_gmail_store')[1]).toEqual({ p_email: 'comunicados.qa@gmail.com', p_refresh_token: REFRESH, p_actor: 'u-admin' });
    expect(f.calls[0].url).toBe('https://oauth2.googleapis.com/token');
    // también por la ruta registrada sin parámetros (.../comm-gmail-oauth/callback)
    const sb2 = fakeSupabase(), r2 = await handle(new Request('https://f/functions/v1/comm-gmail-oauth/callback?code=C2&state=s2'), { env: ENV, fetch: f, userClient: () => sb2.client, serviceClient: () => sb2.client });
    expect(r2.headers.get('Location')).toBe('https://despacho.ejemplo.test/#/comunicaciones?sec=gmail&r=ok');
  });
  it('OA-03 estado inválido o reutilizado: no se canjea nada; si se destilda "enviar correo" en Google: no se conecta', async () => {
    const bad = fakeSupabase({ stateOk: false }), f0 = fakeFetch(() => resp(200, {}));
    const r = await handle(new Request('https://f/?action=callback&code=C&state=robado'), { env: ENV, fetch: f0, userClient: () => bad.client, serviceClient: () => bad.client });
    expect(r.headers.get('Location')).toMatch(/r=error&m=ESTADO_INVALIDO$/); expect(f0.calls).toHaveLength(0);
    const sb = fakeSupabase(), f = fakeFetch(() => resp(200, { refresh_token: REFRESH, scope: 'openid email', id_token: idToken({ email: 'x@gmail.com' }) }));
    const r2 = await handle(new Request('https://f/?action=callback&code=C&state=s'), { env: ENV, fetch: f, userClient: () => sb.client, serviceClient: () => sb.client });
    expect(r2.headers.get('Location')).toMatch(/m=FALTA_PERMISO_DE_ENVIO$/); expect(sb.calls.some(c => c[0] === 'comm_gmail_store')).toBe(false);
  });
  it('OA-04 desconectar: solo con permiso; revoca en Google y borra el secreto; la respuesta no incluye el token', async () => {
    const no = fakeSupabase({ canManage: false });
    expect((await handle(new Request('https://f/?action=disconnect', { method: 'POST' }), { env: ENV, userClient: () => no.client, serviceClient: () => no.client })).status).toBe(403);
    const sb = fakeSupabase(), f = fakeFetch(() => new Response('', { status: 200 }));
    const r = await handle(new Request('https://f/?action=disconnect', { method: 'POST' }), { env: ENV, fetch: f, userClient: () => sb.client, serviceClient: () => sb.client });
    expect(await r.json()).toEqual({ ok: true, revoked_in_google: true });
    expect(f.calls[0].url).toBe('https://oauth2.googleapis.com/revoke'); expect(sb.calls.some(c => c[0] === 'comm_gmail_clear')).toBe(true);
  });
});

describe('Proveedor Gmail API (servidor)', () => {
  const store = { refreshToken: async () => REFRESH };
  it('GP-01 renueva el token, envía y devuelve el id de Gmail', async () => {
    const f = fakeFetch(u => u.includes('/token') ? resp(200, { access_token: 'AT1', expires_in: 3599 }) : resp(200, { id: 'gm-123' }));
    expect(await gmailProvider(store, { clientId: 'c', clientSecret: 's', fetch: f }).send('RAW')).toEqual({ id: 'gm-123' });
    expect(f.calls[1].url).toBe('https://gmail.googleapis.com/gmail/v1/users/me/messages/send');
    expect(f.calls[1].init.headers.Authorization).toBe('Bearer AT1'); expect(JSON.parse(f.calls[1].init.body)).toEqual({ raw: 'RAW' });
  });
  it('GP-02 401 (token de acceso vencido, Gmail NO lo procesó): renueva y reintenta UNA vez', async () => {
    const f = fakeFetch((u, i, n) => u.includes('/token') ? resp(200, { access_token: 'AT' + n }) : (n === 2 ? resp(401, { error: { message: 'Invalid Credentials' } }) : resp(200, { id: 'gm-9' })));
    expect(await gmailProvider(store, { clientId: 'c', clientSecret: 's', fetch: f }).send('R')).toEqual({ id: 'gm-9' });
    expect(f.calls.filter(c => c.url.includes('/send'))).toHaveLength(2);
  });
  it('GP-06 cada llamada REAL a messages.send pide cupo de velocidad (también la que se repite tras un 401)', async () => {
    const f = fakeFetch((u, i, n) => u.includes('/token') ? resp(200, { access_token: 'AT' + n }) : (n === 2 ? resp(401, {}) : resp(200, { id: 'gm-9' })));
    let asked = 0; await gmailProvider(store, { clientId: 'c', clientSecret: 's', fetch: f }).send('R', { beforeHttp: async () => { asked++; } });
    expect(asked).toBe(2); expect(f.calls.filter(c => c.url.includes('/send'))).toHaveLength(2);
  });
  it('GP-03 corte de red DESPUÉS de enviar el pedido: AMBIGUO (Por verificar), sin reintento', async () => {
    const f = fakeFetch(u => { if (u.includes('/token')) return resp(200, { access_token: 'AT' }); throw new TypeError('connection reset'); });
    const e = await gmailProvider(store, { clientId: 'c', clientSecret: 's', fetch: f }).send('R').catch(x => x);
    expect(classifyGmailError(e)).toBe('AMBIGUOUS'); expect(f.calls.filter(c => c.url.includes('/send'))).toHaveLength(1);
  });
  it('GP-04 límite (429) se reintenta más tarde; invalid_grant al renovar → hay que reconectar', async () => {
    const f = fakeFetch(u => u.includes('/token') ? resp(200, { access_token: 'AT' }) : resp(429, { error: { message: 'Rate limit', errors: [{ reason: 'rateLimitExceeded' }] } }));
    expect(classifyGmailError(await gmailProvider(store, { clientId: 'c', clientSecret: 's', fetch: f }).send('R').catch(x => x))).toBe('RETRYABLE');
    const g = fakeFetch(() => resp(400, { error: 'invalid_grant', error_description: 'Token has been expired or revoked.' }));
    expect(classifyGmailError(await gmailProvider(store, { clientId: 'c', clientSecret: 's', fetch: g }).send('R').catch(x => x))).toBe('AUTH');
  });
  it('GP-05 el almacenamiento del servidor usa las funciones de servicio con sus parámetros', async () => {
    const calls = []; const sb = { rpc: async (fn, a) => { calls.push([fn, a]); return { data: fn === 'comm_claim' ? [] : 'OK', error: null }; } };
    const st = pgStore(sb); await st.claim(5, 'w1', Date.parse('2026-11-02T12:00:00Z')); await st.check(7, 'tk'); await st.finish(7, 'tk', { outcome: 'ACCEPTED', gmail_id: 'gm-1' });
    expect(calls).toEqual([['comm_claim', { p_limit: 5, p_worker: 'w1', p_now: '2026-11-02T12:00:00.000Z', p_daily_cap: 400, p_window_hours: 6 }], ['comm_check', { p_id: 7, p_token: 'tk' }],
      ['comm_finish', { p_id: 7, p_token: 'tk', p_outcome: 'ACCEPTED', p_gmail_id: 'gm-1', p_error_code: null, p_error: null }]]);
  });
});
