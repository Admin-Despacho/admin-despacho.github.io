// WebAuthn en el navegador: registro y verificación (demo) con WebCrypto. No se guarda biometría:
// el dispositivo valida huella/Face ID/PIN y solo entrega una firma; acá se guarda la clave pública.
const b64 = b => btoa(String.fromCharCode(...new Uint8Array(b)));
const unb64 = s => Uint8Array.from(atob(s), c => c.charCodeAt(0));
export const passkeysSupported = () => typeof window !== 'undefined' && !!window.PublicKeyCredential && !!navigator.credentials;

export async function createPasskey(opts) {
  const cred = await navigator.credentials.create({ publicKey: {
    challenge: opts.challenge, rp: opts.rp, user: opts.user, timeout: 60000, attestation: 'none',
    pubKeyCredParams: [{ type: 'public-key', alg: -7 }, { type: 'public-key', alg: -257 }],
    authenticatorSelection: { residentKey: 'preferred', userVerification: 'required' },
    excludeCredentials: (opts.excludeCredentials || []).map(id => ({ type: 'public-key', id: unb64(id) })) } });
  const u = x => b64(x).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  return { credential_id: b64(cred.rawId), public_key: b64(cred.response.getPublicKey()), alg: cred.response.getPublicKeyAlgorithm(),
    json: { id: cred.id, rawId: u(cred.rawId), type: 'public-key', response: { clientDataJSON: u(cred.response.clientDataJSON), attestationObject: u(cred.response.attestationObject), transports: cred.response.getTransports ? cred.response.getTransports() : [] }, clientExtensionResults: {} } };
}
export async function getAssertion(opts) {
  const a = await navigator.credentials.get({ publicKey: { challenge: opts.challenge, rpId: opts.rpId, userVerification: 'required', timeout: 60000 } });
  const u = x => b64(x).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  return { credential_id: b64(a.rawId), authenticatorData: b64(a.response.authenticatorData), clientDataJSON: b64(a.response.clientDataJSON), signature: b64(a.response.signature),
    json: { id: a.id, rawId: u(a.rawId), type: 'public-key', response: { clientDataJSON: u(a.response.clientDataJSON), authenticatorData: u(a.response.authenticatorData), signature: u(a.response.signature), userHandle: a.response.userHandle ? u(a.response.userHandle) : undefined }, clientExtensionResults: {} } };
}
// DER (ECDSA) → r||s de 64 bytes
function derToRaw(der) {
  let i = 2; const rl = der[i + 1]; let r = der.slice(i + 2, i + 2 + rl); i = i + 2 + rl; const sl = der[i + 1]; let s = der.slice(i + 2, i + 2 + sl);
  const pad = x => { x = x[0] === 0 ? x.slice(1) : x; const o = new Uint8Array(32); o.set(x, 32 - x.length); return o; };
  const out = new Uint8Array(64); out.set(pad(r), 0); out.set(pad(s), 32); return out;
}
// Verificación de la firma (desafío, origen, RP ID, presencia y verificación del usuario, contador)
export async function verifyAssertion({ assertion, publicKey, alg, expectedChallenge, origin, rpId, signCount }) {
  const cd = JSON.parse(new TextDecoder().decode(unb64(assertion.clientDataJSON)));
  const chB64url = expectedChallenge.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  if (cd.type !== 'webauthn.get' || cd.challenge !== chB64url || cd.origin !== origin) return { verified: false };
  const ad = unb64(assertion.authenticatorData);
  const rpHash = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(rpId)));
  if (!rpHash.every((b, i) => b === ad[i])) return { verified: false };
  const flags = ad[32]; if (!(flags & 1) || !(flags & 4)) return { verified: false }; // UP y UV
  const count = (ad[33] << 24) | (ad[34] << 16) | (ad[35] << 8) | ad[36];
  if (count !== 0 && count <= (signCount || 0)) return { verified: false };
  const data = new Uint8Array([...ad, ...new Uint8Array(await crypto.subtle.digest('SHA-256', unb64(assertion.clientDataJSON)))]);
  const ec = alg === -7;
  const key = await crypto.subtle.importKey('spki', unb64(publicKey), ec ? { name: 'ECDSA', namedCurve: 'P-256' } : { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['verify']);
  const sig = ec ? derToRaw(unb64(assertion.signature)) : unb64(assertion.signature);
  const ok = await crypto.subtle.verify(ec ? { name: 'ECDSA', hash: 'SHA-256' } : 'RSASSA-PKCS1-v1_5', key, sig, data);
  return { verified: ok, signCount: count };
}
