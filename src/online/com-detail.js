// AUTORIZACIONES COMERCIALES · detalle, seguimiento y trazabilidad con el DISEÑO APROBADO (OK_DESPACHO_PROPUESTA_AUTORIZACIONES.html).
// Solo PRESENTACIÓN: no calcula ni modifica condiciones, cuotas, vencimientos ni permisos. Muestra exclusivamente lo que el servidor devuelve
// (estado, línea de tiempo registrada, calendario GUARDADO). Clases propias «az-…» para no chocar con las globales de la app (.card b, .step).
import { FREQ, dmyFull } from './com-schedule.js';

export const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const TZ = 'America/Argentina/Mendoza';
// formato monetario argentino; conserva los decimales SOLO cuando existen (625.000 · 625.000,50)
export const moneyAR = n => {
  if (n == null || n === '' || !Number.isFinite(Number(n))) return '—';
  const v = Number(n), cents = Math.round(Math.abs(v) * 100) % 100 !== 0;
  return '$ ' + v.toLocaleString('es-AR', { minimumFractionDigits: cents ? 2 : 0, maximumFractionDigits: 2 });
};
const dmy = s => { if (!s) return '—'; const [y, m, d] = String(s).slice(0, 10).split('-'); return d && m && y ? d + '/' + m + '/' + y : '—'; };
const ts = s => { const t = Date.parse(s || ''); return Number.isFinite(t) ? t : null; };
// fecha y hora ARGENTINAS de un instante del servidor
export const fecha = s => { const t = ts(s); return t == null ? '—' : new Intl.DateTimeFormat('es-AR', { timeZone: TZ, day: '2-digit', month: '2-digit', year: 'numeric' }).format(t); };
export const hora = s => { const t = ts(s); return t == null ? '—' : new Intl.DateTimeFormat('es-AR', { timeZone: TZ, hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).format(t); };
export const fechaHora = s => ts(s) == null ? '—' : fecha(s) + ' · ' + hora(s);

// ---------- estados: color + TEXTO + ICONO (nunca solo color) ----------
export const STATE = {
  PENDIENTE: { cls: 'pending', label: 'Pendiente de aprobación', icon: '◷' },
  APROBADA: { cls: 'approved', label: 'Aprobada', icon: '✓' },
  APROBADA_MOD: { cls: 'changed', label: 'Aprobada con modificaciones', icon: '✓' },
  DEVUELTA: { cls: 'returned', label: 'Devuelta a Comercial', icon: '↩' },
  RECHAZADA: { cls: 'rejected', label: 'Rechazada', icon: '✕' },
  CANCELADA: { cls: 'neutral', label: 'Retirada por Comercial', icon: '⊘' }
};
const stOf = s => STATE[s] || { cls: 'neutral', label: String(s || '—'), icon: '•' };
export const pill = s => { const x = stOf(s); return '<span class="pill ' + x.cls + '" data-estado="' + esc(s) + '"><i class="az-ico" aria-hidden="true">' + x.icon + '</i>' + esc(x.label) + '</span>'; };

export const EV = { ENVIADA: 'Solicitud enviada a Administración', PENDIENTE: 'Pendiente de aprobación', APROBADA: 'Solicitud aprobada', APROBADA_CON_MODIFICACIONES: 'Aprobada con modificaciones',
  RECHAZADA: 'Solicitud rechazada', DEVUELTA_CON_MODIFICACIONES: 'Devuelta con modificaciones (no es aprobación)', CAMBIOS_ACEPTADOS_REENVIADA: 'Comercial aceptó los cambios y reenvió', RETIRADA_POR_COMERCIAL: 'Retirada por Comercial' };
const RESOLVING = ['APROBADA', 'APROBADA_CON_MODIFICACIONES', 'RECHAZADA', 'DEVUELTA_CON_MODIFICACIONES', 'RETIRADA_POR_COMERCIAL'];
const EV_TONE = { APROBADA: 'ok', APROBADA_CON_MODIFICACIONES: 'changed', RECHAZADA: 'no', DEVUELTA_CON_MODIFICACIONES: 'returned', RETIRADA_POR_COMERCIAL: 'neutral' };
const EV_ICON = { ok: '✓', changed: '✓', no: '✕', returned: '↩', neutral: '⊘', done: '✓', current: '◉', future: '○' };

// «Nombre — Rol» tal como lo registra el servidor (_com_label). Sin rol registrado se usa el PAPEL que exige la acción (nunca un nombre inventado).
export const person = s => { const [n, ...r] = String(s || '').split(' — '); return { name: n.trim() || null, role: r.join(' — ').trim() || null }; };
const FUNC_ROLE = { ENVIADA: 'Comercial', CAMBIOS_ACEPTADOS_REENVIADA: 'Comercial', RETIRADA_POR_COMERCIAL: 'Comercial', APROBADA: 'Responsable de aprobación',
  APROBADA_CON_MODIFICACIONES: 'Responsable de aprobación', RECHAZADA: 'Responsable de aprobación', DEVUELTA_CON_MODIFICACIONES: 'Responsable de aprobación', PENDIENTE: 'Responsable de aprobación asignado' };

// ---------- tiempos de espera (datos REALES de la línea de tiempo) ----------
// instante del ÚLTIMO ingreso a «pendiente de aprobación» (no se reinicia al recargar, navegar, cambiar de dispositivo ni de sesión)
export function pendingSince(r) {
  const tl = (r && r.timeline) || [];
  for (let i = tl.length - 1; i >= 0; i--) if (tl[i].kind === 'PENDIENTE' && ts(tl[i].at) != null) return tl[i].at;
  for (let i = tl.length - 1; i >= 0; i--) if (['ENVIADA', 'CAMBIOS_ACEPTADOS_REENVIADA'].includes(tl[i].kind) && ts(tl[i].at) != null) return tl[i].at;
  return r && r.status === 'PENDIENTE' && ts(r.created_at) != null ? r.created_at : null;
}
// tiempo TOTAL que permaneció pendiente la última vez (solo si la historia registra entrada y salida)
export function pendingSpan(r) {
  const tl = (r && r.timeline) || []; let i = -1;
  for (let k = tl.length - 1; k >= 0; k--) if (tl[k].kind === 'PENDIENTE') { i = k; break; }
  if (i < 0 || ts(tl[i].at) == null) return null;
  const end = tl.slice(i + 1).find(e => RESOLVING.includes(e.kind) && ts(e.at) != null);
  return end ? { since: tl[i].at, until: end.at, ms: Math.max(0, ts(end.at) - ts(tl[i].at)) } : null;
}
const p2 = n => String(n).padStart(2, '0');
// 00 min 35 seg · 07 min 24 seg · 01 h 15 min · 2 d 03 h 10 min
export function fmtElapsed(ms) {
  const s = Math.max(0, Math.floor((Number(ms) || 0) / 1000)), d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60), sec = s % 60;
  if (d) return d + ' d ' + p2(h) + ' h ' + p2(m) + ' min';
  if (h) return p2(h) + ' h ' + p2(m) + ' min';
  return p2(m) + ' min ' + p2(sec) + ' seg';
}
const lastEvent = r => { const tl = (r && r.timeline) || []; return tl.length ? tl[tl.length - 1] : null; };

