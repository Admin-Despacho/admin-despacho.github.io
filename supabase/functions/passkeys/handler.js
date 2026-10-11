// Edge Function "passkeys": ingreso rápido con WebAuthn (huella / Face ID / PIN del dispositivo).
// La app guarda SOLO el id de credencial, la clave pública y el contador. Nunca biometría.
// RP ID = dominio de la app (ej. okdespacho.pages.dev); origen esperado = https://<ese dominio>.
import { hasPerm } from '../_shared/rules.js';

const json = (status, body) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json', 'access-control-allow-origin': '*', 'access-control-allow-headers': 'authorization, content-type' } });
const b64url = bytes => btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const canLogin = p => p && p.status === 'ACTIVO' && (hasPerm(p, 'routes.view_assigned') || hasPerm(p, 'routes.create') || hasPerm(p, 'users.view'));

/** deps: { rpID, rpName, origin, getUserFromJwt, getProfile, findProfileByEmail, newChallenge(), saveChallenge(c), takeChallenge(challenge, kind) → row|null (un solo uso),
 *  listPasskeys(userId), findPasskey(credentialId), savePasskey(p), updatePasskey(id, patch), verifyRegistration(args), verifyAuthentication(args), issueSession(profile), audit(e) } */
// Configuración real obligatoria: WEBAUTHN_RP_ID = dominio sin https (ej. okdespacho.pages.dev) y APP_URL = https://<ese dominio>
export function validateConfig({ rpID, origin }) {
  if (!rpID || !String(rpID).trim()) return 'falta WEBAUTHN_RP_ID (dominio de la app, sin https://)';
  if (/[:/]/.test(rpID) || /^\d+\.\d+\.\d+\.\d+$/.test(rpID)) return 'WEBAUTHN_RP_ID debe ser solo el dominio (sin https://, sin puerto, sin ruta, no una IP): ' + rpID;
  let u; try { u = new URL(origin); } catch (e) { return 'APP_URL inválida o vacía (ej. https://okdespacho.pages.dev)'; }
  if (u.protocol !== 'https:' && u.hostname !== 'localhost') return 'APP_URL debe usar https://';
  if (u.pathname !== '/' && u.pathname !== '') return 'APP_URL debe ser solo el origen, sin ruta: ' + origin;
  if (u.hostname !== rpID && !u.hostname.endsWith('.' + rpID)) return 'APP_URL (' + u.hostname + ') no corresponde a WEBAUTHN_RP_ID (' + rpID + ')';
  return null;
}
export async function handle(req, deps) {
  if (req.method === 'OPTIONS') return json(200, { ok: true });
  const cfg = validateConfig({ rpID: deps.rpID, origin: deps.origin });
  if (cfg) return json(500, { error: 'Ingreso rápido no configurado: ' + cfg, code: 'PASSKEY_CONFIG' });
  let body; try { body = await req.json(); } catch (e) { return json(400, { error: 'JSON inválido.' }); }
  const { action } = body || {};
  const auth = req.headers.get('authorization') || '';
  const who = auth.startsWith('Bearer ') ? await deps.getUserFromJwt(auth.slice(7)) : null;

  if (action === 'register_options' || action === 'register_verify') {
    const me = who && await deps.getProfile(who.id);
    if (!canLogin(me)) return json(401, { error: 'Iniciá sesión con tu contraseña para activar el ingreso rápido.' });
    if (action === 'register_options') {
      const challenge = deps.newChallenge(); await deps.saveChallenge({ user_id: me.id, challenge, kind: 'REGISTER' });
      const existing = (await deps.listPasskeys(me.id)).filter(p => !p.revoked_at);
      return json(200, { options: { challenge, rp: { id: deps.rpID, name: deps.rpName }, user: { id: b64url(new TextEncoder().encode(me.id)), name: me.email, displayName: me.full_name },
        pubKeyCredParams: [{ type: 'public-key', alg: -7 }, { type: 'public-key', alg: -257 }], timeout: 60000, attestation: 'none',
        authenticatorSelection: { residentKey: 'preferred', userVerification: 'required' }, excludeCredentials: existing.map(p => ({ type: 'public-key', id: p.credential_id })) } });
    }
    const ch = await deps.takeChallenge(body.challenge, 'REGISTER');
    if (!ch || ch.user_id !== me.id) return json(400, { error: 'El pedido de registro venció. Probá de nuevo.' });
    let v; try { v = await deps.verifyRegistration({ response: body.response, expectedChallenge: ch.challenge, expectedOrigin: deps.origin, expectedRPID: deps.rpID }); }
    catch (e) { return json(400, { error: 'No se pudo verificar el dispositivo: ' + e.message }); }
    if (!v || !v.verified) return json(400, { error: 'No se pudo verificar el dispositivo.' });
    const pk = await deps.savePasskey({ user_id: me.id, credential_id: v.credentialId, public_key: v.publicKey, sign_count: v.counter || 0, device_name: String(body.device_name || 'Este dispositivo').slice(0, 60), transports: body.transports || [] });
    await deps.audit({ actor_id: me.id, action: 'PASSKEY_REGISTERED', target_type: 'passkey', target_id: String(pk.id) });
    return json(200, { ok: true, passkey: { id: pk.id, device_name: pk.device_name, created_at: pk.created_at } });
  }
  if (action === 'login_options') {
    const challenge = deps.newChallenge(); await deps.saveChallenge({ user_id: null, challenge, kind: 'LOGIN' });
    let allow = [];
    if (body.email) { const p = await deps.findProfileByEmail(body.email); if (p) allow = (await deps.listPasskeys(p.id)).filter(x => !x.revoked_at).map(x => ({ type: 'public-key', id: x.credential_id })); }
    return json(200, { options: { challenge, rpId: deps.rpID, timeout: 60000, userVerification: 'required', allowCredentials: allow } });
  }
  if (action === 'login_verify') {
    const ch = await deps.takeChallenge(body.challenge, 'LOGIN');
    if (!ch) return json(400, { error: 'El pedido de ingreso venció. Probá de nuevo.' });
    const pk = await deps.findPasskey(body.response && body.response.id);
    if (!pk || pk.revoked_at) return json(401, { error: 'Este acceso rápido no está activo. Usá tu contraseña.' });
    const p = await deps.getProfile(pk.user_id);
    if (!canLogin(p)) return json(403, { error: 'Usuario sin acceso. Consultá con Administración.' });
    let v; try { v = await deps.verifyAuthentication({ response: body.response, expectedChallenge: ch.challenge, expectedOrigin: deps.origin, expectedRPID: deps.rpID, passkey: pk }); }
    catch (e) { return json(401, { error: 'No se pudo verificar: ' + e.message }); }
    if (!v || !v.verified) return json(401, { error: 'No se pudo verificar.' });
    await deps.updatePasskey(pk.id, { sign_count: v.newCounter ?? pk.sign_count, last_used_at: new Date().toISOString() });
    await deps.audit({ actor_id: p.id, action: 'PASSKEY_LOGIN', target_type: 'passkey', target_id: String(pk.id) });
    return json(200, { session: await deps.issueSession(p) });
  }
  return json(400, { error: 'Acción desconocida.' });
}
