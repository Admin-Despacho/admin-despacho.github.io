// =====================================================================
// INFORME COMERCIAL · CRISTIAN TORRES — motor de cálculo (único, compartido)
// Lo usan: la pantalla (modo demo y online), la Edge Function (programado/manual),
// el email y el PDF. Toda regla de negocio del informe vive acá.
//
// Reglas aprobadas:
//  · Solo cuentan hojas FINALIZADAS (operational_status = COMPLETADA). PUBLICADA y EN CURSO no.
//  · Fecha que manda: fecha/hora REAL de finalización (completed_at), zona America/Argentina/Mendoza.
//  · ENTREGADO y ENTREGA PARCIAL = COMPLETADO (suman ingreso de envío).
//    NO ENTREGADO y REPROGRAMAR = NO COMPLETADO (no suman ingreso).
//  · Ingreso = SOLO servicio de envío (shipping_fee congelado en la hoja). Nunca mercadería ni cobranzas.
//  · Zonas siempre separadas: ESTE · ALREDEDORES · CENTRO.
//  · Costo mensual con vigencia; períodos parciales se prorratean por día (ver costForPeriod).
// =====================================================================

export const TZ = 'America/Argentina/Mendoza';
export const ZONES = ['ESTE', 'ALREDEDORES', 'CENTRO'];
export const ZONE_LABEL = { ESTE: 'Zona Este', ALREDEDORES: 'Alrededores', CENTRO: 'Centro' };
export const COMPLETED = new Set(['ENTREGADO', 'ENTREGA_PARCIAL']);
export const MONTHS = ['Enero', 'Febrero', 'Marzo', 'Abril', 'Mayo', 'Junio', 'Julio', 'Agosto', 'Septiembre', 'Octubre', 'Noviembre', 'Diciembre'];
const DAY = 86400000;
const r2 = n => Math.round((Number(n) || 0) * 100) / 100;

