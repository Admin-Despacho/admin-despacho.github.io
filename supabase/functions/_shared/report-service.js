// Servicio del informe: genera snapshot inmutable, PDF, email idempotente y programación.
// Es el mismo código para la Edge Function (Supabase) y para el modo demo; cambia solo el "store".
import { buildReport, dueReports, emailKey, fileName } from './report-engine.js';
import { emailSubject, emailHtml, emailText } from './report-email.js';

/**
 * store = {
 *   loadRoutes(toTs) → hojas (con stops) finalizadas o no; el motor filtra
 *   loadCosts() → vigencias de costo
 *   getSettings() → { recipients: [], monthly_time, weekly_time, require_pdf }
 *   findReport(type, start, end) → último informe de ese tipo y período | null
 *   saveReport(report) → report con id     (snapshot inmutable)
 *   updateReport(id, patch)                (solo pdf_status / pdf_path / pdf_error)
 *   savePdf(id, bytes) → path ; loadPdf(id) → bytes
 *   findEmail(key) → email | null ; saveEmail(email) → email ; updateEmail(id, patch)
 *   countResends(reportId, recipient) → n
 * }
 * pdfMaker(snapshot) → bytes   (report-pdf.js)
 * provider.send({ to, subject, html, text, attachments:[{ filename, content(bytes) }] }) → { id }
 */
export function createReportService({ store, pdfMaker, provider, now = () => Date.now() }) {
  async function makePdf(report) {
    try {
      const bytes = await pdfMaker(report.snapshot);
      const path = await store.savePdf(report.id, bytes);
      await store.updateReport(report.id, { pdf_status: 'OK', pdf_path: path, pdf_error: null });
      return { ...report, pdf_status: 'OK', pdf_path: path };
    } catch (e) {
      await store.updateReport(report.id, { pdf_status: 'PDF_ERROR', pdf_error: String(e.message || e) });
      return { ...report, pdf_status: 'PDF_ERROR', pdf_error: String(e.message || e) };
    }
  }

  // Programados: un solo informe por tipo y período (cron repetido, reintento o redeploy no duplican).
  // Manuales: cada generación es una versión nueva.
  async function generate({ type, sel, actorId = null }) {
    const t = now();
    const snapshot = buildReport({ routes: await store.loadRoutes(), costs: await store.loadCosts(), sel, now: t, type });
    if (type !== 'MANUAL') {
      const existing = await store.findReport(type, snapshot.period.start, snapshot.period.end);
      if (existing) return existing.pdf_status === 'OK' ? existing : await makePdf(existing);
    }
    const prev = await store.findReport(type, snapshot.period.start, snapshot.period.end);
    const version = prev ? prev.version + 1 : 1;
    snapshot.version = version;
    const report = await store.saveReport({ report_type: type, period_start: snapshot.period.start, period_end: snapshot.period.end, version,
      generated_at: snapshot.generated_at, generated_by: actorId, snapshot, pdf_status: 'PENDING' });
    return await makePdf(report);
  }

  // Envía a cada destinatario una sola vez por clave (idempotente). resend=true crea un reenvío explícito.
  async function send(report, { recipients, resend = false, requirePdf = true } = {}) {
    const settings = await store.getSettings();
    const to = recipients || settings.recipients || [];
    const out = [];
    for (const r of to) {
      const n = resend ? (await store.countResends(report.id, r)) + 1 : 0;
      const key = emailKey(report.report_type, report.period_start, report.period_end, r, report.version, n);
      let mail = await store.findEmail(key);
      if (mail && mail.status === 'SENT') { out.push({ ...mail, skipped: true }); continue; } // ya enviado: no duplicar
      if (!mail) mail = await store.saveEmail({ report_id: report.id, recipient: r, idempotency_key: key, status: 'QUEUED', queued_at: new Date(now()).toISOString(), retry_count: 0, is_resend: !!resend });
      else await store.updateEmail(mail.id, { retry_count: (mail.retry_count || 0) + 1 });
      if (report.pdf_status !== 'OK' && (settings.require_pdf ?? requirePdf)) {
        await store.updateEmail(mail.id, { status: 'PDF_ERROR', error: 'El PDF no se generó: no se envía un informe incompleto. Reintentar desde Administración.' });
        out.push({ ...mail, status: 'PDF_ERROR' }); continue;
      }
      try {
        const name = fileName(report.snapshot);
        const attachments = report.pdf_status === 'OK' ? [{ filename: name, content: await store.loadPdf(report.id) }] : [];
        const res = await provider.send({ idempotencyKey: key, to: r, subject: emailSubject(report.snapshot), html: emailHtml(report.snapshot, name), text: emailText(report.snapshot, name), attachments });
        await store.updateEmail(mail.id, { status: 'SENT', sent_at: new Date(now()).toISOString(), provider_id: res && res.id, error: null });
        out.push({ ...mail, status: 'SENT', provider_id: res && res.id });
      } catch (e) {
        await store.updateEmail(mail.id, { status: 'ERROR', error: String(e.message || e) });
        out.push({ ...mail, status: 'ERROR', error: String(e.message || e) });
      }
    }
    return out;
  }

  // Reintento desde Administración: si falló el PDF, se rehace DESDE EL SNAPSHOT (mismos números).
  async function retry(report) {
    const r = report.pdf_status === 'OK' ? report : await makePdf(report);
    return { report: r, emails: await send(r) };
  }

  // Lo llama el cron (cada 15 minutos). Genera y envía lo que corresponde; todo idempotente.
  async function runScheduled() {
    const settings = await store.getSettings();
    const due = dueReports(now(), settings);
    const done = [];
    for (const d of due) {
      const report = await generate({ type: d.type, sel: d.sel });
      done.push({ type: d.type, report_id: report.id, period: report.period_start + '..' + report.period_end, emails: await send(report) });
    }
    return done;
  }

  return { generate, send, retry, runScheduled, makePdf };
}
