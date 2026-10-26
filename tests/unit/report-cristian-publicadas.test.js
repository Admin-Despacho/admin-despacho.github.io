// Informe Cristian Torres · criterio V2 = hojas PUBLICADAS por fecha de publicación (Mendoza). Datos ficticios.
import { describe, it, expect } from 'vitest';
import { buildReport, atLocal, period, REPORT_VERSION } from '../../supabase/functions/_shared/report-engine.js';
import { emailHtml } from '../../supabase/functions/_shared/report-email.js';

const COSTS = [{ monthly_cost: 1600000, valid_from: '2025-01-01', valid_to: null }];
const at = (d, t) => new Date(atLocal(d, t)).toISOString();
const st = (id, client, zone, fee, outcome = null, extra = {}) => ({ id, client_name: client, client_key: client, zone, outcome, shipping_fee: fee, merchandise_amount: 250000, stop_type: 'PEDIDO', ...extra });
const route = (id, number, status, pub, stops, extra = {}) => ({ id, number, carrier_id: 'CT-ESTE', operational_status: status, published_at: pub, completed_at: null, stops, ...extra });
const NOW = atLocal('2026-11-15', '12:00');
const rep = (routes, sel) => buildReport({ routes, costs: COSTS, sel, now: NOW });
const z = (r, k) => r.zones.find(x => x.zone === k);

// hoja publicada HOY con TODAS sus entregas pendientes (Cristian no marcó nada ni completó la hoja)
const PEND = route('r-pend', '01-000100', 'PUBLICADA', at('2026-11-14', '09:00'), [
  st('s1', 'Cliente Uno', 'ESTE', 13000), st('s2', 'Cliente Dos', 'ESTE', 13000), st('s3', 'Cliente Tres', 'CENTRO', 7000),
  st('t1', 'Retirar cheques', 'ESTE', 0, null, { stop_type: 'TAREA' })]);   // una TAREA no es un envío

