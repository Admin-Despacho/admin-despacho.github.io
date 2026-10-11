import { describe, it, expect } from 'vitest';
import { buildReport, period, costForPeriod, dueReports, emailKey, recoveryStatus, atLocal, local, fileName } from '../../supabase/functions/_shared/report-engine.js';
import { emailSubject, emailHtml } from '../../supabase/functions/_shared/report-email.js';
import { demoRoutes, DEMO_COSTS } from '../../supabase/functions/_shared/report-demo-data.js';

const COSTS = [{ monthly_cost: 1600000, valid_from: '2026-01-01', valid_to: null }];
const at = (date, hhmm) => new Date(atLocal(date, hhmm)).toISOString();
const stop = (client, zone, outcome, fee, extra = {}) => ({ client_name: client, client_key: client, zone, outcome, shipping_fee: fee, merchandise_amount: 100000, merchandise_collected: 100000, ...extra });
// Semana del 05 al 10/10/2026
const ROUTES = [
  { id: 'a', number: 'CTE-1', carrier_id: 'CT-ESTE', operational_status: 'COMPLETADA', completed_at: at('2026-10-06', '18:00'), stops: [
    stop('Todo Móvil', 'ESTE', 'ENTREGADO', 13000), stop('Celular Shop', 'ESTE', 'ENTREGA_PARCIAL', 13000), stop('Junín Cell', 'ESTE', 'NO_ENTREGADO', 13000), stop('Palmira', 'ESTE', 'REPROGRAMAR', 13000)] },
  { id: 'b', number: 'CTA-1', carrier_id: 'CT-ALR', operational_status: 'COMPLETADA', completed_at: at('2026-10-07', '19:00'), stops: [
    stop('Maipú Cell', 'ALREDEDORES', 'ENTREGADO', 9000), stop('Centro Cell', 'CENTRO', 'ENTREGADO', 7000), stop('Plaza Tech', 'CENTRO', 'ENTREGA_PARCIAL', 7000)] },
  { id: 'p', number: 'CTE-PUB', carrier_id: 'CT-ESTE', operational_status: 'PUBLICADA', completed_at: null, stops: [stop('Publicada SA', 'ESTE', 'ENTREGADO', 13000)] },
  { id: 'c', number: 'CTA-CUR', carrier_id: 'CT-ALR', operational_status: 'EN_CURSO', completed_at: null, stops: [stop('En Curso SA', 'CENTRO', 'ENTREGADO', 7000)] },
  // Finalizada el sábado DESPUÉS de las 15:00: va al informe semanal siguiente
  { id: 'late', number: 'CTE-2', carrier_id: 'CT-ESTE', operational_status: 'COMPLETADA', completed_at: at('2026-10-10', '16:10'), stops: [stop('Tarde SRL', 'ESTE', 'ENTREGADO', 13000)] }
];
const NOW = atLocal('2026-10-10', '15:00');
const WEEK = buildReport({ routes: ROUTES, costs: COSTS, sel: { kind: 'WEEKLY', saturday: '2026-10-10' }, now: NOW, type: 'WEEKLY' });
const z = (rep, k) => rep.zones.find(x => x.zone === k);

