// AUTORIZACIONES COMERCIALES · pantallas con el DISEÑO APROBADO (HTML de referencia). Liviano para celular: sin librerías,
// búsqueda en el servidor, sin descargar el padrón ni archivos financieros. El servidor valida TODO (permisos, términos, decisiones).
import '../styles/com.css';
import { computeSchedule, arDate, FREQ, FREQ_PLURAL, dmyFull, addDays as calAddDays } from './com-schedule.js';
import { renderMailPanel, mailCopiesToSave } from './com-mail-panel.js';
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const money = n => n == null || n === '' ? '—' : '$ ' + Number(n).toLocaleString('es-AR', { maximumFractionDigits: 0 });
const dmy = s => { if (!s) return '—'; const [y, m, d] = String(s).slice(0, 10).split('-'); return d + '/' + m + '/' + y; };
const when = s => s ? new Date(s).toLocaleString('es-AR', { day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' }) : '—';
const ymd = d => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Argentina/Mendoza', year: 'numeric', month: '2-digit', day: '2-digit' }).format(d);
const addDays = (iso, n) => { const d = new Date(iso + 'T12:00:00Z'); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
const errMsg = e => String((e && e.message) || e).replace(/^[A-Z_]+:\s*/, '');
const TYPE = { FINANCIACION: 'Financiación propia', ECHEQ: 'Aceptación de e-cheq' };
const ST = { PENDIENTE: ['pending', 'Pendiente de aprobación'], APROBADA: ['approved', 'Aprobada'], APROBADA_MOD: ['changed', 'Aprobada con modificaciones'],
  DEVUELTA: ['returned', 'Devuelta a Comercial'], RECHAZADA: ['rejected', 'Rechazada'], CANCELADA: ['neutral', 'Retirada por Comercial'] };
const pill = s => '<span class="pill ' + (ST[s] || ['neutral'])[0] + '">' + esc((ST[s] || [, s])[1]) + '</span>';
const EV = { ENVIADA: 'Solicitud enviada a Administración', PENDIENTE: 'Pendiente de aprobación', APROBADA: 'Aprobada', APROBADA_CON_MODIFICACIONES: 'Aprobada con modificaciones',
  RECHAZADA: 'Rechazada', DEVUELTA_CON_MODIFICACIONES: 'Devuelta con modificaciones (no es aprobación)', CAMBIOS_ACEPTADOS_REENVIADA: 'Comercial aceptó los cambios y reenvió', RETIRADA_POR_COMERCIAL: 'Retirada por Comercial' };
const origin = r => r.channel === 'CARTERA' ? 'Cartera · ' + (r.cartera_label || '') : r.branch === 'SAN_JUAN' ? 'San Juan' : r.branch === 'MONTECASEROS' ? 'Montecaseros' : (r.branch || '—');
const finTerms = t => { const k = t.installments, f = t.frequency || (k > 1 ? 'SEMANAL' : null), first = t.first_due || (t.schedule && t.schedule[0] && t.schedule[0].due);
  return k + ' cuota' + (k > 1 ? 's ' + FREQ_PLURAL[f] : '') + (k > 1 && first ? ' · 1.ª ' + dmy(first) : '') + ' · ' + (k > 1 ? 'último vencimiento ' : 'vence ') + dmy(t.last_due) + ' (' + t.days + ' días)'; };
// calendario GUARDADO (nunca se recalcula: una solicitud histórica se muestra como se registró)
const calList = (sched, mark) => '<div class="schedule">' + (sched || []).map(c => '<div class="scheditem"' + (c.n === mark ? ' data-cal-excede style="border-color:#b42318;background:#fdecea"' : '') + '><strong>Cuota ' + c.n + ' · ' + money(c.amount) + '</strong><small>' + dmy(c.due) + (c.n === mark ? ' · <b style="color:#b42318">SUPERA EL LÍMITE</b>' : '') + '</small></div>').join('') + '</div>';
// formulario de calendario (Comercial «c» y aprobador «d»): cantidad → frecuencia (2+) → primer vencimiento
const calForm = (p, v) => '<label class="field"><span>CANTIDAD DE CUOTAS</span><select id="' + p + 'Inst">' + Array.from({ length: 8 }, (_, i) => '<option value="' + (i + 1) + '"' + (i + 1 === v.k ? ' selected' : '') + '>' + (i + 1) + ' cuota' + (i ? 's' : '') + '</option>').join('') + '</select></label>' +
  '<label class="field" id="' + p + 'FreqW"' + (v.k > 1 ? '' : ' hidden') + '><span>FRECUENCIA DE PAGO</span><select id="' + p + 'Freq"><option value="">Elegí la frecuencia…</option>' + Object.keys(FREQ).map(f => '<option value="' + f + '"' + (f === v.freq ? ' selected' : '') + '>' + FREQ[f] + '</option>').join('') + '</select></label>' +
  '<label class="field"><span id="' + p + 'FirstL">' + (v.k > 1 ? 'PRIMER VENCIMIENTO' : 'FECHA DE VENCIMIENTO') + '</span><input class="input" type="date" id="' + p + 'First" min="' + v.base + '" max="' + calAddDays(v.base, 30) + '" value="' + esc(v.first || '') + '"></label>' +
  '<div class="spanall" id="' + p + 'Sched"></div>';
function calWire(p, base, amountOf, after) {
  const $$ = id => document.getElementById(p + id);
  const upd = () => {
    const k = Number($$('Inst').value); $$('FreqW').hidden = k < 2; $$('FirstL').textContent = k > 1 ? 'PRIMER VENCIMIENTO' : 'FECHA DE VENCIMIENTO';
    const c = computeSchedule({ base, installments: k, frequency: $$('Freq').value, first_due: $$('First').value, amount: amountOf() });
    $$('Sched').innerHTML = '<p class="micro" data-cal-limit>Fecha límite: <b>' + dmyFull(c.limit) + '</b> · 30 días corridos desde la creación de la solicitud (' + dmyFull(base) + '), el día 30 incluido.</p>' +
      (c.ok ? '<span class="label">Calendario de pago</span>' + calList(c.schedule)
        : c.error.code === 'BAD_SCHEDULE' ? '<div class="note warn" data-cal-error>' + esc(c.error.message) + '</div>' + calList(c.schedule, c.error.cuota)
        : '<p class="micro" data-cal-pending>' + esc(c.error.message) + '</p>');
    if (after) after(c); return c;
  };
  ['Inst', 'Freq', 'First'].forEach(x => { const e = $$(x); if (e) { e.onchange = upd; e.oninput = upd; } });
  return upd;
}
const terms = (k, t) => !t ? '—' : k === 'FINANCIACION' ? finTerms(t)
  : 'Vence ' + dmy(t.due_date) + ' (' + t.days + ' días) · Emisor: ' + (t.issuer_is_client ? 'el mismo cliente' : esc(t.issuer_name)) + (t.issuer_cuit ? ' · CUIT ' + t.issuer_cuit : '');
const head = (sub, title, desc, extra = '') => '<div class="heading"><div><div class="eyebrow">' + sub + '</div><h1>' + title + '</h1><p class="lead">' + desc + '</p></div>' + extra + '</div>';

function timeline(r) {
  return '<div class="timeline">' + (r.timeline || []).map((e, i, a) => {
    const last = i === a.length - 1, cls = last ? (r.status === 'RECHAZADA' ? 'fail' : ['APROBADA', 'APROBADA_MOD'].includes(r.status) ? 'ending' : '') : '';
    const sup = e.assigned && e.by && !String(e.by).startsWith(String(e.assigned).split(' — ')[0]) && /APROBADA|RECHAZADA|DEVUELTA/.test(e.kind) ? '<small>Solicitud asignada a ' + esc(e.assigned) + '</small>' : '';
    return '<div class="step ' + cls + '"><strong>' + esc(EV[e.kind] || e.kind) + (e.kind === 'PENDIENTE' && e.assigned ? ' · ' + esc(e.assigned) : '') + '</strong><small>' + esc(e.by || '—') + ' · ' + when(e.at) + '</small>' + sup +
      (e.reason ? '<p>' + esc(e.reason) + '</p>' : '') +
      (r.kind === 'FINANCIACION' && e.terms_after && e.terms_after.schedule ? '<small data-cal-paso>' + money(e.terms_after.amount) + ' · ' + e.terms_after.schedule.map(c => 'C' + c.n + ' ' + dmy(c.due)).join(' · ') + '</small>' : '') + '</div>';
  }).join('') + '</div>';
}
function kpiBox(k, amount, compact) {
  if (!k || k.status === 'NO_APLICA') return '';
  const lbl = k.label ? '<span class="provisional">' + esc(k.label) + '</span>' : '';
  if (!['OK', 'PARCIAL'].includes(k.status)) return '<div class="quick-kpi"><div class="row between"><span class="label">KPI ORIENTATIVO · PROMEDIO ' + (k.months_cfg || 3) + ' MESES</span><span class="pill neutral">No bloquea solicitudes</span></div>' + lbl +
    '<div class="kpi-message kpi-warn">' + esc(k.status === 'PENDIENTE_IMPORTACION' ? 'Datos insuficientes / pendiente de importación.' : (k.detail || 'SIN HISTORIAL SUFICIENTE')) + '</div>' +
    '<p class="micro" style="margin:7px 0 0">Fuente: cargas diarias de Depósito' + (k.last_update ? ' · última actualización ' + when(k.last_update) : '') + '. No se inventan importes.</p></div>';
  const a = Number(amount) || 0, bad = a > k.ceiling, low = a > 0 && a < k.floor;
  return '<div class="quick-kpi"><div class="row between"><span class="label">KPI ORIENTATIVO · PROMEDIO ' + k.months_cfg + ' MESES' + (k.status === 'PARCIAL' ? ' (' + k.coverage + ' con cargas)' : '') + '</span><span class="pill neutral">No bloquea solicitudes</span></div>' + lbl +
    '<div class="kpi-twovalues"><div><span class="micro">Compras netas promedio</span><strong>' + money(k.average) + '</strong></div><div style="text-align:right"><span class="micro">Techo sugerido · ' + k.ceiling_pct + '%</span><strong>' + money(k.ceiling) + '</strong></div></div>' +
    '<div class="bar"><span style="width:' + Math.max(0, Math.min(100, k.ceiling ? a / k.ceiling * 100 : 0)) + '%"></span></div>' +
    '<div class="row between"><span class="micro">Piso ' + k.floor_pct + '%: ' + money(k.floor) + '</span><span class="micro">Solicitado: ' + money(a) + '</span></div>' +
    (compact ? '' : '<div class="kpi-message ' + (bad ? 'kpi-warn' : 'kpi-ok') + '">' + (bad ? 'Por encima del techo recomendado. Se envía igualmente a aprobación.' : low ? 'Por debajo del piso recomendado. Se puede solicitar igualmente.' : 'Dentro de la banda recomendada. La aprobación corresponde a Gerencia.') + '</div>') +
    '<p class="micro" style="margin:7px 0 0">Fuente: ' + esc(k.source || 'cargas diarias de Depósito') + (k.last_update ? ' · actualizado ' + when(k.last_update) : '') + (k.excluded_docs ? ' · ' + k.excluded_docs + ' comprobante(s) en conciliación excluidos' : '') + '. Comercial no carga ventas.</p></div>';
}
function requestList(arr, sel, meId) {
  return arr.map(r => '<button type="button" class="request ' + (sel === r.id ? 'active' : '') + '" data-select="' + esc(r.id) + '"><div class="row between"><b>' + esc(r.number) + (r.order_ref ? ' · ' + esc(r.order_ref) : '') + '</b>' + pill(r.status) + '</div>' +
    '<small>' + esc(r.client.razon_social) + ' · ' + esc(origin(r)) + (meId && r.assigned_approver_id && r.assigned_approver_id !== meId && r.status === 'PENDIENTE' ? ' · asignada a ' + esc(String(r.assigned_approver || '').split(' — ')[0]) : '') + '</small>' +
    '<div class="row between"><div class="amount">' + money((r.final_terms || r.current_terms || {}).amount) + '</div><span class="micro">' + esc(TYPE[r.kind]) + '</span></div></button>').join('') || '<div class="note">Sin solicitudes para este filtro.</div>';
}
function details(r, opts = {}) {
  const ok = ['APROBADA', 'APROBADA_MOD'].includes(r.status), t = r.final_terms || r.current_terms, o = r.original_terms || r.current_terms;
  return '<div class="sectionhead"><div><span class="eyebrow">' + esc(r.number) + ' · ' + esc(TYPE[r.kind]) + '</span><h2 style="margin:5px 0">' + esc(r.client.razon_social) + '</h2></div>' + pill(r.status) + '</div>' +
    (opts.urgent ? '<div class="urgentslot" id="rUrgent" data-rid="' + esc(r.id) + '"></div>' : '') +   // alarma urgente desde la solicitud (junto al estado)
    '<div class="grid two" style="gap:9px;margin:12px 0"><div class="metric"><small>Importe solicitado</small><b>' + money(o && o.amount) + '</b></div><div class="metric tint"><small>' + (ok ? 'Importe autorizado' : 'Responsable') + '</small><b style="font-size:18px">' + (ok ? money(t.amount) : esc(String(r.assigned_approver || '—').split(' — ')[0])) + '</b></div></div>' +
    '<div class="fg" style="margin:12px 0"><div><span class="label">Pedido</span><div><b>' + esc(r.order_ref || '—') + '</b></div></div><div><span class="label">Origen</span><div><b>' + esc(origin(r)) + '</b></div></div>' +
    '<div><span class="label">CUIT / Documento</span><div><b>' + esc(r.client.cuit || ((r.client.doc_type || '') + ' ' + (r.client.doc_number || '—'))) + '</b></div></div><div><span class="label">Comercial</span><div><b>' + esc(String(r.requested_by || '').split(' — ')[0]) + '</b></div></div>' +
    '<div class="spanall"><span class="label">' + (ok ? 'Condiciones autorizadas' : r.status === 'DEVUELTA' ? 'Condiciones PROPUESTAS en la devolución' : 'Condiciones solicitadas') + '</span><div><b>' + (ok || r.status === 'DEVUELTA' ? money(t.amount) + ' · ' : '') + terms(r.kind, t) + '</b></div></div>' +
    (r.decided_by ? '<div class="spanall"><span class="label">Resolvió</span><div><b>' + esc(r.decided_by) + '</b>' + (r.decided_as === 'SUPLENTE_ADMIN' ? ' · suplencia de ' + esc(r.assigned_approver) : '') + ' · ' + when(r.decided_at) + '</div></div>' : '') + '</div>' +
    (r.status === 'DEVUELTA' ? '<div class="note warn">La devolución propone <b>' + money(t.amount) + '</b> · ' + terms(r.kind, t) + '. <b>NO es una aprobación.</b> Comercial debe revisar y reenviar.</div>' : '') +
    (r.kind === 'FINANCIACION' && o && o.schedule ? '<div class="calcompare" data-cal-detalle>' +
      '<div><span class="label">Calendario SOLICITADO</span>' + calList(o.schedule) + (o.limit_date ? '<small class="micro">Fecha límite: ' + dmy(o.limit_date) + '</small>' : '') + '</div>' +
      (r.status === 'DEVUELTA' ? '<div><span class="label">Calendario PROPUESTO por el aprobador</span>' + calList(t.schedule) + '</div>'
        : ok ? '<div><span class="label">Calendario AUTORIZADO</span>' + (JSON.stringify(t.schedule) === JSON.stringify(o.schedule) && t.amount === o.amount ? '<p class="micro">El mismo que se solicitó.</p>' : calList(t.schedule)) + '</div>' : '') + '</div>' : '') +
    (opts.kpi && r.kpi ? '<h3 style="margin:14px 0 6px">KPI al momento de la solicitud</h3>' + kpiBox(r.kpi, o && o.amount, true) : '') + (opts.finance || '') +
    '<h3 style="margin:14px 0 6px">Trazabilidad de la autorización</h3>' + timeline(r) + (opts.actions || '');
}

export async function openCom(api, me, frame) { const w = frame(me, 'Autorizaciones comerciales', '#/autorizaciones'); return mount(api, me, w); }
export async function mountComHome(api, me) {
  const np = document.getElementById('noPanel'); const tt = np && np.querySelector('.ttl span'); if (tt) tt.textContent = 'Autorizaciones comerciales';
  const card = np && np.querySelector('.auth-card'); if (card) card.hidden = true;
  let host = document.getElementById('comHome'); if (!host) { host = document.createElement('div'); host.id = 'comHome'; np.appendChild(host); }
  return mount(api, me, host);
}

let disposeCommercial = null;
async function mount(api, me, host) {
  disposeCommercial?.();
  host.innerHTML = '<div class="com-app"><div class="shell"><div class="notice" id="comNotice" hidden></div><nav class="nav" id="comNav"></nav><main class="main" id="comMain"><p class="micro">Cargando…</p></main><div id="comModal"></div><div id="comToast"></div></div></div>';
  const $ = s => host.querySelector(s), app = host.querySelector('.com-app');
  let disposed=false, timer=null;
  const dispose=()=>{disposed=true;if(timer)clearInterval(timer);app.remove();window.removeEventListener('okd-com-cleanup',dispose);};
  disposeCommercial=dispose;window.addEventListener('okd-com-cleanup',dispose);
  let cfg; try { cfg = await api.comConfig(); } catch (e) { $('#comMain').innerHTML = '<div class="note warn">' + esc(errMsg(e)) + '</div>'; return; }
  if(disposed)return;
  // la primera pestaña es la OPERATIVA de cada rol (el módulo abre ahí); el Historial va después de las de trabajo
  const tabs = [cfg.can_request && ['comercial', '✎ Nueva solicitud'], cfg.can_approve && ['gerencia', '✓ Aprobaciones'], cfg.can_track && ['despacho', '◎ Seguimiento'],
    (cfg.can_request || cfg.can_approve || cfg.is_admin) && ['historial', '▤ Historial'],
    cfg.is_admin && ['general', '⚙ Panel General'], cfg.is_admin && ['informes', '▥ Informes']].filter(Boolean);
  const st = { tab: (new URLSearchParams((location.hash.split('?')[1] || '')).get('v')) || tabs[0][0], sel: null, client: null, kpi: null, type: 'FINANCIACION', search: '', open: false, invFilter: 'PENDIENTE' };
  if (!tabs.some(t => t[0] === st.tab)) st.tab = tabs[0][0];
  // HISTORIAL: filtros, alcance y posición se CONSERVAN al abrir un detalle y volver, al cambiar de pestaña y al recargar (sessionStorage, por usuario)
  const scopes = [cfg.can_request && ['MIS', 'Mis solicitudes'], cfg.can_approve && ['BANDEJA', 'Asignadas a mí'], cfg.is_admin && ['TODAS', 'Todas']].filter(Boolean);
  const HKEY = 'okd_com_hist_v1:' + me.id, H0 = { scope: scopes.length ? scopes[0][0] : 'MIS', f: {} };
  let saved = {}; try { saved = JSON.parse(sessionStorage.getItem(HKEY) || '{}'); } catch (e) { }
  st.hist = { scope: scopes.some(x => x[0] === saved.scope) ? saved.scope : H0.scope, f: saved.f || {}, items: [], cursor: null, has_more: false, loaded: false, detail: null, scroll: 0, err: null };
  const mailRequest=new URLSearchParams(location.hash.split('?')[1]||'').get('solicitud');
  if(st.tab==='historial'&&/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(mailRequest||''))st.hist.detail={id:mailRequest};
  const saveHist = () => { try { sessionStorage.setItem(HKEY, JSON.stringify({ scope: st.hist.scope, f: st.hist.f })); } catch (e) { } };
  const toast = (msg, bad) => { const t = document.createElement('div'); t.className = 'toast' + (bad ? ' danger' : ''); t.textContent = msg; $('#comToast').appendChild(t); setTimeout(() => t.remove(), 4200); };
  const nav = () => { $('#comNav').innerHTML = tabs.map(([k, l]) => '<button type="button" class="tab ' + (st.tab === k ? 'active' : '') + '" data-tab="' + k + '">' + l + '</button>').join('') +
    '<button type="button" class="tab" id="comBell" title="Avisos">🔔 <span id="comBellN">0</span></button>';
    host.querySelectorAll('[data-tab]').forEach(b => b.onclick = () => { st.tab = b.dataset.tab; st.sel = null; nav(); render(); }); $('#comBell').onclick = showBell; };
  // ---------- campana: avisos internos (y alerta de escritorio si el navegador lo permite) ----------
  let seen = new Set(), bellItems = [];
  async function pollBell(first) {
    try { bellItems = await api.comNotifications(); } catch (e) { return; }
    const unread = bellItems.filter(n => !n.read), n = $('#comBellN'); if (n) n.textContent = unread.length;
    unread.forEach(x => { if (!seen.has(x.id)) { seen.add(x.id); if (!first) { toast(x.title); try { if ('Notification' in window && Notification.permission === 'granted') new Notification('OK Despacho · ' + x.title, { body: x.body || '' }); } catch (e) { } } } });
  }
  function showBell() {
    try { if ('Notification' in window && Notification.permission === 'default') Notification.requestPermission(); } catch (e) { }
    $('#comModal').innerHTML = '<div class="modalbg"><div class="modal"><div class="sectionhead"><h2>Avisos</h2><button class="btn outline" type="button" data-close>Cerrar</button></div>' +
      (bellItems.map(x => '<div class="note' + (x.read ? '' : ' warn') + '" style="margin:6px 0"><b>' + esc(x.title) + '</b><br><small>' + esc(x.body || '') + ' · ' + when(x.at) + '</small></div>').join('') || '<p class="micro">Sin avisos.</p>') + '</div></div>';
    $('[data-close]').onclick = () => { $('#comModal').innerHTML = ''; };
  }
  // ---------- vistas ----------
  async function render() {
    if(disposed)return;
    const m = $('#comMain');
    try {
      const alarmaSol = new URLSearchParams(location.hash.split('?')[1] || '').get('alarma_sol');   // autorización abierta DESDE una alarma
      if (alarmaSol && /^[A-Za-z0-9-]{3,64}$/.test(alarmaSol)) return await vAlarmaSol(m, alarmaSol);
      if (st.tab === 'comercial') return await vComercial(m);
      if (st.tab === 'historial') return await vHistorial(m);
      if (st.tab === 'gerencia') return await vGerencia(m);
      if (st.tab === 'despacho') return await vDespacho(m);
      if (st.tab === 'general') return await vGeneral(m);
      if (st.tab === 'informes') return await vInformes(m);
    } catch (e) { m.innerHTML = '<div class="note warn">' + esc(errMsg(e)) + '</div>'; }
  }
  async function vComercial(m) {
    const a = cfg.my_assignment, s = cfg.settings, mine = await api.comList('MIS'), r = st.sel && mine.find(x => x.id === st.sel);
    const today = ymd(new Date()), maxK = Math.floor(s.fin_max_days / 7);
    m.innerHTML = head('ROL COMERCIAL', 'Nueva solicitud de autorización', 'Buscá el cliente, elegí el tipo, ingresá importe y plazo, y enviá. El KPI se calcula solo con las cargas de Depósito.') +
      '<div class="grid two"><section class="card"><div class="sectionhead"><h2>Cargar solicitud</h2></div>' +
      (!a ? '<div class="note warn">Administración todavía no te asignó sucursal o cartera. No podés enviar solicitudes hasta que lo haga.</div>' : '') +
      '<div class="selecttype"><button class="typebtn ' + (st.type === 'FINANCIACION' ? 'active' : '') + '" data-type="FINANCIACION" type="button">▤ Financiación propia<small>Cuotas, frecuencia y primer vencimiento</small></button>' +
      '<button class="typebtn ' + (st.type === 'ECHEQ' ? 'active' : '') + '" data-type="ECHEQ" type="button">▣ Aceptación de e-cheq<small>Emisor, importe y plazo</small></button></div>' +
      '<div class="fg"><label class="field spanall"><span>CLIENTE (nombre, razón social o CUIT)</span><input class="input" id="cSearch" autocomplete="off" placeholder="Ej.: TECNO o 30-50001091-2" value="' + esc(st.client ? st.client.razon_social : st.search) + '"><div id="cSugg"></div></label>' +
      '<label class="field"><span>CUIT DEL CLIENTE</span><input class="input" readonly id="cCuit" value="' + esc(st.client ? (st.client.cuit || 'Sin CUIT · ' + st.client.doc_type + ' ' + (st.client.doc_number || '')) : '') + '"></label>' +
      '<label class="field"><span>NÚMERO DE PEDIDO / REFERENCIA</span><input class="input" id="cOrder" placeholder="Ej.: 26940" maxlength="60"></label>' +
      (st.type === 'FINANCIACION' ? '<div id="cKpi" class="spanall">' + (st.client ? kpiBox(st.kpi, 0) : '<p class="micro">Elegí un cliente para ver su KPI orientativo.</p>') + '</div>' : '') +
      '<div class="field"><span>' + (a && a.channel === 'CARTERA' ? 'CARTERA' : 'SUCURSAL') + '</span><div class="input" style="background:var(--soft)">' + esc(a ? (a.channel === 'CARTERA' ? 'Cartera · ' + (a.cartera_label || '') : a.branch === 'SAN_JUAN' ? 'San Juan' : 'Montecaseros') : '—') + '</div></div>' +
      '<div class="field"><span>RESPONSABLE DE APROBACIÓN</span><div class="input" style="background:var(--soft)"><b>' + esc(a && a.approver ? String(a.approver).split(' — ')[0] : '—') + '</b><small style="display:block;color:var(--mut)">Asignación automática</small></div></div>' +
      '<label class="field"><span>IMPORTE SOLICITADO</span><input class="input" id="cAmount" inputmode="numeric" placeholder="Ej.: 2750000"></label>' +
      (st.type === 'FINANCIACION' ? calForm('c', { k: 1, freq: '', first: '', base: arDate() })
        : '<label class="field"><span>VENCIMIENTO DEL E-CHEQ</span><input class="input" type="date" id="cDue" min="' + today + '" max="' + addDays(today, s.cheq_max_days) + '"></label><label class="field"><span>EMISOR (vacío = el mismo cliente)</span><input class="input" id="cIssuer" placeholder="Nombre del emisor"></label><label class="field"><span>CUIT DEL EMISOR</span><input class="input" id="cIssuerCuit" inputmode="numeric" placeholder="Opcional"></label>') +
      '<label class="field spanall"><span>OBSERVACIONES (opcional)</span><textarea class="input" id="cNotes" rows="2" maxlength="600" placeholder="Información adicional para quien autoriza"></textarea></label></div>' +
      '<button class="btn primary wfull" type="button" id="cSend"' + (a ? '' : ' disabled') + '>Enviar solicitud a ' + esc(a && a.approver ? String(a.approver).split(' — ')[0] : 'aprobación') + '</button>' +
      '<p class="micro">El correo al aprobador queda preparado (sin envío real hasta su autorización). La alerta interna le llega al instante.</p></section>' +
      '<section class="card"><div class="sectionhead"><h2>Recientes</h2><button class="btn outline" type="button" id="goHist">▤ Ver historial completo</button></div><div class="requests">' + requestList(mine, st.sel) + '</div>' +
      (r ? '<div style="margin-top:14px">' + details(r, { actions: r.status === 'DEVUELTA' ? '<div class="row" style="gap:8px;flex-wrap:wrap;margin-top:12px"><input class="input" id="rComment" placeholder="Comentario (opcional)" maxlength="300"><button class="btn primary" type="button" id="rAccept">Aceptar cambios y reenviar a Gerencia</button><button class="btn outline" type="button" id="rWithdraw">Retirar solicitud</button></div>' : '' }) + '</div>' : '') + '</section></div>';
    host.querySelectorAll('[data-type]').forEach(b => b.onclick = () => { st.type = b.dataset.type; render(); });
    if ($('#goHist')) $('#goHist').onclick = () => { st.tab = 'historial'; nav(); render(); };
    host.querySelectorAll('[data-select]').forEach(b => b.onclick = () => { st.sel = b.dataset.select; render(); });
    // FINANCIACIÓN: calendario en vivo con la MISMA regla que el servidor; el envío se bloquea mientras sea inválido (lo cargado se conserva)
    const amountOf = () => Number(String(($('#cAmount') || {}).value || '').replace(/\D/g, '')) || 0;
    let cal = null;
    const sendState = () => { const b = $('#cSend'); if (!b || !a) return; const blk = st.type === 'FINANCIACION' && !(cal && cal.ok); b.disabled = blk; b.title = blk && cal ? cal.error.message : ''; };
    const calUpd = $('#cSched') ? calWire('c', arDate(), amountOf, c => { cal = c; sendState(); }) : null;
    const sched = () => { if (calUpd) calUpd(); const kb = $('#cKpi'); if (kb && st.client) kb.innerHTML = kpiBox(st.kpi, amountOf()); sendState(); };
    if ($('#cAmount')) $('#cAmount').oninput = sched; sched();
    // actualización de la app con el formulario abierto: mientras haya datos escritos y sin enviar, la recarga se POSTERGA (main.js · busy)
    { const card = $('#cSend') && $('#cSend').closest('section'), dirty = () => ['#cSearch', '#cOrder', '#cAmount', '#cNotes', '#cFirst'].some(k => $(k) && $(k).value.trim());
      if (card) card.addEventListener('input', () => { if (dirty()) card.setAttribute('data-okd-unsaved', '1'); else card.removeAttribute('data-okd-unsaved'); }); }
    // búsqueda en el SERVIDOR con sugerencias; nombre y CUIT salen SOLO del cliente elegido (vinculados)
    let tmr; const inp = $('#cSearch');
    inp.oninput = () => { st.client = null; st.kpi = null; $('#cCuit').value = ''; st.search = inp.value; if ($('#cKpi')) $('#cKpi').innerHTML = '<p class="micro">Elegí un cliente para ver su KPI orientativo.</p>'; clearTimeout(tmr); tmr = setTimeout(suggest, 250); };
    async function suggest() {
      const q = inp.value.trim(), box = $('#cSugg'); if (q.length < 2) { box.innerHTML = ''; return; }
      let L = []; try { L = await api.comSearchClients(q); } catch (e) { box.innerHTML = '<div class="note warn">' + esc(errMsg(e)) + '</div>'; return; }
      if (inp.value.trim() !== q) return;
      box.innerHTML = L.length ? '<div class="sugg">' + L.map((c, i) => '<button type="button" data-cli="' + i + '"' + (c.selectable ? '' : ' disabled') + '><b>' + esc(c.razon_social) + '</b>' + (c.nombre ? ' · ' + esc(c.nombre) : '') +
        '<small>' + esc(c.cuit ? 'CUIT ' + c.cuit : c.doc_type + ' ' + (c.doc_number || '—')) + (c.localidad ? ' · ' + esc(c.localidad) : '') + (c.selectable ? '' : ' · EN REVISIÓN: ' + esc((c.review_reasons || []).join(', '))) + '</small></button>').join('') + '</div>'
        : '<div class="note warn"><b>CLIENTE NO ENCONTRADO.</b> Pedí a Administración que lo incorpore o corrija en el padrón (Panel General → Padrón de clientes). No cargues datos a mano.</div>';
      box.querySelectorAll('[data-cli]').forEach(b => b.onclick = async () => {
        const c = L[+b.dataset.cli]; st.client = c; inp.value = c.razon_social; box.innerHTML = ''; $('#cCuit').value = c.cuit || 'Sin CUIT · ' + c.doc_type + ' ' + (c.doc_number || '');
        if (st.type === 'FINANCIACION') { try { st.kpi = await api.comKpi(c.id); } catch (e) { st.kpi = { status: 'SIN_HISTORIAL', detail: errMsg(e) }; } sched(); }
      });
    }
    $('#cSend').onclick = async () => {
      if (!st.client) { toast('Elegí el cliente de la lista (el CUIT se completa solo).', true); return; }
      const amount = Number(String($('#cAmount').value).replace(/\D/g, '')); if (!amount) { toast('Ingresá el importe.', true); return; }
      if (st.type === 'FINANCIACION' && !(cal && cal.ok)) { toast(cal ? cal.error.message : 'Completá el calendario de pago.', true); return; }
      const k = Number($('#cInst') ? $('#cInst').value : 0);
      const t = st.type === 'FINANCIACION' ? { amount, installments: k, first_due: $('#cFirst').value, ...(k > 1 ? { frequency: $('#cFreq').value } : {}) } : { amount, due_date: $('#cDue').value, issuer_name: $('#cIssuer').value.trim(), issuer_cuit: $('#cIssuerCuit').value.trim() };
      const b = $('#cSend'); b.disabled = true;
      try { const res = await api.comCreate(st.type, st.client.id, $('#cOrder').value.trim(), t, $('#cNotes').value.trim(), 'com-' + (crypto.randomUUID ? crypto.randomUUID() : Date.now()));
        toast('Solicitud ' + res.number + ' enviada' + (res.approver ? ' a ' + String(res.approver).split(' — ')[0] : '') + '.'); st.client = null; st.kpi = null; st.search = ''; st.sel = res.id; render(); }
      catch (e) { toast(errMsg(e), true); b.disabled = false; }
    };
    if (r && r.status === 'DEVUELTA') {
      const go = async ok => { try { await api.comRespond(r.id, r.version, ok, $('#rComment').value.trim()); toast(ok ? 'Cambios aceptados: la solicitud volvió a Gerencia.' : 'Solicitud retirada.'); render(); } catch (e) { toast(errMsg(e), true); } };
      $('#rAccept').onclick = () => go(true); $('#rWithdraw').onclick = () => go(false);
    }
  }
  // ---------- HISTORIAL COMPLETO (paginación por cursor en el servidor; el alcance lo decide el servidor) ----------
  const HST = ['PENDIENTE', 'DEVUELTA', 'APROBADA', 'APROBADA_MOD', 'RECHAZADA', 'CANCELADA'];
  // N-V4-04: cada búsqueda nueva (filtros, alcance, limpiar) recibe un NÚMERO DE CONSULTA; toda respuesta de una consulta anterior se DESCARTA
  // (no toca filas, cursor ni estado) y «Cargar más» no se superpone ni mezcla cursores de otra búsqueda
  async function histLoad(reset) {
    const H = st.hist;
    if (reset) { H.q = (H.q || 0) + 1; H.items = []; H.cursor = null; H.has_more = false; H.loadingMore = false; }
    else { if (H.loadingMore || !H.cursor) return; H.loadingMore = true; }
    const q = H.q || 0, cursor = reset ? null : H.cursor, f = { ...H.f, status: H.f.status ? [H.f.status] : undefined }; H.err = null;
    try { const r = await api.comHistory(H.scope, f, cursor, 25);
      if (disposed || q !== H.q) return;   // respuesta de una consulta anterior: se descarta
      const seen = new Set(H.items.map(x => x.id)); H.items = H.items.concat((r.items || []).filter(x => !seen.has(x.id))); H.cursor = r.next_cursor; H.has_more = !!r.has_more; H.loaded = true; }
    catch (e) { if (q === H.q) { H.err = errMsg(e); H.loaded = true; } }
    finally { if (!reset && q === H.q) H.loadingMore = false; }
  }
  async function vHistorial(m) {
    const H = st.hist;
    if (H.detail) return histDetail(m);
    if (!H.loaded) await histLoad(true);
    if (disposed) return;
    const f = H.f, sc = scopes.find(x => x[0] === H.scope) || ['MIS', 'Mis solicitudes'];
    m.innerHTML = head('HISTORIAL', esc(sc[1]), H.scope === 'MIS' ? 'Todas tus solicitudes, también las cerradas. Solo ves las tuyas.' : H.scope === 'BANDEJA' ? 'Solicitudes asignadas a vos.' : 'Todas las solicitudes del módulo.') +
      '<section class="card hist-f"><div class="fg">' +
      (scopes.length > 1 ? '<label class="field"><span>ALCANCE</span><select id="hScope">' + scopes.map(([k, l]) => '<option value="' + k + '"' + (k === H.scope ? ' selected' : '') + '>' + esc(l) + '</option>').join('') + '</select></label>' : '') +
      '<label class="field"><span>CLIENTE (razón social o CUIT)</span><input class="input" id="hQ" value="' + esc(f.q || '') + '" autocomplete="off"></label>' +
      '<label class="field"><span>N.º DE PEDIDO</span><input class="input" id="hOrder" value="' + esc(f.order_ref || '') + '"></label>' +
      '<label class="field"><span>N.º DE SOLICITUD</span><input class="input" id="hNum" value="' + esc(f.number || '') + '" placeholder="AUT-…"></label>' +
      '<label class="field"><span>DESDE</span><input class="input" type="date" id="hFrom" value="' + esc(f.from || '') + '"></label>' +
      '<label class="field"><span>HASTA</span><input class="input" type="date" id="hTo" value="' + esc(f.to || '') + '"></label>' +
      '<label class="field"><span>ESTADO</span><select id="hSt"><option value="">Todos</option>' + HST.map(x => '<option value="' + x + '"' + (f.status === x ? ' selected' : '') + '>' + esc((ST[x] || [, x])[1]) + '</option>').join('') + '</select></label>' +
      '<label class="field"><span>TIPO</span><select id="hKind"><option value="">Todos</option><option value="FINANCIACION"' + (f.kind === 'FINANCIACION' ? ' selected' : '') + '>Financiación propia</option><option value="ECHEQ"' + (f.kind === 'ECHEQ' ? ' selected' : '') + '>Aceptación de e-cheq</option></select></label>' +
      '</div><div class="row" style="gap:8px;flex-wrap:wrap"><button class="btn primary" type="button" id="hGo">Buscar</button><button class="btn outline" type="button" id="hClear">Limpiar filtros</button></div></section>' +
      (H.err ? '<div class="note warn" id="hErr" style="margin-top:10px"><b>No se pudo cargar el historial:</b> ' + esc(H.err) + ' <button class="btn outline" type="button" id="hRetry">Reintentar</button></div>' : '') +
      '<p class="micro" id="hCount" style="margin:10px 0">' + H.items.length + ' solicitud(es) cargada(s) · ' + (H.has_more ? '<b>quedan más resultados</b>' : 'no hay más resultados') + '</p>' +
      '<div class="hist-list" id="hList">' + (H.items.length ? H.items.map(x => '<button type="button" class="hist-item" data-hid="' + esc(x.id) + '">' +
        '<div class="hist-top"><b>' + esc(x.number) + '</b> ' + pill(x.status) + '</div>' +
        '<div class="hist-cli">' + esc(x.client || '—') + '</div>' +
        '<div class="hist-meta">Pedido ' + esc(x.order_ref || '—') + ' · ' + (x.kind === 'ECHEQ' ? 'E-cheq' : 'Financiación') + ' · ' + money(x.amount) + '</div>' +
        '<div class="hist-meta">Creada ' + when(x.created_at) + ' · Aprobador: ' + esc(String(x.assigned_approver || '—').split(' — ')[0]) + ' · Últ. modificación ' + when(x.updated_at) + '</div></button>').join('')
        : (H.err ? '' : '<p class="micro">Sin solicitudes para estos filtros.</p>')) + '</div>' +
      (H.has_more ? '<button class="btn outline wfull" type="button" id="hMore" style="margin-top:10px">Cargar más</button>' : '');
    const read = () => ({ q: $('#hQ').value.trim(), order_ref: $('#hOrder').value.trim(), number: $('#hNum').value.trim(), from: $('#hFrom').value, to: $('#hTo').value, status: $('#hSt').value, kind: $('#hKind').value });
    const clean = o => Object.fromEntries(Object.entries(o).filter(([, v]) => v));
    $('#hGo').onclick = async () => { H.f = clean(read()); saveHist(); const p = histLoad(true), q = H.q; await p; if (q === H.q) render(); };   // solo dibuja la consulta VIGENTE
    $('#hClear').onclick = async () => { H.f = {}; saveHist(); const p = histLoad(true), q = H.q; await p; if (q === H.q) render(); };
    [ '#hQ', '#hOrder', '#hNum' ].forEach(k => { $(k).onkeydown = e => { if (e.key === 'Enter') $('#hGo').click(); }; });
    if ($('#hScope')) $('#hScope').onchange = async () => { H.scope = $('#hScope').value; saveHist(); const p = histLoad(true), q = H.q; await p; if (q === H.q) render(); };
    if ($('#hRetry')) $('#hRetry').onclick = async () => { await histLoad(!H.items.length); render(); };
    if ($('#hMore')) $('#hMore').onclick = async () => { if (H.loadingMore) return; const b = $('#hMore'); b.disabled = true; const y = window.scrollY, q = H.q; await histLoad(false); if (q !== H.q) return; await render(); window.scrollTo(0, y); };
    host.querySelectorAll('[data-hid]').forEach(b => b.onclick = async () => { H.scroll = window.scrollY; H.detail = { id: b.dataset.hid }; await render(); window.scrollTo(0, 0); });
    if (H.restoreScroll != null) { const y = H.restoreScroll; H.restoreScroll = null; requestAnimationFrame(() => window.scrollTo(0, y)); }
  }
  async function histDetail(m) {
    const H = st.hist;
    let r = null, err = null; try { r = await api.comRequestDetail(H.detail.id); } catch (e) { err = errMsg(e); }
    if (disposed) return;
    m.innerHTML = '<button class="btn outline" type="button" id="hBack">← Volver al listado</button>' +
      (err ? '<div class="note warn" style="margin-top:10px">' + esc(err) + '</div>' : '<div style="margin-top:12px">' + details(r) + '</div>');
    $('#hBack').onclick = () => { H.detail = null; H.restoreScroll = H.scroll; render(); };   // vuelve SIN recargar: mismos filtros, mismo listado y posición
  }
  async function vGerencia(m) {
    const all = await api.comList('BANDEJA', st.invFilter === 'TODAS' ? null : st.invFilter), pend = all.filter(x => x.status === 'PENDIENTE').length;
    const r = (st.sel && all.find(x => x.id === st.sel)) || all[0];
    let fin = ''; if (r) { try { const f = await api.comClientFinance(r.client.id); if (f && f.cc_disponible !== undefined) { const nv = f.cc_verificacion !== 'VERIFICADO';   // punto 4: el saldo importado se muestra con su ORIGEN y su estado de VERIFICACIÓN
        fin = '<div class="fin-box" data-cc-verif="' + (nv ? 'NO_VERIFICADO' : 'VERIFICADO') + '"><span class="label">SALDO DE CUENTA CORRIENTE INFORMADO POR CIANBOX · ' + (nv ? '<b style="color:#b42318">NO VERIFICADO (no conciliado)</b>' : 'VERIFICADO') + '</span>' +
          '<div><b>' + (f.cc_disponible ? money(f.cc_saldo) : 'Sin dato') + '</b> <small class="micro">· corte ' + esc(f.cc_fecha_corte || when(f.cc_fecha)) + (f.cc_archivo ? ' · archivo ' + esc(f.cc_archivo) : '') + '</small></div>' +
          '<small class="micro">Complementario: no es facturación ni el importe solicitado o autorizado.</small>' +
          (f.pendientes && f.pendientes.length ? '<small class="micro">Saldo informado por comprobante' + (nv ? ' (no verificado)' : '') + ': ' + f.pendientes.slice(0, 6).map(p => esc(p.comprobante) + ' ' + money(p.saldo)).join(' · ') + '</small>' : '') + '</div>'; } } catch (e) { } }
    const sup = r && r.assigned_approver_id !== me.id;
    const actions = r && r.status === 'PENDIENTE' ? (sup ? '<div class="note warn" style="margin-top:12px">Asignada a <b>' + esc(r.assigned_approver) + '</b>. Vas a resolver como <b>Administrador General (suplencia)</b>: queda registrado.</div>' : '') +
      '<div class="row" style="gap:8px;flex-wrap:wrap;margin-top:12px"><button class="btn primary" type="button" data-dec="APROBAR">✓ Aprobar</button><button class="btn secondary" type="button" data-dec="APROBAR_CON_CAMBIOS">Aprobar con cambios</button><button class="btn outline" type="button" data-dec="DEVOLVER">Devolver</button><button class="btn danger" type="button" data-dec="RECHAZAR">Rechazar</button></div>' : '';
    m.innerHTML = head('ROL GERENCIA / TESORERÍA', 'Aprobaciones recibidas', cfg.is_admin ? 'Como Administrador General ves también las pendientes de otros aprobadores y podés resolverlas (suplencia).' : 'Solicitudes asignadas a vos. Cada decisión queda en la trazabilidad.',
      '<span class="pill pending">' + pend + ' pendientes</span>') +
      '<div class="grid two"><section class="card"><div class="sectionhead"><h2>Bandeja de solicitudes</h2><select id="gFilter"><option value="PENDIENTE"' + (st.invFilter === 'PENDIENTE' ? ' selected' : '') + '>Pendientes</option><option value="TODAS"' + (st.invFilter === 'TODAS' ? ' selected' : '') + '>Todas</option></select></div>' +
      '<div class="requests">' + requestList(all, r && r.id, me.id) + '</div></section><section class="card">' + (r ? details(r, { kpi: true, finance: fin, actions }) : '<p class="micro">Sin solicitudes.</p>') + '</section></div>';
    $('#gFilter').onchange = e => { st.invFilter = e.target.value; st.sel = null; render(); };
    host.querySelectorAll('[data-select]').forEach(b => b.onclick = () => { st.sel = b.dataset.select; render(); });
    host.querySelectorAll('[data-dec]').forEach(b => b.onclick = () => decide(r, b.dataset.dec));
  }
  function decide(r, dec) {
    const t = r.current_terms, s = cfg.settings, maxK = Math.floor(s.fin_max_days / 7), base = String(r.created_at).slice(0, 10), change = ['APROBAR_CON_CAMBIOS', 'DEVOLVER'].includes(dec);
    const title = { APROBAR: 'Aprobar', APROBAR_CON_CAMBIOS: 'Aprobar con cambios', DEVOLVER: 'Devolver con modificaciones', RECHAZAR: 'Rechazar' }[dec];
    $('#comModal').innerHTML = '<div class="modalbg"><div class="modal"><div class="sectionhead"><h2>' + title + ' · ' + esc(r.number) + '</h2><button class="btn outline" type="button" data-close>✕</button></div>' +
      (change ? '<div class="fg"><label class="field"><span>IMPORTE</span><input class="input" id="dAmount" inputmode="numeric" value="' + Math.round(t.amount) + '"></label>' +
        (r.kind === 'FINANCIACION' ? '<div class="spanall"><span class="label">Calendario SOLICITADO por el Comercial</span>' + calList((r.original_terms || t).schedule) + '</div>' +
          calForm('d', { k: t.installments, freq: t.frequency || (t.installments > 1 ? 'SEMANAL' : ''), first: t.first_due || (t.schedule && t.schedule[0] && t.schedule[0].due), base: arDate(r.created_at) })
          : '<label class="field"><span>VENCIMIENTO</span><input class="input" type="date" id="dDue" value="' + esc(t.due_date) + '" min="' + base + '" max="' + addDays(base, s.cheq_max_days) + '"></label>') + '</div>' : '<p>' + money(t.amount) + ' · ' + terms(r.kind, t) + '</p>') +
      (dec !== 'APROBAR' ? '<label class="field"><span>MOTIVO (obligatorio)</span><textarea class="input" id="dReason" rows="2" maxlength="400"></textarea></label>' : '') +
      '<button class="btn primary wfull" type="button" id="dGo">Confirmar decisión</button></div></div>';
    $('[data-close]').onclick = () => { $('#comModal').innerHTML = ''; };
    if (change && r.kind === 'FINANCIACION') {   // el aprobador edita el MISMO calendario; límite desde la creación ORIGINAL (fecha argentina)
      const dAmt = () => Number(String($('#dAmount').value).replace(/\D/g, '')) || 0;
      const dUpd = calWire('d', arDate(r.created_at), dAmt, c => { $('#dGo').disabled = !c.ok; $('#dGo').title = c.ok ? '' : c.error.message; });
      $('#dAmount').oninput = dUpd; dUpd();
    }
    $('#dGo').onclick = async () => {
      const dk = $('#dInst') ? Number($('#dInst').value) : 0;
      const nt = change ? (r.kind === 'FINANCIACION' ? { amount: Number(String($('#dAmount').value).replace(/\D/g, '')), installments: dk, first_due: $('#dFirst').value, ...(dk > 1 ? { frequency: $('#dFreq').value } : {}) } : { amount: Number(String($('#dAmount').value).replace(/\D/g, '')), due_date: $('#dDue').value, issuer_name: t.issuer_is_client ? '' : t.issuer_name, issuer_cuit: t.issuer_is_client ? '' : t.issuer_cuit }) : null;
      $('#dGo').disabled = true;
      try { await api.comDecide(r.id, r.version, dec, nt, $('#dReason') ? $('#dReason').value.trim() : null); $('#comModal').innerHTML = ''; toast('Decisión registrada.'); render(); }
      catch (e) { toast(errMsg(e), true); $('#dGo').disabled = false; if (/CONFLICT/.test(String(e.message))) { $('#comModal').innerHTML = ''; render(); } }
    };
  }
  async function vDespacho(m) {
    const L = await api.comTrack(st.search, st.open), r = (st.sel && L.find(x => x.id === st.sel)) || L[0];
    m.innerHTML = head('ROL OPERARIO DE DESPACHO', 'Seguimiento de aprobaciones', 'Buscá por cliente, CUIT, pedido o autorización. El estado final aparece en una sola pantalla.', '<span class="pill neutral">Vista solo lectura</span>') +
      '<div class="card" style="margin-bottom:14px"><div class="fg"><label class="field"><span>BUSCAR</span><input class="input" id="tSearch" placeholder="Cliente, pedido, CUIT o AUT-..." value="' + esc(st.search) + '"></label>' +
      '<label class="field"><span>ESTADO</span><select id="tFilter"><option value="0"' + (st.open ? '' : ' selected') + '>Todas las autorizaciones</option><option value="1"' + (st.open ? ' selected' : '') + '>Aprobaciones en curso</option></select></label></div></div>' +
      '<div class="grid two"><section class="card"><div class="sectionhead"><h2>Resultados (' + L.length + ')</h2><span class="micro">Actualización automática</span></div><div class="requests">' + requestList(L, r && r.id) + '</div></section>' +
      '<section class="card">' + (r ? details(r, { urgent: true }) : '<p class="micro">Sin resultados.</p>') + '</section></div>';
    if (r) wireUrgent(r);
    let tmr; $('#tSearch').oninput = e => { st.search = e.target.value; clearTimeout(tmr); tmr = setTimeout(() => { st.sel = null; render().then(() => { const i = $('#tSearch'); if (i) { i.focus(); i.setSelectionRange(i.value.length, i.value.length); } }); }, 350); };
    $('#tFilter').onchange = e => { st.open = e.target.value === '1'; st.sel = null; render(); };
    host.querySelectorAll('[data-select]').forEach(b => b.onclick = () => { st.sel = b.dataset.select; render(); });
  }
  // ---------- ALARMA URGENTE DESDE LA SOLICITUD ----------
  const URG_KEY = id => 'okd_com_urgent:' + id;
  const urgIntent = id => { try { return JSON.parse(sessionStorage.getItem(URG_KEY(id)) || 'null'); } catch (e) { return null; } };
  const urgSave = (id, v) => { try { v ? sessionStorage.setItem(URG_KEY(id), JSON.stringify(v)) : sessionStorage.removeItem(URG_KEY(id)); } catch (e) { } };
  const hm = s => s ? new Date(s).toLocaleString('es-AR', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' }) : '';
  function urgStatusHtml(al) {
    if (!al) return '';
    if (al.status === 'PENDIENTE_ATENCION') return '<div class="note warn" data-urg-estado="PENDIENTE"><b>Alarma enviada · Pendiente de atención</b> · ' + esc(al.number) + ' · pedida por ' + esc(al.raised_by || '') + ' el ' + hm(al.raised_at) +
      (al.escalated_at ? ' · <b>ESCALADA</b> el ' + hm(al.escalated_at) : '') + '</div>';
    if (al.status === 'ATENDIDA') return '<div class="note ok" data-urg-estado="ATENDIDA"><b>Alarma atendida</b> · ' + esc(al.number) + ' · por <b>' + esc(al.attended_by || '') + '</b> el ' + hm(al.attended_at) + '</div>';
    return '<div class="note" data-urg-estado="' + esc(al.status) + '">Alarma ' + esc(al.number) + ' · ' + esc(al.status) + '</div>';
  }
  async function wireUrgent(r) {
    const slot = $('#rUrgent'); if (!slot || !api.comRequestAlarm || !(cfg.can_track || cfg.is_admin)) return;
    let al = null; try { al = await api.comRequestAlarm(r.id); } catch (e) { slot.innerHTML = '<p class="micro">No se pudo consultar la alarma: ' + esc(errMsg(e)) + '</p>'; return; }
    if (disposed || !document.body.contains(slot)) return;
    const puede = r.status === 'PENDIENTE' && !(al && al.status === 'PENDIENTE_ATENCION');
    slot.innerHTML = urgStatusHtml(al) + (puede ? '<button class="btn danger wfull" type="button" id="rUrgentBtn" style="min-height:48px">⚠ Solicitar aprobación urgente</button>' : '');
    if (puede) $('#rUrgentBtn').onclick = () => openUrgent(r);
  }
  function openUrgent(r) {
    // abrir NO envía nada: el motivo se confirma; la operación tiene un identificador ESTABLE que se conserva en los reintentos
    const it = urgIntent(r.id) || { reason: '', op: 'sol-' + r.id.slice(0, 8) + '-' + Date.now().toString(36) + Math.random().toString(36).slice(2, 8) };
    $('#comModal').innerHTML = '<div class="modalbg"><div class="modal" role="dialog" aria-modal="true" data-urg-modal><div class="sectionhead"><h2>Solicitar aprobación urgente</h2></div>' +
      '<p class="micro">Autorización <b>' + esc(r.number) + '</b> · ' + esc(r.client.razon_social) + '</p><p class="micro">Se avisa al responsable configurado; si nadie la atiende en 3 minutos, se escala.</p>' +
      '<label class="field"><span>MOTIVO (obligatorio)</span><textarea class="input" id="uReason" rows="3" maxlength="400" placeholder="Ej.: el cliente está esperando para cargar">' + esc(it.reason) + '</textarea></label>' +
      '<div class="note" id="uMsg" hidden></div>' +
      '<button class="btn primary wfull" type="button" id="uGo" style="min-height:48px;margin-top:10px">Confirmar y enviar alarma</button>' +
      '<button class="btn outline wfull" type="button" id="uCancel" style="min-height:48px;margin-top:8px">Cancelar</button></div></div>';
    const card = $('#comModal [data-urg-modal]'), ta = $('#uReason'), msg = (t, cls) => { const e = $('#uMsg'); e.hidden = !t; e.className = 'note ' + (cls || 'warn'); e.innerHTML = t || ''; };
    const mark = () => { if (ta.value.trim()) card.setAttribute('data-okd-unsaved', '1'); else card.removeAttribute('data-okd-unsaved'); };
    ta.oninput = mark; mark(); ta.focus();
    $('#uCancel').onclick = () => { if (!it.sent) urgSave(r.id, null); $('#comModal').innerHTML = ''; };   // cancelar no genera avisos
    let busy = false;
    $('#uGo').onclick = async () => {
      if (busy) return; const reason = ta.value.trim();
      if (reason.length < 10) { msg('Indicá el motivo (al menos 10 caracteres).'); ta.focus(); return; }
      busy = true; $('#uGo').disabled = true; it.reason = reason; urgSave(r.id, it); msg('Enviando…', '');
      try {
        const res = await api.comAlarmRaiseRequest(r.id, reason, it.op);
        if (res && res.ok) {   // SOLO con el registro del servidor se confirma
          urgSave(r.id, null); $('#comModal').innerHTML = '';
          toast(res.existing ? 'Ya había una alarma activa para esta autorización · Pendiente de atención' : 'Alarma enviada · Pendiente de atención');
          await render(); return;
        }
        if (res && res.code === 'NOT_PENDING') { urgSave(r.id, null); msg(esc(res.message) + ' <button class="btn outline" type="button" id="uSee">Ver estado actual</button>');
          $('#uGo').hidden = true; $('#uSee').onclick = async () => { $('#comModal').innerHTML = ''; await render(); }; busy = false; return; }
        if (res && res.code === 'OP_ID_CONFLICT') it.op = 'sol-' + r.id.slice(0, 8) + '-' + Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
        urgSave(r.id, it); msg('NO SE ENVIÓ: ' + esc((res && res.message) || 'respuesta inesperada') + '. Tu motivo quedó guardado; podés reintentar.');
      } catch (e) {
        it.sent = true; urgSave(r.id, it);   // sin respuesta: el reintento usa la MISMA operación (nunca duplica)
        msg('SIN RESPUESTA DEL SERVIDOR (' + esc(errMsg(e)) + '). Tu motivo quedó guardado: tocá «Confirmar» para reintentar; no se va a duplicar.');
      }
      busy = false; $('#uGo').disabled = false;
    };
  }
  async function vAlarmaSol(m, alarmId) {
    let d; try { d = await api.comAlarmRequestDetail(alarmId); } catch (e) { m.innerHTML = '<div class="note warn">' + esc(errMsg(e)) + '</div><button class="btn outline" type="button" id="aBack">Volver</button>'; $('#aBack').onclick = () => { location.hash = '#/autorizaciones'; }; return; }
    const a = d.alarm, r = d.request;
    m.innerHTML = head('DESDE LA ALARMA URGENTE', 'Autorización ' + esc(r.number), 'Abierta desde la alarma ' + esc(a.number) + '. Atender la alarma no aprueba ni rechaza: la decisión comercial se toma aparte.', '<button class="btn outline" type="button" id="aBack">← Volver</button>') +
      '<section class="card" data-alarma-sol="' + esc(r.id) + '">' + urgStatusHtml({ ...a, raised_by: a.raised_by, attended_by: a.attended_by }) + details(r, {}) + '</section>';
    $('#aBack').onclick = () => { location.hash = '#/autorizaciones'; };
  }
  async function vGeneral(m) {
    const [c, src, ap, al, ps] = await Promise.all([api.comConfig(), api.comSourcesStatus(), api.comApprovers(), api.comAlarmSettings ? api.comAlarmSettings().catch(() => null) : null, api.comAlarmPushStatus ? api.comAlarmPushStatus().catch(() => null) : null]), s = c.settings; cfg = c;
    const mailSettings = api.comMailSettings ? await api.comMailSettings().catch(() => null) : null;
    const alI = (al && al.initial_user) || '', alE = new Set((al && al.escalation_users) || []);   // B-AL-03: lo GUARDADO se muestra seleccionado
    const opts = sel => '<option value="">— sin asignar —</option>' + ap.map(u => '<option value="' + esc(u.id) + '"' + (u.id === sel ? ' selected' : '') + '>' + esc(u.name) + '</option>').join('');
    const CH = { 'SUCURSAL:MONTECASEROS': 'Sucursal Montecaseros', 'SUCURSAL:SAN_JUAN': 'Sucursal San Juan', CARTERA: 'Vendedores de cartera' };
    m.innerHTML = head('ADMINISTRADOR GENERAL', 'Panel General · Autorizaciones', 'Configuración del KPI, aprobadores, asignaciones, padrón y estado de las cargas de Depósito.') +
      '<div class="grid two"><section class="card"><div class="sectionhead"><h2>KPI sugerido de financiación propia</h2></div><div class="fg">' +
      '<label class="field"><span>MESES DEL PROMEDIO</span><select id="sMonths">' + [1, 2, 3, 6].map(n => '<option' + (n === s.kpi_months ? ' selected' : '') + '>' + n + '</option>').join('') + '</select></label>' +
      '<label class="field"><span>PISO SUGERIDO %</span><input class="input" id="sFloor" inputmode="numeric" value="' + s.floor_pct + '"></label><label class="field"><span>TECHO SUGERIDO %</span><input class="input" id="sCeil" inputmode="numeric" value="' + s.ceiling_pct + '"></label>' +
      '<label class="field"><span>MESES SIN CARGAS COMPLETAS</span><select id="sRule"><option value="NO_CALCULAR"' + (s.kpi_partial_rule === 'NO_CALCULAR' ? ' selected' : '') + '>No calcular (sin historial suficiente)</option><option value="PROMEDIO_MESES_CUBIERTOS"' + (s.kpi_partial_rule === 'PROMEDIO_MESES_CUBIERTOS' ? ' selected' : '') + '>Promediar solo los meses con cargas</option></select></label>' +
      '<label class="field spanall"><span><input type="checkbox" id="sVerified"' + (s.kpi_source_verified ? ' checked' : '') + '> Fuente verificada: «Saldo comprobante» incluye TODAS las operaciones (quita la etiqueta de recomendación provisoria)</span></label></div>' +
      '<button class="btn primary" type="button" id="sSave">Guardar parámetros</button></section>' +
      '<section class="card"><div class="sectionhead"><h2>Aprobadores por canal</h2></div>' + Object.keys(CH).map(k => '<label class="field"><span>' + CH[k] + '</span><select data-route="' + k + '">' + opts((c.routing.find(x => x.channel_key === k) || {}).approver_user_id) + '</select></label>').join('') +
      '<p class="micro">Los Administradores Generales activos pueden resolver también las pendientes de cualquier aprobador (suplencia registrada).</p></section></div>' +
      '<section class="card" style="margin-top:14px"><div class="sectionhead"><h2>Usuarios Comerciales · sucursal o cartera</h2></div><div class="tablewrap"><table class="tbl"><thead><tr><th>Usuario</th><th>Canal</th><th>Sucursal / cartera</th><th></th></tr></thead><tbody>' +
      (c.assignments || []).map(u => '<tr data-u="' + esc(u.user_id) + '"><td>' + esc(u.name) + '</td><td><select data-ch><option value="SUCURSAL"' + (u.channel === 'SUCURSAL' ? ' selected' : '') + '>Sucursal</option><option value="CARTERA"' + (u.channel === 'CARTERA' ? ' selected' : '') + '>Cartera</option></select></td>' +
        '<td><select data-br><option value="MONTECASEROS"' + (u.branch === 'MONTECASEROS' ? ' selected' : '') + '>Montecaseros</option><option value="SAN_JUAN"' + (u.branch === 'SAN_JUAN' ? ' selected' : '') + '>San Juan</option></select> <input class="input" data-ca placeholder="Cartera (p. ej. Hernán)" value="' + esc(u.cartera_label || '') + '"></td><td><button class="btn outline" type="button" data-asg>Guardar</button></td></tr>').join('') +
      '</tbody></table></div></section>' +
      '<section class="card" style="margin-top:14px"><div class="sectionhead"><h2>Cargas de Depósito (automáticas)</h2><span class="micro">Sin carga manual: llegan desde el Constructor</span></div><div class="fg">' +
      '<div><span class="label">Última «Saldo comprobante»</span><div><b>' + (src.ultima_sc ? when(src.ultima_sc.at) : 'Sin cargas') + '</b><small style="display:block" class="micro">' + esc(src.ultima_sc ? src.ultima_sc.archivo || '' : '') + '</small></div></div>' +
      '<div><span class="label">Última «Saldo cuenta corriente»</span><div><b>' + (src.ultima_cc ? when(src.ultima_cc.at) : 'Sin cargas') + '</b><small style="display:block" class="micro">' + esc(src.ultima_cc ? src.ultima_cc.archivo || '' : '') + '</small></div></div>' +
      '<div><span class="label">Meses con cargas</span><div><b>' + esc((src.meses_cubiertos || []).map(x => String(x).slice(0, 7)).join(' · ') || '—') + '</b></div></div>' +
      '<div><span class="label">Clientes sin historial</span><div><b>' + (src.clientes_sin_historial ?? '—') + '</b></div></div></div>' +
      (src.ultima_sc && (Date.now() - new Date(src.ultima_sc.at)) > 3 * 864e5 ? '<div class="note warn">Sincronización ATRASADA: la última carga recibida tiene más de 3 días.</div>' : '') +
      ((src.errores || []).length ? '<div class="note warn"><b>Sincronizaciones con error:</b> ' + src.errores.slice(0, 4).map(e => esc(e.kind + ' · ' + (e.archivo || '') + ' · ' + when(e.at) + ' · ' + e.error)).join('<br>') + '</div>' : '') +
      '<h3>Incidencias de conciliación</h3><p class="micro">' + (Object.entries(src.incidencias || {}).map(([k, n]) => esc(k.replace(/_/g, ' ')) + ': <b>' + n + '</b>').join(' · ') || 'Sin incidencias abiertas.') + '</p>' +
      '<h3>Tipos de comprobante</h3><div class="row" style="gap:8px;flex-wrap:wrap">' + (src.tipos || []).map(t => '<span class="chip">' + esc(t.prefijo) + ' · ' + esc(t.clase) + '</span>').join('') + '</div>' +
      '<div class="row" style="gap:8px;flex-wrap:wrap;margin-top:8px"><input class="input" id="tPre" maxlength="3" placeholder="Prefijo (p. ej. NDC)" style="max-width:150px"><select id="tCls"><option>VENTA</option><option>NOTA_CREDITO</option><option>PAGO</option><option>ANULACION</option><option>EXCLUIDO</option></select><button class="btn outline" type="button" id="tSave">Clasificar</button></div></section>' +
      '<section class="card" style="margin-top:14px"><div class="sectionhead"><h2>KPI financiero</h2><span class="micro">Hasta verificar los informes de Cianbox</span></div>' +
      '<label class="field"><span>MODO DEL KPI</span><select id="kMode"><option value="PROVISORIO"' + (s.kpi_mode === 'PROVISORIO' ? ' selected' : '') + '>Provisorio (requiere autorización expresa de Dirección General)</option>' +
      '<option value="DESHABILITADO"' + (s.kpi_mode !== 'PROVISORIO' ? ' selected' : '') + '>Deshabilitado (predeterminado: no se calcula ni se muestra; autorización manual)</option></select></label>' +
      '<button class="btn outline" type="button" id="kSave">Guardar modo del KPI</button></section>' +
      '<section class="card" style="margin-top:14px"><div class="sectionhead"><h2>Alarma urgente</h2><span class="micro">Escalamiento automático del SERVIDOR a los 3 minutos sin atención</span></div><div class="fg">' +
      '<label class="field"><span>DESTINATARIO INICIAL (obligatorio)</span><select id="alIni"><option value="">— elegí —</option>' + ap.map(u => '<option value="' + esc(u.id) + '"' + (u.id === alI ? ' selected' : '') + '>' + esc(u.name) + '</option>').join('') + '</select></label>' +
      '<label class="field"><span>ESCALAMIENTO A LOS 3 MINUTOS (obligatorio · solo Administradores Generales activos)</span><select id="alEsc" multiple size="3">' + ap.filter(u => /Administrador General/.test(u.name)).map(u => '<option value="' + esc(u.id) + '"' + (alE.has(u.id) ? ' selected' : '') + '>' + esc(u.name) + '</option>').join('') + '</select></label></div>' +
      '<p class="micro" id="alEff">Efectivos ahora: inicial <b>' + esc((al && al.efectivos && al.efectivos.inicial) || '—') + '</b> · escalamiento <b>' + esc(((al && al.efectivos && al.efectivos.escalamiento) || []).join(', ') || '—') + '</b>. No se amplía automáticamente a otros usuarios.</p>' +
      (al && al.problemas && al.problemas.length ? '<div class="banner" id="alProb" style="margin:6px 0">⚠ ' + al.problemas.map(esc).join(' · ') + '</div>' : '') +
      '<p class="micro" id="alPush">Push con la app cerrada (dispositivos registrados): ' + (Array.isArray(ps) && ps.length ? ps.map(x => '<b>' + esc(String(x.usuario || '').split(' — ')[0]) + '</b> ' +
        (x.dispositivos_activos > 0 ? x.dispositivos_activos + ' activo(s)' : '<span style="color:#b42318">ninguno</span>')).join(' · ') : '—') + '. El sonido de la app no reemplaza la suscripción push.</p>' +
      '<button class="btn outline" type="button" id="alSave">Guardar destinatarios</button> <span class="micro" id="alRes"></span></section>' +
      renderMailPanel(mailSettings) +
      '<section class="card" style="margin-top:14px"><div class="sectionhead"><h2>Padrón de clientes</h2><span class="micro">listado_clientes.xlsx · sin duplicar, con historial</span></div><input type="file" id="pFile" accept=".xlsx,.xls"><div id="pRes" class="micro"></div></section>' +
      '<section class="card" style="margin-top:14px"><div class="sectionhead"><h2>Score externo · futuro</h2></div><p class="micro">XFact / Veraz: integración preparada para el futuro. No se consulta ningún servicio externo ni se simula una consulta oficial.</p></section>';
    $('#comMailSave').onclick=async()=>{const b=$('#comMailSave'),v=mailCopiesToSave($('#comMailCopies').value,(mailSettings&&mailSettings.copies)||[],$('#comMailAuth').checked);if(v.error){$('#comMailResult').textContent=v.error;return;}b.disabled=true;try{await api.comSetMailCopies(v.list);if(mailSettings)mailSettings.copies=v.list;$('#comMailAuth').checked=false;$('#comMailResult').textContent='Destinatarios guardados (cambio auditado). El solicitante sigue recibiendo su aviso.';}catch(e){$('#comMailResult').textContent=String(e.message||e).includes('INVALID_EMAIL')?'Revisá las direcciones: hay un correo inválido o demasiados destinatarios (máximo 20).':errMsg(e);}finally{b.disabled=false;}};
    $('#sSave').onclick = async () => { try { cfg.settings = await api.comSetSettings({ kpi_months: Number($('#sMonths').value), floor_pct: Number($('#sFloor').value), ceiling_pct: Number($('#sCeil').value), kpi_partial_rule: $('#sRule').value, kpi_source_verified: $('#sVerified').checked }); toast('Parámetros guardados.'); } catch (e) { toast(errMsg(e), true); } };
    host.querySelectorAll('[data-route]').forEach(sel => sel.onchange = async () => { try { await api.comSetRouting(sel.dataset.route, sel.value || null); toast('Aprobador actualizado.'); } catch (e) { toast(errMsg(e), true); render(); } });
    host.querySelectorAll('[data-asg]').forEach(b => b.onclick = async () => { const tr = b.closest('tr'); try { await api.comSetAssignment(tr.dataset.u, tr.querySelector('[data-ch]').value, tr.querySelector('[data-br]').value, tr.querySelector('[data-ca]').value); toast('Asignación guardada.'); } catch (e) { toast(errMsg(e), true); } });
    $('#kSave').onclick = async () => { const v = $('#kMode').value; if (v === (s.kpi_mode || 'DESHABILITADO')) { toast('Sin cambios en el modo del KPI.'); return; }
      let aut = null;
      if (v === 'PROVISORIO') { aut = prompt('Reactivar el KPI requiere la AUTORIZACIÓN EXPRESA de Dirección General.\nIndicá la referencia (número de resolución o acta, fecha y firmante):'); if (aut == null) return; }
      else if (!confirm('¿Deshabilitar el KPI? No se calculará ni se mostrará ninguna cifra.')) return;
      try { await api.comSetKpiMode(v, aut); toast('Modo del KPI guardado (auditado).'); vGeneral(m); } catch (e) { toast(errMsg(e), true); } };
    $('#alSave').onclick = async () => {
      const ini = $('#alIni').value || null, escs = [...$('#alEsc').selectedOptions].map(o => o.value);
      if (!ini || !escs.length) { toast('Elegí el destinatario inicial y al menos un destinatario de escalamiento.', true); return; }
      const changed = ini !== alI || escs.length !== alE.size || escs.some(x => !alE.has(x));
      if (!changed) { toast('Sin cambios en los destinatarios.'); return; }
      const nm = id => ((ap.find(u => u.id === id) || {}).name || id).split(' — ')[0];
      if (!confirm('¿Cambiar los destinatarios de la alarma urgente?\n\nInicial: ' + nm(ini) + '\nEscalamiento: ' + escs.map(nm).join(', '))) return;
      try { const r = await api.comSetAlarmSettings({ initial_user: ini, escalation_users: escs });
        $('#alRes').textContent = 'Guardado. Inicial: ' + ((r.efectivos && r.efectivos.inicial) || '—') + ' · Escalamiento: ' + (((r.efectivos && r.efectivos.escalamiento) || []).join(', ') || '—');
        toast('Destinatarios de la alarma guardados (auditado).'); vGeneral(m); } catch (e) { toast(errMsg(e), true); } };
    $('#tSave').onclick = async () => { try { await api.comSetCompType($('#tPre').value.trim(), $('#tCls').value); toast('Tipo clasificado.'); render(); } catch (e) { toast(errMsg(e), true); } };
    $('#pFile').onchange = async e => {
      const f = e.target.files[0]; if (!f) return; const out = $('#pRes'); out.textContent = 'Leyendo ' + f.name + '…';
      try {
        if (!window.XLSX) await new Promise((ok, ko) => { const sc = document.createElement('script'); sc.src = '/legacy/xlsx.full.min.js'; sc.onload = ok; sc.onerror = () => ko(new Error('No se pudo cargar el lector de Excel.')); document.head.appendChild(sc); });
        const buf = await f.arrayBuffer(), wb = window.XLSX.read(buf, { type: 'array' }), rows = window.XLSX.utils.sheet_to_json(wb.Sheets[wb.SheetNames[0]], { defval: null, raw: false });
        const M = { erp_id: 'ID', razon_social: 'Razón Social', nombre: 'Nombre', cond_fiscal: 'Cond. Fiscal', doc_type: 'Tipo Doc.', doc_number: 'Número', localidad: 'Localidad', provincia: 'Provincia', email: 'eMail', vendedor: 'Vendedor', zona: 'Zona', categoria: 'Categoría', cod_interno: 'Cód.Interno' };
        const data = rows.map((r, i) => Object.assign({ _row: i + 2 }, Object.fromEntries(Object.entries(M).map(([k, h]) => [k, r[h] == null ? null : String(r[h]).trim()]))));
        const h = await crypto.subtle.digest('SHA-256', buf), sha = Array.from(new Uint8Array(h), x => x.toString(16).padStart(2, '0')).join('');
        const res = await api.comImportClients(f.name, sha, data);
        out.innerHTML = '<b>Importado:</b> ' + res.filas + ' filas · nuevos ' + res.nuevos + ' · actualizados ' + res.actualizados + ' · sin cambios ' + res.sin_cambios + ' · rechazados ' + res.rechazados + ' · en revisión ' + res.en_revision + ' · total ' + res.total;
      } catch (x) { out.textContent = errMsg(x); }
    };
  }
  async function vInformes(m) {
    const to = ymd(new Date()), from = st.from || addDays(to, -90), [rp, ds, alh] = await Promise.all([api.comReport(from, st.to || to), api.comDispatchStats(from, st.to || to), st.alhKeep ? Promise.resolve(null) : api.comAlarmHistoryPage ? api.comAlarmHistoryPage(from, st.to || to, null, 25).catch(() => ({ items: [] })) : (api.comAlarmHistory ? api.comAlarmHistory(from, st.to || to).then(x => ({ items: x })).catch(() => ({ items: [] })) : { items: [] })]);
    if (alh) st.alh = { items: alh.items || [], cursor: alh.next_cursor || null, more: !!alh.has_more, from, to: st.to || to };   // con «Cargar más» se CONSERVA lo acumulado
    const T = (cols, rows) => '<div class="tablewrap"><table class="tbl"><thead><tr>' + cols.map(c => '<th>' + c[0] + '</th>').join('') + '</tr></thead><tbody>' + (rows.map(r => '<tr>' + cols.map(c => '<td>' + c[1](r) + '</td>').join('') + '</tr>').join('') || '<tr><td colspan="' + cols.length + '">Sin datos en el período.</td></tr>') + '</tbody></table></div>';
    m.innerHTML = head('INFORMES', 'Informe de decisiones comerciales', 'Solicitado vs. autorizado, tiempos de resolución, canales, clientes y evolución. «Concretado» solo con fuente que lo acredite.') +
      '<div class="card" style="margin-bottom:14px"><div class="fg"><label class="field"><span>DESDE</span><input class="input" type="date" id="iFrom" value="' + from + '"></label><label class="field"><span>HASTA</span><input class="input" type="date" id="iTo" value="' + (st.to || to) + '"></label></div><button class="btn outline" type="button" id="iCsv">↓ Exportar CSV</button></div>' +
      '<section class="card"><h2>Por tipo y estado</h2>' + T([['Tipo', r => esc(TYPE[r.tipo] || r.tipo)], ['Estado', r => pill(r.estado)], ['Cantidad', r => r.cantidad], ['Solicitado', r => money(r.solicitado)], ['Autorizado', r => money(r.autorizado)]], rp.por_tipo_estado) +
      '<p class="micro">Concretado: ' + esc(rp.concretado || 'sin fuente que lo acredite') + '</p></section>' +
      '<section class="card" style="margin-top:14px"><h2>Aprobaciones por aprobador</h2>' + T([['Asignado', r => esc(r.asignado || '—')], ['Resolvió', r => esc(r.resuelto_por || '—')], ['Como', r => esc(r.como === 'SUPLENTE_ADMIN' ? 'Suplencia (Administrador General)' : r.como || '—')], ['Cantidad', r => r.cantidad], ['Horas promedio', r => r.horas_promedio ?? '—']], rp.por_aprobador) + '</section>' +
      '<div class="grid two" style="margin-top:14px"><section class="card"><h2>Por canal</h2>' + T([['Canal', r => esc(r.canal)], ['Sucursal / cartera', r => esc(r.sucursal || r.cartera || '—')], ['Cantidad', r => r.cantidad], ['Autorizado', r => money(r.autorizado)]], rp.por_canal) + '</section>' +
      '<section class="card"><h2>Evolución mensual</h2>' + T([['Mes', r => esc(r.mes)], ['Cantidad', r => r.cantidad], ['Solicitado', r => money(r.solicitado)], ['Autorizado', r => money(r.autorizado)]], rp.por_mes || []) + '</section></div>' +
      '<section class="card" style="margin-top:14px"><h2>Vencimientos autorizados</h2>' + T([['Autorización', r => esc(r.numero)], ['Cliente', r => esc(r.cliente)], ['Tipo', r => esc(TYPE[r.tipo] || r.tipo)], ['Importe', r => money(r.importe)], ['Vence', r => dmy(r.vence)]], rp.vencimientos) + '</section>' +
      '<section class="card" style="margin-top:14px"><h2>Alarmas urgentes</h2><p class="micro">Historial inmutable: activación, destinatarios, escalamiento, atención y resolución comercial.</p>' +
      T([['Alarma', r => esc(r.number)], ['Pedido · hoja', r => esc(r.order_ref + ' · ' + r.sheet_key)], ['Solicitó', r => esc(String(r.raised_by || '').split(' — ')[0]) + ' · ' + when(r.raised_at)],
         ['Inicial', r => esc(String(r.initial_user || '').split(' — ')[0])], ['Escalada', r => r.escalated_at ? when(r.escalated_at) + ' → ' + esc((r.escalated_to || []).map(x => String(x).split(' — ')[0]).join(', ')) : '—'],
         ['Atendió', r => r.attended_at ? esc(String(r.attended_by || '').split(' — ')[0]) + ' · ' + when(r.attended_at) + ' (' + r.seconds_to_attend + ' s)' : '<b>' + esc(r.status) + '</b>'],
         ['Resolución comercial', r => r.resolucion_comercial ? esc(r.resolucion_comercial.estado + (r.resolucion_comercial.resolvio ? ' · ' + String(r.resolucion_comercial.resolvio).split(' — ')[0] : '')) : '—']], st.alh.items) + '<p class="micro" id="alhCount">' + st.alh.items.length + ' alarma(s) · ' + (st.alh.more ? '<b>quedan más</b>' : 'no hay más') + '</p>' +
         (st.alh.more ? '<button class="btn outline" type="button" id="alhMore">Cargar más alarmas</button>' : '') + '</section>' +
      '<section class="card" style="margin-top:14px"><h2>Despachos por transportista y zona</h2><p class="micro">Solo hojas reales publicadas en el período (sin destinos ni métricas inventadas).</p>' +
      T([['Transportista', r => esc(r.transportista)], ['Zona', r => esc(r.zona)], ['Hojas', r => r.hojas], ['Paradas', r => r.paradas], ['Entregadas', r => r.entregadas]], ds) + '</section>' +
      '<p class="micro" style="margin-top:10px">' + esc(rp.score_externo || '') + '</p>';
    $('#iFrom').onchange = e => { st.from = e.target.value; render(); }; $('#iTo').onchange = e => { st.to = e.target.value; render(); };
    $('#iCsv').onclick = () => { const rows = [['tipo', 'estado', 'cantidad', 'solicitado', 'autorizado']].concat(rp.por_tipo_estado.map(r => [r.tipo, r.estado, r.cantidad, r.solicitado, r.autorizado]));
      const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob(['\ufeff' + rows.map(r => r.join(';')).join('\n')], { type: 'text/csv' })); a.download = 'autorizaciones_' + from + '_' + (st.to || to) + '.csv'; a.click(); };
    const amb = $('#alhMore'); if (amb) amb.onclick = async () => { try { const r = await api.comAlarmHistoryPage(st.alh.from, st.alh.to, st.alh.cursor, 25);
      const seen = new Set(st.alh.items.map(x => x.id)); st.alh.items = st.alh.items.concat((r.items || []).filter(x => !seen.has(x.id))); st.alh.cursor = r.next_cursor; st.alh.more = !!r.has_more;
      const y = window.scrollY; st.alhKeep = true; try { await vInformes(m); } finally { st.alhKeep = false; } window.scrollTo(0, y); } catch (e) { toast(errMsg(e), true); } };
  }
  nav(); await render(); await pollBell(true);
  timer = setInterval(() => { if (disposed || !document.body.contains(app)) { clearInterval(timer); return; } if (document.visibilityState === 'visible') { pollBell(false); if (st.tab === 'despacho' && !host.querySelector('#tSearch:focus')) render(); } }, 20000);
  return { render, state: st };
}
