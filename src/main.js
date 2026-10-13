import './styles/offline.css';
import './styles/online.css';
import { createApi } from './online/api.js';
import { renderLogin, renderSetPassword, renderNewPassword } from './online/auth-ui.js';
import { UsersPanel } from './online/users-ui.js';
import { openAccount } from './online/account-ui.js';
import { esc } from './online/util.js';
import { hasPerm, ROLE_LABEL } from '../supabase/functions/_shared/rules.js';

const api = createApi();
const $ = s => document.querySelector(s);
const show = id => ['#auth', '#noPanel', '#operario'].forEach(s => { $(s).hidden = s !== id; });
let legacyLoaded = false;

async function loadText(url) { const r = await fetch(url); if (!r.ok) throw new Error('No se pudo cargar ' + url); return r.text(); }
function loadScript(url) {
  return new Promise((res, rej) => { const s = document.createElement('script'); s.src = url; s.onload = res; s.onerror = () => rej(new Error('No se pudo cargar ' + url)); document.body.appendChild(s); });
}
// Panel del Operario = versión offline v15 sin cambios de lógica (se carga recién con sesión válida)
async function loadLegacy() {
  if (legacyLoaded) return;
  // Puente con el servidor: la confirmación de envíos provisorios se guarda server-side
  window.OKD_BRIDGE = {
    shipping: { confirm: p => api.shippingConfirm(p), invalidate: p => api.shippingInvalidate(p) },
    orders: { reserve: (k, o) => api.reserveOrders(k, o), release: (k, o) => api.releaseOrders(k, o) },
    noc: { reconcile: (imp, items, complete) => api.reconcileCreditNotes(imp, items, complete), reassociate: (app, k) => api.nocReassociate(app, k), detect: (k, items) => api.detectCreditNotes(k, items), apply: p => api.applyCreditNote(p), applyFinancing: p => api.consumeCreditNoteFinancing(p), release: (k, fp) => api.releaseCreditNote(k, fp) },
    financing: { keys: () => api.financingPlanKeys(), sync: (imp, plans) => api.syncFinancingPlans(imp, plans), forClients: keys => api.financingPlansFor(keys) },
    drafts: { touch: (k, n, c, cnt, o, content) => api.touchDraft(k, n, c, cnt, o, content), content: k => api.draftContent(k), remove: k => api.deleteDraft(k) },
    routes: { routing: () => api.routingRules(), rules: () => api.financialRules(), template: id => api.currentTemplate(id), pdf: { settings: () => api.dispatchSettings(), save: (id, v, n, b) => api.saveRoutePdf(id, v, n, b), error: (id, v, m) => api.routePdfError(id, v, m), snapshot: id => api.routePdfSnapshot(id), download: (id, v) => api.downloadRoutePdf(id, v) },
      vehicles: () => api.listVehicles(), carriers: () => api.listCarriers(), responsables: id => api.responsables(id), publish: async p => { try { return await api.publishRoute(p); } catch (e) {
        // Reglas financieras cambiadas: se recalcula con la versión vigente y se pide revisar antes de publicar
        if (/ROUTING_RULES_OUTDATED/.test(e.message || '')) { const g = await api.routingRules(); window.OKD_APPLY_ROUTING && window.OKD_APPLY_ROUTING(g); throw new Error('Las reglas de asignación cambiaron (v' + g.version + '). Se recalcularon solo las asignaciones automáticas (las reasignaciones manuales se conservan): revisá la hoja y publicá de nuevo.'); }
        if (/(^|[^_])RULES_OUTDATED/.test(e.message || '')) { const f = await api.financialRules(); window.OKD_APPLY_RULES && window.OKD_APPLY_RULES(f); throw new Error('Las reglas financieras cambiaron (v' + f.version + '). Se recalculó la hoja: revisá los montos y publicá de nuevo.'); }
        throw e; } }, status: id => api.routeStatus(id), subscribe: cb => api.subscribe(cb) }
  };
  const [xlsx, worker] = await Promise.all([loadText('/legacy/xlsx.full.min.js'), loadText('/legacy/worker.js')]);
  $('#src-xlsx').textContent = xlsx; $('#src-worker').textContent = worker;
  for (const f of ['exceljs.min.js', 'jspdf.umd.min.js', 'jspdf.plugin.autotable.min.js', 'financing.js', 'despacho-v15.js']) await loadScript('/legacy/' + f);
  legacyLoaded = true;
}

