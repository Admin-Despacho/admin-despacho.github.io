// deno test --allow-read --config supabase/functions/deno.json supabase/functions
import { handle } from './handler.js';
import { createReportService } from '../_shared/report-service.js';
import { memoryStore } from '../_shared/report-memory-store.js';
import { reportPdf } from '../_shared/report-pdf.js';
import { demoRoutes, DEMO_COSTS } from '../_shared/report-demo-data.js';
import { atLocal } from '../_shared/report-engine.js';

const eq = (a, b, m) => { if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error((m || 'distinto') + ': ' + JSON.stringify(a) + ' ≠ ' + JSON.stringify(b)); };
const ok = (c, m) => { if (!c) throw new Error(m || 'falló'); };

function setup({ pdfFails = false, providerFails = 0, nowTs = atLocal('2026-10-10', '15:00') } = {}) {
  const store = memoryStore({ routes: demoRoutes(), costs: DEMO_COSTS, settings: { recipients: ['admin@okaccesorios.com.ar', 'gerencia@okaccesorios.com.ar'] } });
  const sent = []; let fails = providerFails; let clock = nowTs;
  const provider = { async send(m) { if (fails > 0) { fails--; throw new Error('proveedor caído'); } sent.push(m); return { id: 'prov-' + sent.length }; } };
  let pdfMaker = pdfFails ? async () => { throw new Error('sin memoria'); } : reportPdf;
  const service = createReportService({ store, pdfMaker: s => pdfMaker(s), provider, now: () => clock });
  const users = { adm: { id: 'adm', role: 'ADMIN', status: 'ACTIVO' }, des: { id: 'des', role: 'DESPACHO', status: 'ACTIVO' }, cri: { id: 'cri', role: 'TRANSPORTISTA', status: 'ACTIVO' } };
  const audit = [];
  const deps = { store, service, cronSecret: 'secreto', now: () => clock, getUserFromJwt: async t => users[t] ? { id: t } : null, getProfile: async id => users[id], audit: async e => audit.push(e) };
  return { store, sent, service, deps, audit, setNow: t => { clock = t; }, fixPdf: () => { pdfMaker = reportPdf; } };
}
const call = (deps, token, body, headers = {}) => handle(new Request('https://x', { method: 'POST', headers: { 'content-type': 'application/json', ...(token ? { authorization: 'Bearer ' + token } : {}), ...headers }, body: JSON.stringify(body) }), deps);
const read = async r => ({ status: r.status, body: await r.json() });

