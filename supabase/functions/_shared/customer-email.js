// Emails al cliente (Fase 2B.3): "TU PEDIDO VA EN CAMINO" y confirmación de entrega (total o parcial).
// Nunca incluyen DNI, CUIL, GPS, firma ni notas internas. Sin hora estimada exacta.
const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const F = 'font-family:Arial,Helvetica,sans-serif;';
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
export async function sendCustomerEmails({ store, provider, onlyIds }) {
  const out = [];
  for (const j of await store.listJobs({ statuses: ['QUEUED', 'ERROR'], ids: onlyIds })) {
    const mail = customerEmail({ kind: j.kind, stop: await store.stopFor(j) });
    try { const r = await provider.send({ to: j.recipient, idempotencyKey: j.idempotency_key, ...mail }); await store.updateJob(j.id, { status: 'SENT', sent_at: new Date().toISOString(), provider_id: r && r.id, error: null }); out.push({ id: j.id, status: 'SENT' }); }
    catch (e) { await store.updateJob(j.id, { status: 'ERROR', error: String(e.message || e), retry_count: (j.retry_count || 0) + 1 }); out.push({ id: j.id, status: 'ERROR' }); }
  }
  return out;
}
