import {renderDecisionMail} from './commercial-decision-template.js';
import {commercialDelivery, buildCommercialMime} from './commercial-mail-delivery.js';
// AUTORIZACIONES COMERCIALES · avisos (nueva solicitud + resoluciones) por el correo corporativo. Lo llama comm-dispatcher: MISMO cron.
// Mensaje con destinatarios VISIBLES: Para = principales (aprobador / solicitante), CC = copias RATIFICADAS. Sin CCO.
// V3:
//  · La distribución se RECALCULA en el servidor inmediatamente antes de cada envío (distribución EFECTIVA = original de la foto menos
//    revocados / no habilitados) y se vuelve a comparar justo antes de MAIL FROM y de DATA: si cambió, el intento se suspende sin gastar
//    intento y se rearma. Un revocado no recibe ni figura en Para/CC de lo que todavía no salió. Lo enviado no se modifica.
//  · Clave de idempotencia POR CONTENIDO (evento:E:destinatario:v3:<huella>) + estado AGREGADO de TODAS las claves del destinatario en
//    el ledger (publicada, :v2, :v3:*): un cambio de distribución nunca duplica ni produce conflictos; lo aceptado nunca se reenvía.
//  · Foto faltante o inconsistente: el servidor RETIENE el aviso y registra una incidencia (no se reconstruye con el estado actual).
//  · SENT nunca se reenvía · INCIERTO → HELD sin reintento (los demás siguen) · sin cupo → PENDING sin gastar intento
//  · rechazo de UN destinatario → ERROR de ese destinatario · falla de infraestructura → ERROR (reintento seguro) y se corta el ciclo
export const DECISION_MAIL_LIMITS = {maxPerCycle: 20, budgetMs: 45000};
const PER_RECIPIENT = /^SMTP_(RECIPIENT|REJECTED)_|^SMTP_(MESSAGE_INVALID|CONFLICT|REJECTED|PREVIOUSLY_REJECTED)$/;
const NO_CAPACITY = new Set(['SMTP_RATE_LIMIT', 'SMTP_NOT_ACTIVE', 'SMTP_BUSY', 'SMTP_CREDENTIAL_MISSING', 'SMTP_AUTH_REJECTED', 'SMTP_CONFIG_INVALID', 'SMTP_AUTH_UNSUPPORTED']);
export const deliveryKey = (eventId, recipient, fingerprint) => 'evento:' + eventId + ':' + recipient + ':v3:' + String(fingerprint).slice(0, 16);

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
    if (r.error || !r.data) { out.stop = 'QUEUE_UNAVAILABLE'; break; }   // SQL no aplicado o revertido: no envía y no bloquea al despachador
    if (r.data.state === 'ROW_HELD' || r.data.state === 'ROW_FAILED') { out.held++; continue; }   // foto faltante/inconsistente: retenida + incidencia
    if (r.data.state === 'ROW_SKIPPED') { out.skipped++; continue; }   // copia que no estaba autorizada al registrarse el evento
    if (r.data.state !== 'CLAIMED') { out.stop = r.data.state; break; }
    out.claimed++;
    const step = await processOne(sb, delivery, st.email, r.data.job, r.data.payload, r.data.distribution);
    out[step.count]++;
    if (step.stop) { out.stop = step.stop; break; }
  }
  return out;
}

