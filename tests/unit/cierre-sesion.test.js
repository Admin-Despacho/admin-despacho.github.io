// CORRECCIÓN DE CIERRE DE SESIÓN · pruebas SIMULADAS (dependencias controladas) del código REAL de SupabaseApi.signOut y revokePushOnLogout.
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { SupabaseApi } from '../../src/online/supabase-api.js';
import { revokePushOnLogout, retryPendingPushUnsubscribe } from '../../src/online/push-notifications.js';

const NEVER = () => new Promise(() => {});
function memStorage(init = {}) { const m = new Map(Object.entries(init)); return { getItem: k => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)), removeItem: k => m.delete(k), key: i => [...m.keys()][i] ?? null, get length() { return m.size; }, _m: m, clear: () => { throw new Error('clear() PROHIBIDO'); } }; }
const KEY = 'sb-uqwilzzeyfuatlmwzxna-auth-token';
function fakeSb(signOutImpl, localImpl) {
  const calls = [];
  return { calls, auth: { storageKey: KEY, stopAutoRefresh: () => calls.push('stopAutoRefresh'),
    signOut: (opts) => { calls.push(opts ? 'signOut:' + opts.scope : 'signOut'); return opts && opts.scope === 'local' ? (localImpl ? localImpl() : Promise.resolve({ error: null })) : signOutImpl(); } } };
}
beforeEach(() => { globalThis.localStorage = memStorage({ [KEY]: '{"access_token":"x"}', [KEY + '-code-verifier']: 'v', okd_pin_v1_u1_last: '{"at":1}', 'okd_queue:x': '[1]' }); });
afterEach(() => { vi.useRealTimers(); });

describe('SupabaseApi.signOut · Auth (simulado)', () => {
  const run = async (impl, local) => { const sb = fakeSb(impl, local); const api = new SupabaseApi('https://x.supabase.co', 'k', sb); return { r: await api.signOut(), sb }; };
  it('CS-A1 normal: revoca con el MISMO alcance que antes (sin argumentos), no llama al cierre local y retira solo las claves de sesión', async () => {
    const { r, sb } = await run(() => Promise.resolve({ error: null }));
    expect(r.remote).toBe('OK'); expect(sb.calls).toEqual(['stopAutoRefresh', 'signOut']);
    expect(localStorage.getItem(KEY)).toBeNull(); expect(localStorage.getItem('okd_pin_v1_u1_last')).not.toBeNull(); expect(localStorage.getItem('okd_queue:x')).toBe('[1]');
  });
  it('CS-A2 Auth responde {error}: se informa ERROR (no se presenta como revocada), se cierra la sesión LOCAL y se retiran sus claves', async () => {
    const { r, sb } = await run(() => Promise.resolve({ error: { message: 'Failed to fetch' } }));
    expect(r.remote).toBe('ERROR'); expect(r.detail).toMatch(/Failed to fetch/); expect(sb.calls).toContain('signOut:local'); expect(localStorage.getItem(KEY)).toBeNull();
  });
  it('CS-A3 Auth RECHAZA: ERROR, cierre local, y signOut nunca rechaza hacia la app', async () => {
    const { r, sb } = await run(() => Promise.reject(new TypeError('NetworkError')));
    expect(r.remote).toBe('ERROR'); expect(sb.calls).toContain('signOut:local'); expect(localStorage.getItem(KEY)).toBeNull();
  });
  it('CS-A4 Auth PENDIENTE para siempre (y también el cierre local): termina en ~7 s con SIN_RESPUESTA y las claves de sesión retiradas', async () => {
    vi.useFakeTimers(); const sb = fakeSb(NEVER, NEVER); const api = new SupabaseApi('https://x.supabase.co', 'k', sb);
    const p = api.signOut(); await vi.advanceTimersByTimeAsync(7100); const r = await p;
    expect(r.remote).toBe('SIN_RESPUESTA'); expect(localStorage.getItem(KEY)).toBeNull(); expect(localStorage.getItem(KEY + '-code-verifier')).toBeNull();
    expect(localStorage.getItem('okd_pin_v1_u1_last')).not.toBeNull();   // PIN y demás claves de la app intactos
  });
});

describe('revokePushOnLogout · operaciones del navegador (simulado)', () => {
  let ops;
  const setup = (o = {}) => {
    ops = { revoke: 0, unsub: 0 };
    const sub = { endpoint: 'https://push.invalid/e1', unsubscribe: () => { ops.unsub++; return (o.unsub || (() => Promise.resolve(true)))(); } };
    const reg = { pushManager: { getSubscription: () => (o.getSub || (() => Promise.resolve(sub)))() } };
    globalThis.window = { PushManager: function () {}, Notification: function () {} }; globalThis.Notification = function () {};
    Object.defineProperty(globalThis, 'navigator', { value: { serviceWorker: { getRegistration: () => (o.getReg || (() => Promise.resolve(reg)))() } }, configurable: true });
    return { revokePushSubscription: () => { ops.revoke++; return (o.revoke || (() => Promise.resolve(true)))(); } };
  };
  const timed = async (api) => { vi.useFakeTimers(); const p = revokePushOnLogout(api); await vi.advanceTimersByTimeAsync(4600); return p; };
  it('CS-P1 normal: revoca en el servidor y da de baja el dispositivo; sin marca pendiente', async () => {
    const r = await revokePushOnLogout(setup()); expect(r).toEqual({ servidor: 'OK', dispositivo: 'OK' }); expect(localStorage.getItem('okd_push_unsub_pending')).toBeNull();
  });
  for (const [name, o, expected] of [
    ['getRegistration PENDIENTE', { getReg: NEVER }, { dispositivo: 'NO_CONFIRMADA' }],
    ['getSubscription PENDIENTE', { getSub: NEVER }, { dispositivo: 'NO_CONFIRMADA' }],
    ['unsubscribe PENDIENTE', { unsub: NEVER }, { servidor: 'OK', dispositivo: 'NO_CONFIRMADA' }],
    ['revocación en el servidor PENDIENTE', { revoke: NEVER }, { servidor: 'NO_CONFIRMADA', dispositivo: 'OK' }],
    ['getRegistration RECHAZA', { getReg: () => Promise.reject(new Error('x')) }, { dispositivo: 'NO_CONFIRMADA' }],
    ['unsubscribe RECHAZA', { unsub: () => Promise.reject(new Error('x')) }, { servidor: 'OK', dispositivo: 'NO_CONFIRMADA' }],
    ['revocación RECHAZA', { revoke: () => Promise.reject(new Error('x')) }, { servidor: 'NO_CONFIRMADA', dispositivo: 'OK' }],
  ]) {
    it('CS-P · ' + name + ': termina en ≤ 4,6 s, informa el resultado REAL y nunca bloquea', async () => {
      const r = await timed(setup(o)); for (const [k, v] of Object.entries(expected)) expect(r[k]).toBe(v);
      expect(localStorage.getItem('okd_push_unsub_pending')).toBe(r.dispositivo === 'NO_CONFIRMADA' ? '1' : null);
    });
  }
  it('CS-P9 baja local PENDIENTE: la próxima carga la REINTENTA y, si se confirma, retira la marca', async () => {
    await timed(setup({ unsub: NEVER })); expect(localStorage.getItem('okd_push_unsub_pending')).toBe('1'); vi.useRealTimers();
    setup(); await retryPendingPushUnsubscribe(); expect(ops.unsub).toBe(1); expect(localStorage.getItem('okd_push_unsub_pending')).toBeNull();
  });
});
