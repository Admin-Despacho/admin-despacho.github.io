import {describe,it,expect} from 'vitest';
import {renderDecisionMail,STATES,money,stamp,day} from '../../supabase/functions/_shared/commercial-decision-template.js';
import {normalizeMail,corporateMime} from '../../supabase/functions/_shared/corporate-mail.js';
import {SAMPLES,ORIGINAL,MODIFIED} from '../fixtures/commercial-decision-payloads.js';
const R=k=>renderDecisionMail(SAMPLES[k]);
const plain=h=>h.replace(/<[^>]+>/g,' ').replace(/&amp;/g,'&').replace(/\s+/g,' ');
describe('Plantilla de resolución · contenido obligatorio',()=>{
 it('asunto con el formato aprobado para cada estado',()=>{
  expect(R('aprobada').subject).toBe('Solicitud comercial APROBADA | AUT-000004 | Tecnología del Norte S.A.');
  expect(R('rechazada').subject).toBe('Solicitud comercial RECHAZADA | AUT-000004 | Tecnología del Norte S.A.');
  expect(R('devuelta').subject).toBe('Solicitud comercial DEVUELTA | AUT-000004 | Tecnología del Norte S.A.');
  expect(R('aprobada_con_cambios').subject).toBe('Solicitud comercial APROBADA CON CAMBIOS | AUT-000004 | Tecnología del Norte S.A.');
  expect(R('cancelada').subject).toBe('Solicitud comercial CANCELADA | AUT-000004 | Tecnología del Norte S.A.');
 });
 it('colores por estado: verde, rojo, naranja, azul, gris',()=>{
  expect(R('aprobada').html).toContain(STATES.APROBADA.fg);expect(STATES.APROBADA.fg).toBe('#067647');
  expect(R('rechazada').html).toContain('#b42318');expect(R('devuelta').html).toContain('#b54708');
  expect(R('aprobada_con_cambios').html).toContain('#175cd3');expect(R('cancelada').html).toContain('#475467');
 });
 it('datos de la solicitud original completos (financiación) y calendario con importes',()=>{
  const t=plain(R('rechazada').html);
  for(const s of ['OK DESPACHO','AUTORIZACIONES COMERCIALES','Número de autorización AUT-000004','Tipo de solicitud Financiación propia','Fecha y hora de creación 18/11/2026 – 10:30',
   'Cliente Tecnología del Norte S.A.','CUIT 30-71234567-9','Número de pedido PV 17-000125','Sucursal San Juan','Comercial solicitante Asesor Comercial QA','Responsable de aprobación Tesorería QA',
   'Importe solicitado $ 600.000,00','Cantidad de cuotas 3','Frecuencia Semanal','Primer vencimiento 25/11/2026','Fecha límite 18/12/2026','Calendario de pagos solicitado',
   '1 25/11/2026 $ 200.000,00','2 02/12/2026 $ 200.000,00','3 09/12/2026 $ 200.000,00','Total $ 600.000,00','Observaciones del comercial','OK ACCESORIOS','Administración · Autorizaciones Comerciales',
   'CONSULTAR SOLICITUD EN OK DESPACHO'])expect(t).toContain(s);
 });
 it('rechazo: MOTIVO DEL RECHAZO textual y aclaración de no autorizada; resolución diferenciada de las observaciones del comercial',()=>{
  const h=R('rechazada').html,t=plain(h);
  expect(t).toContain('MOTIVO DEL RECHAZO El cliente registra deuda vencida en cuenta corriente. No se autoriza una nueva financiación hasta regularizar el saldo pendiente.');
  expect(t).toContain('La operación solicitada NO está autorizada.');
  expect(t).toMatch(/Resolución administrativa Estado RECHAZADA Resuelto por Tesorería QA — Administrador General Fecha y hora 18\/11\/2026 – 11:05/);
  expect(h.indexOf('Observaciones del comercial')).toBeLessThan(h.indexOf('Resolución administrativa'));
 });
 it('aprobada con cambios: solicitadas y autorizadas lado a lado, sin alterar las originales; suplencia indicada',()=>{
  const t=plain(R('aprobada_con_cambios').html);
  expect(t).toContain('Condiciones solicitadas y condiciones autorizadas');
  expect(t).toMatch(/Importe solicitado \$ 600\.000,00 \$ 450\.000,00 ●/);expect(t).toMatch(/Cantidad de cuotas 3 2 ●/);expect(t).toMatch(/Frecuencia Semanal Quincenal ●/);
  expect(t).not.toContain('Solicitadas · calendario');expect(t).toContain('Calendario de pagos solicitado');expect(t).toContain('Autorizadas · calendario');expect(t).toContain('10/12/2026 $ 225.000,00');
  expect(t).toContain('Importe solicitado $ 600.000,00 Cantidad de cuotas 3');   // bloque original intacto
  expect(t).toContain('En suplencia del responsable asignado');
 });
 it('devuelta: condiciones PROPUESTAS y aclaración de que no es aprobación definitiva',()=>{
  const t=plain(R('devuelta').html);
  expect(t).toContain('Condiciones solicitadas y condiciones propuestas');expect(t).toContain('NO constituyen una aprobación definitiva');expect(t).toContain('MOTIVO DE LA DEVOLUCIÓN');
 });
 it('cancelada (retirada por el comercial): propuesta no aceptada y motivo del comercial',()=>{
  const t=plain(R('cancelada').html);
  expect(t).toContain('Cancelada por Asesor Comercial QA');expect(t).toContain('condiciones propuestas no aceptadas');expect(t).toContain('MOTIVO DE LA CANCELACIÓN');
 });
 it('e-cheq: campos propios del tipo (vencimiento, plazo, emisor, CUIT del emisor) y cartera',()=>{
  const t=plain(R('echeq_aprobada').html);
  for(const s of ['Tipo de solicitud Aceptación de e-cheq','Importe del e-cheq $ 1.250.000,50','Vencimiento del e-cheq 10/12/2026','Plazo 22 días','Emisor Distribuidora Andina SRL','CUIT del emisor 30-70000001-3','Cartera Cartera Hernán'])expect(t).toContain(s);
  expect(t).not.toContain('Calendario de pagos');expect(plain(R('echeq_rechazada').html)).toContain('Emisor El mismo cliente');
 });
 it('histórica (formato anterior, sin frecuencia ni primer vencimiento): se muestra lo REGISTRADO, sin recalcular ni inventar',()=>{
  const t=plain(R('historica').html);
  expect(t).toContain('Frecuencia No registrado');expect(t).toContain('Primer vencimiento 08/10/2026');expect(t).not.toContain('Fecha límite');
  expect(t).toContain('3 22/10/2026 $ 70.000,00');
 });
 it('datos opcionales faltantes: «No registrado», sin inventar; 1 cuota = Pago único; importe de cuota ausente no se calcula',()=>{
  const t=plain(R('faltantes').html);
  for(const s of ['CUIT No registrado','Número de pedido No registrado','Sucursal No registrado','Responsable de aprobación No registrado','Resuelto por No registrado','Frecuencia Pago único','Sin observaciones registradas','1 30/11/2026 No registrado'])expect(t).toContain(s);
 });
 it('escape total de HTML y anti-inyección de cabeceras',()=>{
  const m=R('especiales');
  expect(m.html).not.toMatch(/<script|<img|<b>S\.A\.|="[^"]*onerror/);expect(m.html).toContain('&lt;script&gt;');expect(m.html).toContain('&quot;&gt;&lt;img');
  expect(m.subject).not.toMatch(/[\r\n]/);expect(m.subject).toContain('Bcc: intruso');   // queda como TEXTO del asunto, nunca como cabecera
  const raw=corporateMime(normalizeMail({to:'qa@example.invalid',idempotencyKey:'k',subject:m.subject,html:m.html,text:m.text}),'fgutierrez@okaccesorios.com','abc');
  const headers=raw.split('\r\n\r\n')[0];expect(headers).not.toMatch(/^Bcc:/mi);expect(headers.match(/^To:/gmi).length).toBe(1);
  expect(m.text).toContain('Texto extenso.');expect(m.html).toContain('overflow-wrap:anywhere');
 });
 it('enlace al detalle SIN tokens: solo el identificador de la solicitud',()=>{
  const h=R('aprobada').html;const href=h.match(/href="([^"]+)"/)[1].replace(/&amp;/g,'&');
  expect(href).toBe('https://admin-despacho.github.io/#/autorizaciones?v=historial&solicitud=a1b2c3d4-0000-4000-8000-000000000004');
  expect(href).not.toMatch(/token|access|jwt|key=/i);
 });
 it('sin datos internos: ni KPI, ni saldo, ni documento personal, ni copias',()=>{
  for(const k of Object.keys(SAMPLES)){const h=R(k).html+R(k).text;expect(h).not.toMatch(/KPI|saldo comprobante|DNI|doc_number|copias/i);}
 });
 it('texto plano con el mismo contenido esencial',()=>{
  const t=R('aprobada_con_cambios').text;
  for(const s of ['SOLICITUD APROBADA CON CAMBIOS','DATOS DE LA SOLICITUD ORIGINAL','Importe solicitado: $ 600.000,00','AUTORIZADAS:','Importe solicitado: $ 450.000,00  (cambió)','RESOLUCIÓN ADMINISTRATIVA','OBSERVACIONES Y CONDICIONES DEL AUTORIZANTE','https://admin-despacho.github.io/#/autorizaciones'])expect(t).toContain(s);
  expect(t).not.toMatch(/<[a-z]/i);
 });
 it('compatibilidad: estilos en línea, tablas de presentación, sin <style>, <script>, clases ni imágenes externas',()=>{
  for(const k of Object.keys(SAMPLES)){const h=R(k).html;expect(h).not.toMatch(/<style|<script|class=|<img|<link/i);expect(h).toContain('role="presentation"');expect(h).toContain('max-width:640px');}
 });
 it('determinista: el mismo evento produce el mismo correo (idempotencia de la huella)',()=>{
  expect(R('aprobada')).toEqual(R('aprobada'));
 });
 it('formatos',()=>{expect(money(1234567.891)).toBe('$ 1.234.567,89');expect(money(null)).toBe('No registrado');expect(day('2026-01-05')).toBe('05/01/2026');expect(stamp('2026-11-18T02:59:00Z')).toBe('17/11/2026 – 23:59');});
 it('rechaza payload inválido o estado no notificable',()=>{
  expect(()=>renderDecisionMail(null)).toThrow('PAYLOAD_INVALID');
  expect(()=>renderDecisionMail({...SAMPLES.aprobada,event:{...SAMPLES.aprobada.event,kind:'PENDIENTE'}})).toThrow('EVENT_KIND_UNSUPPORTED');
 });
});

