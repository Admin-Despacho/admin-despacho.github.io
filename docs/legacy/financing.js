/* =====================================================================
   OK DESPACHO · FINANCIACIÓN PROPIA (Fase 2A.1) — script clásico, sin dependencias.
   Un mismo comprobante puede venir en Saldo Comprobante dividido en partes/cuotas.
   Reglas:
   · Se agrupa por comprobante normalizado + cliente (CUIT o nombre) + importación (source_import_id).
     Nunca por importe solamente y nunca mezclando importaciones distintas.
   · Duplicado EXACTO (mismos fecha, vencimiento, cuota, importes y saldo) → se cuenta una sola vez.
   · Partes reales: se distinguen por vencimiento o número de cuota → se SUMAN los saldos pendientes.
   · Si hay varias filas que no se pueden distinguir (mismo vencimiento/cuota pero distinto saldo)
     → POSIBLE FINANCIACIÓN PROPIA · REVISAR y NO se suma.
   Estados: NORMAL · FINANCIACION_PROPIA_VIGENTE · FINANCIACION_PROPIA_SALDADA · POSIBLE_FINANCIACION_REVISAR
   ===================================================================== */
(function (root) {
  'use strict';
  var RESOLVER_VERSION = 'fin-1';
  var r2 = function (n) { return Math.round((Number(n) || 0) * 100) / 100; };
  var key = function (v) { return v == null ? '' : String(v); };
  var exactKey = function (r) { return [key(r.d), key(r.due), key(r.q), key(r.m), key(r.s), key(r.ve), key(r.co)].join('|'); };
  var partKey = function (r) { return key(r.due) + '#' + key(r.q); };

  /**
   * rows: filas de UN comprobante normalizado, del mismo cliente y de la misma importación.
   * Devuelve { status, rows (únicas), parts, total, pending, settled, duplicates, label }
   */
  function classify(rows) {
    var seen = {}, uniq = [], dups = 0;
    rows.forEach(function (r) { var k = exactKey(r); if (seen[k]) { dups++; return; } seen[k] = true; uniq.push(r); });
    if (uniq.length === 1) {
      return { status: 'NORMAL', rows: uniq, parts: 1, total: uniq[0].s == null ? null : r2(Math.max(0, uniq[0].s)), pending: (uniq[0].s || 0) > 0.004 ? 1 : 0, settled: (uniq[0].s || 0) > 0.004 ? 0 : 1, duplicates: dups, label: '' };
    }
    // ¿Las filas restantes se distinguen como partes reales (vencimiento o cuota)?
    var pk = {}, ambiguous = false;
    uniq.forEach(function (r) { var k = partKey(r); if (k === '#' || pk[k]) ambiguous = true; pk[k] = true; });
    if (ambiguous) {
      return { status: 'POSIBLE_FINANCIACION_REVISAR', rows: uniq, parts: uniq.length, total: null, pending: null, settled: null, duplicates: dups,
        label: 'POSIBLE FINANCIACIÓN PROPIA · REVISAR' };
    }
    var sorted = uniq.slice().sort(function (a, b) { return key(a.due).localeCompare(key(b.due)) || key(a.q).localeCompare(key(b.q)); });
    var pending = sorted.filter(function (r) { return (r.s || 0) > 0.004; });
    var total = r2(pending.reduce(function (a, r) { return a + r.s; }, 0));
    var st = total > 0.004 ? 'FINANCIACION_PROPIA_VIGENTE' : 'FINANCIACION_PROPIA_SALDADA';
    return { status: st, rows: sorted, parts: sorted.length, total: total, pending: pending.length, settled: sorted.length - pending.length, duplicates: dups,
      label: st === 'FINANCIACION_PROPIA_VIGENTE' ? 'FINANCIACIÓN PROPIA · DEUDA VIGENTE' : 'FINANCIACIÓN PROPIA · SALDADA' };
  }

  /**
   * Agrupa todas las filas de Saldo Comprobante (ya normalizadas: r.n = comprobante normalizado, r.key = cliente).
   * Devuelve { groups: Map(n -> [grupo por cliente]), uniqueRows: filas sin duplicados exactos }
   */
  function groupAll(rows, importId) {
    var by = new Map(), out = new Map(), uniqueRows = [];
    rows.forEach(function (r) {
      var k = r.n + '||' + r.key + '||' + (importId || '');
      if (!by.has(k)) by.set(k, []);
      by.get(k).push(r);
    });
    by.forEach(function (list) {
      var g = classify(list), first = g.rows[0];
      var rec = Object.assign({}, first, {
        s: g.status === 'NORMAL' ? first.s : g.total,
        fin: g.status === 'NORMAL' && !g.duplicates ? null : {
          status: g.status, label: g.label, parts: g.parts, pending: g.pending, settled: g.settled, duplicates: g.duplicates,
          total: g.total, importId: importId || '', resolver: RESOLVER_VERSION,
          rows: g.rows.map(function (r) { return { due: r.due || '', q: r.q || '', s: r.s, m: r.m, d: r.d || '' }; })
        }
      });
      if (!out.has(first.n)) out.set(first.n, []);
      out.get(first.n).push(rec);
      g.rows.forEach(function (r) { uniqueRows.push(r); });
    });
    return { groups: out, uniqueRows: uniqueRows };
  }

  // Texto "6 partes · 4 con saldo · 2 saldadas"
  function partsText(fin) {
    if (!fin || fin.status === 'NORMAL' || fin.status === 'POSIBLE_FINANCIACION_REVISAR') return fin && fin.parts > 1 ? fin.parts + ' filas que no se pueden distinguir' : '';
    return fin.parts + ' partes · ' + fin.pending + ' con saldo · ' + fin.settled + ' saldada' + (fin.settled === 1 ? '' : 's');
  }

  root.OKFinancing = { classify: classify, groupAll: groupAll, partsText: partsText, RESOLVER_VERSION: RESOLVER_VERSION };
})(typeof window !== 'undefined' ? window : globalThis);
