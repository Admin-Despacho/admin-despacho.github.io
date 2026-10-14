// Edge Function "internal-approvals". Secrets: CRON_SECRET, RESEND_API_KEY, REPORT_FROM, APP_URL.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { json } from '../_shared/http.js';
import { handle } from './handler.js';
import { resendBody, inlineLogoFrom } from '../_shared/resend-body.js';
import * as logoModule from '../_shared/ok-accesorios-logo.js';
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
  // RC4.1: el Recibido Conforme se arma SIEMPRE desde el comprobante guardado (nunca se regenera ni se duplica)
  async receiptFor(j: any) { return must(await admin.from('delivery_receipts').select('receipt_number, snapshot').eq('stop_id', j.stop_id).single()); },
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
    body: JSON.stringify(resendBody(m, Deno.env.get('REPORT_FROM'))) });
  const j = await r.json().catch(() => ({})); if (!r.ok) throw new Error('Resend ' + r.status + ': ' + (j.message ?? 'error')); return { id: j.id };
} };
const deps = {
  cronSecret: Deno.env.get('CRON_SECRET') ?? '', appUrl: (Deno.env.get('APP_URL') ?? '').replace(/\/$/, ''), store, customerStore, sheetStore, provider,
  inlineLogo: inlineLogoFrom(logoModule),   // RC4.1: logo del Recibido Conforme embebido por CID (no depende de APP_URL)
  async queueSheetEmails() { must(await admin.rpc('queue_sheet_emails', { p_day: new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Argentina/Mendoza' }).format(new Date()) })); },
  async runServiceAlerts() {
    const settings = must(await admin.from('notification_settings').select('*').eq('id', 'DEFAULT').single()) as any;
    if (!settings.service_email_enabled) return [];
    const warning = Math.max(0, Number(settings.service_warning_km ?? 1000));
    const repeat = Math.max(1, Number(settings.service_repeat_km ?? 500));
    const vehicles = must(await admin.from('vehicle_service_status').select('*').eq('active', true)) as any[];
    const admins = settings.service_copy_admin ? must(await admin.from('profiles').select('email').eq('role', 'ADMIN').eq('status', 'ACTIVO')) as any[] : [];
    const out: any[] = [];
    for (const v of vehicles) {
      const remaining = Number(v.km_to_service);
      if (!Number.isFinite(remaining) || remaining > warning) continue;
      const level = remaining <= 0 ? 'REQUIRED' : 'UPCOMING';
      const bucket = level === 'REQUIRED'
        ? Math.floor(Math.max(0, -remaining) / repeat)
        : Math.floor(Math.max(0, warning - remaining) / repeat);
      const recipients = new Set<string>((settings.service_email_recipients || []).map((x: string) => String(x).trim().toLowerCase()).filter(Boolean));
      admins.forEach((a: any) => { if (a.email) recipients.add(String(a.email).trim().toLowerCase()); });
      if (settings.service_copy_driver && v.habitual_driver_id) {
        const p = must(await admin.from('profiles').select('email').eq('id', v.habitual_driver_id).maybeSingle()) as any;
        if (p?.email) recipients.add(String(p.email).trim().toLowerCase());
      }
      const cycle = Number(v.last_service_km ?? 0);
      for (const to of recipients) {
        const key = ['service', v.id, cycle, level, bucket, to].join(':');
        const existing = must(await admin.from('vehicle_service_email_jobs').select('id,status').eq('idempotency_key', key).maybeSingle()) as any;
        if (!existing) {
          must(await admin.from('vehicle_service_email_jobs').insert({ vehicle_id: v.id, cycle_base_km: cycle, alert_level: level, alert_bucket: bucket, recipient: to, idempotency_key: key }));
        }
      }
    }
    const jobs = must(await admin.from('vehicle_service_email_jobs').select('*, vehicle:vehicles(name,plate,current_km,last_service_km,last_service_date,service_interval_km,habitual_driver_id)').in('status', ['QUEUED','ERROR']).lt('retry_count', 5).order('queued_at').limit(200)) as any[];
    for (const j of jobs) {
      const v = j.vehicle || {}, next = Number(v.last_service_km || 0) + Number(v.service_interval_km || 0), current = Number(v.current_km || 0), remaining = next - current;
      const status = j.alert_level === 'REQUIRED' ? (remaining < 0 ? 'VENCIDO' : 'SERVICE REQUERIDO') : 'PRÓXIMO SERVICE';
      const subject = 'OK Despacho · ' + status + ' · ' + (v.name || 'Vehículo') + ' · ' + (v.plate || '');
      const html = '<div style="font-family:Arial,sans-serif;color:#10222c"><h2>' + status + '</h2><p><b>Vehículo:</b> ' + (v.name || '—') + ' · ' + (v.plate || '—') + '</p><p><b>KM actual:</b> ' + current.toLocaleString('es-AR') + '<br><b>Último service:</b> ' + Number(v.last_service_km || 0).toLocaleString('es-AR') + (v.last_service_date ? ' · ' + v.last_service_date : '') + '<br><b>Próximo service:</b> ' + next.toLocaleString('es-AR') + '<br><b>' + (remaining >= 0 ? 'KM restantes' : 'KM excedidos') + ':</b> ' + Math.abs(remaining).toLocaleString('es-AR') + '</p><p>Revisá Vehículos / Service en OK Despacho.</p></div>';
      const textBody = status + '\nVehículo: ' + (v.name || '—') + ' · ' + (v.plate || '—') + '\nKM actual: ' + current + '\nPróximo service: ' + next + '\n' + (remaining >= 0 ? 'KM restantes: ' : 'KM excedidos: ') + Math.abs(remaining);
      try {
        const r = await provider.send({ to: j.recipient, idempotencyKey: j.idempotency_key, subject, html, text: textBody, attachments: [] });
        must(await admin.from('vehicle_service_email_jobs').update({ status: 'SENT', sent_at: new Date().toISOString(), provider_id: r?.id || null, error: null }).eq('id', j.id));
        out.push({ id: j.id, status: 'SENT', recipient: j.recipient, vehicle_id: j.vehicle_id, level: j.alert_level });
      } catch (e) {
        must(await admin.from('vehicle_service_email_jobs').update({ status: 'ERROR', error: String((e as Error).message || e), retry_count: (j.retry_count || 0) + 1 }).eq('id', j.id));
        out.push({ id: j.id, status: 'ERROR', recipient: j.recipient, vehicle_id: j.vehicle_id, level: j.alert_level });
      }
    }
    return out;
  },
  async getUserFromJwt(jwt: string) { const { data } = await admin.auth.getUser(jwt); return data?.user ? { id: data.user.id } : null; },
  async getProfile(id: string) { return must(await admin.from('profiles').select('*').eq('id', id).maybeSingle()); },
  async getSettings() { return must(await admin.from('internal_route_notification_settings').select('*').eq('id', 'DEFAULT').single()); },
  async setSettings(s: any) { must(await admin.from('internal_route_notification_settings').update(s).eq('id', 'DEFAULT')); },
  async audit(e: any) { await admin.from('audit_log').insert(e); }
};
Deno.serve(async (req) => { try { return await handle(req, deps); } catch (e) { return json(500, { error: String((e as Error).message || e), code: 'SERVER_ERROR' }); } });