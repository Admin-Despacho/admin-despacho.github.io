import {renderDecisionMail} from './commercial-decision-template.js';
import {commercialDelivery, buildCommercialMime} from './commercial-mail-delivery.js';
// AUTORIZACIONES COMERCIALES · avisos (nueva solicitud + resoluciones) por el correo corporativo. Lo llama comm-dispatcher: MISMO cron.
// Mensaje ÚNICO por evento con destinatarios VISIBLES: Para = principales (aprobador / solicitante), CC = copias RATIFICADAS. Sin CCO.
// La distribución sale de la FOTO del evento (servidor), nunca del navegador. Cada destinatario se entrega en su propia transacción SMTP
// con su propia clave de idempotencia: el ciclo toma de a uno (SKIP LOCKED + cupo) y repite mientras haya pendientes, cupo y tiempo.
//  · SENT nunca se reenvía · resultado INCIERTO → HELD, sin reintento automático (los demás destinatarios siguen)
//  · aceptado antes con la clave publicada o la V2 (también tras una reversión/reinstalación) → SENT sin reenviar
//  · sin cupo / proveedor inactivo antes de enviar → PENDING sin gastar intento y se corta el ciclo
//  · rechazo de UN destinatario → ERROR de ese destinatario y se sigue con los demás
//  · falla de infraestructura antes de enviar → ERROR (reintento seguro en 5 min, máx. 4) y se corta el ciclo
export const DECISION_MAIL_LIMITS = {maxPerCycle: 20, budgetMs: 45000};
const PER_RECIPIENT = /^SMTP_(RECIPIENT|REJECTED)_|^SMTP_(MESSAGE_INVALID|CONFLICT|REJECTED|PREVIOUSLY_REJECTED)$|^RECIPIENT_NOT_IN_DISTRIBUTION$/;
const NO_CAPACITY = new Set(['SMTP_RATE_LIMIT', 'SMTP_NOT_ACTIVE', 'SMTP_BUSY', 'SMTP_CREDENTIAL_MISSING', 'SMTP_AUTH_REJECTED', 'SMTP_CONFIG_INVALID', 'SMTP_AUTH_UNSUPPORTED']);
// Claves del ledger: la PUBLICADA (evento:E:destinatario) y la alternativa V2 (…:v2, solo si la publicada quedó con otro contenido sin entregar).
export const deliveryKeys = (eventId, recipient) => { const k = 'evento:' + eventId + ':' + recipient; return [k, k + ':v2']; };

export async function sendCommercialDecisionEmails(sb, options = {}) {
  const limits = {...DECISION_MAIL_LIMITS, ...(options.limits || {})}, now = options.now || (() => Date.now()), start = now();
  const delivery = options.delivery || commercialDelivery(sb, options);
  const out = {sent: 0, held: 0, errors: 0, skipped: 0, released: 0, claimed: 0, stop: null};
  let st;
  try { st = await delivery.runtime(); } catch { return {...out, active: false, stop: 'RUNTIME_UNAVAILABLE'}; }
  if (st.provider !== 'SMTP' || !st.connected) return {...out, active: false, stop: 'SMTP_NOT_ACTIVE'};
  for (let i = 0; i < limits.maxPerCycle; i++) {
    if (now() - start > limits.budgetMs) { out.stop = 'TIME_BUDGET'; break; }
    const r = await sb.rpc('comm_decision_mail_claim_next');
    if (r.error || !r.data) { out.stop = 'QUEUE_UNAVAILABLE'; break; }   // SQL V2 no aplicado o revertido: no envía y no bloquea al despachador
    if (r.data.state === 'ROW_FAILED') { out.errors++; continue; }
    if (r.data.state !== 'CLAIMED') { out.stop = r.data.state; break; }
    out.claimed++;
    const step = await processOne(sb, delivery, st.email, r.data.job, r.data.payload);
    out[step.count]++;
    if (step.stop) { out.stop = step.stop; break; }
  }
  return out;
}

