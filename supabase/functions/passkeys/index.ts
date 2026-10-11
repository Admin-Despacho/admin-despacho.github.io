// Edge Function "passkeys". Secrets: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (automáticos), WEBAUTHN_RP_ID (dominio de la app, sin https://), APP_URL (origen).
import { createClient } from 'npm:@supabase/supabase-js@2';
import { verifyRegistrationResponse, verifyAuthenticationResponse } from 'npm:@simplewebauthn/server@10.0.1';
import { handle, validateConfig } from './handler.js';

const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
const must = <T>(r: { data: T; error: any }) => { if (r.error) throw new Error(r.error.message); return r.data; };
const b64u = (b: Uint8Array) => btoa(String.fromCharCode(...b)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const fromB64u = (s: string) => Uint8Array.from(atob(s.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((s.length + 3) % 4)), (c) => c.charCodeAt(0));
const withPerms = async (p: any) => p;

const deps = {
  rpID: Deno.env.get('WEBAUTHN_RP_ID') ?? '', rpName: 'OK Despacho', origin: (Deno.env.get('APP_URL') ?? '').replace(/\/$/, ''),
  async getUserFromJwt(jwt: string) { const { data } = await admin.auth.getUser(jwt); return data?.user ? { id: data.user.id } : null; },
  async getProfile(id: string) { return withPerms(must(await admin.from('profiles').select('*').eq('id', id).maybeSingle())); },
  async findProfileByEmail(email: string) { return must(await admin.from('profiles').select('*').eq('email', String(email).toLowerCase()).maybeSingle()); },
  newChallenge() { return b64u(crypto.getRandomValues(new Uint8Array(32))); },
  async saveChallenge(c: any) { must(await admin.from('webauthn_challenges').insert(c)); },
  async takeChallenge(challenge: string, kind: string) {
    const r = must(await admin.from('webauthn_challenges').update({ used_at: new Date().toISOString() }).eq('challenge', challenge).eq('kind', kind).is('used_at', null)
      .gte('created_at', new Date(Date.now() - 5 * 60000).toISOString()).select().maybeSingle());
    return r;
  },
  async listPasskeys(userId: string) { return must(await admin.from('user_passkeys').select('*').eq('user_id', userId)) as any[]; },
  async findPasskey(credId: string) { return must(await admin.from('user_passkeys').select('*').eq('credential_id', credId).maybeSingle()); },
  async savePasskey(p: any) { return must(await admin.from('user_passkeys').insert(p).select().single()); },
  async updatePasskey(id: string, patch: any) { must(await admin.from('user_passkeys').update(patch).eq('id', id)); },
  async verifyRegistration(a: any) {
    const v = await verifyRegistrationResponse({ response: a.response, expectedChallenge: a.expectedChallenge, expectedOrigin: a.expectedOrigin, expectedRPID: a.expectedRPID, requireUserVerification: true });
    if (!v.verified || !v.registrationInfo) return { verified: false };
    const info: any = v.registrationInfo;
    return { verified: true, credentialId: typeof info.credentialID === 'string' ? info.credentialID : b64u(info.credentialID), publicKey: b64u(info.credentialPublicKey), counter: info.counter };
  },
  async verifyAuthentication(a: any) {
    const v = await verifyAuthenticationResponse({ response: a.response, expectedChallenge: a.expectedChallenge, expectedOrigin: a.expectedOrigin, expectedRPID: a.expectedRPID, requireUserVerification: true,
      authenticator: { credentialID: a.passkey.credential_id, credentialPublicKey: fromB64u(a.passkey.public_key), counter: Number(a.passkey.sign_count) } as any });
    return { verified: v.verified, newCounter: v.authenticationInfo?.newCounter };
  },
  // Sesión: link mágico de un solo uso generado por el servidor; el cliente lo canjea con verifyOtp (no viaja contraseña)
  async issueSession(p: any) { const r = await admin.auth.admin.generateLink({ type: 'magiclink', email: p.email }); if (r.error) throw new Error(r.error.message); return { email: p.email, token_hash: (r.data as any).properties.hashed_token }; },
  async audit(e: any) { await admin.from('audit_log').insert(e); }
};
const cfgError = validateConfig({ rpID: Deno.env.get('WEBAUTHN_RP_ID') ?? '', origin: (Deno.env.get('APP_URL') ?? '').replace(/\/$/, '') });
if (cfgError) console.error('[passkeys] Configuración incompleta: ' + cfgError); // también se responde con error claro en cada llamada
Deno.serve(async (req) => { try { return await handle(req, deps); } catch (e) { return new Response(JSON.stringify({ error: String((e as Error).message) }), { status: 500 }); } });
