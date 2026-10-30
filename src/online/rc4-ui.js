// RC4 · Interfaz por rol. Diseño tomado de los HTML aprobados:
//   OK_Despacho_Dashboard_Admin_General_V4.html y OK_Despacho_Dashboard_Superior_Despacho_V2.html
// La pantalla solo muestra lo autorizado; el servidor valida cada acción igual (RLS + RPC).
import { switcherHtml } from './role-view.js';
import { esc } from './util.js';
import { hasPerm, ROLE_LABEL } from '../../supabase/functions/_shared/rules.js';

export const RC4_ROLES = ['ADMIN', 'SUPERVISOR_DESPACHO', 'OPERARIO_DEPOSITO'];
export const isRc4 = me => !!me && RC4_ROLES.includes(me.role);
const dt = iso => iso ? new Date(iso).toLocaleString('es-AR', { timeZone: 'America/Argentina/Mendoza', day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' }) : '—';
const n0 = v => Number(v || 0).toLocaleString('es-AR');
const REQ_LABEL = { CAMBIO_TRANSPORTISTA: 'Cambio de transportista', REASIGNACION: 'Reasignación', CAMBIO_RESPONSABLE: 'Cambio de responsable', MODIFICAR_BULTOS: 'Modificar bultos',
  CAMBIO_VEHICULO: 'Cambio de vehículo', CORRECCION_KM: 'Corrección de kilometraje', CANCELACION: 'Cancelación', CAMBIO_POST_PUBLICACION: 'Cambio posterior a publicación', OTRO: 'Otra acción' };
const ST_LABEL = { PENDING: ['PENDIENTE', 'warn'], APPROVED: ['APROBADA', 'ok'], OBSERVED: ['OBSERVADA', 'info'], REJECTED: ['RECHAZADA', 'bad'], CANCELLED: ['CANCELADA', 'info'] };
const pill = (cls, t) => '<span class="status ' + cls + '">' + esc(t) + '</span>';
const canRequests = me => hasPerm(me, 'requests.create') || hasPerm(me, 'requests.view_team') || hasPerm(me, 'requests.approve_team') || me.role === 'ADMIN';

// ===== Menú lateral por rol (V4 / V2) =====
export function roleNav(me) {
  if (me.role === 'ADMIN') return [
    ['#/dashboard', 'Dashboard'],
    ['#/historial', 'Hojas de ruta', [['#/despacho', 'Despacho'], ['#/borradores', 'Borradores'], ['#/historial', 'Hojas publicadas']]],
    ['#/solicitudes', 'Solicitudes', [['#/aprobaciones', 'Aprobaciones de ruta interna']]],
    ['#/conciliacion-noc', 'NOC'],
    ['#/informes', 'Informes'],
    hasPerm(me, 'comms.view') && ['#/comunicaciones', 'Comunicaciones'],
    ['#/auditoria', 'Auditoría'],
    ['#/usuarios', 'Usuarios y permisos'],
    // Transportistas, Vehículos, Emails y Backup son secciones de Configuración: van agrupados dentro de ella
    ['#/configuracion', 'Configuración', [['#/configuracion?sec=transportistas', 'Transportistas'], ['#/configuracion?sec=vehiculos', 'Vehículos / Service'],
      ['#/configuracion?sec=emails', 'Emails'], ['#/backup', 'Backup / Archivo']]]].filter(Boolean);
  if (me.role === 'SUPERVISOR_DESPACHO') return [
    ['#/dashboard', 'Dashboard'], ['#/nueva-hoja', 'Nueva hoja de ruta'], ['#/despacho', 'Despacho'], ['#/borradores', 'Borradores del equipo'],
    (hasPerm(me, 'routes.view_all') || hasPerm(me, 'routes.view_team')) && ['#/historial', 'Hojas publicadas'], canRequests(me) && ['#/solicitudes', 'Solicitudes / Aprobaciones'], ['#/notificaciones', 'Notificaciones'],
    (hasPerm(me, 'vehicles.view') || hasPerm(me, 'vehicle_mileage.view')) && ['#/vehiculos', 'Vehículos'],
    (hasPerm(me, 'columns.view') || hasPerm(me, 'vehicle_mileage.view')) && ['#/config-operativa', 'Configuración operativa'],
    hasPerm(me, 'comms.view') && ['#/comunicaciones', 'Comunicaciones']].filter(Boolean);
  return [
    ['#/dashboard', 'Dashboard'], ['#/nueva-hoja', 'Nueva hoja / Preparar hoja'], ['#/despacho', 'Despacho'], ['#/borradores', hasPerm(me, 'drafts.manage_all') ? 'Borradores de despacho' : 'Mis borradores'],
    (hasPerm(me, 'routes.view_all') || hasPerm(me, 'routes.view_team')) ? ['#/historial', 'Hojas publicadas'] : hasPerm(me, 'routes.view_own') && ['#/historial', 'Mis hojas publicadas'], ['#/notificaciones', 'Notificaciones'], canRequests(me) && ['#/solicitudes', 'Solicitudes'],
    hasPerm(me, 'carriers.manage') && ['#/configuracion?sec=transportistas', 'Transportistas'],
    (hasPerm(me, 'vehicles.view') || hasPerm(me, 'vehicle_mileage.view')) && ['#/vehiculos', 'Vehículos / Kilometraje / Service'],
    hasPerm(me, 'columns.view') && ['#/config-operativa', 'Columnas predeterminadas'],
    hasPerm(me, 'comms.view') && ['#/comunicaciones', 'Comunicaciones']].filter(Boolean);
}
export const ROUTE_OF = h => h.split('?')[0];
const NAV_MATCH = (target, active) => {
  const t = String(target || ''), a = String(active || '');
  if (t === '#/configuracion') return ROUTE_OF(a) === '#/configuracion';
  if (t.includes('?') || a.includes('?')) return t === a;
  return ROUTE_OF(t) === ROUTE_OF(a);
};
const MGROUP = h => { const r = ROUTE_OF(h);
  if (['#/dashboard', '#/notificaciones'].includes(r)) return 'Inicio';
  if (['#/nueva-hoja', '#/despacho', '#/borradores', '#/historial'].includes(r)) return 'Hojas de ruta';
  if (['#/solicitudes', '#/aprobaciones'].includes(r)) return 'Solicitudes';
  if (['#/conciliacion-noc', '#/informes', '#/auditoria'].includes(r)) return 'Control';
  return 'ADMIN_OR_OP'; };
export function mobileNav(me, active) {
  const a = String(active || ''), items = [];
  roleNav(me).forEach(([h, l, sub]) => {
    // "Hojas de ruta" (padre) repite el destino de "Hojas publicadas": en el celular el grupo hace de título
    if (!(sub && sub.some(s => s[0] === h))) items.push([h, l, false]);
    (sub || []).forEach(([sh, sl]) => items.push([sh, sl, ROUTE_OF(h) === '#/configuracion']));
  });
  const last = me.role === 'ADMIN' ? 'Administración' : 'Operación', order = ['Inicio', 'Hojas de ruta', 'Solicitudes', 'Control', last], groups = {};
  items.forEach(it => { const g = MGROUP(it[0]) === 'ADMIN_OR_OP' ? last : MGROUP(it[0]); (groups[g] = groups[g] || []).push(it); });
  const isOn = h => NAV_MATCH(h, a) && !(h === '#/configuracion' && items.some(x => x[0] !== h && x[0].startsWith('#/configuracion') && NAV_MATCH(x[0], a)));
  const link = ([h, l, sub]) => '<a href="' + h + '" data-nav="' + h + '" class="' + (sub ? 'msub ' : '') + (isOn(h) ? 'active' : '') + '">' + esc(l) + '</a>';
  const any = order.some(g => (groups[g] || []).some(x => isOn(x[0])));
  return order.filter(g => groups[g]).map(g => {
    const its = groups[g];
    if (its.length === 1) return '<div class="mone">' + link(its[0]) + '</div>';
    const open = its.some(x => isOn(x[0])) || (!any && g === 'Hojas de ruta');
    return '<details class="mgrp"' + (open ? ' open' : '') + '><summary>' + esc(g) + '</summary>' + its.map(link).join('') + '</details>';
  }).join('');
}
function navLinks(me, active) {
  const a = String(active || '');
  return roleNav(me).map(([h, l, sub]) => '<a href="' + h + '" data-nav="' + h + '" class="' + (NAV_MATCH(h, a) && !(sub || []).some(s => NAV_MATCH(s[0], a) && s[0] !== h) ? 'active' : '') + '"><span class="dot"></span>' + esc(l) + '</a>' +
    (sub ? '<div class="sub">' + sub.map(([sh, sl]) => '<a href="' + sh + '" data-nav="' + sh + '" class="' + (NAV_MATCH(sh, a) ? 'active' : '') + '">' + esc(sl) + '</a>').join('') + '</div>' : '')).join('');
}
// Barra horizontal (encima del panel de Despacho) con los mismos destinos
export function roleTopNav(me, active) {
  const a = ROUTE_OF(active || '');
  const flat = []; roleNav(me).forEach(([h, l, sub]) => { flat.push([h, l]); (sub || []).forEach(s => { if (!flat.some(f => f[0] === s[0])) flat.push(s); }); });
  return '<nav class="adnav" id="adNav">' + flat.map(([h, l]) => '<a href="' + h + '" class="' + (ROUTE_OF(h) === a ? 'on' : '') + '" data-nav="' + h + '">' + esc(l.toUpperCase()) + '</a>').join('') + '</nav>';
}
// Marco con menú lateral (V4/V2) dentro de #usersPanel
export function appFrame(me, title, active, sub) {
  const el = document.getElementById('usersPanel'); el.hidden = false;
  const foot = { ADMIN: 'OK Despacho · Administración<br>Configuración global exclusiva Admin', SUPERVISOR_DESPACHO: 'Rol operativo de supervisión<br>Sin acceso a configuración global', OPERARIO_DEPOSITO: 'Operario Depósito<br>Preparación de hojas' }[me.role];
  const newBtn = me.role !== 'ADMIN' && hasPerm(me, 'routes.create') ? '<a class="btn primary" href="#/nueva-hoja" id="newRouteTop">+ NUEVA HOJA DE RUTA</a>' : '';
  el.innerHTML = '<div class="rc4app"><aside class="rc4side"><div class="brand"><img class="logo" src="/icons/icon-192.png" alt="OK"><div><b>DESPACHO</b><small>' + esc(ROLE_LABEL[me.role] || me.role) + '</small></div><button class="rc4menu" type="button" aria-expanded="false" aria-label="Abrir menú"><span></span>MENÚ</button></div>' +
    '<nav class="nav" id="adNav">' + navLinks(me, active) + '</nav><nav class="mnav" aria-label="Menú">' + mobileNav(me, active) + '</nav>' + '<div class="rc4who"><b>' + esc(me.full_name) + '</b>' + switcherHtml(me) + '<span>' + esc(ROLE_LABEL[me.role] || me.role) + ' · ' + (me.role === 'ADMIN' ? 'Acceso total' : esc(me.team_label || 'Equipo de Despacho')) + '</span><button class="rc4logout" type="button">Cerrar sesión</button></div>' + '<div class="footer">' + foot + '</div></aside>' +
    '<main class="rc4main"><div class="topbar"><div class="title"><h1>' + esc(title) + '</h1>' + (sub ? '<p>' + esc(sub) + '</p>' : '') + '</div>' +
    '<div class="topact">' + newBtn + '<div class="userchip"><b>' + esc(me.full_name) + ' · ' + esc(ROLE_LABEL[me.role] || me.role) + '</b>' + switcherHtml(me) + '<br><span>' + (me.role === 'ADMIN' ? 'Acceso total' : esc(me.team_label || 'Equipo de Despacho')) + '</span></div>' +
    '<button class="tbtn" type="button" id="adLogout">Cerrar sesión</button></div></div><div id="adBody" class="rc4body"></div></main></div>';
  el.querySelector('#adLogout').onclick = () => window.OKD_LOGOUT && window.OKD_LOGOUT();
  return el.querySelector('#adBody');
}
const msg = (w, m) => { if (!m) return; const d = document.createElement('div'); d.className = 'up-msg ' + (m.err ? 'err' : 'ok'); d.id = 'adMsg'; d.textContent = m.text; w.prepend(d); };
const go = h => { location.hash = h; };

// ===================== DASHBOARD ADMIN GENERAL (V4) =====================
export async function openDashboardAdmin(api, me) {
  const w = appFrame(me, 'Dashboard Admin General', '#/dashboard', 'Control completo de la operación de despacho');
  let d; try { d = await api.dashboardAdmin(); } catch (e) { msg(w, { err: true, text: e.message }); return; }
  let veh = []; try { veh = (await api.vehicleStatus()).filter(v => v.service_due); } catch (e) { veh = []; }
  const k = d.kpis, G = { CRISTIAN: 'Cristian Torres', INTERNO: 'Transporte Interno', OTROS: 'Otros transportistas' };
  const state = c => c.incidencias > 0 ? pill('warn', 'Revisar') : c.activas > 0 ? pill('info', 'En seguimiento') : pill('ok', 'Operativo');
  const al = d.alerts, alert = (key, label, href) => '<a class="alert' + (Number(al[key]) > 0 ? ' hot' : '') + '" href="' + href + '" data-alert="' + key + '"><b>' + label + '</b><span>' + n0(al[key]) + '</span></a>';
  w.innerHTML = '<div class="grid">' +
    '<div class="card kpi" data-kpi="hoy"><div class="label">Hojas hoy</div><div class="value">' + n0(k.hojas_hoy) + '</div><div class="mini">publicadas hoy</div></div>' +
    '<div class="card kpi" data-kpi="curso"><div class="label">En curso</div><div class="value">' + n0(k.en_curso) + '</div><div class="mini">en ruta</div></div>' +
    '<div class="card kpi" data-kpi="fin"><div class="label">Finalizadas</div><div class="value">' + n0(k.finalizadas) + '</div><div class="mini">hoy</div></div>' +
    '<div class="card kpi" data-kpi="inc"><div class="label">Incidencias</div><div class="value">' + n0(k.incidencias) + '</div><div class="mini">requieren revisión</div></div>' +
    '<section class="card span8"><div class="section-title"><h2>Operación por transportista</h2><span class="tag">Tiempo real</span></div><table class="table" id="dashCarriers"><thead><tr><th>Transportista</th><th>Publicadas</th><th>Activas</th><th>Finalizadas</th><th>Incidencias</th><th>Devoluciones</th><th>Km</th><th>Estado</th></tr></thead><tbody>' +
      ['CRISTIAN', 'INTERNO', 'OTROS'].map(g => { const c = (d.carriers || []).find(x => x.grp === g) || { publicadas: 0, activas: 0, finalizadas: 0, incidencias: 0, devoluciones: 0, km: 0 };
        return '<tr><td><b>' + G[g] + '</b></td><td>' + n0(c.publicadas) + '</td><td>' + n0(c.activas) + '</td><td>' + n0(c.finalizadas) + '</td><td>' + n0(c.incidencias) + '</td><td>' + n0(c.devoluciones) + '</td><td>' + n0(c.km) + '</td><td>' + state(c) + '</td></tr>'; }).join('') +
    '</tbody></table></section>' +
    '<section class="card span4"><div class="section-title"><h2>Alertas</h2><span class="tag">Accionables</span></div><div class="alerts" id="dashAlerts">' +
      alert('solicitudes', 'Solicitudes pendientes', '#/solicitudes') + alert('incidencias', 'Incidencias / devoluciones', '#/historial') + alert('service', 'Vehículos / service', '#/configuracion?sec=vehiculos') +
      alert('emails_error', 'Emails con error', '#/configuracion?sec=emails') + alert('noc', 'NOC para revisar', '#/conciliacion-noc') + alert('km', 'Alertas de kilometraje', '#/vehiculos') + '</div>' +
      (veh.length ? '<div class="up-msg err" id="dashService">⚠ SERVICE REQUERIDO: ' + veh.map(v => esc(v.name + ' · ' + v.plate)).join(' · ') + '</div>' : '') + '</section>' +
    '<section class="card span7 hero"><div class="section-title"><h2>Usuarios y permisos</h2><span class="tag">Jerarquía operativa</span></div><p>Administrá roles, superior asignado y permisos específicos por usuario.</p>' +
      '<div class="tscroll"><table class="table" id="dashUsers"><thead><tr><th>Usuario</th><th>Rol</th><th>Superior</th><th>Columnas</th><th>Kilometraje</th><th>Aprueba</th></tr></thead><tbody>' +
      (d.users || []).map(u => '<tr><td>' + esc(u.full_name) + '</td><td>' + esc(ROLE_LABEL[u.role] || u.role) + '</td><td>' + esc(u.supervisor || (u.role === 'ADMIN' ? '—' : 'Sin superior')) + '</td><td>' + (u.columns ? pill('ok', 'Permitido') : pill('warn', 'No')) + '</td><td>' +
        (u.km ? pill('ok', 'Permitido') : pill('warn', 'No')) + '</td><td>' + (u.approve ? pill('ok', 'Sí') : pill('warn', 'No')) + '</td></tr>').join('') + '</tbody></table></div>' +
      '<div style="margin-top:14px"><a class="btn primary" href="#/usuarios">ABRIR USUARIOS Y PERMISOS</a></div></section>' +
    '<section class="card span5"><div class="section-title"><h2>Permisos configurables</h2><span class="tag">Por usuario</span></div>' +
      perm('Configurar columnas predeterminadas', 'Define columnas por defecto de hoja / PDF / Excel', 'columns.manage_defaults', (d.users || []).filter(u => u.columns && u.role !== 'ADMIN').length) +
      perm('Configurar kilometraje de vehículo', 'Km inicial, km final, controles y alertas', 'vehicle_mileage.rules_manage', (d.users || []).filter(u => u.km && u.role !== 'ADMIN').length) +
      perm('Aprobar cambios de Operario', 'Permite resolver solicitudes del equipo', 'requests.approve_team', (d.users || []).filter(u => u.approve && u.role !== 'ADMIN').length) +
      '<p class="note">Se asignan a Superior Despacho u otros usuarios desde <a href="#/usuarios">Usuarios y permisos</a> (PERMISOS). Solo Admin General otorga permisos sensibles.</p></section>' +
    '<section class="card span12"><div class="section-title"><h2>Configuración rápida</h2><span class="tag">Admin</span></div><div class="config-grid">' +
      box('Columnas predeterminadas', 'Definí qué columnas aparecen por defecto en la hoja, PDF, impresión y Excel.', 'CONFIGURAR COLUMNAS', '#/configuracion?sec=plantillas', 'qCols') +
      box('Kilometraje de vehículos', 'Reglas de km inicial/final, control de recorrido y alertas de inconsistencias.', 'CONFIGURAR KILOMETRAJE', '#/vehiculos', 'qKm') +
      box('Vehículos / Service', 'Alta, estado, service requerido y alertas.', 'ABRIR VEHÍCULOS', '#/configuracion?sec=vehiculos', 'qVeh') +
      box('Reglas de hojas', 'Correlativos, PDF, email, plantillas y reglas generales.', 'ABRIR CONFIGURACIÓN', '#/configuracion', 'qCfg') + '</div></section></div>';
}
const perm = (t, s, code, n) => '<div class="permission"><div class="txt"><b>' + esc(t) + '</b><small>' + esc(s) + '</small></div><span class="tag" data-perm="' + code + '">' + n0(n) + ' usuario' + (n === 1 ? '' : 's') + '</span></div>';
const box = (t, p, b, h, id) => '<div class="config-box" id="' + id + '"><h3>' + esc(t) + '</h3><p>' + esc(p) + '</p><a class="small-btn" href="' + h + '">' + esc(b) + '</a></div>';

// ===================== DASHBOARD SUPERIOR DESPACHO (V2) =====================
export async function openDashboardSupervisor(api, me) {
  const w = appFrame(me, 'Dashboard Superior Despacho', '#/dashboard', 'Supervisión del equipo y control operativo');
  let d; try { d = await api.dashboardSupervisor(); } catch (e) { msg(w, { err: true, text: e.message }); return; }
  const k = d.kpis, byType = {}; (d.requests || []).forEach(q => { byType[q.type] = (byType[q.type] || 0) + 1; });
  const sw = (t, s, on) => '<div class="permission"><div class="txt"><b>' + esc(t) + '</b><small>' + esc(s) + '</small></div><label class="switch" title="Lo define Admin General"><input type="checkbox" disabled' + (on ? ' checked' : '') + '><span class="slider"></span></label></div>';
  w.innerHTML = '<div class="grid">' +
    '<section class="card span12 hero" id="nueva-hoja"><div class="section-title"><h2>Nueva hoja de ruta</h2><span class="tag">Acción principal</span></div><p>Creá, prepará, asigná, revisá y publicá una hoja de ruta completa.</p>' +
      '<div class="heroact"><a class="btn primary" href="#/nueva-hoja" id="newRouteHero">+ CREAR NUEVA HOJA DE RUTA</a><a class="btn soft" href="#/borradores">ABRIR BORRADORES DEL EQUIPO</a>' + (hasPerm(me, 'routes.view_all') || hasPerm(me, 'routes.view_team') ? '<a class="btn soft" href="#/historial">VER HOJAS PUBLICADAS</a>' : '') + '</div>' +
      '<div class="steps">' + [['1. Cargar pedidos', 'Importar archivos o cargar pedidos.'], ['2. Preparar ruta', 'Paradas, bultos, columnas y orden.'], ['3. Asignar', 'Transportista, responsable y vehículo.'], ['4. Revisar', 'Reglas, kilometraje y alertas.'], ['5. Publicar', 'Generar hoja, PDF y notificaciones.']]
        .map(([t, p]) => '<div class="config-box"><h3>' + t + '</h3><p>' + p + '</p></div>').join('') + '</div></section>' +
    '<div class="card kpi"><div class="label">Borradores activos</div><div class="value" data-kpi="borradores">' + n0(k.borradores) + '</div><div class="mini">' + n0(k.borradores_equipo) + ' de tu equipo</div></div>' +
    '<div class="card kpi"><div class="label">Pendientes aprobación</div><div class="value" data-kpi="pendientes">' + n0(k.pendientes) + '</div><div class="mini">requieren decisión</div></div>' +
    '<div class="card kpi"><div class="label">Hojas activas</div><div class="value" data-kpi="activas">' + n0(k.activas) + '</div><div class="mini">' + n0((d.active || []).filter(a => a.incidencia).length) + ' con incidencias</div></div>' +
    '<div class="card kpi"><div class="label">Operarios</div><div class="value" data-kpi="operarios">' + n0(k.operarios) + '</div><div class="mini">' + n0((d.team || []).filter(t => t.status === 'ACTIVO').length) + ' activos</div></div>' +
    '<section class="card span8"><div class="section-title"><h2>Equipo de Despacho</h2><span class="tag">Asignación por superior</span></div><table class="table" id="teamTable"><thead><tr><th>Operario</th><th>Borradores</th><th>Publicadas hoy</th><th>Solicitudes</th><th>Estado</th></tr></thead><tbody>' +
      ((d.team || []).map(t => '<tr><td><b>' + esc(t.full_name) + '</b></td><td>' + n0(t.borradores) + '</td><td>' + n0(t.publicadas_hoy) + '</td><td>' + n0(t.solicitudes) + '</td><td>' +
        (t.status !== 'ACTIVO' ? pill('bad', 'Inactivo') : t.solicitudes > 0 ? pill('warn', 'Revisar') : pill('ok', 'Operativo')) + '</td></tr>').join('') || '<tr><td colspan="5">Todavía no tenés operarios asignados (los asigna Admin General).</td></tr>') + '</tbody></table></section>' +
    '<section class="card span4"><div class="section-title"><h2>Solicitudes pendientes</h2><span class="tag">Tu equipo</span></div><div class="alerts" id="supRequests">' +
      (Object.keys(byType).map(t => '<div class="alert"><b>' + esc(REQ_LABEL[t] || t) + '</b><span>' + byType[t] + '</span></div>').join('') || '<div class="alert"><b>Sin solicitudes pendientes</b><span>0</span></div>') +
      '</div><a class="btn dark wide" href="#/solicitudes">ABRIR APROBACIONES</a></section>' +
    '<section class="card span6"><div class="section-title"><h2>Permisos habilitados</h2><span class="tag">Definidos por Admin</span></div>' +
      sw('Configurar columnas predeterminadas', 'Este permiso puede ser activado o quitado por Admin General.', d.perms.columns) +
      sw('Configurar kilometraje de vehículo', 'Permite editar parámetros operativos de kilometraje.', d.perms.km) +
      sw('Aprobar solicitudes del equipo', 'No puede aprobar solicitudes propias.', d.perms.approve) + '</section>' +
    '<section class="card span6"><div class="section-title"><h2>Configuración operativa</h2><span class="tag">Según permiso</span></div><div class="config-grid">' +
      '<div class="config-box' + (d.perms.columns ? '' : ' off') + '" id="boxCols"><h3>Columnas predeterminadas</h3><p>Columnas por defecto para hoja, impresión, PDF y Excel.</p><a class="small-btn" href="#/config-operativa">' + (d.perms.columns ? 'EDITAR COLUMNAS' : 'VER COLUMNAS') + '</a></div>' +
      '<div class="config-box' + (d.perms.km ? '' : ' off') + '" id="boxKm"><h3>Kilometraje de vehículo</h3><p>Km inicial/final, rango válido, alertas y control por vehículo.</p><a class="small-btn" href="#/vehiculos">' + (d.perms.km ? 'EDITAR KILOMETRAJE' : 'VER KILOMETRAJE') + '</a></div>' +
      '</div><div class="note">No incluye reglas globales, usuarios, NOC, backup ni configuración administrativa.</div></section>' +
    '<section class="card span7"><div class="section-title"><h2>Hojas activas</h2><span class="tag">Seguimiento</span></div><table class="table" id="activeTable"><thead><tr><th>Hoja</th><th>Transportista</th><th>Responsable</th><th>Estado</th><th>Incidencia</th></tr></thead><tbody>' +
      ((d.active || []).map(a => '<tr><td>' + esc(a.number) + '</td><td>' + esc(a.carrier) + '</td><td>' + esc(a.responsable || '') + '</td><td>' + pill(a.incidencia ? 'warn' : 'info', a.incidencia ? 'Revisar' : a.status === 'EN_CURSO' ? 'En curso' : 'Publicada') + '</td><td>' + (a.incidencia ? 'Sí' : '—') + '</td></tr>').join('')
        || '<tr><td colspan="5">Sin hojas activas tuyas o de tu equipo.</td></tr>') + '</tbody></table></section>' +
    '<section class="card span5"><div class="section-title"><h2>Notificaciones operativas</h2><span class="tag">Supervisor</span></div><div class="alerts" id="supNotifs">' +
      ((d.notifications || []).map(n => '<div class="alert"><b>' + esc(n.title) + '</b><span>' + esc(dt(n.at)) + '</span></div>').join('') || '<div class="alert"><b>Sin novedades</b><span>—</span></div>') + '</div></section></div>';
}

// ===================== DASHBOARD OPERARIO DEPÓSITO =====================
export async function openDashboardOperario(api, me) {
  const w = appFrame(me, 'Operario Depósito', '#/dashboard', 'Preparación de hojas y trabajo diario');
  let d; try { d = await api.dashboardOperario(); } catch (e) { msg(w, { err: true, text: e.message }); return; }
  const st = s => { const [l, c] = ST_LABEL[s] || [s, 'info']; return pill(c, l); };
  const m = d.mileage, assigned = (d.vehicles || []).filter(v => v.assigned);
  w.innerHTML = '<div class="grid">' +
    '<section class="card span12 hero"><div class="section-title"><h2>Nueva hoja / Preparar hoja</h2><span class="tag">' + esc(d.supervisor ? 'Superior: ' + d.supervisor : 'Sin superior asignado') + '</span></div><p>Cargá pedidos, prepará la hoja y trabajá tus borradores.' +
      (hasPerm(me, 'routes.publish') ? '' : ' La publicación la hace tu Superior: si necesitás algo que no podés hacer, usá SOLICITAR AUTORIZACIÓN.') + '</p>' +
      '<div class="heroact"><a class="btn primary" href="#/nueva-hoja" id="opNew">+ NUEVA HOJA</a><a class="btn soft" href="#/borradores">MIS BORRADORES (' + n0(d.borradores) + ')</a>' +
      (hasPerm(me, 'requests.create') ? '<a class="btn soft" href="#/solicitudes?nueva=1" id="opAsk">SOLICITAR AUTORIZACIÓN</a>' : '') + '</div></section>' +
    '<div class="card kpi"><div class="label">Mis borradores</div><div class="value">' + n0(d.borradores) + '</div><div class="mini"><a href="#/borradores">abrir</a></div></div>' +
    '<div class="card kpi"><div class="label">Solicitudes pendientes</div><div class="value">' + n0((d.requests || []).filter(q => q.status === 'PENDING').length) + '</div><div class="mini">enviadas a tu superior</div></div>' +
    '<div class="card kpi"><div class="label">Alertas de km</div><div class="value">' + n0(d.km_alerts) + '</div><div class="mini">abiertas</div></div>' +
    '<div class="card kpi"><div class="label">Vehículo asignado</div><div class="value small">' + esc(assigned[0] ? assigned[0].plate : '—') + '</div><div class="mini">' + (assigned[0] ? 'Último km: ' + n0(assigned[0].current_km) : 'sin vehículo habitual') + '</div></div>' +
    '<section class="card span6"><div class="section-title"><h2>Mis solicitudes</h2><span class="tag">Autorizaciones</span></div><table class="table" id="opRequests"><thead><tr><th>Tipo</th><th>Estado</th><th>Motivo</th><th>Respuesta</th></tr></thead><tbody>' +
      ((d.requests || []).map(q => '<tr><td>' + esc(REQ_LABEL[q.type] || q.type) + '</td><td>' + st(q.status) + '</td><td>' + esc(q.reason || '') + '</td><td>' + esc(q.note || '—') + '</td></tr>').join('') || '<tr><td colspan="4">Sin solicitudes.</td></tr>') + '</tbody></table></section>' +
    '<section class="card span6"><div class="section-title"><h2>Notificaciones</h2><span class="tag">Propias</span></div><div class="alerts" id="opNotifs">' +
      ((d.notifications || []).map(n => '<div class="alert"><b>' + esc(n.title) + '</b><span>' + esc(dt(n.at)) + '</span></div>').join('') || '<div class="alert"><b>Sin novedades</b><span>—</span></div>') + '</div></section>' +
    (m ? '<section class="card span6" id="opKm"><div class="section-title"><h2>Kilometraje</h2><span class="tag">Configuración vigente</span></div>' + mileageView(m) + '<a class="small-btn" href="#/vehiculos">VER VEHÍCULOS Y CARGAR KM</a></section>' : '') +
    (hasPerm(me, 'columns.view') ? '<section class="card span6"><div class="section-title"><h2>Columnas predeterminadas</h2><span class="tag">' + (hasPerm(me, 'columns.manage_defaults') ? 'Podés modificarlas' : 'Solo lectura') + '</span></div><p class="note">Las columnas por transportista que se usan en pantalla, PDF y Excel.</p><a class="small-btn" href="#/config-operativa">VER COLUMNAS</a></section>' : '') +
    '</div>';
}
const yes = b => b ? 'Sí' : 'No';
export const mileageView = m => '<div class="kmcfg" id="kmView"><div><span>Km inicial obligatorio</span><b>' + yes(m.require_km_start) + '</b></div><div><span>Km final obligatorio</span><b>' + yes(m.require_km_end) + '</b></div>' +
  '<div><span>Recorrido máximo esperable</span><b>' + n0(m.max_trip_km) + ' km</b></div><div><span>Tolerancia</span><b>' + n0(m.tolerance_km) + ' km</b></div><div><span>Alerta si el km es menor al último</span><b>' + yes(m.alert_lower_than_last) + '</b></div></div>';

// ===================== SOLICITUDES / APROBACIONES =====================
export async function openRequests(api, me, frame) {
  const w = frame(me, isRc4(me) ? 'Solicitudes / Aprobaciones' : 'Solicitudes', '#/solicitudes');
  const approver = me.role === 'ADMIN' || hasPerm(me, 'requests.approve_team') || hasPerm(me, 'requests.reject_team') || hasPerm(me, 'requests.observe_team');
  let filter = approver ? 'asignadas' : 'mias';
  const wantNew = /nueva=1/.test(location.hash);
  let vehicles = []; try { vehicles = hasPerm(me, 'vehicle_mileage.view') || hasPerm(me, 'vehicles.view') ? await api.listVehicles() : []; } catch (e) { vehicles = []; }
  const draw = async m => {
    let list = []; try { list = await api.listOperationalRequests(filter); } catch (e) { m = { err: true, text: e.message }; }
    const F = (approver ? [['asignadas', 'PARA RESOLVER'], ['pendientes', 'PENDIENTES DEL EQUIPO']] : []).concat([['mias', 'MIS SOLICITUDES'], ['todas', 'TODAS']]);
    w.innerHTML = '<div class="grid">' + (hasPerm(me, 'requests.create') ? '<section class="card span12" id="reqNew"><div class="section-title"><h2>Solicitar autorización</h2><span class="tag">Va a tu superior asignado' + (me.role === 'SUPERVISOR_DESPACHO' ? ' (Admin General)' : '') + '</span></div>' +
      '<div class="reqform"><label>Tipo<select id="rqType">' + Object.entries(REQ_LABEL).map(([k, l]) => '<option value="' + k + '">' + esc(l) + '</option>').join('') + '</select></label>' +
      '<label>Hoja (opcional)<input id="rqRoute" placeholder="número de hoja"></label>' +
      '<label class="kmonly">Vehículo<select id="rqVeh">' + vehicles.map(v => '<option value="' + v.id + '">' + esc(v.name + ' · ' + v.plate + ' · ' + n0(v.current_km) + ' km') + '</option>').join('') + '</select></label>' +
      '<label class="kmonly">Km correcto<input id="rqKm" inputmode="numeric"></label>' +
      '<label class="wide">Motivo (obligatorio)<input id="rqReason"></label><button class="btn primary" type="button" id="rqSend">SOLICITAR</button></div></section>' : '') +
      '<section class="card span12"><div class="section-title"><h2>Solicitudes</h2><span class="tag">Sin autoaprobación · doble resolución protegida</span></div><div class="uact" id="rqFilters">' +
      F.map(([k, l]) => '<button type="button" class="btn ' + (k === filter ? 'dark' : 'soft') + '" data-f="' + k + '">' + l + '</button>').join('') + '</div>' +
      '<div class="tscroll"><table class="table" id="rqTable"><thead><tr><th>Fecha</th><th>Tipo</th><th>Solicitante</th><th>Resuelve</th><th>Hoja</th><th>Motivo</th><th>Estado</th><th>Respuesta</th><th></th></tr></thead><tbody>' +
      (list.map(q => { const [l, c] = ST_LABEL[q.status] || [q.status, 'info'], own = q.requested_by === me.id;
        const can = !own && ['PENDING', 'OBSERVED'].includes(q.status) && (me.role === 'ADMIN' || q.supervisor_user_id === me.id);
        return '<tr data-id="' + q.id + '"><td>' + esc(dt(q.requested_at)) + '</td><td>' + esc(REQ_LABEL[q.request_type] || q.request_type) + (q.request_type === 'CORRECCION_KM' && q.payload ? '<br><small>' + n0(q.payload.km) + ' km</small>' : '') + '</td><td>' + esc(q.requested_by_name || '') +
          '</td><td>' + esc(q.approver_name || 'Admin General') + (q.escalated ? ' <small>(escalada)</small>' : '') + '</td><td>' + esc(q.route_number || '—') + '</td><td>' + esc(q.reason || '') + '</td><td>' + pill(c, l) + '</td><td>' + esc(q.review_note || '—') + '</td><td>' +
          (can ? '<div class="uact"><input class="ed" data-note placeholder="Nota (obligatoria para observar/rechazar)"><button class="btn soft" type="button" data-d="APPROVED">APROBAR</button><button class="btn soft" type="button" data-d="OBSERVED">OBSERVAR</button><button class="btn danger" type="button" data-d="REJECTED">RECHAZAR</button></div>'
            : own && ['PENDING', 'OBSERVED'].includes(q.status) ? '<button class="btn soft" type="button" data-cancel>CANCELAR</button>' : '') + '</td></tr>'; }).join('') || '<tr><td colspan="9">Sin solicitudes en este filtro.</td></tr>') + '</tbody></table></div></section></div>';
    msg(w, m);
    w.querySelectorAll('[data-f]').forEach(b => b.onclick = () => { filter = b.dataset.f; draw(); });
    const ty = w.querySelector('#rqType'); const syncKm = () => w.querySelectorAll('.kmonly').forEach(x => { x.hidden = !ty || ty.value !== 'CORRECCION_KM'; });
    if (ty) { ty.onchange = syncKm; syncKm(); if (wantNew) w.querySelector('#rqReason').focus(); }
    const send = w.querySelector('#rqSend');
    if (send) send.onclick = async () => {
      const t = ty.value, payload = {};
      if (t === 'CORRECCION_KM') { payload.vehicle_id = w.querySelector('#rqVeh').value; payload.km = Number(w.querySelector('#rqKm').value); if (!payload.vehicle_id || !(payload.km >= 0)) { draw({ err: true, text: 'Indicá vehículo y km correcto.' }); return; } }
      let routeId = null; const rn = w.querySelector('#rqRoute').value.trim();
      if (rn && api.searchRoutes) { try { const r = await api.searchRoutes({ number: rn, page: 1 }); routeId = (r.rows || r || []).map(x => x).find(x => x.number === rn); routeId = routeId ? routeId.id : null; } catch (e) { routeId = null; } }
      try { const q = await api.createOperationalRequest({ request_type: t, reason: w.querySelector('#rqReason').value, payload, route_id: routeId, op_id: 'rq-' + me.id + '-' + Date.now() });
        draw({ text: 'Solicitud enviada a ' + (q.supervisor_user_id ? 'tu superior' : 'Admin General') + '.' }); } catch (e) { draw({ err: true, text: e.message }); }
    };
    w.querySelectorAll('[data-d]').forEach(b => b.onclick = async () => {
      const tr = b.closest('tr'), note = tr.querySelector('[data-note]').value.trim();
      try { await api.resolveOperationalRequest(tr.dataset.id, b.dataset.d, note, 'ui-' + tr.dataset.id + '-' + b.dataset.d); draw({ text: 'Solicitud ' + ST_LABEL[b.dataset.d][0].toLowerCase() + ' (auditada).' }); }
      catch (e) { draw({ err: true, text: /ALREADY_RESOLVED/.test(e.message) ? 'Otra persona ya resolvió esta solicitud. Se recargó el estado real.' : e.message.replace(/^[A-Z_]+:\s*/, '') }); }
    });
    w.querySelectorAll('[data-cancel]').forEach(b => b.onclick = async () => { try { await api.cancelOperationalRequest(b.closest('tr').dataset.id); draw({ text: 'Solicitud cancelada.' }); } catch (e) { draw({ err: true, text: e.message }); } });
  };
  await draw();
}

// ===================== NOTIFICACIONES =====================
export async function openNotifications(api, me, frame) {
  const w = frame(me, 'Notificaciones', '#/notificaciones');
  const draw = async () => {
    let list = []; try { list = await api.listNotifications(); } catch (e) { msg(w, { err: true, text: e.message }); return; }
    w.innerHTML = '<section class="card"><div class="section-title"><h2>Notificaciones operativas</h2><span class="tag">' + (me.role === 'ADMIN' ? 'Todas' : me.role === 'SUPERVISOR_DESPACHO' ? 'Tuyas y de tu equipo' : 'Propias') + '</span></div>' +
      '<div class="tscroll"><table class="table" id="ntTable"><thead><tr><th>Fecha</th><th>Para</th><th>Aviso</th><th>Detalle</th><th></th></tr></thead><tbody>' +
      (list.map(n => '<tr data-id="' + n.id + '" class="' + (n.read_at ? 'dim' : '') + '"><td>' + esc(dt(n.created_at)) + '</td><td>' + esc(n.mine ? 'Vos' : n.user_name || '') + '</td><td><b>' + esc(n.title) + '</b></td><td>' + esc(n.body || '') + '</td><td>' +
        (n.mine && !n.read_at ? '<button class="btn soft" type="button" data-read>MARCAR LEÍDA</button>' : '') + '</td></tr>').join('') || '<tr><td colspan="5">Sin notificaciones.</td></tr>') + '</tbody></table></div></section>';
    w.querySelectorAll('[data-read]').forEach(b => b.onclick = async () => { await api.markNotificationRead(b.closest('tr').dataset.id); draw(); });
  };
  await draw();
}

// ===================== VEHÍCULOS Y KILOMETRAJE =====================
export async function mileageBlock(api, me, host, again) {
  let m = null; try { m = await api.mileageSettings(); } catch (e) { m = null; }
  if (!m) { host.innerHTML = ''; return; }
  const can = hasPerm(me, 'vehicle_mileage.rules_manage') || hasPerm(me, 'settings.manage');
  host.innerHTML = '<div class="section-title"><h2>Reglas de kilometraje</h2><span class="tag">' + (can ? 'Podés modificarlas' : 'Solo lectura') + '</span></div>' + (can ?
    '<div class="kmcfg edit" id="kmEdit"><label><input type="checkbox" id="kmStart"' + (m.require_km_start ? ' checked' : '') + '> Km inicial obligatorio</label><label><input type="checkbox" id="kmEnd"' + (m.require_km_end ? ' checked' : '') + '> Km final obligatorio</label>' +
    '<label>Recorrido máximo esperable (km)<input class="ed" id="kmMax" value="' + m.max_trip_km + '"></label><label>Tolerancia (km)<input class="ed" id="kmTol" value="' + m.tolerance_km + '"></label>' +
    '<label><input type="checkbox" id="kmLower"' + (m.alert_lower_than_last ? ' checked' : '') + '> Alertar si el km es menor al último registrado</label><button class="btn dark" type="button" id="kmSave">GUARDAR REGLAS</button></div>' : mileageView(m));
  const sv = host.querySelector('#kmSave');
  if (sv) sv.onclick = async () => {
    try { await api.setMileageSettings({ require_km_start: host.querySelector('#kmStart').checked, require_km_end: host.querySelector('#kmEnd').checked, max_trip_km: host.querySelector('#kmMax').value,
      tolerance_km: host.querySelector('#kmTol').value, alert_lower_than_last: host.querySelector('#kmLower').checked }); again({ text: 'Reglas de kilometraje guardadas (auditado).' }); }
    catch (e) { again({ err: true, text: e.message }); }
  };
}
// Lo escrito en la pantalla de vehículos (formulario, km por vehículo, resolución por alerta)
function captureVehInputs(doc) {
  const out = { form: {}, km: {}, note: {}, formCtx: null };
  const f = doc.querySelector('#vehForm'); if (f) out.formCtx = f.dataset.ctx || null;   // 'new' o 'edit:<id>': los valores SOLO valen para ese contexto
  doc.querySelectorAll('#vehForm input').forEach(i => { if (i.id) out.form[i.id] = i.value; });
  doc.querySelectorAll('#vehTable tr[data-vid] [data-km]').forEach(i => { if (i.value) out.km[i.closest('tr').dataset.vid] = i.value; });
  doc.querySelectorAll('#kmAlerts tr[data-aid] [data-note]').forEach(i => { if (i.value) out.note[i.closest('tr').dataset.aid] = i.value; });
  return out;
}
// Lo escrito en Vehículos se GUARDA antes de evaluar la ruta (p. ej. si se revoca todo el acceso), en sessionStorage de esta pestaña y con
// clave POR USUARIO: solo lo escrito y el id del vehículo en edición. Se recupera si vuelve el permiso y se borra al cerrar sesión.
const VD = uid => 'okd_veh_draft:' + uid;
// combinar respaldos: lo de 'top' (lo que está escrito AHORA en pantalla) tiene prioridad sobre 'base' (lo pendiente)
// el formulario se combina SOLO si es el mismo contexto (misma alta o edición del mismo vehículo); si no, manda el de 'top' (lo visible)
const mergeVals = (base, top) => {
  const tf = top && Object.keys(top.form || {}).length, bc = base && base.formCtx, tc = top && top.formCtx;
  const form = !tf ? Object.assign({}, base && base.form) : (bc && tc && bc !== tc) ? Object.assign({}, top.form) : Object.assign({}, base && base.form, top.form);
  return { form, formCtx: tf ? tc : (bc || null), km: Object.assign({}, base && base.km, top && top.km), note: Object.assign({}, base && base.note, top && top.note) };
};
const formCtxOf = form => form ? (form.v ? 'edit:' + form.v.id : 'new') : null;
const emptyVals = v => !v || (!Object.keys(v.form || {}).length && !Object.keys(v.km || {}).length && !Object.keys(v.note || {}).length);
const readDraft = uid => { try { return JSON.parse(sessionStorage.getItem(VD(uid)) || 'null'); } catch (e) { return null; } };
export function stashVehDraft(uid) {
  if (!uid || !document.getElementById('vehTable') && !document.getElementById('vehForm')) return false;
  const prev = readDraft(uid), st = window.__okdVehState || {};
  const vals = mergeVals(prev && prev.vals, captureVehInputs(document));   // no pisa lo pendiente que no está en pantalla (p. ej. alertas que no cargaron)
  const form = st.form ? { mode: st.form.v ? 'edit' : 'new', vid: st.form.v ? st.form.v.id : null } : null;
  if (!form && !Object.keys(vals.km).length && !Object.keys(vals.note).length) return false;
  try { sessionStorage.setItem(VD(uid), JSON.stringify({ tab: st.tab || 'ACTIVOS', form, vals })); return true; } catch (e) { return false; }
}
export function clearVehDrafts() { try { Object.keys(sessionStorage).filter(k => k.startsWith('okd_veh_draft:')).forEach(k => sessionStorage.removeItem(k)); } catch (e) { } }
export async function openVehicles(api, me, frame) {
  // Redibujo por CAMBIO DE PERMISOS (window.__okdKeepState): se conservan pestaña, formulario abierto y TODO lo escrito
  const keep = window.__okdKeepState === true; window.__okdKeepState = false;
  const saved = readDraft(me.id);   // solo lo de ESTE usuario
  const st = keep && window.__okdVehState ? window.__okdVehState
    : saved ? { tab: saved.tab || 'ACTIVOS', form: saved.form ? { v: saved.form.mode === 'edit' ? { id: saved.form.vid, pending: true } : null } : null } : { tab: 'ACTIVOS', form: null };
  let kept = keep ? captureVehInputs(document) : null;   // antes de que frame() reemplace la pantalla
  if (saved) kept = mergeVals(saved.vals, kept);   // vuelve el acceso: lo guardado + lo que esté en pantalla (que tiene prioridad)
  window.__okdVehState = st;
  const w = frame(me, isRc4(me) && me.role !== 'ADMIN' ? 'Vehículos y kilometraje' : 'Kilometraje de vehículos', '#/vehiculos');
  const draw = async (m, drop) => {
    // TODO redibujo conserva lo escrito en pantalla (tiene prioridad sobre el respaldo): abrir el formulario, cambiar de pestaña, REINTENTAR,
    // guardar otra cosa… Solo se descarta lo que una acción ACABA de guardar con éxito ('drop': km de un vehículo / resolución de una alerta).
    const live = captureVehInputs(w);
    if (drop && drop.form) { live.form = {}; live.formCtx = null; if (kept) { kept.form = {}; kept.formCtx = null; } }   // descarte CONFIRMADO
    if (drop && drop.km) delete live.km[drop.km];
    if (drop && drop.note) delete live.note[drop.note];
    if (kept && drop) { if (drop.km) delete kept.km[drop.km]; if (drop.note) delete kept.note[drop.note]; }
    if (!emptyVals(live)) kept = mergeVals(kept, live);
    // Un fallo al consultar NO se muestra como "Sin vehículos"/"Sin alertas": se informa con REINTENTAR
    let vs = [], alerts = [], vErr = null, aErr = null;
    try { vs = await (api.vehicleStatus ? api.vehicleStatus() : api.listVehicles()); if (!Array.isArray(vs)) throw new Error('respuesta inválida'); } catch (e) { vErr = e.message || String(e); vs = []; }
    try { alerts = await api.listMileageAlerts(); if (!Array.isArray(alerts)) throw new Error('respuesta inválida'); } catch (e) { aErr = e.message || String(e); alerts = []; }
    const canEnter = hasPerm(me, 'vehicle_mileage.enter'), canManageVehicles = hasPerm(me, 'vehicles.manage'), canService = hasPerm(me, 'vehicles.service_manage') || canManageVehicles, canEdit = hasPerm(me, 'vehicle_mileage.edit') || canManageVehicles, canResolve = hasPerm(me, 'vehicle_mileage.resolve_alerts');
    if (st.form && st.form.v && st.form.v.pending) { const real = vs.find(x => x.id === st.form.v.id); st.form = real ? { v: real } : (vErr ? st.form : null); }   // EDITAR recuperado
    const tab = st.form && st.form.v && st.form.v.pending ? st.tab : st.tab, form = st.form && st.form.v && st.form.v.pending ? null : st.form, K = kept || { form: {}, km: {}, note: {} };
    const act = vs.filter(v => v.active !== false), ina = vs.filter(v => v.active === false), list = tab === 'INACTIVOS' ? ina : act;
    const errBox = (id, what, e) => '<div class="msg err" id="' + id + '">No se pudieron cargar ' + what + ': ' + esc(e) + ' <button class="btn soft" type="button" data-retry>REINTENTAR</button></div>';
    const tagTxt = [canManageVehicles && 'Administrás vehículos', canEnter && 'Podés cargar km'].filter(Boolean).join(' · ') || 'Solo lectura';
    const fv = form && form.v;
    const RO = fv ? ['vfBrand', 'vfModel', 'vfType', 'vfYear'] : [];   // el servidor no actualiza estos campos al EDITAR (solo en el alta)
    const ctx = formCtxOf(form), KF = K.formCtx === ctx ? K.form : {};   // NUNCA se vuelcan valores de otro vehículo ni de un alta
    const formHtml = form ? '<div class="card" id="vehForm" data-ctx="' + esc(ctx) + '" style="margin:10px 0"><h3>' + (fv ? 'Editar vehículo · ' + esc(fv.plate || '') : 'Nuevo vehículo') + '</h3>' +
      (canManageVehicles ? '' : '<p class="msg warn" id="vfNoPerm">Se quitó tu permiso para administrar vehículos: este formulario no se puede guardar. Lo que escribiste se conserva; podés copiarlo o tocar CANCELAR.</p>') +
      '<div class="row-form">' +
      [['vfName', 'Modelo / nombre (obligatorio)', fv ? fv.name : ''], ['vfPlate', 'Patente (obligatoria)', fv ? fv.plate : ''], ['vfBrand', 'Marca', fv ? fv.brand || '' : ''], ['vfModel', 'Modelo', fv ? fv.model || '' : ''],
       ['vfType', 'Tipo', fv ? fv.type || '' : ''], ['vfYear', 'Año', fv ? (fv.year || '') : ''], ['vfInterval', 'Intervalo de service (km)', fv ? String(fv.service_interval_km || 10000) : '10000']]
        .concat(fv ? [] : [['vfKm', 'Kilometraje inicial', '0']]).concat([['vfNotes', 'Observaciones', fv ? fv.notes || '' : '']])
        .map(([id, l, val]) => '<label>' + l + ' <input class="ed" id="' + id + '" data-orig="' + esc(String(val)) + '" value="' + esc(String(KF[id] != null && !RO.includes(id) ? KF[id] : val)) + '"' + (/Year|Interval|Km/.test(id) ? ' inputmode="numeric"' : '') +
          (RO.includes(id) ? ' readonly aria-readonly="true" data-ro' : '') + '></label>').join('') +
      '</div>' + (fv ? '<p class="rp-note" id="vfRoNote">Marca, modelo, tipo y año no se pueden cambiar al editar: el servidor no guarda esos cambios (solo se cargan en el alta).</p>' : '') +
      '<div class="uact"><button class="btn dark" type="button" id="vfSave"' + (canManageVehicles ? '' : ' disabled') + '>' + (fv ? 'GUARDAR CAMBIOS' : 'DAR DE ALTA') + '</button><button class="btn soft" type="button" id="vfCancel">CANCELAR</button></div>' +
      (fv ? '' : '<p class="rp-note">El vehículo nuevo queda ACTIVO. Los vehículos existentes nunca se activan solos.</p>') + '</div>' : '';
    const row = v => { const on = v.active !== false;
      return '<tr data-vid="' + v.id + '"' + (on ? '' : ' class="veh-off"') + '><td><b>' + esc(v.name) + '</b>' + (v.habitual_driver_id === me.id ? ' <small>(asignado)</small>' : '') + (on ? '' : ' ' + pill('warn', 'Inactivo')) + '</td><td>' + esc(v.plate) + '</td><td>' + n0(v.current_km) + '</td><td>' + (v.next_service_km ? n0(v.next_service_km) : '—') + '</td><td>' +
        (on ? (v.service_due ? pill('bad', 'Service requerido') : pill('ok', 'OK')) : pill('warn', 'Fuera de uso')) + '</td><td><div class="uact">' +
        // un vehículo INACTIVO no recibe km, service ni correcciones; solo se edita o se activa (con administración)
        (on && canEnter ? '<input class="ed" data-km placeholder="Km actual" inputmode="numeric" value="' + esc(K.km[v.id] || '') + '"><button class="btn soft" type="button" data-rec>CARGAR KM</button>'
          : K.km[v.id] ? '<input class="ed" data-km value="' + esc(K.km[v.id]) + '" disabled><small class="msg warn" data-kmnoperm>Sin permiso para cargar km: lo escrito se conserva.</small>' : '') +
        (on && canService ? '<button class="btn soft" type="button" data-service>REGISTRAR SERVICE</button>' : '') +
        (canManageVehicles ? '<button class="btn soft" type="button" data-vedit>EDITAR</button>' + (on ? '<button class="btn soft" type="button" data-voff>DESACTIVAR</button>' : '<button class="btn dark" type="button" data-von>ACTIVAR</button>') : '') +
        (on ? (canEdit ? '<button class="btn soft" type="button" data-fix>CORREGIR KM</button>' : hasPerm(me, 'requests.create') ? '<button class="btn soft" type="button" data-askfix>SOLICITAR CORRECCIÓN</button>' : '') : '') + '</div></td></tr>'; };
    const empty = tab === 'INACTIVOS' ? 'No hay vehículos inactivos.' : 'No hay vehículos activos.' + (ina.length ? ' Hay ' + ina.length + ' inactivo(s): mirá INACTIVOS.' : '');
    w.innerHTML = '<div class="grid"><section class="card span12" id="kmRules"></section>' +
      '<section class="card span12"><div class="section-title"><h2>Vehículos</h2><span class="tag">' + esc(tagTxt) + '</span></div>' +
      (vErr ? errBox('vehErr', 'los vehículos', vErr) :
        '<div class="uact" id="vehTabs"><button class="btn ' + (tab === 'ACTIVOS' ? 'dark' : 'soft') + '" type="button" data-vtab="ACTIVOS">ACTIVOS (' + act.length + ')</button><button class="btn ' + (tab === 'INACTIVOS' ? 'dark' : 'soft') + '" type="button" data-vtab="INACTIVOS">INACTIVOS (' + ina.length + ')</button>' +
        (canManageVehicles ? '<button class="btn go" type="button" id="vehNew">+ NUEVO VEHÍCULO</button>' : '') + '</div>' + formHtml +
        '<div class="tscroll"><table class="table" id="vehTable"><thead><tr><th>Vehículo</th><th>Patente</th><th>Último km</th><th>Próximo service</th><th>Estado</th><th>Acciones</th></tr></thead><tbody>' +
        (list.map(row).join('') || '<tr><td colspan="6" id="vehEmpty">' + esc(empty) + '</td></tr>') + '</tbody></table></div>') + '</section>' +
      '<section class="card span12"><div class="section-title"><h2>Alertas de kilometraje</h2><span class="tag">' + (canResolve ? 'Podés resolverlas' : 'Solo lectura') + '</span></div>' +
      (aErr ? errBox('kmAlertsErr', 'las alertas', aErr) : '<div class="tscroll"><table class="table" id="kmAlerts"><thead><tr><th>Fecha</th><th>Vehículo</th><th>Tipo</th><th>Km</th><th>Estado</th><th></th></tr></thead><tbody>' +
      (alerts.map(a => '<tr data-aid="' + a.id + '"><td>' + esc(dt(a.created_at)) + '</td><td>' + esc(a.plate || '') + '</td><td>' + esc({ LOWER_THAN_LAST: 'Km menor que el último registrado', TRIP_OUT_OF_RANGE: 'Recorrido fuera de rango', INCONSISTENT: 'Diferencia inconsistente' }[a.kind] || a.kind) + '</td><td>' +
        n0(a.km_from) + ' → ' + n0(a.km_to) + '</td><td>' + (a.status === 'OPEN' ? pill('warn', 'Abierta') : pill('ok', 'Resuelta')) + (a.resolution_note ? '<br><small>' + esc(a.resolution_note) + '</small>' : '') + '</td><td>' +
        (a.status === 'OPEN' && canResolve ? '<div class="uact"><input class="ed" data-note placeholder="Resolución" value="' + esc(K.note[a.id] || '') + '"><button class="btn soft" type="button" data-res>RESOLVER</button></div>'
          : K.note[a.id] ? '<div class="uact"><input class="ed" data-note value="' + esc(K.note[a.id]) + '" disabled><small class="msg warn">Sin permiso para resolver: lo escrito se conserva.</small></div>' : '') + '</td></tr>').join('') || '<tr><td colspan="6">Sin alertas.</td></tr>') + '</tbody></table></div>') + '</section></div>';
    // Cada parte del respaldo se descarta SOLO si quedó a la vista con su valor (formulario, km por vehículo, resolución por alerta).
    // Lo que no se pudo mostrar (p. ej. falló solo la consulta de alertas) se CONSERVA en memoria y en el respaldo del usuario.
    if (kept) {
      if (!st.form || (kept.formCtx && kept.formCtx !== formCtxOf(st.form) && w.querySelector('#vehForm'))) { kept.form = {}; kept.formCtx = null; }
      else if (w.querySelector('#vehForm') && Object.keys(kept.form).every(id => { const i = w.querySelector('#' + id); return !i || i.readOnly || i.value === kept.form[id]; })) { kept.form = {}; kept.formCtx = null; }
      for (const [vid, val] of Object.entries(kept.km)) { const i = w.querySelector('tr[data-vid="' + vid + '"] [data-km]'); if (i && i.value === val) delete kept.km[vid]; }
      for (const [aid, val] of Object.entries(kept.note)) { const i = w.querySelector('tr[data-aid="' + aid + '"] [data-note]'); if (i && i.value === val) delete kept.note[aid]; }
      if (emptyVals(kept)) { kept = null; try { sessionStorage.removeItem(VD(me.id)); } catch (e) { } }
      else { try { sessionStorage.setItem(VD(me.id), JSON.stringify({ tab: st.tab, form: st.form ? { mode: st.form.v ? 'edit' : 'new', vid: st.form.v ? st.form.v.id : null } : null, vals: kept })); } catch (e) { } }
    }
    w.querySelectorAll('[data-retry]').forEach(b => b.onclick = () => { b.disabled = true; draw(); });
    // ¿el formulario abierto tiene cambios sin guardar? (algún campo distinto de su valor original)
    const dirty = () => [...w.querySelectorAll('#vehForm input[data-orig]')].some(i => !i.readOnly && i.value !== i.dataset.orig);
    const ctxLabel = () => st.form && st.form.v ? 'la edición de ' + (st.form.v.name || '') + ' (' + (st.form.v.plate || '') + ')' : 'el alta de un vehículo nuevo';
    // cambiar de contexto con cambios pendientes: aviso con opción de CANCELAR; aceptar descarta esos cambios (nunca se transfieren)
    const leaveForm = target => !st.form || !dirty() || confirm('Tenés cambios sin guardar en ' + ctxLabel() + '. Si ' + target + ', esos cambios se descartan (no se pasan a otro formulario). ¿Continuar?');
    w.querySelectorAll('[data-vtab]').forEach(b => b.onclick = () => { if (!leaveForm('cambiás de pestaña')) return; st.tab = b.dataset.vtab; st.form = null; draw(undefined, { form: true }); });
    const nb = w.querySelector('#vehNew'); if (nb) nb.onclick = () => { if (st.form && !st.form.v) return;   // ya está abierta el alta
      if (!leaveForm('abrís NUEVO VEHÍCULO')) return; st.form = { v: null }; draw(undefined, { form: true }); };
    const cc = w.querySelector('#vfCancel'); if (cc) cc.onclick = () => { if (!leaveForm('cancelás')) return; st.form = null; draw(undefined, { form: true }); };
    const sv = w.querySelector('#vfSave'); if (sv) sv.onclick = async () => {
      if (!hasPerm(me, 'vehicles.manage')) { msg(w, { err: true, text: 'Sin permiso para administrar vehículos: no se guardó. Lo escrito se conserva.' }); return; }
      const g = id => (w.querySelector('#' + id) || {}).value || '', v = st.form.v;
      const p = { name: g('vfName').trim(), plate: g('vfPlate').trim(), service_interval_km: Number(g('vfInterval')) || 10000, notes: g('vfNotes'), habitual_driver_id: v ? v.habitual_driver_id || '' : '' };
      // editar NO cambia el estado activo/inactivo ni envía marca/modelo/tipo/año (el servidor no los actualiza en la edición)
      if (v) Object.assign(p, { id: v.id, active: v.active !== false });
      else Object.assign(p, { brand: g('vfBrand').trim(), model: g('vfModel').trim(), type: g('vfType').trim(), year: g('vfYear').trim(), current_km: Number(g('vfKm')) || 0 });
      sv.disabled = true;
      try { await api.saveVehicle(p); st.form = null; draw({ text: v ? 'Vehículo actualizado (auditado): modelo/nombre, patente, intervalo de service y observaciones.' : 'Vehículo dado de alta (activo).' }, { form: true }); }
      catch (e) { sv.disabled = false; msg(w, { err: true, text: e.message }); }
    };
    w.querySelectorAll('[data-vedit]').forEach(b => b.onclick = () => { const v = vs.find(x => x.id === b.closest('tr').dataset.vid); if (!v) return;
      if (st.form && st.form.v && st.form.v.id === v.id) return;   // ya se está editando ese vehículo
      if (!leaveForm('abrís la edición de ' + v.name + ' (' + v.plate + ')')) return; st.form = { v }; draw(undefined, { form: true }); });
    const setActive = (b, on) => b.onclick = async () => { const v = vs.find(x => x.id === b.closest('tr').dataset.vid); if (!v) return;
      if (!confirm((on ? '¿ACTIVAR' : '¿DESACTIVAR') + ' el vehículo ' + v.name + ' (' + v.plate + ')?' + (on ? '' : ' No se podrá asignar a hojas ni cargarle km.'))) return;
      try { await api.saveVehicle({ id: v.id, name: v.name, plate: v.plate, habitual_driver_id: v.habitual_driver_id || '', service_interval_km: v.service_interval_km || 10000, notes: v.notes || '', active: on });
        draw({ text: 'Vehículo ' + (on ? 'activado' : 'desactivado') + ' (auditado).' }); } catch (e) { draw({ err: true, text: e.message }); } };
    w.querySelectorAll('[data-von]').forEach(b => setActive(b, true)); w.querySelectorAll('[data-voff]').forEach(b => setActive(b, false));
    msg(w, m);
    await mileageBlock(api, me, w.querySelector('#kmRules'), draw);
    w.querySelectorAll('[data-rec]').forEach(b => b.onclick = async () => { const tr = b.closest('tr'), km = Number(tr.querySelector('[data-km]').value);
      try { const r = await api.recordVehicleKm(tr.dataset.vid, km, 'Carga desde OK Despacho'); draw(r.ok === false ? { err: true, text: r.message } : { text: 'Kilometraje cargado: ' + n0(r.current_km) + ' km.' }, r.ok === false ? null : { km: tr.dataset.vid }); } catch (e) { draw({ err: true, text: e.message }); } });
    w.querySelectorAll('[data-service]').forEach(b => b.onclick = async () => {
      const tr = b.closest('tr'), v = vs.find(x => x.id === tr.dataset.vid);
      const km = prompt('Kilometraje al momento del service', String(v && v.current_km != null ? v.current_km : '')); if (km == null) return;
      const date = prompt('Fecha del service (AAAA-MM-DD)', new Date().toISOString().slice(0,10)); if (date == null) return;
      const note = prompt('Observación del service (opcional)', '') || '';
      try { await api.registerServiceDone(tr.dataset.vid, Number(km), date, note); if (api.sendServiceAlerts) api.sendServiceAlerts().catch(() => null); draw({ text: 'Service registrado. Se recalculó el próximo service y comenzó un nuevo ciclo.' }); }
      catch (e) { draw({ err: true, text: e.message }); }
    });
    w.querySelectorAll('[data-fix]').forEach(b => b.onclick = async () => { const tr = b.closest('tr'), km = prompt('Kilometraje correcto'); if (km == null) return; const why = prompt('Motivo de la corrección (obligatorio)'); if (!why) return;
      try { await api.correctVehicleKm(tr.dataset.vid, Number(km), why); draw({ text: 'Kilometraje corregido (auditado).' }); } catch (e) { draw({ err: true, text: e.message }); } });
    w.querySelectorAll('[data-askfix]').forEach(b => b.onclick = async () => { const tr = b.closest('tr'), km = prompt('Kilometraje correcto'); if (km == null) return; const why = prompt('Motivo (obligatorio)'); if (!why) return;
      try { await api.createOperationalRequest({ request_type: 'CORRECCION_KM', reason: why, payload: { vehicle_id: tr.dataset.vid, km: Number(km) }, op_id: 'km-' + me.id + '-' + Date.now() }); draw({ text: 'Corrección solicitada a tu superior.' }); } catch (e) { draw({ err: true, text: e.message }); } });
    w.querySelectorAll('[data-res]').forEach(b => b.onclick = async () => { const tr = b.closest('tr');
      try { await api.resolveMileageAlert(tr.dataset.aid, tr.querySelector('[data-note]').value); draw({ text: 'Alerta resuelta (auditada).' }, { note: tr.dataset.aid }); } catch (e) { draw({ err: true, text: e.message }); } });
  };
  await draw();
}

// ===================== CONFIGURACIÓN OPERATIVA (columnas + kilometraje, según permiso) =====================
export async function openOperationalConfig(api, me, frame, plantillasSection) {
  const w = frame(me, me.role === 'OPERARIO_DEPOSITO' ? 'Columnas predeterminadas' : 'Configuración operativa', '#/config-operativa');
  const canCols = hasPerm(me, 'columns.manage_defaults') || hasPerm(me, 'columns.manage_templates') || hasPerm(me, 'settings.manage');
  const draw = async m => {
    w.innerHTML = '<div class="grid">' + (hasPerm(me, 'columns.view') || canCols ? '<section class="card span12 step rp-step" id="cfg-plantillas"></section>' : '') + (hasPerm(me, 'vehicle_mileage.view') && me.role !== 'OPERARIO_DEPOSITO' ? '<section class="card span12" id="kmRules"></section>' : '') + '</div>';
    msg(w, m);
    const sec = w.querySelector('#cfg-plantillas');
    if (sec) {
      if (canCols) await plantillasSection(api, me, sec, draw);
      else {
        const cs = await api.listCarriers(), cid = sec.dataset.cid || cs[0].id, t = await api.currentTemplate(cid), cols = (t.columns || []).slice().sort((a, b) => (a.order || 0) - (b.order || 0));
        const f = b => b === false ? '—' : '✓';
        sec.innerHTML = '<h2>COLUMNAS PREDETERMINADAS</h2><p class="rp-note">Solo lectura. Para cambiarlas hace falta el permiso "Modificar columnas", que otorga Admin General.</p><label class="rp-lbl">Transportista <select id="tplCarrierRo">' +
          cs.map(c => '<option value="' + c.id + '"' + (c.id === cid ? ' selected' : '') + '>' + esc(c.name) + '</option>').join('') + '</select></label> <span class="rp-note">' + (t.version ? 'Versión v' + t.version : 'Plantilla predeterminada') + '</span>' +
          '<div class="tscroll"><table class="table" id="tplRo"><thead><tr><th>Columna</th><th>Título</th><th>Visible</th><th>Pantalla</th><th>PDF</th><th>Excel</th></tr></thead><tbody>' +
          cols.map(c => '<tr><td>' + esc(c.key) + '</td><td>' + esc(c.title) + '</td><td>' + f(c.visible) + '</td><td>' + f(c.screen) + '</td><td>' + f(c.pdf) + '</td><td>' + f(c.excel) + '</td></tr>').join('') + '</tbody></table></div>';
        sec.querySelector('#tplCarrierRo').onchange = e => { sec.dataset.cid = e.target.value; draw(); };
      }
    }
    const km = w.querySelector('#kmRules'); if (km) await mileageBlock(api, me, km, draw);
  };
  await draw();
}

// ===================== PERMISOS DE UN USUARIO (Admin) =====================
export const PERM_GROUPS = [
  ['Comunicaciones', ['comms.view', 'comms.collaborators_manage', 'comms.compose', 'comms.schedule', 'comms.test_send', 'comms.gmail_manage']],
  ['Hojas', ['routes.create', 'routes.edit', 'routes.publish', 'routes.cancel', 'routes.assign', 'routes.reassign', 'routes.view_all', 'routes.view_team', 'routes.view_own', 'routes.receive_internal', 'routes.manage_all_drafts']],
  ['Borradores', ['drafts.create', 'drafts.view_own', 'drafts.view_team', 'drafts.manage_team']],
  ['Solicitudes / aprobaciones', ['requests.create', 'requests.view_team', 'requests.approve_team', 'requests.reject_team', 'requests.observe_team', 'requests.reassign', 'can_approve_internal_route_changes']],
  ['Columnas', ['columns.view', 'columns.manage_defaults', 'columns.manage_templates', 'columns.apply_global']],
  ['Kilometraje', ['vehicle_mileage.view', 'vehicle_mileage.enter', 'vehicle_mileage.edit', 'vehicle_mileage.rules_manage', 'vehicle_mileage.resolve_alerts']],
  ['Vehículos', ['vehicles.view', 'vehicles.manage', 'vehicles.service_manage']],
  ['Usuarios', ['users.view', 'users.manage', 'users.assign_supervisor', 'users.manage_permissions']],
  ['Administración', ['settings.manage', 'credit_notes.manage', 'audit.view', 'backup.manage', 'identity_docs.view', 'collections.manage', 'internal_routes.manage', 'locations.manage', 'can_view_commercial_transport_reports', 'can_manage_commercial_transport_reports']]
];
export const PERM_LABEL = {
  'routes.create': 'Crear / preparar hojas', 'routes.edit': 'Editar hojas', 'routes.publish': 'Publicar hojas', 'routes.cancel': 'Cancelar hojas', 'routes.assign': 'Asignar transportista / responsable / vehículo',
  'routes.reassign': 'Reasignar', 'routes.view_all': 'Ver todas las hojas', 'routes.view_team': 'Ver hojas del equipo', 'routes.view_own': 'Ver hojas propias', 'routes.receive_internal': 'Permitir asignación de hojas de ruta', 'comms.view': 'Comunicaciones: consultar', 'comms.collaborators_manage': 'Comunicaciones: administrar colaboradores', 'comms.compose': 'Comunicaciones: redactar y compartir', 'comms.schedule': 'Comunicaciones: programar, pausar y cancelar', 'comms.test_send': 'Comunicaciones: enviar pruebas', 'comms.gmail_manage': 'Comunicaciones: administrar la conexión Gmail', 'routes.manage_all_drafts': 'Gestionar TODOS los borradores',
  'drafts.create': 'Crear borradores', 'drafts.view_own': 'Ver borradores propios', 'drafts.view_team': 'Ver borradores del equipo', 'drafts.manage_team': 'Gestionar borradores del equipo',
  'requests.create': 'Solicitar autorización', 'requests.view_team': 'Ver solicitudes del equipo', 'requests.approve_team': 'Aprobar solicitudes del equipo', 'requests.reject_team': 'Rechazar solicitudes del equipo',
  'requests.observe_team': 'Observar solicitudes del equipo', 'requests.reassign': 'Reasignar solicitudes', 'can_approve_internal_route_changes': 'Aprobar cambios de ruta interna',
  'columns.view': 'Ver columnas', 'columns.manage_defaults': 'Modificar columnas predeterminadas', 'columns.manage_templates': 'Modificar plantillas', 'columns.apply_global': 'Aplicar columnas globales',
  'vehicle_mileage.view': 'Ver kilometraje', 'vehicle_mileage.enter': 'Cargar kilometraje', 'vehicle_mileage.edit': 'Corregir kilometraje', 'vehicle_mileage.rules_manage': 'Modificar reglas de kilometraje',
  'vehicle_mileage.resolve_alerts': 'Resolver alertas de kilometraje', 'vehicles.view': 'Ver vehículos', 'vehicles.manage': 'Administrar vehículos', 'vehicles.service_manage': 'Gestionar service',
  'users.view': 'Ver usuarios', 'users.manage': 'Administrar usuarios', 'users.assign_supervisor': 'Asignar superior', 'users.manage_permissions': 'Administrar permisos',
  'settings.manage': 'Configuración global', 'credit_notes.manage': 'NOC administrativo', 'audit.view': 'Auditoría', 'backup.manage': 'Backup', 'identity_docs.view': 'Ver DNI', 'collections.manage': 'Cobranzas',
  'internal_routes.manage': 'Gestionar ruta interna', 'locations.manage': 'Administrar ubicaciones', 'can_view_commercial_transport_reports': 'Ver informes comerciales', 'can_manage_commercial_transport_reports': 'Administrar informes comerciales'
};