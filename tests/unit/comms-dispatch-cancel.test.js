// Comunicaciones · cancelación/pausa DURANTE la espera por cupo y la renovación del token, con el proveedor Gmail REAL (fetch simulado).
// Se cuentan las solicitudes a messages.send: ninguna puede salir después de detectar la cancelación o pausa.
import { describe, it, expect } from 'vitest';
import { dispatch } from '../../supabase/functions/comm-dispatcher/handler.js';
import { gmailProvider, pgStore } from '../../supabase/functions/comm-dispatcher/adapters.js';
import { MemoryCommsStore } from '../../supabase/functions/_shared/comms-memory-store.js';
import { zonedToUtc } from '../../supabase/functions/_shared/comms-core.js';

const MON9 = zonedToUtc('2026-11-02', '09:00'), NOW = MON9 + 60e3;
const resp = (status, body) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
function setup() {
  const s = new MemoryCommsStore();
  s.db.gmail = { connected: true, needs_reconnect: false, email: 'comunicados.qa@gmail.com' };
  s.db.collaborators = [{ id: 'c1', full_name: 'Ana Díaz', email: 'ana@ejemplo.test', sector: 'Cobranzas', active: true },
                        { id: 'c2', full_name: 'Bruno Paz', email: 'bruno@ejemplo.test', sector: 'Cobranzas', active: true }];
  s.db.messages = [{ id: 'm1', subject: 'Normas de cobro', body_html: '<p>Hola</p>', version: 1, status: 'BORRADOR', selection: { sectors: ['Cobranzas'] },
    schedule: { kind: 'WEEKLY', time: '09:00', start_date: '2026-11-01', weekdays: [1] }, attachments: [] }];
  s.activate('m1', Date.parse('2026-11-01T12:00:00Z'));
  return s;
}
// Gmail simulado a nivel HTTP: el proveedor REAL hace las llamadas; 'onToken' / 'onSend' permiten actuar en el medio
function google({ onToken, sendStatus } = {}) {
  const log = []; let n = 0;
  const f = async (url, init) => {
    if (String(url).includes('/token')) { log.push('token'); if (onToken) await onToken(); return resp(200, { access_token: 'AT' + (++n), expires_in: 3599 }); }
    log.push('send'); const st = sendStatus ? sendStatus(log.filter(x => x === 'send').length) : 200;
    return st === 200 ? resp(200, { id: 'gm-' + log.length }) : resp(st, { error: { message: 'Invalid Credentials' } });
  };
  return { log, sends: () => log.filter(x => x === 'send').length, provider: gmailProvider({ refreshToken: async () => 'RT' }, { clientId: 'c', clientSecret: 's', fetch: f }) };
}
const statuses = s => s.db.deliveries.map(d => [d.email, d.status, d.attempts]);

