// AUTORIZACIONES COMERCIALES · API. En línea: funciones del servidor (validan TODO). Demo: las MISMAS reglas sobre el almacenamiento local.
import { hasPerm } from '../../supabase/functions/_shared/rules.js';
import { computeSchedule, arDate, addDays as schedAddDays } from './com-schedule.js';

export const SupabaseCom = {
  comMailSettings() { return this._rpc('com_mail_settings_get', {}); },
  comSetMailCopies(copies) { return this._rpc('com_mail_settings_set', { p_copies: copies }); },
  comConfig() { return this._rpc('com_config', {}); },
  comOrderAlerts(orders, cuits) { return this._rpc('com_order_alerts', { p_orders: orders, p_cuits: cuits }); },   // «CONSULTAR APROBACIÓN» (solo lectura)
  // ALARMA URGENTE (servidor: emisión, escalamiento a 3 min por pg_cron, atender, historial inmutable)
  comAlarmRaise(order, sheet, client, cuit, reason, opId) { return this._rpc('com_alarm_raise', { p_order_ref: order, p_sheet_key: sheet, p_client_name: client, p_client_cuit: cuit, p_reason: reason, p_op_id: opId }); },
  comAlarmAttend(id, version) { return this._rpc('com_alarm_attend', { p_id: id, p_version: version }); },
  comMyAlarms() { return this._rpc('com_my_alarms', {}); },
  comAlarmHistory(from, to) { return this._rpc('com_alarm_history', { p_from: from, p_to: to }); },
  comSetAlarmSettings(p) { return this._rpc('com_set_alarm_settings', { p }); },
  comAlarmSettings() { return this._rpc('com_alarm_settings', {}); },   // configuración GUARDADA + efectiva + problemas (B-AL-03)
  comAlarmByNotification(nid) { return this._rpc('com_alarm_by_notification', { p_notification: nid }); },   // enlace directo del push (B-AL-02)
  // V4 · historial completo por vendedor (paginación por cursor en el servidor) y escala de alarmas / push por dispositivo
  comHistory(scope, filters, cursor, limit) { return this._rpc('com_history', { p_scope: scope, p_filters: filters || {}, p_cursor: cursor || null, p_limit: limit || 25 }); },
  comRequestDetail(id) { return this._rpc('com_request_detail', { p_id: id }); },
  comMyAlarmsPage(limit) { return this._rpc('com_my_alarms_page', { p_limit: limit || 20 }); },
  comAlarmHistoryPage(from, to, cursor, limit) { return this._rpc('com_alarm_history_page', { p_from: from || null, p_to: to || null, p_cursor: cursor || null, p_limit: limit || 25 }); },
  comAlarmPushStatus() { return this._rpc('com_alarm_push_status', {}); },
  comMyPushDevices() { return this._rpc('com_my_push_devices', {}); },
  comSetKpiMode(mode, autorizacion) { return this._rpc('com_set_kpi_mode', { p_mode: mode, p_autorizacion: autorizacion || null }); },   // N-V4-03: reactivar exige la autorización de Dirección General
  async comUploadSource(path, blob, type) {   // almacenamiento PRIVADO: subida sin sobrescribir; si ya existe (mismo contenido) no es error
    const { error } = await this.sb.storage.from('com-sources').upload(path, blob, { contentType: type || 'application/octet-stream', upsert: false });
    if (error && !/exist|duplicate|409/i.test(String(error.message || error.statusCode || ''))) throw new Error(error.message || 'No se pudo respaldar el original');
    return { path };
  },
  comRegisterSource(kind, sha, size, name, type, path) { return this._rpc('com_register_source_file', { p_kind: kind, p_sha256: sha, p_size: size, p_name: name, p_mime: type, p_path: path }); },
  comSearchClients(q, limit = 12) { return this._rpc('com_search_clients', { p_q: q, p_limit: limit }); },
  comKpi(clientId) { return this._rpc('com_kpi_for_client', { p_client: clientId }); },
  comClientFinance(clientId) { return this._rpc('com_client_finance', { p_client: clientId }); },
  comCreate(kind, clientId, orderRef, terms, notes, opId) { return this._rpc('com_create_request', { p_kind: kind, p_client: clientId, p_order_ref: orderRef, p_terms: terms, p_notes: notes, p_op_id: opId }); },
  comDecide(id, version, decision, terms, reason) { return this._rpc('com_decide', { p_id: id, p_version: version, p_decision: decision, p_terms: terms, p_reason: reason }); },
  comRespond(id, version, accept, comment) { return this._rpc('com_respond', { p_id: id, p_version: version, p_accept: accept, p_comment: comment }); },
  comList(scope, status = null, limit = 30, offset = 0) { return this._rpc('com_list', { p_scope: scope, p_status: status, p_limit: limit, p_offset: offset }); },
  comTrack(q, openOnly = false, limit = 20, offset = 0) { return this._rpc('com_track', { p_q: q, p_open_only: openOnly, p_limit: limit, p_offset: offset }); },
  comNotifications() { return this._rpc('com_my_notifications', {}); },
  comSetSettings(p) { return this._rpc('com_set_settings', { p }); },
  comSetRouting(key, userId) { return this._rpc('com_set_routing', { p_channel_key: key, p_approver: userId }); },
  comSetAssignment(userId, channel, branch, cartera) { return this._rpc('com_set_assignment', { p_user: userId, p_channel: channel, p_branch: branch, p_cartera: cartera }); },
  comSetCompType(prefix, cls) { return this._rpc('com_set_comp_type', { p_prefix: prefix, p_class: cls }); },
  comSourcesStatus() { return this._rpc('com_sources_status', {}); },
  comReport(from, to) { return this._rpc('com_report', { p_from: from, p_to: to }); },
  comImportClients(fileName, sha, rows) { return this._rpc('com_import_clients', { p_file_name: fileName, p_sha256: sha, p_rows: rows }); },
  comApprovers() { return this._rpc('com_approvers', {}); },
  comDispatchStats(from, to) { return this._rpc('com_dispatch_stats', { p_from: from, p_to: to }); }
};

