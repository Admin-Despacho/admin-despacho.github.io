// Informe Cristian · el PDF usa el mismo criterio y los mismos números que la pantalla (V2), y reimprime un informe V1 guardado tal cual.
import { describe, it, expect } from 'vitest';
import { execFileSync } from 'node:child_process';
import { writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os'; import { join } from 'node:path';
import { buildReport, atLocal, money } from '../../supabase/functions/_shared/report-engine.js';
import { reportPdf } from '../../supabase/functions/_shared/report-pdf.js';
const at = (d, t) => new Date(atLocal(d, t)).toISOString();
const st = (id, c, zone, fee, outcome = null) => ({ id, client_name: c, client_key: c, zone, outcome, shipping_fee: fee, merchandise_amount: 100000, stop_type: 'PEDIDO' });
const ROUTES = [{ id: 'r1', number: '01-000200', carrier_id: 'CT-ESTE', operational_status: 'PUBLICADA', published_at: at('2026-11-14', '09:00'), stops: [st('a', 'Uno', 'ESTE', 13000), st('b', 'Dos', 'CENTRO', 7000, 'ENTREGADO')] }];
const text = async rep => { const d = mkdtempSync(join(tmpdir(), 'okdpdf-')), f = join(d, 'r.pdf'); writeFileSync(f, Buffer.from(await reportPdf(rep))); return execFileSync('pdftotext', ['-layout', f, '-']).toString(); };
// cajas de cada palabra del PDF (pdftotext -bbox) por página
const boxes = async (rep, file) => { const d = mkdtempSync(join(tmpdir(), 'okdpdf-')), f = file || join(d, 'r.pdf'); writeFileSync(f, Buffer.from(await reportPdf(rep)));
  const html = execFileSync('pdftotext', ['-bbox', f, '-']).toString(); const pages = html.split('<page').slice(1);
  return pages.map(pg => [...pg.matchAll(/<word xMin="([\d.]+)" yMin="([\d.]+)" xMax="([\d.]+)" yMax="([\d.]+)">([^<]*)<\/word>/g)].map(m => ({ x1: +m[1], y1: +m[2], x2: +m[3], y2: +m[4], w: m[5] }))); };
const overlaps = words => { const out = []; for (let i = 0; i < words.length; i++) for (let j = i + 1; j < words.length; j++) { const a = words[i], b = words[j];
  const ix = Math.min(a.x2, b.x2) - Math.max(a.x1, b.x1), iy = Math.min(a.y2, b.y2) - Math.max(a.y1, b.y1); if (ix > 0.5 && iy > 0.5) out.push(a.w + ' × ' + b.w); } return out; };
describe('PDF del informe Cristian', () => {
  it('PDF-01 (V2) criterio de publicación, envíos incluidos con su estado y el mismo total que la pantalla', async () => {
    const rep = buildReport({ routes: ROUTES, costs: [], sel: { kind: '7D' }, now: atLocal('2026-11-15', '12:00') });
    const t = await text(rep);
    expect(t).toMatch(/PUBLICACIÓN de la hoja/); expect(t).toMatch(/ENVÍOS INCLUIDOS: 2/); expect(t).toMatch(/PENDIENTES: 1/); expect(t).toMatch(/ENTREGADOS: 1/);
    expect(t).toContain(money(rep.total.income)); expect(rep.total.income).toBe(20000);
    expect(t).not.toMatch(/Solo hojas FINALIZADAS/);
  });
  it('PDF-03 con importes GRANDES ningún texto se superpone (rótulos largos pasan a otra línea) y el importe aparece completo', async () => {
    const big = [{ id: 'g', number: '01-009999', carrier_id: 'CT-ESTE', operational_status: 'PUBLICADA', published_at: at('2026-11-14', '09:00'),
      stops: Array.from({ length: 40 }, (_, i) => st('g' + i, 'Cliente Grande ' + i, ['ESTE', 'ALREDEDORES', 'CENTRO'][i % 3], 3086419.75)) }];
    const rep = buildReport({ routes: big, costs: [{ monthly_cost: 987654321.12, valid_from: '2026-01-01', valid_to: null }], sel: { kind: '7D' }, now: atLocal('2026-11-15', '12:00') });
    const pages = await boxes(rep, process.env.OKD_PDF_OUT || undefined); const all = pages.flatMap((p, i) => overlaps(p).map(x => 'pág ' + (i + 1) + ': ' + x));
    expect(all).toEqual([]);
    // nada se sale del margen derecho (página A4 595,28 pt − margen 40)
    const out = pages.flatMap((p, i) => p.filter(w => w.x2 > 595.28 - 40 + 1).map(w => 'pág ' + (i + 1) + ': ' + w.w + ' (' + w.x2 + ')'));
    expect(out).toEqual([]);
    const words = pages.flat().map(w => w.w).join(' ');
    expect(words).toContain(money(rep.total.income).replace(/\s/g, ' ').split(' ').pop()); expect(rep.total.income).toBeGreaterThan(100000000);
    expect(words).toMatch(/Importe de envíos/); expect(words).toMatch(/cobrado\)/);
  });
  it('PDF-02 un informe guardado con la versión 1 se reimprime como se generó (historial conservado)', async () => {
    // informe guardado ANTES del cambio (sin 'criterion'), aunque fuera una regeneración v2 del período
    const v1 = { version: 2, type: 'WEEKLY', generated_at: new Date().toISOString(), period: { start: '2026-10-04', end: '2026-10-10', days: 7, label: 'Semana', window: null },
      summary: { completed: 5, not_delivered: 1, rescheduled: 1, note: 'Entrega parcial se contabiliza como completada.' },
      zones: [{ zone: 'ESTE', completed: 2, not_delivered: 1, rescheduled: 1, income: 26000, avg: 13000 }, { zone: 'ALREDEDORES', completed: 1, not_delivered: 0, rescheduled: 0, income: 9000, avg: 9000 }, { zone: 'CENTRO', completed: 2, not_delivered: 0, rescheduled: 0, income: 14000, avg: 7000 }],
      total: { completed: 5, not_delivered: 1, rescheduled: 1, income: 49000, avg: 9800 }, coverage: { income_by_zone: { ESTE: 26000, ALREDEDORES: 9000, CENTRO: 14000 }, income: 49000, cost: 0, diff: 49000, covers: true, verdict: 'CUBRE EL COSTO', text: 'Sobran $ 49.000' },
      best_clients: [], recover: [], alerts: { over30: 0, over60: 0, over90: 0 }, reinforce: [], decisions: [], inputs: { routes_counted: ['CTE-1'], costs_used: [] } };
    const t = await text(v1);
    expect(t).toMatch(/Solo hojas FINALIZADAS/); expect(t).toMatch(/ENVÍOS COMPLETADOS: 5/); expect(t).toContain(money(49000));
  });
});
