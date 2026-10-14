// API online · RC4: roles jerárquicos, permisos individuales, solicitudes, kilometraje, notificaciones y dashboards.
// Toda validación ocurre en PostgreSQL (RPC security definer + RLS); esto solo transporta.
const sel = async q => { const { data, error } = await q; if (error) throw new Error(error.message); return data; };
export const SupabaseRC4 = {
  async userEffectivePermissions(userId) { return (await this._rpc('user_effective_permissions', { p_user: userId })) || []; },
  async userPermissionOverrides(userId) { return sel(this.sb.from('user_permission_overrides').select('*').eq('user_id', userId)); },
  async setUserPermission(userId, perm, state, reason) { return this._rpc('set_user_permission', { p_user: userId, p_perm: perm, p_state: state, p_reason: reason || null }); },
  async setUserSupervisor(userId, supId) { return this._rpc('set_user_supervisor', { p_user: userId, p_sup: supId || null }); },
  async myTeam() { const me = await this.me(); const ids = (await this._rpc('team_of', { p_user: me.id })) || []; return ids.length ? sel(this.sb.from('profiles').select('id, full_name, role, status').in('id', ids)) : []; },
  async createOperationalRequest(p) { return this._rpc('create_operational_request', { p }); },
  async listOperationalRequests(filter) {
    const me = await this.me();
    let q = this.sb.from('route_approval_requests').select('*, requester:profiles!route_approval_requests_requested_by_fkey(full_name), approver:profiles!route_approval_requests_supervisor_user_id_fkey(full_name), route:routes(number)')
      .neq('request_type', 'INTERNAL_ROUTE_CHANGE').order('requested_at', { ascending: false }).limit(300);
    if (filter === 'pendientes') q = q.eq('status', 'PENDING');
    if (filter === 'mias') q = q.eq('requested_by', me.id);
    const rows = await sel(q);
    return rows.filter(r => filter !== 'asignadas' || (r.status === 'PENDING' && (r.supervisor_user_id === me.id || (r.escalated && me.role === 'ADMIN'))))
      .map(r => ({ ...r, requested_by_name: r.requester && r.requester.full_name, approver_name: r.approver ? r.approver.full_name : 'Admin General', route_number: r.route && r.route.number }));
  },
  async resolveOperationalRequest(id, decision, note, opId) { return this._rpc('resolve_operational_request', { p_request: id, p_decision: decision, p_note: note || null, p_op_id: opId || null }); },
  async cancelOperationalRequest(id) { return this._rpc('cancel_operational_request', { p_request: id }); },
  async mileageSettings() { const r = await sel(this.sb.from('mileage_settings').select('*').eq('id', 'DEFAULT')); return r && r[0]; },
  async setMileageSettings(p) { return this._rpc('set_mileage_settings', { p }); },
  async recordVehicleKm(vehicleId, km, note) { const r = await this._rpc('record_vehicle_km', { p_vehicle: vehicleId, p_km: km, p_note: note || null }); this.sendServiceAlerts().catch(() => null); return r; },
  async listMileageAlerts(status) { let q = this.sb.from('vehicle_mileage_alerts').select('*, vehicle:vehicles(plate)').order('created_at', { ascending: false }).limit(200); if (status) q = q.eq('status', status); return (await sel(q)).map(a => ({ ...a, plate: a.vehicle && a.vehicle.plate })); },
  async resolveMileageAlert(id, note) { return this._rpc('resolve_mileage_alert', { p_alert: id, p_note: note }); },
  async listNotifications() { const me = await this.me(); return (await sel(this.sb.from('notifications').select('*, user:profiles(full_name)').order('created_at', { ascending: false }).limit(200))).map(n => ({ ...n, user_name: n.user && n.user.full_name, mine: n.user_id === me.id })); },
  async markNotificationRead(id) { return this._rpc('mark_notification_read', { p_id: id }); },
  async dashboardAdmin() { return this._rpc('dashboard_admin', {}); },
  async dashboardSupervisor() { return this._rpc('dashboard_supervisor', {}); },
  async dashboardOperario() { return this._rpc('dashboard_operario', {}); }
};