// Ruta interna dinámica + aprobación (Fase 2B.2). Reglas compartidas por la demo, la pantalla y la Edge Function.
// La base de datos aplica las mismas reglas en SQL (add_internal_stop, reorder_internal_stops, finalize_route, review_route_approval).

export const byOrder = stops => stops.slice().sort((a, b) => (a.sequence_number ?? a.seq) - (b.sequence_number ?? b.seq));
// Parada actual = primera pendiente en el orden vigente; futuras = las pendientes siguientes
export function currentStop(stops) { return byOrder(stops).find(s => s.outcome === 'PENDIENTE') || null; }
export function futureStops(stops) { const cur = currentStop(stops); return byOrder(stops).filter(s => s.outcome === 'PENDIENTE' && (!cur || s.id !== cur.id)); }

// Valida un reordenamiento (mismo criterio que el servidor). Devuelve null o el código de error.
export function reorderError(stops, order) {
  const cur = currentStop(stops), fut = futureStops(stops).map(s => s.id);
  if (!order || (cur && order.includes(cur.id))) return 'CURRENT_STOP_FIXED';
  if (order.some(id => { const s = stops.find(x => x.id === id); return s && s.outcome !== 'PENDIENTE'; })) return 'COMPLETED_STOP_FIXED';
  if (order.length !== fut.length || [...order].sort().join() !== [...fut].sort().join()) return 'BAD_ORDER';
  return null;
}
export function applyReorder(stops, order) {
  const fixed = Math.max(0, ...stops.filter(s => !order.includes(s.id)).map(s => s.sequence_number ?? s.seq));
  order.forEach((id, i) => { stops.find(s => s.id === id).sequence_number = fixed + i + 1; });
}

// Original publicada vs real ejecutada: agregadas, movidas, acción/destino cambiado, bultos, incidencias
export function routeDiff(route) {
  const orig = ((route.sheet_snapshot && route.sheet_snapshot.stops) || []).map((s, i) => ({ seq: i + 1, client_name: s.client_name, address: s.address || '', action: s.action || 'ENTREGA', bultos: s.bultos ?? null }));
  const exec = byOrder(route.stops || []);
  const pubRank = new Map(exec.filter(s => s.provenance !== 'DRIVER').map((s, i) => [s.id, i + 1])); // orden relativo entre las publicadas
  const rows = exec.map((s, i) => {
    const o = orig.find(x => x.seq === s.seq && s.provenance !== 'DRIVER');
    const marks = [];
    if (s.provenance === 'DRIVER') marks.push('PARADA AGREGADA');
    else if (o && o.seq !== pubRank.get(s.id)) marks.push('PARADA MOVIDA (era ' + o.seq + '°, se hizo ' + (i + 1) + '°)');
    if (o && (o.action !== (s.action || 'ENTREGA') || o.address !== (s.address || ''))) marks.push('ACCIÓN/DESTINO CAMBIADO');
    if (o && (o.bultos ?? null) !== (s.bultos ?? null)) marks.push('BULTOS CAMBIADOS');
    if (['NO_ENTREGADO', 'REPROGRAMAR', 'ENTREGA_PARCIAL'].includes(s.outcome)) marks.push('INCIDENCIA: ' + s.outcome.replace('_', ' ') + (s.outcome_reason || s.outcome_note ? ' · ' + (s.outcome_reason || s.outcome_note) : ''));
    return { pos: i + 1, seq: s.seq, client_name: s.client_name, address: s.address || '', action: s.action || 'ENTREGA', bultos: s.bultos ?? null, outcome: s.outcome, provenance: s.provenance || 'PUBLISHED', marks };
  });
  return { original: orig, executed: rows, added: rows.filter(r => r.provenance === 'DRIVER').length, moved: rows.filter(r => r.marks.some(m => m.startsWith('PARADA MOVIDA'))).length,
    incidents: rows.filter(r => r.marks.some(m => m.startsWith('INCIDENCIA'))).length, bultos: rows.reduce((a, r) => a + (r.bultos || 0), 0) };
}

// Destinatarios del aviso de aprobación (sin duplicados, sin hardcodear)
export function approvalRecipients({ driver, users, settings }) {
  const sup = users.find(u => u.id === ((driver && driver.supervisor_user_id) || settings.supervisor_user_id) && u.status === 'ACTIVO');
  const list = [];
  if (sup) list.push(sup.email);
  if (settings.copy_admin !== false) users.filter(u => u.role === 'ADMIN' && u.status === 'ACTIVO').forEach(u => list.push(u.email));
  (settings.extra_emails || []).forEach(e => list.push(e));
  return { supervisor: sup || null, emails: [...new Set(list.filter(Boolean).map(e => String(e).trim().toLowerCase()))] };
}

