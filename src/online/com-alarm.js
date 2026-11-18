// AUTORIZACIONES COMERCIALES · ALARMA URGENTE en CUALQUIER pantalla (no depende de estar en el módulo Comercial). V4.
// · Destinatarios (Wilfredo; tras el escalamiento del SERVIDOR, Franco y Gabriela): aviso + SONIDO repetitivo + ATENDER SOLICITUD.
// · PRIORIDADES (B-W03): con el bloqueo PIN abierto NO se muestra nada (ni datos ni botones), NO se puede atender y el sonido se pausa.
//   Con una firma u otro formulario modal abierto se muestra SOLO un indicador compacto, sin datos, que no tapa el formulario.
// · Aviso CONTENIDO (B-W07): altura máxima con desplazamiento interno, textos largos sin desbordes, botones siempre accesibles, teclado
//   (Escape minimiza) y zoom. «MINIMIZAR» libera la pantalla SIN registrar una atención; se vuelve a abrir solo ante una alarma nueva o escalada.
// · Con la pestaña oculta: notificación del sistema (si el usuario la permitió). Con la app cerrada o el teléfono bloqueado: el PUSH existente
//   (service worker sin cambios), cuando Android/Chrome y los permisos lo permiten. No se promete sonido continuo fuera de la app.
// · Ciclo de vida (B-AL-01 / O-W01): una instancia por usuario; al destruirla se cancelan TODOS los temporizadores y nada se reprograma.
import { capable, subscribe } from './push-notifications.js';
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const hhmm = s => s ? new Date(s).toLocaleTimeString('es-AR', { hour: '2-digit', minute: '2-digit' }) : '—';
const ST = { PENDIENTE_ATENCION: 'PENDIENTE DE ATENCIÓN', ATENDIDA: 'ATENDIDA', CANCELADA: 'CANCELADA' };
const nm = s => String(s || '').split(' — ')[0];
const vis = el => !!el && !el.hidden && el.getClientRects().length > 0 && getComputedStyle(el).visibility !== 'hidden';
// prioridad 1: bloqueo PIN · prioridad 2: firma / formularios modales críticos (la alarma nunca los tapa)
const PIN_SEL = '#pinGate';
const SIGN_SEL = '.drv-sign-modal, canvas[data-sigpad]';   // firma a pantalla completa: se trata IGUAL que el PIN (nada visible, sonido en pausa)
const CRIT_SEL = '.drv-sign-modal, canvas[data-sigpad], .drv-form:not([hidden]), [data-okd-critical], .umodal, .modalbg, dialog[open]';   // N-V4-06: también la entrega EMBEBIDA del chofer

