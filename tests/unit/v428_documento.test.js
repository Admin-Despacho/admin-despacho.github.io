// V4.28 · documento del receptor: CLASIFICACIÓN de lo DECLARADO (nunca bloquea) = _receiver_doc_issue del servidor (mismos motivos)
import { test, expect } from 'vitest';
import { docIssue, docError } from '../../src/online/receiver-doc.js';
test('V4.28 · válidos sin advertencia (puntos, espacios y guiones habituales se normalizan)', () => {
  expect(docIssue('DNI', '30111222')).toBe(''); expect(docIssue('DNI', '30.111.222')).toBe(''); expect(docIssue('DNI', '1234567')).toBe('');
  expect(docIssue('CUIL', '20-12345678-6')).toBe(''); expect(docIssue('CUIL', '20 12345678 6')).toBe(''); expect(docIssue('CUIT', '30500010912')).toBe(''); expect(docIssue('CUIT', '20123456786')).toBe('');
});
test('V4.28 · inválidos, con caracteres inesperados o faltantes → MOTIVO de revisión (la entrega continúa)', () => {
  expect(docIssue('DNI', '123')).toBe('DNI CON CANTIDAD DE DÍGITOS INCORRECTA');
  expect(docIssue('DNI', '20123456786')).toBe('PARECE UN CUIL O CUIT: SE ELIGIÓ DNI');
  expect(docIssue('CUIL', '20123456787')).toBe('CUIL CON DÍGITO VERIFICADOR INVÁLIDO');
  expect(docIssue('CUIT', '3050001091')).toBe('CUIT CON CANTIDAD DE DÍGITOS INCORRECTA');
  expect(docIssue('CUIL', '30111222')).toBe('PARECE UN DNI: SE ELIGIÓ CUIL');
  expect(docIssue('CUIL', '30500010912')).toBe('PREFIJO DE EMPRESA: PARECE UN CUIT');
  expect(docIssue('CUIT', '30716111089')).toBe('CUIT CON DÍGITO VERIFICADOR INVÁLIDO');
  expect(docIssue('PASAPORTE', 'AB123')).toBe('TIPO DE DOCUMENTO NO RECONOCIDO');
  expect(docIssue('DNI', '30.111.222A')).toBe('DOCUMENTO CON CARACTERES NO VÁLIDOS');   // letras: a revisar, no se descartan en silencio
  expect(docIssue('CUIL', '20/12345678/6')).toBe('DOCUMENTO CON CARACTERES NO VÁLIDOS');
  expect(docIssue('DNI', '')).toBe('DOCUMENTO FALTANTE'); expect(docIssue('DNI', '', false)).toBe('');
  expect(docError('DNI', '30111222X')).toMatch(/solo números/); expect(docError('CUIL', '30500010912')).toMatch(/elegí CUIT/);
});
