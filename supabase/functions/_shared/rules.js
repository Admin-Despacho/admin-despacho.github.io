// Reglas de negocio compartidas por el frontend (modo demo y filtros de pantalla) y por las
// Edge Functions (Deno). La base de datos aplica las MISMAS reglas en SQL (migración Fase 1):
// la pantalla nunca es la única defensa.

// RC4: DESPACHO queda por compatibilidad (los usuarios existentes migran a SUPERVISOR_DESPACHO); no se ofrece para usuarios nuevos.
export const ROLES = ['ADMIN', 'SUPERVISOR_DESPACHO', 'OPERARIO_DEPOSITO', 'DESPACHO', 'TRANSPORTISTA', 'TRANSPORTISTA_INTERNO', 'SOLO_LECTURA'];
export const ASSIGNABLE_ROLES = ROLES.filter(r => r !== 'DESPACHO');

export const ROLE_LABEL = {
  ADMIN: 'Admin General',
  SUPERVISOR_DESPACHO: 'Superior Despacho',
  OPERARIO_DEPOSITO: 'Operario Depósito',
  DESPACHO: 'Despacho',
  TRANSPORTISTA: 'Transportista',
  TRANSPORTISTA_INTERNO: 'Transportista interno',
  SOLO_LECTURA: 'Solo lectura'
};

export const PERMISSIONS = [
  'users.view', 'users.manage',
  'routes.create', 'routes.publish', 'routes.assign', 'routes.view_all', 'routes.view_assigned',
  'deliveries.update', 'deliveries.capture_signature',
  'internal_routes.use', 'internal_routes.manage',
  'locations.view', 'locations.manage',
  'signatures.view', 'audit.view', 'settings.manage',
  'can_approve_internal_route_changes',
  'can_view_commercial_transport_reports', 'can_manage_commercial_transport_reports',
  'routes.manage_all_drafts', 'identity_docs.view', 'collections.manage', 'vehicles.manage', 'credit_notes.manage',
  // RC4: permisos granulares
  'vehicle_mileage.view', 'vehicle_mileage.enter', 'vehicle_mileage.edit', 'vehicle_mileage.rules_manage', 'vehicle_mileage.resolve_alerts',
  'columns.view', 'columns.manage_defaults', 'columns.manage_templates', 'columns.apply_global',
  'routes.edit', 'routes.cancel', 'routes.reassign', 'routes.view_team', 'routes.view_own',
  'drafts.create', 'drafts.view_own', 'drafts.view_team', 'drafts.manage_team',
  'requests.create', 'requests.view_team', 'requests.approve_team', 'requests.reject_team', 'requests.observe_team', 'requests.reassign',
  'users.assign_supervisor', 'users.manage_permissions', 'vehicles.view', 'vehicles.service_manage', 'backup.manage'
];
// Solo Admin General puede otorgarlos (mismo criterio que public.is_sensitive_permission)
export const SENSITIVE_PERMISSIONS = ['users.manage', 'users.manage_permissions', 'users.assign_supervisor', 'settings.manage', 'credit_notes.manage', 'audit.view', 'backup.manage',
  'identity_docs.view', 'can_manage_commercial_transport_reports', 'routes.manage_all_drafts', 'columns.apply_global'];

export const ROLE_PERMISSIONS = {
  ADMIN: PERMISSIONS.slice(),
  // RC4.1: el Superior ve SU EQUIPO por defecto (routes.view_team); "todas las hojas" (routes.view_all) solo por permiso individual de Admin
  SUPERVISOR_DESPACHO: ['routes.create', 'routes.edit', 'routes.publish', 'routes.cancel', 'routes.assign', 'routes.reassign', 'routes.view_team', 'routes.view_own',
    'internal_routes.manage', 'locations.view', 'signatures.view', 'collections.manage', 'drafts.create', 'drafts.view_own', 'drafts.view_team', 'drafts.manage_team',
    'requests.create', 'requests.view_team', 'requests.approve_team', 'requests.reject_team', 'requests.observe_team',
    'columns.view', 'vehicle_mileage.view', 'vehicle_mileage.enter', 'vehicle_mileage.resolve_alerts', 'vehicles.view'],
  OPERARIO_DEPOSITO: ['routes.create', 'routes.view_own', 'locations.view', 'drafts.create', 'drafts.view_own', 'requests.create', 'columns.view', 'vehicle_mileage.view', 'vehicle_mileage.enter', 'vehicles.view'],
  DESPACHO: ['routes.create', 'routes.publish', 'routes.assign', 'routes.view_all', 'internal_routes.manage', 'locations.view', 'signatures.view',
    'columns.view', 'vehicle_mileage.view', 'vehicles.view', 'drafts.create', 'drafts.view_own', 'requests.create'],
  TRANSPORTISTA: ['routes.view_assigned', 'deliveries.update', 'deliveries.capture_signature'],
  TRANSPORTISTA_INTERNO: ['routes.view_assigned', 'internal_routes.use', 'deliveries.update', 'deliveries.capture_signature'],
  SOLO_LECTURA: ['routes.view_all']
};

