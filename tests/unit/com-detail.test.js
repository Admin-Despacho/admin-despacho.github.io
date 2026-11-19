// Detalle de autorizaciones (presentación): tiempos de espera con datos REALES, formato monetario, calendario en tabla, trazabilidad y temporizador único.
import { describe, it, expect, vi, afterEach } from 'vitest';
import { fmtElapsed, pendingSince, pendingSpan, moneyAR, scheduleTable, timeline, statusBlock, detailView, signature, startWaitTicker, pill, person, diffTerms } from '../../src/online/com-detail.js';

const T0 = '2026-11-18T18:10:00.000Z';
const at = s => new Date(Date.parse(T0) + s * 1000).toISOString();
const req = (status, tl, extra = {}) => ({ id: 'r1', number: 'AUT-000001', kind: 'FINANCIACION', status, client: { razon_social: 'CLIENTE', cuit: '20273692771' }, channel: 'SUCURSAL', branch: 'MONTECASEROS',
  requested_by: 'Ana Pérez — Comercial', assigned_approver: 'Wilfredo Guzmán', created_at: at(0), updated_at: at(0), version: 1,
  current_terms: { amount: 2500000, installments: 4, frequency: 'SEMANAL', schedule: [1, 2, 3, 4].map(n => ({ n, due: '2026-11-2' + n, amount: 625000 })), limit_date: '2026-12-18' },
  timeline: tl, ...extra });
const ENV = [{ seq: 1, kind: 'ENVIADA', by: 'Ana Pérez — Comercial', at: at(0) }, { seq: 2, kind: 'PENDIENTE', by: 'Ana Pérez — Comercial', assigned: 'Wilfredo Guzmán', at: at(0) }];

afterEach(() => vi.useRealTimers());

describe('contador de espera', () => {
  it('formatos pedidos: 00 min 35 seg · 07 min 24 seg · 01 h 15 min', () => {
    expect(fmtElapsed(35e3)).toBe('00 min 35 seg');
    expect(fmtElapsed((7 * 60 + 24) * 1e3)).toBe('07 min 24 seg');
    expect(fmtElapsed((75 * 60 + 9) * 1e3)).toBe('01 h 15 min');
    expect(fmtElapsed((26 * 3600 + 5 * 60) * 1e3)).toBe('1 d 02 h 05 min');
    expect(fmtElapsed(-5000)).toBe('00 min 00 seg');   // reloj del equipo atrasado: nunca negativo
  });
  it('usa el ÚLTIMO ingreso a pendiente registrado (reenvío tras devolución), no la creación', () => {
    const tl = [...ENV, { seq: 3, kind: 'DEVUELTA_CON_MODIFICACIONES', by: 'Wilfredo Guzmán', at: at(300) }, { seq: 4, kind: 'CAMBIOS_ACEPTADOS_REENVIADA', by: 'Ana Pérez — Comercial', at: at(900) }, { seq: 5, kind: 'PENDIENTE', at: at(900) }];
    expect(pendingSince(req('PENDIENTE', tl))).toBe(at(900));
  });
  it('tiempo TOTAL pendiente solo con entrada y salida registradas', () => {
    expect(pendingSpan(req('APROBADA', [...ENV, { seq: 3, kind: 'APROBADA', by: 'Wilfredo Guzmán', at: at(444) }])).ms).toBe(444000);
    expect(pendingSpan(req('APROBADA', [{ seq: 1, kind: 'APROBADA', at: at(10) }]))).toBeNull();   // historia insuficiente: no se inventa
    expect(pendingSpan(req('PENDIENTE', ENV))).toBeNull();
  });
});

describe('formato y calendario', () => {
  it('moneda argentina con decimales solo cuando existen', () => {
    expect(moneyAR(625000)).toBe('$ 625.000'); expect(moneyAR(333333.34)).toBe('$ 333.333,34'); expect(moneyAR(950000.5)).toBe('$ 950.000,50'); expect(moneyAR(null)).toBe('—');
  });
  it('tabla «n de k», vencimiento completo, importe, total y metadatos', () => {
    const h = scheduleTable(req('PENDIENTE', ENV).current_terms.schedule, { frequency: 'SEMANAL', limit: '2026-12-18', total: 2500000 });
    expect(h).toContain('1 de 4'); expect(h).toContain('4 de 4'); expect(h).toContain('<span data-cal-due>21/11/2026</span>'); expect(h).toContain('$ 2.500.000');
    expect(h).toContain('Fecha límite'); expect(h).toContain('18/12/2026'); expect(h).toContain('Semanal'); expect((h.match(/data-cal-row=/g) || []).length).toBe(4);
  });
  it('vista previa con cuota que excede: se marca y conserva la cantidad total', () => {
    const h = scheduleTable([{ n: 1, due: '2026-11-25', amount: 1 }, { n: 2, due: '2026-12-25', amount: 1 }], { mark: 2, count: 3 });
    expect(h).toContain('2 de 3'); expect(h).toContain('data-cal-excede'); expect(h).toContain('SUPERA EL LÍMITE');
  });
});

