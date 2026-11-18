import {describe,it,expect,vi} from 'vitest';
import {sendCommercialDecisionEmails,deliveryKeys} from '../../supabase/functions/_shared/commercial-decision-mail.js';
import {SAMPLES} from '../fixtures/commercial-decision-payloads.js';
// Datos SINTÉTICOS. Sin envíos reales: la entrega es un doble que registra (sobre, mensaje, clave).
const err=(code,o={})=>Object.assign(new Error(code),{code,status:503,phase:'BEFORE_SEND',...o});
function queue(principals,copies=[],{capacity=Infinity,claimError=false,kind='ENVIADA'}={}){
 const payload={...SAMPLES.nueva,distribution:{to:principals,cc:copies}};
 const rows=[...principals.map((r,i)=>({kind:i?'AUTHOR':'APPROVER',recipient:r})),...copies.map(r=>({kind:'COPY',recipient:r}))].map((x,i)=>({...x,id:i+1,token:'t'+(i+1),event_id:7,event_kind:kind,request_number:'AUT-000004',state:'PENDING'}));
 const calls=[];let used=0;
 const sb={rpc:async(name,args)=>{calls.push([name,args]);
  if(name==='comm_decision_mail_claim_next'){if(claimError)return {error:{message:'function does not exist'}};if(used>=capacity)return {data:{state:'NO_CAPACITY'}};const j=rows.find(x=>x.state==='PENDING');if(!j)return {data:{state:'EMPTY'}};j.state='PROCESSING';used++;return {data:{state:'CLAIMED',job:j,payload}};}
  if(name==='comm_decision_mail_guard')return {data:true};
  if(name==='comm_decision_mail_finish'){const x=rows.find(x=>x.id===args.p_id);x.state=args.p_state;x.ref=args.p_reference;x.err=args.p_error;return {};}
  if(name==='comm_decision_mail_release'){const x=rows.find(x=>x.id===args.p_id);x.state='PENDING';x.released=args.p_code;used--;return {data:true};}
  return {};}};
 return {sb,rows,calls};
}
function delivery(behavior=async()=>({id:'smtp:ok'}),ledger={}){
 const sent=[];return {sent,ledger,runtime:async()=>({provider:'SMTP',connected:true,email:'fgutierrez@okaccesorios.com'}),lookup:vi.fn(async k=>ledger[k]||null),
  deliver:vi.fn(async a=>{await a.beforeData?.();const r=await behavior(a);sent.push(a);ledger[a.key]={state:'ACCEPTED',id:r.id};return r;})};
}
const P=['aprobador@qa.invalid','comercial@qa.invalid'],C=['copia1@qa.invalid','copia2@qa.invalid','copia3@qa.invalid','copia4@qa.invalid','copia5@qa.invalid'];
const header=(raw,h)=>(raw.split('\r\n\r\n')[0].match(new RegExp('^'+h+': ([\\s\\S]*?)\\r\\n(?=[A-Z])','m'))||[])[1]||'';

