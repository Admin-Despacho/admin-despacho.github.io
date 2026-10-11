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
    routes: { pdf: { settings: () => api.dispatchSettings(), save: (id, v, n, b) => api.saveRoutePdf(id, v, n, b), error: (id, v, m) => api.routePdfError(id, v, m), snapshot: id => api.routePdfSnapshot(id), download: (id, v) => api.downloadRoutePdf(id, v) },
      vehicles: () => api.listVehicles(), carriers: () => api.listCarriers(), responsables: id => api.responsables(id), publish: p => api.publishRoute(p), status: id => api.routeStatus(id), subscribe: cb => api.subscribe(cb) }
  };
  const [xlsx, worker] = await Promise.all([loadText('/legacy/xlsx.full.min.js'), loadText('/legacy/worker.js')]);
  $('#src-xlsx').textContent = xlsx; $('#src-worker').textContent = worker;
  for (const f of ['exceljs.min.js', 'jspdf.umd.min.js', 'jspdf.plugin.autotable.min.js', 'financing.js', 'despacho-v15.js']) await loadScript('/legacy/' + f);
  legacyLoaded = true;
}

// ===== Módulos (RC1.1): el menú muestra solo lo autorizado y cada URL valida el permiso (el servidor valida igual) =====
const canApprovals = me => hasPerm(me, 'can_approve_internal_route_changes') || hasPerm(me, 'settings.manage') || hasPerm(me, 'vehicles.manage');
const MODULE_ROUTES = {
  '#/usuarios': { label: 'Usuarios', id: 'btnUsers', ok: me => hasPerm(me, 'users.view'), open: me => new UsersPanel(api, me, null, logout).open() },
  '#/aprobaciones': { label: 'Aprobaciones', id: 'btnApprovals', ok: canApprovals, open: async me => { const { ApprovalsPanel } = await import('./online/approvals-ui.js'); new ApprovalsPanel(api, me).open(); } },
  '#/configuracion': { ok: me => hasPerm(me, 'settings.manage') || hasPerm(me, 'vehicles.manage'), open: async me => { const { ApprovalsPanel } = await import('./online/approvals-ui.js'); new ApprovalsPanel(api, me).open(); } },
  '#/informes': { label: 'Informes', id: 'btnReports', ok: me => hasPerm(me, 'can_view_commercial_transport_reports') || hasPerm(me, 'can_manage_commercial_transport_reports'), open: async me => { const { ReportsPanel } = await import('./online/reports-ui.js'); new ReportsPanel(api, me, logout).open(); } },
  '#/despacho': { ok: me => hasPerm(me, 'routes.create'), open: () => closeOverlay() },
  '#/mis-hojas': { ok: me => hasPerm(me, 'routes.view_assigned'), open: () => closeOverlay() }
};
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
function moduleButtons(me, top, before) {
  for (const [hash, r] of Object.entries(MODULE_ROUTES)) {
    if (!r.label || !r.ok(me) || top.querySelector('#' + r.id)) continue;
    const b = document.createElement('button'); b.className = 'tbtn'; b.type = 'button'; b.id = r.id; b.textContent = r.label;
    b.addEventListener('click', () => { if (location.hash === hash) openRoute(); else location.hash = hash; });
    top.insertBefore(b, before);
  }
}
function addHeaderControls(me) {
  const top = document.querySelector('#operario .top');
  if (!top || top.querySelector('.who-chip')) return;
  const before = top.querySelector('#btnConfig');
  const chip = document.createElement('button'); chip.type = 'button'; chip.className = 'who-chip linkchip'; chip.id = 'btnMe'; chip.title = 'Mi cuenta';
  chip.innerHTML = esc(me.full_name) + ' · <b>' + esc(ROLE_LABEL[me.role] || me.role) + '</b>';
  chip.addEventListener('click', () => openAccount(api, me, logout));
  top.insertBefore(chip, before);
  moduleButtons(me, top, before);
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
  ME = me;
  if (hasPerm(me, 'routes.create')) {
    show('#operario');
    try { await loadLegacy(); } catch (e) { alert(e.message); }
    addHeaderControls(me);
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
    const top = document.querySelector('#noPanel .top'); moduleButtons(me, top, $('#np-logout'));
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
route();
// PWA: solo en el build publicado
if (import.meta.env.PROD && 'serviceWorker' in navigator) navigator.serviceWorker.register('/sw.js').catch(() => {});
