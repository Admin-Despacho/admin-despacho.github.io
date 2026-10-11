import { describe, it, expect } from 'vitest';
import { readFileSync } from 'fs';
const win = {}; new Function('window', readFileSync(new URL('../../public/legacy/financing.js', import.meta.url), 'utf8'))(win);
const F = win.OKFinancing;
const row = (s, due, extra = {}) => ({ n: 'NDPX002000007242', key: '12156143', c: 'MORAN ELISA', comp: 'NDP [X] 0020-00007242', d: '2026-10-08', m: 5165598.86, s, due, q: '', ...extra });
const ELISA = ['2026-10-15', '2026-11-15', '2026-12-15', '2027-01-15', '2027-02-15', '2027-03-15'].map((d, i) => row(i === 5 ? 860933.16 : 860933.14, d));

describe('Financiación propia (cuotas vs duplicados)', () => {
  it('FP-ON-01 comprobante normal', () => { const g = F.classify([row(100, '')]); expect(g.status).toBe('NORMAL'); expect(g.total).toBe(100); });
  it('FP-ON-02/03 seis partes agrupadas y sumadas (Elisa Moran)', () => { const g = F.classify(ELISA); expect(g.status).toBe('FINANCIACION_PROPIA_VIGENTE'); expect(g.parts).toBe(6); expect(g.total).toBe(5165598.86); });
  it('FP-ON-04 no se queda con la primera fila', () => { const { groups } = F.groupAll(ELISA, 'imp1'); const rec = groups.get('NDPX002000007242')[0]; expect(rec.s).toBe(5165598.86); expect(rec.s).not.toBe(860933.14); });
  it('FP-ON-05 duplicado exacto se cuenta una sola vez', () => { const g = F.classify([...ELISA, { ...ELISA[2] }]); expect(g.total).toBe(5165598.86); expect(g.duplicates).toBe(1); expect(g.parts).toBe(6); });
  it('FP-ON-06 partes reales (mismo saldo, distinto vencimiento) se conservan', () => { const g = F.classify([row(500, '2026-11-01'), row(500, '2026-12-01')]); expect(g.parts).toBe(2); expect(g.total).toBe(1000); });
  it('FP-ON-07 vigente', () => expect(F.classify(ELISA).label).toBe('FINANCIACIÓN PROPIA · DEUDA VIGENTE'));
  it('FP-ON-08 saldada', () => { const g = F.classify(ELISA.map(r => ({ ...r, s: 0 }))); expect(g.status).toBe('FINANCIACION_PROPIA_SALDADA'); expect(g.total).toBe(0); expect(g.label).toBe('FINANCIACIÓN PROPIA · SALDADA'); });
  it('FP-ON-09 parcialmente saldada: solo suma las pendientes y lo informa', () => {
    const g = F.classify(ELISA.map((r, i) => ({ ...r, s: i < 2 ? 0 : r.s })));
    expect(g.total).toBe(Math.round((860933.14 * 3 + 860933.16) * 100) / 100); expect(F.partsText(g)).toBe('6 partes · 4 con saldo · 2 saldadas');
  });
  it('FP-ON-17 importaciones distintas no se mezclan', () => {
    const a = F.groupAll(ELISA, 'impA'), b = F.groupAll(ELISA.slice(0, 3), 'impB');
    expect(a.groups.get('NDPX002000007242')[0].fin.importId).toBe('impA'); expect(b.groups.get('NDPX002000007242')[0].s).toBe(Math.round(860933.14 * 3 * 100) / 100);
  });
  it('FP-ON-18 filas que no se pueden distinguir → POSIBLE FINANCIACIÓN PROPIA · REVISAR (no suma)', () => {
    const g = F.classify([row(100, '2026-11-01'), row(200, '2026-11-01')]); expect(g.status).toBe('POSIBLE_FINANCIACION_REVISAR'); expect(g.total).toBeNull();
    expect(F.classify([row(100, ''), row(200, '')]).status).toBe('POSIBLE_FINANCIACION_REVISAR');
  });
  it('Distinto cliente con el mismo número no se mezcla', () => {
    const { groups } = F.groupAll([row(100, '2026-11-01'), { ...row(300, '2026-11-01'), key: 'OTRO' }], 'i');
    expect(groups.get('NDPX002000007242').map(g => g.s).sort()).toEqual([100, 300]);
  });
});
