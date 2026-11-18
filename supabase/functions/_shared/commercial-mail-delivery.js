// AUTORIZACIONES COMERCIALES · entrega con destinatarios VISIBLES (Para + CC, sin CCO) sobre el transporte CERTIFICADO SIN CAMBIOS.
// Un mismo mensaje por evento (mismas cabeceras Para/CC/Asunto/Message-ID) se entrega a CADA destinatario en su propia transacción
// SMTP (un RCPT por transacción, exactamente como el transporte certificado). Así:
//  · todos ven quiénes fueron notificados y pueden «Responder a todos»;
//  · una aceptación parcial nunca obliga a reenviar a quien ya lo recibió (cada entrega tiene su propia clave en el ledger);
//  · el cupo (100/h, 850/24 h) se descuenta por destinatario, igual que el proveedor cuenta destinatarios.
// Usa el MISMO ledger (comm_smtp_claim / comm_smtp_finish) y las mismas reglas de incertidumbre que corporate-mail.js.
import { smtpTransport, SmtpError, denoSmtpIO } from './smtp-transport.js';
import { digest } from './corporate-mail.js';

const enc = new TextEncoder();
const b64 = b => { let s = ''; for (let i = 0; i < b.length; i += 32768) s += String.fromCharCode(...b.subarray(i, i + 32768)); return btoa(s); };
const clean = s => String(s ?? '').replace(/[\r\n\u0000]/g, ' ').trim();
const word = s => '=?UTF-8?B?' + b64(enc.encode(clean(s))) + '?=';
const fold76 = s => (s.match(/.{1,76}/g) || []).join('\r\n') + '\r\n';
export const ADDRESS = /^[A-Za-z0-9.!#$%&'*+\/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z0-9-]+$/;
export const validAddress = a => typeof a === 'string' && a.length <= 254 && ADDRESS.test(a);
const addrHeader = (name, list) => list.length ? name + ': ' + list.map(a => '<' + a + '>').join(',\r\n ') + '\r\n' : '';

// Normaliza y deduplica: Para tiene prioridad; CC excluye lo que ya está en Para. Nunca CCO.
export function distributionLists(to, cc) {
  const norm = a => String(a ?? '').trim().toLowerCase(), seen = new Set(), T = [], C = [];
  for (const a of to || []) { const v = norm(a); if (!validAddress(v)) throw new SmtpError('SMTP_MESSAGE_INVALID', { status: 400 }); if (!seen.has(v)) { seen.add(v); T.push(v); } }
  for (const a of cc || []) { const v = norm(a); if (!validAddress(v)) throw new SmtpError('SMTP_MESSAGE_INVALID', { status: 400 }); if (!seen.has(v)) { seen.add(v); C.push(v); } }
  if (!T.length && !C.length) throw new SmtpError('SMTP_MESSAGE_INVALID', { status: 400 });   // sin principales habilitados puede quedar solo CC (nunca CCO)
  return { to: T, cc: C };
}

// MIME determinista (mismo evento ⇒ mismos bytes ⇒ misma huella en el ledger, también entre reintentos).
export async function buildCommercialMime({ from, to, cc, subject, html, text, eventId }) {
  if (from !== 'fgutierrez@okaccesorios.com') throw new SmtpError('SMTP_CONFIG_INVALID', { status: 401 });
  const d = distributionLists(to, cc), h = (await digest(String(eventId) + '|' + clean(subject))).slice(0, 24);
  const A = 'okd-alt-' + h, mid = 'okd-com-' + String(eventId).replace(/\D/g, '') + '-' + h + '@okaccesorios.com';
  let raw = 'From: ' + word('OK Despacho') + ' <' + from + '>\r\n' + addrHeader('To', d.to) + addrHeader('Cc', d.cc) +
    'Subject: ' + word(subject) + '\r\nMessage-ID: <' + mid + '>\r\nMIME-Version: 1.0\r\nContent-Type: multipart/alternative; boundary="' + A + '"\r\n\r\n';
  for (const [type, body] of [['text/plain', text], ['text/html', html]]) raw += '--' + A + '\r\nContent-Type: ' + type + '; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n' + fold76(b64(enc.encode(String(body ?? ''))));
  raw += '--' + A + '--\r\n';
  return { raw, to: d.to, cc: d.cc, messageId: mid, fingerprint: await digest(raw) };
}

/** @param {any} sb @param {{connect?:any,startTls?:any,transport?:any}} [o] */
export function commercialDelivery(sb, { connect, startTls, transport } = {}) {
  if (!transport) { const io = denoSmtpIO(), cn = connect || io.connect, st = startTls || io.startTls;
    transport = (cn && st) ? smtpTransport({ connect: cn, startTls: st }) : { send: async () => { throw new SmtpError('SMTP_STARTTLS_REQUIRED', { status: 503 }); } }; }
  const rpc = async (name, args = {}) => { const { data, error } = await sb.rpc(name, args); if (error) throw new SmtpError('SMTP_STATE_UNAVAILABLE'); return data; };
  const runtime = () => rpc('comm_mail_runtime');
  const scope = k => 'decisiones:' + k;
  return {
    runtime,
    // Estado de una clave en el ledger: ACCEPTED · HELD (incluye PROCESSING) · REJECTED · RETRYABLE · AUTH_ERROR · null
    async lookup(key) { const p = await rpc('comm_smtp_lookup', { p_key: scope(key) }); return p ? { state: p.state, id: p.provider_id } : null; },
    // Entrega a UN destinatario del sobre (envelopeTo) el mensaje completo (con Para/CC visibles). Mismas reglas que corporate-mail.js.
    async deliver({ key, envelopeTo, raw, fingerprint, beforeData }) {
      if (!validAddress(envelopeTo)) throw new SmtpError('SMTP_MESSAGE_INVALID', { status: 400 });
      const c = await rpc('comm_smtp_credentials'); if (!c) throw new SmtpError('SMTP_CREDENTIAL_MISSING', { status: 401 });
      const claim = await rpc('comm_smtp_claim', { p_key: scope(key), p_fingerprint: fingerprint });
      if (claim.state === 'ACCEPTED') return { id: claim.provider_id, cached: true };
      if (claim.state === 'HELD') throw new SmtpError('SMTP_POR_VERIFICAR', { ambiguous: true });
      if (claim.state !== 'READY') throw new SmtpError('SMTP_' + claim.state, { status: ['CONFLICT', 'REJECTED'].includes(claim.state) ? 400 : 503 });
      let accepted = false;
      try {
        const check = async () => { const st = await runtime(); if (st.provider !== 'SMTP' || !st.connected || st.secret_version !== c.secret_version) throw Object.assign(new Error('MAIL_CONFIGURATION_CHANGED'), { code: 'ABORTED' }); if (beforeData) await beforeData(); };
        await check();
        const r = await transport.send(c, { from: c.from, to: envelopeTo, raw }, check); accepted = true;
        await rpc('comm_smtp_finish', { p_key: scope(key), p_token: claim.token, p_state: 'ACCEPTED', p_provider_id: r.id });
        return r;
      } catch (e) {
        const uncertain = accepted || e.phase === 'AFTER_SEND';
        await rpc('comm_smtp_finish', { p_key: scope(key), p_token: claim.token, p_state: uncertain ? 'HELD' : e.status === 401 ? 'AUTH_ERROR' : e.status === 400 ? 'REJECTED' : 'RETRYABLE', p_provider_id: null }).catch(() => {});
        if (e.status === 401) await rpc('comm_smtp_probe_result', { p_ok: false, p_secret_version: c.secret_version }).catch(() => {});
        if (uncertain) throw new SmtpError('SMTP_POR_VERIFICAR', { ambiguous: true });
        throw e;
      }
    },
  };
}