describe('estado y trazabilidad', () => {
  it('pendiente: bloque amarillo con puntos animados y contador basado en el evento real', () => {
    const h = statusBlock(req('PENDIENTE', ENV));
    expect(h).toContain('Esperando aprobación de Administración'); expect(h).toContain('data-az-dots'); expect(h).toContain('data-wait-since="' + at(0) + '"'); expect(h).toContain('role="timer"');
  });
  it('resuelta: sin puntos ni contador vivo; muestra quién y cuánto estuvo pendiente', () => {
    const h = statusBlock(req('RECHAZADA', [...ENV, { seq: 3, kind: 'RECHAZADA', by: 'Wilfredo Guzmán', at: at(60), reason: 'Saldo vencido' }], { decided_by: 'Wilfredo Guzmán', decided_at: at(60) }));
    expect(h).not.toContain('data-az-dots'); expect(h).not.toContain('data-wait-since'); expect(h).toContain('01 min 00 seg'); expect(h).toContain('Wilfredo Guzmán');
  });
  it('trazabilidad: SOLO eventos registrados + paso futuro rotulado; nunca «En revisión»', () => {
    const h = timeline(req('PENDIENTE', ENV));
    expect((h.match(/class="az-ev /g) || []).length).toBe(3); expect(h).toContain('Resolución pendiente'); expect(h).not.toMatch(/revisi/i);
    expect(h).toContain('Comercial'); expect(h).toContain('Responsable asignado: <b>Wilfredo Guzmán</b>');
    const r = timeline(req('APROBADA', [...ENV, { seq: 3, kind: 'APROBADA', by: 'Wilfredo Guzmán', at: at(60) }]));
    expect(r).not.toContain('Resolución pendiente'); expect(r).toContain('Responsable de aprobación');
  });
  it('estados por texto + icono (no solo color) y escape de datos', () => {
    expect(pill('APROBADA_MOD')).toContain('Aprobada con modificaciones'); expect(pill('DEVUELTA')).toContain('↩');
    const h = detailView(req('PENDIENTE', ENV, { client: { razon_social: '<img src=x onerror=alert(1)>' } }));
    expect(h).not.toContain('<img'); expect(h).toContain('&lt;img');
    expect(person('Gabriela — Administrador General')).toEqual({ name: 'Gabriela', role: 'Administrador General' });
  });
  it('sin el calendario original (permisos de Despacho) no se rotula el autorizado como «solicitado»', () => {
    const h = detailView(req('APROBADA_MOD', ENV, { final_terms: { amount: 2000000, schedule: [{ n: 1, due: '2026-11-25', amount: 2000000 }] } }));
    expect(h).not.toContain('Importe solicitado'); expect(h).toContain('Calendario AUTORIZADO'); expect(h).not.toContain('Calendario SOLICITADO');
  });
});

describe('actualización y temporizador', () => {
  it('la firma cambia solo con cambios reales del servidor', () => {
    const a = req('PENDIENTE', ENV), b = { ...a };
    expect(signature([a])).toBe(signature([b])); expect(signature([a])).not.toBe(signature([{ ...a, status: 'APROBADA', version: 2 }]));
  });
  it('UN intervalo actualiza todos los contadores y se detiene al salir', () => {
    vi.useFakeTimers(); vi.setSystemTime(Date.parse(T0) + 35e3);
    const els = [0, 1].map(() => ({ textContent: '', getAttribute: () => T0 }));
    let alive = true; const t = startWaitTicker({ querySelectorAll: () => els }, () => alive);
    expect(els.map(e => e.textContent)).toEqual(['00 min 35 seg', '00 min 35 seg']);
    vi.advanceTimersByTime(2000); expect(els[0].textContent).toBe('00 min 37 seg');
    alive = false; vi.advanceTimersByTime(1000); expect(t.active).toBe(false); expect(vi.getTimerCount()).toBe(0);
  });
});

describe('comparación solicitado ↔ autorizado (V2)', () => {
  const S = (amts, dues) => amts.map((a, i) => ({ n: i + 1, due: dues[i], amount: a }));
  const o = { amount: 1800000, installments: 2, frequency: 'QUINCENAL', limit_date: '2026-12-18', schedule: S([900000, 900000], ['2026-11-28', '2026-12-13']) };
  it('mismo TOTAL con otra cantidad de cuotas, frecuencia, vencimientos e importes por cuota: se detecta TODO', () => {
    const t = { amount: 1800000, installments: 3, frequency: 'SEMANAL', limit_date: '2026-12-18', schedule: S([600000, 600000, 600000], ['2026-11-25', '2026-12-02', '2026-12-09']) };
    const k = diffTerms('FINANCIACION', o, t).map(c => c.label);
    expect(k).not.toContain('Importe total'); expect(k).toContain('Cantidad de cuotas'); expect(k).toContain('Frecuencia');
    expect(k).toContain('Vencimiento de la cuota 1'); expect(k).toContain('Importe de la cuota 1'); expect(k).toContain('Cuota 3');
  });
  it('mismo total y mismas fechas, otra DISTRIBUCIÓN de pagos', () => {
    const t = { ...o, schedule: S([1000000, 800000], ['2026-11-28', '2026-12-13']) };
    const d = diffTerms('FINANCIACION', o, t);
    expect(d.map(c => c.label)).toEqual(['Importe de la cuota 1', 'Importe de la cuota 2']); expect(d[0].from).toBe('$ 900.000'); expect(d[0].to).toBe('$ 1.000.000');
    const h = scheduleTable(t.schedule, { compare: o.schedule }); expect((h.match(/data-cal-mod="IMPORTE"/g) || []).length).toBe(2); expect(h).toContain('antes $ 900.000');
  });
  it('mismo total, solo cambia el primer vencimiento: celdas de fecha marcadas', () => {
    const t = { ...o, schedule: S([900000, 900000], ['2026-11-30', '2026-12-15']) };
    expect(diffTerms('FINANCIACION', o, t).map(c => c.key)).toEqual(['cuota_due', 'cuota_due']);
    expect((scheduleTable(t.schedule, { compare: o.schedule }).match(/data-cal-mod="VENCIMIENTO"/g) || []).length).toBe(2);
  });
  it('e-cheq con el MISMO importe: cambio de vencimiento y de emisor', () => {
    const a = { amount: 950000.5, due_date: '2026-12-08', issuer_is_client: true, issuer_name: null, issuer_cuit: null };
    const b = { amount: 950000.5, due_date: '2026-12-03', issuer_is_client: false, issuer_name: 'ELECTRO ANDINO S.A.', issuer_cuit: '30715531319' };
    expect(diffTerms('ECHEQ', a, b).map(c => c.label)).toEqual(['Vencimiento del e-cheq', 'Emisor', 'CUIT del emisor']);
    expect(diffTerms('ECHEQ', a, { ...a })).toEqual([]);
  });
  it('cualquier otro dato registrado distinto se informa sin interpretarlo; idéntico → sin cambios', () => {
    expect(diffTerms('FINANCIACION', { ...o, tasa: 0 }, { ...o, tasa: 2 }).map(c => c.key)).toEqual(['otro']);
    expect(diffTerms('FINANCIACION', o, JSON.parse(JSON.stringify(o)))).toEqual([]);
  });
  it('detalle: con permiso completo lista las modificaciones; sin él (Despacho) NO revela lo solicitado', () => {
    const base = { id: 'x', number: 'AUT-9', kind: 'FINANCIACION', status: 'APROBADA_MOD', client: { razon_social: 'C' }, timeline: [], requested_by: 'A — Comercial', assigned_approver: 'W' };
    const t = { ...o, schedule: S([1000000, 800000], ['2026-11-28', '2026-12-13']) };
    const full = detailView({ ...base, original_terms: o, current_terms: t, final_terms: t });
    expect(full).toContain('data-cal-cambios="2"'); expect(full).toContain('Calendario SOLICITADO'); expect(full).toContain('Calendario AUTORIZADO');
    const desp = detailView({ ...base, original_terms: null, current_terms: t, final_terms: t });
    expect(desp).toContain('data-cal-cambios="RESERVADO"'); expect(desp).not.toContain('900.000'); expect(desp).not.toContain('Calendario SOLICITADO');
  });
});
