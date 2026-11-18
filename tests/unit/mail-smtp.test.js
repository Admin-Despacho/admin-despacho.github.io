import {describe,it,expect,vi} from 'vitest';
import {smtpTransport} from '../../supabase/functions/_shared/smtp-transport.js';
import {corporateMail,normalizeMail,corporateMime,routedMailProvider} from '../../supabase/functions/_shared/corporate-mail.js';
const c={host:'mail.okaccesorios.com',port:26,user:'fgutierrez@okaccesorios.com',from:'fgutierrez@okaccesorios.com',password:'test-only',secret_version:'v1'};
const msg={from:c.from,to:'test@example.test',raw:'From: <'+c.from+'>\r\nTo: <test@example.test>\r\n\r\n.line\r\n.'};
// Servidor SMTP SIMULADO con STARTTLS (sin red): antes del TLS ofrece STARTTLS y NO AUTH; después del TLS ofrece AUTH. Nunca envía correo real.
function wire({auth=235,rcpt=250,final=250,failData=false,partial=false,starttls=true,starttlsCode=220,inject=false,mech='PLAIN LOGIN'}={}){let buf='220 test\r\n',data=false,closed=false,tls=false,login=0;const commands=[];
 const w={commands,get closed(){return closed;},get tls(){return tls;},startTlsNow(){tls=true;},async read(b){if(closed)return null;if(!buf)return new Promise(()=>{});const n=Math.min(b.length,buf.length,partial?3:buf.length);b.set(new TextEncoder().encode(buf.slice(0,n)));buf=buf.slice(n);return n;},
 async write(bytes){const t=new TextDecoder().decode(bytes);commands.push((tls?'[TLS] ':'[PLANO] ')+t);
  if(data){if(failData)throw Error('lost');buf+=final+' final\r\n';data=false;}
  else if(t.startsWith('EHLO'))buf+=tls?'250-test\r\n250 AUTH '+mech+'\r\n':'250-test\r\n'+(starttls?'250-STARTTLS\r\n':'')+'250 SIZE 1000000\r\n';
  else if(t==='STARTTLS\r\n')buf+=starttlsCode+' go ahead\r\n'+(inject?'250 inyectado\r\n':'');
  else if(t.startsWith('AUTH PLAIN'))buf+=auth+' auth\r\n';
  else if(t==='AUTH LOGIN\r\n'){login=1;buf+='334 VXNlcm5hbWU6\r\n';}
  else if(login===1){login=2;buf+='334 UGFzc3dvcmQ6\r\n';}
  else if(login===2){login=0;buf+=auth+' auth\r\n';}
  else if(t.startsWith('MAIL'))buf+='250 sender\r\n';else if(t.startsWith('RCPT'))buf+=rcpt+' recipient\r\n';else if(t==='DATA\r\n'){buf+='354 data\r\n';data=true;}
  return bytes.length;},close(){closed=true;}};return w;}
