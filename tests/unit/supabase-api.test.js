import { describe, it, expect } from 'vitest';
import { SupabaseApi } from '../../src/online/supabase-api.js';

// Cliente de Supabase simulado: solo lo que usa SupabaseApi
function fakeSb({ profile, acceptFails = false, iat = 2000000000 }) {
  const token = 'x.' + btoa(JSON.stringify({ iat })) + '.y';
  const state = { profile: { ...profile }, signedOut: false, password: null };
  const q = (table) => ({
    select: () => ({ eq: () => ({ maybeSingle: async () => ({ data: table === 'profiles' ? { ...state.profile } : null }), then: undefined }) })
  });
  return {
    state,
    // me() consulta los permisos efectivos incluso durante la activación de una invitación.
    rpc: async (name, args) => {
      expect(name).toBe('user_effective_permissions');
      expect(args).toEqual({ p_user: profile.id });
      return { data: [], error: null };
    },
    auth: {
      getSession: async () => ({ data: { session: state.signedOut ? null : { user: { id: profile.id }, access_token: token } } }),
      updateUser: async ({ password }) => { state.password = password; return { error: null }; },
      signOut: async () => { state.signedOut = true; }
    },
    from: (table) => table === 'user_carriers'
      ? { select: () => ({ eq: async () => ({ data: [] }) }) }
      : q(table),
    functions: {
      invoke: async (name, { body }) => {
        if (body.action === 'accept_invite') {
          if (acceptFails) return { data: null, error: { message: 'Edge Function returned a non-2xx status code', context: { json: async () => ({ error: 'No se pudo activar tu usuario: timeout', code: 'ACCEPT_FAILED' }) } } };
          state.profile.status = 'ACTIVO'; return { data: { user: state.profile }, error: null };
        }
        return { data: {}, error: null };
      }
    }
  };
}

describe('Frontend online — invitación y sesiones', () => {
  it('F1.1-12 si falla accept_invite: error claro, el usuario NO queda como activo y la sesión no se cierra en silencio', async () => {
    const sb = fakeSb({ profile: { id: 'inv', status: 'INVITACION_PENDIENTE' }, acceptFails: true });
    const api = new SupabaseApi('', '', sb);
    await expect(api.setPassword('clave-segura-1')).rejects.toMatchObject({ code: 'ACCEPT_FAILED' });
    expect(sb.state.password).toBe('clave-segura-1');
    expect(sb.state.profile.status).toBe('INVITACION_PENDIENTE');
    expect(sb.state.signedOut).toBe(false);
  });
  it('F1.1-12b si accept_invite funciona, el usuario queda ACTIVO', async () => {
    const sb = fakeSb({ profile: { id: 'inv', status: 'INVITACION_PENDIENTE' } });
    await new SupabaseApi('', '', sb).setPassword('clave-segura-1');
    expect(sb.state.profile.status).toBe('ACTIVO');
  });
  it('F1.1-03c sesión anterior a "cerrar sesiones": la app la cierra y avisa', async () => {
    const sb = fakeSb({ profile: { id: 'des', status: 'ACTIVO', sessions_revoked_at: '2026-10-09T12:00:00Z' }, iat: Date.parse('2026-10-09T11:00:00Z') / 1000 });
    const api = new SupabaseApi('', '', sb);
    expect(await api.me()).toBeNull(); expect(api.revokedNotice).toBe(true); expect(sb.state.signedOut).toBe(true);
  });
  it('F1.1-20 cambiar la propia contraseña usa Supabase Auth del propio usuario', async () => {
    const sb = fakeSb({ profile: { id: 'g', status: 'ACTIVO' } });
    await new SupabaseApi('', '', sb).changeOwnPassword('otra-clave-99');
    expect(sb.state.password).toBe('otra-clave-99');
  });
});
