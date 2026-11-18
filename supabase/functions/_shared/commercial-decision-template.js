// AUTORIZACIONES COMERCIALES · correo de resolución (HTML + texto plano). Se genera SOLO en el servidor, a partir de la FOTO
// inmutable del evento (com_decision_mail_payloads): nunca de datos enviados por el navegador ni de la solicitud vigente.
// Reglas: mostrar solo lo REGISTRADO (nada se inventa ni se recalcula), escapar TODO dato dinámico, sin tokens en el enlace,
// sin KPI, sin documento de identidad, sin saldo y sin la lista de los demás destinatarios.
// Diseño: modelo aprobado por Administración (OK_DESPACHO_MODELO_CORREO_AUTORIZACION.html): tablas + estilos en línea.

export const APP_URL = 'https://admin-despacho.github.io/';
const TZ = 'America/Argentina/Buenos_Aires';
const NAVY = '#102631', CYAN = '#56dce9', MUTED = '#536672', LINE = '#d9e3e8', SOFT = '#eef3f5';

// Estados REALES del sistema (eventos de com_request_events que generan correo) → presentación.
export const STATES = {
  APROBADA: { label: 'APROBADA', banner: 'SOLICITUD APROBADA', fg: '#067647', bg: '#e3f6ea', box: '#0b4a2b',
    intro: 'Se informa que la siguiente solicitud comercial fue evaluada y aprobada.' },
  APROBADA_CON_MODIFICACIONES: { label: 'APROBADA CON CAMBIOS', banner: 'SOLICITUD APROBADA CON CAMBIOS', fg: '#175cd3', bg: '#e6efff', box: '#14306b',
    intro: 'Se informa que la siguiente solicitud comercial fue aprobada con condiciones distintas de las solicitadas.' },
  RECHAZADA: { label: 'RECHAZADA', banner: 'SOLICITUD RECHAZADA', fg: '#b42318', bg: '#fce8e8', box: '#702420',
    intro: 'Se informa que la siguiente solicitud comercial fue evaluada y rechazada.' },
  DEVUELTA_CON_MODIFICACIONES: { label: 'DEVUELTA', banner: 'SOLICITUD DEVUELTA CON CAMBIOS', fg: '#b54708', bg: '#fff1e0', box: '#7a2e0e',
    intro: 'Se informa que la siguiente solicitud comercial fue devuelta al comercial con condiciones propuestas.' },
  RETIRADA_POR_COMERCIAL: { label: 'CANCELADA', banner: 'SOLICITUD CANCELADA', fg: '#475467', bg: '#eceff2', box: '#344054',
    intro: 'Se informa que la siguiente solicitud comercial fue cancelada: el comercial la retiró sin aceptar las condiciones propuestas.' },
  CANCELADA: { label: 'CANCELADA', banner: 'SOLICITUD CANCELADA', fg: '#475467', bg: '#eceff2', box: '#344054',
    intro: 'Se informa que la siguiente solicitud comercial fue cancelada.' },
  CAMBIOS_ACEPTADOS_REENVIADA: { label: 'REENVIADA', banner: 'CAMBIOS ACEPTADOS · REENVIADA A EVALUACIÓN', fg: '#0e7490', bg: '#e0f5f8', box: '#164e63',
    intro: 'Se informa que el comercial aceptó las condiciones propuestas y la solicitud volvió a evaluación. Todavía no está aprobada.' },
};
const KIND = { FINANCIACION: 'Financiación propia', ECHEQ: 'Aceptación de e-cheq' };
const FREQ = { SEMANAL: 'Semanal', QUINCENAL: 'Quincenal', MENSUAL: 'Mensual' };
const BRANCH = { MONTECASEROS: 'Montecaseros', SAN_JUAN: 'San Juan' };