// ---------- calendario como TABLA (cuota «n de k», vencimiento, importe, total) ----------
// sched: calendario GUARDADO (o la vista previa del formulario). mark: n.º de cuota que supera el límite (vista previa).
export function scheduleTable(sched, opts = {}) {
  const L = sched || [], k = Math.max(L.length, Number(opts.count) || 0); if (!L.length) return '<p class="micro">Sin calendario registrado.</p>';
  const total = opts.total != null ? Number(opts.total) : L.reduce((a, c) => a + (Number(c.amount) || 0), 0);
  const meta = [['Cuotas', k + ' cuota' + (k > 1 ? 's' : '')], opts.frequency && k > 1 ? ['Frecuencia', (FREQ[opts.frequency] || opts.frequency)] : null,
    opts.limit ? ['Fecha límite', dmy(opts.limit)] : null, ['Total', moneyAR(total)]].filter(Boolean);
  return '<div class="az-cal"' + (opts.attr ? ' ' + opts.attr : '') + '>' + (opts.meta === false ? '' : '<div class="az-calmeta">' + meta.map(([a, b]) => '<span><small>' + a + '</small><b>' + esc(b) + '</b></span>').join('') + '</div>') +
    '<div class="az-tblwrap"><table class="az-tbl"><thead><tr><th scope="col">Cuota</th><th scope="col">Vencimiento</th><th scope="col" class="num">Importe</th></tr></thead><tbody>' +
    L.map(c => { const over = mark(opts, c.n), b = opts.compare ? opts.compare.find(x => Number(x.n) === Number(c.n)) : undefined;
      const newRow = opts.compare && !b, dd = opts.compare && b && String(b.due) !== String(c.due), da = opts.compare && b && !sameNum(b.amount, c.amount);
      return '<tr data-cal-row="' + esc(c.n) + '"' + (over ? ' data-cal-excede class="az-over"' : newRow ? ' class="az-rowadd" data-cal-mod="NUEVA"' : '') + '><td class="az-n">' + esc(c.n) + ' de ' + k + (newRow ? ' <b class="az-modtag">NUEVA</b>' : '') + '</td>' +
        '<td' + (dd ? ' class="az-mod" data-cal-mod="VENCIMIENTO"' : '') + '><span data-cal-due>' + dmy(c.due) + '</span>' + (dd ? '<small class="az-before">antes ' + dmy(b.due) + '</small>' : '') +
        (over ? ' <b class="az-overtag">SUPERA EL LÍMITE</b>' : '') + '</td><td class="num' + (da ? ' az-mod" data-cal-mod="IMPORTE' : '') + '">' + moneyAR(c.amount) + (da ? '<small class="az-before">antes ' + moneyAR(b.amount) + '</small>' : '') + '</td></tr>'; }).join('') +
    '</tbody><tfoot><tr><th scope="row">Total</th><td>' + k + ' cuota' + (k > 1 ? 's' : '') + '</td><td class="num">' + moneyAR(total) + '</td></tr></tfoot></table></div></div>';
}
const mark = (o, n) => o.mark != null && n === o.mark;
const sameNum = (a, b) => (a == null && b == null) || (a != null && b != null && Math.abs(Number(a) - Number(b)) < 0.005);
// COMPARACIÓN solicitado ↔ autorizado/propuesto: detecta cambios aunque el TOTAL sea igual (cuotas, importes por cuota, vencimientos,
// frecuencia, fecha límite, emisor y cualquier otro dato registrado en las condiciones). Solo compara lo que el servidor envió.
const KNOWN = ['amount', 'installments', 'frequency', 'first_due', 'last_due', 'limit_date', 'schedule', 'days', 'due_date', 'issuer_is_client', 'issuer_name', 'issuer_cuit'];
const LBL = { amount: 'Importe total', installments: 'Cantidad de cuotas', frequency: 'Frecuencia', first_due: 'Primer vencimiento', last_due: 'Último vencimiento', limit_date: 'Fecha límite', due_date: 'Vencimiento del e-cheq', issuer: 'Emisor', issuer_cuit: 'CUIT del emisor' };
const fmtV = (k, v) => v == null || v === '' ? '—' : k === 'amount' ? moneyAR(v) : /due|date/.test(k) ? dmy(v) : k === 'frequency' ? (FREQ[v] || v) : String(v);
export function diffTerms(kind, o, t) {
  const ch = []; if (!o || !t) return ch;
  const add = (key, label, from, to) => ch.push({ key, label, from, to });
  if (!sameNum(o.amount, t.amount)) add('amount', LBL.amount, moneyAR(o.amount), moneyAR(t.amount));
  if (kind === 'ECHEQ') {
    if (String(o.due_date || '') !== String(t.due_date || '')) add('due_date', LBL.due_date, dmy(o.due_date), dmy(t.due_date));
    const iss = x => x.issuer_is_client || !x.issuer_name ? 'el mismo cliente' : x.issuer_name;
    if (iss(o) !== iss(t)) add('issuer', LBL.issuer, iss(o), iss(t));
    if (String(o.issuer_cuit || '') !== String(t.issuer_cuit || '')) add('issuer_cuit', LBL.issuer_cuit, o.issuer_cuit || '—', t.issuer_cuit || '—');
  } else {
    const so = o.schedule || [], sn = t.schedule || [], ko = o.installments != null ? Number(o.installments) : so.length, kn = t.installments != null ? Number(t.installments) : sn.length;
    if (ko !== kn) add('installments', LBL.installments, ko + ' cuota' + (ko === 1 ? '' : 's'), kn + ' cuota' + (kn === 1 ? '' : 's'));
    if ((ko > 1 || kn > 1) && (o.frequency || null) !== (t.frequency || null)) add('frequency', LBL.frequency, fmtV('frequency', o.frequency), fmtV('frequency', t.frequency));
    ['limit_date'].forEach(k => { if ((o[k] || t[k]) && String(o[k] || '') !== String(t[k] || '')) add(k, LBL[k], dmy(o[k]), dmy(t[k])); });
    const n = Math.max(so.length, sn.length);
    for (let i = 1; i <= n; i++) {
      const a = so.find(c => Number(c.n) === i), b = sn.find(c => Number(c.n) === i);
      if (!a) add('cuota', 'Cuota ' + i, 'no existía', dmy(b.due) + ' · ' + moneyAR(b.amount));
      else if (!b) add('cuota', 'Cuota ' + i, dmy(a.due) + ' · ' + moneyAR(a.amount), 'eliminada');
      else {
        if (String(a.due) !== String(b.due)) add('cuota_due', 'Vencimiento de la cuota ' + i, dmy(a.due), dmy(b.due));
        if (!sameNum(a.amount, b.amount)) add('cuota_amount', 'Importe de la cuota ' + i, moneyAR(a.amount), moneyAR(b.amount));
      }
    }
  }
  // cualquier otro dato registrado en las condiciones (sin interpretar su significado)
  [...new Set([...Object.keys(o), ...Object.keys(t)])].filter(k => !KNOWN.includes(k)).forEach(k => {
    const a = o[k], b = t[k]; if (JSON.stringify(a ?? null) !== JSON.stringify(b ?? null)) add('otro', 'Dato registrado «' + k + '»', a == null ? '—' : typeof a === 'object' ? JSON.stringify(a) : String(a), b == null ? '—' : typeof b === 'object' ? JSON.stringify(b) : String(b));
  });
  return ch;
}
function changesBox(r, o, t, ok) {
  const lbl = r.status === 'DEVUELTA' ? 'propuesto' : 'autorizado';
  if (!r.original_terms) return ok && r.status === 'APROBADA_MOD' ? '<div class="note az-note" data-cal-cambios="RESERVADO">Condiciones <b>modificadas</b> por el aprobador. Lo solicitado originalmente es información reservada para tu rol: se muestran solo las condiciones autorizadas.</div>' : '';
  const ch = diffTerms(r.kind, o, t);
  if (!ch.length) return '<div class="note good az-note" data-cal-cambios="0">' + (r.status === 'APROBADA_MOD' ? 'El servidor registró «aprobada con modificaciones», pero las condiciones guardadas coinciden con lo solicitado.' : 'Sin modificaciones: lo ' + lbl + ' coincide con lo solicitado.') + '</div>';
  return '<div class="az-changes" data-cal-cambios="' + ch.length + '"><b>Modificaciones respecto de lo solicitado (' + ch.length + ')</b><ul>' +
    ch.map(c => '<li data-cambio="' + esc(c.key) + '"><span>' + esc(c.label) + '</span><s>' + esc(c.from) + '</s><i aria-hidden="true">→</i><b>' + esc(c.to) + '</b><em class="az-sr"> (antes ' + esc(c.from) + ', ahora ' + esc(c.to) + ')</em></li>').join('') + '</ul></div>';
}
function echeqTable(t) {
  return '<div class="az-cal" data-cal-echeq><div class="az-tblwrap"><table class="az-tbl"><thead><tr><th scope="col">Instrumento</th><th scope="col">Vencimiento</th><th scope="col" class="num">Importe</th></tr></thead><tbody>' +
    '<tr><td>E-cheq' + (t.days != null ? ' · ' + esc(t.days) + ' días' : '') + '</td><td><span data-cal-due>' + dmy(t.due_date) + '</span></td><td class="num">' + moneyAR(t.amount) + '</td></tr></tbody></table></div>' +
    '<p class="az-mini">Emisor: <b>' + (t.issuer_is_client || !t.issuer_name ? 'el mismo cliente' : esc(t.issuer_name)) + '</b>' + (t.issuer_cuit ? ' · CUIT ' + esc(t.issuer_cuit) : '') + '</p></div>';
}