export const STATUS = ['ACTIVO', 'DESHABILITADO', 'ARCHIVADO', 'INVITACION_PENDIENTE'];

// Módulos (RC1.1): cada permiso pertenece a un módulo; Administración puede RESTRINGIR módulos por usuario (nunca agregar)
export const MODULES = ['DESPACHO', 'MIS_HOJAS', 'USUARIOS', 'INFORMES', 'APROBACIONES', 'CONFIGURACION', 'AUDITORIA'];
export const MODULE_LABEL = { DESPACHO: 'Despacho general', MIS_HOJAS: 'Mis hojas publicadas', USUARIOS: 'Usuarios', INFORMES: 'Informes', APROBACIONES: 'Aprobaciones', CONFIGURACION: 'Configuración', AUDITORIA: 'Auditoría' };
export const MODULE_PERMISSIONS = {
  DESPACHO: ['routes.create', 'routes.publish', 'routes.assign', 'routes.view_all', 'internal_routes.manage', 'locations.view', 'signatures.view', 'routes.manage_all_drafts', 'collections.manage',
    'routes.edit', 'routes.cancel', 'routes.reassign', 'routes.view_team', 'routes.view_own', 'drafts.create', 'drafts.view_own', 'drafts.view_team', 'drafts.manage_team',
    'columns.view', 'vehicle_mileage.view', 'vehicle_mileage.enter', 'vehicles.view', 'requests.create'],
  MIS_HOJAS: ['routes.view_assigned', 'deliveries.update', 'deliveries.capture_signature', 'internal_routes.use'],
  USUARIOS: ['users.view', 'users.manage', 'users.assign_supervisor', 'users.manage_permissions'],
  INFORMES: ['can_view_commercial_transport_reports', 'can_manage_commercial_transport_reports'],
  APROBACIONES: ['can_approve_internal_route_changes', 'requests.view_team', 'requests.approve_team', 'requests.reject_team', 'requests.observe_team', 'requests.reassign'],
  CONFIGURACION: ['settings.manage', 'vehicles.manage', 'locations.manage', 'credit_notes.manage', 'columns.manage_defaults', 'columns.manage_templates', 'columns.apply_global',
    'vehicle_mileage.edit', 'vehicle_mileage.rules_manage', 'vehicle_mileage.resolve_alerts', 'vehicles.service_manage', 'backup.manage'],
  AUDITORIA: ['audit.view', 'identity_docs.view']
};
export const moduleOf = perm => MODULES.find(m => MODULE_PERMISSIONS[m].includes(perm)) || null;
export const roleModules = role => MODULES.filter(m => MODULE_PERMISSIONS[m].some(p => (ROLE_PERMISSIONS[role] || []).includes(p)));
export const effectivePermissions = user => PERMISSIONS.filter(p => hasPerm(user, p));
export const userModules = user => (user && user.status === 'ACTIVO') ? MODULES.filter(m => MODULE_PERMISSIONS[m].some(p => hasPerm(user, p))) : [];

// Permiso efectivo = (rol + otorgados) − quitados − módulos restringidos (igual que public.user_has_perm)
export function hasPerm(user, perm) {
  if (!user || user.status !== 'ACTIVO') return false;
  const ov = (user.permission_overrides || {})[perm];
  if (ov === false) return false;
  if (ov !== true && !(ROLE_PERMISSIONS[user.role] || []).includes(perm)) return false;
  const m = moduleOf(perm);
  return !(m && (user.disabled_modules || []).includes(m));
}

/**
 * ¿Puede este usuario ser RESPONSABLE de una hoja de este transportista?
 *  · Transporte interno → solo usuarios ACTIVOS con rol TRANSPORTISTA_INTERNO
 *  · Carrier externo    → solo usuarios ACTIVOS vinculados a ese carrier
 * carrier: { id, kind: 'INTERNO' | 'EXTERNO', active }
 * user: { id, role, status, carriers: [carrier_id] }
 */
export function canBeResponsable(user, carrier) {
  if (!user || !carrier || carrier.active === false) return false;
  if (user.status !== 'ACTIVO') return false;
  if (carrier.kind === 'INTERNO') return user.role === 'TRANSPORTISTA_INTERNO';
  return (user.role === 'TRANSPORTISTA' || user.role === 'TRANSPORTISTA_INTERNO') && (user.carriers || []).includes(carrier.id);
}

