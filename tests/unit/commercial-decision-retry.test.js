import {describe,it,expect,vi,beforeEach} from 'vitest';
import {sendCommercialDecisionEmails,DECISION_MAIL_KEY_VERSION} from '../../supabase/functions/_shared/commercial-decision-mail.js';
import {corporateMail} from '../../supabase/functions/_shared/corporate-mail.js';
vi.mock('../../supabase/functions/_shared/corporate-mail.js',()=>({corporateMail:vi.fn()}));
// Datos SINTÉTICOS. Sin envíos reales: el transporte es un doble.
const payload={version:1,event:{id:7,seq:3,kind:'APROBADA',at:'2026-11-18T14:05:00Z',actor:'QA Aprobador',reason:null,terms_before:{amount:100},terms_after:{amount:100}},
 request:{id:'11111111-1111-4111-8111-111111111111',number:'AUT-000901',kind:'ECHEQ',created_at:'2026-11-18T13:30:00Z',client_name:'CLIENTE QA',client_cuit:'30-00000000-0',
  order_ref:'PV-QA',channel:'SUCURSAL',branch:'SAN_JUAN',requester:'QA Comercial',approver:'QA Aprobador',notes:null,original_terms:{amount:100,due_date:'2026-11-30',days:12,issuer_is_client:true,issuer_name:'CLIENTE QA',issuer_cuit:'30-00000000-0'}},previous_proposal:null};
// Cola simulada: N destinatarios del MISMO evento; la toma devuelve de a uno (como comm_decision_mail_claim_next).
function queue(recipients,{capacity=Infinity,claimError=false}={}){
 const rows=recipients.map((r,i)=>({id:i+1,token:'t'+(i+1),event_id:7,recipient:r,kind:i?'COPY':'AUTHOR',event_kind:'APROBADA',request_number:'AUT-000901',state:'PENDING'}));
 const calls=[];let used=0;
 const sb={rpc:async(name,args)=>{calls.push([name,args]);
  if(name==='comm_decision_mail_claim_next'){if(claimError)return {error:{message:'function does not exist'}};if(used>=capacity)return {data:{state:'NO_CAPACITY'}};const j=rows.find(x=>x.state==='PENDING');if(!j)return {data:{state:'EMPTY'}};j.state='PROCESSING';used++;return {data:{state:'CLAIMED',job:j,payload}};}
  if(name==='comm_decision_mail_guard')return {data:true};
  if(name==='comm_decision_mail_finish'){rows.find(x=>x.id===args.p_id).state=args.p_state;return {};}
  if(name==='comm_decision_mail_release'){const x=rows.find(x=>x.id===args.p_id);x.state='PENDING';x.released=args.p_code;used--;return {data:true};}
  return {};}};
 return {sb,rows,calls};
}
const mailDouble=(send,prior=async()=>null)=>corporateMail.mockReturnValue({runtime:async()=>({provider:'SMTP',connected:true,available_slots:100}),send:vi.fn(send),prior:vi.fn(prior)});
beforeEach(()=>corporateMail.mockReset());

