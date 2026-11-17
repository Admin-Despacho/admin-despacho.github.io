// FINANCIACIÓN PROPIA · calendario de cuotas. MISMA regla que el servidor (_com_terms, migración 001200) para la pantalla y la demo.
// Límite: 30 días corridos desde la CREACIÓN de la solicitud (fecha argentina), el día 30 INCLUIDO. Nunca recorta ni mueve fechas.
export const FREQ = { SEMANAL: 'Semanal (cada 7 días)', QUINCENAL: 'Quincenal (cada 15 días)', MENSUAL: 'Mensual' };
export const FREQ_PLURAL = { SEMANAL: 'semanales', QUINCENAL: 'quincenales', MENSUAL: 'mensuales' };
export const MAX_DAYS = 30;
const TZ = 'America/Argentina/Mendoza';
// fecha argentina (AAAA-MM-DD) de un instante
export const arDate = (d = new Date()) => new Intl.DateTimeFormat('en-CA', { timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date(d));
const parse = iso => { const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(iso || '')); if (!m) return null; const d = new Date(Date.UTC(+m[1], +m[2] - 1, +m[3])); return d.getUTCMonth() === +m[2] - 1 && d.getUTCDate() === +m[3] ? d : null; };
const iso = d => d.toISOString().slice(0, 10);
export const addDays = (s, n) => { const d = parse(s); d.setUTCDate(d.getUTCDate() + n); return iso(d); };
// mes calendario con ajuste de fin de mes, igual que PostgreSQL (31/01 + 1 mes = 28/02)
export const addMonths = (s, n) => { const d = parse(s), y = d.getUTCFullYear(), m = d.getUTCMonth() + n, last = new Date(Date.UTC(y, m + 1, 0)).getUTCDate(); return iso(new Date(Date.UTC(y, m, Math.min(d.getUTCDate(), last)))); };
export const dmyFull = s => { const [y, m, d] = String(s).slice(0, 10).split('-'); return d + '/' + m + '/' + y; };
const r2 = x => Math.round(x * 100) / 100;
// { ok, schedule[{n,due,amount}], limit, last_due, days, error:{code, cuota, due, message} }
export function computeSchedule({ base, installments, frequency, first_due, amount = 0, maxDays = MAX_DAYS }) {
  const maxd = Math.min(Number(maxDays) || MAX_DAYS, MAX_DAYS), limit = addDays(base, maxd), k = Number(installments);
  const fail = (code, message, extra = {}) => ({ ok: false, limit, error: { code, message, ...extra } });
  if (!Number.isInteger(k) || k < 1 || k > 31) return fail('BAD_INSTALLMENTS', 'Elegí una cantidad de cuotas válida.');
  if (!parse(first_due)) return fail('BAD_FIRST_DUE', k === 1 ? 'Elegí la fecha de vencimiento.' : 'Elegí la fecha del primer vencimiento.');
  if (first_due < base) return fail('BAD_FIRST_DUE', 'El primer vencimiento (' + dmyFull(first_due) + ') no puede ser anterior a la creación de la solicitud (' + dmyFull(base) + ').');
  const freq = k > 1 ? String(frequency || '').toUpperCase() : null;
  if (k > 1 && !FREQ[freq]) return fail('BAD_FREQUENCY', 'Con 2 o más cuotas elegí la frecuencia de pago.');
  const a = r2(Number(amount) || 0), part = r2(a / k), schedule = [];
  for (let i = 1; i <= k; i++) {
    const due = k === 1 ? first_due : freq === 'QUINCENAL' ? addDays(first_due, (i - 1) * 15) : freq === 'MENSUAL' ? addMonths(first_due, i - 1) : addDays(first_due, (i - 1) * 7);
    schedule.push({ n: i, due, amount: i < k ? part : r2(a - part * (k - 1)) });
    if (due > limit) return { ...fail('BAD_SCHEDULE', 'La cuota ' + i + ' vence el ' + dmyFull(due) + ' y supera el límite del ' + dmyFull(limit) + ' (' + maxd + ' días corridos desde la creación de la solicitud). Corregí la cantidad, la frecuencia o el primer vencimiento.', { cuota: i, due }), schedule };
  }
  const last = schedule[k - 1].due;
  return { ok: true, schedule, limit, last_due: last, days: Math.round((parse(last) - parse(base)) / 864e5), frequency: freq, first_due };
}
