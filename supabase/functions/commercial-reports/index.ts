// Edge Function "commercial-reports" en Supabase (Deno).
// Secrets: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (automáticos), CRON_SECRET, RESEND_API_KEY, REPORT_FROM
import { createClient } from 'npm:@supabase/supabase-js@2';
import { handle } from './handler.js';
import { createReportService } from '../_shared/report-service.js';
import { reportPdf } from '../_shared/report-pdf.js';

const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
const must = <T>(r: { data: T; error: any }) => { if (r.error) throw new Error(r.error.message); return r.data; };
const BUCKET = 'commercial-reports';

const store = {
  async loadRoutes() {
    const carriers = must(await admin.from('carriers').select('id').eq('report_group', 'CRISTIAN_TORRES')) as any[];
    const routes = must(await admin.from('routes').select('id, number, carrier_id, operational_status, completed_at, route_stops(*)')
      .in('carrier_id', carriers.map((c) => c.id)).eq('operational_status', 'COMPLETADA')) as any[];
    return routes.map((r) => ({ ...r, stops: r.route_stops ?? [] }));
  },
  async loadCosts() { return must(await admin.from('transport_cost_settings').select('monthly_cost, valid_from, valid_to').eq('carrier_group', 'CRISTIAN_TORRES').order('valid_from')) as any[]; },
  async addCost(monthly_cost: number, valid_from: string, by: string) { must(await admin.rpc('set_transport_cost', { p_group: 'CRISTIAN_TORRES', p_monthly_cost: monthly_cost, p_valid_from: valid_from, p_by: by })); },
  async getSettings() { const d = must(await admin.from('report_settings').select('*').eq('id', 'CRISTIAN_TORRES').maybeSingle()) as any; return d ?? {}; },
  async setSettings(s: any) { must(await admin.from('report_settings').update(s).eq('id', 'CRISTIAN_TORRES')); },
  async findReport(type: string, start: string, end: string) {
    return must(await admin.from('commercial_reports').select('*').eq('report_type', type).eq('period_start', start).eq('period_end', end).order('version', { ascending: false }).limit(1).maybeSingle());
  },
  async saveReport(r: any) { return must(await admin.from('commercial_reports').insert(r).select().single()); },
  async updateReport(id: string, patch: any) { must(await admin.from('commercial_reports').update(patch).eq('id', id)); },
  async getReport(id: string) { return must(await admin.from('commercial_reports').select('*').eq('id', id).maybeSingle()); },
  async listReports(f: any) {
    let q = admin.from('commercial_reports').select('id, report_type, period_start, period_end, version, generated_at, pdf_status, report_emails(recipient, status, sent_at, error, retry_count)').order('generated_at', { ascending: false }).limit(200);
    if (f.type) q = q.eq('report_type', f.type);
    if (f.from) q = q.gte('period_end', f.from);
    if (f.to) q = q.lte('period_start', f.to);
    const rows = (must(await q) as any[]).map((r) => ({ ...r, emails: r.report_emails ?? [] }));
    return f.sent ? rows.filter((r) => (f.sent === 'SI') === r.emails.some((e: any) => e.status === 'SENT')) : rows;
  },
  async savePdf(id: string, bytes: Uint8Array) { const path = id + '.pdf'; must(await admin.storage.from(BUCKET).upload(path, bytes, { contentType: 'application/pdf', upsert: false })); return path; },
  async loadPdf(id: string) { const { data, error } = await admin.storage.from(BUCKET).download(id + '.pdf'); if (error) throw new Error(error.message); return new Uint8Array(await data.arrayBuffer()); },
  async findEmail(key: string) { return must(await admin.from('report_emails').select('*').eq('idempotency_key', key).maybeSingle()); },
  async saveEmail(e: any) { return must(await admin.from('report_emails').insert(e).select().single()); },
  async updateEmail(id: string, patch: any) { must(await admin.from('report_emails').update(patch).eq('id', id)); },
  async listEmails(reportId: string) { return must(await admin.from('report_emails').select('*').eq('report_id', reportId).order('queued_at')); },
  async countResends(reportId: string, recipient: string) { const r = await admin.from('report_emails').select('id', { count: 'exact', head: true }).eq('report_id', reportId).eq('recipient', recipient).eq('is_resend', true); return r.count ?? 0; }
};

// Proveedor de email: Resend (https://resend.com). Cambiable por otro con el mismo contrato send().
const provider = {
  async send(m: any) {
    const toB64 = (b: Uint8Array) => { let s = ''; for (let i = 0; i < b.length; i += 0x8000) s += String.fromCharCode(...b.subarray(i, i + 0x8000)); return btoa(s); };
    const r = await fetch('https://api.resend.com/emails', {
      method: 'POST', headers: { authorization: 'Bearer ' + Deno.env.get('RESEND_API_KEY'), 'content-type': 'application/json', 'idempotency-key': m.idempotencyKey ?? crypto.randomUUID() },
      body: JSON.stringify({ from: Deno.env.get('REPORT_FROM'), to: [m.to], subject: m.subject, html: m.html, text: m.text, attachments: m.attachments.map((a: any) => ({ filename: a.filename, content: toB64(a.content) })) })
    });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error('Resend ' + r.status + ': ' + (j.message ?? 'error'));
    return { id: j.id };
  }
};

const service = createReportService({ store, pdfMaker: reportPdf, provider });
const deps = {
  cronSecret: Deno.env.get('CRON_SECRET') ?? '', store, service, now: () => Date.now(),
  async getUserFromJwt(jwt: string) { const { data } = await admin.auth.getUser(jwt); return data?.user ? { id: data.user.id } : null; },
  async getProfile(id: string) { return must(await admin.from('profiles').select('*').eq('id', id).maybeSingle()); },
  async audit(e: any) { await admin.from('audit_log').insert(e); }
};

Deno.serve(async (req) => {
  try { return await handle(req, deps); }
  catch (e) { return new Response(JSON.stringify({ error: String((e as Error).message || e) }), { status: 500, headers: { 'content-type': 'application/json' } }); }
});
