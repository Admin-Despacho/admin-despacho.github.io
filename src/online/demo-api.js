// MODO DEMO: sin servidor. Mismo contrato que SupabaseApi y MISMAS reglas (rules.js).
// Sirve para aceptación visual y pruebas automáticas cuando no hay proyecto Supabase configurado.
import { validateUserAction, compatibleResponsables, hasPerm, canBeResponsable, userModules, canOperateAssigned } from '../../supabase/functions/_shared/rules.js';
import { reorderError, applyReorder, currentStop, approvalRecipients, sendQueuedEmails, routeDiff } from '../../supabase/functions/_shared/internal-route.js';
import { sendCustomerEmails } from '../../supabase/functions/_shared/customer-email.js';
import { DemoAdmin } from './demo-admin.js';
import { DemoRC4 } from './demo-rc4.js';


const KEY = 'okd_online_demo_v2';
// CONTRATO DE SERVIDOR que emula la demo (explícito):
//  · 'V4.16-PROPUESTA' (por defecto; contenido V4.17): propuestas/v4_17/20261108000100_v4_17_set_stop_outcome.sql — cobranza OPCIONAL
//    y, en TODA entrega comercial (externo e interno), CUIL + email + identidad con DNI registrado (vinculada). NO está aplicada en producción.
//  · 'VIGENTE': definición más reciente del repo (cristian_email_dni_required): exige cobranza en COBRANZA/AMBAS; CUIL, DNI y email solo para Cristian.
// Se elige con localStorage 'okd_demo_contract'. Lo que funcione solo con la propuesta NO funciona en producción hasta aplicarla.
export const demoContract = () => { try { return localStorage.getItem('okd_demo_contract') === 'VIGENTE' ? 'VIGENTE' : 'V4.16-PROPUESTA'; } catch (e) { return 'V4.16-PROPUESTA'; } };
export const DEMO_CARRIERS = [
  { id: 'INTERNO', name: 'TRANSPORTE INTERNO', kind: 'INTERNO', active: true },
  { id: 'CT-ESTE', name: 'CRISTIAN TORRES - ESTE', kind: 'EXTERNO', report_group: 'CRISTIAN_TORRES', active: true },   // report_group: igual que la migración fase2a
  { id: 'CT-ALR', name: 'CRISTIAN TORRES - ALREDEDORES', kind: 'EXTERNO', report_group: 'CRISTIAN_TORRES', active: true },
  { id: 'UCO', name: 'UCO', kind: 'EXTERNO', active: true },
  { id: 'VASCA', name: 'VASCA', kind: 'EXTERNO', active: true },
  { id: 'ANDESMAR', name: 'ANDESMAR', kind: 'EXTERNO', active: true },
  { id: 'MARCHETTI', name: 'MARCHETTI', kind: 'EXTERNO', active: true }
];
const day = d => new Date(Date.UTC(2026, 9, d, 12)).toISOString();
const SEQ_CODE = { 'CT-ESTE': '01', 'CT-ALR': '01', UCO: '02', INTERNO: '03', VASCA: '04', ANDESMAR: '05', MARCHETTI: '06' };
const u = (id, full_name, email, role, status, carriers, created, phone = '') => ({ id, full_name, email, phone, role, status, carriers, created_at: day(created), last_sign_in_at: null, supervisor_user_id: null, sessions_revoked_at: null });
export function demoSeed() {
  return {
    users: [
      u('u-admin', 'Admin OK', 'admin@okdespacho.demo', 'ADMIN', 'ACTIVO', [], 1),
      u('u-deposito', 'Depósito', 'despacho@okdespacho.demo', 'DESPACHO', 'ACTIVO', [], 1),
      u('u-gabriel', 'Gabriel Figueroa', 'gabriel@okdespacho.demo', 'TRANSPORTISTA_INTERNO', 'ACTIVO', [], 2, '261 555-0101'),
      u('u-gabriel2', 'Martín Sosa', 'martin@okdespacho.demo', 'TRANSPORTISTA_INTERNO', 'ACTIVO', [], 2),
      u('u-lucas', 'Lucas Méndez', 'lucas@okdespacho.demo', 'TRANSPORTISTA_INTERNO', 'DESHABILITADO', [], 2),
      u('u-cristian', 'Cristian Torres', 'cristian@okdespacho.demo', 'TRANSPORTISTA', 'ACTIVO', ['CT-ESTE', 'CT-ALR'], 2, '261 555-0202'),
      u('u-diego', 'Diego Ríos', 'diego@okdespacho.demo', 'TRANSPORTISTA', 'ACTIVO', ['CT-ALR'], 3),
      u('u-invitada', 'Paula Invitada', 'paula@okdespacho.demo', 'DESPACHO', 'INVITACION_PENDIENTE', [], 7)
    ],
    // Hojas de prueba (la publicación real llega en Fase 2)
    routes: [
      { id: 'r-0302', number: '03-02', carrier_id: 'INTERNO', responsable_id: 'u-gabriel', operational_status: 'PUBLICADA' },
      { id: 'r-cte1', number: 'CTE-01', carrier_id: 'CT-ESTE', responsable_id: 'u-cristian', operational_status: 'COMPLETADA' }
    ],
    passwords: {},            // contraseñas cambiadas en la demo (por defecto: "demo")
    history: ['u-gabriel', 'u-cristian'], // usuarios con hojas/firmas/eventos (no se eliminan, se archivan)
    // G2 (ubicaciones internas de Mendoza). "San Juan" es la calle San Juan de Mendoza.
    internalLocations: [
      { location_key: 'MONTECASEROS', name: 'Montecaseros - casa central', address: 'Montecaseros 1234, Mendoza', lat: -32.8900, lon: -68.8400, radius_m: 200, active: true, note: null, updated_at: '2026-10-01T12:00:00.000Z' },
      { location_key: 'SAN_JUAN', name: 'Sucursal San Juan', address: 'San Juan 500, Mendoza', lat: -32.8950, lon: -68.8450, radius_m: 150, active: true, note: null, updated_at: '2026-10-01T12:00:00.000Z' }],
    vehicles: [{ id: 'vh-1', name: 'Kangoo', plate: 'AB123CD', active: true, brand: 'Renault', model: 'Kangoo', type: 'Utilitario', year: 2019, notes: '', current_km: 50000, last_service_km: 41000, last_service_date: '2026-03-01', service_interval_km: 10000, habitual_driver_id: 'u-gabriel' }],
    audit: [], mails: [], seq: 1
  };
}
const err = (message, code, status, extra) => Object.assign(new Error(message), { code, status }, extra || {});

export class DemoApi {
  constructor(storage) {
    this.mode = 'demo';
    this.storage = storage === undefined ? (typeof localStorage !== 'undefined' ? localStorage : null) : storage;
    this.db = this._load();
    this.session = this._get('session');
  }
  _load() { try { const v = this.storage && this.storage.getItem(KEY); if (v) return JSON.parse(v); } catch (e) { } return demoSeed(); }
  _save() { try { this.storage && this.storage.setItem(KEY, JSON.stringify(this.db)); } catch (e) { } }
  _st(k) { return (k === 'session' || k === 'revoked_notice') && typeof sessionStorage !== 'undefined' && typeof localStorage !== 'undefined' && this.storage === localStorage ? sessionStorage : this.storage; }
  _get(k) { try { const st = this._st(k); return st ? JSON.parse(st.getItem(KEY + ':' + k) || 'null') : null; } catch (e) { return null; } }
  _set(k, v) { try { const st = this._st(k); st && (v == null ? st.removeItem(KEY + ':' + k) : st.setItem(KEY + ':' + k, JSON.stringify(v))); } catch (e) { } }
  _user(id) { return this.db.users.find(x => x.id === id); }
  _activeRoutes(id) { return this.db.routes.filter(r => r.responsable_id === id && ['BORRADOR', 'PUBLICADA', 'EN_CURSO'].includes(r.operational_status)); }
  _audit(actor, action, target, before, after) { this.db.audit.push({ at: new Date().toISOString(), actor_id: actor ? actor.id : null, action, target_id: target || null, before: before || null, after: after || null }); }
  reset() { this.db = demoSeed(); this._save(); this.signOut(); }

