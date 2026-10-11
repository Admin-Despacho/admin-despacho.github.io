/* ===== ExcelImporter (corre dentro de un Web Worker; también puede correr en el hilo principal) ===== */
var ExcelImporterCore = (function () {
  function norm(s) {
    return String(s == null ? '' : s).normalize('NFD').replace(/[\u0300-\u036f]/g, '')
      .toLowerCase().replace(/[^a-z0-9]/g, '');
  }
  var SYN = {
    pedidos: {
      pedido: ['pedidon', 'pedidono', 'pedidonro', 'npedido', 'nropedido', 'numeropedido', 'pedidonumero', 'pedido'],
      fecha: ['fecha', 'fechapedido'],
      vendedor: ['vendedor'],
      estado: ['estado', 'estadopedido'],
      cliente: ['cliente', 'razonsocial'],
      zona: ['zona'],
      producto: ['producto', 'articulo'],
      subtotalPesos: ['subtotalpesos'],
      subtotal: ['subtotal', 'total', 'importe'],
      obs: ['observaciones', 'observacion', 'obs'],
      obsPedido: ['obspedido', 'observacionesdelpedido', 'observacionespedido', 'notadelpedido'],
      factura: ['factura', 'facturandp', 'nfacturandp', 'comprobante'],
      fantasia: ['nombrefantasia', 'fantasia'],
      domicilio: ['domicilio', 'direccion'],
      localidad: ['localidad'],
      provincia: ['provincia'],
      estadoFactura: ['estadofactura']
    },
    sc: {
      cliente: ['cliente'], fantasia: ['nombrefantasia'], cuit: ['cuit', 'cuitdni', 'dni'],
      fecha: ['femision', 'fechaemision', 'fecha'], comprobante: ['comprobante'],
      saldoComp: ['saldocomp', 'saldocomprobante'], monto: ['montooriginal'], ventas: ['ventas'], cobros: ['cobros'], zona: ['zona'],
      venc: ['fvencimiento', 'fechavencimiento', 'vencimiento'], cuota: ['cuota', 'ncuota', 'nrocuota', 'numerocuota']
    },
    cc: {
      cliente: ['cliente'], fantasia: ['nombrefantasia'], cuit: ['cuit', 'cuitdni', 'dni'],
      saldo: ['saldo', 'saldoactual'], localidad: ['localidad'], provincia: ['provincia'],
      telefono: ['telefono'], domicilio: ['domicilio', 'direccion'], email: ['email', 'mail', 'correo', 'correoelectronico']
    }
  };
  var REQUIRED = {
    pedidos: ['pedido', 'estado', 'cliente', 'producto'],
    sc: ['cliente', 'comprobante', 'saldoComp'],
    cc: ['cliente', 'saldo']
  };
  var LABEL = {
    pedido: 'Pedido Nº', estado: 'Estado', cliente: 'Cliente', producto: 'Producto', comprobante: 'Comprobante',
    saldoComp: 'Saldo Comp.', saldo: 'Saldo', factura: 'Factura', zona: 'Zona', subtotalPesos: 'Subtotal Pesos',
    obs: 'Observaciones', cuit: 'CUIT', fecha: 'Fecha', localidad: 'Localidad'
  };

  function mapHeaders(row, syn) {
    var n = row.map(norm), map = {};
    Object.keys(syn).forEach(function (f) {
      for (var i = 0; i < syn[f].length; i++) {
        var idx = n.indexOf(syn[f][i]);
        if (idx >= 0) { map[f] = idx; break; }
      }
    });
    return map;
  }
  function detect(rows) {
    var lim = Math.min(rows.length, 20);
    for (var r = 0; r < lim; r++) {
      var row = rows[r] || [];
      var s = row.map(norm);
      var has = function (k) { return s.indexOf(k) >= 0; };
      var hasAny = function (arr) { return arr.some(has); };
      if (has('comprobante') && hasAny(SYN.sc.saldoComp)) return { kind: 'sc', headerRow: r };
      if (hasAny(SYN.pedidos.pedido) && hasAny(SYN.pedidos.producto)) return { kind: 'pedidos', headerRow: r };
      if (has('cliente') && hasAny(SYN.cc.saldo) && !has('comprobante')) return { kind: 'cc', headerRow: r };
    }
    return null;
  }
  function toNum(v) {
    if (v == null || v === '') return null;
    if (typeof v === 'number') return isFinite(v) ? v : null;
    var s = String(v).replace(/\$/g, '').replace(/\s/g, '');
    if (!s) return null;
    if (s.indexOf(',') >= 0) s = s.replace(/\./g, '').replace(',', '.');
    var n = parseFloat(s);
    return isFinite(n) ? n : null;
  }
  function pad(n) { return (n < 10 ? '0' : '') + n; }
  function toISO(v) {
    if (v == null || v === '') return '';
    if (typeof v === 'number') {
      var d = new Date(Math.round((v - 25569) * 86400000));
      return d.getUTCFullYear() + '-' + pad(d.getUTCMonth() + 1) + '-' + pad(d.getUTCDate());
    }
    if (v instanceof Date) return v.getFullYear() + '-' + pad(v.getMonth() + 1) + '-' + pad(v.getDate());
    var s = String(v).trim(), m;
    if ((m = s.match(/^(\d{4})-(\d{1,2})-(\d{1,2})/))) return m[1] + '-' + pad(+m[2]) + '-' + pad(+m[3]);
    if ((m = s.match(/^(\d{1,2})[\/\-.](\d{1,2})[\/\-.](\d{2,4})/))) {
      var y = +m[3]; if (y < 100) y += 2000;
      return y + '-' + pad(+m[2]) + '-' + pad(+m[1]);
    }
    return '';
  }
  function str(v) {
    if (v == null) return '';
    if (typeof v === 'number') return Number.isInteger(v) ? String(v) : String(v);
    return String(v).trim();
  }
  function orderId(v) {
    if (v == null || v === '') return '';
    if (typeof v === 'number') return String(Math.round(v));
    var s = String(v).trim();
    var m = s.match(/\d+/);
    return m ? String(parseInt(m[0], 10)) : '';
  }

  function parse(buffer, fileName, progress) {
    progress = progress || function () {};
    progress(5, 'Leyendo el archivo…');
    var wb = XLSX.read(buffer, { type: 'array', cellDates: false, dense: true });
    progress(35, 'Buscando columnas…');
    var found = null, rows = null, sheetName = '';
    for (var i = 0; i < wb.SheetNames.length; i++) {
      var ws = wb.Sheets[wb.SheetNames[i]];
      var rr = XLSX.utils.sheet_to_json(ws, { header: 1, raw: true, defval: null, blankrows: false });
      var d = detect(rr);
      if (d) { found = d; rows = rr; sheetName = wb.SheetNames[i]; break; }
    }
    if (!found) {
      return { ok: false, fileName: fileName, error: 'No se reconocieron las columnas. Se esperaba un informe de pedidos (Pedido Nº, Producto, Estado…), un saldo por comprobante (Comprobante, Saldo Comp.…) o un saldo de cuenta corriente (Cliente, Saldo…).' };
    }
    var kind = found.kind;
    var header = rows[found.headerRow];
    var map = mapHeaders(header, SYN[kind]);
    var missing = REQUIRED[kind].filter(function (f) { return map[f] == null; });
    if (missing.length) {
      return { ok: false, kind: kind, fileName: fileName, error: 'Faltan columnas obligatorias: ' + missing.map(function (f) { return LABEL[f] || f; }).join(', ') };
    }
    var warnings = [];
    var data = rows.slice(found.headerRow + 1);
    var g = function (row, f) { return map[f] == null ? null : row[map[f]]; };
    var total = data.length;
    var records = [];

    if (kind === 'pedidos') {
      if (map.factura == null) warnings.push('No hay columna Factura: no se podrán cruzar saldos.');
      if (map.subtotalPesos == null && map.subtotal == null) warnings.push('No hay columna de importes (Subtotal Pesos).');
      if (map.obs == null) warnings.push('No hay columna Observaciones: no se podrán relacionar envíos.');
      var orders = {}, order = [];
      for (var r = 0; r < total; r++) {
        var row = data[r]; if (!row) continue;
        var id = orderId(g(row, 'pedido'));
        if (!id) continue;
        var o = orders[id];
        if (!o) {
          o = orders[id] = { id: id, fecha: '', estado: '', zona: '', vendedor: '', cliente: '', fantasia: '', obs: '', obsPedido: '',
            facturas: [], domicilio: '', localidad: '', provincia: '', estadoFactura: '', total: 0, lines: 0, shipLines: 0, shipCode: '', products: [] };
          order.push(id);
        }
        o.lines++;
        if (!o.fecha) o.fecha = toISO(g(row, 'fecha'));
        ['estado', 'zona', 'vendedor', 'cliente', 'fantasia', 'obs', 'obsPedido', 'domicilio', 'localidad', 'provincia', 'estadoFactura'].forEach(function (f) {
          if (!o[f]) { var v = str(g(row, f)); if (v) o[f] = v; }
        });
        var fac = str(g(row, 'factura'));
        if (fac && o.facturas.indexOf(fac) < 0) o.facturas.push(fac);
        var amt = toNum(g(row, 'subtotalPesos'));
        if (amt == null) amt = toNum(g(row, 'subtotal'));
        if (amt != null) o.total += amt;
        var prod = str(g(row, 'producto'));
        var pm = prod.match(/^\s*\[\s*ENV[IÍ]O\s*-\s*([^\]]+)\]/i);
        if (pm) { o.shipLines++; o.shipCode = pm[1].trim().toUpperCase(); }
        if (o.products.length < 40) o.products.push(prod);
        if (r % 3000 === 0) progress(40 + Math.round(50 * r / total), 'Procesando pedidos…');
      }
      order.forEach(function (id) {
        var o = orders[id];
        o.total = Math.round(o.total * 100) / 100;
        o.isShipping = o.lines > 0 && o.shipLines === o.lines;
        o.factura = o.facturas[0] || '';
        records.push(o);
      });
    } else if (kind === 'sc') {
      var saldoAnt = 0;
      for (var r2 = 0; r2 < total; r2++) {
        var row2 = data[r2]; if (!row2) continue;
        var comp = str(g(row2, 'comprobante'));
        if (!comp) continue;
        if (/^saldo\s+anterior/i.test(comp)) {
          saldoAnt++;
          var cuA = g(row2, 'cuit');
          var vA = toNum(g(row2, 'ventas')); if (vA == null) vA = toNum(g(row2, 'saldoComp')); if (vA == null) vA = toNum(g(row2, 'monto'));
          records.push({ c: str(g(row2, 'cliente')), f: str(g(row2, 'fantasia')), cuit: cuA == null ? '' : String(cuA).replace(/\D/g, ''), d: '', comp: 'Saldo Anterior', san: true, s: null, v: vA });
          continue;
        }
        var cuit = g(row2, 'cuit');
        records.push({
          c: str(g(row2, 'cliente')), f: str(g(row2, 'fantasia')), cuit: cuit == null ? '' : String(cuit).replace(/\D/g, ''),
          d: toISO(g(row2, 'fecha')), comp: comp, s: toNum(g(row2, 'saldoComp')), m: toNum(g(row2, 'monto')),
          // Fase 2A.1: datos para distinguir cuotas/partes reales de duplicados exactos
          due: toISO(g(row2, 'venc')), q: str(g(row2, 'cuota')), ve: toNum(g(row2, 'ventas')), co: toNum(g(row2, 'cobros')), ix: r2
        });
        if (r2 % 3000 === 0) progress(40 + Math.round(50 * r2 / total), 'Procesando comprobantes…');
      }
      if (saldoAnt) warnings.push(saldoAnt + ' filas "Saldo Anterior" sin detalle: no se usan como crédito.');
    } else {
      for (var r3 = 0; r3 < total; r3++) {
        var row3 = data[r3]; if (!row3) continue;
        var cli = str(g(row3, 'cliente'));
        if (!cli) continue;
        var cu = g(row3, 'cuit');
        records.push({
          c: cli, f: str(g(row3, 'fantasia')), cuit: cu == null ? '' : String(cu).replace(/\D/g, ''),
          s: toNum(g(row3, 'saldo')), loc: str(g(row3, 'localidad')), prov: str(g(row3, 'provincia')),
          tel: str(g(row3, 'telefono')), dom: str(g(row3, 'domicilio')), email: str(g(row3, 'email'))
        });
      }
    }
    progress(100, 'Listo');
    return { ok: true, v: kind === 'sc' ? 3 : 2, kind: kind, fileName: fileName, sheet: sheetName, records: records, count: records.filter(function (r) { return !r.san; }).length, rows: total, warnings: warnings };
  }
  return { parse: parse };
})();

if (typeof WorkerGlobalScope !== 'undefined' && self instanceof WorkerGlobalScope) {
  self.onmessage = function (e) {
    var job = e.data;
    try {
      var res = ExcelImporterCore.parse(job.buffer, job.fileName, function (p, msg) {
        self.postMessage({ id: job.id, type: 'progress', p: p, msg: msg });
      });
      self.postMessage({ id: job.id, type: 'done', result: res });
    } catch (err) {
      self.postMessage({ id: job.id, type: 'done', result: { ok: false, fileName: job.fileName, error: 'No se pudo leer el archivo: ' + (err && err.message || err) } });
    }
  };
}
