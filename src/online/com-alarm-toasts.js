// ALARMAS COMERCIALES · avisos emergentes de CAMBIO DE ESTADO (atendida / cancelada / ya no pendiente).
// Corrección del recuadro «trabado»: antes se listaban SIEMPRE las alarmas propias no sonando (también las ya ATENDIDAS de las
// últimas 12 h), sin cierre ni vencimiento. Ahora:
//  · una alarma PENDIENTE sigue a la vista mientras esté pendiente (lo decide com-alarm.js);
//  · al DETECTAR la transición efectiva (pendiente → atendida/cancelada) se muestra UNA confirmación, 5 s, con X para cerrarla ya;
//  · la primera consulta de cada sesión/página es la LÍNEA DE BASE: lo histórico nunca se muestra (ni al recargar ni al navegar);
//  · una vez cerrada (X o vencida) no vuelve a aparecer; las consultas periódicas NO reinician el temporizador;
//  · cada alarma tiene su propio temporizador; todo se cancela al destruir la instancia (cierre de sesión / cambio de usuario).
// Es SOLO visual: no toca el servidor, el historial, los estados ni la auditoría.
export const TOAST_MS = 5000;
const PENDING = 'PENDIENTE_ATENCION';

export function createAlarmToasts({ later, clear = () => {}, now = () => Date.now(), ttl = TOAST_MS, onChange = () => {} } = {}) {
  const seen = new Map();      // id → última vista de la alarma
  const toasts = new Map();    // id → { alarm, until, timer }
  const closed = new Set();    // ids ya mostrados y cerrados: no vuelven
  const startedAt = now();
  let baseline = false;
  function show(alarm) {
    if (closed.has(alarm.id) || toasts.has(alarm.id)) return false;   // nunca se reinicia el temporizador
    const t = { alarm, until: now() + ttl, timer: 0 };
    t.timer = later(() => { if (toasts.get(alarm.id) === t) { toasts.delete(alarm.id); closed.add(alarm.id); onChange(); } }, ttl);
    toasts.set(alarm.id, t); return true;
  }
  return {
    // items: respuesta completa de la consulta; complete=false si la lista pudo quedar truncada (no se infieren desapariciones)
    observe(items, { complete = true } = {}) {
      let changed = false;
      const ids = new Set();
      for (const a of items || []) {
        if (!a || !a.id) continue; ids.add(a.id);
        const prev = seen.get(a.id);
        if (baseline && a.status !== PENDING) {
          const fresh = !prev && Date.parse(a.raised_at || 0) >= startedAt - 60000;   // creada y resuelta entre dos consultas de esta sesión
          if ((prev && prev.status === PENDING) || fresh) changed = show(a) || changed;
        }
        seen.set(a.id, a);
      }
      if (baseline && complete) for (const [id, prev] of seen) {
        if (!ids.has(id) && prev.status === PENDING) { changed = show({ ...prev, status: 'NO_PENDIENTE' }) || changed; seen.set(id, { ...prev, status: 'NO_PENDIENTE' }); }
      }
      baseline = true;
      return changed;
    },
    close(id) { const t = toasts.get(id); if (!t) return false; clear(t.timer); toasts.delete(id); closed.add(id); onChange(); return true; },
    list() { return [...toasts.values()].map(t => t.alarm); },
    isClosed: id => closed.has(id),
    dispose() { for (const t of toasts.values()) clear(t.timer); toasts.clear(); seen.clear(); closed.clear(); },
  };
}
