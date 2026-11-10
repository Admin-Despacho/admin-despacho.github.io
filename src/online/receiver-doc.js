// V4.28 · documento de quien recibe — reglas compartidas (pantalla del chofer, demo) = _receiver_doc_issue del servidor.
// REGLA DEFINITIVA: un documento incorrecto o faltante NO bloquea la entrega; se advierte, se registra y se revisa después.
export function docIssue(type, raw, required = true) {   // motivo de la advertencia, o '' si es válido (= _receiver_doc_issue: recibe lo DECLARADO)
  const t = (type || 'CUIL').toUpperCase(), raw0 = String(raw || '').trim(), d = raw0.replace(/\D/g, '');
  if (!raw0) return required ? 'DOCUMENTO FALTANTE' : '';
  if (!['DNI', 'CUIL', 'CUIT'].includes(t)) return 'TIPO DE DOCUMENTO NO RECONOCIDO';
  if (!/^[0-9 .\-–]+$/.test(raw0)) return 'DOCUMENTO CON CARACTERES NO VÁLIDOS';   // se normalizan puntos, espacios y guiones; letras u otros, a revisar
  if (!d) return required ? 'DOCUMENTO FALTANTE' : '';
  if (t === 'DNI') return /^\d{7,8}$/.test(d) ? '' : d.length === 11 ? 'PARECE UN CUIL O CUIT: SE ELIGIÓ DNI' : 'DNI CON CANTIDAD DE DÍGITOS INCORRECTA';
  if (d.length === 7 || d.length === 8) return 'PARECE UN DNI: SE ELIGIÓ ' + t;
  if (d.length !== 11) return t + ' CON CANTIDAD DE DÍGITOS INCORRECTA';
  const w = [5, 4, 3, 2, 7, 6, 5, 4, 3, 2]; let s = 0; for (let i = 0; i < 10; i++) s += +d[i] * w[i]; const r = 11 - (s % 11);
  if (r === 10 || (r === 11 ? 0 : r) !== +d[10]) return t + ' CON DÍGITO VERIFICADOR INVÁLIDO';
  if (t === 'CUIL' && !['20', '23', '24', '27'].includes(d.slice(0, 2))) return 'PREFIJO DE EMPRESA: PARECE UN CUIT';
  return '';
}
// texto amable para la pantalla (no bloquea)
export function docError(type, raw) {
  const i = docIssue(type, raw, true); if (!i) return '';
  const M = { 'DOCUMENTO FALTANTE': 'Falta el documento de quien recibe.', 'DOCUMENTO CON CARACTERES NO VÁLIDOS': 'El documento tiene letras u otros caracteres: usá solo números.', 'TIPO DE DOCUMENTO NO RECONOCIDO': 'Elegí el tipo de documento: DNI, CUIL o CUIT.',
    'PARECE UN CUIL O CUIT: SE ELIGIÓ DNI': 'El número parece un CUIL o CUIT: revisá el tipo elegido.', 'PREFIJO DE EMPRESA: PARECE UN CUIT': 'Un CUIL empieza con 20, 23, 24 o 27. Si es de una empresa, elegí CUIT.' };
  return M[i] || (/^PARECE UN DNI/.test(i) ? 'El número parece un DNI: revisá el tipo elegido.' : /DÍGITO VERIFICADOR/.test(i) ? 'El ' + (type || 'CUIL') + ' no es válido: revisá los números.' : /^DNI/.test(i) ? 'El DNI debe tener 7 u 8 dígitos.' : 'El ' + (type || 'CUIL') + ' debe tener 11 dígitos.');
}