const T=(w,{tlsFail=false}={})=>smtpTransport({connect:async()=>w,startTls:async x=>{if(tlsFail)throw Error('certificado inválido');x.startTlsNow();return x;}});
describe('SMTP protocol, simulated wire: no real email',()=>{
 it('AUTH-only probe never issues MAIL/RCPT/DATA',async()=>{const w=wire();await expect(T(w).probe(c)).resolves.toEqual({authenticated:true});expect(w.commands.some(x=>/^(MAIL|RCPT|DATA)/.test(x))).toBe(false);expect(w.closed).toBe(true);});
 it('partial replies, successful acceptance, final permission checks and dot-stuffing',async()=>{const w=wire({partial:true}),check=vi.fn();expect((await T(w).send(c,msg,check)).id).toMatch(/^smtp:/);expect(check).toHaveBeenCalledTimes(2);expect(w.commands.at(-1)).toContain('\r\n..line\r\n..\r\n.\r\n');expect(w.closed).toBe(true);});
 for(const auth of [530,534,535,538])it('AUTH '+auth+' is before send',async()=>{const w=wire({auth});await expect(T(w).send(c,msg)).rejects.toMatchObject({status:401,phase:'BEFORE_SEND'});expect(w.commands.some(x=>x.startsWith('MAIL'))).toBe(false);});
 for(const rcpt of [450,550])it('RCPT '+rcpt+' does not issue DATA',async()=>{const w=wire({rcpt});await expect(T(w).send(c,msg)).rejects.toMatchObject({status:rcpt===450?503:400,phase:'BEFORE_SEND'});expect(w.commands).not.toContain('DATA\r\n');});
 it('lost response after DATA is ambiguous',async()=>{const w=wire({failData:true});await expect(T(w).send(c,msg)).rejects.toMatchObject({phase:'AFTER_SEND'});});
 for(const final of [451,550])it('explicit final rejection '+final+' is safe to classify',async()=>{const w=wire({final});await expect(T(w).send(c,msg)).rejects.toMatchObject({status:final===451?503:400,phase:'BEFORE_SEND'});});
 it('connection timeout is bounded and closes late sockets',async()=>{vi.useFakeTimers();try{let release;const w=wire(),t=smtpTransport({timeoutMs:10,connect:()=>new Promise(r=>release=r),startTls:async x=>x});const p=expect(t.probe(c)).rejects.toMatchObject({phase:'BEFORE_SEND'});await vi.advanceTimersByTimeAsync(11);await p;release(w);await vi.advanceTimersByTimeAsync(1);expect(w.closed).toBe(true);}finally{vi.useRealTimers();}});
 it('permission revoked just before DATA stops the email',async()=>{const w=wire();let n=0;await expect(T(w).send(c,msg,()=>{if(++n===2)throw Object.assign(Error('no'),{code:'ABORTED'});})).rejects.toMatchObject({code:'ABORTED'});expect(w.commands).not.toContain('DATA\r\n');});
 it('refuses other host, port, sender and recipient injection',async()=>{for(const bad of [{...c,port:587},{...c,port:465},{...c,host:'wo47.wiroos.host'},{...c,host:'evil.test'},{...c,from:'x@evil.test'}])await expect(smtpTransport({connect:vi.fn(),startTls:vi.fn()}).probe(bad)).rejects.toMatchObject({code:'SMTP_CONFIG_INVALID'});await expect(smtpTransport({connect:vi.fn(),startTls:vi.fn()}).send(c,{...msg,to:'x@test.test\r\nRCPT TO:y@test.test'})).rejects.toMatchObject({status:400});});
});
function fake({mode='SMTP',claim='READY',finishError=false}={}){const calls=[],sent=vi.fn(async()=>({id:'smtp:accepted'}));let stored=null;const sb={rpc:async(name,args)=>{calls.push([name,args]);if(name==='comm_mail_runtime')return {data:{provider:mode,connected:true,email:c.from,secret_version:'v1',available_slots:10}};if(name==='comm_smtp_credentials')return {data:c};if(name==='comm_smtp_claim')return {data:{state:stored?'ACCEPTED':claim,provider_id:stored,token:'token'}};if(name==='comm_smtp_lookup')return {data:null};if(name==='comm_smtp_finish'){if(finishError)return {error:{message:'db'}};if(args.p_state==='ACCEPTED')stored=args.p_provider_id;return {data:null};}return {data:true};}};return {sb,calls,sent,transport:{send:sent,probe:vi.fn(async()=>({authenticated:true}))}};}
const m={to:'test@example.test',idempotencyKey:'job:1',subject:'Prueba',html:'<img src="cid:logo"><p>texto</p>',text:'texto',attachments:[{filename:'logo.png',content:'aGk=',content_type:'image/png',content_id:'logo'}]};
describe('SMTP ledger adapter and MIME',()=>{
 it('preserves CID, HTML/text and attachments with deterministic MIME',()=>{const n=normalizeMail(m),r=corporateMime(n,c.from,'stable');expect(r).toContain('Content-ID: <logo>');expect(r).toContain('Content-Disposition: inline');expect(r).toContain('aGk=');expect(r).toBe(corporateMime(n,c.from,'stable'));expect(normalizeMail({...m,attachments:[{filename:'x.pdf',content:new Uint8Array([1,2])}]}).attachments[0].content).toBe('AQI=');expect(r).not.toContain('undefined');});
 it('rejects bad recipient, missing operation, bad attachment and MIME injection',()=>{for(const bad of [{...m,to:'x\r\ny@test.test'},{...m,idempotencyKey:''},{...m,attachments:[{filename:'a',content:'%%'}]},{...m,attachments:[{filename:'a',content:'aGk=',mime:'text/plain; bad'}]}])expect(()=>normalizeMail(bad)).toThrow();});
 it('one SMTP acceptance across retries',async()=>{const f=fake(),mail=corporateMail(f.sb,{transport:f.transport,scope:'test'});await mail.send(m);await mail.send(m);expect(f.sent).toHaveBeenCalledTimes(1);});
 for(const claim of ['HELD','BUSY','CONFLICT','REJECTED','RATE_LIMIT'])it(claim+' never transmits',async()=>{const f=fake({claim});await expect(corporateMail(f.sb,{transport:f.transport}).send(m)).rejects.toThrow();expect(f.sent).not.toHaveBeenCalled();});
 it('lost DB acknowledgment after acceptance is HELD',async()=>{const f=fake({finishError:true});await expect(corporateMail(f.sb,{transport:f.transport}).send(m)).rejects.toMatchObject({phase:'AFTER_SEND'});expect(f.sent).toHaveBeenCalledTimes(1);});
 it('no SMTP-to-legacy fallback on failure',async()=>{const f=fake({claim:'RATE_LIMIT'}),legacy={send:vi.fn()};await expect(routedMailProvider(f.sb,legacy,{transport:f.transport}).send(m)).rejects.toThrow();expect(legacy.send).not.toHaveBeenCalled();});
 it('LEGACY preserves existing provider',async()=>{const f=fake({mode:'LEGACY'}),legacy={send:vi.fn(async()=>({id:'legacy'}))};expect(await routedMailProvider(f.sb,legacy,{transport:f.transport}).send(m)).toEqual({id:'legacy'});expect(legacy.send).toHaveBeenCalledTimes(1);expect(f.sent).not.toHaveBeenCalled();});
 it('namespaced operation, stable fingerprint, and final permission guard',async()=>{const f=fake(),check=vi.fn();await corporateMail(f.sb,{transport:f.transport,scope:'reports'}).send({...m,beforeData:check});expect(f.calls.find(x=>x[0]==='comm_smtp_claim')[1]).toMatchObject({p_key:'reports:job:1',p_fingerprint:expect.stringMatching(/^[a-f0-9]{64}$/)});await f.sent.mock.calls[0][2]();expect(check).toHaveBeenCalled();});
});

