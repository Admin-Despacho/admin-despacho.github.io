// Email del informe de Cristian Torres. HTML compatible con clientes de correo:
// tablas, estilos en línea, sin JavaScript, sin fuentes externas, ancho máximo ~700 px.
import { ZONE_LABEL, money, dmy, MONTHS } from './report-engine.js';

const C = { ink: '#000E18', cyan: '#00E6FE', teal: '#00788A', bg: '#F2F5F7', line: '#DCE3E8', muted: '#5D6D78', ok: '#0F8A5F', okbg: '#E5F6EF', err: '#B42318', errbg: '#FDECEA' };
const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const FONT = "font-family:Arial,Helvetica,sans-serif;";

export const periodText = rep => rep.period.window ? 'Ventana analizada: ' + rep.period.window : 'Período: ' + dmy(rep.period.start) + ' al ' + dmy(rep.period.end);
export function emailSubject(rep) {
  if (rep.type === 'MONTHLY') { const [y, m] = rep.period.start.split('-'); return 'OK Despacho · Informe mensual Cristian Torres · ' + MONTHS[+m - 1] + ' ' + y; }
  if (rep.type === 'WEEKLY') return 'OK Despacho · Informe semanal Cristian Torres · cierre ' + dmy(rep.period.end) + ' 15:00';
  return 'OK Despacho · Informe Cristian Torres · ' + dmy(rep.period.start) + ' al ' + dmy(rep.period.end);
}
const typeLabel = rep => rep.type === 'MONTHLY' ? 'MENSUAL' : rep.type === 'WEEKLY' ? 'SEMANAL' : 'MANUAL';

const th = t => '<th align="left" style="' + FONT + 'font-size:12px;color:#ffffff;background:' + C.ink + ';padding:8px;border-bottom:2px solid ' + C.cyan + ';">' + t + '</th>';
const td = (t, extra = '') => '<td style="' + FONT + 'font-size:13px;color:' + C.ink + ';padding:7px 8px;border-bottom:1px solid ' + C.line + ';' + extra + '">' + t + '</td>';
const h2 = t => '<tr><td style="' + FONT + 'font-size:13px;font-weight:bold;letter-spacing:1px;color:' + C.ink + ';padding:22px 0 8px;">' + t + '</td></tr>';
const table = (heads, rows) => '<tr><td><table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;background:#ffffff;border:1px solid ' + C.line + ';"><tr>' + heads.map(th).join('') + '</tr>' + rows.join('') + '</table></td></tr>';

