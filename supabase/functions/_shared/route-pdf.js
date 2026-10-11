// PDF final de una hoja (Fase 2B.3): ruta original vs ejecutada, cambios, resultados, bultos, vehículo/km, incidencias, estado e historial.
// Sin mapas, sin firmas, sin DNI/CUIL ni coordenadas.
import { PDFDocument, StandardFonts, rgb } from 'pdf-lib';
import { routeDiff } from './internal-route.js';
const INK = rgb(0, 14 / 255, 24 / 255), CYAN = rgb(0, 230 / 255, 254 / 255), MUTED = rgb(93 / 255, 109 / 255, 120 / 255);
const OUT = { ENTREGADO: 'ENTREGADO', ENTREGA_PARCIAL: 'ENTREGA PARCIAL', NO_ENTREGADO: 'NO ENTREGADO', REPROGRAMAR: 'REPROGRAMAR', PENDIENTE: 'PENDIENTE' };
const APR = { NO_REQUERIDA: '', PENDIENTE: ' · PENDIENTE DE APROBACIÓN', APROBADA: ' · APROBADA', OBSERVADA: ' · OBSERVADA' };
const dt = iso => iso ? new Date(iso).toLocaleString('es-AR', { timeZone: 'America/Argentina/Mendoza' }) : '—';
export async function routePdf({ route, driverName, carrierName, vehicle, history = [] }) {
  const doc = await PDFDocument.create(); const font = await doc.embedFont(StandardFonts.Helvetica), bold = await doc.embedFont(StandardFonts.HelveticaBold);
  doc.setTitle('Hoja ' + route.number);
  const W = 595.28, H = 841.89, M = 40; let page, y;
  const np = () => { page = doc.addPage([W, H]); page.drawRectangle({ x: 0, y: H - 58, width: W, height: 58, color: INK }); page.drawRectangle({ x: 0, y: H - 61, width: W, height: 3, color: CYAN });
    page.drawText('OK ACCESORIOS · HOJA ' + route.number, { x: M, y: H - 34, size: 14, font: bold, color: rgb(1, 1, 1) }); page.drawText((carrierName || route.carrier_id) + ' · ' + (driverName || ''), { x: M, y: H - 50, size: 9, font, color: CYAN }); y = H - 84; };
  const need = h => { if (y - h < 50) np(); };
  const wrap = (t, w, size, f = font) => { const out = []; let cur = ''; for (const wd of String(t).split(' ')) { const n = cur ? cur + ' ' + wd : wd; if (f.widthOfTextAtSize(n, size) > w && cur) { out.push(cur); cur = wd; } else cur = n; } if (cur) out.push(cur); return out; };
  const text = (t, o = {}) => wrap(t, W - 2 * M - (o.x || 0), o.size || 9.5, o.bold ? bold : font).forEach(l => { need(14); page.drawText(l, { x: M + (o.x || 0), y, size: o.size || 9.5, font: o.bold ? bold : font, color: o.color || INK }); y -= o.gap || 13; });
  const sec = t => { need(28); y -= 6; page.drawText(t, { x: M, y, size: 11, font: bold, color: INK }); y -= 4; page.drawRectangle({ x: M, y: y - 2, width: W - 2 * M, height: 0.8, color: CYAN }); y -= 14; };
  np();
  const d = routeDiff(route);
  text('Estado: ' + (route.operational_status === 'COMPLETADA' ? 'COMPLETADA' : route.operational_status) + (APR[route.approval_status] || '') + ' · Publicada ' + dt(route.published_at) + ' · Iniciada ' + dt(route.started_at) + ' · Finalizada ' + dt(route.completed_at), { bold: true });
  if (vehicle) text('Vehículo: ' + vehicle.name + ' (' + vehicle.plate + ') · Km inicial ' + (route.km_start ?? '—') + ' · Km final ' + (route.km_end ?? '—') + (route.km_start != null && route.km_end != null ? ' · Recorrido ' + (route.km_end - route.km_start) + ' km' : ''));
  sec('RUTA PUBLICADA ORIGINAL');
  d.original.forEach(o => text(o.seq + '. ' + o.client_name + (o.bultos ? ' · ' + o.bultos + ' bultos' : '')));
  sec('RUTA REAL EJECUTADA');
  d.executed.forEach(x => { const st = (route.stops || []).find(s => s.seq === x.seq) || {};
    text(x.pos + '. ' + x.client_name + (x.action !== 'ENTREGA' ? ' · ' + x.action : '') + (x.bultos ? ' · ' + x.bultos + ' bultos' : '') + ' — ' + (OUT[x.outcome] || x.outcome) + (st.receiver_name ? ' · Recibió: ' + st.receiver_name : ''), { bold: x.provenance === 'DRIVER' });
    if (x.marks.length) text(x.marks.join(' · '), { x: 14, size: 8.5, color: MUTED });
    if (st.collection_status && st.collection_status !== 'PENDIENTE') text('Cobranza: ' + st.collection_status.replace('_', ' ') + (st.collected_amount != null ? ' · $ ' + Number(st.collected_amount).toLocaleString('es-AR') : '') + (st.payment_mode ? ' · ' + st.payment_mode : ''), { x: 14, size: 8.5, color: MUTED });
  });
  sec('RESUMEN');
  text('Paradas originales: ' + d.original.length + ' · Ejecutadas: ' + d.executed.length + ' · Agregadas: ' + d.added + ' · Movidas: ' + d.moved + ' · Incidencias: ' + d.incidents + ' · Bultos: ' + d.bultos);
  sec('HISTORIAL');
  (history.length ? history : [{ at: route.published_at, text: 'Hoja publicada' }]).forEach(h => text(dt(h.at) + ' · ' + h.text, { size: 8.8 }));
  const pages = doc.getPages(); pages.forEach((p, i) => p.drawText('OK Despacho · Hoja ' + route.number + ' · Página ' + (i + 1) + ' de ' + pages.length, { x: M, y: 24, size: 7.5, font, color: MUTED }));
  return await doc.save();
}
export function routeHistory(route) {
  const h = [{ at: route.published_at, text: 'Hoja publicada' }];
  if (route.started_at) h.push({ at: route.started_at, text: 'Recorrido iniciado' });
  (route.events || []).forEach(e => h.push({ at: e.at, text: e.type === 'INTERNAL_STOP_ADDED' ? 'Parada agregada por el chofer' + (e.offline ? ' (sin conexión)' : '') : 'Paradas reordenadas por el chofer' + (e.offline ? ' (sin conexión)' : '') }));
  if (route.completed_at) h.push({ at: route.completed_at, text: 'Hoja finalizada' + (route.km_end != null ? ' · km ' + route.km_end : '') });
  if (route.approval_status === 'APROBADA') h.push({ at: route.reviewed_at || route.completed_at, text: 'Cambios aprobados' });
  if (route.approval_status === 'OBSERVADA') h.push({ at: route.reviewed_at || route.completed_at, text: 'Aclaración solicitada: ' + (route.review_note || '') });
  return h.sort((a, b) => String(a.at).localeCompare(String(b.at)));
}
