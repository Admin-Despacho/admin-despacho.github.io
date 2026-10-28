// Celular del transportista (Fase 2B.1): MIS HOJAS PUBLICADAS → ver → iniciar → resultados → finalizar.
// Offline básico: cambios locales + cola con op_id (el servidor ignora un op_id repetido) + sincronización al volver.
import { canSwitch, switcherHtml } from './role-view.js';
import { esc } from './util.js';
import { ROLE_LABEL } from '../../supabase/functions/_shared/rules.js';
import { openAccount } from './account-ui.js';
import { byOrder, currentStop, futureStops } from '../../supabase/functions/_shared/internal-route.js';
import { passkeysSupported } from './webauthn.js';

const OUT = { ENTREGADO: 'ENTREGADO', ENTREGA_PARCIAL: 'ENTREGA PARCIAL', NO_ENTREGADO: 'NO ENTREGADO', REPROGRAMAR: 'REPROGRAMAR' };
// Perfil del chofer por la CONFIGURACIÓN del transportista de la hoja (carriers.kind), nunca por nombres:
// EXTERNO (p. ej. Cristian Torres): sin LLEGADA A DESTINO · INTERNO (p. ej. Gabriel Figueroa): con LLEGADA A DESTINO.
const isInternal = r => r && r.carrier_kind === 'INTERNO';
// Resultados por tipo: TAREA (operativa) y UBICACIÓN INTERNA (traslado entre sucursales) no son entregas al cliente
const outLabel = (s, k) => s && s.stop_type === 'TAREA'
  ? ({ ENTREGADO: 'REALIZADO', ENTREGA_PARCIAL: 'REALIZADO PARCIAL', NO_ENTREGADO: 'NO REALIZADO', REPROGRAMAR: 'REPROGRAMAR' }[k] || OUT[k])
  : s && s.stop_type === 'UBICACION_INTERNA'
    ? ({ ENTREGADO: 'RECIBIDO EN SUCURSAL', ENTREGA_PARCIAL: 'RECEPCIÓN PARCIAL', NO_ENTREGADO: 'NO RECIBIDO', REPROGRAMAR: 'REPROGRAMAR' }[k] || OUT[k])
    : OUT[k];
