// Emails al cliente (Fase 2B.3): "TU PEDIDO VA EN CAMINO" y confirmación de entrega (total o parcial).
// Nunca incluyen DNI, CUIL, GPS, firma ni notas internas. Sin hora estimada exacta.
const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const F = 'font-family:Arial,Helvetica,sans-serif;';
// RC4.1: Recibido Conforme (comprobante de entrega total). Usa la instantánea INMUTABLE del comprobante.
// Diseño transaccional OK Accesorios: tablas + estilos inline (Gmail, Outlook, Apple Mail, móviles), sin CSS externo ni scripts.
// Logo: ícono oficial ya publicado (<APP_URL>/icons/icon-192.png), sin modificar. Si el cliente bloquea imágenes queda el texto "OK ACCESORIOS".
// Privacidad: nunca incluye DNI, CUIL, firma, GPS, foto de DNI ni notas internas.
export const SITE_URL = 'https://www.okaccesorios.com.ar';
export function receiptEmail({ receipt, stop, inlineLogo }) {
  const s = receipt.snapshot || {}, orders = (s.order_numbers || stop.order_numbers || []).filter(Boolean).join(' + ');
  const client = s.client_name || stop.client_name || '';
  const when = s.delivered_at ? new Date(s.delivered_at).toLocaleString('es-AR', { timeZone: 'America/Argentina/Mendoza', day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' }) : '';
  const subject = 'OK Accesorios · Recibido conforme ' + s.receipt_number;
  // Logo horizontal OFICIAL como imagen INLINE (CID): viaja dentro del mismo correo (no depende del sitio publicado ni de APP_URL).
  // Algunos clientes pueden igualmente no mostrar imágenes inline: queda el alt "OK ACCESORIOS". Sin bytes del logo, solo el texto de marca.
  const logo = inlineLogo && inlineLogo.content && inlineLogo.content_id ? 'cid:' + inlineLogo.content_id : '';
  // Proporción exacta del original (1536×201). El logo es azul/naranja sobre transparente: va sobre una placa blanca para que se lea en el fondo azul oscuro (sin cambiar sus colores).
  const LW = 1536, LH = 201;
  // el texto alternativo (imágenes bloqueadas) se escala a la altura de cada logo para que no se corte
  const img = w => { const h = Math.round(w * LH / LW), afs = Math.max(9, Math.min(16, Math.floor(h * 0.5)));
    return '<img src="' + esc(logo) + '" width="' + w + '" height="' + h + '" alt="OK ACCESORIOS" style="display:block;width:' + w + 'px;max-width:100%;height:auto;border:0;outline:none;text-decoration:none;' + F + 'font-size:' + afs + 'px;line-height:' + h + 'px;font-weight:bold;letter-spacing:1px;color:#1e3a8a;">'; };
  const plate = (w, pad) => '<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="max-width:100%;"><tr><td bgcolor="#ffffff" style="background:#ffffff;border-radius:10px;padding:' + pad + ';">' + img(w) + '</td></tr></table>';
  const textBrand = fs => '<div style="' + F + 'font-size:' + fs + 'px;font-weight:bold;letter-spacing:2px;color:#ffffff;">OK <span style="color:#16d6e5;">ACCESORIOS</span></div>';
  const brand = (w, pad, fs) => logo ? plate(w, pad) : textBrand(fs);
  const site = '<a href="' + SITE_URL + '" target="_blank" rel="noopener" style="color:#16d6e5;text-decoration:underline;font-weight:bold;">' + SITE_URL + '</a>';
  const rows = [['Comprobante', s.receipt_number], ['Cliente', client], ['Pedido', orders], ['Recibió', s.receiver_name], ['Fecha y hora', when], ['Estado', 'Recibido conforme']];
  const row = ([k, v], last) => '<tr><td valign="top" style="' + F + 'padding:11px 14px;font-size:13px;color:#667680;width:36%;' + (last ? '' : 'border-bottom:1px solid #e7eef1;') + '">' + esc(k) + '</td>' +
    '<td valign="top" style="' + F + 'padding:11px 14px;font-size:14px;color:#07151b;font-weight:bold;' + (last ? '' : 'border-bottom:1px solid #e7eef1;') + '">' +
    (k === 'Estado' ? '<span style="color:#0d7a54;">&#10004; ' + esc(v) + '</span>' : esc(v || '—')) + '</td></tr>';
  const html = '<!doctype html><html lang="es" xmlns="http://www.w3.org/1999/xhtml"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">' +
    '<meta http-equiv="Content-Type" content="text/html; charset=utf-8"><meta name="x-apple-disable-message-reformatting"><title>' + esc(subject) + '</title></head>' +
    '<body style="margin:0;padding:0;background:#eef2f4;-webkit-text-size-adjust:100%;-ms-text-size-adjust:100%;">' +
    '<div style="display:none;max-height:0;overflow:hidden;opacity:0;color:#eef2f4;">Tu pedido ' + esc(orders) + ' fue entregado correctamente.</div>' +
    '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" bgcolor="#eef2f4" style="background:#eef2f4;"><tr><td align="center" style="padding:20px 10px;">' +
    '<!--[if mso]><table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0"><tr><td><![endif]-->' +
    '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:600px;width:100%;background:#ffffff;border:1px solid #d8e1e5;border-radius:14px;" bgcolor="#ffffff">' +
    // encabezado azul oscuro con logo y título
    '<tr><td bgcolor="#0b1f2e" style="background:#0b1f2e;border-radius:14px 14px 0 0;padding:22px 24px 20px;border-bottom:4px solid #16d6e5;">' + brand(240, '10px 14px', 15) +
    '<div style="' + F + 'font-size:30px;line-height:36px;font-weight:bold;color:#ffffff;margin-top:16px;">Recibido Conforme</div></td></tr>' +
    // saludo
    '<tr><td style="' + F + 'padding:22px 24px 6px;font-size:15px;line-height:23px;color:#07151b;">Hola <b>' + esc(client) + '</b>, registramos correctamente la entrega de tu pedido.</td></tr>' +
    // bloque verde
    '<tr><td style="padding:14px 24px 4px;"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" bgcolor="#e8f7ef" style="background:#e8f7ef;border:1px solid #b7e4cc;border-left:5px solid #0f8a5f;border-radius:10px;">' +
    '<tr><td style="' + F + 'padding:14px 16px;"><div style="font-size:16px;line-height:22px;font-weight:bold;color:#0d7a54;">&#10004; Entrega confirmada</div>' +
    '<div style="font-size:14px;line-height:20px;color:#1f5f45;margin-top:3px;">Tu pedido fue entregado correctamente.</div></td></tr></table></td></tr>' +
    // tarjeta de datos
    '<tr><td style="padding:16px 24px 4px;"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border:1px solid #d9e3e8;border-radius:10px;border-collapse:separate;">' +
    rows.map((r, i) => row(r, i === rows.length - 1)).join('') + '</table></td></tr>' +
    '<tr><td style="' + F + 'padding:14px 24px 24px;font-size:13px;line-height:20px;color:#667680;">Este correo confirma la recepción conforme de la mercadería.</td></tr>' +
    // pie: logo horizontal a la izquierda y sitio a la derecha; en pantallas angostas se apilan (bloques inline-block "fluidos"), Outlook usa dos celdas fijas
    '<tr><td bgcolor="#07151b" style="background:#07151b;border-radius:0 0 14px 14px;padding:14px 18px;font-size:0;line-height:0;" align="left">' +
    '<!--[if mso]><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"><tr><td valign="middle" width="190"><![endif]-->' +
    '<div style="display:inline-block;vertical-align:middle;max-width:190px;width:100%;padding:4px 0;">' + brand(160, '7px 10px', 12) + '</div>' +
    '<!--[if mso]></td><td valign="middle" align="right"><![endif]-->' +
    '<div style="display:inline-block;vertical-align:middle;width:100%;max-width:372px;padding:4px 0;text-align:right;' + F + 'font-size:13px;line-height:18px;">' + site + '</div>' +
    '<!--[if mso]></td></tr></table><![endif]-->' +
    '</td></tr></table><!--[if mso]></td></tr></table><![endif]--></td></tr></table></body></html>';
  const text = 'RECIBIDO CONFORME\n\nHola ' + client + ', registramos correctamente la entrega de tu pedido.\n\nEntrega confirmada: tu pedido fue entregado correctamente.\n\n' +
    rows.map(([k, v]) => k + ': ' + (v || '—')).join('\n') + '\n\nEste correo confirma la recepción conforme de la mercadería.\n\nOK Accesorios · ' + SITE_URL;
  // el logo va como adjunto inline con el MISMO content_id que el src="cid:…" del HTML
  const attachments = logo ? [{ filename: inlineLogo.filename, content: inlineLogo.content, content_type: inlineLogo.content_type, content_id: inlineLogo.content_id }] : undefined;
  return attachments ? { subject, html, text, attachments } : { subject, html, text };
}
export function customerEmail({ kind, stop }) {
  const orders = (stop.order_numbers || []).filter(Boolean).join(' + ');
  const subject = kind === 'ON_THE_WAY' ? 'OK Accesorios · Tu pedido va en camino' : kind === 'PARTIAL' ? 'OK Accesorios · Entregamos parte de tu pedido' : 'OK Accesorios · Tu pedido fue entregado';
  const body = kind === 'ON_THE_WAY' ? 'Tu pedido' + (orders ? ' ' + esc(orders) : '') + ' es la próxima entrega de nuestro reparto. Llegaremos en el transcurso de la jornada.'
    : kind === 'PARTIAL' ? 'Entregamos <b>parte</b> de tu pedido' + (orders ? ' ' + esc(orders) : '') + '. Nos vamos a comunicar para coordinar el resto.'
    : 'Tu pedido' + (orders ? ' ' + esc(orders) : '') + ' fue entregado. ¡Gracias por tu compra!';
  const html = '<!doctype html><html lang="es"><body style="margin:0;background:#eef2f4;"><table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr><td align="center" style="padding:20px 8px;">' +
    '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:600px;background:#fff;border:1px solid #d8e1e5;border-radius:14px;">' +
    '<tr><td style="background:#07151b;border-bottom:4px solid #16d6e5;padding:18px;border-radius:14px 14px 0 0;' + F + 'font-size:20px;font-weight:bold;color:#fff;">OK ACCESORIOS</td></tr>' +
    '<tr><td style="' + F + 'padding:18px;font-size:14px;color:#111;line-height:1.6;">Hola ' + esc(stop.client_name) + ',<br>' + body + '</td></tr></table></td></tr></table></body></html>';
  return { subject, html, text: subject + '\n' + body.replace(/<[^>]+>/g, '') };
}
/** store: { listJobs(q), stopFor(job), updateJob(id, patch) } — idempotente por job; una falla no revierte la entrega */
export async function sendCustomerEmails({ store, provider, onlyIds, inlineLogo }) {
  const out = [];
  for (const j of await store.listJobs({ statuses: ['QUEUED', 'ERROR'], ids: onlyIds })) {
    const stop = await store.stopFor(j);
    let mail;
    try { mail = j.kind === 'RECIBIDO_CONFORME' ? receiptEmail({ receipt: await store.receiptFor(j), stop, inlineLogo }) : customerEmail({ kind: j.kind, stop }); }
    catch (e) { await store.updateJob(j.id, { status: 'ERROR', error: 'COMPROBANTE: ' + String(e.message || e), retry_count: (j.retry_count || 0) + 1 }); out.push({ id: j.id, status: 'ERROR' }); continue; }
    try { const r = await provider.send({ to: j.recipient, idempotencyKey: j.idempotency_key, ...mail }); await store.updateJob(j.id, { status: 'SENT', sent_at: new Date().toISOString(), provider_id: r && r.id, error: null }); out.push({ id: j.id, status: 'SENT' }); }
    catch (e) { await store.updateJob(j.id, { status: 'ERROR', error: String(e.message || e), retry_count: (j.retry_count || 0) + 1 }); out.push({ id: j.id, status: 'ERROR' }); }
  }
  return out;
}