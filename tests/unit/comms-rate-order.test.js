// Comunicaciones · ORDEN y VIGENCIA del cupo de velocidad con varios trabajadores y tokens DEMORADOS.
// Reloj VIRTUAL compartido: se miden los momentos REALES de las solicitudes a messages.send (no los de reserva).
import { describe, it, expect } from 'vitest';
import { dispatch } from '../../supabase/functions/comm-dispatcher/handler.js';
import { gmailProvider } from '../../supabase/functions/comm-dispatcher/adapters.js';
import { MemoryCommsStore } from '../../supabase/functions/_shared/comms-memory-store.js';
import { zonedToUtc } from '../../supabase/functions/_shared/comms-core.js';

const BASE = zonedToUtc('2026-11-02', '09:00') + 60e3;
class VirtualClock {   // todas las esperas avanzan en un mismo reloj, de forma determinista
  constructor() { this.t = 0; this.q = []; }
  sleep(ms) { return new Promise(r => this.q.push({ at: this.t + Math.max(0, ms), r })); }
  at(time, fn) { this.q.push({ at: time, r: fn }); }
  async run(promises) {
    let done = false; const all = Promise.allSettled(promises).then(v => { done = true; return v; });
    for (let g = 0; g < 200000; g++) {
      for (let k = 0; k < 25; k++) await new Promise(r => setImmediate(r));
      if (done) break;
      if (!this.q.length) throw new Error('bloqueo: nada pendiente en el reloj virtual');
      const at = Math.min(...this.q.map(x => x.at)); this.t = Math.max(this.t, at);
      const due = this.q.filter(x => x.at <= this.t); this.q = this.q.filter(x => x.at > this.t); due.forEach(x => x.r());
    }
    const r = await all; const bad = r.find(x => x.status === 'rejected'); if (bad) throw bad.reason; return r.map(x => x.value);
  }
}
const resp = (status, body) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
function setup(n, vt) {
  const s = new MemoryCommsStore(); s.clock = () => BASE + vt.t;
  s.db.gmail = { connected: true, needs_reconnect: false, email: 'comunicados.qa@gmail.com' };
  s.db.collaborators = Array.from({ length: n }, (_, i) => ({ id: 'c' + i, full_name: 'Persona ' + i, email: 'p' + i + '@ejemplo.test', sector: 'Cobranzas', active: true }));
  s.db.messages = [{ id: 'm1', subject: 'Normas', body_html: '<p>Hola</p>', version: 1, status: 'BORRADOR', selection: { sectors: ['Cobranzas'] },
    schedule: { kind: 'WEEKLY', time: '09:00', start_date: '2026-11-01', weekdays: [1] }, attachments: [] }];
  s.activate('m1', Date.parse('2026-11-01T12:00:00Z'));
  return s;
}
// Google simulado a nivel HTTP, con token DEMORADO; registra el momento de cada solicitud de envío y qué token usó
function google(vt, world, { tokenDelay = 1000, expiresIn = 3599, sendStatus } = {}) {
  const f = async (url, init) => {
    if (String(url).includes('/token')) { await vt.sleep(tokenDelay); const id = 'AT' + (++world.tokens); world.issued[id] = vt.t; return resp(200, { access_token: id, expires_in: expiresIn }); }
    const tok = String(init.headers.Authorization).replace('Bearer ', ''); world.sends.push({ t: vt.t, tok });
    const st = sendStatus ? sendStatus(world.sends.length) : 200;
    return st === 200 ? resp(200, { id: 'gm-' + world.sends.length }) : resp(st, { error: { message: 'Invalid Credentials' } });
  };
  return gmailProvider({ refreshToken: async () => 'RT' }, { clientId: 'c', clientSecret: 's', fetch: f, now: () => BASE + vt.t });
}
const maxIn = (times, w) => Math.max(0, ...times.map(t => times.filter(x => x >= t && x < t + w).length));
const workers = (vt, s, world, k, opt = {}, gopt = {}) => Array.from({ length: k }, (_, i) =>
  dispatch(s, google(vt, world, gopt), { now: BASE, worker: 'W' + i, sleep: ms => vt.sleep(ms), maxRateWaitMs: 600e3, limit: 200, ...opt }));

