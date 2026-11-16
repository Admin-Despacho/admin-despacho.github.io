import EmbeddedPostgres from './tooling/node_modules/embedded-postgres/dist/index.js';
import pg from './tooling/node_modules/pg/lib/index.js';
import {readFileSync,writeFileSync,mkdirSync} from 'node:fs';
mkdirSync('QA/results',{recursive:true});
const server=new EmbeddedPostgres({databaseDir:'/tmp/okd-com-work-portable',port:55449,user:'postgres',password:'local-commercial-qa',persistent:false,postgresFlags:['-c','unix_socket_directories=','-c','listen_addresses=127.0.0.1'],initdbFlags:['--locale=C','--encoding=UTF8'],onLog:()=>{},onError:()=>{}});
const vars={};
const pre=s=>s.split('\n').map(l=>{if(l.startsWith('\\set ')){const m=l.match(/^\\set\s+(\w+)\s+(.+)$/);if(m)vars[m[1]]=m[2].trim().replace(/^'|'$/g,'');return ''}if(l.startsWith('\\'))throw Error('Metacomando '+l);return l}).join('\n').replace(/:'([A-Za-z0-9_]+)'/g,(_,k)=>"'"+vars[k].replaceAll("'","''")+"'");
let c;try{
 await server.initialise();await server.start();c=new pg.Client({host:'127.0.0.1',port:55449,user:'postgres',password:'local-commercial-qa',database:'postgres'});await c.connect();
 for(const f of ['QA/base_setup.sql','propuestas/comercial/20261201000100_comercial_autorizaciones.sql','propuestas/comercial/comercial_test.sql'])await c.query(pre(readFileSync(f,'utf8')));
 const rows=(await c.query('select name,ok,detail from tst.results')).rows;writeFileSync('QA/results/package.json',JSON.stringify(rows,null,2));console.log('PAQUETE',rows.filter(x=>x.ok).length,'/',rows.length);
 await (await import('./concurrency.mjs')).runConcurrency(c);
 await c.query(pre(readFileSync('QA/extra.sql','utf8')));const extra=(await c.query('select * from work_checks')).rows;writeFileSync('QA/results/work.json',JSON.stringify(extra,null,2));console.log('WORK',extra.filter(x=>x.ok).length,'/',extra.length);
 if(rows.some(x=>!x.ok)||extra.some(x=>!x.ok))process.exitCode=1;
}finally{await c?.end();await server.stop();}
