import {describe,it,expect,vi} from 'vitest';
import {buildCommercialMime,distributionLists,commercialDelivery} from '../../supabase/functions/_shared/commercial-mail-delivery.js';
const base={from:'fgutierrez@okaccesorios.com',subject:'NUEVA SOLICITUD COMERCIAL | AUT-1 | Cliente',html:'<p>x</p>',text:'x',eventId:7};
const head=r=>r.split('\r\n\r\n')[0];
describe('MIME con destinatarios visibles (Para + CC, sin CCO)',()=>{
 it('Para y CC visibles, sin Bcc, deduplicados y normalizados',async()=>{
  const m=await buildCommercialMime({...base,to:['Tesoreria@QA.invalid','comercial@qa.invalid','tesoreria@qa.invalid'],cc:['copia1@qa.invalid','COMERCIAL@qa.invalid','copia2@qa.invalid']});
  expect(m.to).toEqual(['tesoreria@qa.invalid','comercial@qa.invalid']);expect(m.cc).toEqual(['copia1@qa.invalid','copia2@qa.invalid']);
  const h=head(m.raw);expect(h).toMatch(/^To: <tesoreria@qa\.invalid>,\r\n <comercial@qa\.invalid>$/m);expect(h).toMatch(/^Cc: <copia1@qa\.invalid>,\r\n <copia2@qa\.invalid>$/m);expect(h).not.toMatch(/^Bcc:/mi);
  expect(h).toMatch(/^From: =\?UTF-8\?B\?[^?]+\?= <fgutierrez@okaccesorios\.com>$/m);
 });
 it('sin CC cuando no hay copias autorizadas',async()=>{const m=await buildCommercialMime({...base,to:['a@qa.invalid'],cc:[]});expect(head(m.raw)).not.toMatch(/^Cc:/m);});
 it('determinista: mismo evento ⇒ mismos bytes y Message-ID (misma huella en reintentos)',async()=>{
  const a=await buildCommercialMime({...base,to:['a@qa.invalid'],cc:['b@qa.invalid']}),b=await buildCommercialMime({...base,to:['a@qa.invalid'],cc:['b@qa.invalid']});
  expect(a.raw).toBe(b.raw);expect(a.fingerprint).toBe(b.fingerprint);expect(a.messageId).toMatch(/^okd-com-7-[0-9a-f]{24}@okaccesorios\.com$/);
 });
 it('rechaza inyección de cabeceras, direcciones inválidas, Para vacío y otro remitente',async()=>{
  for(const bad of [{to:['a@qa.invalid\r\nBcc: x@evil.invalid']},{to:['a@qa.invalid'],cc:['b@qa.invalid>, <x@evil.invalid']},{to:[],cc:[]},{to:['sin-arroba']}])await expect(buildCommercialMime({...base,cc:[],...bad})).rejects.toMatchObject({code:'SMTP_MESSAGE_INVALID'});
  await expect(buildCommercialMime({...base,from:'otro@evil.invalid',to:['a@qa.invalid']})).rejects.toMatchObject({code:'SMTP_CONFIG_INVALID'});
  const m=await buildCommercialMime({...base,subject:'Asunto\r\nBcc: x@evil.invalid',to:['a@qa.invalid']});expect(head(m.raw)).not.toMatch(/^Bcc:/mi);
 });
 it('distributionLists: sin destinatarios → error; solo CC (sin principales habilitados) → válido, nunca CCO',()=>{expect(()=>distributionLists([],[])).toThrow();expect(distributionLists([],['a@qa.invalid'])).toEqual({to:[],cc:['a@qa.invalid']});});
});
describe('Entrega por destinatario sobre el ledger (sin red)',()=>{
 const creds={host:'mail.okaccesorios.com',port:26,user:'fgutierrez@okaccesorios.com',from:'fgutierrez@okaccesorios.com',password:'x',secret_version:'v1'};
 function sbDouble(claim='READY',{finishFails=false}={}){const calls=[];return {calls,rpc:async(n,a)=>{calls.push([n,a]);
  if(n==='comm_mail_runtime')return {data:{provider:'SMTP',connected:true,secret_version:'v1',email:creds.from}};if(n==='comm_smtp_credentials')return {data:creds};
  if(n==='comm_smtp_claim')return {data:{state:claim,token:'t'}};if(n==='comm_smtp_finish'){if(finishFails&&a.p_state==='ACCEPTED')return {error:{}};return {data:null};}if(n==='comm_smtp_lookup')return {data:null};return {data:true};}};}
 it('un RCPT por transacción: el sobre es el destinatario, el mensaje lleva Para/CC completos',async()=>{
  const sb=sbDouble(),send=vi.fn(async()=>({id:'smtp:1'}));const m=await buildCommercialMime({...base,to:['a@qa.invalid'],cc:['b@qa.invalid']});
  await commercialDelivery(sb,{transport:{send}}).deliver({key:'evento:7:b@qa.invalid',envelopeTo:'b@qa.invalid',raw:m.raw,fingerprint:m.fingerprint});
  expect(send.mock.calls[0][1]).toMatchObject({to:'b@qa.invalid',from:creds.from});expect(send.mock.calls[0][1].raw).toContain('Cc: <b@qa.invalid>');
  expect(sb.calls.find(c=>c[0]==='comm_smtp_claim')[1].p_key).toBe('decisiones:evento:7:b@qa.invalid');
 });
 for(const st of ['HELD','BUSY','CONFLICT','REJECTED','RATE_LIMIT','NOT_ACTIVE'])it('ledger '+st+' → no transmite',async()=>{const send=vi.fn();await expect(commercialDelivery(sbDouble(st),{transport:{send}}).deliver({key:'k',envelopeTo:'a@qa.invalid',raw:'x',fingerprint:'f'.repeat(64)})).rejects.toBeTruthy();expect(send).not.toHaveBeenCalled();});
 it('aceptado por SMTP pero el registro falla → INCIERTO (nunca se reintenta solo)',async()=>{const sb=sbDouble('READY',{finishFails:true});await expect(commercialDelivery(sb,{transport:{send:async()=>({id:'x'})}}).deliver({key:'k',envelopeTo:'a@qa.invalid',raw:'x',fingerprint:'f'.repeat(64)})).rejects.toMatchObject({code:'SMTP_POR_VERIFICAR',phase:'AFTER_SEND'});});
 it('sobre inválido → rechazo antes de tocar el ledger',async()=>{const sb=sbDouble();await expect(commercialDelivery(sb,{transport:{send:vi.fn()}}).deliver({key:'k',envelopeTo:'x\r\ny@qa.invalid',raw:'x',fingerprint:'f'.repeat(64)})).rejects.toMatchObject({status:400});expect(sb.calls.length).toBe(0);});
});
