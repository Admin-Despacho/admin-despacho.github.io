import { handle } from './handler.js';
import { approvalRecipients, approvalEmail, routeDiff } from '../_shared/internal-route.js';
const eq = (a, b, m) => { if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error((m || '') + ' ' + JSON.stringify(a) + ' ≠ ' + JSON.stringify(b)); };
const ok = (c, m) => { if (!c) throw new Error(m || 'falló'); };
const ROUTE = { id: 'r1', number: '03-000007', responsable_id: 'gab', completed_at: '2026-10-10T20:00:00Z', sheet_snapshot: { stops: [{ client_name: 'A', bultos: 2 }, { client_name: 'B' }, { client_name: 'C' }] },
  stops: [{ id: 's1', seq: 1, sequence_number: 1, client_name: 'A', bultos: 2, outcome: 'ENTREGADO' }, { id: 's3', seq: 3, sequence_number: 2, client_name: 'C', outcome: 'ENTREGADO' },
    { id: 's4', seq: 4, sequence_number: 3, client_name: 'Banco', provenance: 'DRIVER', action: 'RETIRO', bultos: 1, outcome: 'ENTREGADO' }, { id: 's2', seq: 2, sequence_number: 4, client_name: 'B', outcome: 'NO_ENTREGADO', outcome_reason: 'Cerrado' }] };
function setup(fail = 0) {
  const jobs = [{ id: 'j1', route_id: 'r1', route_version: 3, kind: 'INTERNAL_ROUTE_APPROVAL_REQUEST', recipient: 'sup@ok.test', idempotency_key: 'k1', status: 'QUEUED' },
    { id: 'j2', route_id: 'r1', route_version: 3, kind: 'INTERNAL_ROUTE_APPROVAL_REQUEST', recipient: 'extra@ok.test', idempotency_key: 'k2', status: 'QUEUED' }];
  const sent = []; let f = fail; const route = JSON.parse(JSON.stringify({ ...ROUTE, operational_status: 'COMPLETADA', approval_status: 'PENDIENTE' }));
  const deps = { cronSecret: 's', appUrl: 'https://app', getUserFromJwt: async t => t ? { id: t } : null, getProfile: async id => ({ id, role: 'ADMIN', status: 'ACTIVO' }), audit: async () => {},
    store: { listJobs: async q => jobs.filter(j => q.statuses.includes(j.status) && (!q.ids || q.ids.includes(j.id))), routeFor: async () => route, driverName: async () => 'Gabriel Figueroa', updateJob: async (id, p) => Object.assign(jobs.find(j => j.id === id), p) },
    provider: { send: async m => { if (f-- > 0) throw new Error('SMTP caído'); sent.push(m); return { id: 'p' + sent.length }; } } };
  return { jobs, sent, deps, route };
}
const call = (deps, body, headers = { 'x-cron-secret': 's' }) => handle(new Request('https://x', { method: 'POST', headers, body: JSON.stringify(body) }), deps).then(async r => ({ status: r.status, body: await r.json() }));

