// =====================================================================================================================
// COMUNICACIONES · despachador (lo ejecuta el programador del servidor cada pocos minutos; también la demo con un proveedor simulado).
// 'store' y 'provider' se inyectan: en producción, RPC de Postgres + Gmail API; en pruebas/demo, memoria + Gmail simulado.
//  1) Crea las ejecuciones vencidas (solo con Gmail conectado). Cada ejecución guarda la COPIA de destinatarios activos, contenido y
//     adjuntos. Una ejecución vencida hace más de 'graceMinutes' (servidor caído, Gmail desconectado) queda PERDIDA para revisión.
//  2) Reserva atómica de envíos (clave única ejecución + destinatario) con tope diario de seguridad.
//  3) Por envío: verificación de cancelación/pausa → adjuntos de la copia (huella verificada) → NUEVA verificación justo antes de
//     enviar → envío → registro. AUTH corta la tanda (hay que reconectar). Respuesta perdida → POR_VERIFICAR, nunca se reenvía sola.
// =====================================================================================================================
import { occurrencesBetween, resolveRecipients, buildMime, base64url, classifyGmailError, sniffType, ATTACH } from '../_shared/comms-core.js';

// Cuota de Gmail API (https://developers.google.com/workspace/gmail/api/reference/quota): messages.send = 100 unidades. Proyectos creados desde
// el 1/5/2026: 6.000 unidades por minuto por usuario → 60 envíos/min. Se aplica además una ventana de 1 s (200 unidades) que respeta también
// el criterio anterior por segundo. El control es COMPARTIDO (store.acquireRate, en la base): vale para todos los trabajadores y las pruebas.
export const DISPATCH_DEFAULTS = { graceMinutes: 30, limit: 25, dailyCap: 400, pauseMs: 0, sendWindowHours: 6, persistRetries: [500, 2000, 5000],
  sendUnits: 100, unitsPerMinute: 6000, unitsPerSecond: 200, maxRateWaitMs: 90e3 };

// Gmail YA aceptó el correo: se reintenta SOLO registrar el resultado (nunca enviar de nuevo). Si no se logra, el envío queda
// reservado (PROCESANDO) y a los 10 min pasa a "Por verificar"; el id de Gmail queda en el resumen de la ejecución.
async function persistAccepted(store, d, gmailId, now, o, sleep) {
  for (let i = 0; i <= o.persistRetries.length; i++) {
    try { await store.finish(d.id, d.token, { outcome: 'ACCEPTED', gmail_id: gmailId }, now); return true; }
    catch (e) { if (i < o.persistRetries.length) await sleep(o.persistRetries[i]); }
  }
  return false;
}
async function persistOther(store, d, r, now, o, sleep) {
  for (let i = 0; i <= o.persistRetries.length; i++) {
    try { await store.finish(d.id, d.token, r, now); return true; } catch (e) { if (i < o.persistRetries.length) await sleep(o.persistRetries[i]); }
  }
  return false;   // queda PROCESANDO → a los 10 min "Por verificar" (sin reenvío automático)
}

async function sha256Hex(bytes) {
  const d = await crypto.subtle.digest('SHA-256', bytes);
  return [...new Uint8Array(d)].map(b => b.toString(16).padStart(2, '0')).join('');
}

// Crea las ejecuciones que vencieron desde el último cursor de cada comunicado activo
export async function enqueueDue(store, now, opt = {}) {
  const grace = (opt.graceMinutes ?? DISPATCH_DEFAULTS.graceMinutes) * 60e3, created = [], missed = [];
  const [messages, collaborators] = await Promise.all([store.listActiveMessages(), store.listCollaborators()]);
  for (const m of messages) {
    // desde el último cursor, pero nunca antes de la activación/reanudación (reanudar NO dispara lo vencido durante la pausa)
    const from = Math.max(Date.parse(m.cursor || 0) || 0, Date.parse(m.active_since || 0) || 0);
    const occ = occurrencesBetween(m.schedule, from, now, 200);
    for (const t of occ) {
      const isMissed = now - t > grace;
      const r = isMissed ? { list: [], excluded: [] } : resolveRecipients(collaborators, m.selection);   // destinatarios activos de ESE momento
      const id = await store.createRun({ message_id: m.id, scheduled_for: new Date(t).toISOString(), kind: 'PROGRAMADO', missed: isMissed,
        recipients: r.list, skipped: r.excluded,
        snapshot: { subject: m.subject, body_html: m.body_html, attachments: m.attachments || [], message_version: m.version, from_name: m.from_name || null } });
      if (id) (isMissed ? missed : created).push({ message_id: m.id, run_id: id, scheduled_for: new Date(t).toISOString(), recipients: r.list.length });
    }
    await store.advanceCursor(m.id, m.cursor || null, new Date(now).toISOString());
  }
  return { created, missed };
}