  // Sesión: si Administración cerró las sesiones del usuario, la sesión vieja deja de valer.
  async getSession() {
    const s = this.session, u = s && this._user(s.userId);
    // como Supabase: la sesión de un invitado pendiente es válida (sin permisos: hasPerm exige ACTIVO); el ruteo activa la invitación
    if (!u || !['ACTIVO', 'INVITACION_PENDIENTE'].includes(u.status)) return null;
    if ((u.session_epoch || 0) !== (s.epoch || 0)) { this.revokedNotice = true; this._set('revoked_notice', true); await this.signOut(); return null; } // sesiones cerradas por Administración
    return { userId: u.id };
  }
  async signIn(email, password) {
    const u = this.db.users.find(x => x.email.toLowerCase() === String(email).trim().toLowerCase());
    if (!u || password !== (this.db.passwords[u.id] || 'demo')) throw new Error('Email o contraseña incorrectos.');
    if (u.status === 'DESHABILITADO' || u.status === 'ARCHIVADO') throw new Error('Usuario sin acceso. Consultá con Administración.');
    // Como el servidor real: iniciar sesión NO activa la invitación; la activa el ruteo (acceptInvite) al detectar el ingreso
    u.last_sign_in_at = new Date().toISOString(); this._save(); // último acceso real
    this.session = { userId: u.id, epoch: u.session_epoch || 0 }; this._set('session', this.session);
    return { userId: u.id };
  }
  async signOut() { this.session = null; this._set('session', null); }
  // Invitación (mismo comportamiento que Supabase + Edge Function accept_invite): idempotente, nunca activa a un deshabilitado
  async acceptInvite() {
    this._refresh(); const me = await this.me(); if (!me || me.status !== 'INVITACION_PENDIENTE') return me;
    // SOLO PRUEBAS (modo demo): simula que la Edge Function accept_invite falla, para verificar el mensaje y "Reintentar activación"
    if (this.db.demoFailAcceptInvite) throw err('Tu contraseña se guardó, pero no se pudo activar tu usuario (simulación de falla). Tocá "Reintentar activación" o avisá a Administración.', 'ACCEPT_FAILED', 500);
    const u = this._user(me.id); u.status = 'ACTIVO'; this._audit(u, 'INVITE_ACCEPTED', u.id, { status: 'INVITACION_PENDIENTE' }, { status: 'ACTIVO' }); this._save();
    return { ...u, carriers: [...u.carriers] };
  }
  async setPassword(password) {
    this._refresh(); const me = await this.me(); if (!me) throw err('Sesión inválida.', 'NO_SESSION', 401);
    if (String(password || '').length < 8) throw err('No se pudo guardar la contraseña: Password should be at least 8 characters.', 'PASSWORD_FAILED', 400);
    // Supabase devuelve same_password si es la misma: ya está guardada → se continúa con la activación (no se deja al invitado atrapado)
    this.db.passwords[me.id] = password; this._save();
    await this.acceptInvite();
  }
  takeRevokedNotice() { const v = this.revokedNotice || !!this._get('revoked_notice'); this.revokedNotice = false; this._set('revoked_notice', null); return v; }
  // igual que el servidor: devuelve el usuario ACTUAL (relee el estado; p. ej. un permiso quitado por un administrador)
  async me() { const s = await this.getSession(); if (!s) return null; this._refresh(); const u = this._user(s.userId); return u ? { ...u, carriers: [...u.carriers] } : null; }
  // Autogestión: el usuario cambia SU contraseña (no rol, ni permisos, ni carriers)
  // ===== Contraseñas por enlace (demo de lo que hace Supabase Auth): invitación y recuperación =====
  _authMail(u, type) {
    this.db.authTokens = this.db.authTokens || {}; this.db.authMails = this.db.authMails || [];
    const token = crypto.randomUUID(); this.db.authTokens[token] = { user_id: u.id, type, exp: Date.now() + 3600000, used: false };
    this.db.authMails.push({ to: u.email, type, link: '#/nueva-contrasena?token=' + token, at: new Date().toISOString() });
    this.db.mails.push({ to: u.email, type });
  }
  // Respuesta SIEMPRE genérica: no revela si el email existe
  async requestPasswordReset(email) {
    this._refresh(); const u = this.db.users.find(x => x.email === String(email || '').trim().toLowerCase());
    if (u && ['ACTIVO', 'INVITACION_PENDIENTE'].includes(u.status)) { this._authMail(u, 'RECUPERACION'); this._audit(u, 'PASSWORD_RESET_REQUESTED', u.id, null, { by: 'self' }); this._save(); }
    return { ok: true };
  }
  async completePasswordReset(password, token) {
    this._refresh(); const t = (this.db.authTokens || {})[token];
    if (!t || t.used || t.exp < Date.now()) throw err('El enlace venció o ya se usó. Pedí uno nuevo.', 'BAD_TOKEN', 400);
    if (String(password || '').length < 8) throw err('La contraseña debe tener al menos 8 caracteres.', 'WEAK', 400);
    const u = this._user(t.user_id); if (!u || ['DESHABILITADO', 'ARCHIVADO'].includes(u.status)) throw err('Usuario sin acceso. Consultá con Administración.', 'NO_ACCESS', 403);
    this.db.passwords[u.id] = password; t.used = true;
    // como el servidor: se intenta aceptar la invitación y se devuelve el estado REAL (no se presenta como activada si falló)
    const pendingInvite = u.status === 'INVITACION_PENDIENTE'; let activated = false, activationError = null;
    if (pendingInvite) { if (this.db.demoFailAcceptInvite) activationError = 'Tu contraseña se guardó, pero no se pudo activar tu usuario (simulación de falla). Tocá "Reintentar activación" o avisá a Administración.';
      else { u.status = 'ACTIVO'; activated = true; this._audit(u, 'INVITE_ACCEPTED', u.id); } }
    u.session_epoch = (u.session_epoch || 0) + 1; u.sessions_revoked_at = new Date().toISOString(); // cierra sesiones anteriores
    this._audit(u, 'OWN_PASSWORD_CHANGED', u.id); this._save(); await this.signOut();
    return { ok: true, passwordSaved: true, pendingInvite, activated, activationError };
  }
  // ===== PDF de la hoja publicada (RC1.2) =====
  _dispatch() { return this.db.dispatch = this.db.dispatch || { pdf_auto_generate: true, pdf_auto_download: true }; }
  async dispatchSettings() { this._refresh(); const me = await this.me(); if (!(hasPerm(me, 'routes.create') || hasPerm(me, 'settings.manage'))) throw err('Sin permiso.', 'FORBIDDEN', 403); return { ...this._dispatch() }; }
  async setDispatchSettings(gen, dl) { this._refresh(); const me = await this.me(); if (!hasPerm(me, 'settings.manage')) throw err('Sin permiso.', 'FORBIDDEN', 403); Object.assign(this._dispatch(), { pdf_auto_generate: !!gen, pdf_auto_download: !!dl }); this._audit(me, 'DISPATCH_PDF_SETTINGS', null, null, this._dispatch()); this._save(); }
  async saveRoutePdf(routeId, version, number, bytes) {
    this._net(); this._refresh(); const me = await this.me(); if (!hasPerm(me, 'routes.publish')) throw err('Sin permiso.', 'FORBIDDEN', 403);
    if (typeof window !== 'undefined' && window.OKD_PDF_FAIL) throw new Error('No se pudo guardar el PDF (Storage no disponible)');
    const name = 'Hoja_' + number + '_v' + version + '.pdf', path = routeId + '/v' + version + '/' + name;
    this.db.pdfStore = this.db.pdfStore || {}; this.db.routePdfs = this.db.routePdfs || {};
    const key = routeId + '|' + version, cur = this.db.routePdfs[key];
    if (cur && cur.status === 'OK') { cur.attempts++; this._save(); return cur; } // un PDF lógico por hoja+versión; no se sobrescribe
    if (!this.db.pdfStore[path]) { let t = ''; const u = new Uint8Array(bytes); for (let i = 0; i < u.length; i += 0x8000) t += String.fromCharCode(...u.subarray(i, i + 0x8000)); this.db.pdfStore[path] = btoa(t); }
    this.db.routePdfs[key] = { route_id: routeId, route_version: version, route_number: number, file_name: name, storage_path: path, status: 'OK', error: null, attempts: (cur ? cur.attempts : 0) + 1, generated_at: new Date().toISOString(), generated_by: me.id };
    this._save(); return this.db.routePdfs[key];
  }
  async routePdfError(routeId, version, msg) {
    this._refresh(); this.db.routePdfs = this.db.routePdfs || {}; const key = routeId + '|' + version, cur = this.db.routePdfs[key];
    if (cur && cur.status === 'OK') return cur;
    this.db.routePdfs[key] = { ...(cur || { route_id: routeId, route_version: version, attempts: 0 }), status: 'PDF_ERROR', error: msg, attempts: (cur ? cur.attempts : 0) + 1 }; this._save(); return this.db.routePdfs[key];
  }
  async routePdfSnapshot(routeId) { this._refresh(); const me = await this.me(); { const rr = (this.db.routes2 || []).find(x => x.id === routeId); if (rr) this._routeScope(me, rr); } if (!hasPerm(me, 'routes.publish')) throw err('Sin permiso.', 'FORBIDDEN', 403); const r = this.db.routes2.find(x => x.id === routeId); return { number: r.number, version: r.version || 1, pdf_model: r.sheet_snapshot.pdf_model }; }
  async downloadRoutePdf(routeId, version) {
    this._refresh(); const me = await this.me(); const r = this.db.routes2.find(x => x.id === routeId);
    if (!(hasPerm(me, 'routes.view_all') || (r && r.responsable_id === me.id))) throw err('ACCESO NO AUTORIZADO', 'FORBIDDEN', 403);
    const p = (this.db.routePdfs || {})[routeId + '|' + version]; if (!p || p.status !== 'OK') throw err('El PDF todavía no está generado.', 'NO_PDF', 404);
    return new Blob([Uint8Array.from(atob(this.db.pdfStore[p.storage_path]), c => c.charCodeAt(0))], { type: 'application/pdf' });
  }
  async myModules() { const me = await this.me(); return userModules(me); }
  async viewerRoutes() {
    this._net(); this._refresh(); const me = await this.me();
    if (!hasPerm(me, 'routes.view_all')) throw err('ACCESO NO AUTORIZADO', 'FORBIDDEN', 403);
    return (this.db.routes2 || []).map(r => JSON.parse(JSON.stringify(r))).sort((a, b) => b.published_at.localeCompare(a.published_at));
  }
  async changeOwnPassword(password) {
    const me = await this.me(); if (!me) throw err('Sesión inválida.', 'NO_AUTH', 401);
    if (String(password || '').length < 8) throw err('La contraseña debe tener al menos 8 caracteres.', 'WEAK', 400);
    this.db.passwords[me.id] = password; this._audit(me, 'OWN_PASSWORD_CHANGED', me.id); this._save();
  }
  async listCarriers() { this._refresh(); return this._carriers().map(c => ({ ...c })); }

  async listUsers() {
    const me = await this.me();
    if (!hasPerm(me, 'users.view')) throw err('No tenés permiso para ver usuarios.', 'FORBIDDEN', 403);
    return this.db.users.map(u => ({ ...u, carriers: [...u.carriers], active_routes: this._activeRoutes(u.id).length }));
  }
  async activeRoutes(id) { return this._activeRoutes(id).map(r => ({ ...r })); }

  async action(action, payload = {}) {
    const actor = await this.me();
    const target = payload.user_id ? this._user(payload.user_id) : null;
    const hasHistory = !!(target && this._hasHistory(target.id));
    const routes = target && ['disable', 'archive', 'delete'].includes(action) ? this._activeRoutes(target.id) : [];
    const e = validateUserAction(action, { actor, target, allUsers: this.db.users, hasHistory, activeRoutes: routes.length, payload });
    if (e) throw err(e.message, e.code, e.status, e.code === 'ACTIVE_ROUTES' ? { routes } : null);
    const before = target ? { full_name: target.full_name, email: target.email, phone: target.phone, role: target.role, status: target.status, carriers: [...target.carriers], supervisor_user_id: target.supervisor_user_id } : null;
    const revoke = t => { t.sessions_revoked_at = new Date().toISOString(); t.session_epoch = (t.session_epoch || 0) + 1; };
    switch (action) {
      case 'create': {
        const nu = u('u-' + (++this.db.seq) + '-' + Date.now().toString(36), String(payload.full_name).trim(), String(payload.email).trim().toLowerCase(),
          payload.role, payload.active === false ? 'DESHABILITADO' : 'INVITACION_PENDIENTE', payload.role === 'TRANSPORTISTA_INTERNO' ? [] : [...(payload.carriers || [])], 1, payload.phone || '');
        nu.created_at = new Date().toISOString();
        nu.disabled_modules = [...(payload.disabled_modules || [])];
        this.db.users.push(nu); this._authMail(nu, 'INVITACION'); this._audit(actor, 'USER_CREATED', nu.id, null, { role: nu.role, disabled_modules: nu.disabled_modules });
        this._save(); return { ...nu };
      }
      case 'edit':
      case 'set_role': {
        const role = payload.role || target.role;
        if (action === 'edit') {
          if (payload.full_name !== undefined) target.full_name = String(payload.full_name).trim();
          if (payload.phone !== undefined) target.phone = payload.phone || '';
          if (payload.email !== undefined) target.email = String(payload.email).trim().toLowerCase(); // Auth y perfil a la vez
          if (payload.supervisor_user_id !== undefined) target.supervisor_user_id = payload.supervisor_user_id;
          if (payload.disabled_modules !== undefined) target.disabled_modules = [...payload.disabled_modules];
        }
        target.role = role;
        if (role === 'TRANSPORTISTA_INTERNO') target.carriers = [];
        else if (payload.carriers !== undefined) target.carriers = [...payload.carriers];
        if (role !== 'TRANSPORTISTA_INTERNO') target.supervisor_user_id = null;
        this._audit(actor, action === 'edit' ? 'USER_UPDATED' : 'USER_ROLE_CHANGED', target.id, before, { full_name: target.full_name, email: target.email, phone: target.phone, role: target.role, carriers: [...target.carriers], supervisor_user_id: target.supervisor_user_id });
        break;
      }
      case 'set_carriers': target.carriers = [...(payload.carriers || [])]; this._audit(actor, 'USER_CARRIERS_CHANGED', target.id, before, { carriers: target.carriers }); break;
      case 'disable': target.status = 'DESHABILITADO'; revoke(target); this._audit(actor, 'USER_DISABLED', target.id, before, { status: 'DESHABILITADO', sessions_revoked: true }); break;
      case 'archive': target.status = 'ARCHIVADO'; target.archived_at = new Date().toISOString(); revoke(target); this._audit(actor, 'USER_ARCHIVED', target.id, before, { status: 'ARCHIVADO', sessions_revoked: true }); break;
      case 'cancel_invite': target.status = 'DESHABILITADO'; revoke(target); this._audit(actor, 'INVITE_CANCELLED', target.id, before, { status: 'DESHABILITADO' }); break;
      case 'reactivate': target.status = 'ACTIVO'; target.archived_at = null; this._audit(actor, 'USER_REACTIVATED', target.id, before, { status: 'ACTIVO' }); break;
      case 'reset_password':
        this._authMail(target, 'RECUPERACION'); this._audit(actor, 'PASSWORD_RESET_REQUESTED', target.id, null, { result: 'ENVIADO', email: target.email }); this._save();
        return { ok: true, message: 'Se envió un link para restablecer la contraseña a ' + target.email + '.' };
      case 'revoke_sessions':
        revoke(target); this._audit(actor, 'SESSIONS_REVOKED', target.id, null, { revoked_at: target.sessions_revoked_at }); this._save();
        return { ok: true, message: 'Se cerraron las sesiones de ' + target.full_name + '. Tiene que volver a iniciar sesión.' };
      case 'resend_invite':
        this._authMail(target, 'INVITACION'); this._audit(actor, 'INVITE_RESENT', target.id, null, { email: target.email }); this._save();
        return { ok: true, message: 'Invitación reenviada a ' + target.email + '.' };
      case 'reassign_routes': {
        const to = this._user(payload.to_user);
        const list = this._activeRoutes(target.id);
        const bad = list.find(r => !compatibleResponsables([to], DEMO_CARRIERS.find(c => c.id === r.carrier_id)).length);
        if (bad) throw err('El usuario elegido no puede recibir alguna de esas hojas (responsable incompatible).', 'REASSIGN_FAILED', 409);
        list.forEach(r => { r.responsable_id = to.id; });
        this._audit(actor, 'ROUTES_REASSIGNED', target.id, null, { to_user: to.id, count: list.length }); this._save();
        return { ok: true, count: list.length };
      }
      case 'delete': { // borrado completo: borradores sin publicar, reservas, notificaciones y passkeys
        const drafts = Object.values(this.db.drafts || {}).filter(d => d.owner_id === target.id && !d.route_id).map(d => d.client_sheet_key);
        Object.keys(this.db.reservations || {}).forEach(o => { if (drafts.includes(this.db.reservations[o].sheet_key)) delete this.db.reservations[o]; });
        drafts.forEach(k => delete this.db.drafts[k]);
        this.db.notifs = (this.db.notifs || []).filter(n => n.user_id !== target.id); this.db.passkeys = (this.db.passkeys || []).filter(p => p.user_id !== target.id);
        delete this.db.passwords[target.id];
        this.db.users = this.db.users.filter(x => x.id !== target.id); this._audit(actor, 'USER_DELETED', target.id, before, null); this._save(); return { deleted: target.id }; }
    }
    this._save();
    return { ...target, carriers: [...target.carriers] };
  }