Deno.test('MAIL-01/02 (envío) cada destinatario recibe el aviso con el asunto aprobado', async () => {
  const s = setup(); await call(s.deps, { action: 'send_queued' });
  eq(s.sent.map(m => m.to), ['sup@ok.test', 'extra@ok.test']); eq(s.sent[0].subject, 'OK Despacho · Hoja 03-000007 pendiente de aprobación');
});
Deno.test('MAIL-03 destinatarios duplicados se deduplican (superior = admin, mayúsculas)', () => {
  const users = [{ id: 'a', email: 'Admin@ok.test', role: 'ADMIN', status: 'ACTIVO' }, { id: 'x', email: 'x@ok.test', role: 'DESPACHO', status: 'ACTIVO' }];
  const r = approvalRecipients({ driver: { supervisor_user_id: 'a' }, users, settings: { copy_admin: true, extra_emails: ['ADMIN@OK.TEST', 'log@ok.test'] } });
  eq(r.emails, ['admin@ok.test', 'log@ok.test']);
  eq(approvalRecipients({ driver: {}, users, settings: { copy_admin: false, extra_emails: ['log@ok.test'] } }), { supervisor: null, emails: ['log@ok.test'] });
});
Deno.test('MAIL-05 falla del email no revierte la hoja; queda ERROR para reintentar', async () => {
  const s = setup(1); const r = await call(s.deps, { action: 'send_queued' });
  eq(r.body.results.map(x => x.status), ['ERROR', 'SENT']); eq(s.route.operational_status, 'COMPLETADA'); eq(s.jobs[0].retry_count, 1);
  await call(s.deps, { action: 'retry', job_ids: ['j1'] }, { authorization: 'Bearer adm' });
  eq(s.jobs[0].status, 'SENT'); eq(s.sent.length, 2, 'el que ya salió no se reenvía');
});
Deno.test('MAIL-06 reintentar no reenvía lo ya enviado', async () => { const s = setup(); await call(s.deps, { action: 'send_queued' }); await call(s.deps, { action: 'send_queued' }); eq(s.sent.length, 2); });
Deno.test('Contenido: original vs ejecutada, agregadas, reordenamientos, incidencias, bultos y botón; sin DNI/CUIL/GPS/firmas', () => {
  const m = approvalEmail({ route: ROUTE, driverName: 'Gabriel Figueroa', appUrl: 'https://app' }); const d = routeDiff(ROUTE);
  eq([d.original.length, d.executed.length, d.added, d.moved, d.incidents, d.bultos], [3, 4, 1, 2, 1, 3]);
  ['Gabriel Figueroa', 'Paradas originales: <b>3</b>', 'Agregadas: <b>1</b>', 'REVISAR CAMBIOS', 'PARADA AGREGADA', 'INCIDENCIA'].forEach(t => ok(m.html.includes(t), t));
  ok(!/DNI|CUIL|GPS|latitud|longitud|firma/i.test(m.html + m.text), 'datos sensibles');
});
Deno.test('Cron sin secreto no envía', async () => { const s = setup(); eq((await call(s.deps, { action: 'send_queued' }, { 'x-cron-secret': 'otro' })).status, 401); eq(s.sent.length, 0); });

Deno.test('2B3-ADJ un transportista común no dispara la cola global de emails', async () => {
  const s = setup(); s.deps.getProfile = async id => ({ id, role: 'TRANSPORTISTA_INTERNO', status: 'ACTIVO' });
  eq((await call(s.deps, { action: 'send_queued' }, { authorization: 'Bearer gab' })).status, 403); eq(s.sent.length, 0);
});
Deno.test('MAILC-04 emails al cliente: sin DNI/CUIL/GPS/firma/notas; parcial indica parcial; falla no revierte y se reintenta', async () => {
  const { customerEmail, sendCustomerEmails } = await import('../_shared/customer-email.js');
  const stop = { client_name: 'Cliente Uno', order_numbers: ['90001'], outcome_note: 'NOTA INTERNA', receiver_cuil: '20123456786' };
  const p = customerEmail({ kind: 'PARTIAL', stop }), w = customerEmail({ kind: 'ON_THE_WAY', stop });
  ok(p.html.includes('parte') && w.subject.includes('va en camino') && !/NOTA INTERNA|20123456786|DNI|CUIL|GPS|firma|\d{1,2}:\d{2}/i.test(p.html + w.html), 'contenido');
  const jobs = [{ id: 'c1', kind: 'DELIVERED', recipient: 'a@b.c', idempotency_key: 'k', status: 'QUEUED' }]; let fail = 1; const sent = [];
  const st = { listJobs: async q => jobs.filter(j => q.statuses.includes(j.status)), stopFor: async () => stop, updateJob: async (id, x) => Object.assign(jobs[0], x) };
  const prov = { send: async m => { if (fail-- > 0) throw new Error('caído'); sent.push(m); return { id: 'p' }; } };
  eq((await sendCustomerEmails({ store: st, provider: prov }))[0].status, 'ERROR'); eq((await sendCustomerEmails({ store: st, provider: prov }))[0].status, 'SENT'); eq(await sendCustomerEmails({ store: st, provider: prov }), []); eq(sent.length, 1);
});
