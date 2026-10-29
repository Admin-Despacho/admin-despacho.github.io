// Adaptador ONLINE (SupabaseApi) con un cliente Supabase SIMULADO: los permisos efectivos vienen del servidor (user_effective_permissions),
// no de la demo ni de permission_overrides agregados por la prueba. Datos ficticios.
import { describe, it, expect } from 'vitest';
import { SupabaseApi } from '../../src/online/supabase-api.js';
import { hasPerm, canOperateAssigned } from '../../supabase/functions/_shared/rules.js';
import { canSwitch } from '../../src/online/role-view.js';

const UID = '00000000-0000-0000-0000-0000000000a1';
// cliente Supabase simulado: profiles, user_carriers y rpc('user_effective_permissions')
function fakeSb({ profile, perms, permsError = null, calls = [] }) {
  const q = rows => { const b = { select: () => b, eq: () => b, order: () => b, maybeSingle: async () => ({ data: rows[0] || null, error: null }), then: (ok, ko) => Promise.resolve({ data: rows, error: null }).then(ok, ko) }; return b; };
  return { calls,
    auth: { getSession: async () => ({ data: { session: { user: { id: UID }, access_token: 'x.' + Buffer.from(JSON.stringify({ iat: Math.floor(Date.now() / 1000) })).toString('base64') + '.y' } } }) },
    from: t => q(t === 'profiles' ? [profile] : t === 'user_carriers' ? [] : []),
    rpc: async (fn, args) => { calls.push([fn, args]); if (fn !== 'user_effective_permissions') return { data: null, error: { message: 'no simulado' } };
      return typeof perms === 'function' ? perms() : (permsError ? { data: null, error: permsError } : { data: perms, error: null }); } };
}
const OPER = { id: UID, full_name: 'Operario QA', role: 'OPERARIO_DEPOSITO', status: 'ACTIVO', disabled_modules: [], sessions_revoked_at: null };
const VEH = ['vehicles.manage', 'vehicle_mileage.enter', 'vehicle_mileage.edit', 'vehicle_mileage.resolve_alerts', 'vehicles.service_manage'];
const api = o => new SupabaseApi('http://x', 'k', fakeSb(o));

describe('Permisos ONLINE desde el servidor', () => {
  it('ON-01 Operario con permisos individuales de vehículos: me() trae los permisos efectivos y habilitan las acciones', async () => {
    const sb = fakeSb({ profile: OPER, perms: ['routes.create', ...VEH] }), me = await new SupabaseApi('http://x', 'k', sb).me();
    expect(sb.calls).toEqual([['user_effective_permissions', { p_user: UID }]]);
    expect(me.effective_permissions).toEqual(['routes.create', ...VEH]);
    for (const p of VEH) expect(hasPerm(me, p)).toBe(true);
    expect(me.permission_overrides).toBeUndefined();   // no depende de permission_overrides en el cliente
  });
  it('ON-02 mismo rol SIN esos permisos (o revocados en el servidor): acciones restringidas aunque el rol de la app los tuviera', async () => {
    const me = await api({ profile: OPER, perms: ['routes.create'] }).me();
    for (const p of VEH) expect(hasPerm(me, p)).toBe(false);
    expect(hasPerm(me, 'routes.publish')).toBe(false);   // nunca se amplía con los permisos por rol de la app
  });
  it('ON-03 si falla la consulta de permisos: error PERMISSIONS_UNAVAILABLE y NO se devuelve un usuario con permisos supuestos', async () => {
    await expect(api({ profile: OPER, permsError: { message: 'timeout' } }).me()).rejects.toMatchObject({ code: 'PERMISSIONS_UNAVAILABLE' });
    await expect(api({ profile: OPER, perms: () => ({ data: null, error: null }) }).me()).rejects.toMatchObject({ code: 'PERMISSIONS_UNAVAILABLE' });
  });
  it('ON-04 "Cambiar rol": aparece con routes.receive_internal del servidor y deja de permitir operar al revocarlo', async () => {
    const on = await api({ profile: OPER, perms: ['routes.create', 'routes.receive_internal'] }).me();
    expect(canSwitch(on)).toBe(true); expect(canOperateAssigned(on, { responsable_id: UID }, 'INTERNO')).toBe(true);
    const off = await api({ profile: OPER, perms: ['routes.create'] }).me();
    expect(canSwitch(off)).toBe(false); expect(canOperateAssigned(off, { responsable_id: UID }, 'INTERNO')).toBe(false);
  });
  it('ON-05 usuario no activo: sin permisos aunque el servidor devolviera alguno', async () => {
    const me = await api({ profile: { ...OPER, status: 'SUSPENDIDO' }, perms: VEH }).me(); expect(hasPerm(me, 'vehicles.manage')).toBe(false);
  });
  it('ON-06 cambio de permisos con la sesión abierta: cada me() refleja el estado ACTUAL del servidor', async () => {
    let list = ['routes.create', 'vehicles.manage']; const a = new SupabaseApi('http://x', 'k', fakeSb({ profile: OPER, perms: () => ({ data: list.slice(), error: null }) }));
    expect(hasPerm(await a.me(), 'vehicles.manage')).toBe(true);
    list = ['routes.create']; expect(hasPerm(await a.me(), 'vehicles.manage')).toBe(false);
  });
});
