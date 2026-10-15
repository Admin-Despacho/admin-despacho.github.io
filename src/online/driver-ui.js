// Celular del transportista (Fase 2B.1): MIS HOJAS PUBLICADAS → ver → iniciar → resultados → finalizar.
// Offline básico: cambios locales + cola con op_id (el servidor ignora un op_id repetido) + sincronización al volver.
import { esc } from './util.js';
import { ROLE_LABEL } from '../../supabase/functions/_shared/rules.js';
import { openAccount } from './account-ui.js';
import { byOrder, currentStop, futureStops } from '../../supabase/functions/_shared/internal-route.js';
import { passkeysSupported } from './webauthn.js';

const OUT = { ENTREGADO: 'ENTREGADO', ENTREGA_PARCIAL: 'ENTREGA PARCIAL', NO_ENTREGADO: 'NO ENTREGADO', REPROGRAMAR: 'REPROGRAMAR' };
const LIVE = { live: ['EN VIVO', ''], off: ['SIN CONEXIÓN', 'off'], sync: ['SINCRONIZANDO', 'sync'], rec: ['RECONECTANDO', 'rec'] };
const uid = () => 'op-' + Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
const day = iso => iso ? new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Argentina/Mendoza' }).format(new Date(iso)) : '';
const hhmm = iso => iso ? new Date(iso).toLocaleTimeString('es-AR', { hour: '2-digit', minute: '2-digit' }) : '';
const offline = e => e && (e.code === 'OFFLINE' || e.status === 0);
// Achica la foto del DNI (máx. 1600 px, JPEG) para subirla liviana; si no se puede decodificar se usa el archivo original
async function shrink(f) {
  const b64 = async blob => { const u = new Uint8Array(await blob.arrayBuffer()); let t = ''; for (let i = 0; i < u.length; i += 0x8000) t += String.fromCharCode(...u.subarray(i, i + 0x8000)); return btoa(t); };
  try {
    const bmp = await createImageBitmap(f), k = Math.min(1, 1600 / Math.max(bmp.width, bmp.height));
    const c = document.createElement('canvas'); c.width = Math.round(bmp.width * k); c.height = Math.round(bmp.height * k); c.getContext('2d').drawImage(bmp, 0, 0, c.width, c.height);
    const blob = await new Promise(r => c.toBlob(r, 'image/jpeg', 0.82));
    return { b64: await b64(blob), mime: 'image/jpeg', size: blob.size };
  } catch (e) { return { b64: await b64(f), mime: f.type, size: f.size }; }
}