// ---------- bloque de estado (amarillo de espera con puntos animados y contador) ----------
export function statusBlock(r) {
  const x = stOf(r.status), last = lastEvent(r), who = person(r.assigned_approver), span = pendingSpan(r);
  const since = r.status === 'PENDIENTE' ? pendingSince(r) : null;
  const decisionEv = [...(r.timeline || [])].reverse().find(e => RESOLVING.includes(e.kind));
  const head = {
    PENDIENTE: ['Esperando aprobación de Administración', 'Solicitud enviada correctamente. Aún no está autorizada.'],
    APROBADA: ['Solicitud aprobada', 'La resolución administrativa fue registrada en el servidor.'],
    APROBADA_MOD: ['Aprobada con modificaciones', 'Se autorizaron condiciones DISTINTAS a las solicitadas. Revisá las condiciones autorizadas.'],
    RECHAZADA: ['Solicitud rechazada', 'La operación solicitada NO está autorizada.'],
    DEVUELTA: ['Devuelta a Comercial', 'NO es una aprobación: Comercial debe revisar la propuesta y reenviar o retirar.'],
    CANCELADA: ['Retirada por Comercial', 'La solicitud fue retirada y no está autorizada.']
  }[r.status] || [x.label, ''];
  const info = r.status === 'PENDIENTE' ? [
    ['Autorización', esc(r.number)], ['Estado actual', esc(x.label)], ['Responsable asignado', esc(who.name || '—') + (who.role ? '<em>' + esc(who.role) + '</em>' : '')],
    ['Enviada', fechaHora(r.created_at)], ['Último cambio de estado', last ? fechaHora(last.at) : '—'],
    ['Tiempo de espera', since ? '<span class="az-timer" role="timer" aria-live="off" data-wait-since="' + esc(since) + '">' + fmtElapsed(Date.now() - ts(since)) + '</span>' : 'Sin datos suficientes']
  ] : [
    ['Autorización', esc(r.number)], ['Estado actual', esc(x.label)],
    [{ DEVUELTA: 'Devolvió', CANCELADA: 'Retiró' }[r.status] || 'Resolvió', esc(person((r.status === 'CANCELADA' ? null : r.decided_by) || (decisionEv && decisionEv.by) || (decisionEv && decisionEv.by)).name || '—') + (r.decided_as === 'SUPLENTE_ADMIN' ? '<em>Suplencia de ' + esc(who.name || '') + '</em>' : person(r.decided_by).role ? '<em>' + esc(person(r.decided_by).role) + '</em>' : '')],
    ['Fecha y hora', fechaHora(r.decided_at || (decisionEv && decisionEv.at) || (last && last.at))],
    ['Permaneció pendiente', span ? '<span data-wait-total>' + fmtElapsed(span.ms) + '</span>' : 'Sin datos suficientes']
  ];
  return '<div class="az-state ' + x.cls + '" data-az-state="' + esc(r.status) + '"' + (r.status === 'PENDIENTE' ? ' data-az-waiting' : '') + '>' +
    '<div class="az-stateline"><div class="az-stateicon" aria-hidden="true">' + x.icon + '</div><div class="az-statetext"><h3>' + esc(head[0]) +
    (r.status === 'PENDIENTE' ? '<span class="az-dots" aria-hidden="true" data-az-dots><i></i><i></i><i></i></span><span class="az-stale">Estado sin confirmar · sin conexión</span>' : '') + '</h3>' +
    '<p>' + esc(head[1]) + '</p></div></div>' +
    '<dl class="az-waitinfo">' + info.map(([k, v]) => '<div><dt>' + k + '</dt><dd>' + v + '</dd></div>').join('') + '</dl></div>';
}
function stepper(r) {
  const tl = r.timeline || [], first = tl.find(e => e.kind === 'ENVIADA'), pend = [...tl].reverse().find(e => e.kind === 'PENDIENTE'), dec = [...tl].reverse().find(e => RESOLVING.includes(e.kind));
  const pending = r.status === 'PENDIENTE', x = stOf(r.status), tone = { approved: 'done', changed: 'changed', rejected: 'fail', returned: 'returned', neutral: 'neutral' }[x.cls] || '';
  return '<ol class="az-steps" aria-label="Avance de la solicitud">' +
    '<li class="az-step done"><b><i aria-hidden="true">✓</i> 1. Enviada</b><small>' + (first ? fechaHora(first.at) : fechaHora(r.created_at)) + '</small></li>' +
    '<li class="az-step ' + (pending ? 'current' : 'done') + '"' + (pending ? ' aria-current="step"' : '') + '><b><i aria-hidden="true">' + (pending ? '◉' : '✓') + '</i> 2. Pendiente de evaluación</b><small>' + (pend ? fechaHora(pend.at) : '—') + '</small></li>' +
    '<li class="az-step ' + (pending ? '' : tone) + '"><b><i aria-hidden="true">' + (pending ? '○' : x.icon) + '</i> 3. ' + (pending ? 'Resolución pendiente' : esc(x.label)) + '</b><small>' + (pending ? 'Aún sin decisión registrada' : dec ? fechaHora(dec.at) : fechaHora(r.decided_at)) + '</small></li></ol>';
}

