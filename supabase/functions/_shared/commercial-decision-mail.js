import {corporateMail} from './corporate-mail.js';
import {renderDecisionMail} from './commercial-decision-template.js';
// AUTORIZACIONES COMERCIALES · envío de resoluciones por el correo corporativo (lo llama comm-dispatcher: MISMO cron, sin otro programador).
// Por ciclo toma de a UN destinatario (comm_decision_mail_claim_next: SKIP LOCKED + cupo horario y diario) y repite mientras haya
// pendientes, cupo y tiempo: el autor y las copias salen en el mismo ciclo. Cada destinatario es independiente:
//  · SENT nunca se reenvía (la toma solo ve PENDING/ERROR) · resultado INCIERTO → HELD, sin reintento automático
//  · sin cupo / proveedor inactivo antes de enviar → vuelve a PENDING SIN gastar intento y se corta el ciclo
//  · rechazo de UN destinatario → ERROR de ese destinatario y se sigue con los demás
//  · falla de infraestructura antes de enviar → ERROR (reintento seguro en 5 min, máx. 4) y se corta el ciclo
export const DECISION_MAIL_LIMITS = {maxPerCycle: 20, budgetMs: 45000};
export const DECISION_MAIL_KEY_VERSION = 'detalle-v1';
const PER_RECIPIENT = /^SMTP_(RECIPIENT|REJECTED)_|^SMTP_(MESSAGE_INVALID|CONFLICT|REJECTED|PREVIOUSLY_REJECTED)$/;
const NO_CAPACITY = new Set(['SMTP_RATE_LIMIT', 'SMTP_NOT_ACTIVE', 'SMTP_BUSY', 'SMTP_CREDENTIAL_MISSING', 'SMTP_AUTH_REJECTED', 'SMTP_CONFIG_INVALID', 'SMTP_AUTH_UNSUPPORTED']);

export async function sendCommercialDecisionEmails(sb, options = {}) {
  const limits = {...DECISION_MAIL_LIMITS, ...(options.limits || {})}, now = options.now || (() => Date.now()), start = now();
  const mail = corporateMail(sb, {...options, scope: 'decisiones'});
  const out = {sent: 0, held: 0, errors: 0, skipped: 0, released: 0, claimed: 0, stop: null};
  let st;
  try { st = await mail.runtime(); } catch { return {...out, active: false, stop: 'RUNTIME_UNAVAILABLE'}; }
  if (st.provider !== 'SMTP' || !st.connected) return {...out, active: false, stop: 'SMTP_NOT_ACTIVE'};
  for (let i = 0; i < limits.maxPerCycle; i++) {
    if (now() - start > limits.budgetMs) { out.stop = 'TIME_BUDGET'; break; }
    const r = await sb.rpc('comm_decision_mail_claim_next');
    if (r.error || !r.data) { out.stop = 'QUEUE_UNAVAILABLE'; break; }   // p. ej. SQL no aplicado: no bloquea el resto del despachador
    if (r.data.state === 'ROW_FAILED') { out.errors++; continue; }
    if (r.data.state !== 'CLAIMED') { out.stop = r.data.state; break; }
    out.claimed++;
    const j = r.data.job, step = await processOne(sb, mail, j, r.data.payload);
    out[step.count]++;
    if (step.stop) { out.stop = step.stop; break; }
  }
  return out;
}

async function processOne(sb, mail, j, payload) {
  let discarded = false;
  const guard = async () => {
    const g = await sb.rpc('comm_decision_mail_guard', {p_id: j.id, p_token: j.token});
    if (g.error || typeof g.data !== 'boolean') throw Object.assign(new Error('RECIPIENT_CHECK_UNAVAILABLE'), {code: 'RECIPIENT_CHECK_UNAVAILABLE'});
    if (!g.data) { discarded = true; throw Object.assign(new Error('ABORTED'), {code: 'ABORTED'}); }   // SQL descartó al destinatario (SKIPPED) o se perdió la reserva
  };
  const finish = async (state, reference = null, error = null) => {
    const f = await sb.rpc('comm_decision_mail_finish', {p_id: j.id, p_token: j.token, p_state: state, p_reference: reference, p_error: error});
    if (f.error) throw Object.assign(new Error('MAIL_RESULT_UNRECORDED'), {code: 'MAIL_RESULT_UNRECORDED'});
  };
  const release = async code => { await sb.rpc('comm_decision_mail_release', {p_id: j.id, p_token: j.token, p_code: code}).catch(() => {}); };
  let mailContent;
  try { mailContent = renderDecisionMail(payload); }
  catch (e) { await finish('ERROR', null, e.code || 'DETALLE_INVALIDO').catch(() => {}); return {count: 'errors'}; }
  try {
    await guard();
    // Compatibilidad: si este destinatario ya figura ACEPTADO con la clave anterior (aviso breve), no se vuelve a enviar.
    let prior = null;
    try { prior = await mail.prior('evento:' + j.event_id + ':' + j.recipient); }
    catch (e) { if (e.code !== 'SMTP_PREVIOUSLY_REJECTED') throw e; }
    if (prior) { await finish('SENT', prior.id); return {count: 'sent'}; }
    const res = await mail.send({to: j.recipient, idempotencyKey: 'evento:' + j.event_id + ':' + j.recipient + ':' + DECISION_MAIL_KEY_VERSION,
      subject: mailContent.subject, text: mailContent.text, html: mailContent.html, attachments: [], beforeData: guard});
    await finish('SENT', res.id);
    return {count: 'sent'};
  } catch (e) {
    if (discarded) return {count: 'skipped'};
    const code = e.code || e.message || 'MAIL_FAILED';
    if (e.phase === 'AFTER_SEND' || code === 'MAIL_RESULT_UNRECORDED' || code === 'SMTP_POR_VERIFICAR') {
      await finish('HELD', null, code === 'SMTP_POR_VERIFICAR' ? 'RESULTADO_INCIERTO' : code).catch(() => {});
      return {count: 'held', stop: 'UNCERTAIN_RESULT'};
    }
    if (NO_CAPACITY.has(code) || (code === 'ABORTED' && !discarded) || code === 'SMTP_STATE_UNAVAILABLE') {
      await release(code === 'ABORTED' ? 'MAIL_CONFIGURATION_CHANGED' : code);
      return {count: 'released', stop: code};
    }
    await finish('ERROR', null, code).catch(() => {});
    return PER_RECIPIENT.test(code) ? {count: 'errors'} : {count: 'errors', stop: code};
  }
}