describe('Cupo de velocidad: orden token → cupo → verificación → envío', () => {
  it('T-01 (Codex) 3 trabajadores con token demorado 1.000 ms: como máximo 2 envíos en el mismo segundo (medido en las solicitudes reales)', async () => {
    const vt = new VirtualClock(), s = setup(3, vt), w = { sends: [], tokens: 0, issued: {} };
    await vt.run(workers(vt, s, w, 3, { limit: 1 }));
    const times = w.sends.map(x => x.t);
    expect(times.length).toBe(3); expect(maxIn(times, 1000)).toBeLessThanOrEqual(2);
    expect(times).toEqual([1000, 1000, 2000]);
  });
  it('T-01b (Codex exacto) 3 trabajadores con el MISMO proveedor (caché de token compartida) y token demorado: reservas 0/0/1.000 ms, ≤ 2 envíos por segundo', async () => {
    const vt = new VirtualClock(), s = setup(3, vt), w = { sends: [], tokens: 0, issued: {} };
    const shared = google(vt, w); const reserves = []; const acq = s.acquireRate.bind(s);
    s.acquireRate = async (...a) => { const r = await acq(...a); if (!r.wait_ms) reserves.push(vt.t); return r; };
    await vt.run([0, 1, 2].map(i => dispatch(s, shared, { now: BASE, worker: 'W' + i, sleep: ms => vt.sleep(ms), maxRateWaitMs: 600e3, limit: 1 })));
    const times = w.sends.map(x => x.t);
    expect(times.length).toBe(3); expect(maxIn(times, 1000)).toBeLessThanOrEqual(2);
    expect(reserves.every((r, i) => times.filter(t => t >= r && t < r + 1000).length >= 1)).toBe(true);   // cada reserva representa el segundo de su envío
  });
  it('T-02 3 trabajadores, 90 destinatarios, token demorado: ≤ 2 por segundo y ≤ 60 por minuto en las solicitudes reales', async () => {
    const vt = new VirtualClock(), s = setup(90, vt), w = { sends: [], tokens: 0, issued: {} };
    await vt.run(workers(vt, s, w, 3, { limit: 30 }));
    const times = w.sends.map(x => x.t);
    expect(times.length).toBe(90); expect(maxIn(times, 1000)).toBeLessThanOrEqual(2); expect(maxIn(times, 60e3)).toBeLessThanOrEqual(60);
    expect(s.db.deliveries.every(d => d.status === 'ENVIADO')).toBe(true);
  });
  it('T-03 el token VENCE durante la espera por cupo: se devuelve el cupo, se renueva y se vuelve a reservar; ningún envío usa un token sin margen', async () => {
    const vt = new VirtualClock(), s = setup(70, vt), w = { sends: [], tokens: 0, issued: {} };
    await vt.run(workers(vt, s, w, 3, { limit: 30 }, { tokenDelay: 800, expiresIn: 75 }));   // vigencia útil: 15 s (75 s − 60 s de margen)
    const times = w.sends.map(x => x.t);
    expect(times.length).toBe(70); expect(maxIn(times, 1000)).toBeLessThanOrEqual(2); expect(maxIn(times, 60e3)).toBeLessThanOrEqual(60);
    expect(w.tokens).toBeGreaterThan(3);   // hubo renovaciones por vencimiento
    expect(w.sends.every(x => x.t <= w.issued[x.tok] + 15e3)).toBe(true);
    expect(s.rate.every(e => e.at - BASE <= vt.t)).toBe(true);
  });
  it('T-04 CANCELACIÓN durante la espera por cupo (varios trabajadores): ninguna solicitud de envío después de cancelar', async () => {
    const vt = new VirtualClock(), s = setup(40, vt), w = { sends: [], tokens: 0, issued: {} };
    vt.at(5500, () => s.cancel('m1'));
    await vt.run(workers(vt, s, w, 3, { limit: 20 }));
    expect(w.sends.filter(x => x.t >= 5500)).toHaveLength(0); expect(w.sends.length).toBeGreaterThan(0);
    expect(s.db.deliveries.filter(d => d.status !== 'ENVIADO').every(d => d.status === 'CANCELADO')).toBe(true);
    expect(s.db.deliveries.some(d => d.status === 'ERROR' || d.status === 'POR_VERIFICAR')).toBe(false);
  });
  it('T-05 PAUSA durante la obtención del token: cero solicitudes de envío; pendientes sin gastar intentos', async () => {
    const vt = new VirtualClock(), s = setup(6, vt), w = { sends: [], tokens: 0, issued: {} };
    vt.at(500, () => s.pause('m1'));
    await vt.run(workers(vt, s, w, 3, { limit: 2 }));
    expect(w.sends).toHaveLength(0); expect(s.db.deliveries.every(d => d.status === 'PENDIENTE' && d.attempts === 0)).toBe(true);
  });
  it('T-06 segundo intento tras un 401 con renovación demorada: también token → cupo → verificación; ≤ 2 por segundo contando los 401', async () => {
    const vt = new VirtualClock(), s = setup(4, vt), w = { sends: [], tokens: 0, issued: {} };
    await vt.run(workers(vt, s, w, 2, { limit: 2 }, { sendStatus: n => n <= 2 ? 401 : 200 }));
    const times = w.sends.map(x => x.t);
    expect(times.length).toBe(6); expect(maxIn(times, 1000)).toBeLessThanOrEqual(2);
    expect(s.db.deliveries.every(d => d.status === 'ENVIADO')).toBe(true);
  });
});
