// Admin → USUARIOS. Misma estética que la versión offline (cabecera oscura, tabla negra con línea cyan).
import { esc, fmtDate, fmtDay } from './util.js';
import { ROLES, ROLE_LABEL, hasPerm, compatibleResponsables, MODULES, MODULE_LABEL, roleModules } from '../../supabase/functions/_shared/rules.js';
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
    this.el.innerHTML = '<header class="top"><img src="/logo.png" alt="OK Accesorios"><div class="ttl"><b>DESPACHO</b><span>Administración</span></div><div class="sp"></div>' +
      '<button class="who-chip linkchip" type="button" id="upMe">' + esc(this.me.full_name) + ' · <b>' + esc(ROLE_LABEL[this.me.role] || this.me.role) + '</b></button>' +
      '<button class="tbtn" type="button" id="upClose">Volver al panel</button></header><div class="up-wrap" id="upWrap"></div>';
    this.el.querySelector('#upClose').addEventListener('click', () => this.close());
    this.el.querySelector('#upMe').addEventListener('click', () => openAccount(this.api, this.me, this.onLogout || (() => {})));
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
  filtered() {
    const q = this.f.q.trim().toLowerCase();
    return this.users.filter(u =>
      (!q || u.full_name.toLowerCase().includes(q) || u.email.toLowerCase().includes(q)) &&
      (!this.f.role || u.role === this.f.role) &&
      (!this.f.status || u.status === this.f.status) &&
      (!this.f.carrier || (this.f.carrier === 'INTERNO' ? u.role === 'TRANSPORTISTA_INTERNO' : (u.carriers || []).includes(this.f.carrier)))
    ).sort((a, b) => (a.status === 'ARCHIVADO') - (b.status === 'ARCHIVADO') || a.full_name.localeCompare(b.full_name, 'es'));
  }
  render() {
    const canManage = hasPerm(this.me, 'users.manage');
    const w = this.el.querySelector('#upWrap');
    const opt = (v, l, sel) => '<option value="' + esc(v) + '"' + (v === sel ? ' selected' : '') + '>' + esc(l) + '</option>';
    w.innerHTML =
      '<div class="up-head"><h2>USUARIOS</h2><span class="sp"></span>' + (canManage ? '<button class="btn go" id="upNew" type="button">NUEVO USUARIO</button>' : '') + '</div>' +
      (this.msg ? '<div class="up-msg ' + (this.msg.err ? 'err' : 'ok') + '" id="upMsg">' + esc(this.msg.text) + '</div>' : '') +
      '<div class="ufilters">' +
        '<input id="ufSearch" placeholder="Buscar por nombre o email" value="' + esc(this.f.q) + '">' +
        '<select id="ufRole">' + opt('', 'Todos los roles', this.f.role) + ROLES.map(r => opt(r, ROLE_LABEL[r], this.f.role)).join('') + '</select>' +
        '<select id="ufStatus">' + opt('', 'Todos los estados', this.f.status) + Object.keys(STATUS_LABEL).map(s => opt(s, STATUS_LABEL[s], this.f.status)).join('') + '</select>' +
        '<select id="ufCarrier">' + opt('', 'Todos los transportistas', this.f.carrier) + this.carriers.map(c => opt(c.id, c.name, this.f.carrier)).join('') + '</select>' +
        '<span class="ufcount" id="ufCount"></span>' +
      '</div>' +
      '<div class="utable-wrap"><table class="utable"><thead><tr><th>NOMBRE</th><th>EMAIL</th><th>TELÉFONO</th><th>ROL</th><th>TRANSPORTISTA / EMPRESA</th><th>ESTADO</th><th>ÚLTIMO ACCESO</th><th>CREADO</th>' + (canManage ? '<th>ACCIONES</th>' : '') + '</tr></thead><tbody id="upBody"></tbody></table></div>';
    this.renderRows();
    const n = w.querySelector('#upNew'); if (n) n.addEventListener('click', () => this.openEdit(null));
    w.querySelector('#ufSearch').addEventListener('input', e => { this.f.q = e.target.value; this.renderRows(); });
    [['#ufRole', 'role'], ['#ufStatus', 'status'], ['#ufCarrier', 'carrier']].forEach(([s, k]) => w.querySelector(s).addEventListener('change', e => { this.f[k] = e.target.value; this.renderRows(); }));
  }
  renderRows() {
    const canManage = hasPerm(this.me, 'users.manage');
    const rows = this.filtered();
    this.el.querySelector('#ufCount').textContent = rows.length + ' de ' + this.users.length;
    const b = (act, id, label, cls) => '<button class="btn ' + (cls || 'soft') + '" type="button" data-act="' + act + '" data-id="' + id + '">' + label + '</button>';
    this.el.querySelector('#upBody').innerHTML = rows.map(u => {
      const self = u.id === this.me.id;
      const carr = u.role === 'TRANSPORTISTA_INTERNO' ? 'TRANSPORTE INTERNO' : (u.carriers || []).map(c => this.carrierName(c)).join(', ') || '—';
      let act = '';
      if (canManage) {
        act = '<div class="uact">' + (u.status !== 'ARCHIVADO' ? b('edit', u.id, 'EDITAR', 'dark') : '');
        if (u.status === 'INVITACION_PENDIENTE') act += b('resend_invite', u.id, 'REENVIAR INVITACIÓN') + b('cancel_invite', u.id, 'CANCELAR INVITACIÓN');
        if (u.status === 'ACTIVO') act += b('reset_password', u.id, 'RESTABLECER CONTRASEÑA') + b('revoke_sessions', u.id, 'CERRAR SESIONES ABIERTAS') + (self ? '' : b('disable', u.id, 'DESHABILITAR'));
        if (u.status === 'DESHABILITADO' || u.status === 'ARCHIVADO') act += b('reactivate', u.id, 'REACTIVAR');
        if (!self && u.status !== 'ARCHIVADO') act += b('remove', u.id, 'ELIMINAR / ARCHIVAR', 'danger');
        act += '</div>';
      }
      return '<tr class="' + (u.status === 'ARCHIVADO' ? 'dim' : '') + '" data-uid="' + u.id + '"><td><b>' + esc(u.full_name) + '</b>' + (self ? ' <span style="color:var(--muted);font-size:11.5px">(vos)</span>' : '') + '</td><td>' + esc(u.email) + '</td><td>' + esc(u.phone || '—') + '</td><td>' + esc(ROLE_LABEL[u.role] || u.role) + '</td><td>' + esc(carr) + '</td>' +
        '<td><span class="ust ' + u.status + '">' + esc(STATUS_LABEL[u.status] || u.status) + '</span></td><td>' + esc(fmtDate(u.last_sign_in_at)) + '</td><td>' + esc(fmtDay(u.created_at)) + '</td>' + (canManage ? '<td>' + act + '</td>' : '') + '</tr>';
    }).join('') || '<tr><td colspan="9" style="text-align:center;color:var(--muted);padding:24px">No hay usuarios con esos filtros.</td></tr>';
    this.el.querySelectorAll('#upBody [data-act]').forEach(btn => btn.addEventListener('click', () => this.doAction(btn.dataset.act, btn.dataset.id)));
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
  modal(title, bodyHtml, onSave, saveLabel) {
    const m = document.createElement('div'); m.className = 'umodal';
    m.innerHTML = '<div class="udialog" role="dialog" aria-modal="true"><header><b>' + esc(title) + '</b></header><div class="body">' + bodyHtml + '<div class="up-msg err" id="umErr" hidden></div></div><footer><button class="btn ghost" type="button" id="umCancel">Cancelar</button>' + (onSave ? '<button class="btn dark" type="button" id="umSave">' + esc(saveLabel || 'GUARDAR') + '</button>' : '') + '</footer></div>';
    this.el.appendChild(m);
    m.querySelector('#umCancel').addEventListener('click', () => m.remove());
    const s = m.querySelector('#umSave');
    if (s) s.addEventListener('click', async () => {
      const err = m.querySelector('#umErr'); err.hidden = true; s.disabled = true;
      try { await onSave(m); m.remove(); } catch (e) { err.textContent = e.message; err.hidden = false; } finally { s.disabled = false; }
    });
    return m;
  }
  carrierChecks(selected, disabled) {
    return '<div class="carr">' + this.carriers.filter(c => c.kind === 'EXTERNO' && c.active).map(c => '<label><input type="checkbox" value="' + c.id + '"' + ((selected || []).includes(c.id) ? ' checked' : '') + (disabled ? ' disabled' : '') + '> ' + esc(c.name) + '</label>').join('') + '</div>';
  }
  // NUEVO USUARIO (u = null) o EDITAR USUARIO: rol + transportista/empresa + superior en el mismo flujo
  openEdit(u) {
    const isNew = !u, self = u && u.id === this.me.id;
    const role = u ? u.role : 'DESPACHO';
    const sups = this.users.filter(x => hasPerm(x, 'can_approve_internal_route_changes') && (!u || x.id !== u.id));
    const m = this.modal(isNew ? 'NUEVO USUARIO' : 'EDITAR USUARIO',
      '<label>Nombre y apellido<input id="nuName" value="' + esc(u ? u.full_name : '') + '"></label>' +
      '<label>Email<input id="nuEmail" type="email" value="' + esc(u ? u.email : '') + '"></label>' +
      '<label>Teléfono<input id="nuPhone" value="' + esc(u ? (u.phone || '') : '') + '"></label>' +
      '<label>Rol<select id="nuRole"' + (self ? ' disabled title="No podés cambiar tu propio rol"' : '') + '>' + ROLES.map(r => '<option value="' + r + '"' + (r === role ? ' selected' : '') + '>' + esc(ROLE_LABEL[r]) + '</option>').join('') + '</select></label>' +
      '<div id="nuCarrWrap"><span style="font-size:12.5px;color:var(--muted)">Transportista / empresa (obligatorio para el rol Transportista)</span>' + this.carrierChecks(u ? u.carriers : [], self) + '</div>' +
      '<div id="nuAccess" class="nu-access"></div>' +
      '<label id="nuSupWrap">Superior que aprueba cambios de ruta interna<select id="nuSup"><option value="">— sin superior (avisa a Administración) —</option>' + sups.map(x => '<option value="' + x.id + '"' + (u && u.supervisor_user_id === x.id ? ' selected' : '') + '>' + esc(x.full_name) + '</option>').join('') + '</select></label>' +
      (isNew ? '<label class="chk"><input type="checkbox" id="nuActive" checked> Activo</label><p style="margin:0;font-size:12px;color:var(--muted)">Se envía una invitación al email para que la persona cree su contraseña.</p>'
        : '<p style="margin:0;font-size:12px;color:var(--muted)">Si cambiás el email, se cambia también el email de acceso.</p>'),
      async mm => {
        const r = mm.querySelector('#nuRole').value;
        const carriers = [...mm.querySelectorAll('.carr input:checked')].map(i => i.value);
        const data = { full_name: mm.querySelector('#nuName').value, email: mm.querySelector('#nuEmail').value, phone: mm.querySelector('#nuPhone').value };
        if (isNew) {
          const nu = await this.api.action('create', { ...data, role: r, carriers: r === 'TRANSPORTISTA' ? carriers : [], active: mm.querySelector('#nuActive').checked, disabled_modules: this.disabledFrom(mm, r) });
          this.say('Usuario creado: ' + nu.full_name + '. ' + (nu.status === 'INVITACION_PENDIENTE' ? 'Se envió la invitación a ' + nu.email + '.' : 'Quedó deshabilitado.'));
        } else {
          const payload = { user_id: u.id, ...data };
          if (!self) { payload.role = r; if (r === 'TRANSPORTISTA') payload.carriers = carriers; }
          if (r === 'TRANSPORTISTA_INTERNO') payload.supervisor_user_id = mm.querySelector('#nuSup').value || null;
          payload.disabled_modules = this.disabledFrom(mm, r);
          await this.api.action('edit', payload);
          this.say('Usuario actualizado: ' + data.full_name + '.');
        }
        await this.reload();
      });
    m.id = 'editModal';
    const roleSel = m.querySelector('#nuRole');
    const sync = () => { m.querySelector('#nuCarrWrap').hidden = roleSel.value !== 'TRANSPORTISTA'; m.querySelector('#nuSupWrap').hidden = roleSel.value !== 'TRANSPORTISTA_INTERNO'; /* Superior: SOLO Transportista Interno */ this.renderAccess(m, roleSel.value, u ? u.disabled_modules || [] : []); };
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
