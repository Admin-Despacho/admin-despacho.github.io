// MIME único del informe diario, mismo Message-ID y contenido para todos los destinatarios.
import { distributionLists } from './commercial-mail-delivery.js';
import { digest } from './corporate-mail.js';
const enc=new TextEncoder();
const base64=bytes=>{let s='';for(let i=0;i<bytes.length;i+=32768)s+=String.fromCharCode(...bytes.subarray(i,i+32768));return btoa(s);};
const fold=s=>(s.match(/.{1,76}/g)||[]).join('\r\n')+'\r\n';
const word=s=>'=?UTF-8?B?'+base64(enc.encode(s))+'?=';
const addresses=(key,ls)=>ls.length?key+': '+ls.map(a=>'<'+a+'>').join(',\r\n ')+'\r\n':'';
export async function buildDailyMime({key,from,to,cc,subject,html,text,attachments,maxMimeBytes,allowEmpty=false}){
 if(from!=='fgutierrez@okaccesorios.com')throw Error('REMITENTE_INVALIDO');
 if(!/^[a-zA-Z0-9:_-]{1,160}$/.test(key)||!subject||/[\r\n\0]/.test(subject))throw Error('MENSAJE_INVALIDO');
 if(!Number.isSafeInteger(maxMimeBytes)||maxMimeBytes<=0)throw Error('LIMITE_ADJUNTOS_NO_CONFIRMADO');
 const d=distributionLists(to,cc);if(!d.to.length)throw Error('SIN_DESTINATARIO_PRINCIPAL');
 if(!Array.isArray(attachments)||(!attachments.length&&!allowEmpty))throw Error('SIN_ADJUNTOS');
 const names=new Set();let estimated=0;
 for(const a of attachments){
  if(!a||typeof a.name!=='string'||!/^[a-zA-Z0-9_.-]+\.pdf$/i.test(a.name)||names.has(a.name.toLowerCase()))throw Error('NOMBRE_PDF_INVALIDO');
  names.add(a.name.toLowerCase());
  if(!(a.bytes instanceof Uint8Array)||a.bytes.length<8||new TextDecoder().decode(a.bytes.subarray(0,5))!=='%PDF-')throw Error('PDF_INVALIDO');
  estimated+=Math.ceil(a.bytes.length/3)*4;
  if(estimated>maxMimeBytes)throw Error('LIMITE_ADJUNTOS_SUPERADO');
 }
 const hash=(await digest(key)).slice(0,32),mixed='okd-mixed-'+hash,alt='okd-alt-'+hash,messageId='okd-daily-'+hash+'@okaccesorios.com';
 let raw='From: '+word('OK Despacho')+' <'+from+'>\r\n'+addresses('To',d.to)+addresses('Cc',d.cc)+'Subject: '+word(subject)+'\r\nMessage-ID: <'+messageId+'>\r\nMIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary="'+mixed+'"\r\n\r\n--'+mixed+'\r\nContent-Type: multipart/alternative; boundary="'+alt+'"\r\n\r\n';
 for(const [type,body] of [['text/plain',text],['text/html',html]])raw+='--'+alt+'\r\nContent-Type: '+type+'; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n'+fold(base64(enc.encode(String(body??''))));
 raw+='--'+alt+'--\r\n';
 for(const a of attachments)raw+='--'+mixed+'\r\nContent-Type: application/pdf; name="'+a.name+'"\r\nContent-Disposition: attachment; filename="'+a.name+'"\r\nContent-Transfer-Encoding: base64\r\n\r\n'+fold(base64(a.bytes));
 raw+='--'+mixed+'--\r\n';
 if(enc.encode(raw).length>maxMimeBytes)throw Error('LIMITE_ADJUNTOS_SUPERADO');
 return {raw,to:d.to,cc:d.cc,messageId,fingerprint:await digest(raw)};
}
