// RC2 · Administración: navegación clara + DASHBOARD, BORRADORES, HOJAS PUBLICADAS / HISTORIAL, CONFIGURACIÓN, AUDITORÍA y BACKUP.
// Misma estética (negro, blanco, cyan). Toda acción la valida el servidor; la interfaz solo muestra lo autorizado.
import { esc } from './util.js';
import { hasPerm, ROLE_LABEL } from '../../supabase/functions/_shared/rules.js';
import { DEFAULT_COLUMNS, moduleOfAction } from './demo-admin.js';
import { zipStore, b64ToBytes, sha256Hex } from './zip.js';
import { isRc4, appFrame, roleTopNav, openDashboardAdmin, openDashboardSupervisor, openDashboardOperario, mileageBlock } from './rc4-ui.js';

const fmt = n => Number(n || 0).toLocaleString('es-AR');
const dt = iso => iso ? new Date(iso).toLocaleString('es-AR', { timeZone: 'America/Argentina/Mendoza', day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' }) : '—';
const ST = { PUBLICADA: 'PUBLICADA', EN_CURSO: 'EN CURSO', COMPLETADA: 'FINALIZADA', CANCELADA: 'CANCELADA' };
const AP = { PENDIENTE: 'PENDIENTE DE APROBACIÓN', APROBADA: 'APROBADA', OBSERVADA: 'OBSERVADA', NO_REQUERIDA: '' };

export const NAV = [
  ['#/dashboard', 'DASHBOARD', me => hasPerm(me, 'users.view') || hasPerm(me, 'settings.manage')],
  ['#/despacho', 'DESPACHO', me => hasPerm(me, 'routes.create')],
  ['#/borradores', 'BORRADORES', me => hasPerm(me, 'routes.create')],
  ['#/historial', 'HOJAS PUBLICADAS', me => hasPerm(me, 'routes.view_all') || hasPerm(me, 'routes.view_team') || hasPerm(me, 'routes.view_own')],
  ['#/aprobaciones', 'APROBACIONES', me => hasPerm(me, 'can_approve_internal_route_changes')],
  ['#/usuarios', 'USUARIOS', me => hasPerm(me, 'users.view')],
  ['#/configuracion', 'CONFIGURACIÓN', me => hasPerm(me, 'settings.manage') || hasPerm(me, 'carriers.manage') || hasPerm(me, 'vehicles.manage') || hasPerm(me, 'vehicles.service_manage') || hasPerm(me, 'columns.manage_defaults') || hasPerm(me, 'columns.manage_templates')],
  ['#/informes', 'INFORMES', me => hasPerm(me, 'can_view_commercial_transport_reports') || hasPerm(me, 'can_manage_commercial_transport_reports')],
  ['#/conciliacion-noc', 'CONCILIACIÓN NOC', me => hasPerm(me, 'credit_notes.manage')],
  ['#/auditoria', 'AUDITORÍA', me => hasPerm(me, 'audit.view')],
  ['#/backup', 'BACKUP', me => hasPerm(me, 'settings.manage') || hasPerm(me, 'backup.manage')]
];
export function navHtml(me, active) {
  if (isRc4(me)) return roleTopNav(me, active);   // RC4: navegación por rol (Admin General / Superior / Operario)
  return '<nav class="adnav" id="adNav">' + NAV.filter(n => n[2](me)).map(([h, l]) => '<a href="' + h + '" class="' + (h === active ? 'on' : '') + '" data-nav="' + h + '">' + l + '</a>').join('') + '</nav>';
}
// Marco común de los módulos: encabezado + navegación + contenido
function frame(me, title, active) {
  if (isRc4(me)) return appFrame(me, title, active);   // RC4: menú lateral (diseño V4 / V2 aprobado)
  const el = document.getElementById('usersPanel'); el.hidden = false;
  el.innerHTML = '<header class="top"><img class="brandtile" src="/icons/icon-192.png?v=20261019" alt="OK Accesorios"><div class="ttl"><b>DESPACHO</b><span>' + esc(title) + '</span></div><div class="sp"></div>' +
    '<span class="who-chip">' + esc(me.full_name) + ' · <b>' + esc(ROLE_LABEL[me.role] || me.role) + '</b></span><button class="tbtn" type="button" id="adLogout">Cerrar sesión</button></header>' + navHtml(me, active) + '<div class="up-wrap ad-wrap" id="adBody"></div>';
  el.querySelector('#adLogout').onclick = () => window.OKD_LOGOUT && window.OKD_LOGOUT();
  return el.querySelector('#adBody');
}
const msgBox = (w, m) => { if (!m) return; const d = document.createElement('div'); d.className = 'up-msg ' + (m.err ? 'err' : 'ok'); d.id = 'adMsg'; d.textContent = m.text; w.prepend(d); };
const run = async (fn, ok, after) => { try { await fn(); after({ text: ok }); } catch (e) { after({ err: true, text: e.message }); } };
function download(name, text, type = 'application/json') { const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob([text], { type })); a.download = name; document.body.appendChild(a); a.click(); setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 1500); }

// ================= DASHBOARD =================
export async function openDashboard(api, me) {
  if (me.role === 'ADMIN') return openDashboardAdmin(api, me);
  if (me.role === 'SUPERVISOR_DESPACHO') return openDashboardSupervisor(api, me);
  if (me.role === 'OPERARIO_DEPOSITO') return openDashboardOperario(api, me);
  const w = frame(me, 'Dashboard', '#/dashboard');
  let s = {}; try { s = await api.dashboardSummary(); } catch (e) { msgBox(w, { err: true, text: e.message }); }
  const tiles = NAV.filter(n => n[0] !== '#/dashboard' && n[2](me)).map(([h, l]) => '<a class="dtile" href="' + h + '">' + l + '</a>').join('');
  const al = [
    ['drafts_stale', 'borradores antiguos', '#/borradores'], ['reserved_orders', 'pedidos reservados en borradores', '#/borradores'], ['approvals', 'aprobaciones pendientes', '#/aprobaciones'],
    ['returns', 'devoluciones pendientes', '#/historial'], ['service_due', 'vehículos con ⚠ SERVICE REQUERIDO', '#/configuracion'], ['email_errors', 'emails con error', '#/configuracion'],
    ['pdf_errors', 'PDF pendientes', '#/historial'], ['incidents_today', 'incidencias de hoy', '#/historial'], ['active_routes', 'rutas activas', '#/historial']
  ].map(([k, l, h]) => '<a class="dalert' + (Number(s[k]) > 0 && !['active_routes', 'reserved_orders'].includes(k) ? ' hot' : '') + '" href="' + h + '" data-k="' + k + '"><b>' + fmt(s[k]) + '</b><span>' + l + '</span></a>').join('');
  w.innerHTML = '<div class="up-head"><h2>DASHBOARD</h2></div><div class="dtiles">' + tiles + '</div><h3 class="dsub">ALERTAS</h3><div class="dalerts">' + al + '</div>' +
    ((s.service_list || []).length ? '<div class="up-msg err" id="dashService">⚠ SERVICE REQUERIDO: ' + s.service_list.map(esc).join(' · ') + '</div>' : '') +
    '<p class="rp-note">La preparación de cada hoja (LISTO / ADVERTENCIAS / REVISAR) se ve en DESPACHO al publicar.</p>';
}

// ================= BORRADORES =================
export async function openDrafts(api, me) {
  const w = frame(me, 'Borradores', '#/borradores');
  const render = async m => {
    let list = []; try { list = await api.listDrafts(); } catch (e) { m = { err: true, text: e.message }; }
    w.innerHTML = '<div class="up-head"><h2>BORRADORES</h2><span class="rp-note">' + (hasPerm(me, 'routes.manage_all_drafts') ? 'Todos los borradores activos' : 'Tus borradores activos') + '</span></div>' +
      (list.length ? '<div class="utable-wrap"><table class="utable" id="draftsTable"><thead><tr><th>HOJA</th><th>TRANSPORTISTA</th><th>OPERADOR</th><th>ENTREGAS</th><th>PEDIDOS RESERVADOS</th><th>CREADO</th><th>MODIFICADO</th><th>ESTADO</th><th>ACCIONES</th></tr></thead><tbody>' +
        list.map(d => '<tr data-key="' + esc(d.client_sheet_key) + '"><td><b>' + esc(d.name || 'Hoja') + '</b></td><td>' + esc(d.carrier_name || '—') + '</td><td>' + esc(d.owner_name || '') + '</td><td>' + d.delivery_count + '</td>' +
          '<td><details><summary>' + d.reserved.length + ' pedido(s)</summary>' + esc(d.reserved.join(', ') || '—') + '</details></td><td>' + dt(d.created_at) + '</td><td>' + dt(d.updated_at) + '</td><td><span class="ust INVITACION_PENDIENTE">BORRADOR</span></td>' +
          '<td><div class="uact"><button class="btn soft" type="button" data-open>ABRIR BORRADOR</button><button class="btn soft" type="button" data-ren>RENOMBRAR</button>' +
          '<button class="btn soft" type="button" data-rel>LIBERAR PEDIDOS</button><button class="btn danger" type="button" data-del>ELIMINAR BORRADOR</button></div></td></tr>').join('') + '</tbody></table></div>'
        : '<p class="rp-empty" id="draftsEmpty">No hay borradores activos.</p>') +
      '<p class="rp-note">Eliminar un borrador libera sus pedidos al instante. Las hojas publicadas, el historial y los correlativos no se tocan.</p>';
    msgBox(w, m);
    w.querySelectorAll('tr[data-key]').forEach(tr => {
      const key = tr.dataset.key, d = list.find(x => x.client_sheet_key === key);
      tr.querySelector('[data-open]').onclick = async () => {
        try { const c = await api.draftContent(key); location.hash = '#/despacho'; await waitLegacy(); await window.OKD_LEGACY.openDraft(key, (c && c.name) || d.name, c && c.content); }
        catch (e) { render({ err: true, text: e.message }); }
      };
      tr.querySelector('[data-ren]').onclick = () => { const n = prompt('Nuevo nombre del borrador', d.name || ''); if (n && n.trim()) run(() => api.touchDraft(key, n.trim(), d.carrier_name, d.delivery_count, d.orders, undefined), 'Borrador renombrado.', render); };
      tr.querySelector('[data-rel]').onclick = () => { if (confirm('¿Liberar los pedidos reservados de este borrador?')) run(() => api.releaseOrders(key, null), 'Pedidos liberados: quedan disponibles para otra hoja.', render); };
      tr.querySelector('[data-del]').onclick = async () => {
        if (!confirm('¿Eliminar el borrador "' + (d.name || '') + '" y liberar sus pedidos?')) return;
        try {
          const n = await api.deleteDraft(key);
          if (window.OKD_LEGACY) await window.OKD_LEGACY.dropLocal(key);
          render({ text: Number(n) === -1 ? 'Corrección descartada. La hoja publicada original quedó intacta.' : 'Borrador eliminado y pedidos liberados.' });
        } catch (e) { render({ err: true, text: e.message }); }
      };
    });
  };
  await render();
}
// Hoja publicada en pantalla: columnas de la plantilla con flag "pantalla" (snapshot)
function screenTable(m) {
  if (!m || !m.head) return '';
  return '<h3 class="dsub">HOJA PUBLICADA</h3><div class="utable-wrap"><table class="utable" id="hScreen"><thead><tr>' + m.head.map(h => '<th>' + esc(h) + '</th>').join('') + '</tr></thead><tbody>' +
    (m.data || []).map(it => '<tr>' + (it.cells || []).map(c => '<td>' + esc((c || []).map(l => (l.label ? l.label + ' ' : '') + l.value).join(' · ')) + '</td>').join('') + '</tr>').join('') + '</tbody></table></div><h3 class="dsub">RESULTADOS</h3>';
}
// Excel (.xlsx real) de una hoja publicada: SIEMPRE desde el snapshot (plantilla y columnas de esa versión), igual que el PDF
async function loadExcelJs() {
  if (window.ExcelJS) return;
  await new Promise((ok, ko) => { const sc = document.createElement('script'); sc.src = (import.meta.env.BASE_URL || '/') + 'legacy/exceljs.min.js'; sc.onload = ok; sc.onerror = () => ko(new Error('No se pudo cargar el generador de Excel.')); document.head.appendChild(sc); });
}
export async function xlsxFromSnapshot(model, r, stops) {
  await loadExcelJs();
  if (model && window.OKD_LEGACY && window.OKD_LEGACY.xlsxBytes) return window.OKD_LEGACY.xlsxBytes(model);
  const wb = new window.ExcelJS.Workbook(); const ws = wb.addWorksheet('Hoja ' + r.number);
  ws.addRow(['Hoja ' + r.number + ' · ' + (r.carrier_name || r.carrier_id)]);
  if (model && model.head) {
    ws.addRow(model.head);
    (model.data || []).forEach(it => ws.addRow((it.cells || []).map(c => (c || []).map(l => (l.label ? l.label + ' ' : '') + l.value).join('\n'))));
  } else {
    ws.addRow(['#', 'CLIENTE', 'PEDIDOS', 'BULTOS', 'RESULTADO']);
    stops.forEach((s2, i) => ws.addRow([i + 1, s2.client_name, (s2.order_numbers || []).join(' + '), s2.bultos || 0, s2.outcome]));
  }
  ws.getRow(2).font = { bold: true };
  return wb.xlsx.writeBuffer();
}
async function waitLegacy() { for (let i = 0; i < 60 && !(window.OKD_LEGACY && window.OKD_LEGACY.openDraft); i++) await new Promise(r => setTimeout(r, 100)); }

