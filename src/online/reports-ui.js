// INFORMES → CRISTIAN TORRES. Misma estética de la offline (pasos numerados, tarjetas blancas, tabla negra con cyan).
// Orden aprobado: 1 Período · 2 Cuantificación por zona · 3 ¿Se paga solo? · 4 Mejores clientes · 5 Clientes a recuperar · 6 Zonas a reforzar
import { esc } from './util.js';
import { hasPerm, ROLE_LABEL } from '../../supabase/functions/_shared/rules.js';
import { ZONE_LABEL, money, dmy, MONTHS, localDate } from '../../supabase/functions/_shared/report-engine.js';
import { openAccount } from './account-ui.js';
import { appFrame, isRc4 } from './rc4-ui.js';

const TYPE = { WEEKLY: 'Semanal', BIWEEKLY: 'Quincenal', MONTHLY: 'Mensual', MANUAL: 'Manual' };
const days = f => f == null ? '—' : 'cada ' + Math.round(f) + ' días';

export class ReportsPanel {
  constructor(api, me, onLogout) {
    this.api = api; this.me = me; this.onLogout = onLogout;
    this.el = document.getElementById('usersPanel'); // mismo contenedor de pantalla completa
    this.tab = 'INFORME';
    const today = localDate(Date.now());
    this.sel = { kind: '7D' };
    this.month = { year: +today.slice(0, 4), month: +today.slice(5, 7) };
    this.free = { from: today.slice(0, 8) + '01', to: today };
    this.hf = { type: '', sent: '', from: '', to: '' };
    this.viewing = null; this.msg = null;
  }
  canManage() { return hasPerm(this.me, 'can_manage_commercial_transport_reports'); }
  async open() {
    this.el.hidden = false;
    if (isRc4(this.me)) {
      const w = appFrame(this.me, 'Informes · Cristian Torres', '#/informes', 'Análisis operativo y comercial del transporte');
      w.innerHTML = '<div class="up-wrap rc4-reports-wrap" id="rpWrap"></div>';
    } else {
      this.el.innerHTML = '<header class="top"><img src="/logo.png" alt="OK Accesorios"><div class="ttl"><b>DESPACHO</b><span>Informes · Cristian Torres</span></div><div class="sp"></div>' +
        '<button class="who-chip linkchip" type="button" id="rpMe">' + esc(this.me.full_name) + ' · <b>' + esc(ROLE_LABEL[this.me.role] || this.me.role) + '</b></button>' +
        '<button class="tbtn" type="button" id="rpClose">Volver al panel</button></header><div class="up-wrap" id="rpWrap"></div>';
      this.el.querySelector('#rpClose').addEventListener('click', () => { if (location.hash) history.replaceState(null, '', location.pathname); this.el.hidden = true; this.el.innerHTML = ''; });
      this.el.querySelector('#rpMe').addEventListener('click', () => openAccount(this.api, this.me, this.onLogout || (() => {})));
    }
    await this.render();
  }
  async call(action, body = {}) { return this.api.reports(action, body); }
  say(t, err) { this.msg = { text: t, err: !!err }; }

  async render() {
    const w = this.el.querySelector('#rpWrap');
    const tabs = ['INFORME', 'HISTORIAL'].concat(this.canManage() ? ['CONFIGURACIÓN'] : []);
    w.innerHTML = '<div class="up-head"><h2>INFORMES → CRISTIAN TORRES</h2><span class="sp"></span><div class="rp-tabs">' +
      tabs.map(t => '<button type="button" class="' + (t === this.tab ? 'on' : '') + '" data-tab="' + t + '">' + t + '</button>').join('') + '</div></div>' +
      (this.msg ? '<div class="up-msg ' + (this.msg.err ? 'err' : 'ok') + '" id="rpMsg">' + esc(this.msg.text) + '</div>' : '') + '<div id="rpBody"></div>';
    w.querySelectorAll('[data-tab]').forEach(b => b.addEventListener('click', () => { this.tab = b.dataset.tab; this.viewing = null; this.msg = null; this.render(); }));
    const body = w.querySelector('#rpBody');
    try {
      if (this.tab === 'INFORME') await this.renderReport(body);
      else if (this.tab === 'HISTORIAL') await this.renderHistory(body);
      else await this.renderConfig(body);
    } catch (e) { body.innerHTML = '<div class="up-msg err">' + esc(e.message) + '</div>'; }
  }

