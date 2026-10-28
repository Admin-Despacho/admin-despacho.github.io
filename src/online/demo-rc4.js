// Modo demo · RC4: mismas reglas que la migración 20261026000100 (permisos individuales, jerarquía, solicitudes,
// kilometraje, notificaciones y dashboards por rol). El servidor real valida todo esto en PostgreSQL (RLS + RPC).
import { hasPerm, PERMISSIONS, SENSITIVE_PERMISSIONS, ROLE_LABEL } from '../../supabase/functions/_shared/rules.js';

const err = (message, code, status) => Object.assign(new Error(message), { code, status });
const REQUEST_TYPES = ['CAMBIO_TRANSPORTISTA', 'REASIGNACION', 'CAMBIO_RESPONSABLE', 'MODIFICAR_BULTOS', 'CAMBIO_VEHICULO', 'CORRECCION_KM', 'CANCELACION', 'CAMBIO_POST_PUBLICACION', 'OTRO'];
const MDZ = iso => iso ? new Date(new Date(iso).toLocaleString('en-US', { timeZone: 'America/Argentina/Mendoza' })).toDateString() : null;
const TODAY = () => MDZ(new Date().toISOString());
const isAdmin = u => !!u && u.role === 'ADMIN' && u.status === 'ACTIVO';

