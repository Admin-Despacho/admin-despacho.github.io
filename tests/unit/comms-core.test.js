// Comunicaciones · lógica compartida: programación (hora argentina), destinatarios, sanitización, MIME, adjuntos y errores. Datos ficticios.
import { describe, it, expect } from 'vitest';
import { zonedToUtc, localParts, occurrencesBetween, nextRuns, validateSchedule, describeSchedule, resolveRecipients, sanitizeHtml, htmlToText, whatsappText,
  buildMime, estimateEmailBytes, sniffType, validateAttachment, ATTACH, classifyGmailError, backoffSeconds, isoWeekday } from '../../supabase/functions/_shared/comms-core.js';

const iso = t => new Date(t).toISOString();
const ART = (date, time) => zonedToUtc(date, time);

describe('Programación en hora de Argentina', () => {
  it('CC-01 09:00 en Buenos Aires = 12:00 UTC; 22:30 = 01:30 UTC del DÍA SIGUIENTE (cambio de fecha)', () => {
    expect(iso(ART('2026-11-02', '09:00'))).toBe('2026-11-02T12:00:00.000Z');
    expect(iso(ART('2026-11-02', '22:30'))).toBe('2026-11-03T01:30:00.000Z');
    expect(localParts(Date.parse('2026-11-03T01:30:00Z'))).toMatchObject({ date: '2026-11-02', time: '22:30' });
  });
  it('CC-02 semanal "todos los lunes 9:00": las próximas son lunes a las 9:00 locales', () => {
    const s = { kind: 'WEEKLY', time: '09:00', start_date: '2026-11-01', weekdays: [1] };
    const r = nextRuns(s, Date.parse('2026-10-29T15:00:00Z'), 3).map(t => localParts(t));
    expect(r.map(p => p.date + ' ' + p.time)).toEqual(['2026-11-02 09:00', '2026-11-09 09:00', '2026-11-16 09:00']);
    expect(r.every(p => isoWeekday(p.date) === 1)).toBe(true);
  });
  it('CC-03 semanal a las 22:30 el lunes: el día se evalúa en hora LOCAL (no UTC, que ya es martes)', () => {
    const r = nextRuns({ kind: 'WEEKLY', time: '22:30', start_date: '2026-11-01', weekdays: [1] }, Date.parse('2026-11-01T00:00:00Z'), 2);
    expect(r.map(iso)).toEqual(['2026-11-03T01:30:00.000Z', '2026-11-10T01:30:00.000Z']);
  });
  it('CC-04 mensual día 31 con "último día del mes" y con "omitir ese mes"', () => {
    const base = { kind: 'MONTHLY', time: '08:00', start_date: '2027-01-01', month_day: 31 };
    expect(nextRuns({ ...base, month_missing: 'LAST_DAY' }, Date.parse('2027-01-01T00:00:00Z'), 4).map(t => localParts(t).date)).toEqual(['2027-01-31', '2027-02-28', '2027-03-31', '2027-04-30']);
    expect(nextRuns({ ...base, month_missing: 'SKIP' }, Date.parse('2027-01-01T00:00:00Z'), 3).map(t => localParts(t).date)).toEqual(['2027-01-31', '2027-03-31', '2027-05-31']);
    expect(validateSchedule({ ...base })[0]).toMatch(/último día del mes/);   // sin regla explícita: no se acepta
  });
  it('CC-05 diario con fecha de fin; único; ventana (desde, hasta] sin repetir la ejecución de "desde"', () => {
    const d = { kind: 'DAILY', time: '07:15', start_date: '2026-11-02', end_date: '2026-11-04' };
    expect(nextRuns(d, 0, 10).map(t => localParts(t).date)).toEqual(['2026-11-02', '2026-11-03', '2026-11-04']);
    const t2 = ART('2026-11-02', '07:15');
    expect(occurrencesBetween(d, t2, ART('2026-11-03', '07:15')).map(iso)).toEqual([iso(ART('2026-11-03', '07:15'))]);
    expect(nextRuns({ kind: 'ONCE', time: '10:00', start_date: '2026-12-01' }, 0, 5).map(iso)).toEqual(['2026-12-01T13:00:00.000Z']);
    expect(describeSchedule({ kind: 'WEEKLY', time: '09:00', start_date: '2026-11-02', weekdays: [1] })).toMatch(/Cada lunes a las 09:00 \(hora de Argentina\)/);
  });
});