// ============================== DEMO (mismas reglas que el servidor) ==============================
const E = (code, msg) => Object.assign(new Error(code + (msg ? ': ' + msg : '')), { code });
const norm = s => String(s || '').normalize('NFD').replace(/[\u0300-\u036f]/g, '').toUpperCase().replace(/[^A-Z0-9]+/g, ' ').trim();
const digits = s => String(s || '').replace(/\D/g, '');
function cuitOk(c) { if (!/^\d{11}$/.test(c)) return false; const w = [5, 4, 3, 2, 7, 6, 5, 4, 3, 2]; let t = 0; for (let i = 0; i < 10; i++) t += +c[i] * w[i]; const r = 11 - (t % 11); return r !== 10 && (r === 11 ? 0 : r) === +c[10]; }
const TZ = 'America/Argentina/Mendoza';
const ymd = d => new Intl.DateTimeFormat('en-CA', { timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit' }).format(d);
const addDays = (iso, n) => { const d = new Date(iso + 'T12:00:00Z'); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
const monthStart = iso => iso.slice(0, 7) + '-01';
const addMonths = (m, n) => { const d = new Date(m + 'T12:00:00Z'); d.setUTCMonth(d.getUTCMonth() + n); return d.toISOString().slice(0, 7) + '-01'; };
const lastDay = m => addDays(addMonths(m, 1), -1);
const r2 = n => Math.round(n * 100) / 100;
const LABEL = { CUIT: 'CUIT', CUIL: 'CUIL', DNI: 'DNI' };
// clientes de la DEMO (ficticios): incluye ejemplos de revisión (CUIT duplicado, DNI genérico)
const DEMO_CLIENTS = [
  ['101', 'TECNOLOGIA DEL NORTE S.A.', 'Tecno Norte', 'CUIT', '30500010912', 'Ciudad de Mendoza'], ['102', 'TECNOCASA SRL', null, 'CUIT', '30707865888', 'Godoy Cruz'],
  ['103', 'CARIBE S A', null, 'CUIT', '30707865888', 'Guaymallén'], ['104', 'PEREZ JUAN', null, 'DNI', '30111222', 'Las Heras'],
  ['105', 'CONSUMIDOR FINAL - MONTECASEROS', null, 'DNI', '99999999', 'Ciudad de Mendoza'], ['106', 'COMERCIAL CUYO S.R.L.', 'Cuyo Repuestos', 'CUIT', '30717780406', 'Maipú'],
  ['107', 'ELECTRO ANDINO S.A.', null, 'CUIT', '30715531319', 'San Juan'], ['108', 'DISTRIBUIDORA CUYO S.R.L.', null, 'CUIT', '30717102742', 'San Juan'],
  ['109', 'TECNICA INTEGRAL SAS', 'Técnica Integral', 'CUIT', '30717322637', 'Luján de Cuyo'], ['110', 'GOMEZ ANA', null, 'DNI', '28777666', 'Rivadavia']];

const arDay = iso => new Date(Date.parse(iso) - 3 * 3600e3).toISOString().slice(0, 10);   // N-V4-05: America/Argentina/Mendoza (UTC−3, sin cambio de horario)
export const DemoCom = {
  async comMailSettings() { const me=await this._comMe();if(!this._comAdmin(me))throw E('FORBIDDEN');return {copies:(this._com().mailCopies||[]).slice(),author_always:true,history:[],simulated:true}; },
  async comSetMailCopies(copies) { const me=await this._comMe();if(!this._comAdmin(me))throw E('FORBIDDEN');const list=[...new Set((copies||[]).map(x=>String(x).trim().toLowerCase()).filter(Boolean))];if(list.length>20||list.some(x=>!/^[^\s<>@,;]+@[^\s<>@,;]+\.[^\s<>@,;]+$/.test(x)))throw E('INVALID_EMAIL_LIST');this._com().mailCopies=list;this._save();return this.comMailSettings(); },
  _com() {
    this._refresh();
    const c = this.db.com = this.db.com || {};
    if (!c.ready) {
      Object.assign(c, { ready: true, seq: 0, settings: { kpi_mode: 'DESHABILITADO', kpi_months: 3, floor_pct: 125, ceiling_pct: 150, fin_max_days: 30, cheq_max_days: 30, coverage_gap_days: 4, kpi_partial_rule: 'NO_CALCULAR', kpi_source_verified: false, email_enabled: false, cuota_rule: 'POR_CONFIRMAR', source_backup_enabled: false, source_max_mb: 15 },
        routing: { 'SUCURSAL:MONTECASEROS': 'u-wilfredo', 'SUCURSAL:SAN_JUAN': 'u-wilfredo', CARTERA: 'u-franco' },
        assignments: { 'u-com-mc': { channel: 'SUCURSAL', branch: 'MONTECASEROS' }, 'u-com-sj': { channel: 'SUCURSAL', branch: 'SAN_JUAN' }, 'u-com-hernan': { channel: 'CARTERA', cartera_label: 'Hernán' } },
        compTypes: { FAC: 'VENTA', NDP: 'VENTA', NOC: 'NOTA_CREDITO', NCR: 'NOTA_CREDITO', REC: 'PAGO', RBO: 'PAGO', ANU: 'ANULACION' },
        clients: [], imports: [], requests: [], events: [], notifs: [], emails: [], ingests: [], docs: {}, cc: [], issues: [] });
      DEMO_CLIENTS.forEach(([erp, rs, nf, t, n, loc]) => c.clients.push(this._comClientRow(erp, rs, nf, t, n, loc)));
      this._comReviews(); this._comSeedHistory(c); this._save();
    }
    return c;
  },
  _comClientRow(erp, rs, nf, t, n, loc) {
    const d = digits(n), type = !d ? 'SIN_DOC' : ['CUIT', 'CUIL', 'DNI'].includes(t) ? t : 'OTRO', valid = type === 'DNI' ? /^\d{7,8}$/.test(d) && !/^(\d)\1{6,7}$/.test(d) : ['CUIT', 'CUIL'].includes(type) && cuitOk(d);
    return { id: 'cli-' + erp, erp_id: erp, razon_social: rs, nombre: nf, doc_type: type, doc_number: d || null, doc_valid: valid, cuit: ['CUIT', 'CUIL'].includes(type) && valid ? d : null, localidad: loc, status: 'ACTIVO', review_reasons: [], search: norm([rs, nf, d].filter(Boolean).join(' ')) };
  },
  _comReviews() {
    const c = this.db.com;
    c.clients.forEach(x => {
      const rs = [x.cuit && c.clients.filter(y => y.cuit === x.cuit).length > 1 ? 'CUIT DUPLICADO EN EL PADRÓN' : null, x.doc_type === 'DNI' && /^(\d)\1{6,7}$/.test(x.doc_number || '') ? 'DOCUMENTO GENÉRICO (p. ej. 99999999)' : null,
        x.doc_type === 'DNI' && x.doc_number && !/^\d{7,8}$/.test(x.doc_number) ? 'DNI CON FORMATO INVÁLIDO' : null, ['CUIT', 'CUIL'].includes(x.doc_type) && !x.doc_valid ? x.doc_type + ' INVÁLIDO' : null, x.doc_type === 'SIN_DOC' ? 'SIN DOCUMENTO' : null].filter(Boolean);
      x.review_reasons = rs; x.status = rs.length ? 'REVISION' : 'ACTIVO';
    });
  },
  // historial de DEMOSTRACIÓN generado como si Depósito hubiera cargado «Saldo comprobante» cada 3 días (mismo algoritmo que el servidor)
  _comSeedHistory(c) {
    const today = ymd(new Date()), m1 = addMonths(monthStart(today), -1), m0 = addMonths(m1, -2);
    const docs = [['30500010912', 'FAC A 0001-00000101', addDays(m0, 5), 1500000], ['30500010912', 'FAC A 0001-00000102', addDays(addMonths(m0, 1), 8), 2000000],
      ['30500010912', 'FAC A 0001-00000103', addDays(m1, 3), 2000000], ['30500010912', 'NDP 0001-00000104', addDays(m1, 12), 700000], ['30500010912', 'NOC A 0001-00000005', addDays(m1, 20), -200000],
      ['30717780406', 'FAC B 0002-00000011', addDays(m0, 9), 900000], ['30717780406', 'FAC B 0002-00000012', addDays(addMonths(m0, 1), 9), 1100000], ['30717780406', 'FAC B 0002-00000013', addDays(m1, 9), 1300000],
      ['30715531319', 'FAC A 0003-00000021', addDays(m1, 4), 600000]];
    for (let d = addDays(m0, -2), n = 1; d <= today; d = addDays(d, 3), n++) {
      const rows = docs.filter(x => x[2] <= d).map(([cuit, comp, dd, m]) => ({ c: (c.clients.find(k => k.cuit === cuit) || {}).razon_social || '', cuit, comp, d: dd, m, s: m > 0 ? m : 0 }));
      this._comIngestRows('SC', { hash: 'demo-sc-' + n, file_name: 'Saldo comprobante ' + d + '.xlsx', loaded_at: d + 'T09:00:00Z', batch: 1, batches: 1 }, rows, d + 'T12:00:00Z');
    }
    this._comIngestRows('CC', { hash: 'demo-cc-1', file_name: 'Saldo cuenta corriente ' + today + '.xlsx', loaded_at: today + 'T09:00:00Z', batch: 1, batches: 1 },
      [{ c: 'TECNOLOGIA DEL NORTE S.A.', cuit: '30500010912', saldo: 1250000 }, { c: 'COMERCIAL CUYO S.R.L.', cuit: '30717780406', saldo: 300000 }], today + 'T12:00:00Z');
  },
  async _comMe() { const me = await this.me(); if (!me || me.status !== 'ACTIVO') throw E('FORBIDDEN'); return me; },
  _comAdmin(me) { return !!me && me.role === 'ADMIN' && me.status === 'ACTIVO' && !(me.disabled_modules || []).includes('COMERCIAL'); },   // N-V4-01 (= servidor)
  _alarmRole(a, me) {   // N-V4-01 (= _com_alarm_role): papel con el permiso ACTUAL; una asignación histórica no da acceso
    if (!me) return null;
    if (me.id === a.initial_user && hasPerm(me, 'com.approve')) return 'DESTINATARIO_INICIAL';
    if ((a.escalated_to || []).includes(me.id) && hasPerm(me, 'com.approve')) return 'ESCALAMIENTO';
    if (this._comAdmin(me)) return 'ADMINISTRADOR_GENERAL';
    if (a.raised_by === me.id && hasPerm(me, 'com.track')) return 'SOLICITANTE';
    return null; },
  _comName(id) { const u = (this.db.users || []).find(x => x.id === id); return u ? u.full_name + (u.role === 'ADMIN' ? ' — Administrador General' : u.role === 'COMERCIAL' ? ' — Comercial' : '') : null; },
  async comConfig() {
    const me = await this._comMe(), c = this._com(), adm = this._comAdmin(me), a = c.assignments[me.id];
    // B-W04 (= servidor): con el módulo COMERCIAL restringido (o sin permisos del módulo) no se entrega la configuración
    if (!(adm || ['com.request', 'com.approve', 'com.track', 'com.sources.upload'].some(x => hasPerm(me, x)))) throw E('FORBIDDEN');
    const key = a ? (a.channel === 'CARTERA' ? 'CARTERA' : 'SUCURSAL:' + a.branch) : null;
    return { settings: { ...c.settings }, my_assignment: a ? { ...a, approver: this._comName(c.routing[key]) } : null, is_admin: adm, can_request: hasPerm(me, 'com.request'),
      can_approve: hasPerm(me, 'com.approve') || adm, can_track: hasPerm(me, 'com.track') || adm, can_upload: hasPerm(me, 'com.sources.upload'),
      routing: adm ? Object.entries(c.routing).map(([k, v]) => ({ channel_key: k, approver_user_id: v, approver: this._comName(v) })).sort((x, y) => x.channel_key.localeCompare(y.channel_key)) : null,
      assignments: adm ? (this.db.users || []).filter(u => u.role === 'COMERCIAL').map(u => ({ user_id: u.id, name: u.full_name, ...(c.assignments[u.id] || {}) })) : null };
  },
  async comApprovers() { const me = await this._comMe(); if (!this._comAdmin(me)) throw E('FORBIDDEN'); return (this.db.users || []).filter(u => u.status === 'ACTIVO' && hasPerm(u, 'com.approve')).map(u => ({ id: u.id, name: this._comName(u.id) })); },
  async comSearchClients(q, limit = 12) {
    const me = await this._comMe(); if (!(hasPerm(me, 'com.request') || hasPerm(me, 'com.approve') || hasPerm(me, 'com.track') || this._comAdmin(me))) throw E('FORBIDDEN');
    const c = this._com(), n = norm(q), d = digits(q); if (n.length < 2 && d.length < 3) return [];
    return c.clients.filter(x => (d.length >= 3 && ((x.doc_number || '').startsWith(d) || (x.cuit || '').startsWith(d))) || (n.length >= 2 && (x.search.startsWith(n) || x.search.includes(' ' + n))))
      .sort((a, b) => (b.status === 'ACTIVO') - (a.status === 'ACTIVO') || (b.search.startsWith(n)) - (a.search.startsWith(n)) || a.razon_social.localeCompare(b.razon_social)).slice(0, Math.min(limit, 30))
      .map(x => ({ id: x.id, erp_id: x.erp_id, razon_social: x.razon_social, nombre: x.nombre, doc_type: x.doc_type, doc_number: x.doc_number, cuit: x.cuit, status: x.status, review_reasons: x.review_reasons, localidad: x.localidad, selectable: x.status === 'ACTIVO' }));
  },
  // ---------- ingesta de las cargas diarias (= com_ingest) ----------
  async comIngest(kind, meta, rows) { const me = await this._comMe(); if (!hasPerm(me, 'com.sources.upload')) throw E('FORBIDDEN'); this._com();
    { const c = this.db.com, fid = meta && meta.source_file_id;   // = _com_link_source: con el respaldo ENCENDIDO, una carga sin su original se rechaza
      if (c.settings.source_backup_enabled && !(c.ingests || []).some(i => i.kind === kind && i.hash === meta.hash && i.done)) { if (!fid) throw E('SOURCE_REQUIRED', 'falta el original de la carga (respaldo activo)'); if (!(c.sources || []).some(x => x.id === fid && x.kind === kind)) throw E('BAD_SOURCE', 'el original no corresponde a esta carga'); } } if (typeof window !== 'undefined' && window.OKD_COM_INGEST_FAIL) throw E('NETWORK', 'sin conexión (simulado)'); const r = this._comIngestRows(kind, meta, rows, new Date().toISOString(), me.id); this._save(); return r; },
  async comIngestError(kind, meta, error) {
    const me=await this._comMe(); if(!hasPerm(me,'com.sources.upload')) throw E('FORBIDDEN');
    const c=this._com(),g=c.ingests.find(x=>x.kind===kind&&x.hash===meta.hash&&(x.loaded_at||null)===(meta.loaded_at||null)&&x.by===me.id);
    if(g){g.error=error;if(g.status!=='OK')g.status='ERROR';}
    else c.ingests.push({id:c.ingests.length+1,kind,hash:meta.hash||'err-'+Date.now(),file_name:meta.file_name,loaded_at:meta.loaded_at||null,by:me.id,at:new Date().toISOString(),status:'ERROR',error});this._save();
  },
  // WORK-K02 (= _com_month_sales): venta del mes POR COMPROBANTE con la regla de cuotas; 'pend' = comprobantes en cuotas no asignables
  _comMonthSales(cuit, m) {
    const c = this.db.com, rule = c.settings.cuota_rule || 'POR_CONFIRMAR', G = {};
    Object.values(c.docs).filter(d => d.cuit === cuit && d.status === 'OK' && ['VENTA', 'NOTA_CREDITO'].includes(d.class)).forEach(d => {
      const k = d.key.split('|').slice(0, 2).join('|') + '|' + d.class; (G[k] = G[k] || { cls: d.class, date: d.date, amts: [] }).amts.push(d.amount); if (d.date < G[k].date) G[k].date = d.date; });
    let amount = 0, pend = 0;
    Object.values(G).filter(g => monthStart(g.date || '') === m).forEach(g => {
      const n = g.amts.length, mn = Math.min(...g.amts), mx = Math.max(...g.amts), tot = g.amts.reduce((a, b) => a + b, 0), sg = v => g.cls === 'VENTA' ? v : -Math.abs(v);
      if (n === 1 || (rule === 'MONTO_ES_TOTAL' && mn === mx)) amount += sg(mx); else if (rule === 'MONTO_ES_CUOTA') amount += sg(tot); else pend++;
    });
    return { amount: r2(amount), pend };
  },
  // respaldo privado de ORIGINALES (= com_register_source_file / _com_link_source); la demo guarda solo metadatos, nunca contenido
  async comUploadSource(path, blob, type) { const me = await this._comMe(), c = this._com(); if (!(hasPerm(me, 'com.sources.upload') && c.settings.source_backup_enabled) || !/^(SC|CC)\/[0-9a-f]{64}\.(xlsx|xls|csv)$/.test(path)) throw E('FORBIDDEN', 'subida no permitida');
    c.storage = c.storage || {}; if (!c.storage[path]) c.storage[path] = { size: blob.size, type, by: me.id, at: new Date().toISOString() }; this._save(); return { path }; },
  async comRegisterSource(kind, sha, size, name, type, path) { const me = await this._comMe(), c = this._com(), s = c.settings;
    if (!hasPerm(me, 'com.sources.upload')) throw E('FORBIDDEN'); if (!s.source_backup_enabled) throw E('BACKUP_DISABLED', 'el respaldo de originales no está habilitado');
    const ext = String(name || '').toLowerCase().replace(/^.*\./, ''); if (!['SC', 'CC'].includes(kind) || !/^[0-9a-f]{64}$/.test(sha) || path !== kind + '/' + sha + '.' + ext || !/\.(xlsx|xls|csv)$/.test(path)) throw E('BAD_SOURCE', 'tipo, hash o ruta inválidos');
    if (!(size > 0) || size > s.source_max_mb * 1048576) throw E('FILE_TOO_LARGE', 'supera ' + s.source_max_mb + ' MB'); if (!(c.storage || {})[path]) throw E('SOURCE_NOT_UPLOADED', 'el original todavía no está en el almacenamiento');
    c.sources = c.sources || []; const f = c.sources.find(x => x.kind === kind && x.sha256 === sha); if (f) return { id: f.id, version: f.version, repeated: true };
    const v = c.sources.filter(x => x.kind === kind).length + 1, nf = { id: 'src-' + kind + '-' + v, kind, version: v, sha256: sha, size_bytes: size, original_name: name, storage_path: path, uploaded_by: me.id, uploaded_at: new Date().toISOString() };
    c.sources.push(nf); this._save(); return { id: nf.id, version: v, repeated: false }; },
  _comIngestRows(kind, meta, rows, at, by) {
    const c = this.db.com; let g = c.ingests.find(x => x.kind === kind && x.hash === meta.hash && (x.loaded_at || null) === (meta.loaded_at || null) && (x.by || null) === (by || null));
    if (!g) { g = { id: c.ingests.length + 1, kind, hash: meta.hash, file_name: meta.file_name, loaded_at: meta.loaded_at || null, at, by, batches: meta.batches || 1, done: [], status: 'EN_PROCESO', stats: { nuevos: 0, repetidos: 0, conflictos: 0, sin_cuit: 0, saldo_anterior: 0, sin_clasificar: 0 } }; c.ingests.push(g); }
    if (!g.done) Object.assign(g, { at, by, batches: meta.batches || 1, done: [], status: 'EN_PROCESO', error: null, stats: { nuevos: 0, repetidos: 0, conflictos: 0, sin_cuit: 0, saldo_anterior: 0, sin_clasificar: 0 } });   // un intento fallido registrado (= servidor): se retoma y completa
    if (meta && meta.source_file_id && !g.source_file_id) g.source_file_id = meta.source_file_id;   // vínculo carga → original
    if (g.done.includes(meta.batch || 1)) return { ingest_id: g.id, batch: meta.batch || 1, repeated: true, status: g.status };
    for (const r of rows || []) {
      const cu = digits(r.cuit);
      if (kind === 'CC') { if (!cuitOk(cu)) { g.stats.sin_cuit++; continue; } c.cc.push({ ingest: g.id, cuit: cu, client_name: r.c, saldo: r.saldo }); g.stats.nuevos++; continue; }
      if (r.san) { g.stats.saldo_anterior++; continue; }
      if (!cuitOk(cu)) { g.stats.sin_cuit++; continue; }
      const pre = String(r.comp || '').trim().slice(0, 3).toUpperCase(), cls = c.compTypes[pre] || null, amt = r.m ?? r.ve ?? null, key = cu + '|' + (r.n || String(r.comp).toUpperCase().replace(/[\s[\]\-_.()]/g, '')) + '|' + (r.q || (r.due ? 'V' + r.due : '-'));   // WORK-K02: parte = cuota o vencimiento
      const d = c.docs[key];
      if (!d) { c.docs[key] = { key, cuit: cu, client_name: r.c, comp: r.comp, prefix: pre, class: cls, date: r.d || null, amount: amt, saldo: r.s, first: g.id, last: g.id, seen: 1, status: !cls ? 'SIN_CLASIFICAR' : amt == null ? 'SIN_IMPORTE' : !r.d ? 'SIN_FECHA' : 'OK' };
        g.stats.nuevos++; if (!cls) { g.stats.sin_clasificar++; c.issues.push({ kind: 'TIPO_SIN_CLASIFICAR', cuit: cu, doc_key: key, detail: { prefijo: pre }, status: 'ABIERTA' }); } }
      else { g.stats.repetidos++; d.last = g.id; d.seen++; d.saldo = r.s;
        if (d.amount !== amt || d.date !== (r.d || null)) { g.stats.conflictos++; d.status = 'CONFLICTO'; if (!c.issues.some(i => i.kind === 'IMPORTE_CAMBIADO' && i.doc_key === key)) c.issues.push({ kind: 'IMPORTE_CAMBIADO', cuit: cu, doc_key: key, detail: { antes: d.amount, ahora: amt }, status: 'ABIERTA' }); } }
    }
    g.done.push(meta.batch || 1); if (g.done.length >= g.batches) g.status = 'OK';
    return { ingest_id: g.id, batch: meta.batch || 1, status: g.status, repeated: false, stats: g.stats };
  },
  _comCovered(m) {
    const c = this.db.com, gap = c.settings.coverage_gap_days, days = [...new Set(c.ingests.filter(i => i.kind === 'SC' && i.status === 'OK').map(i => ymd(new Date(i.at))))].sort(), a = m, z = lastDay(m);
    if (!days.some(d => d <= addDays(a, gap)) || !days.some(d => d >= z)) return false;
    const inR = days.filter(d => d >= addDays(a, -gap) && d <= addDays(z, gap));
    if (!inR.length || inR[0] > addDays(a,gap) || inR[inR.length-1] < z) return false;
    for (let i = 1; i < inR.length; i++) if ((new Date(inR[i]) - new Date(inR[i - 1])) / 864e5 > gap) return false;
    return true;
  },
  _comKpi(clientId) {
    const c = this.db.com, s = c.settings, cl = c.clients.find(x => x.id === clientId); if (!cl) return { status: 'SIN_CLIENTE' };
    if (s.kpi_mode !== 'PROVISORIO') return { status: 'DESHABILITADO', provisional: true, detail: 'KPI DESHABILITADO — pendiente de verificar los informes de Cianbox. La autorización es manual.' };   // (= servidor)
    const last = c.ingests.filter(i => i.kind === 'SC' && i.status === 'OK').map(i => i.at).sort().pop() || null;
    const base = { months_cfg: s.kpi_months, last_update: last, provisional: !s.kpi_source_verified, label: s.kpi_source_verified ? null : 'RECOMENDACIÓN PROVISORIA — BASADA EN COMPROBANTES DISPONIBLES' };
    if (!cl.cuit) return { ...base, status: 'SIN_HISTORIAL', detail: 'El cliente no tiene CUIT/CUIL válido en el padrón: no se puede cruzar con las cargas de Depósito.' };
    if (!last) return { ...base, status: 'PENDIENTE_IMPORTACION', detail: 'Datos insuficientes / pendiente de importación de «Saldo comprobante».' };
    const m1 = addMonths(monthStart(ymd(new Date())), -1), ms = Array.from({ length: s.kpi_months }, (_, i) => addMonths(m1, i - s.kpi_months + 1));
    const months = ms.map(m => { const cov = this._comCovered(m); return { month: m, covered: cov, amount: cov ? this._comMonthSales(cl.cuit, m).amount : null }; });
    const cpend = ms.reduce((t, m) => t + this._comMonthSales(cl.cuit, m).pend, 0);
    const cov = months.filter(x => x.covered).length, tot = months.reduce((t, x) => t + (x.amount || 0), 0), excl = Object.values(c.docs).filter(d => d.cuit === cl.cuit && d.status !== 'OK').length;
    if (cov < s.kpi_months && !(s.kpi_partial_rule === 'PROMEDIO_MESES_CUBIERTOS' && cov > 0)) return { ...base, status: 'SIN_HISTORIAL', detail: 'SIN HISTORIAL SUFICIENTE · ' + cov + ' de ' + s.kpi_months + ' meses con cargas', coverage: cov, months, excluded_docs: excl };
    if (tot <= 0) return { ...base, status: 'SIN_HISTORIAL', detail: 'Sin compras registradas en los comprobantes disponibles.', coverage: cov, months, excluded_docs: excl };
    const avg = r2(tot / cov);
    return { ...base, status: cov < s.kpi_months ? 'PARCIAL' : 'OK', coverage: cov, months, average: avg, floor_pct: s.floor_pct, ceiling_pct: s.ceiling_pct, floor: r2(avg * s.floor_pct / 100), ceiling: r2(avg * s.ceiling_pct / 100), excluded_docs: excl + cpend,
      cuota_rule: s.cuota_rule, cuotas_por_confirmar: cpend,
      source: 'Historial automático de «Saldo comprobante» (cargas diarias de Depósito)', scope: 'Comprobantes disponibles en «Saldo comprobante»' };
  },
  async comKpi(clientId) { const me=await this._comMe(); if (!(this._comAdmin(me)||hasPerm(me,'com.request')||hasPerm(me,'com.approve'))) throw E('FORBIDDEN'); this._com(); return this._comKpi(clientId); },
  async comClientFinance(clientId) {
    const me = await this._comMe(); if (!(this._comAdmin(me) || hasPerm(me, 'com.approve'))) throw E('FORBIDDEN');
    const c = this._com(), cl = c.clients.find(x => x.id === clientId); if (!cl || !cl.cuit) return { status: 'SIN_CUIT' };
    const lcc = c.ingests.filter(i => i.kind === 'CC' && i.status === 'OK').pop(), b = lcc && c.cc.find(x => x.ingest === lcc.id && x.cuit === cl.cuit), lsc = c.ingests.filter(i => i.kind === 'SC' && i.status === 'OK').sort((a, z) => a.at.localeCompare(z.at)).pop();
    const ver = c.settings.cc_verificado ? 'VERIFICADO' : 'NO_VERIFICADO';   // punto 4 (= servidor): origen y verificación del saldo importado
    return { cc_verificacion: ver, pendientes_verificacion: ver, cc_fecha_corte: lcc ? (lcc.date_max || String(lcc.at).slice(0, 10)) : null, cc_archivo: lcc ? (lcc.file_name || null) : null, cc_carga: lcc ? lcc.id : null,
      cc_saldo: b ? b.saldo : null, cc_fecha: lcc ? lcc.at : null, cc_disponible: !!b, sc_fecha: lsc ? lsc.at : null,
      pendientes: Object.values(c.docs).filter(d => d.cuit === cl.cuit && lsc && d.last === lsc.id && (d.saldo || 0) > 0.004 && d.class === 'VENTA').map(d => ({ comprobante: d.comp, fecha: d.date, saldo: d.saldo })) };
  },
  // ---------- solicitudes ----------
  _comTerms(kind, t, cl, base) {
    const s = this.db.com.settings, a = r2(Number(t && t.amount));
    if (!(a > 0) || a > 999999999) throw E('BAD_AMOUNT', 'importe inválido');
    if (kind === 'FINANCIACION') {   // MISMA regla que el servidor (001200): calendario con primer vencimiento y frecuencia, tope de 30 días desde la creación
      const maxd = Math.min(s.fin_max_days, 30), k = /^[0-9]{1,3}$/.test(String(t.installments ?? '')) ? Number(t.installments) : NaN;
      let first = t.first_due, freq = t.frequency;
      if (!('first_due' in t)) {   // formato ANTERIOR: semanal desde el día 7, mismo error de siempre
        if (!(k >= 1) || k * 7 > maxd) throw E('BAD_INSTALLMENTS', 'cuotas semanales; el último vencimiento no puede superar ' + maxd + ' días');
        first = schedAddDays(base, 7); freq = k > 1 ? 'SEMANAL' : null;
      }
      const c = computeSchedule({ base, installments: k, frequency: freq, first_due: first, amount: a, maxDays: maxd });
      if (!c.ok) throw E(c.error.code, c.error.message);
      return { amount: a, installments: k, frequency: c.frequency, first_due: first, schedule: c.schedule, last_due: c.last_due, days: c.days, limit_date: c.limit, max_days: maxd };
    }
    const due = t.due_date; if (!due || due < base || due > addDays(base, s.cheq_max_days)) throw E('BAD_DUE_DATE', 'el vencimiento del e-cheq debe estar entre hoy y ' + s.cheq_max_days + ' días');
    const iname = String(t.issuer_name || '').trim(), icuit = digits(t.issuer_cuit);
    if (icuit && !cuitOk(icuit)) throw E('BAD_ISSUER_CUIT', 'el CUIT del emisor no es válido');
    const days = Math.round((new Date(due) - new Date(base)) / 864e5);
    if (!iname && !icuit) return { amount: a, due_date: due, days, issuer_is_client: true, issuer_name: cl.razon_social, issuer_cuit: cl.cuit };
    return { amount: a, due_date: due, days, issuer_is_client: false, issuer_name: iname || '(sin nombre)', issuer_cuit: icuit || null };
  },
  _comEvent(q, kind, reason, before, after, me) { const c = this.db.com, seq = c.events.filter(e => e.request_id === q.id).length + 1; c.events.push({ request_id: q.id, seq, kind, actor_id: me.id, actor_label: this._comName(me.id), assigned: q.assigned_approver_id, reason: reason || null, terms_before: before, terms_after: after, at: new Date().toISOString() }); return seq; },
  _comNotify(q, seq, userId, kind, title, body) { const c = this.db.com; if (!userId || c.notifs.some(n => n.user_id === userId && n.request_id === q.id && n.seq === seq)) return;
    c.notifs.push({ id: c.notifs.length + 1, user_id: userId, request_id: q.id, seq, kind, title, body, at: new Date().toISOString(), read: false });
    const u = (this.db.users || []).find(x => x.id === userId); c.emails.push({ request_id: q.id, seq, user_id: userId, recipient: u && u.email, subject: title, status: u && u.email ? 'PREPARADO' : 'SIN_CORREO' }); },
  async comCreate(kind, clientId, orderRef, terms, notes, opId) {
    const me = await this._comMe(), c = this._com(); if (!hasPerm(me, 'com.request')) throw E('FORBIDDEN', 'solo Comercial crea solicitudes');
    if (opId) { const q = c.requests.find(x => x.op_id === opId); if (q) { if(q.requested_by!==me.id) throw E('OP_ID_REUSED'); if(q.kind!==kind||q.client_id!==clientId||q.order_ref!==(String(orderRef||'').trim()||null)) throw E('OP_ID_MISMATCH'); return { id: q.id, number: q.number, status: q.status, repeated: true }; } }
    const a = c.assignments[me.id]; if (!a) throw E('NO_ASSIGNMENT', 'Administración todavía no te asignó sucursal o cartera');
    const key = a.channel === 'CARTERA' ? 'CARTERA' : 'SUCURSAL:' + a.branch, ap = c.routing[key], apu = (this.db.users || []).find(u => u.id === ap && u.status === 'ACTIVO');
    if (!apu) throw E('NO_APPROVER', 'no hay aprobador ACTIVO configurado para ' + key);
    const cl = c.clients.find(x => x.id === clientId); if (!cl) throw E('CLIENT_NOT_FOUND', 'CLIENTE NO ENCONTRADO');
    if (cl.status !== 'ACTIVO') throw E('CLIENT_IN_REVIEW', 'el cliente está pendiente de revisión (' + cl.review_reasons.join(', ') + ')');
    const t = this._comTerms(kind, terms, cl, arDate()), now = new Date().toISOString();   // fecha ARGENTINA de creación (= servidor)
    const q = { id: 'aut-' + (++c.seq), number: 'AUT-' + String(c.seq).padStart(6, '0'), kind, client_id: cl.id, client: { id: cl.id, erp_id: cl.erp_id, razon_social: cl.razon_social, nombre: cl.nombre, doc_type: cl.doc_type, doc_number: cl.doc_number, cuit: cl.cuit },
      channel: a.channel, branch: a.branch || null, cartera_label: a.cartera_label || null, requested_by: me.id, assigned_approver_id: ap, order_ref: String(orderRef || '').trim().slice(0, 60) || null, notes: String(notes || '').trim().slice(0, 600) || null,
      original_terms: t, current_terms: t, final_terms: null, kpi: kind === 'FINANCIACION' ? this._comKpi(cl.id) : { status: 'NO_APLICA' }, status: 'PENDIENTE', decided_by: null, decided_at: null, decided_as: null, version: 1, op_id: opId || null, created_at: now, updated_at: now };
    c.requests.push(q); this._comEvent(q, 'ENVIADA', null, null, t, me); const n = this._comEvent(q, 'PENDIENTE', null, null, null, me);
    this._comNotify(q, n, ap, 'NUEVA', 'Autorización ' + q.number + ' pendiente', (kind === 'FINANCIACION' ? 'Financiación propia' : 'Aceptación de e-cheq') + ' · ' + cl.razon_social);
    this._save(); return { id: q.id, number: q.number, status: q.status, approver: this._comName(ap), repeated: false };
  },
  async comDecide(id, version, decision, terms, reason) {
    const me = await this._comMe(), c = this._com(), q = c.requests.find(x => x.id === id); if (!q) throw E('NOT_FOUND');
    let as; if (q.assigned_approver_id === me.id && hasPerm(me, 'com.approve')) as = 'APROBADOR'; else if (this._comAdmin(me)) as = q.assigned_approver_id === me.id ? 'APROBADOR' : 'SUPLENTE_ADMIN'; else throw E('FORBIDDEN', 'no sos el aprobador asignado ni Administrador General activo');
    if (q.status !== 'PENDIENTE' || q.version !== version) throw E('CONFLICT', 'la solicitud ya fue resuelta o cambió (estado ' + q.status + ', por ' + (this._comName(q.decided_by) || '—') + ')');
    if (!['APROBAR', 'APROBAR_CON_CAMBIOS', 'RECHAZAR', 'DEVOLVER'].includes(decision)) throw E('BAD_DECISION');
    if (decision !== 'APROBAR' && String(reason || '').trim().length < 5) throw E('REASON_REQUIRED', 'indicá el motivo');
    const cl = c.clients.find(x => x.id === q.client_id), t = ['APROBAR_CON_CAMBIOS', 'DEVOLVER'].includes(decision) ? this._comTerms(q.kind, terms, cl, arDate(q.created_at))   /* fecha ARGENTINA de la creación ORIGINAL (= servidor) */ : q.current_terms;
    if (['APROBAR_CON_CAMBIOS', 'DEVOLVER'].includes(decision) && JSON.stringify(t) === JSON.stringify(q.current_terms)) throw E('NO_CHANGES', 'no hay cambios en importe, cuotas o plazo');
    const st = { APROBAR: 'APROBADA', APROBAR_CON_CAMBIOS: 'APROBADA_MOD', RECHAZAR: 'RECHAZADA', DEVOLVER: 'DEVUELTA' }[decision], before = q.current_terms;
    Object.assign(q, { status: st, current_terms: t, final_terms: ['APROBADA', 'APROBADA_MOD'].includes(st) ? t : null, decided_by: st === 'DEVUELTA' ? null : me.id, decided_at: st === 'DEVUELTA' ? null : new Date().toISOString(), decided_as: st === 'DEVUELTA' ? null : as, version: q.version + 1, updated_at: new Date().toISOString() });
    const ev = { APROBADA: 'APROBADA', APROBADA_MOD: 'APROBADA_CON_MODIFICACIONES', RECHAZADA: 'RECHAZADA', DEVUELTA: 'DEVUELTA_CON_MODIFICACIONES' }[st], n = this._comEvent(q, ev, String(reason || '').trim() || null, before, t, me);
    c.notifs.filter(x => x.request_id === q.id && x.kind === 'NUEVA').forEach(x => { x.read = true; });
    this._comNotify(q, n, q.requested_by, ev, 'Autorización ' + q.number + ' · ' + ev.replace(/_/g, ' '), 'Resuelta por ' + this._comName(me.id) + (as === 'SUPLENTE_ADMIN' ? ' (asignada a ' + this._comName(q.assigned_approver_id) + ')' : ''));
    if (as === 'SUPLENTE_ADMIN') this._comNotify(q, n, q.assigned_approver_id, 'RESUELTA_POR_SUPLENTE', 'Autorización ' + q.number + ' resuelta por ' + this._comName(me.id), ev);
    this._save(); return { id: q.id, status: st, decided_as: as, version: q.version };
  },
  async comRespond(id, version, accept, comment) {
    const me = await this._comMe(), c = this._com(), q = c.requests.find(x => x.id === id); if (!q || q.requested_by !== me.id || !hasPerm(me,'com.request')) throw E('FORBIDDEN');
    if (q.status !== 'DEVUELTA' || q.version !== version) throw E('CONFLICT', 'la solicitud no está devuelta o cambió');
    Object.assign(q, { status: accept ? 'PENDIENTE' : 'CANCELADA', version: q.version + 1, updated_at: new Date().toISOString() });
    let n = this._comEvent(q, accept ? 'CAMBIOS_ACEPTADOS_REENVIADA' : 'RETIRADA_POR_COMERCIAL', String(comment || '').trim() || null, null, accept ? q.current_terms : null, me);
    if (accept) { n = this._comEvent(q, 'PENDIENTE', null, null, null, me); this._comNotify(q, n, q.assigned_approver_id, 'NUEVA', 'Autorización ' + q.number + ' reenviada con los cambios aceptados', comment || ''); }
    this._save(); return { id: q.id, status: q.status, version: q.version };
  },
  _comView(q, full) {
    const ev = this.db.com.events.filter(e => e.request_id === q.id).sort((a, b) => a.seq - b.seq);
    return { id: q.id, number: q.number, kind: q.kind, status: q.status, client: q.client, order_ref: q.order_ref, channel: q.channel, branch: q.branch, cartera_label: q.cartera_label, requested_by: this._comName(q.requested_by),
      assigned_approver: this._comName(q.assigned_approver_id), assigned_approver_id: q.assigned_approver_id, decided_by: this._comName(q.decided_by), decided_as: q.decided_as, decided_at: q.decided_at, created_at: q.created_at, updated_at: q.updated_at,
      version: q.version, current_terms: q.current_terms, final_terms: q.final_terms, original_terms: full ? q.original_terms : null, notes: full ? q.notes : null, kpi: full ? (this.db.com.settings.kpi_mode === 'PROVISORIO' ? q.kpi : { status: 'DESHABILITADO', provisional: true, detail: 'KPI DESHABILITADO — pendiente de verificar los informes de Cianbox. La autorización es manual.' }) : null,
      timeline: ev.map(e => ({ seq: e.seq, kind: e.kind, by: e.actor_label, at: e.at, reason: full ? e.reason : null, assigned: this._comName(e.assigned), terms_after: full ? e.terms_after : null })) };
  },
  async comList(scope, status = null, limit = 30, offset = 0) {
    const me = await this._comMe(), c = this._com(), adm = this._comAdmin(me);
    if (scope === 'MIS' && !hasPerm(me, 'com.request')) throw E('FORBIDDEN'); if (scope === 'BANDEJA' && !(hasPerm(me, 'com.approve') || adm)) throw E('FORBIDDEN'); if (scope === 'TODAS' && !adm) throw E('FORBIDDEN');
    return c.requests.filter(q => (scope === 'MIS' ? q.requested_by === me.id : scope === 'BANDEJA' ? (q.assigned_approver_id === me.id || adm) : true) && (!status || q.status === status))
      .sort((a, b) => (a.status !== 'PENDIENTE') - (b.status !== 'PENDIENTE') || b.updated_at.localeCompare(a.updated_at)).slice(offset, offset + Math.min(limit, 100)).map(q => this._comView(q, true));
  },
  // «CONSULTAR APROBACIÓN» (= com_order_alerts): solicitudes de los pedidos de la hoja (la más reciente, salvo CANCELADA) y EN CURSO de sus clientes
  async comOrderAlerts(orders, cuits) {
    // LECTURA AISLADA: copia propia del almacenamiento, SIN reemplazar this.db (me()/_refresh() recargan la base compartida de la demo y pisaban
    // operaciones en curso, p. ej. la NOC de la ventana de publicación). Mismo ALCANCE y DEDUPLICACIÓN que com_order_alerts (auditoría B-01/B-02).
    this._net && this._net();   // permite simular sin conexión (O-01)
    const ses = await this.getSession(), snap = (this._load && this._load()) || this.db || {};
    const me = ses && (snap.users || []).find(u => u.id === ses.userId);
    if (!me || me.status !== 'ACTIVO') throw E('FORBIDDEN');
    const todas = me.role === 'ADMIN' || hasPerm(me, 'com.track'), aprob = hasPerm(me, 'com.approve'), propias = hasPerm(me, 'com.request');
    if (!(todas || aprob || propias)) throw E('FORBIDDEN');
    const O = new Set((orders || []).map(x => String(x || '').trim().toUpperCase()).filter(Boolean)), C = new Set((cuits || []).map(digits).filter(x => [7, 8, 11].includes(x.length)));
    if (O.size > 300 || C.size > 300) throw E('TOO_MANY', 'máximo 300 pedidos y 300 clientes por consulta');
    const ref = q => String(q.order_ref || '').trim().toUpperCase(), key = q => ref(q) || 'id:' + q.id;
    // 1) alcance por registro: todas (Administrador / Despacho), asignadas (aprobador), propias (Comercial)
    const scope = ((snap.com || {}).requests || []).filter(q => q.status !== 'CANCELADA' && (todas || (aprob && q.assigned_approver_id === me.id) || (propias && q.requested_by === me.id)));
    // 2) UNA política: la MÁS RECIENTE por número de pedido (fecha y, a igual fecha, número correlativo), para ambas coincidencias
    const best = {}; scope.forEach(q => { const b = best[key(q)]; if (!b || q.created_at > b.created_at || (q.created_at === b.created_at && q.number > b.number)) best[key(q)] = q; });
    return Object.values(best).filter(q => O.has(ref(q)) || (['PENDIENTE', 'DEVUELTA'].includes(q.status) && C.has(digits(q.client.cuit))))
      .sort((a, b) => b.created_at.localeCompare(a.created_at) || b.number.localeCompare(a.number))
      .map(q => ({ number: q.number, kind: q.kind, status: q.status, order_ref: q.order_ref, match: O.has(ref(q)) ? 'PEDIDO' : 'CLIENTE', client: q.client.razon_social, cuit: q.client.cuit,
        created_at: q.created_at, decided_at: q.decided_at, alert: ['PENDIENTE', 'DEVUELTA', 'RECHAZADA'].includes(q.status) ? 'CONSULTAR APROBACIÓN' : null,
        final_terms: ['APROBADA', 'APROBADA_MOD'].includes(q.status) ? q.final_terms : null }));
  },
  // ===== ALARMA URGENTE (demo) · mismas reglas que el servidor; el escalamiento usa el reloj, como el servidor (aquí: al consultar) =====
  // B-AL-03: SOLO la configuración EXPLÍCITA; nunca se amplía automáticamente a otros usuarios (= servidor)
  _alarmInitial() { const c = this.db.com, u = (this.db.users || []).find(x => x.id === (c.alarmCfg && c.alarmCfg.initial_user) && x.status === 'ACTIVO' && hasPerm(x, 'com.approve')); return u ? u.id : null; },
  _alarmEscalation() { const c = this.db.com; return ((c.alarmCfg && c.alarmCfg.escalation_users) || []).filter(id => (this.db.users || []).some(u => u.id === id && u.status === 'ACTIVO' && u.role === 'ADMIN' && !(u.disabled_modules || []).includes('COMERCIAL'))); },
  _alarmEvent(a, kind, actor, extra) { (this.db.com.alarmEvents = this.db.com.alarmEvents || []).push({ alarm_id: a.id, kind, actor_id: actor || null, at: new Date().toISOString(), ...(extra || {}) }); },
  _alarmNotify(a, userId, type, title, body, actor) { const c = this.db.com, n = { id: 'an-' + ((c.alarmNotifs || []).length + 1), user_id: userId, type, title, body, at: new Date().toISOString() };
    (c.alarmNotifs = c.alarmNotifs || []).push(n); this._alarmEvent(a, 'NOTIFICADO', actor, { recipient_id: userId, notification_id: n.id, tipo: type }); },
  _alarmEscalateDue() { const c = this.db.com, now = Date.now(); let n = 0;
    (c.alarms || []).filter(a => a.status === 'PENDIENTE_ATENCION' && !a.escalated_at && Date.parse(a.escalate_at) <= now).forEach(a => {
      a.escalated_at = new Date().toISOString(); a.escalated_to = this._alarmEscalation().filter(x => x !== a.initial_user); a.version++;
      if (!a.escalated_to.length) {   // sin ampliación: error registrado, aviso a Wilfredo y a quien la pidió; la alarma SIGUE pendiente
        this._alarmEvent(a, 'ESCALAMIENTO_SIN_DESTINATARIOS', null, { motivo: 'ningún destinatario de escalamiento configurado está ACTIVO' });
        [a.initial_user, a.raised_by].forEach(u => this._alarmNotify(a, u, 'COM_ALARMA_ESCALADA', 'ALARMA COMERCIAL SIN ESCALAMIENTO', 'Pedido ' + a.order_ref + ' · no hay destinatarios de escalamiento activos', null)); n++; return; }
      this._alarmEvent(a, 'ESCALADA', null, { destinatarios: a.escalated_to });
      a.escalated_to.forEach(u => this._alarmNotify(a, u, 'COM_ALARMA_ESCALADA', 'APROBACIÓN COMERCIAL URGENTE · ESCALADA', 'Pedido ' + a.order_ref + ' · sin atender en 3 minutos · tocá para ATENDER', null)); n++; });
    return n; },
  _alarmView(a, me) { const lab = id => this._comName(id); return { id: a.id, number: a.number, order_ref: a.order_ref, sheet_key: a.sheet_key, client: a.client_name, cuit: a.client_cuit, client_source: a.client_source,
    branch: a.branch, reason: a.reason, raised_by: lab(a.raised_by), raised_at: a.raised_at, initial_user: lab(a.initial_user), escalate_at: a.escalate_at, escalated_at: a.escalated_at,
    escalated_to: (a.escalated_to || []).map(lab), status: a.status, attended_by: lab(a.attended_by), attended_at: a.attended_at, seconds_to_attend: a.seconds_to_attend, version: a.version,
    request: a.request_id ? (() => { const q = this.db.com.requests.find(x => x.id === a.request_id); return q ? { id: q.id, number: q.number, status: q.status } : null; })() : null,
    ring: a.status === 'PENDIENTE_ATENCION' && (me.id === a.initial_user || (a.escalated_to || []).includes(me.id)) && hasPerm(me, 'com.approve'),
    can_attend: a.status === 'PENDIENTE_ATENCION' && !!this._alarmRole(a, me) && this._alarmRole(a, me) !== 'SOLICITANTE' }; },
  async comAlarmRaise(order, sheet, client, cuit, reason, opId) {
    this._net && this._net(); const me = await this._comMe(), c = this._com();
    if (!(hasPerm(me, 'com.track') || this._comAdmin(me))) throw E('FORBIDDEN');
    const ref = String(order || '').trim().toUpperCase(); if (!ref || !String(sheet || '').trim()) throw E('BAD_ORDER', 'indicá el pedido y la hoja');
    if (String(reason || '').trim().length < 10) throw E('REASON_REQUIRED', 'indicá el motivo (al menos 10 caracteres)');
    const RS = this.db.reservations || {}, res = Object.keys(RS).find(k => k.trim().toUpperCase() === ref && RS[k].sheet_key === sheet);
    if (!res) throw E('ORDER_NOT_IN_SHEET', 'el pedido no pertenece a esa hoja');
    c.alarms = c.alarms || []; c.alarmOps = c.alarmOps || {};
    // B-W02 (= servidor V4): el op_id es OBLIGATORIO y queda REGISTRADO con usuario, pedido, hoja y RESULTADO (también si devolvió la alarma ACTIVA).
    // Repetirlo devuelve el resultado guardado aunque la alarma ya fue atendida; reutilizarlo para otra operación se rechaza SIN datos y se registra.
    if (!opId) throw E('OP_ID_REQUIRED', 'falta el identificador de operación');
    const prev = c.alarmOps[opId];
    if (prev) {
      if (prev.user === me.id && prev.ref === ref && prev.sheet === sheet) return { ...prev.result, repeated: true };
      const x = c.alarms.find(a => a.id === prev.alarm_id); if (x) this._alarmEvent(x, 'OP_ID_REUTILIZADO_RECHAZADO', me.id, { op_id: opId, pedido_pedido: String(order).trim(), hoja_pedida: sheet });
      (this.db.auditLog = this.db.auditLog || []).push({ actor_id: me.id, action: 'COM_ALARM_OP_ID_REUSE', target_id: prev.alarm_id, at: new Date().toISOString() }); this._save();
      return { ok: false, code: 'OP_ID_CONFLICT', message: 'Ese identificador de operación ya se usó para otra operación. Reintentá desde la pantalla.' };
    }
    const act = c.alarms.find(a => a.status === 'PENDIENTE_ATENCION' && a.order_ref.trim().toUpperCase() === ref);
    if (act) {
      // alcance: quien NO puede ver esa alarma recibe una respuesta MÍNIMA (sin id ni número)
      const ve = !!this._alarmRole(act, me);
      const result = ve ? { id: act.id, number: act.number, status: act.status, existing: true } : { existing: true, status: 'PENDIENTE_ATENCION' };
      c.alarmOps[opId] = { user: me.id, ref, sheet, alarm_id: act.id, result };
      this._alarmEvent(act, 'DUPLICADA_EXISTENTE', me.id, { motivo: String(reason).trim(), op_id: opId }); this._save(); return { ...result, repeated: false };
    }
    const ini = this._alarmInitial(); if (!ini) throw E('ALARM_NOT_CONFIGURED', 'falta configurar (o no está activo) el destinatario inicial de la alarma. Avisá al Administrador General.');
    if (!this._alarmEscalation().length) throw E('ALARM_NOT_CONFIGURED', 'faltan destinatarios de escalamiento activos configurados. Avisá al Administrador General.');
    const q = c.requests.filter(x => x.status !== 'CANCELADA' && String(x.order_ref || '').trim().toUpperCase() === ref).sort((x, y) => y.created_at.localeCompare(x.created_at) || y.number.localeCompare(x.number))[0];
    const now = new Date(), a = { id: 'alr-' + (c.alarms.length + 1), number: 'ALR-' + String(c.alarms.length + 1).padStart(6, '0'), order_ref: String(order).trim(), sheet_key: sheet, request_id: q ? q.id : null,
      branch: q ? (q.branch || q.cartera_label) : null, client_name: q ? q.client.razon_social : String(client || '').slice(0, 160), client_cuit: q ? q.client.cuit : (digits(cuit) || null),
      client_source: q ? 'SOLICITUD_COMERCIAL' : 'DECLARADO_POR_DESPACHO', reason: String(reason).trim(), raised_by: me.id, raised_at: now.toISOString(), initial_user: ini,
      escalate_at: new Date(now.getTime() + 180000).toISOString(), escalated_at: null, escalated_to: [], status: 'PENDIENTE_ATENCION', attended_by: null, attended_at: null, op_id: opId || null, version: 1 };
    c.alarms.push(a); this._alarmEvent(a, 'CREADA', me.id, { pedido: a.order_ref, hoja: a.sheet_key, motivo: a.reason });
    c.alarmOps[opId] = { user: me.id, ref, sheet, alarm_id: a.id, result: { id: a.id, number: a.number, status: 'PENDIENTE_ATENCION', escalate_at: a.escalate_at } };
    this._alarmNotify(a, ini, 'COM_ALARMA', 'APROBACIÓN COMERCIAL URGENTE', 'Pedido ' + a.order_ref + ' · solicitada por ' + me.full_name + ' · tocá para ATENDER', me.id);
    this._save(); return { id: a.id, number: a.number, status: a.status, repeated: false, escalate_at: a.escalate_at };
  },
  async comAlarmAttend(id, version) {
    this._net && this._net(); const me = await this._comMe(), c = this._com(); this._alarmEscalateDue();
    const a = (c.alarms || []).find(x => x.id === id); if (!a) throw E('NOT_FOUND');
    const r0 = this._alarmRole(a, me), como = r0 === 'SOLICITANTE' ? null : r0;
    if (!como) { this._alarmEvent(a, 'INTENTO_ATENDER_RECHAZADO', me.id, { motivo: 'sin autorización' }); this._save(); return { ok: false, code: 'FORBIDDEN', message: 'No sos destinatario de esta alarma.' }; }
    if (a.status !== 'PENDIENTE_ATENCION') { this._save(); throw E('CONFLICT', 'la alarma ya fue atendida por ' + (this._comName(a.attended_by) || '—')); }   // O-AL-05: solo si ya fue atendida
    Object.assign(a, { status: 'ATENDIDA', attended_by: me.id, attended_at: new Date().toISOString(), attended_as: como, seconds_to_attend: Math.round((Date.now() - Date.parse(a.raised_at)) / 1000), version: a.version + 1 });
    this._alarmEvent(a, 'ATENDIDA', me.id, { como, segundos: a.seconds_to_attend, escalada: !!a.escalated_at });
    [a.raised_by, a.initial_user, ...(a.escalated_to || [])].filter((u, i, L) => u && u !== me.id && L.indexOf(u) === i).forEach(u => this._alarmNotify(a, u, 'COM_ALARMA_ATENDIDA', 'Alarma comercial ATENDIDA', 'Pedido ' + a.order_ref + ' · atendida por ' + me.full_name, me.id));
    this._save(); return { ok: true, id: a.id, number: a.number, status: a.status, attended_as: como, seconds_to_attend: a.seconds_to_attend, request_id: a.request_id };
  },
  async comMyAlarms() {
    this._net && this._net(); const me = await this._comMe(), c = this._com(); if (this._alarmEscalateDue()) this._save();
    const cut = Date.now() - 12 * 3600e3;
    return (c.alarms || []).filter(a => (a.status === 'PENDIENTE_ATENCION' || Date.parse(a.attended_at || 0) > cut) && !!this._alarmRole(a, me))
      .sort((x, y) => y.raised_at.localeCompare(x.raised_at)).map(a => this._alarmView(a, me));
  },
  async comAlarmHistory(from, to) {
    const me = await this._comMe(), c = this._com(); if (!this._comAdmin(me)) throw E('FORBIDDEN');
    return (c.alarms || []).filter(a => arDay(a.raised_at) >= from && arDay(a.raised_at) <= to).map(a => ({ ...this._alarmView(a, me),
      resolucion_comercial: a.request_id ? (() => { const q = c.requests.find(x => x.id === a.request_id); return q ? { estado: q.status, resolvio: this._comName(q.decided_by), cuando: q.decided_at } : null; })() : null,
      eventos: (c.alarmEvents || []).filter(e => e.alarm_id === a.id).map(e => ({ kind: e.kind, at: e.at, actor: this._comName(e.actor_id), destinatario: this._comName(e.recipient_id), push: e.notification_id ? 'DEMO (sin envío real)' : null, detalle: e })) }));
  },
  async comAlarmSettings() {
    const me = await this._comMe(), c = this._com(); if (!this._comAdmin(me)) throw E('FORBIDDEN'); const cfg = c.alarmCfg || { initial_user: null, escalation_users: [] }, pr = [];
    if (!cfg.initial_user) pr.push('Falta el destinatario inicial (la alarma no se puede pedir).'); else if (!this._alarmInitial()) pr.push('El destinatario inicial guardado NO está activo o no tiene permiso de aprobación.');
    if (!cfg.escalation_users.length) pr.push('Faltan destinatarios de escalamiento (la alarma no se puede pedir).');
    else if (this._alarmEscalation().length < cfg.escalation_users.length) pr.push('Algún destinatario de escalamiento guardado NO está activo: no se reemplaza automáticamente.');
    return { initial_user: cfg.initial_user, escalation_users: cfg.escalation_users.slice(), efectivos: { inicial: this._comName(this._alarmInitial()), escalamiento: this._alarmEscalation().map(id => this._comName(id)) },
      guardados: cfg.escalation_users.map(id => ({ id, nombre: this._comName(id), activo: (this.db.users || []).some(u => u.id === id && u.status === 'ACTIVO') })), problemas: pr, escala_en_segundos: 180 };
  },
  async comSetAlarmSettings(p) {
    const me = await this._comMe(), c = this._com(); if (!this._comAdmin(me)) throw E('FORBIDDEN'); const U = this.db.users || [];
    const ini = (p && p.initial_user) || null, esc = [...new Set((p && p.escalation_users) || [])];
    if (!ini || !esc.length) throw E('INCOMPLETE', 'elegí el destinatario inicial y al menos un destinatario de escalamiento');
    if (!U.some(u => u.id === ini && u.status === 'ACTIVO' && hasPerm(u, 'com.approve'))) throw E('BAD_RECIPIENT', 'el destinatario inicial debe estar ACTIVO y tener permiso de aprobación');
    if (esc.some(id => !U.some(u => u.id === id && u.status === 'ACTIVO' && u.role === 'ADMIN'))) throw E('BAD_RECIPIENT', 'el escalamiento solo puede dirigirse a Administradores Generales ACTIVOS');
    (this.db.auditLog = this.db.auditLog || []).push({ actor_id: me.id, action: 'COM_ALARM_SETTINGS', before: c.alarmCfg || null, after: { initial_user: ini, escalation_users: esc }, at: new Date().toISOString() });
    c.alarmCfg = { initial_user: ini, escalation_users: esc }; this._save(); return this.comAlarmSettings();
  },
  async comAlarmByNotification(nid) {
    const me = await this._comMe(), c = this._com(); if (this._alarmEscalateDue()) this._save();
    const e = (c.alarmEvents || []).find(x => x.notification_id === nid && x.recipient_id === me.id); if (!e) return null;
    const a = (c.alarms || []).find(x => x.id === e.alarm_id); return a && this._alarmRole(a, me) ? this._alarmView(a, me) : null;   // N-V4-01
  },
  // ===== V4 · historial completo (= com_history / com_request_detail): alcance en el «servidor» de la demo, filtros y cursor estable =====
  async comHistory(scope, filters, cursor, limit) {
    const me = await this._comMe(), c = this._com(), adm = this._comAdmin(me), f = filters || {}, lim = Math.max(1, Math.min(Number(limit) || 25, 100));
    if (!['MIS', 'BANDEJA', 'TODAS'].includes(scope)) throw E('BAD_SCOPE');
    if ((scope === 'MIS' && !hasPerm(me, 'com.request')) || (scope === 'BANDEJA' && !(hasPerm(me, 'com.approve') || adm)) || (scope === 'TODAS' && !adm)) throw E('FORBIDDEN');
    if (cursor && (typeof cursor.c !== 'string' || typeof cursor.i !== 'string')) throw E('BAD_CURSOR');
    const norm = x => String(x || '').normalize('NFD').replace(/[\u0300-\u036f]/g, '').toUpperCase(), qq = norm(f.q), qd = digits(f.q), st = Array.isArray(f.status) && f.status.length ? f.status : null;
    const key = q => [q.created_at, q.id], lt = (a, b) => a[0] < b[0] || (a[0] === b[0] && a[1] < b[1]);
    const L = c.requests.filter(q => ((scope === 'MIS' && q.requested_by === me.id) || (scope === 'BANDEJA' && (q.assigned_approver_id === me.id || adm)) || (scope === 'TODAS' && adm))
      && (!cursor || lt(key(q), [cursor.c, cursor.i]))
      && (!f.q || norm(q.client.razon_social).includes(qq) || norm(q.client.nombre).includes(qq) || (qd.length >= 3 && digits(q.client.cuit).includes(qd)))
      && (!f.order_ref || String(q.order_ref || '').toUpperCase().includes(String(f.order_ref).trim().toUpperCase()))
      && (!f.number || q.number.toUpperCase().includes(String(f.number).trim().toUpperCase()))
      && (!f.from || arDay(q.created_at) >= f.from) && (!f.to || arDay(q.created_at) <= f.to)   // N-V4-05: día operativo argentino
      && (!st || st.includes(q.status)) && (!f.kind || q.kind === f.kind))
      .sort((a, b) => (b.created_at.localeCompare(a.created_at)) || (b.id.localeCompare(a.id)));
    const page = L.slice(0, lim);
    return { items: page.map(q => ({ id: q.id, number: q.number, kind: q.kind, status: q.status, order_ref: q.order_ref, client: q.client.razon_social, cuit: q.client.cuit,
      amount: (q.original_terms || q.current_terms || {}).amount, created_at: q.created_at, updated_at: q.updated_at || q.created_at, assigned_approver: this._comName(q.assigned_approver_id) })),
      has_more: L.length > lim, page_size: lim, next_cursor: L.length > lim ? { c: page[lim - 1].created_at, i: page[lim - 1].id } : null };
  },
  async comRequestDetail(id) {
    const me = await this._comMe(), c = this._com(), q = c.requests.find(x => x.id === id);
    // «no existe» y «no es tuya» responden IGUAL (no revela existencia)
    if (!q || !((q.requested_by === me.id && hasPerm(me, 'com.request')) || (q.assigned_approver_id === me.id && hasPerm(me, 'com.approve')) || this._comAdmin(me))) throw E('FORBIDDEN');
    return this._comView(q, true);
  },
  async comMyAlarmsPage(limit) {
    const all = await this.comMyAlarms(), lim = Math.max(1, Math.min(Number(limit) || 20, 50));
    const ord = all.slice().sort((a, b) => ((b.status === 'PENDIENTE_ATENCION') - (a.status === 'PENDIENTE_ATENCION')) || b.raised_at.localeCompare(a.raised_at));
    return { items: ord.slice(0, lim), total_pending: all.filter(a => a.status === 'PENDIENTE_ATENCION').length, has_more: all.length > lim, page_size: lim };
  },
  async comAlarmHistoryPage(from, to, cursor, limit) {
    const all = (await this.comAlarmHistory(from || '0000-01-01', to || '9999-12-31')).sort((a, b) => b.raised_at.localeCompare(a.raised_at) || b.id.localeCompare(a.id));
    const lim = Math.max(1, Math.min(Number(limit) || 25, 100)), rest = cursor ? all.filter(a => a.raised_at < cursor.c || (a.raised_at === cursor.c && a.id < cursor.i)) : all, page = rest.slice(0, lim);
    return { items: page, has_more: rest.length > lim, page_size: lim, next_cursor: rest.length > lim ? { c: page[lim - 1].raised_at, i: page[lim - 1].id } : null };
  },
  async comSetKpiMode(mode, autorizacion) { const me = await this._comMe(), c = this._com(); if (!this._comAdmin(me)) throw E('FORBIDDEN'); if (!['PROVISORIO', 'DESHABILITADO'].includes(mode)) throw E('BAD_MODE');
    if (mode === 'PROVISORIO' && String(autorizacion || '').trim().length < 20) throw E('AUTORIZACION_REQUERIDA', 'indicá la referencia a la autorización expresa de Dirección General para reactivar el KPI');
    (this.db.auditLog = this.db.auditLog || []).push({ actor_id: me.id, action: 'COM_KPI_MODE', before: c.settings.kpi_mode || 'DESHABILITADO', after: mode, autorizacion: autorizacion || null, at: new Date().toISOString() });
    c.settings.kpi_mode = mode; this._save(); return { kpi_mode: mode }; },
  async comAlarmPushStatus() { const me = await this._comMe(), c = this._com(); if (!this._comAdmin(me)) throw E('FORBIDDEN'); const cfg = c.alarmCfg || { escalation_users: [] };
    return [cfg.initial_user && { rol: 'INICIAL', usuario: this._comName(cfg.initial_user), dispositivos_activos: 0 }, ...(cfg.escalation_users || []).map(u => ({ rol: 'ESCALAMIENTO', usuario: this._comName(u), dispositivos_activos: 0 }))].filter(Boolean); },
  async comMyPushDevices() { await this._comMe(); return { activos: 0, demo: true }; },
  async comTrack(q0, openOnly = false, limit = 20, offset = 0) {
    const me = await this._comMe(), c = this._com(); if (!(hasPerm(me, 'com.track') || this._comAdmin(me))) throw E('FORBIDDEN');
    const n = norm(q0), d = digits(q0);
    return c.requests.filter(q => (!openOnly || ['PENDIENTE', 'DEVUELTA'].includes(q.status)) && (!String(q0 || '').trim() || norm(q.client.razon_social).includes(n) || norm(q.client.nombre).includes(n)
      || (d.length >= 3 && (String(q.client.cuit || '').includes(d) || String(q.client.doc_number || '').includes(d))) || norm(q.order_ref).includes(n) || q.number.toUpperCase().includes(String(q0).toUpperCase())))
      .sort((a, b) => b.updated_at.localeCompare(a.updated_at)).slice(offset, offset + Math.min(limit, 50))
      .map(q => this._comView(q, q.requested_by === me.id || q.assigned_approver_id === me.id || this._comAdmin(me)));
  },
  async comNotifications() { const me = await this._comMe(), c = this._com(); return c.notifs.filter(n => n.user_id === me.id).slice().reverse().slice(0, 50); },
  async comSetSettings(p) { const me = await this._comMe(); if (!this._comAdmin(me)) throw E('FORBIDDEN'); const c = this._com();
    const s = { ...c.settings, ...Object.fromEntries(Object.entries(p || {}).filter(([k]) => k in c.settings && k !== 'email_enabled')) };
    if (![1, 2, 3, 6].includes(Number(s.kpi_months)) || !(Number(s.ceiling_pct) >= Number(s.floor_pct)) || Number(s.floor_pct) < 50) throw E('BAD_SETTINGS', 'parámetros inválidos');
    c.settings = { ...s, kpi_months: Number(s.kpi_months), floor_pct: Number(s.floor_pct), ceiling_pct: Number(s.ceiling_pct) }; this._save(); return c.settings; },
  async comSetRouting(key, userId) { const me = await this._comMe(); if (!this._comAdmin(me)) throw E('FORBIDDEN'); const c = this._com(), u = (this.db.users || []).find(x => x.id === userId);
    if (userId && !(u && u.status === 'ACTIVO' && hasPerm(u, 'com.approve'))) throw E('BAD_APPROVER', 'el aprobador debe estar ACTIVO y tener permiso de aprobación');
    if (!(key in c.routing)) throw E('BAD_CHANNEL'); c.routing[key] = userId || null; this._save(); return { channel_key: key, approver: this._comName(userId) }; },
  async comSetAssignment(userId, channel, branch, cartera) { const me = await this._comMe(); if (!this._comAdmin(me)) throw E('FORBIDDEN'); const c = this._com(), u = (this.db.users || []).find(x => x.id === userId);
    if (!u || u.role !== 'COMERCIAL') throw E('NOT_COMERCIAL', 'el usuario no tiene rol Comercial');
    c.assignments[userId] = channel === 'CARTERA' ? { channel, cartera_label: String(cartera || '').trim() || null } : { channel: 'SUCURSAL', branch }; this._save(); return { user_id: userId, channel }; },
  async comSetCompType(prefix, cls) { const me = await this._comMe(); if (!this._comAdmin(me)) throw E('FORBIDDEN'); const c = this._com(), p = String(prefix).toUpperCase(); c.compTypes[p] = cls;
    Object.values(c.docs).filter(d => d.prefix === p).forEach(d => { d.class = cls; if (d.status === 'SIN_CLASIFICAR') d.status = d.amount == null ? 'SIN_IMPORTE' : !d.date ? 'SIN_FECHA' : 'OK'; });
    c.issues.filter(i => i.kind === 'TIPO_SIN_CLASIFICAR' && i.detail.prefijo === p).forEach(i => { i.status = 'RESUELTA'; }); this._save(); return { prefix: p, class: cls }; },
  async comSourcesStatus() { const me = await this._comMe(); if (!this._comAdmin(me)) throw E('FORBIDDEN'); const c = this._com(), ok = k => c.ingests.filter(i => i.kind === k && i.status === 'OK').sort((a, z) => a.at.localeCompare(z.at)).pop();
    const sc = ok('SC'), cc = ok('CC'), inc = {}; c.issues.filter(i => i.status === 'ABIERTA').forEach(i => { inc[i.kind] = (inc[i.kind] || 0) + 1; });
    const m1 = addMonths(monthStart(ymd(new Date())), -1);
    return { ultima_sc: sc && { at: sc.at, archivo: sc.file_name, stats: sc.stats }, ultima_cc: cc && { at: cc.at, archivo: cc.file_name }, errores: c.ingests.filter(i => i.status === 'ERROR').slice(-10).reverse().map(i => ({ at: i.at, kind: i.kind, archivo: i.file_name, error: i.error })),
      meses_cubiertos: Array.from({ length: 12 }, (_, i) => addMonths(m1, -i)).filter(m => this._comCovered(m)).sort(), incidencias: inc, tipos: Object.entries(c.compTypes).map(([prefijo, clase]) => ({ prefijo, clase })),
      clientes_sin_historial: c.clients.filter(x => x.status === 'ACTIVO' && (!x.cuit || !Object.values(c.docs).some(d => d.cuit === x.cuit))).length, source_verified: c.settings.kpi_source_verified };
  },
  async comReport(from, to) {
    const me = await this._comMe(); if (!this._comAdmin(me)) throw E('FORBIDDEN'); const c = this._com(), R = c.requests.filter(q => arDay(q.created_at) >= from && arDay(q.created_at) <= to);
    const grp = (f, map) => Object.values(R.reduce((a, q) => { const k = f(q); (a[k] = a[k] || { key: k, items: [] }).items.push(q); return a; }, {})).map(map);
    const amt = (L, k) => r2(L.reduce((t, q) => t + Number((q[k] || {}).amount || 0), 0));
    return { por_tipo_estado: grp(q => q.kind + '|' + q.status, g => ({ tipo: g.items[0].kind, estado: g.items[0].status, cantidad: g.items.length, solicitado: amt(g.items, 'original_terms'), autorizado: amt(g.items, 'final_terms') })),
      por_aprobador: grp(q => (q.assigned_approver_id || '') + '|' + (q.decided_by || '') + '|' + (q.decided_as || ''), g => ({ asignado: this._comName(g.items[0].assigned_approver_id), resuelto_por: this._comName(g.items[0].decided_by), como: g.items[0].decided_as, cantidad: g.items.length,
        horas_promedio: g.items[0].decided_at ? r2(g.items.reduce((t, q) => t + (new Date(q.decided_at) - new Date(q.created_at)) / 36e5, 0) / g.items.length) : null })),
      por_canal: grp(q => q.channel + '|' + (q.branch || q.cartera_label || ''), g => ({ canal: g.items[0].channel, sucursal: g.items[0].branch, cartera: g.items[0].cartera_label, cantidad: g.items.length, autorizado: amt(g.items, 'final_terms') })),
      por_cliente: grp(q => q.client.razon_social, g => ({ cliente: g.key, cantidad: g.items.length, solicitado: amt(g.items, 'original_terms'), autorizado: amt(g.items, 'final_terms') })),
      por_mes: grp(q => q.created_at.slice(0, 7), g => ({ mes: g.key, cantidad: g.items.length, solicitado: amt(g.items, 'original_terms'), autorizado: amt(g.items, 'final_terms') })),
      modificaciones: R.filter(q => q.status === 'APROBADA_MOD' || c.events.some(e => e.request_id === q.id && e.kind === 'DEVUELTA_CON_MODIFICACIONES')).length,
      vencimientos: R.filter(q => ['APROBADA', 'APROBADA_MOD'].includes(q.status)).map(q => ({ numero: q.number, cliente: q.client.razon_social, tipo: q.kind, importe: q.final_terms.amount, vence: q.final_terms.last_due || q.final_terms.due_date })),
      concretado: 'Sin fuente que acredite la concreción (pago o e-cheq recibido): no se informa.', score_externo: 'XFact/Veraz: integración FUTURA. No se consulta ningún servicio externo.' };
  },
  // despachos por transportista y zona: SOLO con las hojas reales existentes (sin inventar destinos ni métricas)
  async comDispatchStats(from, to) {
    const me = await this._comMe(); if (!this._comAdmin(me)) throw E('FORBIDDEN'); this._refresh();
    const R = (this.db.routes2 || []).filter(r => r.published_at && arDay(r.published_at) >= from && arDay(r.published_at) <= to), by = {};
    R.forEach(r => (r.stops || []).filter(s => (s.stop_type || 'PEDIDO') === 'PEDIDO').forEach(s => { const k = (r.carrier_name || r.carrier_id) + '|' + (s.zone || 'SIN ZONA'); by[k] = by[k] || { transportista: r.carrier_name || r.carrier_id, zona: s.zone || 'SIN ZONA', hojas: new Set(), paradas: 0, entregadas: 0 }; by[k].hojas.add(r.id); by[k].paradas++; if (s.outcome === 'ENTREGADO') by[k].entregadas++; }));
    return Object.values(by).map(x => ({ ...x, hojas: x.hojas.size })).sort((a, b) => b.paradas - a.paradas);
  },
  async comImportClients(fileName, sha, rows) { const me = await this._comMe(); if (!this._comAdmin(me)) throw E('FORBIDDEN', 'solo el Administrador General importa el padrón'); const c = this._com(); let nuevos = 0, act = 0, igual = 0; const rej = [];
    for (const r of rows || []) { if (!String(r.erp_id || '').trim() || !String(r.razon_social || '').trim()) { rej.push({ fila: r._row, motivo: 'SIN ID O SIN RAZÓN SOCIAL' }); continue; }
      const row = this._comClientRow(String(r.erp_id).trim(), String(r.razon_social).trim(), r.nombre, String(r.doc_type || '').toUpperCase(), r.doc_number, r.localidad), cur = c.clients.find(x => x.erp_id === row.erp_id);
      if (!cur) { c.clients.push(row); nuevos++; } else if (JSON.stringify([cur.razon_social, cur.doc_number, cur.doc_type]) === JSON.stringify([row.razon_social, row.doc_number, row.doc_type])) igual++; else { Object.assign(cur, { ...row, id: cur.id }); act++; } }
    this._comReviews(); this._save(); return { filas: (rows || []).length, nuevos, actualizados: act, sin_cambios: igual, rechazados: rej.length, en_revision: c.clients.filter(x => x.status === 'REVISION').length, total: c.clients.length }; }
};