  // ===================== INFORME =====================
  periodControls() {
    const k = this.sel.kind, today = localDate(Date.now());
    const months = []; let y = +today.slice(0, 4), m = +today.slice(5, 7);
    for (let i = 0; i < 18; i++) { months.push({ y, m }); m--; if (!m) { m = 12; y--; } }
    const btn = (kind, label) => '<button type="button" class="' + (k === kind ? 'on' : '') + '" data-k="' + kind + '">' + label + '</button>';
    return '<div class="rp-period"><div class="rp-seg">' + btn('7D', '7 DÍAS') + btn('15D', '15 DÍAS') + btn('MONTH', 'MES') + btn('FREE', 'LIBRE') + '</div>' +
      (k === 'MONTH' ? '<label class="rp-lbl">Mes <select id="rpMonth">' + months.map(o => '<option value="' + o.y + '-' + o.m + '"' + (o.y === this.month.year && o.m === this.month.month ? ' selected' : '') + '>' + MONTHS[o.m - 1] + ' ' + o.y + '</option>').join('') + '</select></label><button class="btn dark" type="button" id="rpApplyMonth">APLICAR MES</button>' : '') +
      (k === 'FREE' ? '<label class="rp-lbl">Desde <input type="date" id="rpFrom" value="' + this.free.from + '"></label><label class="rp-lbl">Hasta <input type="date" id="rpTo" value="' + this.free.to + '"></label><label class="rp-lbl">Cantidad de días <input id="rpDaysIn" size="4" readonly value="' + (this.free.from && this.free.to ? Math.round((Date.parse(this.free.to) - Date.parse(this.free.from)) / 86400000) + 1 : '') + '"></label><button class="btn dark" type="button" id="rpApplyFree">APLICAR</button>' : '') +
      '</div>';
  }
  async renderReport(body) {
    let rep, saved = this.viewing;
    if (saved) rep = saved.snapshot;
    else rep = (await this.call('preview', { sel: this.sel })).report;
    const step = (n, title, inner, small) => '<section class="step rp-step" id="rpStep' + n + '"><h2><span class="n">' + n + '</span>' + title + (small ? '<small>' + small + '</small>' : '') + '</h2>' + inner + '</section>';
    const c = rep.coverage;
    const zoneCard = z => '<div class="rp-zone"><b>' + ZONE_LABEL[z.zone].toUpperCase() + '</b><div class="rp-zn"><span>Envíos completados</span><strong>' + z.completed + '</strong></div><div class="rp-zn"><span>Ingreso por envíos</span><strong>' + money(z.income) + '</strong></div><div class="rp-zn"><span>Promedio por envío</span><strong>' + money(z.avg) + '</strong></div></div>';
    const tbl = (heads, rows, empty) => rows.length ? '<div class="utable-wrap"><table class="utable rp-table"><thead><tr>' + heads.map(h => '<th>' + h + '</th>').join('') + '</tr></thead><tbody>' + rows.join('') + '</tbody></table></div>' : '<p class="rp-empty">' + empty + '</p>';
    body.innerHTML =
      (saved ? '<div class="up-msg ok" id="rpSaved">INFORME GUARDADO · ' + TYPE[saved.report_type] + ' · versión ' + saved.version + ' · generado ' + new Date(saved.generated_at).toLocaleString('es-AR') + ' · costo usado ' + money(c.cost) + '. No se recalcula. <button class="linkbtn" type="button" id="rpBack">Volver al informe actual</button></div>' : '') +
      step(1, 'PERÍODO A ANALIZAR', (saved ? '' : this.periodControls()) + '<p class="rp-plabel" id="rpPeriod"><b>' + esc(rep.period.label) + '</b>' + (rep.period.window ? '' : ' · ' + dmy(rep.period.start) + ' al ' + dmy(rep.period.end)) + ' · <b id="rpDays">' + rep.period.days + ' días</b>' + (rep.period.cutoff_note ? '<br><span>' + esc(rep.period.cutoff_note) + '</span>' : '') + '</p>' +
        '<div class="rp-meta"><span>Período: <b>' + esc(rep.period.label) + '</b></span><span>Hojas finalizadas: <b id="rpRoutes">' + rep.inputs.routes_counted.length + '</b></span><span>Días: <b>' + rep.period.days + '</b></span></div>' +
        '<p class="rp-note">Solo hojas FINALIZADAS por Cristian, por fecha real de finalización (hora de Mendoza). Entrega parcial cuenta como completada.</p>', '') +
      step(2, 'CUANTIFICACIÓN POR ZONA · ENVÍOS + INGRESOS', '<div class="rp-money"><div class="rp-mhead">Resultado consolidado de hojas finalizadas</div><div class="rp-zrow head"><div>Zona</div><div>Completados</div><div>Ingreso envíos</div><div>Promedio por envío</div></div>' +
        rep.zones.map(z => '<div class="rp-zrow"><div><b>' + ZONE_LABEL[z.zone].toUpperCase() + '</b></div><div>' + z.completed + '</div><div>' + money(z.income) + '</div><div>' + money(z.avg) + '</div></div>').join('') + '</div>' +
        '<div class="rp-total" id="rpTotal"><span>TOTAL GENERAL</span><b>' + rep.total.completed + ' envíos</b><b>' + money(rep.total.income) + '</b><span>promedio ' + money(rep.total.avg) + '</span></div>' +
        '<p class="rp-note">No entregados: ' + rep.summary.not_delivered + ' · Reprogramados: ' + rep.summary.rescheduled + ' (no suman ingreso).</p>') +
      step(3, '¿EL TRANSPORTE SE PAGA SOLO?', '<div class="rp-cards">' +
        [['Ingreso Zona Este', money(c.income_by_zone.ESTE)], ['Ingreso Alrededores', money(c.income_by_zone.ALREDEDORES)], ['Ingreso Centro', money(c.income_by_zone.CENTRO)], ['Costo Cristian', money(c.cost)],
         ['Ingreso total de envíos', money(c.income)], ['Diferencia', (c.diff >= 0 ? '+' : '-') + money(Math.abs(c.diff)), c.covers ? 'good' : 'bad'], ['¿Cubre el costo?', c.covers ? 'SÍ' : 'NO', c.covers ? 'good' : 'bad'], ['Hojas finalizadas', String(rep.inputs.routes_counted.length)]]
          .map(([k, v, cl]) => '<div class="rp-card"><span>' + k + '</span><b class="' + (cl || '') + '">' + v + '</b></div>').join('') + '</div>' +
        '<div class="rp-verdict ' + (c.covers ? 'yes' : 'no') + '" id="rpVerdict"><b>' + c.verdict + '</b><span>' + esc(c.text) + '</span></div>', 'Ingreso solo por servicio de envío') +
      step(4, 'MEJORES CLIENTES', '<div class="rp-best">' + rep.best_clients.slice(0, 3).map((b, i) => '<div class="rp-card"><div class="rp-rankline"><i>' + (i + 1) + '</i><div><b>' + esc(b.client) + '</b><small>' + b.purchases + ' compras · frecuencia ' + days(b.freq) + '</small></div></div><b>' + money(b.amount) + '</b></div>').join('') + '</div>' +
        tbl(['CLIENTE', 'COMPRAS', 'FRECUENCIA PROMEDIO', 'ÚLTIMA COMPRA', 'FACTURACIÓN*'], rep.best_clients.slice(3).map(b => '<tr><td><b>' + esc(b.client) + '</b></td><td>' + b.purchases + '</td><td>' + days(b.freq) + '</td><td>' + dmy(b.last) + '</td><td>' + money(b.amount) + '</td></tr>'), rep.best_clients.length ? '' : 'Sin compras en el período.') +
        '<p class="rp-note">* Mercadería de entregas completadas en hojas finalizadas. No es margen ni rentabilidad.</p>') +
      step(5, 'CLIENTES A RECUPERAR', '<div class="rp-alerts"><span>+30 días sin comprar: <b>' + rep.alerts.over30 + '</b></span><span>+60 días: <b>' + rep.alerts.over60 + '</b></span><span>+90 días: <b>' + rep.alerts.over90 + '</b></span></div>' +
        tbl(['CLIENTE', 'ZONA', 'ÚLTIMA COMPRA', 'DÍAS SIN COMPRAR', 'FRECUENCIA', 'COMPRAS 90 DÍAS', 'DESVÍO', 'ESTADO', 'ACCIÓN'], rep.recover.map(r => '<tr><td><b>' + esc(r.client) + '</b></td><td>' + ZONE_LABEL[r.zone] + '</td><td>' + dmy(r.last) + '</td><td>' + r.days_since + '</td><td>' + days(r.freq) + '</td><td>' + r.purchases_90 + '</td><td>+' + Math.round(r.deviation) + ' días</td><td><span class="rp-st ' + r.status.replace(' ', '_') + '">' + r.status + '</span></td><td>' + esc(r.action) + '</td></tr>'), 'Ningún cliente fuera de su frecuencia habitual.') +
        '<p class="rp-note">La prioridad compara los días sin comprar contra la frecuencia habitual de cada cliente.</p>') +
      step(6, 'ZONAS A REFORZAR', '<div class="rp-best">' + rep.reinforce.map(z => '<div class="rp-card rp-zc ' + (z.decision === 'REFORZAR REPARTO' ? 'high' : z.decision === 'RECUPERAR COMERCIALMENTE' ? 'med' : '') + '"><span>' + ZONE_LABEL[z.zone] + '</span><b>' + z.decision.split(' ')[0] + '</b><small>' + esc(z.why) + '</small></div>').join('') + '</div>' + tbl(['ZONA', 'COMPLETADOS', 'NO ENTREG.', 'REPROG.', 'INGRESO', 'TENDENCIA', 'CLIENTES ACTIVOS', 'INACTIVOS', 'FRECUENCIA', 'CARGA/DÍA', 'CONCLUSIÓN', 'POR QUÉ'],
        rep.reinforce.map(z => '<tr><td><b>' + ZONE_LABEL[z.zone] + '</b></td><td>' + z.completed + '</td><td>' + z.not_delivered + '</td><td>' + z.rescheduled + '</td><td>' + money(z.income) + '</td><td>' + (z.growth >= 0 ? '+' : '') + Math.round(z.growth) + '%</td><td>' + z.active_clients + '</td><td>' + z.inactive_clients + '</td><td>' + days(z.avg_freq) + '</td><td>' + z.load_per_day + '</td><td><b>' + z.decision + '</b></td><td>' + esc(z.why) + '</td></tr>'), '') +
        '<ul class="rp-dec">' + rep.decisions.map(d => '<li>' + esc(d) + '</li>').join('') + '</ul>') +
      (!saved && this.canManage() ? '<div class="rp-actions"><button class="btn go" type="button" id="rpGenerate">GENERAR INFORME Y PDF</button><span class="rp-note">Queda guardado en el historial con estos números (no se recalcula).</span></div>' : '');
    const back = body.querySelector('#rpBack'); if (back) back.addEventListener('click', () => { this.viewing = null; this.render(); });
    body.querySelectorAll('.rp-seg [data-k]').forEach(b => b.addEventListener('click', () => { this.setKind(b.dataset.k); this.render(); }));
    const mSel = body.querySelector('#rpMonth');
    const applyM = () => { const [y, m] = mSel.value.split('-').map(Number); this.month = { year: y, month: m }; this.setKind('MONTH'); this.render(); };
    if (mSel) { mSel.addEventListener('change', applyM); body.querySelector('#rpApplyMonth').addEventListener('click', applyM); }
    const af = body.querySelector('#rpApplyFree'); if (af) af.addEventListener('click', () => { this.free = { from: body.querySelector('#rpFrom').value, to: body.querySelector('#rpTo').value }; this.setKind('FREE'); this.render(); });
    const f = body.querySelector('#rpFrom'), t = body.querySelector('#rpTo');
    if (f) [f, t].forEach(i => i.addEventListener('change', () => { this.free = { from: f.value, to: t.value }; this.setKind('FREE'); this.render(); }));
    const g = body.querySelector('#rpGenerate');
    if (g) g.addEventListener('click', async () => {
      g.disabled = true;
      try { const r = (await this.call('generate', { sel: this.sel })).report; this.say('Informe generado · PDF: ' + (r.pdf_status === 'OK' ? 'OK' : r.pdf_status) + '. Está en HISTORIAL.', r.pdf_status !== 'OK'); this.tab = 'HISTORIAL'; }
      catch (e) { this.say(e.message, true); }
      this.render();
    });
  }
  setKind(k) { this.sel = k === 'MONTH' ? { kind: 'MONTH', year: this.month.year, month: this.month.month } : k === 'FREE' ? { kind: 'FREE', from: this.free.from, to: this.free.to } : { kind: k }; }

