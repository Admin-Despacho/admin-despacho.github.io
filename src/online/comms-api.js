// =====================================================================================================================
// COMUNICACIONES · adaptadores (se suman a DemoApi y SupabaseApi; no modifican sus otros métodos).
//  · Online: lecturas con RLS; escrituras SOLO por funciones SQL que validan el permiso; adjuntos privados; OAuth por la función del servidor.
//  · Demo: mismo almacenamiento en memoria y mismo despachador que las pruebas, con Gmail y conexión SIMULADOS (rotulados en pantalla).
// =====================================================================================================================
import { hasPerm } from '../../supabase/functions/_shared/rules.js';
import { MemoryCommsStore } from '../../supabase/functions/_shared/comms-memory-store.js';
import { dispatch } from '../../supabase/functions/comm-dispatcher/handler.js';
import { sniffType, validateAttachment, ATTACH, zonedToUtc, localParts } from '../../supabase/functions/_shared/comms-core.js';

const err = (message, code) => Object.assign(new Error(message), { code });
const need = (me, p) => { if (!hasPerm(me, p)) throw err('No tenés permiso para esta acción (' + p + ').', 'FORBIDDEN'); };
const EXT = { 'image/png': 'png', 'image/jpeg': 'jpg', 'image/webp': 'webp', 'image/gif': 'gif', 'application/pdf': 'pdf' };
const uuid = () => (crypto.randomUUID ? crypto.randomUUID() : 'xxxxxxxx-xxxx-4xxx-8xxx-xxxxxxxxxxxx'.replace(/x/g, () => (Math.random() * 16 | 0).toString(16)));
const sha256Hex = async buf => [...new Uint8Array(await crypto.subtle.digest('SHA-256', buf))].map(b => b.toString(16).padStart(2, '0')).join('');
// validación del archivo en el navegador (el servidor vuelve a validar tipo, tamaño, ruta y totales)
export async function inspectFile(file, existing) {
  const buf = await file.arrayBuffer(), bytes = new Uint8Array(buf), sniffed = sniffType(bytes);
  const f = { name: file.name, mime: sniffed || file.type || 'application/octet-stream', size: file.size, sniffed };
  const errors = validateAttachment(f, existing);
  return { errors, bytes, mime: f.mime, sha256: errors.length ? null : await sha256Hex(buf) };
}
const SIG = m => JSON.stringify({ s: m.subject, b: m.body_html, sel: m.selection, sch: m.schedule });