describe('Informe Cristian Torres — consolidación', () => {
  it('REPORT-MAIL-01 hoja PUBLICADA no entra', () => { expect(WEEK.inputs.routes_counted).not.toContain('CTE-PUB'); expect(JSON.stringify(WEEK)).not.toContain('Publicada SA'); });
  it('REPORT-MAIL-02 hoja EN CURSO no entra', () => { expect(WEEK.inputs.routes_counted).not.toContain('CTA-CUR'); expect(JSON.stringify(WEEK)).not.toContain('En Curso SA'); });
  it('REPORT-MAIL-03 hoja FINALIZADA entra', () => expect(WEEK.inputs.routes_counted).toEqual(['CTE-1', 'CTA-1']));
  it('REPORT-MAIL-04 ENTREGA PARCIAL cuenta como completada', () => { expect(z(WEEK, 'ESTE').completed).toBe(2); expect(WEEK.summary.completed).toBe(5); });
  it('REPORT-MAIL-05 ENTREGA PARCIAL suma ingreso', () => expect(z(WEEK, 'ESTE').income).toBe(26000));
  it('REPORT-MAIL-06 NO ENTREGADO no suma ingreso', () => { expect(z(WEEK, 'ESTE').not_delivered).toBe(1); expect(WEEK.inputs.fees_used.some(f => f.client === 'Junín Cell')).toBe(false); });
  it('REPORT-MAIL-07 REPROGRAMAR no suma ingreso', () => { expect(z(WEEK, 'ESTE').rescheduled).toBe(1); expect(WEEK.inputs.fees_used.some(f => f.client === 'Palmira')).toBe(false); });
  it('REPORT-MAIL-08/09/10 Este, Alrededores y Centro SEPARADOS (nunca Alrededores + Centro)', () => {
    expect(WEEK.zones.map(x => [x.zone, x.completed, x.income])).toEqual([['ESTE', 2, 26000], ['ALREDEDORES', 1, 9000], ['CENTRO', 2, 14000]]);
    expect(WEEK.total).toMatchObject({ completed: 5, income: 49000 });
    expect(JSON.stringify(WEEK)).not.toMatch(/ALREDEDORES\s*\+\s*CENTRO|Alrededores \+ Centro/i);
  });
  it('Finalizada el sábado después de las 15:00 → entra en el informe SIGUIENTE', () => {
    expect(WEEK.inputs.routes_counted).not.toContain('CTE-2');
    const next = buildReport({ routes: ROUTES, costs: COSTS, sel: { kind: 'WEEKLY', saturday: '2026-10-17' }, now: atLocal('2026-10-17', '15:00'), type: 'WEEKLY' });
    expect(next.inputs.routes_counted).toContain('CTE-2');
  });
  it('Fecha que manda = finalización real (no publicación)', () => {
    const r = [{ ...ROUTES[0], published_at: at('2026-09-20', '08:00') }];
    expect(buildReport({ routes: r, costs: COSTS, sel: { kind: 'MONTH', year: 2026, month: 10 }, now: NOW }).summary.completed).toBe(2);
    expect(buildReport({ routes: r, costs: COSTS, sel: { kind: 'MONTH', year: 2026, month: 9 }, now: NOW }).summary.completed).toBe(0);
  });
});

