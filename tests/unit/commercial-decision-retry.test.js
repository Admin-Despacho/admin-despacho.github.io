import {describe,it,expect,vi} from 'vitest';
import {sendCommercialDecisionEmails,deliveryKey} from '../../supabase/functions/_shared/commercial-decision-mail.js';
import {SAMPLES} from '../fixtures/commercial-decision-payloads.js';
// Datos SINTÉTICOS. Sin envíos reales: la entrega es un doble que registra (sobre, mensaje, clave) y llama al chequeo previo a DATA.
const err=(code,o={})=>Object.assign(new Error(code),{code,status:503,phase:'BEFORE_SEND',...o});
const P=['aprobador@qa.invalid','comercial@qa.invalid'],C=['copia1@qa.invalid','copia2@qa.invalid','copia3@qa.invalid','copia4@qa.invalid','copia5@qa.invalid'];
// Servidor simulado: bandeja + autorizaciones vigentes + ledger agregado. La distribución efectiva se calcula como en SQL.
function server(principals=P,copies=[],{capacity=Infinity,claimError=false,payload}={}){
 const pl=payload||{...SAMPLES.nueva,distribution:{to:principals,cc:copies}};
 const rows=[...principals.map((r,i)=>({kind:i?'AUTHOR':'APPROVER',recipient:r})),...copies.map(r=>({kind:'COPY',recipient:r}))].map((x,i)=>({...x,id:i+1,token:'t'+(i+1),event_id:7,event_kind:'ENVIADA',request_number:'AUT-000004',state:'PENDING',meta:[]}));
 const revoked=new Set(),inactive=new Set(),ledger={},calls=[];let used=0;
 const eff=()=>{const to=pl.distribution.to.filter(x=>!inactive.has(x)),cc=pl.distribution.cc.filter(x=>!revoked.has(x)&&!to.includes(x));return {to,cc,hash:JSON.stringify([to,cc])};};
 const sb={rpc:async(name,a)=>{calls.push([name,a]);const row=a&&rows.find(x=>x.id===a.p_id);
  switch(name){
   case 'comm_decision_mail_claim_next':{if(claimError)return {error:{message:'no existe'}};if(used>=capacity)return {data:{state:'NO_CAPACITY'}};const j=rows.find(x=>x.state==='PENDING'&&!x.blocked);if(!j)return {data:{state:'EMPTY'}};j.state='PROCESSING';used++;return {data:{state:'CLAIMED',job:j,payload:pl,distribution:eff()}};}
   case 'comm_decision_mail_guard':{const ok=row.kind==='COPY'?!revoked.has(row.recipient):!inactive.has(row.recipient);if(!ok)row.state='SKIPPED';return {data:ok};}
   case 'comm_decision_mail_distribution':return {data:row.state==='PROCESSING'?eff():null};
   case 'comm_decision_mail_ledger_state':{const ks=Object.keys(ledger).filter(k=>k===('evento:'+a.p_event+':'+a.p_recipient)||k.startsWith('evento:'+a.p_event+':'+a.p_recipient+':'));const st=ks.map(k=>ledger[k]);
    return {data:st.find(x=>x.state==='ACCEPTED')?{state:'ACCEPTED',provider_id:st.find(x=>x.state==='ACCEPTED').id}:st.some(x=>x.state==='HELD')?{state:'HELD'}:st.some(x=>x.state==='REJECTED')?{state:'REJECTED'}:null};}
   case 'comm_decision_mail_note_delivery':row.meta.push(a.p_meta);return {data:true};
   case 'comm_decision_mail_finish':row.state=a.p_state;row.ref=a.p_reference;row.err=a.p_error;return {};
   case 'comm_decision_mail_release':row.state='PENDING';row.released=a.p_code;row.blocked=true;used--;return {data:true};   // next_at = +1 min
   case 'comm_decision_mail_hold':row.state='HELD';row.err=a.p_code;return {data:true};
  } return {};}};
 return {sb,rows,calls,revoked,inactive,ledger,pl};
}
function delivery(s,behavior=async()=>({id:'smtp:ok'})){
 const sent=[];return {sent,runtime:async()=>({provider:'SMTP',connected:true,email:'fgutierrez@okaccesorios.com'}),
  deliver:vi.fn(async a=>{await a.beforeData?.();const r=await behavior(a);sent.push(a);s.ledger[a.key]={state:'ACCEPTED',id:r.id};return r;})};
}
const hdr=(raw,h)=>{const m=new RegExp('^'+h+': (.*)$','mi').exec(raw.split('\r\n\r\n')[0].replace(/\r\n[ \t]+/g,' '));return m?[...m[1].matchAll(/<([^>]+)>/g)].map(x=>x[1]):[];};

