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

Deno.test('RC2-EMAIL hojas: envía el PDF adjunto una vez por hoja+versión; error queda para reintento', async () => {
  const s = setup(); const jobs = [{ id: 'h1', route_id: 'r1', route_version: 1, recipient: 'log@ok.test', idempotency_key: 'r1|1|log', status: 'QUEUED' }]; let fail = 1;
  s.deps.sheetStore = { listJobs: async () => jobs.filter(j => j.status !== 'SENT'), pdfFor: async () => ({ number: '01-000001', file_name: 'Hoja_01-000001_v1.pdf', bytes: new Uint8Array([37, 80]) }), updateJob: async (id, p) => Object.assign(jobs[0], p) };
  const prov = s.deps.provider; s.deps.provider = { send: async m => { if (fail-- > 0) throw new Error('caído'); return prov.send(m); } };
  eq((await call(s.deps, { action: 'send_sheet_emails' })).body.results[0].status, 'ERROR');
  eq((await call(s.deps, { action: 'send_sheet_emails' })).body.results[0].status, 'SENT'); eq((await call(s.deps, { action: 'send_sheet_emails' })).body.results, []);
  eq(s.sent.at(-1).attachments[0].filename, 'Hoja_01-000001_v1.pdf');
});
Deno.test('RC2-17 reenviar invitación sin crear otro usuario de Auth (fallback a enlace) y límite de emails claro', async () => {
  const { handle: h } = await import('../admin-users/handler.js');
  const base = { getUserFromJwt: async () => ({ id: 'adm' }), getProfile: async id => id === 'adm' ? { id: 'adm', role: 'ADMIN', status: 'ACTIVO', carriers: [] } : { id: 'inv', email: 'inv@ok.test', status: 'INVITACION_PENDIENTE', role: 'DESPACHO', carriers: [] },
    listProfiles: async () => [], userHasPerm: async () => true, audit: async () => {}, hasHistory: async () => false, activeRoutes: async () => [] };
  let created = 0, resets = 0;
  const d1 = { ...base, inviteUser: async () => { created++; }, resendInvite: async () => { throw new Error('A user with this email address has already been registered'); }, sendPasswordReset: async () => { resets++; } };
  const r = await h(new Request('https://x', { method: 'POST', headers: { authorization: 'Bearer t' }, body: JSON.stringify({ action: 'resend_invite', user_id: 'inv' }) }), d1);
  eq(r.status, 200); eq([created, resets], [0, 1]);
  const d2 = { ...base, resendInvite: async () => { throw new Error('email rate limit exceeded'); } };
  const r2 = await h(new Request('https://x', { method: 'POST', headers: { authorization: 'Bearer t' }, body: JSON.stringify({ action: 'resend_invite', user_id: 'inv' }) }), d2);
  eq(r2.status, 429); eq((await r2.json()).code, 'EMAIL_RATE_LIMIT');
});