// ================================ ONLINE (Supabase) ================================
export const SupabaseComms = {
  async _cx(q, what) { const { data, error } = await q; if (error) throw err(String(error.message || what).replace(/^FORBIDDEN: falta el permiso /, 'No tenés permiso para esta acción: '), (String(error.message).match(/^[A-Z_]+/) || [error.code])[0]); return data; },
  async commsCollaborators() { return this._cx(this.sb.from('comm_collaborators').select('*').order('full_name'), 'colaboradores'); },
  async commsSaveCollaborator(p) { return this._cx(this.sb.rpc('comm_save_collaborator', { p }), 'guardar colaborador'); },
  async commsMessages() {
    const ms = await this._cx(this.sb.from('comm_messages').select('*').order('updated_at', { ascending: false }), 'comunicados');
    const at = ms.length ? await this._cx(this.sb.from('comm_attachments').select('*').in('message_id', ms.map(m => m.id)).eq('detached', false), 'adjuntos') : [];
    return ms.map(m => ({ ...m, attachments: at.filter(a => a.message_id === m.id) }));
  },
  async commsSaveMessage(p, confirm) { return this._cx(this.sb.rpc('comm_save_message', { p, p_confirm: !!confirm }), 'guardar'); },
  async commsDuplicate(id) { return this._cx(this.sb.rpc('comm_duplicate_message', { p_id: id }), 'duplicar'); },
  // el navegador valida para avisar rápido, pero el REGISTRO lo hace la función comm-attachments del servidor (contenido, tamaño y hash reales)
  async commsAddAttachment(messageId, file, existing, confirm) {
    const r = await inspectFile(file, existing); if (r.errors.length) throw err(r.errors.join(' '), 'ADJUNTO_INVALIDO');
    const path = 'messages/' + messageId + '/' + uuid() + '.' + EXT[r.mime];
    const up = await this.sb.storage.from('comm-attachments').upload(path, new Blob([r.bytes], { type: r.mime }), { contentType: r.mime, upsert: false });
    if (up.error) throw err('No se pudo subir el archivo: ' + up.error.message, 'UPLOAD');
    const { data } = await this.sb.auth.getSession(); const t = data && data.session && data.session.access_token;
    // registro IDEMPOTENTE: si el resultado es incierto (corte, respuesta perdida), se repite la MISMA solicitud sin duplicar
    let res, j = {};
    for (let i = 0; i < 3; i++) {
      try { res = await fetch(this.sb.supabaseUrl + '/functions/v1/comm-attachments', { method: 'POST', headers: { Authorization: 'Bearer ' + t, apikey: this.sb.supabaseKey, 'Content-Type': 'application/json' },
        body: JSON.stringify({ message_id: messageId, path, file_name: file.name, confirm: !!confirm }) }); j = await res.json().catch(() => ({})); }
      catch (e) { res = { ok: false, status: 0 }; j = { error: 'RESULTADO_INCIERTO' }; }
      if (res.ok || j.error !== 'RESULTADO_INCIERTO') break;
      await new Promise(r => setTimeout(r, 800 * (i + 1)));
    }
    if (j.error === 'RESULTADO_INCIERTO') throw err('No se pudo confirmar el registro del adjunto. El archivo se conservó: volvé a intentar en un momento (no se duplica).', 'RESULTADO_INCIERTO');
    if (!res.ok) throw err(j.error === 'CONTENIDO_NO_PERMITIDO' ? (j.detalle || 'El archivo no es una imagen o PDF válido.') : j.error === 'CONFIRMATION_REQUIRED' ? 'Agregar un adjunto afecta los próximos envíos: confirmalo.'
      : j.error === 'FORBIDDEN' ? 'No tenés permiso para esta acción.' : 'No se pudo registrar el adjunto (' + (j.error || res.status) + ').', j.error || 'ADJUNTO');
    return j.attachment;
  },
  async commsDetachAttachment(id, confirm) { return this._cx(this.sb.rpc('comm_detach_attachment', { p_id: id, p_confirm: !!confirm }), 'quitar adjunto'); },
  async commsAttachmentBlob(a) { const { data, error } = await this.sb.storage.from('comm-attachments').download(String(a.storage_path).split('#')[0]); if (error) throw err('No se pudo descargar ' + a.file_name, 'DOWNLOAD'); return data; },
  async commsActivate(id) { return this._cx(this.sb.rpc('comm_activate', { p_id: id }), 'programar'); },
  async commsPause(id) { return this._cx(this.sb.rpc('comm_pause', { p_id: id }), 'pausar'); },
  async commsResume(id) { return this._cx(this.sb.rpc('comm_resume', { p_id: id }), 'reanudar'); },
  async commsCancel(id) { return this._cx(this.sb.rpc('comm_cancel', { p_id: id }), 'cancelar'); },
  async commsRequestTest(id, email) { return this._cx(this.sb.rpc('comm_request_test', { p_id: id, p_email: email }), 'prueba'); },
  async commsRuns(messageId) {
    const runs = await this._cx(this.sb.from('comm_runs').select('*').eq('message_id', messageId).order('scheduled_for', { ascending: false }).limit(60), 'historial');
    const ds = runs.length ? await this._cx(this.sb.from('comm_deliveries').select('*').in('run_id', runs.map(r => r.id)).order('id'), 'envíos') : [];
    return runs.map(r => ({ ...r, deliveries: ds.filter(d => d.run_id === r.id) }));
  },
  async commsResolveVerify(id, result) { return this._cx(this.sb.rpc('comm_resolve_verify', { p_delivery: id, p_result: result }), 'verificar'); },
  async commsRegisterWhatsApp(id, note) { return this._cx(this.sb.rpc('comm_register_whatsapp', { p_id: id, p_note: note || null }), 'registrar WhatsApp'); },
  async commsWhatsAppShares(id) { return this._cx(this.sb.from('comm_whatsapp_shares').select('*').eq('message_id', id).order('shared_at', { ascending: false }), 'WhatsApp'); },
  async commsAudit(id) { return this._cx(this.sb.from('comm_audit').select('*').eq('message_id', id).order('at', { ascending: false }).limit(100), 'auditoría'); },
  async commsGmailStatus() { const s = await this._cx(this.sb.rpc('comm_gmail_status'), 'estado de Gmail'); return { ...s, mode: 'online' }; },
  async _commsFn(action) {
    const { data } = await this.sb.auth.getSession(); const t = data && data.session && data.session.access_token;
    if (!t) throw err('La sesión venció: volvé a ingresar.', 'SESSION');
    const r = await fetch(this.sb.supabaseUrl + '/functions/v1/comm-gmail-oauth?action=' + action, { method: 'POST', headers: { Authorization: 'Bearer ' + t, apikey: this.sb.supabaseKey } });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) throw err(j.error === 'FORBIDDEN' ? 'No tenés permiso para administrar la conexión Gmail.' : 'No se pudo completar la acción (' + (j.error || r.status) + '). Revisá que la conexión esté configurada en el servidor.', j.error || 'FN');
    return j;
  },
  async commsGmailConnect() { const j = await this._commsFn('start'); location.assign(j.url); return { redirect: true }; },   // la cuenta se elige y autoriza en Google
  async commsGmailDisconnect() { return this._commsFn('disconnect'); },
};