describe('V3 · distribución efectiva, revocaciones y claves por contenido',()=>{
 it('7 destinatarios en un ciclo: Para + CC visibles, sin CCO, un sobre por destinatario, claves por contenido',async()=>{
  const s=server(P,C),d=delivery(s);const out=await sendCommercialDecisionEmails(s.sb,{delivery:d});
  expect(out).toMatchObject({sent:7,stop:'EMPTY'});expect(d.sent.map(x=>x.envelopeTo)).toEqual([...P,...C]);expect(new Set(d.sent.map(x=>x.raw)).size).toBe(1);
  expect(hdr(d.sent[0].raw,'To')).toEqual(P);expect(hdr(d.sent[0].raw,'Cc')).toEqual(C);expect(d.sent[0].raw.split('\r\n\r\n')[0]).not.toMatch(/^Bcc:/mi);
  expect(d.sent[0].key).toBe(deliveryKey(7,P[0],d.sent[0].fingerprint));expect(s.rows[0].meta[0]).toMatchObject({to:P,cc:C});
 });
 it('copia REVOCADA antes del envío: no recibe y desaparece del CC de los mensajes que todavía no salieron',async()=>{
  const s=server(P,C);const d=delivery(s,async a=>{if(a.envelopeTo===P[1])s.revoked.add('copia3@qa.invalid');return {id:'ok'};});
  await sendCommercialDecisionEmails(s.sb,{delivery:d});
  const by=Object.fromEntries(d.sent.map(x=>[x.envelopeTo,x.raw]));
  expect(Object.keys(by)).not.toContain('copia3@qa.invalid');expect(s.rows.find(r=>r.recipient==='copia3@qa.invalid').state).toBe('SKIPPED');
  expect(hdr(by[P[0]],'Cc')).toContain('copia3@qa.invalid');   // ya enviado: no se modifica
  for(const r of ['copia1@qa.invalid','copia2@qa.invalid','copia4@qa.invalid','copia5@qa.invalid'])expect(hdr(by[r],'Cc')).not.toContain('copia3@qa.invalid');
 });
 it('revocación CONCURRENTE entre armar el mensaje y DATA: el intento se suspende sin gastar intento y se rearma sin la copia',async()=>{
  const s=server(P,C);let once=true;const d=delivery(s);const orig=d.deliver;
  d.deliver=vi.fn(async a=>{if(a.envelopeTo==='copia1@qa.invalid'&&once){once=false;s.revoked.add('copia2@qa.invalid');}return orig(a);});
  const out=await sendCommercialDecisionEmails(s.sb,{delivery:d});
  expect(out.released).toBe(1);const c1=s.rows.find(r=>r.recipient==='copia1@qa.invalid');expect(c1).toMatchObject({state:'PENDING',released:'DISTRIBUTION_CHANGED'});
  s.rows.forEach(r=>r.blocked=false);const out2=await sendCommercialDecisionEmails(s.sb,{delivery:d});expect(out2.sent).toBeGreaterThanOrEqual(1);
  const raw=d.sent.find(x=>x.envelopeTo==='copia1@qa.invalid').raw;expect(hdr(raw,'Cc')).not.toContain('copia2@qa.invalid');
  expect(d.sent.filter(x=>x.envelopeTo==='copia1@qa.invalid').length).toBe(1);
 });
 it('un principal que además era copia NO se elimina por revocar su condición de copia',async()=>{
  const s=server(P,['copia1@qa.invalid']);s.revoked.add('aprobador@qa.invalid');const d=delivery(s);await sendCommercialDecisionEmails(s.sb,{delivery:d});
  expect(d.sent.map(x=>x.envelopeTo)).toContain('aprobador@qa.invalid');expect(hdr(d.sent[0].raw,'To')).toContain('aprobador@qa.invalid');
 });
 it('principal no habilitado: no recibe y sale de Para; si no queda ningún principal, el mensaje sale solo con CC (nunca CCO)',async()=>{
  const s=server(P,['copia1@qa.invalid']);s.inactive.add(P[0]);s.inactive.add(P[1]);const d=delivery(s);await sendCommercialDecisionEmails(s.sb,{delivery:d});
  expect(d.sent.map(x=>x.envelopeTo)).toEqual(['copia1@qa.invalid']);expect(hdr(d.sent[0].raw,'To')).toEqual([]);expect(hdr(d.sent[0].raw,'Cc')).toEqual(['copia1@qa.invalid']);
 });
 it('aceptación parcial + reintento con OTRA distribución: no duplica a quien ya lo recibió (clave por contenido + estado agregado)',async()=>{
  const s=server(P,C);s.ledger['evento:7:copia1@qa.invalid:v3:aaaaaaaaaaaaaaaa']={state:'ACCEPTED',id:'smtp:antes'};
  const d=delivery(s);await sendCommercialDecisionEmails(s.sb,{delivery:d});
  expect(d.sent.map(x=>x.envelopeTo)).not.toContain('copia1@qa.invalid');expect(s.rows.find(r=>r.recipient==='copia1@qa.invalid')).toMatchObject({state:'SENT',ref:'smtp:antes'});
 });
 it('clave PUBLICADA aceptada → SENT sin reenviar; cualquier clave incierta → HELD',async()=>{
  const s=server(['a@qa.invalid','b@qa.invalid']);s.ledger['evento:7:a@qa.invalid']={state:'ACCEPTED',id:'smtp:pub'};s.ledger['evento:7:b@qa.invalid:v2']={state:'HELD'};
  const d=delivery(s);await sendCommercialDecisionEmails(s.sb,{delivery:d});expect(d.deliver).not.toHaveBeenCalled();expect(s.rows.map(r=>r.state)).toEqual(['SENT','HELD']);
 });
 it('rechazo previo del servidor para ese destinatario → ERROR sin reenvío automático',async()=>{
  const s=server(['a@qa.invalid']);s.ledger['evento:7:a@qa.invalid:v3:x']={state:'REJECTED'};const d=delivery(s);await sendCommercialDecisionEmails(s.sb,{delivery:d});
  expect(d.deliver).not.toHaveBeenCalled();expect(s.rows[0]).toMatchObject({state:'ERROR',err:'SMTP_PREVIOUSLY_REJECTED'});
 });
 it('foto que la plantilla rechaza → RETENIDA con incidencia, nunca enviada',async()=>{
  const s=server(['a@qa.invalid'],[],{payload:{version:2,event:{kind:'PENDIENTE'},request:{},distribution:{to:['a@qa.invalid'],cc:[]}}});const d=delivery(s);
  const out=await sendCommercialDecisionEmails(s.sb,{delivery:d});expect(d.deliver).not.toHaveBeenCalled();expect(s.rows[0]).toMatchObject({state:'HELD',err:'DETALLE_INVALIDO'});expect(out.held).toBe(1);
 });
 it('fila retenida por el servidor (foto faltante/inconsistente) → se cuenta y el ciclo sigue',async()=>{
  const s=server(['a@qa.invalid']);let first=true;const o=s.sb.rpc;s.sb.rpc=async(n,a)=>{if(n==='comm_decision_mail_claim_next'&&first){first=false;return {data:{state:'ROW_HELD',id:99,code:'SNAPSHOT_MISSING'}};}return o(n,a);};
  const out=await sendCommercialDecisionEmails(s.sb,{delivery:delivery(s)});expect(out).toMatchObject({held:1,sent:1});
 });
 it('sin cupo: quedan PENDIENTES sin gastar intento; RATE_LIMIT del ledger → PENDING y corte',async()=>{
  const s=server(P,C,{capacity:3});expect((await sendCommercialDecisionEmails(s.sb,{delivery:delivery(s)}))).toMatchObject({sent:3,stop:'NO_CAPACITY'});
  const s2=server(P);const out=await sendCommercialDecisionEmails(s2.sb,{delivery:delivery(s2,async()=>{throw err('SMTP_RATE_LIMIT');})});expect(out).toMatchObject({released:1,stop:'SMTP_RATE_LIMIT'});expect(s2.rows[0].state).toBe('PENDING');
 });
 it('fallo individual (550) no afecta al resto; incierto de uno no corta el ciclo',async()=>{
  const s=server(P,C);const out=await sendCommercialDecisionEmails(s.sb,{delivery:delivery(s,async a=>{if(a.envelopeTo==='copia2@qa.invalid')throw err('SMTP_RECIPIENT_550',{status:400});if(a.envelopeTo==='copia4@qa.invalid')throw err('SMTP_POR_VERIFICAR',{phase:'AFTER_SEND'});return {id:'ok'};})});
  expect(out).toMatchObject({sent:5,errors:1,held:1});
 });
 it('aceptado pero la bandeja no registra el SENT → HELD',async()=>{
  const s=server(['a@qa.invalid']);const o=s.sb.rpc;s.sb.rpc=async(n,a)=>n==='comm_decision_mail_finish'&&a.p_state==='SENT'?{error:{}}:o(n,a);
  expect(await sendCommercialDecisionEmails(s.sb,{delivery:delivery(s)})).toMatchObject({sent:0,held:1});
 });
 it('SQL no aplicado/revertido → no envía y no lanza; proveedor no SMTP → nada',async()=>{
  const s=server(P,[],{claimError:true});await expect(sendCommercialDecisionEmails(s.sb,{delivery:delivery(s)})).resolves.toMatchObject({sent:0,stop:'QUEUE_UNAVAILABLE'});
  const s2=server(P);expect(await sendCommercialDecisionEmails(s2.sb,{delivery:{...delivery(s2),runtime:async()=>({provider:'LEGACY',connected:true})}})).toMatchObject({active:false});
 });
 it('presupuesto de tiempo y máximo por ciclo',async()=>{
  let t=0;const s=server(P,Array.from({length:18},(_,i)=>'c'+i+'@qa.invalid'));expect((await sendCommercialDecisionEmails(s.sb,{delivery:delivery(s,async()=>{t+=10000;return {id:'x'};}),now:()=>t}))).toMatchObject({sent:5,stop:'TIME_BUDGET'});
  const s2=server(P,Array.from({length:25},(_,i)=>'e'+i+'@qa.invalid'));expect((await sendCommercialDecisionEmails(s2.sb,{delivery:delivery(s2),now:()=>0})).sent).toBe(20);
 });
});