Deno.test('RC4.1 Recibido Conforme: desde el comprobante guardado, sin DNI/CUIL; falla del proveedor → ERROR con reintento; reintento OK con la misma clave idempotente', async () => {
  const { receiptEmail, sendCustomerEmails } = await import('../_shared/customer-email.js');
  const receipt = { receipt_number: 'RC-01-000123-001', snapshot: { receipt_number: 'RC-01-000123-001', client_name: 'Cliente Mail', order_numbers: ['95001'], receiver_name: 'Laura Gómez', delivered_at: '2026-10-13T15:00:00Z' } };
  const m = receiptEmail({ receipt, stop: { client_name: 'Cliente Mail', order_numbers: ['95001'] } });
  ok(m.subject.includes('RC-01-000123-001') && m.html.includes('Laura Gómez') && m.html.includes('95001') && !/cuil|dni/i.test(m.html));
  const jobs = [{ id: 'r1', kind: 'RECIBIDO_CONFORME', recipient: 'cliente@viejo.com', idempotency_key: 'route|stop|RECIBIDO_CONFORME', status: 'QUEUED', retry_count: 0 }];
  const updates = [], keys = []; let fail = true;
  const store = { listJobs: async () => jobs.filter(j => j.status !== 'SENT'), stopFor: async () => ({ client_name: 'Cliente Mail', order_numbers: ['95001'] }), receiptFor: async () => receipt,
    updateJob: async (id, patch) => { updates.push(patch); Object.assign(jobs[0], patch); } };
  const provider = { send: async x => { keys.push(x.idempotencyKey); if (fail) throw new Error('proveedor caído'); return { id: 'msg-1' }; } };
  await sendCustomerEmails({ store, provider });
  eq(jobs[0].status, 'ERROR'); eq(jobs[0].retry_count, 1); ok(jobs[0].error.includes('proveedor caído'));
  fail = false; await sendCustomerEmails({ store, provider });
  eq(jobs[0].status, 'SENT'); eq(jobs[0].provider_id, 'msg-1'); eq(keys, ['route|stop|RECIBIDO_CONFORME', 'route|stop|RECIBIDO_CONFORME']);
  await sendCustomerEmails({ store, provider }); eq(keys.length, 2);   // ya enviado: no se vuelve a mandar
});
Deno.test('RC4.1 Sin comprobante guardado: el job queda en ERROR (no se inventa uno) y la entrega no se toca', async () => {
  const { sendCustomerEmails } = await import('../_shared/customer-email.js');
  const jobs = [{ id: 'r2', kind: 'RECIBIDO_CONFORME', recipient: 'a@b.com', idempotency_key: 'k2', status: 'QUEUED', retry_count: 0 }];
  const store = { listJobs: async () => jobs.filter(j => j.status !== 'SENT'), stopFor: async () => ({ client_name: 'X' }), receiptFor: async () => { throw new Error('no existe'); }, updateJob: async (id, p) => Object.assign(jobs[0], p) };
  let sent = 0; await sendCustomerEmails({ store, provider: { send: async () => { sent++; return { id: 'x' }; } } });
  eq(jobs[0].status, 'ERROR'); ok(jobs[0].error.startsWith('COMPROBANTE')); eq(sent, 0);
});