// ================================ DEMO (simulado) ================================
const KEY = 'okd_comms_demo_v1', INFO = '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';
const b64ToBytes = s => Uint8Array.from(atob(s), c => c.charCodeAt(0));
const bytesToB64 = b => { let s = ''; for (let i = 0; i < b.length; i += 0x8000) s += String.fromCharCode.apply(null, b.subarray(i, i + 0x8000)); return btoa(s); };
function nextMondayFrom(now) { const p = localParts(now); const [y, m, d] = p.date.split('-').map(Number); const dt = new Date(Date.UTC(y, m - 1, d)); const w = dt.getUTCDay() || 7; dt.setUTCDate(dt.getUTCDate() + (8 - w)); return dt.toISOString().slice(0, 10); }
function seed(now) {
  const c = (id, n, e, ph, b, s, a = true) => ({ id, full_name: n, email: e, phone: ph, branch: b, sector: s, active: a });
  return {
    collaborators: [c('col-1', 'Laura Gómez (ficticia)', 'laura.gomez@ejemplo.test', '+54 9 261 555-0101', 'Mendoza', 'Cobranzas'),
      c('col-2', 'Martín Ruiz (ficticio)', 'martin.ruiz@ejemplo.test', '+54 9 261 555-0102', 'Mendoza', 'Ventas'),
      c('col-3', 'Sofía Pérez (ficticia)', 'sofia.perez@ejemplo.test', '+54 9 264 555-0103', 'San Juan', 'Cobranzas'),
      c('col-4', 'Diego López (ficticio)', 'diego.lopez@ejemplo.test', '+54 9 261 555-0104', 'Mendoza', 'Depósito'),
      c('col-5', 'Valeria Sosa (ficticia)', 'valeria.sosa@ejemplo.test', '+54 9 264 555-0105', 'San Juan', 'Ventas'),
      c('col-6', 'Pablo Díaz (ficticio, inactivo)', 'pablo.diaz@ejemplo.test', '', 'Mendoza', 'Cobranzas', false)],
    messages: [{ id: 'msg-ejemplo', internal_name: 'EJEMPLO · Normas de cobro (semanal)', subject: 'Recordatorio: normas de cobro',
      body_html: '<p>Hola equipo,</p><p>Les recordamos las <b>normas de cobro</b> vigentes:</p><ul><li>Cobrar <b>siempre</b> con recibo.</li><li>En efectivo, contar frente al cliente.</li><li>Transferencias: verificar el comprobante antes de entregar.</li><li>Rendir lo cobrado <i>el mismo día</i>.</li></ul><p>Adjuntamos la infografía. ¡Gracias!</p>',
      from_name: 'OK Accesorios', selection: { sectors: ['Cobranzas', 'Ventas'] }, schedule: { kind: 'WEEKLY', time: '09:00', start_date: nextMondayFrom(now), weekdays: [1] },
      status: 'BORRADOR', version: 1, created_at: new Date(now).toISOString(), updated_at: new Date(now).toISOString(), created_by: 'u-admin',
      attachments: [{ id: 'att-ejemplo', name: 'infografia-normas-de-cobro.png', file_name: 'infografia-normas-de-cobro.png', mime: 'image/png', size_bytes: b64ToBytes(INFO).length, sha256: null, storage_path: 'demo/infografia.png' }] }],
    blobs: { 'demo/infografia.png': INFO }, runs: [], deliveries: [], gmail: { connected: false, needs_reconnect: false, email: null, simulated: true }, dispatches: [], shares: [], audit: []
  };
}
// Gmail SIMULADO para la demo (nunca envía nada real). window.OKD_COMMS_FAKE = ['OK'|'LOST'|{status,reason}, …] fuerza respuestas en pruebas.
class DemoGmail { async send(raw) { const q = (typeof window !== 'undefined' && window.OKD_COMMS_FAKE) || []; const s = q.length ? q.shift() : 'OK';
  if (s === 'OK') return { id: 'simulado-' + Math.random().toString(36).slice(2, 10) }; if (s === 'LOST') throw Object.assign(new Error('respuesta perdida (simulado)'), { phase: 'AFTER_SEND' }); throw Object.assign(new Error(s.reason || 'error simulado'), s); } }