describe('Plantilla · NUEVA SOLICITUD',()=>{
 it('asunto, título, subtítulo, introducción y colores aprobados',()=>{
  const m=R('nueva'),t=plain(m.html);
  expect(m.subject).toBe('NUEVA SOLICITUD COMERCIAL | AUT-000004 | Tecnología del Norte S.A.');
  expect(t).toContain('NUEVA SOLICITUD COMERCIAL Pendiente de aprobación · AUT-000004');
  expect(t).toContain('Se ha registrado una nueva solicitud comercial que requiere evaluación y autorización.');
  for(const c of ['#102631','#56dce9','#fff2d9','#925400'])expect(m.html).toContain(c);
  expect(m.html).toMatch(/<div style="font-size:28px;font-weight:bold;letter-spacing:1px">OK DESPACHO<\/div>/);
  expect(m.html).toContain('color:#ffffff');
 });
 it('detalle completo de financiación + observaciones en bloque propio + recuadro PENDIENTE + botón + pie',()=>{
  const t=plain(R('nueva').html);
  for(const s of ['Datos de la solicitud','Número de autorización AUT-000004','Tipo de solicitud Financiación propia','Cliente Tecnología del Norte S.A.','CUIT 30-71234567-9','Número de pedido PV 17-000125','Sucursal San Juan',
   'Comercial solicitante Asesor Comercial QA','Responsable de aprobación Tesorería QA','Fecha y hora de creación 18/11/2026 – 10:30','Importe solicitado $ 600.000,00','Cantidad de cuotas 3','Frecuencia Semanal',
   'Primer vencimiento 25/11/2026','Fecha límite 18/12/2026','Calendario de pagos solicitado','3 09/12/2026 $ 200.000,00','Total $ 600.000,00','Observaciones del comercial',
   'PENDIENTE DE APROBACIÓN Esta solicitud todavía no se encuentra autorizada.','CONSULTAR SOLICITUD EN OK DESPACHO','OK ACCESORIOS','Administración · Autorizaciones Comerciales'])expect(t).toContain(s);
  expect(t).not.toContain('Resolución administrativa');expect(t).not.toContain('Datos de la solicitud original');
 });
 it('e-cheq: campos propios del tipo',()=>{
  const t=plain(R('nueva_echeq').html);
  for(const s of ['Aceptación de e-cheq','Importe del e-cheq $ 845.000,00','Vencimiento del e-cheq 15/12/2026','Plazo 27 días','Emisor Distribuidora Andina SRL','CUIT del emisor 30-70000001-3','Cartera Cartera Hernán'])expect(t).toContain(s);
  expect(t).not.toContain('Calendario de pagos');
 });
 it('texto plano equivalente',()=>{const x=R('nueva').text;for(const s of ['NUEVA SOLICITUD COMERCIAL','Pendiente de aprobación · AUT-000004','DATOS DE LA SOLICITUD','PENDIENTE DE APROBACIÓN','Esta solicitud todavía no se encuentra autorizada.','CONSULTAR SOLICITUD EN OK DESPACHO: https://'])expect(x).toContain(s);expect(x).not.toContain('RESOLUCIÓN');});
});