// ---------- trazabilidad: SOLO los eventos registrados; si está pendiente se agrega el paso futuro «Resolución pendiente» (rotulado como tal) ----------
export function timeline(r, opts = {}) {
  const tl = r.timeline || [], pending = r.status === 'PENDIENTE', money = opts.money || moneyAR;
  const items = tl.map((e, i) => {
    const isLast = i === tl.length - 1, tone = EV_TONE[e.kind] || (pending && isLast ? 'current' : 'done');
    const actor = e.kind === 'PENDIENTE' ? person(e.assigned) : person(e.by), role = actor.role || FUNC_ROLE[e.kind] || null;
    const sup = e.assigned && e.by && !String(e.by).startsWith(String(e.assigned).split(' — ')[0]) && /APROBADA|RECHAZADA|DEVUELTA/.test(e.kind) ? '<small>Solicitud asignada a ' + esc(e.assigned) + '</small>' : '';
    return '<li class="az-ev ' + tone + '" data-ev="' + esc(e.kind) + '"><span class="az-evdot" aria-hidden="true">' + EV_ICON[tone] + '</span><div class="az-evbody"><strong>' + esc(EV[e.kind] || e.kind) + '</strong>' +
      '<div class="az-evmeta"><span>' + fecha(e.at) + '</span><span>' + hora(e.at) + '</span><span>' + (e.kind === 'PENDIENTE' ? 'Responsable asignado: ' : '') + '<b>' + esc(actor.name || '—') + '</b>' + (role ? ' · ' + esc(role) : '') + '</span></div>' + sup +
      (e.reason ? '<p class="az-evnote">' + esc(e.reason) + '</p>' : '') +
      (r.kind === 'FINANCIACION' && e.terms_after && e.terms_after.schedule ? '<small class="az-evcal" data-cal-paso>' + money(e.terms_after.amount) + ' · ' + e.terms_after.schedule.map(c => 'C' + c.n + ' ' + dmy(c.due)).join(' · ') + '</small>' : '') + '</div></li>';
  });
  if (pending) items.push('<li class="az-ev future" data-ev="FUTURO"><span class="az-evdot" aria-hidden="true">○</span><div class="az-evbody"><strong>Resolución pendiente</strong><div class="az-evmeta"><span>Sin decisión registrada. Se actualizará cuando el servidor informe un cambio real.</span></div></div></li>');
  return '<ol class="az-tl" aria-label="Trazabilidad de la autorización">' + items.join('') + '</ol>';
}