const demoNow = () => (typeof window !== 'undefined' && window.OKD_COMMS_NOW) || Date.now();
export const DemoComms = {
  _commsStore() {
    let raw = null; try { raw = JSON.parse(localStorage.getItem(KEY) || 'null'); } catch (e) { raw = null; }
    if (!raw) raw = seed(Date.now());
    const db = { ...raw, blobs: Object.fromEntries(Object.entries(raw.blobs || {}).map(([k, v]) => [k, b64ToBytes(v)])) };
    const save = d => { try { localStorage.setItem(KEY, JSON.stringify({ ...d, blobs: Object.fromEntries(Object.entries(d.blobs || {}).map(([k, v]) => [k, bytesToB64(v)])) })); } catch (e) { throw err('No hay espacio en este navegador para la demo (adjuntos grandes).', 'QUOTA'); } };
    const st = new MemoryCommsStore(db, { onChange: save }); save(st.db); return st;
  },
  async _me() { const me = await this.me(); if (!me) throw err('Sesión vencida', 'SESSION'); return me; },
  _commsAudit(st, msg, entity, action, actor, detail = {}) { st.db.audit.push({ id: st.db.audit.length + 1, message_id: msg, entity, action, actor, actor_name: actor, at: new Date().toISOString(), detail }); },
  async commsCollaborators() { need(await this._me(), 'comms.view'); return this._commsStore().db.collaborators.slice().sort((a, b) => a.full_name.localeCompare(b.full_name, 'es')); },
  async commsSaveCollaborator(p) {
    const me = await this._me(); need(me, 'comms.collaborators_manage'); const st = this._commsStore(), email = String(p.email || '').trim().toLowerCase();
    if (!String(p.full_name || '').trim()) throw err('Indicá nombre y apellido.', 'NOMBRE_REQUERIDO');
    if (!/^[^\s@<>()",;]+@[^\s@<>()",;]+\.[a-z]{2,}$/i.test(email)) throw err('El correo no es válido.', 'CORREO_INVALIDO');
    if (st.db.collaborators.some(c => c.email.toLowerCase() === email && c.id !== p.id)) throw err('Ya hay un colaborador con ' + email + '.', 'CORREO_DUPLICADO');
    let c = p.id && st.db.collaborators.find(x => x.id === p.id);
    if (!c) { c = { id: 'col-' + uuid().slice(0, 8), created_at: new Date().toISOString() }; st.db.collaborators.push(c); }
    Object.assign(c, { full_name: String(p.full_name).trim(), email, phone: String(p.phone || '').trim(), branch: String(p.branch || '').trim(), sector: String(p.sector || '').trim(), active: p.active !== false });
    this._commsAudit(st, null, 'COLABORADOR', p.id ? 'MODIFICADO' : 'CREADO', me.full_name, { colaborador: c.full_name, activo: c.active }); st._save(); return c;
  },
  async commsMessages() { need(await this._me(), 'comms.view'); return this._commsStore().db.messages.map(m => ({ ...m, attachments: (m.attachments || []).filter(a => !a.detached).map(a => ({ ...a, file_name: a.file_name || a.name })) })); },
  async commsSaveMessage(p, confirm) {
    const me = await this._me(); need(me, 'comms.compose'); const st = this._commsStore();
    const body = String(p.body_html ?? ''); if (/<\s*(script|iframe|object|embed|style|svg)|javascript:|\son[a-z]+\s*=/i.test(body)) throw err('El contenido tiene código no permitido.', 'CONTENIDO');
    let m = p.id && st.db.messages.find(x => x.id === p.id);
    if (!m) { m = { id: 'msg-' + uuid().slice(0, 8), status: 'BORRADOR', version: 1, attachments: [], created_at: new Date().toISOString(), created_by: me.full_name }; st.db.messages.unshift(m); this._commsAudit(st, m.id, 'COMUNICADO', 'CREADO', me.full_name); }
    else {
      if (['CANCELADO', 'FINALIZADO'].includes(m.status)) throw err('El comunicado está ' + m.status.toLowerCase() + ': duplicalo para reutilizarlo.', 'NO_EDITABLE');
      const before = SIG(m), after = SIG({ ...m, ...p });
      if (['ACTIVO', 'PAUSADO'].includes(m.status) && before !== after && !confirm) throw err('El cambio afecta los próximos envíos: confirmalo.', 'CONFIRMATION_REQUIRED');
      if (['ACTIVO', 'PAUSADO'].includes(m.status) && JSON.stringify(m.schedule) !== JSON.stringify(p.schedule ?? m.schedule)) { need(me, 'comms.schedule'); if (m.status === 'ACTIVO') { m.active_since = new Date().toISOString(); m.cursor = new Date().toISOString(); } }
      if (before !== after) m.version++;
      this._commsAudit(st, m.id, 'COMUNICADO', 'MODIFICADO', me.full_name, { version: m.version, confirmado: !!confirm });
    }
    for (const k of ['internal_name', 'subject', 'body_html', 'selection', 'schedule', 'from_name']) if (p[k] !== undefined) m[k] = p[k];
    m.updated_at = new Date().toISOString(); m.updated_by = me.full_name; st._save(); return { ...m };
  },
  async commsDuplicate(id) {
    const me = await this._me(); need(me, 'comms.compose'); const st = this._commsStore(), s = st.db.messages.find(x => x.id === id);
    const m = { ...JSON.parse(JSON.stringify(s)), id: 'msg-' + uuid().slice(0, 8), internal_name: s.internal_name + ' (copia)', status: 'BORRADOR', version: 1, active_since: null, cursor: null, created_at: new Date().toISOString(), created_by: me.full_name,
      attachments: (s.attachments || []).filter(a => !a.detached).map(a => ({ ...a, id: 'att-' + uuid().slice(0, 8) })) };
    st.db.messages.unshift(m); this._commsAudit(st, m.id, 'COMUNICADO', 'DUPLICADO', me.full_name, { origen: s.internal_name }); st._save(); return m;
  },
  async commsAddAttachment(messageId, file, existing, confirm) {
    const me = await this._me(); need(me, 'comms.compose'); const r = await inspectFile(file, existing); if (r.errors.length) throw err(r.errors.join(' '), 'ADJUNTO_INVALIDO');
    const st = this._commsStore(), m = st.db.messages.find(x => x.id === messageId), path = 'demo/' + uuid() + '.' + EXT[r.mime];
    if (['ACTIVO', 'PAUSADO'].includes(m.status) && !confirm) throw err('Agregar un adjunto afecta los próximos envíos: confirmalo.', 'CONFIRMATION_REQUIRED');
    m.version = (m.version || 1) + 1;
    st.db.blobs[path] = r.bytes; const a = { id: 'att-' + uuid().slice(0, 8), name: file.name, file_name: file.name, mime: r.mime, size_bytes: file.size, sha256: r.sha256, storage_path: path };
    m.attachments = (m.attachments || []).concat([a]); this._commsAudit(st, messageId, 'ADJUNTO', 'AGREGADO', me.full_name, { archivo: file.name, confirmado: !!confirm, version: m.version }); st._save(); return a;
  },
  async commsDetachAttachment(id, confirm) { const me = await this._me(); need(me, 'comms.compose'); const st = this._commsStore();
    const m = st.db.messages.find(x => (x.attachments || []).some(a => a.id === id)); if (!m) throw err('No se encontró el adjunto.', 'NO_ENCONTRADO');
    if (['ACTIVO', 'PAUSADO'].includes(m.status) && !confirm) throw err('Quitar un adjunto afecta los próximos envíos: confirmalo.', 'CONFIRMATION_REQUIRED');
    const a = m.attachments.find(x => x.id === id); a.detached = true; m.version = (m.version || 1) + 1;   // las copias de ejecuciones ya hechas no cambian
    this._commsAudit(st, m.id, 'ADJUNTO', 'QUITADO', me.full_name, { archivo: a.name, confirmado: !!confirm, version: m.version }); st._save(); },
  async commsAttachmentBlob(a) { need(await this._me(), 'comms.view'); const b = this._commsStore().db.blobs[a.storage_path]; if (!b) throw err('No se encontró ' + (a.file_name || a.name), 'DOWNLOAD'); return new Blob([b], { type: a.mime }); },
  async commsActivate(id) {
    const me = await this._me(); need(me, 'comms.schedule'); const st = this._commsStore(), m = st.db.messages.find(x => x.id === id);
    if (!st.db.gmail.connected || st.db.gmail.needs_reconnect) throw err('Conectá Gmail antes de programar.', 'GMAIL_NOT_CONNECTED');
    if (m.status !== 'BORRADOR') throw err('Solo se programa un borrador.', 'ESTADO_INVALIDO');
    st.activate(id, demoNow()); this._commsAudit(st, id, 'COMUNICADO', 'PROGRAMADO', me.full_name, { schedule: m.schedule }); st._save();
  },
  async commsPause(id) { const me = await this._me(); need(me, 'comms.schedule'); const st = this._commsStore(); st.pause(id); this._commsAudit(st, id, 'COMUNICADO', 'PAUSADO', me.full_name); st._save(); },
  async commsResume(id) { const me = await this._me(); need(me, 'comms.schedule'); const st = this._commsStore(); st.resume(id, demoNow()); this._commsAudit(st, id, 'COMUNICADO', 'REANUDADO', me.full_name); st._save(); },
  async commsCancel(id) { const me = await this._me(); need(me, 'comms.schedule'); const st = this._commsStore(); st.cancel(id); this._commsAudit(st, id, 'COMUNICADO', 'CANCELADO', me.full_name); st._save(); },
  async commsRequestTest(id, email) {
    const me = await this._me(); need(me, 'comms.test_send'); if (!/^[^\s@]+@[^\s@]+\.[a-z]{2,}$/i.test(String(email).trim())) throw err('Indicá un correo válido para la prueba.', 'CORREO_INVALIDO');
    const st = this._commsStore(); st.requestTest(id, email, demoNow()); this._commsAudit(st, id, 'COMUNICADO', 'PRUEBA_SOLICITADA', me.full_name, { destino: email }); st._save();
  },
  async commsRuns(id) { need(await this._me(), 'comms.view'); const st = this._commsStore();
    return st.db.runs.filter(r => r.message_id === id).sort((a, b) => b.scheduled_for.localeCompare(a.scheduled_for)).map(r => ({ ...r, deliveries: st.db.deliveries.filter(d => d.run_id === r.id) })); },
  async commsResolveVerify(id, result) { const me = await this._me(); need(me, 'comms.schedule'); const st = this._commsStore(); st.resolveVerify(id, result, demoNow()); this._commsAudit(st, null, 'ENVIO', 'VERIFICACION_' + result, me.full_name); st._save(); },
  async commsRegisterWhatsApp(id, note) { const me = await this._me(); need(me, 'comms.compose'); const st = this._commsStore();
    st.db.shares.push({ id: st.db.shares.length + 1, message_id: id, shared_by: me.full_name, shared_at: new Date().toISOString(), note: note || null });
    this._commsAudit(st, id, 'WHATSAPP', 'REGISTRADO_COMPARTIDO', me.full_name, { nota: note || '' }); st._save(); },
  async commsWhatsAppShares(id) { need(await this._me(), 'comms.view'); return this._commsStore().db.shares.filter(s => s.message_id === id).slice().reverse(); },
  async commsAudit(id) { need(await this._me(), 'comms.view'); return this._commsStore().db.audit.filter(a => a.message_id === id).slice().reverse(); },
  async commsGmailStatus() { need(await this._me(), 'comms.view'); const st = this._commsStore(), d = st.db.dispatches[st.db.dispatches.length - 1];
    return { ...st.db.gmail, mode: 'demo', last_dispatch: d ? { at: d.at, status: d.status, sent: d.sent, note: d.note } : null }; },
  async commsGmailConnect() { const me = await this._me(); need(me, 'comms.gmail_manage'); const st = this._commsStore();
    Object.assign(st.db.gmail, { connected: true, needs_reconnect: false, email: 'comunicados.demo@gmail.com', simulated: true, connected_at: new Date().toISOString() });
    this._commsAudit(st, null, 'GMAIL', 'CONECTADO (SIMULADO)', me.full_name); st._save(); return { simulated: true }; },
  async commsGmailDisconnect() { const me = await this._me(); need(me, 'comms.gmail_manage'); const st = this._commsStore();
    Object.assign(st.db.gmail, { connected: false, needs_reconnect: false, email: null }); this._commsAudit(st, null, 'GMAIL', 'DESCONECTADO', me.full_name); st._save(); return { ok: true, revoked_in_google: true }; },   // demo: revocación SIMULADA
  // SOLO demo: ejecuta el mismo despachador que el servidor con Gmail SIMULADO (lo que en producción hace el programador cada 5 minutos)
  async commsDemoTick(now) { const st = this._commsStore(); return dispatch(st, new DemoGmail(), { now: now || demoNow(), pauseMs: 0, worker: 'demo' }); },
};