// B-AL-01: UNA instancia por usuario. Al cerrar o vencer la sesión (okd-com-cleanup), o si el servidor responde sesión revocada, se DESTRUYE
// por completo: consultas, temporizadores, audio, escuchas, estado y vista; las respuestas en camino se descartan; el reingreso reinstala.
let current = null;
export function disposeComAlarm() { const c = current; current = null; if (c) c.dispose(); }
if (typeof window !== 'undefined') window.addEventListener('okd-com-cleanup', disposeComAlarm);
export function installComAlarm(api, me) {
  if (!api || typeof api.comMyAlarms !== 'function' || typeof document === 'undefined' || !me || !me.id) return null;
  if (current && current.userId === me.id) return current;
  disposeComAlarm();
  current = createComAlarm(api, me);
  return current;
}
function createComAlarm(api, me) {
  window.__okdComAlarmInstalled = true;
  let alive = true;   // las respuestas que lleguen después de destruir la instancia se descartan
  const S = window.__okdComAlarm = { ringing: false, beeps: 0, soundBlocked: false, lastError: null, alarms: [], total: 0, polls: 0, forbidden: false, notified: {}, focus: null,
    userId: me.id, minimized: false, suppressed: null, pushDevices: null, known: new Set() };
  let ctx = null, beepTimer = null, beepEvery = 0, pollTimer = null, stopped = false, msg = '', obs = null, raf = 0;
  const timers = new Set();   // O-W01: TODO temporizador queda registrado y se cancela al destruir
  const later = (fn, ms) => { if (!alive) return 0; const id = setTimeout(() => { timers.delete(id); if (alive) fn(); }, ms); timers.add(id); return id; };
  // ---------- sonido (Web Audio): Chrome exige un gesto del usuario para habilitar el audio ----------
  // el toque SOLO habilita el audio y NO redibuja en ese instante (si se reemplaza el aviso entre el toque y el clic, el clic no llega)
  const unlock = () => { try { ctx = ctx || new (window.AudioContext || window.webkitAudioContext)(); if (ctx.state === 'suspended') ctx.resume(); } catch (e) { }
    if (S.soundBlocked) { S.soundBlocked = false; later(render, 400); } };
  const L = [];   // escuchas registradas (se quitan en dispose)
  const on = (t, ev, fn, o) => { t.addEventListener(ev, fn, o); L.push([t, ev, fn, o]); };
  ['pointerdown', 'keydown', 'touchstart'].forEach(ev => on(window, ev, unlock, { capture: true, passive: true }));
  function beep() {
    if (!alive || S.suppressed === 'PIN' || S.suppressed === 'FIRMA') return;
    try {
      ctx = ctx || new (window.AudioContext || window.webkitAudioContext)();
      if (ctx.state !== 'running') { S.soundBlocked = true; ctx.resume().catch(() => null); return; }
      S.soundBlocked = false; const t = ctx.currentTime;
      [0, 0.28].forEach((d, i) => { const o = ctx.createOscillator(), g = ctx.createGain(); o.type = 'square'; o.frequency.value = i ? 660 : 880;
        g.gain.setValueAtTime(0.0001, t + d); g.gain.exponentialRampToValueAtTime(0.25, t + d + 0.02); g.gain.exponentialRampToValueAtTime(0.0001, t + d + 0.22);
        o.connect(g).connect(ctx.destination); o.start(t + d); o.stop(t + d + 0.24); });
      S.beeps++;
    } catch (e) { S.soundBlocked = true; }
  }
  // normal: cada 2,2 s · minimizada o con un formulario crítico: cada 15 s · con el PIN abierto: en pausa
  function setRinging(want) {
    const mute = S.suppressed === 'PIN' || S.suppressed === 'FIRMA';
    const every = !want || mute ? 0 : (S.minimized || S.suppressed === 'CRITICO' ? 15000 : 2200);
    S.ringing = !!want && !mute;
    if (every === beepEvery) return;
    if (beepTimer) { clearInterval(beepTimer); beepTimer = null; }
    beepEvery = every;
    if (every && alive) { beep(); beepTimer = setInterval(beep, every); }
  }
  // ---------- notificación del sistema cuando la pestaña está oculta (una por alarma y etapa) ----------
  function sysNotify(a) {
    const key = a.id + ':' + (a.escalated_at ? 'E' : 'I');
    if (S.notified[key] || !document.hidden || !('Notification' in window) || Notification.permission !== 'granted') return;
    S.notified[key] = true;
    try { const n = new Notification('APROBACIÓN COMERCIAL URGENTE', { body: 'Pedido ' + a.order_ref + ' · solicitada por ' + nm(a.raised_by), tag: 'okd-com-alarm-' + a.id, renotify: true, requireInteraction: true });
      n.onclick = () => { window.focus(); n.close(); }; } catch (e) { }
  }
  // ---------- pantalla ----------
  let host = document.getElementById('comAlarm');
  if (!host) { host = document.createElement('div'); host.id = 'comAlarm'; document.body.appendChild(host); }
  function suppression() {
    const pin = document.querySelector(PIN_SEL); if (vis(pin)) return 'PIN';
    if ([...document.querySelectorAll(SIGN_SEL)].some(el => !host.contains(el) && vis(el))) return 'FIRMA';
    const crit = [...document.querySelectorAll(CRIT_SEL)].find(el => !host.contains(el) && vis(el)); return crit ? 'CRITICO' : null;
  }
  function pushHelp() {
    if (!capable()) return '<small>Este navegador no admite notificaciones push: la alarma solo se ve con la app abierta.</small>';
    if (Notification.permission === 'denied') return '<small><b>Notificaciones BLOQUEADAS en este navegador:</b> con la app cerrada o el teléfono bloqueado no vas a recibir la alarma. Habilitalas en la configuración del sitio.</small>';
    if (Notification.permission !== 'granted') return '<button type="button" data-al-push class="al-btn al-ghost">ACTIVAR NOTIFICACIONES EN ESTE DISPOSITIVO</button>';
    if (S.pushDevices === 0) return '<button type="button" data-al-push class="al-btn al-ghost">REACTIVAR NOTIFICACIONES EN ESTE DISPOSITIVO</button><small>El navegador tiene permiso, pero el servidor no tiene registrado este dispositivo.</small>';
    return '';
  }
  const CSS = '<style>#comAlarm .al-wrap{position:fixed;left:0;right:0;top:0;z-index:2147483000;background:#b42318;color:#fff;box-shadow:0 8px 30px #0006;padding:calc(env(safe-area-inset-top,0px) + 10px) 12px 10px;font-family:inherit;font-size:1rem}' +
    '#comAlarm .al-in{max-width:980px;margin:0 auto;display:flex;flex-direction:column;max-height:min(60vh,520px)}' +
    '#comAlarm .al-head{display:flex;gap:8px;align-items:center;flex-wrap:wrap}#comAlarm .al-title{font-size:1.15em;font-weight:900;letter-spacing:.3px;flex:1 1 220px}' +
    '#comAlarm .al-list{overflow-y:auto;overscroll-behavior:contain;margin-top:8px;min-height:0;flex:1 1 auto}' +
    '#comAlarm .al-card{background:#ffffff1a;border-radius:12px;padding:10px 12px;margin-top:8px;overflow-wrap:anywhere;word-break:break-word}' +
    '#comAlarm .al-card:first-child{margin-top:0}#comAlarm .al-foot{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin-top:8px}' +
    '#comAlarm .al-btn{min-height:44px;border-radius:12px;font-weight:800;padding:8px 14px;font:inherit;font-weight:800;cursor:pointer}' +
    '#comAlarm .al-main{border:0;background:#fff;color:#b42318;font-weight:900}#comAlarm .al-ghost{border:1px solid #fff;background:transparent;color:#fff}' +
    '#comAlarm .al-btn:focus-visible{outline:3px solid #ffd166;outline-offset:2px}' +
    '#comAlarm .al-bar{position:fixed;left:10px;right:10px;bottom:calc(env(safe-area-inset-bottom,0px) + 10px);z-index:2147483000;background:#b42318;color:#fff;padding:6px 8px 6px 12px;display:flex;gap:8px;align-items:center;border-radius:14px;box-shadow:0 4px 16px #0005;font-size:.95em}' +
    '#comAlarm .al-bar b{flex:1 1 auto;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}#comAlarm .al-bar small{display:none}@media (min-width:700px){#comAlarm .al-bar small{display:inline}}' +
    '#comAlarm .al-reason{display:-webkit-box;-webkit-box-orient:vertical;-webkit-line-clamp:3;overflow:hidden}#comAlarm .al-card details summary{cursor:pointer;font-weight:700;margin-top:4px}' +
    // formulario crítico abierto: indicador ARRIBA, compacto y SIN capturar toques (nunca intercepta GUARDAR, CONFIRMAR ni otro botón)
    '#comAlarm .al-pill{position:fixed;left:50%;transform:translateX(-50%);top:calc(env(safe-area-inset-top,0px) + 4px);z-index:2147482990;pointer-events:none;background:#b42318e6;color:#fff;border-radius:999px;padding:4px 12px;font-weight:800;font-size:.8em;box-shadow:0 2px 8px #0004;max-width:min(92vw,360px);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}' +
    '</style>';
  function card(a) {
    const largo = String(a.reason || '').length > 160;
    return '<div class="al-card"><div><b>' + esc(a.number) + '</b> · ' + (a.sheet_key === 'AUTORIZACION' ? 'autorización' : 'pedido') + ' <b>' + esc(a.order_ref) + '</b> · ' + esc(a.client || 'cliente sin identificar') +
      (a.branch ? ' · ' + esc(a.branch === 'SAN_JUAN' ? 'San Juan' : a.branch === 'MONTECASEROS' ? 'Montecaseros' : a.branch) : '') + '</div>' +
      '<div>Solicita: <b>' + esc(nm(a.raised_by)) + '</b> a las ' + hhmm(a.raised_at) + (a.escalated_at ? ' · <b>ESCALADA</b> a las ' + hhmm(a.escalated_at) + ' a ' + esc((a.escalated_to || []).map(nm).join(' y ')) + ' (sin atender en 3 minutos)' : '') + '</div>' +
      // el botón va ANTES del motivo: siempre queda a la vista aunque el motivo sea largo
      '<div class="al-foot"><button type="button" class="al-btn al-main" data-al-attend="' + esc(a.id) + '" data-al-v="' + a.version + '">ATENDER SOLICITUD</button>' +
      '<small>Atender no es aprobar: la decisión se toma en Autorizaciones.</small></div>' +
      '<div class="al-reason">Motivo: ' + esc(a.reason) + '</div>' + (largo ? '<details><summary>Ver motivo completo</summary>' + esc(a.reason) + '</details>' : '') +
      (a.request ? '<div class="al-req">Autorización <b>' + esc(a.request.number) + '</b> · ' + esc(a.request.status) +
        ' <button type="button" class="al-btn" data-al-open-req="' + esc(a.id) + '" style="background:transparent;color:#fff;border:2px solid #fff;font-weight:800;opacity:1">ABRIR AUTORIZACIÓN</button></div>' : '') + '</div>';
  }

  function linkId() { const src = [window.__okdBootHash, location.hash].map(x => String(x || '')).find(h => /[?&]alarma_n=/.test(h)); const m = src && src.match(/[?&]alarma_n=([0-9a-zA-Z-]+)/); return m ? m[1] : null; }
  async function focusFromLink() {
    const nid = linkId(); if (!nid || typeof api.comAlarmByNotification !== 'function') return;
    window.__okdBootHash = '';
    try { const a = await api.comAlarmByNotification(nid); if (!alive) return; S.focus = a || { missing: true }; } catch (e) { if (!alive) return; S.focus = { missing: true }; }
    S.minimized = false; render();
  }
  // si hay alarmas SONANDO, el recuadro del enlace va DENTRO del aviso (si fuera aparte, el aviso lo taparía); si no, es un recuadro propio
  function focusHtml(ring, inline) {
    const a = S.focus; if (!a || (a.id && ring.some(x => x.id === a.id))) return '';
    return '<div role="dialog" aria-label="Alarma comercial" data-al-focus style="' + (inline ? 'margin-top:10px;' : 'position:fixed;left:50%;transform:translateX(-50%);top:calc(env(safe-area-inset-top,0px) + 70px);z-index:2147482995;box-shadow:0 10px 30px #0004;width:min(94vw,560px);max-height:70vh;overflow:auto;') +
      'background:#fff;color:#0b2a37;border:2px solid #b42318;border-radius:14px;padding:12px 14px;overflow-wrap:anywhere">' +
      (a.missing ? '<b>No se encontró la alarma de este aviso</b> (o no sos su destinatario).' :
        '<b>ALARMA ' + esc(a.number) + '</b> · ' + (a.sheet_key === 'AUTORIZACION' ? 'autorización' : 'pedido') + ' <b>' + esc(a.order_ref) + '</b> · ' + esc(a.client || '') + '<br>Solicita ' + esc(nm(a.raised_by)) + ' a las ' + hhmm(a.raised_at) + ' · Motivo: ' + esc(a.reason) +
        '<br><b>' + esc(ST[a.status] || a.status) + '</b>' + (a.status === 'ATENDIDA' ? ' por ' + esc(nm(a.attended_by)) + ' a las ' + hhmm(a.attended_at) : '') +
        (a.can_attend ? '<div style="margin-top:8px"><button type="button" data-al-attend="' + esc(a.id) + '" data-al-v="' + a.version + '" style="min-height:44px;border:0;border-radius:12px;background:#b42318;color:#fff;font-weight:900;padding:8px 16px">ATENDER SOLICITUD</button></div>' : '')) +
      ' <button type="button" data-al-close style="float:right;border:0;background:transparent;font-weight:800;min-height:36px;color:inherit">CERRAR</button></div>';
  }
  function render() {
    if (!alive) return;
    S.suppressed = suppression();
    const ring = S.alarms.filter(a => a.ring), mine = S.alarms.filter(a => !a.ring && a.raised_by && nm(a.raised_by) === String(me.full_name || ''));
    setRinging(ring.length > 0);
    // B-W03 · PIN abierto: NADA visible ni accionable (ni datos operativos ni botones)
    if (S.suppressed === 'PIN' || S.suppressed === 'FIRMA') { host.innerHTML = ''; return; }   // PIN o firma abiertos: NADA visible ni accionable
    let h = CSS;
    const more = Math.max(0, (S.total || 0) - ring.length);
    if (ring.length && S.suppressed === 'CRITICO') {
      // formulario crítico abierto (firma, modal): indicador compacto SIN datos, que no tapa el formulario
      h += '<div class="al-pill" role="status" data-al-pill>⚠ ' + ring.length + ' alarma(s) comercial(es) pendiente(s) · se muestran al terminar</div>';
    } else if (ring.length && S.minimized) {
      h += '<div class="al-bar" role="status" data-al-bar><b>⚠ ' + (ring.length + more) + ' alarma(s) comercial(es) urgente(s)</b><small>Minimizada: sigue pendiente (no se registró ninguna atención).</small>' +
        '<button type="button" class="al-btn al-main" data-al-expand>VER Y ATENDER</button></div>';
    } else if (ring.length) {
      h += '<div class="al-wrap" role="alertdialog" aria-live="assertive" aria-label="Aprobación comercial urgente" data-al-panel><div class="al-in">' +
        '<div class="al-head"><div class="al-title">⚠ APROBACIÓN COMERCIAL URGENTE' + (ring.length > 1 ? ' (' + ring.length + ')' : '') + '</div>' +
        '<button type="button" class="al-btn al-ghost" data-al-min title="Libera la pantalla; la alarma sigue pendiente (Escape)">MINIMIZAR (sigue pendiente)</button></div>' +
        '<div class="al-list" data-al-list tabindex="-1">' + ring.map(card).join('') + (more ? '<div class="al-card"><b>… y ' + more + ' alarma(s) más pendiente(s)</b>: se muestran al atender estas.</div>' : '') + '</div>' +
        '<div class="al-foot">' + (S.soundBlocked ? '<button type="button" class="al-btn al-main" data-al-sound>🔊 ACTIVAR SONIDO</button><small>El navegador bloquea el sonido hasta que toques la pantalla.</small>' : '') +
        pushHelp() + (msg ? '<b>' + esc(msg) + '</b>' : '') + '</div>' + focusHtml(ring, true) + '</div></div>';
    } else if (msg) {
      h += '<div role="status" style="position:fixed;right:14px;bottom:calc(env(safe-area-inset-bottom,0px) + 14px);z-index:2147483000;background:#0b2a37;color:#fff;border-radius:12px;padding:10px 14px;max-width:min(92vw,420px)">' + esc(msg) + '</div>';
    }
    if (!ring.length || S.suppressed !== 'CRITICO') {
      if (!ring.length) h += focusHtml(ring, false);
      if (mine.length) h += '<div role="status" data-al-mine style="position:fixed;left:14px;bottom:calc(env(safe-area-inset-bottom,0px) + 14px);z-index:2147482990;background:#fff8ec;color:#5a3a00;border:1px solid #e3b56a;border-radius:12px;padding:8px 12px;max-width:min(92vw,460px);font-size:13px;overflow-wrap:anywhere">' +
        mine.slice(0, 3).map(a => '<div><b>' + esc(a.number) + '</b> · ' + (a.sheet_key === 'AUTORIZACION' ? 'autorización ' : 'pedido ') + esc(a.order_ref) + ' · <b>' + esc(ST[a.status] || a.status) + '</b>' +
          (a.status === 'ATENDIDA' ? ' por ' + esc(nm(a.attended_by)) + ' a las ' + hhmm(a.attended_at) : a.escalated_at ? ' · ESCALADA a las ' + hhmm(a.escalated_at) : '') + '</div>').join('') + '</div>';
    }
    host.innerHTML = h;
    const cb = host.querySelector('[data-al-close]'); if (cb) cb.onclick = () => { S.focus = null; render(); };
    host.querySelectorAll('[data-al-attend]').forEach(b => b.onclick = () => attend(b.dataset.alAttend, Number(b.dataset.alV), b));
    const mb = host.querySelector('[data-al-min]'); if (mb) mb.onclick = () => { S.minimized = true; render(); };
    // abrir la autorización vinculada DESDE la alarma (no registra atención; el aviso queda minimizado y pendiente)
    host.querySelectorAll('[data-al-open-req]').forEach(b => b.onclick = () => { S.minimized = true; location.hash = '#/autorizaciones?alarma_sol=' + encodeURIComponent(b.dataset.alOpenReq); render(); });
    const xb = host.querySelector('[data-al-expand]'); if (xb) xb.onclick = () => { S.minimized = false; render(); };
    const sb = host.querySelector('[data-al-sound]'); if (sb) sb.onclick = () => { unlock(); beep(); later(render, 0); };
    const pb = host.querySelector('[data-al-push]'); if (pb) pb.onclick = async () => {
      try { const p = await Notification.requestPermission(); if (!alive) return;
        if (p === 'granted') { await subscribe(api); if (!alive) return; msg = 'Notificaciones activadas en este dispositivo.'; await refreshDevices(); } else msg = 'Notificaciones no habilitadas: la alarma solo se ve con la app abierta.'; }
      catch (e) { msg = 'No se pudieron activar las notificaciones: ' + (e.message || e); } render(); };
  }
  async function attend(id, version, btn) {
    if (!alive) return;
    if (['PIN', 'FIRMA'].includes(suppression())) return;   // B-W03: nunca se atiende con el PIN o la firma abiertos (aunque llegue un clic)
    if (btn) btn.disabled = true;
    try {
      const r = await api.comAlarmAttend(id, version); if (!alive) return;
      if (r && r.ok === false) msg = r.message || 'No podés atender esta alarma.';
      else msg = 'Atendida. La decisión (aprobar, rechazar, devolver o aprobar con cambios) se toma en Autorizaciones comerciales.';
    } catch (e) { if (!alive) return; msg = /CONFLICT/.test(String(e.message || e)) ? String(e.message || e).replace(/^CONFLICT:\s*/, '') : 'No se pudo atender: ' + (e.message || e); }
    if (S.focus && S.focus.id === id && !(msg || '').startsWith('No ')) S.focus = { ...S.focus, status: 'ATENDIDA', can_attend: false, attended_by: me.full_name, attended_at: new Date().toISOString() };
    await poll();
    later(() => { msg = ''; render(); }, 8000);
  }
  async function refreshDevices() { if (typeof api.comMyPushDevices !== 'function') return; try { const r = await api.comMyPushDevices(); if (alive) S.pushDevices = r && !r.demo ? Number(r.activos) : null; } catch (e) { } }
  // ---------- consulta (el reloj y el escalamiento son del SERVIDOR) ----------
  async function poll() {
    if (!alive || stopped) return; S.polls++;
    try {
      let items, total;
      if (typeof api.comMyAlarmsPage === 'function') { const r = await api.comMyAlarmsPage(20); items = (r && r.items) || []; total = (r && r.total_pending) || 0; }
      else { items = await api.comMyAlarms() || []; total = items.filter(a => a.status === 'PENDIENTE_ATENCION').length; }
      if (!alive) return;
      // una alarma NUEVA o una nueva ESCALADA vuelve a abrir el aviso aunque se haya minimizado
      const keys = items.filter(a => a.ring).map(a => a.id + ':' + (a.escalated_at ? 'E' : 'I'));
      if (keys.some(k => !S.known.has(k))) S.minimized = false;
      S.known = new Set(keys); S.alarms = items; S.total = total; S.lastError = null;
    } catch (e) {
      if (!alive) return;
      const t = String((e && (e.code || e.message)) || e);
      if (/FORBIDDEN|42501/.test(t)) { S.forbidden = true; if (current && current.userId === me.id) disposeComAlarm(); else dispose(); return; }   // sesión revocada o sin acceso: se destruye
      S.lastError = t;   // sin conexión: se conserva lo último y se reintenta al reconectar
    }
    S.alarms.filter(a => a.ring).forEach(sysNotify);
    render();
  }
  // O-W01: después de cada consulta se reprograma SOLO si la instancia sigue viva
  function schedule() { if (!alive || stopped) return; clearTimeout(pollTimer); timers.delete(pollTimer);
    pollTimer = later(async () => { await poll(); schedule(); }, document.hidden ? 30000 : 10000); }
  function dispose() {   // B-AL-01: SIN esperar al servidor
    if (!alive) return; alive = false; stopped = true;
    timers.forEach(id => clearTimeout(id)); timers.clear(); clearTimeout(pollTimer);
    if (beepTimer) { clearInterval(beepTimer); beepTimer = null; } beepEvery = 0; S.ringing = false;
    if (obs) { obs.disconnect(); obs = null; } if (raf) cancelAnimationFrame(raf);
    try { if (ctx && ctx.close) ctx.close(); } catch (e) { } ctx = null;
    L.forEach(([t, ev, fn, o]) => t.removeEventListener(ev, fn, o)); L.length = 0;
    S.alarms = []; S.focus = null; msg = '';
    try { host.innerHTML = ''; host.remove(); } catch (e) { }
    if (window.__okdComAlarm === S) delete window.__okdComAlarm;
    window.__okdComAlarmInstalled = false;
  }
  // B-W03: el PIN o una pantalla crítica pueden abrirse o cerrarse en cualquier momento → se reevalúa la prioridad (agrupado por cuadro)
  if (typeof MutationObserver !== 'undefined') {
    obs = new MutationObserver(muts => { if (!alive || muts.every(m => host.contains(m.target))) return; if (raf) return;
      raf = requestAnimationFrame(() => { raf = 0; if (alive && suppression() !== S.suppressed) render(); }); });
    obs.observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ['class', 'style', 'hidden', 'open'] });
  }
  on(window, 'keydown', e => { if (e.key === 'Escape' && S.ringing && !S.minimized && host.querySelector('[data-al-panel]')) { S.minimized = true; render(); } });
  on(window, 'online', () => { if (!stopped) poll(); });
  on(document, 'visibilitychange', () => { if (!stopped && !document.hidden) poll(); });
  on(window, 'focus', () => { if (!stopped) poll(); });
  on(window, 'hashchange', () => { if (!stopped) focusFromLink(); });
  S.poll = poll;   // reconexión / pruebas: consultar ya (el reloj y el escalamiento siguen siendo del servidor)
  poll().then(() => { if (alive) { schedule(); focusFromLink(); refreshDevices().then(() => { if (alive) render(); }); } });
  return { userId: me.id, poll, dispose, state: S };
}
