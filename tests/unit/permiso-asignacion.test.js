// "Permitir asignación de hojas de ruta" (routes.receive_internal) y "⇄ Cambiar rol": reglas del cliente (mismo criterio que el servidor).
import { describe, it, expect } from 'vitest';
import { hasPerm, canBeResponsable, canOperateAssigned, hasDriverAccess, ROLE_PERMISSIONS } from '../../supabase/functions/_shared/rules.js';
const INT = { id: 'INTERNO', kind: 'INTERNO', active: true }, EXT = { id: 'CT-ESTE', kind: 'EXTERNO', active: true };
const u = (role, ov = {}) => ({ id: 'u-' + role, role, status: 'ACTIVO', carriers: [], permission_overrides: ov });
const ON = { 'routes.receive_internal': true };
describe('Permiso de asignación de hojas', () => {
  it('PA-01 ningún rol lo tiene por defecto (ni Admin): solo habilitado a la persona', () => {
    for (const r of Object.keys(ROLE_PERMISSIONS)) expect(ROLE_PERMISSIONS[r]).not.toContain('routes.receive_internal');
    expect(canBeResponsable(u('ADMIN'), INT)).toBe(false);
  });
  it('PA-02 habilitado a Admin, Superior, Operario o Solo Lectura: candidato del Transporte Interno (no de externos), conserva su rol', () => {
    for (const r of ['ADMIN', 'SUPERVISOR_DESPACHO', 'OPERARIO_DEPOSITO', 'SOLO_LECTURA']) { const x = u(r, ON);
      expect(canBeResponsable(x, INT)).toBe(true); expect(canBeResponsable(x, EXT)).toBe(false); expect(x.role).toBe(r); expect(hasDriverAccess(x)).toBe(true); }
  });
  it('PA-03 no amplía otros permisos (Solo Lectura sigue sin crear, publicar ni registrar entregas en general)', () => {
    const x = u('SOLO_LECTURA', ON); for (const p of ['routes.create', 'routes.publish', 'deliveries.update', 'routes.view_assigned']) expect(hasPerm(x, p)).toBe(false);
  });
  it('PA-04 solo SUS hojas internas; nunca ajenas ni externas', () => {
    const x = u('OPERARIO_DEPOSITO', ON);
    expect(canOperateAssigned(x, { responsable_id: x.id }, 'INTERNO')).toBe(true);
    expect(canOperateAssigned(x, { responsable_id: 'otro' }, 'INTERNO')).toBe(false);
    expect(canOperateAssigned(x, { responsable_id: x.id }, 'EXTERNO')).toBe(false);
  });
  it('PA-05 sin el permiso (o quitado) deja de ser candidato y no opera; usuario inactivo tampoco', () => {
    expect(canBeResponsable(u('OPERARIO_DEPOSITO'), INT)).toBe(false);
    expect(canOperateAssigned(u('OPERARIO_DEPOSITO'), { responsable_id: 'u-OPERARIO_DEPOSITO' }, 'INTERNO')).toBe(false);
    expect(canBeResponsable({ ...u('OPERARIO_DEPOSITO', ON), status: 'SUSPENDIDO' }, INT)).toBe(false);
  });
  it('PA-07 Admin con routes.view_assigned por su rol: SIN el permiso no opera su hoja interna (igual que el servidor); con el permiso sí', () => {
    const a = u('ADMIN'), r = { responsable_id: a.id };
    expect(hasPerm(a, 'routes.view_assigned')).toBe(true);                     // sus permisos administrativos siguen intactos
    expect(canOperateAssigned(a, r, 'INTERNO')).toBe(false);                    // revocado / nunca habilitado
    expect(canOperateAssigned({ ...a, permission_overrides: ON }, r, 'INTERNO')).toBe(true);
    expect(canOperateAssigned(a, r, 'EXTERNO')).toBe(true);                     // externos: sin cambios (view_assigned)
  });
  it('PA-06 transportistas actuales sin cambios', () => {
    const g = u('TRANSPORTISTA_INTERNO'); expect(canBeResponsable(g, INT)).toBe(true); expect(canOperateAssigned(g, { responsable_id: g.id }, 'INTERNO')).toBe(true);
  });
});
