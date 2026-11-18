import {describe,it,expect,vi} from 'vitest';
import {renderMailPanel,friendlyMailError,providerStatus,parseAddresses,MAIL_STATES,AUTH_SCOPE,wireMailPanel} from '../../src/online/com-mail-panel.js';
const base={copies:['copia1@qa.invalid','vieja@qa.invalid'],author_always:true,transport:{provider:'SMTP',connected:true,sender:'fgutierrez@okaccesorios.com',hourly_cap:100,hourly_used:12,daily_cap:850,daily_used:140},
 recipients:[{address:'vieja@qa.invalid',status:'PENDIENTE_RATIFICACION'},{address:'copia1@qa.invalid',status:'AUTORIZADA',authorized_by:'Admin QA',authorized_at:'2026-11-18T14:00:00Z'},{address:'ex@qa.invalid',status:'REVOCADA',revoked_by:'Admin QA',revoked_at:'2026-11-18T14:10:00Z'}],
 authorization_log:[{at:'2026-11-18T14:00:00Z',address:'copia1@qa.invalid',action:'RATIFICADA',actor:'Admin QA'}],
 history:[{request_number:'AUT-000004',event_kind:'ENVIADA',kind:'APPROVER',recipient:'tesoreria@qa.invalid',state:'SENT',attempts:1,created_at:'2026-11-18T14:05:00Z',sent_at:'2026-11-18T14:05:20Z',error_code:null},
  {request_number:'AUT-000004',event_kind:'ENVIADA',kind:'AUTHOR',recipient:'comercial@qa.invalid',state:'PENDING',attempts:0,created_at:'2026-11-18T14:05:00Z',error_code:'SMTP_RATE_LIMIT'},
  {request_number:'AUT-000004',event_kind:'ENVIADA',kind:'COPY',recipient:'vieja@qa.invalid',state:'SKIPPED',attempts:1,created_at:'2026-11-18T14:05:00Z',error_code:'COPY_NOT_RATIFIED'},
  {request_number:'AUT-000004',event_kind:'RECHAZADA',kind:'COPY',recipient:'<b>x</b>@qa.invalid',state:'ERROR',attempts:4,created_at:'2026-11-18T14:05:00Z',error_code:'SMTP_RECIPIENT_550'},
  {request_number:'AUT-000004',event_kind:'RECHAZADA',kind:'COPY',recipient:'c3@qa.invalid',state:'HELD',attempts:1,created_at:'2026-11-18T14:05:00Z',error_code:'RESULTADO_INCIERTO'}]};
describe('Panel de correos de autorizaciones · V2',()=>{
 it('estado dinámico del proveedor (sin la leyenda de activación pendiente)',()=>{
  const h=renderMailPanel(base);expect(h).not.toContain('pendiente de activación');expect(h).toContain('Correo corporativo ACTIVO');
  expect(providerStatus({...base,transport:{...base.transport,connected:false}}).text).toContain('requiere revisión');expect(providerStatus({simulated:true}).text).toContain('demostración');
 });
 it('historial: NUEVA SOLICITUD, participación SOLICITANTE/APROBADOR/COPIA ADICIONAL, estados en español, errores comprensibles',()=>{
  const h=renderMailPanel(base);
  for(const s of ['Nueva solicitud','APROBADOR','SOLICITANTE','COPIA ADICIONAL','Enviado','Pendiente de envío','Omitido','Error de envío','Retenido para verificar','pendiente de ratificación: no recibe','Esperando cupo','Sin más reintentos automáticos','no garantiza que haya llegado a la bandeja'])expect(h).toContain(s);
  expect(MAIL_STATES.PENDING[0]).toBe('Pendiente de envío');expect(MAIL_STATES.PROCESSING[0]).toBe('Procesando');
 });
 it('estado de autorización de las copias y aviso de pendientes de ratificación',()=>{
  const h=renderMailPanel(base);for(const s of ['Autorizada','Pendiente de ratificación','Revocada','1 dirección(es) pendiente(s) de ratificación','Admin QA','copia visible (CC)','Para','CC','Responder a todos','no garantiza por sí sola'])expect(h).toContain(s);
 });
 it('escapa todo y no expone detalles técnicos',()=>{const h=renderMailPanel({...base,history:[...base.history,{request_number:'A',event_kind:'X',kind:'COPY',recipient:'z@qa.invalid',state:'ERROR',attempts:1,error_code:'SMTP_EHLO_421 password=secreto'}]});
  expect(h).not.toContain('<b>x</b>');expect(h).not.toMatch(/password|secreto|SMTP_/);});
 it('sin configuración: controles deshabilitados',()=>{expect(renderMailPanel(null)).toMatch(/id="comMailAuthorize" type="button" disabled/);});
 it('parseAddresses normaliza y deduplica',()=>{expect(parseAddresses(' A@qa.invalid ; a@qa.invalid\nb@qa.invalid')).toEqual(['a@qa.invalid','b@qa.invalid']);});
 it('acciones: exige confirmación local y envía alcance + confirmación al servidor; revocar solo activas',async()=>{
  const nodes={};const mk=(id,extra={})=>nodes[id]={id,value:'',checked:false,disabled:false,textContent:'',...extra};
  ['#comMailAll','#comMailAuthorize','#comMailRevoke','#comMailNew','#comMailAuth','#comMailResult'].forEach(k=>mk(k));
  const boxes=[{dataset:{copy:'vieja@qa.invalid'},checked:true},{dataset:{copy:'ex@qa.invalid',revoked:'1'},checked:true}];
  const root={querySelector:s=>nodes[s],querySelectorAll:s=>s==='[data-copy]:checked'?boxes.filter(b=>b.checked):boxes};
  const api={comMailCopyAuthorize:vi.fn(async()=>({})),comMailCopyRevoke:vi.fn(async()=>({}))};const done=vi.fn();
  wireMailPanel(root,api,done);nodes['#comMailNew'].value='Nueva@qa.invalid';
  await nodes['#comMailAuthorize'].onclick();expect(api.comMailCopyAuthorize).not.toHaveBeenCalled();expect(nodes['#comMailResult'].textContent).toMatch(/confirmar/);
  nodes['#comMailAuth'].checked=true;await nodes['#comMailAuthorize'].onclick();
  expect(api.comMailCopyAuthorize).toHaveBeenCalledWith(['vieja@qa.invalid','ex@qa.invalid','nueva@qa.invalid'],AUTH_SCOPE,true);
  await nodes['#comMailRevoke'].onclick();expect(api.comMailCopyRevoke).toHaveBeenCalledWith(['vieja@qa.invalid']);expect(done).toHaveBeenCalledTimes(2);
 });
 it('códigos nuevos con explicación',()=>{for(const c of ['APPROVER_NO_LONGER_AUTHORIZED','APPROVER_WITHOUT_EMAIL','VERSION_REVERTIDA','CONCILIADO_REVERSION','RECIPIENT_NOT_IN_DISTRIBUTION','SMTP_PREVIOUSLY_REJECTED'])expect(friendlyMailError(c,'SKIPPED',1)).not.toMatch(/Si persiste/);});
});
