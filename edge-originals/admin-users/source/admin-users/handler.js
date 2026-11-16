// Edge Function "admin-users": administración de usuarios de OK Despacho (Fase 1.1).
// La lógica está separada del cliente de Supabase (deps) para poder probarla sin red.
// El service_role SOLO vive en el servidor (variables de entorno de la función).
// Auditoría: un evento de éxito se registra RECIÉN cuando la operación terminó bien.
import { validateUserAction, ROLES } from '../_shared/rules.js';

import { CORS, json } from '../_shared/http.js';
export { CORS, json };
const errMsg = e => String((e && e.message) || e);

/**
 * deps = {
 *   redirectTo                                         URL para invitaciones y recuperación
 *   getUserFromJwt(jwt) → { id } | null                verifica el token con Supabase Auth
 *   getProfile(id) → profile | null                    incluye carriers: []
 *   listProfiles() → [profile]
 *   hasHistory(id) → boolean                           rpc user_has_history
 *   activeRoutes(id) → [{ id, number, carrier_id, operational_status }]   rpc user_active_routes
 *   inviteUser(email, redirectTo) → { id }             auth.admin.inviteUserByEmail (crea usuario en Auth)
 *   resendInvite(email, redirectTo)                    reenvía la invitación del MISMO usuario
 *   deleteAuthUser(id)                                 auth.admin.deleteUser (compensación del alta)
 *   createProfileAtomic(profile, carriers)             rpc admin_create_profile (una transacción)
 *   updateProfileAtomic(id, fields)                    rpc admin_update_profile (una transacción)
 *   updateStatus(id, patch)                            estado (los triggers validan último admin y hojas activas)
 *   setCarriersAtomic(id, carriers)                    rpc set_user_carriers (una transacción)
 *   updateAuthEmail(id, email)                         auth.admin.updateUserById({ email, email_confirm: true })
 *   sendPasswordReset(email, redirectTo)               auth.resetPasswordForEmail: link al email del usuario
 *   revokeSessions(id)                                 rpc revoke_user_sessions
 *   reassignRoutes(from, to) → n                       rpc reassign_active_routes
 *   banUser(id), unbanUser(id)                         auth.admin.updateUserById ban_duration
 *   deleteProfileAndAuth(id)                           auth.admin.deleteUser (cascade al profile)
 *   audit(entry)
 *   userHasPerm(userId, perm) → boolean               rpc public.user_has_perm(p_user, p_perm): ÚNICA fuente de permisos
 *   configError                                        texto si faltan SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY
 * }
 */
export async function handle(req, deps) {
  if (req.method === 'OPTIONS') return new Response('ok', { status: 200, headers: CORS });
  if (req.method !== 'POST') return json(405, { error: 'Método no permitido', code: 'METHOD' });
  if (deps.configError) return json(500, { error: 'Función mal configurada: ' + deps.configError, code: 'CONFIG_ERROR' });
  try { return await handleInner(req, deps); }
  catch (e) { return json(500, { error: errMsg(e), code: 'SERVER_ERROR' }); } // nunca una excepción sin respuesta legible
}

