// =====================================================================================================================
// COMUNICACIONES · conexión con una cuenta Gmail PERSONAL por OAuth oficial (Gmail API). Nunca se pide la contraseña.
// Permisos pedidos: gmail.send (enviar; sin leer el buzón) + openid email (solo para saber qué cuenta se conectó).
// El token de actualización queda en Vault (servidor); NUNCA vuelve al navegador, a la URL ni a los registros.
// =====================================================================================================================
export const GMAIL_SCOPES = ['https://www.googleapis.com/auth/gmail.send', 'openid', 'email'];
const json = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } });
const back = (appUrl, result, code) => new Response(null, { status: 302, headers: { Location: appUrl.replace(/#.*$/, '') + '#/comunicaciones?sec=gmail&r=' + result + (code ? '&m=' + encodeURIComponent(code) : ''), 'Cache-Control': 'no-store' } });
// payload del id_token recibido DIRECTAMENTE del endpoint de tokens de Google por HTTPS (no viene del navegador)
const idPayload = t => { try { const p = String(t).split('.')[1].replace(/-/g, '+').replace(/_/g, '/'); return JSON.parse(atob(p + '='.repeat((4 - p.length % 4) % 4))); } catch (e) { return {}; } };

export async function handle(req, deps) {
  // la vuelta de Google llega a .../comm-gmail-oauth/callback (URI registrada SIN parámetros, coincidencia exacta)
  const url = new URL(req.url), action = url.searchParams.get('action') || (/\/callback\/?$/.test(url.pathname) ? 'callback' : '');
  const { env, fetch: f = fetch } = deps;
  try {
    if (action === 'start' && req.method === 'POST') {
      const user = deps.userClient(req.headers.get('Authorization') || '');
      const { data: state, error } = await user.rpc('comm_oauth_begin');   // valida comms.gmail_manage EN EL SERVIDOR
      if (error) return json({ error: /FORBIDDEN/.test(error.message) ? 'FORBIDDEN' : 'NO_SE_PUDO_INICIAR' }, /FORBIDDEN/.test(error.message) ? 403 : 400);
      const q = new URLSearchParams({ client_id: env.clientId, redirect_uri: env.redirectUri, response_type: 'code', scope: GMAIL_SCOPES.join(' '),
        access_type: 'offline', prompt: 'consent', include_granted_scopes: 'false', state });
      return json({ url: 'https://accounts.google.com/o/oauth2/v2/auth?' + q });
    }
    if (action === 'callback' && req.method === 'GET') {
      const svc = deps.serviceClient(), code = url.searchParams.get('code'), state = url.searchParams.get('state') || '';
      if (url.searchParams.get('error')) return back(env.appUrl, 'error', 'CANCELADO_EN_GOOGLE');
      const { data: actor, error: se } = await svc.rpc('comm_oauth_consume', { p_state: state });   // un solo uso, 10 min, el usuario sigue autorizado
      if (se || !actor) return back(env.appUrl, 'error', 'ESTADO_INVALIDO');
      const res = await f('https://oauth2.googleapis.com/token', { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({ code, client_id: env.clientId, client_secret: env.clientSecret, redirect_uri: env.redirectUri, grant_type: 'authorization_code' }) });
      const tok = await res.json().catch(() => ({}));
      if (!res.ok || !tok.refresh_token) return back(env.appUrl, 'error', !res.ok ? 'GOOGLE_RECHAZO' : 'SIN_TOKEN_DE_ACTUALIZACION');
      const scopes = String(tok.scope || '').split(' ');
      if (!scopes.includes('https://www.googleapis.com/auth/gmail.send')) return back(env.appUrl, 'error', 'FALTA_PERMISO_DE_ENVIO');
      const p = idPayload(tok.id_token);
      if (!p.email || p.email_verified === false) return back(env.appUrl, 'error', 'CORREO_NO_VERIFICADO');
      const { error: e2 } = await svc.rpc('comm_gmail_store', { p_email: p.email, p_refresh_token: tok.refresh_token, p_actor: actor });
      if (e2) return back(env.appUrl, 'error', 'NO_SE_PUDO_GUARDAR');
      return back(env.appUrl, 'ok');
    }
    if (action === 'disconnect' && req.method === 'POST') {
      const user = deps.userClient(req.headers.get('Authorization') || ''), svc = deps.serviceClient();
      const { data: can } = await user.rpc('comm_can', { p_perm: 'comms.gmail_manage' });
      if (!can) return json({ error: 'FORBIDDEN' }, 403);
      const { data: u } = await user.auth.getUser();
      const { data: secret } = await svc.rpc('comm_gmail_secret');
      let revoked = false;
      if (secret) { const r = await f('https://oauth2.googleapis.com/revoke', { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams({ token: secret }) }).catch(() => null); revoked = !!(r && r.ok); }
      const { error } = await svc.rpc('comm_gmail_clear', { p_actor: u && u.user ? u.user.id : null });
      if (error) return json({ error: 'NO_SE_PUDO_DESCONECTAR' }, 500);
      return json({ ok: true, revoked_in_google: revoked });
    }
    return json({ error: 'ACCION_INVALIDA' }, 400);
  } catch (e) { return json({ error: 'ERROR_INTERNO' }, 500); }   // sin detalles: nunca se exponen secretos
}
