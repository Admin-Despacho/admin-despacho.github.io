// Worker del informe diario. No usa el circuito individual de hojas ni el namespace de decisiones.
import { summarizeDay, renderDailyDispatch } from './daily-dispatch-report.js';
import { buildDailyMime } from './daily-dispatch-mime.js';
import { commercialDelivery, distributionLists } from './commercial-mail-delivery.js';
const fail=code=>Object.assign(Error(code),{code});
const codeOf=e=>String(e?.code||e?.message||'ERROR_DESCONOCIDO').slice(0,160);
const transient=new Set(['SMTP_RATE_LIMIT','SMTP_NOT_ACTIVE','SMTP_BUSY','SMTP_CREDENTIAL_MISSING','SMTP_AUTH_REJECTED','SMTP_CONFIG_INVALID','SMTP_AUTH_UNSUPPORTED','SMTP_STATE_UNAVAILABLE','CONFIGURATION_CHANGED','ABORTED']);
const ambiguous=e=>e?.ambiguous||e?.phase==='AFTER_SEND'||codeOf(e)==='SMTP_POR_VERIFICAR';
const MAX_ATTACHMENTS=100;
export const recipientKey=(batchId,recipient)=>'lote:'+batchId+':'+recipient;
const sha=async bytes=>[...new Uint8Array(await crypto.subtle.digest('SHA-256',bytes))].map(b=>b.toString(16).padStart(2,'0')).join('');
function lists(recipients){
 if(!Array.isArray(recipients)||!recipients.length||recipients.length>100)throw fail('DESTINATARIOS_INVALIDOS');
 const norm=distributionLists([recipients[0]],recipients.slice(1));return {to:norm.to,cc:norm.cc};
}
export function dailyDispatchStore(sb){
 const rpc=async(name,args={})=>{const {data,error}=await sb.rpc(name,args);if(error)throw fail('INFORME_DB_'+name);return data;};
 return {
  config:()=>rpc('daily_dispatch_config'),
  prepare:()=>rpc('daily_dispatch_prepare'),
  seal:(id,snapshot)=>rpc('daily_dispatch_seal',{p_id:id,p_snapshot:snapshot}),
  claim:()=>rpc('daily_dispatch_claim'),
  guard:(id,token)=>rpc('daily_dispatch_guard',{p_id:id,p_token:token}),
  finish:(id,token,state,reference,error)=>rpc('daily_dispatch_finish',{p_id:id,p_token:token,p_state:state,p_reference:reference,p_error:error}),
  incident:(id,error)=>rpc('daily_dispatch_incident',{p_id:id,p_error:error}),
  async download(path){
   const {data,error}=await sb.storage.from('route-pdfs').download(path);
   if(error||!data)throw fail('PDF_NO_DISPONIBLE');
   return new Uint8Array(await data.arrayBuffer());
  }
 };
}
async function loadAttachments(store,manifest,maxMimeBytes){
 if(!Array.isArray(manifest)||manifest.length>MAX_ATTACHMENTS)throw fail('CANTIDAD_ADJUNTOS_INVALIDA');
 let bytesTotal=0;const atts=[],files=[];
 for(const f of manifest){
  if(!f.storage_path||!f.name)throw fail('PDF_NO_DISPONIBLE');
  const bytes=await store.download(f.storage_path);
  bytesTotal+=Math.ceil(bytes.length/3)*4;if(bytesTotal>maxMimeBytes)throw fail('LIMITE_ADJUNTOS_SUPERADO');
  const fingerprint=await sha(bytes);
  if(f.sha256&&f.sha256!==fingerprint)throw fail('PDF_MODIFICADO');
  atts.push({name:f.name,bytes});
  files.push({name:f.name,storage_path:f.storage_path,sha256:fingerprint,bytes:bytes.length});
 }
 return {atts,files};
}
export async function sendDailyDispatch(sb,options={}){
 const store=options.store||dailyDispatchStore(sb);
 const delivery=options.delivery||commercialDelivery(sb,{...options,namespace:'informe-diario'});
 const config=options.config||await store.config();
 if(!config?.active)return {sent:0,held:0,retry:0,skipped:0,stop:'DISABLED'};
 const maxMimeBytes=config.max_mime_bytes;
 const out={sent:0,held:0,retry:0,skipped:0,stop:null};
 if(!Number.isSafeInteger(maxMimeBytes)||maxMimeBytes<=0)return {...out,stop:'LIMITE_ADJUNTOS_NO_CONFIRMADO'};
 const runtime=await delivery.runtime();
 if(runtime.provider!=='SMTP'||!runtime.connected||runtime.email!=='fgutierrez@okaccesorios.com')return {...out,stop:'SMTP_NOT_ACTIVE'};
 // prepare congela el corte, no crea otro informe del mismo día. WAIT_PDF conserva la lista de hojas.
 const p=await store.prepare();
 if(p?.state==='READY'){
  try{
   const d=lists(p.recipients), files=[], atts=[], missing=[], routes=[];
   let remaining=maxMimeBytes;
   for(const route of p.routes.slice().sort((a,b)=>a.number.localeCompare(b.number))){
    let attached=false;
    if(route.storage_path && route.file_name && files.length<MAX_ATTACHMENTS){
     try{
      const part=await loadAttachments(store,[{name:route.file_name,storage_path:route.storage_path}],remaining);
      const bytes=part.atts[0].bytes;
      if(bytes.length>=8 && new TextDecoder().decode(bytes.subarray(0,5))==='%PDF-'){
       atts.push(part.atts[0]);files.push(part.files[0]);remaining-=Math.ceil(bytes.length/3)*4;
       attached=true;
      }
     }catch(e){if(!['PDF_NO_DISPONIBLE','LIMITE_ADJUNTOS_SUPERADO'].includes(codeOf(e)))throw e;}
    }
    if(!attached)missing.push({number:route.number,version:route.version});
    routes.push({...route,file_name:attached?route.file_name:'PDF pendiente'});
   }
   const report=summarizeDay(routes);
   const body=renderDailyDispatch({day:p.day,time:p.time,report});
   const msg=await buildDailyMime({key:p.id,from:runtime.email,...d,...body,attachments:atts,maxMimeBytes,allowEmpty:true});
   // Se guardan únicamente resumen/cuerpo, distribución y huellas; ningún PDF ni datos de clientes en esta fila.
   const sealed=await store.seal(p.id,{...body,...d,files,missing,fingerprint:msg.fingerprint,messageId:msg.messageId});
   if(sealed!==true)return {...out,stop:'SEAL_NOT_CONFIRMED'};
  }catch(e){await store.incident(p.id,codeOf(e));return {...out,stop:codeOf(e)};}
 }
 const start=Date.now(),limit=Math.min(100,Math.max(1,options.limit??20));
 for(let i=0;i<limit&&Date.now()-start<45000;i++){
  const j=await store.claim();
  if(!j||j.state!=='CLAIMED'){out.stop=j?.state||'NO_PENDING';break;}
  const key=recipientKey(j.batch_id,j.recipient);
  const finish=(state,reference=null,error=null)=>store.finish(j.id,j.token,state,reference,error);
  try{
   // Consultar primero el ledger: si SMTP aceptó pero falló la escritura del resultado, NO reenviar.
   const prior=await delivery.lookup(key);
   if(prior?.state==='ACCEPTED'){await finish('SENT',prior.id);out.sent++;continue;}
   if(prior&&['HELD','PROCESSING'].includes(prior.state)){await finish('HELD',null,'RESULTADO_INCIERTO');out.held++;continue;}
   const guard=async()=>{if(await store.guard(j.id,j.token)!==true)throw Object.assign(fail('CONFIGURATION_CHANGED'),{code:'ABORTED',reason:'CONFIGURATION_CHANGED'});};
   await guard();
   const s=j.snapshot;
   if(!s||![...s.to,...s.cc].includes(j.recipient))throw fail('SNAPSHOT_INVALIDO');
   const {atts}=await loadAttachments(store,s.files,maxMimeBytes);
   const msg=await buildDailyMime({key:j.batch_id,from:runtime.email,to:s.to,cc:s.cc,subject:s.subject,html:s.html,text:s.text,attachments:atts,maxMimeBytes,allowEmpty:true});
   if(msg.fingerprint!==s.fingerprint||msg.messageId!==s.messageId)throw fail('MENSAJE_MODIFICADO');
   // El mismo MIME y Message-ID en todas las bandejas, pero un RCPT y una clave por destinatario.
   const res=await delivery.deliver({key,envelopeTo:j.recipient,raw:msg.raw,fingerprint:msg.fingerprint,beforeData:guard});
   if(await finish('SENT',res.id)!==true)throw fail('RESULTADO_NO_REGISTRADO');
   out.sent++;
  }catch(e){
   const c=codeOf(e);
   if(ambiguous(e)||c==='RESULTADO_NO_REGISTRADO'){await finish('HELD',null,c).catch(()=>{});out.held++;continue;}
   if(e.reason==='CONFIGURATION_CHANGED'){await finish('HELD',null,'CONFIGURATION_CHANGED').catch(()=>{});out.held++;continue;}
   if(transient.has(c)){await finish('PENDING',null,c).catch(()=>{});out.retry++;out.stop=c;break;}
   // Archivo cambiado, distribución inválida, rechazo permanente o cualquier falla desconocida: intervención administrativa.
   await finish('HELD',null,c).catch(()=>{});out.held++;
  }
 }
 return out;
}
