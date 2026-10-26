// PDF liviano del informe (pdf-lib, sin mapas ni imágenes pesadas). Se genera SIEMPRE desde el snapshot guardado,
// así un PDF viejo no cambia si después cambian el costo o las tarifas.
import { PDFDocument, StandardFonts, rgb } from 'pdf-lib';
import { ZONE_LABEL, money, dmy } from './report-engine.js';
import { emailSubject, periodText } from './report-email.js';

const INK = rgb(0, 14 / 255, 24 / 255), CYAN = rgb(0, 230 / 255, 254 / 255), MUTED = rgb(93 / 255, 109 / 255, 120 / 255), LINE = rgb(220 / 255, 227 / 255, 232 / 255);
const OK = rgb(15 / 255, 138 / 255, 95 / 255), ERR = rgb(180 / 255, 35 / 255, 24 / 255);

export async function reportPdf(rep) {
  const doc = await PDFDocument.create();
  doc.setTitle(emailSubject(rep)); doc.setAuthor('OK Despacho'); doc.setCreationDate(new Date(rep.generated_at));
  const font = await doc.embedFont(StandardFonts.Helvetica), bold = await doc.embedFont(StandardFonts.HelveticaBold);
  const W = 595.28, H = 841.89, M = 40;
  let page, y;
  const newPage = () => {
    page = doc.addPage([W, H]);
    page.drawRectangle({ x: 0, y: H - 64, width: W, height: 64, color: INK });
    page.drawRectangle({ x: 0, y: H - 67, width: W, height: 3, color: CYAN });
    page.drawText('OK ACCESORIOS', { x: M, y: H - 32, size: 15, font: bold, color: rgb(1, 1, 1) });
    page.drawText('INFORME CRISTIAN TORRES · ' + (rep.type === 'MONTHLY' ? 'MENSUAL' : rep.type === 'WEEKLY' ? 'SEMANAL' : 'MANUAL'), { x: M, y: H - 50, size: 9.5, font, color: CYAN });
    const pt = periodText(rep);
    page.drawText(pt, { x: W - M - font.widthOfTextAtSize(pt, 9.5), y: H - 50, size: 9.5, font, color: rgb(1, 1, 1) });
    y = H - 90;
  };
  const need = h => { if (y - h < 50) newPage(); };
  // texto que no entra en el ancho útil pasa a la línea siguiente (nunca se sale de la página)
  const text = (t, o = {}) => { const sz = o.size || 9.5, f = o.bold ? bold : font, x = o.x || M, ls = wrap(String(t), W - M - x, sz, f);
    ls.forEach((ln, i) => { need(sz + 6); page.drawText(ln, { x, y, size: sz, font: f, color: o.color || INK }); y -= i < ls.length - 1 ? sz + 3 : (o.gap || 14); }); };
  const wrap = (t, width, size, f = font) => {
    const words = String(t).split(' '), lines = []; let cur = '';
    for (const w of words) { const n = cur ? cur + ' ' + w : w; if (f.widthOfTextAtSize(n, size) > width && cur) { lines.push(cur); cur = w; } else cur = n; }
    if (cur) lines.push(cur); return lines;
  };
  const section = (n, t) => { need(30); y -= 6; page.drawText(n + '. ' + t, { x: M, y, size: 11, font: bold, color: INK }); y -= 4; page.drawRectangle({ x: M, y: y - 2, width: W - 2 * M, height: 0.8, color: CYAN }); y -= 16; };
  // Tabla simple con ajuste de texto
  const tableRows = (cols, rows) => {
    const size = 8.6, x0 = M;
    const drawRow = (cells, isHead) => {
      const lines = cells.map((c, i) => wrap(c, cols[i].w - 6, size, isHead ? bold : font));
      const h = Math.max(...lines.map(l => l.length)) * 11 + 6;
      need(h + 2);
      if (isHead) page.drawRectangle({ x: x0, y: y - h + 9, width: W - 2 * M, height: h, color: INK });
      let x = x0;
      lines.forEach((ls, i) => {
        ls.forEach((l, j) => {
          const w = (isHead ? bold : font).widthOfTextAtSize(l, size);
          page.drawText(l, { x: cols[i].right ? x + cols[i].w - 4 - w : x + 3, y: y - j * 11, size, font: isHead ? bold : font, color: isHead ? rgb(1, 1, 1) : INK });
        });
        x += cols[i].w;
      });
      y -= h; if (!isHead) page.drawRectangle({ x: x0, y: y + 7, width: W - 2 * M, height: 0.5, color: LINE });
    };
    drawRow(cols.map(c => c.t), true);
    rows.forEach(r => drawRow(r, false));
    y -= 8;
  };

  newPage();
  section(1, 'PERÍODO');
  text(rep.period.window ? periodText(rep) + ' · ' + rep.period.days + ' días' : rep.period.label + ' · ' + dmy(rep.period.start) + ' al ' + dmy(rep.period.end) + ' · ' + rep.period.days + ' días');
  if (rep.period.cutoff_note) text(rep.period.cutoff_note, { color: MUTED, size: 8.6 });
  // V2 = hojas PUBLICADAS; un informe guardado con la versión 1 se reimprime como se generó (criterio de finalizadas)
  const v2 = rep.criterion === 'HOJAS_PUBLICADAS';
  if (v2) {
    text('Fecha que manda: PUBLICACIÓN de la hoja (America/Argentina/Mendoza). Hojas publicadas: pendientes, en curso o finalizadas. Sin borradores ni canceladas.', { color: MUTED, size: 8.6 });
    if ((rep.inputs?.missing_publication || []).length) text('Hojas sin fecha de publicación registrada (NO incluidas): ' + rep.inputs.missing_publication.join(', '), { color: ERR, size: 8.6 });
    section(2, 'ENVÍOS INCLUIDOS Y SU ESTADO');
    text('ENVÍOS INCLUIDOS: ' + rep.summary.shipments + '      PENDIENTES: ' + rep.summary.pending + '      ENTREGADOS: ' + rep.summary.delivered + '      NO ENTREGADOS: ' + rep.summary.not_delivered + '      REPROGRAMADOS: ' + rep.summary.rescheduled, { bold: true });
    text(rep.summary.note, { color: MUTED, size: 8.6 });
    section('3-6', 'ESTE · ALREDEDORES · CENTRO · IMPORTE DE ENVÍO INFORMADO');
    // columnas = ancho útil exacto (595 − 2×40 = 515): importes grandes entran en una línea
    const zc = [{ t: 'Zona', w: 95 }, { t: 'Envíos', w: 48, right: true }, { t: 'Pendientes', w: 58, right: true }, { t: 'Entregados', w: 58, right: true }, { t: 'No entreg.', w: 55, right: true }, { t: 'Reprog.', w: 50, right: true }, { t: 'Importe', w: 85, right: true }, { t: 'Promedio', w: 66, right: true }];
    tableRows(zc, rep.zones.map(z => [ZONE_LABEL[z.zone], String(z.shipments), String(z.pending), String(z.delivered), String(z.not_delivered), String(z.rescheduled), money(z.income), money(z.avg)])
      .concat([['TOTAL GENERAL', String(rep.total.shipments), String(rep.total.pending), String(rep.total.delivered), String(rep.total.not_delivered), String(rep.total.rescheduled), money(rep.total.income), money(rep.total.avg)]]));
  } else {
    text('Fecha que manda: finalización real de la hoja (America/Argentina/Mendoza). Solo hojas FINALIZADAS.', { color: MUTED, size: 8.6 });
    section(2, 'COMPLETADOS · NO ENTREGADOS · REPROGRAMADOS');
    text('ENVÍOS COMPLETADOS: ' + rep.summary.completed + '      NO ENTREGADOS: ' + rep.summary.not_delivered + '      REPROGRAMADOS: ' + rep.summary.rescheduled, { bold: true });
    text(rep.summary.note, { color: MUTED, size: 8.6 });
    section('3-6', 'ESTE · ALREDEDORES · CENTRO · INGRESOS');
    const zc = [{ t: 'Zona', w: 150 }, { t: 'Completados', w: 80, right: true }, { t: 'No entregados', w: 85, right: true }, { t: 'Reprogramados', w: 85, right: true }, { t: 'Ingreso envíos', w: 70, right: true }, { t: 'Promedio', w: 45, right: true }];
    tableRows(zc, rep.zones.map(z => [ZONE_LABEL[z.zone], String(z.completed), String(z.not_delivered), String(z.rescheduled), money(z.income), money(z.avg)])
      .concat([['TOTAL GENERAL', String(rep.total.completed), String(rep.total.not_delivered), String(rep.total.rescheduled), money(rep.total.income), money(rep.total.avg)]]));
  }

  section('7-8', 'COSTO Y RESULTADO · ¿EL TRANSPORTE SE PAGA SOLO?');
  const c = rep.coverage;
  [['Ingreso Zona Este', money(c.income_by_zone.ESTE)], ['Ingreso Alrededores', money(c.income_by_zone.ALREDEDORES)], ['Ingreso Centro', money(c.income_by_zone.CENTRO)],
   [v2 ? 'Importe de envíos informado (no es dinero cobrado)' : 'Ingreso total de envíos', money(c.income)], ['Costo Cristian del período', money(c.cost)], ['Diferencia', (c.diff >= 0 ? '+' : '-') + money(Math.abs(c.diff))]]
    .forEach(([k, v]) => {
      // el rótulo usa solo el ancho libre a la izquierda del importe y pasa a otra línea si no entra (nunca lo pisa)
      const vw = bold.widthOfTextAtSize(v, 9.5), right = M + 330, room = right - vw - 14 - M, lines = [];
      for (const w of String(k).split(' ')) { const cur = lines.length ? lines[lines.length - 1] : null;
        if (cur !== null && font.widthOfTextAtSize(cur + ' ' + w, 9.5) <= room) lines[lines.length - 1] = cur + ' ' + w; else lines.push(w); }
      need(14 * lines.length);
      page.drawText(v, { x: right - vw, y, size: 9.5, font: bold, color: INK });
      lines.forEach((ln, i) => page.drawText(ln, { x: M, y: y - i * 12, size: 9.5, font, color: MUTED }));
      y -= 14 + (lines.length - 1) * 12;
    });
  y -= 4; text(c.verdict + ' · ' + c.text, { bold: true, size: 12, color: c.covers ? OK : ERR, gap: 18 });
  text('Costo prorrateado por día: cada día vale costo mensual / días de ese mes.', { color: MUTED, size: 8.6 });

  section(9, 'MEJORES CLIENTES');
  if (rep.best_clients.length) tableRows([{ t: 'Cliente', w: 190 }, { t: 'Compras', w: 60, right: true }, { t: 'Frecuencia', w: 90 }, { t: 'Última compra', w: 80 }, { t: 'Facturación*', w: 95, right: true }],
    rep.best_clients.map(b => [b.client, String(b.purchases), b.freq ? 'cada ' + Math.round(b.freq) + ' días' : '—', dmy(b.last), money(b.amount)]));
  else text('Sin compras en el período.', { color: MUTED });
  text(v2 ? '* Mercadería de los envíos de hojas publicadas (compra = envío publicado). No es rentabilidad ni margen.' : '* Mercadería de entregas completadas en hojas finalizadas. No es rentabilidad ni margen.', { color: MUTED, size: 8 });

  section(10, 'CLIENTES A RECUPERAR');
  text('Alertas de inactividad: +30 días: ' + rep.alerts.over30 + ' · +60 días: ' + rep.alerts.over60 + ' · +90 días: ' + rep.alerts.over90, { size: 9 });
  if (rep.recover.length) tableRows([{ t: 'Cliente', w: 120 }, { t: 'Zona', w: 62 }, { t: 'Última', w: 58 }, { t: 'Días sin', w: 42, right: true }, { t: 'Frec.', w: 40, right: true }, { t: 'Últ. 90 d', w: 42, right: true }, { t: 'Desvío', w: 42, right: true }, { t: 'Acción', w: 109 }],
    rep.recover.map(r => [r.client, ZONE_LABEL[r.zone], dmy(r.last), String(r.days_since), String(Math.round(r.freq)), String(r.purchases_90), '+' + Math.round(r.deviation), r.status]));
  else text('Sin clientes fuera de su frecuencia.', { color: MUTED });

  section(11, 'ZONAS A REFORZAR');
  tableRows([{ t: 'Zona', w: 80 }, { t: 'Conclusión', w: 120 }, { t: 'Por qué', w: 315 }], rep.reinforce.map(r => [ZONE_LABEL[r.zone], r.decision, r.why]));

  section(12, 'DECISIONES SUGERIDAS');
  rep.decisions.forEach(d => wrap('• ' + d, W - 2 * M, 9.5).forEach(l => text(l)));

  const pages = doc.getPages();
  pages.forEach((p, i) => p.drawText('OK Despacho · generado ' + rep.generated_at.slice(0, 16).replace('T', ' ') + ' UTC · Página ' + (i + 1) + ' de ' + pages.length, { x: M, y: 24, size: 7.5, font, color: MUTED }));
  return await doc.save();
}
