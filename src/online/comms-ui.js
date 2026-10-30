// =====================================================================================================================
// COMUNICACIONES INTERNAS · interfaz (módulo separado). Pestañas: Comunicados · Colaboradores · Conexión Gmail.
// Los botones reflejan los permisos efectivos; el servidor valida cada operación. WhatsApp: SOLO compartir manual.
// =====================================================================================================================
import { esc } from './util.js';
import { hasPerm } from '../../supabase/functions/_shared/rules.js';
import { resolveRecipients, sanitizeHtml, whatsappText, validateSchedule, nextRuns, describeSchedule, fmtLocal, fmtDate, estimateEmailBytes, mb, ATTACH,
  STATUS_LABEL, WEEKDAYS, localParts } from '../../supabase/functions/_shared/comms-core.js';

const can = (me, p) => hasPerm(me, p);
const pill = (cls, t) => '<span class="status ' + cls + '">' + esc(t) + '</span>';
const MSTATE = { BORRADOR: ['warn', 'Borrador'], ACTIVO: ['ok', 'Programado'], PAUSADO: ['warn', 'Pausado'], CANCELADO: ['bad', 'Cancelado'], FINALIZADO: ['ok', 'Finalizado'] };
const DSTATE = { PENDIENTE: 'warn', PROCESANDO: 'warn', ENVIADO: 'ok', ERROR: 'bad', POR_VERIFICAR: 'bad', CANCELADO: 'bad', OMITIDO: 'warn', VENCIDO: 'bad' };
const RSTATE = { PENDIENTE: ['warn', 'Pendiente'], EN_CURSO: ['warn', 'En curso'], COMPLETADA: ['ok', 'Completada'], PERDIDA: ['bad', 'Perdida: NO se envió (revisar)'], CANCELADA: ['bad', 'Cancelada'] };
const dt = t => t ? fmtLocal(Date.parse(t)) : '—';
const todayLocal = () => localParts(Date.now()).date;

function modal(host, title, bodyHtml, { okText, cancelText = 'CERRAR', wide } = {}) {
  return new Promise(resolve => {
    const m = document.createElement('div'); m.className = 'umodal comms-modal';
    m.innerHTML = '<div class="udialog' + (wide ? ' wide' : '') + '" role="dialog" aria-modal="true"><header><b>' + esc(title) + '</b></header><div class="body">' + bodyHtml +
      '<div class="up-msg err" data-merr hidden></div></div><footer><button class="btn ghost" type="button" data-mcancel>' + esc(cancelText) + '</button>' +
      (okText ? '<button class="btn dark" type="button" data-mok>' + esc(okText) + '</button>' : '') + '</footer></div>';
    (host || document.body).appendChild(m);
    const close = v => { m.remove(); resolve(v); };
    m.querySelector('[data-mcancel]').onclick = () => close(false);
    // al confirmar devuelve los valores de los campos [data-mval] (leídos ANTES de cerrar)
    const ok = m.querySelector('[data-mok]'); if (ok) ok.onclick = () => { const v = {}; m.querySelectorAll('[data-mval]').forEach(i => { v[i.dataset.mval] = i.value; }); close(v); };
    setTimeout(() => { const f = m.querySelector('input, textarea, button[data-mok]'); if (f) f.focus(); }, 30);
  });
}