const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
// Email breve (sin DNI, CUIL, GPS ni firmas)
export function approvalEmail({ route, driverName, appUrl }) {
  const d = routeDiff(route);
  const subject = 'OK Despacho · Hoja ' + route.number + ' pendiente de aprobación';
  const F = 'font-family:Arial,Helvetica,sans-serif;';
  const li = d.executed.map(r => '<tr><td style="' + F + 'font-size:12px;padding:6px 8px;border-bottom:1px solid #edf1f3;">' + r.pos + '. ' + esc(r.client_name) + ' · ' + esc(r.action) + (r.bultos ? ' · ' + r.bultos + ' bultos' : '') + '</td><td style="' + F + 'font-size:11px;padding:6px 8px;border-bottom:1px solid #edf1f3;color:#9b6900;">' + esc(r.marks.join(' · ')) + '</td></tr>').join('');
  const html = '<!doctype html><html lang="es"><body style="margin:0;background:#eef2f4;"><table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr><td align="center" style="padding:20px 8px;">' +
    '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:640px;background:#fff;border:1px solid #d8e1e5;border-radius:14px;">' +
    '<tr><td style="background:#07151b;border-bottom:4px solid #16d6e5;padding:18px;border-radius:14px 14px 0 0;"><div style="' + F + 'font-size:11px;font-weight:bold;letter-spacing:2px;color:#16d6e5;">OK ACCESORIOS · RUTA INTERNA</div><div style="' + F + 'font-size:20px;font-weight:bold;color:#fff;margin-top:4px;">Hoja ' + esc(route.number) + ' pendiente de aprobación</div></td></tr>' +
    '<tr><td style="' + F + 'padding:16px 18px;font-size:13px;color:#111;line-height:1.6;">Chofer: <b>' + esc(driverName) + '</b><br>Fecha: ' + esc(new Date(route.completed_at || Date.now()).toLocaleDateString('es-AR')) +
    '<br>Paradas originales: <b>' + d.original.length + '</b> · Ejecutadas: <b>' + d.executed.length + '</b><br>Agregadas: <b>' + d.added + '</b> · Reordenamientos: <b>' + d.moved + '</b> · Incidencias: <b>' + d.incidents + '</b> · Bultos: <b>' + d.bultos + '</b></td></tr>' +
    '<tr><td style="padding:0 18px;"><table role="presentation" width="100%" cellpadding="0" cellspacing="0">' + li + '</table></td></tr>' +
    '<tr><td style="padding:18px;"><a href="' + esc((appUrl || '') + '/#/aprobaciones/' + route.id) + '" style="' + F + 'display:inline-block;background:#16d6e5;color:#07151b;font-weight:bold;text-decoration:none;padding:12px 18px;border-radius:10px;">REVISAR CAMBIOS</a></td></tr>' +
    '</table></td></tr></table></body></html>';
  const text = [subject, 'Chofer: ' + driverName, 'Paradas originales: ' + d.original.length + ' · Ejecutadas: ' + d.executed.length, 'Agregadas: ' + d.added + ' · Reordenamientos: ' + d.moved + ' · Incidencias: ' + d.incidents + ' · Bultos: ' + d.bultos,
    ...d.executed.map(r => r.pos + '. ' + r.client_name + (r.marks.length ? ' — ' + r.marks.join(' · ') : '')), 'REVISAR CAMBIOS: ' + (appUrl || '') + '/#/aprobaciones/' + route.id].join('\n');
  return { subject, html, text };
}
export function observedEmail({ route, note }) {
  return { subject: 'OK Despacho · Hoja ' + route.number + ' · aclaración solicitada', html: '<p style="font-family:Arial,sans-serif">Se solicitó una aclaración sobre la hoja <b>' + esc(route.number) + '</b>: ' + esc(note) + '</p>', text: 'Aclaración solicitada sobre la hoja ' + route.number + ': ' + note };
}

/**
 * Envío de emails en cola (idempotente por job). Una falla NO revierte la hoja: el job queda en ERROR y se reintenta.
 * store: { listJobs(filter) → jobs, routeFor(job) → route con stops, driverName(route), updateJob(id, patch) }
 */
export async function sendQueuedEmails({ store, provider, appUrl, onlyIds }) {
  const out = [];
  for (const j of await store.listJobs({ statuses: ['QUEUED', 'ERROR'], ids: onlyIds })) {
    const route = await store.routeFor(j);
    const mail = j.kind === 'INTERNAL_ROUTE_OBSERVED' ? observedEmail({ route, note: route.review_note || '' }) : approvalEmail({ route, driverName: await store.driverName(route), appUrl });
    try {
      const r = await provider.send({ to: j.recipient, idempotencyKey: j.idempotency_key, ...mail });
      await store.updateJob(j.id, { status: 'SENT', sent_at: new Date().toISOString(), provider_id: r && r.id, error: null });
      out.push({ id: j.id, status: 'SENT' });
    } catch (e) {
      await store.updateJob(j.id, { status: 'ERROR', error: String(e.message || e), retry_count: (j.retry_count || 0) + 1 });
      out.push({ id: j.id, status: 'ERROR', error: String(e.message || e) });
    }
  }
  return out;
}