export function compatibleResponsables(users, carrier) {
  return (users || []).filter(u => canBeResponsable(u, carrier))
    .sort((a, b) => String(a.full_name || '').localeCompare(String(b.full_name || ''), 'es'));
}

/**
 * Valida una acción de administración de usuarios. Devuelve null si está permitida,
 * o { code, status, message } si no. Se usa en la Edge Function y en el modo demo.
 * ctx: { actor, target, allUsers, hasHistory, payload }
 */
export function validateUserAction(action, ctx) {
  const { actor, target, allUsers = [], hasHistory = false, activeRoutes = 0, payload = {} } = ctx;
  const deny = (code, status, message) => ({ code, status, message });
  if (!actor) return deny('NO_AUTH', 401, 'Sesión inválida.');
  // canManage viene de la base (user_has_perm) cuando la llama la Edge Function; si no, se usa la misma regla en JS
  if (!(ctx.canManage !== undefined ? ctx.canManage : hasPerm(actor, 'users.manage'))) return deny('FORBIDDEN', 403, 'No tenés permiso para administrar usuarios.');
  const activeAdmins = allUsers.filter(u => u.role === 'ADMIN' && u.status === 'ACTIVO');
  const isLastAdmin = t => t && t.role === 'ADMIN' && t.status === 'ACTIVO' && activeAdmins.length <= 1;
  const emailOk = e => /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(String(e || '').trim());
  const emailTaken = (e, exceptId) => allUsers.some(u => (exceptId == null || u.id !== exceptId) && String(u.email).toLowerCase() === String(e).trim().toLowerCase());
  // Un TRANSPORTISTA siempre necesita al menos un carrier externo
  const needsCarrier = (role, carriers) => role === 'TRANSPORTISTA' && !(carriers || []).length;
  const supervisorProblem = (supId, forUserId, role) => {
    if (supId == null) return null;
    if (role !== 'TRANSPORTISTA_INTERNO') return deny('BAD_SUPERVISOR', 400, 'El superior se configura solo para transportistas internos.');
    const sup = allUsers.find(u => u.id === supId);
    if (!sup || supId === forUserId || !hasPerm(sup, 'can_approve_internal_route_changes')) return deny('BAD_SUPERVISOR', 400, 'El superior debe estar activo y tener permiso para aprobar cambios de rutas internas.');
    return null;
  };

  if (payload.disabled_modules !== undefined && (!Array.isArray(payload.disabled_modules) || payload.disabled_modules.some(m => !MODULES.includes(m)))) return deny('BAD_MODULES', 400, 'Módulos inválidos.');
  if (action === 'create') {
    if (!emailOk(payload.email)) return deny('BAD_EMAIL', 400, 'Email inválido.');
    if (!payload.full_name || !String(payload.full_name).trim()) return deny('BAD_NAME', 400, 'Falta nombre y apellido.');
    if (!ROLES.includes(payload.role)) return deny('BAD_ROLE', 400, 'Rol inválido.');
    if (emailTaken(payload.email)) return deny('DUPLICATE', 409, 'Ya existe un usuario con ese email.');
    if (needsCarrier(payload.role, payload.carriers)) return deny('CARRIER_REQUIRED', 400, 'Un transportista debe estar vinculado al menos a un carrier.');
    return null;
  }
  if (!target) return deny('NOT_FOUND', 404, 'Usuario no encontrado.');
  const self = target.id === actor.id;

  switch (action) {
    case 'edit': {
      const role = payload.role || target.role;
      if (payload.role && payload.role !== target.role) {
        if (self) return deny('SELF_ROLE', 400, 'No podés cambiar tu propio rol.');
        if (!ROLES.includes(payload.role)) return deny('BAD_ROLE', 400, 'Rol inválido.');
        if (payload.role !== 'ADMIN' && isLastAdmin(target)) return deny('LAST_ADMIN', 409, 'Es el último administrador activo: no se le puede quitar el rol.');
      }
      if (payload.full_name !== undefined && !String(payload.full_name).trim()) return deny('BAD_NAME', 400, 'Falta nombre y apellido.');
      if (payload.email !== undefined && String(payload.email).trim().toLowerCase() !== String(target.email).toLowerCase()) {
        if (!emailOk(payload.email)) return deny('BAD_EMAIL', 400, 'Email inválido.');
        if (emailTaken(payload.email, target.id)) return deny('DUPLICATE', 409, 'Ya existe un usuario con ese email.');
      }
      const carriers = payload.carriers !== undefined ? payload.carriers : target.carriers;
      if (needsCarrier(role, carriers)) return deny('CARRIER_REQUIRED', 400, 'Para el rol Transportista elegí al menos un transportista/empresa.');
      if (self && payload.carriers !== undefined && JSON.stringify([...(payload.carriers || [])].sort()) !== JSON.stringify([...(target.carriers || [])].sort())) return deny('SELF_CARRIER', 400, 'No podés cambiar tus propios carriers.');
      if (payload.supervisor_user_id !== undefined) { const p = supervisorProblem(payload.supervisor_user_id, target.id, role); if (p) return p; }
      if (self && (payload.disabled_modules || []).includes('USUARIOS')) return deny('SELF_LOCKOUT', 400, 'No podés quitarte el acceso a Usuarios.');
      if (target.status === 'ARCHIVADO') return deny('ARCHIVED', 409, 'El usuario está archivado: reactivalo antes de editarlo.');
      return null;
    }
    case 'set_role':
      if (self) return deny('SELF_ROLE', 400, 'No podés cambiar tu propio rol.');
      if (!ROLES.includes(payload.role)) return deny('BAD_ROLE', 400, 'Rol inválido.');
      if (payload.role !== 'ADMIN' && isLastAdmin(target)) return deny('LAST_ADMIN', 409, 'Es el último administrador activo: no se le puede quitar el rol.');
      if (needsCarrier(payload.role, payload.carriers !== undefined ? payload.carriers : target.carriers)) return deny('CARRIER_REQUIRED', 400, 'Para el rol Transportista elegí al menos un transportista/empresa.');
      return null;
    case 'set_carriers':
      if (self) return deny('SELF_CARRIER', 400, 'No podés cambiar tus propios carriers.');
      if (needsCarrier(target.role, payload.carriers)) return deny('CARRIER_REQUIRED', 400, 'Un transportista debe estar vinculado al menos a un carrier.');
      return null;
    case 'disable':
    case 'archive':
      if (self) return deny(action === 'disable' ? 'SELF_DISABLE' : 'SELF_ARCHIVE', 400, action === 'disable' ? 'No podés deshabilitar tu propio usuario.' : 'No podés archivar tu propio usuario.');
      if (isLastAdmin(target)) return deny('LAST_ADMIN', 409, 'Es el último administrador activo: no se puede ' + (action === 'disable' ? 'deshabilitar.' : 'archivar.'));
      if (action === 'disable' && target.status === 'ARCHIVADO') return deny('ARCHIVED', 409, 'El usuario está archivado.');
      if (activeRoutes > 0) return deny('ACTIVE_ROUTES', 409, 'ESTE USUARIO TIENE HOJAS ACTIVAS: reasignalas o resolvelas antes.');
      return null;
    case 'reactivate':
      if (target.status === 'ACTIVO') return deny('ALREADY_ACTIVE', 409, 'El usuario ya está activo.');
      return null;
    case 'delete':
      if (self) return deny('SELF_DELETE', 400, 'No podés eliminar tu propio usuario.');
      if (isLastAdmin(target)) return deny('LAST_ADMIN', 409, 'Es el último administrador activo: no se puede eliminar.');
      if (hasHistory) return deny('HAS_HISTORY', 409, 'El usuario tiene historial operativo: no se elimina, se ARCHIVA para conservar la trazabilidad.');
      if (activeRoutes > 0) return deny('ACTIVE_ROUTES', 409, 'ESTE USUARIO TIENE HOJAS ACTIVAS: reasignalas o resolvelas antes.');
      return null;
    case 'reset_password':
      if (target.status === 'DESHABILITADO' || target.status === 'ARCHIVADO') return deny('NO_ACCESS', 409, 'El usuario no tiene acceso: reactivalo antes de restablecer la contraseña.');
      return null;
    case 'revoke_sessions':
      return null;
    case 'resend_invite':
    case 'cancel_invite':
      if (target.status !== 'INVITACION_PENDIENTE') return deny('NO_INVITE', 409, 'El usuario no tiene una invitación pendiente.');
      return null;
    case 'reassign_routes': {
      const to = allUsers.find(u => u.id === payload.to_user);
      if (!to) return deny('BAD_TARGET', 400, 'Elegí a quién reasignar las hojas.');
      if (to.id === target.id) return deny('SAME_USER', 400, 'Elegí otro usuario.');
      if (to.status !== 'ACTIVO') return deny('BAD_TARGET', 400, 'Solo se reasigna a usuarios activos.');
      return null;
    }
    default:
      return deny('BAD_ACTION', 400, 'Acción desconocida.');
  }
}