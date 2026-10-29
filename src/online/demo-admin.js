// RC2 · Modo demo: mismas reglas que las funciones SQL de la migración RC2 (borradores, historial, configuración,
// plantillas, vehículos, reglas financieras, emails, ubicaciones, parámetros, auditoría, backup y dashboard).
import { hasPerm } from '../../supabase/functions/_shared/rules.js';
import { DEMO_CARRIERS } from './demo-api.js';

const testFail = (flag, what) => { if (typeof window !== 'undefined' && window[flag]) throw Object.assign(new Error('No se pudo leer ' + what + ' (servidor no disponible)'), { code: 'NETWORK', status: 503 }); };
const err = (message, code, status, extra) => Object.assign(new Error(message), { code, status }, extra || {});
const SEQ = { 'CT-ESTE': '01', 'CT-ALR': '01', UCO: '02', INTERNO: '03', VASCA: '04', ANDESMAR: '05', MARCHETTI: '06' };
export const DEFAULT_ROUTING = [
  { estado: 'CRISTIAN', zona: 'ESTE', carrier: 'CRISTIAN TORRES - ESTE' }, { estado: 'CRISTIAN', zona: '', carrier: 'CRISTIAN TORRES - ALREDEDORES' },
  { estado: 'ALREDEDORES', zona: '', carrier: 'CRISTIAN TORRES - ALREDEDORES' }, { estado: 'GRAN MENDOZA', zona: '', carrier: 'CRISTIAN TORRES - ALREDEDORES' },
  { estado: 'ZONA ESTE', zona: '', carrier: 'CRISTIAN TORRES - ESTE' }, { estado: 'UCO', zona: '', carrier: 'UCO' }, { estado: 'VASCA', zona: '', carrier: 'VASCA' },
  { estado: 'ANDESMAR', zona: '', carrier: 'ANDESMAR' }, { estado: 'MARCHETTI', zona: '', carrier: 'MARCHETTI' }];
export const DEFAULT_RULES = { pay: { FAC: 'ICBC', NDP: 'SIMPLY' }, shipCosts: { ESTE: [13000], ALREDEDORES: [2000, 4000, 10000] }, creditMonths: 6, creditTypes: ['NOC', 'REC', 'REP'], tolerance: 1 };
export const DEFAULT_COLUMNS = [
  ['fecha', 'FECHA'], ['pedido', 'N° PEDIDO WEB'], ['comp', 'N° FACTURA / NDP'], ['cliente', 'CLIENTE', true], ['domicilio', 'DOMICILIO'], ['localidad', 'LOCALIDAD'],
  ['monto', 'MONTO', true], ['pago', 'MODO DE PAGO'], ['obs', 'OBSERVACIONES DE PAGO'], ['transp', 'TRANSPORTISTA'], ['bultos', 'BULTOS'], ['accion', 'ACCIÓN'], ['responsable', 'RESPONSABLE'], ['estado', 'ESTADO']
].map(([key, title, required], i) => ({ key, title, visible: i < 10 || key === 'bultos', order: i + 1, width: 0, align: key === 'monto' || key === 'bultos' ? 'right' : 'left',
  format: key === 'monto' ? 'money' : key === 'bultos' ? 'int' : 'text', screen: true, pdf: true, excel: true, required: !!required }));
const day = iso => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Argentina/Mendoza' }).format(new Date(iso));