describe('Destinatarios', () => {
  const C = [
    { id: 'c1', full_name: 'Ana Díaz', email: 'ana@ejemplo.test', branch: 'Mendoza', sector: 'Ventas', active: true },
    { id: 'c2', full_name: 'Bruno Paz', email: 'bruno@ejemplo.test', branch: 'San Juan', sector: 'Ventas', active: true },
    { id: 'c3', full_name: 'Carla Ruiz', email: 'carla@ejemplo.test', branch: 'Mendoza', sector: 'Depósito', active: false },
    { id: 'c4', full_name: 'Duplicada Ana', email: ' ANA@ejemplo.test ', branch: 'Mendoza', sector: 'Cobranzas', active: true },
    { id: 'c5', full_name: 'Elena Sosa', email: 'elena@ejemplo.test', branch: 'Mendoza', sector: 'Cobranzas', active: true }];
  it('CC-06 varios criterios a la vez: cada persona UNA vez, solo activos, con motivos de exclusión', () => {
    const r = resolveRecipients(C, { ids: ['c1'], branches: ['mendoza'], sectors: ['Ventas'] });
    expect(r.list.map(x => x.collaborator_id)).toEqual(['c1', 'c2', 'c5']);
    expect(r.list.find(x => x.collaborator_id === 'c1').matched_by).toEqual(['individual', 'sucursal Mendoza', 'sector Ventas']);
    expect(r.excluded).toEqual([{ id: 'c3', name: 'Carla Ruiz', reason: 'Inactivo' }, { id: 'c4', name: 'Duplicada Ana', reason: 'Mismo correo que Ana Díaz' }]);
  });
  it('CC-07 "todos los activos"', () => {
    expect(resolveRecipients(C, { all: true }).list.map(x => x.email)).toEqual(['ana@ejemplo.test', 'bruno@ejemplo.test', 'elena@ejemplo.test']);
  });
});

