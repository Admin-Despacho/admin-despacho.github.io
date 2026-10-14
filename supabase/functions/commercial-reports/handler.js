// Edge Function "commercial-reports": informe comercial de Cristian Torres.
// Ver/descargar: can_view_commercial_transport_reports · Generar/enviar/configurar: can_manage_commercial_transport_reports
// Programado (cron): solo con el secreto CRON_SECRET en el header x-cron-secret.
import { hasPerm } from '../_shared/rules.js';
import { buildReport, period } from '../_shared/report-engine.js';

import { json, withCors } from '../_shared/http.js';
const VIEW = 'can_view_commercial_transport_reports', MANAGE = 'can_manage_commercial_transport_reports';
const B64 = bytes => { let s = ''; const a = new Uint8Array(bytes); for (let i = 0; i < a.length; i += 0x8000) s += String.fromCharCode(...a.subarray(i, i + 0x8000)); return btoa(s); };

/**
 * deps = { getUserFromJwt, getProfile, cronSecret, service (createReportService), store (mismo store del servicio),
 *          now(), audit(entry) }
 */
export const handle = withCors(handleRaw);
async function handleRaw(req, deps) {
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
    case 'third_party_preview': { const d = needView(); if (d) return d;
      try {
        const p = period(body.sel || { kind: '7D' }, deps.now());
        const carriers = await st.loadThirdPartyCarriers();
        const allowed = new Set(carriers.map(c => c.id));
        const carrierId = body.carrier_id && allowed.has(body.carrier_id) ? body.carrier_id : null;
        const routes = await st.loadThirdPartyRoutes();
        const inPeriod = routes.filter(r => {
          if (carrierId && r.carrier_id !== carrierId) return false;
          if (r.operational_status !== 'COMPLETADA' || !r.completed_at) return false;
          const t = Date.parse(r.completed_at);
          return t >= p.fromTs && t < p.toTs;
        });
        const carrierById = new Map(carriers.map(c => [c.id, c]));
        const buckets = new Map(carriers.map(c => [c.id, { carrier_id: c.id, carrier_name: c.name, routes: new Set(), orders: 0, bultos: 0, amount: 0, with_amount: 0, zero_amount: 0 }]));
        const details = [];
        let orders = 0, bultos = 0, amount = 0, withAmount = 0, zeroAmount = 0;
        for (const r of inPeriod) {
          const bucket = buckets.get(r.carrier_id); if (!bucket) continue;
          bucket.routes.add(r.id);
          for (const s of (r.stops || [])) {
            const nums = Array.isArray(s.order_numbers) ? s.order_numbers.filter(Boolean) : [];
            const orderCount = nums.length;
            const hasAmount = s.merchandise_amount != null;
            const value = hasAmount ? Number(s.merchandise_amount) || 0 : null;
            orders += orderCount; bucket.orders += orderCount;
            bultos += Number(s.bultos) || 0; bucket.bultos += Number(s.bultos) || 0;
            if (value != null) {
              amount += value; bucket.amount += value;
              if (value > 0) { withAmount += orderCount; bucket.with_amount += orderCount; }
              else { zeroAmount += orderCount; bucket.zero_amount += orderCount; }
            }
            details.push({
              completed_at: r.completed_at, route_number: r.number, carrier_id: r.carrier_id,
              carrier_name: (carrierById.get(r.carrier_id) || {}).name || r.carrier_id,
              client_name: s.client_name, order_numbers: nums, bultos: Number(s.bultos) || 0,
              outcome: s.outcome || null, merchandise_amount: value
            });
          }
        }
        const byCarrier = [...buckets.values()].filter(x => x.routes.size || !carrierId).map(x => ({
          carrier_id: x.carrier_id, carrier_name: x.carrier_name, routes: x.routes.size, orders: x.orders,
          bultos: x.bultos, amount: Math.round(x.amount * 100) / 100, with_amount: x.with_amount, zero_amount: x.zero_amount
        })).sort((a,b) => b.orders - a.orders || a.carrier_name.localeCompare(b.carrier_name, 'es'));
        details.sort((a,b) => String(b.completed_at).localeCompare(String(a.completed_at)) || a.route_number.localeCompare(b.route_number));
        return json(200, { report: {
          period: { start: p.start, end: p.end, days: p.days, label: p.label },
          carrier_id: carrierId,
          summary: { routes: new Set(inPeriod.map(r => r.id)).size, orders, bultos, amount: Math.round(amount * 100) / 100, with_amount: withAmount, zero_amount: zeroAmount },
          by_carrier: byCarrier, details
        }, carriers });
      } catch (e) { return json(400, { error: e.message }); } }
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
      if (s.schedule_mode && !['OFF','WEEKLY','BIWEEKLY','MONTHLY'].includes(s.schedule_mode)) return json(400, { error: 'Frecuencia automática inválida.' });
      for (const k of ['weekly_time','biweekly_time','monthly_time']) if (s[k] && !/^([01]\d|2[0-3]):[0-5]\d$/.test(s[k])) return json(400, { error: 'Hora inválida (HH:MM).' });
      if (s.biweekly_day_1 != null || s.biweekly_day_2 != null) {
        const d1 = Number(s.biweekly_day_1), d2 = Number(s.biweekly_day_2);
        if (!(d1 >= 1 && d1 <= 28 && d2 >= 1 && d2 <= 28 && d1 < d2)) return json(400, { error: 'Días quincenales inválidos: elegí dos días entre 1 y 28, en orden.' });
      }
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