async function processOne(sb, delivery, from, j, payload) {
  let discarded = false;
  const guard = async () => {
    const g = await sb.rpc('comm_decision_mail_guard', {p_id: j.id, p_token: j.token});
    if (g.error || typeof g.data !== 'boolean') throw Object.assign(new Error('RECIPIENT_CHECK_UNAVAILABLE'), {code: 'RECIPIENT_CHECK_UNAVAILABLE'});
    if (!g.data) { discarded = true; throw Object.assign(new Error('ABORTED'), {code: 'ABORTED'}); }   // revocado / inactivo / sin ratificar: SKIPPED en SQL
  };
  const finish = async (state, reference = null, error = null) => {
    const f = await sb.rpc('comm_decision_mail_finish', {p_id: j.id, p_token: j.token, p_state: state, p_reference: reference, p_error: error});
    if (f.error) throw Object.assign(new Error('MAIL_RESULT_UNRECORDED'), {code: 'MAIL_RESULT_UNRECORDED'});
  };
  const release = async code => { await sb.rpc('comm_decision_mail_release', {p_id: j.id, p_token: j.token, p_code: code}).catch(() => {}); };
  let msg;
  try {
    const content = renderDecisionMail(payload);
    const dist = payload.distribution || {to: [j.recipient], cc: []};
    msg = await buildCommercialMime({from, to: dist.to, cc: dist.cc, subject: content.subject, html: content.html, text: content.text, eventId: j.event_id});
    if (![...msg.to, ...msg.cc].includes(j.recipient)) throw Object.assign(new Error('RECIPIENT_NOT_IN_DISTRIBUTION'), {code: 'RECIPIENT_NOT_IN_DISTRIBUTION'});
  } catch (e) {
    try { await guard(); } catch { if (discarded) return {count: 'skipped'}; }
    await finish('ERROR', null, e.code === 'RECIPIENT_NOT_IN_DISTRIBUTION' ? e.code : 'DETALLE_INVALIDO').catch(() => {});
    return {count: 'errors'};
  }
  try {
    await guard();
    // Idempotencia entre versiones: si la clave publicada o la V2 ya figuran ACEPTADAS → SENT sin reenviar; si alguna es incierta → HELD.
    const [k1, k2] = deliveryKeys(j.event_id, j.recipient), p1 = await delivery.lookup(k1), p2 = await delivery.lookup(k2);
    const acc = [p1, p2].find(p => p?.state === 'ACCEPTED');
    if (acc) { await finish('SENT', acc.id); return {count: 'sent'}; }
    if ([p1, p2].some(p => p?.state === 'HELD')) { await finish('HELD', null, 'RESULTADO_INCIERTO'); return {count: 'held'}; }
    if (p1?.state === 'REJECTED' || p2?.state === 'REJECTED') throw Object.assign(new Error('SMTP_PREVIOUSLY_REJECTED'), {code: 'SMTP_PREVIOUSLY_REJECTED', status: 400});
    const send = key => delivery.deliver({key, envelopeTo: j.recipient, raw: msg.raw, fingerprint: msg.fingerprint, beforeData: guard});
    let res;
    try { res = await send(k1); }
    catch (e) { if (e.code !== 'SMTP_CONFLICT') throw e; res = await send(k2); }   // la clave publicada guarda OTRO contenido NO entregado
    await finish('SENT', res.id);
    return {count: 'sent'};
  } catch (e) {
    if (discarded) return {count: 'skipped'};
    const code = e.code || e.message || 'MAIL_FAILED';
    if (e.phase === 'AFTER_SEND' || code === 'MAIL_RESULT_UNRECORDED' || code === 'SMTP_POR_VERIFICAR') {
      await finish('HELD', null, code === 'SMTP_POR_VERIFICAR' ? 'RESULTADO_INCIERTO' : code).catch(() => {});
      return {count: 'held'};   // incierto para ESTE destinatario: no se reintenta; los demás siguen (cada entrega es independiente)
    }
    if (NO_CAPACITY.has(code) || code === 'ABORTED' || code === 'SMTP_STATE_UNAVAILABLE') {
      await release(code === 'ABORTED' ? 'MAIL_CONFIGURATION_CHANGED' : code);
      return {count: 'released', stop: code};
    }
    await finish('ERROR', null, code).catch(() => {});
    return PER_RECIPIENT.test(code) ? {count: 'errors'} : {count: 'errors', stop: code};
  }
}
