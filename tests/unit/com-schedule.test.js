// FINANCIACIÓN PROPIA · calendario de cuotas (src/online/com-schedule.js). Mismos valores esperados que QA/extra_cuotas.sql (servidor).
import { describe, it, expect } from 'vitest';
import { computeSchedule, arDate, addMonths } from '../../src/online/com-schedule.js';
const B = '2026-11-16', dues = c => c.ok ? c.schedule.map(s => s.due) : c.error;
describe('calendario · casos acordados con Dirección (creación 16/11/2026 → límite 16/12/2026 incluido)', () => {
  it('CS-1 una cuota el 23/11 → se acepta', () => expect(dues(computeSchedule({ base: B, installments: 1, first_due: '2026-11-23' }))).toEqual(['2026-11-23']));
  it('CS-2 una cuota el 16/12 (día 30) → se acepta', () => expect(dues(computeSchedule({ base: B, installments: 1, first_due: '2026-12-16' }))).toEqual(['2026-12-16']));
  it('CS-3 dos quincenales desde el 01/12 → 01/12 y 16/12', () => expect(dues(computeSchedule({ base: B, installments: 2, frequency: 'QUINCENAL', first_due: '2026-12-01' }))).toEqual(['2026-12-01', '2026-12-16']));
  it('CS-4 cuatro semanales desde el 23/11 → 23/11, 30/11, 07/12, 14/12', () => expect(dues(computeSchedule({ base: B, installments: 4, frequency: 'SEMANAL', first_due: '2026-11-23' }))).toEqual(['2026-11-23', '2026-11-30', '2026-12-07', '2026-12-14']));
  it('CS-5 dos mensuales desde el 16/12 → bloquea: la cuota 2 vencería el 16/01/2027 (se muestra, no se mueve)', () => {
    const c = computeSchedule({ base: B, installments: 2, frequency: 'MENSUAL', first_due: '2026-12-16' });
    expect(c.ok).toBe(false); expect(c.error).toMatchObject({ code: 'BAD_SCHEDULE', cuota: 2, due: '2027-01-16' }); expect(c.error.message).toContain('16/12/2026'); expect(c.schedule.map(s => s.due)).toEqual(['2026-12-16', '2027-01-16']);
  });
  it('CS-6 una cuota el 17/12 → rechaza aunque sea un único pago', () => expect(computeSchedule({ base: B, installments: 1, first_due: '2026-12-17' }).error).toMatchObject({ code: 'BAD_SCHEDULE', cuota: 1 }));
});
describe('calendario · fechas', () => {
  it('cambio de AÑO', () => expect(dues(computeSchedule({ base: '2026-12-20', installments: 3, frequency: 'SEMANAL', first_due: '2026-12-27' }))).toEqual(['2026-12-27', '2027-01-03', '2027-01-10']));
  it('FIN DE MES igual que PostgreSQL (31/01 + 1 mes = 28/02) y bloqueo si supera', () => {
    expect(dues(computeSchedule({ base: '2027-01-31', installments: 2, frequency: 'MENSUAL', first_due: '2027-01-31' }))).toEqual(['2027-01-31', '2027-02-28']);
    expect(computeSchedule({ base: '2027-01-01', installments: 2, frequency: 'MENSUAL', first_due: '2027-01-30' }).error).toMatchObject({ code: 'BAD_SCHEDULE', cuota: 2, due: '2027-02-28' });
    expect(addMonths('2028-01-31', 1)).toBe('2028-02-29');   // año bisiesto
  });
  it('cambio de MES (quincenal 30/11 → 15/12)', () => expect(dues(computeSchedule({ base: '2026-11-29', installments: 2, frequency: 'QUINCENAL', first_due: '2026-11-30' }))).toEqual(['2026-11-30', '2026-12-15']));
  it('fecha ARGENTINA cerca de medianoche: 02:30 UTC del 17/11 = 16/11 en Argentina', () => { expect(arDate('2026-11-17T02:30:00Z')).toBe('2026-11-16'); expect(arDate('2026-11-17T03:00:00Z')).toBe('2026-11-17'); });
});
describe('calendario · datos inválidos o manipulados', () => {
  for (const k of [0, -2, 'abc', 40, 1.5]) it('cantidad ' + JSON.stringify(k) + ' → rechazo explicado (nunca aceptada)', () => expect(computeSchedule({ base: B, installments: k, frequency: 'SEMANAL', first_due: '2026-11-20' }).ok).toBe(false));
  it('2+ cuotas sin frecuencia o con frecuencia inexistente → BAD_FREQUENCY', () => { expect(computeSchedule({ base: B, installments: 2, first_due: '2026-11-20' }).error.code).toBe('BAD_FREQUENCY'); expect(computeSchedule({ base: B, installments: 2, frequency: 'DIARIA', first_due: '2026-11-20' }).error.code).toBe('BAD_FREQUENCY'); });
  it('primer vencimiento anterior a la creación, inválido o vacío → BAD_FIRST_DUE', () => { for (const f of ['2026-11-15', '2026-13-45', '', null]) expect(computeSchedule({ base: B, installments: 1, first_due: f }).error.code).toBe('BAD_FIRST_DUE'); });
  it('con 1 cuota la frecuencia se ignora', () => expect(computeSchedule({ base: B, installments: 1, frequency: 'MENSUAL', first_due: '2026-11-20' }).frequency).toBeNull());
  it('importes: la última cuota absorbe el redondeo (igual que el servidor)', () => expect(computeSchedule({ base: B, installments: 3, frequency: 'SEMANAL', first_due: '2026-11-20', amount: 100000 }).schedule.map(s => s.amount)).toEqual([33333.33, 33333.33, 33333.34]));
});
