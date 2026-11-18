// Panel General · «Correos de autorizaciones comerciales». Estado REAL del proveedor (servidor), destinatarios adicionales y
// historial con estados en español. Sin credenciales ni detalles técnicos sensibles.
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const when = s => s ? new Date(s).toLocaleString('es-AR', { timeZone: 'America/Argentina/Buenos_Aires', day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' }) : '—';
export const MAIL_STATES = {
  PENDING: ['Pendiente de envío', 'pending'], PROCESSING: ['Procesando', 'returned'], SENT: ['Enviado', 'approved'], ERROR: ['Error de envío', 'rejected'],
  HELD: ['Retenido para verificar', 'warning'], SKIPPED: ['Omitido', 'neutral'],
};
export const MAIL_EVENTS = {
  APROBADA: 'Aprobada', APROBADA_CON_MODIFICACIONES: 'Aprobada con cambios', RECHAZADA: 'Rechazada', DEVUELTA_CON_MODIFICACIONES: 'Devuelta',
  RETIRADA_POR_COMERCIAL: 'Cancelada (retirada por el comercial)', CANCELADA: 'Cancelada', CAMBIOS_ACEPTADOS_REENVIADA: 'Cambios aceptados · reenviada',
};
// Errores comprensibles. Lo no listado se muestra genérico (nunca el detalle técnico).
const ERRORS = [
  [/^SMTP_RECIPIENT_5/, 'El servidor de correo rechazó la dirección del destinatario. Revisá que sea correcta.'],
  [/^SMTP_RECIPIENT_4|^SMTP_REJECTED_4/, 'El servidor de correo pidió reintentar más tarde. Se reintenta automáticamente.'],
  [/^SMTP_REJECTED_5/, 'El servidor de correo rechazó el mensaje.'],
  [/RATE_LIMIT|NO_CAPACITY/, 'Esperando cupo disponible de envío (límite por hora o por día). Sale automáticamente.'],
  [/^(SMTP_NOT_ACTIVE|MAIL_CONFIGURATION_CHANGED|SMTP_BUSY|SMTP_STATE_UNAVAILABLE)$/, 'El correo corporativo no estaba disponible en ese momento. Se reintenta automáticamente.'],
  [/^(SMTP_AUTH_REJECTED|SMTP_CREDENTIAL_MISSING|SMTP_CONFIG_INVALID|SMTP_AUTH_UNSUPPORTED)$/, 'La conexión del correo corporativo requiere revisión por Administración. Se reintenta al normalizarse.'],
  [/^(RESULTADO_INCIERTO|SMTP_POR_VERIFICAR|SMTP_ACCEPTANCE_UNKNOWN|MAIL_RESULT_UNRECORDED|WORKER_INTERRUPTED)$/, 'No se pudo confirmar si el servidor lo aceptó. No se reenvía solo para evitar duplicados: verificar antes de reenviar.'],
  [/^COPY_REMOVED$/, 'La dirección dejó de figurar entre las copias antes del envío.'],
  [/^AUTHOR_NO_LONGER_AUTHORIZED$/, 'El usuario solicitante ya no está activo o no tiene permiso.'],
  [/^AUTHOR_WITHOUT_EMAIL$/, 'El usuario solicitante no tiene correo registrado.'],
  [/^(DETALLE_NO_DISPONIBLE|DETALLE_INVALIDO|PAYLOAD_INVALID|EVENT_KIND_UNSUPPORTED)$/, 'No se pudo armar el detalle de la solicitud. Se reintenta automáticamente.'],
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
export function renderMailPanel(s) {
  const t = s && s.transport, st = providerStatus(s);
  const usage = t && t.provider === 'SMTP' ? '<p class="micro" data-mail-usage>Cupo compartido de la app: <b>' + esc(t.hourly_used) + ' / ' + esc(t.hourly_cap ?? '—') + '</b> en la última hora · <b>' + esc(t.daily_used) + ' / ' + esc(t.daily_cap ?? '—') +
    '</b> en las últimas 24 h (el resto del límite diario del proveedor queda reservado para Authentication y el uso directo de la cuenta). Lo que excede el cupo queda pendiente y sale solo.</p>' : '';
  const rows = (s && s.history || []).map(x => { const [lbl, cls] = MAIL_STATES[x.state] || [String(x.state || '—'), 'neutral'];
    return '<tr data-mail-row><td>' + esc(when(x.created_at)) + '</td><td>' + esc(x.request_number) + '</td><td>' + esc(MAIL_EVENTS[x.event_kind] || String(x.event_kind || '').replace(/_/g, ' ')) + '</td><td style="overflow-wrap:anywhere">' + esc(x.recipient || '—') +
      '<small style="display:block" class="micro">' + (x.kind === 'AUTHOR' ? 'Solicitante' : 'Copia adicional') + '</small></td><td><span class="pill ' + cls + '">' + esc(lbl) + '</span></td><td>' + esc(x.attempts ?? 0) + '</td><td>' + esc(x.sent_at ? when(x.sent_at) : '—') + '</td><td class="micro">' + esc(friendlyMailError(x.error_code, x.state, x.attempts)) + '</td></tr>'; }).join('');
  return '<section class="card" id="comMailSettings" style="margin-top:14px"><div class="sectionhead"><h2>Correos de autorizaciones comerciales</h2></div>' +
    '<div class="' + st.cls + '" id="comMailProvider">' + esc(st.text) + '</div>' + usage +
    '<p class="micro">Cada aprobación, aprobación con cambios, rechazo, devolución o cancelación genera un correo para el usuario que cargó la solicitud y para cada dirección adicional configurada acá. Cada destinatario recibe su propio correo: nadie ve las direcciones de los demás. Si el correo del solicitante también figura como copia, recibe uno solo.</p>' +
    '<div class="note warn" id="comMailWarn"><b>Importante:</b> las direcciones adicionales reciben el <b>detalle completo</b> de cada solicitud (cliente, CUIT, pedido, importes, calendario, observaciones y resolución). Agregá solo direcciones <b>autorizadas expresamente</b> por Administración para recibir esta información. Recibir el correo no da acceso a la aplicación.</div>' +
    '<label class="field" style="margin-top:10px"><span>Copias adicionales (separadas por coma o por línea)</span><textarea class="input" rows="3" id="comMailCopies"' + (!s ? ' disabled' : '') + '>' + esc((s && s.copies || []).join(', ')) + '</textarea></label>' +
    '<label class="micro" style="display:block;margin:8px 0"><input type="checkbox" id="comMailAuth"' + (!s ? ' disabled' : '') + '> Confirmo que las direcciones adicionales están autorizadas para recibir el detalle completo de las solicitudes.</label>' +
    '<button class="btn outline" id="comMailSave" type="button"' + (!s ? ' disabled' : '') + '>Guardar correos adicionales</button><p class="micro" id="comMailResult">' + (!s ? 'Configuración de correos todavía no disponible en el servidor.' : 'El solicitante siempre recibe su aviso. Los cambios quedan auditados.') + '</p>' +
    '<h3 style="margin-top:14px">Últimos envíos</h3><p class="micro">«Enviado» significa que el servidor de correo lo ACEPTÓ; no garantiza que haya llegado a la bandeja de entrada ni que se haya leído.</p>' +
    (rows ? '<div class="tablewrap"><table class="tbl" id="comMailHistory"><thead><tr><th>Generado</th><th>Autorización</th><th>Resolución</th><th>Destinatario</th><th>Estado</th><th>Intentos</th><th>Enviado</th><th>Detalle</th></tr></thead><tbody>' + rows + '</tbody></table></div>'
      : '<p class="micro">Sin envíos registrados.</p>') + '</section>';
}
// Normaliza la lista y exige la confirmación cuando hay copias nuevas.
export function mailCopiesToSave(text, previous, confirmed) {
  const list = [...new Set(String(text || '').split(/[,;\n]+/).map(x => x.trim().toLowerCase()).filter(Boolean))];
  const added = list.filter(x => !(previous || []).map(y => String(y).toLowerCase()).includes(x));
  if (added.length && !confirmed) return { error: 'Para agregar direcciones confirmá que están autorizadas a recibir el detalle completo.' };
  return { list };
}