Deno.test('RC4.1 · Diseño Recibido Conforme: asunto, logo oficial, datos, link al sitio, privacidad, acentos, móvil y sin imágenes', async () => {
  const { receiptEmail, SITE_URL } = await import('../_shared/customer-email.js');
  const receipt = { receipt_number: 'RC-01-000123-001', snapshot: { receipt_number: 'RC-01-000123-001', client_name: 'Ferretería Ñandú', order_numbers: ['95001', '95002'], receiver_name: 'José Pérez',
    delivered_at: '2026-10-13T15:05:00Z', carrier_id: 'CT-ESTE' } };
  const stop = { client_name: 'Ferretería Ñandú', order_numbers: ['95001', '95002'], receiver_cuil: '20301112223', receiver_dni: '30111222', lat: -32.89, lon: -68.84, outcome_note: 'NOTA INTERNA' };
  const L = await import('../_shared/ok-accesorios-logo.js'); const { inlineLogoFrom } = await import('../_shared/resend-body.js');
  const m = receiptEmail({ receipt, stop, inlineLogo: inlineLogoFrom(L) });
  // 1. asunto
  eq(m.subject, 'OK Accesorios · Recibido conforme RC-01-000123-001');
  // 2. logo HORIZONTAL oficial en encabezado y pie (nunca el ícono cuadrado de la app), con proporción exacta 1536×201 y alt textual
  eq((m.html.match(/<img src="cid:ok-accesorios-logo"/g) || []).length, 2); ok(m.html.includes('alt="OK ACCESORIOS"'));
  ok(!/icon-192|icon-512|apple-touch|\/logo\.png/.test(m.html));
  ok(m.html.includes('width="240" height="31"') && m.html.includes('width="160" height="21"') && m.html.includes('max-width:100%;height:auto'));   // 240×201/1536 = 31,4 · 160×201/1536 = 20,9
  // 3. textos y datos dinámicos
  for (const t of ['Recibido Conforme', 'Hola <b>Ferretería Ñandú</b>, registramos correctamente la entrega de tu pedido.', 'Entrega confirmada', 'Tu pedido fue entregado correctamente.',
    'RC-01-000123-001', '95001 + 95002', 'José Pérez', '13/10/2026', '12:05', 'Recibido conforme', 'Este correo confirma la recepción conforme de la mercadería.']) ok(m.html.includes(t), t);
  for (const k of ['Comprobante', 'Cliente', 'Pedido', 'Recibió', 'Fecha y hora', 'Estado']) ok(m.html.includes('>' + k + '<'), k);
  // 4. sitio web visible y clickeable, con https, en el pie (sin el lema anterior)
  eq(SITE_URL, 'https://www.okaccesorios.com.ar'); ok(m.html.includes('<a href="https://www.okaccesorios.com.ar"') && m.html.includes('>https://www.okaccesorios.com.ar</a>'));
  ok(!/SIEMPRE CERCA/i.test(m.html + m.text)); ok(m.text.includes('https://www.okaccesorios.com.ar'));
  // 5. móvil / compatibilidad: viewport, ancho fluido con tope 600, tablas, estilos inline, sin CSS externo, <style>, scripts ni flex/grid
  ok(m.html.includes('name="viewport"') && m.html.includes('max-width:600px;width:100%') && m.html.includes('<!--[if mso]>') && m.html.includes('role="presentation"'));
  ok(!/<style|<link|<script|display:\s*(flex|grid)|position:\s*(absolute|fixed)/i.test(m.html));
  // 6. acentos y codificación
  ok(m.html.includes('<meta charset="utf-8">') && m.html.includes('Recibió') && m.html.includes('recepción') && m.html.includes('Ñandú'));
  // 7. sin datos sensibles (aunque la parada los traiga)
  ok(!/\bcuil\b|\bdni\b|\bfirma\b|signature|\bgps\b|latitud|-32\.89|-68\.84|30111222|20301112223|NOTA INTERNA/i.test(m.html + m.text));
  // 8. imágenes bloqueadas / sin URL pública: queda el texto de marca, sin <img>
  const n = receiptEmail({ receipt, stop });
  ok(!n.html.includes('<img') && n.html.includes('OK <span style="color:#16d6e5;">ACCESORIOS</span>'));
  ok(!n.attachments);   // sin bytes del logo no hay adjunto ni <img>
  // caracteres peligrosos escapados
  const x = receiptEmail({ receipt: { receipt_number: 'R', snapshot: { receipt_number: 'R', client_name: '<script>x</script>', receiver_name: 'A & B' } }, stop: {} });
  ok(!x.html.includes('<script>x') && x.html.includes('&lt;script&gt;') && x.html.includes('A &amp; B'));
});
Deno.test('RC4.1 · Diseño: el envío no cambia (misma clave idempotente, un solo envío, mismo destinatario)', async () => {
  const { sendCustomerEmails } = await import('../_shared/customer-email.js'); const L = await import('../_shared/ok-accesorios-logo.js'); const { inlineLogoFrom } = await import('../_shared/resend-body.js');
  const receipt = { receipt_number: 'RC-9', snapshot: { receipt_number: 'RC-9', client_name: 'C', order_numbers: ['1'], receiver_name: 'R', delivered_at: '2026-10-13T15:00:00Z' } };
  const jobs = [{ id: 'z1', kind: 'RECIBIDO_CONFORME', recipient: 'c@c.com', idempotency_key: 'r|s|RECIBIDO_CONFORME', status: 'QUEUED', retry_count: 0 }];
  const sent = []; const store = { listJobs: async () => jobs.filter(j => j.status !== 'SENT'), stopFor: async () => ({}), receiptFor: async () => receipt, updateJob: async (id, p) => Object.assign(jobs[0], p) };
  await sendCustomerEmails({ store, provider: { send: async x => { sent.push(x); return { id: 'm1' }; } }, inlineLogo: inlineLogoFrom(L) });
  await sendCustomerEmails({ store, provider: { send: async x => { sent.push(x); return { id: 'm2' }; } }, inlineLogo: inlineLogoFrom(L) });
  eq(sent.length, 1); eq(sent[0].idempotencyKey, 'r|s|RECIBIDO_CONFORME'); eq(sent[0].to, 'c@c.com'); eq(jobs[0].status, 'SENT'); ok(sent[0].html.includes('cid:ok-accesorios-logo') && !sent[0].html.includes('icon-192'));
});