describe('Avisos comerciales · Para + CC visibles, entrega por destinatario',()=>{
 it('aprobador + solicitante + 5 copias en el MISMO ciclo, un mismo mensaje con Para/CC visibles para todos',async()=>{
  const q=queue(P,C),d=delivery();const out=await sendCommercialDecisionEmails(q.sb,{delivery:d});
  expect(out).toMatchObject({sent:7,claimed:7,stop:'EMPTY'});expect(q.rows.every(r=>r.state==='SENT')).toBe(true);
  expect(d.sent.map(x=>x.envelopeTo)).toEqual([...P,...C]);
  expect(new Set(d.sent.map(x=>x.raw)).size).toBe(1);   // MISMO mensaje para todos
  const raw=d.sent[0].raw;expect(header(raw,'To')).toBe('<aprobador@qa.invalid>,\r\n <comercial@qa.invalid>');expect(header(raw,'Cc').split(',').length).toBe(5);expect(raw.split('\r\n\r\n')[0]).not.toMatch(/^Bcc:/mi);
  expect(new Set(d.sent.map(x=>x.key)).size).toBe(7);expect(d.sent[0].key).toBe('evento:7:aprobador@qa.invalid');
 });
 it('sin cupo: los que exceden quedan PENDIENTES sin gastar intento',async()=>{
  const q=queue(P,C,{capacity:3});const out=await sendCommercialDecisionEmails(q.sb,{delivery:delivery()});
  expect(out).toMatchObject({sent:3,stop:'NO_CAPACITY'});expect(q.rows.filter(r=>r.state==='PENDING').length).toBe(4);
 });
 it('RATE_LIMIT del ledger entre la toma y el envío → vuelve a PENDIENTE, sin ERROR',async()=>{
  const q=queue(P);const out=await sendCommercialDecisionEmails(q.sb,{delivery:delivery(async()=>{throw err('SMTP_RATE_LIMIT');})});
  expect(out).toMatchObject({released:1,errors:0,stop:'SMTP_RATE_LIMIT'});expect(q.rows[0]).toMatchObject({state:'PENDING',released:'SMTP_RATE_LIMIT'});
 });
 it('fallo INDIVIDUAL (550) no impide entregar al resto',async()=>{
  const q=queue(P,C);const out=await sendCommercialDecisionEmails(q.sb,{delivery:delivery(async a=>{if(a.envelopeTo==='copia2@qa.invalid')throw err('SMTP_RECIPIENT_550',{status:400});return {id:'ok'};})});
  expect(out).toMatchObject({sent:6,errors:1});expect(q.rows.find(r=>r.recipient==='copia2@qa.invalid').state).toBe('ERROR');
 });
 it('resultado INCIERTO de UN destinatario (respuesta perdida tras aceptar) → HELD sin reintento; los demás siguen',async()=>{
  const q=queue(P);const out=await sendCommercialDecisionEmails(q.sb,{delivery:delivery(async a=>{if(a.envelopeTo===P[0])throw err('SMTP_POR_VERIFICAR',{phase:'AFTER_SEND'});return {id:'ok'};})});
  expect(out).toMatchObject({held:1,sent:1});expect(q.rows.map(r=>r.state)).toEqual(['HELD','SENT']);
 });
 it('aceptado pero la bandeja no registra el SENT → HELD (no se cuenta ni se reenvía)',async()=>{
  const q=queue(['a@qa.invalid']);const o=q.sb.rpc;q.sb.rpc=async(n,a)=>n==='comm_decision_mail_finish'&&a.p_state==='SENT'?{error:{}}:o(n,a);
  const out=await sendCommercialDecisionEmails(q.sb,{delivery:delivery()});expect(out).toMatchObject({sent:0,held:1});expect(q.rows[0].state).toBe('HELD');
 });
 it('idempotencia entre versiones: clave PUBLICADA ya aceptada → SENT sin reenviar',async()=>{
  const q=queue(['a@qa.invalid']),d=delivery(undefined,{'evento:7:a@qa.invalid':{state:'ACCEPTED',id:'smtp:publicada'}});
  await sendCommercialDecisionEmails(q.sb,{delivery:d});expect(d.deliver).not.toHaveBeenCalled();expect(q.rows[0]).toMatchObject({state:'SENT',ref:'smtp:publicada'});
 });
 it('idempotencia entre versiones: clave V2 ya aceptada (reinstalación) → SENT sin reenviar',async()=>{
  const q=queue(['a@qa.invalid']),d=delivery(undefined,{'evento:7:a@qa.invalid:v2':{state:'ACCEPTED',id:'smtp:v2'}});
  await sendCommercialDecisionEmails(q.sb,{delivery:d});expect(d.deliver).not.toHaveBeenCalled();expect(q.rows[0].state).toBe('SENT');
 });
 it('cualquier clave incierta → HELD sin enviar',async()=>{
  const q=queue(['a@qa.invalid']),d=delivery(undefined,{'evento:7:a@qa.invalid':{state:'HELD'}});
  await sendCommercialDecisionEmails(q.sb,{delivery:d});expect(d.deliver).not.toHaveBeenCalled();expect(q.rows[0].state).toBe('HELD');
 });
 it('clave publicada con OTRO contenido no entregado (CONFLICT) → se usa la clave V2, una sola entrega',async()=>{
  const q=queue(['a@qa.invalid']);const d=delivery(async a=>{if(a.key==='evento:7:a@qa.invalid')throw err('SMTP_CONFLICT',{status:400});return {id:'smtp:v2'};});
  await sendCommercialDecisionEmails(q.sb,{delivery:d});expect(d.sent.map(x=>x.key)).toEqual(['evento:7:a@qa.invalid:v2']);expect(q.rows[0].state).toBe('SENT');
 });
 it('destinatario descartado por el servidor (revocado / sin ratificar / inactivo) → no se entrega',async()=>{
  const q=queue(P,['copia1@qa.invalid']);const o=q.sb.rpc;q.sb.rpc=async(n,a)=>n==='comm_decision_mail_guard'&&a.p_id===3?{data:false}:o(n,a);
  const d=delivery();const out=await sendCommercialDecisionEmails(q.sb,{delivery:d});expect(out).toMatchObject({skipped:1,sent:2});expect(d.sent.map(x=>x.envelopeTo)).not.toContain('copia1@qa.invalid');
 });
 it('destinatario que NO figura en la distribución de la foto → ERROR, nunca se envía',async()=>{
  const q=queue(['a@qa.invalid']);q.rows[0].recipient='intruso@qa.invalid';const d=delivery();
  await sendCommercialDecisionEmails(q.sb,{delivery:d});expect(d.deliver).not.toHaveBeenCalled();expect(q.rows[0]).toMatchObject({state:'ERROR',err:'RECIPIENT_NOT_IN_DISTRIBUTION'});
 });
 it('verificación de destinatario no disponible → ERROR seguro y se corta',async()=>{
  const q=queue(P);const o=q.sb.rpc;q.sb.rpc=async(n,a)=>n==='comm_decision_mail_guard'?{error:{}}:o(n,a);const d=delivery();
  const out=await sendCommercialDecisionEmails(q.sb,{delivery:d});expect(out).toMatchObject({errors:1,stop:'RECIPIENT_CHECK_UNAVAILABLE'});expect(d.deliver).not.toHaveBeenCalled();
 });
 it('presupuesto de tiempo y máximo por ciclo',async()=>{
  let t=0;const q=queue(P,Array.from({length:18},(_,i)=>'c'+i+'@qa.invalid'));const out=await sendCommercialDecisionEmails(q.sb,{delivery:delivery(async()=>{t+=10000;return {id:'x'};}),now:()=>t});
  expect(out).toMatchObject({sent:5,stop:'TIME_BUDGET'});
  const q2=queue(P,Array.from({length:25},(_,i)=>'e'+i+'@qa.invalid'));expect((await sendCommercialDecisionEmails(q2.sb,{delivery:delivery(),now:()=>0})).sent).toBe(20);
 });
 it('SQL V2 no aplicado o revertido → no envía y no lanza',async()=>{
  const q=queue(P,[],{claimError:true});await expect(sendCommercialDecisionEmails(q.sb,{delivery:delivery()})).resolves.toMatchObject({sent:0,stop:'QUEUE_UNAVAILABLE'});
 });
 it('proveedor no SMTP → no toma nada',async()=>{
  const q=queue(P);const out=await sendCommercialDecisionEmails(q.sb,{delivery:{...delivery(),runtime:async()=>({provider:'LEGACY',connected:true})}});expect(out).toMatchObject({active:false});expect(q.calls.length).toBe(0);
 });
 it('claves: publicada + alternativa V2',()=>{expect(deliveryKeys(9,'x@qa.invalid')).toEqual(['evento:9:x@qa.invalid','evento:9:x@qa.invalid:v2']);});
});