// ===== Módulos (RC1.1): el menú muestra solo lo autorizado y cada URL valida el permiso (el servidor valida igual) =====
const canApprovals = me => hasPerm(me, 'can_approve_internal_route_changes');
const adminUi = () => import('./online/admin-ui.js');
const isAdminHome = me => hasPerm(me, 'users.view') || hasPerm(me, 'settings.manage');
const MODULE_ROUTES = {
  '#/dashboard': { ok: isAdminHome, open: async me => (await adminUi()).openDashboard(api, me) },
  '#/despacho': { ok: me => hasPerm(me, 'routes.create'), open: () => closeOverlay() },
  '#/borradores': { ok: me => hasPerm(me, 'routes.create'), open: async me => (await adminUi()).openDrafts(api, me) },
  '#/historial': { ok: me => hasPerm(me, 'routes.view_all'), open: async me => (await adminUi()).openHistory(api, me) },
  '#/aprobaciones': { ok: canApprovals, open: async me => { const { ApprovalsPanel } = await import('./online/approvals-ui.js'); await new ApprovalsPanel(api, me).open(); await withNav(me, '#/aprobaciones'); } },
  '#/usuarios': { ok: me => hasPerm(me, 'users.view'), open: async me => { await new UsersPanel(api, me, null, logout).open(); await withNav(me, '#/usuarios'); } },
  '#/configuracion': { ok: me => hasPerm(me, 'settings.manage') || hasPerm(me, 'vehicles.manage'), open: async me => (await adminUi()).openConfig(api, me) },
  '#/informes': { ok: me => hasPerm(me, 'can_view_commercial_transport_reports') || hasPerm(me, 'can_manage_commercial_transport_reports'), open: async me => { const { ReportsPanel } = await import('./online/reports-ui.js'); await new ReportsPanel(api, me, logout).open(); await withNav(me, '#/informes'); } },
  '#/conciliacion-noc': { ok: me => hasPerm(me, 'credit_notes.manage'), open: async me => (await adminUi()).openNocRecon(api, me) },
  '#/auditoria': { ok: me => hasPerm(me, 'audit.view'), open: async me => (await adminUi()).openAudit(api, me) },
  '#/backup': { ok: me => hasPerm(me, 'settings.manage'), open: async me => (await adminUi()).openBackup(api, me) },
  '#/mis-hojas': { ok: me => hasPerm(me, 'routes.view_assigned'), open: () => closeOverlay() }
};
// Inserta la barra de navegación debajo del encabezado del panel abierto
async function withNav(me, active) {
  const { navHtml } = await adminUi(); const top = document.querySelector('#usersPanel > .top');
  if (top && !document.querySelector('#usersPanel #adNav')) top.insertAdjacentHTML('afterend', navHtml(me, active));
}
let ME = null;
function closeOverlay() { const p = $('#usersPanel'); p.hidden = true; p.innerHTML = ''; }
function show403() {
  const p = $('#usersPanel'); p.hidden = false;
  p.innerHTML = '<header class="top"><img src="/logo.png" alt="OK Accesorios"><div class="ttl"><b>DESPACHO</b><span>Acceso</span></div></header><div class="up-wrap"><div class="auth-card" id="e403"><h3>403 · ACCESO NO AUTORIZADO</h3><p>Tu usuario no tiene permiso para este módulo.</p><button class="btn dark" type="button" id="b403">VOLVER</button></div></div>';
  p.querySelector('#b403').onclick = () => { history.replaceState(null, '', location.pathname); closeOverlay(); };
}
async function openRoute() {
  const h = location.hash.split('?')[0], r = MODULE_ROUTES[h];
  if (!r || !ME) return;
  if (!r.ok(ME)) { show403(); return; }
  await r.open(ME);
}
window.addEventListener('hashchange', () => (location.hash.startsWith('#/nueva-contrasena') ? route() : openRoute()));
// Sesión realmente vencida (no se pudo renovar): vuelve al acceso con aviso
window.addEventListener('okd-session-expired', async () => { await api.signOut().catch(() => null); history.replaceState(null, '', location.pathname); showLogin('Tu sesión venció. Ingresá de nuevo.'); });
async function moduleButtons(me, top) {
  const { navHtml } = await adminUi();
  const host = top.parentElement; if (!host || host.querySelector('#adNav')) return;
  if (NAV_COUNT(me) > 1) top.insertAdjacentHTML('afterend', navHtml(me, location.hash.split('?')[0] || '#/despacho'));
}
const NAV_COUNT = me => Object.entries(MODULE_ROUTES).filter(([h, r]) => h !== '#/mis-hojas' && r.ok(me)).length;
async function addHeaderControls(me) {
  const top = document.querySelector('#operario .top');
  if (!top || top.querySelector('.who-chip')) return;
  const before = top.querySelector('#btnConfig');
  const chip = document.createElement('button'); chip.type = 'button'; chip.className = 'who-chip linkchip'; chip.id = 'btnMe'; chip.title = 'Mi cuenta';
  chip.innerHTML = esc(me.full_name) + ' · <b>' + esc(ROLE_LABEL[me.role] || me.role) + '</b>';
  chip.addEventListener('click', () => openAccount(api, me, logout));
  top.insertBefore(chip, before);
  await moduleButtons(me, top);
  const out = document.createElement('button'); out.className = 'tbtn'; out.type = 'button'; out.id = 'btnLogout'; out.textContent = 'Cerrar sesión';
  out.addEventListener('click', logout);
  top.appendChild(out);
}
async function logout() { await api.signOut(); location.hash = ''; location.reload(); }