export const esc = v => String(v ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const oneLine = v => String(v ?? '').replace(/[\u0000-\u001f\u007f\u2028\u2029]+/g, ' ').replace(/\s+/g, ' ').trim();
const multi = v => esc(String(v ?? '').replace(/\r\n?/g, '\n').trim()).replace(/\n/g, '<br>');
const has = v => v !== null && v !== undefined && String(v).trim() !== '';
const NR = 'No registrado';

export function money(v) {
  if (!has(v) || !isFinite(Number(v))) return NR;
  const n = Number(v), neg = n < 0, [i, d] = Math.abs(n).toFixed(2).split('.');
  return (neg ? '-' : '') + '$ ' + i.replace(/\B(?=(\d{3})+(?!\d))/g, '.') + ',' + d;
}
export function day(v) {   // fecha REGISTRADA (YYYY-MM-DD): se muestra tal cual, sin zona horaria
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(v ?? ''));
  return m ? m[3] + '/' + m[2] + '/' + m[1] : NR;
}
export function stamp(v) {  // instante → hora ARGENTINA «18/11/2026 – 10:30»
  const t = new Date(v); if (!has(v) || isNaN(t)) return NR;
  const p = Object.fromEntries(new Intl.DateTimeFormat('es-AR', { timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' })
    .formatToParts(t).map(x => [x.type, x.value]));
  return p.day + '/' + p.month + '/' + p.year + ' – ' + p.hour + ':' + p.minute;
}
const person = v => has(v) ? oneLine(v) : NR;
const sched = t => Array.isArray(t?.schedule) ? t.schedule : [];
const same = (a, b) => JSON.stringify(a ?? null) === JSON.stringify(b ?? null);

// Campos de condiciones según el TIPO. Solo lo registrado; «Pago único» cuando hay UNA cuota (deriva sin ambigüedad del dato).
function termRows(kind, t) {
  t = t || {};
  if (kind === 'ECHEQ') return [
    ['Importe del e-cheq', money(t.amount)],
    ['Vencimiento del e-cheq', day(t.due_date)],
    has(t.days) ? ['Plazo', t.days + ' días'] : null,
    ['Emisor', t.issuer_is_client === true ? 'El mismo cliente' + (has(t.issuer_name) ? ' (' + oneLine(t.issuer_name) + ')' : '') : has(t.issuer_name) ? oneLine(t.issuer_name) : NR],
    t.issuer_is_client === true ? null : ['CUIT del emisor', has(t.issuer_cuit) ? oneLine(t.issuer_cuit) : NR],
  ].filter(Boolean);
  const s = sched(t), k = has(t.installments) ? Number(t.installments) : (s.length || null);
  return [
    ['Importe solicitado', money(t.amount)],
    ['Cantidad de cuotas', has(k) ? String(k) : NR],
    ['Frecuencia', has(t.frequency) ? (FREQ[t.frequency] || oneLine(t.frequency)) : k === 1 ? 'Pago único' : NR],
    ['Primer vencimiento', has(t.first_due) ? day(t.first_due) : s.length ? day(s[0].due) : NR],
    has(t.last_due) ? ['Último vencimiento', day(t.last_due)] : null,
    has(t.limit_date) ? ['Fecha límite', day(t.limit_date)] : null,
  ].filter(Boolean);
}

// ---------- piezas HTML (tablas de presentación, estilos en línea) ----------
const H2 = (txt, extra = '') => '<h2 style="margin:22px 0 8px;font-size:17px;line-height:1.3;color:' + NAVY + ';border-bottom:1px solid ' + LINE + ';padding-bottom:10px' + extra + '">' + esc(txt) + '</h2>';
const kv = rows => '<table role="presentation" width="100%" cellspacing="0" cellpadding="6" style="font-size:13px;line-height:1.45;border-collapse:collapse">' +
  rows.map(([k, v, color]) => '<tr><td width="44%" valign="top" style="color:' + MUTED + ';border-bottom:1px solid #f0f4f6">' + esc(k) + '</td><td align="right" valign="top" style="font-weight:bold;overflow-wrap:anywhere;word-break:break-word;border-bottom:1px solid #f0f4f6' + (color ? ';color:' + color : '') + '">' + esc(v) + '</td></tr>').join('') + '</table>';
function calendarHtml(title, t) {
  const s = sched(t); if (!s.length) return '';
  return H2(title, ';font-size:16px') + '<table role="presentation" width="100%" cellspacing="0" cellpadding="8" style="font-size:13px;border-collapse:collapse">' +
    '<tr style="background:' + SOFT + '" bgcolor="' + SOFT + '"><th align="left">Cuota</th><th align="left">Vencimiento</th><th align="right">Importe</th></tr>' +
    s.map((c, i) => '<tr><td style="border-bottom:1px solid #e4ebef">' + esc(has(c.n) ? c.n : i + 1) + '</td><td style="border-bottom:1px solid #e4ebef">' + esc(day(c.due)) + '</td><td align="right" style="border-bottom:1px solid #e4ebef">' + esc(has(c.amount) ? money(c.amount) : NR) + '</td></tr>').join('') +
    '<tr><td colspan="2"><b>Total</b></td><td align="right"><b>' + esc(money(t.amount)) + '</b></td></tr></table>';
}
const box = (title, body, st) => '<div style="background:' + st.bg + ';padding:16px;border-radius:8px;margin-top:16px;color:' + st.box + ';font-size:14px;line-height:1.6;overflow-wrap:anywhere;word-break:break-word"><b style="color:' + st.fg + '">' + esc(title) + '</b><br>' + body + '</div>';
const softBox = (title, body) => '<div style="background:' + SOFT + ';padding:16px;border-radius:8px;margin-top:18px;font-size:14px;line-height:1.55;overflow-wrap:anywhere;word-break:break-word"><b>' + esc(title) + '</b><br>' + body + '</div>';
function compareHtml(kind, cmp, st) {
  const a = termRows(kind, cmp.left), b = termRows(kind, cmp.right), keys = [...new Set([...a, ...b].map(r => r[0]))];
  const get = (rows, k) => (rows.find(r => r[0] === k) || [k, '—'])[1];
  return H2(cmp.title) + '<table role="presentation" width="100%" cellspacing="0" cellpadding="7" style="font-size:13px;border-collapse:collapse;line-height:1.4">' +
    '<tr style="background:' + SOFT + '" bgcolor="' + SOFT + '"><th align="left" width="34%"></th><th align="right" width="33%">' + esc(cmp.leftLabel) + '</th><th align="right" width="33%" style="color:' + st.fg + '">' + esc(cmp.rightLabel) + '</th></tr>' +
    keys.map(k => { const l = get(a, k), r = get(b, k), d = l !== r; return '<tr><td style="color:' + MUTED + ';border-bottom:1px solid #e4ebef">' + esc(k) + '</td><td align="right" style="border-bottom:1px solid #e4ebef">' + esc(l) + '</td><td align="right" style="border-bottom:1px solid #e4ebef;font-weight:bold' + (d ? ';color:' + st.fg + ';background:' + st.bg : '') + '"' + (d ? ' bgcolor="' + st.bg + '"' : '') + '>' + esc(r) + (d ? ' ●' : '') + '</td></tr>'; }).join('') +
    '</table><p style="font-size:11px;color:' + MUTED + ';margin:6px 0 0">● = dato distinto de las condiciones de la izquierda. Los datos originales se conservan sin cambios.</p>' +
    (kind === 'FINANCIACION' ? (cmp.leftIsOriginal ? '' : calendarHtml(cmp.leftLabel + ' · calendario', cmp.left)) + calendarHtml(cmp.rightLabel + ' · calendario', cmp.right) : '') +
    (cmp.note ? '<p style="font-size:13px;line-height:1.55;color:' + st.box + ';background:' + st.bg + ';padding:12px;border-radius:8px">' + esc(cmp.note) + '</p>' : '');
}

// ---------- modelo de contenido común (HTML y texto usan EXACTAMENTE los mismos datos) ----------
export function buildModel(payload) {
  if (!payload || payload.version !== 1 || !payload.event || !payload.request) throw Object.assign(new Error('PAYLOAD_INVALID'), { code: 'PAYLOAD_INVALID' });
  const e = payload.event, q = payload.request, st = STATES[e.kind];
  if (!st) throw Object.assign(new Error('EVENT_KIND_UNSUPPORTED'), { code: 'EVENT_KIND_UNSUPPORTED' });
  const kind = q.kind, orig = q.original_terms || {}, prev = payload.previous_proposal || null;
  const client = has(q.client_name) ? oneLine(q.client_name) : NR;
  const place = q.channel === 'CARTERA' ? ['Cartera', has(q.cartera_label) ? oneLine(q.cartera_label) : 'Vendedores de cartera'] : ['Sucursal', has(q.branch) ? (BRANCH[q.branch] || oneLine(String(q.branch).replace(/_/g, ' '))) : NR];
  const data = [
    ['Número de autorización', oneLine(q.number)], ['Tipo de solicitud', KIND[kind] || oneLine(kind)], ['Fecha y hora de creación', stamp(q.created_at)],
    ['Cliente', client], ['CUIT', has(q.client_cuit) ? oneLine(q.client_cuit) : NR], ['Número de pedido', has(q.order_ref) ? oneLine(q.order_ref) : NR], place,
    ['Comercial solicitante', person(q.requester)], ['Responsable de aprobación', person(q.approver)],
    ...termRows(kind, orig),
  ];
  // Condiciones del evento: nunca reemplazan a las originales; se muestran al lado.
  let cmp = null;
  const before = e.terms_before || null, after = e.terms_after || null;
  if (e.kind === 'APROBADA_CON_MODIFICACIONES') cmp = { title: 'Condiciones solicitadas y condiciones autorizadas', leftLabel: 'Solicitadas', left: before || orig, rightLabel: 'Autorizadas', right: after };
  else if (e.kind === 'DEVUELTA_CON_MODIFICACIONES') cmp = { title: 'Condiciones solicitadas y condiciones propuestas', leftLabel: 'Solicitadas', left: before || orig, rightLabel: 'Propuestas', right: after,
    note: 'Las condiciones propuestas NO constituyen una aprobación definitiva. El comercial debe aceptarlas (la solicitud vuelve a evaluación) o retirar la solicitud.' };
  else if (e.kind === 'CAMBIOS_ACEPTADOS_REENVIADA' && after && !same(after, orig)) cmp = { title: 'Condiciones originales y condiciones aceptadas', leftLabel: 'Originales', left: orig, rightLabel: 'Aceptadas', right: after,
    note: 'Las condiciones aceptadas vuelven a evaluación del responsable de aprobación. Todavía no están autorizadas.' };
  else if (e.kind === 'RETIRADA_POR_COMERCIAL' && prev && prev.terms) cmp = { title: 'Condiciones originales y condiciones propuestas no aceptadas', leftLabel: 'Originales', left: orig, rightLabel: 'Propuestas', right: prev.terms,
    note: 'El comercial no aceptó las condiciones propuestas. Ninguna de las dos condiciones quedó autorizada.' };
  else if (e.kind === 'APROBADA' && after && !same(after, orig)) cmp = { title: 'Condiciones originales y condiciones autorizadas', leftLabel: 'Originales', left: orig, rightLabel: 'Autorizadas', right: after,
    note: 'Se autorizaron las condiciones propuestas por el responsable de aprobación y aceptadas por el comercial.' };
  else if (e.kind === 'RECHAZADA' && before && !same(before, orig)) cmp = { title: 'Condiciones originales y condiciones evaluadas', leftLabel: 'Originales', left: orig, rightLabel: 'Evaluadas', right: before };
  if (cmp) cmp.leftIsOriginal = same(cmp.left, orig) && kind === 'FINANCIACION' && sched(orig).length > 0;   // el calendario original ya figura arriba: no se repite
  const reasonTitle = { RECHAZADA: 'MOTIVO DEL RECHAZO', DEVUELTA_CON_MODIFICACIONES: 'MOTIVO DE LA DEVOLUCIÓN', RETIRADA_POR_COMERCIAL: 'MOTIVO DE LA CANCELACIÓN (comentario del comercial)',
    CANCELADA: 'MOTIVO DE LA CANCELACIÓN', CAMBIOS_ACEPTADOS_REENVIADA: 'COMENTARIO DEL COMERCIAL', APROBADA: 'OBSERVACIONES DEL AUTORIZANTE', APROBADA_CON_MODIFICACIONES: 'OBSERVACIONES Y CONDICIONES DEL AUTORIZANTE' }[e.kind];
  const byRequester = ['RETIRADA_POR_COMERCIAL', 'CAMBIOS_ACEPTADOS_REENVIADA'].includes(e.kind);
  const resolution = [
    ['Estado', st.label, st.fg],
    [byRequester ? (e.kind === 'RETIRADA_POR_COMERCIAL' ? 'Cancelada por' : 'Aceptada por') : 'Resuelto por', person(e.actor)],
    e.substitute ? ['Modalidad', 'En suplencia del responsable asignado'] : null,
    ['Fecha y hora', stamp(e.at)],
  ].filter(Boolean);
  const closing = { RECHAZADA: 'La operación solicitada NO está autorizada.', DEVUELTA_CON_MODIFICACIONES: 'La solicitud todavía no está aprobada.',
    RETIRADA_POR_COMERCIAL: 'La operación solicitada no está autorizada.', CANCELADA: 'La operación solicitada no está autorizada.',
    CAMBIOS_ACEPTADOS_REENVIADA: 'La solicitud todavía no está aprobada.', APROBADA: 'La operación quedó autorizada en las condiciones indicadas.',
    APROBADA_CON_MODIFICACIONES: 'La operación quedó autorizada SOLO en las condiciones autorizadas.' }[e.kind];
  const rid = /^[0-9a-f-]{36}$/i.test(String(q.id || '')) ? String(q.id) : '';
  const url = APP_URL + '#/autorizaciones?v=historial' + (rid ? '&solicitud=' + encodeURIComponent(rid) : '');
  const subject = oneLine('Solicitud comercial ' + st.label + ' | ' + oneLine(q.number) + ' | ' + client).slice(0, 200);
  return { st, e, q, kind, orig, data, cmp, reasonTitle, reason: has(e.reason) ? String(e.reason) : null, resolution, closing, url, subject,
    showOrigCalendar: kind === 'FINANCIACION' && sched(orig).length > 0, notes: has(q.notes) ? String(q.notes) : null };
}

export function renderDecisionMail(payload, { sampleBanner = '' } = {}) {
  const m = buildModel(payload), st = m.st;
  const pre = st.label + ' · ' + oneLine(m.q.number) + ' · ' + (KIND[m.kind] || '');
  const html = '<!doctype html><html lang="es-AR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="x-apple-disable-message-reformatting"><title>' + esc(m.subject) + '</title></head>' +
    '<body style="margin:0;padding:0;background:' + SOFT + ';font-family:Arial,Helvetica,sans-serif;color:' + NAVY + '">' +
    '<div style="display:none;max-height:0;overflow:hidden;mso-hide:all">' + esc(pre) + '</div>' +
    '<table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background:' + SOFT + '" bgcolor="' + SOFT + '"><tr><td align="center" style="padding:20px 8px">' +
    '<!--[if mso]><table role="presentation" width="640" align="center" cellspacing="0" cellpadding="0"><tr><td><![endif]-->' +
    '<table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="max-width:640px;background:#ffffff;border:1px solid ' + LINE + ';border-radius:12px;overflow:hidden" bgcolor="#ffffff">' +
    (sampleBanner ? '<tr><td style="padding:16px 24px;font-size:12px;color:' + MUTED + ';border-bottom:1px solid #e4ebef">' + esc(sampleBanner) + '<br>Asunto: ' + esc(m.subject) + '</td></tr>' : '') +
    '<tr><td style="background:' + NAVY + ';padding:26px;color:#ffffff" bgcolor="' + NAVY + '"><div style="font-size:28px;font-weight:bold;letter-spacing:1px">OK DESPACHO</div><div style="color:' + CYAN + ';font-size:13px;margin-top:7px;font-weight:bold">AUTORIZACIONES COMERCIALES</div></td></tr>' +
    '<tr><td style="padding:24px">' +
    '<div style="background:' + st.bg + ';border-radius:8px;padding:16px;color:' + st.fg + '"><b style="font-size:21px">' + esc(st.banner) + '</b><div style="margin-top:6px;font-size:13px">' + esc(oneLine(m.q.number) + ' · ' + (KIND[m.kind] || oneLine(m.kind))) + '</div></div>' +
    '<p style="font-size:14px;line-height:1.6">' + esc(st.intro) + '</p>' +
    H2('Datos de la solicitud original') + kv(m.data) +
    (m.showOrigCalendar ? calendarHtml('Calendario de pagos solicitado', m.orig) : '') +
    softBox('Observaciones del comercial', m.notes ? multi(m.notes) : 'Sin observaciones registradas.') +
    (m.cmp ? compareHtml(m.kind, m.cmp, st) : '') +
    '<h2 style="font-size:19px;margin-top:26px;border-bottom:1px solid ' + LINE + ';padding-bottom:10px">Resolución administrativa</h2>' + kv(m.resolution) +
    box(m.reasonTitle, m.reason ? multi(m.reason) : 'No se registraron observaciones.', st) +
    '<p style="font-size:14px;line-height:1.6;font-weight:bold">' + esc(m.closing) + '</p>' +
    '<table role="presentation" width="100%" cellspacing="0" cellpadding="0"><tr><td align="center" bgcolor="' + NAVY + '" style="border-radius:8px;padding:16px;background:' + NAVY + '"><a href="' + esc(m.url) + '" style="color:#ffffff;font-size:13px;font-weight:bold;text-decoration:none;display:inline-block">CONSULTAR SOLICITUD EN OK DESPACHO</a></td></tr></table>' +
    '<p style="font-size:11px;color:#60717c;line-height:1.5">Notificación automática del sistema de Autorizaciones Comerciales. El acceso a la aplicación requiere usuario y permisos vigentes. Este correo no otorga acceso ni permisos.</p>' +
    '</td></tr><tr><td align="center" style="background:' + SOFT + ';padding:18px;font-size:13px" bgcolor="' + SOFT + '"><b>OK ACCESORIOS</b><div style="font-size:11px;color:' + MUTED + ';margin-top:5px">Administración · Autorizaciones Comerciales</div></td></tr>' +
    '</table><!--[if mso]></td></tr></table><![endif]--></td></tr></table></body></html>';
  return { subject: m.subject, html, text: renderText(m) };
}

function renderText(m) {
  const L = [], line = (k, v) => L.push(k + ': ' + v), cal = (title, t) => { const s = sched(t); if (!s.length) return; L.push('', title.toUpperCase()); s.forEach((c, i) => L.push('  Cuota ' + (has(c.n) ? c.n : i + 1) + ' · ' + day(c.due) + ' · ' + (has(c.amount) ? money(c.amount) : NR))); L.push('  Total: ' + money(t.amount)); };
  L.push('OK DESPACHO · AUTORIZACIONES COMERCIALES', '', m.st.banner, oneLine(m.q.number) + ' · ' + (KIND[m.kind] || oneLine(m.kind)), '', m.st.intro, '', 'DATOS DE LA SOLICITUD ORIGINAL');
  m.data.forEach(([k, v]) => line(k, v));
  if (m.showOrigCalendar) cal('Calendario de pagos solicitado', m.orig);
  L.push('', 'OBSERVACIONES DEL COMERCIAL', m.notes ? m.notes.replace(/\r\n?/g, '\n').trim() : 'Sin observaciones registradas.');
  if (m.cmp) {
    const a = termRows(m.kind, m.cmp.left), b = termRows(m.kind, m.cmp.right);
    L.push('', m.cmp.title.toUpperCase(), m.cmp.leftLabel.toUpperCase() + ':'); a.forEach(([k, v]) => L.push('  ' + k + ': ' + v));
    L.push(m.cmp.rightLabel.toUpperCase() + ':'); b.forEach(([k, v]) => { const o = a.find(r => r[0] === k); L.push('  ' + k + ': ' + v + (o && o[1] !== v ? '  (cambió)' : '')); });
    if (m.kind === 'FINANCIACION') { if (!m.cmp.leftIsOriginal) cal(m.cmp.leftLabel + ' · calendario', m.cmp.left); cal(m.cmp.rightLabel + ' · calendario', m.cmp.right); }
    if (m.cmp.note) L.push('', m.cmp.note);
  }
  L.push('', 'RESOLUCIÓN ADMINISTRATIVA'); m.resolution.forEach(([k, v]) => line(k, v));
  L.push('', m.reasonTitle, m.reason ? m.reason.replace(/\r\n?/g, '\n').trim() : 'No se registraron observaciones.', '', m.closing, '',
    'CONSULTAR SOLICITUD EN OK DESPACHO: ' + m.url, 'El acceso a la aplicación requiere usuario y permisos vigentes. Este correo no otorga acceso ni permisos.', '',
    'OK ACCESORIOS', 'Administración · Autorizaciones Comerciales');
  return L.join('\n') + '\n';
}