describe('STARTTLS obligatorio (puerto 26): credenciales SOLO dentro del TLS',()=>{
 // en CLARO solo pueden viajar EHLO y STARTTLS; ningún comando AUTH (ni sus datos) en ningún momento
 const sinCredenciales=w=>w.commands.every(x=>!x.startsWith('[PLANO] ')||/^\[PLANO\] (EHLO |STARTTLS\r\n)/.test(x))&&!w.commands.some(x=>/AUTH/.test(x));
 it('flujo certificado: EHLO → STARTTLS → TLS → EHLO → AUTH; AUTH y MAIL viajan SOLO por TLS',async()=>{const w=wire();await T(w).send(c,msg);
   expect(w.commands[0]).toMatch(/^\[PLANO\] EHLO/);expect(w.commands[1]).toBe('[PLANO] STARTTLS\r\n');expect(w.commands[2]).toMatch(/^\[TLS\] EHLO/);
   expect(w.commands.filter(x=>/AUTH|MAIL|RCPT|DATA/.test(x)).every(x=>x.startsWith('[TLS] '))).toBe(true);});
 it('el servidor NO ofrece STARTTLS → se corta ANTES de AUTH (sin degradar a texto plano)',async()=>{const w=wire({starttls:false});await expect(T(w).probe(c)).rejects.toMatchObject({code:'SMTP_STARTTLS_UNSUPPORTED',phase:'BEFORE_SEND'});expect(sinCredenciales(w)).toBe(true);expect(w.tls).toBe(false);});
 for(const code of [454,502])it('STARTTLS rechazado ('+code+') → sin credenciales',async()=>{const w=wire({starttlsCode:code});await expect(T(w).probe(c)).rejects.toMatchObject({code:'SMTP_STARTTLS_'+code});expect(sinCredenciales(w)).toBe(true);});
 it('datos colados después del 220 de STARTTLS (inyección) → sesión descartada, sin TLS ni AUTH',async()=>{const w=wire({inject:true});await expect(T(w).probe(c)).rejects.toMatchObject({code:'SMTP_STARTTLS_INJECTION'});expect(w.tls).toBe(false);expect(sinCredenciales(w)).toBe(true);});
 it('certificado o negociación TLS inválidos → SMTP_TLS_FAILED, sin AUTH',async()=>{const w=wire();await expect(T(w,{tlsFail:true}).probe(c)).rejects.toMatchObject({code:'SMTP_TLS_FAILED',phase:'BEFORE_SEND'});expect(sinCredenciales(w)).toBe(true);});
 it('AUTH LOGIN (el certificado el 17/11) cuando el servidor no ofrece PLAIN → 235',async()=>{const w=wire({mech:'LOGIN'});await expect(T(w).probe(c)).resolves.toEqual({authenticated:true});expect(w.commands.some(x=>x==='[TLS] AUTH LOGIN\r\n')).toBe(true);});
 for(const auth of [535,534])it('AUTH LOGIN rechazado '+auth+' → SMTP_AUTH_REJECTED antes de enviar',async()=>{const w=wire({mech:'LOGIN',auth});await expect(T(w).send(c,msg)).rejects.toMatchObject({code:'SMTP_AUTH_REJECTED',status:401,phase:'BEFORE_SEND'});expect(w.commands.some(x=>/MAIL|RCPT|DATA/.test(x))).toBe(false);});
 it('sin AUTH anunciado dentro del TLS → SMTP_AUTH_UNSUPPORTED',async()=>{const w=wire({mech:''});await expect(T(w).probe(c)).rejects.toMatchObject({code:'SMTP_AUTH_UNSUPPORTED'});});
 it('servidor o puerto distintos del certificado (incluido el anterior wo47:465) → rechazo SIN conectar',async()=>{const connect=vi.fn();for(const bad of [{...c,port:465},{...c,host:'wo47.wiroos.host'}])await expect(smtpTransport({connect,startTls:vi.fn()}).probe(bad)).rejects.toMatchObject({code:'SMTP_CONFIG_INVALID'});expect(connect).not.toHaveBeenCalled();});
});
