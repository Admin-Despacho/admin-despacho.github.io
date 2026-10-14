// Edge Function "internal-approvals": envío de emails de rutas internas (cola idempotente), reintento y configuración.
import { hasPerm } from '../_shared/rules.js';
import { sendQueuedEmails } from '../_shared/internal-route.js';
import { sendCustomerEmails } from '../_shared/customer-email.js';

import { json, withCors } from '../_shared/http.js';
/** deps: { cronSecret, getUserFromJwt, getProfile, store (ver sendQueuedEmails), provider, appUrl, inlineLogo (logo del Recibido Conforme por CID), getSettings, setSettings(s), audit } */
export const handle = withCors(handleRaw);
async function handleRaw(req, deps) {
  if (req.method === 'OPTIONS') return json(200, { ok: true });
  let body; try { body = await req.json(); } catch (e) { return json(400, { error: 'JSON inválido.' }); }
  const { action } = body || {};
  let me = null;
  if (req.headers.get('x-cron-secret')) { if (!deps.cronSecret || req.headers.get('x-cron-secret') !== deps.cronSecret) return json(401, { error: 'No autorizado.' }); }
  else {
    const auth = req.headers.get('authorization') || ''; const who = auth.startsWith('Bearer ') ? await deps.getUserFromJwt(auth.slice(7)) : null;
    me = who && await deps.getProfile(who.id);
    if (!me) return json(401, { error: 'Sesión inválida.' });
  }
  const can = p => !me || hasPerm(me, p);
  if (action === 'send_queued' || action === 'retry') {
    if (me && !(hasPerm(me, 'can_approve_internal_route_changes') || hasPerm(me, 'settings.manage'))) return json(403, { error: 'Sin permiso.' });
    const out = await sendQueuedEmails({ store: deps.store, provider: deps.provider, appUrl: deps.appUrl, onlyIds: action === 'retry' ? body.job_ids : undefined });
    if (me && action === 'retry') await deps.audit({ actor_id: me.id, action: 'APPROVAL_EMAIL_RETRY', target_type: 'email', target_id: (body.job_ids || []).join(','), after: { results: out } });
    return json(200, { results: out });
  }
  if (action === 'send_customer_queued' || action === 'retry_customer') {
    if (me && !(hasPerm(me, 'settings.manage') || hasPerm(me, 'routes.view_all'))) return json(403, { error: 'Sin permiso.' });
    return json(200, { results: await sendCustomerEmails({ store: deps.customerStore, provider: deps.provider, inlineLogo: deps.inlineLogo, onlyIds: action === 'retry_customer' ? body.job_ids : undefined }) });
  }
  // Email diario de PDFs de hojas (default 18:00 Mendoza): cola idempotente hoja+versión+destinatario; adjunta el PDF guardado
  if (action === 'send_sheet_emails') {
    if (me && !hasPerm(me, 'settings.manage')) return json(403, { error: 'Sin permiso.' });
    if (deps.queueSheetEmails) await deps.queueSheetEmails();
    const out = [];
    for (const j of await deps.sheetStore.listJobs()) {
      try {
        const pdf = await deps.sheetStore.pdfFor(j);
        const r = await deps.provider.send({ to: j.recipient, idempotencyKey: j.idempotency_key, subject: 'OK Despacho · Hoja ' + pdf.number + ' (v' + j.route_version + ')',
          html: '<p style="font-family:Arial,sans-serif">Adjuntamos la hoja <b>' + pdf.number + '</b> versión ' + j.route_version + '.</p>', text: 'Hoja ' + pdf.number + ' v' + j.route_version, attachments: [{ filename: pdf.file_name, content: pdf.bytes }] });
        await deps.sheetStore.updateJob(j.id, { status: 'SENT', sent_at: new Date().toISOString(), provider_id: r && r.id, error: null }); out.push({ id: j.id, status: 'SENT' });
      } catch (e) { await deps.sheetStore.updateJob(j.id, { status: 'ERROR', error: String(e.message || e), retry_count: (j.retry_count || 0) + 1 }); out.push({ id: j.id, status: 'ERROR' }); }
    }
    return json(200, { results: out });
  }
  if (action === 'settings_get' || action === 'settings_set') {
    if (!can('settings.manage')) return json(403, { error: 'Sin permiso.' });
    if (action === 'settings_get') return json(200, { settings: await deps.getSettings() });
    const s = body.settings || {};
    if ((s.extra_emails || []).some(e => !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(e))) return json(400, { error: 'Hay un email adicional inválido.' });
    const before = await deps.getSettings(); await deps.setSettings(s);
    await deps.audit({ actor_id: me && me.id, action: 'INTERNAL_ROUTE_NOTIF_SETTINGS', target_type: 'settings', target_id: 'DEFAULT', before, after: s });
    return json(200, { settings: await deps.getSettings() });
  }
  return json(400, { error: 'Acción desconocida.' });
}