describe('Informe Cristian · hojas PUBLICADAS (V2)', () => {
  it('PUB-01 hoja publicada con TODAS las entregas pendientes: aparece con cantidades e importes correctos', () => {
    const r = rep([PEND], { kind: '7D' });
    expect(r.criterion).toBe('HOJAS_PUBLICADAS'); expect(r.criterion_version).toBe(REPORT_VERSION);
    expect(r.inputs.routes_counted).toEqual(['01-000100']);
    expect([z(r, 'ESTE').shipments, z(r, 'ESTE').income, z(r, 'CENTRO').shipments, z(r, 'CENTRO').income]).toEqual([2, 26000, 1, 7000]);
    expect(r.total).toMatchObject({ shipments: 3, income: 33000, pending: 3, delivered: 0 });   // pendientes, nunca "entregados"
    expect(r.total.avg).toBe(11000);
  });
  it('PUB-02 hoja ANTIGUA publicada antes del cambio entra en su período (sin corte, sin republicar)', () => {
    const OLD = route('r-old', '01-000007', 'COMPLETADA', at('2025-03-12', '08:30'), [st('o1', 'Cliente Viejo', 'ALREDEDORES', 9000, 'ENTREGADO')], { completed_at: at('2025-03-12', '18:00') });
    const r = rep([PEND, OLD], { kind: 'MONTH', year: 2025, month: 3 });
    expect(r.inputs.routes_counted).toEqual(['01-000007']); expect(r.total).toMatchObject({ shipments: 1, income: 9000 });
  });
  it('PUB-03 marcar DESPUÉS una entrega como completada: los totales no se duplican ni cambian de período', () => {
    const before = rep([PEND], { kind: 'FREE', from: '2026-11-14', to: '2026-11-14' });
    const done = JSON.parse(JSON.stringify(PEND)); done.stops[0].outcome = 'ENTREGADO'; done.stops[2].outcome = 'ENTREGA_PARCIAL';
    done.operational_status = 'COMPLETADA'; done.completed_at = at('2026-11-20', '19:00');   // finaliza en OTRO día
    const after = rep([done], { kind: 'FREE', from: '2026-11-14', to: '2026-11-14' });
    expect(after.total.shipments).toBe(before.total.shipments); expect(after.total.income).toBe(before.total.income);
    expect(after.total).toMatchObject({ delivered: 2, pending: 1 });   // solo cambia el desglose de estado
    expect(rep([done], { kind: 'FREE', from: '2026-11-20', to: '2026-11-20' }).total.shipments).toBe(0);   // NO se mueve al día de finalización
  });
  it('PUB-04 borrador y cancelada se excluyen', () => {
    const B = route('r-b', '01-000101', 'BORRADOR', at('2026-11-14', '10:00'), [st('b1', 'Borrador', 'ESTE', 13000)]);
    const C = route('r-c', '01-000102', 'CANCELADA', at('2026-11-14', '11:00'), [st('c1', 'Cancelada', 'ESTE', 13000)]);
    const r = rep([PEND, B, C], { kind: '7D' });
    expect(r.inputs.routes_counted).toEqual(['01-000100']); expect(JSON.stringify(r.inputs.fees_used)).not.toMatch(/Borrador|Cancelada/);
  });
  it('PUB-05 sin duplicados: la misma hoja cargada dos veces (reapertura) o con varias versiones suma una sola vez', () => {
    const v2 = { ...PEND, version: 2 };
    const r = rep([PEND, v2, JSON.parse(JSON.stringify(PEND))], { kind: '7D' });
    expect(r.total.shipments).toBe(3); expect(r.total.income).toBe(33000);
  });
  it('PUB-06 importe = envío guardado en la hoja (no mercadería, no cobrado); un envío provisorio se cuenta pero no suma importe', () => {
    const P = route('r-p', '01-000103', 'EN_CURSO', at('2026-11-13', '10:00'), [st('p1', 'Provisorio', 'ESTE', 10000, null, { shipping_fee_source: 'PENDING_CONFIRMATION' }), st('p2', 'Firme', 'ESTE', 13000, 'ENTREGADO', { merchandise_collected: 999999 })]);
    const r = rep([P], { kind: '7D' });
    expect(r.total).toMatchObject({ shipments: 2, income: 13000, fee_pending: 1 }); expect(r.total.avg).toBe(13000); expect(r.inputs.fees_excluded_pending).toBe(1);
  });
  it('PUB-07 límites en hora de Mendoza: 23:59 del último día entra; 00:00 del día siguiente no', () => {
    const A = route('r-a', '01-000104', 'PUBLICADA', at('2026-10-31', '23:59'), [st('a1', 'Límite A', 'ESTE', 13000)]);
    const B = route('r-b2', '01-000105', 'PUBLICADA', at('2026-11-01', '00:00'), [st('b1', 'Límite B', 'ESTE', 13000)]);
    expect(rep([A, B], { kind: 'MONTH', year: 2026, month: 10 }).inputs.routes_counted).toEqual(['01-000104']);
    expect(rep([A, B], { kind: 'MONTH', year: 2026, month: 11 }).inputs.routes_counted).toEqual(['01-000105']);
    expect(Date.parse(A.published_at) < period({ kind: 'MONTH', year: 2026, month: 10 }).toTs).toBe(true);
  });
  it('PUB-08 filtros 7 días, 15 días, mes y libre usan la fecha de publicación', () => {
    const D8 = route('r-8', '01-000106', 'PUBLICADA', at('2026-11-07', '10:00'), [st('d1', 'Hace ocho', 'ESTE', 13000)]);    // fuera de 7D, dentro de 15D
    const D20 = route('r-20', '01-000107', 'COMPLETADA', at('2026-10-26', '10:00'), [st('d2', 'Hace veinte', 'ESTE', 13000, 'ENTREGADO')], { completed_at: at('2026-11-14', '18:00') });
    const all = [PEND, D8, D20];
    expect(rep(all, { kind: '7D' }).inputs.routes_counted).toEqual(['01-000100']);
    expect(rep(all, { kind: '15D' }).inputs.routes_counted.sort()).toEqual(['01-000100', '01-000106']);
    expect(rep(all, { kind: 'MONTH', year: 2026, month: 10 }).inputs.routes_counted).toEqual(['01-000107']);   // publicada en octubre aunque finalizó en noviembre
    expect(rep(all, { kind: 'FREE', from: '2026-11-07', to: '2026-11-07' }).inputs.routes_counted).toEqual(['01-000106']);
  });
  it('PUB-09 hoja antigua sin published_at: usa el registro histórico ROUTE_PUBLISHED; sin ninguna fuente NO se incluye ni se usa la finalización', () => {
    const H = route('r-h', '01-000003', 'COMPLETADA', null, [st('h1', 'Histórica', 'ESTE', 13000, 'ENTREGADO')], { published_at_hist: at('2025-02-03', '08:00'), completed_at: at('2025-02-03', '19:00') });
    const N = route('r-n', '01-000002', 'COMPLETADA', null, [st('n1', 'Sin fecha', 'ESTE', 13000, 'ENTREGADO')], { completed_at: at('2025-02-04', '19:00') });
    const r = rep([H, N], { kind: 'MONTH', year: 2025, month: 2 });
    expect(r.inputs.routes_counted).toEqual(['01-000003']); expect(r.inputs.publication_sources).toEqual({ audit_log: 1 });
    expect(r.inputs.missing_publication).toEqual(['01-000002']);   // se informa: no se inventa ni se usa completed_at
    const ext = route('r-e', '07-000001', 'COMPLETADA', null, [st('e1', 'Externa', 'ESTE', 5000)], { dispatch_mode: 'EXTERNAL', dispatched_at: at('2025-02-05', '10:00') });
    expect(rep([ext], { kind: 'MONTH', year: 2025, month: 2 }).inputs.publication_sources).toEqual({ dispatched_at: 1 });
  });
  it('PUB-10 el contenido del correo/PDF usa los mismos números y no presenta pendientes como entregados (también al regenerar: version 2+)', () => {
    const r = { ...rep([PEND], { kind: '7D' }), version: 3 }; const html = emailHtml(r);   // el servicio pisa 'version' con la regeneración
    expect(html).toContain('Envíos incluidos'); expect(html).toContain('pendientes 3 · entregados 0'); expect(html).toContain('$ 33.000');
    expect(html).not.toContain('Envíos completados');
  });
});