Deno.test('RC4.1 · CID: HTML y payload a Resend con el logo oficial inline, mismo content_id, image/png, sin URL externa, fallback y texto plano', async () => {
  const { receiptEmail, sendCustomerEmails } = await import('../_shared/customer-email.js'); const L = await import('../_shared/ok-accesorios-logo.js'); const { resendBody, inlineLogoFrom } = await import('../_shared/resend-body.js');
  const receipt = { receipt_number: 'RC-01-000123-001', snapshot: { receipt_number: 'RC-01-000123-001', client_name: 'Ferretería Ñandú', order_numbers: ['95001'], receiver_name: 'José Pérez', delivered_at: '2026-10-13T15:05:00Z' } };
  const m = receiptEmail({ receipt, stop: {}, inlineLogo: inlineLogoFrom(L) });
  // 1. el HTML usa cid:ok-accesorios-logo (encabezado y pie)
  eq((m.html.match(/src="cid:ok-accesorios-logo"/g) || []).length, 2);
  // 2. ninguna URL del logo: ni /branding/ok-accesorios-horizontal.png ni <img src="http…">
  ok(!m.html.includes('/branding/ok-accesorios-horizontal.png') && !/<img[^>]+src="https?:/i.test(m.html) && !m.html.includes('icon-192'));
  // 3-6. payload real a Resend (el mismo que arma la Edge Function)
  const sent = []; const jobs = [{ id: 'c1', kind: 'RECIBIDO_CONFORME', recipient: 'cliente@viejo.com', idempotency_key: 'r1|s1|RECIBIDO_CONFORME', status: 'QUEUED', retry_count: 0 }];
  const store = { listJobs: async () => jobs.filter(j => j.status !== 'SENT'), stopFor: async () => ({}), receiptFor: async () => receipt, updateJob: async (id, p) => Object.assign(jobs[0], p) };
  let fail = true;
  const provider = { send: async x => { const body = resendBody(x, 'OK Accesorios <avisos@okaccesorios.com.ar>'); sent.push({ x, body }); if (fail) throw new Error('Resend 500: caído'); return { id: 'msg-cid' }; } };
  await sendCustomerEmails({ store, provider, inlineLogo: inlineLogoFrom(L) });         // falla
  fail = false; await sendCustomerEmails({ store, provider, inlineLogo: inlineLogoFrom(L) });   // reintento OK
  await sendCustomerEmails({ store, provider, inlineLogo: inlineLogoFrom(L) });         // ya enviado: no se repite
  eq(sent.length, 2);                                                                   // 9. no duplica: un intento fallido + uno OK
  const b = sent[1].body, a = b.attachments;
  ok(Array.isArray(a) && a.length === 1);                                               // 3. el logo va inline en el payload
  eq(a[0].content_id, 'ok-accesorios-logo'); ok(b.html.includes('src="cid:' + a[0].content_id + '"'));   // 4. mismo CID que el HTML
  eq(a[0].content_type, 'image/png');                                                   // 5. MIME
  eq(a[0].filename, 'ok-accesorios-horizontal.png');                                     // 6. nombre de archivo
  // 7. bytes idénticos al PNG oficial congelado (y al hash del BRAND-LOCK)
  const bytes = Uint8Array.from(atob(a[0].content), c => c.charCodeAt(0));
  const file = await Deno.readFile(new URL('../../../public/branding/ok-accesorios-horizontal.png', import.meta.url));
  eq(bytes.length, file.length); eq(bytes.length, L.LOGO_BYTES); ok(bytes.every((v, i) => v === file[i]));
  const hex = Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes)), x => x.toString(16).padStart(2, '0')).join('');
  const lock = JSON.parse(await Deno.readTextFile(new URL('../../../tests/brand/branding.lock.json', import.meta.url))).sha256;
  eq(hex, L.LOGO_SHA256); eq(hex, lock['public/branding/ok-accesorios-horizontal.png']);
  // 8 / 10. reintento con la MISMA clave idempotente y el MISMO destinatario
  eq(sent[0].x.idempotencyKey, 'r1|s1|RECIBIDO_CONFORME'); eq(sent[1].x.idempotencyKey, 'r1|s1|RECIBIDO_CONFORME');
  eq(b.to, ['cliente@viejo.com']); eq(sent[0].body.to, ['cliente@viejo.com']); eq(jobs[0].status, 'SENT'); eq(jobs[0].provider_id, 'msg-cid');
  // 11. fallback ALT y 12. texto plano completo (sin imágenes)
  ok(b.html.includes('alt="OK ACCESORIOS"')); ok(b.text.includes('RECIBIDO CONFORME') && b.text.includes('RC-01-000123-001') && b.text.includes('https://www.okaccesorios.com.ar') && !b.text.includes('cid:'));
  // los otros emails al cliente siguen sin adjuntos (sin cambios)
  const other = resendBody({ to: 'x@y.com', subject: 's', html: 'h', text: 't' }, 'f'); ok(!('attachments' in other)); eq(Object.keys(other), ['from', 'to', 'subject', 'html', 'text']);
  // tamaño real del logo en cada correo
  ok(L.LOGO_BYTES === 127934 && a[0].content.length === 170580);
});