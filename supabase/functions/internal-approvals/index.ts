// Edge Function "internal-approvals". Secrets: CRON_SECRET, RESEND_API_KEY, REPORT_FROM, APP_URL.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { json } from '../_shared/http.js';
import { handle } from './handler.js';
const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
const must = <T>(r: { data: T; error: any }) => { if (r.error) throw new Error(r.error.message); return r.data; };
const store = {
  async listJobs(f: any) { let q = admin.from('approval_email_jobs').select('*').in('status', f.statuses); if (f.ids) q = q.in('id', f.ids); return must(await q) as any[]; },
  async routeFor(j: any) {
    const r = must(await admin.from('routes').select('*, route_stops(*)').eq('id', j.route_id).single()) as any;
    const q = must(await admin.from('route_approval_requests').select('review_note').eq('route_id', j.route_id).eq('route_version', j.route_version).maybeSingle()) as any;
    return { ...r, stops: r.route_stops, review_note: q?.review_note };
  },
  async driverName(r: any) { const p = must(await admin.from('profiles').select('full_name').eq('id', r.responsable_id).single()) as any; return p.full_name; },
  async updateJob(id: string, patch: any) { must(await admin.from('approval_email_jobs').update(patch).eq('id', id)); }
};
const customerStore = {
  async listJobs(f: any) { let q = admin.from('customer_email_jobs').select('*').in('status', f.statuses); if (f.ids) q = q.in('id', f.ids); return must(await q) as any[]; },
  async stopFor(j: any) { return must(await admin.from('route_stops').select('client_name, order_numbers').eq('id', j.stop_id).single()); },
  async updateJob(id: string, patch: any) { must(await admin.from('customer_email_jobs').update(patch).eq('id', id)); }
};
const sheetStore = {
  async listJobs() { return must(await admin.from('sheet_email_jobs').select('*').in('status', ['QUEUED', 'ERROR']).lt('retry_count', 5)) as any[]; },
  async pdfFor(j: any) { const p = must(await admin.from('route_pdfs').select('*').eq('route_id', j.route_id).eq('route_version', j.route_version).single()) as any;
    const f = await admin.storage.from('route-pdfs').download(p.storage_path); if (f.error) throw new Error('PDF: ' + f.error.message);
    return { number: p.route_number, file_name: p.file_name, bytes: new Uint8Array(await f.data.arrayBuffer()) }; },
  async updateJob(id: string, patch: any) { must(await admin.from('sheet_email_jobs').update(patch).eq('id', id)); }
};
const provider = { async send(m: any) {
  const r = await fetch('https://api.resend.com/emails', { method: 'POST', headers: { authorization: 'Bearer ' + Deno.env.get('RESEND_API_KEY'), 'content-type': 'application/json', 'idempotency-key': m.idempotencyKey },
    body: JSON.stringify({ from: Deno.env.get('REPORT_FROM'), to: [m.to], subject: m.subject, html: m.html, text: m.text }) });
  const j = await r.json().catch(() => ({})); if (!r.ok) throw new Error('Resend ' + r.status + ': ' + (j.message ?? 'error')); return { id: j.id };
} };
const deps = {
  cronSecret: Deno.env.get('CRON_SECRET') ?? '', appUrl: (Deno.env.get('APP_URL') ?? '').replace(/\/$/, ''), store, customerStore, sheetStore, provider,
  async queueSheetEmails() { must(await admin.rpc('queue_sheet_emails', { p_day: new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Argentina/Mendoza' }).format(new Date()) })); },
  async getUserFromJwt(jwt: string) { const { data } = await admin.auth.getUser(jwt); return data?.user ? { id: data.user.id } : null; },
  async getProfile(id: string) { return must(await admin.from('profiles').select('*').eq('id', id).maybeSingle()); },
  async getSettings() { return must(await admin.from('internal_route_notification_settings').select('*').eq('id', 'DEFAULT').single()); },
  async setSettings(s: any) { must(await admin.from('internal_route_notification_settings').update(s).eq('id', 'DEFAULT')); },
  async audit(e: any) { await admin.from('audit_log').insert(e); }
};
Deno.serve(async (req) => { try { return await handle(req, deps); } catch (e) { return json(500, { error: String((e as Error).message || e), code: 'SERVER_ERROR' }); } });