// ---------- detalle completo ----------
const TYPE = { FINANCIACION: 'Financiación propia', ECHEQ: 'Aceptación de e-cheq' };
const origin = r => r.channel === 'CARTERA' ? 'Cartera · ' + (r.cartera_label || '') : r.branch === 'SAN_JUAN' ? 'San Juan' : r.branch === 'MONTECASEROS' ? 'Montecaseros' : (r.branch || '—');
const field = (k, v, wide) => '<div class="az-field' + (wide ? ' wide' : '') + '"><span>' + k + '</span><b>' + v + '</b></div>';
// opts: urgent, kpiHtml, finance, actions, terms(kind,t) (texto de condiciones de com-ui)
export function detailView(r, opts = {}) {
  const ok = ['APROBADA', 'APROBADA_MOD'].includes(r.status), t = r.final_terms || r.current_terms || {}, o = r.original_terms || r.current_terms || {};
  const termsTxt = opts.terms || (() => '—'), who = person(r.assigned_approver), dec = person(r.decided_by);
  const decEv = [...(r.timeline || [])].reverse().find(e => RESOLVING.includes(e.kind) && e.kind !== 'RETIRADA_POR_COMERCIAL');
  let cal = '';
  const second = ok || r.status === 'DEVUELTA', full = !!r.original_terms, title2 = r.status === 'DEVUELTA' ? 'PROPUESTO por el aprobador' : 'AUTORIZADO';
  const box = (h, inner) => '<div class="az-calbox"><h4 class="az-sub label">' + h + '</h4>' + inner + '</div>';
  if (r.kind === 'FINANCIACION') {
    const sOpts = x => ({ frequency: x.frequency, limit: x.limit_date, total: x.amount });
    const req = full && o.schedule ? box('Calendario SOLICITADO', scheduleTable(o.schedule, sOpts(o))) : !second && o.schedule ? box('Calendario SOLICITADO', scheduleTable(o.schedule, sOpts(o))) : '';
    const sec = second ? box('Calendario ' + title2, t.schedule ? scheduleTable(t.schedule, { ...sOpts(t), compare: full ? o.schedule || [] : undefined }) : '<p class="micro">Sin calendario registrado.</p>') : '';
    cal = '<div class="az-section">Calendario de pagos</div>' + (second ? changesBox(r, o, t, ok) : '') + '<div class="calcompare az-calcompare" data-cal-detalle>' + req + sec + '</div>';
  } else if (r.kind === 'ECHEQ' && (t.due_date || o.due_date)) {
    cal = '<div class="az-section">Vencimiento del e-cheq</div>' + (second ? changesBox(r, o, t, ok) : '') +
      (second && full ? '<div class="calcompare az-calcompare" data-cal-detalle>' + box('SOLICITADO', echeqTable(o)) + box(title2, echeqTable(t)) + '</div>' : echeqTable(second ? t : o));
  }
  const reasonShown = decEv && decEv.reason;
  return '<div class="az" data-az-id="' + esc(r.id) + '" data-az-status="' + esc(r.status) + '">' +
    '<div class="sectionhead az-head"><div class="az-headtxt"><span class="eyebrow">' + esc(r.number) + ' · ' + esc(TYPE[r.kind] || r.kind) + '</span><h2>' + esc(r.client && r.client.razon_social) + '</h2><p class="az-mini">' + esc(origin(r)) + '</p></div>' + pill(r.status) + '</div>' +
    (opts.urgent ? '<div class="urgentslot" id="rUrgent" data-rid="' + esc(r.id) + '"></div>' : '') +
    '<div class="az-amounts">' + (!r.original_terms && ['APROBADA_MOD', 'DEVUELTA'].includes(r.status) ? '' : '<div><span>Importe solicitado</span><b>' + moneyAR(o.amount) + '</b></div>') + (ok ? '<div class="az-amt-ok"><span>Importe autorizado</span><b>' + moneyAR(t.amount) + '</b></div>' : r.status === 'DEVUELTA' ? '<div class="az-amt-ret"><span>Importe propuesto (no autorizado)</span><b>' + moneyAR(t.amount) + '</b></div>' : '') + '</div>' +
    statusBlock(r) + stepper(r) + (opts.sync ? '<p class="az-sync" data-az-sync>' + opts.sync + '</p>' : '') +
    '<div class="az-section">Detalle de la solicitud</div><div class="az-fields">' +
    field('Pedido', esc(r.order_ref || 'No informado')) + field('Origen', esc(origin(r))) +
    field('CUIT / Documento', esc((r.client && (r.client.cuit || ((r.client.doc_type || '') + ' ' + (r.client.doc_number || '')).trim())) || 'No informado')) +
    field('Comercial', esc(person(r.requested_by).name || '—')) +
    field(ok ? 'Condiciones autorizadas' : r.status === 'DEVUELTA' ? 'Condiciones PROPUESTAS en la devolución' : 'Condiciones solicitadas', (ok || r.status === 'DEVUELTA' ? moneyAR(t.amount) + ' · ' : '') + termsTxt(r.kind, t), true) +
    (r.decided_by && r.status !== 'PENDIENTE' ? field('Resolvió', esc(dec.name || '—') + (dec.role ? ' — ' + esc(dec.role) : '') + (r.decided_as === 'SUPLENTE_ADMIN' ? ' · suplencia de ' + esc(r.assigned_approver) : '') + ' · ' + fechaHora(r.decided_at), true)
      : field('Responsable de aprobación asignado', esc(who.name || '—') + (who.role ? ' — ' + esc(who.role) : ''), true)) +
    (opts.notes && r.notes ? field('Observaciones de Comercial', esc(r.notes), true) : '') + '</div>' +
    (r.status === 'DEVUELTA' ? '<div class="note warn az-note">La devolución propone <b>' + moneyAR(t.amount) + '</b> · ' + termsTxt(r.kind, t) + '. <b>NO es una aprobación.</b> Comercial debe revisar y reenviar.</div>' : '') +
    cal + (opts.kpiHtml || '') + (opts.finance || '') +
    (!['PENDIENTE'].includes(r.status) && reasonShown ? '<div class="az-section">Resolución administrativa</div><div class="az-resol ' + stOf(r.status).cls + '"><b>' +
      (r.status === 'RECHAZADA' ? 'Motivo del rechazo' : r.status === 'DEVUELTA' ? 'Motivo de la devolución' : 'Observación de la resolución') + '</b><p>' + esc(decEv.reason) + '</p></div>' : '') +
    '<h3 class="az-section az-tltitle">Trazabilidad de la autorización</h3>' + timeline(r, opts) +
    '<p class="az-foot">' + (r.status === 'PENDIENTE' ? 'No tomar la solicitud pendiente como autorización de despacho. Aplicar las reglas operativas vigentes.' : 'Consultá las condiciones y la resolución registradas antes de continuar.') + '</p>' +
    (opts.actions || '') + '</div>';
}

// firma de una lista: cambia SOLO si el servidor informó un cambio real (estado, versión, eventos)
export const signature = L => JSON.stringify((Array.isArray(L) ? L : [L]).filter(Boolean).map(x => [x.id, x.version, x.status, x.updated_at, (x.timeline || []).length]));

// UN solo temporizador por pantalla del módulo: actualiza todos los contadores visibles; se detiene al salir (stop) o si la pantalla ya no está.
export function startWaitTicker(root, alive, skewMs = () => 0) {
  const tick = () => {
    if (!alive()) { stop(); return; }
    if (typeof document !== 'undefined' && document.visibilityState === 'hidden') return;
    const now = Date.now() + (skewMs() || 0);
    root.querySelectorAll('[data-wait-since]').forEach(el => { const t = ts(el.getAttribute('data-wait-since')); if (t != null) { const v = fmtElapsed(now - t); if (el.textContent !== v) el.textContent = v; } });
  };
  let id = setInterval(tick, 1000);
  function stop() { if (id) { clearInterval(id); id = null; } }
  tick();
  return { stop, tick, get active() { return !!id; } };
}