async function handleInner(req, deps) {
  const auth = req.headers.get('authorization') || '';
  const jwt = auth.startsWith('Bearer ') ? auth.slice(7) : '';
  const who = jwt ? await deps.getUserFromJwt(jwt) : null;
  if (!who) return json(401, { error: 'Sesión inválida.', code: 'NO_AUTH' });
  const actor = await deps.getProfile(who.id);

  let body;
  try { body = await req.json(); } catch (e) { return json(400, { error: 'JSON inválido.', code: 'BAD_JSON' }); }
  const { action, user_id: targetId, ...payload } = body || {};
  const audit = (a, target_id, before, after) => deps.audit({ actor_id: actor ? actor.id : who.id, action: a, target_type: 'user', target_id, before, after });

  // Permisos: misma regla que la base (rol − módulos restringidos, usuario ACTIVO)
  const can = async perm => !!(actor && actor.status === 'ACTIVO' && await deps.userHasPerm(actor.id, perm));
  if (action === 'list') {
    if (!(await can('users.view'))) return json(403, { error: 'No tenés permiso para ver usuarios.', code: 'FORBIDDEN' });
    return json(200, { users: await deps.listProfiles() });
  }

  // El usuario invitado confirma su cuenta la primera vez que entra (crea su contraseña). Idempotente:
  // si ya está ACTIVO (por ejemplo, REINTENTAR ACTIVACIÓN), responde 200 con el usuario.
  if (action === 'accept_invite') {
    if (!actor) return json(404, { error: 'No se encontró tu perfil. Consultá con Administración.', code: 'NO_PROFILE' });
    if (actor.status === 'ACTIVO') return json(200, { user: actor, already: true });
    if (actor.status !== 'INVITACION_PENDIENTE') return json(403, { error: 'Usuario sin acceso. Consultá con Administración.', code: 'NO_ACCESS' });
    try { await deps.updateStatus(actor.id, { status: 'ACTIVO' }); }
    catch (e) { return json(500, { error: 'No se pudo activar tu usuario: ' + errMsg(e), code: 'ACCEPT_FAILED' }); }
    await audit('INVITE_ACCEPTED', actor.id, { status: actor.status }, { status: 'ACTIVO' });
    return json(200, { user: await deps.getProfile(actor.id) });
  }

  const allUsers = await deps.listProfiles();
  const target = targetId ? await deps.getProfile(targetId) : null;
  const hasHistory = action === 'delete' && target ? await deps.hasHistory(target.id) : false;
  const routes = target && ['disable', 'archive', 'delete'].includes(action) ? await deps.activeRoutes(target.id) : [];
  const err = validateUserAction(action, { actor, target, allUsers, hasHistory, activeRoutes: routes.length, payload, canManage: await can('users.manage') });
  if (err) return json(err.status, { error: err.message, code: err.code, ...(err.code === 'ACTIVE_ROUTES' ? { routes } : {}) });

  const now = new Date().toISOString();
  const before = target ? { full_name: target.full_name, email: target.email, phone: target.phone || null, role: target.role, status: target.status, carriers: target.carriers || [], supervisor_user_id: target.supervisor_user_id || null } : null;

  switch (action) {
    case 'create': {
      const role = payload.role;
      const carriers = role === 'TRANSPORTISTA_INTERNO' ? [] : (payload.carriers || []);
      const email = String(payload.email).trim().toLowerCase();
      let created;
      try { created = await deps.inviteUser(email, deps.redirectTo); }
      catch (e) { await audit('USER_CREATE_FAILED', null, null, { email, step: 'invite', error: errMsg(e) });
        if (/rate limit/i.test(errMsg(e))) return json(429, { error: 'Se alcanzó el límite de emails de Supabase. Configurá un SMTP propio (Authentication → SMTP) o esperá unos minutos.', code: 'EMAIL_RATE_LIMIT' });
        return json(502, { error: 'No se pudo enviar la invitación: ' + errMsg(e), code: 'INVITE_FAILED' }); }
      const profile = { id: created.id, full_name: String(payload.full_name).trim(), email, phone: payload.phone || null, role,
        status: payload.active === false ? 'DESHABILITADO' : 'INVITACION_PENDIENTE', created_by: actor.id };
      try {
        await deps.createProfileAtomic(profile, carriers);
        if (payload.active === false) await deps.banUser(created.id);
      } catch (e) {
        // Compensación: no dejar un usuario de Auth huérfano ni una invitación sin perfil.
        let cleanup = 'ok';
        try { await deps.deleteAuthUser(created.id); } catch (e2) { cleanup = 'FALLÓ: ' + errMsg(e2); }
        await audit('USER_CREATE_FAILED', created.id, null, { email, step: 'profile', error: errMsg(e), auth_cleanup: cleanup });
        return json(500, { error: 'No se creó el usuario: ' + errMsg(e), code: 'CREATE_FAILED' });
      }
      if (payload.disabled_modules && payload.disabled_modules.length) await deps.setDisabledModules(created.id, payload.disabled_modules);
      await audit('USER_CREATED', created.id, null, { role, status: profile.status, carriers, disabled_modules: payload.disabled_modules || [] });
      return json(200, { user: { ...profile, carriers } });
    }
    case 'edit':
    case 'set_role': {
      const role = payload.role || target.role;
      const carriers = role === 'TRANSPORTISTA_INTERNO' ? [] : (payload.carriers !== undefined ? payload.carriers : null);
      const newEmail = action === 'edit' && payload.email !== undefined ? String(payload.email).trim().toLowerCase() : target.email;
      const emailChanged = newEmail !== String(target.email).toLowerCase();
      const fields = {
        full_name: action === 'edit' && payload.full_name !== undefined ? String(payload.full_name).trim() : target.full_name,
        phone: action === 'edit' && payload.phone !== undefined ? (payload.phone || null) : (target.phone || null),
        email: newEmail, role, carriers,
        set_supervisor: action === 'edit' && payload.supervisor_user_id !== undefined, supervisor: payload.supervisor_user_id ?? null
      };
      // Email: primero Auth (es el que se usa para entrar); si después falla el perfil, se vuelve atrás Auth.
      if (emailChanged) {
        try { await deps.updateAuthEmail(target.id, newEmail); }
        catch (e) { return json(502, { error: 'No se pudo cambiar el email en Auth: ' + errMsg(e), code: 'AUTH_EMAIL_FAILED' }); }
      }
      try { await deps.updateProfileAtomic(target.id, fields); if (action === 'edit' && payload.disabled_modules !== undefined) await deps.setDisabledModules(target.id, payload.disabled_modules); }
      catch (e) {
        if (emailChanged) { try { await deps.updateAuthEmail(target.id, target.email); } catch (e2) { /* se informa abajo */ } }
        return json(409, { error: 'No se guardaron los cambios: ' + errMsg(e), code: /CARRIER_REQUIRED/.test(errMsg(e)) ? 'CARRIER_REQUIRED' : 'UPDATE_FAILED' });
      }
      const after = await deps.getProfile(target.id);
      await audit(action === 'set_role' ? 'USER_ROLE_CHANGED' : 'USER_UPDATED', target.id, before,
        { full_name: after.full_name, email: after.email, phone: after.phone || null, role: after.role, carriers: after.carriers || [], supervisor_user_id: after.supervisor_user_id || null, disabled_modules: after.disabled_modules || [] });
      return json(200, { user: after });
    }
    case 'set_carriers': {
      try { await deps.setCarriersAtomic(target.id, payload.carriers || []); }
      catch (e) { return json(409, { error: 'No se cambiaron los carriers (se conservan los anteriores): ' + errMsg(e), code: 'CARRIERS_FAILED' }); }
      await audit('USER_CARRIERS_CHANGED', target.id, before, { carriers: payload.carriers || [] });
      break;
    }
    case 'disable':
    case 'archive':
    case 'cancel_invite': {
      const status = action === 'archive' ? 'ARCHIVADO' : 'DESHABILITADO';
      try {
        await deps.updateStatus(target.id, action === 'archive' ? { status, archived_at: now } : { status });
        await deps.banUser(target.id);
        await deps.revokeSessions(target.id);
      } catch (e) {
        const m = errMsg(e);
        return json(409, { error: /ACTIVE_ROUTES/.test(m) ? 'ESTE USUARIO TIENE HOJAS ACTIVAS: reasignalas o resolvelas antes.' : 'No se pudo completar: ' + m, code: /ACTIVE_ROUTES/.test(m) ? 'ACTIVE_ROUTES' : 'STATUS_FAILED' });
      }
      await audit({ disable: 'USER_DISABLED', archive: 'USER_ARCHIVED', cancel_invite: 'INVITE_CANCELLED' }[action], target.id, before, { status, sessions_revoked: true });
      break;
    }
    case 'reactivate': {
      await deps.unbanUser(target.id);
      await deps.updateStatus(target.id, { status: 'ACTIVO', archived_at: null });
      await audit('USER_REACTIVATED', target.id, before, { status: 'ACTIVO' });
      break;
    }
    case 'reset_password': {
      // El Admin nunca ve ni define la contraseña: Supabase envía un link de recuperación al email del usuario.
      try { await deps.sendPasswordReset(target.email, deps.redirectTo); }
      catch (e) { await audit('PASSWORD_RESET_REQUESTED', target.id, null, { result: 'ERROR', error: errMsg(e) }); return json(502, { error: 'No se pudo enviar el link: ' + errMsg(e), code: 'RESET_FAILED' }); }
      await audit('PASSWORD_RESET_REQUESTED', target.id, null, { result: 'ENVIADO', email: target.email });
      return json(200, { ok: true, message: 'Se envió un link para restablecer la contraseña a ' + target.email + '.' });
    }
    case 'revoke_sessions': {
      let at;
      try { at = await deps.revokeSessions(target.id); }
      catch (e) { return json(500, { error: 'No se pudieron cerrar las sesiones: ' + errMsg(e), code: 'REVOKE_FAILED' }); }
      await audit('SESSIONS_REVOKED', target.id, null, { revoked_at: at || now });
      return json(200, { ok: true, message: 'Se cerraron las sesiones de ' + target.full_name + '. Tiene que volver a iniciar sesión.' });
    }
    case 'resend_invite': {
      try { await deps.resendInvite(target.email, deps.redirectTo); }
      catch (e) {
        if (/rate limit/i.test(errMsg(e))) return json(429, { error: 'Se alcanzó el límite de emails de Supabase. Configurá un SMTP propio (Authentication → SMTP) o esperá unos minutos.', code: 'EMAIL_RATE_LIMIT' });
        // Si Auth ya registró al usuario, NO se crea otro: se envía un enlace para que defina su contraseña
        if (/already|registered|exists/i.test(errMsg(e))) {
          try { await deps.sendPasswordReset(target.email, deps.redirectTo); }
          catch (e2) { return json(502, { error: 'No se pudo reenviar la invitación: ' + errMsg(e2), code: 'INVITE_FAILED' }); }
        } else return json(502, { error: 'No se pudo reenviar la invitación: ' + errMsg(e), code: 'INVITE_FAILED' });
      }
      await audit('INVITE_RESENT', target.id, null, { email: target.email });
      return json(200, { ok: true, message: 'Invitación reenviada a ' + target.email + '.' });
    }
    case 'reassign_routes': {
      let n;
      try { n = await deps.reassignRoutes(target.id, payload.to_user); }
      catch (e) { const m = errMsg(e); return json(409, { error: /INCOMPATIBLE/.test(m) ? 'El usuario elegido no puede recibir alguna de esas hojas (responsable incompatible).' : 'No se reasignaron las hojas: ' + m, code: 'REASSIGN_FAILED' }); }
      await audit('ROUTES_REASSIGNED', target.id, null, { to_user: payload.to_user, count: n });
      return json(200, { ok: true, count: n });
    }
    case 'delete': {
      // Primero se borra; recién si terminó bien se registra el borrado.
      const snapshot = { ...before, email: target.email, full_name: target.full_name };
      try { await deps.deleteProfileAndAuth(target.id); }
      catch (e) { await audit('USER_DELETE_FAILED', target.id, snapshot, { error: errMsg(e) }); return json(409, { error: 'No se eliminó el usuario: ' + errMsg(e), code: /HAS_HISTORY/.test(errMsg(e)) ? 'HAS_HISTORY' : 'DELETE_FAILED' }); }
      await audit('USER_DELETED', target.id, snapshot, null);
      return json(200, { deleted: target.id });
    }
  }
  return json(200, { user: await deps.getProfile(target.id) });
}

export { ROLES };
