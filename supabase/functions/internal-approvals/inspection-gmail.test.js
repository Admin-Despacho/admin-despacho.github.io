import { inspectionGmailSender, GMAIL_HOLD, canEmailInspection } from './inspection-gmail.js';
const assert = (x,m='assertion')=>{if(!x)throw Error(m);};
Deno.test('Current Gmail scope: active Admin all teams; Supervisor own team only even after Admin demotion',()=>{
 const foreign={status:'APROBADA',created_by:'other',team_supervisor_id:'other-team'};
 assert(canEmailInspection({role:'ADMIN',status:'ACTIVO'},foreign,'user'));
 assert(!canEmailInspection({role:'SUPERVISOR_DESPACHO',status:'ACTIVO'},foreign,'user'));
 assert(canEmailInspection({role:'SUPERVISOR_DESPACHO',status:'ACTIVO'},{...foreign,team_supervisor_id:'user'},'user'));
 assert(canEmailInspection({role:'SUPERVISOR_DESPACHO',status:'ACTIVO'},{...foreign,created_by:'user'},'user'));
});
Deno.test('Gmail: disabled Admin/Supervisor, unapproved inspections and other roles denied',()=>{
 const own={status:'APROBADA',created_by:'user',team_supervisor_id:'user'};
 for(const role of ['ADMIN','SUPERVISOR_DESPACHO']){
  assert(!canEmailInspection({role,status:'DESHABILITADO'},own,'user'));
  assert(!canEmailInspection({role,status:'ACTIVO'},{...own,status:'PENDIENTE'},'user'));
 }
 for(const role of ['OPERARIO_DEPOSITO','TRANSPORTISTA_INTERNO','TRANSPORTISTA','SOLO_LECTURA'])assert(!canEmailInspection({role,status:'ACTIVO'},own,'user'));
});
const fixture = (options={}) => {
  const job={id:1,inspection_id:'qa',requested_by:'sup',status:'ERROR',error:'old error',retry_count:2,recipients:['qa@example.invalid','QA@example.invalid'],subject:'Inspección QA',body:'<script>test</script>'};
  let row=structuredClone(job),posts=0;const log=[];
  const sender=inspectionGmailSender({
    async claim(j,lock){if(row.status!==j.status||row.error!==j.error)return false;row.error=lock;row.status='ERROR';return true;},
    async finish(j,lock,p){assert(row.error===lock);if(options.finishFails)throw Error('DB unavailable');Object.assign(row,p);},
    authorized:async()=>options.authorized!==false,
    audit:async(j,a,p)=>{if(options.auditFails)throw Error('audit unavailable');log.push({a,p});},
    gmailStore:{gmailStatus:async()=>({connected:options.connected!==false,email:'sender@example.invalid'}),acquireRate:async()=>({wait_ms:0})},
    provider:{prepare:async()=>{if(options.tokenFails)throw Error('invalid_grant');return 'token';},
      post:async raw=>{posts++;log.push({raw});if(options.network)throw Object.assign(Error('network after send'),{phase:'AFTER_SEND'});return {status:options.http||200,ok:!options.http,json:{id:'gmail-123'}};},
      interpret:r=>{if(!r.ok)throw Object.assign(Error('Gmail rejected'),{status:r.status});return r.json;}}
  });
  return {job,sender,row:()=>row,posts:()=>posts,log};
};
Deno.test('Gmail success: one authorized recipient, audit provider ID, immutable request content',async()=>{
 const f=fixture();const r=await f.sender(f.job);assert(r.status==='ENVIADO');assert(f.posts()===1);assert(f.row().sent_at);assert(f.log.some(x=>x.p?.gmail_id==='gmail-123'));
 const raw=atob(f.log.find(x=>x.raw).raw.replace(/-/g,'+').replace(/_/g,'/'));assert(raw.includes('To: <qa@example.invalid>'));assert(!raw.includes('Bcc:'));assert(f.row().body===f.job.body);
});
Deno.test('Concurrent invocations and stale retry: at most one HTTP send',async()=>{
 const f=fixture();await Promise.all([f.sender(f.job),f.sender(f.job)]);await f.sender(f.job);assert(f.posts()===1);
});
Deno.test('Timeout after POST: durable hold, no automatic retry',async()=>{
 const f=fixture({network:true});assert((await f.sender(f.job)).held);assert(f.row().error.startsWith(GMAIL_HOLD));await f.sender(f.row());assert(f.posts()===1);
});
for(const failure of ['auditFails','finishFails'])Deno.test('Acceptance then '+failure+': no duplicate retry',async()=>{
 const f=fixture({[failure]:true});assert((await f.sender(f.job)).held);await f.sender(f.row());assert(f.posts()===1);
});
Deno.test('Gmail 503 is ambiguous: hold without retry',async()=>{const f=fixture({http:503});assert((await f.sender(f.job)).held);});
Deno.test('Gmail 403 is a definite refusal: audited error, retry count advances',async()=>{const f=fixture({http:403});assert(!(await f.sender(f.job)).held);assert(f.row().retry_count===3);assert(!f.row().error.startsWith(GMAIL_HOLD));});
for(const opts of [{connected:false},{tokenFails:true},{authorized:false}])Deno.test('Preflight failure has no Gmail POST '+JSON.stringify(opts),async()=>{const f=fixture(opts);assert((await f.sender(f.job)).status==='ERROR');assert(f.posts()===0);});