  // ===================== HISTORIAL =====================
  async renderHistory(body) {
    const list = (await this.call('history', { filters: Object.fromEntries(Object.entries(this.hf).filter(([, v]) => v)) })).reports;
    const opt = (v, l, s) => '<option value="' + v + '"' + (v === s ? ' selected' : '') + '>' + l + '</option>';
    const mailState = r => { const e = r.emails || []; if (!e.length) return 'NO ENVIADO'; const sent = e.filter(x => x.status === 'SENT').length; const bad = e.find(x => x.status !== 'SENT'); return sent + '/' + e.length + ' enviados' + (bad ? ' · ' + bad.status : ''); };
    body.innerHTML = '<div class="ufilters"><select id="hfType">' + opt('', 'Todos los tipos', this.hf.type) + opt('WEEKLY', 'Semanal', this.hf.type) + opt('BIWEEKLY', 'Quincenal', this.hf.type) + opt('MONTHLY', 'Mensual', this.hf.type) + opt('MANUAL', 'Manual', this.hf.type) + '</select>' +
      '<select id="hfSent">' + opt('', 'Enviados y no enviados', this.hf.sent) + opt('SI', 'Enviados', this.hf.sent) + opt('NO', 'No enviados', this.hf.sent) + '</select>' +
      '<label class="rp-lbl">Desde <input type="date" id="hfFrom" value="' + this.hf.from + '"></label><label class="rp-lbl">Hasta <input type="date" id="hfTo" value="' + this.hf.to + '"></label><span class="ufcount">' + list.length + ' informes</span></div>' +
      (list.length ? '<div class="utable-wrap"><table class="utable"><thead><tr><th>TIPO</th><th>PERÍODO</th><th>VERSIÓN</th><th>GENERADO</th><th>PDF</th><th>EMAIL</th><th>ACCIONES</th></tr></thead><tbody>' +
        list.map(r => '<tr data-rid="' + r.id + '"><td><b>' + TYPE[r.report_type] + '</b></td><td>' + dmy(r.period_start) + ' al ' + dmy(r.period_end) + '</td><td>v' + r.version + '</td><td>' + new Date(r.generated_at).toLocaleString('es-AR') + '</td>' +
          '<td><span class="ust ' + (r.pdf_status === 'OK' ? 'ACTIVO' : 'DESHABILITADO') + '">' + r.pdf_status + '</span></td><td>' + esc(mailState(r)) + '</td><td><div class="uact">' +
          '<button class="btn dark" type="button" data-a="view">VER</button>' + (r.pdf_status === 'OK' ? '<button class="btn soft" type="button" data-a="pdf">DESCARGAR PDF</button>' : '') +
          (this.canManage() ? ((r.emails || []).length ? '<button class="btn soft" type="button" data-a="resend">REENVIAR EMAIL</button>' : '<button class="btn soft" type="button" data-a="send">ENVIAR EMAIL</button>') +
            (r.pdf_status !== 'OK' || (r.emails || []).some(e => e.status !== 'SENT') ? '<button class="btn soft" type="button" data-a="retry">REINTENTAR</button>' : '') : '') +
          '</div></td></tr>').join('') + '</tbody></table></div>' : '<p class="rp-empty">Todavía no hay informes con esos filtros.</p>');
    [['#hfType', 'type'], ['#hfSent', 'sent'], ['#hfFrom', 'from'], ['#hfTo', 'to']].forEach(([s, k]) => body.querySelector(s).addEventListener('change', e => { this.hf[k] = e.target.value; this.render(); }));
    body.querySelectorAll('[data-a]').forEach(b => b.addEventListener('click', () => this.historyAction(b.dataset.a, b.closest('tr').dataset.rid)));
  }
  async historyAction(a, id) {
    try {
      if (a === 'view') { const r = await this.call('get', { report_id: id }); this.viewing = r.report; this.tab = 'INFORME'; return this.render(); }
      if (a === 'pdf') {
        const r = await this.call('pdf', { report_id: id });
        const blob = new Blob([Uint8Array.from(atob(r.base64), c => c.charCodeAt(0))], { type: 'application/pdf' });
        const link = document.createElement('a'); link.href = URL.createObjectURL(blob); link.download = r.filename; document.body.appendChild(link); link.click(); link.remove();
        return;
      }
      if (a === 'resend' && !confirm('¿Reenviar el email de este informe a los destinatarios configurados?')) return;
      const r = await this.call(a, { report_id: id });
      const em = r.emails || [];
      this.say(a === 'retry' ? 'Reintento: PDF ' + r.report.pdf_status + ' · ' + em.filter(e => e.status === 'SENT').length + ' emails enviados.' : em.filter(e => e.status === 'SENT' && !e.skipped).length + ' email(s) enviados' + (em.some(e => e.skipped) ? ' (los ya enviados no se duplican)' : '') + (em.some(e => e.status === 'PDF_ERROR') ? ' · PDF_ERROR: no se envió un informe incompleto.' : '') + '.', em.some(e => ['ERROR', 'PDF_ERROR'].includes(e.status)));
    } catch (e) { this.say(e.message, true); }
    this.render();
  }

