// SMTP sobre TLS implícito. Sin logs de credenciales ni fallback a otro proveedor.
// Un rechazo explícito permite reintentar según su clase. Respuesta perdida después de DATA es INCIERTA.
const enc = new TextEncoder();
const address = s => typeof s === 'string' && /^[A-Za-z0-9.!#$%&'*+\/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$/.test(s) && !/[\r\n<>]/.test(s);
const b64 = s => { let x=''; for (const b of enc.encode(s)) x+=String.fromCharCode(b); return btoa(x); };
export class SmtpError extends Error {
  constructor(code, { ambiguous=false, status=503 }={}) { super(code); this.code=code; this.status=status; this.phase=ambiguous?'AFTER_SEND':'BEFORE_SEND'; }
}
export function smtpTransport({ connectTls, timeoutMs=25000, maxBytes=25*1024*1024 }) {
  if (typeof connectTls !== 'function') throw new Error('SMTP_TLS_REQUIRED');
  async function run(c, message, beforeData) {
    if(c.host!=='wo47.wiroos.host'||c.port!==465||c.user!=='fgutierrez@okaccesorios.com'||c.from!==c.user||!c.password) throw new SmtpError('SMTP_CONFIG_INVALID',{status:401});
    if(message && (!address(message.to)||message.from!==c.from||enc.encode(message.raw).length>maxBytes||/\0/.test(message.raw))) throw new SmtpError('SMTP_MESSAGE_INVALID',{status:400});
    let conn=null, expired=false, dataStarted=false, rejected=false, accepted=false, buf='';
    let timer;
    const work=async()=>{
      conn=await connectTls({hostname:c.host,port:465});
      if(expired){try{conn.close();}catch{} throw new SmtpError('SMTP_TIMEOUT');}
      const write=async text=>{const bytes=enc.encode(text);let offset=0;while(offset<bytes.length){const n=await conn.write(bytes.subarray(offset));if(!n)throw Error('WRITE_EOF');offset+=n;}};
      const line=async()=>{while(!buf.includes('\r\n')){const b=new Uint8Array(4096);const n=await conn.read(b);if(n===null||n===0)throw Error('READ_EOF');buf+=new TextDecoder().decode(b.subarray(0,n));if(buf.length>32768)throw Error('REPLY_TOO_LONG');}const p=buf.indexOf('\r\n'),s=buf.slice(0,p);buf=buf.slice(p+2);return s;};
      const reply=async()=>{let code=null;const lines=[];for(let i=0;i<100;i++){const l=await line(),m=/^(\d{3})([ -])(.*)$/.exec(l);if(!m||code!==null&&code!==+m[1])throw Error('INVALID_REPLY');code=+m[1];lines.push(m[3]);if(m[2]===' ')return {code,lines};}throw Error('REPLY_TOO_LONG');};
      const requireCode=(r,expected,stage)=>{if(r.code===expected)return r;if(stage==='AUTH'&&[530,534,535,538].includes(r.code))throw new SmtpError('SMTP_AUTH_REJECTED',{status:401});throw new SmtpError('SMTP_'+stage+'_'+r.code,{status:r.code>=400&&r.code<500?503:400});};
      const cmd=async(s,expected,stage)=>{await write(s+'\r\n');return requireCode(await reply(),expected,stage);};
      requireCode(await reply(),220,'GREETING');
      const ehlo=await cmd('EHLO okdespacho.local',250,'EHLO');
      if(!ehlo.lines.some(l=>/^AUTH(?:=|\s).*\bPLAIN\b/i.test(l)))throw new SmtpError('SMTP_AUTH_UNSUPPORTED',{status:401});
      await write('AUTH PLAIN '+b64('\0'+c.user+'\0'+c.password)+'\r\n');
      let ar=await reply();if(ar.code===334){await write(b64('\0'+c.user+'\0'+c.password)+'\r\n');ar=await reply();}requireCode(ar,235,'AUTH');
      if(!message)return {authenticated:true}; // Prueba SOLO AUTH: nunca MAIL FROM, RCPT o DATA.
      if(beforeData)await beforeData();
      await cmd('MAIL FROM:<'+c.from+'>',250,'FROM');
      await write('RCPT TO:<'+message.to+'>\r\n');const rc=await reply();if(rc.code!==251)requireCode(rc,250,'RECIPIENT');
      if(beforeData)await beforeData();
      await cmd('DATA',354,'DATA');
      // Desde el primer byte DATA, un corte podría haber dejado un correo aceptado: no repetirlo a ciegas.
      dataStarted=true;
      const raw=message.raw.replace(/\r?\n/g,'\r\n').replace(/(^|\r\n)\./g,'$1..');
      await write(raw+(raw.endsWith('\r\n')?'':'\r\n')+'.\r\n');
      const final=await reply();
      if(final.code!==250){rejected=true;requireCode(final,250,'REJECTED');}
      accepted=true;
      const queueId=final.lines.join(' ').match(/\b(?:id[= ]|queued as )([A-Za-z0-9-]{3,80})\b/i)?.[1];
      return {id:'smtp:'+(queueId||crypto.randomUUID()),accepted:true};
    };
    try{
      return await Promise.race([work(),new Promise((_,reject)=>{timer=setTimeout(()=>{expired=true;try{conn?.close();}catch{}reject(new SmtpError('SMTP_TIMEOUT',{ambiguous:dataStarted&&!rejected&&!accepted}));},timeoutMs);})]);
    }catch(e){
      if(e?.code==='ABORTED')throw e;
      if(dataStarted&&!rejected&&!accepted)throw new SmtpError('SMTP_ACCEPTANCE_UNKNOWN',{ambiguous:true});
      if(e instanceof SmtpError)throw e;
      throw new SmtpError('SMTP_CONNECTION_FAILED');
    }finally{clearTimeout(timer);try{conn?.close();}catch{}}
  }
  return {probe:c=>run(c,null),send:(c,m,beforeData)=>run(c,m,beforeData)};
}