// Estructura del modelo aprobado (MODELO_EMAIL_INFORME_CRISTIAN_TORRES): encabezado oscuro + cyan, resumen en 3 tarjetas,
// zonas, ¿se paga solo?, decisiones, clientes a recuperar, mejores clientes y adjunto. HTML de email (tablas y estilos en línea).
export function emailHtml(rep, attachmentName) {
  const cov = rep.coverage, G = '#15845a', R = '#b33d3d', A = '#9b6900', M = '#6c7880', L = '#d8e1e5';
  const title = rep.type === 'MONTHLY' ? 'Informe mensual · Cristian Torres' : rep.type === 'WEEKLY' ? 'Informe semanal · Cristian Torres' : 'Informe · Cristian Torres';
  const h2 = t => '<tr><td style="' + FONT + 'font-size:14px;font-weight:bold;color:#111;padding:22px 0 8px;border-bottom:1px solid #e6ecef;">' + t + '</td></tr>';
  const th = (t, al) => '<th align="' + (al || 'left') + '" style="' + FONT + 'font-size:10px;color:' + M + ';text-transform:uppercase;padding:8px;border-bottom:1px solid ' + L + ';">' + t + '</th>';
  const td = (t, al, b) => '<td align="' + (al || 'left') + '" style="' + FONT + 'font-size:12px;color:#111;padding:10px 8px;border-bottom:1px solid #edf1f3;' + (b ? 'font-weight:bold;' : '') + '">' + t + '</td>';
  const table = (head, rows) => '<tr><td style="padding-top:6px;"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;">' + (head ? '<tr>' + head.join('') + '</tr>' : '') + rows.join('') + '</table></td></tr>';
  const card = (label, val, color, sub) => '<td width="33%" valign="top" style="padding:4px;"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border:1px solid ' + L + ';border-radius:12px;"><tr><td style="' + FONT + 'padding:12px;"><div style="font-size:10px;font-weight:bold;letter-spacing:1px;color:' + M + ';text-transform:uppercase;">' + label + '</div><div style="font-size:23px;font-weight:bold;color:' + color + ';margin-top:4px;">' + val + '</div>' + (sub ? '<div style="font-size:11px;color:' + M + ';">' + sub + '</div>' : '') + '</td></tr></table></td>';
  const badge = st => { const red = st === 'CONTACTAR HOY'; return '<span style="' + FONT + 'font-size:10px;font-weight:bold;padding:5px 8px;border-radius:999px;background:' + (red ? '#fdecec' : '#fff3d6') + ';color:' + (red ? R : '#8b5d00') + ';">' + esc(st) + '</span>'; };
  const zoneRows = rep.zones.map(z => '<tr>' + td('<b>' + ZONE_LABEL[z.zone] + '</b>') + td(String(z.completed), 'center') + td('<b>' + money(z.income) + '</b>', 'right') + '</tr>')
    .concat(['<tr>' + td('<b>TOTAL</b>') + td('<b>' + rep.total.completed + '</b>', 'center') + td('<b>' + money(rep.total.income) + '</b>', 'right') + '</tr>']);
  const cl = (k, v, b, color) => '<tr>' + td(b ? '<b>' + k + '</b>' : k) + '<td align="right" style="' + FONT + 'font-size:12px;padding:10px 8px;border-bottom:1px solid #edf1f3;' + (b ? 'font-weight:bold;' : '') + (color ? 'color:' + color + ';' : '') + '">' + v + '</td></tr>';
  return '<!doctype html><html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>' + esc(emailSubject(rep)) + '</title></head>' +
    '<body style="margin:0;padding:0;background:#eef2f4;"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#eef2f4;"><tr><td align="center" style="padding:24px 8px;">' +
    '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:700px;background:#ffffff;border:1px solid ' + L + ';border-radius:16px;">' +
    '<tr><td style="background:#07151b;padding:22px;border-bottom:4px solid #16d6e5;border-radius:16px 16px 0 0;">' +
    '<div style="' + FONT + 'font-size:11px;font-weight:bold;letter-spacing:2px;color:#16d6e5;">OK ACCESORIOS · INFORME AUTOMÁTICO</div>' +
    '<div style="' + FONT + 'font-size:23px;font-weight:bold;color:#ffffff;margin:6px 0 3px;">' + title + '</div>' +
    '<div style="' + FONT + 'font-size:13px;color:#cbd6da;">' + esc(periodText(rep)) + '</div><div style="display:none;">INFORME CRISTIAN TORRES · ' + typeLabel(rep) + '</div></td></tr>' +
    '<tr><td style="padding:20px;"><table role="presentation" width="100%" cellpadding="0" cellspacing="0">' +
    '<tr><td style="' + FONT + 'font-size:10px;font-weight:bold;letter-spacing:1px;color:' + M + ';text-transform:uppercase;">Resumen del período</td></tr>' +
    '<tr><td><table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr>' + card('Envíos completados', rep.summary.completed, G, 'incluye entregas parciales') + card('No entregados', rep.summary.not_delivered, R) + card('Reprogramados', rep.summary.rescheduled, A) + '</tr></table></td></tr>' +
    '<tr><td style="' + FONT + 'font-size:11px;color:' + M + ';">' + esc(rep.summary.note) + (rep.period.cutoff_note ? ' ' + esc(rep.period.cutoff_note) : '') + '</td></tr>' +
    h2('Envíos e ingresos por zona') + table([th('Zona'), th('Completados', 'center'), th('Ingreso', 'right')], zoneRows) +
    h2('¿El transporte se paga solo?') + table(null, [cl('Ingreso Zona Este', money(cov.income_by_zone.ESTE)), cl('Ingreso Alrededores', money(cov.income_by_zone.ALREDEDORES)), cl('Ingreso Centro', money(cov.income_by_zone.CENTRO)),
      cl('Ingreso total de envíos', money(cov.income), true), cl('Costo Cristian del período', money(cov.cost)), cl('Diferencia', (cov.diff >= 0 ? '+' : '-') + money(Math.abs(cov.diff)), true, cov.covers ? G : R)]) +
    '<tr><td style="padding-top:12px;"><table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr><td style="' + FONT + 'background:' + (cov.covers ? '#e8f7ef' : '#fdecec') + ';border:1px solid ' + (cov.covers ? '#cfead9' : '#f0caca') + ';border-radius:12px;padding:14px;">' +
    '<b style="font-size:17px;color:' + (cov.covers ? G : R) + ';">' + (cov.covers ? '✓ ' : '✕ ') + cov.verdict + '</b><div style="font-size:12px;margin-top:4px;color:#111;">' + (cov.covers ? 'El período deja ' + money(cov.diff) + ' por encima del costo de Cristian.' : 'En el período faltan ' + money(-cov.diff) + ' para cubrir el costo de Cristian.') + ' (' + esc(cov.text) + ')</div></td></tr></table></td></tr>' +
    h2('Decisiones sugeridas') + '<tr><td style="' + FONT + 'background:#f4f8f9;border-radius:12px;padding:13px;font-size:12px;line-height:1.6;color:#111;">' + rep.decisions.map(d => '• ' + esc(d)).join('<br>') + '</td></tr>' +
    h2('Clientes a recuperar · prioridad') + (rep.recover.length ? table([th('Cliente'), th('Zona'), th('Días', 'center'), th('Frecuencia'), th('Acción')], rep.recover.slice(0, 5).map(c => '<tr>' + td(esc(c.client)) + td(ZONE_LABEL[c.zone]) + td(String(c.days_since), 'center') + td('cada ' + Math.round(c.freq) + ' días') + td(badge(c.status)) + '</tr>'))
      : '<tr><td style="' + FONT + 'font-size:12px;color:' + M + ';">Sin clientes fuera de su frecuencia.</td></tr>') +
    h2('Mejores clientes') + (rep.best_clients.length ? table([th('Cliente'), th('Compras', 'center'), th('Frecuencia'), th('Facturación', 'right')], rep.best_clients.slice(0, 5).map(c => '<tr>' + td(esc(c.client)) + td(String(c.purchases), 'center') + td(c.freq ? 'cada ' + Math.round(c.freq) + ' días' : '—') + td(money(c.amount), 'right') + '</tr>'))
      : '<tr><td style="' + FONT + 'font-size:12px;color:' + M + ';">Sin compras en el período.</td></tr>') +
    h2('Zonas a reforzar') + table([th('Zona'), th('Conclusión'), th('Por qué')], rep.reinforce.map(r => '<tr>' + td('<b>' + ZONE_LABEL[r.zone] + '</b>') + td('<b>' + esc(r.decision) + '</b>') + td(esc(r.why)) + '</tr>')) +
    '<tr><td style="padding-top:18px;"><table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr><td style="' + FONT + 'border:1px dashed #aebfc6;border-radius:12px;padding:12px;font-size:12px;">📎 <b>Adjunto:</b> ' + esc(attachmentName) + '<br><span style="color:' + M + ';">El PDF contiene el detalle completo del período. Solo hojas finalizadas; ingreso exclusivamente por servicio de envío.</span></td></tr></table></td></tr>' +
    '</table></td></tr><tr><td align="center" style="' + FONT + 'color:#7b888e;font-size:11px;padding:18px;">OK Despacho · Informe generado automáticamente</td></tr></table></td></tr></table></body></html>';
}

export function emailText(rep, attachmentName) {
  const c = rep.coverage;
  return [
    'OK ACCESORIOS · INFORME CRISTIAN TORRES · ' + typeLabel(rep), periodText(rep), '',
    'ENVÍOS COMPLETADOS: ' + rep.summary.completed, 'NO ENTREGADOS: ' + rep.summary.not_delivered, 'REPROGRAMADOS: ' + rep.summary.rescheduled, rep.summary.note, '',
    ...rep.zones.map(z => ZONE_LABEL[z.zone] + ': ' + z.completed + ' · ' + money(z.income)), 'TOTAL: ' + rep.total.completed + ' · ' + money(rep.total.income), '',
    'Costo Cristian del período: ' + money(c.cost), 'Resultado: ' + (c.diff >= 0 ? '+' : '-') + money(Math.abs(c.diff)), c.verdict + ' · ' + c.text, '',
    'DECISIONES', ...rep.decisions.map(d => '• ' + d), '', 'Adjunto: ' + attachmentName
  ].join('\n');
}
