// Edge Function "internal-approvals": envío de emails de rutas internas (cola idempotente), reintento y configuración.
import { hasPerm } from '../_shared/rules.js';
import { sendQueuedEmails } from '../_shared/internal-route.js';
import { sendCustomerEmails } from '../_shared/customer-email.js';

const json = (status, body) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json', 'access-control-allow-origin': '*', 'access-control-allow-headers': 'authorization, content-type, x-cron-secret' } });
/** deps: { cronSecret, getUserFromJwt, getProfile, store (ver sendQueuedEmails), provider, appUrl, getSettings, setSettings(s), audit } */
export async function handle(req, deps) {
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
    return json(200, { results: await sendCustomerEmails({ store: deps.customerStore, provider: deps.provider, onlyIds: action === 'retry_customer' ? body.job_ids : undefined }) });
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