  // Selector de RESPONSABLE: el "servidor" devuelve solo los compatibles
  async responsables(carrierId) {
    const me = await this.me();
    if (!hasPerm(me, 'routes.assign')) throw err('FORBIDDEN: falta permiso routes.assign', 'FORBIDDEN', 403);
    return compatibleResponsables(this.db.users, DEMO_CARRIERS.find(c => c.id === carrierId)).map(x => ({ id: x.id, full_name: x.full_name, role: x.role }));
  }
  // Historial operativo real (hojas, resultados, publicaciones); aceptar invitación o cambiar contraseña no cuenta
  _hasHistory(id) { return this.db.history.includes(id) || (this.db.routes2 || []).some(r => [r.responsable_id, r.published_by, r.started_by, r.completed_by].includes(id) || r.stops.some(st => st.outcome_by === id || st.added_by === id)); }
  async hasHistory(id) { this._refresh(); return this._hasHistory(id); }
  // ===== Fase 2B.1: publicar → recibir → ver → iniciar → resultados → finalizar (equivale a las funciones SQL) =====
  _refresh() { const d = this._load(); if (d) this.db = d; }
  _net() { if (typeof window !== 'undefined' && window.OKD_NET && window.OKD_NET.offline) throw err('Sin conexión', 'OFFLINE', 0); }
  _mendozaDay() { return new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Argentina/Mendoza' }).format(new Date()); }
  // DESPACHAR E IMPRIMIR (tercerizados): igual que el servidor dispatch_external_route — hoja COMPLETADA, dispatch_mode EXTERNAL,
  // número del correlativo del transportista, reservas y borrador PUBLICADA. El PDF lo genera/guarda el constructor después.
  async dispatchExternalRoute(p) {
    this._refresh(); const me = await this.me();
    if (!hasPerm(me, 'routes.publish')) throw err('FORBIDDEN', 'FORBIDDEN', 403);
    const draft = this._draft(p.sheet_key, me, true, false);   // mismo control de borrador que publishRoute
    if (draft.status === 'PUBLICADA') return (this.db.routes2 || []).find(r => r.id === draft.route_id);   // reintento
    const carrier = this._carriers().find(c => c.id === p.carrier_id && c.active !== false);
    if (!carrier) throw err('BAD_CARRIER: elegí el transportista', 'BAD_CARRIER', 400);
    if (carrier.kind !== 'EXTERNO' || carrier.report_group === 'CRISTIAN_TORRES') throw err('NOT_EXTERNAL_DISPATCH: este transportista usa PUBLICAR HOJA', 'NOT_EXTERNAL_DISPATCH', 400);
    if (!(p.stops || []).length) throw err('EMPTY_SHEET: la hoja no tiene pedidos', 'EMPTY_SHEET', 400);
    const ords = [...new Set(p.stops.flatMap(x => x.order_numbers || []))], now = new Date().toISOString();
    const code = carrier.sequence_code || SEQ_CODE[carrier.id]; this.db.sequences = this.db.sequences || {}; const n = this.db.sequences[code] = (this.db.sequences[code] || 0) + 1;
    const r = { id: 'rt-' + (++this.db.seq) + '-' + Date.now().toString(36), number: code + '-' + String(n).padStart(6, '0'), carrier_id: carrier.id, carrier_name: carrier.name,
      responsable_id: null, responsable_name: null, operational_status: 'COMPLETADA', status: 'COMPLETADA', dispatch_mode: 'EXTERNAL', dispatched_at: now, dispatched_by: me.id,
      sheet_key: p.sheet_key, published_at: now, published_by: me.id, completed_at: now, version: 1, approval_status: 'NO_REQUERIDA', events: [],
      stops: p.stops.map((x, i) => ({ id: 'st-' + this.db.seq + '-' + i, seq: i + 1, sequence_number: i + 1, provenance: 'DESPACHO', stop_type: x.stop_type || 'PEDIDO', client_name: x.client_name,
        address: x.address, order_numbers: x.order_numbers || [], merchandise_amount: x.merchandise_amount ?? null, shipping_fee: x.shipping_fee ?? null, bultos: x.bultos ?? null,
        task: x.task || 'ENTREGA', outcome: 'PENDIENTE', collection_status: 'PENDIENTE' })) };
    (this.db.routes2 = this.db.routes2 || []).push(r);
    Object.assign(draft, { status: 'PUBLICADA', route_id: r.id, updated_at: now });
    Object.entries(this.db.reservations || {}).filter(([o, x]) => x.sheet_key === p.sheet_key && ords.includes(o)).forEach(([, x]) => { x.status = 'PUBLICADA'; x.route_id = r.id; x.number = r.number; });
    this._audit(me, 'ROUTE_DISPATCHED_EXTERNAL', r.id, null, { number: r.number, carrier: carrier.id });
    this._save(); return r;
  }
  async publishRoute(p) {
    this._net(); this._refresh(); const me = await this.me();
    if (!hasPerm(me, 'routes.publish')) throw err('No tenés permiso para publicar.', 'FORBIDDEN', 403);
    const R = this.db.routes2 = this.db.routes2 || [];
    const draft = this._draft(p.sheet_key, me, true, false);
    if (draft.status === 'PUBLICADA') return R.find(r => r.id === draft.route_id); // reintento
    { const F = this.db.financialRules || [{ version: 1 }], cur = F[F.length - 1].version, v = p.rules_version; // obligatorio y EXACTO (como el servidor)
      if (v == null || v === '') throw err('RULES_REQUIRED: la hoja debe calcularse con la versión vigente de las reglas financieras (v' + cur + ')', 'RULES_REQUIRED', 409);
      if (Number(v) < cur) throw err('RULES_OUTDATED: las reglas financieras cambiaron (v' + cur + '); recalculá la hoja antes de publicar', 'RULES_OUTDATED', 409);
      if (Number(v) > cur) throw err('RULES_UNKNOWN: la versión de reglas v' + v + ' no existe (vigente v' + cur + ')', 'RULES_UNKNOWN', 409); }
    { const RR = this.db.routingRules, cur = RR && RR.length ? RR[RR.length - 1].version : 1, v = p.routing_rules_version; // reglas de asignación: obligatoria y EXACTA
      if (v == null || v === '') throw err('ROUTING_RULES_REQUIRED: la hoja debe calcularse con la versión vigente de las reglas de asignación (v' + cur + ')', 'ROUTING_RULES_REQUIRED', 409);
      if (Number(v) < cur) throw err('ROUTING_RULES_OUTDATED: las reglas de asignación cambiaron (v' + cur + '); recalculá la hoja antes de publicar', 'ROUTING_RULES_OUTDATED', 409);
      if (Number(v) > cur) throw err('ROUTING_RULES_UNKNOWN: la versión de reglas de asignación v' + v + ' no existe (vigente v' + cur + ')', 'ROUTING_RULES_UNKNOWN', 409); }
    const carrier = this._carriers().find(c => c.id === p.carrier_id && c.active !== false); if (!carrier) throw err('Elegí el transportista.', 'BAD_CARRIER', 400);
    if (carrier.kind === 'INTERNO' && !(this.db.vehicles || []).some(v => v.id === p.vehicle_id && v.active)) throw err(p.vehicle_id ? 'BAD_VEHICLE: vehículo inexistente o inactivo' : 'VEHICLE_REQUIRED: la ruta interna necesita un vehículo activo', p.vehicle_id ? 'BAD_VEHICLE' : 'VEHICLE_REQUIRED', 409);
    const resp = this._user(p.responsable_id);
    if (!canBeResponsable(resp, carrier)) throw err('RESPONSABLE_INCOMPATIBLE', 'RESPONSABLE_INCOMPATIBLE', 409);
    if (!(p.stops || []).length) throw err('La hoja no tiene pedidos.', 'EMPTY_SHEET', 400);
    const ok = new Set((this.db.shipping || []).filter(x => x.sheet_key === p.sheet_key && ['CONFIRMED', 'MODIFIED_CONFIRMED', 'RESOLVED_BY_SALDO'].includes(x.status)).map(x => x.ship_order));
    const miss = p.stops.filter(x => x.ship_fee_status === 'PROVISIONAL' && !ok.has(x.ship_order)).map(x => x.ship_order);
    if (miss.length) throw err('SHIPPING_PENDING: envíos sin confirmar: ' + miss.join(', '), 'SHIPPING_PENDING', 409);
    if (p.stops.some(x => !x.ready)) throw err('Hay pedidos con revisión pendiente o sin monto.', 'NOT_READY', 409);
    const ords = [...new Set(p.stops.flatMap(x => x.order_numbers || []))];
    this._reserve(p.sheet_key, ords, me); // falla si algún pedido está en otra hoja
    this._orphanCheck(p.sheet_key, ords);
    const ruled = p.stops.map(x => this._stopRules(x, carrier));
    { const keys = ruled.filter(x => x.stop_type === 'UBICACION_INTERNA').map(x => x.internal_location_key); const dup = keys.find((k, i) => keys.indexOf(k) !== i);
      if (dup) throw err('duplicate key value violates unique constraint "route_stops_one_internal_location_per_route" (' + dup + ')', 'DUPLICATE_INTERNAL_LOCATION', 409); }
    // Correlativo por transportista/base, continuo (CT Este y Alrededores comparten el 01)
    const code = carrier.sequence_code || SEQ_CODE[carrier.id]; this.db.sequences = this.db.sequences || {}; const n = this.db.sequences[code] = (this.db.sequences[code] || 0) + 1;
    const now = new Date().toISOString();
    const r = { id: 'rt-' + (++this.db.seq) + '-' + Date.now().toString(36), number: code + '-' + String(n).padStart(6, '0'), carrier_id: carrier.id, carrier_name: carrier.name,
      responsable_id: resp.id, responsable_name: resp.full_name, operational_status: 'PUBLICADA', sheet_key: p.sheet_key, published_at: now, published_by: me.id,
      notified_at: null, viewed_at: null, started_at: null, completed_at: null, sheet_snapshot: p,
      version: 1, approval_status: 'NO_REQUERIDA', events: [],
      stops: ruled.map((x, i) => ({ id: 'st-' + this.db.seq + '-' + i, seq: i + 1,
        stop_type: x.stop_type, instructions: x.instructions, contact_name: x.contact_name, contact_phone: x.contact_phone, internal_location_key: x.internal_location_key,
        expected_lat: x.expected_lat, expected_lon: x.expected_lon, expected_radius_m: x.expected_radius_m, internal_location_updated_at: x.internal_location_updated_at, sequence_number: i + 1, provenance: 'PUBLISHED', action: x.action || 'ENTREGA', client_name: x.client_name, client_key: x.client_key, zone: x.zone || null, order_numbers: x.order_numbers || [], address: x.address || '', bultos: x.bultos || null,
        merchandise_amount: x.merchandise_amount || 0, shipping_fee: x.shipping_fee || 0, shipping_fee_source: x.ship_fee_status === 'PROVISIONAL' ? 'CONFIRMED_FALLBACK' : 'SALDO', outcome: 'PENDIENTE',
        task: x.task || 'ENTREGA', expected_amount: x.expected_amount ?? null, customer_email: x.customer_email || null, collection_status: 'PENDIENTE' })) };
    if (carrier.kind === 'INTERNO' && !p.vehicle_id) throw err('VEHICLE_REQUIRED: la ruta interna necesita un vehículo activo', 'VEHICLE_REQUIRED', 409);
    if (p.vehicle_id && carrier.kind === 'INTERNO') { const v = (this.db.vehicles || []).find(x => x.id === p.vehicle_id && x.active); if (!v) throw err('Vehículo inexistente o inactivo.', 'BAD_VEHICLE', 400); r.vehicle_id = v.id; r.vehicle_plate = v.plate; r.vehicle_name = v.name; r.km_start = null; }
    R.push(r); Object.assign(draft, { status: 'PUBLICADA', route_id: r.id, updated_at: now });
    this._nocConsume(a => a.sheet_key === p.sheet_key, Object.assign(r, { sheet_key: p.sheet_key }), me); // consumo definitivo de las NOC reservadas en este borrador (y reasociaciones)
    // Snapshot de financiación propia (inmutable) desde el plan real
    (p.financing || []).forEach(e => { const f = (this.db.finPlans || []).find(x => x.id === e.plan_id); (this.db.finSnapshots = this.db.finSnapshots || []).push({ route_id: r.id, route_version: 1, comp: e.comp || (f && f.comp),
      client_key: e.client_key || (f && f.client_key), classification: e.classification || 'FINANCIACION_PROPIA_VIGENTE', parts: e.parts || (f && f.parts) || [], frequency: f ? f.frequency : e.frequency,
      source_pending: f ? f.source_pending : null, noc_adjustments: f ? f.noc_adjustments : null, operational_pending: f ? f.operational_pending : null, source_import: e.import_id || (f && f.last_import_id), resolver_version: e.resolver_version, plan_id: e.plan_id, created_at: now }); });
    Object.entries(this.db.reservations).filter(([o, x]) => x.sheet_key === p.sheet_key && ords.includes(o)).forEach(([, x]) => { x.status = 'PUBLICADA'; x.route_id = r.id; x.number = r.number; });   // solo las de las paradas
    this.db.notifs = this.db.notifs || [];
    if (!this.db.notifs.some(x => x.user_id === resp.id && x.route_id === r.id)) this.db.notifs.push({ id: 'nt-' + this.db.seq, user_id: resp.id, route_id: r.id, type: 'NUEVA_HOJA_PUBLICADA', title: 'NUEVA HOJA PUBLICADA', body: 'Hoja ' + r.number + ' · ' + r.stops.length + (carrier.kind === 'INTERNO' ? (r.stops.length === 1 ? ' parada' : ' paradas') : (r.stops.length === 1 ? ' entrega' : ' entregas')), created_at: now, read_at: null });
    this._audit(me, 'ROUTE_PUBLISHED', r.id, null, { number: r.number, carrier: carrier.id, responsable: resp.id });
    this._save(); return r;
  }
  // Reservas huérfanas: pedidos reservados por el borrador que no están en ninguna parada → se rechaza (como publish_route)
  _orphanCheck(sheetKey, ords) {
    const orf = Object.entries(this.db.reservations || {}).filter(([o, x]) => x.sheet_key === sheetKey && x.status === 'BORRADOR' && !ords.includes(o)).map(([o]) => o).sort();
    if (orf.length) throw err('ORPHAN_RESERVATIONS: hay pedidos reservados que no están en la hoja: ' + orf.join(', '), 'ORPHAN_RESERVATIONS', 409);
  }
  // Reglas por tipo de parada (= trigger trg_zz_stop_type_rules del servidor)
  _stopRules(x, carrier) {
    const t = x.stop_type || 'PEDIDO', o = Object.assign({}, x, { stop_type: t, instructions: String(x.instructions || '').trim() || null, contact_name: x.contact_name || null, contact_phone: x.contact_phone || null });
    if (['TAREA', 'UBICACION_INTERNA'].includes(t) && carrier.kind !== 'INTERNO') throw err('STOP_TYPE_REQUIRES_INTERNAL: ' + t + ' solo se publica con Transporte Interno', 'STOP_TYPE_REQUIRES_INTERNAL', 409);
    if (t === 'UBICACION_INTERNA') {
      if (!x.internal_location_key) throw err('INTERNAL_LOCATION_REQUIRED: la ubicación interna no tiene clave G2', 'INTERNAL_LOCATION_REQUIRED', 409);
      const l = (this.db.internalLocations || []).find(y => y.location_key === x.internal_location_key);
      if (!l || l.active === false) throw err('INTERNAL_LOCATION_INACTIVE: ' + x.internal_location_key + ' no existe o está desactivada en G2', 'INTERNAL_LOCATION_INACTIVE', 409);
      Object.assign(o, { client_name: l.name, address: l.address || '', client_key: l.location_key, expected_lat: l.lat, expected_lon: l.lon, expected_radius_m: l.radius_m, internal_location_updated_at: l.updated_at || null });
    } else Object.assign(o, { internal_location_key: null, expected_lat: null, expected_lon: null, expected_radius_m: null, internal_location_updated_at: null });
    if (t !== 'PEDIDO') Object.assign(o, { merchandise_amount: 0, shipping_fee: 0, customer_email: null, task: 'ENTREGA', expected_amount: null });
    return o;
  }
  async driverInternalLocations() {
    this._refresh(); const me = await this.me();
    // igual que el servidor: con "Permitir asignación de hojas de ruta", solo mientras tenga una hoja interna propia pendiente o en curso
    const ownInternal = hasPerm(me, 'routes.receive_internal') && (this.db.routes2 || []).some(r => r.responsable_id === me.id && ['PUBLICADA', 'EN_CURSO'].includes(r.operational_status)
      && ((this._carriers().find(c => c.id === r.carrier_id) || {}).kind === 'INTERNO'));
    if (!['internal_routes.use', 'routes.create', 'locations.view'].some(p => hasPerm(me, p)) && !ownInternal) return [];
    return (this.db.internalLocations || []).filter(l => l.active !== false).map(l => ({ location_key: l.location_key, name: l.name, address: l.address, radius_m: l.radius_m })).sort((a, b) => a.name.localeCompare(b.name));
  }
  _canReadG2(me) { return ['settings.manage', 'locations.manage', 'locations.view', 'routes.create'].some(p => hasPerm(me, p)); }
  async listInternalLocations() {
    this._refresh(); const me = await this.me(); if (!this._canReadG2(me)) return [];   // como la RLS: sin permiso, lista vacía
    return (this.db.internalLocations || []).slice().sort((a, b) => a.name.localeCompare(b.name)).map(x => ({ ...x }));
  }
  async saveInternalLocation(p) {
    this._refresh(); const me = await this.me();
    if (!hasPerm(me, 'settings.manage') && !hasPerm(me, 'locations.manage')) throw err('FORBIDDEN', 'FORBIDDEN', 403);
    const key = String(p.location_key || '').trim().toUpperCase();
    if (!key || !String(p.name || '').trim() || p.lat == null || p.lon == null || p.lat === '' || p.lon === '') throw err('BAD_LOCATION: completá clave, nombre y coordenadas', 'BAD_LOCATION', 400);
    const rad = Number(p.radius_m || 200); if (!(rad >= 10 && rad <= 5000)) throw err('BAD_LOCATION: el radio debe estar entre 10 y 5000 m', 'BAD_LOCATION', 400);
    const L = this.db.internalLocations = this.db.internalLocations || [];
    if (L.some(x => x.active !== false && x.location_key !== key && x.name.trim().toLowerCase() === String(p.name).trim().toLowerCase())) throw err('DUPLICATE_LOCATION_NAME: ya existe otra ubicación activa con ese nombre', 'DUPLICATE_LOCATION_NAME', 409);
    const prev = L.find(x => x.location_key === key), now = new Date().toISOString();
    const row = { location_key: key, name: String(p.name).trim(), address: String(p.address || '').trim() || null, lat: Number(p.lat), lon: Number(p.lon), radius_m: rad, active: p.active !== false, note: p.note || null,
      geocode_source: p.geocode_source || (prev && prev.geocode_source) || null, geocode_display_name: p.geocode_display_name || (prev && prev.geocode_display_name) || null, updated_at: now };
    if (prev) Object.assign(prev, row); else L.push(row);
    this._audit(me, 'INTERNAL_LOCATION_SAVED', key, prev ? { ...prev } : null, row); this._save(); return row;
  }
  async geocodeInternalLocation(address) {
    this._refresh(); const me = await this.me();
    if (!hasPerm(me, 'settings.manage') && !hasPerm(me, 'locations.manage')) throw err('Solo quien administra ubicaciones (G2) puede buscar coordenadas.', 'FORBIDDEN', 403);
    throw err('Modo demo: sin conexión al geocodificador. Cargá las coordenadas a mano.', 'DEMO_NO_GEOCODER', 400);
  }
  // Borrador con dueño (equivale a route_drafts / _draft del servidor)
  _draft(sheetKey, me, create, needDraft = true) {
    if (!sheetKey) throw err('Hoja inválida.', 'BAD_SHEET', 400);
    const D = this.db.drafts = this.db.drafts || {};
    let d = D[sheetKey];
    if (!d) { if (!create) return null; d = D[sheetKey] = { id: 'dr-' + (++this.db.seq), client_sheet_key: sheetKey, owner_id: me.id, status: 'BORRADOR', route_id: null, created_at: new Date().toISOString() }; }
    if (!this._canManageDraftOf(me, d.owner_id)) throw err('FORBIDDEN_DRAFT: el borrador pertenece a otro operador', 'FORBIDDEN_DRAFT', 403);
    if (needDraft && d.status !== 'BORRADOR') throw err('DRAFT_PUBLISHED: la hoja ya fue publicada; no se modifica como borrador', 'DRAFT_PUBLISHED', 409);
    return d;
  }
  // Reserva de pedidos (equivale a reserve_orders / release_orders del servidor)
  // REENVÍOS (igual que la propuesta de servidor reserve_orders): la reserva PUBLICADA de un pedido pasa a la hoja nueva SOLO si en su
  // hoja anterior todas sus paradas quedaron NO_ENTREGADO/REPROGRAMAR, o esa hoja fue cancelada. Se guarda en el historial.
  _retryable(o, routeId) {
    const r = (this.db.routes2 || []).find(x => x.id === routeId); if (!r) return false;
    if (r.operational_status === 'CANCELADA') return true;
    const st = (r.stops || []).filter(s => (s.order_numbers || []).map(String).includes(o));
    return st.length > 0 && st.every(s => ['NO_ENTREGADO', 'REPROGRAMAR'].includes(s.outcome));
  }
  _reserve(sheetKey, orders, me) {
    const RS = this.db.reservations = this.db.reservations || {};
    orders.filter(o => o && RS[o] && RS[o].sheet_key !== sheetKey && RS[o].status === 'PUBLICADA' && RS[o].route_id && this._retryable(o, RS[o].route_id)).forEach(o => {
      const r = (this.db.routes2 || []).find(x => x.id === RS[o].route_id) || {};
      (this.db.reservationHistory = this.db.reservationHistory || []).push({ order_id: o, ...RS[o], released_at: new Date().toISOString(), released_by: me.id, released_to_sheet: sheetKey,
        reason: r.operational_status === 'CANCELADA' ? 'HOJA_CANCELADA' : 'REINTENTO_NO_ENTREGADO_O_REPROGRAMADO' });
      delete RS[o];
    });
    const bad = orders.filter(o => o && RS[o] && RS[o].sheet_key !== sheetKey);
    const details = bad.map(o => { const d = (this.db.drafts || {})[RS[o].sheet_key] || {}, u = this._user(RS[o].reserved_by) || {};
      return { order: o, sheet_key: RS[o].sheet_key, draft_name: d.name || null, owner_id: RS[o].reserved_by, owner: u.full_name || '', route_number: RS[o].number || null, published: !!RS[o].number }; });
    if (bad.length) throw err('PEDIDO_YA_EN_OTRA_HOJA: ' + details.map(x => x.order + ' (' + (x.route_number ? 'hoja ' + x.route_number : 'borrador' + (x.draft_name ? ' "' + x.draft_name + '"' : '') + (x.owner ? ' de ' + x.owner : '')) + ')').join(', '), 'PEDIDO_YA_EN_OTRA_HOJA', 409, { details });
    orders.filter(Boolean).forEach(o => { if (!RS[o]) RS[o] = { sheet_key: sheetKey, status: 'BORRADOR', reserved_by: me.id, reserved_at: new Date().toISOString() }; });
  }
  async reserveOrders(sheetKey, orders) {
    this._net(); this._refresh(); const me = await this.me();
    if (!hasPerm(me, 'routes.create')) throw err('No tenés permiso.', 'FORBIDDEN', 403);
    this._draft(sheetKey, me, true);
    this._reserve(sheetKey, orders.map(String), me); this._save();
  }
  async releaseOrders(sheetKey, orders) {
    this._net(); this._refresh(); const me = await this.me();
    if (!this._draft(sheetKey, me, false)) return;
    const RS = this.db.reservations || {};
    Object.keys(RS).forEach(o => { if (RS[o].sheet_key === sheetKey && RS[o].status === 'BORRADOR' && (!orders || orders.map(String).includes(o))) delete RS[o]; });
    this._save();
  }
  async routeStatus(id) { this._refresh(); const r = (this.db.routes2 || []).find(x => x.id === id); return r ? { ...r } : null; }
  _mine(id) { const me = this._user(this.session && this.session.userId); const r = (this.db.routes2 || []).find(x => x.id === id); if (!r || !me || !canOperateAssigned(me, r, ((this._carriers().find(c => c.id === r.carrier_id) || {}).kind))) throw err('FORBIDDEN', 'FORBIDDEN', 403); return { r, me }; }   // igual que _my_route
  async myRoutes() {
    this._net(); this._refresh(); const me = await this.me(); if (!me) throw err('Sesión inválida.', 'NO_AUTH', 401);
    const cs = this._carriers(), cfg = id => cs.find(c => c.id === id) || DEMO_CARRIERS.find(c => c.id === id) || {};
    return (this.db.routes2 || []).filter(r => r.responsable_id === me.id).map(r => Object.assign(JSON.parse(JSON.stringify(r)), { carrier_kind: cfg(r.carrier_id).kind || null, carrier_report_group: cfg(r.carrier_id).report_group || null })).sort((a, b) => b.published_at.localeCompare(a.published_at));
  }
  async markDelivered(id) { this._net(); this._refresh(); const { r } = this._mine(id); if (!r.notified_at) { r.notified_at = new Date().toISOString(); this._save(); } }
  async markViewed(id) { this._net(); this._refresh(); const { r, me } = this._mine(id); const t = new Date().toISOString(); r.viewed_at = r.viewed_at || t; r.notified_at = r.notified_at || t; (this.db.notifs || []).filter(x => x.route_id === id && x.user_id === me.id).forEach(x => { x.read_at = x.read_at || t; }); this._save(); return r; }
  async startRoute(id, kmStart) {
    this._net(); this._refresh(); const { r, me } = this._mine(id);
    if (r.operational_status === 'EN_CURSO') return r;
    if (r.operational_status !== 'PUBLICADA') throw err('La hoja no se puede iniciar.', 'BAD_STATE', 409);
    if (r.vehicle_id) {
      const v = this.db.vehicles.find(x => x.id === r.vehicle_id);
      if (kmStart == null || kmStart === '') throw err('KM_START_REQUIRED: cargá el kilometraje inicial', 'KM_START_REQUIRED', 400);
      if (Number(kmStart) < v.current_km) throw err('KM_LOWER: el kilometraje no puede ser menor al último registrado (' + v.current_km + ')', 'KM_LOWER', 400);
      v.current_km = Number(kmStart); r.km_start = Number(kmStart); r.km_started_at = new Date().toISOString();
    }
    Object.assign(r, { operational_status: 'EN_CURSO', started_at: new Date().toISOString(), started_by: me.id, viewed_at: r.viewed_at || new Date().toISOString() });
    this._onTheWay(r); this._audit(me, 'ROUTE_STARTED', r.id); this._save(); await this.sendCustomerQueued(); return r;
  }
  // Ubicación puntual (nunca inventada): lat/lon o motivo
  _loc(p, st) {
    if (!p) throw err('LOCATION_REQUIRED: registrá la ubicación o indicá por qué no se pudo', 'LOCATION_REQUIRED', 400);
    if (p.lat != null && p.lon != null) {
      const o = { lat: +p.lat, lon: +p.lon, accuracy: p.accuracy != null ? +p.accuracy : null, at: new Date().toISOString() };
      if (st && st.expected_lat != null) {   // ubicación interna: SIEMPRE contra el snapshot de la publicación
        const d = Math.round(6371000 * 2 * Math.asin(Math.sqrt(Math.sin((o.lat - st.expected_lat) * Math.PI / 360) ** 2 + Math.cos(o.lat * Math.PI / 180) * Math.cos(st.expected_lat * Math.PI / 180) * Math.sin((o.lon - st.expected_lon) * Math.PI / 360) ** 2)));
        Object.assign(o, { validation_source: 'INTERNAL_SNAPSHOT', validation_key: st.internal_location_key, expected_lat: st.expected_lat, expected_lon: st.expected_lon, radius_m: st.expected_radius_m, distance_m: d, outside_m: d > st.expected_radius_m ? d : null });
      }
      return o;
    }
    if (!String(p.missing_reason || '').trim()) throw err('LOCATION_REASON_REQUIRED: sin ubicación hay que indicar el motivo', 'LOCATION_REASON_REQUIRED', 400);
    return { missing_reason: String(p.missing_reason).trim(), at: new Date().toISOString() };
  }
  async arriveStop(stopId, location, opId) {
    this._net(); this._refresh();
    const r = (this.db.routes2 || []).find(x => x.stops.some(st => st.id === stopId)); if (!r) throw err('No existe.', 'NOT_FOUND', 404);
    this._mine(r.id); const st = r.stops.find(x => x.id === stopId);
    if (r.operational_status !== 'EN_CURSO') throw err('La hoja no está en curso.', 'BAD_STATE', 409);
    if (st.arrived_at) return st;
    st.arrive_location = this._loc(location, st); st.arrived_at = new Date().toISOString(); this._save(); return st;
  }
  // Storage privado (demo): el chofer sube, no descarga; solo identity_docs.view obtiene un enlace temporal
  async uploadIdentityDoc(cuil, file) {
    this._net(); this._refresh(); const me = await this.me();
    if (!hasPerm(me, 'deliveries.capture_signature')) throw err('Sin permiso.', 'FORBIDDEN', 403);
    if (!['image/jpeg', 'image/png'].includes(file.mime)) throw err('La foto del DNI debe ser JPEG o PNG.', 'BAD_TYPE', 400);
    if (!(file.size > 0) || file.size > 5242880) throw err('La foto del DNI supera 5 MB.', 'BAD_SIZE', 400);
    const path = String(cuil).replace(/\D/g, '') + '/' + crypto.randomUUID() + (file.mime === 'image/png' ? '.png' : '.jpg');
    // la foto llega como Blob (V4.16, sin base64 en memoria del chofer); la demo la guarda en su almacenamiento local
    const b64 = file.b64 || await new Promise((ok, ko) => { const fr = new FileReader(); fr.onload = () => ok(String(fr.result).split(',')[1]); fr.onerror = ko; fr.readAsDataURL(file.blob); });
    this.db.storage = this.db.storage || {}; this.db.storage[path] = { b64, mime: file.mime, size: file.size, owner: me.id }; this._save(); return path;
  }
  async identityDocUrl(cuil) {
    this._refresh(); const me = await this.me(); if (!hasPerm(me, 'identity_docs.view')) throw err('Sin permiso.', 'FORBIDDEN', 403);
    const d = (this.db.identity || {})[cuil]; if (!d) return null; const o = this.db.storage[d.storage_path];
    const url = URL.createObjectURL(new Blob([Uint8Array.from(atob(o.b64), c => c.charCodeAt(0))], { type: o.mime })); setTimeout(() => URL.revokeObjectURL(url), 60000); return url; // vence en 60 s
  }
  async cuilHasDni(cuil) { this._refresh(); const d = (this.db.identity || {})[String(cuil || '').replace(/\D/g, '')]; return !!(d && d.storage_path); }
  // RC4.1: autocompletar la segunda pantalla (solo el chofer de la parada o Admin; nunca la foto del DNI). CUIL → DNI → cliente.
  async deliveryIdentityLookup(stopId, cuil, dni) {
    this._refresh(); const me = await this.me();
    const r = (this.db.routes2 || []).find(x => x.stops.some(s => s.id === stopId)); if (!r) throw err('NOT_FOUND', 'NOT_FOUND', 404);
    if (!(r.responsable_id === me.id || me.role === 'ADMIN')) throw err('FORBIDDEN', 'FORBIDDEN', 403);
    const st = r.stops.find(s => s.id === stopId), I = this.db.identity || {}, c = String(cuil || '').replace(/\D/g, ''), d = String(dni || '').replace(/\D/g, '');
    let p = c && I[c] ? { ...I[c], cuil: c, source: 'CUIL' } : null;
    if (!p && d) { const k = Object.keys(I).filter(x => I[x].dni === d).sort((a, b) => String(I[b].updated_at).localeCompare(String(I[a].updated_at)))[0]; if (k) p = { ...I[k], cuil: k, source: 'DNI' }; }
    if (p) return { source: p.source, cuil: p.cuil, dni: p.dni || null, full_name: p.full_name || null, email: p.email || null, has_dni_photo: !!p.storage_path };
    if (st.client_key) { const e = Object.values(this.db.evidence || {}).filter(x => x.client_key === st.client_key && x.receiver_email).sort((a, b) => String(b.at).localeCompare(String(a.at)))[0];
      if (e) return { source: 'CLIENTE', cuil: e.cuil || null, dni: e.receiver_dni || null, full_name: e.receiver_name, email: e.receiver_email, has_dni_photo: !!(e.cuil && I[e.cuil] && I[e.cuil].storage_path) }; }
    return null;
  }
  _onTheWay(r) {
    const cur = currentStop(r.stops); if (!cur || !cur.customer_email || (cur.stop_type && cur.stop_type !== 'PEDIDO')) return;   // solo pedidos comerciales
    this._queueCustomer(r, cur, 'ON_THE_WAY');
  }
  _queueCustomer(r, st, kind, recipient) {
    const J = this.db.customerJobs = this.db.customerJobs || [], key = r.id + '|' + st.id + '|' + kind;
    if (!J.some(j => j.idempotency_key === key)) J.push({ id: 'cj-' + (++this.db.seq), route_id: r.id, stop_id: st.id, kind, recipient: String(recipient || st.customer_email).trim().toLowerCase(), idempotency_key: key, status: 'QUEUED', retry_count: 0, attempts: [] });
  }
  async sendCustomerQueued(onlyIds) {
    this.db.outboxCustomer = this.db.outboxCustomer || [];
    const store = { listJobs: async q => (this.db.customerJobs || []).filter(j => q.statuses.includes(j.status) && (!q.ids || q.ids.includes(j.id))),
      stopFor: async j => this.db.routes2.find(r => r.id === j.route_id).stops.find(x => x.id === j.stop_id),
      receiptFor: async j => { const rc = (this.db.receipts || {})[j.stop_id]; if (!rc) throw new Error('no existe el comprobante'); return rc; },
      // mismo historial de intentos que el trigger del servidor
      updateJob: async (id, p) => { const j = this.db.customerJobs.find(x => x.id === id); Object.assign(j, p, { last_attempt_at: new Date().toISOString() });
        j.attempts = (j.attempts || []).concat([{ at: j.last_attempt_at, status: j.status, provider_id: j.provider_id || null, error: j.error || null, retry: j.retry_count || 0 }]); } };
    const provider = { send: async m => { if (typeof window !== 'undefined' && window.OKD_MAIL_FAIL) throw new Error('Proveedor de email caído (simulado)'); this.db.outboxCustomer.push({ to: m.to, subject: m.subject, html: m.html, idempotency_key: m.idempotencyKey, attachments: (m.attachments || []).map(x => ({ filename: x.filename, content_type: x.content_type, content_id: x.content_id, bytes: Math.floor(String(x.content || '').length * 3 / 4) - ((String(x.content || '').match(/=+$/) || [''])[0].length) })) }); return { id: 'c' + this.db.outboxCustomer.length }; } };
    // mismo logo inline (CID) que la Edge Function; el módulo se carga aparte solo cuando hay que enviar
    const [lm, rb] = await Promise.all([import('../../supabase/functions/_shared/ok-accesorios-logo.js'), import('../../supabase/functions/_shared/resend-body.js')]);
    const out = await sendCustomerEmails({ store, provider, onlyIds, inlineLogo: rb.inlineLogoFrom(lm) }); this._save(); return out;
  }
  async setStopOutcome(stopId, outcome, note, reason, opId, extra) {
    this._net(); this._refresh();
    const r = (this.db.routes2 || []).find(x => x.stops.some(s => s.id === stopId)); if (!r) throw err('No existe.', 'NOT_FOUND', 404);
    const { me } = this._mine(r.id), st = r.stops.find(s => s.id === stopId);
    this.db.ops = this.db.ops || {}; if (opId && this.db.ops[opId]) return st; // reintento offline
    if (r.operational_status !== 'EN_CURSO') throw err('Iniciá el recorrido o la hoja ya está cerrada.', 'BAD_STATE', 409);
    if (!['ENTREGADO', 'ENTREGA_PARCIAL', 'NO_ENTREGADO', 'REPROGRAMAR'].includes(outcome)) throw err('Resultado inválido.', 'BAD_OUTCOME', 400);
    if (outcome === 'ENTREGA_PARCIAL' && !String(note || '').trim()) throw err('Entrega parcial exige observación.', 'NOTE_REQUIRED', 400);
    if (['NO_ENTREGADO', 'REPROGRAMAR'].includes(outcome) && !String(reason || '').trim()) throw err('Indicá el motivo.', 'REASON_REQUIRED', 400);
    const type = st.stop_type || 'PEDIDO', commercial = type === 'PEDIDO', task = type === 'TAREA';
    const ev = (extra && extra.evidence) || {}, col = commercial ? extra && extra.collection : null;
    // igual que el servidor: Cristian = transportista con report_group CRISTIAN_TORRES (configuración, no identificadores)
    const cfgC = this._carriers().find(c => c.id === r.carrier_id) || DEMO_CARRIERS.find(c => c.id === r.carrier_id) || {}, cristian = commercial && cfgC.report_group === 'CRISTIAN_TORRES';
    let cuil = null;
    if (['ENTREGADO', 'ENTREGA_PARCIAL'].includes(outcome)) {
      if (!task && (!String(ev.receiver_name || '').trim() || !ev.signature_png_b64)) throw err('EVIDENCE_REQUIRED: nombre del receptor y firma obligatorios', 'EVIDENCE_REQUIRED', 400);
      // contrato VIGENTE (migración cristian_email_dni_required): CUIL + DNI + email obligatorios solo para Cristian.
      // contrato V4.17-PROPUESTA: los mismos controles para TODA entrega comercial (externo e interno). Sucursal/TAREA: sin ellos.
      var idReq = cristian || (demoContract() !== 'VIGENTE' && commercial);
      if (idReq) { cuil = String(ev.cuil || '').replace(/\D/g, ''); if (cuil.length !== 11) throw err('CUIL_INVALID: el CUIL debe tener 11 dígitos', 'CUIL_INVALID', 400); }
      else { cuil = String(ev.cuil || '').replace(/\D/g, '') || null; if (cuil && cuil.length !== 11) throw err('CUIL_INVALID: el CUIL debe tener 11 dígitos', 'CUIL_INVALID', 400); }
      // RC4.1: email del receptor (segunda pantalla), opcional; si viene debe ser válido
      var vEmail = String(ev.email || '').trim().toLowerCase() || null;
      if (idReq && !vEmail) throw err('EMAIL_REQUIRED: el email del receptor es obligatorio', 'EMAIL_REQUIRED', 400);
      if (vEmail && !(/^[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}$/i.test(vEmail) && vEmail.length <= 254)) throw err('EMAIL_INVALID: el email no es válido', 'EMAIL_INVALID', 400);
      var vDni = String(ev.dni || '').replace(/\D/g, '') || (cuil ? cuil.slice(2, 10) : null);
      if (vDni && !/^[0-9]{7,8}$/.test(vDni)) throw err('DNI_INVALID: el DNI debe tener 7 u 8 dígitos', 'DNI_INVALID', 400);
      if (ev.dni_photo_b64) throw err('DNI_STORAGE_REQUIRED: la foto del DNI se sube a Storage privado', 'DNI_STORAGE_REQUIRED', 400);
      if ((cristian || (demoContract() !== 'VIGENTE' && commercial && cuil)) && ev.dni_storage_path) { const o = (this.db.storage || {})[ev.dni_storage_path];
        if (!new RegExp('^' + cuil + '/[0-9a-f-]{36}\\.(jpg|png)$').test(ev.dni_storage_path) || !o || o.owner !== me.id) throw err('DNI_UPLOAD_INVALID', 'DNI_UPLOAD_INVALID', 400); }
      // DNI_REQUIRED: la identidad tiene que quedar con DNI registrado (foto subida ahora o identidad ya registrada que se reutiliza)
      if (idReq && !(((this.db.identity || {})[cuil] || {}).storage_path || ev.dni_storage_path)) throw err('DNI_REQUIRED: cargá la foto del DNI para el CUIL nuevo', 'DNI_REQUIRED', 400);
    }
    const contract = demoContract(), colGiven = !!(col && col.status && col.status !== 'PENDIENTE');
    if (commercial && ['COBRANZA', 'AMBAS'].includes(st.task) && (contract === 'VIGENTE' || colGiven)) {   // propuesta: solo se valida si se informa
      if (!colGiven) throw err('COLLECTION_REQUIRED: indicá el resultado de la cobranza', 'COLLECTION_REQUIRED', 400);
      if (['COBRO_PARCIAL', 'NO_COBRADO'].includes(col.status) && !String(col.note || '').trim()) throw err('COLLECTION_NOTE_REQUIRED: cobro parcial exige observación y no cobrado exige motivo', 'COLLECTION_NOTE_REQUIRED', 400);
      if (['COBRADO', 'COBRO_PARCIAL'].includes(col.status) && !(Number(col.amount) > 0)) throw err('Indicá el importe cobrado.', 'COLLECTION_AMOUNT_REQUIRED', 400);
    }
    const loc = this._loc(extra && extra.location, st);
    Object.assign(st, { outcome, outcome_at: new Date().toISOString(), outcome_by: me.id, outcome_note: note || null, outcome_reason: reason || null, finish_location: loc });
    if (['COBRANZA', 'AMBAS'].includes(st.task) && colGiven) Object.assign(st, { collection_status: col.status, collected_amount: col.amount != null ? Number(col.amount) : null, payment_mode: col.mode || null, collection_note: col.note || null });
    if (['ENTREGADO', 'ENTREGA_PARCIAL'].includes(outcome) && !commercial) {
      // TAREA / traslado interno: nunca email, Recibido Conforme, identidad ni cobranza. La recepción interna queda con su evidencia PROPIA.
      if (ev.signature_png_b64) { st.receiver_name = String(ev.receiver_name || '').trim() || null; this.db.evidence = this.db.evidence || {};
        if (!this.db.evidence[st.id]) this.db.evidence[st.id] = { receiver_name: st.receiver_name || 'Sin receptor (tarea)', signature_png_b64: ev.signature_png_b64, created_by: me.id, at: new Date().toISOString(),
          evidence_kind: type === 'UBICACION_INTERNA' ? 'RECEPCION_INTERNA' : 'TAREA', receiver_email: null, client_key: st.client_key || null }; }
      if (type === 'UBICACION_INTERNA') this._audit(me, 'INTERNAL_TRANSFER_RECEIVED', st.id, null, { route_id: r.id, route_number: r.number, internal_location_key: st.internal_location_key, location_name: st.client_name,
        address: st.address, order_numbers: st.order_numbers, outcome, receiver_name: st.receiver_name, transported_by: me.id, at: new Date().toISOString(), gps: loc });
    } else if (['ENTREGADO', 'ENTREGA_PARCIAL'].includes(outcome)) {
      st.receiver_name = String(ev.receiver_name).trim(); // el nombre sí; firma y CUIL/DNI solo en evidencia privada
      this.db.evidence = this.db.evidence || {};
      if (!this.db.evidence[st.id]) this.db.evidence[st.id] = { evidence_kind: 'ENTREGA_CLIENTE', receiver_name: st.receiver_name, signature_png_b64: ev.signature_png_b64, cuil, created_by: me.id, at: new Date().toISOString(), receiver_email: vEmail, receiver_dni: vDni, client_key: st.client_key || null };
      this.db.identity = this.db.identity || {};
      if ((cristian || (contract !== 'VIGENTE' && commercial && cuil)) && ev.dni_storage_path) { const id0 = this.db.identity[cuil]; if (!id0 || !id0.storage_path) this.db.identity[cuil] = Object.assign(id0 || {}, { storage_path: ev.dni_storage_path, mime: this.db.storage[ev.dni_storage_path].mime, registered_by: me.id, registered_at: new Date().toISOString() }); }
      // Perfil reutilizable (misma capa de identidad): nombre, DNI, email y cliente
      if (cuil) { const p0 = this.db.identity[cuil] = this.db.identity[cuil] || { registered_by: me.id, registered_at: new Date().toISOString() };
        if (vEmail && vEmail !== p0.email) Object.assign(p0, { email: vEmail, email_updated_at: new Date().toISOString(), email_updated_by: me.id });
        Object.assign(p0, { full_name: st.receiver_name || p0.full_name, dni: vDni || p0.dni, client_key: st.client_key || p0.client_key, updated_at: new Date().toISOString() }); }
      // Recibido Conforme: entrega total + email válido → comprobante único + envío (la falla del email nunca revierte la entrega)
      let receipt = false;
      if (outcome === 'ENTREGADO' && vEmail) {
        this.db.receipts = this.db.receipts || {};
        if (!this.db.receipts[st.id]) { const num = 'RC-' + r.number + '-' + String(st.seq || 0).padStart(3, '0');
          this.db.receipts[st.id] = { stop_id: st.id, route_id: r.id, receipt_number: num, recipient_email: vEmail, generated_by: me.id, generated_at: new Date().toISOString(),
            snapshot: { receipt_number: num, route_number: r.number, client_name: st.client_name, order_numbers: st.order_numbers, receiver_name: st.receiver_name, delivered_at: new Date().toISOString(), carrier_id: r.carrier_id } }; }
        this._queueCustomer(r, st, 'RECIBIDO_CONFORME', vEmail); receipt = true;
      }
      if (st.customer_email && !receipt) this._queueCustomer(r, st, outcome === 'ENTREGADO' ? 'DELIVERED' : 'PARTIAL');
    }
    if (opId) this.db.ops[opId] = stopId;
    this._onTheWay(r); this._save(); await this.sendCustomerQueued(); return st;
  }
  async addInternalStop(id, stop, version, opId, offline) {
    this._net(); this._refresh(); const { r, me } = this._mine(id);
    if ((r.events || []).some(e => e.client_op_id === opId)) return r; // reintento offline
    if (r.carrier_id !== 'INTERNO') throw err('Solo en rutas internas.', 'NOT_INTERNAL', 409);
    if (r.operational_status !== 'EN_CURSO') throw err('La hoja no está en curso.', 'BAD_STATE', 409);
    if (version !== r.version) throw err('VERSION_CONFLICT: la hoja cambió (versión ' + r.version + ')', 'VERSION_CONFLICT', 409);
    // TAREA libre o UBICACIÓN INTERNA G2 existente (segunda visita incluida), como el servidor
    const vType = stop.stop_type === 'UBICACION_INTERNA' ? 'UBICACION_INTERNA' : 'TAREA', vKey = vType === 'UBICACION_INTERNA' ? String(stop.internal_location_key || '').trim().toUpperCase() : null;
    const g2 = vKey ? (this.db.internalLocations || []).find(l => l.location_key === vKey && l.active !== false) : null;
    if (vType === 'UBICACION_INTERNA' && !vKey) throw err('INTERNAL_LOCATION_REQUIRED: elegí la ubicación interna', 'INTERNAL_LOCATION_REQUIRED', 400);
    if (vType === 'UBICACION_INTERNA' && !g2) throw err('INTERNAL_LOCATION_INACTIVE: ' + vKey + ' no existe o está desactivada en G2', 'INTERNAL_LOCATION_INACTIVE', 409);
    if (vType === 'TAREA' && !String(stop.client_name || '').trim()) throw err('Indicá el destino.', 'NAME_REQUIRED', 400);
    const maxSeq = Math.max(...r.stops.map(s => s.seq)), maxN = Math.max(...r.stops.map(s => s.sequence_number));
    const st = { id: stop.id || 'st-' + (++this.db.seq) + '-d', seq: maxSeq + 1, sequence_number: maxN + 1, provenance: 'DRIVER', client_name: stop.client_name, address: stop.address || '', action: stop.action || 'ENTREGA',
      bultos: stop.bultos ? Number(stop.bultos) : null, order_numbers: [], outcome: 'PENDIENTE', added_by: me.id, added_at: new Date().toISOString(), shipping_fee: 0, merchandise_amount: 0,
      // como el servidor: TAREA operativa futura, sin pedidos ni ubicación G2 aunque el celular mande otra cosa
      stop_type: vType, instructions: String(stop.instructions || '').trim() || null,
      contact_name: vType === 'TAREA' ? String(stop.contact_name || '').trim() || null : null, contact_phone: vType === 'TAREA' ? String(stop.contact_phone || '').trim() || null : null,
      internal_location_key: g2 ? g2.location_key : null, expected_lat: g2 ? g2.lat : null, expected_lon: g2 ? g2.lon : null, expected_radius_m: g2 ? g2.radius_m : null,
      internal_location_updated_at: g2 ? g2.updated_at || null : null, customer_email: null, task: 'ENTREGA' };
    if (g2) { st.client_name = g2.name; st.address = g2.address || ''; st.client_key = g2.location_key; }   // de G2, solo lectura
    r.stops.push(st); r.version++; r.events = r.events || [];
    r.events.push({ type: 'INTERNAL_STOP_ADDED', stop_id: st.id, version: r.version, user_id: me.id, at: new Date().toISOString(), client_op_id: opId, offline: !!offline, after: stop });
    this._onTheWay(r); this._audit(me, 'INTERNAL_STOP_ADDED', r.id, null, stop); this._save(); return r;
  }
  async reorderInternalStops(id, order, version, opId, offline) {
    this._net(); this._refresh(); const { r, me } = this._mine(id);
    if ((r.events || []).some(e => e.client_op_id === opId)) return r;
    if (r.carrier_id !== 'INTERNO') throw err('Solo en rutas internas.', 'NOT_INTERNAL', 409);
    if (r.operational_status !== 'EN_CURSO') throw err('La hoja no está en curso.', 'BAD_STATE', 409);
    if (version !== r.version) throw err('VERSION_CONFLICT: la hoja cambió (versión ' + r.version + ')', 'VERSION_CONFLICT', 409);
    const e = reorderError(r.stops, order); if (e) throw err(e, e, 409);
    const before = r.stops.filter(s => order.includes(s.id)).sort((a, b) => a.sequence_number - b.sequence_number).map(s => s.id);
    applyReorder(r.stops, order); r.version++;
    r.events.push({ type: 'INTERNAL_STOP_REORDERED', version: r.version, user_id: me.id, at: new Date().toISOString(), client_op_id: opId, offline: !!offline, before, after: order });
    this._onTheWay(r); this._audit(me, 'INTERNAL_STOP_REORDERED', r.id, before, order); this._save(); return r;
  }
  _notif(userId, r, type, title, body) {
    this.db.notifs = this.db.notifs || [];
    if (!this.db.notifs.some(x => x.user_id === userId && x.route_id === r.id && x.type === type && x.version === r.version))
      this.db.notifs.push({ id: 'nt-' + (++this.db.seq), user_id: userId, route_id: r.id, version: r.version, type, title, body, created_at: new Date().toISOString(), read_at: null });
  }
  _queueEmails(r, kind, list) {
    const J = this.db.emailJobs = this.db.emailJobs || [];
    list.forEach(e => { const key = r.id + '|' + r.version + '|' + kind + '|' + e; if (!J.some(j => j.idempotency_key === key)) J.push({ id: 'ej-' + (++this.db.seq), route_id: r.id, route_version: r.version, kind, recipient: e, idempotency_key: key, status: 'QUEUED', retry_count: 0, queued_at: new Date().toISOString() }); });
  }
  _irSettings() { return this.db.irSettings = this.db.irSettings || { supervisor_user_id: null, copy_admin: true, extra_emails: [], email_enabled: true, push_enabled: false }; }
  async finalizeRoute(id, kmEnd) {
    this._net(); this._refresh(); const { r, me } = this._mine(id);
    if (r.operational_status === 'COMPLETADA') return r;
    if (r.operational_status !== 'EN_CURSO') throw err('La hoja no está en curso.', 'BAD_STATE', 409);
    const pend = r.stops.filter(s => s.outcome === 'PENDIENTE').length;
    if (pend) throw err('Faltan ' + pend + ' entregas por resolver.', 'PENDING_STOPS', 409);
    if (r.vehicle_id) {
      const v = this.db.vehicles.find(x => x.id === r.vehicle_id);
      if (kmEnd == null || kmEnd === '') throw err('KM_REQUIRED: cargá el kilometraje final', 'KM_REQUIRED', 400);
      if (Number(kmEnd) < v.current_km) throw err('KM_LOWER: el kilometraje no puede bajar (último ' + v.current_km + ')', 'KM_LOWER', 400);
      if (r.km_start != null && Number(kmEnd) < r.km_start) throw err('KM_LOWER: el km final no puede ser menor al inicial', 'KM_LOWER', 400);
      v.current_km = Number(kmEnd); r.km_end = Number(kmEnd); r.km_ended_at = new Date().toISOString(); this._serviceCheck(v); this._checkTripRange(r);
    }
    const summary = {}; r.stops.forEach(s => { summary[s.outcome] = (summary[s.outcome] || 0) + 1; });
    const mods = (r.events || []).length;
    Object.assign(r, { operational_status: 'COMPLETADA', completed_at: new Date().toISOString(), completed_by: me.id, final_summary: summary, approval_status: mods ? 'PENDIENTE' : 'NO_REQUERIDA' });
    if (mods) { // COMPLETADA · PENDIENTE DE APROBACIÓN: una solicitud, avisos y emails (no bloquea al chofer)
      const st = this._irSettings(), rc = approvalRecipients({ driver: me, users: this.db.users, settings: st });
      const sup = rc.supervisor && hasPerm(rc.supervisor, 'can_approve_internal_route_changes') ? rc.supervisor : null;
      this.db.approvals = this.db.approvals || [];
      if (!this.db.approvals.some(a => a.route_id === r.id && a.route_version === r.version))
        this.db.approvals.push({ id: 'ap-' + (++this.db.seq), route_id: r.id, route_version: r.version, requested_by: me.id, supervisor_user_id: sup && sup.id, supervisor_missing: !sup, modification_count: mods, status: 'PENDING', requested_at: new Date().toISOString() });
      (sup ? [sup] : this.db.users.filter(u => u.role === 'ADMIN' && u.status === 'ACTIVO')).forEach(u => this._notif(u.id, r, sup ? 'INTERNAL_ROUTE_APPROVAL_REQUEST' : 'INTERNAL_ROUTE_NO_SUPERVISOR', 'HOJA ' + r.number + ' PENDIENTE DE APROBACIÓN', mods + ' cambio(s) del chofer'));
      if (st.email_enabled !== false) this._queueEmails(r, 'INTERNAL_ROUTE_APPROVAL_REQUEST', rc.emails);
    }
    this._audit(me, 'ROUTE_FINALIZED', r.id, null, { ...summary, modifications: mods }); this._save();
    if (mods) await this.sendQueuedApprovalEmails();
    return r;
  }
  // ===== Aprobaciones de rutas internas =====
  async pendingApprovals() {
    this._refresh(); const me = await this.me();
    if (!hasPerm(me, 'can_approve_internal_route_changes')) throw err('Sin permiso.', 'FORBIDDEN', 403);
    return (this.db.approvals || []).filter(a => a.status === 'PENDING').map(a => { const r = this.db.routes2.find(x => x.id === a.route_id);
      return { ...a, route: JSON.parse(JSON.stringify(r)), driver_name: (this._user(r.responsable_id) || {}).full_name, diff: routeDiff(r) }; });
  }
  async reviewApproval(id, decision, note) {
    this._refresh(); const me = await this.me();
    if (!hasPerm(me, 'can_approve_internal_route_changes')) throw err('FORBIDDEN', 'FORBIDDEN', 403);
    const a = (this.db.approvals || []).find(x => x.id === id); if (!a) throw err('No existe.', 'NOT_FOUND', 404);
    if (a.status !== 'PENDING') throw err('La solicitud ya fue resuelta.', 'NOT_PENDING', 409);
    if (a.supervisor_user_id && a.supervisor_user_id !== me.id && !hasPerm(me, 'users.manage')) throw err('La revisa el superior asignado o Administración.', 'FORBIDDEN', 403);
    if (decision === 'OBSERVED' && !String(note || '').trim()) throw err('Para solicitar aclaración hay que indicar el motivo.', 'NOTE_REQUIRED', 400);
    Object.assign(a, { status: decision, reviewed_by: me.id, reviewed_at: new Date().toISOString(), review_note: note || null });
    const rr = this.db.routes2.find(x => x.id === a.route_id); rr.reviewed_at = a.reviewed_at;
    const r = this.db.routes2.find(x => x.id === a.route_id); r.approval_status = decision === 'APPROVED' ? 'APROBADA' : 'OBSERVADA'; r.review_note = note || null;
    this._audit(me, decision === 'APPROVED' ? 'INTERNAL_ROUTE_APPROVED' : 'INTERNAL_ROUTE_OBSERVED', r.id, null, { note });
    if (decision === 'APPROVED') this._notif(r.responsable_id, r, 'INTERNAL_ROUTE_APPROVED', 'HOJA APROBADA · ' + r.number, 'Tu hoja fue aprobada.');
    if (decision === 'OBSERVED') { this._notif(r.responsable_id, r, 'INTERNAL_ROUTE_OBSERVED', 'ACLARACIÓN SOLICITADA · HOJA ' + r.number, note); this._queueEmails(r, 'INTERNAL_ROUTE_OBSERVED', [this._user(r.responsable_id).email]); }
    this._save(); await this.sendQueuedApprovalEmails();
  }
  // Cola de emails (mismo servicio que la Edge Function internal-approvals). Una falla no revierte la hoja.
  async sendQueuedApprovalEmails(onlyIds) {
    this.db.outboxIR = this.db.outboxIR || [];
    const store = { listJobs: async q => (this.db.emailJobs || []).filter(j => q.statuses.includes(j.status) && (!q.ids || q.ids.includes(j.id))),
      routeFor: async j => this.db.routes2.find(r => r.id === j.route_id), driverName: async r => (this._user(r.responsable_id) || {}).full_name, updateJob: async (id, p) => Object.assign(this.db.emailJobs.find(j => j.id === id), p) };
    const provider = { send: async m => { if (typeof window !== 'undefined' && window.OKD_MAIL_FAIL) throw new Error('Proveedor de email caído (simulado)'); this.db.outboxIR.push({ to: m.to, subject: m.subject, html: m.html, at: new Date().toISOString() }); return { id: 'demo-' + this.db.outboxIR.length }; } };
    const out = await sendQueuedEmails({ store, provider, appUrl: typeof location !== 'undefined' ? location.origin : '', onlyIds });
    this._save(); return out;
  }
  async customerEmailJobs() { this._refresh(); return (this.db.customerJobs || []).slice(); }
  async approvalEmailJobs() { this._refresh(); return (this.db.emailJobs || []).slice(); }
  async irSettings() { this._refresh(); return { ...this._irSettings() }; }
  async setIrSettings(s) {
    this._refresh(); const me = await this.me(); if (!hasPerm(me, 'settings.manage')) throw err('Sin permiso.', 'FORBIDDEN', 403);
    if ((s.extra_emails || []).some(e => !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(e))) throw err('Hay un email adicional inválido.', 'BAD_EMAIL', 400);
    Object.assign(this._irSettings(), s); this._audit(me, 'INTERNAL_ROUTE_NOTIF_SETTINGS', null, null, s); this._save();
  }
  myNotifications() { const me = this._user(this.session && this.session.userId); return me ? (this.db.notifs || []).filter(n => n.user_id === me.id) : []; }

  // ===== Vehículos =====
  async listVehicles() { this._refresh(); return (this.db.vehicles || []).map(v => ({ ...v, km_since_service: v.current_km - v.last_service_km, service_due: v.current_km - v.last_service_km >= v.service_interval_km })); }
  async upsertVehicle(p) {
    this._refresh(); const me = await this.me(); if (!hasPerm(me, 'vehicles.manage')) throw err('Sin permiso.', 'FORBIDDEN', 403);
    const V = this.db.vehicles = this.db.vehicles || []; const plate = String(p.plate || '').toUpperCase().trim();
    if (!p.name || !plate) throw err('Nombre y patente obligatorios.', 'BAD_VEHICLE', 400);
    if (V.some(v => v.plate === plate && v.id !== p.id)) throw err('Ya existe esa patente.', 'DUPLICATE', 409);
    let v = V.find(x => x.id === p.id);
    if (!v) { v = { id: 'vh-' + (++this.db.seq), current_km: Number(p.current_km) || 0, last_service_km: Number(p.last_service_km ?? p.current_km) || 0, last_service_date: null }; V.push(v); }
    Object.assign(v, { name: p.name, plate, active: p.active !== false, brand: p.brand || '', model: p.model || '', type: p.type || '', year: p.year || null, notes: p.notes || '', service_interval_km: Number(p.service_interval_km) || 10000 });
    this._audit(me, 'VEHICLE_SAVED', v.id, null, { plate }); this._save(); return v;
  }
  async correctVehicleKm(id, km, reason) {
    this._refresh(); const me = await this.me(); if (!hasPerm(me, 'vehicles.manage') && !hasPerm(me, 'vehicle_mileage.edit')) throw err('Sin permiso.', 'FORBIDDEN', 403);
    if (!String(reason || '').trim()) throw err('Indicá el motivo de la corrección.', 'REASON_REQUIRED', 400);
    const v = this.db.vehicles.find(x => x.id === id); const before = v.current_km; v.current_km = Number(km);
    this._audit(me, 'VEHICLE_KM_CORRECTED', id, { km: before }, { km: Number(km), reason }); this._save();
  }
  async registerService(id, km, date) {
    this._refresh(); const me = await this.me(); if (!hasPerm(me, 'vehicles.manage')) throw err('Sin permiso.', 'FORBIDDEN', 403);
    const v = this.db.vehicles.find(x => x.id === id); Object.assign(v, { last_service_km: Number(km), last_service_date: date, current_km: Math.max(v.current_km, Number(km)) });
    this._audit(me, 'VEHICLE_SERVICE_REGISTERED', id, null, { km, date }); this._save();
  }
  // ===== Devolver hoja (solicitud, hasta 2 días calendario en Mendoza) =====
  async requestRouteReturn(id, reason) {
    this._net(); this._refresh(); const { r, me } = this._mine(id);
    if (r.operational_status !== 'COMPLETADA') throw err('Solo hojas finalizadas.', 'BAD_STATE', 409);
    if (!String(reason || '').trim()) throw err('Indicá el motivo.', 'REASON_REQUIRED', 400);
    const day = iso => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Argentina/Mendoza' }).format(new Date(iso));
    if ((Date.parse(day(new Date().toISOString())) - Date.parse(day(r.completed_at))) / 86400000 > 2) throw err('Pasaron más de 2 días desde el cierre.', 'RETURN_EXPIRED', 409);
    const RR = this.db.returns = this.db.returns || [];
    const cur = RR.find(x => x.route_id === id && x.status === 'PENDING'); if (cur) return cur;
    const q = { id: 'rr-' + (++this.db.seq), route_id: id, route_number: r.number, requested_by: me.id, reason: reason.trim(), status: 'PENDING', created_at: new Date().toISOString() };
    RR.push(q); this._audit(me, 'ROUTE_RETURN_REQUESTED', id, null, { reason }); this._save(); return q;
  }
  async returnRequests() { this._refresh(); return (this.db.returns || []).slice(); }
  async resolveReturn(id, decision, note) {
    this._refresh(); const me = await this.me(); if (!hasPerm(me, 'routes.manage_all_drafts')) throw err('Sin permiso.', 'FORBIDDEN', 403);
    if (!String(note || '').trim()) throw err('Indicá la resolución.', 'NOTE_REQUIRED', 400);
    const q = (this.db.returns || []).find(x => x.id === id && x.status === 'PENDING'); if (!q) throw err('La solicitud ya fue resuelta.', 'NOT_PENDING', 409);
    Object.assign(q, { status: decision, resolved_by: me.id, resolved_at: new Date().toISOString(), resolution_note: note }); this._audit(me, 'ROUTE_RETURN_' + decision, id, null, { note }); this._save();
  }
  // ===== Cancelar hoja activa (Administración): libera los pedidos; el correlativo no se reutiliza =====
  async activeRoutes() { this._refresh(); return (this.db.routes2 || []).filter(r => ['PUBLICADA', 'EN_CURSO'].includes(r.operational_status)).map(r => ({ id: r.id, number: r.number, carrier_name: r.carrier_name, responsable_name: r.responsable_name, operational_status: r.operational_status })); }
  async cancelRoute(id, reason) {
    this._refresh(); const me = await this.me(); if (!hasPerm(me, 'routes.manage_all_drafts') && !hasPerm(me, 'routes.cancel')) throw err('Sin permiso.', 'FORBIDDEN', 403);
    if (!String(reason || '').trim()) throw err('Indicá el motivo.', 'REASON_REQUIRED', 400);
    const r = this.db.routes2.find(x => x.id === id && ['PUBLICADA', 'EN_CURSO'].includes(x.operational_status)); if (!r) throw err('Solo hojas publicadas o en curso.', 'BAD_STATE', 409);
    { const any0 = this.db.routes2.find(x => x.id === id); if (any0) this._routeScope(me, any0); }   // RC4.1: fuera de alcance → FORBIDDEN_ROUTE
    r.operational_status = 'CANCELADA'; Object.values(this.db.drafts || {}).filter(d => d.route_id === id).forEach(d => { d.status = 'CANCELADA'; });
    // RC3: cancelar ≠ revertir NOC. Importes intactos; las aplicaciones consumidas quedan en revisión administrativa
    (this.db.nocApps || []).filter(a => a.route_id === id && a.status === 'CONSUMED').forEach(a => {
      Object.assign(a, { reconciliation_status: 'CANCELLED_ROUTE_REVIEW', cancelled_route_id: id, cancelled_route_number: r.number, cancelled_by: me.id, cancelled_at: new Date().toISOString(), cancel_reason: reason, resolution: null });
      this._nocEvent(a.fingerprint, 'HOJA_CANCELADA_REVISION', a.amount, { route_id: id, reference: 'hoja ' + r.number, reason, order_numbers: a.order_numbers, application: a.id }, me);
      this._nocAggregate(a.fingerprint); const n = this.db.nocs[a.fingerprint]; n.recon_version = (n.recon_version || 1) + 1;
    });
    Object.keys(this.db.reservations || {}).forEach(o => { if (this.db.reservations[o].route_id === id) delete this.db.reservations[o]; });
    this._notif(r.responsable_id, r, 'ROUTE_CANCELLED', 'HOJA ' + r.number + ' CANCELADA', reason); this._audit(me, 'ROUTE_CANCELLED', id, null, { reason, number: r.number }); this._save(); return r;
  }

  // ===== Passkeys (demo): ceremonia WebAuthn real del navegador; verificación con WebCrypto (webauthn-verify.js) =====
  async passkeyRegisterOptions() { const me = await this.me(); if (!me) throw err('Iniciá sesión.', 'NO_AUTH', 401); const ch = crypto.getRandomValues(new Uint8Array(32)); this._pkChallenge = { b64: btoa(String.fromCharCode(...ch)), user: me.id, kind: 'REGISTER' };
    return { challenge: ch, rp: { id: location.hostname, name: 'OK Despacho' }, user: { id: new TextEncoder().encode(me.id), name: me.email, displayName: me.full_name },
      excludeCredentials: (this.db.passkeys || []).filter(p => p.user_id === me.id && !p.revoked_at).map(p => p.credential_id) }; }
  async passkeyRegisterSave(rec) {
    const me = await this.me(); if (!me || !this._pkChallenge || this._pkChallenge.kind !== 'REGISTER' || this._pkChallenge.user !== me.id) throw err('El pedido de registro venció.', 'BAD_CHALLENGE', 400);
    this._pkChallenge = null; this._refresh(); this.db.passkeys = this.db.passkeys || [];
    const p = { id: 'pk-' + (++this.db.seq), user_id: me.id, credential_id: rec.credential_id, public_key: rec.public_key, alg: rec.alg, sign_count: 0, device_name: rec.device_name, created_at: new Date().toISOString(), last_used_at: null, revoked_at: null };
    this.db.passkeys.push(p); this._audit(me, 'PASSKEY_REGISTERED', p.id); this._save(); return p;
  }
  async myPasskeys() { this._refresh(); const me = await this.me(); return (this.db.passkeys || []).filter(p => p.user_id === me.id).map(({ public_key, ...x }) => x); }
  async revokePasskey(id) { this._refresh(); const me = await this.me(); const p = (this.db.passkeys || []).find(x => x.id === id && (x.user_id === me.id || hasPerm(me, 'users.manage'))); if (!p) throw err('FORBIDDEN', 'FORBIDDEN', 403); p.revoked_at = p.revoked_at || new Date().toISOString(); this._audit(me, 'PASSKEY_REVOKED', id); this._save(); }
  passkeyLoginOptions() { const ch = crypto.getRandomValues(new Uint8Array(32)); this._pkLogin = btoa(String.fromCharCode(...ch)); return { challenge: ch, rpId: location.hostname }; }
  async passkeyLogin(assertion, verify) {
    this._refresh();
    const ch = this._pkLogin; this._pkLogin = null; if (!ch) throw err('El pedido de ingreso venció.', 'BAD_CHALLENGE', 400);
    const p = (this.db.passkeys || []).find(x => x.credential_id === assertion.credential_id);
    if (!p || p.revoked_at) throw err('Este acceso rápido no está activo. Usá tu contraseña.', 'REVOKED', 401);
    const u = this._user(p.user_id);
    if (!u || u.status !== 'ACTIVO') throw err('Usuario sin acceso. Consultá con Administración.', 'NO_ACCESS', 403);
    const v = await verify({ assertion, publicKey: p.public_key, alg: p.alg, expectedChallenge: ch, origin: location.origin, rpId: location.hostname, signCount: p.sign_count });
    if (!v.verified) throw err('No se pudo verificar el dispositivo.', 'BAD_SIGNATURE', 401);
    p.sign_count = v.signCount; p.last_used_at = new Date().toISOString();
    u.last_sign_in_at = new Date().toISOString();
    this.session = { userId: u.id, epoch: u.session_epoch || 0 }; this._set('session', this.session);
    this._audit(u, 'PASSKEY_LOGIN', p.id); this._save(); return { userId: u.id };
  }

  // En vivo (demo): cambios de otra pestaña llegan por el evento "storage"; además un sondeo liviano por si se pierde un evento
  subscribe(cb) {
    if (typeof window === 'undefined') return () => {};
    const h = e => { if (e.key === KEY) { this._refresh(); cb(); } };
    window.addEventListener('storage', h); const t = setInterval(() => { this._refresh(); cb(); }, 5000);
    return () => { window.removeEventListener('storage', h); clearInterval(t); };
  }
  // Hojas reales finalizadas de Cristian → informe
  _liveForReport() {
    this._refresh();
    // igual que el servidor (V2): hojas de Cristian (report_group CRISTIAN_TORRES) con su fecha de PUBLICACIÓN; si falta, el registro
    // histórico ROUTE_PUBLISHED de la auditoría. El motor excluye borradores/canceladas y filtra por publicación.
    const ct = new Set(this._carriers().filter(c => c.report_group === 'CRISTIAN_TORRES').map(c => c.id));
    const hist = id => { const a = (this.db.audit || []).filter(x => x.action === 'ROUTE_PUBLISHED' && x.target_id === id).map(x => x.at).sort()[0]; return a || null; };
    return (this.db.routes2 || []).filter(r => ct.has(r.carrier_id)).map(r => ({ id: r.id, number: r.number, carrier_id: r.carrier_id, operational_status: r.operational_status,
      published_at: r.published_at || null, dispatched_at: r.dispatched_at || null, dispatch_mode: r.dispatch_mode || null, completed_at: r.completed_at, version: r.version || 1,
      published_at_hist: r.published_at ? null : hist(r.id),
      stops: r.stops.map(s => ({ id: s.id, seq: s.seq, order_numbers: (s.order_numbers || []).map(String), stop_type: s.stop_type || 'PEDIDO', client_name: s.client_name, client_key: s.client_key, zone: s.zone, outcome: s.outcome, shipping_fee: s.shipping_fee, shipping_fee_source: s.shipping_fee_source, merchandise_amount: s.merchandise_amount })) }));
  }

  // Confirmación de envío provisorio (equivale a confirm_shipping_amount del servidor)
  async shippingConfirm(p) {
    const me = await this.me();
    if (!hasPerm(me, 'routes.create')) throw err('No tenés permiso para confirmar envíos.', 'FORBIDDEN', 403);
    this._refresh(); this._draft(p.sheet_key, me, true);
    if (!(p.confirmed_amount > 0)) throw err('Importe inválido.', 'BAD_AMOUNT', 400);
    const changed = Math.abs(p.confirmed_amount - p.detected_amount) > 0.004;
    if (changed && !String(p.reason || '').trim()) throw err('Para cambiar el importe indicá el motivo.', 'REASON_REQUIRED', 400);
    this.db.shipping = this.db.shipping || [];
    const cur = this.db.shipping.find(x => x.sheet_key === p.sheet_key && x.ship_order === p.ship_order && x.status !== 'INVALIDATED');
    if (cur && cur.fingerprint === p.fingerprint && cur.confirmed_amount === p.confirmed_amount && cur.status !== 'PENDING_CONFIRMATION') return cur; // doble clic
    if (cur) cur.status = 'INVALIDATED';
    const rec = { id: 'sc-' + (++this.db.seq), ...p, source: 'INFORME_PEDIDOS', status: changed ? 'MODIFIED_CONFIRMED' : 'CONFIRMED', confirmed_by: me.id, confirmed_at: new Date().toISOString() };
    this.db.shipping.push(rec);
    this._audit(me, changed ? 'SHIPPING_AMOUNT_MODIFIED' : 'SHIPPING_AMOUNT_CONFIRMED', null, { amount: p.detected_amount }, { amount: p.confirmed_amount, reason: p.reason || null, ship_order: p.ship_order });
    this._save(); return rec;
  }
  async shippingInvalidate(p) {
    this._refresh(); const me = await this.me(); if (!this._draft(p.sheet_key, me, false)) return;
    (this.db.shipping || []).filter(x => x.sheet_key === p.sheet_key && x.ship_order === p.ship_order && x.status !== 'INVALIDATED' && x.fingerprint !== p.fingerprint).forEach(x => { x.status = 'INVALIDATED'; });
    this._save();
  }

  // ===== Informe comercial Cristian Torres (modo demo): usa la MISMA Edge Function con un store en el navegador =====
  // Los módulos del informe (incluye pdf-lib) se cargan recién cuando se abre INFORMES
  async _reports() {
    if (this._rep) return this._rep;
    const [{ handle: reportsHandle }, { createReportService }, { memoryStore }, { reportPdf }, { demoRoutes, DEMO_COSTS }, { localDate }] = await Promise.all([
      import('../../supabase/functions/commercial-reports/handler.js'), import('../../supabase/functions/_shared/report-service.js'),
      import('../../supabase/functions/_shared/report-memory-store.js'), import('../../supabase/functions/_shared/report-pdf.js'),
      import('../../supabase/functions/_shared/report-demo-data.js'), import('../../supabase/functions/_shared/report-engine.js')]);
    const store = memoryStore({ routes: demoRoutes({ to: localDate(Date.now()) }), costs: DEMO_COSTS, state: this._get('reports') || undefined, persist: st => this._set('reports', st) });
    store.state.outbox = store.state.outbox || [];
    const demo = store.routes; store.loadRoutes = async () => demo.concat(this._liveForReport()); // datos reales de hojas finalizadas
    const provider = { send: async m => { store.state.outbox.push({ to: m.to, subject: m.subject, html: m.html, attachment: m.attachments[0] && m.attachments[0].filename, at: new Date().toISOString() }); this._set('reports', store.state); return { id: 'demo-' + store.state.outbox.length }; } };
    const now = () => this._clock || Date.now();
    const service = createReportService({ store, pdfMaker: reportPdf, provider, now });
    const deps = { store, service, cronSecret: 'demo', now, getUserFromJwt: async t => t ? { id: t } : null, getProfile: async id => this._user(id) || null,
      audit: async e => { this.db.audit.push({ at: new Date().toISOString(), ...e }); this._save(); } };
    this._rep = { store, deps, handle: reportsHandle };
    return this._rep;
  }
  async _reportsCall(body, headers = {}) {
    const me = await this.me();
    const rep = await this._reports();
    const res = await rep.handle(new Request('https://demo.local/functions/v1/commercial-reports', { method: 'POST', headers: { 'content-type': 'application/json', ...(me ? { authorization: 'Bearer ' + me.id } : {}), ...headers }, body: JSON.stringify(body) }), rep.deps);
    const j = await res.json();
    if (!res.ok) throw err(j.error || 'Error', j.code, res.status);
    return j;
  }
  async reports(action, body = {}) { return this._reportsCall({ action, ...body }); }
  // Simula el cron (cada 15 min en producción) a una fecha/hora de Mendoza 'YYYY-MM-DDTHH:MM'
  async runScheduledAt(v) {
    await this._reports(); const { atLocal } = await import('../../supabase/functions/_shared/report-engine.js');
    this._clock = atLocal(v.slice(0, 10), v.slice(11, 16));
    try { return await this._reportsCall({ action: 'scheduled' }, { 'x-cron-secret': 'demo' }); } finally { this._clock = null; }
  }
  outbox() { return this._rep ? this._rep.store.state.outbox.slice() : []; }
  auditLog() { return this.db.audit.slice(); }
}

// RC2: borradores, historial, configuración, auditoría, backup y dashboard (mismas reglas que la base)
Object.assign(DemoApi.prototype, DemoAdmin);
Object.assign(DemoApi.prototype, DemoRC4);
