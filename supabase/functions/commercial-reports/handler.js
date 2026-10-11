// Edge Function "commercial-reports": informe comercial de Cristian Torres.
// Ver/descargar: can_view_commercial_transport_reports · Generar/enviar/configurar: can_manage_commercial_transport_reports
// Programado (cron): solo con el secreto CRON_SECRET en el header x-cron-secret.
import { hasPerm } from '../_shared/rules.js';
import { buildReport } from '../_shared/report-engine.js';

const json = (status, body) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json', 'access-control-allow-origin': '*', 'access-control-allow-headers': 'authorization, content-type, x-cron-secret' } });
const VIEW = 'can_view_commercial_transport_reports', MANAGE = 'can_manage_commercial_transport_reports';
const B64 = bytes => { let s = ''; const a = new Uint8Array(bytes); for (let i = 0; i < a.length; i += 0x8000) s += String.fromCharCode(...a.subarray(i, i + 0x8000)); return btoa(s); };

/**
 * deps = { getUserFromJwt, getProfile, cronSecret, service (createReportService), store (mismo store del servicio),
 *          now(), audit(entry) }
 */
export async function handle(req, deps) {
  if (req.method === 'OPTIONS') return json(200, { ok: true });
  if (req.method !== 'POST') return json(405, { error: 'Método no permitido' });
  let body; try { body = await req.json(); } catch (e) { return json(400, { error: 'JSON inválido.' }); }
  const { action } = body || {};

  if (action === 'scheduled') {
    const secret = req.headers.get('x-cron-secret') || '';
    if (!deps.cronSecret || secret !== deps.cronSecret) return json(401, { error: 'No autorizado.' });
    const done = await deps.service.runScheduled();
    for (const d of done) await deps.audit({ actor_id: null, action: 'REPORT_SCHEDULED_RUN', target_type: 'report', target_id: String(d.report_id), after: { type: d.type, period: d.period, emails: d.emails.map(e => ({ to: e.recipient, status: e.status, skipped: !!e.skipped })) } });
    return json(200, { done });
  }

  const auth = req.headers.get('authorization') || '';
  const who = auth.startsWith('Bearer ') ? await deps.getUserFromJwt(auth.slice(7)) : null;
  if (!who) return json(401, { error: 'Sesión inválida.' });
  const me = await deps.getProfile(who.id);
  const can = p => hasPerm(me, p);
  const needView = () => (can(VIEW) || can(MANAGE)) ? null : json(403, { error: 'No tenés permiso para ver informes comerciales.' });
  const needManage = () => can(MANAGE) ? null : json(403, { error: 'No tenés permiso para generar o enviar informes comerciales.' });
  const st = deps.store;

  switch (action) {
    case 'preview': { const d = needView(); if (d) return d;
      try { return json(200, { report: buildReport({ routes: await st.loadRoutes(), costs: await st.loadCosts(), sel: body.sel, now: deps.now(), type: 'SCREEN' }) }); }
      catch (e) { return json(400, { error: e.message }); } }
    case 'history': { const d = needView(); if (d) return d; return json(200, { reports: await st.listReports(body.filters || {}) }); }
    case 'get': { const d = needView(); if (d) return d; const r = await st.getReport(body.report_id); return r ? json(200, { report: r, emails: await st.listEmails(r.id) }) : json(404, { error: 'No existe.' }); }
    case 'pdf': { const d = needView(); if (d) return d; const r = await st.getReport(body.report_id); if (!r || r.pdf_status !== 'OK') return json(409, { error: 'El informe no tiene PDF (estado ' + (r ? r.pdf_status : '—') + ').' });
      return json(200, { filename: r.snapshot && r.snapshot.type ? (await import('../_shared/report-engine.js')).fileName(r.snapshot) : 'informe.pdf', base64: B64(await st.loadPdf(r.id)) }); }
    case 'generate': { const d = needManage(); if (d) return d;
      let r; try { r = await deps.service.generate({ type: 'MANUAL', sel: body.sel, actorId: me.id }); } catch (e) { return json(400, { error: e.message }); }
      await deps.audit({ actor_id: me.id, action: 'REPORT_GENERATED', target_type: 'report', target_id: String(r.id), after: { type: 'MANUAL', period: r.period_start + '..' + r.period_end, pdf_status: r.pdf_status } });
      return json(200, { report: r }); }
    case 'send': case 'resend': case 'retry': { const d = needManage(); if (d) return d;
      const r = await st.getReport(body.report_id); if (!r) return json(404, { error: 'No existe.' });
      const res = action === 'retry' ? await deps.service.retry(r) : { report: r, emails: await deps.service.send(r, { recipients: body.recipients, resend: action === 'resend' }) };
      await deps.audit({ actor_id: me.id, action: action === 'resend' ? 'REPORT_EMAIL_RESENT' : action === 'retry' ? 'REPORT_RETRY' : 'REPORT_EMAIL_SENT', target_type: 'report', target_id: String(r.id), after: { emails: res.emails.map(e => ({ to: e.recipient, status: e.status, skipped: !!e.skipped })) } });
      return json(200, res); }
    case 'settings_get': { const d = needManage(); if (d) return d; return json(200, { settings: await st.getSettings(), costs: await st.loadCosts() }); }
    case 'settings_set': { const d = needManage(); if (d) return d;
      const s = body.settings || {};
      if (s.recipients && !s.recipients.every(x => /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(x))) return json(400, { error: 'Hay un email de destinatario inválido.' });
      if (s.monthly_time && !/^([01]\d|2[0-3]):[0-5]\d$/.test(s.monthly_time)) return json(400, { error: 'Hora mensual inválida (HH:MM).' });
      const before = await st.getSettings(); await st.setSettings(s);
      await deps.audit({ actor_id: me.id, action: 'REPORT_SETTINGS_CHANGED', target_type: 'settings', target_id: 'commercial_reports', before, after: s });
      return json(200, { settings: await st.getSettings() }); }
    case 'cost_set': { const d = needManage(); if (d) return d;
      const v = Number(body.monthly_cost); if (!(v > 0) || !/^\d{4}-\d{2}-\d{2}$/.test(body.valid_from || '')) return json(400, { error: 'Costo o fecha de vigencia inválidos.' });
      await st.addCost(v, body.valid_from, me.id);
      await deps.audit({ actor_id: me.id, action: 'TRANSPORT_COST_CHANGED', target_type: 'cost', target_id: 'CRISTIAN_TORRES', after: { monthly_cost: v, valid_from: body.valid_from } });
      return json(200, { costs: await st.loadCosts() }); }
    default: return json(400, { error: 'Acción desconocida.' });
  }
}
