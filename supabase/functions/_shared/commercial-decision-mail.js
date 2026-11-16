import {corporateMail} from './corporate-mail.js';
export async function sendCommercialDecisionEmails(sb,options){
 const mail=corporateMail(sb,{...options,scope:'decisiones'}),st=await mail.runtime();
 if(st.provider!=='SMTP'||!st.connected||st.available_slots<1)return {sent:0,active:false};
 const r=await sb.rpc('comm_decision_mail_claim');if(r.error)throw new Error('COMMERCIAL_MAIL_QUEUE_UNAVAILABLE');
 const out={sent:0,held:0,errors:0};
 for(const j of r.data||[]){
  const guard=async()=>{const r=await sb.rpc('comm_decision_mail_guard',{p_id:j.id,p_token:j.token});if(r.error||r.data!==true)throw Object.assign(new Error('ABORTED'),{code:'ABORTED'});};
  const finish=async(state,reference=null,error=null)=>{const r=await sb.rpc('comm_decision_mail_finish',{p_id:j.id,p_token:j.token,p_state:state,p_reference:reference,p_error:error});if(r.error)throw Error('MAIL_RESULT_UNRECORDED');};
  try{
   await guard();
   const label=String(j.event_kind).replace(/_/g,' ');
   // No enviar saldo, KPI, documento, condiciones ni lista de copias. El detalle requiere ingreso con permisos vigentes.
   const url='https://admin-despacho.github.io/#/autorizaciones?v=historial&solicitud='+encodeURIComponent(j.request_id);
   const summary='La autorización '+j.request_number+' cambió a '+label+'. Ingresá a OK Despacho para consultar el detalle.';
   const escape=s=>String(s).replace(/[&<>"]/g,x=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[x]));
   const res=await mail.send({to:j.recipient,idempotencyKey:'evento:'+j.event_id+':'+j.recipient,subject:'OK Despacho · '+j.request_number+' · '+label,text:summary+'\n'+url,html:'<p>'+escape(summary)+'</p><p><a href="'+escape(url)+'">VER AUTORIZACIÓN</a></p>',attachments:[],beforeData:guard});
   await finish('SENT',res.id);out.sent++;
  }catch(e){if(e.code==='ABORTED')continue;const held=e.phase==='AFTER_SEND'||e.message==='MAIL_RESULT_UNRECORDED';await finish(held?'HELD':'ERROR',null,e.code||'MAIL_RESULT_UNRECORDED').catch(()=>{});if(held)out.held++;else out.errors++;}
 }
 return out;
}