describe('Informe — filtros, programación y costo', () => {
  it('REPORT-MAIL-11 semanal: sábado 15:00 Mendoza (no antes, no otro día)', () => {
    expect(dueReports(atLocal('2026-10-10', '15:00')).map(d => d.type)).toEqual(['WEEKLY']);
    expect(dueReports(atLocal('2026-10-10', '14:59'))).toEqual([]);
    expect(dueReports(atLocal('2026-10-09', '15:00'))).toEqual([]);
    expect(new Date(atLocal('2026-10-10', '15:00')).toISOString()).toBe('2026-10-10T18:00:00.000Z'); // Mendoza = UTC-3
    expect(local(atLocal('2026-10-10', '15:00')).weekday).toBe(6);
  });
  it('REPORT-MAIL-12 mensual: mes CALENDARIO, al cierre (último día, hora configurable)', () => {
    const d = dueReports(atLocal('2026-10-31', '23:30'));
    expect(d.find(x => x.type === 'MONTHLY').sel).toEqual({ kind: 'MONTHLY', year: 2026, month: 10 });
    expect(dueReports(atLocal('2026-10-30', '23:30')).some(x => x.type === 'MONTHLY')).toBe(false);
    expect(dueReports(atLocal('2026-10-31', '22:00'), { monthly_time: '22:00' }).some(x => x.type === 'MONTHLY')).toBe(true);
    const p = period({ kind: 'MONTHLY', year: 2026, month: 2 });
    expect([p.start, p.end, p.days]).toEqual(['2026-02-01', '2026-02-28', 28]);
  });
  it('REPORT-MAIL-13 filtro MES selecciona un mes específico (no "últimos 30 días")', () => {
    const p = period({ kind: 'MONTH', year: 2026, month: 9 }, atLocal('2026-10-10', '12:00'));
    expect([p.start, p.end, p.days, p.label]).toEqual(['2026-09-01', '2026-09-30', 30, 'Septiembre 2026']);
  });
  it('REPORT-MAIL-14 filtro LIBRE respeta Desde/Hasta y muestra los días', () => {
    const p = period({ kind: 'FREE', from: '2026-10-06', to: '2026-10-06' });
    expect([p.start, p.end, p.days]).toEqual(['2026-10-06', '2026-10-06', 1]);
    expect(buildReport({ routes: ROUTES, costs: COSTS, sel: { kind: 'FREE', from: '2026-10-06', to: '2026-10-06' }, now: NOW }).inputs.routes_counted).toEqual(['CTE-1']);
    expect(() => period({ kind: 'FREE', from: '2026-10-07', to: '2026-10-06' })).toThrow('Período inválido');
  });
  it('7 y 15 días incluyen hoy', () => {
    const n = atLocal('2026-10-10', '12:00');
    expect([period({ kind: '7D' }, n).start, period({ kind: '15D' }, n).start]).toEqual(['2026-10-04', '2026-09-26']);
  });
  it('REPORT-MAIL-15 costo proporcional: mes completo = costo mensual; 7 días de octubre = 1.600.000 × 7/31', () => {
    expect(costForPeriod(COSTS, '2026-09-01', '2026-09-30')).toBe(1600000);
    expect(costForPeriod(COSTS, '2026-10-04', '2026-10-10')).toBe(Math.round(1600000 * 7 / 31 * 100) / 100);
    // Cruza meses: 30/09 (1/30) + 01/10 (1/31)
    expect(costForPeriod(COSTS, '2026-09-30', '2026-10-01')).toBe(Math.round((1600000 / 30 + 1600000 / 31) * 100) / 100);
    // Con cambio de vigencia a mitad de mes
    const two = [{ monthly_cost: 1600000, valid_from: '2026-01-01', valid_to: '2026-10-15' }, { monthly_cost: 2000000, valid_from: '2026-10-16', valid_to: null }];
    expect(costForPeriod(two, '2026-10-01', '2026-10-31')).toBe(Math.round((1600000 * 15 / 31 + 2000000 * 16 / 31) * 100) / 100);
    expect(WEEK.coverage.cost).toBe(Math.round(1600000 * 7 / 31 * 100) / 100); // semanal = 7 días
  });
  it('CUBRE / NO CUBRE con Sobran / Faltan', () => {
    expect(WEEK.coverage.verdict).toBe('NO CUBRE EL COSTO'); expect(WEEK.coverage.text).toMatch(/^Faltan \$ /);
    const cheap = buildReport({ routes: ROUTES, costs: [{ monthly_cost: 31000, valid_from: '2026-01-01' }], sel: { kind: 'WEEKLY', saturday: '2026-10-10' }, now: NOW });
    expect(cheap.coverage.verdict).toBe('CUBRE EL COSTO'); expect(cheap.coverage.text).toMatch(/^Sobran \$ /);
  });
});

describe('Informe — clientes y zonas', () => {
  const rep = buildReport({ routes: demoRoutes(), costs: DEMO_COSTS, sel: { kind: 'MONTH', year: 2026, month: 9 }, now: atLocal('2026-10-10', '12:00') });
  it('Prioridad por frecuencia propia (no solo 30/60/90): compra cada 7 y lleva 25 > compra cada 30 y lleva 35', () => {
    expect(recoveryStatus(25, 7)).toBe('CONTACTAR HOY');
    expect(recoveryStatus(35, 30)).toBe(null);
    expect([recoveryStatus(16, 7), recoveryStatus(11, 7), recoveryStatus(9, 7)]).toEqual(['RECUPERAR', 'ATRASADO', 'SEGUIMIENTO']);
  });
  it('Clientes a recuperar traen zona, última compra, días, frecuencia, compras 90 días, desvío y acción', () => {
    expect(rep.recover.length).toBeGreaterThan(0);
    expect(Object.keys(rep.recover[0]).sort()).toEqual(['action', 'client', 'days_since', 'deviation', 'freq', 'last', 'purchases_90', 'ratio', 'status', 'zone'].sort());
    expect(rep.recover[0].status).toBe('CONTACTAR HOY');
  });
  it('Alertas +30 / +60 / +90 días cuantificadas', () => expect(Object.keys(rep.alerts)).toEqual(['over30', 'over60', 'over90']));
  it('Mejores clientes: compras, frecuencia, última compra, facturación (sin margen ni rentabilidad)', () => {
    expect(rep.best_clients[0]).toMatchObject({ purchases: expect.any(Number), last: expect.any(String), amount: expect.any(Number) });
    expect(JSON.stringify(rep.best_clients)).not.toMatch(/margen|rentab/i);
  });
  it('Zonas a reforzar: una conclusión explicada por zona (sin score opaco)', () => {
    expect(rep.reinforce.map(r => r.zone)).toEqual(['ESTE', 'ALREDEDORES', 'CENTRO']);
    rep.reinforce.forEach(r => { expect(['REFORZAR REPARTO', 'RECUPERAR COMERCIALMENTE', 'MANTENER']).toContain(r.decision); expect(r.why.length).toBeGreaterThan(10); });
  });
  it('Decisiones comerciales: de 3 a 5', () => { expect(rep.decisions.length).toBeGreaterThanOrEqual(3); expect(rep.decisions.length).toBeLessThanOrEqual(5); });
});