describe('Cancelación y pausa durante esperas (solicitudes reales a messages.send)', () => {
  it('R-01 (Codex) se CANCELA durante la espera por cupo: CERO solicitudes de envío; cancelado, sin error y sin consumir cupo', async () => {
    const s = setup(), g = google(); const acq = s.acquireRate.bind(s); let first = true;
    s.acquireRate = async (...a) => first ? (first = false, { wait_ms: 5000 }) : acq(...a);
    const r = await dispatch(s, g.provider, { now: NOW, sleep: async () => s.cancel('m1') });
    expect(g.sends()).toBe(0); expect(statuses(s).map(x => x[1])).toEqual(['CANCELADO', 'CANCELADO']);
    expect(r).toMatchObject({ failed: 0, retry: 0, sent: 0 }); expect(s.rate).toHaveLength(0);
  });
  it('R-02 se PAUSA durante la espera por cupo: cero envíos; vuelven a PENDIENTE sin gastar intento; al reanudar salen', async () => {
    const s = setup(), g = google(); const acq = s.acquireRate.bind(s); let first = true;
    s.acquireRate = async (...a) => first ? (first = false, { wait_ms: 5000 }) : acq(...a);
    await dispatch(s, g.provider, { now: NOW, sleep: async () => s.pause('m1') });
    expect(g.sends()).toBe(0); expect(statuses(s)).toEqual([['ana@ejemplo.test', 'PENDIENTE', 0], ['bruno@ejemplo.test', 'PENDIENTE', 0]]);
    s.resume('m1', NOW + 60e3); await dispatch(s, g.provider, { now: NOW + 2 * 60e3 });
    expect(g.sends()).toBe(2); expect(statuses(s).map(x => x[1])).toEqual(['ENVIADO', 'ENVIADO']);
  });
  it('R-03 se CANCELA durante la RENOVACIÓN del token: cero envíos y el cupo reservado se devuelve', async () => {
    const s = setup(); const g = google({ onToken: async () => s.cancel('m1') });
    await dispatch(s, g.provider, { now: NOW });
    expect(g.sends()).toBe(0); expect(statuses(s).map(x => x[1])).toEqual(['CANCELADO', 'CANCELADO']); expect(s.rate).toHaveLength(0);
  });
  it('R-04 se PAUSA durante el SEGUNDO intento tras un 401 (renovación forzada): solo existe el primer pedido (no procesado por Gmail)', async () => {
    const s = setup(); let tokens = 0;
    const g = google({ sendStatus: () => 401, onToken: async () => { if (++tokens === 2) s.pause('m1'); } });
    const r = await dispatch(s, g.provider, { now: NOW });
    expect(g.sends()).toBe(1);   // el 401 inicial; tras la pausa no sale ninguno más (ni el reintento, ni Bruno)
    expect(statuses(s)).toEqual([['ana@ejemplo.test', 'PENDIENTE', 0], ['bruno@ejemplo.test', 'PENDIENTE', 0]]);
    expect(r).toMatchObject({ failed: 0, retry: 0, auth: false }); expect(s.rate).toHaveLength(1);   // solo cuenta la llamada que existió
  });
  it('R-05 se DESACTIVA el destinatario durante la espera: queda OMITIDO con motivo, sin enviarse', async () => {
    const s = setup(), g = google(); const acq = s.acquireRate.bind(s); let first = true;
    s.acquireRate = async (...a) => first ? (first = false, { wait_ms: 3000 }) : acq(...a);
    await dispatch(s, g.provider, { now: NOW, sleep: async () => { s.db.collaborators[0].active = false; } });
    expect(g.sends()).toBe(1);   // solo Bruno
    expect(s.db.deliveries.find(d => d.email === 'ana@ejemplo.test')).toMatchObject({ status: 'OMITIDO', reason: 'Colaborador desactivado antes del envío' });
  });
  it('R-06 Gmail se DESCONECTA durante la renovación del token: cero envíos; vuelven a PENDIENTE sin gastar intento', async () => {
    const s = setup(); const g = google({ onToken: async () => { s.db.gmail.connected = false; } });
    await dispatch(s, g.provider, { now: NOW });
    expect(g.sends()).toBe(0); expect(statuses(s)).toEqual([['ana@ejemplo.test', 'PENDIENTE', 0], ['bruno@ejemplo.test', 'PENDIENTE', 0]]);
  });
  it('R-07 espera de cupo demasiado larga: NO es error de Gmail; vuelven a PENDIENTE sin gastar intento', async () => {
    const s = setup(), g = google(); s.acquireRate = async () => ({ wait_ms: 60e3 });
    const r = await dispatch(s, g.provider, { now: NOW, sleep: async () => {}, maxRateWaitMs: 90e3 });
    expect(g.sends()).toBe(0); expect(r).toMatchObject({ status: 'CUPO_VELOCIDAD', failed: 0, retry: 0 });
    expect(statuses(s)).toEqual([['ana@ejemplo.test', 'PENDIENTE', 0], ['bruno@ejemplo.test', 'PENDIENTE', 0]]);
  });
  it('R-08 orden real: inmediatamente ANTES de cada solicitud de envío está la verificación final (y el token se obtuvo antes)', async () => {
    const s = setup(), ev = []; const chk = s.check.bind(s); s.check = async (...a) => { ev.push('check'); return chk(...a); };
    const g = google({ sendStatus: n => n === 1 ? 401 : 200 });
    const p = g.provider, post = p.post, prep = p.prepare;
    p.post = async (...a) => { ev.push('send'); return post(...a); }; p.prepare = async (...a) => { ev.push('token'); return prep(...a); };
    await dispatch(s, p, { now: NOW });
    const sends = ev.map((e, i) => [e, i]).filter(([e]) => e === 'send').map(([, i]) => i);
    expect(sends.length).toBe(3);   // Ana: 401 + 2º intento; Bruno: 1
    expect(sends.every(i => ev[i - 1] === 'check' && ev[i - 2] === 'token')).toBe(true);
  });
  it('CL-01 la limpieza automática de adjuntos está DESACTIVADA: el despachador no borra archivos', async () => {
    const s = setup(), g = google(); let called = 0; s.cleanupOrphans = async () => { called++; return 1; };
    await dispatch(s, g.provider, { now: NOW });
    expect(called).toBe(0); expect('cleanupOrphans' in pgStore({})).toBe(false);
  });
});