export class DriverApp {
  constructor(api, me, onLogout, opts = {}) {
    this.api = api; this.me = me; this.onLogout = onLogout; this.readOnly = !!opts.readOnly; // SOLO_LECTURA: ve hojas, no ejecuta nada
    this.kC = 'okd_drv_cache:' + me.id; this.kQ = 'okd_drv_queue:' + me.id;
    this.routes = this._ls(this.kC) || []; this.queue = this._ls(this.kQ) || [];
    this.tab = 'HOY'; this.openId = null; this.conn = 'live'; this.known = new Set(this.routes.map(r => r.id));
  }
  _ls(k) { try { return JSON.parse(localStorage.getItem(k) || 'null'); } catch (e) { return null; } }
  _sv(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch (e) { } }
  start() {
    const top = document.querySelector('#noPanel .top');
    const chip = document.getElementById('np-who');
    chip.innerHTML = esc(this.me.full_name) + ' · <b>' + esc(ROLE_LABEL[this.me.role] || this.me.role) + '</b>';
    chip.onclick = () => openAccount(this.api, this.me, this.onLogout);
    document.getElementById('np-logout').onclick = this.onLogout;
    if (!document.getElementById('drvLive')) {
      const live = document.createElement('span'); live.id = 'drvLive'; live.className = 'live'; live.innerHTML = '<i></i><span>EN VIVO</span>';
      const bell = document.createElement('button'); bell.id = 'drvBell'; bell.type = 'button'; bell.className = 'bell'; bell.title = 'Hojas nuevas'; bell.innerHTML = '🔔<span class="cnt" hidden>0</span>';
      top.insertBefore(bell, chip); top.insertBefore(live, bell);
      bell.onclick = () => { this.openId = null; this.tab = 'HOY'; this.render(); };
    }
    const card = document.querySelector('#noPanel .auth-card'); card.className = 'drv'; card.id = 'drv';
    window.addEventListener('online', () => this.reconnect());
    window.addEventListener('offline', () => this.setConn('off'));
    window.addEventListener('okd-net', () => (window.OKD_NET && window.OKD_NET.offline ? this.setConn('off') : this.reconnect()));
    this.api.subscribe && this.api.subscribe(() => { if (this.conn === 'live') this.load(true); });
    this.render(); this.load('boot');
  }
  setConn(c) { this.conn = c; const el = document.getElementById('drvLive'); if (el) { el.className = 'live' + (LIVE[c][1] ? ' ' + LIVE[c][1] : ''); el.querySelector('span').textContent = LIVE[c][0]; } }
  async load(silent) {
    try {
      const fresh = this.readOnly ? await this.api.viewerRoutes() : await this.api.myRoutes();
      // Lo pendiente en la cola se superpone a lo que trae el servidor (no se pierde)
      this.routes = fresh; this._applyQueue(); this._sv(this.kC, this.routes);
      for (const r of fresh) if (!this.readOnly && !r.notified_at) { try { await this.api.markDelivered(r.id); } catch (e) { } }
      const nuevas = fresh.filter(r => !this.known.has(r.id)); nuevas.forEach(r => this.known.add(r.id));
      if (nuevas.length && silent !== 'boot') this.toast('NUEVA HOJA PUBLICADA · Hoja ' + nuevas.map(r => r.number).join(', '));
      if (this.conn !== 'sync') this.setConn(this.queue.length ? 'off' : 'live');
    } catch (e) { if (offline(e)) this.setConn('off'); }
    // No redibujar si el transportista está escribiendo una observación o un motivo
    if (silent === true && (document.querySelector('#drv .drv-form:not([hidden])') || [...document.querySelectorAll('#drvKm, #drvKmIni, #drvSearch')].some(i => i.value || document.activeElement === i))) return; // no pisar lo que se está escribiendo
    this.render();
  }
  async reconnect() {
    this.setConn('rec');
    await new Promise(r => setTimeout(r, 300));
    await this.sync();
  }
  // Sincroniza la cola en orden; un reintento con el mismo op_id no duplica en el servidor
  async sync() {
    if (this.queue.length) this.setConn('sync');
    while (this.queue.length) {
      const op = this.queue[0];
      try { await this._send(op); }
      catch (e) { if (offline(e)) { this.setConn('off'); return; } this.toast(/VERSION_CONFLICT/.test(e.message) ? 'La hoja cambió mientras no había conexión: se recargó la versión actual.' : 'No se pudo aplicar un cambio guardado: ' + e.message); }
      this.queue.shift(); this._sv(this.kQ, this.queue);
    }
    this.setConn('live'); await this.load();
  }
  _send(op) {
    const a = op.args;
    if (op.kind === 'view') return this.api.markViewed(a.route);
    if (op.kind === 'start') return this.api.startRoute(a.route, a.km);
    if (op.kind === 'outcome') return this._sendOutcome(op);
    if (op.kind === 'arrive') return this.api.arriveStop(a.stop, a.location, op.op_id);
    if (op.kind === 'finalize') return this.api.finalizeRoute(a.route, a.km);
    if (op.kind === 'addStop') return this.api.addInternalStop(a.route, a.stop, a.version, op.op_id, op.offline);
    if (op.kind === 'reorder') return this.api.reorderInternalStops(a.route, a.order, a.version, op.op_id, op.offline);
  }
  _applyLocal(op) {
    const r = this.routes.find(x => x.id === op.args.route); if (!r) return;
    const t = new Date().toISOString();
    if (op.kind === 'view') r.viewed_at = r.viewed_at || t;
    if (op.kind === 'start' && r.operational_status === 'PUBLICADA') Object.assign(r, { operational_status: 'EN_CURSO', started_at: t });
    if (op.kind === 'outcome') Object.assign(r.stops.find(s => s.id === op.args.stop) || {}, { outcome: op.args.outcome, outcome_note: op.args.note, outcome_reason: op.args.reason, outcome_at: t });
    if (op.kind === 'finalize') Object.assign(r, { operational_status: 'COMPLETADA', completed_at: t, km_end: op.args.km ?? r.km_end });
    if (op.kind === 'arrive') Object.assign(r.stops.find(s => s.id === op.args.stop) || {}, { arrived_at: t, arrive_location: op.args.location });
    if (op.kind === 'addStop' && !r.stops.some(s => s.id === op.args.stop.id)) { const n = Math.max(...r.stops.map(s => s.sequence_number ?? s.seq)) + 1;
      r.stops.push({ id: op.args.stop.id, seq: n, sequence_number: n, provenance: 'DRIVER', client_name: op.args.stop.client_name, address: op.args.stop.address, action: op.args.stop.action, bultos: op.args.stop.bultos, outcome: 'PENDIENTE', order_numbers: [] }); r.version = (r.version || 1) + 1; }
    if (op.kind === 'reorder') { const base = Math.min(...op.args.order.map(id => (r.stops.find(s => s.id === id) || {}).sequence_number || 0)); op.args.order.forEach((id, i) => { const s = r.stops.find(x => x.id === id); if (s) s.sequence_number = base + i; }); r.version = (r.version || 1) + 1; }
  }
  _applyQueue() { this.queue.forEach(op => this._applyLocal(op)); }
  // Acción: primero se guarda localmente; si no hay conexión queda en cola
  async act(kind, args) {
    const op = { op_id: uid(), kind, args, offline: this.conn !== 'live' };
    if (this.conn !== 'live') { this.queue.push(op); this._sv(this.kQ, this.queue); this._applyLocal(op); this._sv(this.kC, this.routes); this.render(); return true; }
    try { await this._send(op); this._applyLocal(op); this._sv(this.kC, this.routes); await this.load(); return true; }
    catch (e) {
      if (offline(e)) { this.setConn('off'); this.queue.push(op); this._sv(this.kQ, this.queue); this._applyLocal(op); this._sv(this.kC, this.routes); this.render(); return true; }
      this.toast(e.message); return false;
    }
  }
  toast(t) { let el = document.getElementById('drvToast'); if (!el) { el = document.createElement('div'); el.id = 'drvToast'; el.className = 'drv-toast'; document.body.appendChild(el); } el.textContent = t; el.hidden = false; clearTimeout(this._tt); this._tt = setTimeout(() => { el.hidden = true; }, 4000); }
  badge(r) {
    if (r.operational_status === 'COMPLETADA') return [r.approval_status === 'PENDIENTE' ? 'FINALIZADA · PENDIENTE DE APROBACIÓN' : r.approval_status === 'OBSERVADA' ? 'FINALIZADA · ACLARACIÓN SOLICITADA' : r.approval_status === 'APROBADA' ? 'FINALIZADA · APROBADA' : 'FINALIZADA', 'done'];
    if (r.operational_status === 'EN_CURSO') return ['EN CURSO', 'cur'];
    if (r.operational_status === 'CANCELADA') return ['CANCELADA', 'done'];
    return r.viewed_at ? ['VISTA', 'seen'] : ['NUEVA', 'new'];
  }
  render() {
    const el = document.getElementById('drv'); if (!el) return;
    const unseen = this.routes.filter(r => !r.viewed_at).length;
    const cnt = document.querySelector('#drvBell .cnt'); if (cnt) { cnt.hidden = !unseen; cnt.textContent = unseen; }
    if (this.openId) return this.renderRoute(el);
    const today = day(new Date().toISOString());
    const q = (this.q || '').trim().toLowerCase();
    const list = this.routes.filter(r => this.tab === 'HOY' ? (day(r.published_at) === today || !['COMPLETADA', 'CANCELADA'].includes(r.operational_status)) : (day(r.published_at) !== today && ['COMPLETADA', 'CANCELADA'].includes(r.operational_status)))
      .filter(r => !q || String(r.number).toLowerCase().includes(q) || r.stops.some(st => String(st.client_name).toLowerCase().includes(q)));
    const pkOffer = this.me.role === 'TRANSPORTISTA_INTERNO' && passkeysSupported() && !localStorage.getItem('okd_pk_hint');
    el.innerHTML = (pkOffer ? '<div class="drv-pk"><span>Entrá más rápido con huella o Face ID.</span><button class="btn go" type="button" id="drvPk">ACTIVAR INGRESO RÁPIDO</button></div>' : '') + '<div class="drv-title">' + (this.readOnly ? 'HOJAS · SOLO LECTURA' : 'MIS HOJAS PUBLICADAS') + '</div>' +
      (this.queue.length ? '<div class="drv-q">' + this.queue.length + ' cambio(s) guardados en el celular · se envían al volver la conexión</div>' : '') +
      '<input class="ed drv-search" id="drvSearch" placeholder="Buscar hoja o cliente" value="' + esc(this.q || '') + '">' +
      '<div class="drv-tabs"><button type="button" data-t="HOY" class="' + (this.tab === 'HOY' ? 'on' : '') + '">HOY</button><button type="button" data-t="ANT" class="' + (this.tab === 'ANT' ? 'on' : '') + '">ANTERIORES</button></div>' +
      (list.length ? list.map(r => { const [b, c] = this.badge(r), bultos = r.stops.reduce((a, s) => a + (s.bultos || 0), 0);
        return '<div class="drv-card ' + c + '" data-r="' + r.id + '"><span class="drv-badge ' + c + '">' + b + '</span><b>HOJA ' + esc(r.number) + '</b><div class="drv-tp">' + esc(r.carrier_name || r.carrier_id) + '</div>' +
          '<div class="drv-m">' + new Date(r.published_at).toLocaleDateString('es-AR') + ' · ' + r.stops.length + ' entregas' + (bultos ? ' · ' + bultos + ' bultos' : '') + '</div><button class="btn go" type="button" data-open="' + r.id + '">' + (r.operational_status === 'EN_CURSO' ? 'CONTINUAR RECORRIDO' : 'VER HOJA') + '</button></div>'; }).join('')
        : '<p class="drv-empty">' + (this.tab === 'HOY' ? 'No tenés hojas publicadas hoy.' : 'Sin hojas anteriores.') + '</p>');
    el.querySelectorAll('[data-t]').forEach(b => b.onclick = () => { this.tab = b.dataset.t; this.render(); });
    const sq = el.querySelector('#drvSearch'); sq.oninput = () => { this.q = sq.value; const pos = sq.selectionStart; this.render(); const n = document.getElementById('drvSearch'); n.focus(); n.setSelectionRange(pos, pos); };
    const pk = el.querySelector('#drvPk'); if (pk) pk.onclick = () => openAccount(this.api, this.me, this.onLogout);
    el.querySelectorAll('[data-open]').forEach(b => b.onclick = async () => { this.openId = b.dataset.open; const r = this.routes.find(x => x.id === this.openId); if (!r.viewed_at && !this.readOnly) await this.act('view', { route: r.id }); this.render(); });
  }
  renderRoute(el) {
    const r = this.routes.find(x => x.id === this.openId); if (!r) { this.openId = null; return this.render(); }
    const running = !this.readOnly && r.operational_status === 'EN_CURSO', closed = r.operational_status === 'COMPLETADA';
    const pend = r.stops.filter(s => s.outcome === 'PENDIENTE').length;
    const internal = r.carrier_id === 'INTERNO' && running, cur = currentStop(r.stops), fut = futureStops(r.stops).map(s => s.id);
    el.innerHTML = '<button class="linkbtn" type="button" id="drvBack">← Mis hojas</button><div class="drv-title">HOJA ' + esc(r.number) + ' · ' + esc(r.carrier_name || r.carrier_id) + '</div>' +
      '<div class="drv-m">' + r.stops.length + ' entregas · ' + this.badge(r)[0] + (r.started_at ? ' · iniciada ' + hhmm(r.started_at) : '') + (closed ? ' · finalizada ' + hhmm(r.completed_at) : '') + '</div>' +
      (r.approval_status === 'OBSERVADA' && r.review_note ? '<div class="drv-q">ACLARACIÓN SOLICITADA: ' + esc(r.review_note) + '</div>' : '') +
      byOrder(r.stops).map((s, i) => '<div class="drv-stop' + (internal && cur && s.id === cur.id ? ' cur' : '') + (internal && fut.includes(s.id) ? ' fut' : '') + (s.provenance === 'DRIVER' ? ' drv-new' : '') + '" data-s="' + s.id + '"' + (internal && fut.includes(s.id) ? ' draggable="true"' : '') + '><div class="drv-sh"><i>' + (i + 1) + '</i><div><b>' + esc(s.client_name) + '</b>' + (s.provenance === 'DRIVER' ? '<span class="drv-tag">AGREGADA</span>' : '') + (internal && cur && s.id === cur.id ? '<span class="drv-tag">ACTUAL</span>' : '') + (s.action && s.action !== 'ENTREGA' ? ' · ' + esc(s.action) : '') + (s.bultos ? ' · ' + s.bultos + ' bultos' : '') + '<small>' + esc(s.address || '') + (s.order_numbers && s.order_numbers.length ? ' · Pedido ' + esc(s.order_numbers.join(' + ')) : '') + '</small></div>' +
        (s.outcome !== 'PENDIENTE' ? '<span class="drv-out ' + s.outcome + '">' + OUT[s.outcome] + '</span>' : (internal && fut.includes(s.id) ? '<span class="drv-move"><button type="button" data-up title="Subir">↑</button><button type="button" data-down title="Bajar">↓</button></span>' : '')) + '</div>' +
        (s.outcome_note || s.outcome_reason ? '<small class="drv-note">' + esc(s.outcome_note || s.outcome_reason) + '</small>' : '') +
        (s.location_warning ? '<small class="drv-note"><b>⚠ ' + esc(s.location_warning) + '</b></small>' : '') +
        (running ? '<div class="drv-acts">' + Object.keys(OUT).map(k => '<button type="button" class="btn ' + (s.outcome === k ? 'dark' : 'soft') + '" data-o="' + k + '">' + OUT[k] + '</button>').join('') + '</div>' +
          '<div class="drv-form" hidden></div>' : '') +
        (running && s.outcome === 'PENDIENTE' && cur && s.id === cur.id ? (s.arrived_at ? '<small class="drv-note">Llegada registrada ' + hhmm(s.arrived_at) + (s.arrive_location && s.arrive_location.missing_reason ? ' · sin ubicación' : '') + '</small>' : '<button class="btn soft drv-arrive" type="button" data-arrive>LLEGUÉ A LA PARADA</button>') : '') + '</div>').join('') +
      (internal ? '<button class="btn soft" type="button" id="drvAddOpen">+ AGREGAR PARADA</button><div class="drv-add" id="drvAdd" hidden><input class="ed" id="naName" placeholder="Destino / cliente"><input class="ed" id="naAddr" placeholder="Dirección">' +
        '<select class="ed" id="naAct"><option>ENTREGA</option><option>RETIRO</option><option>TRÁMITE</option></select><input class="ed" id="naBul" inputmode="numeric" placeholder="Bultos"><button class="btn dark" type="button" id="naSave">AGREGAR</button><span class="shiperr" id="naErr" hidden></span></div>' : '') +
      (r.operational_status === 'PUBLICADA' && !this.readOnly && r.vehicle_id ? '<label class="drv-km">KM INICIAL del vehículo ' + esc(r.vehicle_plate || '') + ' (obligatorio) <input class="ed" id="drvKmIni" inputmode="numeric"></label>' : '') +
      '<div class="drv-foot">' + (r.operational_status === 'PUBLICADA' && !this.readOnly ? '<button class="btn go" type="button" id="drvStart">INICIAR RECORRIDO</button><small>Abrir la hoja no inicia el recorrido.</small>' : '') +
      (running && r.vehicle_id ? '<label class="drv-km">KM FINAL del vehículo (inicial ' + (r.km_start ?? '—') + ') <input class="ed" id="drvKm" inputmode="numeric"></label>' : '') +
      (running ? '<button class="btn go" type="button" id="drvFin"' + (pend ? ' disabled' : '') + '>FINALIZAR HOJA</button>' + (pend ? '<small>Faltan ' + pend + ' entregas por resolver.</small>' : '') : '') +
      (closed ? '<b class="drv-closed">HOJA FINALIZADA · solo lectura</b><button class="btn dark" type="button" id="drvPdf">DESCARGAR PDF</button>' +
        (!this.readOnly && this.canReturn(r) ? '<button class="btn soft" type="button" id="drvRet">DEVOLVER HOJA</button><div class="drv-form" id="drvRetForm" hidden><input class="ed" id="drvRetWhy" placeholder="Motivo (obligatorio)"><button class="btn dark" type="button" id="drvRetGo">ENVIAR SOLICITUD</button><span class="shiperr" hidden></span></div>' : '') : '') + '</div>';
    el.querySelector('#drvBack').onclick = () => { this.openId = null; this.render(); };
    if (internal) this.bindInternal(el, r, fut);
    const st = el.querySelector('#drvStart'); if (st) st.onclick = async () => {
      const ki = el.querySelector('#drvKmIni'), km = ki ? ki.value.trim().replace(/\./g, '') : null;
      if (ki && !/^\d+$/.test(km)) { this.toast('Cargá el kilometraje inicial del vehículo.'); return; }
      st.disabled = true; await this.act('start', { route: r.id, km: km ? Number(km) : null }); this.render(); };
    const fin = el.querySelector('#drvFin'); if (fin) fin.onclick = async () => {
      const kmI = el.querySelector('#drvKm'); const km = kmI ? kmI.value.trim() : null;
      if (kmI && (!km || Number(km) < Number(r.km_start || 0))) { this.toast(!km ? 'Cargá el kilometraje final.' : 'El kilometraje no puede ser menor a ' + r.km_start + '.'); return; }
      if (!confirm('¿Finalizar la hoja ' + r.number + '? Después queda solo lectura.')) return; fin.disabled = true; await this.act('finalize', { route: r.id, km: km ? Number(km) : null }); this.render(); };
    const pdf = el.querySelector('#drvPdf'); if (pdf) pdf.onclick = () => this.downloadPdf(r);
    const ret = el.querySelector('#drvRet'); if (ret) { const f = el.querySelector('#drvRetForm'); ret.onclick = () => { f.hidden = false; };
      el.querySelector('#drvRetGo').onclick = async () => { const why = el.querySelector('#drvRetWhy').value.trim(), er = f.querySelector('.shiperr'); if (!why) { er.textContent = 'Indicá el motivo.'; er.hidden = false; return; }
        try { await this.api.requestRouteReturn(r.id, why); this.toast('Solicitud enviada a Administración. La hoja no se modifica hasta que la resuelvan.'); f.hidden = true; } catch (e) { er.textContent = e.message; er.hidden = false; } }; }
    el.querySelectorAll('[data-arrive]').forEach(b => b.onclick = async () => { const sid = b.closest('.drv-stop').dataset.s; b.disabled = true; const loc = await this.locate(b.closest('.drv-stop')); if (!loc) { b.disabled = false; return; } await this.act('arrive', { route: r.id, stop: sid, location: loc }); this.render(); });
    el.querySelectorAll('.drv-stop').forEach(box => {
      const sid = box.dataset.s, st = r.stops.find(x => x.id === sid);
      box.querySelectorAll('[data-o]').forEach(b => b.onclick = () => this.openForm(box, r, st, b.dataset.o));
    });
  }
  // Ruta interna: agregar parada y reordenar SOLO las futuras (arrastrar o ↑↓). La actual y las resueltas quedan fijas.
  bindInternal(el, r, fut) {
    const reorder = async order => { if (order.join() === fut.join()) return; await this.act('reorder', { route: r.id, order, version: r.version || 1 }); this.render(); };
    el.querySelectorAll('.drv-stop.fut').forEach(box => {
      const id = box.dataset.s, i = fut.indexOf(id);
      const up = box.querySelector('[data-up]'), down = box.querySelector('[data-down]');
      if (up) up.onclick = () => { if (i > 0) { const o = fut.slice(); [o[i - 1], o[i]] = [o[i], o[i - 1]]; reorder(o); } };
      if (down) down.onclick = () => { if (i < fut.length - 1) { const o = fut.slice(); [o[i + 1], o[i]] = [o[i], o[i + 1]]; reorder(o); } };
      box.addEventListener('dragstart', e => { box.classList.add('dragging'); e.dataTransfer.setData('text/plain', id); });
      box.addEventListener('dragend', () => box.classList.remove('dragging'));
      box.addEventListener('dragover', e => e.preventDefault());
      box.addEventListener('drop', e => { e.preventDefault(); const from = e.dataTransfer.getData('text/plain'); if (!fut.includes(from) || from === id) return;
        const o = fut.filter(x => x !== from); o.splice(o.indexOf(id) + (fut.indexOf(from) < fut.indexOf(id) ? 1 : 0), 0, from); reorder(o); });
    });
    const open = el.querySelector('#drvAddOpen'), form = el.querySelector('#drvAdd');
    open.onclick = () => { form.hidden = false; form.querySelector('#naName').focus(); };
    form.querySelector('#naSave').onclick = async () => {
      const name = form.querySelector('#naName').value.trim(), er = form.querySelector('#naErr');
      if (!name) { er.textContent = 'Indicá el destino.'; er.hidden = false; return; }
      await this.act('addStop', { route: r.id, version: r.version || 1, stop: { id: (crypto.randomUUID ? crypto.randomUUID() : uid()), client_name: name, address: form.querySelector('#naAddr').value.trim(), action: form.querySelector('#naAct').value, bultos: form.querySelector('#naBul').value.trim() || null } });
      this.render();
    };
  }
  // La foto del DNI se sube a Storage privado recién al enviar (también al sincronizar una acción hecha sin conexión)
  async _sendOutcome(op) {
    const a = op.args, ev = a.extra && a.extra.evidence;
    if (ev && ev.dni_upload) { ev.dni_storage_path = await this.api.uploadIdentityDoc(ev.cuil, ev.dni_upload); delete ev.dni_upload; this._sv(this.kQ, this.queue); }
    return this.api.setStopOutcome(a.stop, a.outcome, a.note, a.reason, op.op_id, a.extra);
  }
  canReturn(r) {
    if (r.operational_status !== 'COMPLETADA' || !r.completed_at) return false;
    return (Date.parse(day(new Date().toISOString())) - Date.parse(day(r.completed_at))) / 86400000 <= 2;
  }
  async downloadPdf(r) {
    const { routePdf, routeHistory } = await import('../../supabase/functions/_shared/route-pdf.js');
    const veh = r.vehicle_id && this.api.listVehicles ? (await this.api.listVehicles().catch(() => [])).find(v => v.id === r.vehicle_id) : null;
    const bytes = await routePdf({ route: r, driverName: this.me.full_name, carrierName: r.carrier_name, vehicle: veh, history: routeHistory(r) });
    const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob([bytes], { type: 'application/pdf' })); a.download = 'Hoja_' + r.number + '.pdf'; document.body.appendChild(a); a.click(); a.remove();
  }
  // Ubicación puntual (solo al llegar y al finalizar la parada). Si no se puede: motivo obligatorio. Nunca se inventa.
  locate(box) {
    return new Promise(resolve => {
      const ask = () => {
        let f = box.querySelector('.drv-noloc');
        if (!f) { f = document.createElement('div'); f.className = 'drv-form drv-noloc'; f.innerHTML = '<span class="shiperr">No se pudo obtener la ubicación.</span><input class="ed" data-f="noloc" placeholder="Motivo (obligatorio)"><button class="btn dark" type="button" data-nl>REGISTRAR SIN UBICACIÓN</button>'; box.appendChild(f); }
        f.hidden = false;
        f.querySelector('[data-nl]').onclick = () => { const why = f.querySelector('[data-f="noloc"]').value.trim(); if (!why) { f.querySelector('.shiperr').textContent = 'Indicá el motivo para registrar sin ubicación.'; return; } f.hidden = true; resolve({ missing_reason: why }); };
      };
      if (!navigator.geolocation) return ask();
      navigator.geolocation.getCurrentPosition(p => resolve({ lat: p.coords.latitude, lon: p.coords.longitude, accuracy: p.coords.accuracy }), ask, { enableHighAccuracy: true, timeout: 8000, maximumAge: 30000 });
    });
  }
  // Resolver parada: receptor + firma (ENTREGADO/PARCIAL), CUIL/DNI (Cristian), cobranza (si corresponde), observación/motivo y ubicación final
  openForm(box, r, st, o) {
    const form = box.querySelector('.drv-form'); form.hidden = false; form.dataset.o = o;
    const delivered = o === 'ENTREGADO' || o === 'ENTREGA_PARCIAL', cristian = ['CT-ESTE', 'CT-ALR'].includes(r.carrier_id), cob = ['COBRANZA', 'AMBAS'].includes(st.task);
    form.innerHTML = '<b class="drv-ft">' + OUT[o] + '</b>' +
      (delivered ? '<input class="ed" data-f="recv" placeholder="Nombre de quien recibe (obligatorio)"><div class="sigbox"><canvas width="300" height="120" data-sig></canvas><button type="button" class="linkbtn" data-sigclr>Borrar firma</button></div>' +
        (cristian ? '<input class="ed" data-f="cuil" inputmode="numeric" placeholder="CUIL de quien recibe (11 dígitos)"><span class="drv-dni" data-dni></span>' : '') +
        // RC4.1: email del cliente en esta MISMA pantalla (identidad + evidencia + contacto); opcional. Con email válido y entrega total se envía el Recibido Conforme.
        '<input class="ed" data-f="email" type="email" inputmode="email" autocomplete="off" placeholder="Email del cliente (opcional · Recibido Conforme)"><span class="drv-mailhint" data-mailhint></span>' : '') +
      (cob ? '<div class="drv-cob"><b>COBRANZA</b>' + (st.expected_amount != null ? ' · esperado $ ' + Number(st.expected_amount).toLocaleString('es-AR') : '') +
        '<select class="ed" data-f="cst"><option value="">Resultado de la cobranza…</option><option value="COBRADO">COBRADO</option><option value="COBRO_PARCIAL">COBRO PARCIAL</option><option value="NO_COBRADO">NO COBRADO</option></select>' +
        '<input class="ed" data-f="camt" inputmode="decimal" placeholder="Importe cobrado"><select class="ed" data-f="cmode"><option value="">Modo de pago…</option><option>EFECTIVO</option><option>TRANSFERENCIA</option><option>CHEQUE</option></select><input class="ed" data-f="cnote" placeholder="Observación / motivo de la cobranza"></div>' : '') +
      (o === 'ENTREGA_PARCIAL' ? '<input class="ed" data-f="txt" placeholder="Observación (obligatoria)">' : o !== 'ENTREGADO' ? '<input class="ed" data-f="txt" placeholder="Motivo (obligatorio)">' : '') +
      '<button class="btn dark" type="button" data-save>GUARDAR</button><span class="shiperr" hidden></span>';
    const er = form.querySelector('.shiperr'), fail = t => { er.textContent = t; er.hidden = false; };
    // firma táctil
    const cv = form.querySelector('[data-sig]'); let drawn = false;
    if (cv) { const ctx = cv.getContext('2d'); ctx.lineWidth = 2.2; ctx.lineCap = 'round'; ctx.strokeStyle = '#000E18'; let down = false;
      const pos = e => { const b = cv.getBoundingClientRect(); return [(e.clientX - b.left) * cv.width / b.width, (e.clientY - b.top) * cv.height / b.height]; };
      cv.onpointerdown = e => { down = true; cv.setPointerCapture(e.pointerId); ctx.beginPath(); ctx.moveTo(...pos(e)); };
      cv.onpointermove = e => { if (!down) return; ctx.lineTo(...pos(e)); ctx.stroke(); drawn = true; };
      cv.onpointerup = () => { down = false; };
      form.querySelector('[data-sigclr]').onclick = () => { ctx.clearRect(0, 0, cv.width, cv.height); drawn = false; }; }
    // Autocompletar con el perfil reutilizable (CUIL → DNI → cliente). Sin conexión, simplemente no se completa.
    const em = form.querySelector('[data-f="email"]'), hint = form.querySelector('[data-mailhint]'), rv = form.querySelector('[data-f="recv"]');
    const fill = async cuil => {
      if (!em || !this.api.deliveryIdentityLookup) return;
      const p = await this.api.deliveryIdentityLookup(st.id, cuil || null).catch(() => null);
      if (!p) return;
      if (p.email && (!em.value || em.dataset.auto === '1')) { em.value = p.email; em.dataset.auto = '1'; hint.textContent = 'Email recuperado del cliente (podés corregirlo)'; }
      if (p.full_name && rv && !rv.value) rv.value = p.full_name;
    };
    if (em) { em.oninput = () => { em.dataset.auto = ''; hint.textContent = ''; }; fill(null); }
    // DNI: si el CUIL ya tiene DNI no se pide foto
    let dni = null; const cu = form.querySelector('[data-f="cuil"]');
    if (cu) cu.onchange = async () => {
      const n = cu.value.replace(/\D/g, ''), box2 = form.querySelector('[data-dni]');
      if (n.length !== 11) { box2.textContent = 'El CUIL debe tener 11 dígitos.'; return; }
      fill(n);
      const has = await this.api.cuilHasDni(n).catch(() => false);
      box2.innerHTML = has ? '✓ DNI YA REGISTRADO' : 'CUIL nuevo · foto del DNI (opcional, JPEG/PNG hasta 5 MB) <input type="file" accept="image/jpeg,image/png" capture="environment" data-dnifile>';
      const fi = box2.querySelector('[data-dnifile]');
      if (fi) fi.onchange = async () => { dni = null; const f = fi.files[0]; if (!f) return;
        if (!['image/jpeg', 'image/png'].includes(f.type)) { fail('La foto del DNI debe ser JPEG o PNG.'); fi.value = ''; return; }
        if (f.size > 5242880) { fail('La foto del DNI supera 5 MB.'); fi.value = ''; return; }
        dni = await shrink(f); er.hidden = true; };
    };
    form.querySelector('[data-save]').onclick = async ev => {
      er.hidden = true;
      const txt = (form.querySelector('[data-f="txt"]') || {}).value; const extra = {};
      if (o === 'ENTREGA_PARCIAL' && !String(txt || '').trim()) return fail('Entrega parcial exige observación.');
      if (['NO_ENTREGADO', 'REPROGRAMAR'].includes(o) && !String(txt || '').trim()) return fail('Indicá el motivo.');
      if (delivered) {
        const recv = form.querySelector('[data-f="recv"]').value.trim();
        if (!recv) return fail('Indicá el nombre de quien recibe.');
        if (!drawn) return fail('Falta la firma de quien recibe.');
        extra.evidence = { receiver_name: recv, signature_png_b64: cv.toDataURL('image/png').split(',')[1] };
        if (cristian) { const n = cu.value.replace(/\D/g, ''); if (n.length !== 11) return fail('El CUIL debe tener 11 dígitos.'); extra.evidence.cuil = n; if (dni) extra.evidence.dni_upload = dni; }
        const mail = em ? em.value.trim().toLowerCase() : '';
        if (mail && !/^[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}$/i.test(mail)) return fail('El email del cliente no es válido (podés dejarlo vacío).');
        if (mail) extra.evidence.email = mail;
      }
      if (cob) {
        const cst = form.querySelector('[data-f="cst"]').value, amt = form.querySelector('[data-f="camt"]').value.replace(/\./g, '').replace(',', '.'), note = form.querySelector('[data-f="cnote"]').value.trim();
        if (!cst) return fail('Indicá el resultado de la cobranza.');
        if (cst !== 'NO_COBRADO' && !(Number(amt) > 0)) return fail('Indicá el importe cobrado.');
        if (cst !== 'COBRADO' && !note) return fail(cst === 'COBRO_PARCIAL' ? 'Cobro parcial exige observación.' : 'No cobrado exige motivo.');
        extra.collection = { status: cst, amount: cst === 'NO_COBRADO' ? null : Number(amt), mode: form.querySelector('[data-f="cmode"]').value || null, note: note || null };
      }
      ev.target.disabled = true;
      const loc = await this.locate(box); if (!loc) { ev.target.disabled = false; return; }
      extra.location = loc;
      const ok = await this.act('outcome', { route: r.id, stop: st.id, outcome: o, note: o === 'ENTREGA_PARCIAL' ? txt : null, reason: ['NO_ENTREGADO', 'REPROGRAMAR'].includes(o) ? txt : null, extra });
      if (!ok) ev.target.disabled = false; this.render();
    };
  }
}