async function route() {
  // Enlace de nueva contraseña (recuperación o invitación): antes de cualquier otra cosa
  const q = new URLSearchParams(location.search), hq = new URLSearchParams(location.hash.split('?')[1] || '');
  if (location.hash.startsWith('#/nueva-contrasena') || q.has('nueva-contrasena')) {
    show('#auth'); renderNewPassword(api, hq.get('token'), () => { history.replaceState(null, '', location.pathname); showLogin('Contraseña actualizada. Ingresá con la nueva.'); }); return;
  }
  const session = await api.getSession();
  if (!session) { showLogin(); return; }
  const me = await api.me();
  if (!me) { showLogin(); return; }
  // Invitado que entró por el link: crea su contraseña. Nunca queda atrapado: ve el error y puede reintentar.
  if (me.status === 'INVITACION_PENDIENTE' || location.hash.startsWith('#/crear-contrasena')) {
    show('#auth'); renderSetPassword(api, () => { location.hash = ''; route(); }, logout); return;
  }
  if (me.status !== 'ACTIVO') { await api.signOut(); showLogin('Tu usuario no está activo. Consultá con Administración.'); return; }
  window.OKD_LOGOUT = logout;
  ME = me; window.OKD_ME = { id: me.id, allDrafts: hasPerm(me, 'routes.manage_all_drafts') };
  if (hasPerm(me, 'routes.create')) {
    show('#operario');
    try { await loadLegacy(); } catch (e) { alert(e.message); }
    await addHeaderControls(me);
    // reglas financieras vigentes del servidor (versionadas)
    // Reglas del servidor (financieras + asignación): se ESPERAN y el estado queda visible. Sin servidor se puede seguir preparando
    // (contingencia identificada), pero no se publica hasta recuperar las reglas, recalcular y revisar con la versión vigente.
    if (hasPerm(me, 'routes.create')) await syncServerConfig();
    if (!location.hash && isAdminHome(me)) location.hash = '#/dashboard';
  } else {
    show('#noPanel');
    if (hasPerm(me, 'routes.view_assigned')) { const { DriverApp } = await import('./online/driver-ui.js'); new DriverApp(api, me, logout).start(); }
    else if (hasPerm(me, 'routes.view_all')) { const { DriverApp } = await import('./online/driver-ui.js'); new DriverApp(api, me, logout, { readOnly: true }).start(); }
    else {
      const chip = $('#np-who');
      chip.innerHTML = esc(me.full_name) + ' · <b>' + esc(ROLE_LABEL[me.role] || me.role) + '</b>';
      chip.onclick = () => openAccount(api, me, logout);
      $('#np-msg').textContent = 'Elegí un módulo en la parte superior.';
      $('#np-logout').onclick = logout;
    }
    const top = document.querySelector('#noPanel .top'); if (!hasPerm(me, 'routes.view_assigned')) await moduleButtons(me, top);
  }
  await openRoute();
}
function showLogin(note) {
  show('#auth'); renderLogin(api, route);
  const msg = note || (api.takeRevokedNotice() ? 'Tu sesión fue cerrada por Administración. Volvé a iniciar sesión.' : '');
  if (msg) { const n = document.createElement('div'); n.className = 'auth-note'; n.id = 'authNote'; n.textContent = msg; document.getElementById('authCard').prepend(n); }
}

