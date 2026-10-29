// Incidente: usuario invitado que no puede ingresar ("New password should be different from the old password").
// Cliente Supabase simulado con el comportamiento REAL de Auth: misma contraseña → error same_password; credenciales
// inválidas → invalid_credentials; email sin confirmar → email_not_confirmed. No envía correos ni toca credenciales reales.
import { describe, it, expect } from 'vitest';
import { SupabaseApi } from '../../src/online/supabase-api.js';

function fakeAuth({ status = 'INVITACION_PENDIENTE', stored = null, acceptFails = false, confirmed = true } = {}) {
  const token = 'x.' + btoa(JSON.stringify({ iat: 2000000000 })) + '.y';
  const st = { profile: { id: 'u-1', email: 'invitado@example.invalid', role: 'OPERARIO_DEPOSITO', status }, password: stored, session: true, accepts: 0, signOuts: [] };
  const sb = {
    st,
    // Permisos confirmados, sin otorgamientos: la activación no depende de permisos de operación.
    rpc: async (name, args) => {
      expect(name).toBe('user_effective_permissions');
      expect(args).toEqual({ p_user: st.profile.id });
      return { data: [], error: null };
    },
    auth: {
      getSession: async () => ({ data: { session: st.session ? { user: { id: 'u-1' }, access_token: token } : null } }),
      updateUser: async ({ password }) => {
        if (st.password === password) return { error: { code: 'same_password', status: 422, message: 'New password should be different from the old password.' } };
        st.password = password; return { error: null };
      },
      signInWithPassword: async ({ email, password }) => {
        if (email !== st.profile.email || password !== st.password) return { data: {}, error: { code: 'invalid_credentials', status: 400, message: 'Invalid login credentials' } };
        if (!confirmed) return { data: {}, error: { code: 'email_not_confirmed', status: 400, message: 'Email not confirmed' } };
        st.session = true; return { data: { user: { id: 'u-1' } }, error: null };
      },
      signOut: async (o) => { st.signOuts.push((o && o.scope) || 'local'); if (!o || o.scope !== 'others') st.session = false; }
    },
    from: (table) => table === 'user_carriers' ? { select: () => ({ eq: async () => ({ data: [] }) }) }
      : { select: () => ({ eq: () => ({ maybeSingle: async () => ({ data: table === 'profiles' ? { ...st.profile } : null }) }) }) },
    functions: { invoke: async (name, { body }) => {
      if (body.action === 'accept_invite') {
        st.accepts++;
        if (acceptFails) return { data: null, error: { message: 'Edge Function returned a non-2xx status code', context: { json: async () => ({ error: 'No se pudo activar tu usuario: timeout', code: 'ACCEPT_FAILED' }) } } };
        st.profile.status = 'ACTIVO'; return { data: { user: st.profile }, error: null };
      }
      return { data: {}, error: null };
    } }
  };
  return sb;
}
const apiWith = sb => new SupabaseApi('http://x', 'anon', sb);

