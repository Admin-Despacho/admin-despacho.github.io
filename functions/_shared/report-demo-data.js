// Datos de DEMOSTRACIÓN para el informe de Cristian Torres (modo demo y pruebas).
// Determinístico: misma semilla → mismos datos. No son datos reales.
import { atLocal, addDays, local } from './report-engine.js';

function rng(seed) { let s = seed >>> 0; return () => { s = (s * 1664525 + 1013904223) >>> 0; return s / 4294967296; }; }

// Tarifas de envío de la demo (en el sistema real se congelan en cada parada al publicar la hoja)
export const DEMO_FEES = { ESTE: 13000, ALREDEDORES: 9000, CENTRO: 7000 };
export const DEMO_COSTS = [{ monthly_cost: 1600000, valid_from: '2026-01-01', valid_to: null }];

const NAMES = {
  ESTE: ['Todo Móvil', 'Celular Shop', 'Informática del Este', 'Claro Junín', 'Rivadavia Cell', 'San Martín Tech', 'Junín Accesorios', 'Palmira Phone', 'La Colonia Cel', 'Medrano Store', 'Este Digital', 'Santa Rosa Cell'],
  ALREDEDORES: ['Maipú Cell', 'Luján Accesorios', 'Godoy Cruz Tech', 'Las Heras Phone', 'Guaymallén Store', 'Dorrego Cell', 'Carrodilla Móvil', 'Chacras Tech', 'Villa Nueva Cel', 'Rodeo Phone', 'Perdriel Store', 'Coquimbito Cell'],
  CENTRO: ['Centro Cell', 'Peatonal Phone', 'San Martín 1200', 'Plaza Tech', 'Arístides Store', 'Mitre Accesorios', 'Godoy Centro', 'Microcentro Cel', 'Las Heras Centro', 'Alameda Phone']
};

/**
 * Genera hojas de Cristian Torres desde `from` hasta `to` (fechas locales), lunes a sábado.
 * Cada cliente tiene su frecuencia; algunos dejan de comprar (para "clientes a recuperar").
 * Agrega una hoja PUBLICADA y una EN CURSO el último día (no deben contarse).
 */
export function demoRoutes({ from = '2026-07-01', to = '2026-10-10', seed = 7 } = {}) {
  const rand = rng(seed);
  const clients = [];
  for (const zone of Object.keys(NAMES)) NAMES[zone].forEach((name, i) => {
    const freq = [3, 4, 5, 6, 7, 7, 10, 12, 14, 21][Math.floor(rand() * 10)];
    const stopAfter = rand() < 0.28 ? addDays(to, -Math.floor(20 + rand() * 80)) : null; // dejó de comprar
    clients.push({ zone, name, key: zone + ':' + i, freq, next: addDays(from, Math.floor(rand() * freq)), stopAfter, avg: 40000 + Math.floor(rand() * 220000) });
  });
  const routes = []; let n = 1;
  for (let d = from; d <= to; d = addDays(d, 1)) {
    const wd = local(atLocal(d, '12:00')).weekday; if (wd === 0) continue; // domingo sin reparto
    for (const carrier of ['CT-ESTE', 'CT-ALR']) {
      const stops = [];
      for (const c of clients) {
        const zoneOk = carrier === 'CT-ESTE' ? c.zone === 'ESTE' : c.zone !== 'ESTE';
        if (!zoneOk || c.next > d || (c.stopAfter && d > c.stopAfter)) continue;
        if (c.next < d) c.next = d;
        const r = rand();
        const outcome = r < 0.84 ? 'ENTREGADO' : r < 0.91 ? 'ENTREGA_PARCIAL' : r < 0.96 ? 'NO_ENTREGADO' : 'REPROGRAMAR';
        const merch = Math.round(c.avg * (0.6 + rand() * 0.8));
        stops.push({ seq: stops.length + 1, client_name: c.name, client_key: c.key, zone: c.zone, outcome, shipping_fee: DEMO_FEES[c.zone],
          merchandise_amount: merch, merchandise_collected: outcome === 'NO_ENTREGADO' ? 0 : merch, order_numbers: [String(30000 + n * 10 + stops.length)] });
        c.next = addDays(d, Math.max(2, Math.round(c.freq * (0.8 + rand() * 0.4))));
      }
      if (!stops.length) continue;
      const hh = 17 + Math.floor(rand() * 3), mm = Math.floor(rand() * 60);
      routes.push({ id: 'rt-' + n, number: (carrier === 'CT-ESTE' ? 'CTE-' : 'CTA-') + String(n).padStart(4, '0'), carrier_id: carrier,
        operational_status: 'COMPLETADA', published_at: new Date(atLocal(d, '08:00')).toISOString(), completed_at: new Date(atLocal(d, String(hh).padStart(2, '0') + ':' + String(mm).padStart(2, '0'))).toISOString(), stops });
      n++;
    }
  }
  // Hojas que NO deben entrar al informe
  const mk = (status, num, zone) => ({ id: 'rt-' + num, number: num, carrier_id: zone === 'ESTE' ? 'CT-ESTE' : 'CT-ALR', operational_status: status, published_at: new Date(atLocal(to, '08:00')).toISOString(), completed_at: null,
    stops: [{ seq: 1, client_name: 'Cliente Hoja ' + status, client_key: 'X:' + num, zone, outcome: 'ENTREGADO', shipping_fee: DEMO_FEES[zone], merchandise_amount: 999999, order_numbers: ['99999'] }] });
  routes.push(mk('PUBLICADA', 'CTE-PUB', 'ESTE'), mk('EN_CURSO', 'CTA-CUR', 'CENTRO'));
  return routes;
}
