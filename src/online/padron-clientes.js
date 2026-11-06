// V4.26 · PADRÓN DE CLIENTES (listado_clientes.xlsx): reglas de asociación de correos. Funciones PURAS, idénticas a
// tools/analizar_padron_clientes.py y re-validadas en el servidor (client_padron_import). No envía nada ni escribe nada.
//  · CUIT/CUIL con dígito verificador · DNI de 7 u 8 dígitos · NOMBRE/razón social normalizado como el constructor, ÚNICO en el padrón y de 2+ palabras
//  · una misma clave (CUIT o DNI) con correos DISTINTOS es AMBIGUA: no se asocia ninguna de sus filas · modo CONSERVAR (lo decide el servidor)
const EMAIL = /^[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}$/i;
export const normName = s => String(s || '').normalize('NFD').replace(/[\u0300-\u036f]/g, '').toUpperCase().replace(/[^A-Z0-9]+/g, ' ').trim();   // = Normalizer.name
export function cuitOk(c) {
  if (!/^\d{11}$/.test(c)) return false;
  const w = [5, 4, 3, 2, 7, 6, 5, 4, 3, 2]; let t = 0; for (let i = 0; i < 10; i++) t += +c[i] * w[i];
  const r = 11 - (t % 11); if (r === 10) return false;   // AFIP no emite estos CUIT (cambia el prefijo): igual que _cuit_valid del servidor
  return (r === 11 ? 0 : r) === +c[10];
}
const emailsOf = cell => { const parts = String(cell ?? '').split(/[;,/\s]+/).map(p => p.trim().replace(/^\.+|\.+$/g, '').toLowerCase()).filter(Boolean);
  return { ok: parts.filter(p => EMAIL.test(p)), bad: parts.filter(p => !EMAIL.test(p)) }; };
// matrix: filas del Excel (la primera es el encabezado: Razón Social · Nombre · Tipo Doc. · Número · eMail)
export function analyzePadron(matrix) {
  const head = (matrix[0] || []).map(h => String(h ?? '').trim().toLowerCase());
  const col = (...n) => head.findIndex(h => n.some(x => h.includes(x)));
  const iR = col('raz'), iN = col('nombre'), iT = col('tipo'), iD = col('mero', 'numero'), iE = col('mail');
  if ([iR, iN, iT, iD, iE].some(i => i < 0)) throw new Error('El archivo no tiene las columnas esperadas: Razón Social, Nombre, Tipo Doc., Número, eMail.');
  const recs = matrix.slice(1).map((r, k) => { const g = i => String(r[i] ?? '').trim(); const e = emailsOf(r[iE]);
    return { fila: k + 2, razon_social: g(iR), nombre: g(iN), tipo_doc: g(iT).toUpperCase(), documento: g(iD).replace(/\D/g, ''), email_original: g(iE), email: e.ok[0] || null, emails_extra: e.ok.slice(1), emails_invalidos: e.bad }; })
    .filter(x => x.razon_social || x.nombre || x.documento || x.email_original);
  const byName = new Map(); const addN = (n, f) => { if (!n) return; if (!byName.has(n)) byName.set(n, new Set()); byName.get(n).add(f); };
  recs.forEach(x => { addN(normName(x.razon_social), x.fila); addN(normName(x.nombre), x.fila); });
  const byDoc = new Map(); recs.forEach(x => { if (x.email && x.documento) { if (!byDoc.has(x.documento)) byDoc.set(x.documento, new Set()); byDoc.get(x.documento).add(x.email); } });
  const names = x => [...new Set([normName(x.razon_social), normName(x.nombre)].filter(Boolean))].sort();
  // un documento con correos DISTINTOS indica un error de datos: esas filas tampoco se asocian por nombre (coincidencia dudosa)
  const uniq = x => (x.documento && (byDoc.get(x.documento) || new Set()).size > 1) ? [] : names(x).filter(n => byName.get(n).size === 1 && n.split(' ').length >= 2);
  const out = { cuit: [], dni: [], nombre: [], pendientes: [], sin_email: [], invalidos: [], nombres_ambiguos: {} }; const seenC = new Set(), seenD = new Set();
  for (const x of recs) {
    if (!x.email) { (x.emails_invalidos.length ? out.invalidos : out.sin_email).push({ ...x, motivo: x.emails_invalidos.length ? 'correo inválido' : 'sin correo' }); continue; }
    if (x.emails_extra.length) out.pendientes.push({ ...x, motivo: 'varios correos: se sugiere el primero; los otros quedan para revisión', importado: true });
    const d = x.documento, t = x.tipo_doc;
    if (t.startsWith('CUIT') || t.startsWith('CUIL') || d.length === 11) {
      if (cuitOk(d)) { if (byDoc.get(d).size > 1) { out.pendientes.push({ ...x, motivo: 'CUIT repetido con correos distintos: no se asocia ninguna fila', importado: false }); continue; }
        if (!seenC.has(d)) { seenC.add(d); out.cuit.push(x); } continue; }
      out.pendientes.push({ ...x, motivo: 'CUIT/CUIL con dígito verificador inválido: se intenta por nombre', importado: false });
    } else if (t.startsWith('DNI') || /^\d{7,8}$/.test(d)) {
      if (/^\d{7,8}$/.test(d)) { if (byDoc.get(d).size > 1) { out.pendientes.push({ ...x, motivo: 'DNI repetido con correos distintos: no se asocia ninguna fila', importado: false }); continue; }
        if (!seenD.has(d)) { seenD.add(d); out.dni.push(x); } continue; }
      out.pendientes.push({ ...x, motivo: 'DNI con formato inválido: se intenta por nombre', importado: false });
    }
    if (!uniq(x).length) out.pendientes.push({ ...x, motivo: 'sin documento válido y nombre ambiguo, repetido o de una sola palabra: no se asocia', importado: false });
  }
  for (const x of recs) { if (!x.email) continue; const u = uniq(x); if (u.length) out.nombre.push({ fila: x.fila, razon_social: x.razon_social, nombre: x.nombre, email: x.email, claves_nombre: u });
    names(x).forEach(n => { if (byName.get(n).size > 1) out.nombres_ambiguos[n] = [...byName.get(n)].sort((a, b) => a - b); }); }
  const rows = [...out.cuit.map(x => ({ fila: x.fila, tipo: 'CUIT', clave: x.documento, email: x.email, nombre: x.razon_social || x.nombre })),
    ...out.dni.map(x => ({ fila: x.fila, tipo: 'DNI', clave: x.documento, email: x.email, nombre: x.razon_social || x.nombre })),
    ...out.nombre.flatMap(x => x.claves_nombre.map(k => ({ fila: x.fila, tipo: 'NOMBRE', clave: k, email: x.email, nombre: x.razon_social || x.nombre })))];
  const resumen = { filas: recs.length, con_correo_valido: recs.filter(r => r.email).length, por_CUIT: out.cuit.length, por_DNI: out.dni.length,
    claves_de_nombre: out.nombre.reduce((a, x) => a + x.claves_nombre.length, 0), clientes_con_clave_por_nombre: out.nombre.length,
    nombres_ambiguos: Object.keys(out.nombres_ambiguos).length, pendientes: out.pendientes.length, sin_correo: out.sin_email.length, correo_invalido: out.invalidos.length, filas_para_importar: rows.length };
  return { resumen, rows, ...out };
}