describe('Invitación: primer ingreso, reintentos y acceso posterior', () => {
  it('INV-01 primer ingreso: guarda la contraseña y activa al usuario', async () => {
    const sb = fakeAuth(); await apiWith(sb).setPassword('Clave-Segura-1');
    expect(sb.st.password).toBe('Clave-Segura-1'); expect(sb.st.profile.status).toBe('ACTIVO');
  });
  it('INV-02 reintento después de guardado parcial: la contraseña quedó guardada y la activación falló → al reintentar con la MISMA, activa (no queda atrapado)', async () => {
    const sb = fakeAuth({ acceptFails: true }), api = apiWith(sb);
    await expect(api.setPassword('Clave-Segura-1')).rejects.toMatchObject({ code: 'ACCEPT_FAILED' });
    expect(sb.st.password).toBe('Clave-Segura-1'); expect(sb.st.profile.status).toBe('INVITACION_PENDIENTE');
    // vuelve a la pantalla CREAR CONTRASEÑA y pone la misma: antes fallaba con "should be different" y nunca activaba
    const sb2 = fakeAuth({ stored: 'Clave-Segura-1' }); await apiWith(sb2).setPassword('Clave-Segura-1');
    expect(sb2.st.profile.status).toBe('ACTIVO'); expect(sb2.st.accepts).toBe(1);
  });
  it('INV-03 misma contraseña: same_password NO se muestra como error y activa la invitación', async () => {
    const sb = fakeAuth({ stored: 'Clave-Segura-1' });
    await expect(apiWith(sb).setPassword('Clave-Segura-1')).resolves.toBeUndefined();
    expect(sb.st.profile.status).toBe('ACTIVO');
  });
  it('INV-04 cualquier OTRO error al guardar la contraseña se sigue informando (no se oculta) y NO activa', async () => {
    const sb = fakeAuth(); sb.auth.updateUser = async () => ({ error: { code: 'weak_password', message: 'Password should be at least 8 characters' } });
    await expect(apiWith(sb).setPassword('x')).rejects.toMatchObject({ code: 'PASSWORD_FAILED' }); expect(sb.st.profile.status).toBe('INVITACION_PENDIENTE');
  });
  it('INV-05 enlace de recuperación usado por un invitado (p. ej. "reenviar invitación" de un usuario ya registrado): queda activo', async () => {
    const sb = fakeAuth(); await apiWith(sb).completePasswordReset('Clave-Segura-1');
    expect(sb.st.password).toBe('Clave-Segura-1'); expect(sb.st.profile.status).toBe('ACTIVO'); expect(sb.st.signOuts).toContain('others');
  });
  it('INV-06 recuperación con activación fallida: guarda la contraseña pero informa que NO quedó activado (no se presenta como activado)', async () => {
    const sb = fakeAuth({ acceptFails: true }); const r = await apiWith(sb).completePasswordReset('Clave-Segura-1');
    expect(r).toMatchObject({ ok: true, passwordSaved: true, pendingInvite: true, activated: false }); expect(r.activationError).toMatch(/no se pudo activar/);
    expect(sb.st.password).toBe('Clave-Segura-1'); expect(sb.st.profile.status).toBe('INVITACION_PENDIENTE');
  });
  it('INV-05b recuperación con invitación pendiente que se activa: lo informa como activado', async () => {
    const r = await apiWith(fakeAuth()).completePasswordReset('Clave-Segura-1'); expect(r).toMatchObject({ pendingInvite: true, activated: true, activationError: null });
  });
  it('INV-11 recuperación: un error distinto de same_password NO se oculta ni se trata como éxito', async () => {
    const sb = fakeAuth(); sb.auth.updateUser = async () => ({ error: { code: 'weak_password', message: 'Password is known to be weak' } });
    await expect(apiWith(sb).completePasswordReset('Clave-Segura-1')).rejects.toThrow(/No se pudo cambiar la contraseña/); expect(sb.st.accepts).toBe(0);
  });
  it('INV-12 recuperación con la MISMA contraseña ya guardada: continúa y activa', async () => {
    const sb = fakeAuth({ stored: 'Clave-Segura-1' }); const r = await apiWith(sb).completePasswordReset('Clave-Segura-1');
    expect(r.activated).toBe(true); expect(sb.st.profile.status).toBe('ACTIVO');
  });
  it('INV-13 usuario ARCHIVADO: ni la creación ni la recuperación lo activan', async () => {
    const sb = fakeAuth({ status: 'ARCHIVADO' }); await apiWith(sb).setPassword('Clave-Segura-1'); const r = await apiWith(sb).completePasswordReset('Otra-Clave-2');
    expect(sb.st.accepts).toBe(0); expect(sb.st.profile.status).toBe('ARCHIVADO'); expect(r.activated).toBe(false);
  });
  it('INV-07 acceso posterior: con la contraseña guardada el login funciona y la activación posterior es idempotente', async () => {
    const sb = fakeAuth({ stored: 'Clave-Segura-1' }), api = apiWith(sb);
    await expect(api.signIn('invitado@example.invalid', 'Clave-Segura-1')).resolves.toMatchObject({ userId: 'u-1' });
    await api.acceptInvite(); await api.acceptInvite(); expect(sb.st.profile.status).toBe('ACTIVO');
  });
  it('INV-08 login: credenciales inválidas siguen siendo un mensaje genérico (no revela si el email existe)', async () => {
    const sb = fakeAuth({ stored: 'Clave-Segura-1' });
    await expect(apiWith(sb).signIn('invitado@example.invalid', 'otra1234')).rejects.toMatchObject({ message: 'Email o contraseña incorrectos.', code: 'INVALID_CREDENTIALS' });
    await expect(apiWith(sb).signIn('noexiste@x.com', 'Clave-Segura-1')).rejects.toMatchObject({ message: 'Email o contraseña incorrectos.' });
  });
  it('INV-09 login: email sin confirmar ya no se disfraza de "contraseña incorrecta"', async () => {
    const sb = fakeAuth({ stored: 'Clave-Segura-1', confirmed: false });
    await expect(apiWith(sb).signIn('invitado@example.invalid', 'Clave-Segura-1')).rejects.toMatchObject({ code: 'EMAIL_NOT_CONFIRMED' });
  });
  it('INV-10 un usuario deshabilitado sigue sin poder activarse (no se debilitan permisos)', async () => {
    const sb = fakeAuth({ status: 'DESHABILITADO', stored: 'Clave-Segura-1' }); const r = await apiWith(sb).acceptInvite();
    expect(sb.st.accepts).toBe(0); expect(r.status).toBe('DESHABILITADO');
  });
});
