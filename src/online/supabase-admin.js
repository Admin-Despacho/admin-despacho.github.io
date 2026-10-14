// RC2 · API online (Supabase) de los módulos de Administración. Todo lo valida el servidor (RLS + funciones SQL).
import { DEFAULT_COLUMNS, DEFAULT_RULES } from './demo-admin.js';
import { moduleOfAction } from './demo-admin.js';

const sel = async q => { const { data, error } = await q; if (error) throw new Error(error.message); return data; };
const day = iso => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Argentina/Mendoza' }).format(new Date(iso));

export const SupabaseAdmin = {
  // Borradores
  async touchDraft(sheetKey, name, carrier, count, orders, content) { return this._rpc('touch_draft', { p_sheet_key: sheetKey, p_name: name, p_carrier: carrier, p_count: count, p_orders: orders, p_content: content }); },
  async listDrafts() { return (await this._rpc('list_drafts', {})) || []; },
  async draftContent(sheetKey) { return this._rpc('draft_content', { p_sheet_key: sheetKey }); },
  async deleteDraft(sheetKey) { return this._rpc('delete_draft', { p_sheet_key: sheetKey }); },
  // Historial
  async searchRoutes(f = {}) {
    const rows = (await this._rpc('search_routes', { p: f })) || [];
    return { total: rows.length ? Number(rows[0].total_count) : 0, rows };
  },
  async routeDetail(id) {
    const r = await sel(this.sb.from('routes').select('*, carriers(name), route_stops(*)').eq('id', id).single());
    const pdfs = await sel(this.sb.from('route_pdfs').select('*').eq('route_id', id).order('route_version'));
    const audit = await sel(this.sb.from('audit_log').select('*').eq('target_id', id).order('at', { ascending: false }).limit(100)).catch(() => []);
    const returns = await sel(this.sb.from('route_return_requests').select('*').eq('route_id', id));
    const postPublishRequests = await sel(this.sb.from('route_approval_requests').select('*').eq('route_id', id).eq('request_type', 'CAMBIO_POST_PUBLICACION').order('requested_at', { ascending: false })).catch(() => []);
    return { route: { ...r, carrier_name: r.carriers && r.carriers.name, stops: (r.route_stops || []).sort((a, b) => a.seq - b.seq) }, pdfs, audit, returns, postPublishRequests };
  },
  async deliveryTrace(stopId) {
    const stop = await sel(this.sb.from('route_stops').select('*').eq('id', stopId).single());
    const evidence = await sel(this.sb.from('stop_evidence').select('*').eq('stop_id', stopId).maybeSingle()).catch(() => null);
    const receipt = await sel(this.sb.from('delivery_receipts').select('*').eq('stop_id', stopId).maybeSingle()).catch(() => null);
    const emails = await sel(this.sb.from('customer_email_jobs').select('*').eq('stop_id', stopId).order('queued_at', { ascending: false })).catch(() => []);
    const ids = [...new Set([stop.outcome_by, evidence && evidence.created_by, receipt && receipt.generated_by].filter(Boolean))];
    const people = ids.length ? await sel(this.sb.from('profiles').select('id,full_name').in('id', ids)).catch(() => []) : [];
    const by = id => (people.find(p => p.id === id) || {}).full_name || null;
    return { stop, evidence, receipt, emails, outcome_by_name: by(stop.outcome_by) };
  },
  async resendNotification(id) { return this._rpc('resend_route_notification', { p_route: id }); },
  // Transportistas y plantillas
  async upsertCarrier(p) { return this._rpc('upsert_carrier', { p }); },
  async currentTemplate(carrierId) {
    const t = await sel(this.sb.from('sheet_templates').select('*').eq('carrier_id', carrierId).order('version', { ascending: false }).limit(1));
    return t && t[0] ? t[0] : { id: null, carrier_id: carrierId, version: 0, columns: DEFAULT_COLUMNS.map(c => ({ ...c })) };
  },
  async saveTemplate(carrierId, columns) { return this._rpc('save_sheet_template', { p_carrier: carrierId, p_columns: columns }); },
  // Vehículos
  async vehicleStatus() { return sel(this.sb.from('vehicle_service_status').select('*').order('name')); },
  async saveVehicle(p) { const r = await this._rpc('upsert_vehicle', { p }); this.sendServiceAlerts().catch(() => null); return r; },
  async registerServiceDone(id, km, date, note) { const r = await this._rpc('register_vehicle_service', { p_vehicle: id, p_km: km, p_date: date, p_note: note || null }); this.sendServiceAlerts().catch(() => null); return r; },
  // Reglas, notificaciones, ubicaciones, parámetros
  async financialRules() { const r = await sel(this.sb.from('financial_rules').select('*').order('version', { ascending: false }).limit(1)); return r && r[0] ? r[0] : { version: 0, rules: DEFAULT_RULES }; },
  async setFinancialRules(rules) { return this._rpc('set_financial_rules', { p_rules: rules }); },
  async notificationSettings() { return (await sel(this.sb.from('notification_settings').select('*').eq('id', 'DEFAULT').maybeSingle())) || {}; },
  async setNotificationSettings(p) { return this._rpc('set_notification_settings', { p }); },
  async listLocations() { return sel(this.sb.from('client_locations').select('*').order('client_key')); },
  async saveLocation(p) { return this._rpc('upsert_client_location', { p }); },
  async appSettings() { const r = await sel(this.sb.from('app_settings').select('value').eq('key', 'general').maybeSingle()); return (r && r.value) || {}; },
  async setAppSettings(v) { return this._rpc('set_app_setting', { p_key: 'general', p_value: { ...(await this.appSettings()), ...v } }); },
  async emailHistory() {
    const lab = { INTERNAL_ROUTE_APPROVAL_REQUEST: 'Aprobación ruta interna', INTERNAL_ROUTE_OBSERVED: 'Aclaración', ON_THE_WAY: 'Va en camino', DELIVERED: 'Entregado', PARTIAL: 'Entrega parcial', SERVICE_UPCOMING: 'Próximo service', SERVICE_REQUIRED: 'Service requerido' };
    const a = await sel(this.sb.from('approval_email_jobs').select('*').order('queued_at', { ascending: false }).limit(100));
    const c = await sel(this.sb.from('customer_email_jobs').select('*').order('queued_at', { ascending: false }).limit(100));
    const h = await sel(this.sb.from('sheet_email_jobs').select('*').order('queued_at', { ascending: false }).limit(100));
    const s = await sel(this.sb.from('vehicle_service_email_jobs').select('*').order('queued_at', { ascending: false }).limit(100)).catch(() => []);
    return [
      ...a.map(j => ({ ...j, source: 'approval' })),
      ...c.map(j => ({ ...j, source: 'customer' })),
      ...h.map(j => ({ ...j, source: 'sheet', kind: 'SHEET_PDF' })),
      ...s.map(j => ({ ...j, source: 'service', kind: j.alert_level === 'REQUIRED' ? 'SERVICE_REQUIRED' : 'SERVICE_UPCOMING' }))
    ].sort((x, y) => String(y.queued_at || '').localeCompare(String(x.queued_at || ''))).map(j => ({ ...j, label: lab[j.kind] || (j.kind === 'SHEET_PDF' ? 'PDF de hoja' : j.kind) }));
  },
  // NOC
  async applyCreditNote(p) { return this._rpc('apply_credit_note', { p }); },
  async reconcileCreditNotes(importId, items, complete) { return this._rpc('reconcile_credit_notes', { p_import_id: importId, p_items: items, p_complete: !!complete }); },
  async routeNocSummary(routeId) { return this._rpc('route_noc_summary', { p_route: routeId }); },
  async nocResolveApplication(appId, action, reason, expectedVersion, opId) { return this._rpc('noc_resolve_application', { p_app: appId, p_action: action, p_reason: reason, p_expected_version: expectedVersion == null ? null : expectedVersion, p_op_id: opId || null }); },
  async nocReassociate(appId, sheetKey) { return this._rpc('noc_reassociate', { p_app: appId, p_sheet_key: sheetKey }); },
  async nocReconciliationList(filter) { return (await this._rpc('noc_reconciliation_list', { p_filter: filter || 'todos' })) || []; },
  async detectCreditNotes(sheetKey, items) { return this._rpc('detect_credit_notes', { p_sheet_key: sheetKey, p_items: items }); },
  async consumeCreditNoteFinancing(p) { return this._rpc('consume_credit_note_financing', { p }); },
  async syncFinancingPlans(importId, plans) { return (await this._rpc('sync_financing_plans', { p_import_id: importId, p_plans: plans })) || []; },
  async financingPlanKeys() { return (await this._rpc('financing_plan_keys', {})) || []; },
  async listFinancingPlans() {
    const rows = await sel(this.sb.from('financing_plans').select('*').order('client_name'));
    const ids = [...new Set(rows.map(r => r.frequency_confirmed_by).filter(Boolean))];
    const ps = ids.length ? await sel(this.sb.from('profiles').select('id, full_name').in('id', ids)) : [];
    return rows.map(r => ({ ...r, confirmed_by_name: (ps.find(p => p.id === r.frequency_confirmed_by) || {}).full_name || null }));
  },
  async routingRules() { const r = await sel(this.sb.from('routing_rules').select('*').order('version', { ascending: false }).limit(1)); return r && r[0] ? r[0] : { version: 0, rules: [] }; },
  async setRoutingRules(rules) { return this._rpc('set_routing_rules', { p_rules: rules }); },
  async financingPlansFor(keys) { return sel(this.sb.from('financing_plans').select('*').in('client_key', keys)); },
  async confirmFinancingFrequency(id, freq, reason) { return this._rpc('confirm_financing_frequency', { p_plan: id, p_frequency: freq, p_reason: reason }); },
  async releaseCreditNote(sheetKey, fp) { return this._rpc('release_credit_note', { p_sheet_key: sheetKey, p_fingerprint: fp }); },
  async decideCreditNote(fp, decision, reason) { return this._rpc('decide_credit_note', { p_fingerprint: fp, p_decision: decision, p_reason: reason }); },
  async listCreditNotes() { return sel(this.sb.from('credit_notes').select('*').order('created_at', { ascending: false }).limit(300)); },
  // Auditoría / dashboard / backup
  async auditSearch(f = {}) {
    let q = this.sb.from('audit_log').select('*').order('at', { ascending: false }).limit(300);
    if (f.action) q = q.ilike('action', '%' + f.action + '%');
    if (f.target) q = q.ilike('target_id', '%' + f.target + '%');
    if (f.from) q = q.gte('at', f.from);
    let rows = await sel(q);
    const ids = [...new Set(rows.map(r => r.actor_id).filter(Boolean))];
    const ps = ids.length ? await sel(this.sb.from('profiles').select('id, full_name').in('id', ids)) : [];
    rows = rows.map(r => ({ ...r, actor_name: (ps.find(p => p.id === r.actor_id) || {}).full_name || '' }));
    if (f.user) rows = rows.filter(r => r.actor_name.toLowerCase().includes(f.user.toLowerCase()));
    if (f.text) rows = rows.filter(r => JSON.stringify([r.before, r.after]).toLowerCase().includes(f.text.toLowerCase()));
    if (f.module) rows = rows.filter(r => moduleOfAction(r.action) === f.module);
    return rows;
  },
  async dashboardSummary() {
    const s = await this._rpc('dashboard_summary', {});
    const v = await sel(this.sb.from('vehicle_service_status').select('name, plate, service_due, active')).catch(() => []);
    return { ...s, service_list: v.filter(x => x.active && x.service_due).map(x => x.name + ' · ' + x.plate) };
  },
  async backupExport() {
    const { data, error } = await this._invoke('backup', { body: { action: 'export' } });
    if (error) { let m = error.message; try { m = (await error.context.json()).error || m; } catch (e) { } throw new Error(m); }
    return data;
  },
  async backupFile(bucket, name) {
    const { data, error } = await this._invoke('backup', { body: { action: 'storage_file', bucket, name } });
    if (error) { let m = error.message; try { m = (await error.context.json()).error || m; } catch (e) { } throw new Error(m); }
    return data;
  },
  // compatibilidad con la vista de vehículos
  async _today() { return day(new Date().toISOString()); }
};
