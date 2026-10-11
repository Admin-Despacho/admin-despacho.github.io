import { describe, it, expect } from 'vitest';
import { canBeResponsable, compatibleResponsables, hasPerm, validateUserAction, ROLE_PERMISSIONS } from '../../supabase/functions/_shared/rules.js';

const INT = { id: 'INTERNO', kind: 'INTERNO', active: true };
const ESTE = { id: 'CT-ESTE', kind: 'EXTERNO', active: true };
const ALR = { id: 'CT-ALR', kind: 'EXTERNO', active: true };
const U = {
  gabriel: { id: 'g', full_name: 'Gabriel Figueroa', role: 'TRANSPORTISTA_INTERNO', status: 'ACTIVO', carriers: [] },
  lucas: { id: 'l', full_name: 'Lucas Méndez', role: 'TRANSPORTISTA_INTERNO', status: 'DESHABILITADO', carriers: [] },
  cristian: { id: 'c', full_name: 'Cristian Torres', role: 'TRANSPORTISTA', status: 'ACTIVO', carriers: ['CT-ESTE', 'CT-ALR'] },
  diego: { id: 'd', full_name: 'Diego Ríos', role: 'TRANSPORTISTA', status: 'ACTIVO', carriers: ['CT-ALR'] },
  archivado: { id: 'a', full_name: 'Archivado', role: 'TRANSPORTISTA', status: 'ARCHIVADO', carriers: ['CT-ESTE'] },
  despacho: { id: 'x', full_name: 'Depósito', role: 'DESPACHO', status: 'ACTIVO', carriers: [] },
  admin: { id: 'adm', full_name: 'Administración', role: 'ADMIN', status: 'ACTIVO', carriers: [] }
};
const all = Object.values(U);

describe('Responsable compatible', () => {
  it('U01 TRANSPORTE INTERNO → solo TRANSPORTISTA_INTERNO activos', () => expect(compatibleResponsables(all, INT).map(u => u.full_name)).toEqual(['Gabriel Figueroa']));
  it('U02 CT-ESTE → solo vinculados a CT-ESTE', () => expect(compatibleResponsables(all, ESTE).map(u => u.full_name)).toEqual(['Cristian Torres']));
  it('U03 CT-ALR → solo vinculados a CT-ALR', () => expect(compatibleResponsables(all, ALR).map(u => u.full_name)).toEqual(['Cristian Torres', 'Diego Ríos']));
  it('U04 Cristian nunca aparece en TRANSPORTE INTERNO', () => expect(canBeResponsable(U.cristian, INT)).toBe(false));
  it('U05 deshabilitados y archivados nunca aparecen', () => { expect(canBeResponsable(U.lucas, INT)).toBe(false); expect(canBeResponsable(U.archivado, ESTE)).toBe(false); });
  it('U06 roles de oficina nunca son responsables', () => { expect(canBeResponsable(U.despacho, INT)).toBe(false); expect(canBeResponsable(U.admin, ESTE)).toBe(false); });
  it('U07 carrier inactivo no tiene responsables', () => expect(canBeResponsable(U.cristian, { ...ESTE, active: false })).toBe(false));
});

describe('Permisos', () => {
  it('U08 ADMIN tiene users.manage; DESPACHO no', () => { expect(hasPerm(U.admin, 'users.manage')).toBe(true); expect(hasPerm(U.despacho, 'users.manage')).toBe(false); });
  it('U09 usuario deshabilitado no tiene ningún permiso', () => expect(ROLE_PERMISSIONS.TRANSPORTISTA_INTERNO.some(p => hasPerm(U.lucas, p))).toBe(false));
  it('U10 TRANSPORTISTA_INTERNO tiene internal_routes.use; TRANSPORTISTA no', () => { expect(hasPerm(U.gabriel, 'internal_routes.use')).toBe(true); expect(hasPerm(U.cristian, 'internal_routes.use')).toBe(false); });
});

