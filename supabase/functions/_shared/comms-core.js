// =====================================================================================================================
// COMUNICACIONES INTERNAS · lógica pura compartida (navegador, demo y Edge Functions). Sin dependencias.
//  · Programación en America/Argentina/Buenos_Aires (únicos, diarios, semanales, mensuales con regla para días inexistentes).
//  · Destinatarios: individuales / sucursal / sector / todos los activos, sin duplicados, con motivos de exclusión.
//  · Sanitización del texto con formato (lista blanca), texto plano y texto para WhatsApp.
//  · Correo MIME individual (un solo "Para"), adjuntos en base64, tamaño estimado final.
//  · Clasificación de errores de Gmail y espera creciente de reintentos.
// =====================================================================================================================
export const COMMS_TZ = 'America/Argentina/Buenos_Aires';
export const COMMS_PERMS = ['comms.view', 'comms.collaborators_manage', 'comms.compose', 'comms.schedule', 'comms.test_send', 'comms.gmail_manage'];

// ---------- Fechas en hora argentina ----------
const DTF = new Intl.DateTimeFormat('en-CA', { timeZone: COMMS_TZ, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23' });
export function localParts(ts) {
  const o = {}; for (const p of DTF.formatToParts(new Date(ts))) o[p.type] = p.value;
  return { y: +o.year, m: +o.month, d: +o.day, hh: +o.hour, mm: +o.minute, ss: +o.second, date: o.year + '-' + o.month + '-' + o.day, time: o.hour + ':' + o.minute };
}
// fecha y hora LOCALES (Buenos Aires) → instante UTC (ms). Resuelve el desfase real de la zona (hoy UTC-3, sin horario de verano).
export function zonedToUtc(date, time) {
  const [y, m, d] = date.split('-').map(Number), [hh, mm] = String(time || '00:00').split(':').map(Number);
  let guess = Date.UTC(y, m - 1, d, hh, mm);
  for (let i = 0; i < 3; i++) { const p = localParts(guess); const diff = Date.UTC(p.y, p.m - 1, p.d, p.hh, p.mm) - Date.UTC(y, m - 1, d, hh, mm); if (!diff) break; guess -= diff; }
  return guess;
}
export const isoWeekday = date => { const [y, m, d] = date.split('-').map(Number); const w = new Date(Date.UTC(y, m - 1, d)).getUTCDay(); return w === 0 ? 7 : w; };   // 1 = lunes … 7 = domingo
const addDays = (date, n) => { const [y, m, d] = date.split('-').map(Number); const t = new Date(Date.UTC(y, m - 1, d + n)); return t.toISOString().slice(0, 10); };
const daysInMonth = (y, m) => new Date(Date.UTC(y, m, 0)).getUTCDate();
const pad = n => String(n).padStart(2, '0');
export const WEEKDAYS = { 1: 'lunes', 2: 'martes', 3: 'miércoles', 4: 'jueves', 5: 'viernes', 6: 'sábado', 7: 'domingo' };

// Valida y normaliza una programación. kind: ONCE | DAILY | WEEKLY | MONTHLY
export function validateSchedule(s) {
  const e = [];
  if (!s || !['ONCE', 'DAILY', 'WEEKLY', 'MONTHLY'].includes(s.kind)) e.push('Elegí el tipo de envío.');
  if (!/^\d{2}:\d{2}$/.test(String(s && s.time || '')) || +s.time.slice(0, 2) > 23 || +s.time.slice(3) > 59) e.push('Indicá un horario válido (HH:MM).');
  if (!/^\d{4}-\d{2}-\d{2}$/.test(String(s && s.start_date || ''))) e.push('Indicá la fecha de inicio.');
  if (s && s.end_date && !/^\d{4}-\d{2}-\d{2}$/.test(s.end_date)) e.push('La fecha de finalización no es válida.');
  if (s && s.end_date && s.start_date && s.end_date < s.start_date) e.push('La fecha de finalización es anterior al inicio.');
  if (s && s.kind === 'WEEKLY' && !(Array.isArray(s.weekdays) && s.weekdays.length && s.weekdays.every(d => d >= 1 && d <= 7))) e.push('Elegí al menos un día de la semana.');
  if (s && s.kind === 'MONTHLY') {
    if (!(s.month_day >= 1 && s.month_day <= 31)) e.push('Elegí el día del mes (1 a 31).');
    if (s.month_day > 28 && !['LAST_DAY', 'SKIP'].includes(s.month_missing)) e.push('Indicá qué hacer los meses que no tienen el día ' + s.month_day + ': "último día del mes" u "omitir ese mes".');
  }
  return e;
}
// Ejecuciones (instantes UTC) en (fromTs, toTs], en orden. Nunca más de 'max'.
export function occurrencesBetween(s, fromTs, toTs, max = 1000) {
  if (validateSchedule(s).length) return [];
  const out = [], push = date => { if (s.end_date && date > s.end_date) return false; const t = zonedToUtc(date, s.time); if (t > fromTs && t <= toTs) out.push(t); return t <= toTs; };
  if (s.kind === 'ONCE') { push(s.start_date); return out; }
  let date = s.start_date; const startLocal = localParts(Math.max(fromTs, 0)).date;
  if (startLocal > date) date = addDays(startLocal, -1);   // empezar cerca de 'fromTs' (sin recorrer años)
  if (s.kind === 'MONTHLY') {
    let [y, m] = date.split('-').map(Number);
    for (let i = 0; i < 1200 && out.length < max; i++, m === 12 ? (m = 1, y++) : m++) {
      const dim = daysInMonth(y, m); let d = s.month_day;
      if (d > dim) { if (s.month_missing === 'SKIP') continue; d = dim; }
      const ds = y + '-' + pad(m) + '-' + pad(d); if (ds < s.start_date) continue;
      if (s.end_date && ds > s.end_date) break;
      if (!push(ds)) break;
    }
    return out;
  }
  for (let i = 0; i < 4000 && out.length < max; i++, date = addDays(date, 1)) {
    if (date < s.start_date) continue;
    if (s.end_date && date > s.end_date) break;
    if (s.kind === 'WEEKLY' && !s.weekdays.includes(isoWeekday(date))) continue;
    if (!push(date)) break;
  }
  return out;
}
// próximas 'count' ejecuciones después de 'fromTs' (la ventana parte del inicio de la programación si es posterior)
export const nextRuns = (s, fromTs, count = 5) => { if (validateSchedule(s).length) return []; const base = Math.max(fromTs, zonedToUtc(s.start_date, '00:00') - 864e5); return occurrencesBetween(s, fromTs, base + 3 * 366 * 864e5, count); };
export function describeSchedule(s) {
  if (!s || validateSchedule(s).length) return 'Sin programación válida';
  const h = s.time + ' (hora de Argentina)', end = s.end_date ? ' hasta el ' + fmtDate(s.end_date) : '';
  if (s.kind === 'ONCE') return 'Una vez, el ' + fmtDate(s.start_date) + ' a las ' + h;
  if (s.kind === 'DAILY') return 'Todos los días a las ' + h + ', desde el ' + fmtDate(s.start_date) + end;
  if (s.kind === 'WEEKLY') return 'Cada ' + s.weekdays.slice().sort().map(d => WEEKDAYS[d]).join(', ') + ' a las ' + h + ', desde el ' + fmtDate(s.start_date) + end;
  return 'El día ' + s.month_day + ' de cada mes a las ' + h + (s.month_day > 28 ? (s.month_missing === 'SKIP' ? ' (se omiten los meses sin ese día)' : ' (último día del mes cuando no existe)') : '') + ', desde el ' + fmtDate(s.start_date) + end;
}
export const fmtDate = d => d.slice(8, 10) + '/' + d.slice(5, 7) + '/' + d.slice(0, 4);
export const fmtLocal = ts => { const p = localParts(ts); return WEEKDAYS[isoWeekday(p.date)] + ' ' + fmtDate(p.date) + ' ' + p.time; };

// ---------- Destinatarios ----------
export const normEmail = e => String(e || '').trim().toLowerCase();
export const validEmail = e => /^[^\s@<>()",;]+@[^\s@<>()",;]+\.[a-z]{2,}$/i.test(String(e || '').trim());
const norm = s => String(s || '').trim().toLowerCase();
// selection: { all: bool, ids: [], branches: [], sectors: [] } → lista final (activos, sin duplicados) + excluidos con motivo
export function resolveRecipients(collaborators, selection) {
  const sel = selection || {}, ids = new Set(sel.ids || []), br = new Set((sel.branches || []).map(norm)), se = new Set((sel.sectors || []).map(norm));
  const list = [], excluded = [], seenId = new Set(), seenMail = new Map();
  for (const c of collaborators || []) {
    const why = [sel.all && 'todos los activos', ids.has(c.id) && 'individual', br.has(norm(c.branch)) && 'sucursal ' + c.branch, se.has(norm(c.sector)) && 'sector ' + c.sector].filter(Boolean);
    if (!why.length) continue;
    if (!c.active) { excluded.push({ id: c.id, name: c.full_name, reason: 'Inactivo' }); continue; }
    if (!validEmail(c.email)) { excluded.push({ id: c.id, name: c.full_name, reason: 'Correo inválido' }); continue; }
    if (seenId.has(c.id)) continue;
    const em = normEmail(c.email);
    if (seenMail.has(em)) { excluded.push({ id: c.id, name: c.full_name, reason: 'Mismo correo que ' + seenMail.get(em) }); continue; }
    seenId.add(c.id); seenMail.set(em, c.full_name);
    list.push({ collaborator_id: c.id, name: c.full_name, email: em, branch: c.branch || '', sector: c.sector || '', matched_by: why });
  }
  list.sort((a, b) => a.name.localeCompare(b.name, 'es'));
  return { list, excluded };
}

// ---------- Texto con formato: sanitización por lista blanca ----------
const ALLOWED = new Set(['p', 'br', 'b', 'strong', 'i', 'em', 'u', 's', 'ul', 'ol', 'li', 'h2', 'h3', 'blockquote', 'hr', 'a', 'div']);
const DROP_WITH_CONTENT = new Set(['script', 'style', 'iframe', 'object', 'embed', 'noscript', 'template', 'svg', 'math', 'head', 'title', 'textarea', 'select']);
const VOID = new Set(['br', 'hr']);
export const escHtml = s => String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const decodeEntities = s => String(s).replace(/&(#x[0-9a-f]+|#\d+|amp|lt|gt|quot|apos|nbsp);/gi, (m, e) => {
  const k = e.toLowerCase(); if (k === 'amp') return '&'; if (k === 'lt') return '<'; if (k === 'gt') return '>'; if (k === 'quot') return '"'; if (k === 'apos') return "'"; if (k === 'nbsp') return '\u00a0';
  const n = k[1] === 'x' ? parseInt(k.slice(2), 16) : parseInt(k.slice(1), 10); return Number.isFinite(n) && n > 0 && n < 0x110000 ? String.fromCodePoint(n) : ''; });
function safeHref(raw) {
  const v = decodeEntities(String(raw || '')).replace(/[\u0000-\u0020\u007f]+/g, '').trim();
  return /^(https?:|mailto:)/i.test(v) ? v : null;
}
export function sanitizeHtml(html) {
  const src = String(html || '').replace(/<!--[\s\S]*?-->/g, '').replace(/<!\[CDATA\[[\s\S]*?\]\]>/gi, '');
  let out = '', i = 0, dropDepth = 0, dropTag = null; const stack = [];
  const re = /<\s*(\/?)\s*([a-zA-Z][a-zA-Z0-9-]*)([^>]*)>/g; let m;
  while ((m = re.exec(src))) {
    const text = src.slice(i, m.index); i = re.lastIndex;
    if (!dropDepth) out += escHtml(decodeEntities(text));
    const closing = !!m[1], tag = m[2].toLowerCase(), attrs = m[3] || '';
    if (dropDepth) { if (tag === dropTag) dropDepth += closing ? -1 : 1; if (!dropDepth) dropTag = null; continue; }
    if (DROP_WITH_CONTENT.has(tag)) { if (!closing && !/\/\s*$/.test(attrs)) { dropDepth = 1; dropTag = tag; } continue; }
    if (!ALLOWED.has(tag)) continue;   // la etiqueta se quita; el texto que contiene se conserva (escapado)
    if (closing) { if (VOID.has(tag)) continue; const k = stack.lastIndexOf(tag); if (k < 0) continue; while (stack.length > k) out += '</' + stack.pop() + '>'; continue; }
    if (VOID.has(tag)) { out += '<' + tag + '>'; continue; }
    if (tag === 'a') {
      const hm = attrs.match(/\shref\s*=\s*("([^"]*)"|'([^']*)'|([^\s>]+))/i), href = hm ? safeHref(hm[2] ?? hm[3] ?? hm[4]) : null;
      if (!href) continue;   // enlace no seguro: se conserva el texto, sin enlace
      out += '<a href="' + escHtml(href) + '" target="_blank" rel="noopener noreferrer">'; stack.push('a'); continue;
    }
    out += '<' + tag + '>'; stack.push(tag);   // sin atributos: ni estilos, ni eventos, ni clases
  }
  if (!dropDepth) out += escHtml(decodeEntities(src.slice(i)));
  while (stack.length) out += '</' + stack.pop() + '>';
  return out.replace(/<(p|div)><\/\1>/g, '').trim();
}
export function htmlToText(html, { whatsapp = false } = {}) {
  let s = sanitizeHtml(html);
  const W = whatsapp;
  s = s.replace(/<a href="([^"]*)"[^>]*>([\s\S]*?)<\/a>/g, (m, h, t) => { const txt = t.replace(/<[^>]+>/g, ''); const hh = decodeEntities(h); return txt && decodeEntities(txt) !== hh ? txt + ' (' + hh + ')' : hh; });
  if (W) s = s.replace(/<(b|strong)>([\s\S]*?)<\/\1>/g, (m, t, x) => x.trim() ? '*' + x.trim() + '*' : '').replace(/<(i|em)>([\s\S]*?)<\/\1>/g, (m, t, x) => x.trim() ? '_' + x.trim() + '_' : '').replace(/<s>([\s\S]*?)<\/s>/g, (m, x) => x.trim() ? '~' + x.trim() + '~' : '')
    .replace(/<h[23]>([\s\S]*?)<\/h[23]>/g, (m, x) => '\n*' + x.trim() + '*\n');
  s = s.replace(/<li>/g, '\n• ').replace(/<\/li>/g, '').replace(/<br>/g, '\n').replace(/<hr>/g, '\n———\n').replace(/<\/(p|div|h2|h3|blockquote|ul|ol)>/g, '\n\n').replace(/<[^>]+>/g, '');   // cada bloque separado por una línea en blanco
  return decodeEntities(s).replace(/\u00a0/g, ' ').replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
}
export const whatsappText = msg => [msg.subject ? '*' + String(msg.subject).trim() + '*' : '', htmlToText(msg.body_html, { whatsapp: true })].filter(Boolean).join('\n\n');

// ---------- Adjuntos y tamaño final del correo ----------
export const ATTACH = { types: { 'image/png': 'PNG', 'image/jpeg': 'JPG', 'image/webp': 'WEBP', 'image/gif': 'GIF', 'application/pdf': 'PDF' },
  maxFileBytes: 8 * 1024 * 1024, maxTotalBytes: 15 * 1024 * 1024, maxFiles: 6, gmailMaxEmailBytes: 25 * 1024 * 1024 };
// tipo REAL por los primeros bytes (no se confía en la extensión ni en el tipo informado por el navegador)
export function sniffType(bytes) {
  const b = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes || []);
  const h = (...xs) => xs.every((x, i) => b[i] === x);
  if (h(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a)) return 'image/png';
  if (h(0xff, 0xd8, 0xff)) return 'image/jpeg';
  if (h(0x47, 0x49, 0x46, 0x38)) return 'image/gif';
  if (h(0x52, 0x49, 0x46, 0x46) && b[8] === 0x57 && b[9] === 0x45 && b[10] === 0x42 && b[11] === 0x50) return 'image/webp';
  if (h(0x25, 0x50, 0x44, 0x46, 0x2d)) return 'application/pdf';
  return null;
}
export function validateAttachment(file, existing = []) {
  const e = [];
  if (!ATTACH.types[file.mime]) e.push(file.name + ': solo se aceptan imágenes (PNG, JPG, WEBP, GIF) o PDF.');
  // si se analizó el contenido, debe coincidir: un contenido NO reconocido (null) también se rechaza (p. ej. un .exe renombrado)
  if ('sniffed' in file && file.sniffed !== file.mime) e.push(file.name + ': el contenido no coincide con el tipo de archivo.');
  if (file.size > ATTACH.maxFileBytes) e.push(file.name + ': supera ' + mb(ATTACH.maxFileBytes) + ' por archivo.');
  if (existing.length + 1 > ATTACH.maxFiles) e.push('Máximo ' + ATTACH.maxFiles + ' adjuntos por comunicado.');
  const total = existing.reduce((a, x) => a + (x.size_bytes || x.size || 0), 0) + file.size;
  if (total > ATTACH.maxTotalBytes) e.push('Los adjuntos sumarían ' + mb(total) + ': el máximo es ' + mb(ATTACH.maxTotalBytes) + ' por comunicado.');
  return e;
}
export const mb = n => (n / 1024 / 1024).toFixed(n >= 10 * 1024 * 1024 ? 0 : 1).replace('.', ',') + ' MB';
const b64len = n => Math.ceil(n / 3) * 4, lines = n => n + Math.ceil(n / 76) * 2;
// tamaño FINAL estimado del correo: encabezados + HTML + texto (base64) + adjuntos en base64 con saltos de línea
export function estimateEmailBytes({ subject = '', html = '', attachments = [] }) {
  const enc = new TextEncoder(), body = enc.encode(html).length, text = enc.encode(htmlToText(html)).length;
  return 1200 + enc.encode(subject).length * 2 + lines(b64len(body)) + lines(b64len(text)) + attachments.reduce((a, x) => a + 300 + lines(b64len(x.size_bytes || x.size || 0)), 0);
}