export const DemoRC4 = {
  // ===== Equipo y alcance =====
  _teamOf(uid) {
    const out = new Set(); let frontier = [uid];
    for (let d = 0; d < 20 && frontier.length; d++) {
      const next = this.db.users.filter(u => frontier.includes(u.supervisor_user_id) && !out.has(u.id)).map(u => u.id);
      next.forEach(id => out.add(id)); frontier = next;
    }
    return out;
  },
  _canManageDraftOf(me, owner) { return owner === me.id || hasPerm(me, 'routes.manage_all_drafts') || (hasPerm(me, 'drafts.manage_team') && this._teamOf(me.id).has(owner)); },
  _canViewDraftOf(me, owner) { return this._canManageDraftOf(me, owner) || (hasPerm(me, 'drafts.view_team') && this._teamOf(me.id).has(owner)); },
  // RC4.1: alcance real de hojas (mismo criterio que public.can_view_route_row)
  _routeBelongsTo(r, uid) { return r.published_by === uid || Object.values(this.db.drafts || {}).some(d => d.route_id === r.id && d.owner_id === uid); },
  _canViewRoute(me, r) {
    if (!me || !r) return false;
    if (hasPerm(me, 'routes.view_all')) return true;
    if (r.responsable_id === me.id && hasPerm(me, 'routes.view_assigned')) return true;
    if (r.responsable_id === me.id && hasPerm(me, 'routes.receive_internal') && ((this._carriers ? this._carriers() : []).find(c => c.id === r.carrier_id) || {}).kind === 'INTERNO') return true;   // permiso de asignación: solo su hoja interna
    if ((hasPerm(me, 'routes.view_own') || hasPerm(me, 'routes.view_team')) && this._routeBelongsTo(r, me.id)) return true;
    return hasPerm(me, 'routes.view_team') && [...this._teamOf(me.id)].some(u => this._routeBelongsTo(r, u));
  },
  _routeScope(me, r) { if (!this._canViewRoute(me, r)) throw err('FORBIDDEN_ROUTE: la hoja está fuera de tu alcance', 'FORBIDDEN_ROUTE', 403); },
  _notifyUser(userId, type, title, body, routeId) {
    this.db.notifs = this.db.notifs || [];
    this.db.notifs.push({ id: 'nt-' + (++this.db.seq), user_id: userId, route_id: routeId || null, type, title, body: body || '', created_at: new Date().toISOString(), read_at: null });
  },

  // ===== Permisos individuales (Admin) =====
  async userEffectivePermissions(userId) {
    this._refresh(); const me = await this.me();
    if (userId !== me.id && !hasPerm(me, 'users.view')) throw err('ACCESO NO AUTORIZADO', 'FORBIDDEN', 403);
    const u = this._user(userId); return u ? PERMISSIONS.filter(p => hasPerm(u, p)) : [];
  },
  async setUserPermission(userId, perm, state, reason) {
    this._refresh(); const me = await this.me();
    if (!hasPerm(me, 'users.manage_permissions')) throw err('FORBIDDEN', 'FORBIDDEN', 403);
    if (userId === me.id) throw err('SELF_PERMISSION: nadie modifica sus propios permisos', 'SELF_PERMISSION', 403);
    if (!PERMISSIONS.includes(perm)) throw err('BAD_PERMISSION', 'BAD_PERMISSION', 400);
    if (!['GRANT', 'REVOKE', 'ROLE'].includes(state)) throw err('BAD_STATE', 'BAD_STATE', 400);
    if (state === 'GRANT' && SENSITIVE_PERMISSIONS.includes(perm) && !isAdmin(me)) throw err('SENSITIVE_PERMISSION: solo Admin General otorga este permiso', 'SENSITIVE_PERMISSION', 403);
    const u = this._user(userId); if (!u) throw err('No existe.', 'NOT_FOUND', 404);
    const ov = u.permission_overrides = u.permission_overrides || {}, prev = perm in ov ? (ov[perm] ? 'GRANT' : 'REVOKE') : 'ROLE';
    if (state === 'ROLE') delete ov[perm]; else ov[perm] = state === 'GRANT';
    this._audit(me, 'USER_PERMISSION_SET', userId, { permission: perm, state: prev }, { permission: perm, state, reason: reason || null });
    this._save(); return { user: userId, permission: perm, state, effective: hasPerm(u, perm) };
  },

  // ===== Jerarquía =====
  _checkSupervisor(user, supId) {
    if (!supId) return;
    if (supId === user.id) throw err('BAD_SUPERVISOR: un usuario no puede ser su propio superior', 'BAD_SUPERVISOR', 409);
    const sup = this._user(supId);
    if (!sup || sup.status !== 'ACTIVO') throw err('BAD_SUPERVISOR: el superior debe existir y estar activo', 'BAD_SUPERVISOR', 409);
    let cur = sup.supervisor_user_id, hops = 0;
    while (cur && hops++ < 50) { if (cur === user.id) throw err('BAD_SUPERVISOR: la asignación generaría un ciclo de supervisión', 'BAD_SUPERVISOR', 409); cur = (this._user(cur) || {}).supervisor_user_id; }
    if (user.role === 'OPERARIO_DEPOSITO' && !['SUPERVISOR_DESPACHO', 'ADMIN', 'DESPACHO'].includes(sup.role)) throw err('BAD_SUPERVISOR: el superior de un Operario Depósito debe ser Superior Despacho o Admin General', 'BAD_SUPERVISOR', 409);
    if (['SUPERVISOR_DESPACHO', 'DESPACHO'].includes(user.role) && sup.role !== 'ADMIN') throw err('BAD_SUPERVISOR: el superior de un Superior Despacho debe ser Admin General', 'BAD_SUPERVISOR', 409);
    if (user.role === 'TRANSPORTISTA_INTERNO' && !hasPerm(sup, 'can_approve_internal_route_changes')) throw err('BAD_SUPERVISOR: el superior debe estar activo y tener permiso de aprobación', 'BAD_SUPERVISOR', 409);
  },
  async setUserSupervisor(userId, supId) {
    this._refresh(); const me = await this.me();
    if (!hasPerm(me, 'users.assign_supervisor')) throw err('FORBIDDEN', 'FORBIDDEN', 403);
    if (userId === me.id) throw err('SELF_SUPERVISOR: nadie cambia su propio superior', 'SELF_SUPERVISOR', 403);
    const u = this._user(userId); if (!u) throw err('No existe.', 'NOT_FOUND', 404);
    this._checkSupervisor(u, supId || null);
    const prev = u.supervisor_user_id || null; u.supervisor_user_id = supId || null;
    this._audit(me, 'USER_SUPERVISOR_SET', userId, { supervisor: prev }, { supervisor: u.supervisor_user_id });
    this._save(); return { ...u };
  },
  async myTeam() {
    this._refresh(); const me = await this.me(); const t = this._teamOf(me.id);
    return this.db.users.filter(u => t.has(u.id)).map(u => ({ id: u.id, full_name: u.full_name, role: u.role, status: u.status }));
  },

  // ===== Solicitudes (mismo motor que las aprobaciones) =====
  _requestApprover(userId) {
    const sid = (this._user(userId) || {}).supervisor_user_id, sup = this._user(sid);
    if (!sup || sid === userId || sup.status !== 'ACTIVO' || !(hasPerm(sup, 'requests.approve_team') || isAdmin(sup))) return null;
    return sid;
  },
  async createOperationalRequest(p) {
    this._refresh(); const me = await this.me();
    if (!hasPerm(me, 'requests.create')) throw err('FORBIDDEN', 'FORBIDDEN', 403);
    const Q = this.db.opRequests = this.db.opRequests || [];
    const again = p.op_id && Q.find(q => q.op_id === p.op_id); if (again) return { ...again };
    if (!REQUEST_TYPES.includes(p.request_type)) throw err('BAD_REQUEST_TYPE', 'BAD_REQUEST_TYPE', 400);
    if (!String(p.reason || '').trim()) throw err('REASON_REQUIRED: indicá el motivo', 'REASON_REQUIRED', 400);
    const r = p.route_id ? (this.db.routes2 || []).find(x => x.id === p.route_id) : null, sup = this._requestApprover(me.id);
    const q = { id: 'rq-' + (++this.db.seq), route_id: r ? r.id : null, route_number: r ? r.number : null, requested_by: me.id, requested_by_name: me.full_name, requested_at: new Date().toISOString(),
      supervisor_user_id: sup, escalated: !sup, request_type: p.request_type, payload: p.payload || {}, reason: p.reason, status: 'PENDING', op_id: p.op_id || null, applied: false };
    Q.push(q);
    const to = sup ? [sup] : this.db.users.filter(isAdmin).map(u => u.id);
    to.forEach(id => this._notifyUser(id, 'REQUEST_CREATED', 'SOLICITUD · ' + q.request_type.replace(/_/g, ' '), me.full_name + ': ' + q.reason, q.route_id));
    this._audit(me, 'REQUEST_CREATED', q.id, null, { type: q.request_type, approver: sup, escalated: q.escalated, route: q.route_id, payload: q.payload });
    this._save(); return { ...q };
  },
  _visibleRequest(me, q) { return q.requested_by === me.id || q.supervisor_user_id === me.id || isAdmin(me) || (hasPerm(me, 'requests.view_team') && this._teamOf(me.id).has(q.requested_by)); },
  async listOperationalRequests(filter) {
    this._refresh(); const me = await this.me();
    return (this.db.opRequests || []).filter(q => this._visibleRequest(me, q) && (!filter || filter === 'todas' || (filter === 'pendientes' && q.status === 'PENDING') || (filter === 'asignadas' && q.status === 'PENDING' && (q.supervisor_user_id === me.id || (q.escalated && isAdmin(me)))) || (filter === 'mias' && q.requested_by === me.id)))
      .map(q => ({ ...q, approver_name: q.supervisor_user_id ? (this._user(q.supervisor_user_id) || {}).full_name : 'Admin General', reviewed_by_name: q.reviewed_by ? (this._user(q.reviewed_by) || {}).full_name : null }))
      .sort((a, b) => String(b.requested_at).localeCompare(String(a.requested_at)));
  },
  async resolveOperationalRequest(id, decision, note, opId) {
    this._refresh(); const me = await this.me();
    if (!['APPROVED', 'REJECTED', 'OBSERVED'].includes(decision)) throw err('BAD_DECISION', 'BAD_DECISION', 400);
    const q = (this.db.opRequests || []).find(x => x.id === id); if (!q) throw err('NOT_FOUND', 'NOT_FOUND', 404);
    if (!['PENDING', 'OBSERVED'].includes(q.status)) {
      if (opId && q.resolution_op_id === opId) return { ...q };
      throw err('REQUEST_ALREADY_RESOLVED: la solicitud ya fue resuelta (' + q.status + ')', 'REQUEST_ALREADY_RESOLVED', 409);
    }
    if (q.requested_by === me.id) throw err('SELF_APPROVAL: no podés resolver tu propia solicitud', 'SELF_APPROVAL', 403);
    const perm = { APPROVED: 'requests.approve_team', REJECTED: 'requests.reject_team', OBSERVED: 'requests.observe_team' }[decision];
    if (!(isAdmin(me) || (q.supervisor_user_id && q.supervisor_user_id === me.id && hasPerm(me, perm)))) throw err('FORBIDDEN: solo el superior asignado o Admin General', 'FORBIDDEN', 403);
    if (decision !== 'APPROVED' && !String(note || '').trim()) throw err('REASON_REQUIRED: indicá el motivo', 'REASON_REQUIRED', 400);
    Object.assign(q, { status: decision, reviewed_by: me.id, reviewed_at: new Date().toISOString(), review_note: note || '', resolution_op_id: opId || null });
    if (decision === 'APPROVED' && q.request_type === 'CORRECCION_KM' && q.payload && q.payload.vehicle_id && q.payload.km != null) {
      const v = (this.db.vehicles || []).find(x => x.id === q.payload.vehicle_id);
      if (v) { v.current_km = Number(q.payload.km); q.applied = true; this._audit(me, 'VEHICLE_KM_CORRECTED', v.id, null, { km: q.payload.km, reason: q.reason, request: q.id, requested_by: q.requested_by }); }
    }
    this._notifyUser(q.requested_by, 'REQUEST_' + decision, 'SOLICITUD ' + { APPROVED: 'APROBADA', REJECTED: 'RECHAZADA', OBSERVED: 'OBSERVADA' }[decision], note || '', q.route_id);
    this._audit(me, 'REQUEST_' + decision, q.id, null, { note, type: q.request_type });
    this._save(); return { ...q };
  },
  async cancelOperationalRequest(id) {
    this._refresh(); const me = await this.me(); const q = (this.db.opRequests || []).find(x => x.id === id);
    if (!q || q.requested_by !== me.id || !['PENDING', 'OBSERVED'].includes(q.status)) throw err('BAD_STATE', 'BAD_STATE', 409);
    q.status = 'CANCELLED'; this._audit(me, 'REQUEST_CANCELLED', q.id, null, {}); this._save(); return { ...q };
  },

  // ===== Kilometraje =====
  _mileage() { return this.db.mileageSettings = this.db.mileageSettings || { require_km_start: true, require_km_end: true, tolerance_km: 0, max_trip_km: 1000, alert_lower_than_last: true }; },
  async mileageSettings() { this._refresh(); const me = await this.me(); this._need(me, 'vehicle_mileage.view', 'vehicle_mileage.rules_manage'); return { ...this._mileage() }; },
  async setMileageSettings(p) {
    this._refresh(); const me = await this.me(); this._need(me, 'vehicle_mileage.rules_manage', 'settings.manage');
    const prev = { ...this._mileage() }, m = this._mileage();
    ['require_km_start', 'require_km_end', 'alert_lower_than_last'].forEach(k => { if (p[k] != null) m[k] = !!p[k]; });
    ['tolerance_km', 'max_trip_km'].forEach(k => { if (p[k] != null && p[k] !== '') { const n = Number(p[k]); if (!(n >= 0) || (k === 'max_trip_km' && !(n > 0))) throw err('Valor inválido: ' + k, 'BAD_VALUE', 400); m[k] = n; } });
    m.updated_by = me.id; m.updated_at = new Date().toISOString();
    this._audit(me, 'MILEAGE_SETTINGS_CHANGED', 'mileage', prev, { ...m }); this._save(); return { ...m };
  },
  _mileageAlert(vehicle, routeId, kind, from, to, detail, me) {
    const A = this.db.mileageAlerts = this.db.mileageAlerts || [];
    const a = { id: 'ka-' + (++this.db.seq), vehicle_id: vehicle.id, plate: vehicle.plate, route_id: routeId, kind, km_from: from, km_to: to, detail: detail || {}, status: 'OPEN', created_at: new Date().toISOString(), created_by: me ? me.id : null };
    A.push(a);
    this.db.users.filter(u => u.status === 'ACTIVO' && (isAdmin(u) || hasPerm(u, 'vehicle_mileage.resolve_alerts'))).forEach(u =>
      this._notifyUser(u.id, 'KM_ALERT', 'KILOMETRAJE FUERA DE RANGO · ' + (vehicle.plate || ''), kind === 'LOWER_THAN_LAST' ? 'Km menor al último registrado' : kind === 'TRIP_OUT_OF_RANGE' ? 'Recorrido de ' + (to - from) + ' km' : 'Diferencia inconsistente', routeId));
    return a;
  },
  async recordVehicleKm(vehicleId, km, note) {
    this._refresh(); const me = await this.me(); this._need(me, 'vehicle_mileage.enter');
    const v = (this.db.vehicles || []).find(x => x.id === vehicleId); if (!v || v.active === false) throw err('BAD_VEHICLE', 'BAD_VEHICLE', 409);
    const m = this._mileage(), n = Number(km);
    if (!(n >= 0)) throw err('BAD_KM', 'BAD_KM', 400);
    if (n < Number(v.current_km)) {
      if (m.alert_lower_than_last) this._mileageAlert(v, null, 'LOWER_THAN_LAST', Number(v.current_km), n, { note }, me);
      this._save(); return { ok: false, code: 'KM_LOWER', message: 'El kilometraje no puede ser menor al último registrado (' + v.current_km + '). Pedí una corrección.', current_km: v.current_km };
    }
    if (n - Number(v.current_km) > m.max_trip_km + m.tolerance_km) this._mileageAlert(v, null, 'INCONSISTENT', Number(v.current_km), n, { note }, me);
    v.current_km = n; if (this._serviceCheck) this._serviceCheck(v);
    this._audit(me, 'VEHICLE_KM_RECORDED', v.id, null, { km: n, note: note || null }); this._save();
    return { ok: true, current_km: n, vehicle: v.id };
  },
  async listMileageAlerts(status) {
    this._refresh(); const me = await this.me(); this._need(me, 'vehicle_mileage.view');
    return (this.db.mileageAlerts || []).filter(a => !status || a.status === status).slice().reverse();
  },
  async resolveMileageAlert(id, note) {
    this._refresh(); const me = await this.me(); this._need(me, 'vehicle_mileage.resolve_alerts');
    if (!String(note || '').trim()) throw err('REASON_REQUIRED', 'REASON_REQUIRED', 400);
    const a = (this.db.mileageAlerts || []).find(x => x.id === id);
    if (!a || a.status !== 'OPEN') throw err('ALREADY_RESOLVED', 'ALREADY_RESOLVED', 409);
    Object.assign(a, { status: 'RESOLVED', resolved_by: me.id, resolved_at: new Date().toISOString(), resolution_note: note });
    this._audit(me, 'MILEAGE_ALERT_RESOLVED', a.vehicle_id, null, { alert: id, note }); this._save(); return { ...a };
  },
  // Alerta de recorrido fuera de rango al cerrar una hoja (no bloquea)
  _checkTripRange(r) {
    if (r && r.km_start != null && r.km_end != null) {
      const m = this._mileage(); if (r.km_end - r.km_start > m.max_trip_km + m.tolerance_km) {
        const v = (this.db.vehicles || []).find(x => x.id === r.vehicle_id); if (v) this._mileageAlert(v, r.id, 'TRIP_OUT_OF_RANGE', r.km_start, r.km_end, { max: m.max_trip_km }, null);
      }
    }
  },

  // ===== Notificaciones =====
  async listNotifications() {
    this._refresh(); const me = await this.me(); const team = this._teamOf(me.id);
    return (this.db.notifs || []).filter(n => n.user_id === me.id || isAdmin(me) || (hasPerm(me, 'requests.view_team') && team.has(n.user_id)))
      .map(n => ({ ...n, user_name: (this._user(n.user_id) || {}).full_name, mine: n.user_id === me.id })).sort((a, b) => String(b.created_at).localeCompare(String(a.created_at)));
  },
  async markNotificationRead(id) { this._refresh(); const me = await this.me(); const n = (this.db.notifs || []).find(x => x.id === id && x.user_id === me.id); if (n && !n.read_at) { n.read_at = new Date().toISOString(); this._save(); } return true; },

  // ===== Dashboards por rol =====
  async dashboardAdmin() {
    this._refresh(); const me = await this.me(); if (!isAdmin(me)) throw err('FORBIDDEN', 'FORBIDDEN', 403);
    const R = (this.db.routes2 || []).filter(r => r.operational_status !== 'CANCELADA'), today = TODAY();
    const C = this._carriers ? this._carriers() : [];
    const grp = r => String(r.carrier_id).startsWith('CT-') ? 'CRISTIAN' : ((C.find(c => c.id === r.carrier_id) || {}).kind === 'INTERNO' ? 'INTERNO' : 'OTROS');
    const inc = r => (r.stops || []).filter(s => ['NO_ENTREGADO', 'REPROGRAMAR', 'ENTREGA_PARCIAL'].includes(s.outcome)).length;
    const carriers = ['CRISTIAN', 'INTERNO', 'OTROS'].map(g => { const l = R.filter(r => grp(r) === g); return { grp: g,
      publicadas: l.filter(r => ['PUBLICADA', 'EN_CURSO', 'FINALIZADA'].includes(r.operational_status)).length, activas: l.filter(r => ['PUBLICADA', 'EN_CURSO'].includes(r.operational_status)).length,
      finalizadas: l.filter(r => r.operational_status === 'FINALIZADA').length, incidencias: l.reduce((t, r) => t + inc(r), 0),
      devoluciones: (this.db.returns || []).filter(x => x.status === 'PENDING' && l.some(r => r.id === x.route_id)).length,
      km: l.reduce((t, r) => t + (r.km_end != null && r.km_start != null ? r.km_end - r.km_start : 0), 0) }; });
    const veh = this.vehicleStatus ? await this.vehicleStatus() : [];
    return {
      kpis: { hojas_hoy: R.filter(r => MDZ(r.published_at) === today).length, en_curso: R.filter(r => r.operational_status === 'EN_CURSO').length,
        finalizadas: R.filter(r => r.operational_status === 'FINALIZADA' && MDZ(r.completed_at || r.finished_at) === today).length,
        incidencias: R.filter(r => ['PUBLICADA', 'EN_CURSO', 'FINALIZADA'].includes(r.operational_status)).reduce((t, r) => t + inc(r), 0) },
      carriers,
      alerts: { solicitudes: (this.db.opRequests || []).filter(q => q.status === 'PENDING').length + (this.db.approvals || []).filter(a => a.status === 'PENDING').length,
        incidencias: (this.db.returns || []).filter(x => x.status === 'PENDING').length, service: veh.filter(v => v.service_due).length,
        emails_error: (this.db.customerJobs || []).filter(j => j.status === 'ERROR').length + (this.db.sheetEmailJobs || []).filter(j => j.status === 'ERROR').length,
        noc: Object.values(this.db.nocs || {}).filter(n => ['CANCELLED_ROUTE_REVIEW', 'CIANBOX_DIFFERENCE'].includes(n.reconciliation_status)).length,
        km: (this.db.mileageAlerts || []).filter(a => a.status === 'OPEN').length },
      users: this.db.users.filter(u => ['ADMIN', 'SUPERVISOR_DESPACHO', 'OPERARIO_DEPOSITO', 'DESPACHO'].includes(u.role) && u.status !== 'ARCHIVADO').map(u => ({ id: u.id, full_name: u.full_name, role: u.role,
        role_label: ROLE_LABEL[u.role], status: u.status, supervisor: (this._user(u.supervisor_user_id) || {}).full_name || null,
        columns: hasPerm(u, 'columns.manage_defaults'), km: hasPerm(u, 'vehicle_mileage.rules_manage'), approve: hasPerm(u, 'requests.approve_team') }))
    };
  },
  async dashboardSupervisor() {
    this._refresh(); const me = await this.me(); this._need(me, 'requests.view_team', 'drafts.view_team');
    const team = this._teamOf(me.id), D = Object.values(this.db.drafts || {}).filter(d => d.status === 'BORRADOR'), R = this.db.routes2 || [], Q = this.db.opRequests || [], today = TODAY();
    const mine = R.filter(r => ['PUBLICADA', 'EN_CURSO'].includes(r.operational_status) && (r.published_by === me.id || team.has(r.published_by)));
    return {
      kpis: { borradores: D.filter(d => d.owner_id === me.id || team.has(d.owner_id)).length, borradores_equipo: D.filter(d => team.has(d.owner_id)).length,
        pendientes: Q.filter(q => q.status === 'PENDING' && q.supervisor_user_id === me.id).length, activas: mine.length, operarios: team.size },
      team: this.db.users.filter(u => team.has(u.id)).map(u => ({ id: u.id, full_name: u.full_name, role: u.role, status: u.status,
        borradores: D.filter(d => d.owner_id === u.id).length, publicadas_hoy: R.filter(r => r.published_by === u.id && MDZ(r.published_at) === today).length,
        solicitudes: Q.filter(q => q.requested_by === u.id && q.status === 'PENDING').length })).sort((a, b) => a.full_name.localeCompare(b.full_name)),
      requests: Q.filter(q => q.status === 'PENDING' && q.supervisor_user_id === me.id).map(q => ({ id: q.id, type: q.request_type, reason: q.reason, requested_by: (this._user(q.requested_by) || {}).full_name, at: q.requested_at, route: q.route_number })),
      active: mine.map(r => ({ number: r.number, carrier: r.carrier_name || r.carrier_id, responsable: r.responsable_name || '', status: r.operational_status,
        incidencia: (r.stops || []).some(s => ['NO_ENTREGADO', 'REPROGRAMAR', 'ENTREGA_PARCIAL'].includes(s.outcome)) })),
      notifications: (this.db.notifs || []).filter(n => n.user_id === me.id || team.has(n.user_id)).slice().sort((a, b) => String(b.created_at).localeCompare(String(a.created_at))).slice(0, 12)
        .map(n => ({ title: n.title, body: n.body, at: n.created_at, type: n.type })),
      perms: { columns: hasPerm(me, 'columns.manage_defaults') || hasPerm(me, 'columns.manage_templates'), km: hasPerm(me, 'vehicle_mileage.rules_manage'), approve: hasPerm(me, 'requests.approve_team') }
    };
  },
  async dashboardOperario() {
    this._refresh(); const me = await this.me(); this._need(me, 'routes.create');
    const kmView = hasPerm(me, 'vehicle_mileage.view');
    return {
      borradores: Object.values(this.db.drafts || {}).filter(d => d.owner_id === me.id && d.status === 'BORRADOR').length,
      requests: (this.db.opRequests || []).filter(q => q.requested_by === me.id).map(q => ({ id: q.id, type: q.request_type, status: q.status, reason: q.reason, note: q.review_note || null, at: q.requested_at }))
        .sort((a, b) => String(b.at).localeCompare(String(a.at))),
      notifications: (this.db.notifs || []).filter(n => n.user_id === me.id).slice().sort((a, b) => String(b.created_at).localeCompare(String(a.created_at))).slice(0, 12)
        .map(n => ({ title: n.title, body: n.body, at: n.created_at, type: n.type })),
      vehicles: kmView ? (this.db.vehicles || []).filter(v => v.active !== false).map(v => ({ id: v.id, name: v.name, plate: v.plate, current_km: v.current_km, assigned: v.habitual_driver_id === me.id }))
        .sort((a, b) => (b.assigned - a.assigned) || String(a.name).localeCompare(String(b.name))) : [],
      mileage: kmView ? { ...this._mileage() } : null,
      km_alerts: kmView ? (this.db.mileageAlerts || []).filter(a => a.status === 'OPEN').length : 0,
      supervisor: (this._user((this._user(me.id) || {}).supervisor_user_id) || {}).full_name || null
    };
  }
};