describe('Acciones de usuarios', () => {
  const ctx = (extra) => ({ actor: U.admin, allUsers: all, ...extra });
  it('U11 no podés cambiar tu propio rol', () => expect(validateUserAction('set_role', ctx({ target: U.admin, payload: { role: 'DESPACHO' } })).code).toBe('SELF_ROLE'));
  it('U12 último admin protegido', () => {
    const other = { ...U.admin, id: 'adm2', status: 'ACTIVO' };
    expect(validateUserAction('disable', { actor: other, target: U.admin, allUsers: [U.admin] }).code).toBe('LAST_ADMIN');
  });
  it('U13 con historial no se elimina', () => expect(validateUserAction('delete', ctx({ target: U.cristian, hasHistory: true })).code).toBe('HAS_HISTORY'));
  it('U14 sin historial se puede eliminar', () => expect(validateUserAction('delete', ctx({ target: U.despacho, hasHistory: false }))).toBeNull());
  it('U15 sin users.manage no se crea', () => expect(validateUserAction('create', { actor: U.despacho, allUsers: all, payload: { email: 'a@b.c', full_name: 'A', role: 'DESPACHO' } }).code).toBe('FORBIDDEN'));
  it('U16 transportista externo requiere carrier', () => expect(validateUserAction('create', ctx({ payload: { email: 'n@b.c', full_name: 'N', role: 'TRANSPORTISTA', carriers: [] } })).code).toBe('CARRIER_REQUIRED'));
  it('U17 email duplicado rechazado (sin importar mayúsculas)', () => expect(validateUserAction('create', ctx({ payload: { email: 'X@OK.test', full_name: 'N', role: 'DESPACHO' }, allUsers: [{ email: 'x@ok.test' }, U.admin] })).code).toBe('DUPLICATE'));
});

describe('Fase 1.1 — reglas', () => {
  const ctx = (extra) => ({ actor: U.admin, allUsers: all, ...extra });
  it('F1.1-07 (regla) DESPACHO → TRANSPORTISTA sin carrier: rechazado (edit y set_role)', () => {
    expect(validateUserAction('edit', ctx({ target: U.despacho, payload: { role: 'TRANSPORTISTA' } })).code).toBe('CARRIER_REQUIRED');
    expect(validateUserAction('set_role', ctx({ target: U.despacho, payload: { role: 'TRANSPORTISTA' } })).code).toBe('CARRIER_REQUIRED');
  });
  it('F1.1-08 (regla) DESPACHO → TRANSPORTISTA con CT-ESTE: aceptado', () => expect(validateUserAction('edit', ctx({ target: U.despacho, payload: { role: 'TRANSPORTISTA', carriers: ['CT-ESTE'] } }))).toBeNull());
  it('F1.1-13/14 (regla) con hojas activas no se deshabilita ni archiva', () => {
    expect(validateUserAction('disable', ctx({ target: U.gabriel, activeRoutes: 1 })).code).toBe('ACTIVE_ROUTES');
    expect(validateUserAction('archive', ctx({ target: U.gabriel, activeRoutes: 2 })).code).toBe('ACTIVE_ROUTES');
  });
  it('F1.1-22 (regla) superior: solo para internos y con permiso de aprobación', () => {
    expect(validateUserAction('edit', ctx({ target: U.gabriel, payload: { supervisor_user_id: 'x' } })).code).toBe('BAD_SUPERVISOR');
    expect(validateUserAction('edit', ctx({ target: U.gabriel, payload: { supervisor_user_id: 'adm' } }))).toBeNull();
    expect(validateUserAction('edit', ctx({ target: U.cristian, payload: { supervisor_user_id: 'adm' } })).code).toBe('BAD_SUPERVISOR');
  });
  it('F1.1-21 (regla) ADMIN tiene can_approve_internal_route_changes; DESPACHO y transportistas no', () => {
    expect(hasPerm(U.admin, 'can_approve_internal_route_changes')).toBe(true);
    expect(hasPerm(U.despacho, 'can_approve_internal_route_changes')).toBe(false);
    expect(hasPerm(U.gabriel, 'can_approve_internal_route_changes')).toBe(false);
  });
  it('F1.1-15/16 (regla) reenviar/cancelar solo con invitación pendiente', () => {
    expect(validateUserAction('resend_invite', ctx({ target: U.gabriel })).code).toBe('NO_INVITE');
    expect(validateUserAction('cancel_invite', ctx({ target: { ...U.gabriel, status: 'INVITACION_PENDIENTE' } }))).toBeNull();
  });
});