  // ===================== CONFIGURACIÓN =====================
  async renderConfig(body) {
    const { settings, costs } = await this.call('settings_get');
    const cur = costs.filter(c => !c.valid_to).sort((a, b) => b.valid_from.localeCompare(a.valid_from))[0];
    body.innerHTML =
      '<section class="step rp-step"><h2><span class="n">$</span>COSTO MENSUAL DE CRISTIAN<small>con vigencia histórica</small></h2>' +
      '<p class="rp-plabel">Vigente: <b id="cfgCostNow">' + (cur ? money(cur.monthly_cost) : '—') + '</b> desde ' + (cur ? dmy(cur.valid_from) : '—') + '</p>' +
      '<div class="utable-wrap"><table class="utable"><thead><tr><th>COSTO MENSUAL</th><th>DESDE</th><th>HASTA</th></tr></thead><tbody>' + costs.slice().sort((a, b) => b.valid_from.localeCompare(a.valid_from)).map(c => '<tr><td>' + money(c.monthly_cost) + '</td><td>' + dmy(c.valid_from) + '</td><td>' + (c.valid_to ? dmy(c.valid_to) : 'vigente') + '</td></tr>').join('') + '</tbody></table></div>' +
      '<div class="ufilters" style="margin-top:10px"><label class="rp-lbl">Nuevo costo mensual <input id="cfgCost" inputmode="decimal" placeholder="1600000"></label><label class="rp-lbl">Desde <input type="date" id="cfgFrom"></label><button class="btn dark" type="button" id="cfgCostSave">GUARDAR COSTO</button></div>' +
      '<p class="rp-note">Los informes ya generados no cambian. Períodos menores al mes: cada día vale costo mensual / días de ese mes.</p></section>' +
      '<section class="step rp-step"><h2><span class="n">@</span>ENVÍO AUTOMÁTICO<small>hora de Mendoza</small></h2>' +
      '<p class="rp-note">Elegí una frecuencia automática. El sistema genera el informe, crea el PDF y lo envía a todos los destinatarios configurados.</p>' +
      '<div class="ufilters report-schedule-grid">' +
      '<label class="rp-lbl">Frecuencia <select id="cfgMode">' +
        '<option value="OFF"' + ((settings.schedule_mode || 'WEEKLY') === 'OFF' ? ' selected' : '') + '>Desactivado</option>' +
        '<option value="WEEKLY"' + ((settings.schedule_mode || 'WEEKLY') === 'WEEKLY' ? ' selected' : '') + '>Semanal</option>' +
        '<option value="BIWEEKLY"' + ((settings.schedule_mode || 'WEEKLY') === 'BIWEEKLY' ? ' selected' : '') + '>Quincenal</option>' +
        '<option value="MONTHLY"' + ((settings.schedule_mode || 'WEEKLY') === 'MONTHLY' ? ' selected' : '') + '>Mensual</option>' +
      '</select></label>' +
      '<div id="cfgWeeklyBox"><label class="rp-lbl">Semanal · hora <input id="cfgWeekly" value="' + esc(settings.weekly_time || '15:00') + '" size="5"></label><p class="rp-note">Se envía todos los sábados.</p></div>' +
      '<div id="cfgBiweeklyBox"><label class="rp-lbl">Quincenal · primer día <input id="cfgBiDay1" type="number" min="1" max="28" value="' + Number(settings.biweekly_day_1 || 1) + '"></label>' +
        '<label class="rp-lbl">Segundo día <input id="cfgBiDay2" type="number" min="1" max="28" value="' + Number(settings.biweekly_day_2 || 15) + '"></label>' +
        '<label class="rp-lbl">Hora <input id="cfgBiTime" value="' + esc(settings.biweekly_time || '15:00') + '" size="5"></label><p class="rp-note">Por defecto: días 1 y 15 de cada mes.</p></div>' +
      '<div id="cfgMonthlyBox"><label class="rp-lbl">Mensual · hora <input id="cfgMonthly" value="' + esc(settings.monthly_time || '23:30') + '" size="5"></label><p class="rp-note">Se envía el último día de cada mes.</p></div>' +
      '</div>' +
      '<div class="report-recipients"><label class="rp-lbl" style="display:block">Destinatarios</label>' +
        '<div class="recipient-row"><input id="cfgRcptAdd" type="email" placeholder="nombre@empresa.com"><button class="btn soft" type="button" id="cfgRcptAddBtn">AGREGAR EMAIL</button></div>' +
        '<div id="cfgRcptList" class="recipient-chips"></div>' +
        '<p class="rp-note">Podés agregar uno o varios emails. Cada destinatario recibe su propio envío y queda registrado en el historial.</p></div>' +
      '<label class="rp-lbl chk"><input type="checkbox" id="cfgPdf"' + (settings.require_pdf !== false ? ' checked' : '') + '> Exigir PDF adjunto (si falla el PDF no se envía)</label>' +
      '<div style="margin-top:12px"><button class="btn dark" type="button" id="cfgSave">GUARDAR CONFIGURACIÓN</button></div></section>' +
      (this.api.mode === 'demo' ? '<section class="step rp-step"><h2><span class="n">▶</span>SIMULAR ENVÍO PROGRAMADO<small>solo modo demo</small></h2>' +
        '<div class="ufilters"><label class="rp-lbl">Fecha y hora (Mendoza) <input type="datetime-local" id="simAt"></label><button class="btn soft" type="button" id="simRun">EJECUTAR PROGRAMACIÓN</button></div>' +
        '<div id="outbox">' + this.outboxHtml() + '</div></section>' : '');
    body.querySelector('#cfgCostSave').addEventListener('click', async () => {
      try { await this.call('cost_set', { monthly_cost: Number(String(body.querySelector('#cfgCost').value).replace(/\./g, '').replace(',', '.')), valid_from: body.querySelector('#cfgFrom').value }); this.say('Costo guardado. Los informes ya generados conservan el costo anterior.'); }
      catch (e) { this.say(e.message, true); } this.render();
    });
    const recipients = [...(settings.recipients || [])];
    const listRcpt = () => {
      const box = body.querySelector('#cfgRcptList');
      box.innerHTML = recipients.length ? recipients.map((mail, i) => '<span class="recipient-chip">' + esc(mail) + '<button type="button" data-rm="' + i + '" aria-label="Quitar destinatario">×</button></span>').join('') : '<span class="rp-note">Todavía no hay destinatarios configurados.</span>';
      box.querySelectorAll('[data-rm]').forEach(b => b.addEventListener('click', () => { recipients.splice(+b.dataset.rm, 1); listRcpt(); }));
    };
    const addRcpt = () => {
      const inp = body.querySelector('#cfgRcptAdd'), mail = inp.value.trim().toLowerCase();
      if (!mail) return;
      if (!/^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$/.test(mail)) { this.say('Ingresá un email válido.', true); return this.render(); }
      if (!recipients.includes(mail)) recipients.push(mail);
      inp.value = ''; listRcpt();
    };
    body.querySelector('#cfgRcptAddBtn').addEventListener('click', addRcpt);
    body.querySelector('#cfgRcptAdd').addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); addRcpt(); } });
    listRcpt();
    const syncMode = () => {
      const mode = body.querySelector('#cfgMode').value;
      body.querySelector('#cfgWeeklyBox').hidden = mode !== 'WEEKLY';
      body.querySelector('#cfgBiweeklyBox').hidden = mode !== 'BIWEEKLY';
      body.querySelector('#cfgMonthlyBox').hidden = mode !== 'MONTHLY';
    };
    body.querySelector('#cfgMode').addEventListener('change', syncMode); syncMode();
    body.querySelector('#cfgSave').addEventListener('click', async () => {
      try {
        const settingsOut = {
          schedule_mode: body.querySelector('#cfgMode').value,
          weekly_time: body.querySelector('#cfgWeekly').value.trim(),
          biweekly_day_1: Number(body.querySelector('#cfgBiDay1').value),
          biweekly_day_2: Number(body.querySelector('#cfgBiDay2').value),
          biweekly_time: body.querySelector('#cfgBiTime').value.trim(),
          monthly_time: body.querySelector('#cfgMonthly').value.trim(),
          recipients,
          require_pdf: body.querySelector('#cfgPdf').checked
        };
        await this.call('settings_set', { settings: settingsOut });
        this.say('Configuración de envío automático guardada.');
      } catch (e) { this.say(e.message, true); }
      this.render();
    });
    const sim = body.querySelector('#simRun');
    if (sim) sim.addEventListener('click', async () => {
      const v = body.querySelector('#simAt').value; if (!v) { this.say('Elegí fecha y hora.', true); return this.render(); }
      const r = await this.api.runScheduledAt(v);
      this.say(r.done.length ? 'Programación ejecutada: ' + r.done.map(d => TYPE[d.type] + ' ' + d.period + ' (' + d.emails.filter(e => e.status === 'SENT' && !e.skipped).length + ' enviados' + (d.emails.some(e => e.skipped) ? ', sin duplicar' : '') + ')').join(' · ') : 'A esa hora no corresponde ningún informe.');
      this.render();
    });
    body.querySelectorAll('[data-mail]').forEach(b => b.addEventListener('click', () => {
      const m = this.api.outbox()[+b.dataset.mail];
      const f = document.createElement('div'); f.className = 'umodal'; f.id = 'mailPreview';
      f.innerHTML = '<div class="udialog" style="width:min(760px,100%)"><header><b>' + esc(m.subject) + '</b></header><div class="body"><p style="margin:0;font-size:12.5px">Para: ' + esc(m.to) + ' · Adjunto: ' + esc(m.attachment || 'sin adjunto') + '</p><iframe title="Vista del email" style="width:100%;height:560px;border:1px solid var(--line);border-radius:8px" sandbox=""></iframe></div><footer><button class="btn ghost" type="button" id="mpClose">Cerrar</button></footer></div>';
      this.el.appendChild(f); f.querySelector('iframe').srcdoc = m.html; f.querySelector('#mpClose').addEventListener('click', () => f.remove());
    }));
  }
  outboxHtml() {
    const box = this.api.outbox ? this.api.outbox() : [];
    return '<p class="rp-plabel">Bandeja de salida (demo): ' + box.length + ' emails</p>' + (box.length ? '<div class="utable-wrap"><table class="utable"><thead><tr><th>PARA</th><th>ASUNTO</th><th>ADJUNTO</th><th></th></tr></thead><tbody>' +
      box.map((m, i) => '<tr><td>' + esc(m.to) + '</td><td>' + esc(m.subject) + '</td><td>' + esc(m.attachment || '—') + '</td><td><button class="btn soft" type="button" data-mail="' + i + '">VER EMAIL</button></td></tr>').reverse().join('') + '</tbody></table></div>' : '');
  }
}