export const DemoAdmin = {
  _need(me, ...perms) { if (!me || !perms.some(p => hasPerm(me, p))) throw err('ACCESO NO AUTORIZADO', 'FORBIDDEN', 403); },
  _carriers() { return this.db.carriers = this.db.carriers || DEMO_CARRIERS.map(c => ({ ...c, sequence_code: SEQ[c.id], emails: [], notes: '', report_group: /^CT-/.test(c.id) ? 'CRISTIAN_TORRES' : null })); },

  // ===== Borradores =====
  async touchDraft(sheetKey, name, carrier, count, orders, content) {
    this._refresh(); const me = await this.me(); this._need(me, 'routes.create');
    const d = this._draft(sheetKey, me, true);
    Object.assign(d, { name: name || d.name, carrier_name: carrier, delivery_count: count || 0, orders: orders || [], content, updated_at: new Date().toISOString() }); this._save(); return d;
  },
  async listDrafts() {
    this._refresh(); const me = await this.me(); this._need(me, 'routes.create');
    const RS = this.db.reservations || {};
    return Object.values(this.db.drafts || {}).filter(d => d.status === 'BORRADOR' && this._canViewDraftOf(me, d.owner_id)).map(d => ({
      id: d.id, client_sheet_key: d.client_sheet_key, name: d.name || 'Hoja', carrier_name: d.carrier_name || '', delivery_count: d.delivery_count || 0, orders: d.orders || [],
      owner_id: d.owner_id, owner_name: (this._user(d.owner_id) || {}).full_name, status: d.status, created_at: d.created_at, updated_at: d.updated_at || d.created_at,
      reserved: Object.keys(RS).filter(o => RS[o].sheet_key === d.client_sheet_key && RS[o].status === 'BORRADOR').sort() })).sort((a, b) => String(b.updated_at).localeCompare(String(a.updated_at)));
  },
  async draftContent(sheetKey) {
    this._refresh(); const me = await this.me(); this._need(me, 'routes.create'); const d = (this.db.drafts || {})[sheetKey]; if (!d) return null;
    if (!this._canViewDraftOf(me, d.owner_id)) throw err('FORBIDDEN_DRAFT', 'FORBIDDEN_DRAFT', 403);
    return { name: d.name, status: d.status, content: d.content || null };
  },
  async deleteDraft(sheetKey) {
    this._net(); this._refresh(); const me = await this.me(); this._need(me, 'routes.create');
    const d = this._draft(sheetKey, me, false); if (!d) return 0;
    const RS = this.db.reservations || {}; let n = 0;
    Object.keys(RS).forEach(o => { if (RS[o].sheet_key === sheetKey && RS[o].status === 'BORRADOR') { delete RS[o]; n++; } });
    this.db.shipping = (this.db.shipping || []).filter(x => !(x.sheet_key === sheetKey && !x.route_id));
    Object.assign(d, { status: 'CANCELADA', content: null, orders: [], updated_at: new Date().toISOString() });
    this._nocRelease(a => a.sheet_key === sheetKey, 'borrador eliminado', me);
    this._audit(me, 'DRAFT_DELETED', sheetKey, null, { released: n, owner: d.owner_id, name: d.name }); this._save(); return n;
  },

  // ===== Historial =====
  async searchRoutes(f = {}) {
    this._refresh(); const me = await this.me(); this._need(me, 'routes.view_all', 'routes.view_team', 'routes.view_own');
    const C = this._carriers(); let list = (this.db.routes2 || []).filter(r => this._canViewRoute(me, r));   // RC4.1: mismo alcance que la RLS
    const has = (a, b) => String(a || '').toLowerCase().includes(String(b || '').toLowerCase());
    if (f.number) list = list.filter(r => has(r.number, f.number));
    if (f.carrier) list = list.filter(r => r.carrier_id === f.carrier);
    if (f.status) list = list.filter(r => r.operational_status === f.status);
    if (f.approval) list = list.filter(r => r.approval_status === f.approval);
    if (f.responsable) list = list.filter(r => has(r.responsable_name, f.responsable));
    if (f.order) list = list.filter(r => r.stops.some(s => (s.order_numbers || []).includes(String(f.order))));
    if (f.client) list = list.filter(r => r.stops.some(s => has(s.client_name, f.client)));
    if (f.zone) list = list.filter(r => r.stops.some(s => s.zone === f.zone));
    if (f.from) list = list.filter(r => day(r.published_at) >= f.from);
    if (f.to) list = list.filter(r => day(r.published_at) <= f.to);
    list.sort((a, b) => String(b.published_at).localeCompare(String(a.published_at)));
    const total = list.length, off = f.offset || 0, lim = Math.min(f.limit || 25, 100);
    return { total, rows: list.slice(off, off + lim).map(r => ({ id: r.id, number: r.number, carrier_id: r.carrier_id, carrier_name: (C.find(c => c.id === r.carrier_id) || {}).name || r.carrier_name,
      responsable_name: r.responsable_name, operational_status: r.operational_status, approval_status: r.approval_status || 'NO_REQUERIDA', published_at: r.published_at, completed_at: r.completed_at,
      stops: r.stops.length, bultos: r.stops.reduce((a, s) => a + (Number(s.bultos) || 0), 0), zones: [...new Set(r.stops.map(s => s.zone).filter(Boolean))] })) };
  },
  async routeDetail(id) {
    this._refresh(); const me = await this.me(); this._need(me, 'routes.view_all', 'routes.view_team', 'routes.view_own');
    const r = (this.db.routes2 || []).find(x => x.id === id); if (!r) throw err('No existe.', 'NOT_FOUND', 404);
    this._routeScope(me, r);
    const pdfs = Object.values(this.db.routePdfs || {}).filter(p => p.route_id === id).sort((a, b) => a.route_version - b.route_version)
      .map(p => ({ ...p, generated_by_name: (this._user(p.generated_by) || {}).full_name }));
    const audit = (this.db.audit || []).filter(a => a.target === id || a.target_id === id);
    const returns = (this.db.returns || []).filter(x => x.route_id === id);
    return { route: JSON.parse(JSON.stringify(r)), pdfs, audit, returns };
  },
  async resendNotification(id) {
    this._refresh(); const me = await this.me(); this._need(me, 'routes.publish');
    { const any0 = (this.db.routes2 || []).find(x => x.id === id); if (any0) this._routeScope(me, any0); }
    const r = this.db.routes2.find(x => x.id === id && ['PUBLICADA', 'EN_CURSO'].includes(x.operational_status)); if (!r) throw err('Solo hojas publicadas o en curso.', 'BAD_STATE', 409);
    this.db.notifs = (this.db.notifs || []).filter(n => !(n.route_id === id && n.type === 'RECORDATORIO_HOJA'));
    this.db.notifs.push({ id: 'nt-' + (++this.db.seq), user_id: r.responsable_id, route_id: id, type: 'RECORDATORIO_HOJA', title: 'HOJA ' + r.number + ' PUBLICADA', body: 'Recordatorio de Despacho', created_at: new Date().toISOString(), read_at: null });
    r.viewed_at = null; this._audit(me, 'ROUTE_NOTIFICATION_RESENT', id); this._save();
  },

  // ===== Configuración: transportistas y plantillas =====
  async upsertCarrier(p) {
    // igual que el servidor (20261018190731_carrier_auto_sequence): settings.manage O carriers.manage; el correlativo se asigna solo
    // (siguiente libre de 2 dígitos) y es INMUTABLE
    this._refresh(); const me = await this.me();
    if (!(hasPerm(me, 'settings.manage') || hasPerm(me, 'carriers.manage'))) throw err('FORBIDDEN', 'FORBIDDEN', 403);
    if (!p.id || !p.name) throw err('BAD_CARRIER: id y nombre obligatorios', 'BAD_CARRIER', 400);
    const C = this._carriers(); let c = C.find(x => x.id === p.id.toUpperCase()), code;
    if (c && c.sequence_code) { code = c.sequence_code; if (p.sequence_code && p.sequence_code !== code) throw err('IMMUTABLE_CODE: el correlativo histórico no se puede modificar', 'IMMUTABLE_CODE', 400); }
    else { const n = Math.max(0, ...C.map(x => /^[0-9]{2}$/.test(x.sequence_code || '') ? +x.sequence_code : 0)) + 1; if (n > 99) throw err('NO_SEQUENCE_CODE', 'NO_SEQUENCE_CODE', 400); code = String(n).padStart(2, '0'); }
    if (!c) { c = { id: p.id.toUpperCase() }; C.push(c); }
    Object.assign(c, { name: p.name.toUpperCase(), kind: p.kind || 'EXTERNO', active: p.active !== false, sequence_code: code, report_group: p.report_group || null, emails: p.emails || [], notes: p.notes || '' });
    this._audit(me, 'CARRIER_SAVED', c.id, null, c); this._save(); return c;
  },
  async currentTemplate(carrierId) {
    testFail('OKD_TPL_FAIL', 'la plantilla de columnas'); this._refresh(); const T = (this.db.templates || []).filter(t => t.carrier_id === carrierId).sort((a, b) => b.version - a.version)[0];
    return T || { id: null, carrier_id: carrierId, version: 0, columns: DEFAULT_COLUMNS.map(c => ({ ...c })) };
  },
  async saveTemplate(carrierId, columns) {
    this._refresh(); const me = await this.me(); this._need(me, 'settings.manage', 'columns.manage_defaults', 'columns.manage_templates');
    if (!Array.isArray(columns) || !columns.length) throw err('Plantilla vacía.', 'BAD_TEMPLATE', 400);
    if (columns.some(c => c.required && c.visible === false)) throw err('Una columna obligatoria no se puede ocultar.', 'REQUIRED_HIDDEN', 400);
    const T = this.db.templates = this.db.templates || [];
    const t = { id: 'tp-' + (++this.db.seq), carrier_id: carrierId, version: Math.max(0, ...T.filter(x => x.carrier_id === carrierId).map(x => x.version)) + 1, columns, created_by: me.id, created_at: new Date().toISOString() };
    T.push(t); this._audit(me, 'TEMPLATE_SAVED', carrierId, null, { version: t.version }); this._save(); return t;
  },

  // ===== Vehículos =====
  async vehicleStatus() {
    const list = await this.listVehicles();
    return list.map(v => { const next = Number(v.last_service_km) + Number(v.service_interval_km);
      return { ...v, next_service_km: next, km_to_service: next - Number(v.current_km), service_due: Number(v.current_km) >= next, habitual_driver_name: (this._user(v.habitual_driver_id) || {}).full_name || '' }; });
  },
  async saveVehicle(p) {
    this._refresh(); const me = await this.me(); this._need(me, 'vehicles.manage');
    if (!String(p.name || '').trim() || !String(p.plate || '').trim()) throw err('Modelo y patente obligatorios.', 'BAD_VEHICLE', 400);
    const V = this.db.vehicles = this.db.vehicles || []; const plate = p.plate.toUpperCase().trim();
    if (V.some(v => v.plate === plate && v.id !== p.id)) throw err('Ya existe esa patente.', 'DUPLICATE', 409);
    let v = V.find(x => x.id === p.id); const isNew = !v;
    if (!v) { const km = Number(p.current_km) || 0; v = { id: 'vh-' + (++this.db.seq), current_km: km, last_service_km: p.last_service_km !== '' && p.last_service_km != null ? Number(p.last_service_km) : km, last_service_date: null, active: true }; V.push(v); }
    Object.assign(v, { name: p.name, plate, active: p.active !== false, notes: p.notes || '', service_interval_km: Number(p.service_interval_km) || 10000, habitual_driver_id: p.habitual_driver_id || null });
    // igual que el servidor (upsert_vehicle): marca, modelo, tipo y año SOLO se cargan en el ALTA; la edición los ignora
    if (isNew) { ['brand', 'model', 'type'].forEach(k => { if (p[k] != null) v[k] = p[k]; }); if (p.year !== undefined) v.year = p.year === '' ? null : Number(p.year); }
    this._audit(me, 'VEHICLE_SAVED', v.id, null, { plate }); this._serviceCheck(v); this._save(); return v;
  },
  _serviceCheck(v) {
    if (Number(v.current_km) < Number(v.last_service_km) + Number(v.service_interval_km)) return;
    const A = this.db.serviceAlerts = this.db.serviceAlerts || []; const key = v.id + '|' + v.last_service_km;
    if (A.includes(key)) return; A.push(key);
    this.db.notifs = this.db.notifs || [];
    this.db.users.filter(u => u.role === 'ADMIN' && u.status === 'ACTIVO').forEach(u => this.db.notifs.push({ id: 'nt-' + (++this.db.seq), user_id: u.id, type: 'SERVICE_REQUERIDO', title: '⚠ SERVICE REQUERIDO · ' + v.name + ' · ' + v.plate, body: 'KM actual ' + v.current_km, created_at: new Date().toISOString() }));
  },
  async registerServiceDone(id, km, date, note) {
    this._refresh(); const me = await this.me(); this._need(me, 'vehicles.manage');
    if (!(Number(km) > 0)) throw err('Indicá el kilometraje del service.', 'BAD_KM', 400);
    const v = this.db.vehicles.find(x => x.id === id); Object.assign(v, { last_service_km: Number(km), last_service_date: date, current_km: Math.max(v.current_km, Number(km)) });
    (this.db.vehicleServices = this.db.vehicleServices || []).push({ vehicle_id: id, km: Number(km), date, note: note || '', by: me.id, at: new Date().toISOString() });
    this._audit(me, 'VEHICLE_SERVICE_REGISTERED', id, null, { km, date, note }); this._save();
  },

  // ===== Reglas financieras / notificaciones / ubicaciones / parámetros =====
  async financialRules() { testFail('OKD_CFG_FAIL', 'las reglas financieras'); this._refresh(); const F = this.db.financialRules = this.db.financialRules || [{ version: 1, rules: DEFAULT_RULES, created_at: null }]; return F[F.length - 1]; },
  async setFinancialRules(rules) {
    this._refresh(); const me = await this.me(); this._need(me, 'settings.manage');
    if (Number(rules.tolerance) < 0 || Number(rules.creditMonths) < 0) throw err('Valores inválidos.', 'BAD_RULES', 400);
    const cur = await this.financialRules(); const f = { version: cur.version + 1, rules, created_by: me.id, created_at: new Date().toISOString() };
    this.db.financialRules.push(f); this._audit(me, 'FINANCIAL_RULES_CHANGED', 'v' + f.version, cur.rules, rules); this._save(); return f;
  },
  _ns() { return this.db.notifSettings = this.db.notifSettings || { on_the_way_enabled: true, delivered_enabled: true, sheet_email_enabled: false, sheet_email_time: '18:00', sheet_email_recipients: [], provider: 'RESEND', max_retries: 5 }; },
  async notificationSettings() { this._refresh(); return { ...this._ns() }; },
  async pendingAssignedRoutes(userId) { this._refresh(); return (this.db.routes2 || []).filter(r => r.responsable_id === userId && ['PUBLICADA', 'EN_CURSO'].includes(r.operational_status)).map(r => ({ id: r.id, number: r.number, operational_status: r.operational_status, carrier_id: r.carrier_id })); },
  async setNotificationSettings(p) {
    this._refresh(); const me = await this.me(); this._need(me, 'settings.manage');
    if (p.sheet_email_time && !/^([01][0-9]|2[0-3]):[0-5][0-9]$/.test(p.sheet_email_time)) throw err('Horario inválido (HH:MM).', 'BAD_TIME', 400);
    if ((p.sheet_email_recipients || []).some(e => !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(e))) throw err('Hay un email inválido.', 'BAD_EMAIL', 400);
    Object.assign(this._ns(), p); this._audit(me, 'NOTIFICATION_SETTINGS_CHANGED', null, null, p); this._save();
  },
  async listLocations() { this._refresh(); return (this.db.locations || []).slice(); },
  async saveLocation(p) {
    this._refresh(); const me = await this.me(); this._need(me, 'settings.manage', 'locations.manage');
    if (!p.client_key || p.lat === '' || p.lon === '' || isNaN(+p.lat) || isNaN(+p.lon) || Math.abs(+p.lat) > 90 || Math.abs(+p.lon) > 180) throw err('Coordenadas inválidas.', 'BAD_LOCATION', 400);
    const L = this.db.locations = this.db.locations || []; let l = L.find(x => x.client_key === p.client_key); if (!l) { l = { client_key: p.client_key }; L.push(l); }
    Object.assign(l, { client_name: p.client_name || '', address: p.address || '', lat: +p.lat, lon: +p.lon, radius_m: +p.radius_m || 200, active: p.active !== false, note: p.note || '' });
    this._audit(me, 'LOCATION_SAVED', l.client_key, null, l); this._save(); return l;
  },
  async appSettings() { this._refresh(); return { ...(this.db.appSettings || { company: 'OK Accesorios', timezone: 'America/Argentina/Mendoza', draft_stale_days: 2, return_days: 2 }) }; },
  async setAppSettings(v) { this._refresh(); const me = await this.me(); this._need(me, 'settings.manage'); this.db.appSettings = { ...(await this.appSettings()), ...v }; this._audit(me, 'APP_SETTING_CHANGED', 'general', null, v); this._save(); },
  async emailHistory() {
    this._refresh(); const me = await this.me(); this._need(me, 'settings.manage');
    const lab = { INTERNAL_ROUTE_APPROVAL_REQUEST: 'Aprobación ruta interna', INTERNAL_ROUTE_OBSERVED: 'Aclaración', ON_THE_WAY: 'Va en camino', DELIVERED: 'Entregado', PARTIAL: 'Entrega parcial' };
    return [...(this.db.emailJobs || []).map(j => ({ ...j, source: 'approval' })), ...(this.db.customerJobs || []).map(j => ({ ...j, source: 'customer' }))].map(j => ({ ...j, label: lab[j.kind] || j.kind }));
  },

  // ===== NOC: aceptación explícita, Saldo CC como piso, huella estable, consumo único, remanente, decisión de Administración =====
  // Comprobante → tipo, letra, punto de venta y número (mismo criterio que public.parse_comprobante)
  _parseComp(c) { const m = String(c || '').toUpperCase().match(/^\s*([A-Z]{3})\s*(?:\[\s*([A-Z])\s*\]|\s([A-Z]))\s*0*(\d{1,5})\s*-\s*0*(\d{1,8})\s*$/); return m ? { tipo: m[1], letra: m[2] || m[3], pv: Number(m[4]), numero: Number(m[5]) } : null; },
  // Huella: tipo + letra + PV + número + CUIT + fecha de emisión + importe original (mismo texto que public.noc_fingerprint)
  async _nocFp(c, cuit, fecha, orig) {
    const txt = c.tipo + '|' + c.letra + '|' + c.pv + '|' + c.numero + '|' + String(cuit).replace(/\D/g, '') + '|' + fecha + '|' + Math.abs(Number(orig)).toFixed(2);
    return [...new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(txt)))].map(x => x.toString(16).padStart(2, '0')).join('');
  },
  // Estado derivado de los importes (igual que el trigger credit_note_state)
  _nocStatus(n) { return ['IGNORADA', 'RECHAZADA'].includes(n.status) ? n.status : n.reserved_amount > 0.004 ? 'RESERVADA' : n.remaining_amount <= 0.004 && n.consumed_amount > 0.004 ? 'UTILIZADA' : n.consumed_amount > 0.004 ? 'PARCIALMENTE_UTILIZADA' : 'DISPONIBLE'; },
  _nocEvent(fp, event, amount, extra, me) {
    const n = (this.db.nocs || {})[fp] || {};
    (this.db.nocEvents = this.db.nocEvents || []).push({ fingerprint: fp, event, amount, remaining: n.remaining_amount, at: new Date().toISOString(), actor: me ? me.id : null, ...(extra || {}) });
    this._audit(me || null, 'NOC_' + event, fp, null, { amount, remaining: n.remaining_amount, ...(extra || {}) });
  },
  async _nocIdentity(p) {
    const c = this._parseComp(p.comp), cuit = String(p.cuit || '').replace(/\D/g, ''), orig = Math.abs(Number(p.original_amount));
    if (!c || c.tipo !== 'NOC') return { error: 'NOC_BAD_COMP' };
    if (![7, 8, 11].includes(cuit.length) || !/^\d{4}-\d{2}-\d{2}$/.test(p.issued_date || '') || !(orig > 0)) return { error: 'NOC_MISSING_DATA' };
    return { fingerprint: await this._nocFp(c, cuit, p.issued_date, orig), ...c, cuit, fecha: p.issued_date, original: orig };
  },
  _nocEnsure(idn, p, me) {
    const N = this.db.nocs = this.db.nocs || {};
    if (N[idn.fingerprint]) return false; // re-importar NUNCA revive saldo
    const avail = p.available_amount != null && p.available_amount !== '' ? Math.min(idn.original, Number(p.available_amount)) : idn.original;
    N[idn.fingerprint] = { fingerprint: idn.fingerprint, client_key: idn.cuit, cuit: idn.cuit, comp: p.comp, tipo: idn.tipo, letra: idn.letra, pv: idn.pv, numero: idn.numero, issued_date: idn.fecha,
      original_amount: idn.original, remaining_amount: avail, reserved_amount: 0, consumed_amount: 0, destination: null, status: 'DISPONIBLE', created_at: new Date().toISOString(),
      source_baseline_amount: avail, source_remaining_amount: null, reversed_amount: 0, reconciliation_status: 'OK', recon_version: 1 };
    this._nocEvent(idn.fingerprint, 'DETECTADA', null, { comp: p.comp, sheet_key: p.sheet_key }, me); return true;
  },
  // DETECCIÓN server-side (demo): estado real de cada NOC antes de ofrecerla
  async detectCreditNotes(sheetKey, items) {
    this._refresh(); const me = await this.me(); this._need(me, 'routes.create');
    const out = [], A = this.db.nocApps || [];
    for (const it of items || []) {
      const idn = await this._nocIdentity(it); if (idn.error) { out.push({ comp: it.comp, error: idn.error }); continue; }
      this._nocEnsure(idn, { ...it, sheet_key: sheetKey }, me);
      const n = this.db.nocs[idn.fingerprint];
      const last = A.filter(a => a.fingerprint === n.fingerprint && a.status === 'CONSUMED').sort((a, b) => String(b.at).localeCompare(String(a.at)))[0];
      const other = A.find(a => a.fingerprint === n.fingerprint && a.status === 'RESERVED' && a.sheet_key !== sheetKey);
      const od = other && (this.db.drafts || {})[other.sheet_key];
      const prior = A.filter(a => a.fingerprint === n.fingerprint && a.cancelled_route_id && a.status === 'CONSUMED').map(a => ({ app_id: a.id, amount: a.amount, route_number: a.cancelled_route_number, order_numbers: a.order_numbers || [],
        state: a.reconciliation_status, resolution: a.resolution || null, reassigned_sheet_key: a.reassigned_sheet_key || null }));
      out.push({ comp: it.comp, fingerprint: n.fingerprint, status: n.status, original: n.original_amount, reserved: n.reserved_amount, consumed: n.consumed_amount, available: this._nocEffective(n), destination: n.destination,
        reconciliation_status: n.reconciliation_status || 'OK', source_remaining: n.source_remaining_amount == null ? null : n.source_remaining_amount, prior,
        mine: A.filter(a => a.fingerprint === n.fingerprint && a.sheet_key === sheetKey && a.status === 'RESERVED').reduce((t, a) => t + a.amount, 0),
        reserved_elsewhere: !!other, reserved_by: other ? (od && od.name ? 'borrador "' + od.name + '"' : 'otro borrador') + ((this._user(other.created_by) || {}).full_name ? ' · ' + this._user(other.created_by).full_name : '') : null,
        used_at: last ? last.at : null, used_destination: last ? last.destination : null, used_reference: last ? (last.route_number ? 'hoja ' + last.route_number : last.reference) : null });
    }
    this._save(); return out;
  },
  async applyCreditNote(p) {
    this._net(); this._refresh(); const me = await this.me(); this._need(me, 'routes.create');
    if (p.accept !== true) throw err('NOC_NOT_ACCEPTED: la NOC se aplica solo con aceptación explícita', 'NOC_NOT_ACCEPTED', 400);
    const dest = p.destination || 'PEDIDO_ACTUAL'; if (dest === 'PEDIDO_ACTUAL') this._draft(p.sheet_key, me, true);
    const A = this.db.nocApps = this.db.nocApps || [];
    const again = A.find(a => a.op_id && a.op_id === p.op_id);
    if (again) { const n0 = this.db.nocs[again.fingerprint]; return { ok: true, fingerprint: again.fingerprint, applied: again.amount, remaining: n0.remaining_amount, status: n0.status, repeated: true }; }
    const idn = await this._nocIdentity(p);
    if (idn.error === 'NOC_BAD_COMP') throw err('NOC_BAD_COMP: no se puede identificar tipo/letra/punto de venta/número de "' + p.comp + '"', 'NOC_BAD_COMP', 400);
    if (idn.error) throw err('NOC_MISSING_DATA: faltan CUIT/DNI, fecha de emisión o importe original de la NOC', 'NOC_MISSING_DATA', 400);
    const req = Number(p.amount), ord = Number(p.order_amount), cc = Number(p.cc_saldo || 0);
    if (!(req > 0) || !(ord >= 0)) throw err('Importe inválido.', 'BAD_AMOUNT', 400);
    if (ord <= 0.004) throw err('NOC_NOTHING_TO_COLLECT: no hay importe a cobrar para reducir', 'NOC_NOTHING_TO_COLLECT', 409);
    this._nocEnsure(idn, p, me); const n = this.db.nocs[idn.fingerprint], fp = n.fingerprint;
    const other = A.find(a => a.fingerprint === fp && a.status === 'RESERVED' && a.sheet_key !== (p.sheet_key || ''));
    const eff = this._nocEffective(n);   // RC3: saldo realmente utilizable
    const code = ['IGNORADA', 'RECHAZADA'].includes(n.status) ? 'NOC_BLOCKED' : ['CANCELLED_ROUTE_REVIEW', 'CIANBOX_DIFFERENCE'].includes(n.reconciliation_status) ? 'NOC_UNDER_REVIEW'
      : (eff <= 0.004 && n.reserved_amount <= 0.004) ? 'NOC_CONSUMED' : other ? 'NOC_RESERVED_ELSEWHERE'
      : n.destination && n.destination !== dest ? 'NOC_DESTINATION_LOCKED' : eff <= 0.004 ? 'NOC_CONSUMED' : null;
    if (code) {
      const msg = { NOC_BLOCKED: 'Administración marcó esta NOC como ' + n.status, NOC_CONSUMED: 'NOTA DE CRÉDITO YA UTILIZADA', NOC_RESERVED_ELSEWHERE: 'NOTA DE CRÉDITO RESERVADA EN OTRO BORRADOR', NOC_UNDER_REVIEW: 'NOTA DE CRÉDITO EN REVISIÓN ADMINISTRATIVA (conciliación pendiente)' }[code] || 'La NOC ya se usó en ' + n.destination + ' y no puede usarse en otro destino';
      this._nocEvent(fp, 'INTENTO_DUPLICADO_BLOQUEADO', req, { sheet_key: p.sheet_key, destination: dest, code }, me); this._save();
      return { ok: false, code, message: msg, fingerprint: fp, status: n.status, original: n.original_amount, consumed: n.consumed_amount, available: eff, reconciliation_status: n.reconciliation_status };
    }
    const applied = Math.round(Math.min(req, eff, ord) * 100) / 100;
    const prev = A.filter(a => a.sheet_key === p.sheet_key && a.status === 'RESERVED' && (this.db.nocs[a.fingerprint] || {}).cuit === n.cuit).reduce((t, a) => t + a.amount, 0);
    A.push({ id: 'na-' + (++this.db.seq), fingerprint: fp, sheet_key: p.sheet_key || 'FIN:' + p.reference, amount: applied, status: 'RESERVED', op_id: p.op_id, created_by: me.id, destination: dest, reference: p.reference || p.sheet_key, at: new Date().toISOString(), order_numbers: p.order_numbers || [] });
    n.remaining_amount = Math.round((n.remaining_amount - applied) * 100) / 100; n.reserved_amount = Math.round((n.reserved_amount + applied) * 100) / 100; n.destination = n.destination || dest; n.status = this._nocStatus(n);
    const floorBefore = Math.max(0, cc - prev), floorAfter = Math.max(0, cc - prev - applied);
    this._nocEvent(fp, 'RESERVADA', applied, { sheet_key: p.sheet_key, destination: dest, floor_before: floorBefore, floor_after: floorAfter }, me); this._save();
    return { ok: true, fingerprint: fp, applied, remaining: this._nocEffective(n), status: n.status, repeated: false, floor_before: floorBefore, floor_after: floorAfter, collect_after: Math.round((ord - applied) * 100) / 100 };
  },
  // Solo libera lo RESERVADO (nunca lo consumido)
  _nocRelease(filter, reason, me) {
    const A = this.db.nocApps || [], N = this.db.nocs || {}; let k = 0;
    A.filter(a => a.status === 'RESERVED' && filter(a)).forEach(a => { a.status = 'RELEASED'; const n = N[a.fingerprint];
      n.reserved_amount = Math.max(0, Math.round((n.reserved_amount - a.amount) * 100) / 100); n.remaining_amount = Math.min(n.original_amount, Math.round((n.remaining_amount + a.amount) * 100) / 100);
      if (n.consumed_amount <= 0.004 && n.reserved_amount <= 0.004) n.destination = null; n.status = this._nocStatus(n);
      this._nocEvent(a.fingerprint, 'RESERVA_LIBERADA', a.amount, { sheet_key: a.sheet_key, reason, destination: a.destination }, me); k++; });
    return k;
  },
  // Consumo definitivo (publicar / confirmar financiación)
  _nocConsume(filter, route, me) {
    const A = this.db.nocApps || [], N = this.db.nocs || {};
    A.filter(a => a.status === 'RESERVED' && filter(a)).forEach(a => { a.status = 'CONSUMED'; a.reconciliation_status = 'PENDING_CIANBOX'; a.at = new Date().toISOString(); if (route) { a.route_id = route.id; a.route_number = route.number; }
      const n = N[a.fingerprint]; n.reserved_amount = Math.max(0, Math.round((n.reserved_amount - a.amount) * 100) / 100); n.consumed_amount = Math.round((n.consumed_amount + a.amount) * 100) / 100; n.status = this._nocStatus(n);
      this._nocEvent(a.fingerprint, n.status === 'UTILIZADA' ? 'APLICADA_TOTAL' : 'APLICADA_PARCIAL', a.amount, { sheet_key: a.sheet_key, destination: a.destination, reference: route ? 'hoja ' + route.number : a.reference }, me);
      this._nocAggregate(a.fingerprint); });
    if (route) A.filter(a => a.reassigned_sheet_key && a.reassigned_sheet_key === (route.sheet_key || '') && a.status === 'CONSUMED').forEach(a => { a.reassigned_from_route = a.cancelled_route_id; a.route_id = route.id; a.route_number = route.number; });
  },
  // ===== RC3: conciliación con Cianbox (mismas reglas que las funciones SQL) =====
  _nocEffective(n) {
    if (['IGNORADA', 'RECHAZADA'].includes(n.status)) return 0;
    const base = n.source_baseline_amount == null ? n.original_amount : n.source_baseline_amount;
    const src = n.source_remaining_amount == null ? n.remaining_amount : n.source_remaining_amount - n.reserved_amount - Math.max(0, n.consumed_amount - Math.max(0, base - n.source_remaining_amount));
    return Math.max(0, Math.round(Math.min(n.original_amount, n.remaining_amount, src) * 100) / 100);
  },
  _nocAggregate(fp) {
    const n = this.db.nocs[fp], apps = (this.db.nocApps || []).filter(a => a.fingerprint === fp), cons = apps.filter(a => a.status === 'CONSUMED').map(a => a.reconciliation_status);
    let st = ['CANCELLED_ROUTE_REVIEW', 'CIANBOX_DIFFERENCE', 'PENDING_CIANBOX', 'RECONCILED'].find(x => cons.includes(x));
    if (!st) { st = apps.some(a => a.status === 'REVERSED') ? 'REVERSED' : 'OK'; if (n.reconciliation_status === 'CIANBOX_DIFFERENCE' && n.reconciliation_detail && ['NO_INFORMADA', 'SALDO_MAYOR'].includes(n.reconciliation_detail.reason)) st = n.reconciliation_status; }
    n.reconciliation_status = st; return st;
  },
  _nocClassify(n) {
    const base = n.source_baseline_amount == null ? n.original_amount : n.source_baseline_amount, S = n.source_remaining_amount, C = n.consumed_amount, eq = (a, b) => Math.abs(a - b) <= 0.01;
    const d = { expected: Math.round((base - C) * 100) / 100, informed: S, difference: S == null ? null : Math.round((S - (base - C)) * 100) / 100 };
    if (S == null || C <= 0.004) return { st: 'OK', ...d };
    if (S <= 0.004) return { st: 'RECONCILED', reason: 'SALDO_CERO', ...d };
    if (eq(S, base - C)) return { st: 'RECONCILED', reason: 'REDUCCION_EXACTA', ...d };
    if (eq(S, base)) return { st: 'PENDING_CIANBOX', reason: 'SIN_REFLEJAR', ...d };
    return { st: 'CIANBOX_DIFFERENCE', reason: S > base ? 'SALDO_MAYOR' : 'REDUCCION_PARCIAL', ...d };
  },
  async reconcileCreditNotes(importId, items, complete) {
    this._refresh(); const me = await this.me(); this._need(me, 'routes.create');
    const N = this.db.nocs = this.db.nocs || {}, A = this.db.nocApps || [], seen = new Set(), cnt = {};
    for (const it of items || []) {
      const idn = await this._nocIdentity(it); if (idn.error) continue; seen.add(idn.fingerprint);
      const n = N[idn.fingerprint]; if (!n) continue;
      const prev = n.reconciliation_status || 'OK';
      Object.assign(n, { source_remaining_amount: Math.max(0, Number(it.available_amount) || 0), last_source_seen_at: new Date().toISOString(), last_source_import: importId });
      const c = this._nocClassify(n);
      A.filter(a => a.fingerprint === n.fingerprint && a.status === 'CONSUMED' && a.reconciliation_status !== 'CANCELLED_ROUTE_REVIEW').forEach(a => { a.reconciliation_status = c.st === 'OK' ? 'PENDING_CIANBOX' : c.st; if (c.st === 'RECONCILED') a.reconciled_source_amount = n.source_remaining_amount; });
      n.reconciliation_detail = { ...c, import: importId }; if (c.st === 'RECONCILED') n.last_reconciled_at = new Date().toISOString();
      if (c.st === 'CIANBOX_DIFFERENCE' && n.consumed_amount > 0.004) n.reconciliation_status = 'CIANBOX_DIFFERENCE';
      this._nocAggregate(n.fingerprint);
      if (n.reconciliation_status !== prev) { n.recon_version = (n.recon_version || 1) + 1; this._nocEvent(n.fingerprint, { RECONCILED: 'CONCILIADA', PENDING_CIANBOX: 'PENDIENTE_CIANBOX' }[n.reconciliation_status] || 'DIFERENCIA_CIANBOX', null, { reference: importId, ...c }, me); }
      cnt[n.reconciliation_status] = (cnt[n.reconciliation_status] || 0) + 1;
    }
    if (complete && (items || []).length) Object.values(N).filter(n => n.consumed_amount > 0.004 && !seen.has(n.fingerprint) && ['PENDING_CIANBOX', 'OK'].includes(n.reconciliation_status || 'OK')).forEach(n => {
      Object.assign(n, { reconciliation_status: 'CIANBOX_DIFFERENCE', recon_version: (n.recon_version || 1) + 1, reconciliation_detail: { st: 'CIANBOX_DIFFERENCE', reason: 'NO_INFORMADA', import: importId } });
      A.filter(a => a.fingerprint === n.fingerprint && a.status === 'CONSUMED' && a.reconciliation_status === 'PENDING_CIANBOX').forEach(a => { a.reconciliation_status = 'CIANBOX_DIFFERENCE'; });
      this._nocEvent(n.fingerprint, 'DIFERENCIA_CIANBOX', null, { reference: importId, reason: 'NO_INFORMADA' }, me); cnt.NO_INFORMADA = (cnt.NO_INFORMADA || 0) + 1;
    });
    this._save(); return cnt;
  },
  async routeNocSummary(routeId) {
    this._refresh(); const me = await this.me(); this._need(me, 'routes.manage_all_drafts', 'credit_notes.manage');
    const l = (this.db.nocApps || []).filter(a => a.route_id === routeId && a.status === 'CONSUMED'); return { count: l.length, amount: l.reduce((t, a) => t + a.amount, 0) };
  },
  // Administración: MANTENER APLICADA / REVERTIR / CONFIRMAR CONCILIACIÓN (versión esperada = control de concurrencia)
  async nocResolveApplication(appId, action, reason, expectedVersion, opId) {
    this._refresh(); const me = await this.me(); this._need(me, 'credit_notes.manage');
    if (!['KEEP', 'REVERSE', 'RECONCILE'].includes(action)) throw err('Acción inválida.', 'BAD_ACTION', 400);
    const a = (this.db.nocApps || []).find(x => x.id === appId); if (!a) throw err('No existe.', 'NOT_FOUND', 404);
    const n = this.db.nocs[a.fingerprint];
    if (action === 'REVERSE' && a.status === 'REVERSED' && opId && a.reversed_op_id === opId) return { ok: true, repeated: true, application: a.id, available: this._nocEffective(n), version: n.recon_version };
    if (expectedVersion != null && (n.recon_version || 1) !== expectedVersion) throw err('NOC_CONFLICT: otra persona modificó esta Nota de Crédito; se recargó el estado real', 'NOC_CONFLICT', 409);
    if (['KEEP', 'REVERSE'].includes(action) && !String(reason || '').trim()) throw err('REASON_REQUIRED: indicá el motivo', 'REASON_REQUIRED', 400);
    if (a.status === 'REVERSED') throw err('NOC_ALREADY_REVERSED: esta aplicación ya fue revertida', 'NOC_ALREADY_REVERSED', 409);
    if (a.status !== 'CONSUMED') throw err('BAD_STATE: solo aplicaciones consumidas', 'BAD_STATE', 409);
    const before = { consumed: n.consumed_amount, remaining: n.remaining_amount, reversed: n.reversed_amount || 0, available: this._nocEffective(n), note_state: n.reconciliation_status, application_state: a.reconciliation_status, resolution: a.resolution || null };
    const now = new Date().toISOString();
    if (action === 'KEEP') {
      if (a.reconciliation_status !== 'CANCELLED_ROUTE_REVIEW') throw err('BAD_STATE: solo aplicaciones de hojas canceladas en revisión', 'BAD_STATE', 409);
      const c = this._nocClassify(n); Object.assign(a, { resolution: 'KEEP', resolution_reason: reason, resolved_by: me.id, resolved_at: now, reconciliation_status: c.st === 'OK' ? 'PENDING_CIANBOX' : c.st });
      this._nocEvent(n.fingerprint, 'MANTENIDA_APLICADA', a.amount, { reference: reason, application: a.id }, me);
    } else if (action === 'REVERSE') {
      if (a.reconciliation_status === 'RECONCILED') throw err('NOC_ALREADY_RECONCILED: Cianbox ya refleja esta aplicación; no se puede revertir desde OK Despacho', 'NOC_ALREADY_RECONCILED', 409);
      const amt = Math.min(a.amount, n.consumed_amount);
      Object.assign(a, { status: 'REVERSED', resolution: 'REVERSED', resolution_reason: reason, resolved_by: me.id, resolved_at: now, reconciliation_status: 'REVERSED', reversed_op_id: opId || 'rev-' + a.id });
      n.consumed_amount = Math.round((n.consumed_amount - amt) * 100) / 100; n.reversed_amount = Math.round(((n.reversed_amount || 0) + amt) * 100) / 100;
      n.remaining_amount = Math.min(n.original_amount, Math.round((n.remaining_amount + amt) * 100) / 100); if (n.consumed_amount <= 0.004 && n.reserved_amount <= 0.004) n.destination = null; n.status = this._nocStatus(n);
      this._nocEvent(n.fingerprint, 'REVERTIDA', amt, { reference: reason, application: a.id }, me);
    } else {
      Object.assign(a, { resolution: 'RECONCILED', resolution_reason: reason, resolved_by: me.id, resolved_at: now, reconciliation_status: 'RECONCILED', reconciled_source_amount: n.source_remaining_amount });
      n.last_reconciled_at = now; this._nocEvent(n.fingerprint, 'CONCILIADA', a.amount, { reference: reason, application: a.id }, me);
    }
    this._nocAggregate(n.fingerprint); n.recon_version = (n.recon_version || 1) + 1;
    this._audit(me, 'NOC_' + action, n.fingerprint, before, { consumed: n.consumed_amount, remaining: n.remaining_amount, reversed: n.reversed_amount, available: this._nocEffective(n), note_state: n.reconciliation_status,
      application_state: a.reconciliation_status, resolution: a.resolution, reason, application: a.id, amount: a.amount, route: a.cancelled_route_id || a.route_id, order_numbers: a.order_numbers, import: n.last_source_import || null });
    this._save(); return { ok: true, repeated: false, application: a.id, state: a.reconciliation_status, available: this._nocEffective(n), version: n.recon_version };
  },
  async nocReassociate(appId, sheetKey) {
    this._refresh(); const me = await this.me(); this._need(me, 'routes.create'); this._draft(sheetKey, me, false);
    const a = (this.db.nocApps || []).find(x => x.id === appId);
    if (!a || a.status !== 'CONSUMED' || !a.cancelled_route_id || a.resolution !== 'KEEP') throw err('NOC_NOT_REASSIGNABLE: solo una aplicación mantenida por Administración de una hoja cancelada', 'NOC_NOT_REASSIGNABLE', 409);
    if (a.reassigned_sheet_key && a.reassigned_sheet_key !== sheetKey) throw err('NOC_ALREADY_REASSIGNED: ya se vinculó a otra hoja', 'NOC_ALREADY_REASSIGNED', 409);
    a.reassigned_sheet_key = sheetKey; this._nocEvent(a.fingerprint, 'REASOCIADA', a.amount, { sheet_key: sheetKey, reference: 'sin nuevo consumo', application: a.id }, me); this._save();
    return { ok: true, application: a.id, amount: a.amount, fingerprint: a.fingerprint };
  },
  async nocReconciliationList(filter) {
    this._refresh(); const me = await this.me(); this._need(me, 'credit_notes.manage');
    const f = filter || 'todos', map = { pendientes: 'PENDING_CIANBOX', cancelada: 'CANCELLED_ROUTE_REVIEW', diferencias: 'CIANBOX_DIFFERENCE', conciliados: 'RECONCILED', revertidos: 'REVERSED' };
    const R = this.db.routes2 || [], rank = { CANCELLED_ROUTE_REVIEW: 0, CIANBOX_DIFFERENCE: 1, PENDING_CIANBOX: 2 };
    return (this.db.nocApps || []).filter(a => ['CONSUMED', 'REVERSED'].includes(a.status) && (f === 'todos' || a.reconciliation_status === map[f])).map(a => {
      const n = this.db.nocs[a.fingerprint], r = R.find(x => x.id === (a.cancelled_route_id || a.route_id)) || {};
      const stop = (r.stops || []).find(s => (s.order_numbers || []).some(o => (a.order_numbers || []).includes(o)));
      return { application_id: a.id, fingerprint: n.fingerprint, comp: n.comp, client_name: stop ? stop.client_name : null, cuit: n.cuit, issued_date: n.issued_date, original_amount: n.original_amount,
        source_remaining_amount: n.source_remaining_amount == null ? null : n.source_remaining_amount, reserved_amount: n.reserved_amount, consumed_amount: n.consumed_amount, reversed_amount: n.reversed_amount || 0,
        effective_available: this._nocEffective(n), application_amount: a.amount, application_status: a.status, route_number: r.number || null, route_status: r.operational_status || null, order_numbers: a.order_numbers || [],
        note_state: n.reconciliation_status, application_state: a.reconciliation_status, resolution: a.resolution || null, resolution_reason: a.resolution_reason || null, last_source_seen_at: n.last_source_seen_at || null,
        last_source_import: n.last_source_import || null, difference: n.reconciliation_detail ? n.reconciliation_detail.difference : null, detail: n.reconciliation_detail || null, recon_version: n.recon_version || 1,
        cancel_reason: a.cancel_reason || null, cancelled_at: a.cancelled_at || null, _rank: rank[a.reconciliation_status] == null ? 3 : rank[a.reconciliation_status] };
    }).sort((x, y) => x._rank - y._rank);
  },
  async releaseCreditNote(sheetKey, fp) { this._refresh(); const me = await this.me(); this._need(me, 'routes.create'); this._draft(sheetKey, me, false); const k = this._nocRelease(a => a.sheet_key === sheetKey && a.fingerprint === fp, 'deshacer', me); this._save(); return k; },
  // ===== Financiación propia: plan del cliente persistido (mismas reglas que las funciones SQL de RC2.1b) =====
  _finFreq(parts) {
    const ds = [...new Set((parts || []).map(p => p.due).filter(d => /^\d{4}-\d{2}-\d{2}$/.test(d || '')))].sort().map(d => new Date(d + 'T00:00:00Z'));
    if (ds.length < 3) return 'POR_CONFIRMAR';
    const ld = d => new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + 1, 0)).getUTCDate();
    const pm = d => { const y = d.getUTCFullYear(), mo = d.getUTCMonth() + 1; return new Date(Date.UTC(y, mo, Math.min(d.getUTCDate(), new Date(Date.UTC(y, mo + 1, 0)).getUTCDate()))); };
    let w = true, m = true;
    for (let i = 1; i < ds.length; i++) {
      if ((ds[i] - ds[i - 1]) / 86400000 !== 7) w = false;
      const endBoth = ds[i].getUTCDate() === ld(ds[i]) && ds[i - 1].getUTCDate() === ld(ds[i - 1]) && (ds[i].getUTCFullYear() * 12 + ds[i].getUTCMonth()) - (ds[i - 1].getUTCFullYear() * 12 + ds[i - 1].getUTCMonth()) === 1;
      if (pm(ds[i - 1]).getTime() !== ds[i].getTime() && !endBoth) m = false;
    }
    return w ? 'SEMANAL' : m ? 'MENSUAL' : 'POR_CONFIRMAR';
  },
  _finState(f) { f.operational_pending = Math.max(0, Math.round((Number(f.source_pending) - Number(f.noc_adjustments)) * 100) / 100); if (f.status !== 'CANCELADO') f.status = f.operational_pending > 0.004 ? 'ACTIVO' : 'SALDADO'; f.updated_at = new Date().toISOString(); return f; },
  async syncFinancingPlans(importId, plans) {
    if (typeof window !== 'undefined' && window.OKD_FIN_DELAY) await new Promise(r => setTimeout(r, window.OKD_FIN_DELAY)); // pruebas de latencia
    if (typeof window !== 'undefined' && window.OKD_FIN_FAIL) throw err('No se pudo sincronizar la financiación (servidor no disponible)', 'NETWORK', 503);
    this._refresh(); const me = await this.me(); this._need(me, 'routes.create');
    const F = this.db.finPlans = this.db.finPlans || [];
    for (const p of plans || []) {
      if (!p.client_key || !p.comp) continue;
      const nxt = (p.parts || []).filter(x => Number(x.s) > 0.004 && /^\d{4}-\d{2}-\d{2}$/.test(x.due || '')).sort((a, b) => a.due.localeCompare(b.due))[0];
      let f = F.find(x => x.client_key === p.client_key && x.comp === p.comp);
      const nparts = (p.parts || []).length;
      if (!f && (nparts < 2 || p.only_if_exists)) continue; // un comprobante normal nunca crea un plan; la continuidad solo actualiza uno existente
      if (!f) { f = { id: 'fp-' + crypto.randomUUID(), client_key: p.client_key, comp: p.comp, status: 'ACTIVO', frequency_source: 'AUTO', noc_adjustments: 0, created_at: new Date().toISOString(), created_by: me.id }; F.push(f); }
      Object.assign(f, { client_name: p.client_name || f.client_name, comp_label: p.comp_label || f.comp_label, parts: nparts >= 2 ? p.parts : (f.parts || p.parts || []), source_pending: Math.max(0, Number(p.source_pending) || 0), next_due: nxt ? nxt.due : null, next_amount: nxt ? Number(nxt.s) : null,
        last_import_id: importId, last_source_at: new Date().toISOString(), resolver_version: p.resolver_version || f.resolver_version });
      if (f.frequency_source !== 'CONFIRMADA' && nparts >= 3) f.frequency = this._finFreq(p.parts); else if (!f.frequency) f.frequency = 'POR_CONFIRMAR';   // el ajuste NOC NUNCA se toca
      this._finState(f);
    }
    this._save(); const keys = new Set((plans || []).map(p => p.client_key)); return F.filter(f => keys.has(f.client_key)).map(f => ({ ...f }));
  },
  async financingPlanKeys() {
    if (typeof window !== 'undefined' && window.OKD_FIN_FAIL) throw err('No se pudo sincronizar la financiación (servidor no disponible)', 'NETWORK', 503);
    this._refresh(); const me = await this.me(); this._need(me, 'routes.create', 'routes.view_all'); return (this.db.finPlans || []).map(f => ({ client_key: f.client_key, comp: f.comp }));
  },
  async listFinancingPlans() { this._refresh(); const me = await this.me(); this._need(me, 'routes.create', 'routes.view_all', 'credit_notes.manage', 'settings.manage');
    return (this.db.finPlans || []).map(f => ({ ...f, confirmed_by_name: (this._user(f.frequency_confirmed_by) || {}).full_name || null })); },
  // Reglas Estado/Zona → Transportista (versionadas; única fuente online)
  async routingRules() {
    testFail('OKD_CFG_FAIL', 'las reglas de asignación'); this._refresh(); const R = this.db.routingRules = this.db.routingRules || [{ version: 1, rules: DEFAULT_ROUTING.map((r, i) => ({ ...r, priority: i + 1, active: true })), created_at: null }];
    return JSON.parse(JSON.stringify(R[R.length - 1]));
  },
  async setRoutingRules(rules) {
    this._refresh(); const me = await this.me(); this._need(me, 'settings.manage');
    if (!Array.isArray(rules) || rules.some(r => !String(r.estado || '').trim() || !String(r.carrier || '').trim())) throw err('BAD_RULES: cada regla necesita estado y transportista', 'BAD_RULES', 400);
    const cur = await this.routingRules(); const v = { version: cur.version + 1, rules, created_by: me.id, created_at: new Date().toISOString() };
    this.db.routingRules.push(v); this._audit(me, 'ROUTING_RULES_CHANGED', 'v' + v.version, cur.rules, rules); this._save(); return v;
  },
  async financingPlansFor(keys) { testFail('OKD_FIN_READ_FAIL', 'los planes de financiación'); this._refresh(); const me = await this.me(); this._need(me, 'routes.create', 'routes.view_all', 'credit_notes.manage'); const k = new Set(keys || []); return (this.db.finPlans || []).filter(f => k.has(f.client_key)).map(f => ({ ...f })); },
  async confirmFinancingFrequency(id, freq, reason) {
    this._refresh(); const me = await this.me(); this._need(me, 'credit_notes.manage', 'settings.manage');
    if (!['SEMANAL', 'MENSUAL'].includes(freq) || !String(reason || '').trim()) throw err('Indicá SEMANAL o MENSUAL y el motivo.', 'REASON_REQUIRED', 400);
    const f = (this.db.finPlans || []).find(x => x.id === id); if (!f) throw err('PLAN_NOT_FOUND', 'PLAN_NOT_FOUND', 404);
    const prev = f.frequency; Object.assign(f, { frequency: freq, frequency_source: 'CONFIRMADA', frequency_confirmed_by: me.id, frequency_confirmed_at: new Date().toISOString(), frequency_reason: reason });
    this._audit(me, 'FINANCING_FREQUENCY_CONFIRMED', id, { frequency: prev }, { frequency: freq, reason }); this._save(); return f;
  },
  // NOC → FINANCIACIÓN PROPIA: solo contra un plan REAL activo; baja únicamente el saldo operativo del plan
  async consumeCreditNoteFinancing(p) {
    testFail('OKD_FIN_APPLY_FAIL', 'el servidor al aplicar la NOC'); this._refresh(); const me = await this.me(); this._need(me, 'routes.create');
    const f = (this.db.finPlans || []).find(x => x.id === p.plan_id);
    if (!f) throw err('PLAN_NOT_FOUND: el plan de financiación no existe', 'PLAN_NOT_FOUND', 404);
    if (f.status !== 'ACTIVO' || f.operational_pending <= 0.004) throw err('PLAN_INACTIVE: el plan no está activo o no tiene saldo pendiente', 'PLAN_INACTIVE', 409);
    if (String(p.cuit || '').replace(/\D/g, '') !== String(f.client_key).replace(/\D/g, '')) throw err('PLAN_CLIENT_MISMATCH: la NOC no es del cliente del plan', 'PLAN_CLIENT_MISMATCH', 409);
    const r = await this.applyCreditNote({ ...p, destination: 'FINANCIACION_PROPIA', sheet_key: 'FIN:' + f.id, reference: f.id, order_amount: f.operational_pending });
    this._refresh(); const f2 = this.db.finPlans.find(x => x.id === f.id);
    if (r.ok && !r.repeated) {
      this._nocConsume(a => a.sheet_key === 'FIN:' + f.id, null, me);
      f2.noc_adjustments = Math.round((Number(f2.noc_adjustments) + r.applied) * 100) / 100; this._finState(f2);
      const n = this.db.nocs[r.fingerprint]; r.status = n.status; r.remaining = n.remaining_amount;
      this._audit(me, 'FINANCING_NOC_APPLIED', f2.id, null, { fingerprint: r.fingerprint, applied: r.applied, operational_pending: f2.operational_pending, source_pending: f2.source_pending });
      this._save();
    }
    return { ...r, consumed: !!r.ok, plan_id: f2.id, plan_operational_pending: f2.operational_pending, plan_source_pending: f2.source_pending, plan_noc_adjustments: f2.noc_adjustments, plan_status: f2.status };
  },
  async decideCreditNote(fp, decision, reason) {
    this._refresh(); const me = await this.me(); this._need(me, 'credit_notes.manage');
    if (!['IGNORADA', 'RECHAZADA'].includes(decision) || !String(reason || '').trim()) throw err('Indicá la decisión y el motivo.', 'REASON_REQUIRED', 400);
    const n = (this.db.nocs || {})[fp]; if (!n) throw err('No existe.', 'NOT_FOUND', 404);
    this._nocRelease(a => a.fingerprint === fp, 'NOC ' + decision, me);
    Object.assign(n, { status: decision, reason, decided_by: me.id, decided_at: new Date().toISOString() });
    this._nocEvent(fp, decision, null, { reason }, me); this._save(); return n;
  },
  async listCreditNotes() { this._refresh(); const me = await this.me(); this._need(me, 'routes.create', 'credit_notes.manage'); return Object.values(this.db.nocs || {}); },

  // ===== Auditoría / dashboard / backup =====
  async auditSearch(f = {}) {
    this._refresh(); const me = await this.me(); this._need(me, 'audit.view');
    const has = (a, b) => String(a || '').toLowerCase().includes(String(b || '').toLowerCase());
    let list = (this.db.audit || []).map(a => ({ ...a, actor_name: (this._user(a.actor || a.actor_id) || {}).full_name || '', target_id: a.target_id || a.target, at: a.at || a.created_at }));
    if (f.user) list = list.filter(a => has(a.actor_name, f.user));
    if (f.action) list = list.filter(a => has(a.action, f.action));
    if (f.target) list = list.filter(a => has(a.target_id, f.target) || has(JSON.stringify(a.after || {}), f.target));
    if (f.text) list = list.filter(a => has(JSON.stringify([a.before, a.after]), f.text));
    if (f.module) list = list.filter(a => moduleOfAction(a.action) === f.module);
    if (f.from) list = list.filter(a => !a.at || day(a.at) >= f.from);
    return list.reverse().slice(0, 300);
  },
  async dashboardSummary() {
    this._refresh(); const me = await this.me(); this._need(me, 'routes.create', 'users.view', 'settings.manage');
    const drafts = await this.listDrafts().catch(() => []), stale = (await this.appSettings()).draft_stale_days || 2;
    const veh = hasPerm(me, 'vehicles.manage') ? await this.vehicleStatus() : [];
    const today = day(new Date().toISOString()), R = this.db.routes2 || [];
    return { drafts: drafts.length, drafts_stale: drafts.filter(d => Date.now() - Date.parse(d.updated_at) > stale * 86400000).length,
      reserved_orders: Object.values(this.db.reservations || {}).filter(x => x.status === 'BORRADOR').length,
      approvals: hasPerm(me, 'can_approve_internal_route_changes') ? (this.db.approvals || []).filter(a => a.status === 'PENDING').length : 0,
      returns: (this.db.returns || []).filter(x => x.status === 'PENDING').length, service_due: veh.filter(v => v.active && v.service_due).length, service_list: veh.filter(v => v.active && v.service_due).map(v => v.name + ' · ' + v.plate),
      email_errors: [...(this.db.emailJobs || []), ...(this.db.customerJobs || [])].filter(j => j.status === 'ERROR').length,
      pdf_errors: Object.values(this.db.routePdfs || {}).filter(p => p.status === 'PDF_ERROR').length,
      incidents_today: R.flatMap(r => r.stops).filter(s => ['NO_ENTREGADO', 'REPROGRAMAR'].includes(s.outcome) && s.outcome_at && day(s.outcome_at) === today).length,
      active_routes: R.filter(r => ['PUBLICADA', 'EN_CURSO'].includes(r.operational_status)).length };
  },
  async backupFile(bucket, name) {
    this._refresh(); const me = await this.me(); this._need(me, 'settings.manage');
    const b64 = bucket === 'route-pdfs' ? (this.db.pdfStore || {})[name] : bucket === 'identity-docs' ? ((this.db.storage || {})[name] || {}).b64 : null;
    if (!b64) throw err('Archivo inexistente.', 'BAD_FILE', 400);
    const u = Uint8Array.from(atob(b64), c => c.charCodeAt(0));
    return { bucket, name, size: u.length, base64: b64, sha256: [...new Uint8Array(await crypto.subtle.digest('SHA-256', u))].map(x => x.toString(16).padStart(2, '0')).join('') };
  },
  async backupExport() {
    this._refresh(); const me = await this.me(); this._need(me, 'settings.manage');
    const enc = new TextEncoder(), hash = async o => [...new Uint8Array(await crypto.subtle.digest('SHA-256', enc.encode(JSON.stringify(o))))].map(x => x.toString(16).padStart(2, '0')).join('');
    const tables = {}; const data = JSON.parse(JSON.stringify({ ...this.db, passwords: undefined, authTokens: undefined, pdfStore: undefined, storage: undefined })); delete data.passwords; delete data.authTokens; delete data.pdfStore; delete data.storage; // archivos: aparte, en storage/
    for (const k of Object.keys(data)) tables[k] = { rows: Array.isArray(data[k]) ? data[k].length : Object.keys(data[k] || {}).length, sha256: await hash(data[k] ?? null) };
    const manifest = { app: 'OK Despacho (demo)', created_at: new Date().toISOString(), created_by: me.id, tables,
      storage: { 'route-pdfs': { objects: Object.keys(this.db.pdfStore || {}).length, names: Object.keys(this.db.pdfStore || {}) }, 'identity-docs': { objects: Object.keys(this.db.storage || {}).length, names: Object.keys(this.db.storage || {}) } } };
    const authUsers = this.db.users.map(u => ({ id: u.id, email: u.email || null, phone: u.phone || null, email_confirmed_at: u.status === 'ACTIVO' ? u.created_at || null : null, created_at: u.created_at || null })); // sin contraseñas
    manifest.auth_users = { count: authUsers.length, sha256: await hash(authUsers) };
    manifest.sha256 = await hash(tables);
    this._audit(me, 'BACKUP_CREATED', manifest.created_at, null, { tables: Object.keys(tables).length }); this._save();
    return { manifest, data, auth_users: authUsers, readme: 'Restaurar SIEMPRE primero en un proyecto de PRUEBA. Aplicar migraciones en orden, cargar las tablas en el orden del manifest con la clave de servidor (solo en el servidor), verificar los hashes SHA-256 y validar antes de cualquier decisión sobre producción.' };
  }
};

export function moduleOfAction(a) {
  a = String(a || '');
  if (/^USER_|^INVITE|^PASSWORD|^SESSIONS|^PASSKEY/.test(a)) return 'USUARIOS';
  if (/^DRAFT|^ORDER|^RESERV/.test(a)) return 'BORRADORES';
  if (/^ROUTE_|^SHIPPING|^STOP|^EXPECTED/.test(a)) return 'HOJAS';
  if (/^INTERNAL_/.test(a)) return 'APROBACIONES';
  if (/^VEHICLE/.test(a)) return 'VEHÍCULOS';
  if (/^REPORT|^COMMERCIAL/.test(a)) return 'INFORMES';
  if (/^BACKUP/.test(a)) return 'BACKUP';
  return 'CONFIGURACIÓN';
}