// =====================================================================================================================
// COMUNICACIONES · almacenamiento EN MEMORIA con las mismas reglas que las funciones SQL de la migración (claim/check/finish/…).
// Lo usan las pruebas del despachador y el modo demo. Las reglas reales del servidor se prueban aparte en Postgres.
// =====================================================================================================================
import { MAX_ATTEMPTS, backoffSeconds } from './comms-core.js';

const uid = p => p + '-' + Math.random().toString(36).slice(2, 10) + Date.now().toString(36).slice(-4);
export const STALE_PROCESSING_MS = 10 * 60e3;
export const vencidoReason = h => 'Vencido: no se envió dentro de las ' + h + ' h siguientes al horario programado (pausa, desconexión o interrupción). Queda para revisión; no se envía automáticamente.';

export class MemoryCommsStore {
  constructor(db = {}, { onChange, clock } = {}) {
    this.clock = clock || (() => Date.now());   // reloj del limitador (inyectable en pruebas)
    this.rate = [];
    this.db = Object.assign({ collaborators: [], messages: [], blobs: {}, runs: [], deliveries: [], gmail: { connected: false, needs_reconnect: false, email: null },
      dispatches: [], shares: [], audit: [] }, db);
    this.onChange = onChange || (() => {});
  }
  _save() { this.onChange(this.db); }
  _msg(id) { return this.db.messages.find(m => m.id === id); }
  _run(id) { return this.db.runs.find(r => r.id === id); }
  // ---------- lo que usa el despachador ----------
  async gmailStatus() { return { ...this.db.gmail }; }
  async listActiveMessages() { return this.db.messages.filter(m => m.status === 'ACTIVO').map(m => ({ ...m, attachments: (m.attachments || []).filter(a => !a.detached) })); }
  async listCollaborators() { return this.db.collaborators.map(c => ({ ...c })); }
  async createRun(r) {
    if (this.db.runs.some(x => x.message_id === r.message_id && x.scheduled_for === r.scheduled_for && x.kind === r.kind)) return null;   // única por comunicado + horario
    const run = { id: uid('run'), message_id: r.message_id, scheduled_for: r.scheduled_for, kind: r.kind, status: r.missed ? 'PERDIDA' : 'PENDIENTE',
      snapshot: JSON.parse(JSON.stringify(r.snapshot)), recipients_count: (r.recipients || []).length, created_at: new Date().toISOString(),
      note: r.missed ? 'Ejecución perdida (el servidor no la procesó a tiempo): NO se envió; queda para revisión.' : null };
    this.db.runs.push(run);
    for (const p of r.recipients || []) {
      if (this.db.deliveries.some(d => d.run_id === run.id && d.email === p.email)) continue;   // clave única ejecución + destinatario
      this.db.deliveries.push({ id: uid('dl'), run_id: run.id, collaborator_id: p.collaborator_id || null, email: p.email, name: p.name, status: 'PENDIENTE', attempts: 0, next_attempt_at: null, retryable: true,
        claim_token: null, claimed_at: null, gmail_message_id: null, sent_at: null, last_error: null, reason: null });
    }
    for (const x of r.skipped || []) this.db.deliveries.push({ id: uid('dl'), run_id: run.id, collaborator_id: x.id, email: null, name: x.name, status: 'OMITIDO', attempts: 0, reason: x.reason });
    this._save(); return run.id;
  }
  async advanceCursor(id, prev, next) { const m = this._msg(id); if (!m || (m.cursor || null) !== prev) return false; m.cursor = next; this._save(); return true; }
  async sentLast24h(now) { return this.db.deliveries.filter(d => d.status === 'ENVIADO' && Date.parse(d.sent_at || d.claimed_at || d.confirmed_at || 0) > now - 864e5).length; }
  // limitador COMPARTIDO (mismas reglas que comm_rate_acquire): ventanas de 60 s y de 1 s.
  // Devuelve { wait_ms: 0, event_id } si concede, o { wait_ms: N } si hay que esperar (nada se reserva).
  async acquireRate(units, perMin = 6000, perSec = 200) {
    const t = this.clock(); this.rate = this.rate.filter(e => e.at > t - 120e3);
    const sum = w => this.rate.filter(e => e.at > t - w).reduce((a, e) => a + e.units, 0), m60 = sum(60e3), m1 = sum(1e3);
    if (m60 + units <= perMin && m1 + units <= perSec) { const id = (this.rateSeq = (this.rateSeq || 0) + 1); this.rate.push({ id, at: t, units }); return { wait_ms: 0, event_id: id }; }
    const first = w => Math.min(...this.rate.filter(e => e.at > t - w).map(e => e.at));
    return { wait_ms: Math.max(20, Math.ceil(Math.max(m60 + units > perMin ? first(60e3) + 60e3 - t : 0, m1 + units > perSec ? first(1e3) + 1e3 - t : 0))) };
  }
  // devuelve EXACTAMENTE la reserva indicada (un envío interrumpido antes de llamar a Gmail no consume cupo)
  async refundRate(id) { this.rate = this.rate.filter(e => e.id !== id); }
  async claim(limit, worker, now, { dailyCap = Infinity, windowHours = 6 } = {}) {
    for (const d of this.db.deliveries) if (d.status === 'PROCESANDO' && Date.parse(d.claimed_at) < now - STALE_PROCESSING_MS) {
      Object.assign(d, { status: 'POR_VERIFICAR', claim_token: null, last_error: 'El procesamiento se interrumpió: verificá en "Enviados" de Gmail si llegó a enviarse antes de reintentar.' }); }
    // VENCIMIENTO también para pendientes y reintentos YA encolados (p. ej. al reanudar después de una pausa): quedan para revisión
    for (const d of this.db.deliveries) if ((d.status === 'PENDIENTE' || (d.status === 'ERROR' && d.retryable)) && !(d.manual_ok_until && Date.parse(d.manual_ok_until) > now)) {
      const r = this._run(d.run_id); if (r && Date.parse(r.scheduled_for) < now - windowHours * 3600e3) Object.assign(d, { status: 'VENCIDO', next_attempt_at: null, reason: vencidoReason(windowHours) }); }
    // CUPO diario reservado en la MISMA operación: enviados + en curso + inciertos de las últimas 24 h (incluye pruebas)
    const sentAt = d => Date.parse(d.sent_at || d.claimed_at || d.confirmed_at || 0);
    const used = this.db.deliveries.filter(d => (d.status === 'ENVIADO' && sentAt(d) > now - 864e5) || d.status === 'PROCESANDO'
      || (d.status === 'POR_VERIFICAR' && d.claimed_at && Date.parse(d.claimed_at) > now - 864e5)).length;
    limit = Math.max(0, Math.min(limit, dailyCap - used));
    const ok = d => { const r = this._run(d.run_id); if (!r || r.status === 'CANCELADA') return false; if (r.kind === 'PRUEBA') return true; const m = this._msg(r.message_id); return m && m.status === 'ACTIVO'; };
    const due = this.db.deliveries.filter(d => (d.status === 'PENDIENTE' || (d.status === 'ERROR' && d.retryable && d.attempts < MAX_ATTEMPTS && d.next_attempt_at && Date.parse(d.next_attempt_at) <= now)) && ok(d))
      .sort((a, b) => (this._run(a.run_id).scheduled_for).localeCompare(this._run(b.run_id).scheduled_for)).slice(0, limit);   // estable: por ejecución y luego orden de alta (como el id correlativo del SQL)
    const out = due.map(d => { Object.assign(d, { status: 'PROCESANDO', claim_token: uid('tk'), claimed_at: new Date(now).toISOString(), attempts: d.attempts + 1, worker });
      return { id: d.id, token: d.claim_token, run_id: d.run_id, email: d.email, name: d.name, collaborator_id: d.collaborator_id, attempts: d.attempts, snapshot: this._run(d.run_id).snapshot }; });
    this._save(); return out;
  }
  async check(id, token) {
    const d = this.db.deliveries.find(x => x.id === id); if (!d || d.status !== 'PROCESANDO' || d.claim_token !== token) return 'LOST';
    const r = this._run(d.run_id), m = this._msg(r.message_id);
    if (r.kind !== 'PRUEBA') {
      if (r.status === 'CANCELADA' || !m || m.status === 'CANCELADO') { Object.assign(d, { status: 'CANCELADO', claim_token: null, reason: 'Comunicado cancelado antes del envío' }); this._save(); return 'CANCELLED'; }
      if (m.status === 'PAUSADO') { Object.assign(d, { status: 'PENDIENTE', claim_token: null, attempts: d.attempts - 1 }); this._save(); return 'PAUSED'; }
      const c = d.collaborator_id && this.db.collaborators.find(x => x.id === d.collaborator_id);
      if (c && !c.active) { Object.assign(d, { status: 'OMITIDO', claim_token: null, reason: 'Colaborador desactivado antes del envío' }); this._save(); return 'INACTIVE_RECIPIENT'; }
    }
    if (!this.db.gmail.connected || this.db.gmail.needs_reconnect) { Object.assign(d, { status: 'PENDIENTE', claim_token: null, attempts: d.attempts - 1 }); this._save(); return 'NO_CONNECTION'; }
    return 'OK';
  }
  async release(id, token) { const d = this.db.deliveries.find(x => x.id === id); if (d && d.claim_token === token && d.status === 'PROCESANDO') { Object.assign(d, { status: 'PENDIENTE', claim_token: null, attempts: d.attempts - 1 }); this._save(); } }
  async finish(id, token, r, now) {
    const d = this.db.deliveries.find(x => x.id === id); if (!d || d.claim_token !== token || d.status !== 'PROCESANDO') return 'LOST';
    d.claim_token = null; d.last_error = null;
    if (r.outcome === 'ACCEPTED') Object.assign(d, { status: 'ENVIADO', gmail_message_id: r.gmail_id || null, sent_at: new Date(now).toISOString(), sent_at_source: 'GMAIL' });
    else if (r.outcome === 'RETRYABLE' && d.attempts < MAX_ATTEMPTS) Object.assign(d, { status: 'ERROR', retryable: true, next_attempt_at: new Date(now + backoffSeconds(d.attempts) * 1000).toISOString(), last_error: r.error, error_code: r.error_code });
    else if (r.outcome === 'AMBIGUOUS') Object.assign(d, { status: 'POR_VERIFICAR', last_error: r.error, error_code: r.error_code });
    else { Object.assign(d, { status: 'ERROR', retryable: false, next_attempt_at: null, last_error: r.outcome === 'RETRYABLE' ? 'Se agotaron los reintentos. ' + (r.error || '') : r.error, error_code: r.error_code });
      if (r.outcome === 'AUTH') Object.assign(this.db.gmail, { needs_reconnect: true, last_error: r.error }); }
    this._settleRun(d.run_id); this._save(); return 'OK';
  }
  _settleRun(runId) {
    const r = this._run(runId); if (!r || ['CANCELADA', 'PERDIDA'].includes(r.status)) return;
    const ds = this.db.deliveries.filter(d => d.run_id === runId);
    r.status = ds.some(d => d.status === 'PENDIENTE' || d.status === 'PROCESANDO' || (d.status === 'ERROR' && d.retryable)) ? 'EN_CURSO' : 'COMPLETADA';
  }
  async fetchAttachment(a) { const b = this.db.blobs[a.storage_path]; if (!b) throw Object.assign(new Error('No se encontró el adjunto ' + a.name), { code: 'ATTACHMENT_MISSING' }); return b instanceof Uint8Array ? b : new Uint8Array(b); }
  async recordDispatch(s) { this.db.dispatches.push(s); if (this.db.dispatches.length > 50) this.db.dispatches.shift(); this._save(); }
  // ---------- acciones de administración (en el servidor: RPC con permisos) ----------
  activate(id, now) { const m = this._msg(id); Object.assign(m, { status: 'ACTIVO', active_since: new Date(now).toISOString(), cursor: new Date(now).toISOString() }); this._save(); }
  pause(id) { const m = this._msg(id); m.status = 'PAUSADO'; this._save(); }
  // reanudar: NO se envía lo que venció durante la pausa (la ventana arranca ahora)
  resume(id, now) { const m = this._msg(id); Object.assign(m, { status: 'ACTIVO', active_since: new Date(now).toISOString(), cursor: new Date(now).toISOString() }); this._save(); }
  cancel(id) {
    const m = this._msg(id); m.status = 'CANCELADO';
    for (const r of this.db.runs.filter(x => x.message_id === id && x.kind !== 'PRUEBA')) {
      for (const d of this.db.deliveries.filter(x => x.run_id === r.id && (x.status === 'PENDIENTE' || (x.status === 'ERROR' && x.retryable)))) Object.assign(d, { status: 'CANCELADO', reason: 'Comunicado cancelado' });
      if (!this.db.deliveries.some(x => x.run_id === r.id && x.status === 'PROCESANDO')) { if (['PENDIENTE', 'EN_CURSO'].includes(r.status)) r.status = 'CANCELADA'; }
    }
    this._save();
  }
  requestTest(messageId, email, now) {
    const m = this._msg(messageId);
    return this.createRun({ message_id: messageId, scheduled_for: new Date(now).toISOString(), kind: 'PRUEBA', recipients: [{ collaborator_id: null, email: String(email).trim().toLowerCase(), name: 'Prueba' }],
      snapshot: { subject: '[PRUEBA] ' + m.subject, body_html: m.body_html, attachments: (m.attachments || []).filter(a => !a.detached), message_version: m.version } });
  }
  resolveVerify(deliveryId, result, now = Date.now()) {   // decisión HUMANA sobre un envío "Por verificar" o "Vencido"
    const d = this.db.deliveries.find(x => x.id === deliveryId); if (!d || !['POR_VERIFICAR', 'VENCIDO'].includes(d.status)) return false;
    // confirmado a mano: la hora de envío no se inventa (estimada con el inicio del intento); la confirmación queda aparte; sigue contando en el cupo
    if (result === 'CONFIRMADO_ENVIADO' && d.status === 'POR_VERIFICAR') Object.assign(d, { status: 'ENVIADO', reason: 'Confirmado manualmente en "Enviados" de Gmail',
      sent_at: d.sent_at || d.claimed_at, sent_at_source: d.sent_at_source || 'ESTIMADA_INICIO_INTENTO', confirmed_at: new Date(now).toISOString(), confirmed_by: 'manual' });
    else if (result === 'REINTENTAR') Object.assign(d, { status: 'PENDIENTE', retryable: true, attempts: Math.min(d.attempts, MAX_ATTEMPTS - 1), manual_ok_until: new Date(now + 3600e3).toISOString(),
      reason: d.status === 'VENCIDO' ? 'Envío del vencido autorizado manualmente' : 'Reintento autorizado manualmente (no figuraba en "Enviados")' });
    else return false;
    this._settleRun(d.run_id); this._save(); return true;
  }
}
