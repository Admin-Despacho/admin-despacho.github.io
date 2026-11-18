// SOLO PRUEBAS LOCALES (no toca QA/run.mjs de Work). Aplica la base de Work + la migración de CUOTAS y RESPALDO, y separa resultados:
// PAQUETE (pruebas del módulo) · CONCURRENCIA · WORK (casos de la auditoría, SIN modificar) · CORRECCIONES (cuotas y respaldo).
import EmbeddedPostgres from './tooling/node_modules/embedded-postgres/dist/index.js';
import pg from './tooling/node_modules/pg/lib/index.js';
import {readFileSync,writeFileSync,mkdirSync} from 'node:fs';
mkdirSync('QA/results',{recursive:true});
const server=new EmbeddedPostgres({databaseDir:'/tmp/okd-com-correcciones',port:55449,user:'postgres',password:'local-commercial-qa',persistent:false,postgresFlags:['-c','unix_socket_directories=','-c','listen_addresses=127.0.0.1'],initdbFlags:['--locale=C','--encoding=UTF8'],onLog:()=>{},onError:()=>{}});
const vars={};
const pre=s=>s.split('\n').map(l=>{if(l.startsWith('\\set ')){const m=l.match(/^\\set\s+(\w+)\s+(.+)$/);if(m)vars[m[1]]=m[2].trim().replace(/^'|'$/g,'');return ''}if(l.startsWith('\\'))throw Error('Metacomando '+l);return l}).join('\n').replace(/:'([A-Za-z0-9_]+)'/g,(_,k)=>"'"+vars[k].replaceAll("'","''")+"'");
let c;const out={};try{
 await server.initialise();await server.start();c=new pg.Client({host:'127.0.0.1',port:55449,user:'postgres',password:'local-commercial-qa',database:'postgres'});await c.connect();
 for(const f of ['QA/base_setup.sql','QA/storage_stub.sql','propuestas/comercial/20261201000100_comercial_autorizaciones.sql','propuestas/comercial/20261201000200_comercial_cuotas_respaldo.sql','propuestas/comercial/20261201000300_comercial_consultar_aprobacion.sql','propuestas/comercial/20261201000400_comercial_alarma_urgente.sql','propuestas/comercial/20261201000500_comercial_admin_sesion_vigente.sql','propuestas/comercial/20261201000600_comercial_modulo_historial.sql','propuestas/comercial/20261201000700_comercial_sesion_vigente_total.sql','propuestas/comercial/20261201000800_comercial_v4_alarma_escala_push.sql','propuestas/comercial/20261201000900_comercial_v5_permisos_kpi_fechas.sql','propuestas/comercial/20261201001000_comercial_v6_push_instalacion.sql','propuestas/comercial/20261201001100_comercial_kpi_facturacion.sql','propuestas/comercial/20261201001200_comercial_cuotas_calendario.sql','propuestas/comercial/20261201001300_comercial_alarma_solicitud.sql'])await c.query(pre(readFileSync(f,'utf8')));
 // N-V4-03: el modo del KPI que deja la INSTALACIÓN (se verifica en V5-K01). Después, activación EXPLÍCITA de PROVISORIO solo para probar el CÁLCULO del KPI
 out.kpi_tras_instalar=(await c.query("select kpi_mode from public.com_settings where id='DEFAULT'")).rows[0].kpi_mode; console.log('KPI tras instalar:', out.kpi_tras_instalar);
 await c.query({text:'create temp table v5_kpi_instalacion(modo text); insert into v5_kpi_instalacion values ($1)', values:[out.kpi_tras_instalar]}).catch(async()=>{ await c.query('create temp table v5_kpi_instalacion(modo text)'); await c.query({text:'insert into v5_kpi_instalacion values ($1)', values:[out.kpi_tras_instalar]}); });
 await c.query("update public.com_settings set kpi_mode='PROVISORIO' where id='DEFAULT'");
 await c.query(pre(readFileSync('propuestas/comercial/comercial_test.sql','utf8')));
 out.paquete=(await c.query('select name,ok,detail from tst.results')).rows;console.log('PAQUETE',out.paquete.filter(x=>x.ok).length,'/',out.paquete.length);
 await (await import('./concurrency.mjs')).runConcurrency(c);
 await c.query(pre(readFileSync('QA/extra.sql','utf8')));out.work=(await c.query('select * from work_checks')).rows;console.log('WORK',out.work.filter(x=>x.ok).length,'/',out.work.length);
 for(const x of out.work) if(!x.ok) console.log('FAIL | '+x.name+' | '+String(x.detail||'').slice(0,300));
 await c.query(pre(readFileSync('QA/extra_cuotas_respaldo.sql','utf8')));out.correcciones=(await c.query('select * from cr_checks order by name')).rows;
 console.log('CORRECCIONES',out.correcciones.filter(x=>x.ok).length,'/',out.correcciones.length);
 for(const x of out.correcciones)console.log((x.ok?'PASS':'FAIL')+' | '+x.name+' | '+String(x.detail||'').slice(0,240));
 await c.query(pre(readFileSync('QA/extra_consultar_aprobacion.sql','utf8')));out.consultar=(await c.query('select * from ca_checks order by name')).rows;console.log('CONSULTAR APROBACIÓN',out.consultar.filter(x=>x.ok).length,'/',out.consultar.length);
 for(const x of out.consultar)console.log((x.ok?'PASS':'FAIL')+' | '+x.name+' | '+String(x.detail||'').slice(0,240));
 await c.query(pre(readFileSync('QA/extra_alarma.sql','utf8')));out.alarma=(await c.query('select * from al_checks order by name')).rows;console.log('ALARMA',out.alarma.filter(x=>x.ok).length,'/',out.alarma.length);
 for(const x of out.alarma)console.log((x.ok?'PASS':'FAIL')+' | '+x.name+' | '+String(x.detail||'').slice(0,240));
 // ===== B-AL-06 · CONCURRENCIA REAL: dos conexiones a la vez =====
 { const cfgc={host:'127.0.0.1',port:55449,user:'postgres',password:'local-commercial-qa',database:'postgres'}, O='e0000000-0000-0000-0000-000000000006';
   const k1=new pg.Client(cfgc), k2=new pg.Client(cfgc); await k1.connect(); await k2.connect(); const conc=[];
   await c.query(`select tst.u('${O}'); set role authenticated; select public.reserve_orders('AL-C', array['27301','27302']); reset role;`);
   const raise=(k,ord,op,sleep)=>(async()=>{ const t0=Date.now(); await k.query('begin'); await k.query(`select tst.u('${O}')`); await k.query('set local role authenticated');
     let v; try{ v=(await k.query(`select public.com_alarm_raise($1,'AL-C','x','',$2,$3)::text r`,[ord,'Prueba de concurrencia real',op])).rows[0].r; }catch(e){ v='ERR '+e.message; }
     const ms=Date.now()-t0; if(sleep) await k.query('select pg_sleep(1.2)'); await k.query('commit'); return Object.assign(new String(v),{ms}); })();
   // C1: mismo op_id para DOS pedidos distintos, solapados (la primera retiene el bloqueo 1,2 s)
   let p1=raise(k1,'27301','op-conc-1',true); await new Promise(z=>setTimeout(z,250)); let p2=raise(k2,'27302','op-conc-1',false); let [a1,a2]=await Promise.all([p1,p2]);
   const n1=(await c.query(`select count(*)::int n from public.com_alarms where op_id='op-conc-1'`)).rows[0].n;
   conc.push({name:'AL-C1 (B-AL-06) CONCURRENCIA REAL: mismo op_id para DOS pedidos en conexiones simultáneas → se crea UNA alarma y la otra llamada recibe OP_ID_CONFLICT (sin error genérico ni datos)',
     ok: n1===1 && /"repeated": false/.test(a1) && /OP_ID_CONFLICT/.test(a2) && !/"number"/.test(a2) && a2.ms>=700, detail: 'la 2.ª conexión ESPERÓ '+a2.ms+' ms el bloqueo · '+a1.slice(0,50)+' | '+a2.slice(0,70)});
   // C2: la MISMA operación dos veces a la vez → una sola alarma; la segunda devuelve la misma (repetida)
   p1=raise(k1,'27302','op-conc-2',true); await new Promise(z=>setTimeout(z,250)); p2=raise(k2,'27302','op-conc-2',false); [a1,a2]=await Promise.all([p1,p2]);
   const n2=(await c.query(`select count(*)::int n from public.com_alarms where op_id='op-conc-2'`)).rows[0].n, j1=JSON.parse(String(a1)), j2=JSON.parse(String(a2));
   conc.push({name:'AL-C2 (B-AL-06) CONCURRENCIA REAL: la MISMA operación dos veces a la vez → UNA sola alarma; la segunda llamada devuelve el mismo resultado (repetida)',
     ok: n2===1 && j1.id===j2.id && j2.repeated===true && a2.ms>=700, detail: 'la 2.ª conexión ESPERÓ '+a2.ms+' ms · '+a1.slice(0,50)+' | '+a2.slice(0,50)});
   // C3 (B-W02): DOS op_id DISTINTOS para el MISMO pedido a la vez → UNA alarma; la otra recibe la existente; tras ATENDER, reintentar la 2.ª operación devuelve lo MISMO
   await c.query(`select tst.u('${O}'); set role authenticated; select public.reserve_orders('AL-C', array['27303']); reset role;`);
   p1=raise(k1,'27303','op-conc-3a',true); await new Promise(z=>setTimeout(z,250)); p2=raise(k2,'27303','op-conc-3b',false); [a1,a2]=await Promise.all([p1,p2]);
   const j3a=JSON.parse(String(a1)), j3b=JSON.parse(String(a2)), n3=(await c.query(`select count(*)::int n from public.com_alarms where order_ref='27303'`)).rows[0].n;
   await c.query(`select tst.u('c0000000-0000-0000-0000-0000000000a1'); set role authenticated; select public.com_alarm_attend('${j3a.id}', 1); reset role;`);
   const re3=JSON.parse((await c.query(`select tst.u('${O}'); set role authenticated; select public.com_alarm_raise('27303','AL-C','x','','Prueba de concurrencia real','op-conc-3b')::text r`)).slice(-1)[0].rows[0].r);
   await c.query('reset role'); const n3b=(await c.query(`select count(*)::int n from public.com_alarms where order_ref='27303'`)).rows[0].n;
   conc.push({name:'AL-C3 (B-W02) CONCURRENCIA REAL: dos op_id DISTINTOS para el MISMO pedido a la vez → UNA alarma; la otra recibe la existente (vinculada); tras ATENDER, reintentar la 2.ª operación devuelve la MISMA respuesta y no crea otra',
     ok: n3===1 && j3b.existing===true && j3b.id===j3a.id && a2.ms>=700 && re3.id===j3a.id && re3.repeated===true && n3b===1, detail: 'espera '+a2.ms+' ms · '+String(a2).slice(0,70)+' | reintento: '+JSON.stringify(re3).slice(0,70)});
   await k1.end(); await k2.end(); out.concurrencia=conc; console.log('CONCURRENCIA B-AL-06',conc.filter(x=>x.ok).length,'/',conc.length);
   for(const x of conc)console.log((x.ok?'PASS':'FAIL')+' | '+x.name+' | '+String(x.detail||'').slice(0,240)); }
 writeFileSync('/tmp/okd_cron_test.sql', readFileSync('propuestas/comercial/CRON_ALARMA_COMERCIAL.sql','utf8'));
 await c.query(pre(readFileSync('QA/extra_cron.sql','utf8')));out.cron=(await c.query('select * from cron_checks order by name')).rows;console.log('CRON B-W05',out.cron.filter(x=>x.ok).length,'/',out.cron.length);
 for(const x of out.cron)console.log((x.ok?'PASS':'FAIL')+' | '+x.name+' | '+String(x.detail||'').slice(0,240));
 await c.query(pre(readFileSync('QA/extra_historial.sql','utf8')));out.historial=(await c.query('select * from hi_checks order by name')).rows;console.log('HISTORIAL',out.historial.filter(x=>x.ok).length,'/',out.historial.length);
 for(const x of out.historial)console.log((x.ok?'PASS':'FAIL')+' | '+x.name+' | '+String(x.detail||'').slice(0,240));
 await c.query(pre(readFileSync('QA/extra_v4.sql','utf8')));out.v4=(await c.query('select * from v4_checks order by name')).rows;console.log('V4',out.v4.filter(x=>x.ok).length,'/',out.v4.length);
 for(const x of out.v4)console.log((x.ok?'PASS':'FAIL')+' | '+x.name+' | '+String(x.detail||'').slice(0,300));
 await c.query(pre(readFileSync('QA/extra_v5.sql','utf8')));out.v5=(await c.query('select * from v5_checks order by name')).rows;console.log('V5',out.v5.filter(x=>x.ok).length,'/',out.v5.length);
 for(const x of out.v5)console.log((x.ok?'PASS':'FAIL')+' | '+x.name+' | '+String(x.detail||'').slice(0,260));
 await c.query(pre(readFileSync('QA/extra_v6.sql','utf8')));out.v6=(await c.query('select * from v6_checks order by name')).rows;console.log('V6',out.v6.filter(x=>x.ok).length,'/',out.v6.length);
 for(const x of out.v6)console.log((x.ok?'PASS':'FAIL')+' | '+x.name+' | '+String(x.detail||'').slice(0,260));
 await c.query("update public.com_settings set kpi_mode='DESHABILITADO' where id='DEFAULT'");   // el KPI de facturación se valida con el KPI DESHABILITADO (rótulo)
 await c.query(pre(readFileSync('QA/extra_kpi.sql','utf8')));out.kpi=(await c.query('select * from kpi_checks order by name')).rows;console.log('KPI FACTURACIÓN',out.kpi.filter(x=>x.ok).length,'/',out.kpi.length);
 for(const x of out.kpi)console.log((x.ok?'PASS':'FAIL')+' | '+x.name+' | '+String(x.detail||'').slice(0,300));
 await c.query(pre(readFileSync('QA/extra_cuotas.sql','utf8')));out.cuotas=(await c.query('select * from cu_checks order by name')).rows;console.log('CUOTAS',out.cuotas.filter(x=>x.ok).length,'/',out.cuotas.length);
 for(const x of out.cuotas)console.log((x.ok?'PASS':'FAIL')+' | '+x.name+' | '+String(x.detail||'').slice(0,260));
 // reversión EXACTA de 001200 y reaplicación (los datos con calendario se conservan)
 { const nreq=(await c.query("select count(*)::int n from public.com_requests where original_terms ? 'first_due'")).rows[0].n;
   await c.query(readFileSync('propuestas/comercial/REVERSION_CUOTAS_CALENDARIO.sql','utf8'));
   const md5r=(await c.query("select md5(pg_get_functiondef('public._com_terms(text,jsonb,public.com_clients,date)'::regprocedure)) m")).rows[0].m;
   const nreq2=(await c.query("select count(*)::int n from public.com_requests where original_terms ? 'first_due'")).rows[0].n;
   let again; try{ await c.query(readFileSync('propuestas/comercial/REVERSION_CUOTAS_CALENDARIO.sql','utf8')); again='SIN ERROR'; }catch(e){ await c.query('rollback').catch(()=>{}); again=e.message; }
   await c.query(readFileSync('propuestas/comercial/20261201001200_comercial_cuotas_calendario.sql','utf8'));
   let twice; try{ await c.query(readFileSync('propuestas/comercial/20261201001200_comercial_cuotas_calendario.sql','utf8')); twice='SIN ERROR'; }catch(e){ await c.query('rollback').catch(()=>{}); twice=e.message; }
   const ok=md5r==='cd4e5a9e0a39ac7bcdd712ef57b25bef' && nreq>0 && nreq2===nreq && /NADA_QUE_REVERTIR/.test(again) && /YA_APLICADA/.test(twice);
   out.cuotas.push({name:'CU-21 REVERSIÓN exacta (huella original) que CONSERVA las solicitudes con calendario; segunda reversión y doble aplicación se detienen; reaplicable',ok,detail:`md5=${md5r} · solicitudes=${nreq}→${nreq2} · 2.ª reversión=${again.slice(0,30)} · doble=${twice.slice(0,20)}`});
   console.log((ok?'PASS':'FAIL')+' | CU-21 reversión exacta | '+out.cuotas.at(-1).detail); }
 await c.query(pre(readFileSync('QA/extra_alarma_solicitud.sql','utf8')));out.alsol=(await c.query('select * from as_checks order by name')).rows;
 // AS-03 · DOS OPERARIOS A LA VEZ: dos conexiones REALES, la misma autorización, operaciones distintas → UNA sola alarma
 { const reqId=(await c.query("select id from public.com_requests where op_id='as-sol-4b'")).rows[0].id;
   await c.query("update public.com_alarms set status='ATENDIDA', attended_at=now() where request_id=$1 and status='PENDIENTE_ATENCION'",[reqId]).catch(()=>{});
   const reqC=(await c.query("select pg_temp.as_new('as-sol-3','106') id")).rows[0].id;
   const mk=async()=>{ const x=new pg.Client({host:'127.0.0.1',port:55449,user:'postgres',password:'local-commercial-qa',database:'postgres'}); await x.connect(); return x; };
   const c1=await mk(), c2=await mk();
   const call=(cl,u,op)=>cl.query(`select tst.u('${u}'); set role authenticated; select public.com_alarm_raise_request('${reqC}','Dos operarios a la vez sobre la misma autorización','${op}')::text r`).then(r=>{ const rows=r.at?r.at(-1).rows:r.rows; return rows[0].r; }).catch(e=>'ERR '+e.message);
   const [r1,r2]=await Promise.all([call(c1,'e0000000-0000-0000-0000-000000000006','as-op-3a'), call(c2,'e0000000-0000-0000-0000-000000000005','as-op-3b')]);
   await c1.end(); await c2.end();
   const n=(await c.query("select count(*)::int n from public.com_alarms where request_id=$1",[reqC])).rows[0].n;
   const j=[r1,r2].map(x=>{try{return JSON.parse(x)}catch(e){return {raw:x}}});
   const ok=n===1 && j.every(x=>x.ok===true || x.code==='RETRY') && j.some(x=>x.existing===false) && (j.some(x=>x.existing===true) || j.some(x=>x.code==='RETRY'));
   out.alsol.push({name:'AS-03 DOS OPERARIOS A LA VEZ (dos conexiones reales, misma autorización): UNA sola alarma; el otro ve la existente (o reintenta)',ok,detail:`alarmas=${n} · ${JSON.stringify(j.map(x=>({ok:x.ok,existing:x.existing,code:x.code})))}`}); }
 // AS-17 · REVISAR (operario O) y Seguimiento (operario S) A LA VEZ sobre la MISMA autorización: dos conexiones reales → UNA sola alarma
 { await c.query("select pg_temp.as_u('e0000000-0000-0000-0000-000000000006', $q$select public.reserve_orders('V5-1', array['27508'])::text$q$)");
   const reqH=(await c.query("select pg_temp.as_new('as-sol-17','106') id")).rows[0].id;
   await c.query("update public.com_requests set order_ref='27508' where id=$1",[reqH]);
   const mk=async()=>{ const x=new pg.Client({host:'127.0.0.1',port:55449,user:'postgres',password:'local-commercial-qa',database:'postgres'}); await x.connect(); return x; };
   const k1=await mk(), k2=await mk();
   const run=(cl,u,sql)=>cl.query(`select tst.u('${u}'); set role authenticated; select (${sql})::text r`).then(r=>{ const rows=r.at?r.at(-1).rows:r.rows; return rows[0].r; }).catch(e=>'ERR '+e.message);
   const [rv,sg]=await Promise.all([
     run(k1,'e0000000-0000-0000-0000-000000000006',"public.com_alarm_raise('27508','V5-1','x','','REVISAR y Seguimiento a la vez sobre la misma autorización','as-op-17r')"),
     run(k2,'e0000000-0000-0000-0000-000000000005',`public.com_alarm_raise_request('${reqH}','REVISAR y Seguimiento a la vez sobre la misma autorización','as-op-17s')`)]);
   await k1.end(); await k2.end();
   const n=(await c.query("select count(*)::int n from public.com_alarms where status='PENDIENTE_ATENCION' and request_id=$1",[reqH])).rows[0].n;
   const j=[rv,sg].map(x=>{try{return JSON.parse(x)}catch(e){return {raw:String(x).slice(0,80)}}});
   const ok=n===1 && j.every(x=>x.ok===true || x.code==='RETRY') && (j.filter(x=>x.existing===false).length===1 || j.some(x=>x.code==='RETRY'));
   out.alsol.push({name:'AS-17 REVISAR y Seguimiento A LA VEZ sobre la MISMA autorización (dos operarios, dos conexiones reales): UNA sola alarma activa; el otro recupera la misma (o reintenta)',ok,detail:`activas=${n} · ${JSON.stringify(j.map(x=>({ok:x.ok,existing:x.existing,code:x.code,raw:x.raw})))}`}); }
 // EVIDENCIA del caso A/B (Work): pedido compartido, los dos request_id, las dos alarmas, el aviso de cada una y la autorización que ABRE ese aviso
 { const ev=(await c.query(`with x as (select 'A' quien, a rid, (rev->>'id')::uuid alarma from as13 union all select 'B', b, (sol->>'id')::uuid from as13)
     select x.quien, q.number autorizacion, x.rid::text request_id, q.order_ref pedido, (q.client_snapshot->>'razon_social') cliente, al.number alarma_numero, x.alarma::text alarma_id,
       case when al.sheet_key='AUTORIZACION' then 'Seguimiento' else 'REVISAR (hoja '||al.sheet_key||')' end origen, n.id::text aviso_id, n.body aviso_texto,
       (select count(*) from public.push_jobs j where j.notification_id = n.id)::int push_encolado,
       ((pg_temp.as_j(pg_temp.as_u('c0000000-0000-0000-0000-0000000000a1', format('select public.com_alarm_by_notification(%L)::text', n.id)))->'request'->>'id')) abre_request_id,
       ((pg_temp.as_j(pg_temp.as_u('c0000000-0000-0000-0000-0000000000a1', format('select public.com_alarm_by_notification(%L)::text', n.id)))->'request'->>'number')) abre_autorizacion,
       al.status estado_alarma, q.status estado_comercial
     from x join public.com_requests q on q.id = x.rid join public.com_alarms al on al.id = x.alarma
     join public.com_alarm_events e on e.alarm_id = al.id and e.kind = 'NOTIFICADO' and e.recipient_id = 'c0000000-0000-0000-0000-0000000000a1'
     join public.notifications n on n.id = e.notification_id order by x.quien`)).rows;
   writeFileSync('QA/results/evidencia_caso_AB.json', JSON.stringify(ev, null, 2)); out.evidenciaAB=ev;
   for (const r of ev) console.log('EVIDENCIA', r.quien, r.autorizacion, r.request_id, '· pedido', r.pedido, '·', r.alarma_numero, r.alarma_id, '·', r.origen, '· push encolado', r.push_encolado, '· el aviso abre', r.abre_autorizacion, r.abre_request_id, '·', r.estado_alarma, '/', r.estado_comercial); }
 console.log('ALARMA SOLICITUD',out.alsol.filter(x=>x.ok).length,'/',out.alsol.length);
 for(const x of out.alsol)console.log((x.ok?'PASS':'FAIL')+' | '+x.name+' | '+String(x.detail||'').slice(0,260));
 // reversión EXACTA de 001300: conserva alarmas e historial; segunda reversión y doble aplicación detenidas; reaplicable
 { const n0=(await c.query("select (select count(*) from public.com_alarms)::int a, (select count(*) from public.com_alarm_events)::int e, (select count(*) from public.com_alarm_ops)::int o")).rows[0];
   // con dos alarmas activas del MISMO pedido (AS-18b) la reversión se BLOQUEA sin tocar datos
   let bloq; try{ await c.query(readFileSync('propuestas/comercial/REVERSION_ALARMA_SOLICITUD.sql','utf8')); bloq='SIN ERROR'; }catch(e){ await c.query('rollback').catch(()=>{}); bloq=e.message; }
   const nB=(await c.query("select (select count(*) from public.com_alarms)::int a, (select count(*) from public.com_alarm_events)::int e, (select count(*) from public.com_alarm_ops)::int o")).rows[0];
   // se atiende una de ellas con la función REAL (destinatario W) y recién ahí se revierte
   const dup=(await c.query("select id, version from public.com_alarms where status='PENDIENTE_ATENCION' and upper(order_ref) in (select upper(order_ref) from public.com_alarms where status='PENDIENTE_ATENCION' group by 1 having count(*)>1) order by raised_at desc")).rows;
   for (const x of dup.slice(0, dup.length-1)) await c.query(`select pg_temp.as_u('c0000000-0000-0000-0000-0000000000a1', format('select public.com_alarm_attend(%L, %s)::text', '${x.id}', ${x.version}))`);
   const n0b=(await c.query("select (select count(*) from public.com_alarms)::int a, (select count(*) from public.com_alarm_events)::int e, (select count(*) from public.com_alarm_ops)::int o")).rows[0];
   await c.query(readFileSync('propuestas/comercial/REVERSION_ALARMA_SOLICITUD.sql','utf8'));
   const n1=(await c.query("select (select count(*) from public.com_alarms)::int a, (select count(*) from public.com_alarm_events)::int e, (select count(*) from public.com_alarm_ops)::int o")).rows[0];
   const gone=(await c.query("select to_regprocedure('public.com_alarm_raise_request(uuid,text,text)') is null and to_regclass('public.com_alarms_one_active_request') is null g")).rows[0].g;   // también el ÍNDICE
   const md=(await c.query("select md5(pg_get_functiondef('public.com_alarm_raise(text,text,text,text,text,text)'::regprocedure)) m")).rows[0].m;
   let again; try{ await c.query(readFileSync('propuestas/comercial/REVERSION_ALARMA_SOLICITUD.sql','utf8')); again='SIN ERROR'; }catch(e){ await c.query('rollback').catch(()=>{}); again=e.message; }
   await c.query(readFileSync('propuestas/comercial/20261201001300_comercial_alarma_solicitud.sql','utf8'));
   let twice; try{ await c.query(readFileSync('propuestas/comercial/20261201001300_comercial_alarma_solicitud.sql','utf8')); twice='SIN ERROR'; }catch(e){ await c.query('rollback').catch(()=>{}); twice=e.message; }
   const back=(await c.query("select to_regclass('public.com_alarms_one_active_request') is not null b")).rows[0].b;   // reaplicada: el índice vuelve
   const idxPub=(await c.query("select pg_get_indexdef('public.com_alarms_one_active'::regclass) d")).rows[0].d;   // tras reaplicar: el acotado (sin autorización)
   const ok=/REVERSION_BLOQUEADA/.test(bloq) && JSON.stringify(n0)===JSON.stringify(nB) && dup.length>1 && gone && back && md==='28e609cc5878f2ebb00e1716462d5437'
     && n0b.a===n1.a && n1.a===n0.a && n1.e>=n0.e && /request_id IS NULL/.test(idxPub) && n0.a>0 && /NADA_QUE_REVERTIR/.test(again) && /YA_APLICADA/.test(twice);
   out.alsol.push({name:'AS-12 REVERSIÓN: con dos alarmas activas del MISMO pedido se BLOQUEA sin tocar datos; atendida una, quita las funciones nuevas y el índice, restaura el índice por pedido y REVISAR con su huella y CONSERVA alarmas, eventos y operaciones; segunda reversión y doble aplicación detenidas; reaplicable',ok,detail:`bloqueo=${bloq.slice(0,40)} · alarmas/eventos/ops ${JSON.stringify(n0)}→${JSON.stringify(n1)} (sin borrar; eventos de atención agregados) · md5=${md} · 2.ª=${again.slice(0,22)} · doble=${twice.slice(0,14)}`});
   console.log((ok?'PASS':'FAIL')+' | AS-12 reversión | '+out.alsol.at(-1).detail); }
 // REVERSIÓN del módulo: AL FINAL, sobre la base con los datos de todas las pruebas
 const REV=readFileSync('propuestas/comercial/REVERSION_MODULO_COMERCIAL.sql','utf8');
 await c.query(pre(readFileSync('QA/extra_reversion_pre.sql','utf8')));
 // 1.er intento con un usuario con COMERCIAL restringido: DEBE fallar sin cambios (se aplica el archivo TAL CUAL, con su propia transacción)
 try { await c.query(REV); await c.query("insert into rv_a values ('SIN ERROR')"); } catch(e) { await c.query('rollback').catch(()=>{}); await c.query({text:'insert into rv_a values ($1)', values:[String(e.message)]}); }
 await c.query("create temp table rv_a_estado as select has_function_privilege('authenticated','public.com_config()','EXECUTE') priv, exists (select 1 from public.module_permissions where module='COMERCIAL') perms");   // foto JUSTO después del 1.er intento
 await c.query("select set_config('okd.sync','on',false); update public.profiles set disabled_modules='{}' where id='c0000000-0000-0000-0000-0000000000c1'; select set_config('okd.sync','',false);");
 await c.query(REV);   // 2.º intento: se aplica
 await c.query(pre(readFileSync('QA/extra_reversion_post.sql','utf8')));out.reversion=(await c.query('select * from rv_checks order by name')).rows;console.log('REVERSIÓN',out.reversion.filter(x=>x.ok).length,'/',out.reversion.length);
 for(const x of out.reversion)console.log((x.ok?'PASS':'FAIL')+' | '+x.name+' | '+String(x.detail||'').slice(0,240));
 const k02=out.work.find(x=>/WORK-K02/.test(x.name));
 console.log('PENDIENTE DE ARCHIVO REAL | '+(k02?k02.name+' → '+(k02.ok?'pasa':'sigue fallando (bloqueo abierto, NO se altera)')+' · '+k02.detail:'no encontrado'));
 writeFileSync('QA/results/correcciones.json',JSON.stringify(out,null,2));
 if(out.paquete.some(x=>!x.ok)||out.correcciones.some(x=>!x.ok)||out.consultar.some(x=>!x.ok)||out.alarma.some(x=>!x.ok)||(out.concurrencia||[]).some(x=>!x.ok)||(out.historial||[]).some(x=>!x.ok)||(out.reversion||[]).some(x=>!x.ok)||(out.v5||[]).some(x=>!x.ok)||(out.v6||[]).some(x=>!x.ok)||(out.kpi||[]).some(x=>!x.ok)||(out.cuotas||[]).some(x=>!x.ok)||(out.alsol||[]).some(x=>!x.ok)||(out.cron||[]).some(x=>!x.ok)||(out.v4||[]).some(x=>!x.ok)||out.work.some(x=>!x.ok&&!/WORK-K02/.test(x.name)))process.exitCode=1;
}finally{await c?.end();await server.stop();}