Deno.test('R-SCH-01 Sábado 15:00: genera el semanal y lo envía una vez a cada destinatario con el PDF adjunto', async () => {
  const s = setup();
  const r = await read(await call(s.deps, null, { action: 'scheduled' }, { 'x-cron-secret': 'secreto' }));
  eq(r.status, 200); eq(r.body.done.map(d => d.type), ['WEEKLY']); eq(s.sent.length, 2);
  eq(s.sent[0].subject, 'OK Despacho · Informe semanal Cristian Torres · cierre 10/10/2026 15:00');
  eq(s.sent[0].attachments[0].filename, 'Informe_Cristian_Torres_Semanal_2026-10-10.pdf'); ok(s.sent[0].attachments[0].content.length > 2000, 'PDF adjunto');
  ok(s.sent[0].html.includes('CUBRE EL COSTO') && s.sent[0].text.includes('ENVÍOS COMPLETADOS'));
});
Deno.test('REPORT-MAIL-21 Cron repetido / redeploy / refresh: no duplica informe ni emails', async () => {
  const s = setup();
  for (let i = 0; i < 3; i++) await call(s.deps, null, { action: 'scheduled' }, { 'x-cron-secret': 'secreto' });
  s.setNow(atLocal('2026-10-10', '15:45')); await call(s.deps, null, { action: 'scheduled' }, { 'x-cron-secret': 'secreto' });
  eq(s.store.state.reports.length, 1); eq(s.sent.length, 2); eq(s.store.state.emails.length, 2);
});
Deno.test('REPORT-MAIL-21b Reintento tras error del proveedor: se envía una sola vez y queda retry_count', async () => {
  const s = setup({ providerFails: 1 });
  await call(s.deps, null, { action: 'scheduled' }, { 'x-cron-secret': 'secreto' });
  const e1 = s.store.state.emails.find(e => e.recipient === 'admin@okaccesorios.com.ar');
  eq(e1.status, 'ERROR'); eq(s.sent.length, 1);
  await call(s.deps, null, { action: 'scheduled' }, { 'x-cron-secret': 'secreto' });
  const e2 = s.store.state.emails.find(e => e.recipient === 'admin@okaccesorios.com.ar');
  eq(e2.status, 'SENT'); eq(e2.retry_count, 1); eq(s.sent.length, 2); eq(s.store.state.emails.length, 2);
});
Deno.test('REPORT-MAIL-21c REENVIAR EMAIL desde Admin es un envío explícito nuevo (clave con reenvío)', async () => {
  const s = setup(); await call(s.deps, null, { action: 'scheduled' }, { 'x-cron-secret': 'secreto' });
  const id = s.store.state.reports[0].id;
  const r = await read(await call(s.deps, 'adm', { action: 'resend', report_id: id, recipients: ['admin@okaccesorios.com.ar'] }));
  eq(r.status, 200); eq(s.sent.length, 3); ok(r.body.emails[0].idempotency_key.endsWith('|reenvio-1'));
  eq(s.audit.at(-1).action, 'REPORT_EMAIL_RESENT');
});
Deno.test('R-PDF-ERR Falla el PDF: estado PDF_ERROR, no se envía un informe incompleto y se puede reintentar', async () => {
  const s = setup({ pdfFails: true });
  await call(s.deps, null, { action: 'scheduled' }, { 'x-cron-secret': 'secreto' });
  const rep = s.store.state.reports[0];
  eq(rep.pdf_status, 'PDF_ERROR'); eq(s.sent.length, 0); ok(s.store.state.emails.every(e => e.status === 'PDF_ERROR'));
  s.fixPdf();
  const r = await read(await call(s.deps, 'adm', { action: 'retry', report_id: rep.id }));
  eq(r.body.report.pdf_status, 'OK'); eq(s.sent.length, 2); ok(r.body.emails.every(e => e.status === 'SENT'));
});
Deno.test('REPORT-MAIL-22/23 Histórico conserva snapshot: un cambio futuro de costo no cambia el informe ni su PDF', async () => {
  const s = setup();
  const g = await read(await call(s.deps, 'adm', { action: 'generate', sel: { kind: 'MONTH', year: 2026, month: 9 } }));
  const id = g.body.report.id, cost0 = g.body.report.snapshot.coverage.cost, pdf0 = await s.store.loadPdf(id);
  eq(cost0, 1600000);
  eq((await read(await call(s.deps, 'adm', { action: 'cost_set', monthly_cost: 2000000, valid_from: '2026-09-01' }))).status, 200);
  const again = await read(await call(s.deps, 'adm', { action: 'get', report_id: id }));
  eq(again.body.report.snapshot.coverage.cost, 1600000);
  eq([...await s.store.loadPdf(id)], [...pdf0], 'el PDF guardado es el mismo');
  const now = await read(await call(s.deps, 'adm', { action: 'preview', sel: { kind: 'MONTH', year: 2026, month: 9 } }));
  eq(now.body.report.coverage.cost, 2000000, 'la vista nueva sí usa el costo vigente');
});
Deno.test('REPORT-MAIL-24 Un cambio futuro de tarifa no modifica el informe ni el PDF viejo', async () => {
  const s = setup();
  const g = await read(await call(s.deps, 'adm', { action: 'generate', sel: { kind: 'MONTH', year: 2026, month: 9 } }));
  const id = g.body.report.id, inc0 = g.body.report.snapshot.total.income, pdf0 = await s.store.loadPdf(id);
  s.store.routes.forEach(r => r.stops.forEach(st => { st.shipping_fee = st.shipping_fee * 2; }));
  eq((await read(await call(s.deps, 'adm', { action: 'get', report_id: id }))).body.report.snapshot.total.income, inc0);
  eq([...await s.store.loadPdf(id)], [...pdf0]);
  ok((await read(await call(s.deps, 'adm', { action: 'preview', sel: { kind: 'MONTH', year: 2026, month: 9 } }))).body.report.total.income === inc0 * 2);
});
Deno.test('REPORT-MAIL-12b Fin de mes 23:30: genera el MENSUAL del mes calendario', async () => {
  const s = setup({ nowTs: atLocal('2026-09-30', '23:30') });
  const r = await read(await call(s.deps, null, { action: 'scheduled' }, { 'x-cron-secret': 'secreto' }));
  eq(r.body.done.map(d => d.type), ['MONTHLY']); eq(r.body.done[0].period, '2026-09-01..2026-09-30');
  eq(s.sent[0].subject, 'OK Despacho · Informe mensual Cristian Torres · Septiembre 2026');
});
Deno.test('Permisos: sin permiso no ve; ver no alcanza para generar; cron sin secreto no corre', async () => {
  const s = setup();
  eq((await call(s.deps, 'des', { action: 'preview', sel: { kind: '7D' } })).status, 403);
  eq((await call(s.deps, 'cri', { action: 'history' })).status, 403);
  eq((await call(s.deps, null, { action: 'scheduled' })).status, 401);
  eq((await call(s.deps, null, { action: 'scheduled' }, { 'x-cron-secret': 'otro' })).status, 401);
  eq((await call(s.deps, 'adm', { action: 'preview', sel: { kind: '7D' } })).status, 200);
  eq(s.sent.length, 0);
});
Deno.test('Historial: filtros por tipo y enviado/no enviado', async () => {
  const s = setup(); await call(s.deps, null, { action: 'scheduled' }, { 'x-cron-secret': 'secreto' });
  await call(s.deps, 'adm', { action: 'generate', sel: { kind: '15D' } });
  eq((await read(await call(s.deps, 'adm', { action: 'history', filters: { type: 'WEEKLY' } }))).body.reports.length, 1);
  eq((await read(await call(s.deps, 'adm', { action: 'history', filters: { sent: 'NO' } }))).body.reports.map(r => r.report_type), ['MANUAL']);
  const pdf = await read(await call(s.deps, 'adm', { action: 'pdf', report_id: s.store.state.reports[0].id }));
  eq(pdf.status, 200); ok(pdf.body.base64.length > 1000); eq(pdf.body.filename, 'Informe_Cristian_Torres_Semanal_2026-10-10.pdf');
});
Deno.test('Configuración: destinatarios válidos y hora HH:MM; el cambio queda auditado', async () => {
  const s = setup();
  eq((await call(s.deps, 'adm', { action: 'settings_set', settings: { recipients: ['malo'] } })).status, 400);
  eq((await call(s.deps, 'adm', { action: 'settings_set', settings: { monthly_time: '25:00' } })).status, 400);
  eq((await call(s.deps, 'adm', { action: 'settings_set', settings: { monthly_time: '22:00', recipients: ['admin@okaccesorios.com.ar'] } })).status, 200);
  eq(s.audit.at(-1).action, 'REPORT_SETTINGS_CHANGED');
});
