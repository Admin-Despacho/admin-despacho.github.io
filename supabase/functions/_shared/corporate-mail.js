import { smtpTransport, SmtpError } from './smtp-transport.js';
const enc=new TextEncoder();
const b64=b=>{let s='';for(let i=0;i<b.length;i+=32768)s+=String.fromCharCode(...b.subarray(i,i+32768));return btoa(s);};
const safe=s=>String(s||'').replace(/[\r\n]/g,' ').trim();
const word=s=>'=?UTF-8?B?'+b64(enc.encode(safe(s)))+'?=';
const fold=s=>(s.match(/.{1,76}/g)||[]).join('\r\n')+'\r\n';
const email=s=>typeof s==='string'&&/^[^\s<>@,;\r\n]+@[^\s<>@,;\r\n]+\.[^\s<>@,;\r\n]+$/.test(s);
export const digest=async s=>[...new Uint8Array(await crypto.subtle.digest('SHA-256',enc.encode(s)))].map(b=>b.toString(16).padStart(2,'0')).join('');
const unwrap=({data,error})=>{if(error)throw new SmtpError('SMTP_STATE_UNAVAILABLE');return data;};
const decode=s=>new TextDecoder().decode(Uint8Array.from(atob(s.replace(/-/g,'+').replace(/_/g,'/')),c=>c.charCodeAt(0)));
export function normalizeMail(m){
 if(!email(m.to)||!m.idempotencyKey||String(m.idempotencyKey).length>500)throw new SmtpError('SMTP_MESSAGE_INVALID',{status:400});
 const attachments=(m.attachments||[]).map(a=>{
  let content=a.content;
  if(content instanceof ArrayBuffer)content=new Uint8Array(content);
  if(content instanceof Uint8Array)content=b64(content);
  if(typeof content!=='string'||!/^[A-Za-z0-9+/]*={0,2}$/.test(content))throw new SmtpError('SMTP_ATTACHMENT_INVALID',{status:400});
  const filename=safe(a.filename||a.name),mime=safe(a.content_type||a.mime||(/\.pdf$/i.test(filename)?'application/pdf':/\.xlsx$/i.test(filename)?'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet':'application/octet-stream'));
  if(!/^[a-z0-9.+-]+\/[a-z0-9.+-]+$/i.test(mime))throw new SmtpError('SMTP_ATTACHMENT_TYPE',{status:400});
  return {filename,mime,content,cid:a.content_id?safe(a.content_id):null};
 });
 return {to:m.to.toLowerCase(),subject:safe(m.subject),html:String(m.html||''),text:String(m.text||''),attachments};
}
export function corporateMime(m,from,key){
 const B='okd-'+key,A='alt-'+B;
 let raw='From: '+word('OK Despacho')+' <'+from+'>\r\nTo: <'+m.to+'>\r\nSubject: '+word(m.subject)+'\r\nMessage-ID: <'+key+'@okaccesorios.com>\r\nMIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary="'+B+'"\r\n\r\n--'+B+'\r\nContent-Type: multipart/alternative; boundary="'+A+'"\r\n\r\n';
 for(const [type,body] of [['text/plain',m.text],['text/html',m.html]])raw+='--'+A+'\r\nContent-Type: '+type+'; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n'+fold(b64(enc.encode(body)));
 raw+='--'+A+'--\r\n';
 for(const a of m.attachments){const name=a.filename.replace(/["\\]/g,'_');raw+='--'+B+'\r\nContent-Type: '+a.mime+'\r\nContent-Disposition: '+(a.cid?'inline':'attachment')+'; filename="'+word(name)+'"\r\n'+(a.cid?'Content-ID: <'+a.cid.replace(/[<>]/g,'')+'>\r\n':'')+'Content-Transfer-Encoding: base64\r\n\r\n'+fold(a.content);}
 return raw+'--'+B+'--\r\n';
}
/** @param {any} sb @param {{connectTls?: any, transport?: any, scope?: string}} [options] */
export function corporateMail(sb,{connectTls,transport=smtpTransport({connectTls}),scope='mail'}={}){
 const rpc=async(name,args={})=>unwrap(await sb.rpc(name,args));
 const runtime=()=>rpc('comm_mail_runtime');
 const credentials=()=>rpc('comm_smtp_credentials');
 async function transmit({key,fingerprint,to,raw,beforeData}){
  const c=await credentials();if(!c)throw new SmtpError('SMTP_CREDENTIAL_MISSING',{status:401});
  const claim=await rpc('comm_smtp_claim',{p_key:key,p_fingerprint:fingerprint});
  if(claim.state==='ACCEPTED')return {id:claim.provider_id,cached:true};
  if(claim.state==='HELD')throw new SmtpError('SMTP_POR_VERIFICAR',{ambiguous:true});
  if(claim.state!=='READY')throw new SmtpError('SMTP_'+claim.state,{status:['CONFLICT','REJECTED'].includes(claim.state)?400:503});
  let accepted=false;
  try{
   const check=async()=>{const st=await runtime();if(st.provider!=='SMTP'||!st.connected||st.secret_version!==c.secret_version)throw Object.assign(new Error('MAIL_CONFIGURATION_CHANGED'),{code:'ABORTED'});if(beforeData)await beforeData();};
   await check();
   const r=await transport.send(c,{from:c.from,to,raw},check);accepted=true;
   await rpc('comm_smtp_finish',{p_key:key,p_token:claim.token,p_state:'ACCEPTED',p_provider_id:r.id});
   return r;
  }catch(e){
   const uncertain=accepted||e.phase==='AFTER_SEND';
   await rpc('comm_smtp_finish',{p_key:key,p_token:claim.token,p_state:uncertain?'HELD':e.status===401?'AUTH_ERROR':e.status===400?'REJECTED':'RETRYABLE',p_provider_id:null}).catch(()=>{});
   if(e.status===401)await rpc('comm_smtp_probe_result',{p_ok:false,p_secret_version:c.secret_version}).catch(()=>{});
   if(uncertain)throw new SmtpError('SMTP_POR_VERIFICAR',{ambiguous:true});
   throw e;
  }
 }
 return {
  runtime,
  async prior(key){const p=await rpc('comm_smtp_lookup',{p_key:scope+':'+key});if(p?.state==='ACCEPTED')return {id:p.provider_id};if(p&&['HELD','PROCESSING'].includes(p.state))throw new SmtpError('SMTP_POR_VERIFICAR',{ambiguous:true});if(p?.state==='REJECTED')throw new SmtpError('SMTP_PREVIOUSLY_REJECTED',{status:400});return null;},
  async probe(){const c=await credentials();if(!c)throw new SmtpError('SMTP_CREDENTIAL_MISSING',{status:401});try{await transport.probe(c);const verified=await rpc('comm_smtp_probe_result',{p_ok:true,p_secret_version:c.secret_version});if(!verified)throw new SmtpError('SMTP_CREDENTIAL_CHANGED');return {authenticated:true,mail_sent:false};}catch(e){await rpc('comm_smtp_probe_result',{p_ok:false,p_secret_version:c.secret_version}).catch(()=>{});throw e;}},
  async send(m){const st=await runtime();if(st.provider!=='SMTP'||!st.connected)throw new SmtpError('SMTP_NOT_ACTIVE',{status:401});const n=normalizeMail(m),key=scope+':'+m.idempotencyKey,hash=await digest(JSON.stringify(n));return transmit({key,fingerprint:hash,to:n.to,raw:corporateMime(n,st.email,await digest(key)),beforeData:m.beforeData});},
  // Contrato compatible con gmailProvider. Se exige identidad estable de la entrega; no se inventa una clave por intento.
  prepare:async()=>null,tokenFresh:()=>true,kind:'SMTP',
  async post(encoded,_token,{idempotencyKey,beforeData}={}){
   if(!idempotencyKey)throw new SmtpError('SMTP_IDEMPOTENCY_REQUIRED',{status:400});
   const raw=decode(encoded),header=raw.split('\r\n\r\n')[0];
   const to=/^To:[^<>\r\n]*<([^<>]+)>[ \t]*$/mi.exec(header)?.[1],from=/^From:[^<>\r\n]*<([^<>]+)>[ \t]*$/mi.exec(header)?.[1];
   if(!email(to)||from!=='fgutierrez@okaccesorios.com'||/^(?:Cc|Bcc):/mi.test(header))throw new SmtpError('SMTP_ENVELOPE_INVALID',{status:400});
   const boundary=/boundary="([^"]+)"/.exec(header)?.[1];
   const canonical=boundary?raw.split(boundary).join('OKD-STABLE-BOUNDARY'):raw;
   const r=await transmit({key:scope+':'+idempotencyKey,fingerprint:await digest(canonical),to,raw,beforeData});return {status:200,ok:true,json:{id:r.id}};
  },
  interpret:r=>{if(!r.ok||!r.json?.id)throw new SmtpError('SMTP_RESPONSE_INVALID',{ambiguous:true});return {id:r.json.id};}
 };
}
// Solo cambia proveedor por decisión explícita en BD. Los errores SMTP nunca disparan fallback automático.
export function routedMailProvider(sb,legacy,options){const smtp=corporateMail(sb,options);return {async batchLimit(){const s=await smtp.runtime();return s.provider==='SMTP'?(s.connected?Math.max(0,Math.min(2,s.available_slots||0)):0):Infinity;},async send(m){const s=await smtp.runtime();if(s.provider==='SMTP')return smtp.send(m);const prior=await smtp.prior(m.idempotencyKey);return prior||legacy.send(m);}};}

export async function mailChannel(sb,{legacyStore,legacyProvider,connectTls,scope}){
 const smtp=corporateMail(sb,{connectTls,scope});const st=await smtp.runtime();
 if(st.provider==='SMTP')return {provider:smtp,store:{...legacyStore,gmailStatus:()=>smtp.runtime(),markGmail:async()=>{}}};
 const wrapped={...legacyProvider,async post(raw,token,opts){const p=opts?.idempotencyKey?await smtp.prior(opts.idempotencyKey):null;return p?{ok:true,status:200,json:{id:p.id}}:legacyProvider.post(raw,token);}};
 return {provider:wrapped,store:legacyStore};
}
