// V4.25 · INSPECCIONES · modo DEMO: mismas reglas que el servidor (inspection_* de la migración V4.25). Datos ficticios en este navegador.
import CONTROLS from './inspection-controls.json';
const err = (m, code, status) => Object.assign(new Error(m), { code, status });
const ALL = CONTROLS.categorias.flatMap(c => c.controles.map(x => x.n));
export const DemoInsp = {
  _insp() { const d = this.db; d.insp = d.insp || []; d.inspItems = d.inspItems || {}; d.inspEvents = d.inspEvents || []; d.inspEmails = d.inspEmails || []; d.inspSeq = d.inspSeq || 0; return d; },
  async _inspMe() { const me = await this.me(); if (!me || me.status !== 'ACTIVO') throw err('FORBIDDEN', 'FORBIDDEN', 403); return me; },
  _inspCanView(me, i) { return me.role === 'ADMIN' || i.created_by === me.id || (me.role === 'SUPERVISOR_DESPACHO' && i.team_supervisor_id === me.id); },   // sin Superior: solo autor y Administrador
  _inspEv(i, action, me, detail) { this._insp().inspEvents.push({ id: this.db.inspEvents.length + 1, inspection_id: i.id, action, actor: me.id, actor_name: me.full_name, at: new Date().toISOString(), detail: detail || {} }); },
  _inspNotify(userId, type, title, body, i) { this.db.notifs = this.db.notifs || []; this.db.notifs.push({ id: 'nt-' + (++this.db.seq), user_id: userId, route_id: null, inspection_id: i.id, type, title, body, created_at: new Date().toISOString(), read_at: null }); },
  async inspSaveDraft(p) {
    this._refresh(); const me = await this._inspMe(), d = this._insp();
    if (!['OPERARIO_DEPOSITO', 'SUPERVISOR_DESPACHO'].includes(me.role)) throw err('FORBIDDEN: solo Operario Depósito o Superior Despacho realizan inspecciones', 'FORBIDDEN', 403);
    if (!p.client_id) throw err('CLIENT_ID_REQUIRED', 'CLIENT_ID_REQUIRED', 400);
    let i = d.insp.find(x => x.client_id === p.client_id);
    if (i && i.created_by !== me.id) throw err('FORBIDDEN', 'FORBIDDEN', 403);
    if (i && i.status !== 'BORRADOR') return { ...i };   // un guardado tardío (sin conexión) no modifica una enviada
    const v = (this.db.vehicles || []).find(x => x.id === p.vehicle_id); if (!v) throw err('VEHICLE_NOT_FOUND: elegí un vehículo', 'VEHICLE_NOT_FOUND', 400);
    const snap = { vehicle_id: v.id, vehicle_name: v.name, vehicle_type: v.type || null, brand: v.brand || null, model: v.model || null, plate: v.plate, km: p.km === '' || p.km == null ? null : Number(p.km), general_observation: p.general_observation || null, updated_at: new Date().toISOString() };
    if (!i) {
      i = Object.assign({ id: 'insp-' + (++this.db.seq), number: 'INS-' + String(++d.inspSeq).padStart(6, '0'), revision: 1, parent_id: null, client_id: p.client_id, form_code: 'R SE 4.5.1-05', form_rev: 'Rev:00',
        created_by: me.id, created_by_name: me.full_name, team_supervisor_id: me.role === 'SUPERVISOR_DESPACHO' ? me.id : (me.supervisor_user_id || null), status: 'BORRADOR', anomalies: 0, created_at: new Date().toISOString(),
        submitted_at: null, reviewed_by: null, reviewed_by_name: null, reviewed_at: null, reject_reason: null }, snap);
      d.insp.push(i); this._inspEv(i, 'CREADA', me, { number: i.number, plate: i.plate });
    } else Object.assign(i, snap);
    const items = d.inspItems[i.id] = d.inspItems[i.id] || {};
    for (const it of p.items || []) { const n = Number(it.n); if (!ALL.includes(n)) throw err('ITEM_INVALID', 'ITEM_INVALID', 400);
      items[n] = { inspection_id: i.id, item_no: n, result: it.result || null, defect: it.defect || null, observation: (it.observation || '').trim() || null, extra_date: it.extra_date || null, extra_km: it.extra_km === '' || it.extra_km == null ? null : Number(it.extra_km) }; }
    this._save(); return { ...i };
  },
  async inspSubmit(id) {
    this._refresh(); const me = await this._inspMe(), d = this._insp(), i = d.insp.find(x => x.id === id);
    if (!i || i.created_by !== me.id) throw err('FORBIDDEN', 'FORBIDDEN', 403);
    if (i.status === 'PENDIENTE') return { ...i };
    if (i.status !== 'BORRADOR') throw err('BAD_STATE: la inspección ya fue revisada', 'BAD_STATE', 409);
    if (i.km == null || i.km < 0) throw err('KM_REQUIRED: cargá el kilometraje', 'KM_REQUIRED', 400);
    const items = d.inspItems[i.id] || {}, miss = ALL.filter(n => !items[n] || !items[n].result).length;
    if (miss) throw err('INCOMPLETE: faltan ' + miss + ' controles por responder', 'INCOMPLETE', 400);
    const bad = ALL.filter(n => items[n].result === 'MAL' && (!items[n].defect || !items[n].observation)).length;
    if (bad) throw err('ANOMALY_INCOMPLETE: cada control MAL necesita FALTANTE o MAL ESTADO y una observación (' + bad + ' sin completar)', 'ANOMALY_INCOMPLETE', 400);
    const team = me.role === 'SUPERVISOR_DESPACHO' ? me.id : (me.supervisor_user_id || null);
    if (!team || !(this.db.users || []).some(u => u.id === team && u.role === 'SUPERVISOR_DESPACHO' && u.status === 'ACTIVO'))
      throw err('SUPERVISOR_REQUIRED: tu usuario no tiene un Superior Despacho asignado. Pedí al Administrador General que te asigne uno; la inspección queda guardada como borrador', 'SUPERVISOR_REQUIRED', 400);
    Object.assign(i, { status: 'PENDIENTE', submitted_at: new Date().toISOString(), team_supervisor_id: team, anomalies: ALL.filter(n => items[n].result === 'MAL').length });
    this._inspEv(i, 'ENVIADA', me, { anomalies: i.anomalies, supervisor: team });
    if (me.role !== 'SUPERVISOR_DESPACHO') this._inspNotify(team, 'INSPECTION_PENDING', 'Inspección ' + i.number + ' pendiente de aprobación', i.plate + ' · ' + (i.vehicle_name || '') + ' · ' + i.created_by_name + ' · ' + i.anomalies + ' anomalía(s)', i);
    this._save(); return { ...i };
  },
  async inspReview(id, decision, reason) {
    this._refresh(); const me = await this._inspMe(), d = this._insp(), i = d.insp.find(x => x.id === id);
    if (me.role !== 'SUPERVISOR_DESPACHO') throw err('FORBIDDEN: solo el Superior Despacho aprueba o rechaza inspecciones', 'FORBIDDEN', 403);
    if (!['APROBADA', 'RECHAZADA'].includes(decision)) throw err('DECISION_INVALIDA', 'DECISION_INVALIDA', 400);
    if (!i || !(i.created_by === me.id || i.team_supervisor_id === me.id)) throw err('FORBIDDEN: la inspección es de otro equipo', 'FORBIDDEN', 403);
    if (['APROBADA', 'RECHAZADA'].includes(i.status)) { if (i.status === decision) return { ...i }; throw err('ALREADY_REVIEWED: la inspección ya fue ' + i.status.toLowerCase(), 'ALREADY_REVIEWED', 409); }
    if (i.status !== 'PENDIENTE') throw err('BAD_STATE: la inspección no está pendiente', 'BAD_STATE', 409);
    if (decision === 'RECHAZADA' && !String(reason || '').trim()) throw err('REASON_REQUIRED: indicá el motivo del rechazo', 'REASON_REQUIRED', 400);
    Object.assign(i, { status: decision, reviewed_by: me.id, reviewed_by_name: me.full_name, reviewed_at: new Date().toISOString(), reject_reason: decision === 'RECHAZADA' ? String(reason).trim() : null });
    this._inspEv(i, decision, me, { reason: i.reject_reason, self: i.created_by === me.id });
    if (i.created_by !== me.id) this._inspNotify(i.created_by, 'INSPECTION_' + decision, 'Inspección ' + i.number + ' ' + decision.toLowerCase(), i.plate + (i.reject_reason ? ' · Motivo: ' + i.reject_reason : ''), i);
    this._save(); return { ...i };
  },
  async inspNewRevision(id, clientId) {
    this._refresh(); const me = await this._inspMe(), d = this._insp();
    if (!['OPERARIO_DEPOSITO', 'SUPERVISOR_DESPACHO'].includes(me.role)) throw err('FORBIDDEN', 'FORBIDDEN', 403);
    if (!id || !clientId) throw err('FORBIDDEN', 'FORBIDDEN', 403);
    const o = d.insp.find(x => x.id === id); if (!o || !this._inspCanView(me, o)) throw err('FORBIDDEN', 'FORBIDDEN', 403);   // PRIMERO la original
    const ex = d.insp.find(x => x.client_id === clientId);   // reintento: solo la revisión de ESTE usuario desde ESTA original
    if (ex) { if (ex.created_by === me.id && ex.parent_id === o.id) return { ...ex }; throw err('CLIENT_ID_CONFLICT: el identificador de la revisión ya está en uso; generá uno nuevo', 'CLIENT_ID_CONFLICT', 409); }
    if (!['APROBADA', 'RECHAZADA'].includes(o.status)) throw err('BAD_STATE: solo se revisa una inspección aprobada o rechazada', 'BAD_STATE', 409);
    const n = { ...o, id: 'insp-' + (++this.db.seq), revision: Math.max(...d.insp.filter(x => x.number === o.number).map(x => x.revision)) + 1, parent_id: o.id, client_id: clientId, created_by: me.id, created_by_name: me.full_name,
      team_supervisor_id: me.role === 'SUPERVISOR_DESPACHO' ? me.id : (me.supervisor_user_id || null), status: 'BORRADOR', submitted_at: null, reviewed_by: null, reviewed_by_name: null, reviewed_at: null, reject_reason: null, created_at: new Date().toISOString() };
    d.insp.push(n); d.inspItems[n.id] = JSON.parse(JSON.stringify(d.inspItems[o.id] || {})); Object.values(d.inspItems[n.id]).forEach(x => { x.inspection_id = n.id; });
    this._inspEv(n, 'REVISION_CREADA', me, { from: o.id, revision: n.revision }); this._inspEv(o, 'REVISION_CREADA', me, { to: n.id, revision: n.revision });
    this._save(); return { ...n };
  },
  async inspEmailRequest(id, to, subject, body) {
    this._refresh(); const me = await this._inspMe(), d = this._insp(), i = d.insp.find(x => x.id === id);
    if (me.role !== 'SUPERVISOR_DESPACHO') throw err('FORBIDDEN', 'FORBIDDEN', 403);
    if (!i || !this._inspCanView(me, i)) throw err('FORBIDDEN', 'FORBIDDEN', 403);
    if (i.status !== 'APROBADA') throw err('BAD_STATE: el email se prepara solo para inspecciones aprobadas', 'BAD_STATE', 409);
    if (!to || !to.length) throw err('RECIPIENTS_REQUIRED', 'RECIPIENTS_REQUIRED', 400);
    const bad = to.find(r => !/^[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}$/i.test(r)); if (bad) throw err('EMAIL_INVALID: ' + bad, 'EMAIL_INVALID', 400);
    d.inspEmails.push({ id: d.inspEmails.length + 1, inspection_id: i.id, requested_by: me.id, requested_at: new Date().toISOString(), recipients: to, subject, body, status: 'PENDIENTE_ENVIO' });
    this._inspEv(i, 'EMAIL_SOLICITADO', me, { recipients: to });
    const req = d.inspEmails[d.inspEmails.length - 1]; Object.assign(req, { status: 'ENVIADO', sent_at: new Date().toISOString() });   // demo: envío SIMULADO (no sale ningún correo)
    this._save(); return { id: req.id, status: 'ENVIADO', simulated: true };
  },
  async inspVehicles() { this._refresh(); await this._inspMe(); return (this.db.vehicles || []).filter(v => v.active !== false).map(v => ({ id: v.id, name: v.name, plate: v.plate, type: v.type, brand: v.brand, model: v.model, current_km: v.current_km })); },
  async inspList(f = {}) {
    this._refresh(); const me = await this._inspMe(), d = this._insp(), low = s => String(s || '').toLowerCase();
    return d.insp.filter(i => this._inspCanView(me, i)).filter(i => (!f.from || i.created_at.slice(0, 10) >= f.from) && (!f.to || i.created_at.slice(0, 10) <= f.to) && (!f.status || i.status === f.status)
      && (!f.vehicle_id || i.vehicle_id === f.vehicle_id) && (!f.plate || low(i.plate).includes(low(f.plate))) && (!f.responsable || low(i.created_by_name).includes(low(f.responsable))))
      .sort((a, b) => b.created_at.localeCompare(a.created_at)).map(i => ({ ...i }));
  },
  async inspDetail(id) {
    this._refresh(); const me = await this._inspMe(), d = this._insp(), i = d.insp.find(x => x.id === id);
    if (!i || !this._inspCanView(me, i)) throw err('No existe o no tenés acceso.', 'NOT_FOUND', 404);
    return { inspection: { ...i }, items: Object.values(d.inspItems[i.id] || {}).sort((a, b) => a.item_no - b.item_no), events: d.inspEvents.filter(e => e.inspection_id === i.id) };
  },
  async inspEvents(ids) { this._refresh(); const me = await this._inspMe(), d = this._insp(); const ok = new Set(d.insp.filter(i => ids.includes(i.id) && this._inspCanView(me, i)).map(i => i.id)); return d.inspEvents.filter(e => ok.has(e.inspection_id)); },
  async inspItems(ids) { this._refresh(); const me = await this._inspMe(), d = this._insp(); return d.insp.filter(i => ids.includes(i.id) && this._inspCanView(me, i)).flatMap(i => Object.values(d.inspItems[i.id] || {})); },
};
