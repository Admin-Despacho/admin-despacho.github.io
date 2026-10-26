// =====================================================================
// INFORME COMERCIAL · CRISTIAN TORRES — motor de cálculo (único, compartido)
// Lo usan: la pantalla (modo demo y online), la Edge Function (programado/manual),
// el email y el PDF. Toda regla de negocio del informe vive acá.
//
// Reglas aprobadas:
//  · (V2) Cuentan las hojas PUBLICADAS desde su publicación: pendientes, en curso o finalizadas. Se excluyen BORRADOR y CANCELADA.
//    No hace falta que Cristian marque ENTREGADO ni complete la hoja. Se incluyen las hojas antiguas ya publicadas (sin corte).
//  · Fecha que manda: PUBLICACIÓN (published_at; tercerizado: dispatched_at; si falta, el registro histórico ROUTE_PUBLISHED de
//    audit_log). Nunca se inventa ni se usa la finalización: una hoja sin fecha de publicación confiable queda FUERA y se informa.
//    Zona horaria America/Argentina/Mendoza.
//  · Cada envío (parada comercial) cuenta UNA vez (hoja + parada): finalizar una entrega o tener varias versiones no lo suma de nuevo.
//    El estado (pendiente, entregado, no entregado, reprogramado) se informa aparte y NO cambia los totales.
//  · Importe = SOLO el importe de envío informado y guardado en la hoja (shipping_fee). No es dinero cobrado, ni mercadería, ni cobranza.
//  · Los informes guardados con la versión 1 (solo hojas finalizadas) se conservan tal cual en el historial.
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
 *  { kind: 'WEEKLY', saturday }    informe semanal: desde el sábado anterior al corte actual
 *  { kind: 'BIWEEKLY', cutoff, previous, time } informe quincenal entre dos cortes configurados
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
      const sat = sel.saturday, prevSat = addDays(sat, -7), time = sel.time || '15:00';
      const win = dmy(prevSat) + ' ' + time + ' al ' + dmy(sat) + ' ' + time;
      return { start: prevSat, end: sat, days: 7, costStart: addDays(sat, -6), costEnd: sat, label: 'Ventana ' + win, window: win, fromTs: atLocal(prevSat, time), toTs: atLocal(sat, time),
        cutoffNote: 'Ventana analizada: ' + win + '. Lo que se finaliza después entra en el informe siguiente.' };
    }
    case 'BIWEEKLY': {
      const cutoff = sel.cutoff, prev = sel.previous, time = sel.time || '15:00';
      if (!cutoff || !prev || prev >= cutoff) throw new Error('Período quincenal inválido.');
      const win = dmy(prev) + ' ' + time + ' al ' + dmy(cutoff) + ' ' + time;
      return { start: prev, end: cutoff, days: daysBetween(prev, cutoff), costStart: addDays(prev, 1), costEnd: cutoff, label: 'Quincenal · ' + win, window: win, fromTs: atLocal(prev, time), toTs: atLocal(cutoff, time),
        cutoffNote: 'Ventana quincenal analizada: ' + win + '. Lo que se finaliza después entra en el informe siguiente.' };
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

export const REPORT_VERSION = 2;
const EXCLUDED = new Set(['BORRADOR', 'CANCELADA']);
const isShipment = s => !s.stop_type || s.stop_type === 'PEDIDO';   // TAREA y ubicaciones internas no son envíos
// Fecha de PUBLICACIÓN de una hoja y su origen (null si no hay una fuente confiable)
export function publication(r) {
  if (r.published_at) return { at: r.published_at, source: 'published_at' };
  if (r.dispatch_mode === 'EXTERNAL' && r.dispatched_at) return { at: r.dispatched_at, source: 'dispatched_at' };
  if (r.published_at_hist) return { at: r.published_at_hist, source: 'audit_log' };   // registro ROUTE_PUBLISHED (lo carga el servidor)
  return null;
}
// Envíos de hojas PUBLICADAS dentro de [fromTs, toTs) por fecha de publicación. Sin duplicados (hoja + parada).
export function consolidatedStops(routes, fromTs, toTs) {
  const out = [], seen = new Set();
  for (const r of routes || []) {
    if (EXCLUDED.has(r.operational_status)) continue;
    const pub = publication(r); if (!pub) continue;
    const t = Date.parse(pub.at);
    if (!(t >= fromTs && t < toTs)) continue;
    (r.stops || []).forEach((s, i) => {
      if (!isShipment(s)) return;
      // un envío = hoja + parada (id real; si no lo hay, su posición dentro de la hoja). Nunca se suma dos veces.
      const k = r.id + '|' + (s.id != null ? 'id:' + s.id : '#' + i);
      if (seen.has(k)) return; seen.add(k);
      out.push({ ...s, route_id: r.id, route_number: r.number, published_at: pub.at, publication_source: pub.source, day: localDate(t) });
    });
  }
  return out;
}
// Hojas publicadas (no borrador ni cancelada) SIN fecha de publicación confiable: no se incluyen y se informan
export const missingPublication = routes => (routes || []).filter(r => !EXCLUDED.has(r.operational_status) && !publication(r)).map(r => r.number);

// Un costo de envío provisorio sin confirmar por el operador no es ingreso consolidado
export const pendingFee = s => s.shipping_fee_source === 'PENDING_CONFIRMATION' || s.shipping_fee_status === 'PENDING_CONFIRMATION';
// V2: TODOS los envíos de hojas publicadas cuentan (cantidad e importe), sin importar su estado; el estado se desglosa aparte.
// "delivered" = ENTREGADO o ENTREGA PARCIAL; "pending" = sin resultado todavía (nunca se presenta como entregado).
// "completed" se mantiene como sinónimo de "delivered" solo por compatibilidad de lectura.
function zoneTotals(stops) {
  const blank = k => ({ zone: k, shipments: 0, delivered: 0, pending: 0, not_delivered: 0, rescheduled: 0, income: 0, priced: 0, fee_pending: 0 });
  const z = Object.fromEntries(ZONES.map(k => [k, blank(k)]));
  for (const s of stops) {
    const t = z[s.zone]; if (!t) continue;
    t.shipments++;
    if (COMPLETED.has(s.outcome)) t.delivered++;
    else if (s.outcome === 'NO_ENTREGADO') t.not_delivered++;
    else if (s.outcome === 'REPROGRAMAR') t.rescheduled++;
    else t.pending++;
    if (pendingFee(s)) t.fee_pending++; else { t.income += Number(s.shipping_fee) || 0; t.priced++; }
  }
  const fin = x => ({ ...x, income: r2(x.income), avg: x.priced ? r2(x.income / x.priced) : 0, completed: x.delivered });
  const rows = ZONES.map(k => fin(z[k]));
  const total = fin(rows.reduce((a, x) => { for (const k of ['shipments', 'delivered', 'pending', 'not_delivered', 'rescheduled', 'income', 'priced', 'fee_pending']) a[k] += x[k]; return a; }, blank('TOTAL')));
  return { rows, total };
}

// Historial de compras por cliente (V2: una compra = un envío de una hoja publicada, por fecha de publicación)
function clientHistory(stops) {
  const m = new Map();
  for (const s of stops) {
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
  const workDays = new Set(stops.map(s => s.day)).size || 1;   // días con hojas publicadas
  const reinforce = zones.rows.map(z => {
    const pz = prev.rows.find(x => x.zone === z.zone);
    const growth = pz.shipments ? r2((z.shipments - pz.shipments) / pz.shipments * 100) : (z.shipments ? 100 : 0);
    const done = z.delivered + z.not_delivered + z.rescheduled;   // efectividad solo sobre envíos con resultado (los pendientes no cuentan)
    const effectiveness = done ? r2(z.delivered / done * 100) : 100;
    const zoneClients = [...histAll.values()].filter(h => h.zone === z.zone);
    const active = zoneClients.filter(h => daysBetween(h.last, endDate) <= 30).length;
    const inactive = zoneClients.filter(h => daysBetween(h.last, endDate) > 60).length;
    const outOfFreq = recover.filter(c => c.zone === z.zone).length;
    const freqs = zoneClients.map(h => h.freq).filter(Boolean);
    const share = zones.total.shipments ? z.shipments / zones.total.shipments * 100 : 0;
    const loadPerDay = r2(z.shipments / workDays);
    let decision = 'MANTENER', why = 'Volumen ' + (Math.abs(growth) < 15 ? 'estable' : growth > 0 ? 'en suba' : 'en baja') + ' (' + (growth >= 0 ? '+' : '') + Math.round(growth) + '% vs. período anterior) y efectividad ' + Math.round(effectiveness) + '%.';
    if (share >= 35 && growth >= 10 && (effectiveness < 90 || loadPerDay >= (zones.total.shipments / workDays / ZONES.length) * 1.2)) {
      decision = 'REFORZAR REPARTO';
      why = 'Concentra el ' + Math.round(share) + '% de los envíos, crece ' + growth + '% y tiene ' + (effectiveness < 90 ? 'efectividad ' + effectiveness + '%' : loadPerDay + ' envíos por día de reparto') + '.';
    } else if (outOfFreq >= 3 || (zoneClients.length && outOfFreq / zoneClients.length >= 0.25)) {
      decision = 'RECUPERAR COMERCIALMENTE';
      why = outOfFreq + ' clientes fuera de su frecuencia habitual y ' + inactive + ' con más de 60 días sin comprar.';
    }
    return { zone: z.zone, shipments: z.shipments, delivered: z.delivered, pending: z.pending, completed: z.delivered, not_delivered: z.not_delivered, rescheduled: z.rescheduled, income: z.income, growth, effectiveness,
      active_clients: active, inactive_clients: inactive, out_of_freq: outOfFreq, avg_freq: freqs.length ? r2(freqs.reduce((a, b) => a + b, 0) / freqs.length) : null,
      load_per_day: loadPerDay, share: r2(share), decision, why };
  });

  // Decisiones comerciales (máximo 5, explicadas con números)
  const decisions = [];
  const top = [...zones.rows].sort((a, b) => b.shipments - a.shipments)[0];
  if (top && top.shipments) decisions.push(ZONE_LABEL[top.zone] + ' concentra el mayor volumen (' + top.shipments + ' envíos publicados): ' + (reinforce.find(x => x.zone === top.zone).decision === 'REFORZAR REPARTO' ? 'evaluar refuerzo de reparto en días pico.' : 'sostener la frecuencia de reparto.'));
  for (const z of reinforce) if (z.decision === 'RECUPERAR COMERCIALMENTE') decisions.push(ZONE_LABEL[z.zone] + ' tiene ' + z.out_of_freq + ' clientes fuera de frecuencia: priorizar recuperación comercial.');
  if (over60 + over90) decisions.push((over60 + over90) + ' clientes superan 60 días sin comprar.');
  decisions.push(coverage.covers ? 'El ingreso por envíos cubre el costo de Cristian (' + coverage.text.toLowerCase() + ').' : 'El ingreso por envíos no cubre el costo de Cristian (' + coverage.text.toLowerCase() + '): revisar volumen o tarifa.');
  const urgent = recover.filter(c => c.status === 'CONTACTAR HOY').length;
  if (urgent) decisions.push(urgent + ' clientes para CONTACTAR HOY.');

  return {
    // 'criterion' identifica el criterio (no se pisa); 'version' lo reemplaza el servicio con el número de regeneración del período
    version: 1, criterion: 'HOJAS_PUBLICADAS', criterion_version: REPORT_VERSION, type, generated_at: new Date(now).toISOString(), tz: TZ,
    period: { start: p.start, end: p.end, days: p.days, label: p.label, window: p.window || null, from: new Date(p.fromTs).toISOString(), to: new Date(p.toTs).toISOString(), cutoff_note: p.cutoffNote || null },
    summary: { shipments: zones.total.shipments, delivered: zones.total.delivered, pending: zones.total.pending, completed: zones.total.delivered, not_delivered: zones.total.not_delivered,
      rescheduled: zones.total.rescheduled, note: 'Incluye todos los envíos de hojas publicadas, aunque estén pendientes. El importe es el envío informado en la hoja: no es dinero cobrado. Entrega parcial cuenta como entregada.' },
    zones: zones.rows, total: zones.total, coverage,
    best_clients: best, recover, alerts: { over30, over60, over90 }, reinforce, decisions: decisions.slice(0, 5),
    // Lo que se usó para calcular (queda congelado en el histórico)
    inputs: { costs_used: (costs || []).map(c => ({ ...c })), routes_counted: [...new Set(stops.map(s => s.route_number))], stops_counted: stops.length,
      fees_excluded_pending: stops.filter(s => pendingFee(s)).length,
      fees_used: stops.filter(s => !pendingFee(s)).map(s => ({ route: s.route_number, client: s.client_name, zone: s.zone, fee: Number(s.shipping_fee) || 0, outcome: s.outcome || 'PENDIENTE' })),
      // hojas publicadas sin fecha de publicación confiable: NO incluidas (no se inventa la fecha ni se usa la de finalización)
      missing_publication: missingPublication(routes),
      publication_sources: stops.reduce((a, s) => { a[s.publication_source] = (a[s.publication_source] || 0) + 1; return a; }, {}) }
  };
}

// ---------- Programación (sábado 15:00 y cierre de mes) ----------
// Devuelve los informes que corresponde generar en este momento (el envío es idempotente aparte).
export function dueReports(now, settings = {}) {
  const l = local(now), out = [], mode = settings.schedule_mode || 'WEEKLY';
  if (mode === 'OFF') return out;
  const weeklyTime = settings.weekly_time || '15:00', monthlyTime = settings.monthly_time || '23:30', biweeklyTime = settings.biweekly_time || '15:00';
  const mins = l.hour * 60 + l.minute, atOrAfter = t => { const [h, m] = t.split(':').map(Number); return mins >= h * 60 + m; };
  const y = +l.date.slice(0, 4), m = +l.date.slice(5, 7), day = +l.date.slice(8, 10);
  if (mode === 'WEEKLY' && l.weekday === (settings.weekly_day ?? 6) && atOrAfter(weeklyTime)) {
    out.push({ type: 'WEEKLY', sel: { kind: 'WEEKLY', saturday: l.date, time: weeklyTime } });
  }
  if (mode === 'BIWEEKLY') {
    const d1 = Number(settings.biweekly_day_1 || 1), d2 = Number(settings.biweekly_day_2 || 15);
    if ((day === d1 || day === d2) && atOrAfter(biweeklyTime)) {
      let previous;
      if (day === d2) previous = l.date.slice(0, 8) + String(d1).padStart(2, '0');
      else {
        const prevMonthLast = addDays(l.date.slice(0, 8) + '01', -1);
        previous = prevMonthLast.slice(0, 8) + String(d2).padStart(2, '0');
      }
      out.push({ type: 'BIWEEKLY', sel: { kind: 'BIWEEKLY', cutoff: l.date, previous, time: biweeklyTime } });
    }
  }
  if (mode === 'MONTHLY' && day === daysInMonth(y, m) && atOrAfter(monthlyTime)) {
    out.push({ type: 'MONTHLY', sel: { kind: 'MONTHLY', year: y, month: m } });
  }
  return out;
}

// Clave de idempotencia del email
export const emailKey = (type, start, end, recipient, version = 1, resend = 0) =>
  [type, start, end, String(recipient).toLowerCase(), 'v' + version].join('|') + (resend ? '|reenvio-' + resend : '');

export const fileName = rep => rep.type === 'MONTHLY'
  ? 'Informe_Cristian_Torres_Mensual_' + rep.period.start.slice(0, 7) + '.pdf'
  : 'Informe_Cristian_Torres_' + (rep.type === 'WEEKLY' ? 'Semanal' : rep.type === 'BIWEEKLY' ? 'Quincenal' : 'Manual') + '_' + rep.period.end + '.pdf';
