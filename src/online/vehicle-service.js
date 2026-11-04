// V4.22 · Cálculo ÚNICO del service de un vehículo (lo usan Configuración → C y la pantalla de Vehículos).
// Próximo service = km del último service + intervalo de mantenimiento DEL VEHÍCULO.  Faltan = próximo − km actual.
// El intervalo de mantenimiento NO es el intervalo de repetición de las alertas por email (configuración aparte).
export const SERVICE_INTERVAL_MIN = 500, SERVICE_INTERVAL_MAX = 100000;
export function intervalError(raw) {
  const n = Number(String(raw ?? '').replace(/\./g, '').replace(',', '.'));
  if (!String(raw ?? '').trim()) return 'Indicá el intervalo de service (cada cuántos km se hace el service).';
  if (!Number.isFinite(n) || !Number.isInteger(n)) return 'El intervalo de service tiene que ser un número entero de km.';
  if (n < SERVICE_INTERVAL_MIN || n > SERVICE_INTERVAL_MAX)
    return 'El intervalo de service (cada cuántos km se hace) tiene que estar entre ' + SERVICE_INTERVAL_MIN.toLocaleString('es-AR') + ' y ' + SERVICE_INTERVAL_MAX.toLocaleString('es-AR') + ' km. No es el kilometraje del vehículo.';
  return null;
}
export function serviceInfo(v, warnKm = 1000) {
  const cur = Number(v.current_km) || 0, last = Number(v.last_service_km) || 0, iv = Number(v.service_interval_km) || 0;
  const suspicious = !iv || iv < SERVICE_INTERVAL_MIN || iv > SERVICE_INTERVAL_MAX;   // p. ej. el km cargado por error como intervalo
  const next = last + iv, left = next - cur, due = !suspicious && left <= 0, soon = !suspicious && !due && left <= (Number(warnKm) || 0);
  return { current: cur, last, interval: iv, next, left, due, soon, suspicious,
    state: suspicious ? 'REVISAR' : due ? 'VENCIDO' : soon ? 'PROXIMO' : 'OK' };
}
