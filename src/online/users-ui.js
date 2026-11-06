// Admin → USUARIOS. Misma estética que la versión offline (cabecera oscura, tabla negra con línea cyan).
import { esc, fmtDate, fmtDay } from './util.js';
import { ROLES, ASSIGNABLE_ROLES, ROLE_LABEL, hasPerm, compatibleResponsables, MODULES, MODULE_LABEL, roleModules, ROLE_PERMISSIONS, SENSITIVE_PERMISSIONS } from '../../supabase/functions/_shared/rules.js';
import { PERM_GROUPS, PERM_LABEL, appFrame, isRc4 } from './rc4-ui.js';
// RC4: roles que tienen superior asignado y qué roles pueden ser su superior
const SUP_ROLES = { OPERARIO_DEPOSITO: ['SUPERVISOR_DESPACHO', 'ADMIN'], SUPERVISOR_DESPACHO: ['ADMIN'], TRANSPORTISTA_INTERNO: ['SUPERVISOR_DESPACHO', 'ADMIN'] };
import { openAccount } from './account-ui.js';

const STATUS_LABEL = { ACTIVO: 'ACTIVO', DESHABILITADO: 'DESHABILITADO', ARCHIVADO: 'ARCHIVADO', INVITACION_PENDIENTE: 'INVITACIÓN PENDIENTE' };

