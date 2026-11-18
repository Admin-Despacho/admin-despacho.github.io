import {describe,it,expect} from 'vitest';
import {renderMailPanel,friendlyMailError,providerStatus,mailCopiesToSave,MAIL_STATES} from '../../src/online/com-mail-panel.js';
const base={copies:['copia1@qa.invalid'],author_always:true,transport:{provider:'SMTP',connected:true,sender:'fgutierrez@okaccesorios.com',hourly_cap:100,hourly_used:12,daily_cap:850,daily_used:140},
 history:[{request_number:'AUT-000004',event_kind:'RECHAZADA',kind:'AUTHOR',recipient:'comercial@qa.invalid',state:'SENT',attempts:1,created_at:'2026-11-18T14:05:00Z',sent_at:'2026-11-18T14:05:20Z',error_code:null},
  {request_number:'AUT-000004',event_kind:'RECHAZADA',kind:'COPY',recipient:'<b>x</b>@qa.invalid',state:'PENDING',attempts:0,created_at:'2026-11-18T14:05:00Z',sent_at:null,error_code:'SMTP_RATE_LIMIT'},
  {request_number:'AUT-000004',event_kind:'RECHAZADA',kind:'COPY',recipient:'c2@qa.invalid',state:'ERROR',attempts:4,created_at:'2026-11-18T14:05:00Z',sent_at:null,error_code:'SMTP_RECIPIENT_550'},
  {request_number:'AUT-000004',event_kind:'RECHAZADA',kind:'COPY',recipient:'c3@qa.invalid',state:'HELD',attempts:1,created_at:'2026-11-18T14:05:00Z',sent_at:null,error_code:'RESULTADO_INCIERTO'}]};
describe('Panel de correos de autorizaciones',()=>{
 it('ya no muestra la leyenda de activación pendiente; estado dinámico del proveedor',()=>{
  const h=renderMailPanel(base);expect(h).not.toContain('pendiente de activación');expect(h).toContain('Correo corporativo ACTIVO');expect(h).toContain('fgutierrez@okaccesorios.com');
  expect(providerStatus({...base,transport:{...base.transport,connected:false}}).text).toContain('requiere revisión');
  expect(providerStatus({...base,transport:{provider:'LEGACY',connected:true}}).text).toContain('no está activo');
  expect(providerStatus({simulated:true}).text).toContain('demostración');
 });
 it('estados en español, intentos, fechas y errores comprensibles',()=>{
  const h=renderMailPanel(base);
  for(const s of ['Enviado','Pendiente de envío','Error de envío','Retenido para verificar','Solicitante','Copia adicional','Esperando cupo disponible','rechazó la dirección','Sin más reintentos automáticos','No se pudo confirmar si el servidor lo aceptó'])expect(h).toContain(s);
  expect(Object.fromEntries(Object.entries(MAIL_STATES).map(([k,v])=>[k,v[0]]))).toMatchObject({PENDING:'Pendiente de envío',PROCESSING:'Procesando',SENT:'Enviado',ERROR:'Error de envío'});
  expect(h).toContain('no garantiza que haya llegado a la bandeja de entrada');
 });
 it('advierte que las copias reciben el detalle completo y exige confirmar direcciones nuevas',()=>{
  expect(renderMailPanel(base)).toContain('detalle completo');
  expect(mailCopiesToSave('copia1@qa.invalid, nueva@qa.invalid',base.copies,false).error).toMatch(/autorizadas/);
  expect(mailCopiesToSave(' NUEVA@qa.invalid ;nueva@qa.invalid',base.copies,true).list).toEqual(['nueva@qa.invalid']);
  expect(mailCopiesToSave('',base.copies,false).list).toEqual([]);   // quitar no requiere confirmación
 });
 it('escapa todo y no expone detalles técnicos ni credenciales',()=>{
  const h=renderMailPanel({...base,history:[...base.history,{request_number:'A',event_kind:'X',kind:'COPY',recipient:'z@qa.invalid',state:'ERROR',attempts:1,error_code:'SMTP_EHLO_421 password=secreto'}]});
  expect(h).not.toContain('<b>x</b>');expect(h).toContain('&lt;b&gt;x&lt;/b&gt;');expect(h).not.toMatch(/password|secreto|SMTP_/);
  expect(friendlyMailError('ALGO_DESCONOCIDO','ERROR',1)).toBe('Error de envío. Si persiste, consultá a Administración.');
 });
 it('cupo horario y diario visibles',()=>{const h=renderMailPanel(base);expect(h).toContain('12 / 100');expect(h).toContain('140 / 850');});
 it('sin configuración disponible: controles deshabilitados',()=>{const h=renderMailPanel(null);expect(h).toContain('todavía no disponible');expect(h).toMatch(/id="comMailSave" type="button" disabled/);});
});