export async function dispatch(store, provider, opt = {}) {
  const o = { ...DISPATCH_DEFAULTS, ...opt }, now = o.now ?? Date.now(), worker = o.worker || 'w-' + Math.random().toString(36).slice(2, 8);
  const sleep = o.sleep || (ms => new Promise(r => setTimeout(r, ms)));
  const sum = { worker, at: new Date(now).toISOString(), created: 0, missed: 0, claimed: 0, sent: 0, retry: 0, failed: 0, verify: 0, skipped: 0, auth: false, status: 'OK', note: '', unrecorded: [] };
  try {
    const st = await store.gmailStatus();
    if (!st || !st.connected || st.needs_reconnect) {
      sum.status = 'SIN_CONEXION'; sum.note = st && st.needs_reconnect ? 'Hay que reconectar Gmail.' : 'Gmail no está conectado.';
      return await store.recordDispatch(sum), sum;   // no se crean ejecuciones: al volver, lo vencido de más de 'grace' queda PERDIDO
    }
    const q = await enqueueDue(store, now, o); sum.created = q.created.length; sum.missed = q.missed.length;
    // el CUPO diario se reserva dentro de la misma reserva atómica del servidor (cuenta enviados, en curso e inciertos de 24 h)
    const batch = await store.claim(o.limit, worker, now, { dailyCap: o.dailyCap, windowHours: o.sendWindowHours }); sum.claimed = batch.length;
    if (!batch.length && (await store.sentLast24h(now)) >= o.dailyCap) { sum.status = 'LIMITE_DIARIO'; sum.note = 'Se alcanzó el tope diario de seguridad del módulo (' + o.dailyCap + '). Se continúa cuando se libere cupo.'; }
    for (let i = 0; i < batch.length; i++) {
      const d = batch[i];
      if ((await store.check(d.id, d.token, now)) !== 'OK') { sum.skipped++; continue; }   // cancelado / pausado / destinatario inactivo / perdido
      let raw;
      try {
        const atts = [];
        for (const a of d.snapshot.attachments || []) {
          const bytes = await store.fetchAttachment(a);
          if (a.sha256 && (await sha256Hex(bytes)) !== a.sha256) throw Object.assign(new Error('El adjunto ' + a.name + ' no coincide con la copia guardada.'), { code: 'ATTACHMENT_CHANGED' });
          // el CONTENIDO real debe ser del formato permitido declarado (no se confía en metadatos ni en un hash "coincidente")
          const real = sniffType(bytes);
          if (!real || real !== a.mime || !ATTACH.types[real]) throw Object.assign(new Error('El adjunto ' + a.name + ' no es un ' + (ATTACH.types[a.mime] || a.mime) + ' válido: no se envía.'), { code: 'ATTACHMENT_INVALID' });
          if (bytes.length > ATTACH.maxFileBytes) throw Object.assign(new Error('El adjunto ' + a.name + ' supera el tamaño permitido.'), { code: 'ATTACHMENT_TOO_BIG' });
          atts.push({ name: a.name, mime: a.mime, bytes });
        }
        raw = buildMime({ from: st.email, fromName: d.snapshot.from_name || o.fromName || 'OK Accesorios', to: d.email, toName: d.name, subject: d.snapshot.subject, html: d.snapshot.body_html, attachments: atts });
      } catch (e) { await persistOther(store, d, { outcome: 'PERMANENT', error_code: e.code || 'BUILD', error: e.message }, now, o, sleep); sum.failed++; continue; }
      // verificación JUSTO ANTES de enviar: una cancelación o pausa durante la preparación no llega a Gmail
      if ((await store.check(d.id, d.token, now)) !== 'OK') { sum.skipped++; continue; }
      // 1) ENVÍO. Antes de CADA llamada real a Gmail (también la segunda tras un 401), en este orden:
      //    a) TOKEN (obtener o renovar; puede tardar)  →  b) CUPO de velocidad compartido (puede esperar; se reserva DESPUÉS del token,
      //    para que la reserva represente el momento real del envío)  →  c) si la espera dejó el token por vencer: se DEVUELVE el cupo y se
      //    vuelve a empezar  →  d) VERIFICACIÓN FINAL (cancelación, pausa, conexión, destinatario)  →  llamada, sin más esperas en el medio.
      const gate = async forceToken => {
        let force = forceToken, rounds = 0;
        for (;;) {
          let token = null;
          if (provider.prepare) token = await provider.prepare(force);   // a) token primero (sin cupo reservado todavía)
          force = false;
          let waited = 0, lease = null;
          for (;;) {   // b) cupo compartido
            const a = store.acquireRate ? await store.acquireRate(o.sendUnits, o.unitsPerMinute, o.unitsPerSecond) : { wait_ms: 0 };
            const w = typeof a === 'number' ? a : a.wait_ms;
            if (!w) { lease = typeof a === 'number' ? null : a.event_id; break; }
            if (waited + w > o.maxRateWaitMs) throw Object.assign(new Error('Cupo de velocidad de Gmail ocupado'), { code: 'RATE_WAIT' });
            waited += w; await sleep(w);
          }
          const refund = async () => { if (lease != null && store.refundRate) await store.refundRate(lease).catch(() => {}); };
          // c) la espera por cupo dejó el token por vencer: renovarlo tardaría y la reserva quedaría vieja → se devuelve y se repite el ciclo
          if (provider.tokenFresh && !provider.tokenFresh()) {
            await refund();
            if (++rounds > 3) throw Object.assign(new Error('Cupo de velocidad de Gmail ocupado'), { code: 'RATE_WAIT' });
            continue;
          }
          const c = await store.check(d.id, d.token, now);   // d) verificación final: nada más se espera entre esta y la llamada
          if (c !== 'OK') { await refund(); throw Object.assign(new Error('Interrumpido antes de llamar a Gmail: ' + c), { code: 'ABORTED', check: c }); }
          return token;
        }
      };
      let res = null, sendErr = null;
      try {
        if (provider.post) {
          let r = await provider.post(base64url(raw), await gate(false));
          if (r.status === 401) r = await provider.post(base64url(raw), await gate(true));   // token vencido: Gmail NO lo procesó; el 2º intento pasa por su propia verificación
          res = provider.interpret(r);
        } else res = await provider.send(base64url(raw), { beforeHttp: () => gate(false) });   // proveedores simples (pruebas)
      } catch (e) { sendErr = e; }
      // cancelado / pausado / sin conexión / destinatario inactivo detectado ANTES de llamar a Gmail: NO es un error de Gmail.
      // El estado ya lo dejó la verificación (cancelado, pendiente sin gastar intento, omitido) y el cupo de velocidad se devolvió.
      if (sendErr && sendErr.code === 'ABORTED') { sum.skipped++; continue; }
      if (sendErr && sendErr.code === 'RATE_WAIT') {   // espera de cupo demasiado larga: vuelve a pendiente SIN gastar intento (no es error de Gmail)
        sum.status = 'CUPO_VELOCIDAD'; sum.note = 'El cupo de velocidad de Gmail estuvo ocupado: los envíos siguen pendientes para la próxima ejecución.';
        for (const r of batch.slice(i)) await store.release(r.id, r.token).catch(() => {});
        break;
      }
      if (!sendErr) {
        // 2) REGISTRO: Gmail aceptó. Un fallo al registrar NUNCA se trata como error de envío (no se reenvía)
        const gid = res && res.id;
        if (await persistAccepted(store, d, gid, now, o, sleep)) sum.sent++;
        else { sum.unrecorded.push({ delivery: d.id, gmail_id: gid || null }); sum.verify++; sum.status = 'ERROR_REGISTRO';
          sum.note = 'Gmail aceptó ' + sum.unrecorded.length + ' correo(s) pero no se pudo registrar el resultado: quedan "Por verificar" (no se reenvían). Ids de Gmail: ' + sum.unrecorded.map(x => x.gmail_id).join(', ');
          for (const r of batch.slice(i + 1)) await store.release(r.id, r.token).catch(() => {});
          break; }   // la base no responde: no se sigue enviando (los demás reservados se liberan si se puede)
      } else {
        const cls = classifyGmailError(sendErr);
        await persistOther(store, d, { outcome: cls, error_code: sendErr.reason || sendErr.code || String(sendErr.status || ''), error: humanError(cls, sendErr) }, now, o, sleep);
        if (cls === 'RETRYABLE') sum.retry++; else if (cls === 'AMBIGUOUS') sum.verify++; else sum.failed++;
        if (cls === 'AUTH') {   // no se repite: se marca que hay que reconectar y los demás quedan PENDIENTES (sin intento consumido)
          sum.auth = true; sum.status = 'REQUIERE_RECONEXION'; sum.note = 'Gmail rechazó la autorización: hay que reconectar la cuenta.';
          for (const r of batch.slice(i + 1)) await store.release(r.id, r.token).catch(() => {});
          break;
        }
      }
      if (sum.status === 'ERROR_REGISTRO') { for (const r of batch.slice(i + 1)) await store.release(r.id, r.token).catch(() => {}); break; }
      if (i < batch.length - 1 && o.pauseMs) await sleep(o.pauseMs);   // pausa opcional (0 por defecto): la cuota de Gmail la controla el limitador COMPARTIDO (antes de cada llamada), no esta pausa
    }
  } catch (e) { sum.status = 'ERROR'; sum.note = String(e && e.message || e).slice(0, 300); }
  // Sin limpieza automática de adjuntos: los archivos sin referencias se CONSERVAN hasta implementar una limpieza coordinada con el registro
  // (ver LIMITES_Y_COSTOS.md). Es preferible conservar archivos de más que arriesgar un adjunto válido.
  await store.recordDispatch(sum).catch(() => {});
  return sum;
}

export function humanError(cls, e) {
  if (cls === 'AUTH') return 'Gmail rechazó la autorización. Hay que reconectar la cuenta en Comunicaciones → Conexión Gmail.';
  if (cls === 'AMBIGUOUS') return 'No se recibió la respuesta de Gmail después de enviar: puede haberse enviado. Verificá en "Enviados" de la cuenta antes de reintentar.';
  if (cls === 'RETRYABLE') return 'Gmail no está disponible o se alcanzó un límite temporal (' + (e.status || e.reason || 'red') + '). Se reintenta automáticamente con espera.';
  return 'Gmail rechazó el correo (' + (e.status || '') + ' ' + String(e.reason || e.message || '').slice(0, 120) + ').';
}
