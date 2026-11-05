// V4.25 · VEHÍCULOS Y SERVICE → INSPECCIONES (formulario R SE 4.5.1-05 Rev:00 · 30 controles EXACTOS del Excel original).
// Administrador General: operación completa; Operario realiza y Superior revisa su equipo. Sin fotografías, cámara, adjuntos ni firmas.
// Borrador automático en el celular + sincronización sin duplicados (client_id). Los Excel se generan con los registros GUARDADOS.
import CONTROLS from './inspection-controls.json';
import { esc } from './util.js';
const CATS = CONTROLS.categorias;
const ALL = CATS.flatMap(c => c.controles);
const ST = { BORRADOR: 'BORRADOR', PENDIENTE: 'PENDIENTE', APROBADA: 'APROBADA', RECHAZADA: 'RECHAZADA' };
const RES = { BIEN: 'BIEN', MAL: 'MAL', NO_APLICA: 'NO APLICA' }, DEF = { FALTANTE: 'FALTANTE', MAL_ESTADO: 'MAL ESTADO' };
const dt = iso => iso ? new Date(iso).toLocaleString('es-AR', { timeZone: 'America/Argentina/Mendoza', day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' }) : '';
const uuid = () => (crypto.randomUUID ? crypto.randomUUID() : 'xxxxxxxx-xxxx-4xxx-8xxx-xxxxxxxxxxxx'.replace(/x/g, () => (Math.random() * 16 | 0).toString(16)));
const loadExcelJS = () => window.ExcelJS ? Promise.resolve(window.ExcelJS) : new Promise((ok, ko) => { const s = document.createElement('script'); s.src = '/legacy/exceljs.min.js'; s.onload = () => ok(window.ExcelJS); s.onerror = () => ko(new Error('No se pudo cargar el generador de Excel.')); document.head.appendChild(s); });
const activeAdmin = me => me.status === 'ACTIVO' && me.role === 'ADMIN';
const canDo = me => me.status === 'ACTIVO' && ['ADMIN', 'OPERARIO_DEPOSITO', 'SUPERVISOR_DESPACHO'].includes(me.role);
const canEmail = me => me.status === 'ACTIVO' && ['ADMIN', 'SUPERVISOR_DESPACHO'].includes(me.role);
const canReview = (me, i) => me.status === 'ACTIVO' && i.status === 'PENDIENTE' && (activeAdmin(me) || (me.role === 'SUPERVISOR_DESPACHO' && (i.created_by === me.id || i.team_supervisor_id === me.id)));
const noSupervisor = me => me.role === 'OPERARIO_DEPOSITO' && 'supervisor_user_id' in me && !me.supervisor_user_id;   // sin Superior asignado: borrador sí, envío no

// ---------- borrador local (sobrevive al cierre de la app) y cola de sincronización (sin duplicados) ----------
const LK = me => 'okd_insp_draft:' + me.id, QK = me => 'okd_insp_queue:' + me.id;
const readJ = (k, d) => { try { return JSON.parse(localStorage.getItem(k) || 'null') ?? d; } catch (e) { return d; } };
const writeJ = (k, v) => { try { localStorage.setItem(k, JSON.stringify(v)); } catch (e) { } };
async function flushQueue(api, me) {   // envía en orden; cada operación es idempotente en el servidor (client_id / id)
  const q = readJ(QK(me), []); let changed = false;
  while (q.length && navigator.onLine) {
    const op = q[0];
    try {
      if (op.kind === 'save') { const r = await api.inspSaveDraft(op.p); q.slice(1).forEach(o => { if (o.kind === 'submit' && o.client_id === op.p.client_id) o.id = r.id; }); }
      else if (op.kind === 'submit') { if (!op.id) break; await api.inspSubmit(op.id); }
      q.shift(); changed = true; writeJ(QK(me), q);
    } catch (e) { if (/fetch|network|Failed|conexi/i.test(e.message)) break; op.error = e.message; q.shift(); changed = true; writeJ(QK(me), q); writeJ('okd_insp_last_error:' + me.id, { at: Date.now(), msg: e.message }); }
  }
  return changed;
}

export async function openInspections(api, me, frame) {
  const w = frame(me, 'Inspecciones de vehículos', '#/inspecciones');
  const tabs = [canDo(me) && ['nueva', 'NUEVA INSPECCIÓN'], canDo(me) && ['mias', 'MIS INSPECCIONES'], canEmail(me) && ['pend', 'PENDIENTES'], ['hist', 'HISTORIAL DE INSPECCIONES']].filter(Boolean);
  const h = new URLSearchParams(location.hash.split('?')[1] || '');
  w.innerHTML = '<div class="up-head"><h2>INSPECCIONES DE VEHÍCULOS</h2><span class="tag">R SE 4.5.1-05 · Rev:00</span></div>' +
    '<div class="htabs" role="tablist" id="inTabs">' + tabs.map(([k, l]) => '<button type="button" role="tab" data-intab="' + k + '">' + l + '</button>').join('') +
    '<button type="button" role="tab" data-intab="det" hidden>DETALLE</button></div><div id="inPane"></div><div class="up-msg" id="inMsg" hidden></div>';
  const pane = w.querySelector('#inPane'), msg = (t, err) => { const m = w.querySelector('#inMsg'); m.hidden = !t; m.className = 'up-msg' + (err ? ' err' : ''); m.textContent = t || ''; };
  const sel = k => w.querySelectorAll('[data-intab]').forEach(b => b.setAttribute('aria-selected', String(b.dataset.intab === k)));
  window.addEventListener('online', () => flushQueue(api, me).then(c => { if (c) msg('Inspecciones sincronizadas.'); }));
  flushQueue(api, me).catch(() => null);
  const show = async k => { sel(k); msg(''); try { if (k === 'nueva') await formView(); else if (k === 'mias') await listView({ mine: true }); else if (k === 'pend') await listView({ status: 'PENDIENTE' }); else await histView(); } catch (e) { msg(e.message, true); } };
  w.querySelectorAll('[data-intab]').forEach(b => b.onclick = () => b.dataset.intab === 'det' ? null : show(b.dataset.intab));

  // =============== NUEVA INSPECCIÓN (Android primero) ===============
  async function formView(fromDraft) {
    const vehicles = await api.inspVehicles().catch(() => readJ('okd_insp_vehicles', []));
    if (vehicles.length) writeJ('okd_insp_vehicles', vehicles);
    let d = fromDraft || readJ(LK(me), null);
    if (!d) d = { client_id: uuid(), vehicle_id: '', km: '', general_observation: '', items: {}, open: CATS[0].categoria, started_at: new Date().toISOString() };
    const save = () => { d.saved_at = new Date().toISOString(); writeJ(LK(me), d); const s = pane.querySelector('#inSaved'); if (s) s.textContent = 'Borrador guardado en el celular · ' + dt(d.saved_at); };
    const done = () => ALL.filter(c => d.items[c.n] && d.items[c.n].result).length;
    const ctrl = c => { const it = d.items[c.n] || {}, mal = it.result === 'MAL';
      return '<div class="in-ctrl' + (it.result ? ' ok' : '') + (mal ? ' mal' : '') + '" data-n="' + c.n + '"><div class="in-q"><b>' + c.n + '.</b> ' + esc(c.control) + '</div>' +
        '<div class="in-res">' + Object.entries(RES).map(([k, l]) => '<button type="button" class="in-b ' + k + (it.result === k ? ' on' : '') + '" data-res="' + k + '">' + l + '</button>').join('') + '</div>' +
        (mal ? '<div class="in-def">' + Object.entries(DEF).map(([k, l]) => '<button type="button" class="in-d' + (it.defect === k ? ' on' : '') + '" data-def="' + k + '">' + l + '</button>').join('') + '</div>' +
          '<label class="in-obs">Observación (obligatoria)<textarea data-obs rows="2" placeholder="Describí la anomalía">' + esc(it.observation || '') + '</textarea></label>' : '') +
        (c.dato_extra === 'Vence' ? '<label class="in-x">Vence <input type="date" data-xdate value="' + esc(it.extra_date || '') + '"></label>' : '') +
        (c.dato_extra === 'Km' ? '<label class="in-x">Km <input inputmode="numeric" data-xkm value="' + esc(it.extra_km ?? '') + '"></label>' : '') + '</div>'; };
    const render = () => {
      const n = done(), pct = Math.round(n / ALL.length * 100), mal = ALL.filter(c => (d.items[c.n] || {}).result === 'MAL').length;
      pane.innerHTML = '<section class="card in-form">' +
        '<div class="in-head"><label>Vehículo <select id="inVeh"><option value="">Elegí el vehículo…</option>' + vehicles.map(v => '<option value="' + v.id + '"' + (v.id === d.vehicle_id ? ' selected' : '') + '>' + esc(v.name + ' · ' + v.plate) + '</option>').join('') + '</select></label>' +
        '<label>Kilómetros <input id="inKm" inputmode="numeric" value="' + esc(d.km) + '" placeholder="Km actual"></label></div>' +
        '<div class="in-prog" role="progressbar" aria-valuenow="' + n + '" aria-valuemax="30"><div style="width:' + pct + '%"></div></div>' +
        '<p class="in-progt"><b>' + n + ' de 30</b> controles · ' + (30 - n) + ' pendientes · ' + mal + ' anomalía(s) <small id="inSaved"></small></p>' +
        CATS.map(c => { const k = c.controles.filter(x => d.items[x.n] && d.items[x.n].result).length;
          return '<details class="in-cat" data-cat="' + esc(c.categoria) + '"' + (d.open === c.categoria ? ' open' : '') + '><summary>' + esc(c.categoria) + ' <span>' + k + '/' + c.controles.length + (k === c.controles.length ? ' ✓' : '') + '</span></summary>' + c.controles.map(ctrl).join('') + '</details>'; }).join('') +
        '<label class="in-obs">Observaciones generales<textarea id="inGen" rows="2">' + esc(d.general_observation || '') + '</textarea></label>' +
        (noSupervisor(me) ? '<div class="up-msg err" id="inNoSup" role="alert">Tu usuario no tiene un Superior Despacho asignado. Podés completar y guardar la inspección, pero no enviarla: pedí al Administrador General que te asigne uno.</div>' : '') +
        '<div class="in-bar"><button type="button" class="btn soft" id="inNext">IR A PENDIENTE</button><button type="button" class="btn dark" id="inSend"' + (n < 30 || noSupervisor(me) ? ' disabled' : '') + '>ENVIAR A APROBACIÓN</button></div></section>';
      bind(); save();
    };
    const bind = () => {
      pane.querySelector('#inVeh').onchange = e => { d.vehicle_id = e.target.value; const v = vehicles.find(x => x.id === d.vehicle_id); if (v && !d.km) { d.km = String(v.current_km ?? ''); pane.querySelector('#inKm').value = d.km; } save(); };
      pane.querySelector('#inKm').oninput = e => { d.km = e.target.value.replace(/[^0-9.]/g, ''); save(); };
      pane.querySelector('#inGen').oninput = e => { d.general_observation = e.target.value; save(); };
      pane.querySelectorAll('details.in-cat').forEach(x => x.ontoggle = () => { if (x.open) { d.open = x.dataset.cat; save(); } });
      pane.querySelectorAll('.in-ctrl').forEach(el => { const n = +el.dataset.n, it = () => (d.items[n] = d.items[n] || {});
        el.querySelectorAll('[data-res]').forEach(b => b.onclick = () => { const x = it(); x.result = b.dataset.res; if (x.result !== 'MAL') { x.defect = null; } keepPos(el, n); });
        el.querySelectorAll('[data-def]').forEach(b => b.onclick = () => { it().defect = b.dataset.def; keepPos(el, n); });
        const o = el.querySelector('[data-obs]'); if (o) o.oninput = () => { it().observation = o.value; save(); };
        const xd = el.querySelector('[data-xdate]'); if (xd) xd.onchange = () => { it().extra_date = xd.value; save(); };
        const xk = el.querySelector('[data-xkm]'); if (xk) xk.oninput = () => { it().extra_km = xk.value.replace(/[^0-9.]/g, ''); save(); }; });
      pane.querySelector('#inNext').onclick = () => { const c = ALL.find(x => !(d.items[x.n] || {}).result || ((d.items[x.n] || {}).result === 'MAL' && (!(d.items[x.n] || {}).defect || !(d.items[x.n] || {}).observation)));
        if (!c) { msg('No quedan controles pendientes.'); return; } const cat = CATS.find(k => k.controles.includes(c)); d.open = cat.categoria; render();
        const el = pane.querySelector('.in-ctrl[data-n="' + c.n + '"]'); if (el) { el.scrollIntoView({ block: 'center' }); el.classList.add('focus'); } };
      pane.querySelector('#inSend').onclick = send;
    };
    const keepPos = (el, n) => { const top = el.getBoundingClientRect().top; const cat = CATS.find(k => k.controles.some(x => x.n === n));
      if (cat.controles.every(x => (d.items[x.n] || {}).result && ((d.items[x.n] || {}).result !== 'MAL' || ((d.items[x.n] || {}).defect && (d.items[x.n] || {}).observation)))) { const nx = CATS[CATS.indexOf(cat) + 1]; if (nx) d.open = nx.categoria; }
      render(); const el2 = pane.querySelector('.in-ctrl[data-n="' + n + '"]'); if (el2 && el2.offsetParent) window.scrollBy(0, el2.getBoundingClientRect().top - top); };
    const payload = () => ({ client_id: d.client_id, vehicle_id: d.vehicle_id, km: d.km, general_observation: d.general_observation,
      items: Object.entries(d.items).map(([n, x]) => ({ n: +n, result: x.result || null, defect: x.result === 'MAL' ? x.defect || null : null, observation: x.observation || null, extra_date: x.extra_date || null, extra_km: x.extra_km || null })) });
    const send = async () => {
      if (!d.vehicle_id) return msg('Elegí el vehículo.', true); if (d.km === '' || d.km == null) return msg('Cargá el kilometraje.', true);
      const bad = ALL.filter(c => (d.items[c.n] || {}).result === 'MAL' && (!(d.items[c.n] || {}).defect || !String((d.items[c.n] || {}).observation || '').trim()));
      if (bad.length) return msg('Cada control MAL necesita FALTANTE o MAL ESTADO y una observación: ' + bad.map(c => c.n).join(', ') + '.', true);
      const anomalies = ALL.filter(c => (d.items[c.n] || {}).result === 'MAL');
      if (!confirm('¿Enviar la inspección a aprobación?\n\n' + (anomalies.length ? anomalies.length + ' anomalía(s):\n' + anomalies.map(c => '· ' + c.n + '. ' + c.control + ' — ' + DEF[d.items[c.n].defect]).join('\n') : 'Sin anomalías.') + '\n\nDespués de enviarla no se puede modificar.')) return;
      const q = readJ(QK(me), []); q.push({ kind: 'save', p: payload() }, { kind: 'submit', client_id: d.client_id }); writeJ(QK(me), q);
      const errBefore = readJ('okd_insp_last_error:' + me.id, null); await flushQueue(api, me);
      const left = readJ(QK(me), []).length, errNow = readJ('okd_insp_last_error:' + me.id, null);
      if (errNow && (!errBefore || errNow.at !== errBefore.at) && /SUPERVISOR_REQUIRED/.test(errNow.msg)) { msg(errNow.msg.replace(/^SUPERVISOR_REQUIRED:\s*/, ''), true); return; }   // el borrador se CONSERVA
      localStorage.removeItem(LK(me));
      await show(canDo(me) ? 'mias' : 'hist');   // primero la pestaña (limpia mensajes) y DESPUÉS la confirmación, para que el operario la vea
      msg(left ? 'Sin conexión: la inspección quedó guardada en el celular y se enviará al volver la señal.' : 'Inspección enviada a aprobación.');
    };
    render();
  }

  // =============== LISTADOS (mis inspecciones · pendientes) ===============
  const row = i => '<tr data-iid="' + i.id + '"><td>' + esc(i.number) + (i.revision > 1 ? ' · rev ' + i.revision : '') + '</td><td>' + esc(dt(i.submitted_at || i.created_at)) + '</td><td>' + esc(i.vehicle_name || '') + '</td><td>' + esc(i.plate) +
    '</td><td>' + (i.km ?? '') + '</td><td>' + esc(i.created_by_name) + '</td><td><span class="in-st ' + i.status + '">' + ST[i.status] + '</span></td><td>' + (i.anomalies || 0) + '</td><td>' + esc(i.reviewed_by_name || '') +
    '</td><td><button type="button" class="btn soft" data-open>VER</button></td></tr>';
  const table = rows => '<div class="utable-wrap"><table class="utable" id="inTable"><thead><tr><th>N°</th><th>FECHA</th><th>VEHÍCULO</th><th>PATENTE</th><th>KM</th><th>RESPONSABLE</th><th>ESTADO</th><th>ANOMALÍAS</th><th>APROBÓ / RECHAZÓ</th><th></th></tr></thead><tbody>' +
    (rows.length ? rows.map(row).join('') : '<tr><td colspan="10">Sin inspecciones.</td></tr>') + '</tbody></table></div>';
  const wireOpen = () => pane.querySelectorAll('[data-open]').forEach(b => b.onclick = () => detailView(b.closest('tr').dataset.iid));
  async function listView(f) {
    let rows = await api.inspList(f.status ? { status: f.status } : {}); if (f.mine) rows = rows.filter(i => i.created_by === me.id);
    const pendQ = readJ(QK(me), []).length, draft = readJ(LK(me), null);
    pane.innerHTML = (f.mine && (draft || pendQ) ? '<p class="rp-note">' + (draft ? 'Tenés un borrador sin enviar. <button type="button" class="btn soft" id="inResume">CONTINUAR BORRADOR</button> ' : '') + (pendQ ? pendQ + ' operación(es) esperando conexión.' : '') + '</p>' : '') + table(rows);
    const r = pane.querySelector('#inResume'); if (r) r.onclick = () => { sel('nueva'); formView(); };
    wireOpen();
  }

  // =============== HISTORIAL (filtros + exportación) ===============
  let hf = readJ('okd_insp_hist_filters:' + me.id, {});
  async function histView() {
    const vehicles = await api.inspVehicles().catch(() => []);
    pane.innerHTML = '<details class="hfold" open><summary>FILTROS</summary><div class="ufilters"><label>Desde <input type="date" id="hfF" value="' + esc(hf.from || '') + '"></label><label>Hasta <input type="date" id="hfT" value="' + esc(hf.to || '') + '"></label>' +
      '<label>Vehículo <select id="hfV"><option value="">Todos</option>' + vehicles.map(v => '<option value="' + v.id + '"' + (v.id === hf.vehicle_id ? ' selected' : '') + '>' + esc(v.name) + '</option>').join('') + '</select></label>' +
      '<label>Patente <input id="hfP" value="' + esc(hf.plate || '') + '"></label><label>Responsable <input id="hfR" value="' + esc(hf.responsable || '') + '"></label>' +
      '<label>Estado <select id="hfS"><option value="">Todos</option>' + Object.keys(ST).filter(s => s !== 'BORRADOR').map(s => '<option' + (s === hf.status ? ' selected' : '') + '>' + s + '</option>').join('') + '</select></label>' +
      '<button type="button" class="btn dark" id="hfGo">BUSCAR</button><button type="button" class="btn soft" id="hfX">EXPORTAR HISTORIAL</button></div></details><div id="hfList"></div>';
    const read = () => ({ from: pane.querySelector('#hfF').value, to: pane.querySelector('#hfT').value, vehicle_id: pane.querySelector('#hfV').value, plate: pane.querySelector('#hfP').value.trim(), responsable: pane.querySelector('#hfR').value.trim(), status: pane.querySelector('#hfS').value });
    const list = async () => { hf = read(); writeJ('okd_insp_hist_filters:' + me.id, hf); const rows = (await api.inspList(hf)).filter(i => i.status !== 'BORRADOR');
      pane.querySelector('#hfList').innerHTML = table(rows); wireOpen(); return rows; };
    pane.querySelector('#hfGo').onclick = list;
    pane.querySelector('#hfX').onclick = async () => { try { const rows = await list(); await exportHistory(api, rows, hf); msg('Historial exportado (' + rows.length + ' inspecciones).'); } catch (e) { msg(e.message, true); } };
    await list();
  }

  // =============== DETALLE (30 controles · auditoría · aprobar/rechazar · revisión · Excel · email) ===============
  async function detailView(id) {
    const tb = w.querySelector('[data-intab="det"]'); tb.hidden = false; sel('det');
    const { inspection: i, items, events } = await api.inspDetail(id); tb.textContent = i.number + (i.revision > 1 ? ' · rev ' + i.revision : '');
    const byN = Object.fromEntries(items.map(x => [x.item_no, x]));
    pane.innerHTML = '<section class="delivery-trace-panel dt"><header class="dt-head"><div><h3>INSPECCIÓN ' + esc(i.number) + (i.revision > 1 ? ' · REVISIÓN ' + i.revision : '') + '</h3><p>' + esc((i.vehicle_name || '') + ' · ' + i.plate + ' · ' + (i.km ?? '—') + ' km') + '</p></div>' +
      '<span class="in-st ' + i.status + '">' + ST[i.status] + '</span></header><div class="dt-pane">' +
      '<div class="dt-summary"><div><span>Realizó</span><b>' + esc(i.created_by_name) + '</b><small>' + esc(dt(i.submitted_at || i.created_at)) + '</small></div><div><span>Aprobó / rechazó</span><b>' + esc(i.reviewed_by_name || '—') + '</b><small>' + esc(dt(i.reviewed_at)) + '</small></div>' +
      '<div><span>Anomalías</span><b>' + (i.anomalies || 0) + '</b></div></div>' + (i.reject_reason ? '<div class="dt-warn">Motivo del rechazo: ' + esc(i.reject_reason) + '</div>' : '') +
      CATS.map(c => '<details class="in-cat" open><summary>' + esc(c.categoria) + '</summary><table class="utable in-dt"><tbody>' + c.controles.map(x => { const r = byN[x.n] || {};
        return '<tr class="' + (r.result === 'MAL' ? 'mal' : '') + '"><td>' + x.n + '</td><td>' + esc(x.control) + '</td><td><b>' + esc(RES[r.result] || 'SIN RESPUESTA') + '</b>' + (r.defect ? ' · ' + DEF[r.defect] : '') + '</td><td>' + esc(r.observation || '') +
          (r.extra_date ? ' · Vence ' + esc(r.extra_date) : '') + (r.extra_km != null ? ' · Km ' + esc(r.extra_km) : '') + '</td></tr>'; }).join('') + '</tbody></table></details>').join('') +
      (i.general_observation ? '<p><b>Observaciones generales:</b> ' + esc(i.general_observation) + '</p>' : '') +
      '<details class="dt-more"><summary>AUDITORÍA (' + events.length + ')</summary>' + events.map(e => '<p>' + esc(dt(e.at)) + ' · <b>' + esc(e.action) + '</b> · ' + esc(e.actor_name || '') + '</p>').join('') + '</details>' +
      '<div class="uact in-acts">' + (canReview(me, i) ? '<button type="button" class="btn dark" id="inOk">APROBAR</button><button type="button" class="btn soft" id="inNo">RECHAZAR</button>' : '') +
      '<button type="button" class="btn soft" id="inXls">DESCARGAR EXCEL</button>' + (canDo(me) && ['APROBADA', 'RECHAZADA'].includes(i.status) ? '<button type="button" class="btn soft" id="inRev">NUEVA REVISIÓN</button>' : '') +
      (canEmail(me) && i.status === 'APROBADA' ? '<button type="button" class="btn soft" id="inMail">PREPARAR EMAIL PARA SUPERIORES</button>' : '') + '</div><div id="inExtra"></div></div></section>';
    const act = async (f, okMsg) => { try { await f(); msg(okMsg); await detailView(id); } catch (e) { msg(e.message, true); } };
    const ok = pane.querySelector('#inOk'); if (ok) ok.onclick = () => confirm('¿Aprobar la inspección ' + i.number + '?') && act(() => api.inspReview(id, 'APROBADA', null), 'Inspección aprobada.');
    const no = pane.querySelector('#inNo'); if (no) no.onclick = () => { pane.querySelector('#inExtra').innerHTML = '<label class="in-obs">Motivo del rechazo (obligatorio)<textarea id="inWhy" rows="2"></textarea></label><button type="button" class="btn dark" id="inNoGo">CONFIRMAR RECHAZO</button>';
      pane.querySelector('#inNoGo').onclick = () => { const r = pane.querySelector('#inWhy').value.trim(); if (!r) return msg('Indicá el motivo del rechazo.', true); act(() => api.inspReview(id, 'RECHAZADA', r), 'Inspección rechazada.'); }; };
    pane.querySelector('#inXls').onclick = async () => { try { await exportOne(api, id); } catch (e) { msg(e.message, true); } };
    const rv = pane.querySelector('#inRev'); if (rv) rv.onclick = () => confirm('¿Crear una NUEVA REVISIÓN? La inspección original queda sin cambios.') && act(async () => { const n = await api.inspNewRevision(id, uuid()); await detailView(n.id); }, 'Nueva revisión creada como borrador.');
    const ml = pane.querySelector('#inMail'); if (ml) ml.onclick = () => { const mal = items.filter(x => x.result === 'MAL');
      const body = 'Inspección ' + i.number + (i.revision > 1 ? ' (revisión ' + i.revision + ')' : '') + ' — APROBADA\nVehículo: ' + (i.vehicle_name || '') + ' · Patente: ' + i.plate + '\nFecha: ' + dt(i.submitted_at || i.created_at) + ' · Kilometraje: ' + (i.km ?? '—') +
        '\nResponsable: ' + i.created_by_name + ' · Aprobó: ' + (i.reviewed_by_name || '') + ' (' + dt(i.reviewed_at) + ')\nResultado: ' + (mal.length ? mal.length + ' anomalía(s)' : 'sin anomalías') +
        (mal.length ? '\n\nControles observados:\n' + mal.map(x => '· ' + x.item_no + '. ' + (ALL.find(c => c.n === x.item_no) || {}).control + ' — ' + DEF[x.defect] + ': ' + (x.observation || '')).join('\n') : '') + (i.general_observation ? '\n\nObservaciones: ' + i.general_observation : '');
      pane.querySelector('#inExtra').innerHTML = '<div class="card"><b>BORRADOR DEL EMAIL (no se envió)</b><label>Destinatarios (separados por coma)<input id="inTo" placeholder="nombre@empresa.com"></label><label>Asunto<input id="inSub" value="' + esc('Inspección ' + i.number + ' aprobada · ' + i.plate) + '"></label>' +
        '<label>Mensaje<textarea id="inBody" rows="9">' + esc(body) + '</textarea></label><button type="button" class="btn dark" id="inMailGo">ENVIAR EMAIL</button></div>';
      pane.querySelector('#inMailGo').onclick = () => { const to = pane.querySelector('#inTo').value.split(',').map(s => s.trim()).filter(Boolean); if (!to.length) return msg('Indicá al menos un destinatario.', true);
        if (!confirm('¿Enviar el email a ' + to.join(', ') + '?')) return;
        (async () => { try { const r = await api.inspEmailRequest(id, to, pane.querySelector('#inSub').value, pane.querySelector('#inBody').value); await detailView(id);
          msg(r && r.status === 'ENVIADO' ? 'Email enviado a ' + to.join(', ') + (r.simulated ? ' (modo demo: envío simulado).' : '.') : 'El email quedó registrado pero NO se pudo enviar' + (r && r.error ? ': ' + r.error : '') + '. Se reintentará.', !(r && r.status === 'ENVIADO'));
        } catch (e) { msg(e.message, true); } })(); }; };
  }

  if (h.get('id')) await detailView(h.get('id')); else await show(tabs[0][0]);
}

// =============== EXCEL ===============
const headStyle = ws => { ws.getRow(1).font = { bold: true, color: { argb: 'FFFFFFFF' } }; ws.getRow(1).fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FF07151B' } }; };
const save = async (wb, name) => { const buf = await wb.xlsx.writeBuffer(), a = document.createElement('a'); a.href = URL.createObjectURL(new Blob([buf], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' })); a.download = name; document.body.appendChild(a); a.click(); a.remove(); };
export async function exportOne(api, id) {   // A. una inspección (desde los registros guardados)
  const X = await loadExcelJS(), { inspection: i, items, events } = await api.inspDetail(id), byN = Object.fromEntries(items.map(x => [x.item_no, x]));
  const wb = new X.Workbook(), ws = wb.addWorksheet('Inspección', { pageSetup: { paperSize: 9, orientation: 'portrait', fitToPage: true, fitToWidth: 1, fitToHeight: 0 } });
  ws.columns = [{ width: 6 }, { width: 48 }, { width: 13 }, { width: 14 }, { width: 46 }];
  const add = (v, o = {}) => { const r = ws.addRow(v); if (o.bold) r.font = { bold: true }; if (o.fill) r.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: o.fill } }; if (o.white) r.font = { bold: true, color: { argb: 'FFFFFFFF' } }; return r; };
  add(['OK DESPACHO · INSPECCIÓN SISTEMÁTICA DE VEHÍCULOS'], { white: true, fill: 'FF07151B' }); ws.mergeCells('A1:E1');
  add(['Formulario', i.form_code + ' · ' + i.form_rev]); add(['N°', i.number + (i.revision > 1 ? ' · revisión ' + i.revision : '')]);
  add(['Fecha y hora', dt(i.submitted_at || i.created_at)]); add(['Vehículo', (i.vehicle_name || '') + (i.vehicle_type ? ' · ' + i.vehicle_type : '') + (i.brand ? ' · ' + i.brand : '') + (i.model ? ' ' + i.model : '')]);
  add(['Patente', i.plate]); add(['Kilómetros', i.km]); add(['Realizó', i.created_by_name]); add(['Estado', i.status]);
  add(['Aprobó / rechazó', (i.reviewed_by_name || '—') + (i.reviewed_at ? ' · ' + dt(i.reviewed_at) : '')]); if (i.reject_reason) add(['Motivo del rechazo', i.reject_reason], { bold: true });
  for (let r = 2; r <= ws.rowCount; r++) { ws.getRow(r).getCell(1).font = { bold: true }; ws.mergeCells(r, 2, r, 5); }
  add([]); add(['Nº', 'DETALLE', 'RESULTADO', 'ANOMALÍA', 'OBSERVACIONES'], { white: true, fill: 'FF13212A' });
  for (const c of CATS) { add([c.categoria], { bold: true, fill: 'FFE3F9FB' }); ws.mergeCells(ws.rowCount, 1, ws.rowCount, 5);
    for (const x of c.controles) { const r = byN[x.n] || {}; const row = add([x.n, x.control, RES[r.result] || 'SIN RESPUESTA', DEF[r.defect] || '', [r.observation, r.extra_date && 'Vence ' + r.extra_date, r.extra_km != null && 'Km ' + r.extra_km].filter(Boolean).join(' · ')]);
      row.alignment = { wrapText: true, vertical: 'top' }; if (r.result === 'MAL') row.getCell(3).font = { bold: true, color: { argb: 'FFB42318' } }; } }
  const mal = items.filter(x => x.result === 'MAL'); add([]); add(['RESUMEN DE ANOMALÍAS: ' + mal.length], { bold: true });
  mal.forEach(x => add([x.item_no, (ALL.find(c => c.n === x.item_no) || {}).control, 'MAL', DEF[x.defect], x.observation]));
  if (i.general_observation) { add([]); add(['Observaciones generales', i.general_observation]); }
  add([]); add(['AUDITORÍA'], { bold: true }); events.forEach(e => add([dt(e.at), e.action + ' · ' + (e.actor_name || '')]));
  await save(wb, 'Inspeccion_' + i.number + (i.revision > 1 ? '_rev' + i.revision : '') + '_' + i.plate + '.xlsx');
}
export async function exportHistory(api, rows, f) {   // B. historial filtrado: RESUMEN · DETALLE · AUDITORÍA (solo lo que el usuario puede ver)
  const X = await loadExcelJS(), ids = rows.map(r => r.id), [items, events] = await Promise.all([api.inspItems(ids), api.inspEvents(ids)]), byId = Object.fromEntries(rows.map(r => [r.id, r]));
  const wb = new X.Workbook(), s1 = wb.addWorksheet('RESUMEN'), s2 = wb.addWorksheet('DETALLE'), s3 = wb.addWorksheet('AUDITORÍA');
  s1.columns = ['N°', 'REVISIÓN', 'FECHA', 'VEHÍCULO', 'PATENTE', 'KM', 'RESPONSABLE', 'ESTADO', 'ANOMALÍAS', 'APROBÓ / RECHAZÓ', 'FECHA DECISIÓN', 'MOTIVO RECHAZO'].map(h => ({ header: h, width: 16 }));
  rows.forEach(i => s1.addRow([i.number, i.revision, dt(i.submitted_at || i.created_at), i.vehicle_name, i.plate, i.km, i.created_by_name, i.status, i.anomalies || 0, i.reviewed_by_name || '', dt(i.reviewed_at), i.reject_reason || '']));
  s2.columns = ['N°', 'REVISIÓN', 'VEHÍCULO', 'PATENTE', 'CATEGORÍA', 'Nº CONTROL', 'CONTROL', 'RESULTADO', 'ANOMALÍA', 'OBSERVACIÓN'].map((h, k) => ({ header: h, width: [12, 9, 18, 11, 24, 10, 46, 12, 13, 40][k] }));
  items.sort((a, b) => (byId[a.inspection_id].number + a.inspection_id).localeCompare(byId[b.inspection_id].number + b.inspection_id) || a.item_no - b.item_no).forEach(x => { const i = byId[x.inspection_id], c = ALL.find(k => k.n === x.item_no), cat = CATS.find(k => k.controles.includes(c));
    s2.addRow([i.number, i.revision, i.vehicle_name, i.plate, cat.categoria, x.item_no, c.control, RES[x.result] || '', DEF[x.defect] || '', [x.observation, x.extra_date && 'Vence ' + x.extra_date, x.extra_km != null && 'Km ' + x.extra_km].filter(Boolean).join(' · ')]); });
  s3.columns = ['FECHA Y HORA', 'N°', 'REVISIÓN', 'ACCIÓN', 'USUARIO'].map((h, k) => ({ header: h, width: [20, 12, 9, 18, 28][k] }));
  events.slice().sort((a, b) => String(a.at).localeCompare(String(b.at))).forEach(e => { const i = byId[e.inspection_id]; s3.addRow([dt(e.at), i.number, i.revision, e.action, e.actor_name || '']); });
  [s1, s2, s3].forEach(headStyle);
  await save(wb, 'Historial_inspecciones_' + (f.from || 'inicio') + '_' + (f.to || 'hoy') + '.xlsx');
}