describe('Correos de resoluciones · lote por ciclo',()=>{
 it('solicitante + 5 copias se envían en el MISMO ciclo (antes: uno por minuto)',async()=>{
  const q=queue(['autor@qa.invalid','c1@qa.invalid','c2@qa.invalid','c3@qa.invalid','c4@qa.invalid','c5@qa.invalid']);
  const m=mailDouble(async msg=>{await msg.beforeData();return {id:'smtp:'+msg.to};});
  const out=await sendCommercialDecisionEmails(q.sb,{});
  expect(out).toMatchObject({sent:6,claimed:6,stop:'EMPTY'});expect(q.rows.every(r=>r.state==='SENT')).toBe(true);
  const sent=corporateMail.mock.results[0].value.send.mock.calls.map(c=>c[0]);
  expect(sent.map(x=>x.to)).toEqual(q.rows.map(r=>r.recipient));                      // un correo por destinatario: nadie ve a los demás
  expect(new Set(sent.map(x=>x.idempotencyKey)).size).toBe(6);                          // unicidad por evento y destinatario
  expect(sent[0].idempotencyKey).toBe('evento:7:autor@qa.invalid:'+DECISION_MAIL_KEY_VERSION);
  expect(new Set(sent.map(x=>x.html)).size).toBe(1);                                     // mismo detalle completo para todos
 });
 it('sin cupo: los que exceden quedan PENDIENTES sin gastar intento',async()=>{
  const q=queue(['a@qa.invalid','b@qa.invalid','c@qa.invalid'],{capacity:2});mailDouble(async msg=>({id:'x'}));
  const out=await sendCommercialDecisionEmails(q.sb,{});
  expect(out).toMatchObject({sent:2,stop:'NO_CAPACITY'});expect(q.rows.map(r=>r.state)).toEqual(['SENT','SENT','PENDING']);
 });
 it('el proveedor responde RATE_LIMIT (cupo diario/horario agotado entre la toma y el envío) → RELEASE, se corta el ciclo, sin ERROR',async()=>{
  const q=queue(['a@qa.invalid','b@qa.invalid']);mailDouble(async()=>{throw Object.assign(new Error('SMTP_RATE_LIMIT'),{code:'SMTP_RATE_LIMIT',status:503,phase:'BEFORE_SEND'});});
  const out=await sendCommercialDecisionEmails(q.sb,{});
  expect(out).toMatchObject({released:1,stop:'SMTP_RATE_LIMIT',errors:0});expect(q.rows[0]).toMatchObject({state:'PENDING',released:'SMTP_RATE_LIMIT'});expect(q.rows[1].state).toBe('PENDING');
 });
 it('fallo INDIVIDUAL (destinatario rechazado) no impide enviar a los demás',async()=>{
  const q=queue(['malo@qa.invalid','b@qa.invalid','c@qa.invalid']);
  mailDouble(async msg=>{if(msg.to==='malo@qa.invalid')throw Object.assign(new Error('SMTP_RECIPIENT_550'),{code:'SMTP_RECIPIENT_550',status:400,phase:'BEFORE_SEND'});return {id:'ok'};});
  const out=await sendCommercialDecisionEmails(q.sb,{});
  expect(out).toMatchObject({sent:2,errors:1});expect(q.rows.map(r=>r.state)).toEqual(['ERROR','SENT','SENT']);
 });
 it('resultado INCIERTO → HELD (nunca se reintenta solo) y se corta el ciclo',async()=>{
  const q=queue(['a@qa.invalid','b@qa.invalid']);mailDouble(async()=>{throw Object.assign(new Error('SMTP_POR_VERIFICAR'),{code:'SMTP_POR_VERIFICAR',phase:'AFTER_SEND'});});
  const out=await sendCommercialDecisionEmails(q.sb,{});
  expect(out).toMatchObject({held:1,stop:'UNCERTAIN_RESULT'});expect(q.rows.map(r=>r.state)).toEqual(['HELD','PENDING']);
 });
 it('aceptado pero NO registrado → HELD y no se cuenta como enviado',async()=>{
  const q=queue(['a@qa.invalid']);const orig=q.sb.rpc;
  q.sb.rpc=async(n,a)=>n==='comm_decision_mail_finish'&&a.p_state==='SENT'?{error:{message:'db down'}}:orig(n,a);
  mailDouble(async msg=>{await msg.beforeData();return {id:'smtp:aceptado'};});
  const out=await sendCommercialDecisionEmails(q.sb,{});
  expect(out).toMatchObject({sent:0,held:1});expect(q.rows[0].state).toBe('HELD');
 });
 it('destinatario descartado por el servidor (copia quitada / autor inactivo) → no se envía',async()=>{
  const q=queue(['a@qa.invalid','b@qa.invalid']);const orig=q.sb.rpc;
  q.sb.rpc=async(n,a)=>n==='comm_decision_mail_guard'&&a.p_id===1?{data:false}:orig(n,a);
  const m=mailDouble(async msg=>{await msg.beforeData();return {id:'x'};});
  const out=await sendCommercialDecisionEmails(q.sb,{});
  expect(out).toMatchObject({skipped:1,sent:1});expect(corporateMail.mock.results[0].value.send).toHaveBeenCalledTimes(1);
 });
 it('verificación de destinatario no disponible → ERROR seguro (reintento en 5 min) y se corta',async()=>{
  const q=queue(['a@qa.invalid','b@qa.invalid']);const orig=q.sb.rpc;
  q.sb.rpc=async(n,a)=>n==='comm_decision_mail_guard'?{error:{message:'x'}}:orig(n,a);mailDouble(async()=>({id:'x'}));
  const out=await sendCommercialDecisionEmails(q.sb,{});
  expect(out).toMatchObject({errors:1,stop:'RECIPIENT_CHECK_UNAVAILABLE'});expect(corporateMail.mock.results[0].value.send).not.toHaveBeenCalled();
 });
 it('configuración cambiada antes de DATA → vuelve a PENDIENTE sin gastar intento',async()=>{
  const q=queue(['a@qa.invalid']);mailDouble(async()=>{throw Object.assign(new Error('MAIL_CONFIGURATION_CHANGED'),{code:'ABORTED'});});
  const out=await sendCommercialDecisionEmails(q.sb,{});
  expect(out).toMatchObject({released:1});expect(q.rows[0]).toMatchObject({state:'PENDING',released:'MAIL_CONFIGURATION_CHANGED'});
 });
 it('ya ACEPTADO con la clave anterior (aviso breve) → se registra SENT sin reenviar',async()=>{
  const q=queue(['a@qa.invalid']);mailDouble(async()=>({id:'nuevo'}),async key=>key==='evento:7:a@qa.invalid'?{id:'smtp:viejo'}:null);
  await sendCommercialDecisionEmails(q.sb,{});
  expect(q.rows[0].state).toBe('SENT');expect(corporateMail.mock.results[0].value.send).not.toHaveBeenCalled();
  expect(q.calls.find(c=>c[0]==='comm_decision_mail_finish')[1]).toMatchObject({p_state:'SENT',p_reference:'smtp:viejo'});
 });
 it('clave anterior con resultado incierto → HELD, nunca se arriesga un duplicado',async()=>{
  const q=queue(['a@qa.invalid']);mailDouble(async()=>({id:'nuevo'}),async()=>{throw Object.assign(new Error('SMTP_POR_VERIFICAR'),{code:'SMTP_POR_VERIFICAR',phase:'AFTER_SEND'});});
  await sendCommercialDecisionEmails(q.sb,{});expect(q.rows[0].state).toBe('HELD');
 });
 it('respeta el presupuesto de tiempo de la Edge Function y el máximo por ciclo',async()=>{
  let t=0;const q=queue(Array.from({length:30},(_,i)=>'d'+i+'@qa.invalid'));mailDouble(async()=>{t+=10000;return {id:'x'};});
  const out=await sendCommercialDecisionEmails(q.sb,{now:()=>t});
  expect(out.sent).toBe(5);expect(out.stop).toBe('TIME_BUDGET');
  t=0;const q2=queue(Array.from({length:30},(_,i)=>'e'+i+'@qa.invalid'));mailDouble(async()=>({id:'x'}));
  expect((await sendCommercialDecisionEmails(q2.sb,{now:()=>0})).sent).toBe(20);
 });
 it('SQL todavía no aplicado (toma nueva inexistente) → no envía y NO lanza (no bloquea los demás módulos)',async()=>{
  const q=queue(['a@qa.invalid'],{claimError:true});mailDouble(async()=>({id:'x'}));
  await expect(sendCommercialDecisionEmails(q.sb,{})).resolves.toMatchObject({sent:0,stop:'QUEUE_UNAVAILABLE'});
 });
 it('proveedor no SMTP o desconectado → no toma nada',async()=>{
  const q=queue(['a@qa.invalid']);corporateMail.mockReturnValue({runtime:async()=>({provider:'LEGACY',connected:true})});
  expect(await sendCommercialDecisionEmails(q.sb,{})).toMatchObject({active:false});expect(q.calls.length).toBe(0);
 });
});