describe('Texto con formato', () => {
  it('CC-08 sanitización: sin scripts, eventos, estilos ni enlaces javascript:; conserva el formato permitido', () => {
    const dirty = '<p onclick="x()">Hola <b>equipo</b><script>alert(1)</script><img src=x onerror=alert(2)></p><a href="javascript:alert(3)">mal</a> <a href="https://ok.test/a?b=1&c=2">bien</a>' +
      '<style>p{}</style><iframe src="x"></iframe><a href=" jav&#x09;ascript:alert(4)">x</a><svg><script>alert(5)</script></svg><p style="color:red">rojo</p><ul><li>uno</li></ul>';
    const s = sanitizeHtml(dirty);
    expect(s).not.toMatch(/script|onerror|onclick|javascript|style|iframe|<img|<svg|alert\(/i);
    expect(s).toContain('<b>equipo</b>'); expect(s).toContain('<a href="https://ok.test/a?b=1&amp;c=2" target="_blank" rel="noopener noreferrer">bien</a>');
    expect(s).toContain('<p>rojo</p>'); expect(s).toContain('<ul><li>uno</li></ul>');
    expect(sanitizeHtml('<b>sin cerrar')).toBe('<b>sin cerrar</b>');
  });
  it('CC-09 texto para WhatsApp con negrita/cursiva/viñetas y enlaces visibles', () => {
    const t = whatsappText({ subject: 'Normas de cobro', body_html: '<p>Recordá: <b>cobrar en efectivo</b> y <i>emitir recibo</i>.</p><ul><li>Uno</li><li>Dos</li></ul><p><a href="https://ok.test/normas">ver normas</a></p>' });
    expect(t).toBe('*Normas de cobro*\n\nRecordá: *cobrar en efectivo* y _emitir recibo_.\n\n• Uno\n• Dos\n\nver normas (https://ok.test/normas)');
  });
});

describe('Correo y adjuntos', () => {
  it('CC-10 MIME: UN solo "Para" (sin CC/CCO de otros), HTML sanitizado y adjunto en base64', () => {
    const png = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3]);
    const raw = buildMime({ from: 'comunicados.qa@gmail.com', fromName: 'OK Accesorios', to: 'ana@ejemplo.test', toName: 'Ana Díaz', subject: 'Normas de cobro ✔',
      html: '<p>Hola<script>x</script></p>', attachments: [{ name: 'infografia.png', mime: 'image/png', bytes: png }], boundary: 'B1' });
    expect(raw.match(/^To: /gm)).toHaveLength(1); expect(raw).not.toMatch(/^(Cc|Bcc):/mi);
    expect(raw).toContain('To: =?UTF-8?B?'); expect(raw).toContain('<ana@ejemplo.test>');
    expect(raw).toMatch(/Subject: =\?UTF-8\?B\?/); expect(raw).toContain('Content-Disposition: attachment; filename="infografia.png"');
    const htmlPart = raw.split('Content-Type: text/html; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n')[1].split('--alt-B1')[0].replace(/\r\n/g, '');
    expect(Buffer.from(htmlPart, 'base64').toString('utf8')).not.toMatch(/script/);
    expect(() => buildMime({ from: 'a@gmail.com', to: 'no-es-correo', subject: 'x', html: '' })).toThrow(/Destinatario inválido/);
  });
  it('CC-11 tamaño FINAL estimado (base64 +33 %) y límites visibles por archivo y total', () => {
    const est = estimateEmailBytes({ subject: 'x', html: '<p>hola</p>', attachments: [{ size_bytes: 9 * 1024 * 1024 }] });
    expect(est).toBeGreaterThan(9 * 1024 * 1024 * 4 / 3); expect(est).toBeLessThan(ATTACH.gmailMaxEmailBytes);
    expect(estimateEmailBytes({ html: '', attachments: [{ size_bytes: ATTACH.maxTotalBytes }] })).toBeLessThan(ATTACH.gmailMaxEmailBytes);   // el máximo permitido entra en 25 MB
    expect(validateAttachment({ name: 'a.pdf', mime: 'application/pdf', size: 9 * 1024 * 1024 })[0]).toMatch(/supera 8,0 MB por archivo/);
    expect(validateAttachment({ name: 'b.pdf', mime: 'application/pdf', size: 7 * 1024 * 1024 }, [{ size_bytes: 7 * 1024 * 1024 }, { size_bytes: 2 * 1024 * 1024 }])[0]).toMatch(/máximo es 15 MB/);
  });
  it('CC-12 el tipo se valida por el CONTENIDO (un .exe renombrado a .pdf se rechaza)', () => {
    expect(sniffType(new Uint8Array([0x25, 0x50, 0x44, 0x46, 0x2d, 0x31]))).toBe('application/pdf');
    const exe = new Uint8Array([0x4d, 0x5a, 0x90, 0x00]);
    expect(sniffType(exe)).toBeNull();
    expect(validateAttachment({ name: 'virus.pdf', mime: 'application/pdf', sniffed: sniffType(exe), size: 10 })[0]).toMatch(/no coincide/);
    expect(validateAttachment({ name: 'x.docx', mime: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document', size: 10 })[0]).toMatch(/solo se aceptan/);
  });
});

describe('Errores de Gmail', () => {
  it('CC-13 clasificación: reconectar, reintentar, permanente y AMBIGUO (respuesta perdida tras enviar)', () => {
    expect(classifyGmailError({ status: 400, reason: 'invalid_grant' })).toBe('AUTH');
    expect(classifyGmailError({ status: 401 })).toBe('AUTH');
    expect(classifyGmailError({ status: 403, reason: 'insufficientPermissions' })).toBe('AUTH');
    expect(classifyGmailError({ status: 429 })).toBe('RETRYABLE');
    expect(classifyGmailError({ status: 403, reason: 'userRateLimitExceeded' })).toBe('RETRYABLE');
    expect(classifyGmailError({ status: 503 })).toBe('RETRYABLE');
    expect(classifyGmailError({ status: 400, reason: 'Invalid To header' })).toBe('PERMANENT');
    expect(classifyGmailError({ phase: 'AFTER_SEND', reason: 'connection reset' })).toBe('AMBIGUOUS');
    expect([1, 2, 3, 4, 5].map(backoffSeconds)).toEqual([60, 240, 960, 3600, 3600]);
  });
});
