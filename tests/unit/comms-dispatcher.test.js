// Comunicaciones · despachador con almacenamiento en memoria (mismas reglas que el SQL) y Gmail SIMULADO. Datos ficticios.
import { describe, it, expect } from 'vitest';
import { dispatch } from '../../supabase/functions/comm-dispatcher/handler.js';
import { MemoryCommsStore } from '../../supabase/functions/_shared/comms-memory-store.js';
import { zonedToUtc, MAX_ATTEMPTS } from '../../supabase/functions/_shared/comms-core.js';

const PNG = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 7, 7, 7]);
const sha = async b => [...new Uint8Array(await crypto.subtle.digest('SHA-256', b))].map(x => x.toString(16).padStart(2, '0')).join('');
const MON9 = zonedToUtc('2026-11-02', '09:00');   // lunes 2/11/2026 09:00 (Buenos Aires)
const decode = raw => Buffer.from(raw.replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString('utf8');
// Gmail simulado: cada envío consume la próxima respuesta programada (por defecto, aceptado)
class FakeGmail {
  constructor(script = []) { this.script = script; this.sent = []; this.hook = null; }
  async send(raw) {
    if (this.hook) await this.hook(raw);
    const s = this.script.length ? this.script.shift() : 'OK';
    if (s === 'OK') { const id = 'gm-' + (this.sent.length + 1); this.sent.push({ id, raw: decode(raw) }); return { id }; }
    if (s === 'LOST') { this.sent.push({ id: 'gm-perdido', raw: decode(raw) }); throw Object.assign(new Error('connection reset'), { phase: 'AFTER_SEND' }); }   // Gmail lo aceptó pero se perdió la respuesta
    throw Object.assign(new Error(s.reason || 'error'), s);
  }
}
async function setup({ extraCollab = [] } = {}) {
  const store = new MemoryCommsStore();
  store.db.gmail = { connected: true, needs_reconnect: false, email: 'comunicados.qa@gmail.com' };
  store.db.collaborators = [
    { id: 'c1', full_name: 'Ana Díaz', email: 'ana@ejemplo.test', branch: 'Mendoza', sector: 'Cobranzas', active: true },
    { id: 'c2', full_name: 'Bruno Paz', email: 'bruno@ejemplo.test', branch: 'San Juan', sector: 'Cobranzas', active: true },
    { id: 'c3', full_name: 'Carla Ruiz', email: 'carla@ejemplo.test', branch: 'Mendoza', sector: 'Depósito', active: true }, ...extraCollab];
  store.db.blobs['att/1'] = PNG;
  store.db.messages = [{ id: 'm1', internal_name: 'Normas de cobro', subject: 'Recordatorio: normas de cobro', body_html: '<p>Hola, recordá las <b>normas de cobro</b>.</p>', version: 1, status: 'BORRADOR',
    selection: { sectors: ['Cobranzas'] }, schedule: { kind: 'WEEKLY', time: '09:00', start_date: '2026-11-01', weekdays: [1] },
    attachments: [{ id: 'a1', name: 'infografia.png', mime: 'image/png', size_bytes: PNG.length, sha256: await sha(PNG), storage_path: 'att/1' }] }];
  store.activate('m1', Date.parse('2026-11-01T12:00:00Z'));
  return store;
}
const run = (store, gm, now, extra = {}) => dispatch(store, gm, { now, pauseMs: 0, worker: extra.worker || 'w1', ...extra });
const dl = (store, email) => store.db.deliveries.filter(d => d.email === email);

describe('Despachador de comunicaciones', () => {
  it('D-01 lunes 9:00: un correo INDIVIDUAL por colaborador activo seleccionado, con adjunto; se guarda el id de Gmail', async () => {
    const s = await setup(), gm = new FakeGmail();
    expect((await run(s, gm, MON9 - 60e3)).created).toBe(0);   // 8:59: todavía no
    const r = await run(s, gm, MON9 + 2 * 60e3);
    expect(r).toMatchObject({ created: 1, sent: 2, status: 'OK' });
    expect(gm.sent.map(x => x.raw.match(/^To: .*<(.*)>/m)[1]).sort()).toEqual(['ana@ejemplo.test', 'bruno@ejemplo.test']);
    expect(gm.sent.every(x => (x.raw.match(/^To:/gm) || []).length === 1 && !/^(Cc|Bcc):/mi.test(x.raw) && x.raw.includes('filename="infografia.png"'))).toBe(true);
    expect(s.db.deliveries.map(d => [d.status, d.gmail_message_id])).toEqual([['ENVIADO', 'gm-1'], ['ENVIADO', 'gm-2']]);
    expect((await run(s, gm, MON9 + 7 * 60e3)).created).toBe(0);   // el mismo lunes no se repite
  });
  it('D-02 la ejecución usa su COPIA: un reintento envía el contenido original aunque se edite el comunicado', async () => {
    const s = await setup(), gm = new FakeGmail([{ status: 503 }, 'OK']);
    await run(s, gm, MON9 + 60e3);
    s.db.messages[0].subject = 'ASUNTO CAMBIADO'; s.db.messages[0].body_html = '<p>otro</p>';
    const ana = dl(s, 'ana@ejemplo.test')[0]; expect(ana.status).toBe('ERROR');
    await run(s, gm, Date.parse(ana.next_attempt_at) + 1000);
    expect(dl(s, 'ana@ejemplo.test')[0].status).toBe('ENVIADO');
    expect(gm.sent.every(x => x.raw.includes('Subject: Recordatorio: normas de cobro') && !x.raw.includes('ASUNTO CAMBIADO'))).toBe(true);
    expect(s.db.runs[0].snapshot.subject).toBe('Recordatorio: normas de cobro');
  });
  it('D-03 si alguien se desactiva antes de enviarse: OMITIDO con motivo (los demás salen)', async () => {
    const s = await setup(), gm = new FakeGmail(); let first = true;
    gm.hook = async () => { if (first) { first = false; s.db.collaborators.find(c => c.id === 'c2').active = false; } };
    await run(s, gm, MON9 + 60e3);
    expect(dl(s, 'bruno@ejemplo.test')[0]).toMatchObject({ status: 'OMITIDO', reason: 'Colaborador desactivado antes del envío' });
    expect(gm.sent).toHaveLength(1);
  });
  it('D-04 dos trabajadores a la vez: cada correo se envía UNA sola vez (reserva atómica + clave única)', async () => {
    const s = await setup({ extraCollab: [4, 5, 6, 7].map(i => ({ id: 'x' + i, full_name: 'Persona ' + i, email: 'p' + i + '@ejemplo.test', branch: 'Mendoza', sector: 'Cobranzas', active: true })) });
    const gm = new FakeGmail();
    const [a, b] = await Promise.all([run(s, gm, MON9 + 60e3, { worker: 'A', limit: 3 }), run(s, gm, MON9 + 60e3, { worker: 'B', limit: 3 })]);
    await run(s, gm, MON9 + 2 * 60e3, { worker: 'C' });
    const to = gm.sent.map(x => x.raw.match(/^To: .*<(.*)>/m)[1]);
    expect(to.length).toBe(6); expect(new Set(to).size).toBe(6);
    expect(s.db.runs).toHaveLength(1); expect(a.sent + b.sent).toBeLessThanOrEqual(6);
  });
  it('D-05 errores recuperables: reintentos LIMITADOS con espera creciente; no se reintenta antes de tiempo', async () => {
    const s = await setup(), gm = new FakeGmail(Array(20).fill({ status: 503 }));
    await run(s, gm, MON9 + 60e3); let t = MON9 + 60e3;
    for (let i = 0; i < 6; i++) { const d = dl(s, 'ana@ejemplo.test')[0]; if (!d.next_attempt_at || !d.retryable) break;
      expect((await run(s, gm, Date.parse(d.next_attempt_at) - 5000)).claimed).toBe(0);   // antes de tiempo: nada
      t = Date.parse(d.next_attempt_at) + 1000; await run(s, gm, t); }
    const d = dl(s, 'ana@ejemplo.test')[0];
    expect(d).toMatchObject({ status: 'ERROR', retryable: false, attempts: MAX_ATTEMPTS }); expect(d.last_error).toMatch(/Se agotaron los reintentos/);
  });
  it('D-06 respuesta AMBIGUA (Gmail pudo aceptarlo): "Por verificar", NO se reenvía a ciegas; reintento solo por decisión manual', async () => {
    const s = await setup(), gm = new FakeGmail(['LOST', 'OK']);
    await run(s, gm, MON9 + 60e3);
    const ana = dl(s, 'ana@ejemplo.test')[0]; expect(ana.status).toBe('POR_VERIFICAR'); expect(ana.last_error).toMatch(/puede haberse enviado/);
    for (let k = 1; k <= 3; k++) await run(s, gm, MON9 + k * 3600e3);
    expect(gm.sent.filter(x => x.raw.includes('<ana@ejemplo.test>'))).toHaveLength(1);   // un solo intento hacia Gmail
    s.resolveVerify(ana.id, 'REINTENTAR'); await run(s, gm, MON9 + 5 * 3600e3);
    expect(dl(s, 'ana@ejemplo.test')[0].status).toBe('ENVIADO');
  });
  it('D-07 error de AUTORIZACIÓN: hay que reconectar; no se repite y los demás quedan pendientes sin gastar intentos', async () => {
    const s = await setup(), gm = new FakeGmail([{ status: 400, reason: 'invalid_grant' }]);
    const r = await run(s, gm, MON9 + 60e3);
    expect(r).toMatchObject({ auth: true, status: 'REQUIERE_RECONEXION' }); expect(s.db.gmail.needs_reconnect).toBe(true);
    expect(s.db.deliveries.map(d => [d.status, d.attempts])).toEqual([['ERROR', 1], ['PENDIENTE', 0]]);
    const r2 = await run(s, gm, MON9 + 10 * 60e3); expect(r2).toMatchObject({ status: 'SIN_CONEXION', claimed: 0 }); expect(gm.sent).toHaveLength(0);
  });
  it('D-08 CANCELACIÓN mientras se prepara el correo: CERO llamadas a Gmail', async () => {
    const s = await setup(), gm = new FakeGmail(); const f = s.fetchAttachment.bind(s);
    s.fetchAttachment = async a => { s.cancel('m1'); return f(a); };
    await run(s, gm, MON9 + 60e3);
    expect(gm.sent).toHaveLength(0); expect(s.db.deliveries.every(d => d.status === 'CANCELADO')).toBe(true);
  });
  it('D-09 PAUSA durante la preparación: vuelve a pendiente sin gastar intento; al REANUDAR no se envía de golpe lo vencido', async () => {
    const s = await setup(), gm = new FakeGmail(); const f = s.fetchAttachment.bind(s);
    s.fetchAttachment = async a => { s.pause('m1'); return f(a); };
    await run(s, gm, MON9 + 60e3); s.fetchAttachment = f;
    expect(gm.sent).toHaveLength(0); expect(s.db.deliveries.map(d => [d.status, d.attempts])).toEqual([['PENDIENTE', 0], ['PENDIENTE', 0]]);
    const resumeAt = MON9 + 15 * 864e5 + 3600e3;   // reanuda dos semanas después
    s.resume('m1', resumeAt); await run(s, gm, resumeAt + 60e3);
    expect(s.db.runs).toHaveLength(1);   // los lunes 9 y 16 (vencidos en pausa) NO se crean ni se envían
    await run(s, gm, zonedToUtc('2026-11-23', '09:01'));
    expect(s.db.runs.map(r => r.scheduled_for)).toEqual(['2026-11-02T12:00:00.000Z', '2026-11-23T12:00:00.000Z']);
    expect(gm.sent.filter(x => x.raw.includes('<ana@ejemplo.test>'))).toHaveLength(1);   // solo el del 23: el pendiente del 2 NO salió
  });
  it('D-10 ejecución PERDIDA por interrupción (servidor caído): identificada para revisión, SIN envíos masivos', async () => {
    const s = await setup(), gm = new FakeGmail();
    const r = await run(s, gm, MON9 + 3 * 3600e3);   // el programador recién corre 3 h después
    expect(r).toMatchObject({ created: 0, missed: 1, sent: 0 }); expect(s.db.runs[0]).toMatchObject({ status: 'PERDIDA' }); expect(s.db.runs[0].note).toMatch(/NO se envió/);
  });
  it('D-11 un trabajador se cae a mitad de envío: tras 10 min queda "Por verificar" y no se reenvía solo', async () => {
    const s = await setup(), gm = new FakeGmail();
    await run(s, gm, MON9 - 60e3);
    await s.createRun({ message_id: 'm1', scheduled_for: new Date(MON9).toISOString(), kind: 'PROGRAMADO', recipients: [{ collaborator_id: 'c1', email: 'ana@ejemplo.test', name: 'Ana Díaz' }], snapshot: { subject: 's', body_html: 'b', attachments: [] } });
    await s.claim(1, 'muerto', MON9);   // lo reservó y no terminó
    await run(s, gm, MON9 + 11 * 60e3);
    expect(dl(s, 'ana@ejemplo.test')[0].status).toBe('POR_VERIFICAR'); expect(gm.sent.filter(x => x.raw.includes('ana@'))).toHaveLength(0);
  });
  it('D-12 tope diario de seguridad (por debajo del límite de 500 de Gmail)', async () => {
    const s = await setup(), gm = new FakeGmail();
    const r = await run(s, gm, MON9 + 60e3, { dailyCap: 1 });
    expect(gm.sent).toHaveLength(1);
    expect((await run(s, gm, MON9 + 2 * 60e3, { dailyCap: 1 })).status).toBe('LIMITE_DIARIO'); expect(r.sent).toBe(1);
  });
  it('D-13 adjunto alterado después de programar: no se envía (error con motivo)', async () => {
    const s = await setup(), gm = new FakeGmail(); s.db.blobs['att/1'] = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 9]);
    await run(s, gm, MON9 + 60e3);
    expect(gm.sent).toHaveLength(0); expect(s.db.deliveries[0].last_error).toMatch(/no coincide con la copia guardada/);
  });
  it('D-14 envío de PRUEBA a una dirección elegida (también con el comunicado en borrador)', async () => {
    const s = await setup(), gm = new FakeGmail(); s.db.messages[0].status = 'BORRADOR';
    s.requestTest('m1', 'prueba.autorizada@ejemplo.test', MON9); await run(s, gm, MON9 + 1000);
    expect(gm.sent).toHaveLength(1); expect(gm.sent[0].raw).toContain('<prueba.autorizada@ejemplo.test>');
  });
  it('D-15 lo ya ENVIADO no cambia al editar el comunicado (copia y registros intactos)', async () => {
    const s = await setup(), gm = new FakeGmail(); await run(s, gm, MON9 + 60e3);
    const before = JSON.stringify({ runs: s.db.runs, deliveries: s.db.deliveries });
    Object.assign(s.db.messages[0], { subject: 'Nuevo', body_html: '<p>nuevo</p>', version: 2, attachments: [] });
    expect(JSON.stringify({ runs: s.db.runs, deliveries: s.db.deliveries })).toBe(before);
  });
  // ===================== Defectos reproducidos por Codex =====================
  const persistFast = { persistRetries: [0, 0, 0] };
  it('D-16 Gmail ACEPTÓ y registrar falla UNA vez ("fetch failed"): se reintenta SOLO el registro; un único envío y se guarda el id', async () => {
    const s = await setup(), gm = new FakeGmail(); const f = s.finish.bind(s); let fails = 1;
    s.finish = async (...a) => { if (a[2].outcome === 'ACCEPTED' && fails-- > 0) throw new Error('registrar resultado: fetch failed'); return f(...a); };
    await run(s, gm, MON9 + 60e3, persistFast); await run(s, gm, MON9 + 5 * 60e3, persistFast); await run(s, gm, MON9 + 30 * 60e3, persistFast);
    expect(gm.sent.filter(x => x.raw.includes('<ana@ejemplo.test>'))).toHaveLength(1);
    expect(dl(s, 'ana@ejemplo.test')[0]).toMatchObject({ status: 'ENVIADO', gmail_message_id: 'gm-1' });
  });
  it('D-17 registrar falla SIEMPRE tras la aceptación: NO se reenvía nunca; queda "Por verificar" y el id de Gmail queda en el resumen', async () => {
    const s = await setup(), gm = new FakeGmail(); const f = s.finish.bind(s);
    s.finish = async (...a) => { if (a[2].outcome === 'ACCEPTED') throw new Error('registrar resultado: fetch failed'); return f(...a); };
    const r = await run(s, gm, MON9 + 60e3, persistFast);
    expect(r).toMatchObject({ status: 'ERROR_REGISTRO', sent: 0 }); expect(r.unrecorded).toEqual([{ delivery: dl(s, 'ana@ejemplo.test')[0].id, gmail_id: 'gm-1' }]);
    s.finish = f;   // la base vuelve
    await run(s, gm, MON9 + 5 * 60e3, persistFast); await run(s, gm, MON9 + 12 * 60e3, persistFast); await run(s, gm, MON9 + 60 * 60e3, persistFast);
    expect(gm.sent.filter(x => x.raw.includes('<ana@ejemplo.test>'))).toHaveLength(1);   // jamás un segundo envío
    expect(dl(s, 'ana@ejemplo.test')[0].status).toBe('POR_VERIFICAR');
    expect(dl(s, 'bruno@ejemplo.test')[0].status).toBe('ENVIADO');   // el que no llegó a enviarse se liberó y salió después
  });
  it('D-18 el PROCESO se cae entre la aceptación de Gmail y el registro: el siguiente trabajador NO lo reenvía (queda "Por verificar")', async () => {
    const s = await setup(), gm = new FakeGmail(); const f = s.finish.bind(s), rec = s.recordDispatch.bind(s), rel = s.release.bind(s);
    const dead = async () => { throw new Error('proceso terminado'); };
    s.finish = async (...a) => a[2].outcome === 'ACCEPTED' ? dead() : f(...a); s.recordDispatch = dead; s.release = dead;
    await run(s, gm, MON9 + 60e3, { persistRetries: [], limit: 1 });
    Object.assign(s, { finish: f, recordDispatch: rec, release: rel });
    await run(s, gm, MON9 + 6 * 60e3, persistFast); await run(s, gm, MON9 + 15 * 60e3, persistFast);
    expect(gm.sent.filter(x => x.raw.includes('<ana@ejemplo.test>'))).toHaveLength(1); expect(dl(s, 'ana@ejemplo.test')[0].status).toBe('POR_VERIFICAR');
  });
  it('D-19 (Codex) pendiente del 2/11 ya encolado, pausa y reanudación el 17/11: NO llega a Gmail; queda VENCIDO en el historial', async () => {
    const s = await setup(), gm = new FakeGmail();
    await run(s, gm, MON9 + 60e3, { limit: 0 });   // se creó la ejecución del 2/11 pero todavía no se envió
    s.pause('m1'); const nov17 = zonedToUtc('2026-11-17', '10:00'); s.resume('m1', nov17);
    const r = await run(s, gm, nov17 + 60e3);
    expect(gm.sent).toHaveLength(0); expect(r.sent).toBe(0);
    const d2 = s.db.deliveries.filter(d => d.run_id === s.db.runs[0].id);
    expect(d2.map(d => d.status)).toEqual(['VENCIDO', 'VENCIDO']); expect(d2[0].reason).toMatch(/Queda para revisión; no se envía automáticamente/);
    await run(s, gm, zonedToUtc('2026-11-23', '09:01'));
    expect(gm.sent).toHaveLength(2);   // el lunes siguiente sí, normalmente
  });
  it('D-20 un REINTENTO que excede la ventana de envío queda VENCIDO (Gmail no se vuelve a llamar)', async () => {
    const s = await setup(), gm = new FakeGmail([{ status: 503 }, { status: 503 }]);
    await run(s, gm, MON9 + 60e3); const calls = gm.script.length;
    await run(s, gm, MON9 + 7 * 3600e3);
    expect(gm.script.length).toBe(calls); expect(gm.sent).toHaveLength(0);
    expect(s.db.deliveries.map(d => d.status)).toEqual(['VENCIDO', 'VENCIDO']);
  });
  it('D-21 un VENCIDO solo vuelve a enviarse por decisión MANUAL', async () => {
    const s = await setup(), gm = new FakeGmail(); await run(s, gm, MON9 + 60e3, { limit: 0 });
    await run(s, gm, MON9 + 8 * 3600e3); const ana = dl(s, 'ana@ejemplo.test')[0]; expect(ana.status).toBe('VENCIDO');
    s.resolveVerify(ana.id, 'REINTENTAR', MON9 + 8 * 3600e3); await run(s, gm, MON9 + 8 * 3600e3 + 60e3);
    expect(dl(s, 'ana@ejemplo.test')[0].status).toBe('ENVIADO'); expect(dl(s, 'bruno@ejemplo.test')[0].status).toBe('VENCIDO');
  });
  it('D-22 (Codex) cupo diario = 1 con DOS trabajadores a la vez: sale UN solo correo (cupo reservado en la reserva)', async () => {
    const s = await setup(), gm = new FakeGmail();
    await Promise.all([run(s, gm, MON9 + 60e3, { worker: 'A', dailyCap: 1 }), run(s, gm, MON9 + 60e3, { worker: 'B', dailyCap: 1 })]);
    expect(gm.sent).toHaveLength(1);
    s.requestTest('m1', 'prueba@ejemplo.test', MON9 + 2 * 60e3); await run(s, gm, MON9 + 3 * 60e3, { dailyCap: 1 });
    expect(gm.sent).toHaveLength(1);   // las PRUEBAS también consumen el cupo
  });
  it('D-23 (Codex) adjunto con cabecera MZ declarado PDF y hash COINCIDENTE: CERO llamadas a Gmail', async () => {
    const s = await setup(), gm = new FakeGmail(), mz = new Uint8Array([0x4d, 0x5a, 0x90, 0, 3, 0, 0, 0]);
    s.db.blobs['att/mz'] = mz; s.db.messages[0].attachments = [{ id: 'a2', name: 'manual.pdf', mime: 'application/pdf', size_bytes: mz.length, sha256: await sha(mz), storage_path: 'att/mz' }];
    await run(s, gm, MON9 + 60e3);
    expect(gm.sent).toHaveLength(0); expect(s.db.deliveries[0]).toMatchObject({ status: 'ERROR', error_code: 'ATTACHMENT_INVALID' });
  });
  it('D-24 (Codex) cupo = 1: Gmail acepta pero se pierde la respuesta → "Por verificar" → confirmado a mano: SIGUE contando; no sale un segundo correo', async () => {
    const s = await setup(), gm = new FakeGmail(['LOST', 'OK', 'OK']);
    await run(s, gm, MON9 + 60e3, { dailyCap: 1 });
    const ana = dl(s, 'ana@ejemplo.test')[0]; expect(ana.status).toBe('POR_VERIFICAR');
    s.resolveVerify(ana.id, 'CONFIRMADO_ENVIADO', MON9 + 30 * 60e3);
    const conf = dl(s, 'ana@ejemplo.test')[0];
    expect(conf).toMatchObject({ status: 'ENVIADO', sent_at: conf.claimed_at, sent_at_source: 'ESTIMADA_INICIO_INTENTO' });   // hora estimada = inicio del intento
    expect(conf.confirmed_at).toBe(new Date(MON9 + 30 * 60e3).toISOString());                                                    // confirmación, aparte
    await Promise.all([run(s, gm, MON9 + 40 * 60e3, { dailyCap: 1, worker: 'A' }), run(s, gm, MON9 + 40 * 60e3, { dailyCap: 1, worker: 'B' })]);
    expect(gm.sent).toHaveLength(1);   // solo el primero (el "perdido"); Bruno espera
    expect(dl(s, 'bruno@ejemplo.test')[0].status).toBe('PENDIENTE');
    await run(s, gm, MON9 + 864e5 + 2 * 60e3, { dailyCap: 1 });   // el programador corre: Bruno quedó fuera de la ventana → VENCIDO
    expect(dl(s, 'bruno@ejemplo.test')[0].status).toBe('VENCIDO');
    s.resolveVerify(dl(s, 'bruno@ejemplo.test')[0].id, 'REINTENTAR', MON9 + 864e5 + 2 * 60e3);   // habilitación manual
    await run(s, gm, MON9 + 864e5 + 3 * 60e3, { dailyCap: 1 });   // 24 h después del intento de Ana: hay cupo otra vez
    expect(gm.sent).toHaveLength(2);
  });
  it('D-25 velocidad COMPARTIDA: dos trabajadores + pruebas nunca superan 60 envíos/min ni 2/s (6.000 y 200 unidades)', async () => {
    let clock = MON9 + 60e3; const sleep = async ms => { clock += ms; await Promise.resolve(); };
    const many = Array.from({ length: 75 }, (_, i) => ({ id: 'm' + i, full_name: 'Persona ' + i, email: 'p' + i + '@ejemplo.test', branch: 'Mendoza', sector: 'Cobranzas', active: true }));
    const s = await setup({ extraCollab: many }); s.clock = () => clock;
    const times = []; const gm = { send: async (raw, o) => { if (o && o.beforeHttp) await o.beforeHttp(); times.push(clock); return { id: 'gm-' + times.length }; } };
    s.requestTest('m1', 'prueba1@ejemplo.test', MON9); s.requestTest('m1', 'prueba2@ejemplo.test', MON9 + 1);
    const opt = { sleep, limit: 50, dailyCap: 400, maxRateWaitMs: 600e3 };
    await Promise.all([dispatch(s, gm, { ...opt, now: MON9 + 60e3, worker: 'A' }), dispatch(s, gm, { ...opt, now: MON9 + 60e3, worker: 'B' })]);
    expect(times.length).toBe(79);   // 77 programados + 2 pruebas
    const maxIn = w => Math.max(...times.map(t => times.filter(x => x >= t && x < t + w).length));
    expect(maxIn(60e3)).toBeLessThanOrEqual(60); expect(maxIn(1e3)).toBeLessThanOrEqual(2);
    expect(times[times.length - 1] - times[0]).toBeGreaterThanOrEqual(60e3);   // 79 envíos necesitan más de un minuto
  });
});