describe('Email del informe', () => {
  const html = emailHtml(WEEK, fileName(WEEK));
  it('Asunto semanal y mensual con el formato aprobado', () => {
    // Fase 2A.1: el asunto usa la ventana real (sábado 15:00 → sábado 15:00), no lunes–sábado
    expect(emailSubject(WEEK)).toBe('OK Despacho · Informe semanal Cristian Torres · cierre 10/10/2026 15:00');
    const m = buildReport({ routes: ROUTES, costs: COSTS, sel: { kind: 'MONTHLY', year: 2026, month: 10 }, now: NOW, type: 'MONTHLY' });
    expect(emailSubject(m)).toBe('OK Despacho · Informe mensual Cristian Torres · Octubre 2026');
    expect(fileName(m)).toBe('Informe_Cristian_Torres_Mensual_2026-10.pdf');
    expect(fileName(WEEK)).toBe('Informe_Cristian_Torres_Semanal_2026-10-10.pdf');
  });
  it('Encabezado, resumen y nota de entrega parcial', () => {
    // Fase 2A.1: resumen en tarjetas según el modelo de email aprobado
    ['OK ACCESORIOS · INFORME AUTOMÁTICO', 'Informe semanal · Cristian Torres', 'Envíos completados', '>5<', 'No entregados', '>1<', 'Reprogramados', 'Entrega parcial se contabiliza como completada.'].forEach(t => expect(html).toContain(t));
  });
  it('Tabla por zona con Este, Alrededores, Centro y TOTAL separados', () => ['Zona Este', 'Alrededores', 'Centro', '<b>TOTAL</b>'].forEach(t => expect(html).toContain(t)));
  it('Email: decisiones, clientes a recuperar con prioridad y adjunto', () => ['Decisiones sugeridas', 'Clientes a recuperar · prioridad', '📎', 'OK Despacho · Informe generado automáticamente'].forEach(t => expect(html).toContain(t)));
  it('REPORT-MAIL-16 el email muestra CUBRE / NO CUBRE', () => { expect(html).toContain('NO CUBRE EL COSTO'); expect(html).toContain('Costo Cristian del período'); expect(html).toContain('¿El transporte se paga solo?'); });
  it('REPORT-MAIL-17 el email contiene los principales clientes a recuperar (máx. 5)', () => {
    const rep = buildReport({ routes: demoRoutes(), costs: DEMO_COSTS, sel: { kind: 'WEEKLY', saturday: '2026-10-10' }, now: NOW, type: 'WEEKLY' });
    const h = emailHtml(rep, 'x.pdf');
    expect(h).toContain('Clientes a recuperar'); rep.recover.slice(0, 5).forEach(c => expect(h).toContain(c.client));
    if (rep.recover.length > 5) expect(h).not.toContain('>' + rep.recover[5].client + '<');
  });
  it('REPORT-MAIL-18 el email contiene los mejores clientes', () => { expect(html).toContain('Mejores clientes'); expect(html).toContain('Todo Móvil'); });
  it('REPORT-MAIL-19 el email contiene zonas a reforzar', () => { expect(html).toContain('Zonas a reforzar'); expect(html).toMatch(/MANTENER|REFORZAR REPARTO|RECUPERAR COMERCIALMENTE/); });
  it('REPORT-MAIL-20 el ingreso de transporte NO incluye cobranzas de mercadería', () => {
    expect(WEEK.total.income).toBe(49000); // 5 envíos completados; la mercadería cobrada (500.000) no suma
    expect(html).toContain('$ 49.000'); expect(html).not.toContain('$ 549.000');
  });
  it('Email compatible: sin JavaScript, sin fuentes externas, ancho máximo 700 px, adjunto nombrado', () => {
    expect(html).not.toMatch(/<script|@import|fonts\.googleapis|<link /i); expect(html).toContain('max-width:700px'); expect(html).toContain('Informe_Cristian_Torres_Semanal_2026-10-10.pdf');
  });
  it('REPORT-MAIL-21 clave de idempotencia = tipo + desde + hasta + destinatario + versión', () => {
    expect(emailKey('WEEKLY', '2026-10-05', '2026-10-10', 'Admin@OK.com', 1)).toBe('WEEKLY|2026-10-05|2026-10-10|admin@ok.com|v1');
    expect(emailKey('WEEKLY', '2026-10-05', '2026-10-10', 'admin@ok.com', 1, 2)).toBe('WEEKLY|2026-10-05|2026-10-10|admin@ok.com|v1|reenvio-2');
  });
});

