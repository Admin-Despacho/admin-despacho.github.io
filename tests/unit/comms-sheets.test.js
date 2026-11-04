// Correo diario de PDF de hojas por la cuenta GMAIL de Comunicaciones (despachador real, almacenamiento en memoria, Gmail SIMULADO).
// Hojas PUBLICADAS o tercerizados DESPACHADOS; versión VIGENTE; PDF tardío; estado y versión verificados antes de cada envío.
import { describe, it, expect } from 'vitest';
import { dispatch } from '../../supabase/functions/comm-dispatcher/handler.js';
import { MemoryCommsStore } from '../../supabase/functions/_shared/comms-memory-store.js';
import { zonedToUtc } from '../../supabase/functions/_shared/comms-core.js';

const DAY = '2026-11-02', PREV = '2026-11-01', NEXT = '2026-11-03', T = (hm, d = DAY) => zonedToUtc(d, hm), iso = t => new Date(t).toISOString();
const PDF = new TextEncoder().encode('%PDF-1.4\n% hoja ficticia de prueba\n');
const raw = r => Buffer.from(r.replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString();
const subject = r => { const m = r.match(/^Subject: =\?UTF-8\?B\?([^?]+)\?=/m); return m ? Buffer.from(m[1], 'base64').toString() : ''; };
const route = (id, number, o = {}) => ({ id, number, version: 1, operational_status: 'PUBLICADA', dispatch_mode: 'APP', published_at: iso(T('09:00')), dispatched_at: null, ...o });
function addPdf(s, r, version, generatedAt) {
  const path = r.id + '/v' + version + '/Hoja_' + r.number + '_v' + version + '.pdf';
  s.db.sheetPdfs.push({ route_id: r.id, route_version: version, route_number: r.number, file_name: 'Hoja_' + r.number + '_v' + version + '.pdf', storage_path: path, status: 'OK', generated_at: iso(generatedAt) });
  s.db.blobs['route-pdfs:' + path] = PDF;
}
function setup({ via = 'GMAIL', recipients = ['logistica@ejemplo.test', 'admin@ejemplo.test'], routes = 2 } = {}) {
  const s = new MemoryCommsStore();
  s.db.gmail = { connected: true, needs_reconnect: false, email: 'comunicados.qa@gmail.com' };
  s.db.sheet = { enabled: true, via, time: '17:35', recipients }; s.db.sheetRoutes = []; s.db.sheetPdfs = [];
  for (let i = 0; i < routes; i++) { const r = route('r' + i, '03-00012' + i); s.db.sheetRoutes.push(r); addPdf(s, r, 1, T('09:0' + (i + 1))); }
  return s;
}
function gmail(script = []) { const sent = []; return { sent, send: async r => { const st = script.shift(); if (st) throw Object.assign(new Error('Gmail ' + st), { status: st }); sent.push(raw(r)); return { id: 'gm-' + sent.length }; } }; }
const sheetDeliveries = s => s.db.deliveries.filter(d => (s._run(d.run_id) || {}).kind === 'HOJAS');
const R = (s, id) => s.db.sheetRoutes.find(x => x.id === id);

describe('Correo diario de hojas por Gmail', () => {
  it('HG-01 hojas PUBLICADAS (sin esperar a que el chofer termine): antes del horario nada; desde las 17:35, un correo por hoja y destinatario', async () => {
    const s = setup(), g = gmail();
    await dispatch(s, g, { now: T('17:30') }); expect(g.sent).toHaveLength(0); expect(s.db.runs).toHaveLength(0);
    await dispatch(s, g, { now: T('17:36') });
    expect(g.sent).toHaveLength(4);
    expect(g.sent.filter(x => subject(x) === 'OK Despacho · Hoja 03-000120 (v1)' && x.includes('filename="Hoja_03-000120_v1.pdf"'))).toHaveLength(2);
    expect(s.db.messages.find(m => m.system_kind === 'HOJAS_DIA')).toMatchObject({ status: 'ACTIVO', internal_name: 'Correo diario de hojas (automático)' });
  });
  it('HG-02 repetir el despachador NO duplica (una ejecución por hoja y versión)', async () => {
    const s = setup(), g = gmail();
    await dispatch(s, g, { now: T('17:36') }); await dispatch(s, g, { now: T('17:41') }); await dispatch(s, g, { now: T('17:46') });
    expect(g.sent).toHaveLength(4); expect(s.db.runs.filter(r => r.kind === 'HOJAS')).toHaveLength(2);
  });
  it('HG-04 con el canal RESEND no se encola nada por Gmail', async () => {
    const s = setup({ via: 'RESEND' }), g = gmail(); await dispatch(s, g, { now: T('17:36') });
    expect(g.sent).toHaveLength(0); expect(s.db.runs).toHaveLength(0);
  });
  it('HG-05 lo que ya salió por Resend no se repite por Gmail', async () => {
    const s = setup({ routes: 1 }), g = gmail(); s.db.resendSent = ['r0|1|logistica@ejemplo.test'];
    await dispatch(s, g, { now: T('17:36') }); expect(g.sent).toHaveLength(1); expect(g.sent[0]).toContain('admin@ejemplo.test');
  });
  it('HG-06 encolado y cambiado a RESEND antes de enviar: se CANCELA, cero envíos por Gmail', async () => {
    const s = setup(), g = gmail(); await dispatch(s, g, { now: T('17:36'), limit: 0 });
    s.db.sheet.via = 'RESEND'; await dispatch(s, g, { now: T('17:41') });
    expect(g.sent).toHaveLength(0); expect(sheetDeliveries(s).every(d => d.status === 'CANCELADO')).toBe(true);
  });
  it('HG-07 pausado en Comunicaciones: no sale; al reanudar dentro de la ventana sale', async () => {
    const s = setup({ routes: 1 }), g = gmail(); await dispatch(s, g, { now: T('17:36'), limit: 0 });
    const m = s.db.messages.find(x => x.system_kind); s.pause(m.id); await dispatch(s, g, { now: T('17:41') }); expect(g.sent).toHaveLength(0);
    s.resume(m.id, T('18:00')); await dispatch(s, g, { now: T('18:01') }); expect(g.sent).toHaveLength(2);
  });
  it('HG-08 Gmail desconectado: no se envía; sale al reconectar', async () => {
    const s = setup({ routes: 1 }), g = gmail(); s.db.gmail.connected = false;
    await dispatch(s, g, { now: T('17:36') }); expect(g.sent).toHaveLength(0);
    s.db.gmail.connected = true; await dispatch(s, g, { now: T('17:41') }); expect(g.sent).toHaveLength(2);
  });
  it('HG-09 un PDF con contenido inválido no se envía: CERO llamadas a Gmail', async () => {
    const s = setup({ routes: 1 }), g = gmail(); s.db.blobs['route-pdfs:' + s.db.sheetPdfs[0].storage_path] = new Uint8Array([0x4d, 0x5a, 0x90, 0]);
    await dispatch(s, g, { now: T('17:36') });
    expect(g.sent).toHaveLength(0); expect(sheetDeliveries(s).every(d => d.status === 'ERROR' && d.error_code === 'ATTACHMENT_INVALID')).toBe(true);
  });
  it('HG-10 comparte el CUPO diario con los comunicados (tope 3: salen 3 de 4)', async () => {
    const s = setup(), g = gmail(); await dispatch(s, g, { now: T('17:36'), dailyCap: 3 });
    expect(g.sent).toHaveLength(3); expect(sheetDeliveries(s).filter(d => d.status === 'PENDIENTE')).toHaveLength(1);
  });
  it('HG-11 borradores y hojas CANCELADAS nunca se encolan (aunque tengan PDF)', async () => {
    const s = setup({ routes: 0 }), g = gmail();
    for (const [id, st] of [['rb', 'BORRADOR'], ['rc', 'CANCELADA']]) { const r = route(id, '03-0009' + id, { operational_status: st }); s.db.sheetRoutes.push(r); addPdf(s, r, 1, T('09:00')); }
    const r = route('rx', '03-000999', { published_at: null }); s.db.sheetRoutes.push(r); addPdf(s, r, 1, T('09:00'));   // sin publicar
    await dispatch(s, g, { now: T('17:36') }); expect(s.db.runs).toHaveLength(0); expect(g.sent).toHaveLength(0);
  });
  it('HG-12 tercerizado DESPACHADO se incluye (por su fecha de despacho); uno sin despacho, no', async () => {
    const s = setup({ routes: 0 }), g = gmail();
    const ex = route('re', '07-000001', { operational_status: 'COMPLETADA', dispatch_mode: 'EXTERNAL', published_at: iso(T('08:00', PREV)), dispatched_at: iso(T('10:00')) });
    const nd = route('rn', '07-000002', { operational_status: 'COMPLETADA', dispatch_mode: 'EXTERNAL', dispatched_at: null });
    s.db.sheetRoutes.push(ex, nd); addPdf(s, ex, 1, T('10:01')); addPdf(s, nd, 1, T('10:01'));
    await dispatch(s, g, { now: T('17:36') });
    expect(g.sent).toHaveLength(2); expect(g.sent.every(x => subject(x) === 'OK Despacho · Hoja 07-000001 (v1)')).toBe(true);
  });
  it('HG-13 CANCELADA antes del encolado: no se encola; cancelada DESPUÉS del encolado: cero envíos y motivo', async () => {
    const s = setup(), g = gmail(); R(s, 'r0').operational_status = 'CANCELADA';
    await dispatch(s, g, { now: T('17:36'), limit: 0 });
    expect(s.db.runs.map(r => r.source_key)).toEqual(['HOJA|r1|1']);
    R(s, 'r1').operational_status = 'CANCELADA'; await dispatch(s, g, { now: T('17:41') });
    expect(g.sent).toHaveLength(0);
    expect(sheetDeliveries(s).every(d => d.status === 'CANCELADO' && /cancelada o dejó de estar publicada/.test(d.reason))).toBe(true);
  });
  it('HG-14 VERSIÓN ANTERIOR encolada y la hoja se republica (v2): la v1 se cancela antes de enviar y sale solo la v2', async () => {
    const s = setup({ routes: 1 }), g = gmail(); await dispatch(s, g, { now: T('17:36'), limit: 0 });
    Object.assign(R(s, 'r0'), { version: 2 }); addPdf(s, R(s, 'r0'), 2, T('17:50'));
    await dispatch(s, g, { now: T('17:52') });
    expect(g.sent).toHaveLength(2); expect(g.sent.every(x => subject(x) === 'OK Despacho · Hoja 03-000120 (v2)')).toBe(true);
    const v1 = s.db.deliveries.filter(d => s._run(d.run_id).source_key === 'HOJA|r0|1');
    expect(v1.every(d => d.status === 'CANCELADO' && /versión más nueva de la hoja \(v2\)/.test(d.reason))).toBe(true);
  });
  it('HG-15 versión vigente SIN PDF todavía: no se usa el de la versión anterior; cuando aparece (tardío), se envía', async () => {
    const s = setup({ routes: 1 }), g = gmail(); R(s, 'r0').version = 2;   // la v2 se publicó pero su PDF aún no está
    await dispatch(s, g, { now: T('17:36') }); expect(g.sent).toHaveLength(0); expect(s.db.runs).toHaveLength(0);
    addPdf(s, R(s, 'r0'), 2, T('19:10')); await dispatch(s, g, { now: T('19:12') });
    expect(g.sent).toHaveLength(2); expect(g.sent.every(x => subject(x) === 'OK Despacho · Hoja 03-000120 (v2)')).toBe(true);
    expect(s.db.runs[0].scheduled_for).toBe(iso(T('19:10')));   // programado por el PDF tardío, dentro de la ventana
  });
  it('HG-16 PDF TARDÍO de una hoja de AYER (generado hoy) se envía; lo de ayer con PDF a tiempo no se reenvía', async () => {
    const s = setup({ routes: 0 }), g = gmail();
    const late = route('ry', '03-000201', { published_at: iso(T('16:00', PREV)) }), ontime = route('rz', '03-000202', { published_at: iso(T('16:00', PREV)) });
    s.db.sheetRoutes.push(late, ontime); addPdf(s, late, 1, T('00:40')); addPdf(s, ontime, 1, T('16:01', PREV));
    await dispatch(s, g, { now: T('00:45') });
    expect(g.sent).toHaveLength(2); expect(g.sent.every(x => subject(x) === 'OK Despacho · Hoja 03-000201 (v1)')).toBe(true);
    await dispatch(s, g, { now: T('17:40') }); expect(g.sent).toHaveLength(2);
    await dispatch(s, g, { now: T('17:40', NEXT) }); expect(g.sent).toHaveLength(2);   // al día siguiente, la de "ayer" ya no aplica
  });
  it('HG-17 REINTENTO: Gmail falla (503), la hoja se cancela antes del reintento → no se reenvía', async () => {
    const s = setup({ routes: 1, recipients: ['logistica@ejemplo.test'] }), g = gmail([503]);
    await dispatch(s, g, { now: T('17:36') }); expect(sheetDeliveries(s)[0]).toMatchObject({ status: 'ERROR', retryable: true });
    R(s, 'r0').operational_status = 'CANCELADA'; await dispatch(s, g, { now: T('17:50') });
    expect(g.sent).toHaveLength(0); expect(sheetDeliveries(s)[0].status).toBe('CANCELADO');
  });
});