if (api.mode === 'demo') $('#demoBanner').hidden = false;
window.OKD_ONLINE = { api };
// La splash se oculta apenas termina la inicialización real (sesión restaurada y primera pantalla elegida): sin demoras artificiales
window.OKD_BUILD = import.meta.env.VITE_OKD_BUILD_TAG || ''; // identificador del build (diagnóstico)
async function syncServerConfig() {
  const set = (st, msg) => {
    window.OKD_CFG_STATE = st;
    const el = document.getElementById('cfgSync'); if (!el) return;
    el.hidden = false; el.className = 'finsync ' + (st === 'OK' ? 'OK' : st === 'SINCRONIZANDO' ? 'SINCRONIZANDO' : 'ERROR');
    el.innerHTML = st === 'OK' ? 'CONFIGURACIÓN · OK · reglas financieras v' + window.OKD_RULES_VERSION + ' · asignación v' + window.OKD_ROUTING_VERSION
      : st === 'SINCRONIZANDO' ? 'CONFIGURACIÓN · SINCRONIZANDO…'
      : '<b>CONFIGURACIÓN · SIN CONEXIÓN / REVISAR</b> · se está usando la configuración local como contingencia (' + (msg || 'sin respuesta del servidor') + '). Podés preparar la hoja, pero no publicarla hasta recuperar las reglas del servidor. <button type="button" class="btn soft" id="cfgRetry">REINTENTAR</button>';
    const rb = document.getElementById('cfgRetry'); if (rb) rb.onclick = () => syncServerConfig();
  };
  set('SINCRONIZANDO');
  try {
    const [f, g] = await Promise.all([api.financialRules(), api.routingRules()]);
    if (!f || !g) throw new Error('respuesta vacía');
    window.OKD_APPLY_RULES && window.OKD_APPLY_RULES(f); window.OKD_APPLY_ROUTING && window.OKD_APPLY_ROUTING(g); // aplica y recalcula
    set('OK');
  } catch (e) { set('REVISAR', e.message); }
}
window.OKD_SYNC_CONFIG = syncServerConfig;
window.addEventListener('online', () => { if (window.OKD_CFG_STATE === 'REVISAR') syncServerConfig(); });
function hideSplash() { const el = document.getElementById('splash'); if (!el) return; el.classList.add('hide'); setTimeout(() => el.remove(), 250); window.OKD_SPLASH_HIDDEN_AT = performance.now(); }
route().catch(e => console.error(e)).finally(hideSplash);
// PWA: solo en el build publicado
if (import.meta.env.PROD && 'serviceWorker' in navigator) navigator.serviceWorker.register('/sw.js').then(r => r.update()).catch(() => {}); // busca una versión nueva de los assets en cada inicio