describe('Fase 2A.1 — semanal con una sola convención (WEEK) y envío provisorio', () => {
  const W = WEEK, html = emailHtml(WEEK, fileName(WEEK));
  it('WEEK-01 ventana exacta sábado 15:00 → sábado 15:00 (Mendoza)', () => {
    expect([W.period.from, W.period.to]).toEqual(['2026-10-03T18:00:00.000Z', '2026-10-10T18:00:00.000Z']);
    expect([W.period.start, W.period.end, W.period.days]).toEqual(['2026-10-03', '2026-10-10', 7]);
  });
  it('WEEK-02 el asunto coincide con la ventana real', () => expect(emailSubject(W)).toContain('cierre 10/10/2026 15:00'));
  it('WEEK-03 el cuerpo coincide con la ventana real (sin lunes–sábado)', () => { expect(html).toContain('Ventana analizada: 03/10/2026 15:00 al 10/10/2026 15:00'); expect(html).not.toContain('05/10/2026'); });
  it('WEEK-05 el historial guarda la ventana real (período 03/10 a 10/10)', () => expect([W.period.start, W.period.end, W.period.window]).toEqual(['2026-10-03', '2026-10-10', '03/10/2026 15:00 al 10/10/2026 15:00']));
  it('WEEK-06 finalización sábado 16:00 entra al informe siguiente', () => {
    const next = buildReport({ routes: ROUTES, costs: COSTS, sel: { kind: 'WEEKLY', saturday: '2026-10-17' }, now: atLocal('2026-10-17', '15:00'), type: 'WEEKLY' });
    expect(W.inputs.routes_counted).not.toContain('CTE-2'); expect(next.inputs.routes_counted).toEqual(['CTE-2']);
  });
  it('WEEK-07/08 ventanas consecutivas sin huecos ni doble conteo', () => {
    const all = demoRoutes(); const sats = ['2026-09-19', '2026-09-26', '2026-10-03', '2026-10-10'];
    const reps = sats.map(sat => buildReport({ routes: all, costs: COSTS, sel: { kind: 'WEEKLY', saturday: sat }, now: atLocal(sat, '15:00'), type: 'WEEKLY' }));
    for (let i = 1; i < reps.length; i++) expect(reps[i].period.from).toBe(reps[i - 1].period.to); // sin huecos
    const counted = reps.flatMap(r => r.inputs.routes_counted); expect(new Set(counted).size).toBe(counted.length); // sin doble conteo
    const direct = all.filter(r => r.operational_status === 'COMPLETADA' && Date.parse(r.completed_at) >= Date.parse(reps[0].period.from) && Date.parse(r.completed_at) < Date.parse(reps[3].period.to)).length;
    expect(counted.length).toBe(direct);
  });
  it('ENV-ON-25 el informe no usa un costo de envío provisorio sin confirmar', () => {
    const r = [{ id: 'x', number: 'CTA-9', carrier_id: 'CT-ALR', operational_status: 'COMPLETADA', completed_at: at('2026-10-06', '18:00'), stops: [
      stop('Moran', 'CENTRO', 'ENTREGADO', 10000, { shipping_fee_source: 'PENDING_CONFIRMATION' }), stop('Otro', 'CENTRO', 'ENTREGADO', 7000, { shipping_fee_source: 'CONFIRMED_FALLBACK' })] }];
    const rep = buildReport({ routes: r, costs: COSTS, sel: { kind: 'WEEKLY', saturday: '2026-10-10' }, now: NOW });
    expect(rep.total.income).toBe(7000); expect(rep.inputs.fees_excluded_pending).toBe(1);
  });
});