async function processOne(sb, delivery, from, j, payload, dist) {
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
  const hold = async (code, detail) => { await sb.rpc('comm_decision_mail_hold', {p_id: j.id, p_token: j.token, p_code: code, p_detail: String(detail || '').slice(0, 400)}).catch(() => {}); };
  let content;
  try { content = renderDecisionMail(payload); }
  catch (e) { await hold('DETALLE_INVALIDO', 'La plantilla rechazó la foto: ' + (e.code || e.message)); return {count: 'held'}; }   // nunca se envía un detalle dudoso
  try {
    await guard();
    if (!dist || !Array.isArray(dist.to) || !Array.isArray(dist.cc) || ![...dist.to, ...dist.cc].includes(j.recipient)) {
      await release('DISTRIBUTION_CHANGED'); return {count: 'released'};   // la distribución cambió entre la toma y ahora: se rearma en el ciclo siguiente
    }
    const msg = await buildCommercialMime({from, to: dist.to, cc: dist.cc, subject: content.subject, html: content.html, text: content.text, eventId: j.event_id});
    // Idempotencia: estado AGREGADO de todas las claves de este (evento, destinatario)
    const ls = await sb.rpc('comm_decision_mail_ledger_state', {p_event: j.event_id, p_recipient: j.recipient});
    if (ls.error) throw Object.assign(new Error('SMTP_STATE_UNAVAILABLE'), {code: 'SMTP_STATE_UNAVAILABLE'});
    if (ls.data?.state === 'ACCEPTED') { await finish('SENT', ls.data.provider_id); return {count: 'sent'}; }
    if (ls.data?.state === 'HELD') { await finish('HELD', null, 'RESULTADO_INCIERTO'); return {count: 'held'}; }
    if (ls.data?.state === 'REJECTED') throw Object.assign(new Error('SMTP_PREVIOUSLY_REJECTED'), {code: 'SMTP_PREVIOUSLY_REJECTED', status: 400});
    const key = deliveryKey(j.event_id, j.recipient, msg.fingerprint);
    await sb.rpc('comm_decision_mail_note_delivery', {p_id: j.id, p_token: j.token, p_meta: {to: msg.to, cc: msg.cc, hash: dist.hash, fingerprint: msg.fingerprint, key}});
    // justo antes de MAIL FROM y de DATA: destinatario habilitado Y misma distribución efectiva
    const recheck = async () => {
      await guard();
      const now = await sb.rpc('comm_decision_mail_distribution', {p_id: j.id, p_token: j.token});
      // code ABORTED: el transporte certificado lo propaga tal cual (cualquier otro error lo convertiría en falla de conexión)
      if (now.error) throw Object.assign(new Error('SMTP_STATE_UNAVAILABLE'), {code: 'ABORTED', reason: 'SMTP_STATE_UNAVAILABLE'});
      if (!now.data || now.data.hash !== dist.hash) throw Object.assign(new Error('DISTRIBUTION_CHANGED'), {code: 'ABORTED', reason: 'DISTRIBUTION_CHANGED'});
    };
    const res = await delivery.deliver({key, envelopeTo: j.recipient, raw: msg.raw, fingerprint: msg.fingerprint, beforeData: recheck});
    await finish('SENT', res.id);
    return {count: 'sent'};
  } catch (e) {
    if (discarded) return {count: 'skipped'};
    const code = e.code || e.message || 'MAIL_FAILED';
    if (e.phase === 'AFTER_SEND' || code === 'MAIL_RESULT_UNRECORDED' || code === 'SMTP_POR_VERIFICAR') {
      await finish('HELD', null, code === 'SMTP_POR_VERIFICAR' ? 'RESULTADO_INCIERTO' : code).catch(() => {});
      return {count: 'held'};   // incierto para ESTE destinatario: no se reintenta; los demás siguen
    }
    if (e.reason === 'DISTRIBUTION_CHANGED') { await release('DISTRIBUTION_CHANGED'); return {count: 'released'}; }   // revocación concurrente: sin gastar intento
    if (NO_CAPACITY.has(code) || code === 'ABORTED' || code === 'SMTP_STATE_UNAVAILABLE') {
      await release(code === 'ABORTED' ? (e.reason || 'MAIL_CONFIGURATION_CHANGED') : code);
      return {count: 'released', stop: code};
    }
    await finish('ERROR', null, code).catch(() => {});
    return PER_RECIPIENT.test(code) ? {count: 'errors'} : {count: 'errors', stop: code};
  }
}