export class UsersPanel {
  constructor(api, me, onClose, onLogout) {
    this.api = api; this.me = me; this.onClose = onClose; this.onLogout = onLogout;
    this.el = document.getElementById('usersPanel');
    this.users = []; this.carriers = []; this.msg = null;
    this.f = { q: '', role: '', status: '', carrier: '' };
  }
  async open() {
    this.el.hidden = false;
    if (isRc4(this.me)) {
      const w = appFrame(this.me, 'Usuarios y permisos', '#/usuarios', 'Roles, jerarquía, accesos y permisos por usuario');
      w.innerHTML = '<div class="up-wrap rc4-users-wrap" id="upWrap"></div>';
    } else {
      this.el.innerHTML = '<header class="top"><img class="brandtile" src="/icons/icon-192.png?v=20261120" alt="OK Accesorios"><div class="ttl"><b>DESPACHO</b><span>Administración</span></div><div class="sp"></div>' +
        '<button class="who-chip linkchip" type="button" id="upMe">' + esc(this.me.full_name) + ' · <b>' + esc(ROLE_LABEL[this.me.role] || this.me.role) + '</b></button>' +
        '<button class="tbtn" type="button" id="upClose">Volver al panel</button></header><div class="up-wrap" id="upWrap"></div>';
      this.el.querySelector('#upClose').addEventListener('click', () => this.close());
      this.el.querySelector('#upMe').addEventListener('click', () => openAccount(this.api, this.me, this.onLogout || (() => {})));
    }
    await this.reload();
  }
  close() { if (location.hash) history.replaceState(null, '', location.pathname); this.el.hidden = true; this.el.innerHTML = ''; this.onClose && this.onClose(); }
  async reload() {
    if (!(await this.api.getSession())) { location.reload(); return; } // la propia sesión fue cerrada
    try { [this.users, this.carriers] = await Promise.all([this.api.listUsers(), this.api.listCarriers()]); }
    catch (e) { this.msg = { err: true, text: e.message }; this.users = []; }
    this.render();
  }
  carrierName(id) { const c = this.carriers.find(x => x.id === id); return c ? c.name : id; }
  // ================= V4.26 · DISEÑO V3 APROBADO: pestañas uniformes · búsqueda FIJA · tarjetas sin desplazamiento lateral · panel de edición con TODAS las acciones =================
  // (La lógica de cada acción —doAction, openEdit con el Superior vía setUserSupervisor, openPermissions, withActiveRoutes— es la misma de antes.)
  initials(n) { return String(n || '?').split(/\s+/).filter(Boolean).slice(0, 2).map(x => x[0]).join('').toUpperCase(); }
  render() {
    const canManage = hasPerm(this.me, 'users.manage'); this.tab = this.tab || 'usuarios';
    const w = this.el.querySelector('#upWrap'), opt = (v, l, sel) => '<option value="' + esc(v) + '"' + (v === sel ? ' selected' : '') + '>' + esc(l) + '</option>';
    const tabs = [['usuarios', 'Usuarios (' + this.users.filter(u => u.status !== 'ARCHIVADO').length + ')'], ['roles', 'Roles y permisos'], ['jerarquia', 'Jerarquía y equipos'], ['actividad', 'Actividad']];
    w.innerHTML = '<div class="v3-card"><nav class="v3-tabs" role="tablist">' + tabs.map(([k, l]) => '<button type="button" role="tab" data-v3tab="' + k + '" aria-selected="' + (this.tab === k) + '">' + esc(l) + '</button>').join('') + '</nav>' +
      (this.msg ? '<div class="up-msg ' + (this.msg.err ? 'err' : 'ok') + '" id="upMsg">' + esc(this.msg.text) + '</div>' : '') + '<div id="v3Pane"></div></div>';
    w.querySelectorAll('[data-v3tab]').forEach(b => b.onclick = () => { this.tab = b.dataset.v3tab; this.render(); });
    const pane = w.querySelector('#v3Pane');
    if (this.tab === 'roles') return this.renderRoles(pane);
    if (this.tab === 'jerarquia') return this.renderHierarchy(pane);
    if (this.tab === 'actividad') return this.renderActivity(pane);
    pane.innerHTML = '<div class="v3-sticky"><div class="v3-title"><div><h2>Usuarios</h2><p>Elegí «Editar» para ver todas las opciones aquí mismo</p></div>' + (canManage ? '<button class="btn go" id="upNew" type="button">+ Nuevo usuario</button>' : '') + '</div>' +
      '<div class="v3-filters"><input id="ufSearch" type="search" placeholder="Buscar nombre, email o teléfono" value="' + esc(this.f.q) + '">' +
      '<select id="ufRole">' + opt('', 'Todos los roles', this.f.role) + ROLES.map(r => opt(r, ROLE_LABEL[r], this.f.role)).join('') + '</select>' +
      '<select id="ufStatus">' + opt('', 'Todos los estados', this.f.status) + Object.keys(STATUS_LABEL).map(x => opt(x, STATUS_LABEL[x], this.f.status)).join('') + '</select>' +
      '<select id="ufCarrier">' + opt('', 'Todos los transportistas', this.f.carrier) + this.carriers.map(c => opt(c.id, c.name, this.f.carrier)).join('') + '</select>' +
      '<span class="ufcount" id="ufCount"></span></div></div>' +
      '<div class="v3-grid"><div class="v3-list"><div class="v3-head"><span>USUARIO</span><span>CONTACTO</span><span>ROL</span><span>ACCIÓN</span></div><div id="upBody"></div></div><aside class="v3-side" id="upSide"></aside></div>';
    this.renderRows(); this.renderSide();
    const n = pane.querySelector('#upNew'); if (n) n.addEventListener('click', () => { this.sel = null; this.renderSide(); this.openEdit(null); });
    pane.querySelector('#ufSearch').addEventListener('input', e => { this.f.q = e.target.value; this.renderRows(); });
    [['#ufRole', 'role'], ['#ufStatus', 'status'], ['#ufCarrier', 'carrier']].forEach(([q, k]) => pane.querySelector(q).addEventListener('change', e => { this.f[k] = e.target.value; this.renderRows(); }));
    this.layoutEditor();
  }
  filtered() {
    const q = this.f.q.trim().toLowerCase(), qd = q.replace(/\D/g, '');
    return this.users.filter(u =>
      (!q || u.full_name.toLowerCase().includes(q) || u.email.toLowerCase().includes(q) || (qd.length >= 3 && String(u.phone || '').replace(/\D/g, '').includes(qd))) &&
      (!this.f.role || u.role === this.f.role) && (!this.f.status || u.status === this.f.status) &&
      (!this.f.carrier || (this.f.carrier === 'INTERNO' ? u.role === 'TRANSPORTISTA_INTERNO' : (u.carriers || []).includes(this.f.carrier)))
    ).sort((a, b) => (a.status === 'ARCHIVADO') - (b.status === 'ARCHIVADO') || a.full_name.localeCompare(b.full_name, 'es'));
  }
  subtitle(u) {
    const sup = u.supervisor_user_id ? (this.users.find(x => x.id === u.supervisor_user_id) || {}).full_name : '';
    if (u.role === 'TRANSPORTISTA_INTERNO') return 'Transporte interno' + (sup ? ' · Superior: ' + sup : '');
    if ((u.carriers || []).length) return (u.carriers || []).map(c => this.carrierName(c)).join(', ');
    if (SUP_ROLES[u.role]) return sup ? 'Superior: ' + sup : 'Pendiente de superior';
    return ROLE_LABEL[u.role] || u.role;
  }
  renderRows() {
    const rows = this.filtered(), body = this.el.querySelector('#upBody'); if (!body) return;
    this.el.querySelector('#ufCount').textContent = rows.length + ' de ' + this.users.length;
    body.innerHTML = rows.map(u => {
      const self = u.id === this.me.id;
      return '<article class="v3-row' + (u.id === this.sel ? ' sel' : '') + (u.status === 'ARCHIVADO' ? ' dim' : '') + '" data-uid="' + u.id + '"><div class="v3-who"><span class="v3-av">' + esc(this.initials(u.full_name)) + '</span><div><b>' + esc(u.full_name) + '</b>' + (self ? ' <small>(vos)</small>' : '') +
        '<small class="usup">' + esc(this.subtitle(u)) + '</small></div></div><div class="v3-contact">' + esc(u.email) + '<small>' + esc(u.phone || '') + '</small></div>' +
        '<div class="v3-role"><span class="v3-chip">' + esc(ROLE_LABEL[u.role] || u.role) + '</span><span class="ust ' + u.status + '">' + esc(STATUS_LABEL[u.status] || u.status) + '</span></div>' +
        '<div class="v3-act"><button class="btn soft" type="button" data-pick="' + u.id + '">' + (hasPerm(this.me, 'users.manage') && u.status !== 'ARCHIVADO' ? 'Editar →' : 'Ver →') + '</button></div></article>';
    }).join('') || '<p class="v3-empty">No hay usuarios con esos filtros.</p>';
    body.querySelectorAll('[data-pick]').forEach(b => b.onclick = () => this.pick(b.dataset.pick));
  }
  pick(id) {
    this.sel = id; this.renderRows(); this.renderSide();
    this.layoutEditor();
    const side = this.el.querySelector('#upSide');
    if (side && innerWidth <= 1100) requestAnimationFrame(() => side.scrollIntoView({ behavior: 'smooth', block: 'start' }));
  }
  layoutEditor() {
    const bar = this.el.querySelector('.rc4side'), search = this.el.querySelector('.v3-sticky'), side = this.el.querySelector('#upSide');
    const barHeight = bar && getComputedStyle(bar).position === 'sticky' && innerWidth <= 900 ? bar.getBoundingClientRect().height : 0;
    this.el.style.setProperty('--v3-shell-height', barHeight + 'px');
    if (side) side.style.scrollMarginTop = (barHeight + (search ? search.getBoundingClientRect().height : 0) + 12) + 'px';
  }
  renderSide() {
    const side = this.el.querySelector('#upSide'); if (!side) return;
    const u = this.users.find(x => x.id === this.sel);
    if (!u) { side.innerHTML = '<div class="v3-side-empty">Elegí un usuario para ver y usar todas sus acciones.</div>'; return; }
    const canManage = hasPerm(this.me, 'users.manage'), self = u.id === this.me.id;
    const b = (act, label, cls) => '<button class="btn ' + (cls || 'soft') + '" type="button" data-act="' + act + '" data-id="' + u.id + '">' + label + '</button>';
    let acc = '';   // MISMAS acciones y MISMAS condiciones que la versión anterior
    if (canManage) {
      if (u.status !== 'ARCHIVADO') acc += b('edit', 'EDITAR', 'dark');
      if (u.status === 'INVITACION_PENDIENTE') acc += b('resend_invite', 'REENVIAR INVITACIÓN') + b('cancel_invite', 'CANCELAR INVITACIÓN');
      if (u.status === 'ACTIVO') acc += b('reset_password', 'RESTABLECER CONTRASEÑA') + b('revoke_sessions', 'CERRAR SESIONES ABIERTAS', 'soft wide');
      if (!self && u.status !== 'ARCHIVADO' && hasPerm(this.me, 'users.manage_permissions')) acc += b('perms', 'PERMISOS ▾', 'ghost wide');
      let risky = '';
      if (u.status === 'ACTIVO' && !self) risky += b('disable', 'DESHABILITAR');
      if (u.status === 'DESHABILITADO' || u.status === 'ARCHIVADO') risky += b('reactivate', 'REACTIVAR');
      if (!self && u.status !== 'ARCHIVADO') risky += b('remove', 'ELIMINAR / ARCHIVAR', 'danger');
      if (risky) acc += '<hr class="v3-sep">' + risky;
    }
    side.innerHTML = '<header class="v3-side-head"><div><h3>' + (canManage ? 'Editar usuario' : 'Usuario') + '</h3><p>Todas las acciones disponibles en este panel</p></div><button type="button" class="v3-x" id="upSideX" aria-label="Cerrar">×</button></header>' +
      '<div class="v3-side-body"><div class="v3-who big"><span class="v3-av">' + esc(this.initials(u.full_name)) + '</span><div><b>' + esc(u.full_name) + '</b><small>' + esc(u.email) + '</small></div></div>' +
      '<dl class="v3-facts"><dt>Rol</dt><dd>' + esc(ROLE_LABEL[u.role] || u.role) + '</dd><dt>Estado</dt><dd>' + esc(STATUS_LABEL[u.status] || u.status) + '</dd><dt>Equipo</dt><dd>' + esc(this.subtitle(u)) + '</dd>' +
      '<dt>Último acceso</dt><dd>' + esc(fmtDate(u.last_sign_in_at) || '—') + '</dd><dt>Creado</dt><dd>' + esc(fmtDay(u.created_at) || '—') + '</dd></dl>' +
      (acc ? '<h4 class="v3-sub">ACCIONES DE CUENTA</h4><div class="v3-actions">' + acc + '</div><p class="v3-note">Las acciones piden confirmación y quedan registradas en la auditoría.</p>' : '') +
      '<div id="upInline"></div></div>';
    side.querySelector('#upSideX').onclick = () => { this.sel = null; this.renderRows(); this.renderSide(); };
    side.querySelectorAll('[data-act]').forEach(btn => btn.addEventListener('click', () => this.doAction(btn.dataset.act, btn.dataset.id)));
    if (canManage && u.status !== 'ARCHIVADO' && !this.noAutoEdit) this.openEdit(u);   // DATOS DEL USUARIO en el mismo panel (mismo editor y mismas validaciones que antes)
    this.noAutoEdit = false;
  }
  renderRoles(pane) {
    pane.innerHTML = '<div class="v3-sticky"><div class="v3-title"><div><h2>Roles y permisos</h2><p>Permisos base de cada rol (los permisos individuales se ajustan desde «Editar» → PERMISOS)</p></div></div></div>' +
      '<div class="v3-cards">' + ROLES.map(r => { const perms = ROLE_PERMISSIONS[r] || [], n = this.users.filter(u => u.role === r && u.status !== 'ARCHIVADO').length;
        return '<article class="v3-box"><header><b>' + esc(ROLE_LABEL[r]) + '</b><span class="v3-chip">' + n + ' usuario' + (n === 1 ? '' : 's') + '</span></header>' +
          '<p class="v3-mods">' + (roleModules(r).map(m => esc(MODULE_LABEL[m] || m)).join(' · ') || 'Sin módulos de administración') + '</p>' +
          '<details><summary>' + perms.length + ' permisos</summary><ul>' + perms.map(p => '<li>' + esc(PERM_LABEL[p] || p) + '</li>').join('') + '</ul></details></article>'; }).join('') + '</div>';
  }
  renderHierarchy(pane) {
    const act = this.users.filter(u => u.status !== 'ARCHIVADO'), heads = act.filter(u => u.role === 'ADMIN' || u.role === 'SUPERVISOR_DESPACHO');
    const box = (title, sub, list) => '<article class="v3-box"><header><b>' + esc(title) + '</b><span class="v3-chip">' + list.length + '</span></header><p class="v3-mods">' + esc(sub) + '</p>' +
      (list.length ? '<ul class="v3-members">' + list.map(u => '<li><span class="v3-av sm">' + esc(this.initials(u.full_name)) + '</span>' + esc(u.full_name) + ' <small>' + esc(ROLE_LABEL[u.role] || u.role) + '</small></li>').join('') + '</ul>' : '<p class="v3-empty">Sin integrantes</p>') + '</article>';
    const orphans = act.filter(u => SUP_ROLES[u.role] && !u.supervisor_user_id);
    pane.innerHTML = '<div class="v3-sticky"><div class="v3-title"><div><h2>Jerarquía y equipos</h2><p>Quién depende de cada Superior (se asigna desde «Editar» → Superior asignado)</p></div></div></div>' +
      '<div class="v3-cards">' + heads.map(h => box(h.full_name, ROLE_LABEL[h.role], act.filter(u => u.supervisor_user_id === h.id))).join('') +
      (orphans.length ? box('Sin superior asignado', 'Requieren asignación (por ejemplo, para enviar inspecciones)', orphans) : '') + '</div>';
  }
  renderActivity(pane) {
    const list = this.users.slice().sort((a, b) => String(b.last_sign_in_at || '').localeCompare(String(a.last_sign_in_at || '')));
    pane.innerHTML = '<div class="v3-sticky"><div class="v3-title"><div><h2>Actividad</h2><p>Último acceso de cada usuario (el detalle de acciones está en Auditoría)</p></div></div></div>' +
      '<div class="v3-list"><div id="upActBody">' + list.map(u => '<article class="v3-row"><div class="v3-who"><span class="v3-av">' + esc(this.initials(u.full_name)) + '</span><div><b>' + esc(u.full_name) + '</b><small>' + esc(ROLE_LABEL[u.role] || u.role) + '</small></div></div>' +
        '<div class="v3-contact">Último acceso<small>' + esc(fmtDate(u.last_sign_in_at) || 'nunca') + '</small></div><div class="v3-role"><span class="ust ' + u.status + '">' + esc(STATUS_LABEL[u.status] || u.status) + '</span></div><div></div></article>').join('') + '</div></div>';
  }
  say(text, err) { this.msg = { text, err: !!err }; }
  async run(fn, okText) {
    try { const r = await fn(); this.say((r && r.message) || okText); } catch (e) { this.say(e.message, true); }
    await this.reload();
  }
  async doAction(act, id) {
    const u = this.users.find(x => x.id === id);
    const ask = t => confirm(t);
    switch (act) {
      case 'edit': return this.openEdit(u);
      case 'perms': return this.openPermissions(u);
      case 'disable':
        if (!ask('¿Deshabilitar a ' + u.full_name + '? No podrá iniciar sesión ni operar y se cierran sus sesiones abiertas. Su historial se conserva.')) return;
        return this.withActiveRoutes(u, 'disable', u.full_name + ' quedó DESHABILITADO.');
      case 'reactivate':
        if (!ask('¿Reactivar a ' + u.full_name + '?')) return;
        return this.run(() => this.api.action('reactivate', { user_id: id }), u.full_name + ' quedó ACTIVO.');
      case 'reset_password':
        if (!ask('¿Enviar a ' + u.email + ' un link para restablecer la contraseña?\n\nNadie ve la contraseña: la persona elige una nueva desde el link.')) return;
        return this.run(() => this.api.action('reset_password', { user_id: id }), 'Link enviado.');
      case 'revoke_sessions':
        if (!ask('¿Cerrar todas las sesiones abiertas de ' + u.full_name + '?\n\nVa a tener que volver a iniciar sesión en todos sus dispositivos.')) return;
        return this.run(() => this.api.action('revoke_sessions', { user_id: id }), 'Sesiones cerradas.');
      case 'resend_invite':
        return this.run(() => this.api.action('resend_invite', { user_id: id }), 'Invitación reenviada.');
      case 'cancel_invite':
        if (!ask('¿Cancelar la invitación de ' + u.email + '? El link deja de servir y el usuario queda DESHABILITADO.')) return;
        return this.run(() => this.api.action('cancel_invite', { user_id: id }), 'Invitación cancelada.');
      case 'remove': {
        const hist = this.api.hasHistory ? await this.api.hasHistory(id) : false;
        if (hist) {
          if (!ask(u.full_name + ' tiene historial operativo (hojas, firmas o eventos).\n\nNo se elimina para no perder la trazabilidad: se ARCHIVA.\nNo podrá ingresar ni aparecerá en asignaciones nuevas.\n\n¿Archivar usuario?')) return;
          return this.withActiveRoutes(u, 'archive', u.full_name + ' quedó ARCHIVADO. Su historial sigue mostrando su nombre.');
        }
        const typed = prompt('ELIMINAR DEFINITIVAMENTE a ' + u.full_name + ' (' + u.email + ').\nNo tiene historial operativo. Esta acción no se puede deshacer.\n\nEscribí ELIMINAR para confirmar:');
        if (typed !== 'ELIMINAR') return;
        return this.run(async () => {
          try { await this.api.action('delete', { user_id: id }); }
          catch (e) {
            if (e.code === 'HAS_HISTORY' && ask(e.message + '\n\n¿Archivar en su lugar?')) { await this.api.action('archive', { user_id: id }); return { message: u.full_name + ' quedó ARCHIVADO.' }; }
            throw e;
          }
        }, u.full_name + ' fue eliminado definitivamente.');
      }
    }
  }
  // Deshabilitar/archivar: si tiene hojas activas, se muestran y se ofrece reasignarlas antes.
  async withActiveRoutes(u, action, okText) {
    try { await this.api.action(action, { user_id: u.id }); this.say(okText); await this.reload(); }
    catch (e) {
      if (e.code !== 'ACTIVE_ROUTES') { this.say(e.message, true); return this.reload(); }
      const routes = e.routes || [];
      const carriers = [...new Set(routes.map(r => r.carrier_id))].map(id => this.carriers.find(c => c.id === id)).filter(Boolean);
      const cands = this.users.filter(x => x.id !== u.id && carriers.every(c => compatibleResponsables([x], c).length));
      const m = this.modal('ESTE USUARIO TIENE HOJAS ACTIVAS',
        '<p style="margin:0">' + esc(u.full_name) + ' tiene hojas sin finalizar. No se puede ' + (action === 'disable' ? 'deshabilitar' : 'archivar') + ' dejándolas asignadas a alguien sin acceso.</p>' +
        '<ul id="arList" style="margin:0;padding-left:18px">' + routes.map(r => '<li><b>Hoja ' + esc(r.number) + '</b> · ' + esc(this.carrierName(r.carrier_id)) + ' · ' + esc(r.operational_status) + '</li>').join('') + '</ul>' +
        (cands.length ? '<label>Reasignar todas a<select id="arTo">' + cands.map(c => '<option value="' + c.id + '">' + esc(c.full_name) + '</option>').join('') + '</select></label>'
          : '<p class="up-msg err" style="margin:0">No hay otro usuario activo compatible. Resolvé las hojas antes (cancelar o finalizar llega con la publicación en la Fase 2).</p>'),
        cands.length ? async mm => {
          const to = mm.querySelector('#arTo').value;
          await this.api.action('reassign_routes', { user_id: u.id, to_user: to });
          await this.api.action(action, { user_id: u.id });
          this.say('Hojas reasignadas a ' + this.users.find(x => x.id === to).full_name + '. ' + okText);
          await this.reload();
        } : null, 'REASIGNAR Y CONTINUAR');
      m.id = 'activeRoutesModal';
    }
  }
  // RC4: permisos individuales como checkboxes (base del rol + otorgados − quitados). El servidor valida y audita cada cambio.
  async openPermissions(u) {
    let eff = []; try { eff = await this.api.userEffectivePermissions(u.id); } catch (e) { this.say(e.message, true); await this.reload(); return; }
    const base = new Set(ROLE_PERMISSIONS[u.role] || []), effSet = new Set(eff), admin = this.me.role === 'ADMIN';
    const sup = this.users.find(x => x.id === u.supervisor_user_id);
    // hojas pendientes de las que es responsable SIN el permiso de asignación (p. ej. se lo quitaron): se muestran para reasignarlas
    // con el flujo existente (no se reasignan solas)
    const isDriver = ['TRANSPORTISTA', 'TRANSPORTISTA_INTERNO'].includes(u.role), pendTxt = async () => {
      if (isDriver || !this.api.pendingAssignedRoutes) return ''; let l = []; try { l = await this.api.pendingAssignedRoutes(u.id); } catch (e) { return ''; }
      return l.length ? l.length + ' hoja(s) pendiente(s) asignada(s) a ' + u.full_name + ': ' + l.map(x => x.number + ' (' + x.operational_status.replace('_', ' ').toLowerCase() + ')').join(', ') +
        '. Reasignalas desde Hojas publicadas → Reasignar (no se reasignan solas).' : ''; };
    const pend0 = effSet.has('routes.receive_internal') ? '' : await pendTxt();
    const body = (pend0 ? '<p class="msg warn" id="permPending">' + esc(pend0) + ' <a href="#/historial">Ir a Hojas publicadas</a></p>' : '') + '<p class="permhead" id="permHead"><b>' + esc(u.full_name) + '</b> · ' + esc(ROLE_LABEL[u.role] || u.role) + ' · Superior: ' + esc(sup ? sup.full_name : '—') + '</p>' +
      '<p style="margin:0 0 8px;font-size:12px;color:var(--muted)">Tildado = permiso efectivo. <i>(rol)</i> = incluido en el rol. Los sensibles solo los otorga Admin General. Nadie modifica sus propios permisos.</p>' +
      PERM_GROUPS.map(([g, ps]) => '<fieldset class="permgrp"><legend>' + esc(g) + '</legend>' + ps.map(p => '<label class="chk permchk"><input type="checkbox" data-perm="' + p + '"' + (effSet.has(p) ? ' checked' : '') +
        (!admin && SENSITIVE_PERMISSIONS.includes(p) && !effSet.has(p) ? ' disabled' : '') + '> ' + esc(PERM_LABEL[p] || p) + (base.has(p) ? ' <i>(rol)</i>' : '') + (SENSITIVE_PERMISSIONS.includes(p) ? ' <small>· sensible</small>' : '') + '</label>').join('') + '</fieldset>').join('') +
      '<label>Motivo (queda en auditoría)<input id="permWhy" placeholder="Ej.: encargado de plantillas"></label>';
    const m = this.modal('PERMISOS DE ' + esc(u.full_name.toUpperCase()), body, async mm => {
      const why = mm.querySelector('#permWhy').value || null, changes = [];
      mm.querySelectorAll('[data-perm]').forEach(i => { const p = i.dataset.perm, on = i.checked; if (on === effSet.has(p)) return;
        changes.push([p, on ? (base.has(p) ? 'ROLE' : 'GRANT') : (base.has(p) ? 'REVOKE' : 'ROLE')]); });
      for (const [p, st] of changes) await this.api.setUserPermission(u.id, p, st, why);
      const revokedAssign = changes.some(([p, st]) => p === 'routes.receive_internal' && st !== 'GRANT'), pend = revokedAssign ? await pendTxt() : '';
      this.say((changes.length ? 'Permisos de ' + u.full_name + ' actualizados (' + changes.length + ' cambio' + (changes.length > 1 ? 's' : '') + ', auditados).' : 'Sin cambios.') + (pend ? ' ATENCIÓN: ' + pend : ''), !!pend);
      await this.reload();
    }, 'GUARDAR PERMISOS');
    m.id = 'permModal';
  }
  modal(title, bodyHtml, onSave, saveLabel) {
    const host = this.sel && this.el.querySelector('#upInline');   // V3: el editor vive en el panel lateral
    const m = document.createElement('div'); m.className = host ? 'umodal up-inpanel' : 'umodal';
    m.innerHTML = '<div class="udialog" role="dialog" aria-modal="true"><header><b>' + esc(title) + '</b></header><div class="body">' + bodyHtml + '<div class="up-msg err" id="umErr" hidden></div></div><footer><button class="btn ghost" type="button" id="umCancel">Cancelar</button>' + (onSave ? '<button class="btn dark" type="button" id="umSave">' + esc(saveLabel || 'GUARDAR') + '</button>' : '') + '</footer></div>';
    if (host) { host.innerHTML = ''; host.appendChild(m); } else this.el.appendChild(m);
    m.querySelector('#umCancel').addEventListener('click', () => { m.remove(); if (host && this.sel) this.renderSide(); });
    const s = m.querySelector('#umSave');
    if (s) s.addEventListener('click', async () => {
      const err = m.querySelector('#umErr'); err.hidden = true; s.disabled = true;
      if (host) this.noAutoEdit = true;   // V3: tras GUARDAR el panel muestra el resumen (EDITAR lo reabre). Se marca ANTES: onSave recarga y redibuja el panel
      try { await onSave(m); m.remove(); } catch (e) { this.noAutoEdit = false; err.textContent = e.message; err.hidden = false; } finally { s.disabled = false; }
    });
    return m;
  }
  carrierChecks(selected, disabled) {
    return '<div class="carr">' + this.carriers.filter(c => c.kind === 'EXTERNO' && c.active).map(c => '<label><input type="checkbox" value="' + c.id + '"' + ((selected || []).includes(c.id) ? ' checked' : '') + (disabled ? ' disabled' : '') + '> ' + esc(c.name) + '</label>').join('') + '</div>';
  }
  // NUEVO USUARIO (u = null) o EDITAR USUARIO: rol + transportista/empresa + superior en el mismo flujo
  openEdit(u) {
    const isNew = !u, self = u && u.id === this.me.id;
    const role = u ? u.role : 'OPERARIO_DEPOSITO';
    const sups = this.users.filter(x => hasPerm(x, 'can_approve_internal_route_changes') && (!u || x.id !== u.id));
    const m = this.modal(isNew ? 'NUEVO USUARIO' : 'EDITAR USUARIO',
      '<label>Nombre y apellido<input id="nuName" value="' + esc(u ? u.full_name : '') + '"></label>' +
      '<label>Email<input id="nuEmail" type="email" value="' + esc(u ? u.email : '') + '"></label>' +
      '<label>Teléfono<input id="nuPhone" value="' + esc(u ? (u.phone || '') : '') + '"></label>' +
      '<label>Rol<select id="nuRole"' + (self ? ' disabled title="No podés cambiar tu propio rol"' : '') + '>' + ASSIGNABLE_ROLES.map(r => '<option value="' + r + '"' + (r === role ? ' selected' : '') + '>' + esc(ROLE_LABEL[r]) + '</option>').join('') + '</select></label>' +
      '<div id="nuCarrWrap"><span style="font-size:12.5px;color:var(--muted)">Transportista / empresa (obligatorio para el rol Transportista)</span>' + this.carrierChecks(u ? u.carriers : [], self) + '</div>' +
      '<div id="nuAccess" class="nu-access"></div>' +
      '<label id="nuSupWrap"><span id="nuSupLbl">Superior que aprueba cambios de ruta interna</span><select id="nuSup"><option value="">— sin superior (avisa a Administración) —</option>' + sups.map(x => '<option value="' + x.id + '"' + (u && u.supervisor_user_id === x.id ? ' selected' : '') + '>' + esc(x.full_name) + '</option>').join('') + '</select></label>' +
      (isNew ? '<label class="chk"><input type="checkbox" id="nuActive" checked> Activo</label><p style="margin:0;font-size:12px;color:var(--muted)">Se envía una invitación al email para que la persona cree su contraseña.</p>'
        : '<p style="margin:0;font-size:12px;color:var(--muted)">Si cambiás el email, se cambia también el email de acceso.</p>'),
      async mm => {
        const r = mm.querySelector('#nuRole').value;
        const carriers = [...mm.querySelectorAll('.carr input:checked')].map(i => i.value);
        const data = { full_name: mm.querySelector('#nuName').value, email: mm.querySelector('#nuEmail').value, phone: mm.querySelector('#nuPhone').value };
        if (isNew) {
          const nu = await this.api.action('create', { ...data, role: r, carriers: r === 'TRANSPORTISTA' ? carriers : [], active: mm.querySelector('#nuActive').checked, disabled_modules: this.disabledFrom(mm, r) });
          const ns = SUP_ROLES[r] ? mm.querySelector('#nuSup').value : ''; if (ns && nu && nu.id) await this.api.setUserSupervisor(nu.id, ns);
          this.say('Usuario creado: ' + nu.full_name + '. ' + (nu.status === 'INVITACION_PENDIENTE' ? 'Se envió la invitación a ' + nu.email + '.' : 'Quedó deshabilitado.'));
        } else {
          const payload = { user_id: u.id, ...data };
          if (!self) { payload.role = r; if (r === 'TRANSPORTISTA') payload.carriers = carriers; }
          // La jerarquía usa la RPC que valida los permisos efectivos del superior en la base.
          // Los perfiles de listUsers no incluyen los overrides individuales de permisos.
          payload.disabled_modules = this.disabledFrom(mm, r);
          await this.api.action('edit', payload);
          if (SUP_ROLES[r] && hasPerm(this.me, 'users.assign_supervisor') && !self) { const ns = mm.querySelector('#nuSup').value || null; if (ns !== (u.supervisor_user_id || null)) await this.api.setUserSupervisor(u.id, ns); }
          this.say('Usuario actualizado: ' + data.full_name + '.');
        }
        await this.reload();
      });
    m.id = 'editModal';
    const roleSel = m.querySelector('#nuRole');
    const supOpts = r => SUP_ROLES[r] ? this.users.filter(x => SUP_ROLES[r].includes(x.role) && x.status === 'ACTIVO' && (!u || x.id !== u.id)) : sups;
    const sync = () => {
      const r = roleSel.value, withSup = r === 'TRANSPORTISTA_INTERNO' || (SUP_ROLES[r] && hasPerm(this.me, 'users.assign_supervisor'));
      m.querySelector('#nuCarrWrap').hidden = r !== 'TRANSPORTISTA'; m.querySelector('#nuSupWrap').hidden = !withSup;
      m.querySelector('#nuSupLbl').textContent = SUP_ROLES[r] ? 'Superior asignado (' + SUP_ROLES[r].map(x => ROLE_LABEL[x]).join(' o ') + ')' : 'Superior que aprueba cambios de ruta interna';
      const sel = m.querySelector('#nuSup'), cur = sel.value || (u && u.supervisor_user_id) || '';
      sel.innerHTML = '<option value="">' + (SUP_ROLES[r] ? '— sin superior (las solicitudes van a Admin General) —' : '— sin superior (avisa a Administración) —') + '</option>' + supOpts(r).map(x => '<option value="' + x.id + '"' + (x.id === cur ? ' selected' : '') + '>' + esc(x.full_name) + ' · ' + esc(ROLE_LABEL[x.role] || x.role) + '</option>').join('');
      this.renderAccess(m, r, u ? u.disabled_modules || [] : []);
    };
    roleSel.addEventListener('change', sync); sync();
  }
  // Acceso por rol (RC1.1): el rol carga los módulos; Administración solo puede RESTRINGIR (nunca agregar)
  renderAccess(m, role, disabled) {
    const box = m.querySelector('#nuAccess'), mods = roleModules(role), driver = role === 'TRANSPORTISTA' || role === 'TRANSPORTISTA_INTERNO';
    const checks = MODULES.map(k => '<label class="chk"><input type="checkbox" data-mod="' + k + '"' + (mods.includes(k) ? (disabled.includes(k) ? '' : ' checked') : ' disabled') + '> ' + esc(MODULE_LABEL[k]) + (mods.includes(k) ? '' : ' <em>(no incluido en el rol)</em>') + '</label>').join('');
    const yes = t => '<li>' + t + ' ✅</li>', no = t => '<li>' + t + ' ❌</li>';
    box.innerHTML = driver
      ? '<b>ACCESO DEL USUARIO</b><ul>' + yes('Ver mis hojas publicadas') + yes(role === 'TRANSPORTISTA_INTERNO' ? 'Ruta interna: agregar / reordenar paradas futuras y finalizar' : 'Ejecutar mi ruta (iniciar, actualizar, finalizar)') + yes('Ver mi historial') +
        no('Ver Despacho general') + no('Ver hojas de otros transportistas') + no('Ver Usuarios') + no('Ver Informes') + no('Ver Configuración') + '</ul>' +
        '<p class="rp-note">Este usuario solo verá las hojas que tenga asignadas y las funciones necesarias para completar su recorrido.</p>' +
        (hasPerm(this.me, 'users.manage') ? '<details id="nuAdv"><summary>PERSONALIZAR PERMISOS AVANZADOS</summary><div class="nu-mods">' + checks + '</div></details>' : '')
      : '<b>MÓDULOS HABILITADOS</b><div class="nu-mods">' + checks + '</div><p class="rp-note">El rol define los módulos; podés restringirlos para este usuario.</p>';
  }
  disabledFrom(m, role) { return roleModules(role).filter(k => { const c = m.querySelector('[data-mod="' + k + '"]'); return c && !c.checked; }); }
}
