import pg from './tooling/node_modules/pg/lib/index.js';
import {writeFileSync} from 'node:fs';
export async function runConcurrency(c){
 const cfg={host:'127.0.0.1',port:55449,user:'postgres',password:'local-commercial-qa',database:'postgres'};
 const C='c0000000-0000-0000-0000-0000000000c1',W='c0000000-0000-0000-0000-0000000000a1',F='c0000000-0000-0000-0000-0000000000a2';
 async function as(client,user){await client.query('begin');await client.query("select set_config('request.jwt.claim.sub',$1,true),set_config('request.jwt.claim.role','authenticated',true)",[user]);await client.query('set local role authenticated');}
 const a=new pg.Client(cfg),b=new pg.Client(cfg);await a.connect();await b.connect();const checks=[];
 try{
  const cid=(await c.query("select id from com_clients where erp_id='101'")).rows[0].id;
  await as(a,C);const q=(await a.query("select com_create_request('FINANCIACION',$1,'QA-RACE','{\"amount\":100,\"installments\":1}',null,'work-race') q",[cid])).rows[0].q;await a.query('commit');
  await as(a,W);await as(b,F);await a.query("select com_decide($1,1,'APROBAR',null,null)",[q.id]);
  let finished=false;const second=b.query("select com_decide($1,1,'RECHAZAR',null,'QA competencia')",[q.id]).then(()=>({code:'UNSAFE'}),e=>({code:e.code,message:e.message})).finally(()=>finished=true);
  await new Promise(r=>setTimeout(r,150));const waited=!finished;await a.query('commit');const result=await second;await b.query('rollback');
  const n=(await c.query("select count(*)::int n from com_request_events where request_id=$1 and kind in ('APROBADA','RECHAZADA')",[q.id])).rows[0].n;
  checks.push({case:'dos conexiones: una decision, bloqueo real y rechazo de segunda',pass:waited&&result.code==='40001'&&n===1,waited,result,decisions:n});
  await as(a,C);await as(b,C);
  const sql="select com_create_request('FINANCIACION',$1,'QA-IDEMP','{\"amount\":100,\"installments\":1}',null,'work-race-idem') q";
  const first=(await a.query(sql,[cid])).rows[0].q;const pending=b.query(sql,[cid]);await new Promise(r=>setTimeout(r,100));await a.query('commit');const next=(await pending).rows[0].q;await b.query('commit');
  checks.push({case:'dos conexiones: mismo op_id legitimo, una solicitud y reintento',pass:first.id===next.id&&next.repeated});
  writeFileSync('QA/results/concurrency.json',JSON.stringify(checks,null,2));console.log('CONCURRENCY',JSON.stringify(checks));if(checks.some(x=>!x.pass))throw Error('Concurrency failed');
 }finally{await Promise.allSettled([a.query('rollback'),b.query('rollback')]);await a.end();await b.end();}
}