export async function openComms(api, me, frame) {
  const w = frame(me, 'Comunicaciones', '#/comunicaciones');
  const qs = new URLSearchParams(location.hash.split('?')[1] || '');
  const st = { tab: qs.get('sec') === 'gmail' ? 'GMAIL' : qs.get('sec') === 'colaboradores' ? 'COLAB' : 'MSGS', edit: null, detail: null, flash: null };
  if (qs.get('r') === 'ok') st.flash = { text: 'Gmail conectado. El token quedó guardado en el servidor (nunca en este navegador).' };
  if (qs.get('r') === 'error') st.flash = { err: true, text: 'No se pudo conectar Gmail (' + (qs.get('m') || 'error') + '). Probá de nuevo.' };
  const say = (m) => { const box = w.querySelector('#cmMsg'); if (box) { box.className = 'msg ' + (m.err ? 'err' : 'ok'); box.textContent = m.text; box.hidden = false; box.scrollIntoView({ block: 'nearest' }); } };
  const tabs = () => '<div class="uact comms-tabs" role="tablist">' + [['MSGS', 'COMUNICADOS'], ['COLAB', 'COLABORADORES'], ['GMAIL', 'CONEXIÓN GMAIL']]
    .map(([k, t]) => '<button class="btn ' + (st.tab === k ? 'dark' : 'soft') + '" type="button" role="tab" data-ctab="' + k + '" aria-selected="' + (st.tab === k) + '">' + t + '</button>').join('') + '</div>';
  const shell = inner => { w.innerHTML = '<div class="grid comms"><section class="card span12"><div class="section-title"><h2>Comunicaciones internas</h2><span class="tag">' +
      esc(api.mode === 'online' ? 'Correo por Gmail · WhatsApp manual' : 'MODO DEMO: Gmail y envíos SIMULADOS') + '</span></div>' + tabs() +
      '<div class="msg" id="cmMsg" hidden></div>' + inner + '</section></div>';
    w.querySelectorAll('[data-ctab]').forEach(b => b.onclick = () => { st.tab = b.dataset.ctab; st.edit = null; st.detail = null; draw(); });
    if (st.flash) { say(st.flash); st.flash = null; } };
  const guard = async (fn, okText) => { try { const r = await fn(); if (okText) st.flash = { text: okText }; await draw(); return r; } catch (e) { say({ err: true, text: e.message }); return null; } };

  // ===================== COLABORADORES =====================
  async function drawColab() {
    let cs; try { cs = await api.commsCollaborators(); } catch (e) { shell('<div class="msg err">No se pudieron cargar los colaboradores: ' + esc(e.message) + ' <button class="btn soft" type="button" data-retry>REINTENTAR</button></div>'); w.querySelector('[data-retry]').onclick = () => draw(); return; }
    const mg = can(me, 'comms.collaborators_manage'), act = cs.filter(c => c.active).length;
    shell('<p class="rp-note">' + act + ' activos de ' + cs.length + '. No necesitan tener cuenta en Despacho.</p>' +
      (mg ? '<div class="uact"><button class="btn go" type="button" id="colNew">+ NUEVO COLABORADOR</button></div><div id="colForm"></div>' : '') +
      '<div class="tscroll"><table class="table" id="colTable"><thead><tr><th>Nombre y apellido</th><th>Correo</th><th>Celular</th><th>Sucursal</th><th>Sector</th><th>Estado</th><th></th></tr></thead><tbody>' +
      (cs.map(c => '<tr data-cid="' + esc(c.id) + '"' + (c.active ? '' : ' class="veh-off"') + '><td><b>' + esc(c.full_name) + '</b></td><td>' + esc(c.email) + '</td><td>' + esc(c.phone || '') + '</td><td>' + esc(c.branch || '') + '</td><td>' + esc(c.sector || '') + '</td><td>' +
        (c.active ? pill('ok', 'Activo') : pill('warn', 'Inactivo')) + '</td><td>' + (mg ? '<div class="uact"><button class="btn soft" type="button" data-cedit>EDITAR</button><button class="btn soft" type="button" data-ctoggle>' + (c.active ? 'DESACTIVAR' : 'ACTIVAR') + '</button></div>' : '') + '</td></tr>').join('')
        || '<tr><td colspan="7">Todavía no hay colaboradores.</td></tr>') + '</tbody></table></div>');
    const form = c => { const box = w.querySelector('#colForm'); box.innerHTML = '<div class="card" style="margin:10px 0"><h3>' + (c ? 'Editar colaborador' : 'Nuevo colaborador') + '</h3><div class="row-form">' +
        [['cfName', 'Nombre y apellido', c && c.full_name], ['cfEmail', 'Correo', c && c.email], ['cfPhone', 'Celular', c && c.phone], ['cfBranch', 'Sucursal', c && c.branch], ['cfSector', 'Sector', c && c.sector]]
          .map(([id, l, v]) => '<label>' + l + ' <input class="ed" id="' + id + '" value="' + esc(v || '') + '"></label>').join('') +
        '<label class="chk"><input type="checkbox" id="cfActive"' + (!c || c.active ? ' checked' : '') + '> Activo</label></div><div class="uact"><button class="btn dark" type="button" id="cfSave">GUARDAR</button><button class="btn soft" type="button" id="cfCancel">CANCELAR</button></div></div>';
      box.querySelector('#cfCancel').onclick = () => { box.innerHTML = ''; };
      box.querySelector('#cfSave').onclick = () => guard(() => api.commsSaveCollaborator({ id: c && c.id, full_name: w.querySelector('#cfName').value, email: w.querySelector('#cfEmail').value, phone: w.querySelector('#cfPhone').value,
        branch: w.querySelector('#cfBranch').value, sector: w.querySelector('#cfSector').value, active: w.querySelector('#cfActive').checked }), 'Colaborador guardado.'); };
    const nb = w.querySelector('#colNew'); if (nb) nb.onclick = () => form(null);
    w.querySelectorAll('[data-cedit]').forEach(b => b.onclick = () => form(cs.find(c => c.id === b.closest('tr').dataset.cid)));
    w.querySelectorAll('[data-ctoggle]').forEach(b => b.onclick = () => { const c = cs.find(x => x.id === b.closest('tr').dataset.cid);
      guard(() => api.commsSaveCollaborator({ ...c, active: !c.active }), c.active ? 'Colaborador desactivado: se omite en los próximos envíos (queda registrado el motivo).' : 'Colaborador activado.'); });
  }

  // ===================== CONEXIÓN GMAIL =====================
  async function drawGmail() {
    let g; try { g = await api.commsGmailStatus(); } catch (e) { shell('<div class="msg err">No se pudo consultar la conexión: ' + esc(e.message) + ' <button class="btn soft" type="button" data-retry>REINTENTAR</button></div>'); w.querySelector('[data-retry]').onclick = () => draw(); return; }
    const d = g.last_dispatch, fresh = d && Date.now() - Date.parse(d.at) < 20 * 60e3, mg = can(me, 'comms.gmail_manage');
    const conn = !g.connected ? pill('warn', 'No conectada') : g.needs_reconnect ? pill('bad', 'Requiere reconexión') : pill('ok', 'Conectada');
    const auto = g.mode === 'demo' ? pill('warn', 'Simulada (demo)') : !d ? pill('bad', 'No operativa: el programador del servidor nunca se ejecutó (falta configurarlo)')
      : !fresh ? pill('bad', 'No operativa: la última ejecución fue ' + dt(d.at)) : pill('ok', 'Operativa');
    shell('<div class="grid"><div class="card span6" id="gmailCard"><h3>Cuenta Gmail</h3><p>Estado: ' + conn + '</p>' + (g.email ? '<p>Cuenta: <b>' + esc(g.email) + '</b>' + (g.simulated ? ' (simulada)' : '') + '</p>' : '') +
      (g.connected_at ? '<p class="rp-note">Conectada el ' + esc(dt(g.connected_at)) + '</p>' : '') + (g.last_error ? '<p class="msg err">Último error: ' + esc(g.last_error) + '</p>' : '') +
      (mg ? '<div class="uact">' + (!g.connected ? '<button class="btn dark" type="button" id="gmConnect">CONECTAR GMAIL</button>' : (g.needs_reconnect ? '<button class="btn dark" type="button" id="gmConnect">RECONECTAR</button>' : '') +
        '<button class="btn soft" type="button" id="gmDisconnect">DESCONECTAR</button>') + '</div>' : '<p class="rp-note">Solo quien tiene el permiso "administrar la conexión Gmail" puede conectarla.</p>') +
      '<p class="rp-note">Se conecta con el inicio de sesión oficial de Google (OAuth). Despacho nunca pide la contraseña de Gmail. Permiso pedido: solo <b>enviar correos</b> (no lee el buzón). El token queda guardado en el servidor, nunca en el navegador.</p></div>' +
      '<div class="card span6" id="autoCard"><h3>Automatización</h3><p>Programador: ' + auto + '</p>' + (d ? '<p class="rp-note">Última ejecución: ' + esc(dt(d.at)) + ' · ' + esc(d.status) + ' · enviados: ' + (d.sent || 0) + (d.note ? ' · ' + esc(d.note) : '') + '</p>' : '') +
      (g.mode === 'demo' ? '<p class="msg warn">Modo demo: la conexión y los envíos son SIMULADOS. No se envía ningún correo real.</p><div class="uact"><button class="btn soft" type="button" id="gmTick">SIMULAR EJECUCIÓN DEL PROGRAMADOR</button></div>' : '') +
      '<p class="rp-note">Límites: una cuenta Gmail gratuita admite hasta 500 correos por día (Despacho se detiene en 400, contando solo los enviados por este módulo) y 25 MB por correo. La velocidad la controla el servidor para todos los envíos juntos: hasta 60 por minuto y 2 por segundo (cuota de Gmail API).</p></div></div>');
    const c = w.querySelector('#gmConnect'); if (c) c.onclick = () => guard(() => api.commsGmailConnect(), api.mode === 'online' ? null : 'Gmail conectado (SIMULADO en la demo).');
    const x = w.querySelector('#gmDisconnect'); if (x) x.onclick = async () => { if (await modal(w, 'Desconectar Gmail', '<p>Se revoca el permiso en Google y se borra el token del servidor. Los envíos programados quedan sin enviar hasta reconectar.</p>', { okText: 'DESCONECTAR', cancelText: 'CANCELAR' })) guard(() => api.commsGmailDisconnect(), 'Gmail desconectado.'); };
    const t = w.querySelector('#gmTick'); if (t) t.onclick = () => guard(async () => { const s = await api.commsDemoTick(); st.flash = { text: 'Programador simulado: ' + s.status + ' · enviados ' + s.sent + (s.note ? ' · ' + s.note : '') }; });
  }

  // ===================== COMUNICADOS: lista =====================
  async function drawMsgs() {
    let ms, cs, g;
    try { [ms, cs, g] = await Promise.all([api.commsMessages(), api.commsCollaborators(), api.commsGmailStatus()]); }
    catch (e) { shell('<div class="msg err">No se pudieron cargar los comunicados: ' + esc(e.message) + ' <button class="btn soft" type="button" data-retry>REINTENTAR</button></div>'); w.querySelector('[data-retry]').onclick = () => draw(); return; }
    if (st.edit) return drawEditor(st.edit === 'NEW' ? null : ms.find(m => m.id === st.edit), cs, g);
    if (st.detail) return drawDetail(ms.find(m => m.id === st.detail), cs);
    const warnConn = !g.connected || g.needs_reconnect ? '<p class="msg warn" id="cmNoGmail">Gmail ' + (g.needs_reconnect ? 'requiere reconexión' : 'no está conectado') + ': los comunicados se pueden redactar y compartir por WhatsApp, pero no programar envíos por correo.</p>' : '';
    shell(warnConn + (can(me, 'comms.compose') ? '<div class="uact"><button class="btn go" type="button" id="cmNew">+ NUEVO COMUNICADO</button></div>' : '') + '<div class="comms-list" id="cmList">' +
      (ms.map(m => { const [c, t] = MSTATE[m.status] || ['warn', m.status], nx = m.status === 'ACTIVO' ? nextRuns(m.schedule, Date.now(), 1)[0] : null, n = resolveRecipients(cs, m.selection).list.length;
        return '<article class="card comms-item" data-mid="' + esc(m.id) + '"><div class="section-title"><h3>' + esc(m.internal_name) + '</h3>' + pill(c, t) + '</div>' +
          '<p><b>Asunto:</b> ' + esc(m.subject || '(sin asunto)') + '</p><p class="rp-note">' + esc(describeSchedule(m.schedule)) + ' · ' + n + ' destinatario(s) activos · ' + (m.attachments || []).length + ' adjunto(s)' +
          (nx ? ' · próximo: <b>' + esc(fmtLocal(nx)) + '</b>' : '') + '</p><div class="uact">' +
          '<button class="btn soft" type="button" data-act="detail">HISTORIAL</button><button class="btn soft" type="button" data-act="preview">VISTA PREVIA</button>' +
          (can(me, 'comms.compose') && !['CANCELADO', 'FINALIZADO'].includes(m.status) ? '<button class="btn soft" type="button" data-act="edit">EDITAR</button>' : '') +
          (can(me, 'comms.compose') ? '<button class="btn soft" type="button" data-act="dup">DUPLICAR</button>' : '') +
          (can(me, 'comms.test_send') ? '<button class="btn soft" type="button" data-act="test">ENVIAR PRUEBA</button>' : '') +
          (can(me, 'comms.schedule') && m.status === 'BORRADOR' ? '<button class="btn dark" type="button" data-act="activate">PROGRAMAR ENVÍO</button>' : '') +
          (can(me, 'comms.schedule') && m.status === 'ACTIVO' ? '<button class="btn soft" type="button" data-act="pause">PAUSAR</button>' : '') +
          (can(me, 'comms.schedule') && m.status === 'PAUSADO' ? '<button class="btn dark" type="button" data-act="resume">REANUDAR</button>' : '') +
          (can(me, 'comms.schedule') && ['BORRADOR', 'ACTIVO', 'PAUSADO'].includes(m.status) ? '<button class="btn soft" type="button" data-act="cancel">CANCELAR ENVÍOS</button>' : '') +
          '<button class="btn wa" type="button" data-act="wa">COMPARTIR POR WHATSAPP</button></div></article>'; }).join('') || '<p>No hay comunicados.</p>') + '</div>');
    const nb = w.querySelector('#cmNew'); if (nb) nb.onclick = () => { st.edit = 'NEW'; draw(); };
    w.querySelectorAll('[data-act]').forEach(b => b.onclick = async () => {
      const m = ms.find(x => x.id === b.closest('[data-mid]').dataset.mid), a = b.dataset.act;
      if (a === 'detail') { st.detail = m.id; return draw(); }
      if (a === 'edit') { st.edit = m.id; return draw(); }
      if (a === 'preview') return preview(m);
      if (a === 'wa') return shareWhatsApp(m);
      if (a === 'dup') return guard(() => api.commsDuplicate(m.id), 'Comunicado duplicado como borrador.');
      if (a === 'test') { const v = await modal(w, 'Enviar una prueba', '<p>Se envía UNA copia, marcada [PRUEBA], a la dirección que indiques. No afecta a los destinatarios ni a la programación.</p><label>Correo de prueba <input class="ed" id="tmEmail" data-mval="email" type="email" placeholder="tu.correo@ejemplo.com"></label>', { okText: 'ENVIAR PRUEBA', cancelText: 'CANCELAR' });
        if (!v) return; const em = String(v.email || '').trim(); return guard(() => api.commsRequestTest(m.id, em), 'Prueba en cola para ' + em + '. Se envía en la próxima ejecución del programador.'); }
      if (a === 'activate') return confirmActivate(m, cs);
      if (a === 'pause') return guard(() => api.commsPause(m.id), 'Pausado. Al reanudar NO se envía lo que venció durante la pausa.');
      if (a === 'resume') return guard(() => api.commsResume(m.id), 'Reanudado. Sigue desde el próximo horario (no se envían de golpe los vencidos).');
      if (a === 'cancel') { if (await modal(w, 'Cancelar envíos futuros', '<p>Se cancelan los envíos pendientes y futuros de <b>' + esc(m.internal_name) + '</b>. Lo que Gmail ya aceptó no se puede retirar. El historial se conserva.</p>', { okText: 'CANCELAR ENVÍOS', cancelText: 'VOLVER' }))
        return guard(() => api.commsCancel(m.id), 'Envíos cancelados. El historial se conserva.'); }
    });
  }

  async function confirmActivate(m, cs) {
    const errs = validateSchedule(m.schedule), r = resolveRecipients(cs, m.selection), nx = nextRuns(m.schedule, Date.now(), 5);
    if (errs.length || !r.list.length || !m.subject) return say({ err: true, text: [!m.subject && 'Falta el asunto.', !r.list.length && 'No hay destinatarios activos.', ...errs].filter(Boolean).join(' ') });
    const ok = await modal(w, 'Confirmar programación', '<p><b>' + esc(describeSchedule(m.schedule)) + '</b></p><p>Próximas ejecuciones (hora de Argentina):</p><ul id="actNext">' + nx.map(t => '<li>' + esc(fmtLocal(t)) + '</li>').join('') + '</ul>' +
      '<p>Lista final: <b>' + r.list.length + '</b> destinatario(s) (cada uno recibe su propio correo, sin ver a los demás):</p><div class="tscroll comms-final"><ul id="actList">' + r.list.map(x => '<li>' + esc(x.name) + ' · ' + esc(x.email) + '</li>').join('') + '</ul></div>' +
      (r.excluded.length ? '<p class="rp-note">No incluidos: ' + esc(r.excluded.map(x => x.name + ' (' + x.reason + ')').join(', ')) + '</p>' : '') +
      '<p class="rp-note">En cada ejecución se usan los colaboradores ACTIVOS de ese momento y se guarda una copia del contenido y los adjuntos.</p>', { okText: 'PROGRAMAR', cancelText: 'CANCELAR', wide: true });
    if (ok) return guard(() => api.commsActivate(m.id), 'Programado: ' + describeSchedule(m.schedule) + '.');
  }

  // ===================== Vista previa (aislada) =====================
  async function preview(m) {
    const safe = sanitizeHtml(m.body_html), doc = '<!doctype html><meta charset="utf-8"><body style="font-family:Arial,sans-serif;font-size:15px;line-height:1.5;color:#111;margin:12px">' + safe + '</body>';
    await modal(w, 'Vista previa', '<p><b>Asunto:</b> ' + esc(m.subject) + '</p><iframe class="comms-preview" id="pvFrame" sandbox="" title="Vista previa del correo" srcdoc="' + esc(doc) + '"></iframe>' +
      '<p class="rp-note">Adjuntos: ' + esc((m.attachments || []).map(a => (a.file_name || a.name) + ' (' + mb(a.size_bytes) + ')').join(', ') || 'ninguno') + ' · tamaño estimado del correo: ' +
      esc(mb(estimateEmailBytes({ subject: m.subject, html: safe, attachments: m.attachments || [] }))) + ' de 25 MB</p><h4>Texto para WhatsApp</h4><pre class="comms-wa" id="pvWa">' + esc(whatsappText(m)) + '</pre>', { wide: true });
  }

  // ===================== Compartir por WhatsApp (manual) =====================
  async function shareWhatsApp(m) {
    const text = whatsappText(m), atts = m.attachments || [];
    let files = []; try { files = await Promise.all(atts.map(async a => new File([await api.commsAttachmentBlob(a)], a.file_name || a.name, { type: a.mime }))); } catch (e) { files = []; }
    const canText = typeof navigator.share === 'function', canFiles = !!(files.length && navigator.canShare && (() => { try { return navigator.canShare({ files }); } catch (e) { return false; } })());
    const canBoth = !!(canFiles && navigator.canShare && (() => { try { return navigator.canShare({ text, files }); } catch (e) { return false; } })());
    const capa = '<p class="rp-note" id="waCaps">Este dispositivo: compartir texto ' + (canText ? '✓' : '✗') + ' · compartir archivos ' + (files.length ? (canFiles ? '✓' : '✗') : '(sin adjuntos)') + '</p>';
    const body = '<p>Despacho <b>no</b> crea grupos ni listas de difusión, <b>no</b> elige el grupo y <b>no</b> envía nada solo. Vos elegís el grupo (por ejemplo «OK Accesorios · Comunicados») y tocás Enviar en WhatsApp.</p>' + capa +
      (files.length && canText && !canBoth ? '<p class="msg warn" id="waSplit">Este dispositivo no permite compartir el texto y los archivos juntos. Compartilos por separado: primero el mensaje y después los adjuntos (o descargalos y adjuntalos en WhatsApp).</p>' : '') +
      '<div class="uact">' + (canText ? '<button class="btn wa" type="button" id="waShare">' + (canBoth || !files.length ? 'COMPARTIR POR WHATSAPP' : 'COMPARTIR MENSAJE') + '</button>' : '') +
      (canFiles && !canBoth ? '<button class="btn soft" type="button" id="waShareFiles">COMPARTIR ADJUNTOS</button>' : '') +
      '<button class="btn soft" type="button" id="waCopy">COPIAR MENSAJE PARA WHATSAPP</button>' + (atts.length ? '<button class="btn soft" type="button" id="waDownload">DESCARGAR ADJUNTOS</button>' : '') +
      '<a class="btn soft" id="waOpen" href="https://wa.me/?text=' + encodeURIComponent(text) + '" target="_blank" rel="noopener">ABRIR WHATSAPP CON EL TEXTO</a></div>' +
      '<ol class="rp-note"><li>Compartí o copiá el mensaje (y los adjuntos).</li><li>En WhatsApp elegí el grupo.</li><li>Revisá y tocá Enviar.</li></ol>' +
      '<textarea class="ed comms-wa" id="waText" readonly rows="8">' + esc(text) + '</textarea><p class="msg" id="waMsg" hidden></p>' +
      (can(me, 'comms.compose') ? '<hr><p><b>Registro manual</b> (separado de los correos por Gmail): copiar, abrir WhatsApp o usar «compartir» NO lo marca solo.</p><button class="btn dark" type="button" id="waRegister">REGISTRAR COMO COMPARTIDO POR WHATSAPP</button>' : '');
    const p = modal(w, 'Compartir por WhatsApp', body, { wide: true });
    const box = [...w.querySelectorAll('.comms-modal')].pop(), note = t => { const e = box.querySelector('#waMsg'); e.hidden = false; e.className = 'msg ok'; e.textContent = t; };
    const s = box.querySelector('#waShare'); if (s) s.onclick = async () => { try { await navigator.share(canBoth ? { text, files } : { text }); note(canBoth ? 'Listo el diálogo de compartir. Recordá: compartirlo no lo registra.' : 'Mensaje compartido. Ahora compartí o adjuntá los archivos por separado.'); } catch (e) { if (e && e.name !== 'AbortError') note('No se pudo abrir «compartir»: usá COPIAR MENSAJE.'); } };
    const sf = box.querySelector('#waShareFiles'); if (sf) sf.onclick = async () => { try { await navigator.share({ files }); note('Adjuntos compartidos.'); } catch (e) { if (e && e.name !== 'AbortError') note('No se pudieron compartir los archivos: descargalos.'); } };
    box.querySelector('#waCopy').onclick = async () => { try { await navigator.clipboard.writeText(text); } catch (e) { const t = box.querySelector('#waText'); t.select(); document.execCommand && document.execCommand('copy'); } note('Mensaje copiado. Pegalo en el grupo de WhatsApp.'); };
    const dl = box.querySelector('#waDownload'); if (dl) dl.onclick = async () => { for (const a of atts) { const b = await api.commsAttachmentBlob(a), u = URL.createObjectURL(b), l = document.createElement('a'); l.href = u; l.download = a.file_name || a.name; document.body.appendChild(l); l.click(); l.remove(); setTimeout(() => URL.revokeObjectURL(u), 4000); } note('Adjuntos descargados.'); };
    const rg = box.querySelector('#waRegister'); if (rg) rg.onclick = async () => {
      if (!confirm('¿Confirmás que lo compartiste MANUALMENTE en WhatsApp? Esto registra tu usuario y la fecha; NO confirma que lo hayan recibido ni dispara correos.')) return;
      try { await api.commsRegisterWhatsApp(m.id, 'Compartido manualmente'); note('Registrado como compartido por WhatsApp (' + me.full_name + ', ' + fmtLocal(Date.now()) + ').'); rg.disabled = true; } catch (e) { note(e.message); } };
    await p;
  }

  // ===================== Historial / seguimiento =====================
  async function drawDetail(m, cs) {
    let runs = [], shares = [], audit = [];
    try { [runs, shares, audit] = await Promise.all([api.commsRuns(m.id), api.commsWhatsAppShares(m.id), api.commsAudit(m.id)]); }
    catch (e) { shell('<div class="msg err">No se pudo cargar el historial: ' + esc(e.message) + ' <button class="btn soft" type="button" data-retry>REINTENTAR</button></div>'); w.querySelector('[data-retry]').onclick = () => draw(); return; }
    const nx = m.status === 'ACTIVO' ? nextRuns(m.schedule, Date.now(), 5) : [], rs = can(me, 'comms.schedule');
    const count = r => Object.entries(r.deliveries.reduce((a, d) => (a[d.status] = (a[d.status] || 0) + 1, a), {})).map(([k, v]) => STATUS_LABEL[k] + ': ' + v).join(' · ');
    shell('<div class="uact"><button class="btn soft" type="button" id="cmBack">← VOLVER</button></div><h3>' + esc(m.internal_name) + ' ' + pill(...(MSTATE[m.status] || ['warn', m.status])) + '</h3>' +
      '<p class="rp-note">"Enviado — aceptado por Gmail" significa que Gmail lo recibió para enviarlo; no significa entregado ni leído.</p>' +
      '<h4>Próximos envíos</h4>' + (nx.length ? '<ul id="dtNext">' + nx.map(t => '<li>' + esc(fmtLocal(t)) + ' (hora de Argentina)</li>').join('') + '</ul>' : '<p id="dtNext">' + (m.status === 'PAUSADO' ? 'Pausado: no hay envíos hasta reanudar.' : 'No hay envíos programados.') + '</p>') +
      '<h4>Ejecuciones y resultados por destinatario</h4>' + (runs.map(r => '<details class="card comms-run" data-rid="' + esc(r.id) + '"' + (r.kind === 'PRUEBA' || r === runs[0] ? ' open' : '') + '><summary><b>' + esc(dt(r.scheduled_for)) + '</b> · ' + (r.kind === 'PRUEBA' ? 'Prueba' : 'Programado') + ' · ' +
        pill(...(RSTATE[r.status] || ['warn', r.status])) + ' · ' + esc(count(r)) + '</summary>' + (r.note ? '<p class="msg warn">' + esc(r.note) + '</p>' : '') + '<p class="rp-note">Copia usada: «' + esc(r.snapshot && r.snapshot.subject) + '» (versión ' + esc(r.snapshot && r.snapshot.message_version || '—') + ')</p>' +
        '<div class="tscroll"><table class="table"><thead><tr><th>Destinatario</th><th>Estado</th><th>Intentos</th><th>Detalle</th><th></th></tr></thead><tbody>' +
        r.deliveries.map(d => '<tr data-did="' + esc(d.id) + '"><td>' + esc(d.name || '') + '<br><small>' + esc(d.email || '') + '</small></td><td>' + pill(DSTATE[d.status] || 'warn', STATUS_LABEL[d.status] || d.status) + '</td><td>' + (d.attempts || 0) + '</td><td><small>' +
          esc([d.sent_at && (d.sent_at_source === 'ESTIMADA_INICIO_INTENTO' ? 'Envío estimado (inicio del intento): ' : 'Aceptado por Gmail: ') + dt(d.sent_at),
            d.confirmed_at && 'Confirmado manualmente: ' + dt(d.confirmed_at), d.gmail_message_id && 'Id Gmail: ' + d.gmail_message_id, d.next_attempt_at && d.status === 'ERROR' && d.retryable && 'Próximo intento: ' + dt(d.next_attempt_at), d.reason, d.last_error].filter(Boolean).join(' · ')) + '</small></td><td>' +
          (d.status === 'POR_VERIFICAR' && rs ? '<div class="uact"><button class="btn soft" type="button" data-vok>FIGURA EN ENVIADOS</button><button class="btn soft" type="button" data-vretry>NO FIGURA: REINTENTAR</button></div>' : '') +
          (d.status === 'VENCIDO' && rs ? '<div class="uact"><button class="btn soft" type="button" data-vlate>ENVIAR IGUAL (MANUAL)</button></div>' : '') + '</td></tr>').join('') +
        '</tbody></table></div></details>').join('') || '<p>Todavía no hubo ejecuciones.</p>') +
      '<h4>Compartido por WhatsApp (registro manual, separado de los correos)</h4>' + (shares.length ? '<ul id="dtWa">' + shares.map(s => '<li>' + esc(dt(s.shared_at)) + ' · ' + esc(s.shared_by_name || s.shared_by) + (s.note ? ' · ' + esc(s.note) : '') + ' <small>(no confirma recepción)</small></li>').join('') + '</ul>' : '<p id="dtWa">Sin registros.</p>') +
      '<h4>Auditoría</h4><div class="tscroll"><table class="table" id="dtAudit"><thead><tr><th>Fecha</th><th>Acción</th><th>Quién</th></tr></thead><tbody>' +
      (audit.map(a => '<tr><td>' + esc(dt(a.at)) + '</td><td>' + esc(a.entity + ' · ' + a.action) + '</td><td>' + esc(a.actor_name || a.actor || '') + '</td></tr>').join('') || '<tr><td colspan="3">Sin movimientos.</td></tr>') + '</tbody></table></div>');
    w.querySelector('#cmBack').onclick = () => { st.detail = null; draw(); };
    w.querySelectorAll('[data-vok]').forEach(b => b.onclick = () => guard(() => api.commsResolveVerify(Number(b.closest('tr').dataset.did) || b.closest('tr').dataset.did, 'CONFIRMADO_ENVIADO'), 'Marcado como enviado (confirmado en Enviados).'));
    w.querySelectorAll('[data-vlate]').forEach(b => b.onclick = async () => { if (await modal(w, 'Enviar un vencido', '<p>Este envío no salió a tiempo (pausa, desconexión o interrupción). Enviarlo ahora es una decisión manual: el destinatario lo recibirá tarde.</p>', { okText: 'ENVIAR AHORA', cancelText: 'CANCELAR' }))
      guard(() => api.commsResolveVerify(Number(b.closest('tr').dataset.did) || b.closest('tr').dataset.did, 'REINTENTAR'), 'Habilitado: se envía en la próxima ejecución del programador.'); });
    w.querySelectorAll('[data-vretry]').forEach(b => b.onclick = async () => { if (await modal(w, 'Reintentar envío', '<p>Reintentá SOLO si comprobaste que el correo NO figura en «Enviados» de la cuenta Gmail. Si llegó a enviarse, el destinatario lo recibiría dos veces.</p>', { okText: 'REINTENTAR', cancelText: 'CANCELAR' }))
      guard(() => api.commsResolveVerify(Number(b.closest('tr').dataset.did) || b.closest('tr').dataset.did, 'REINTENTAR'), 'Vuelve a la cola.'); });
  }

  // ===================== Editor =====================
  async function drawEditor(m0, cs, g) {
    let m = m0;   // se actualiza al guardar o al cambiar adjuntos, SIN redibujar el editor
    const isNew = !m, sel = (m && m.selection) || {}, sch = (m && m.schedule) || { kind: 'WEEKLY', time: '09:00', start_date: todayLocal(), weekdays: [1] };
    const uniq = k => [...new Set(cs.map(c => (c[k] || '').trim()).filter(Boolean))].sort((a, b) => a.localeCompare(b, 'es'));
    const chk = (name, val, on, label) => '<label class="chk"><input type="checkbox" data-' + name + ' value="' + esc(val) + '"' + (on ? ' checked' : '') + '> ' + esc(label) + '</label>';
    shell('<div class="uact"><button class="btn soft" type="button" id="edBack">← VOLVER</button></div><h3>' + (isNew ? 'Nuevo comunicado' : 'Editar · ' + esc(m.internal_name)) + (m ? ' ' + pill(...(MSTATE[m.status] || ['warn', m.status])) : '') + '</h3>' +
      (m && ['ACTIVO', 'PAUSADO'].includes(m.status) ? '<p class="msg warn">Está ' + (m.status === 'ACTIVO' ? 'programado' : 'pausado') + ': los cambios afectan los PRÓXIMOS envíos (se pide confirmación). Lo ya enviado no cambia.</p>' : '') +
      '<div class="row-form"><label>Nombre interno <input class="ed" id="edName" value="' + esc(m ? m.internal_name : '') + '"></label><label>Asunto <input class="ed" id="edSubject" value="' + esc(m ? m.subject : '') + '"></label></div>' +
      '<label>Texto</label><div class="uact comms-toolbar" role="toolbar">' + [['bold', 'N', 'Negrita'], ['italic', 'C', 'Cursiva'], ['underline', 'S', 'Subrayado'], ['insertUnorderedList', '• Lista', 'Lista'], ['insertOrderedList', '1. Lista', 'Lista numerada'], ['createLink', 'Enlace', 'Enlace'], ['removeFormat', 'Sin formato', 'Quitar formato']]
        .map(([c, t, l]) => '<button class="btn soft" type="button" data-cmd="' + c + '" title="' + l + '" aria-label="' + l + '">' + t + '</button>').join('') + '</div>' +
      '<div class="ed comms-body" id="edBody" contenteditable="true" role="textbox" aria-multiline="true">' + sanitizeHtml(m ? m.body_html : '<p></p>') + '</div>' +
      '<h4>Adjuntos</h4><p class="rp-note" id="edLimits">Imágenes (PNG, JPG, WEBP, GIF) o PDF · hasta ' + ATTACH.maxFiles + ' archivos, ' + mb(ATTACH.maxFileBytes) + ' cada uno y ' + mb(ATTACH.maxTotalBytes) + ' en total. Gmail admite hasta 25 MB por correo (los adjuntos pesan ~33 % más al enviarse).</p>' +
      '<ul id="edAtts"></ul>' +
      '<label class="btn soft" for="edFile">+ AGREGAR ADJUNTO</label><input type="file" id="edFile" accept="image/png,image/jpeg,image/webp,image/gif,application/pdf" hidden><p class="rp-note" id="edSize"></p>' +
      '<h4>Destinatarios</h4>' + chk('all', '1', sel.all, 'Todos los activos') + '<div class="comms-sel"><b>Sucursales</b> ' + uniq('branch').map(b => chk('branch', b, (sel.branches || []).includes(b), b)).join('') + '</div>' +
      '<div class="comms-sel"><b>Sectores</b> ' + uniq('sector').map(s => chk('sector', s, (sel.sectors || []).includes(s), s)).join('') + '</div>' +
      '<details class="comms-sel"><summary><b>Individuales</b></summary>' + cs.map(c => chk('person', c.id, (sel.ids || []).includes(c.id), c.full_name + (c.active ? '' : ' (inactivo)'))).join('') + '</details>' +
      '<div class="card comms-final" id="edFinal"></div>' +
      '<h4>Programación (hora de Argentina)</h4><div class="row-form"><label>Tipo <select class="ed" id="edKind">' + [['ONCE', 'Único'], ['DAILY', 'Diario'], ['WEEKLY', 'Semanal'], ['MONTHLY', 'Mensual']].map(([k, t]) => '<option value="' + k + '"' + (sch.kind === k ? ' selected' : '') + '>' + t + '</option>').join('') + '</select></label>' +
      '<label>Horario <input class="ed" type="time" id="edTime" value="' + esc(sch.time) + '"></label><label>Desde <input class="ed" type="date" id="edStart" value="' + esc(sch.start_date) + '"></label>' +
      '<label>Hasta (opcional) <input class="ed" type="date" id="edEnd" value="' + esc(sch.end_date || '') + '"></label></div>' +
      '<div id="edWeek" class="comms-sel"><b>Días</b> ' + [1, 2, 3, 4, 5, 6, 7].map(d => chk('wd', String(d), (sch.weekdays || []).includes(d), WEEKDAYS[d])).join('') + '</div>' +
      '<div id="edMonth" class="row-form"><label>Día del mes <input class="ed" type="number" min="1" max="31" id="edMday" value="' + esc(sch.month_day || 1) + '"></label><div id="edMissing"><b>Meses sin ese día:</b> ' +
      '<label class="chk"><input type="radio" name="edMiss" value="LAST_DAY"' + (sch.month_missing === 'LAST_DAY' ? ' checked' : '') + '> último día del mes</label><label class="chk"><input type="radio" name="edMiss" value="SKIP"' + (sch.month_missing === 'SKIP' ? ' checked' : '') + '> omitir ese mes</label></div></div>' +
      '<div class="card" id="edNext"></div><div class="uact"><button class="btn dark" type="button" id="edSave">' + (isNew ? 'GUARDAR BORRADOR' : 'GUARDAR CAMBIOS') + '</button><button class="btn soft" type="button" id="edPreview">VISTA PREVIA</button></div>');
    const $ = s => w.querySelector(s), body = $('#edBody');
    const read = () => { const k = $('#edKind').value, s = { kind: k, time: $('#edTime').value, start_date: $('#edStart').value };
      if ($('#edEnd').value) s.end_date = $('#edEnd').value;
      if (k === 'WEEKLY') s.weekdays = [...w.querySelectorAll('[data-wd]:checked')].map(x => +x.value);
      if (k === 'MONTHLY') { s.month_day = +$('#edMday').value; const r = w.querySelector('[name=edMiss]:checked'); if (r) s.month_missing = r.value; }
      return { internal_name: $('#edName').value.trim(), subject: $('#edSubject').value.trim(), body_html: sanitizeHtml(body.innerHTML), schedule: s,
        selection: { all: $('[data-all]').checked, branches: [...w.querySelectorAll('[data-branch]:checked')].map(x => x.value), sectors: [...w.querySelectorAll('[data-sector]:checked')].map(x => x.value), ids: [...w.querySelectorAll('[data-person]:checked')].map(x => x.value) } }; };
    const refresh = () => { const p = read(), r = resolveRecipients(cs, p.selection), errs = validateSchedule(p.schedule), nx = errs.length ? [] : nextRuns(p.schedule, Date.now(), 5);
      $('#edWeek').hidden = p.schedule.kind !== 'WEEKLY'; $('#edMonth').hidden = p.schedule.kind !== 'MONTHLY'; $('#edMissing').hidden = !(p.schedule.month_day > 28);
      $('#edFinal').innerHTML = '<b>Lista final: ' + r.list.length + ' destinatario(s)</b> (sin duplicados; cada uno recibe su propio correo)<ul id="edFinalList">' + r.list.map(x => '<li>' + esc(x.name) + ' · ' + esc(x.email) + ' <small>(' + esc(x.matched_by.join(', ')) + ')</small></li>').join('') + '</ul>' +
        (r.excluded.length ? '<p class="rp-note">No incluidos: ' + esc(r.excluded.map(x => x.name + ' (' + x.reason + ')').join(', ')) + '</p>' : '');
      $('#edNext').innerHTML = errs.length ? '<p class="msg err">' + esc(errs.join(' ')) + '</p>' : '<b>' + esc(describeSchedule(p.schedule)) + '</b><br>Próximas ejecuciones:<ul id="edNextList">' + nx.map(t => '<li>' + esc(fmtLocal(t)) + '</li>').join('') + '</ul>';
      $('#edSize').textContent = 'Tamaño estimado de cada correo: ' + mb(estimateEmailBytes({ subject: p.subject, html: p.body_html, attachments: (m && m.attachments) || [] })) + ' de 25 MB.'; };
    w.querySelectorAll('input, select').forEach(i => i.addEventListener('change', refresh)); body.addEventListener('input', refresh); refresh();
    w.querySelectorAll('[data-cmd]').forEach(b => b.onclick = () => { body.focus(); if (b.dataset.cmd === 'createLink') { const u = prompt('Dirección del enlace (https://…)'); if (u && /^https?:\/\//i.test(u)) document.execCommand('createLink', false, u); } else document.execCommand(b.dataset.cmd, false, null); });
    body.addEventListener('paste', e => { const h = e.clipboardData && (e.clipboardData.getData('text/html') || esc(e.clipboardData.getData('text/plain')).replace(/\n/g, '<br>')); if (h) { e.preventDefault(); document.execCommand('insertHTML', false, sanitizeHtml(h)); } });
    $('#edBack').onclick = () => { st.edit = null; draw(); };
    $('#edPreview').onclick = () => preview({ ...(m || {}), ...read() });
    const save = async (extra) => { const p = { ...read(), id: m && m.id, ...extra };
      if (!p.internal_name) return say({ err: true, text: 'Indicá el nombre interno.' });
      try { return await api.commsSaveMessage(p, false); }
      catch (e) {
        if (e.code !== 'CONFIRMATION_REQUIRED') { say({ err: true, text: e.message }); return null; }
        // cambio en un comunicado activo/pausado: mostrar QUÉ afecta a los próximos envíos y pedir confirmación
        const r0 = resolveRecipients(cs, m.selection).list, r1 = resolveRecipients(cs, p.selection).list, nx = validateSchedule(p.schedule).length ? [] : nextRuns(p.schedule, Date.now(), 5);
        const add = r1.filter(x => !r0.some(y => y.email === x.email)), rem = r0.filter(x => !r1.some(y => y.email === x.email));
        const ok = await modal(w, 'Confirmar cambios', '<p>Estos cambios afectan los <b>próximos envíos</b>. Lo ya enviado y su historial NO cambian.</p><ul id="impact">' +
          (p.subject !== m.subject || p.body_html !== sanitizeHtml(m.body_html) ? '<li>Cambia el contenido (asunto o texto).</li>' : '') +
          (add.length || rem.length ? '<li>Destinatarios: ' + r0.length + ' → ' + r1.length + (add.length ? ' · se agregan: ' + esc(add.map(x => x.name).join(', ')) : '') + (rem.length ? ' · se quitan: ' + esc(rem.map(x => x.name).join(', ')) : '') + '</li>' : '') +
          (JSON.stringify(p.schedule) !== JSON.stringify(m.schedule) ? '<li>Programación: ' + esc(describeSchedule(p.schedule)) + '</li>' : '') +
          '</ul><p>Próximas ejecuciones:</p><ul>' + nx.map(t => '<li>' + esc(fmtLocal(t)) + '</li>').join('') + '</ul>', { okText: 'CONFIRMAR CAMBIOS', cancelText: 'SEGUIR EDITANDO' });
        if (!ok) return null;
        try { return await api.commsSaveMessage(p, true); } catch (e2) { say({ err: true, text: e2.message }); return null; }
      } };
    $('#edSave').onclick = async () => { const r = await save(); if (r) { st.edit = r.id; st.flash = { text: 'Guardado.' }; draw(); } };   // guardado: ahí sí se redibuja desde lo guardado
    // adjuntos: se actualiza SOLO la lista (lo escrito y la selección sin guardar se conservan)
    const renderAtts = () => { const ul = $('#edAtts'), list = (m && m.attachments) || [];
      ul.innerHTML = list.map(a => '<li data-aid="' + esc(a.id) + '">' + esc(a.file_name || a.name) + ' · ' + esc(mb(a.size_bytes)) + ' <button class="btn soft" type="button" data-adel>QUITAR</button></li>').join('');
      ul.querySelectorAll('[data-adel]').forEach(b => b.onclick = async () => { const aid = b.closest('li').dataset.aid;
        const live = m && ['ACTIVO', 'PAUSADO'].includes(m.status);
        if (live && !(await modal(w, 'Quitar adjunto', '<p>Quitar este adjunto afecta los <b>próximos envíos</b>. Lo ya enviado conserva su copia.</p>', { okText: 'CONFIRMAR', cancelText: 'CANCELAR' }))) return;
        try { await api.commsDetachAttachment(aid, live); m = { ...m, attachments: m.attachments.filter(x => x.id !== aid) }; renderAtts(); say({ text: 'Adjunto quitado (las ejecuciones que ya lo usaron conservan su copia).' }); } catch (x) { say({ err: true, text: x.message }); } });
      refresh(); };
    $('#edFile').onchange = async e => { const f = e.target.files[0]; e.target.value = ''; if (!f) return;
      if (!m || !m.id) { const r = await save(); if (!r) return; m = { ...r, attachments: [] }; st.edit = r.id; }   // un comunicado nuevo se guarda como borrador primero
      const live = ['ACTIVO', 'PAUSADO'].includes(m.status);
      if (live && !(await modal(w, 'Agregar adjunto', '<p>Agregar «' + esc(f.name) + '» afecta los <b>próximos envíos</b>. Lo ya enviado conserva su copia.</p>', { okText: 'CONFIRMAR', cancelText: 'CANCELAR' }))) return;
      try { const a = await api.commsAddAttachment(m.id, f, m.attachments || [], live); m = { ...m, attachments: (m.attachments || []).concat([{ ...a, file_name: a.file_name || a.name }]) }; renderAtts(); say({ text: 'Adjunto agregado: ' + f.name + '.' }); }
      catch (x) { say({ err: true, text: x.message }); } };
    renderAtts();
  }

  const draw = async () => { if (st.tab === 'COLAB') return drawColab(); if (st.tab === 'GMAIL') return drawGmail(); return drawMsgs(); };
  await draw();
}
