// Deno · destino de las notificaciones push: las rutas EXISTENTES se conservan y la alarma abre la alarma específica (B-AL-02).
import { urlFor } from './url.ts';
const A = 'https://app.test';
const eq = (a: string, b: string) => { if (a !== b) throw new Error(a + ' !== ' + b); };
Deno.test('PU-01 hoja publicada / corregida → #/mis-hojas (igual que antes)', () => { eq(urlFor({ type: 'NUEVA_HOJA_PUBLICADA', route_id: 'r1' }, A), A + '/#/mis-hojas?route=r1'); eq(urlFor({ type: 'HOJA_CORREGIDA' }, A), A + '/#/mis-hojas'); });
Deno.test('PU-02 solicitudes de hoja → #/solicitudes (igual que antes)', () => { eq(urlFor({ type: 'REQUEST_CREATED', route_id: 'r2' }, A), A + '/#/solicitudes?route=r2'); eq(urlFor({ type: 'REQUEST_APPROVED', route_id: 'r3' }, A), A + '/#/solicitudes?route=r3'); });
Deno.test('PU-03 alarma comercial (inicial, escalada, atendida) → la alarma ESPECÍFICA por id de aviso', () => {
  for (const t of ['COM_ALARMA', 'COM_ALARMA_ESCALADA', 'COM_ALARMA_ATENDIDA']) eq(urlFor({ type: t, id: 'n-123', route_id: null }, A), A + '/#/autorizaciones?alarma_n=n-123'); });
Deno.test('PU-04 el id del aviso se codifica (no inyecta parámetros)', () => { eq(urlFor({ type: 'COM_ALARMA', id: 'a&b=c' }, A), A + '/#/autorizaciones?alarma_n=a%26b%3Dc'); });
