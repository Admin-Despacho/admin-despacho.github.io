// Informe Cristian · REENVÍOS: el envío se cuenta UNA vez por pedido, en su primera publicación válida (hora de Mendoza). Datos ficticios.
import { describe, it, expect } from 'vitest';
import { execFileSync } from 'node:child_process';
import { writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os'; import { join } from 'node:path';
import { buildReport, atLocal, money, consolidatedStops } from '../../supabase/functions/_shared/report-engine.js';
import { emailHtml, emailText } from '../../supabase/functions/_shared/report-email.js';
import { reportPdf } from '../../supabase/functions/_shared/report-pdf.js';

const at = (d, t) => new Date(atLocal(d, t)).toISOString();
const st = (id, client, zone, fee, orders, outcome = null, extra = {}) => ({ id, client_name: client, client_key: client, zone, outcome, shipping_fee: fee, merchandise_amount: 100000, stop_type: 'PEDIDO', order_numbers: orders, ...extra });
const route = (id, number, status, pub, stops) => ({ id, number, carrier_id: 'CT-ESTE', operational_status: status, published_at: pub, stops });
const NOW = atLocal('2026-11-15', '12:00');
const rep = (routes, sel) => buildReport({ routes, costs: [{ monthly_cost: 1000000, valid_from: '2026-01-01', valid_to: null }], sel, now: NOW });
const NOV = { kind: 'FREE', from: '2026-11-01', to: '2026-11-14' };
// estado del envío CALCULADO POR EL MOTOR (no por la prueba)
const engineOutcome = routes => { const e = consolidatedStops(routes, 0, Number.MAX_SAFE_INTEGER).find(x => x.order_numbers.includes('G-1')); return { outcome: e.outcome, per: e.order_outcomes }; };
// lunes 9/11: intento 1 NO ENTREGADO · martes 10/11: intento 2 ENTREGADO (mismo pedido 0001-00045678, otra hoja)
const LUN = route('r1', '01-000101', 'COMPLETADA', at('2026-11-09', '09:00'), [st('a', 'Cliente Ausente', 'ESTE', 13000, ['0001-00045678'], 'NO_ENTREGADO')]);
const MAR = route('r2', '01-000102', 'COMPLETADA', at('2026-11-10', '09:00'), [st('b', 'Cliente Ausente', 'ESTE', 13000, ['0001-00045678'], 'ENTREGADO')]);

describe('Informe Cristian · reenvíos sin duplicar', () => {
  it('RE-01 mismo pedido en dos hojas (lunes no entregado, martes entregado): UN envío, UN importe, UN resultado, UNA compra', () => {
    const r = rep([LUN, MAR], NOV);
    expect(r.total).toMatchObject({ shipments: 1, income: 13000, delivered: 1, not_delivered: 0 });   // un solo resultado: el último intento
    expect(r.total.avg).toBe(13000);
    const c = r.best_clients.find(x => x.client === 'Cliente Ausente'); expect(c.purchases).toBe(1);
    expect(r.inputs.extra_attempts).toBe(1);
  });
  it('RE-02 cuenta el LUNES (primera publicación), no el martes del reintento', () => {
    expect(rep([LUN, MAR], { kind: 'FREE', from: '2026-11-09', to: '2026-11-09' }).total.shipments).toBe(1);
    expect(rep([LUN, MAR], { kind: 'FREE', from: '2026-11-10', to: '2026-11-10' }).total.shipments).toBe(0);
  });
  it('RE-03 reintento en OTRO período (mes siguiente): no vuelve a sumar', () => {
    const OCT = route('r3', '01-000090', 'COMPLETADA', at('2026-10-31', '10:00'), [st('c', 'Fin de Mes', 'CENTRO', 7000, ['0001-00040000'], 'REPROGRAMAR')]);
    const NOVR = route('r4', '01-000110', 'COMPLETADA', at('2026-11-02', '10:00'), [st('d', 'Fin de Mes', 'CENTRO', 7000, ['0001-00040000'], 'ENTREGADO')]);
    expect(rep([OCT, NOVR], { kind: 'MONTH', year: 2026, month: 11 }).total.shipments).toBe(0);
    expect(rep([OCT, NOVR], { kind: 'MONTH', year: 2026, month: 10 }).total).toMatchObject({ shipments: 1, income: 7000, delivered: 1 });
  });
  it('RE-04 dos pedidos DISTINTOS del mismo cliente siguen siendo dos envíos', () => {
    const R = route('r5', '01-000120', 'PUBLICADA', at('2026-11-11', '09:00'), [st('e', 'Mismo Cliente', 'ESTE', 13000, ['0001-00050001']), st('f', 'Mismo Cliente', 'ESTE', 13000, ['0001-00050002'])]);
    const r = rep([R], NOV); expect(r.total).toMatchObject({ shipments: 2, income: 26000 }); expect(r.best_clients.find(x => x.client === 'Mismo Cliente').purchases).toBe(2);
  });
  it('RE-05 agrupación y cambio de zona: [A+B] se cuenta una vez con SU zona e importe; la parada [B+C] cuenta el envío de C pero su importe NO se suma (no separable)', () => {
    const O = route('r6', '01-000130', 'COMPLETADA', at('2026-11-03', '09:00'), [st('g', 'Agrupado', 'ESTE', 13000, ['A-1', 'B-2'], 'NO_ENTREGADO')]);
    const R1 = route('r7', '01-000131', 'COMPLETADA', at('2026-11-04', '09:00'), [st('h', 'Agrupado', 'CENTRO', 7000, ['A-1'], 'ENTREGADO')]);           // solo A, otra zona
    const R2 = route('r8', '01-000132', 'PUBLICADA', at('2026-11-05', '09:00'), [st('i', 'Agrupado', 'ALREDEDORES', 9000, ['B-2', 'C-3'])]);              // B (reintento) + C (nuevo)
    const r = rep([O, R1, R2], NOV);
    expect(r.total).toMatchObject({ shipments: 2, income: 13000, unsplit: 1 });   // [A+B] 13.000; la parada [B+C] lleva B (ya contado): su 9.000 no se separa
    expect(r.inputs.unsplittable).toEqual([{ route: '01-000132', client: 'Agrupado', new_orders: ['C-3'], retried_orders: ['B-2'], stop_merchandise: 100000, stop_fee: 9000 }]);
    expect(r.zones.find(z => z.zone === 'ESTE')).toMatchObject({ shipments: 1, income: 13000 });
    expect(r.zones.find(z => z.zone === 'CENTRO')).toMatchObject({ shipments: 0, income: 0 });
    const all = r.inputs.retries.flatMap(x => x.orders); expect(all).toEqual(expect.arrayContaining(['A-1', 'B-2']));   // ningún pedido se pierde
  });
  it('RE-06 primera hoja CANCELADA (y borrador): el origen es la primera publicación VÁLIDA', () => {
    const CAN = route('r9', '01-000140', 'CANCELADA', at('2026-11-02', '09:00'), [st('j', 'Cancelado', 'ESTE', 13000, ['0001-00060000'])]);
    const BOR = route('r10', '01-000141', 'BORRADOR', at('2026-11-03', '09:00'), [st('k', 'Cancelado', 'ESTE', 13000, ['0001-00060000'])]);
    const OK = route('r11', '01-000142', 'PUBLICADA', at('2026-11-06', '09:00'), [st('l', 'Cancelado', 'ESTE', 13000, ['0001-00060000'])]);
    const r = rep([CAN, BOR, OK], NOV); expect(r.total.shipments).toBe(1); expect(r.inputs.routes_counted).toEqual(['01-000142']);
    expect(rep([CAN, BOR, OK], { kind: 'FREE', from: '2026-11-02', to: '2026-11-03' }).total.shipments).toBe(0);
  });
  it('RE-07 trazabilidad: se conservan TODOS los intentos con hoja, fecha y resultado', () => {
    const x = rep([LUN, MAR], NOV).inputs.retries[0];
    expect(x.orders).toEqual(['0001-00045678']);
    expect(x.attempts.map(a => [a.route_number, a.outcome])).toEqual([['01-000101', 'NO_ENTREGADO'], ['01-000102', 'ENTREGADO']]);
    expect(x.attempts.every(a => a.published_at)).toBe(true);
  });
  it('RE-10 (Codex) A+B y luego B+C, $100 por pedido: el ranking NO vuelve a sumar B ($200, no $400) y la limitación queda explícita', () => {
    const P1 = route('c1', '01-000160', 'COMPLETADA', at('2026-11-03', '09:00'), [st('p1', 'Cliente Codex', 'ESTE', 13000, ['A', 'B'], 'NO_ENTREGADO', { merchandise_amount: 200 })]);
    const P2 = route('c2', '01-000161', 'COMPLETADA', at('2026-11-04', '09:00'), [st('p2', 'Cliente Codex', 'ESTE', 13000, ['B', 'C'], 'ENTREGADO', { merchandise_amount: 200 })]);
    const r = rep([P1, P2], NOV), c = r.best_clients.find(x => x.client === 'Cliente Codex');
    expect(c.amount).toBe(200); expect(c.amount).not.toBe(400);
    expect(r.total).toMatchObject({ shipments: 2, income: 13000 });
    expect(r.inputs.unsplittable[0]).toMatchObject({ new_orders: ['C'], retried_orders: ['B'], stop_merchandise: 200 });
    const lin = r.inputs.retries.find(x => x.orders.includes('A')); expect(lin.orders).toEqual(['A', 'B']); expect(lin.order_outcomes).toEqual({ A: 'NO_ENTREGADO', B: 'ENTREGADO' });
  });
  it('RE-11 un grupo que se DIVIDE en varios intentos: el estado sale del último resultado de CADA pedido', () => {
    const O = route('d1', '01-000170', 'COMPLETADA', at('2026-11-03', '09:00'), [st('o', 'Grupo', 'ESTE', 13000, ['G-1', 'G-2'], 'NO_ENTREGADO')]);
    const A = route('d2', '01-000171', 'COMPLETADA', at('2026-11-04', '09:00'), [st('a', 'Grupo', 'ESTE', 13000, ['G-1'], 'ENTREGADO')]);
    const one = rep([O, A], NOV); expect(one.total).toMatchObject({ shipments: 1, income: 13000, delivered: 1 });
    expect(engineOutcome([O, A])).toEqual({ outcome: 'ENTREGA_PARCIAL', per: { 'G-1': 'ENTREGADO', 'G-2': 'NO_ENTREGADO' } });   // parte entregada y el resto no
    const B = route('d3', '01-000172', 'PUBLICADA', at('2026-11-05', '09:00'), [st('b', 'Grupo', 'ESTE', 13000, ['G-2'])]);
    const two = rep([O, A, B], NOV); expect(two.total).toMatchObject({ shipments: 1, pending: 1, delivered: 0 });   // G-2 en curso → pendiente
    expect(engineOutcome([O, A, B])).toEqual({ outcome: 'PENDIENTE', per: { 'G-1': 'ENTREGADO', 'G-2': 'PENDIENTE' } });
    const C = { ...B, operational_status: 'COMPLETADA', stops: [{ ...B.stops[0], outcome: 'ENTREGADO' }] };
    const three = rep([O, A, C], NOV); expect(three.total).toMatchObject({ shipments: 1, delivered: 1, pending: 0, income: 13000 });
    expect(engineOutcome([O, A, C])).toEqual({ outcome: 'ENTREGADO', per: { 'G-1': 'ENTREGADO', 'G-2': 'ENTREGADO' } });
  });
  it('RE-08 la misma hoja cargada dos veces no duplica; un intento pendiente en curso no suma', () => {
    const PEND = route('r12', '01-000150', 'PUBLICADA', at('2026-11-12', '09:00'), [st('m', 'Cliente Ausente', 'ESTE', 13000, ['0001-00045678'])]);
    const r = rep([LUN, MAR, MAR, PEND], NOV); expect(r.total.shipments).toBe(1); expect(r.total.income).toBe(13000); expect(r.inputs.extra_attempts).toBe(2);
  });
  it('RE-09 PDF y contenido del correo con los mismos números y el detalle de reenvíos', async () => {
    const r = rep([LUN, MAR], NOV);
    const d = mkdtempSync(join(tmpdir(), 're-')), f = join(d, 'r.pdf'); writeFileSync(f, Buffer.from(await reportPdf(r)));
    const t = execFileSync('pdftotext', ['-layout', f, '-']).toString().replace(/\s+/g, ' ');
    expect(t).toMatch(/ENVÍOS INCLUIDOS: 1/); expect(t).toContain(money(13000)); expect(t).toMatch(/Reenvíos: 1 intento\(s\) adicional\(es\) de 1 envío/);
    expect(emailText(r)).toMatch(/REENVÍOS: 1 intento/); expect(emailHtml(r)).toMatch(/1 reintento\(s\) sin sumar/);
  });
});
