// Autorizaciones → Panel General · «Correos de autorizaciones comerciales». Estado REAL del proveedor (servidor), copias adicionales
// con autorización/ratificación validada en el SERVIDOR, historial con participación y estados en español. Sin credenciales.
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const when = s => s ? new Date(s).toLocaleString('es-AR', { timeZone: 'America/Argentina/Buenos_Aires', day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' }) : '—';
export const AUTH_SCOPE = 'DETALLE_COMERCIAL_COMPLETO_CC_VISIBLE';
export const MAIL_STATES = {
  PENDING: ['Pendiente de envío', 'pending'], PROCESSING: ['Procesando', 'returned'], SENT: ['Enviado', 'approved'], ERROR: ['Error de envío', 'rejected'],
  HELD: ['Retenido para verificar', 'warning'], SKIPPED: ['Omitido', 'neutral'],
};
export const MAIL_EVENTS = {
  ENVIADA: 'Nueva solicitud', APROBADA: 'Aprobada', APROBADA_CON_MODIFICACIONES: 'Aprobada con cambios', RECHAZADA: 'Rechazada', DEVUELTA_CON_MODIFICACIONES: 'Devuelta',
  RETIRADA_POR_COMERCIAL: 'Cancelada (retirada por el comercial)', CANCELADA: 'Cancelada', CAMBIOS_ACEPTADOS_REENVIADA: 'Cambios aceptados · reenviada',
};
export const PARTICIPATION = { AUTHOR: 'SOLICITANTE', APPROVER: 'APROBADOR', COPY: 'COPIA ADICIONAL' };
export const COPY_STATUS = { AUTORIZADA: ['Autorizada', 'approved'], PENDIENTE_RATIFICACION: ['Pendiente de ratificación', 'pending'], REVOCADA: ['Revocada', 'neutral'] };
const ERRORS = [
  [/^SMTP_RECIPIENT_5/, 'El servidor de correo rechazó la dirección del destinatario. Revisá que sea correcta.'],
  [/^SMTP_RECIPIENT_4|^SMTP_REJECTED_4/, 'El servidor de correo pidió reintentar más tarde. Se reintenta automáticamente.'],
  [/^SMTP_REJECTED_5|^SMTP_PREVIOUSLY_REJECTED$/, 'El servidor de correo rechazó el mensaje para este destinatario.'],
  [/RATE_LIMIT|NO_CAPACITY/, 'Esperando cupo disponible de envío (límite por hora o por día). Sale automáticamente.'],
  [/^(SMTP_NOT_ACTIVE|MAIL_CONFIGURATION_CHANGED|SMTP_BUSY|SMTP_STATE_UNAVAILABLE)$/, 'El correo corporativo no estaba disponible en ese momento. Se reintenta automáticamente.'],
  [/^(SMTP_AUTH_REJECTED|SMTP_CREDENTIAL_MISSING|SMTP_CONFIG_INVALID|SMTP_AUTH_UNSUPPORTED)$/, 'La conexión del correo corporativo requiere revisión por Administración. Se reintenta al normalizarse.'],
  [/^(RESULTADO_INCIERTO|SMTP_POR_VERIFICAR|SMTP_ACCEPTANCE_UNKNOWN|MAIL_RESULT_UNRECORDED|WORKER_INTERRUPTED|CONCILIADO_REVERSION_INCIERTO)$/, 'No se pudo confirmar si el servidor lo aceptó. No se reenvía solo para evitar duplicados: verificar antes de reenviar.'],
  [/^CONCILIADO_REVERSION$/, 'El servidor ya lo había aceptado: se registró sin reenviar.'],
  [/^VERSION_REVERTIDA$/, 'No se envió porque la versión de correos se revirtió antes del envío.'],
  [/^COPY_NOT_RATIFIED$/, 'Copia adicional pendiente de ratificación: no recibe el detalle hasta que Administración la autorice.'],
  [/^COPY_NOT_IN_DISTRIBUTION$/, 'La dirección no estaba autorizada cuando se registró el evento: no recibe ese aviso.'],
  [/^COPY_REMOVED$/, 'La dirección fue revocada o quitada de las copias antes del envío.'],
  [/^AUTHOR_NO_LONGER_AUTHORIZED$/, 'El usuario solicitante ya no está activo o no tiene permiso.'],
  [/^APPROVER_NO_LONGER_AUTHORIZED$/, 'El aprobador ya no está activo o no tiene permiso de aprobación.'],
  [/^AUTHOR_WITHOUT_EMAIL$/, 'El usuario solicitante no tiene correo registrado.'],
  [/^APPROVER_WITHOUT_EMAIL$/, 'El aprobador asignado no tiene correo registrado.'],
  [/^RECIPIENT_NOT_IN_DISTRIBUTION$/, 'El destinatario no figura en la lista registrada del aviso: no se envía.'],
  [/^SNAPSHOT_MISSING$/, 'Retenido: no existe la foto del evento. No se envía para no informar datos que no se pueden garantizar. Requiere revisión administrativa (ver Incidencias).'],
  [/^(SNAPSHOT_INCONSISTENT|DETALLE_INVALIDO|PAYLOAD_INVALID|EVENT_KIND_UNSUPPORTED)$/, 'Retenido: la foto del evento no coincide con el registro. No se envía. Requiere revisión administrativa (ver Incidencias).'],
  [/^DETALLE_NO_DISPONIBLE$/, 'No se pudo armar el detalle de la solicitud.'],
  [/^LIBERADO_REVISION$/, 'Liberado por revisión administrativa: se envía con los datos registrados.'],
  [/^DESCARTADO_REVISION$/, 'Descartado en la revisión administrativa: no se envió.'],
  [/^DISTRIBUTION_CHANGED$/, 'Cambió la lista de destinatarios justo antes del envío (por ejemplo, una revocación): se vuelve a armar sin la dirección revocada.'],
  [/^SMTP_(CONNECTION_FAILED|TIMEOUT|TLS_FAILED|STARTTLS|GREETING|EHLO)/, 'No se pudo conectar con el servidor de correo. Se reintenta automáticamente.'],
];
export function friendlyMailError(code, state, attempts) {
  if (!code) return state === 'ERROR' && attempts >= 4 ? 'Sin más reintentos automáticos.' : '';
  const hit = ERRORS.find(([re]) => re.test(String(code)));
  const msg = hit ? hit[1] : 'Error de envío. Si persiste, consultá a Administración.';
  return state === 'ERROR' && attempts >= 4 ? msg.replace(/ Se reintenta automáticamente\.?$/, '') + ' Sin más reintentos automáticos.' : msg;
}
export function providerStatus(s) {
  const t = s && s.transport;
  if (s && s.simulated) return { cls: 'note', text: 'Modo demostración: no se envían correos.' };
  if (!t) return { cls: 'note warn', text: 'No se pudo consultar el estado del correo corporativo.' };
  if (t.provider === 'SMTP' && t.connected) return { cls: 'note good', text: 'Correo corporativo ACTIVO · remitente ' + (t.sender || '—') + '. Los avisos se envían automáticamente.' };
  if (t.provider === 'SMTP') return { cls: 'note warn', text: 'Correo corporativo configurado pero la conexión requiere revisión: los avisos quedan pendientes hasta normalizarse.' };
  return { cls: 'note warn', text: 'El correo corporativo no está activo: los avisos quedan pendientes hasta su activación.' };
}
export const INCIDENT_CODES = { SNAPSHOT_MISSING: 'Falta la foto del evento', SNAPSHOT_INCONSISTENT: 'La foto no coincide con el registro', DETALLE_INVALIDO: 'La plantilla rechazó la foto' };
export const INCIDENT_STATUS = { ABIERTA: ['Abierta · aviso retenido', 'rejected'], RESUELTA_ENVIO: ['Resuelta · enviada con datos registrados', 'approved'], RESUELTA_DESCARTE: ['Resuelta · descartada', 'neutral'] };
export function parseAddresses(text) { return [...new Set(String(text || '').split(/[,;\s]+/).map(x => x.trim().toLowerCase()).filter(Boolean))]; }

export function renderMailPanel(s) {
  const t = s && s.transport, st = providerStatus(s), recips = (s && s.recipients) || [], pend = recips.filter(r => r.status === 'PENDIENTE_RATIFICACION').length;
  const usage = t && t.provider === 'SMTP' ? '<p class="micro" data-mail-usage>Cupo de envíos automáticos de la app: <b>' + esc(t.hourly_used) + ' / ' + esc(t.hourly_cap ?? '—') + '</b> en la última hora · <b>' + esc(t.daily_used) + ' / ' + esc(t.daily_cap ?? '—') +
    '</b> en las últimas 24 h' + (t.daily_cap_confirmed ? ' (tope confirmado por Administración)' : ' (<b>tope propuesto, pendiente de confirmación administrativa</b>)') + '. Cada destinatario cuenta como un envío. Lo que excede el cupo queda pendiente y sale solo. La reserva para Authentication y el uso manual de la cuenta es una estimación: no garantiza por sí sola el límite global del proveedor.</p>' : '';
  const recRows = recips.map(r => { const [lbl, cls] = COPY_STATUS[r.status] || [r.status, 'neutral'];
    return '<tr data-copy-row><td><input type="checkbox" data-copy="' + esc(r.address) + '"' + (r.status === 'REVOCADA' ? ' data-revoked="1"' : '') + '></td><td style="overflow-wrap:anywhere">' + esc(r.address) + '</td><td><span class="pill ' + cls + '">' + esc(lbl) + '</span></td><td class="micro">' +
      (r.status === 'AUTORIZADA' ? esc((r.authorized_by || '—') + ' · ' + when(r.authorized_at)) + '<br>Detalle completo y copia visible (CC)' : r.status === 'REVOCADA' ? esc('Revocada por ' + (r.revoked_by || 'sincronización') + ' · ' + when(r.revoked_at)) : 'No recibe detalle hasta ratificarse') + '</td></tr>'; }).join('');
  const hist = (s && s.history || []).map(x => { const [lbl, cls] = MAIL_STATES[x.state] || [String(x.state || '—'), 'neutral'];
    return '<tr data-mail-row><td>' + esc(when(x.created_at)) + '</td><td>' + esc(x.request_number) + '</td><td>' + esc(MAIL_EVENTS[x.event_kind] || String(x.event_kind || '').replace(/_/g, ' ')) + '</td><td style="overflow-wrap:anywhere">' + esc(x.recipient || '—') +
      '<small style="display:block" class="micro">' + esc(PARTICIPATION[x.kind] || x.kind) + '</small></td><td><span class="pill ' + cls + '">' + esc(lbl) + '</span></td><td>' + esc(x.attempts ?? 0) + '</td><td>' + esc(x.sent_at ? when(x.sent_at) : '—') + '</td><td class="micro">' + esc(friendlyMailError(x.error_code, x.state, x.attempts)) + '</td></tr>'; }).join('');
  const log = (s && s.authorization_log || []).slice(0, 10).map(l => '<li>' + esc(when(l.at) + ' · ' + l.address + ' · ' + String(l.action).replace(/_/g, ' ').toLowerCase() + ' · ' + (l.actor || 'sistema')) + '</li>').join('');
  const dis = !s ? ' disabled' : '';
  return '<section class="card" id="comMailSettings" style="margin-top:14px"><div class="sectionhead"><h2>Correos de autorizaciones comerciales</h2></div>' +
    '<div class="' + st.cls + '" id="comMailProvider">' + esc(st.text) + '</div>' + usage +
    '<p class="micro">Cada nueva solicitud, aprobación, aprobación con cambios, rechazo, devolución o cancelación genera <b>un correo con los destinatarios visibles</b>: en <b>Para</b> el aprobador asignado (en nuevas solicitudes y reenvíos) y el solicitante; en <b>CC</b> las copias adicionales <b>autorizadas</b>. No se usa copia oculta: todos ven quiénes fueron notificados y pueden «Responder a todos». Una dirección repetida recibe un solo correo.</p>' +
    '<div class="note warn" id="comMailWarn"><b>Importante:</b> las copias adicionales reciben el <b>detalle comercial completo</b> (cliente, CUIT, pedido, importes, calendario, observaciones y resolución) y su dirección queda <b>visible para todos</b> los destinatarios. Autorizá solo direcciones aprobadas expresamente por Administración. La autorización queda registrada con tu usuario, la fecha y el alcance. Recibir el correo no da acceso a la aplicación.</div>' +
    (pend ? '<div class="note warn" id="comMailPend" style="margin-top:8px"><b>' + pend + ' dirección(es) pendiente(s) de ratificación.</b> No reciben el nuevo detalle hasta que las ratifiques. El solicitante y el aprobador reciben sus avisos igual.</div>' : '') +
    '<h3 style="margin-top:14px">Copias adicionales</h3>' +
    (recRows ? '<div class="tablewrap"><table class="tbl" id="comMailRecipients"><thead><tr><th><input type="checkbox" id="comMailAll" aria-label="Seleccionar todas"></th><th>Dirección</th><th>Estado</th><th>Autorización</th></tr></thead><tbody>' + recRows + '</tbody></table></div>' : '<p class="micro">Sin copias adicionales configuradas.</p>') +
    '<label class="field" style="margin-top:10px"><span>Agregar direcciones (separadas por coma o por línea)</span><textarea class="input" rows="2" id="comMailNew"' + dis + '></textarea></label>' +
    '<label class="micro" style="display:block;margin:8px 0"><input type="checkbox" id="comMailAuth"' + dis + '> Confirmo que Administración autorizó expresamente estas direcciones a recibir el detalle comercial completo y a figurar en copia visible (CC).</label>' +
    '<div class="row" style="gap:8px"><button class="btn primary" id="comMailAuthorize" type="button"' + dis + '>Autorizar / ratificar seleccionadas y nuevas</button><button class="btn outline" id="comMailRevoke" type="button"' + dis + '>Revocar seleccionadas</button></div>' +
    '<p class="micro" id="comMailResult">' + (!s ? 'Configuración de correos todavía no disponible en el servidor.' : 'El servidor valida la confirmación y registra cada autorización, ratificación y revocación.') + '</p>' +
    (log ? '<details><summary class="micro">Registro de autorizaciones</summary><ul class="micro" id="comMailLog">' + log + '</ul></details>' : '') +
    incidentsHtml(s) +
    '<h3 style="margin-top:14px">Últimos envíos</h3><p class="micro">«Enviado» significa que el servidor de correo lo ACEPTÓ para ese destinatario; no garantiza que haya llegado a la bandeja de entrada ni que se haya leído.</p>' +
    (hist ? '<div class="tablewrap"><table class="tbl" id="comMailHistory"><thead><tr><th>Generado</th><th>Autorización</th><th>Evento</th><th>Destinatario</th><th>Estado</th><th>Intentos</th><th>Enviado</th><th>Detalle</th></tr></thead><tbody>' + hist + '</tbody></table></div>'
      : '<p class="micro">Sin envíos registrados.</p>') + '</section>';
}
function incidentsHtml(s) {
  const list = (s && s.incidents) || []; if (!list.length) return '';
  const open = list.filter(i => i.status === 'ABIERTA').length;
  return '<h3 style="margin-top:14px">Incidencias de integridad</h3>' +
    (open ? '<div class="note warn" id="comMailIncOpen"><b>' + open + ' incidencia(s) abierta(s):</b> los avisos de esos eventos están RETENIDOS y no se envían hasta tu revisión. Nunca se reconstruyen con el estado actual de la solicitud.</div>' : '') +
    '<div class="tablewrap"><table class="tbl" id="comMailIncidents"><thead><tr><th>Detectada</th><th>Autorización</th><th>Evento</th><th>Causa</th><th>Estado</th><th>Revisión</th></tr></thead><tbody>' +
    list.map(i => { const [lbl, cls] = INCIDENT_STATUS[i.status] || [i.status, 'neutral'];
      return '<tr data-inc-row="' + esc(i.id) + '"><td>' + esc(when(i.at)) + '</td><td>' + esc(i.request_number) + '</td><td>' + esc(MAIL_EVENTS[i.event_kind] || i.event_kind || '—') + '</td><td class="micro">' + esc(INCIDENT_CODES[i.code] || i.code) +
        (i.detail ? '<br>' + esc(i.detail) : '') + (i.held_rows ? '<br><b>' + esc(i.held_rows) + ' aviso(s) retenido(s)</b>' : '') + '</td><td><span class="pill ' + cls + '">' + esc(lbl) + '</span></td><td class="micro">' +
        (i.status === 'ABIERTA'
          ? '<input class="input" data-inc-note="' + esc(i.id) + '" placeholder="Nota de la revisión (obligatoria)" maxlength="300" style="min-width:180px"><label style="display:block;margin:6px 0"><input type="checkbox" data-inc-ok="' + esc(i.id) + '"> Revisé el caso</label>' +
            (i.can_send ? '<button class="btn outline" type="button" data-inc-send="' + esc(i.id) + '" title="Arma el aviso con los datos INMUTABLES del evento y los nombres vigentes hoy; el correo lo aclara">Enviar con datos registrados</button> ' : '') +
            '<button class="btn outline" type="button" data-inc-discard="' + esc(i.id) + '">Descartar (no enviar)</button>'
          : esc((i.resolved_by || '—') + ' · ' + when(i.resolved_at)) + (i.resolution_note ? '<br>' + esc(i.resolution_note) : '')) + '</td></tr>'; }).join('') + '</tbody></table></div>';
}
// Acciones del panel. La confirmación también la exige el SERVIDOR (alcance + confirmación); acá solo se evita el viaje inútil.
export function wireMailPanel(root, api, onDone) {
  const $ = s => root.querySelector(s), out = m => { const r = $('#comMailResult'); if (r) r.textContent = m; };
  const selected = (activeOnly) => [...root.querySelectorAll('[data-copy]:checked')].filter(x => !activeOnly || !x.dataset.revoked).map(x => x.dataset.copy);
  const all = $('#comMailAll'); if (all) all.onchange = () => root.querySelectorAll('[data-copy]').forEach(x => { x.checked = all.checked; });
  const a = $('#comMailAuthorize'); if (a) a.onclick = async () => {
    const list = [...new Set([...selected(false), ...parseAddresses($('#comMailNew').value)])];
    if (!list.length) return out('Seleccioná o escribí al menos una dirección.');
    if (!$('#comMailAuth').checked) return out('Para autorizar tenés que confirmar que Administración aprobó estas direcciones.');
    a.disabled = true;
    try { await api.comMailCopyAuthorize(list, AUTH_SCOPE, true); out('Direcciones autorizadas (registrado).'); onDone && onDone(); }
    catch (e) { out(String(e.message || e).includes('INVALID_EMAIL') ? 'Revisá las direcciones: hay un correo inválido o más de 20.' : String(e.message || e).replace(/^[A-Z_]+:\s*/, '')); }
    finally { a.disabled = false; }
  };
  root.querySelectorAll('[data-inc-send],[data-inc-discard]').forEach(b => b.onclick = async () => {
    const id = b.dataset.incSend || b.dataset.incDiscard, action = b.dataset.incSend ? 'ENVIAR_CON_DATOS_REGISTRADOS' : 'DESCARTAR';
    const note = (root.querySelector('[data-inc-note="' + id + '"]') || {}).value || '', okBox = root.querySelector('[data-inc-ok="' + id + '"]');
    if (!okBox || !okBox.checked || String(note).trim().length < 5) return out('Para resolver una incidencia confirmá la revisión y escribí una nota (mínimo 5 caracteres).');
    b.disabled = true;
    try { await api.comMailIncidentResolve(Number(id), action, true, String(note).trim()); out(action === 'DESCARTAR' ? 'Incidencia resuelta: avisos descartados (registrado).' : 'Incidencia resuelta: los avisos se envían con los datos registrados (registrado).'); onDone && onDone(); }
    catch (e) { out(String(e.message || e).replace(/^[A-Z_]+:\s*/, '')); } finally { b.disabled = false; }
  });
  const r = $('#comMailRevoke'); if (r) r.onclick = async () => {
    const list = selected(true); if (!list.length) return out('Seleccioná las direcciones a revocar.');
    r.disabled = true;
    try { await api.comMailCopyRevoke(list); out('Direcciones revocadas: dejan de recibir desde ahora (registrado).'); onDone && onDone(); }
    catch (e) { out(String(e.message || e).replace(/^[A-Z_]+:\s*/, '')); } finally { r.disabled = false; }
  };
}