// ---------- Fechas en Mendoza ----------
// Argentina no aplica horario de verano desde 2009: Mendoza = UTC-03:00. Igual se calcula con Intl.
const fmtParts = new Intl.DateTimeFormat('en-CA', { timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23', weekday: 'short' });
export function local(ts) {
  const p = Object.fromEntries(fmtParts.formatToParts(new Date(ts)).map(x => [x.type, x.value]));
  return { date: p.year + '-' + p.month + '-' + p.day, hour: +p.hour, minute: +p.minute, weekday: ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'].indexOf(p.weekday) };
}
export const localDate = ts => local(ts).date;
// Instante UTC de una fecha/hora local de Mendoza
export function atLocal(date, hhmm = '00:00') {
  const guess = Date.parse(date + 'T' + hhmm + ':00Z') + 3 * 3600000; // UTC-3
  const l = local(guess);
  const want = Date.parse(date + 'T' + hhmm + ':00Z'), got = Date.parse(l.date + 'T' + String(l.hour).padStart(2, '0') + ':' + String(l.minute).padStart(2, '0') + ':00Z');
  return guess + (want - got); // corrige si alguna vez cambiara el huso
}
export const addDays = (date, n) => new Date(Date.parse(date + 'T00:00:00Z') + n * DAY).toISOString().slice(0, 10);
export const daysBetween = (a, b) => Math.round((Date.parse(b + 'T00:00:00Z') - Date.parse(a + 'T00:00:00Z')) / DAY);
export const daysInMonth = (y, m) => new Date(Date.UTC(y, m, 0)).getUTCDate(); // m = 1..12
export const dmy = d => d.slice(8, 10) + '/' + d.slice(5, 7) + '/' + d.slice(0, 4);
export const money = n => '$ ' + Math.round(Number(n) || 0).toLocaleString('es-AR');

/**
 * Período a analizar. Fechas locales de Mendoza, extremos incluidos.
 *  { kind: '7D' }  últimos 7 días (hoy incluido) · { kind: '15D' }
 *  { kind: 'MONTH', year, month }  mes CALENDARIO (no "últimos 30 días")
 *  { kind: 'FREE', from, to }      desde / hasta
 *  { kind: 'WEEKLY', saturday }    informe semanal: desde el sábado anterior 15:00 hasta ese sábado 15:00
 *  { kind: 'MONTHLY', year, month } informe mensual
 * Devuelve: { start, end, days, label, fromTs, toTs } con [fromTs, toTs) en milisegundos UTC.
 */
export function period(sel, now = Date.now()) {
  const today = localDate(now);
  const range = (start, end, label) => ({ start, end, days: daysBetween(start, end) + 1, label, fromTs: atLocal(start), toTs: atLocal(addDays(end, 1)) });
  switch (sel.kind) {
    case '7D': return range(addDays(today, -6), today, 'Últimos 7 días');
    case '15D': return range(addDays(today, -14), today, 'Últimos 15 días');
    case 'MONTH': case 'MONTHLY': {
      const m = String(sel.month).padStart(2, '0');
      const start = sel.year + '-' + m + '-01', end = sel.year + '-' + m + '-' + String(daysInMonth(sel.year, sel.month)).padStart(2, '0');
      return range(start, end, MONTHS[sel.month - 1] + ' ' + sel.year);
    }
    case 'FREE': {
      if (!sel.from || !sel.to || sel.from > sel.to) throw new Error('Período inválido: "Desde" debe ser anterior o igual a "Hasta".');
      return range(sel.from, sel.to, dmy(sel.from) + ' al ' + dmy(sel.to));
    }
    case 'WEEKLY': {
      // Corte: sábado 15:00 Mendoza. Lo que finaliza después entra en el informe siguiente (sin huecos ni duplicados).
      // Una sola convención en asunto, email, PDF, historial y pantalla: la ventana real sábado 15:00 → sábado 15:00.
      const sat = sel.saturday, prevSat = addDays(sat, -7);
      const win = dmy(prevSat) + ' 15:00 al ' + dmy(sat) + ' 15:00';
      return { start: prevSat, end: sat, days: 7, costStart: addDays(sat, -6), costEnd: sat, label: 'Ventana ' + win, window: win, fromTs: atLocal(prevSat, '15:00'), toTs: atLocal(sat, '15:00'),
        cutoffNote: 'Ventana analizada: ' + win + '. Lo que se finaliza después entra en el informe siguiente.' };
    }
    default: throw new Error('Filtro desconocido');
  }
}

/**
 * Costo de Cristian para el período, con vigencias. Convención de prorrateo:
 *   cada día cuesta (costo mensual vigente ese día) / (días de ESE mes calendario).
 *   Un mes calendario completo = exactamente el costo mensual. 7 días de octubre = costo × 7/31.
 * costs: [{ monthly_cost, valid_from: 'YYYY-MM-DD', valid_to: 'YYYY-MM-DD' | null }]
 */
export function costForPeriod(costs, start, end) {
  let total = 0, d = start;
  while (d <= end) {
    const c = (costs || []).filter(x => x.valid_from <= d && (!x.valid_to || x.valid_to >= d)).sort((a, b) => b.valid_from.localeCompare(a.valid_from))[0];
    if (c) total += Number(c.monthly_cost) / daysInMonth(+d.slice(0, 4), +d.slice(5, 7));
    d = addDays(d, 1);
  }
  return r2(total);
}

// Paradas consolidadas: hoja FINALIZADA dentro de [fromTs, toTs)
export function consolidatedStops(routes, fromTs, toTs) {
  const out = [];
  for (const r of routes || []) {
    if (r.operational_status !== 'COMPLETADA' || !r.completed_at) continue;
    const t = Date.parse(r.completed_at);
    if (!(t >= fromTs && t < toTs)) continue;
    for (const s of r.stops || []) out.push({ ...s, route_id: r.id, route_number: r.number, completed_at: r.completed_at, day: localDate(t) });
  }
  return out;
}

// Un costo de envío provisorio sin confirmar por el operador no es ingreso consolidado
export const pendingFee = s => s.shipping_fee_source === 'PENDING_CONFIRMATION' || s.shipping_fee_status === 'PENDING_CONFIRMATION';
function zoneTotals(stops) {
  const z = Object.fromEntries(ZONES.map(k => [k, { zone: k, completed: 0, not_delivered: 0, rescheduled: 0, income: 0 }]));
  for (const s of stops) {
    const t = z[s.zone]; if (!t) continue;
    if (COMPLETED.has(s.outcome)) { t.completed++; if (!pendingFee(s)) t.income += Number(s.shipping_fee) || 0; }
    else if (s.outcome === 'NO_ENTREGADO') t.not_delivered++;
    else if (s.outcome === 'REPROGRAMAR') t.rescheduled++;
  }
  const rows = ZONES.map(k => ({ ...z[k], income: r2(z[k].income), avg: z[k].completed ? r2(z[k].income / z[k].completed) : 0 }));
  const total = rows.reduce((a, x) => ({ completed: a.completed + x.completed, not_delivered: a.not_delivered + x.not_delivered, rescheduled: a.rescheduled + x.rescheduled, income: r2(a.income + x.income) }), { completed: 0, not_delivered: 0, rescheduled: 0, income: 0 });
  total.avg = total.completed ? r2(total.income / total.completed) : 0;
  return { rows, total };
}

// Historial de compras por cliente (una compra = una entrega completada en una hoja finalizada)
function clientHistory(stops) {
  const m = new Map();
  for (const s of stops) {
    if (!COMPLETED.has(s.outcome)) continue;
    const k = s.client_key || s.client_name;
    if (!m.has(k)) m.set(k, { key: k, name: s.client_name, zones: {}, dates: [], amount: 0 });
    const c = m.get(k); c.dates.push(s.day); c.zones[s.zone] = (c.zones[s.zone] || 0) + 1; c.amount += Number(s.merchandise_amount) || 0;
  }
  for (const c of m.values()) {
    c.dates.sort(); c.zone = Object.entries(c.zones).sort((a, b) => b[1] - a[1])[0][0];
    const uniq = [...new Set(c.dates)];
    c.freq = uniq.length >= 2 ? r2(daysBetween(uniq[0], uniq[uniq.length - 1]) / (uniq.length - 1)) : null;
    c.last = uniq[uniq.length - 1]; c.amount = r2(c.amount);
  }
  return m;
}

/**
 * Estado de un cliente contra SU propia frecuencia (no solo 30/60/90 días):
 *   ratio = días sin comprar / frecuencia habitual
 *   CONTACTAR HOY: ratio ≥ 3, o más de 60 días con ratio ≥ 2
 *   RECUPERAR: ratio ≥ 2 · ATRASADO: ratio ≥ 1,5 · SEGUIMIENTO: ratio ≥ 1,2
 */
export function recoveryStatus(daysSince, freq) {
  if (!freq || freq <= 0) return null;
  const ratio = daysSince / freq;
  if (ratio >= 3 || (daysSince > 60 && ratio >= 2)) return 'CONTACTAR HOY';
  if (ratio >= 2) return 'RECUPERAR';
  if (ratio >= 1.5) return 'ATRASADO';
  if (ratio >= 1.2) return 'SEGUIMIENTO';
  return null;
}
const ACTION = { 'CONTACTAR HOY': 'Llamar hoy y ofrecer reposición', RECUPERAR: 'Contactar esta semana con propuesta', ATRASADO: 'Recordatorio de pedido', SEGUIMIENTO: 'Seguir de cerca' };

/**
 * Arma el informe completo (snapshot inmutable).
 * input: { routes (con stops), costs, sel, now, type: 'WEEKLY'|'MONTHLY'|'MANUAL'|'SCREEN' }
 */
export function buildReport({ routes, costs, sel, now = Date.now(), type = 'SCREEN' }) {
  const p = period(sel, now);
  const stops = consolidatedStops(routes, p.fromTs, p.toTs);
  const zones = zoneTotals(stops);
  const cost = costForPeriod(costs, p.costStart || p.start, p.costEnd || p.end);
  const diff = r2(zones.total.income - cost);
  const coverage = { income_by_zone: Object.fromEntries(zones.rows.map(z => [z.zone, z.income])), income: zones.total.income, cost, diff, covers: diff >= 0,
    verdict: diff >= 0 ? 'CUBRE EL COSTO' : 'NO CUBRE EL COSTO', text: diff >= 0 ? 'Sobran ' + money(diff) : 'Faltan ' + money(-diff) };

  // Clientes: historial completo hasta el fin del período (para medir frecuencia)
  const histAll = clientHistory(consolidatedStops(routes, 0, p.toTs));
  const inPeriod = clientHistory(stops);
  const best = [...inPeriod.values()].map(c => {
    const h = histAll.get(c.key);
    return { client: c.name, zone: c.zone, purchases: c.dates.length, freq: h.freq, last: h.last, amount: c.amount };
  }).sort((a, b) => b.purchases - a.purchases || b.amount - a.amount || a.client.localeCompare(b.client)).slice(0, 10);

  const endDate = p.end, d90 = addDays(endDate, -89);
  const recover = [];
  let over30 = 0, over60 = 0, over90 = 0;
  for (const h of histAll.values()) {
    const since = daysBetween(h.last, endDate);
    if (since > 90) over90++; else if (since > 60) over60++; else if (since > 30) over30++;
    const st = recoveryStatus(since, h.freq);
    if (!st) continue;
    recover.push({ client: h.name, zone: h.zone, last: h.last, days_since: since, freq: h.freq, purchases_90: h.dates.filter(d => d >= d90).length,
      deviation: r2(since - h.freq), ratio: r2(since / h.freq), status: st, action: ACTION[st] });
  }
  const order = { 'CONTACTAR HOY': 0, RECUPERAR: 1, ATRASADO: 2, SEGUIMIENTO: 3 };
  recover.sort((a, b) => order[a.status] - order[b.status] || b.ratio - a.ratio || a.client.localeCompare(b.client));

  // Zonas a reforzar: período actual vs. período anterior de igual largo
  const prevStops = consolidatedStops(routes, p.fromTs - (p.toTs - p.fromTs), p.fromTs);
  const prev = zoneTotals(prevStops);
  const workDays = new Set(stops.filter(s => COMPLETED.has(s.outcome)).map(s => s.day)).size || 1;
  const reinforce = zones.rows.map(z => {
    const pz = prev.rows.find(x => x.zone === z.zone);
    const growth = pz.completed ? r2((z.completed - pz.completed) / pz.completed * 100) : (z.completed ? 100 : 0);
    const done = z.completed + z.not_delivered + z.rescheduled;
    const effectiveness = done ? r2(z.completed / done * 100) : 100;
    const zoneClients = [...histAll.values()].filter(h => h.zone === z.zone);
    const active = zoneClients.filter(h => daysBetween(h.last, endDate) <= 30).length;
    const inactive = zoneClients.filter(h => daysBetween(h.last, endDate) > 60).length;
    const outOfFreq = recover.filter(c => c.zone === z.zone).length;
    const freqs = zoneClients.map(h => h.freq).filter(Boolean);
    const share = zones.total.completed ? z.completed / zones.total.completed * 100 : 0;
    const loadPerDay = r2(z.completed / workDays);
    let decision = 'MANTENER', why = 'Volumen ' + (Math.abs(growth) < 15 ? 'estable' : growth > 0 ? 'en suba' : 'en baja') + ' (' + (growth >= 0 ? '+' : '') + Math.round(growth) + '% vs. período anterior) y efectividad ' + Math.round(effectiveness) + '%.';
    if (share >= 35 && growth >= 10 && (effectiveness < 90 || loadPerDay >= (zones.total.completed / workDays / ZONES.length) * 1.2)) {
      decision = 'REFORZAR REPARTO';
      why = 'Concentra el ' + Math.round(share) + '% de los envíos, crece ' + growth + '% y tiene ' + (effectiveness < 90 ? 'efectividad ' + effectiveness + '%' : loadPerDay + ' envíos por día de reparto') + '.';
    } else if (outOfFreq >= 3 || (zoneClients.length && outOfFreq / zoneClients.length >= 0.25)) {
      decision = 'RECUPERAR COMERCIALMENTE';
      why = outOfFreq + ' clientes fuera de su frecuencia habitual y ' + inactive + ' con más de 60 días sin comprar.';
    }
    return { zone: z.zone, completed: z.completed, not_delivered: z.not_delivered, rescheduled: z.rescheduled, income: z.income, growth, effectiveness,
      active_clients: active, inactive_clients: inactive, out_of_freq: outOfFreq, avg_freq: freqs.length ? r2(freqs.reduce((a, b) => a + b, 0) / freqs.length) : null,
      load_per_day: loadPerDay, share: r2(share), decision, why };
  });

  // Decisiones comerciales (máximo 5, explicadas con números)
  const decisions = [];
  const top = [...zones.rows].sort((a, b) => b.completed - a.completed)[0];
  if (top && top.completed) decisions.push(ZONE_LABEL[top.zone] + ' concentra el mayor volumen (' + top.completed + ' envíos): ' + (reinforce.find(x => x.zone === top.zone).decision === 'REFORZAR REPARTO' ? 'evaluar refuerzo de reparto en días pico.' : 'sostener la frecuencia de reparto.'));
  for (const z of reinforce) if (z.decision === 'RECUPERAR COMERCIALMENTE') decisions.push(ZONE_LABEL[z.zone] + ' tiene ' + z.out_of_freq + ' clientes fuera de frecuencia: priorizar recuperación comercial.');
  if (over60 + over90) decisions.push((over60 + over90) + ' clientes superan 60 días sin comprar.');
  decisions.push(coverage.covers ? 'El ingreso por envíos cubre el costo de Cristian (' + coverage.text.toLowerCase() + ').' : 'El ingreso por envíos no cubre el costo de Cristian (' + coverage.text.toLowerCase() + '): revisar volumen o tarifa.');
  const urgent = recover.filter(c => c.status === 'CONTACTAR HOY').length;
  if (urgent) decisions.push(urgent + ' clientes para CONTACTAR HOY.');

  return {
    version: 1, type, generated_at: new Date(now).toISOString(), tz: TZ,
    period: { start: p.start, end: p.end, days: p.days, label: p.label, window: p.window || null, from: new Date(p.fromTs).toISOString(), to: new Date(p.toTs).toISOString(), cutoff_note: p.cutoffNote || null },
    summary: { completed: zones.total.completed, not_delivered: zones.total.not_delivered, rescheduled: zones.total.rescheduled, note: 'Entrega parcial se contabiliza como completada.' },
    zones: zones.rows, total: zones.total, coverage,
    best_clients: best, recover, alerts: { over30, over60, over90 }, reinforce, decisions: decisions.slice(0, 5),
    // Lo que se usó para calcular (queda congelado en el histórico)
    inputs: { costs_used: (costs || []).map(c => ({ ...c })), routes_counted: [...new Set(stops.map(s => s.route_number))], stops_counted: stops.length,
      fees_excluded_pending: stops.filter(s => COMPLETED.has(s.outcome) && pendingFee(s)).length,
      fees_used: stops.filter(s => COMPLETED.has(s.outcome) && !pendingFee(s)).map(s => ({ route: s.route_number, client: s.client_name, zone: s.zone, fee: Number(s.shipping_fee) || 0 })) }
  };
}

// ---------- Programación (sábado 15:00 y cierre de mes) ----------
// Devuelve los informes que corresponde generar en este momento (el envío es idempotente aparte).
export function dueReports(now, settings = {}) {
  const l = local(now), out = [];
  const weeklyTime = settings.weekly_time || '15:00', monthlyTime = settings.monthly_time || '23:30';
  const [wh, wm] = weeklyTime.split(':').map(Number), [mh, mm] = monthlyTime.split(':').map(Number);
  const mins = l.hour * 60 + l.minute;
  if (l.weekday === 6 && mins >= wh * 60 + wm) out.push({ type: 'WEEKLY', sel: { kind: 'WEEKLY', saturday: l.date } });
  const y = +l.date.slice(0, 4), m = +l.date.slice(5, 7);
  if (+l.date.slice(8, 10) === daysInMonth(y, m) && mins >= mh * 60 + mm) out.push({ type: 'MONTHLY', sel: { kind: 'MONTHLY', year: y, month: m } });
  return out;
}

// Clave de idempotencia del email
export const emailKey = (type, start, end, recipient, version = 1, resend = 0) =>
  [type, start, end, String(recipient).toLowerCase(), 'v' + version].join('|') + (resend ? '|reenvio-' + resend : '');

export const fileName = rep => rep.type === 'MONTHLY'
  ? 'Informe_Cristian_Torres_Mensual_' + rep.period.start.slice(0, 7) + '.pdf'
  : 'Informe_Cristian_Torres_' + (rep.type === 'WEEKLY' ? 'Semanal' : 'Manual') + '_' + rep.period.end + '.pdf';