// ---------- Correo MIME (uno por destinatario; nunca CC/BCC con otros) ----------
const b64 = bytes => { let s = ''; const B = bytes instanceof Uint8Array ? bytes : new TextEncoder().encode(String(bytes)); for (let i = 0; i < B.length; i += 0x8000) s += String.fromCharCode.apply(null, B.subarray(i, i + 0x8000)); return btoa(s); };
const wrap76 = s => s.replace(/.{1,76}/g, '$&\r\n');
const encWord = s => /^[\x20-\x7e]*$/.test(s) ? s : '=?UTF-8?B?' + b64(String(s)) + '?=';
const headerSafe = s => String(s || '').replace(/[\r\n]+/g, ' ').trim();
export function buildMime({ from, fromName, to, toName, subject, html, attachments = [], boundary }) {
  if (!validEmail(to)) throw Object.assign(new Error('Destinatario inválido'), { code: 'INVALID_RECIPIENT' });
  const safe = sanitizeHtml(html), text = htmlToText(safe), B = boundary || ('okd-' + Math.random().toString(36).slice(2) + Date.now().toString(36)), A = 'alt-' + B;
  const addr = (n, e) => (n ? encWord(headerSafe(n)) + ' ' : '') + '<' + headerSafe(e) + '>';
  const doc = '<!doctype html><html><body style="font-family:Arial,Helvetica,sans-serif;font-size:15px;line-height:1.5;color:#111">' + safe + '</body></html>';
  let m = 'From: ' + addr(fromName, from) + '\r\nTo: ' + addr(toName, to) + '\r\nSubject: ' + encWord(headerSafe(subject)) + '\r\nMIME-Version: 1.0\r\n';
  m += 'Content-Type: multipart/mixed; boundary="' + B + '"\r\n\r\n--' + B + '\r\nContent-Type: multipart/alternative; boundary="' + A + '"\r\n\r\n';
  m += '--' + A + '\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n' + wrap76(b64(text));
  m += '--' + A + '\r\nContent-Type: text/html; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n' + wrap76(b64(doc)) + '--' + A + '--\r\n';
  for (const a of attachments) {
    const name = headerSafe(a.name).replace(/"/g, '');
    m += '--' + B + '\r\nContent-Type: ' + a.mime + '; name="' + encWord(name) + '"\r\nContent-Disposition: attachment; filename="' + encWord(name) + '"\r\nContent-Transfer-Encoding: base64\r\n\r\n' + wrap76(b64(a.bytes));
  }
  return m + '--' + B + '--\r\n';
}
export const base64url = s => b64(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

// ---------- Errores de Gmail y reintentos ----------
// AUTH: hace falta reconectar (no se reintenta) · RETRYABLE: espera y reintento limitado · PERMANENT: no se reintenta
// AMBIGUOUS: Gmail pudo haberlo aceptado (se perdió la respuesta) → "Por verificar", NUNCA se reenvía a ciegas
export function classifyGmailError(err) {
  const st = err && (err.status || err.httpStatus), reason = String(err && (err.reason || err.code || err.message) || '');
  if (err && err.phase === 'AFTER_SEND') return 'AMBIGUOUS';
  if (st === 401 || /invalid_grant|unauthorized_client|invalid_token|insufficientPermissions|ACCESS_TOKEN_SCOPE_INSUFFICIENT/i.test(reason)) return 'AUTH';
  if (st === 403 && /insufficient|scope|forbidden/i.test(reason) && !/rateLimit|quota|userRateLimit|dailyLimit/i.test(reason)) return 'AUTH';
  if (st === 429 || (st === 403 && /rateLimit|quota|userRateLimit|dailyLimit/i.test(reason)) || (st >= 500 && st < 600) || /network|ECONN|fetch failed|timeout before/i.test(reason)) return 'RETRYABLE';
  return 'PERMANENT';
}
export const MAX_ATTEMPTS = 4;
export const backoffSeconds = attempt => Math.min(3600, 60 * Math.pow(4, Math.max(0, attempt - 1)));   // 1 min, 4 min, 16 min, 1 h
export const STATUS_LABEL = { PENDIENTE: 'Pendiente', PROCESANDO: 'Procesando', ENVIADO: 'Enviado — aceptado por Gmail', ERROR: 'Error', POR_VERIFICAR: 'Por verificar', CANCELADO: 'Cancelado', OMITIDO: 'Omitido', VENCIDO: 'Vencido — no se envió (revisar)' };