// ================= HOJAS PUBLICADAS / HISTORIAL =================
export async function openHistory(api, me) {
  const w = frame(me, 'Hojas publicadas', '#/historial');
  const carriers = await api.listCarriers().catch(() => []);
  let f = { limit: 25, offset: 0 };
  w.innerHTML = '<div class="up-head"><h2>HOJAS PUBLICADAS / HISTORIAL</h2></div><div class="ufilters hfilters" id="hFilters">' +
    '<input id="hfNumber" placeholder="N° hoja"><input id="hfOrder" placeholder="Pedido"><input id="hfClient" placeholder="Cliente"><input id="hfResp" placeholder="Responsable">' +
    '<select id="hfCarrier"><option value="">Transportista</option>' + carriers.map(c => '<option value="' + c.id + '">' + esc(c.name) + '</option>').join('') + '</select>' +
    '<select id="hfStatus"><option value="">Estado</option>' + Object.keys(ST).map(k => '<option value="' + k + '">' + ST[k] + '</option>').join('') + '</select>' +
    '<select id="hfApproval"><option value="">Aprobación</option><option value="PENDIENTE">PENDIENTE</option><option value="APROBADA">APROBADA</option><option value="OBSERVADA">OBSERVADA</option></select>' +
    '<select id="hfZone"><option value="">Zona</option><option>ESTE</option><option>ALREDEDORES</option><option>CENTRO</option></select>' +
    '<input id="hfFrom" type="date"><input id="hfTo" type="date"><button class="btn dark" type="button" id="hfGo">BUSCAR</button></div><div id="hList"></div><div id="hDetail"></div>';
  const list = async m => {
    const box = w.querySelector('#hList'); let res = { total: 0, rows: [] };
    try { res = await api.searchRoutes(f); } catch (e) { m = { err: true, text: e.message }; }
    box.innerHTML = '<div class="utable-wrap"><table class="utable" id="histTable"><thead><tr><th>HOJA</th><th>TRANSPORTISTA</th><th>RESPONSABLE</th><th>PUBLICADA</th><th>PARADAS · BULTOS</th><th>ESTADO</th><th>APROBACIÓN</th><th></th></tr></thead><tbody>' +
      (res.rows.length ? res.rows.map(r => '<tr data-rid="' + r.id + '"><td><b>' + esc(r.number) + '</b></td><td>' + esc(r.carrier_name || r.carrier_id) + '</td><td>' + esc(r.responsable_name || '') + '</td><td>' + dt(r.published_at) + '</td><td>' + r.stops + ' · ' + r.bultos + '</td>' +
        '<td><span class="ust ' + (r.operational_status === 'CANCELADA' ? 'DESHABILITADO' : r.operational_status === 'COMPLETADA' ? 'ACTIVO' : 'INVITACION_PENDIENTE') + '">' + (ST[r.operational_status] || r.operational_status) + '</span></td><td>' + esc(AP[r.approval_status] || '') + '</td>' +
        '<td><button class="btn soft" type="button" data-view>VER HOJA</button></td></tr>').join('') : '<tr><td colspan="8">Sin hojas para esos filtros.</td></tr>') + '</tbody></table></div>' +
      '<div class="pager"><span>' + res.total + ' hoja(s)</span><button class="btn soft" type="button" id="hPrev"' + (f.offset ? '' : ' disabled') + '>‹ ANTERIORES</button><button class="btn soft" type="button" id="hNext"' + (f.offset + f.limit < res.total ? '' : ' disabled') + '>SIGUIENTES ›</button></div>';
    msgBox(box, m);
    box.querySelector('#hPrev').onclick = () => { f.offset = Math.max(0, f.offset - f.limit); list(); };
    box.querySelector('#hNext').onclick = () => { f.offset += f.limit; list(); };
    box.querySelectorAll('[data-view]').forEach(b => b.onclick = () => detail(b.closest('tr').dataset.rid));
  };
  const detail = async (id, m) => {
    const box = w.querySelector('#hDetail'); let d;
    try { d = await api.routeDetail(id); } catch (e) { box.innerHTML = '<div class="up-msg err">' + esc(e.message) + '</div>'; return; }
    const r = d.route, active = ['PUBLICADA', 'EN_CURSO'].includes(r.operational_status), stops = (r.stops || []).slice().sort((a, b) => (a.sequence_number || a.seq) - (b.sequence_number || b.seq));
    const pend = (d.returns || []).filter(x => x.status === 'PENDING');
    const postReq = (d.postPublishRequests || []).find(x => Number(x.route_version || 1) === Number(r.version || 1));
    const canPostRevise = r.operational_status === 'PUBLICADA' && !r.started_at && me.role === 'OPERARIO_DEPOSITO' && hasPerm(me, 'requests.create');
    box.innerHTML = '<section class="step rp-step" id="hSheet"><h2><span class="n">' + esc(r.number) + '</span>HOJA ' + esc(r.number) + ' · ' + esc(r.carrier_name || r.carrier_id) + ' · ' + (ST[r.operational_status] || r.operational_status) + (AP[r.approval_status] ? ' · ' + AP[r.approval_status] : '') + '</h2>' +
      (r.vehicle_plate ? '<p class="rp-note">Vehículo ' + esc(r.vehicle_name || '') + ' · ' + esc(r.vehicle_plate) + ' · km ' + (r.km_start ?? '—') + ' → ' + (r.km_end ?? '—') + (r.km_start != null && r.km_end != null ? ' · ' + fmt(r.km_end - r.km_start) + ' km' : '') + '</p>' : '') +
      screenTable(r.sheet_snapshot && r.sheet_snapshot.screen_model) +
      '<div class="utable-wrap"><table class="utable"><thead><tr><th>#</th><th>CLIENTE</th><th>PEDIDOS</th><th>BULTOS</th><th>RESULTADO</th>' + (me.role === 'ADMIN' ? '<th>ENTREGA</th>' : '') + '</tr></thead><tbody>' +
      stops.map((s, i) => '<tr data-stop="' + s.id + '"><td>' + (i + 1) + '</td><td>' + (s.stop_type === 'UBICACION_INTERNA' ? '<span class="tchip">TRASLADO INTERNO</span> ' : s.stop_type === 'TAREA' ? '<span class="tchip">TAREA</span> ' : '') + esc(s.client_name) + (s.provenance === 'DRIVER' ? ' <em>(agregada)</em>' : '') +
        (s.address && s.stop_type && s.stop_type !== 'PEDIDO' ? '<br><small>' + esc(s.address) + '</small>' : '') + (s.instructions ? '<br><small data-hist-obs><b>' + (s.stop_type === 'TAREA' ? 'Instrucciones' : 'Observación') + ':</b> ' + esc(s.instructions) + '</small>' : '') +
        (s.contact_name || s.contact_phone ? '<br><small>Contacto: ' + esc([s.contact_name, s.contact_phone].filter(Boolean).join(' · ')) + '</small>' : '') + '</td><td>' + esc((s.order_numbers || []).join(' + ')) + '</td><td>' + (s.bultos || 0) + '</td><td>' + esc(String(s.outcome || '').replace('_', ' ')) + (s.outcome_reason || s.outcome_note ? ' · ' + esc(s.outcome_reason || s.outcome_note) : '') + '</td>' + (me.role === 'ADMIN' ? '<td><button class="btn soft" type="button" data-delivery-detail>VER ENTREGA</button></td>' : '') + '</tr>').join('') + '</tbody></table></div><div id="deliveryTraceBox"></div>' +
      '<h3 class="dsub">PDF / VERSIONES</h3><div class="utable-wrap"><table class="utable" id="hPdfs"><thead><tr><th>VERSIÓN</th><th>ARCHIVO</th><th>GENERADO</th><th>POR</th><th>ESTADO</th><th></th></tr></thead><tbody>' +
      (d.pdfs.length ? d.pdfs.map(p => '<tr data-v="' + p.route_version + '"><td>v' + p.route_version + '</td><td>' + esc(p.file_name || '') + '</td><td>' + dt(p.generated_at) + '</td><td>' + esc(p.generated_by_name || '') + '</td><td>' + p.status + (p.error ? ' · ' + esc(p.error) : '') + '</td>' +
        '<td>' + (p.status === 'OK' ? '<button class="btn soft" type="button" data-pdf>PDF</button>' : '<button class="btn dark" type="button" data-retry>REINTENTAR PDF</button>') + '</td></tr>').join('') : '<tr><td colspan="6">Sin PDF registrado.</td></tr>') + '</tbody></table></div>' +
      (pend.length ? '<h3 class="dsub">DEVOLUCIÓN SOLICITADA</h3>' + pend.map(x => '<div class="pkrow" data-ret="' + x.id + '"><span>' + esc(x.reason) + ' · ' + dt(x.created_at) + '</span><span class="uact"><input class="ed" data-rnote placeholder="Resolución (versión/corrección)"><button class="btn soft" type="button" data-rres="RESOLVED">RESOLVER</button><button class="btn soft" type="button" data-rres="REJECTED">RECHAZAR</button></span></div>').join('') : '') +
      '<div class="uact hacts"><button class="btn soft" type="button" id="hExcel">EXCEL</button><button class="btn soft" type="button" id="hAudit">AUDITORÍA</button>' +
      (canPostRevise && (!postReq || ['REJECTED','CANCELLED'].includes(postReq.status)) ? '<button class="btn dark" type="button" id="hRequestChange">SOLICITAR MODIFICACIÓN</button>' : '') +
      (canPostRevise && postReq && ['PENDING','OBSERVED'].includes(postReq.status) ? '<span class="ust INVITACION_PENDIENTE">CORRECCIÓN · ' + esc(postReq.status === 'OBSERVED' ? 'OBSERVADA' : 'PENDIENTE DE APROBACIÓN') + '</span>' : '') +
      (canPostRevise && postReq && postReq.status === 'APPROVED' && !postReq.applied ? '<button class="btn go" type="button" id="hOpenRevision">CORREGIR HOJA · CREAR v' + ((r.version || 1) + 1) + '</button>' : '') +
      (active ? '<button class="btn soft" type="button" id="hResend">REENVIAR NOTIFICACIÓN</button>' + (hasPerm(me, 'routes.cancel') ? '<input class="ed" id="hCancelWhy" placeholder="Motivo de cancelación"><button class="btn danger" type="button" id="hCancel">CANCELAR</button>' : '') : '') + '</div><div id="hAuditBox"></div></section>';
    msgBox(box.querySelector('#hSheet'), m);
    const again = t => detail(id, t);
    const signatureSrc = raw => {
      if (!raw) return '';
      const s = String(raw);
      if (s.startsWith('\\x')) {
        const hex = s.slice(2); let bin = '';
        for (let i = 0; i < hex.length; i += 2) bin += String.fromCharCode(parseInt(hex.slice(i, i + 2), 16));
        return 'data:image/png;base64,' + btoa(bin);
      }
      return 'data:image/png;base64,' + s;
    };
    let geoQueue = Promise.resolve();
    const geoLabelFallback = loc => {
      if (!loc) return 'Sin registro';
      if (loc.missing_reason) return 'Sin ubicación · ' + esc(loc.missing_reason);
      if (loc.lat != null && loc.lon != null) return 'Ubicación registrada' + (loc.accuracy != null ? ' · precisión ' + esc(Math.round(Number(loc.accuracy))) + ' m' : '');
      return 'Sin registro';
    };
    const reversePlace = loc => {
      if (!loc || loc.lat == null || loc.lon == null) return Promise.resolve(geoLabelFallback(loc));
      const lat = Number(loc.lat), lon = Number(loc.lon), key = 'okd-geo:' + lat.toFixed(4) + ',' + lon.toFixed(4);
      const cached = localStorage.getItem(key);
      if (cached) return Promise.resolve(cached + (loc.accuracy != null ? ' · precisión ' + Math.round(Number(loc.accuracy)) + ' m' : ''));
      const work = async () => {
        try {
          const u = 'https://nominatim.openstreetmap.org/reverse?format=jsonv2&addressdetails=1&zoom=10&accept-language=es&lat=' + encodeURIComponent(lat) + '&lon=' + encodeURIComponent(lon);
          const res = await fetch(u, { headers: { Accept: 'application/json' } });
          if (!res.ok) throw new Error('geocode ' + res.status);
          const j = await res.json(), a = j.address || {};
          const clean = v => String(v || '').replace(/^Departamento de\s+/i, '').replace(/^Partido de\s+/i, '').trim();
          const city = clean(a.city || a.town || a.village || a.municipality || a.hamlet || a.suburb);
          const dept = clean(a.county || a.state_district);
          const state = clean(a.state);
          const parts = [];
          [city, dept || state].forEach(v => { if (v && !parts.some(x => x.toLowerCase() === v.toLowerCase())) parts.push(v); });
          const place = parts.join(', ') || clean(j.display_name).split(',').slice(0, 2).join(',').trim() || 'Ubicación registrada';
          localStorage.setItem(key, place);
          return place + (loc.accuracy != null ? ' · precisión ' + Math.round(Number(loc.accuracy)) + ' m' : '');
        } catch (e) {
          return geoLabelFallback(loc);
        } finally {
          await new Promise(r => setTimeout(r, 1050));
        }
      };
      const p = geoQueue.then(work, work);
      geoQueue = p.catch(() => null);
      return p;
    };
    if (me.role === 'ADMIN') box.querySelectorAll('[data-delivery-detail]').forEach(btn => btn.onclick = async () => {
      const row = btn.closest('tr'), traceBox = box.querySelector('#deliveryTraceBox');
      btn.disabled = true; btn.textContent = 'CARGANDO…';
      try {
        const tr = await api.deliveryTrace(row.dataset.stop), s = tr.stop || {}, ev = tr.evidence, rc = tr.receipt, mails = tr.emails || [];
        const sig = ev && signatureSrc(ev.signature_png);
        traceBox.innerHTML = '<section class="delivery-trace-panel"><div class="delivery-trace-head"><div><h3>' + (s.stop_type === 'UBICACION_INTERNA' ? 'TRAZABILIDAD DE TRASLADO INTERNO' : s.stop_type === 'TAREA' ? 'TRAZABILIDAD DE TAREA' : 'TRAZABILIDAD DE ENTREGA') + '</h3><p>' + esc(s.client_name || '') + ' · ' + esc((s.order_numbers || []).join(' + ') || 'Sin pedido') + '</p></div><button class="btn soft" type="button" data-close-trace>CERRAR</button></div>' +
          '<div class="delivery-trace-grid">' +
            '<div><span>Resultado</span><b>' + esc(String(s.outcome || 'PENDIENTE').replaceAll('_',' ')) + '</b></div>' +
            '<div><span>Realizado por</span><b>' + esc(tr.outcome_by_name || '—') + '</b></div>' +
            '<div><span>Llegada</span><b>' + (s.arrived_at ? dt(s.arrived_at) : 'Sin registro') + '</b></div>' +
            '<div><span>Entrega / cierre</span><b>' + (s.outcome_at ? dt(s.outcome_at) : 'Sin registro') + '</b></div>' +
            '<div class="wide"><span>Ubicación al llegar</span><b data-geo="arrive">' + geoLabelFallback(s.arrive_location) + '</b></div>' +
            '<div class="wide"><span>Ubicación al finalizar</span><b data-geo="finish">' + geoLabelFallback(s.finish_location) + '</b></div>' +
            (s.location_warning ? '<div class="wide warning"><span>Alerta de ubicación</span><b>' + esc(s.location_warning) + '</b></div>' : '') +
            (s.outcome_note || s.outcome_reason ? '<div class="wide"><span>Observación / motivo</span><b>' + esc(s.outcome_note || s.outcome_reason) + '</b></div>' : '') +
            (s.collection_status && s.collection_status !== 'PENDIENTE' ? '<div><span>Cobranza</span><b>' + esc(s.collection_status.replaceAll('_',' ')) + '</b></div><div><span>Importe</span><b>' + (s.collected_amount != null ? fmtMoney(s.collected_amount) : '—') + '</b></div><div><span>Medio</span><b>' + esc(s.payment_mode || '—') + '</b></div>' : '') +
          '</div>' +
          '<div class="delivery-evidence"><div><h4>' + (s.stop_type === 'UBICACION_INTERNA' ? 'RECEPCIÓN INTERNA DE TRASLADO' : s.stop_type === 'TAREA' ? 'TAREA' : 'RECEPCIÓN') + '</h4>' +
          (s.stop_type === 'UBICACION_INTERNA' ? '<p><b>Ubicación:</b> ' + esc(s.client_name || '') + ' · ' + esc(s.address || '') + '</p><p><b>Pedidos trasladados:</b> ' + esc((s.order_numbers || []).join(', ') || '—') + '</p><p><i>Traslado entre sucursales: no es entrega al cliente.</i></p>' : '') + '<p><b>Recibió:</b> ' + esc(ev && ev.receiver_name || 'Sin evidencia registrada') + '</p>' + (ev && ev.created_at ? '<p><b>Registrada:</b> ' + dt(ev.created_at) + '</p>' : '') + '</div>' +
          '<div class="signature-card"><h4>FIRMA</h4>' + (sig ? '<img src="' + sig + '" alt="Firma de recepción">' : '<p>Sin firma disponible.</p>') + '</div></div>' +
          (rc ? '<div class="receipt-card"><h4>RECIBIDO CONFORME</h4><p><b>Comprobante:</b> ' + esc(rc.receipt_number || '—') + ' · <b>Generado:</b> ' + (rc.generated_at ? dt(rc.generated_at) : '—') + '</p><p><b>Email:</b> ' + esc(rc.recipient_email || '—') + '</p></div>' : '') +
          (mails.length ? '<div class="email-trace"><h4>EMAILS DE LA ENTREGA</h4>' + mails.map(m => '<div><b>' + esc(m.kind || '') + '</b><span>' + esc(m.status || '') + (m.sent_at ? ' · ' + dt(m.sent_at) : '') + (m.error ? ' · ' + esc(m.error) : '') + '</span></div>').join('') + '</div>' : '') +
        '</section>';
        const geoArrive = traceBox.querySelector('[data-geo="arrive"]'), geoFinish = traceBox.querySelector('[data-geo="finish"]');
        if (geoArrive && s.arrive_location && s.arrive_location.lat != null) reversePlace(s.arrive_location).then(v => { if (geoArrive.isConnected) geoArrive.textContent = v; });
        if (geoFinish && s.finish_location && s.finish_location.lat != null) reversePlace(s.finish_location).then(v => { if (geoFinish.isConnected) geoFinish.textContent = v; });
        const grid = traceBox.querySelector('.delivery-trace-grid');
        if (grid && ((s.arrive_location && s.arrive_location.lat != null) || (s.finish_location && s.finish_location.lat != null))) {
          const at = document.createElement('p'); at.className = 'geo-attribution'; at.textContent = 'Ubicación aproximada · © OpenStreetMap contributors'; grid.after(at);
        }
        traceBox.querySelector('[data-close-trace]').onclick = () => { traceBox.innerHTML = ''; };
        traceBox.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
      } catch (e) { traceBox.innerHTML = '<div class="up-msg err">' + esc(e.message) + '</div>'; }
      finally { btn.disabled = false; btn.textContent = 'VER ENTREGA'; }
    });
    box.querySelectorAll('[data-pdf]').forEach(b => b.onclick = async () => { try { const v = +b.closest('tr').dataset.v, blob = await api.downloadRoutePdf(id, v); const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = 'Hoja_' + r.number + '_v' + v + '.pdf'; document.body.appendChild(a); a.click(); a.remove(); } catch (e) { again({ err: true, text: e.message }); } });
    box.querySelectorAll('[data-retry]').forEach(b => b.onclick = () => run(async () => {
      const v = +b.closest('tr').dataset.v, snap = await api.routePdfSnapshot(id);
      if (!window.PdfExporter && !(window.OKD_LEGACY && window.OKD_LEGACY.pdfBytes)) throw new Error('Abrí DESPACHO una vez para cargar el generador de PDF.');
      await api.saveRoutePdf(id, v, snap.number, window.OKD_LEGACY.pdfBytes(snap.pdf_model));
    }, 'PDF regenerado desde el snapshot publicado.', again));
    box.querySelectorAll('[data-rres]').forEach(b => b.onclick = () => { const row = b.closest('[data-ret]'); run(() => api.resolveReturn(row.dataset.ret, b.dataset.rres, row.querySelector('[data-rnote]').value), 'Devolución ' + (b.dataset.rres === 'RESOLVED' ? 'resuelta' : 'rechazada') + '.', again); });
    box.querySelector('#hExcel').onclick = () => run(async () => {
      const snap = r.sheet_snapshot || {}, model = snap.xlsx_model || snap.pdf_model, ver = r.version || 1, name = 'Hoja_' + r.number + '_v' + ver + '.xlsx'; // columnas con flag Excel
      const buf = await xlsxFromSnapshot(model, r, stops);
      const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob([buf], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' })); a.download = name; document.body.appendChild(a); a.click(); a.remove();
    }, 'Excel descargado (columnas de la plantilla publicada).', () => {});
    box.querySelector('#hAudit').onclick = () => { box.querySelector('#hAuditBox').innerHTML = '<ul class="alist">' + (d.audit.length ? d.audit.map(a => '<li>' + dt(a.at || a.created_at) + ' · ' + esc(a.action) + '</li>').join('') : '<li>Sin eventos.</li>') + '</ul>'; };
    const rev = box.querySelector('#hOpenRevision'); if (rev) rev.onclick = async () => {
      rev.disabled = true;
      try {
        const x = await api.beginPostPublishRevision(id);
        sessionStorage.setItem('okd_open_revision', JSON.stringify(x));
        location.hash = '#/despacho';
      } catch (e) { again({ err: true, text: e.message }); }
      finally { rev.disabled = false; }
    };
    const rq = box.querySelector('#hRequestChange'); if (rq) rq.onclick = async () => {
      const reason = prompt('Indicá qué se publicó mal y qué necesitás modificar en la hoja ' + r.number + ':');
      if (!reason || !reason.trim()) return;
      rq.disabled = true;
      try {
        await api.createOperationalRequest({
          op_id: 'postpub-' + id + '-' + (crypto.randomUUID ? crypto.randomUUID() : Date.now()),
          request_type: 'CAMBIO_POST_PUBLICACION',
          route_id: id,
          reason: reason.trim(),
          payload: { route_number: r.number, route_version: r.version }
        });
        again({ text: 'Solicitud enviada a tu Superior. La hoja publicada no se modifica hasta que la solicitud sea aprobada.' });
      } catch (e) { again({ err: true, text: e.message }); }
      finally { rq.disabled = false; }
    };
    const rs = box.querySelector('#hResend'); if (rs) rs.onclick = () => run(() => api.resendNotification(id), 'Notificación reenviada al responsable.', again);
    const cx = box.querySelector('#hCancel'); if (cx) cx.onclick = async () => {
      const ns = api.routeNocSummary ? await api.routeNocSummary(id).catch(() => null) : null, hasNoc = ns && ns.count > 0;
      const warn = hasNoc ? '\n\nEsta hoja contiene Notas de Crédito ya aplicadas (' + ns.count + ' · ' + fmtMoney(ns.amount) + '). La cancelación de la hoja no devuelve automáticamente esas NOC. Quedarán pendientes de conciliación administrativa.' : '';
      if (confirm('¿Cancelar la hoja ' + r.number + '? Se liberan sus pedidos; el correlativo no se reutiliza.' + warn))
        run(() => api.cancelRoute(id, box.querySelector('#hCancelWhy').value), 'Hoja cancelada. Pedidos liberados.' + (hasNoc ? ' Las Notas de Crédito aplicadas quedaron pendientes de conciliación administrativa (CONCILIACIÓN NOC).' : ''), t => { list(); again(t); });
    };
  };
  w.querySelector('#hfGo').onclick = () => {
    const v = id => w.querySelector(id).value.trim();
    f = { limit: 25, offset: 0, number: v('#hfNumber'), order: v('#hfOrder'), client: v('#hfClient'), responsable: v('#hfResp'), carrier: v('#hfCarrier'), status: v('#hfStatus'), approval: v('#hfApproval'), zone: v('#hfZone'), from: v('#hfFrom'), to: v('#hfTo') };
    list();
  };
  await list();
}

// ================= CONFIGURACIÓN =================
const SECTIONS = [['transportistas', 'A. TRANSPORTISTAS'], ['plantillas', 'B. PLANTILLAS / COLUMNAS'], ['vehiculos', 'C. VEHÍCULOS Y MANTENIMIENTO'], ['financieras', 'D. REGLAS FINANCIERAS'], ['asignacion', 'D2. REGLAS DE ASIGNACIÓN'], ['financiacion', 'D3. FINANCIACIÓN PROPIA'],
  ['emails', 'E. EMAILS Y NOTIFICACIONES'], ['pdf', 'F. PDF Y ENVÍOS'], ['ubicaciones', 'G. UBICACIONES CLIENTES'], ['ubicaciones_interno', 'G2. UBICACIONES TRANSPORTISTA INTERNO'], ['backup', 'H. BACKUP'], ['general', 'I. PARÁMETROS GENERALES']];
export async function openConfig(api, me, section, opts) {
  const only = opts && opts.only;   // acceso por un permiso puntual (carriers.manage): solo esas secciones
  const allowed = SECTIONS.filter(([k]) => !only || only.includes(k)).filter(([k]) => {
    if (hasPerm(me, 'settings.manage')) return true;
    if (k === 'transportistas') return hasPerm(me, 'carriers.manage');
    if (k === 'plantillas') return hasPerm(me, 'columns.manage_defaults') || hasPerm(me, 'columns.manage_templates');
    if (k === 'vehiculos') return hasPerm(me, 'vehicles.view') || hasPerm(me, 'vehicles.manage') || hasPerm(me, 'vehicles.service_manage') || hasPerm(me, 'vehicle_mileage.view') || hasPerm(me, 'vehicle_mileage.enter');
    return false;
  });
  let cur = section && allowed.some(s => s[0] === section) ? section : allowed[0][0];
  const w = frame(me, 'Configuración', '#/configuracion?sec=' + cur);
  w.innerHTML = '<div class="up-head"><h2>CONFIGURACIÓN</h2></div><div class="cfgnav" id="cfgNav">' + allowed.map(([k, l]) => '<button type="button" data-sec="' + k + '">' + l + '</button>').join('') + '</div><div id="cfgBody"></div>';
  const show = async (k, m) => {
    cur = k; w.querySelectorAll('[data-sec]').forEach(b => b.classList.toggle('on', b.dataset.sec === k));
    const body = w.querySelector('#cfgBody'); body.innerHTML = '';
    const sec = document.createElement('section'); sec.className = 'step rp-step'; sec.id = 'cfg-' + k; body.appendChild(sec);
    const again = t => show(k, t);
    try { await CFG[k](api, me, sec, again); } catch (e) { sec.innerHTML = '<div class="up-msg err">' + esc(e.message) + '</div>'; }
    msgBox(sec, m);
  };
  w.querySelectorAll('[data-sec]').forEach(b => b.onclick = () => show(b.dataset.sec));
  await show(cur);
}
const CFG = {
  async transportistas(api, me, sec, again) {
    const cs = await api.listCarriers();
    const canManage = hasPerm(me, 'settings.manage') || hasPerm(me, 'carriers.manage');
    sec.innerHTML = '<h2><span class="n">A</span>TRANSPORTISTAS</h2><p class="rp-note">El código de 2 dígitos se asigna automáticamente al crear un transportista y permanece fijo. Cristian Este y Alrededores comparten 01.</p>' +
      (canManage ? '<div class="cfgform" id="carrierNew"><h3>NUEVO TRANSPORTISTA</h3><label>ID / código interno <input id="ncId" placeholder="Ej. UCO"></label><label>Nombre <input id="ncName" placeholder="Nombre del transportista"></label><label>Tipo <select id="ncKind"><option>EXTERNO</option><option>INTERNO</option></select></label><label>Código correlativo <input id="ncCode" readonly placeholder="Se asigna al guardar"></label><label>Email <input id="ncEmail" type="email" placeholder="opcional"></label><button class="btn dark" type="button" id="ncSave">CREAR TRANSPORTISTA</button></div>' : '') +
      '<div class="utable-wrap"><table class="utable" id="carrTable"><thead><tr><th>ID</th><th>NOMBRE</th><th>TIPO</th><th>CÓDIGO</th><th>ACTIVO</th><th>EMAILS</th><th>RESPONSABLES</th><th></th></tr></thead><tbody>' +
      cs.map(c => '<tr data-cid="' + c.id + '"><td>' + esc(c.id) + '</td><td><input class="ed" data-f="name" value="' + esc(c.name) + '"></td><td><select data-f="kind"><option' + (c.kind === 'EXTERNO' ? ' selected' : '') + '>EXTERNO</option><option' + (c.kind === 'INTERNO' ? ' selected' : '') + '>INTERNO</option></select></td>' +
        '<td><input class="ed" data-f="code" size="3" readonly title="Código permanente" value="' + esc(c.sequence_code || '') + '"></td><td><input type="checkbox" data-f="active"' + (c.active !== false ? ' checked' : '') + '></td><td><input class="ed" data-f="emails" value="' + esc((c.emails || []).join(', ')) + '"></td>' +
        '<td><button class="btn soft" type="button" data-resp>VER</button></td><td><button class="btn dark" type="button" data-save>GUARDAR</button></td></tr>').join('') + '</tbody></table></div><div id="carrResp"></div>';
    const ncSave = sec.querySelector('#ncSave');
    if (ncSave) ncSave.onclick = () => run(() => {
      const id = sec.querySelector('#ncId').value.trim().toUpperCase();
      const name = sec.querySelector('#ncName').value.trim();
      const code = null;
      const email = sec.querySelector('#ncEmail').value.trim();
      if (!id || !name) throw new Error('Completá ID y nombre del transportista.');
      return api.upsertCarrier({ id, name, kind: sec.querySelector('#ncKind').value, sequence_code: code, active: true, report_group: null, emails: email ? [email] : [], notes: null });
    }, 'Transportista creado.', again);
    sec.querySelectorAll('tr[data-cid]').forEach(tr => {
      const g = k => tr.querySelector('[data-f="' + k + '"]'), c = cs.find(x => x.id === tr.dataset.cid);
      tr.querySelector('[data-save]').onclick = () => run(() => api.upsertCarrier({ id: c.id, name: g('name').value, kind: g('kind').value, sequence_code: g('code').value.trim(), active: g('active').checked, report_group: c.report_group, emails: g('emails').value.split(',').map(x => x.trim()).filter(Boolean), notes: c.notes }), 'Transportista guardado.', again);
      tr.querySelector('[data-resp]').onclick = async () => { const r = await api.responsables(c.id).catch(e => { return [{ full_name: e.message }]; }); sec.querySelector('#carrResp').innerHTML = '<p class="rp-note">Responsables compatibles con ' + esc(c.name) + ': ' + (r.map(u => esc(u.full_name)).join(', ') || 'ninguno') + '</p>'; };
    });
  },
  async plantillas(api, me, sec, again) {
    const cs = await api.listCarriers(); let cid = sec.dataset.cid || cs[0].id;
    const t = await api.currentTemplate(cid); let cols = (t.columns || DEFAULT_COLUMNS).map(c => ({ ...c })).sort((a, b) => (a.order || 0) - (b.order || 0));
    sec.innerHTML = '<h2><span class="n">B</span>PLANTILLA DE HOJA</h2><div class="ufilters"><label class="rp-lbl">Transportista <select id="tplCarrier">' + cs.map(c => '<option value="' + c.id + '"' + (c.id === cid ? ' selected' : '') + '>' + esc(c.name) + '</option>').join('') + '</select></label>' +
      '<span class="rp-note">' + (t.version ? 'Versión vigente: v' + t.version : 'Plantilla predeterminada (sin guardar)') + ' · arrastrá las filas para ordenar</span></div>' +
      '<div class="utable-wrap"><table class="utable tpl" id="tplTable"><thead><tr><th></th><th>COLUMNA</th><th>TÍTULO</th><th>VISIBLE</th><th>ANCHO</th><th>ALINEACIÓN</th><th>FORMATO</th><th>PANTALLA</th><th>PDF</th><th>EXCEL</th><th>OBLIGATORIO</th></tr></thead><tbody></tbody></table></div>' +
      '<div class="tplprev" id="tplPrev"></div><button class="btn dark" type="button" id="tplSave">GUARDAR PLANTILLA</button>';
    const tb = sec.querySelector('#tplTable tbody');
    const draw = () => {
      tb.innerHTML = cols.map((c, i) => '<tr draggable="true" data-i="' + i + '"><td class="grip">⠿ <button type="button" data-up title="Subir">↑</button><button type="button" data-down title="Bajar">↓</button></td><td>' + esc(c.key) + '</td><td><input class="ed" data-k="title" value="' + esc(c.title) + '"></td>' +
        '<td><input type="checkbox" data-k="visible"' + (c.visible !== false ? ' checked' : '') + (c.required ? ' disabled' : '') + '></td><td><input class="ed" data-k="width" size="3" value="' + (c.width || '') + '"></td>' +
        '<td><select data-k="align">' + ['left', 'center', 'right'].map(a => '<option' + (c.align === a ? ' selected' : '') + '>' + a + '</option>').join('') + '</select></td>' +
        '<td><select data-k="format">' + ['text', 'money', 'int', 'date'].map(a => '<option' + (c.format === a ? ' selected' : '') + '>' + a + '</option>').join('') + '</select></td>' +
        ['screen', 'pdf', 'excel', 'required'].map(k => '<td><input type="checkbox" data-k="' + k + '"' + (c[k] !== false && (k !== 'required' || c.required) ? ' checked' : '') + '></td>').join('') + '</tr>').join('');
      sec.querySelector('#tplPrev').innerHTML = '<b>VISTA PREVIA (PDF)</b><div class="tplhead">' + cols.filter(c => c.visible !== false && c.pdf !== false).map(c => '<span style="text-align:' + c.align + '">' + esc(c.title) + '</span>').join('') + '</div>';
      tb.querySelectorAll('tr').forEach(tr => {
        const i = +tr.dataset.i;
        tr.querySelectorAll('[data-k]').forEach(inp => inp.onchange = () => { const k = inp.dataset.k; cols[i][k] = inp.type === 'checkbox' ? inp.checked : k === 'width' ? (parseInt(inp.value, 10) || 0) : inp.value; if (k === 'required' && inp.checked) cols[i].visible = true; draw(); });
        tr.querySelector('[data-up]').onclick = () => { if (i > 0) { [cols[i - 1], cols[i]] = [cols[i], cols[i - 1]]; draw(); } };
        tr.querySelector('[data-down]').onclick = () => { if (i < cols.length - 1) { [cols[i + 1], cols[i]] = [cols[i], cols[i + 1]]; draw(); } };
        tr.addEventListener('dragstart', e => e.dataTransfer.setData('text/plain', String(i)));
        tr.addEventListener('dragover', e => e.preventDefault());
        tr.addEventListener('drop', e => { e.preventDefault(); const from = +e.dataTransfer.getData('text/plain'); const [c] = cols.splice(from, 1); cols.splice(i, 0, c); draw(); });
      });
    };
    draw();
    sec.querySelector('#tplCarrier').onchange = e => { sec.dataset.cid = e.target.value; CFG.plantillas(api, me, sec, again); };
    sec.querySelector('#tplSave').onclick = () => run(() => api.saveTemplate(cid, cols.map((c, i) => ({ ...c, order: i + 1 }))), 'Plantilla guardada como versión nueva. Las hojas ya publicadas conservan la suya.', m => { sec.dataset.cid = cid; again(m); });
  },
  async vehiculos(api, me, sec, again) {
    if (hasPerm(me, 'vehicle_mileage.view') || hasPerm(me, 'vehicle_mileage.rules_manage')) { const kb = document.createElement('div'); kb.className = 'card kmrules-in-config'; kb.id = 'kmRules'; await mileageBlock(api, me, kb, again); sec.after(kb); }
    const [vs, allUsers, ns] = await Promise.all([api.vehicleStatus(), api.listUsers().catch(() => []), api.notificationSettings().catch(() => ({}))]);
    const users = allUsers.filter(u => u.role === 'TRANSPORTISTA_INTERNO' && u.status === 'ACTIVO');
    const card = v => '<div class="vcard' + (v.service_due ? ' due' : '') + (v.active === false ? ' off' : '') + '" data-vid="' + v.id + '"><b>' + esc(v.name) + ' · ' + esc(v.plate) + '</b>' + (v.active === false ? ' <em>(inactivo)</em>' : '') +
      '<div>Conductor habitual: ' + esc(v.habitual_driver_name || '—') + '</div><div>KM actual: <b>' + fmt(v.current_km) + '</b></div><div>Próximo service: <b>' + fmt(v.next_service_km) + '</b> (cada ' + fmt(v.service_interval_km) + ' km)</div>' +
      '<div>' + (v.service_due ? '<span class="due-tag">⚠ SERVICE REQUERIDO</span>' : 'Faltan: <b>' + fmt(v.km_to_service) + ' km</b>') + '</div>' +
      '<div class="uact"><button class="btn soft" type="button" data-edit>EDITAR</button><button class="btn soft" type="button" data-svc>REGISTRAR SERVICE REALIZADO</button><button class="btn soft" type="button" data-off>' + (v.active === false ? 'ACTIVAR' : 'DESACTIVAR') + '</button></div><div class="vform" hidden></div></div>';
    sec.innerHTML = '<h2><span class="n">C</span>VEHÍCULOS Y MANTENIMIENTO</h2><div class="vgrid" id="vehList">' + (vs.map(card).join('') || '<p class="rp-empty">Sin vehículos.</p>') + '</div>' +
      '<h3 class="dsub">ALERTAS DE SERVICE POR EMAIL</h3>' +
      '<div class="service-alert-box">' +
        '<label class="chk"><input type="checkbox" id="svcMailOn"' + (ns.service_email_enabled ? ' checked' : '') + '> Activar alertas de service por email</label>' +
        '<div class="ufilters"><label class="rp-lbl">Avisar cuando falten <input id="svcWarnKm" inputmode="numeric" value="' + (ns.service_warning_km ?? 1000) + '"> km</label>' +
        '<label class="rp-lbl">Repetir cada <input id="svcRepeatKm" inputmode="numeric" value="' + (ns.service_repeat_km ?? 500) + '"> km</label></div>' +
        '<div class="report-recipients"><label class="rp-lbl" style="display:block">Destinatarios adicionales</label>' +
          '<div class="recipient-row"><input id="svcRcptAdd" type="email" placeholder="nombre@empresa.com"><button class="btn soft" type="button" id="svcRcptAddBtn">AGREGAR EMAIL</button></div>' +
          '<div id="svcRcptList" class="recipient-chips"></div>' +
          '<p class="rp-note">Sin límite de destinatarios configurado por la app. Cada email queda registrado por separado.</p></div>' +
        '<label class="chk"><input type="checkbox" id="svcCopyAdmin"' + (ns.service_copy_admin !== false ? ' checked' : '') + '> Copiar a todos los Admin General activos</label>' +
        '<label class="chk"><input type="checkbox" id="svcCopyDriver"' + (ns.service_copy_driver ? ' checked' : '') + '> Copiar al conductor habitual del vehículo</label>' +
        '<div style="margin-top:12px"><button class="btn dark" type="button" id="svcMailSave">GUARDAR ALERTAS</button></div>' +
      '</div>' +
      '<h3 class="dsub">REGISTRAR SERVICE REALIZADO</h3>' +
      (vs.length ? '<div class="service-register-box" id="adminServiceRegister"><select id="asVeh"><option value="">Seleccionar vehículo</option>' + vs.filter(v => v.active !== false).map(v => '<option value="' + v.id + '">' + esc(v.name + ' · ' + v.plate) + '</option>').join('') + '</select><input id="asDate" type="date" value="' + new Date().toISOString().slice(0, 10) + '"><input id="asKm" inputmode="numeric" placeholder="KM al momento del service"><input id="asNote" placeholder="Observación (opcional)"><button class="btn dark" type="button" id="asSave">REGISTRAR SERVICE</button></div><p class="rp-note">Disponible para Admin General. También puede habilitarse a Operarios desde Usuarios y permisos → Vehículos → Gestionar service.</p>' : '<div class="up-msg">Todavía no hay vehículos cargados. Agregá el vehículo abajo para poder registrar su service.</div>') +
      '<h3 class="dsub">ALTA DE VEHÍCULO</h3><div class="ufilters" id="vehNew"><input id="nvName" placeholder="Modelo / nombre (ej. TOYOTA HILUX)"><input id="nvPlate" placeholder="Patente"><select id="nvDriver"><option value="">Conductor habitual</option>' + users.map(u => '<option value="' + u.id + '">' + esc(u.full_name) + '</option>').join('') + '</select>' +
      '<input id="nvKm" inputmode="numeric" placeholder="KM actual"><input id="nvLast" inputmode="numeric" placeholder="KM último service (opcional)"><input id="nvInt" inputmode="numeric" placeholder="Intervalo (10.000)"><button class="btn dark" type="button" id="nvSave">AGREGAR VEHÍCULO</button></div>' +
      '<p class="rp-note">Si no cargás el último service, se toma el KM actual como base: próximo service = base + intervalo. Al iniciar una ruta interna el chofer carga el KM inicial y al finalizar el KM final; el KM actual se actualiza con el odómetro real.</p>';
    const svcRecipients = [...(ns.service_email_recipients || [])];
    const drawSvcRecipients = () => {
      const box = sec.querySelector('#svcRcptList');
      box.innerHTML = svcRecipients.length
        ? svcRecipients.map((mail, i) => '<span class="recipient-chip">' + esc(mail) + '<button type="button" data-svc-rm="' + i + '" aria-label="Quitar destinatario">×</button></span>').join('')
        : '<span class="rp-note">Todavía no hay destinatarios adicionales configurados.</span>';
      box.querySelectorAll('[data-svc-rm]').forEach(b => b.onclick = () => { svcRecipients.splice(+b.dataset.svcRm, 1); drawSvcRecipients(); });
    };
    const addSvcRecipient = () => {
      const inp = sec.querySelector('#svcRcptAdd'), mail = inp.value.trim().toLowerCase();
      if (!mail) return;
      if (!/^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$/.test(mail)) { msgBox(sec, { err: true, text: 'Ingresá un email válido.' }); return; }
      if (!svcRecipients.includes(mail)) svcRecipients.push(mail);
      inp.value = ''; drawSvcRecipients();
    };
    sec.querySelector('#svcRcptAddBtn').onclick = addSvcRecipient;
    sec.querySelector('#svcRcptAdd').onkeydown = e => { if (e.key === 'Enter') { e.preventDefault(); addSvcRecipient(); } };
    drawSvcRecipients();
    sec.querySelector('#svcMailSave').onclick = () => run(async () => {
      const warning = parseInt(sec.querySelector('#svcWarnKm').value, 10), repeat = parseInt(sec.querySelector('#svcRepeatKm').value, 10);
      if (!(warning >= 0)) throw new Error('Los KM de aviso deben ser 0 o más.');
      if (!(repeat >= 1)) throw new Error('La repetición debe ser de al menos 1 km.');
      await api.setNotificationSettings({
        service_email_enabled: sec.querySelector('#svcMailOn').checked,
        service_warning_km: warning,
        service_repeat_km: repeat,
        service_email_recipients: svcRecipients,
        service_copy_admin: sec.querySelector('#svcCopyAdmin').checked,
        service_copy_driver: sec.querySelector('#svcCopyDriver').checked
      });
      await api.sendServiceAlerts().catch(() => null);
    }, 'Alertas de service guardadas.', again);

    const num = v => v === '' ? '' : Number(String(v).replace(/\./g, '').replace(',', '.'));
    const adminSvc = sec.querySelector('#adminServiceRegister');
    if (adminSvc) {
      const asVeh = adminSvc.querySelector('#asVeh'), asKm = adminSvc.querySelector('#asKm');
      asVeh.onchange = () => { const v = vs.find(x => x.id === asVeh.value); if (v) asKm.value = v.current_km == null ? '' : v.current_km; };
      adminSvc.querySelector('#asSave').onclick = () => run(async () => {
        const vid = asVeh.value, km = num(asKm.value), date = adminSvc.querySelector('#asDate').value, note = adminSvc.querySelector('#asNote').value;
        if (!vid) throw new Error('Seleccioná un vehículo.');
        if (!(km > 0)) throw new Error('Ingresá el kilometraje al momento del service.');
        await api.registerServiceDone(vid, km, date, note);
        await api.sendServiceAlerts().catch(() => null);
      }, 'Service registrado. Se recalculó el próximo service y comenzó un nuevo ciclo.', again);
    }
    sec.querySelector('#nvSave').onclick = () => run(() => api.saveVehicle({ name: sec.querySelector('#nvName').value, plate: sec.querySelector('#nvPlate').value, habitual_driver_id: sec.querySelector('#nvDriver').value || null,
      current_km: num(sec.querySelector('#nvKm').value) || 0, last_service_km: num(sec.querySelector('#nvLast').value.trim()), service_interval_km: num(sec.querySelector('#nvInt').value) || 10000 }), 'Vehículo agregado.', again);
    sec.querySelectorAll('.vcard').forEach(c => {
      const v = vs.find(x => x.id === c.dataset.vid), form = c.querySelector('.vform');
      c.querySelector('[data-edit]').onclick = () => { form.hidden = false; form.innerHTML = '<input class="ed" data-e="name" value="' + esc(v.name) + '"><input class="ed" data-e="plate" value="' + esc(v.plate) + '"><select data-e="driver"><option value="">Conductor habitual</option>' + users.map(u => '<option value="' + u.id + '"' + (u.id === v.habitual_driver_id ? ' selected' : '') + '>' + esc(u.full_name) + '</option>').join('') + '</select><input class="ed" data-e="int" value="' + v.service_interval_km + '"><button class="btn dark" type="button" data-esave>GUARDAR</button>';
        form.querySelector('[data-esave]').onclick = () => run(() => api.saveVehicle({ id: v.id, name: form.querySelector('[data-e="name"]').value, plate: form.querySelector('[data-e="plate"]').value, habitual_driver_id: form.querySelector('[data-e="driver"]').value || null, service_interval_km: num(form.querySelector('[data-e="int"]').value), active: v.active !== false }), 'Vehículo actualizado.', again); };
      c.querySelector('[data-svc]').onclick = () => { form.hidden = false; form.innerHTML = '<input class="ed" type="date" data-s="date" value="' + new Date().toISOString().slice(0, 10) + '"><input class="ed" data-s="km" inputmode="numeric" placeholder="KM del service" value="' + v.current_km + '"><input class="ed" data-s="note" placeholder="Observación"><button class="btn dark" type="button" data-ssave>REGISTRAR</button>';
        form.querySelector('[data-ssave]').onclick = () => run(() => api.registerServiceDone(v.id, num(form.querySelector('[data-s="km"]').value), form.querySelector('[data-s="date"]').value, form.querySelector('[data-s="note"]').value), 'Service registrado: comienza un nuevo ciclo.', again); };
      c.querySelector('[data-off]').onclick = () => run(() => api.saveVehicle({ id: v.id, name: v.name, plate: v.plate, habitual_driver_id: v.habitual_driver_id, service_interval_km: v.service_interval_km, active: v.active === false }), v.active === false ? 'Vehículo activado.' : 'Vehículo desactivado.', again);
    });
    if (hasPerm(me, 'vehicles.manage')) {
      const fix = document.createElement('div'); fix.className = 'ufilters'; fix.innerHTML = '<b>CORRECCIÓN DE KM (Administración)</b><select id="fxVeh">' + vs.map(v => '<option value="' + v.id + '">' + esc(v.name + ' · ' + v.plate) + '</option>').join('') + '</select><input id="fxKm" inputmode="numeric" placeholder="KM correcto"><input id="fxWhy" placeholder="Motivo (obligatorio)"><button class="btn soft" type="button" id="fxGo">CORREGIR KM</button>';
      sec.appendChild(fix); fix.querySelector('#fxGo').onclick = () => run(() => api.correctVehicleKm(fix.querySelector('#fxVeh').value, num(fix.querySelector('#fxKm').value), fix.querySelector('#fxWhy').value), 'Kilometraje corregido (queda en auditoría).', again);
    }
  },
  async financieras(api, me, sec, again) {
    const f = await api.financialRules(), r = f.rules;
    sec.innerHTML = '<h2><span class="n">D</span>REGLAS FINANCIERAS</h2><p class="rp-note">Versión vigente v' + f.version + '. Cada cambio crea una versión nueva, queda en auditoría y en el snapshot de cada hoja publicada.</p>' +
      '<div class="cfgform" id="finForm"><label>Medio de pago FAC <input data-f="fac" value="' + esc(r.pay.FAC) + '"></label><label>Medio de pago NDP <input data-f="ndp" value="' + esc(r.pay.NDP) + '"></label>' +
      '<label>Envío Cristian Este ($) <input data-f="este" value="' + (r.shipCosts.ESTE || []).join(', ') + '"></label><label>Envío Cristian Alrededores ($, lista) <input data-f="alr" value="' + (r.shipCosts.ALREDEDORES || []).join(', ') + '"></label>' +
      '<label>Antigüedad máxima de créditos (meses) <input data-f="months" value="' + r.creditMonths + '"></label><label>Tipos que pueden ser saldo a favor <input data-f="types" value="' + (r.creditTypes || []).join(', ') + '"></label>' +
      '<label>Tolerancia ($) <input data-f="tol" value="' + r.tolerance + '"></label></div><p class="rp-note">Saldo de cuenta corriente como piso y NOC: se mantiene la lógica de cálculo vigente del panel; la NOC no se aplica sola (créditos antiguos se confirman en el detalle).</p><button class="btn dark" type="button" id="finSave">GUARDAR NUEVA VERSIÓN</button>';
    if (hasPerm(me, 'credit_notes.manage')) {
      const ns = await api.listCreditNotes().catch(() => []);
      const box = document.createElement('div'); box.id = 'nocAdmin';
      box.innerHTML = '<h3 class="dsub">NOTAS DE CRÉDITO (NOC) USADAS EN OK DESPACHO</h3><p class="rp-note">Registro interno de uso (no modifica Cianbox). IGNORAR o RECHAZAR libera lo reservado en borradores; lo consumido en hojas publicadas queda como historial.</p>' +
        '<div class="utable-wrap"><table class="utable"><thead><tr><th>CLIENTE</th><th>NOC</th><th>FECHA</th><th>ORIGINAL</th><th>REMANENTE</th><th>ESTADO</th><th></th></tr></thead><tbody>' +
        (ns.length ? ns.map(n => '<tr data-fp="' + n.fingerprint + '"><td>' + esc(n.client_key) + '</td><td>' + esc(n.comp) + '</td><td>' + esc(n.issued_date || '') + '</td><td>$ ' + fmt(n.original_amount) + '</td><td>$ ' + fmt(n.remaining_amount) + '</td><td>' + n.status + (n.reason ? ' · ' + esc(n.reason) : '') + '</td>' +
          '<td>' + (['IGNORADA', 'RECHAZADA'].includes(n.status) ? '' : '<div class="uact"><input class="ed" data-why placeholder="Motivo"><button class="btn soft" type="button" data-dec="IGNORADA">IGNORAR</button><button class="btn danger" type="button" data-dec="RECHAZADA">RECHAZAR</button></div>') + '</td></tr>').join('') : '<tr><td colspan="7">Sin NOC aplicadas todavía.</td></tr>') + '</tbody></table></div>';
      sec.appendChild(box);
      box.querySelectorAll('[data-dec]').forEach(b => b.onclick = () => { const tr = b.closest('tr'); run(() => api.decideCreditNote(tr.dataset.fp, b.dataset.dec, tr.querySelector('[data-why]').value), 'NOC ' + b.dataset.dec.toLowerCase() + ' (auditada).', again); });
    }
    const g = k => sec.querySelector('[data-f="' + k + '"]').value, nums = v => v.split(',').map(x => Number(x.trim().replace(/\./g, ''))).filter(x => x > 0);
    sec.querySelector('#finSave').onclick = () => run(async () => {
      const rules = { pay: { FAC: g('fac').trim(), NDP: g('ndp').trim() }, shipCosts: { ESTE: nums(g('este')), ALREDEDORES: nums(g('alr')) }, creditMonths: parseInt(g('months'), 10), creditTypes: g('types').split(',').map(x => x.trim().toUpperCase()).filter(Boolean), tolerance: Number(g('tol')) };
      if (!rules.pay.FAC || !rules.pay.NDP || !rules.shipCosts.ESTE.length || !rules.shipCosts.ALREDEDORES.length || !(rules.creditMonths >= 0) || !(rules.tolerance >= 0)) throw new Error('Revisá los valores: todos son obligatorios y no pueden ser negativos.');
      const nf = await api.setFinancialRules(rules); if (window.OKD_APPLY_RULES) window.OKD_APPLY_RULES(nf);
    }, 'Reglas guardadas como versión nueva.', again);
  },
  // Reglas Estado/Zona → Transportista (servidor, versionadas; todos los Operarios usan la misma versión)
  async asignacion(api, me, sec, again) {
    const [f, cs] = await Promise.all([api.routingRules(), api.listCarriers()]);
    let rules = (f.rules || []).slice().sort((a, b) => (a.priority || 0) - (b.priority || 0));
    const draw = () => {
      sec.innerHTML = '<h2><span class="n">D2</span>REGLAS DE ASIGNACIÓN · ESTADO / ZONA → TRANSPORTISTA</h2><p class="rp-note">Versión vigente v' + f.version + '. Se aplican en orden (la primera que coincide). Todos los Operarios usan esta versión; un cambio recalcula solo las asignaciones automáticas, nunca una reasignación manual.</p>' +
        '<div class="utable-wrap"><table class="utable" id="rrTable"><thead><tr><th>ORDEN</th><th>ESTADO (contiene)</th><th>ZONA (contiene)</th><th>TRANSPORTISTA</th><th>ACTIVA</th><th></th></tr></thead><tbody>' +
        rules.map((r, i) => '<tr data-i="' + i + '"><td>' + (i + 1) + ' <button type="button" data-up>↑</button><button type="button" data-down>↓</button></td><td><input class="ed" data-k="estado" value="' + esc(r.estado) + '"></td><td><input class="ed" data-k="zona" value="' + esc(r.zona || '') + '"></td>' +
          '<td><select data-k="carrier">' + cs.map(c => '<option' + (c.name === r.carrier ? ' selected' : '') + '>' + esc(c.name) + '</option>').join('') + '</select></td><td><input type="checkbox" data-k="active"' + (r.active !== false ? ' checked' : '') + '></td><td><button type="button" class="btn soft" data-rm>QUITAR</button></td></tr>').join('') +
        '</tbody></table></div><div class="uact"><button class="btn soft" type="button" id="rrAdd">+ AGREGAR REGLA</button><button class="btn dark" type="button" id="rrSave">GUARDAR NUEVA VERSIÓN</button></div>';
      sec.querySelectorAll('#rrTable tr[data-i]').forEach(tr => {
        const i = +tr.dataset.i;
        tr.querySelectorAll('[data-k]').forEach(x => x.onchange = () => { rules[i][x.dataset.k] = x.type === 'checkbox' ? x.checked : x.value; });
        tr.querySelector('[data-up]').onclick = () => { if (i > 0) { [rules[i - 1], rules[i]] = [rules[i], rules[i - 1]]; draw(); } };
        tr.querySelector('[data-down]').onclick = () => { if (i < rules.length - 1) { [rules[i + 1], rules[i]] = [rules[i], rules[i + 1]]; draw(); } };
        tr.querySelector('[data-rm]').onclick = () => { rules.splice(i, 1); draw(); };
      });
      sec.querySelector('#rrAdd').onclick = () => { rules.push({ estado: '', zona: '', carrier: cs[0] ? cs[0].name : '', active: true }); draw(); };
      sec.querySelector('#rrSave').onclick = () => run(async () => {
        const out = rules.map((r, i) => ({ estado: String(r.estado || '').trim().toUpperCase(), zona: String(r.zona || '').trim().toUpperCase(), carrier: r.carrier, priority: i + 1, active: r.active !== false }));
        if (out.some(r => !r.estado || !r.carrier)) throw new Error('Cada regla necesita estado y transportista.');
        const nf = await api.setRoutingRules(out); if (window.OKD_APPLY_ROUTING) window.OKD_APPLY_ROUTING(nf);
      }, 'Reglas de asignación guardadas como versión nueva.', again);
    };
    draw();
  },
  // Planes de financiación propia (lectura para todos los que acceden; confirmar frecuencia solo con permiso)
  async financiacion(api, me, sec, again) {
    const plans = await api.listFinancingPlans(), can = hasPerm(me, 'credit_notes.manage') || hasPerm(me, 'settings.manage');
    const fl = f => f === 'POR_CONFIRMAR' ? 'POR CONFIRMAR' : f;
    sec.innerHTML = '<h2><span class="n">D3</span>FINANCIACIÓN PROPIA</h2><p class="rp-note">Planes detectados en las importaciones del Saldo Comprobante. Saldo operativo = saldo fuente − ajustes NOC de OK Despacho. La frecuencia se determina sola solo con evidencia; si no, queda POR CONFIRMAR.</p>' +
      '<div class="utable-wrap"><table class="utable" id="finTable"><thead><tr><th>CLIENTE</th><th>CUIT/DNI</th><th>COMPROBANTE</th><th>ESTADO</th><th>SALDO FUENTE</th><th>AJUSTE NOC</th><th>SALDO OPERATIVO</th><th>FRECUENCIA</th><th>PRÓXIMA CUOTA</th><th>ÚLTIMA IMPORTACIÓN</th></tr></thead><tbody>' +
      (plans.length ? plans.map(p => '<tr data-plan="' + p.id + '"><td>' + esc(p.client_name || '') + '</td><td>' + esc(p.client_key) + '</td><td>' + esc(p.comp_label || p.comp) + '</td><td>' + p.status + '</td><td>$ ' + fmt(p.source_pending) + '</td><td>$ ' + fmt(p.noc_adjustments) + '</td><td><b>$ ' + fmt(p.operational_pending) + '</b></td>' +
        '<td>' + fl(p.frequency) + (p.frequency_source === 'CONFIRMADA' ? '<br><small>confirmada por ' + esc(p.confirmed_by_name || '—') + ' · ' + dt(p.frequency_confirmed_at) + ' · ' + esc(p.frequency_reason || '') + '</small>' : '') +
        (p.frequency === 'POR_CONFIRMAR' && can ? '<div class="uact"><input class="ed" data-why placeholder="Motivo (obligatorio)"><button class="btn soft" type="button" data-f="SEMANAL">CONFIRMAR SEMANAL</button><button class="btn soft" type="button" data-f="MENSUAL">CONFIRMAR MENSUAL</button></div>' : '') + '</td>' +
        '<td>' + (p.next_due ? esc(p.next_due.split('-').reverse().join('/')) + (p.next_amount ? ' · $ ' + fmt(p.next_amount) : '') : '—') + '</td><td>' + esc(p.last_import_id || '') + '<br><small>' + dt(p.last_source_at) + '</small></td></tr>').join('') : '<tr><td colspan="10">Sin planes de financiación.</td></tr>') + '</tbody></table></div>';
    sec.querySelectorAll('[data-f]').forEach(b => b.onclick = () => { const tr = b.closest('tr'), why = tr.querySelector('[data-why]').value.trim();
      if (!why) { again({ err: true, text: 'Indicá el motivo de la confirmación.' }); return; }
      run(() => api.confirmFinancingFrequency(tr.dataset.plan, b.dataset.f, why), 'Frecuencia confirmada (' + b.dataset.f + ').', again); });
  },
  async emails(api, me, sec, again) {
    const [ir, ns, hist, users] = await Promise.all([api.irSettings().catch(() => ({})), api.notificationSettings(), api.emailHistory().catch(() => []), api.listUsers().catch(() => [])]);
    const sups = users.filter(u => hasPerm(u, 'can_approve_internal_route_changes'));
    sec.innerHTML = '<h2><span class="n">E</span>EMAILS Y NOTIFICACIONES</h2><div class="cfgform" id="mailForm">' +
      '<label>Superior para rutas internas <select data-f="sup"><option value="">— ninguno (avisa a Administración) —</option>' + sups.map(u => '<option value="' + u.id + '"' + (ir.supervisor_user_id === u.id ? ' selected' : '') + '>' + esc(u.full_name) + '</option>').join('') + '</select></label>' +
      '<label>Emails adicionales (rutas internas) <input data-f="extra" value="' + esc((ir.extra_emails || []).join(', ')) + '"></label>' +
      '<label class="chk"><input type="checkbox" data-f="copy"' + (ir.copy_admin !== false ? ' checked' : '') + '> Copiar a Administración</label><label class="chk"><input type="checkbox" data-f="irmail"' + (ir.email_enabled !== false ? ' checked' : '') + '> Emails de aprobación</label>' +
      '<label class="chk"><input type="checkbox" data-f="otw"' + (ns.on_the_way_enabled !== false ? ' checked' : '') + '> "Tu pedido va en camino" al cliente</label><label class="chk"><input type="checkbox" data-f="dlv"' + (ns.delivered_enabled !== false ? ' checked' : '') + '> Confirmación de entrega al cliente</label>' +
      '<label class="chk"><input type="checkbox" data-f="push"' + (ir.push_enabled ? ' checked' : '') + '> Push (preparado)</label><label>Proveedor <input data-f="prov" value="' + esc(ns.provider || 'RESEND') + '"></label><label>Reintentos máximos <input data-f="retry" value="' + (ns.max_retries ?? 5) + '"></label></div>' +
      '<p class="rp-note">Informes de Cristian: destinatarios y horario en INFORMES → CONFIGURACIÓN. Email de PDFs de hojas: en F. PDF Y ENVÍOS. Los emails de acceso (invitación y recuperación) los envía Supabase Auth: para producción configurá un SMTP propio (Authentication → SMTP) para evitar el límite de envíos.</p><button class="btn dark" type="button" id="mailSave">GUARDAR</button>' +
      '<h3 class="dsub">HISTORIAL DE EMAILS</h3><div class="utable-wrap"><table class="utable" id="mailHist"><thead><tr><th>TIPO</th><th>DESTINATARIO</th><th>ESTADO</th><th>ERROR</th><th></th></tr></thead><tbody>' +
      (hist.length ? hist.map(j => '<tr data-j="' + j.id + '" data-src="' + j.source + '"><td>' + esc(j.label) + '</td><td>' + esc(j.recipient) + '</td><td>' + j.status + '</td><td>' + esc(j.error || '') + '</td><td>' + (j.status !== 'SENT' && j.source !== 'sheet' ? '<button class="btn soft" type="button" data-retry>REINTENTAR EMAIL</button>' : '') + '</td></tr>').join('') : '<tr><td colspan="5">Sin emails.</td></tr>') + '</tbody></table></div>';
    const g = k => sec.querySelector('[data-f="' + k + '"]');
    sec.querySelector('#mailSave').onclick = () => run(async () => {
      const extra = g('extra').value.split(',').map(x => x.trim()).filter(Boolean);
      if (extra.some(e => !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(e))) throw new Error('Hay un email adicional inválido.');
      await api.setIrSettings({ supervisor_user_id: g('sup').value || null, copy_admin: g('copy').checked, extra_emails: extra, email_enabled: g('irmail').checked, push_enabled: g('push').checked });
      await api.setNotificationSettings({ on_the_way_enabled: g('otw').checked, delivered_enabled: g('dlv').checked, provider: g('prov').value.trim() || 'RESEND', max_retries: parseInt(g('retry').value, 10) || 5 });
    }, 'Configuración de emails guardada.', again);
    sec.querySelectorAll('[data-retry]').forEach(b => b.onclick = () => { const tr = b.closest('tr'); run(() => tr.dataset.src === 'customer' ? api.sendCustomerQueued([tr.dataset.j]) : api.sendQueuedApprovalEmails([tr.dataset.j]), 'Reintento enviado.', again); });
  },
  async pdf(api, me, sec, again) {
    const [c, ns] = await Promise.all([api.dispatchSettings(), api.notificationSettings()]);
    sec.innerHTML = '<h2><span class="n">F</span>PDF Y ENVÍOS</h2><div class="cfgform" id="pdfCfg">' +
      '<label class="chk"><input type="checkbox" id="pcGen"' + (c.pdf_auto_generate ? ' checked' : '') + '> GENERAR PDF AUTOMÁTICAMENTE AL PUBLICAR <em>(recomendado)</em></label>' +
      '<label class="chk"><input type="checkbox" id="pcDl"' + (c.pdf_auto_download ? ' checked' : '') + '> DESCARGAR PDF AUTOMÁTICAMENTE AL PUBLICAR</label>' +
      '<p class="rp-note">Al publicar una hoja, OK Despacho genera y guarda el PDF. Si esta opción está activa, también intenta descargarlo en este dispositivo. Cada versión se guarda aparte (v1, v2…).</p>' +
      '<label class="chk"><input type="checkbox" id="seOn"' + (ns.sheet_email_enabled ? ' checked' : '') + '> Enviar por email los PDF de las hojas del día</label><label>Horario (Mendoza) <input id="seTime" value="' + esc(ns.sheet_email_time || '18:00') + '"></label>' +
      '<label>Destinatarios <input id="seTo" value="' + esc((ns.sheet_email_recipients || []).join(', ')) + '"></label></div><button class="btn dark" type="button" id="pcSave">GUARDAR</button>';
    sec.querySelector('#pcSave').onclick = () => run(async () => {
      const to = sec.querySelector('#seTo').value.split(',').map(x => x.trim()).filter(Boolean), time = sec.querySelector('#seTime').value.trim();
      if (!/^([01][0-9]|2[0-3]):[0-5][0-9]$/.test(time)) throw new Error('Horario inválido (HH:MM).');
      if (to.some(e => !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(e))) throw new Error('Hay un email inválido.');
      await api.setDispatchSettings(sec.querySelector('#pcGen').checked, sec.querySelector('#pcDl').checked);
      await api.setNotificationSettings({ sheet_email_enabled: sec.querySelector('#seOn').checked, sheet_email_time: time, sheet_email_recipients: to });
    }, 'Configuración de PDF y envíos guardada.', again);
  },
  async ubicaciones(api, me, sec, again) {
    const ls = await api.listLocations();
    sec.innerHTML = '<h2><span class="n">G</span>UBICACIONES</h2><p class="rp-note">Ubicación maestra por cliente. Al llegar y al finalizar una parada, si el GPS queda fuera del radio se registra una advertencia (nunca se inventa la ubicación).</p>' +
      '<div class="utable-wrap"><table class="utable" id="locTable"><thead><tr><th>CLIENTE</th><th>DOMICILIO</th><th>LAT, LON</th><th>RADIO</th><th>ACTIVO</th><th>NOTA</th></tr></thead><tbody>' +
      (ls.length ? ls.map(l => '<tr><td>' + esc(l.client_name || l.client_key) + '</td><td>' + esc(l.address || '') + '</td><td>' + l.lat + ', ' + l.lon + '</td><td>' + l.radius_m + ' m</td><td>' + (l.active !== false ? 'Sí' : 'No') + '</td><td>' + esc(l.note || '') + '</td></tr>').join('') : '<tr><td colspan="6">Sin ubicaciones.</td></tr>') + '</tbody></table></div>' +
      '<div class="ufilters" id="locNew"><input id="lcKey" placeholder="CUIT / clave del cliente"><input id="lcName" placeholder="Cliente"><input id="lcAddr" placeholder="Domicilio"><input id="lcLat" placeholder="Latitud"><input id="lcLon" placeholder="Longitud"><input id="lcRad" placeholder="Radio (m)" value="200"><input id="lcNote" placeholder="Nota"><button class="btn dark" type="button" id="lcSave">GUARDAR UBICACIÓN</button></div>';
    const v = id => sec.querySelector(id).value.trim();
    sec.querySelector('#lcSave').onclick = () => run(() => api.saveLocation({ client_key: v('#lcKey'), client_name: v('#lcName'), address: v('#lcAddr'), lat: v('#lcLat').replace(',', '.'), lon: v('#lcLon').replace(',', '.'), radius_m: parseInt(v('#lcRad'), 10) || 200, note: v('#lcNote'), active: true }), 'Ubicación guardada.', again);
  },
  async ubicaciones_interno(api, me, sec, again) {
    const ls = await api.listInternalLocations();
    sec.innerHTML = '<h2><span class="n">G2</span>UBICACIONES TRANSPORTISTA INTERNO</h2><p class="rp-note">Puntos fijos propios (sucursales, depósito u otros destinos internos). Cuando el Transportista Interno marca LLEGUÉ o finaliza una parada vinculada, el GPS se compara con este punto y, si queda fuera del radio permitido, se registra la advertencia FUERA DEL RADIO.</p>' +
      '<div class="utable-wrap"><table class="utable" id="ilocTable"><thead><tr><th>CLAVE</th><th>PUNTO</th><th>DOMICILIO</th><th>LAT, LON</th><th>RADIO</th><th>ACTIVO</th><th>NOTA</th></tr></thead><tbody>' +
      (ls.length ? ls.map(l => '<tr><td><b>' + esc(l.location_key) + '</b></td><td>' + esc(l.name) + '</td><td>' + esc(l.address || '') + '</td><td>' + l.lat + ', ' + l.lon + '</td><td>' + l.radius_m + ' m</td><td>' + (l.active !== false ? 'Sí' : 'No') + '</td><td>' + esc(l.note || '') + '</td></tr>').join('') : '<tr><td colspan="7">Sin ubicaciones internas.</td></tr>') + '</tbody></table></div>' +
      '<div class="ufilters" id="ilocNew"><input id="ilKey" placeholder="Clave (ej. SAN_JUAN)"><input id="ilName" placeholder="Sucursal / punto"><input id="ilAddr" placeholder="Domicilio"><button class="btn soft" type="button" id="ilGeocode">BUSCAR COORDENADAS</button><input id="ilLat" placeholder="Latitud"><input id="ilLon" placeholder="Longitud"><input id="ilRad" placeholder="Radio (m)" value="200"><input id="ilNote" placeholder="Nota"><button class="btn dark" type="button" id="ilSave">GUARDAR PUNTO INTERNO</button></div><div id="ilGeoMsg" class="rp-note"></div>' +
      '<p class="rp-note">Una parada se vincula a un punto SOLO por su clave (al elegir la ubicación en el constructor). Al publicar, la hoja guarda las coordenadas y el radio de ese momento: editar o desactivar un punto después no cambia hojas ya publicadas.</p>';
    const v = id => sec.querySelector(id).value.trim();
    sec.querySelector('#ilGeocode').onclick = async () => {
      const btn = sec.querySelector('#ilGeocode'), out = sec.querySelector('#ilGeoMsg');
      const address = v('#ilAddr'), name = v('#ilName');
      if (!address) { out.textContent = 'Ingresá el domicilio antes de buscar las coordenadas.'; return; }
      btn.disabled = true; out.textContent = 'Buscando ubicación…';
      try {
        const g = await api.geocodeInternalLocation(address, name);
        const PREC = { ADDRESS: 'altura exacta', STREET: 'solo la calle', AREA: 'aproximado (barrio/localidad)' };
        const pick = c => { sec.querySelector('#ilLat').value = c.lat; sec.querySelector('#ilLon').value = c.lon; sec.dataset.geoSource = c.source || ''; sec.dataset.geoName = c.display_name || '';
          out.innerHTML = '<b>Punto elegido:</b> ' + esc(c.display_name || address) + ' · <i>' + esc(PREC[c.precision] || '') + '</i> · ' + esc(c.source || '') +
            ' · <a href="https://www.openstreetmap.org/?mlat=' + c.lat + '&mlon=' + c.lon + '#map=18/' + c.lat + '/' + c.lon + '" target="_blank" rel="noopener">ver en el mapa</a>. Revisá el punto y después guardalo.'; };
        const list = (g.candidates || []).length ? g.candidates : [g.best || g.result];
        if (list.length > 1 && (g.ambiguous || g.needs_review)) {
          // varias coincidencias o resultado impreciso: elegir explícitamente (no se toma el primero a ciegas)
          out.innerHTML = '<b>' + esc(g.warning || 'Elegí la coincidencia correcta:') + '</b><div class="geo-cands">' + list.map((c, i) => '<label class="chk"><input type="radio" name="geoC" value="' + i + '"> ' +
            esc(c.display_name) + ' · <i>' + esc(PREC[c.precision] || '') + '</i></label>').join('') + '</div>';
          out.querySelectorAll('[name="geoC"]').forEach(r => r.onchange = () => pick(list[+r.value]));
        } else { pick(list[0]); if (g.warning) out.insertAdjacentHTML('beforeend', '<br><b>⚠ ' + esc(g.warning) + '</b>'); }
      } catch (e) {
        out.textContent = e.message;
      } finally { btn.disabled = false; }
    };
    sec.querySelector('#ilSave').onclick = () => run(() => {
      const key = v('#ilKey').toUpperCase().replace(/[^A-Z0-9_-]+/g, '_');
      if (!key || !v('#ilName') || !v('#ilLat') || !v('#ilLon')) throw new Error('Completá clave, punto y coordenadas.');
      return api.saveInternalLocation({ location_key: key, name: v('#ilName'), address: v('#ilAddr'), lat: v('#ilLat').replace(',', '.'), lon: v('#ilLon').replace(',', '.'), radius_m: parseInt(v('#ilRad'), 10) || 200, note: v('#ilNote'), active: true,
        geocode_source: sec.dataset.geoSource || null, geocode_display_name: sec.dataset.geoName || null });
    }, 'Punto interno guardado.', again);
  },
  async backup(api, me, sec, again) { await backupSection(api, me, sec, again); },
  async general(api, me, sec, again) {
    const g = await api.appSettings();
    sec.innerHTML = '<h2><span class="n">I</span>PARÁMETROS GENERALES</h2><div class="cfgform" id="genForm"><label>Empresa <input data-f="company" value="' + esc(g.company || 'OK Accesorios') + '"></label><label>Zona horaria <input value="America/Argentina/Mendoza" disabled></label>' +
      '<label>Borrador antiguo después de (días) <input data-f="stale" value="' + (g.draft_stale_days ?? 2) + '"></label><label>Plazo para DEVOLVER HOJA (días, fijo) <input value="2" disabled></label></div><button class="btn dark" type="button" id="genSave">GUARDAR</button>';
    sec.querySelector('#genSave').onclick = () => run(async () => { const st = parseInt(sec.querySelector('[data-f="stale"]').value, 10); if (!(st >= 1)) throw new Error('Los días deben ser 1 o más.'); await api.setAppSettings({ company: sec.querySelector('[data-f="company"]').value.trim(), draft_stale_days: st }); }, 'Parámetros guardados.', again);
  }
};

// ================= AUDITORÍA =================
// ===== RC3 · CONCILIACIÓN NOC (solo Administración) =====
const fmtMoney = v => '$ ' + Number(v || 0).toLocaleString('es-AR', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const RC_LABEL = { OK: 'Sin diferencias', PENDING_CIANBOX: 'Pendiente de Cianbox', CANCELLED_ROUTE_REVIEW: 'Hoja cancelada — revisar', RECONCILED: 'Conciliada', REVERSED: 'Revertida', CIANBOX_DIFFERENCE: 'Diferencia detectada' };
const RC_REASON = { SIN_REFLEJAR: 'Cianbox aún no refleja la aplicación registrada en OK Despacho.', REDUCCION_PARCIAL: 'Cianbox reconoce solo una parte de lo aplicado.', SALDO_MAYOR: 'Cianbox informa más saldo que el esperado.',
  NO_INFORMADA: 'La NOC no figura en la última importación del Saldo Comprobante: revisar antes de cualquier decisión.', SALDO_CERO: 'Cianbox ya no informa saldo.', REDUCCION_EXACTA: 'Cianbox refleja exactamente lo aplicado.' };
export async function openNocRecon(api, me) {
  const w = frame(me, 'Conciliación NOC', '#/conciliacion-noc');
  let filter = 'todos';
  const FILTERS = [['todos', 'TODOS'], ['pendientes', 'PENDIENTES DE CIANBOX'], ['cancelada', 'HOJA CANCELADA'], ['diferencias', 'DIFERENCIAS CIANBOX'], ['conciliados', 'CONCILIADOS'], ['revertidos', 'REVERTIDOS']];
  const again = async m => {
    let rows = [];
    try { rows = await api.nocReconciliationList(filter); } catch (e) { w.innerHTML = '<div class="up-msg err">' + esc(e.message) + '</div>'; return; }
    w.innerHTML = '<section class="cfg-sec"><h2><span class="n">$</span>CONCILIACIÓN NOC</h2><p class="rp-note">Cianbox informa el saldo contable; OK Despacho registra las aplicaciones operativas. Una importación nunca borra una aplicación, y cancelar una hoja publicada no devuelve la NOC: queda acá para que Administración decida.</p>' +
      (m ? '<div class="up-msg ' + (m.err ? 'err' : 'ok') + '" id="adMsg">' + esc(m.text) + '</div>' : '<div id="adMsg"></div>') +
      '<div class="uact" id="rcFilters">' + FILTERS.map(([k, l]) => '<button type="button" class="btn ' + (k === filter ? 'dark' : 'soft') + '" data-filter="' + k + '">' + l + '</button>').join('') + '</div>' +
      '<div class="utable-wrap"><table class="utable" id="rcTable"><thead><tr><th>NOC</th><th>CLIENTE / CUIT</th><th>EMISIÓN</th><th>ORIGINAL</th><th>SALDO CIANBOX</th><th>RESERVADO</th><th>CONSUMIDO</th><th>REVERTIDO</th><th>UTILIZABLE</th><th>APLICACIÓN</th><th>HOJA / PEDIDO</th><th>ESTADO</th><th>ÚLTIMA IMPORTACIÓN</th><th>DIFERENCIA</th><th></th></tr></thead><tbody>' +
      (rows.length ? rows.map(r => {
        const st = r.application_state || r.note_state, reason = r.detail && r.detail.reason ? RC_REASON[r.detail.reason] || '' : '';
        const acts = r.application_status !== 'CONSUMED' ? '' : '<div class="uact"><input class="ed" data-why placeholder="Motivo (obligatorio)">' +
          (st === 'CANCELLED_ROUTE_REVIEW' ? '<button class="btn soft" type="button" data-act="KEEP">MANTENER APLICADA</button>' : '') +
          (st !== 'RECONCILED' ? '<button class="btn danger" type="button" data-act="REVERSE">REVERTIR A DISPONIBLE</button>' : '') +
          (st !== 'RECONCILED' && st !== 'CANCELLED_ROUTE_REVIEW' ? '<button class="btn soft" type="button" data-act="RECONCILE">CONFIRMAR CONCILIACIÓN</button>' : '') + '</div>';
        return '<tr data-app="' + r.application_id + '" data-ver="' + r.recon_version + '" data-amt="' + r.application_amount + '"><td><b>' + esc(r.comp) + '</b></td><td>' + esc(r.client_name || '—') + '<br><small>' + esc(r.cuit || '') + '</small></td><td>' + esc(r.issued_date || '') + '</td>' +
          '<td>' + fmtMoney(r.original_amount) + '</td><td>' + (r.source_remaining_amount == null ? '<small>sin importación</small>' : fmtMoney(r.source_remaining_amount)) + '</td><td>' + fmtMoney(r.reserved_amount) + '</td><td>' + fmtMoney(r.consumed_amount) + '</td><td>' + fmtMoney(r.reversed_amount) + '</td>' +
          '<td><b>' + fmtMoney(r.effective_available) + '</b></td><td>' + fmtMoney(r.application_amount) + '</td><td>' + esc(r.route_number || '—') + (r.route_status ? ' <small>(' + esc(r.route_status.toLowerCase()) + ')</small>' : '') + '<br><small>pedido ' + esc((r.order_numbers || []).join(' + ') || '—') + '</small></td>' +
          '<td><span class="rcst ' + st + '">' + esc(RC_LABEL[st] || st) + '</span>' + (reason ? '<br><small>' + esc(reason) + '</small>' : '') + (r.resolution_reason ? '<br><small>Motivo: ' + esc(r.resolution_reason) + '</small>' : '') + (r.cancel_reason ? '<br><small>Cancelación: ' + esc(r.cancel_reason) + '</small>' : '') + '</td>' +
          '<td>' + esc(r.last_source_import || '—') + (r.last_source_seen_at ? '<br><small>' + dt(r.last_source_seen_at) + '</small>' : '') + '</td><td>' + (r.difference == null ? '—' : fmtMoney(r.difference)) + '</td><td>' + acts + '</td></tr>';
      }).join('') : '<tr><td colspan="15">Sin Notas de Crédito en este filtro.</td></tr>') + '</tbody></table></div></section>';
    w.querySelectorAll('[data-filter]').forEach(b => b.onclick = () => { filter = b.dataset.filter; again(); });
    w.querySelectorAll('[data-act]').forEach(b => b.onclick = async () => {
      const tr = b.closest('tr'), why = tr.querySelector('[data-why]').value.trim(), act = b.dataset.act;
      if (act !== 'RECONCILE' && !why) { again({ err: true, text: 'Indicá el motivo.' }); return; }
      if (act === 'REVERSE' && !confirm('Vas a devolver ' + fmtMoney(tr.dataset.amt) + ' al saldo utilizable de esta Nota de Crédito. Esta acción quedará auditada. ¿Confirmar?')) return;
      if (act === 'KEEP' && !confirm('La Nota de Crédito queda aplicada a ese pedido/cliente (no se libera saldo). Esta acción quedará auditada. ¿Confirmar?')) return;
      try {
        await api.nocResolveApplication(tr.dataset.app, act, why || 'Conciliación confirmada', Number(tr.dataset.ver), 'ui-' + act + '-' + tr.dataset.app);
        again({ text: { KEEP: 'Aplicación mantenida (auditada).', REVERSE: 'Aplicación revertida: el saldo volvió a estar disponible (auditado).', RECONCILE: 'Conciliación confirmada (auditada).' }[act] });
      } catch (e) {
        const conflict = /NOC_CONFLICT/.test(e.message || '');
        again({ err: true, text: conflict ? 'Otra persona modificó esta Nota de Crédito al mismo tiempo. Se recargó el estado real: revisalo y volvé a intentar.' : String(e.message || e).replace(/^[A-Z_]+:\s*/, '') });
      }
    });
  };
  await again();
}
export async function openAudit(api, me) {
  const w = frame(me, 'Auditoría', '#/auditoria');
  w.innerHTML = '<div class="up-head"><h2>AUDITORÍA</h2><span class="rp-note">Solo lectura</span></div><div class="ufilters"><input id="auUser" placeholder="Usuario"><input id="auAction" placeholder="Acción"><input id="auTarget" placeholder="Hoja / id"><input id="auText" placeholder="Pedido / texto">' +
    '<select id="auModule"><option value="">Módulo</option>' + ['USUARIOS', 'BORRADORES', 'HOJAS', 'APROBACIONES', 'VEHÍCULOS', 'INFORMES', 'BACKUP', 'CONFIGURACIÓN'].map(m => '<option>' + m + '</option>').join('') + '</select><input id="auFrom" type="date"><button class="btn dark" type="button" id="auGo">BUSCAR</button></div><div id="auList"></div>';
  const go = async () => {
    const v = id => w.querySelector(id).value.trim(); let rows = [];
    try { rows = await api.auditSearch({ user: v('#auUser'), action: v('#auAction'), target: v('#auTarget'), text: v('#auText'), module: v('#auModule'), from: v('#auFrom') }); } catch (e) { w.querySelector('#auList').innerHTML = '<div class="up-msg err">' + esc(e.message) + '</div>'; return; }
    w.querySelector('#auList').innerHTML = '<div class="utable-wrap"><table class="utable" id="auTable"><thead><tr><th>FECHA</th><th>USUARIO</th><th>MÓDULO</th><th>ACCIÓN</th><th>OBJETO</th><th>DETALLE</th></tr></thead><tbody>' +
      (rows.length ? rows.map(a => '<tr><td>' + dt(a.at) + '</td><td>' + esc(a.actor_name || '') + '</td><td>' + moduleOfAction(a.action) + '</td><td>' + esc(a.action) + '</td><td>' + esc(a.target_id || '') + '</td><td><small>' + esc(JSON.stringify(a.after || a.before || '').slice(0, 140)) + '</small></td></tr>').join('') : '<tr><td colspan="6">Sin eventos.</td></tr>') + '</tbody></table></div>';
  };
  w.querySelector('#auGo').onclick = go; await go();
}

// ================= BACKUP =================
async function backupSection(api, me, sec, again) {
  sec.innerHTML = '<h2><span class="n">H</span>BACKUP</h2><p class="rp-note">Genera UN archivo .zip con: datos de todas las tablas (data.json), configuración, los ARCHIVOS de Storage (PDF de hojas, DNI e informes) en storage/, un manifest con SHA-256 de cada tabla y de cada archivo, y las instrucciones de restauración. No borra nada. Incluye las identidades de usuarios SIN contraseñas. Restaurar SIEMPRE primero en un proyecto de prueba con las migraciones aplicadas (scripts/restore_backup.mjs).</p>' +
    '<button class="btn dark" type="button" id="bkGo">GENERAR BACKUP</button><div id="bkOut"></div>';
  sec.querySelector('#bkGo').onclick = async () => {
    const out = sec.querySelector('#bkOut'); out.innerHTML = '<p class="rp-note" id="bkProg">Generando datos…</p>';
    try {
      const b = await api.backupExport(), enc = new TextEncoder(), files = [], storageFiles = {};
      for (const [bucket, info] of Object.entries(b.manifest.storage || {})) {
        storageFiles[bucket] = [];
        for (const name of info.names || []) {
          const prog = sec.querySelector('#bkProg'); if (prog) prog.textContent = 'Descargando ' + bucket + '/' + name + '…';
          const f = await api.backupFile(bucket, name), bytes = b64ToBytes(f.base64), h = await sha256Hex(bytes);
          if (h !== f.sha256) throw new Error('Hash distinto en ' + bucket + '/' + name + ': el backup se cancela.');
          files.push({ name: 'storage/' + bucket + '/' + name, data: bytes }); storageFiles[bucket].push({ name, size: bytes.length, sha256: h });
        }
      }
      const manifest = { ...b.manifest, storage_files: storageFiles, format: 'okdespacho-backup-v2' };
      const zip = zipStore([{ name: 'manifest.json', data: enc.encode(JSON.stringify(manifest, null, 1)) }, { name: 'data.json', data: enc.encode(JSON.stringify(b.data)) },
        { name: 'auth_users.json', data: enc.encode(JSON.stringify(b.auth_users || [])) }, { name: 'README_RESTAURAR.txt', data: enc.encode(b.readme) }, ...files]);
      const name = 'okdespacho-backup-' + b.manifest.created_at.slice(0, 19).replace(/[:T]/g, '-') + '.zip';
      const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob([zip], { type: 'application/zip' })); a.download = name; document.body.appendChild(a); a.click(); a.remove();
      const nFiles = files.length;
      out.innerHTML = '<div class="up-msg ok" id="bkOk">Backup generado: ' + esc(name) + ' · ' + Object.keys(b.manifest.tables).length + ' tablas · ' + nFiles + ' archivo(s) de Storage verificados por SHA-256.</div><pre class="bkreadme">' + esc(b.readme) + '</pre>';
    } catch (e) { out.innerHTML = '<div class="up-msg err">' + esc(e.message) + '</div>'; }
  };
}
export async function openBackup(api, me) { const w = frame(me, 'Backup', '#/backup'); const sec = document.createElement('section'); sec.className = 'step rp-step'; sec.id = 'cfg-backup'; w.appendChild(sec); await backupSection(api, me, sec, () => openBackup(api, me)); }

// RC4: secciones reutilizables desde Configuración operativa (el servidor valida el permiso igual)
export const plantillasSection = (api, me, sec, again) => CFG.plantillas(api, me, sec, again);
export const frameFor = (me, title, active) => frame(me, title, active);
