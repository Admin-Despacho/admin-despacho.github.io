import { describe, it, expect, beforeEach } from 'vitest';
import { DemoApi } from '../../src/online/demo-api.js';

const mem = () => { const m = new Map(); return { getItem: k => m.has(k) ? m.get(k) : null, setItem: (k, v) => m.set(k, String(v)), removeItem: k => m.delete(k) }; };
let api;
beforeEach(() => { api = new DemoApi(mem()); });

describe('Modo demo (mismas reglas que el servidor)', () => {
  it('D01 contraseña incorrecta no entra', async () => { await expect(api.signIn('admin@okdespacho.demo', 'x')).rejects.toThrow('incorrectos'); });
  it('D02 usuario deshabilitado no entra', async () => { await expect(api.signIn('lucas@okdespacho.demo', 'demo')).rejects.toThrow('sin acceso'); });
  it('D03 admin crea usuario con invitación pendiente', async () => {
    await api.signIn('admin@okdespacho.demo', 'demo');
    const u = await api.action('create', { full_name: 'Nuevo', email: 'nuevo@okdespacho.demo', role: 'TRANSPORTISTA_INTERNO' });
    expect(u.status).toBe('INVITACION_PENDIENTE');
    expect((await api.listUsers()).some(x => x.email === 'nuevo@okdespacho.demo')).toBe(true);
  });
  it('D04 despacho no ve la lista de usuarios', async () => { await api.signIn('despacho@okdespacho.demo', 'demo'); await expect(api.listUsers()).rejects.toThrow('permiso'); });
  it('D05 eliminar con historial se rechaza y archivar conserva nombre', async () => {
    await api.signIn('admin@okdespacho.demo', 'demo');
    await expect(api.action('delete', { user_id: 'u-cristian' })).rejects.toMatchObject({ code: 'HAS_HISTORY' });
    const a = await api.action('archive', { user_id: 'u-cristian' });
    expect(a.status).toBe('ARCHIVADO'); expect(a.full_name).toBe('Cristian Torres');
  });
  it('D06 deshabilitar impide entrar; reactivar devuelve el acceso con el mismo id', async () => {
    await api.signIn('admin@okdespacho.demo', 'demo');
    await api.action('disable', { user_id: 'u-diego' });
    await api.signOut(); await expect(api.signIn('diego@okdespacho.demo', 'demo')).rejects.toThrow('sin acceso');
    await api.signIn('admin@okdespacho.demo', 'demo'); const r = await api.action('reactivate', { user_id: 'u-diego' });
    expect(r.id).toBe('u-diego'); await api.signOut(); await expect(api.signIn('diego@okdespacho.demo', 'demo')).resolves.toBeTruthy();
  });
  it('D07 responsables: interno sin Cristian; Este solo Cristian; Alrededores Cristian y Diego', async () => {
    await api.signIn('despacho@okdespacho.demo', 'demo');
    expect((await api.responsables('INTERNO')).map(x => x.full_name)).toEqual(['Gabriel Figueroa', 'Martín Sosa']);
    expect((await api.responsables('CT-ESTE')).map(x => x.full_name)).toEqual(['Cristian Torres']);
    expect((await api.responsables('CT-ALR')).map(x => x.full_name)).toEqual(['Cristian Torres', 'Diego Ríos']);
  });
  it('D08 transportista no puede pedir responsables', async () => { await api.signIn('gabriel@okdespacho.demo', 'demo'); await expect(api.responsables('INTERNO')).rejects.toThrow('routes.assign'); });
  it('D09 cambio de rol queda auditado', async () => {
    await api.signIn('admin@okdespacho.demo', 'demo'); await api.action('set_role', { user_id: 'u-diego', role: 'TRANSPORTISTA_INTERNO' });
    const a = api.auditLog().at(-1); expect(a.action).toBe('USER_ROLE_CHANGED'); expect(a.before.role).toBe('TRANSPORTISTA');
  });

  // ===== Fase 1.1 =====
  it('F1.1-04 (demo) el último acceso se actualiza al iniciar sesión', async () => {
    await api.signIn('gabriel@okdespacho.demo', 'demo'); await api.signOut(); await api.signIn('admin@okdespacho.demo', 'demo');
    expect((await api.listUsers()).find(u => u.id === 'u-gabriel').last_sign_in_at).toBeTruthy();
  });
  it('F1.1-03 (demo) cerrar sesiones invalida la sesión abierta del usuario', async () => {
    const other = new DemoApi(api.storage);
    await other.signIn('despacho@okdespacho.demo', 'demo'); expect(await other.getSession()).toBeTruthy();
    await api.signIn('admin@okdespacho.demo', 'demo'); await api.action('revoke_sessions', { user_id: 'u-deposito' });
    const reopened = new DemoApi(api.storage); reopened.session = other.session;
    expect(await reopened.getSession()).toBeNull(); expect(reopened.revokedNotice).toBe(true);
    expect(api.auditLog().at(-1).action).toBe('SESSIONS_REVOKED');
  });
  it('F1.1-15 (demo) reenviar invitación no duplica el usuario', async () => {
    await api.signIn('admin@okdespacho.demo', 'demo'); const n = (await api.listUsers()).length;
    await api.action('resend_invite', { user_id: 'u-invitada' }); expect((await api.listUsers()).length).toBe(n);
  });
  it('F1.1-16 (demo) cancelar invitación bloquea el acceso', async () => {
    await api.signIn('admin@okdespacho.demo', 'demo'); await api.action('cancel_invite', { user_id: 'u-invitada' }); await api.signOut();
    await expect(api.signIn('paula@okdespacho.demo', 'demo')).rejects.toThrow('sin acceso');
  });
  it('F1.1-13 (demo) usuario con hoja activa no se deshabilita y se informa la hoja', async () => {
    await api.signIn('admin@okdespacho.demo', 'demo');
    await expect(api.action('disable', { user_id: 'u-gabriel' })).rejects.toMatchObject({ code: 'ACTIVE_ROUTES', routes: [expect.objectContaining({ number: '03-02' })] });
  });
  it('F1.1-20 (demo) el usuario cambia su propia contraseña y entra con la nueva', async () => {
    await api.signIn('gabriel@okdespacho.demo', 'demo'); await api.changeOwnPassword('nueva-clave-123'); await api.signOut();
    await expect(api.signIn('gabriel@okdespacho.demo', 'demo')).rejects.toThrow('incorrectos');
    await expect(api.signIn('gabriel@okdespacho.demo', 'nueva-clave-123')).resolves.toBeTruthy();
  });
});