// Contadores GENERALES de una hoja: en Transporte Interno se mezclan traslados, tareas y entregas → "paradas". Externos: "entregas".
const stopNoun = (r, n) => isInternal(r) ? (n === 1 ? 'parada' : 'paradas') : (n === 1 ? 'entrega' : 'entregas');
// Observación / instrucciones de la parada (TAREA, UBICACIÓN INTERNA y paradas agregadas por el chofer)
const stopInfo = s => {
  const contact = [s.contact_name, s.contact_phone].filter(Boolean).join(' · ');
  if (s.stop_type === 'UBICACION_INTERNA') return '<div class="drv-loc"><b>TRASLADO INTERNO</b> · no es entrega al cliente' +
    ((s.order_numbers || []).length ? '<div class="drv-locorders"><b>PEDIDOS (' + s.order_numbers.length + ')</b> ' + s.order_numbers.map(n => '<span>' + esc(n) + '</span>').join('') + '</div>' : '') +
    (s.instructions ? '<div class="drv-obs"><b>OBSERVACIÓN</b><span>' + esc(s.instructions) + '</span></div>' : '') +
    (s.expected_radius_m ? '<small>GPS: radio ' + esc(s.expected_radius_m) + ' m</small>' : '') + '</div>';
  if (s.stop_type === 'TAREA' || s.instructions) return '<div class="drv-loc">' + (s.stop_type === 'TAREA' ? '<b>TAREA</b>' : '') +
    (s.instructions ? '<div class="drv-obs"><b>' + (s.stop_type === 'TAREA' ? 'INSTRUCCIONES' : 'OBSERVACIÓN') + '</b><span>' + esc(s.instructions) + '</span></div>' : '') +
    (contact ? '<small>Contacto: ' + esc(contact) + '</small>' : '') + '</div>';
  return '';
};
const LIVE = { live: ['EN VIVO', ''], off: ['SIN CONEXIÓN', 'off'], sync: ['SINCRONIZANDO', 'sync'], rec: ['RECONECTANDO', 'rec'] };
const uid = () => 'op-' + Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
const day = iso => iso ? new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Argentina/Mendoza' }).format(new Date(iso)) : '';
const hhmm = iso => iso ? new Date(iso).toLocaleTimeString('es-AR', { hour: '2-digit', minute: '2-digit' }) : '';
const offline = e => e && (e.code === 'OFFLINE' || e.status === 0);
// Foto DNI: comprimir en el celular sin librerías extras (máx. 1200 px, JPEG).
// Foto del DNI liviana SIN picos de memoria (V4.16). Causa del "memoria insuficiente": se decodificaba la foto ORIGINAL a resolución
// completa (createImageBitmap sin tamaño) y después se copiaba a base64 por concatenación de texto; si fallaba, se pasaba a base64 el
// archivo original entero. Ahora: se pide al navegador decodificarla YA REDUCIDA (resizeWidth), un solo canvas chico, JPEG 0,75 con
// el lado mayor en 1600 px, se devuelve un Blob (nunca base64) y se liberan bitmap y canvas siempre.
// Dimensiones desde el ENCABEZADO del archivo (JPEG/PNG), sin decodificar la imagen. null si no se pueden leer.
export async function imageDims(f) {
  try {
    const b = new Uint8Array(await f.slice(0, 512 * 1024).arrayBuffer());
    if (b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4E && b[3] === 0x47) {   // PNG: IHDR
      const v = (o) => ((b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]) >>> 0; return { w: v(16), h: v(20) };
    }
    if (b[0] === 0xFF && b[1] === 0xD8) {   // JPEG: primer SOFn
      let o = 2;
      while (o + 9 < b.length) {
        if (b[o] !== 0xFF) { o++; continue; }
        const m = b[o + 1]; if (m === 0xD8 || m === 0x01 || (m >= 0xD0 && m <= 0xD7)) { o += 2; continue; }
        const len = (b[o + 2] << 8) | b[o + 3];
        if (m >= 0xC0 && m <= 0xCF && m !== 0xC4 && m !== 0xC8 && m !== 0xCC) return { h: (b[o + 5] << 8) | b[o + 6], w: (b[o + 7] << 8) | b[o + 8] };
        o += 2 + len;
      }
    }
  } catch (e) { }
  return null;
}
// Foto del DNI liviana SIN picos de memoria (V4.16/V4.17). Causa del "memoria insuficiente": se decodificaba la foto ORIGINAL a resolución
// completa y se copiaba a base64. Ahora se decodifica YA REDUCIDA (lado mayor 1600 px), un solo canvas chico, JPEG 0,75, Blob (sin base64).
// V4.17: NUNCA se vuelve a abrir el original sin límites. Solo una imagen con dimensiones CONOCIDAS (leídas del encabezado) y chicas
// (≤ 1600 px por lado) se decodifica entera; el peso del archivo no decide (una imagen de pocos KB puede tener dimensiones enormes).
export async function processDniPhoto(f, opts = {}) {
  const MAX = opts.max || 1600, Q = opts.quality || 0.75, t0 = (globalThis.performance || Date).now();
  if (!f || !/^image\//i.test(f.type || '')) throw new Error('el archivo no es una imagen');
  const dims = await imageDims(f), small = !!(dims && dims.w > 0 && dims.h > 0 && dims.w <= MAX && dims.h <= MAX);
  let bmp = null, c = null;
  try {
    if (small) bmp = await createImageBitmap(f);   // chica y con tamaño conocido: decodificarla entera no genera un pico
    else {
      const k = dims && dims.w > 0 && dims.h > 0 ? MAX / Math.max(dims.w, dims.h) : null;
      const o = k ? { resizeWidth: Math.max(1, Math.round(dims.w * k)), resizeHeight: Math.max(1, Math.round(dims.h * k)), resizeQuality: 'medium' } : { resizeWidth: MAX, resizeQuality: 'medium' };
      try { bmp = await createImageBitmap(f, o); }
      catch (e) { throw new Error('este celular no pudo reducir la foto; no se abre la original completa para no agotar la memoria'); }
    }
    const k2 = Math.min(1, MAX / Math.max(bmp.width, bmp.height));
    c = document.createElement('canvas'); c.width = Math.max(1, Math.round(bmp.width * k2)); c.height = Math.max(1, Math.round(bmp.height * k2));
    c.getContext('2d').drawImage(bmp, 0, 0, c.width, c.height);
    const w = c.width, h = c.height; bmp.close(); bmp = null;
    const blob = await new Promise(r => c.toBlob(r, 'image/jpeg', Q));
    if (!blob) throw new Error('no se pudo generar la imagen');
    return { blob, mime: 'image/jpeg', size: blob.size, w, h, original: f.size, srcW: dims ? dims.w : null, srcH: dims ? dims.h : null, ms: Math.round((globalThis.performance || Date).now() - t0) };
  } finally { if (bmp) bmp.close(); if (c) { c.width = 0; c.height = 0; } }
}
// Fotos de la cola SIN CONEXIÓN: Blob en IndexedDB (no base64 en localStorage, que se llenaba y fallaba en silencio)
const BLOBS = {
  _db: null,
  open() { return this._db || (this._db = new Promise((ok, ko) => { const q = indexedDB.open('okd_drv_blobs', 1); q.onupgradeneeded = () => q.result.createObjectStore('b'); q.onsuccess = () => ok(q.result); q.onerror = () => ko(q.error); })); },
  async put(k, v) { const d = await this.open(); return new Promise((ok, ko) => { const t = d.transaction('b', 'readwrite'); t.objectStore('b').put(v, k); t.oncomplete = () => ok(true); t.onerror = () => ko(t.error); }); },
  async get(k) { const d = await this.open(); return new Promise((ok, ko) => { const q = d.transaction('b').objectStore('b').get(k); q.onsuccess = () => ok(q.result || null); q.onerror = () => ko(q.error); }); },
  async del(k) { const d = await this.open(); return new Promise(ok => { const t = d.transaction('b', 'readwrite'); t.objectStore('b').delete(k); t.oncomplete = () => ok(true); t.onerror = () => ok(false); }); }
};
const kb = n => (n >= 1048576 ? (n / 1048576).toFixed(1) + ' MB' : Math.max(1, Math.round(n / 1024)) + ' KB');

export class DriverApp {
  constructor(api, me, onLogout, opts = {}) {
    this.api = api; this.me = me; this.onLogout = onLogout; this.opts = opts; this.readOnly = !!opts.readOnly; // SOLO_LECTURA: ve hojas, no ejecuta nada
    this.kC = 'okd_drv_cache:' + me.id; this.kQ = 'okd_drv_queue:' + me.id;
    this.routes = this._ls(this.kC) || []; this.queue = this._ls(this.kQ) || [];
    this.tab = 'HOY'; this.openId = null; this.conn = 'live'; this.known = new Set(this.routes.map(r => r.id));
  }
  _ls(k) { try { return JSON.parse(localStorage.getItem(k) || 'null'); } catch (e) { return null; } }
  _sv(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); return true; } catch (e) { return false; } }
  // antes de dejar una entrega en la cola: la foto del DNI pasa a IndexedDB y en la cola queda solo su referencia
  async _stash(op) {
    const ev = op.kind === 'outcome' && op.args.extra && op.args.extra.evidence;
    if (ev && ev.dni_upload && ev.dni_upload.blob) { const k = 'dni:' + op.op_id; await BLOBS.put(k, ev.dni_upload.blob);
      ev.dni_blob = { key: k, mime: ev.dni_upload.mime, size: ev.dni_upload.size }; delete ev.dni_upload; }
  }
  async _enqueue(op) {
    try { await this._stash(op); } catch (e) { this.toast('No se pudo guardar la foto en el celular: liberá espacio y reintentá. Los datos cargados se conservan.'); return false; }
    this.queue.push(op);
    if (!this._sv(this.kQ, this.queue)) { this.queue.pop(); this.toast('No se pudo guardar el cambio en el celular. Los datos cargados se conservan: reintentá.'); return false; }
    this._applyLocal(op); this._sv(this.kC, this.routes); this.render(); return true;
  }
  start() {
    const top = document.querySelector('#noPanel .top');
    const chip = document.getElementById('np-who');
    chip.innerHTML = esc(this.me.full_name) + ' · <b>' + esc(ROLE_LABEL[this.me.role] || this.me.role) + '</b>';
    // ⇄ Cambiar rol (usuarios habilitados para su perfil habitual y para Transportista): debajo del nombre
    if (canSwitch(this.me) && !document.querySelector('#noPanel [data-rolesw-box]')) chip.insertAdjacentHTML('afterend', switcherHtml(this.me));
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
    // Una cola conservada tras reabrir la PWA debe intentar sincronizarse.
    // No depender exclusivamente del evento online: Android puede conservar 4G
    // sin disparar un nuevo evento después de un fallo temporal de Supabase.
    this.render(); this.load('boot').then(() => { if (this.queue.length && navigator.onLine) this.reconnect(); });
    this._retryTimer = setInterval(() => {
      if (this.queue.length && navigator.onLine && !this._syncing) this.reconnect();
    }, 15000);
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
    // No redibujar si el transportista está usando un formulario: resultado de una parada, "+ AGREGAR PARADA" (#drvAdd), km o búsqueda.
    // Vale para los avisos en tiempo real/periódicos (silent = true) Y para el fin de la carga inicial ('boot'): antes, un aviso que
    // llegaba con "Agregar parada" abierto lo cerraba y borraba lo escrito (falla intermitente). Los datos ya quedaron actualizados;
    // el redibujo se hace en la próxima carga o al guardar/cerrar el formulario.
    const busy = document.querySelector('#drv .drv-form:not([hidden]), #drvAdd:not([hidden])') || [...document.querySelectorAll('#drvKm, #drvKmIni, #drvSearch')].some(i => i.value || document.activeElement === i);
    if ((silent === true || silent === 'boot') && busy) return; // no pisar lo que se está escribiendo
    this.render();
  }
  async reconnect() {
    this.setConn('rec');
    await new Promise(r => setTimeout(r, 300));
    await this.sync();
  }
  // Sincroniza la cola en orden; un reintento con el mismo op_id no duplica en el servidor
  async sync() {
    if (this._syncing) return;
    this._syncing = true;
    try {
    if (this.queue.length) this.setConn('sync');
    while (this.queue.length) {
      const op = this.queue[0];
      try { await this._send(op); }
      catch (e) {
        // Nunca descartar una operación que el servidor NO confirmó.
        this.setConn('off');
        if (!offline(e)) this.toast(/VERSION_CONFLICT/.test(e.message) ? 'Conflicto al sincronizar: se conservó el cambio pendiente. Avisá a Administración.' : 'No se pudo sincronizar: el cambio sigue guardado en este celular. ' + e.message);
        // rechazo por permiso (p. ej. se quitó con la app abierta): la operación QUEDA en la cola; se verifica y se vuelve al perfil
        if (!offline(e) && this.opts && this.opts.onForbidden && /FORBIDDEN|42501/.test(String(e.code || e.message || ''))) this.opts.onForbidden();
        return;
      }
      this.queue.shift(); this._sv(this.kQ, this.queue);
    }
    this.setConn('live'); await this.load();
    } finally { this._syncing = false; }
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
    if (op.kind === 'addStop' && !r.stops.some(s => s.id === op.args.stop.id)) {
      const s = op.args.stop || {};
      const n = Math.max(0, ...r.stops.map(x => x.sequence_number ?? x.seq ?? 0)) + 1;
      const stopType = s.stop_type === 'UBICACION_INTERNA' ? 'UBICACION_INTERNA' : 'TAREA';
      r.stops.push({
        id: s.id, seq: n, sequence_number: n, provenance: 'DRIVER',
        stop_type: stopType, client_name: s.client_name, client_key: stopType === 'UBICACION_INTERNA' ? (s.internal_location_key || null) : null,
        address: s.address, action: s.action || 'ENTREGA', bultos: s.bultos || null,
        instructions: s.instructions || null, contact_name: s.contact_name || null, contact_phone: s.contact_phone || null,
        internal_location_key: stopType === 'UBICACION_INTERNA' ? (s.internal_location_key || null) : null,
        expected_lat: null, expected_lon: null, expected_radius_m: null, internal_location_updated_at: null,
        outcome: 'PENDIENTE', order_numbers: [], merchandise_amount: 0, shipping_fee: 0,
        customer_email: null, task: 'ENTREGA', expected_amount: null
      });
      r.version = (r.version || 1) + 1;
    }
    if (op.kind === 'reorder') { const base = Math.min(...op.args.order.map(id => (r.stops.find(s => s.id === id) || {}).sequence_number || 0)); op.args.order.forEach((id, i) => { const s = r.stops.find(x => x.id === id); if (s) s.sequence_number = base + i; }); r.version = (r.version || 1) + 1; }
  }
  _applyQueue() { this.queue.forEach(op => this._applyLocal(op)); }
  // Acción: primero se guarda localmente; si no hay conexión queda en cola
  async act(kind, args) {
    const op = { op_id: uid(), kind, args, offline: this.conn !== 'live' };
    if (this.conn !== 'live') return this._enqueue(op);
    try { await this._send(op); this._applyLocal(op); this._sv(this.kC, this.routes); await this.load(); return true; }
    catch (e) {
      if (offline(e)) { this.setConn('off'); return this._enqueue(op); }
      this.toast(e.message);
      // vista Transportista: si el servidor rechaza (p. ej. se quitó el permiso con la app abierta), se verifica y se vuelve al perfil
      if (this.opts && this.opts.onForbidden && /FORBIDDEN|42501/.test(String(e.code || e.message || ''))) this.opts.onForbidden();
      return false;
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
    el.innerHTML = (pkOffer ? '<div class="drv-pk"><span>Entrá más rápido con huella o Face ID.</span><button class="btn go" type="button" id="drvPk">ACTIVAR INGRESO RÁPIDO</button></div>' : '') + '<div class="drv-title">' + (this.readOnly ? 'HOJAS · SOLO LECTURA' : '' + (this.opts && this.opts.assignedOnly ? 'MIS RUTAS' : 'MIS HOJAS PUBLICADAS') + '') + '</div>' +
      (this.queue.length ? '<div class="drv-q">' + this.queue.length + ' cambio(s) guardados en el celular · se envían al volver la conexión</div>' : '') +
      '<input class="ed drv-search" id="drvSearch" placeholder="Buscar hoja o cliente" value="' + esc(this.q || '') + '">' +
      '<div class="drv-tabs"><button type="button" data-t="HOY" class="' + (this.tab === 'HOY' ? 'on' : '') + '">HOY</button><button type="button" data-t="ANT" class="' + (this.tab === 'ANT' ? 'on' : '') + '">ANTERIORES</button></div>' +
      (list.length ? list.map(r => { const [b, c] = this.badge(r), bultos = r.stops.reduce((a, s) => a + (s.bultos || 0), 0);
        return '<div class="drv-card ' + c + '" data-r="' + r.id + '"><span class="drv-badge ' + c + '">' + b + '</span><b>HOJA ' + esc(r.number) + '</b><div class="drv-tp">' + esc(r.carrier_name || r.carrier_id) + '</div>' +
          '<div class="drv-m">' + new Date(r.published_at).toLocaleDateString('es-AR') + ' · ' + r.stops.length + ' ' + stopNoun(r, r.stops.length) + (bultos ? ' · ' + bultos + ' bultos' : '') + '</div><button class="btn go" type="button" data-open="' + r.id + '">' + (r.operational_status === 'EN_CURSO' ? 'CONTINUAR RECORRIDO' : 'VER HOJA') + '</button></div>'; }).join('')
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
    const internal = isInternal(r) && running, cur = currentStop(r.stops), fut = futureStops(r.stops).map(s => s.id);
    el.innerHTML = '<button class="linkbtn" type="button" id="drvBack">← Mis hojas</button><div class="drv-title">HOJA ' + esc(r.number) + ' · ' + esc(r.carrier_name || r.carrier_id) + '</div>' +
      '<div class="drv-m">' + r.stops.length + ' ' + stopNoun(r, r.stops.length) + ' · ' + this.badge(r)[0] + (r.started_at ? ' · iniciada ' + hhmm(r.started_at) : '') + (closed ? ' · finalizada ' + hhmm(r.completed_at) : '') + '</div>' +
      (r.approval_status === 'OBSERVADA' && r.review_note ? '<div class="drv-q">ACLARACIÓN SOLICITADA: ' + esc(r.review_note) + '</div>' : '') +
      byOrder(r.stops).map((s, i) => '<div class="drv-stop' + (internal && cur && s.id === cur.id ? ' cur' : '') + (internal && fut.includes(s.id) ? ' fut' : '') + (s.provenance === 'DRIVER' ? ' drv-new' : '') + '" data-s="' + s.id + '"' + (internal && fut.includes(s.id) ? ' draggable="true"' : '') + '><div class="drv-sh"><i>' + (i + 1) + '</i><div><b>' + esc(s.client_name) + '</b>' + (s.provenance === 'DRIVER' ? '<span class="drv-tag">AGREGADA</span>' : '') + (s.stop_type === 'UBICACION_INTERNA' ? '<span class="drv-tag">UBICACIÓN</span>' : '') + (s.stop_type === 'TAREA' ? '<span class="drv-tag">TAREA</span>' : '') + (internal && cur && s.id === cur.id ? '<span class="drv-tag">ACTUAL</span>' : '') + (s.action && s.action !== 'ENTREGA' ? ' · ' + esc(s.action) : '') + (s.bultos ? ' · ' + s.bultos + ' bultos' : '') + '<small>' + esc(s.address || '') + (s.order_numbers && s.order_numbers.length ? ' · Pedido ' + esc(s.order_numbers.join(' + ')) : '') + '</small></div>' +
        (s.outcome !== 'PENDIENTE' ? '<span class="drv-out ' + s.outcome + '">' + outLabel(s, s.outcome) + '</span>' : (internal && fut.includes(s.id) ? '<span class="drv-move"><button type="button" data-up title="Subir">↑</button><button type="button" data-down title="Bajar">↓</button></span>' : '')) + '</div>' +
        stopInfo(s) +
        (s.outcome_note || s.outcome_reason ? '<small class="drv-note">' + esc(s.outcome_note || s.outcome_reason) + '</small>' : '') +
        (s.location_warning ? '<small class="drv-note"><b>⚠ ' + esc(s.location_warning) + '</b></small>' : '') +
        (running ? '<div class="drv-acts">' + Object.keys(OUT).map(k => '<button type="button" class="btn drv-result-btn ' + (k === 'ENTREGADO' ? 'result-done' : k === 'ENTREGA_PARCIAL' ? 'result-partial' : k === 'NO_ENTREGADO' ? 'result-failed' : k === 'REPROGRAMAR' ? 'result-reschedule' : '') + (s.outcome === k ? ' selected' : '') + '" data-o="' + k + '">' + outLabel(s, k) + '</button>').join('') + '</div>' +
          '<div class="drv-form" hidden></div>' : '') +
        (running && isInternal(r) && s.outcome === 'PENDIENTE' && cur && s.id === cur.id ? (s.arrived_at ? '<small class="drv-note">Llegada registrada ' + hhmm(s.arrived_at) + (s.arrive_location && s.arrive_location.missing_reason ? ' · sin ubicación' : '') + '</small>' : '<button class="btn soft drv-arrive" type="button" data-arrive>LLEGUÉ A LA PARADA</button>') : '') + '</div>').join('') +
      (internal ? '<button class="btn soft" type="button" id="drvAddOpen">+ AGREGAR PARADA</button><div class="drv-add" id="drvAdd" hidden><b class="drv-ft">NUEVA PARADA</b>' +
        '<div class="drv-type" role="radiogroup" aria-label="Tipo de parada"><b>TIPO DE PARADA</b><div class="drv-seg"><button type="button" class="btn dark" data-ntype="TAREA" aria-pressed="true">TAREA</button><button type="button" class="btn soft" data-ntype="UBICACION_INTERNA" aria-pressed="false">UBICACIÓN INTERNA</button></div></div>' +
        '<div data-nt="TAREA"><input class="ed" id="naName" placeholder="Destino / qué hay que hacer (obligatorio)"><input class="ed" id="naAddr" placeholder="Domicilio"></div>' +
        '<div data-nt="UBICACION_INTERNA" hidden><input class="ed" id="naLocQ" type="search" placeholder="Buscar ubicación (Montecaseros, San Juan…)" autocomplete="off"><div class="drv-loclist" id="naLocList"></div>' +
        '<div class="drv-locpick" id="naLocPick" hidden></div></div>' +
        '<textarea class="ed" id="naIns" rows="2" placeholder="Observación / instrucciones (ej. retirar documentación)"></textarea>' +
        '<div data-nt="TAREA"><input class="ed" id="naCon" placeholder="Contacto (opcional)"><input class="ed" id="naTel" inputmode="tel" placeholder="Teléfono (opcional)"></div>' +
        '<small>Se agrega al final del recorrido. No modifica paradas existentes, pedidos ni ubicaciones guardadas.</small><button class="btn dark" type="button" id="naSave">AGREGAR PARADA</button><span class="shiperr" id="naErr" hidden></span></div>' : '') +
      (r.operational_status === 'PUBLICADA' && !this.readOnly && r.vehicle_id ? '<label class="drv-km">KM INICIAL del vehículo ' + esc(r.vehicle_plate || '') + ' (obligatorio) <input class="ed" id="drvKmIni" inputmode="numeric"></label>' : '') +
      '<div class="drv-foot">' + (r.operational_status === 'PUBLICADA' && !this.readOnly ? '<button class="btn go" type="button" id="drvStart">INICIAR RECORRIDO</button><small>Abrir la hoja no inicia el recorrido.</small>' : '') +
      (running && r.vehicle_id ? '<label class="drv-km">KM FINAL del vehículo (inicial ' + (r.km_start ?? '—') + ') <input class="ed" id="drvKm" inputmode="numeric"></label>' : '') +
      (running ? '<button class="btn go" type="button" id="drvFin"' + (pend ? ' disabled' : '') + '>FINALIZAR HOJA</button>' + (pend ? '<small>' + (pend === 1 ? 'Falta 1 ' + stopNoun(r, 1) : 'Faltan ' + pend + ' ' + stopNoun(r, pend)) + ' por resolver.</small>' : '') : '') +
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
    // Tipo de parada: TAREA libre o UBICACIÓN INTERNA G2 existente (puede ser una segunda visita). La G2 es de solo lectura.
    let ntype = 'TAREA', locs = null, pick = null;
    const er = form.querySelector('#naErr'), fail = t => { er.textContent = t; er.hidden = false; };
    const list = form.querySelector('#naLocList'), pickBox = form.querySelector('#naLocPick');
    const drawList = () => {
      const q = (form.querySelector('#naLocQ').value || '').trim().toLowerCase(), ls = (locs || []).filter(l => !q || (l.name + ' ' + (l.address || '') + ' ' + l.location_key).toLowerCase().includes(q));
      list.innerHTML = locs == null ? '<small>Cargando ubicaciones…</small>' : ls.length ? ls.map(l => '<button type="button" class="drv-locopt" data-lk="' + esc(l.location_key) + '"><b>' + esc(l.name) + '</b><small>' + esc(l.address || '') + '</small></button>').join('') : '<small>No hay ubicaciones que coincidan.</small>';
      list.querySelectorAll('[data-lk]').forEach(bn => bn.onclick = () => { pick = locs.find(l => l.location_key === bn.dataset.lk);
        pickBox.innerHTML = '<span>UBICACIÓN</span><b>' + esc(pick.name) + '</b><span>Dirección</span><b>' + esc(pick.address || '—') + '</b><small>GPS: radio ' + esc(pick.radius_m) + ' m · firma de recepción obligatoria</small>';
        pickBox.hidden = false; list.hidden = true; form.querySelector('#naLocQ').value = pick.name; });
    };
    const setType = t => { ntype = t; er.hidden = true;
      form.querySelectorAll('[data-ntype]').forEach(bn => { const on = bn.dataset.ntype === t; bn.className = 'btn ' + (on ? 'dark' : 'soft'); bn.setAttribute('aria-pressed', on ? 'true' : 'false'); });
      form.querySelectorAll('[data-nt]').forEach(d => { d.hidden = d.dataset.nt !== t; });
      if (t === 'UBICACION_INTERNA' && locs == null) {
        drawList();
        (this.api.driverInternalLocations ? this.api.driverInternalLocations() : Promise.reject(new Error('no disponible')))
          .then(ls => { locs = ls || []; drawList(); }).catch(() => { locs = []; list.innerHTML = '<small>No se pudieron cargar las ubicaciones (¿sin conexión?). Probá de nuevo con conexión.</small>'; });
      }
    };
    form.querySelectorAll('[data-ntype]').forEach(bn => bn.onclick = () => setType(bn.dataset.ntype));
    form.querySelector('#naLocQ').oninput = () => { pick = null; pickBox.hidden = true; list.hidden = false; drawList(); };
    open.onclick = () => { form.hidden = false; form.querySelector('#naName').focus(); };
    form.querySelector('#naSave').onclick = async () => {
      const ins = form.querySelector('#naIns').value.trim(), id = (crypto.randomUUID ? crypto.randomUUID() : uid());
      let stop;
      if (ntype === 'UBICACION_INTERNA') {
        if (!pick) return fail('Elegí la ubicación interna.');
        // sin pedidos ni montos: los pedidos siguen siendo administrativos
        stop = { id, stop_type: 'UBICACION_INTERNA', internal_location_key: pick.location_key, client_name: pick.name, address: pick.address || '', action: 'ENTREGA', instructions: ins };
      } else {
        const name = form.querySelector('#naName').value.trim(); if (!name) return fail('Indicá el destino.');
        stop = { id, stop_type: 'TAREA', client_name: name, address: form.querySelector('#naAddr').value.trim(), action: 'ENTREGA', instructions: ins,
          contact_name: form.querySelector('#naCon').value.trim(), contact_phone: form.querySelector('#naTel').value.trim() };
      }
      const bn = form.querySelector('#naSave'); bn.disabled = true;   // evita el doble toque (además el servidor es idempotente)
      try { await this.act('addStop', { route: r.id, version: r.version || 1, stop }); } finally { bn.disabled = false; }
      this.render();
    };
  }
  // La foto del DNI se sube a Storage privado recién al enviar (también al sincronizar una acción hecha sin conexión)
  async _sendOutcome(op) {
    const a = op.args, ev = a.extra && a.extra.evidence;
    if (ev && ev.dni_upload) { ev.dni_storage_path = await this.api.uploadIdentityDoc(ev.cuil, ev.dni_upload); delete ev.dni_upload; this._sv(this.kQ, this.queue); }
    if (ev && ev.dni_blob) {   // foto guardada sin conexión (IndexedDB)
      const blob = await BLOBS.get(ev.dni_blob.key);
      if (!blob) throw Object.assign(new Error('La foto del DNI guardada en el celular no está disponible: volvé a cargar la entrega.'), { code: 'DNI_LOST' });
      ev.dni_storage_path = await this.api.uploadIdentityDoc(ev.cuil, { blob, mime: ev.dni_blob.mime, size: ev.dni_blob.size });
      const k = ev.dni_blob.key; delete ev.dni_blob; this._sv(this.kQ, this.queue); BLOBS.del(k);
    }
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
  // Resolver parada según su TIPO (stop_type), sin que el chofer elija formulario:
  //  · PEDIDO (entrega comercial a un cliente): nombre y apellido + CUIL + foto del DNI + firma
  //  · UBICACION_INTERNA (sucursal precargada, p. ej. Montecaseros / San Juan): nombre y apellido + firma (recepción interna)
  //  · TAREA: sin receptor ni firma (observación opcional)
  // Sin cobranza ni medio de pago: entregar NO es cobrar. Solo las hojas publicadas ANTES de este cambio con task COBRANZA/AMBAS
  // la conservan, porque el servidor vigente todavía la exige ahí (cambio de servidor pendiente de aprobación).
  openForm(box, r, st, o) {
    const form = box.querySelector('.drv-form'); if (form._release) form._release();   // cambiar de resultado libera la foto anterior
    form.hidden = false; form.dataset.o = o;
    const type = st.stop_type || 'PEDIDO', task = type === 'TAREA', transfer = type === 'UBICACION_INTERNA', commercial = type === 'PEDIDO';
    const delivered = o === 'ENTREGADO' || o === 'ENTREGA_PARCIAL', idReq = commercial;   // sin cobranza para ningún chofer (V4.16)
    // TAREA: sin firma ni receptor obligatorios (GPS + observación). Traslado interno: RECEPCIÓN INTERNA firmada por la sucursal (no es Recibido Conforme).
    const sign = delivered && !task;
    form.innerHTML = '<b class="drv-ft">' + outLabel(st, o) + '</b>' +
      (transfer && delivered ? '<div class="drv-rec"><b>RECEPCIÓN INTERNA DE TRASLADO</b><small>' + esc(st.client_name) + ((st.order_numbers || []).length ? ' · pedidos ' + esc(st.order_numbers.join(', ')) : '') + '</small></div>' : '') +
      (task && o === 'ENTREGADO' ? '<input class="ed" data-f="txt" placeholder="Observación (opcional)">' : '') +
      (sign ? '<input class="ed" data-f="recv" placeholder="' + (transfer ? 'Nombre y apellido de quien recibe en la sucursal (obligatorio)' : 'Nombre y apellido de quien recibe (obligatorio)') + '"><div class="sigbox"><canvas width="600" height="240" data-sig></canvas><div class="sig-actions"><button type="button" class="btn soft" data-sigexpand>FIRMAR EN PANTALLA GRANDE</button><button type="button" class="linkbtn" data-sigclr>Borrar firma</button></div></div>' : '') +
      // entrega comercial: CUIL + foto del DNI (ambos transportistas). Nunca en sucursal/ubicación interna ni en TAREA.
      (sign && idReq ? '<input class="ed" data-f="email" type="email" inputmode="email" autocomplete="off" placeholder="Email del receptor (obligatorio)"><span class="drv-mailhint" data-mailhint></span>' +
        '<input class="ed" data-f="cuil" inputmode="numeric" placeholder="CUIL de quien recibe (11 dígitos)"><span class="drv-dni" data-dni></span>' : '') +
      (o === 'ENTREGA_PARCIAL' ? '<input class="ed" data-f="txt" placeholder="Observación (obligatoria)">' : o !== 'ENTREGADO' ? '<input class="ed" data-f="txt" placeholder="Motivo (obligatorio)">' : '') +
      '<button class="btn dark" type="button" data-save>GUARDAR</button><span class="shiperr" hidden></span>';
    const er = form.querySelector('.shiperr'), fail = t => { er.textContent = t; er.hidden = false; };
    form.addEventListener('input', () => { er.hidden = true; });   // el aviso se oculta apenas se corrige un dato
    // firma táctil
    const cv = form.querySelector('[data-sig]'); let drawn = false;
    if (cv) { const ctx = cv.getContext('2d'); ctx.lineWidth = 2.2; ctx.lineCap = 'round'; ctx.strokeStyle = '#000E18'; let down = false;
      const pos = e => { const b = cv.getBoundingClientRect(); return [(e.clientX - b.left) * cv.width / b.width, (e.clientY - b.top) * cv.height / b.height]; };
      cv.onpointerdown = e => { down = true; cv.setPointerCapture(e.pointerId); ctx.beginPath(); ctx.moveTo(...pos(e)); };
      cv.onpointermove = e => { if (!down) return; ctx.lineTo(...pos(e)); ctx.stroke(); drawn = true; };
      cv.onpointerup = () => { down = false; keep(); };
      const origin = cv.parentElement;
      const expand = form.querySelector('[data-sigexpand]');
      let modal = null;
      const closeModal = () => {
        if (!modal) return;
        origin.insertBefore(cv, origin.firstChild);
        modal.remove(); modal = null;
        expand.focus();
      };
      expand.onclick = () => {
        if (modal) return;
        modal = document.createElement('div'); modal.className = 'drv-sign-modal';
        modal.setAttribute('role', 'dialog'); modal.setAttribute('aria-modal', 'true'); modal.setAttribute('aria-label', 'Firmar recepción');
        modal.innerHTML = '<div class="drv-sign-panel"><b>FIRMA DE QUIEN RECIBE</b><p>Firmá con el dedo en el espacio de abajo.</p><div class="drv-sign-stage"></div><div class="drv-sign-controls"><button type="button" class="btn soft" data-modal-clear>BORRAR FIRMA</button><button type="button" class="btn dark" data-modal-done>LISTO</button></div></div>';
        document.body.appendChild(modal);
        modal.querySelector('.drv-sign-stage').appendChild(cv);
        modal.querySelector('[data-modal-clear]').onclick = () => { ctx.clearRect(0, 0, cv.width, cv.height); drawn = false; };
        modal.querySelector('[data-modal-done]').onclick = closeModal;
        modal.onkeydown = ev => { if (ev.key === 'Escape') { ev.preventDefault(); closeModal(); } };
        modal.querySelector('[data-modal-done]').focus();
      };
      form.querySelector('[data-sigclr]').onclick = () => { ctx.clearRect(0, 0, cv.width, cv.height); drawn = false; };
    }
    // Autocompletar con el perfil reutilizable (CUIL → DNI → cliente). Sin conexión, simplemente no se completa.
    const em = form.querySelector('[data-f="email"]'), hint = form.querySelector('[data-mailhint]'), rv = form.querySelector('[data-f="recv"]');
    const fill = async cuil => {
      if (!this.api.deliveryIdentityLookup || (!em && !cuil)) return;
      const p = await this.api.deliveryIdentityLookup(st.id, cuil || null).catch(() => null);
      if (!p) return;
      if (em && p.email && (!em.value || em.dataset.auto === '1')) { em.value = p.email; em.dataset.auto = '1'; hint.textContent = 'Email recuperado del cliente (podés corregirlo)'; }
      if (p.full_name && rv && !rv.value) rv.value = p.full_name;
    };
    if (em) { em.oninput = () => { em.dataset.auto = ''; hint.textContent = ''; }; fill(null); }
    // DNI: si el CUIL ya tiene DNI no se pide foto
    // DNI: si el CUIL ya tiene DNI registrado, se reutiliza (no se pide foto). Foto nueva: se procesa al aceptarla, con vista previa
    let dni = null, dniRegistered = false, dniBusy = false, dniTok = 0, prevUrl = null; const cu = form.querySelector('[data-f="cuil"]'), saveBtn = form.querySelector('[data-save]');
    const release = () => { if (prevUrl) { URL.revokeObjectURL(prevUrl); prevUrl = null; } };
    form._release = () => { dniTok++; release(); dni = null; };   // cancelar/cerrar: libera la vista previa y descarta resultados en curso
    if (cu) cu.onchange = async () => {
      const n = cu.value.replace(/\D/g, ''), box2 = form.querySelector('[data-dni]');
      if (n.length !== 11) { box2.textContent = 'El CUIL debe tener 11 dígitos.'; return; }
      fill(n); keep();
      dniRegistered = false;
      const has = await this.api.cuilHasDni(n).catch(() => false);
      dniRegistered = has;
      form._release(); dniBusy = false; saveBtn.disabled = false;
      box2.innerHTML = has ? '✓ DNI YA REGISTRADO (se reutiliza la identidad)' : 'CUIL nuevo · foto del DNI (obligatoria) <input type="file" accept="image/jpeg,image/png" capture="environment" data-dnifile><span class="drv-dnist" data-dnist></span><img class="drv-dniprev" data-dniprev alt="Vista previa del DNI" hidden>';
      const fi = box2.querySelector('[data-dnifile]'), stt = box2.querySelector('[data-dnist]'), prev = box2.querySelector('[data-dniprev]');
      if (fi) fi.onchange = async () => {
        const f = fi.files[0], tok = ++dniTok; dni = null; release(); prev.hidden = true;
        if (!f) { stt.textContent = ''; return; }
        dniBusy = true; saveBtn.disabled = true; stt.textContent = 'Procesando foto…'; er.hidden = true;
        try {
          const p = await processDniPhoto(f);
          if (tok !== dniTok) return;   // la reemplazaron mientras se procesaba: este resultado se descarta
          if (p.size > 5242880) throw new Error('la imagen procesada supera 5 MB');
          dni = p; prevUrl = URL.createObjectURL(p.blob); prev.src = prevUrl; prev.hidden = false;
          stt.textContent = '✓ Foto lista · ' + kb(p.original) + ' → ' + kb(p.size) + ' (' + p.w + '×' + p.h + ')';
        } catch (e) {
          if (tok === dniTok) { stt.textContent = ''; fail('No se pudo procesar la foto del DNI: ' + (e.message || e) + '. Nombre, email, CUIL y firma se conservan: volvé a sacar la foto (si se repite, bajá la resolución de la cámara).'); }
        } finally { if (tok === dniTok) { dniBusy = false; saveBtn.disabled = false; } fi.value = ''; }   // se suelta el archivo original
      };
    };
    // Los datos cargados sobreviven a una recarga (p. ej. Android cerró la página al volver de la cámara) y a un fallo de la foto
    const draftKey = 'okd_drv_form:' + st.id + ':' + o;
    function keep() { try { sessionStorage.setItem(draftKey, JSON.stringify({ recv: rv ? rv.value : '', email: em ? em.value : '', cuil: cu ? cu.value : '', sig: cv && drawn ? cv.toDataURL('image/png') : null })); } catch (e) { } }
    form.addEventListener('input', keep);
    try { const d = JSON.parse(sessionStorage.getItem(draftKey) || 'null');
      if (d) { if (rv && d.recv) rv.value = d.recv; if (em && d.email) { em.value = d.email; em.dataset.auto = ''; } if (cu && d.cuil) { cu.value = d.cuil; cu.onchange(); }
        if (cv && d.sig) { const im = new Image(); im.onload = () => { cv.getContext('2d').drawImage(im, 0, 0); drawn = true; }; im.src = d.sig; } } } catch (e) { }
    form.querySelector('[data-save]').onclick = async ev => {
      er.hidden = true;
      const txt = (form.querySelector('[data-f="txt"]') || {}).value; const extra = {};
      if (o === 'ENTREGA_PARCIAL' && !String(txt || '').trim()) return fail('Entrega parcial exige observación.');
      if (['NO_ENTREGADO', 'REPROGRAMAR'].includes(o) && !String(txt || '').trim()) return fail('Indicá el motivo.');
      if (sign) {
        const recv = form.querySelector('[data-f="recv"]').value.trim();
        if (!recv) return fail(transfer ? 'Indicá quién recibe en la sucursal.' : 'Indicá el nombre de quien recibe.');
        if (!drawn) return fail(transfer ? 'Falta la firma de quien recibe en la sucursal.' : 'Falta la firma de quien recibe.');
        extra.evidence = { receiver_name: recv, signature_png_b64: cv.toDataURL('image/png').split(',')[1] };
        const mail = em ? em.value.trim().toLowerCase() : '';
        if (idReq && !mail) return fail('El email del receptor es obligatorio.');
        if (mail && !/^[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}$/i.test(mail)) return fail('El email del receptor no es válido.');
        if (idReq) { const n = cu.value.replace(/\D/g, ''); if (n.length !== 11) return fail('El CUIL debe tener 11 dígitos.');
          if (dniBusy) return fail('Esperá a que termine de procesarse la foto del DNI.');
          if (!dniRegistered && !dni) return fail('La foto del DNI es obligatoria para un CUIL nuevo.'); extra.evidence.cuil = n; if (dni) extra.evidence.dni_upload = { blob: dni.blob, mime: dni.mime, size: dni.size }; }
        if (mail) extra.evidence.email = mail;
      }
      ev.target.disabled = true;
      const loc = await this.locate(box); if (!loc) { ev.target.disabled = false; return; }
      extra.location = loc;
      const ok = await this.act('outcome', { route: r.id, stop: st.id, outcome: o, note: (o === 'ENTREGA_PARCIAL' || (task && o === 'ENTREGADO')) ? (String(txt || '').trim() || null) : null, reason: ['NO_ENTREGADO', 'REPROGRAMAR'].includes(o) ? txt : null, extra });
      if (!ok) ev.target.disabled = false;   // falló: se conservan nombre, email, CUIL, firma y la foto procesada para reintentar
      else { try { sessionStorage.removeItem(draftKey); } catch (e) { } if (form._release) form._release(); }
      this.render();
    };
  }
}
