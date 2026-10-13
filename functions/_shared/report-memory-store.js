// Store en memoria del informe (modo demo y pruebas). Mismo contrato que el store de Supabase (index.ts).
// persist(state) opcional: el modo demo lo guarda en el navegador. Los PDF se guardan en base64.
const toB64 = b => { let s = ''; const a = new Uint8Array(b); for (let i = 0; i < a.length; i += 0x8000) s += String.fromCharCode(...a.subarray(i, i + 0x8000)); return btoa(s); };
const fromB64 = s => Uint8Array.from(atob(s), c => c.charCodeAt(0));
const clone = x => JSON.parse(JSON.stringify(x));

export function memoryStore({ routes = [], costs = [], settings = {}, state, persist } = {}) {
  const S = state || { reports: [], emails: [], pdfs: {}, seq: 0, settings: { recipients: ['administracion@okaccesorios.com.ar'], weekly_time: '15:00', monthly_time: '23:30', require_pdf: true, ...settings }, costs: clone(costs) };
  const save = () => persist && persist(S);
  return {
    state: S,
    routes,
    async loadRoutes() { return this.routes; },
    async loadCosts() { return clone(S.costs); },
    async addCost(monthly_cost, valid_from, by) {
      // Nueva vigencia: cierra la anterior el día previo. El histórico no se reescribe.
      const prev = S.costs.filter(c => !c.valid_to || c.valid_to >= valid_from).sort((a, b) => b.valid_from.localeCompare(a.valid_from))[0];
      if (prev && prev.valid_from < valid_from) prev.valid_to = new Date(Date.parse(valid_from + 'T00:00:00Z') - 86400000).toISOString().slice(0, 10);
      S.costs = S.costs.filter(c => c.valid_from !== valid_from).concat([{ monthly_cost, valid_from, valid_to: null, created_by: by || null }]);
      save();
    },
    async getSettings() { return clone(S.settings); },
    async setSettings(s) { S.settings = { ...S.settings, ...s }; save(); },
    async findReport(type, start, end) { return clone(S.reports.filter(r => r.report_type === type && r.period_start === start && r.period_end === end).sort((a, b) => b.version - a.version)[0] || null); },
    async saveReport(r) { const x = { ...clone(r), id: 'rep-' + (++S.seq) }; S.reports.push(x); save(); return clone(x); },
    async updateReport(id, patch) { Object.assign(S.reports.find(r => r.id === id), patch); save(); },
    async getReport(id) { const r = S.reports.find(x => x.id === id); return r ? clone(r) : null; },
    async listReports(f = {}) {
      return clone(S.reports.filter(r => (!f.type || r.report_type === f.type) && (!f.from || r.period_end >= f.from) && (!f.to || r.period_start <= f.to))
        .map(r => ({ ...r, emails: S.emails.filter(e => e.report_id === r.id) }))
        .filter(r => !f.sent || (f.sent === 'SI' ? r.emails.some(e => e.status === 'SENT') : !r.emails.some(e => e.status === 'SENT')))
        .sort((a, b) => b.generated_at.localeCompare(a.generated_at)));
    },
    async savePdf(id, bytes) { S.pdfs[id] = toB64(bytes); save(); return 'reports/' + id + '.pdf'; },
    async loadPdf(id) { return S.pdfs[id] ? fromB64(S.pdfs[id]) : null; },
    async findEmail(key) { const e = S.emails.find(x => x.idempotency_key === key); return e ? clone(e) : null; },
    async saveEmail(e) { if (S.emails.some(x => x.idempotency_key === e.idempotency_key)) throw new Error('DUPLICATE_KEY'); const x = { ...e, id: 'mail-' + (++S.seq) }; S.emails.push(x); save(); return clone(x); },
    async updateEmail(id, patch) { Object.assign(S.emails.find(e => e.id === id), patch); save(); },
    async listEmails(reportId) { return clone(S.emails.filter(e => e.report_id === reportId)); },
    async countResends(reportId, recipient) { return S.emails.filter(e => e.report_id === reportId && e.recipient === recipient && e.is_resend).length; }
  };
}
