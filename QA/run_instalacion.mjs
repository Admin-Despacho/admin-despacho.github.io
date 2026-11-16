// SOLO PRUEBAS LOCALES · instalación ÚNICA y activación (sección 4 de la orden V5), en un PostgreSQL embebido PROPIO con TRES bases nuevas:
//  okd_inst (INSTALAR + ACTIVAR) · okd_seq (las 9 migraciones una por una, referencia) · okd_fail (instalador con un ERROR inyectado a mitad)
import EmbeddedPostgres from './tooling/node_modules/embedded-postgres/dist/index.js';
import pg from './tooling/node_modules/pg/lib/index.js';
import {readFileSync,writeFileSync,rmSync} from 'node:fs';
rmSync('/tmp/okd-com-instalacion',{recursive:true,force:true});   // siempre desde una base NUEVA
const PORT=55447, PW='local-commercial-qa';   // puerto admitido por la protección de QA/base_setup.sql (solo 55447/55449)
const server=new EmbeddedPostgres({databaseDir:'/tmp/okd-com-instalacion',port:PORT,user:'postgres',password:PW,persistent:false,postgresFlags:['-c','unix_socket_directories=','-c','listen_addresses=127.0.0.1'],initdbFlags:['--locale=C','--encoding=UTF8']});
const vars={};
const pre=s=>s.split('\n').map(l=>{if(l.startsWith('\\set ')){const m=l.match(/^\\set\s+(\w+)\s+(.+)$/);if(m)vars[m[1]]=m[2].trim().replace(/^'|'$/g,'');return ''}if(l.startsWith('\\'))throw Error('Metacomando '+l);return l}).join('\n').replace(/:'([A-Za-z0-9_]+)'/g,(_,k)=>"'"+vars[k]+"'");
const MIG0=[1,2,3,4,5,6,7,8,9].map(n=>'propuestas/comercial/20261201000'+n+'00_'+({1:'comercial_autorizaciones',2:'comercial_cuotas_respaldo',3:'comercial_consultar_aprobacion',4:'comercial_alarma_urgente',5:'comercial_admin_sesion_vigente',6:'comercial_modulo_historial',7:'comercial_sesion_vigente_total',8:'comercial_v4_alarma_escala_push',9:'comercial_v5_permisos_kpi_fechas'})[n]+'.sql');
const MIG=[...MIG0,'propuestas/comercial/20261201001000_comercial_v6_push_instalacion.sql','propuestas/comercial/20261201001100_comercial_kpi_facturacion.sql'];
const R=[]; const res=(name,ok,detail)=>{R.push({name,ok:!!ok,detail:String(detail||'').slice(0,300)}); console.log((ok?'PASS':'FAIL')+' | '+name+' | '+String(detail||'').slice(0,240));};
const EXEC=`select coalesce(array_agg(p.oid::regprocedure::text order by p.oid::regprocedure::text),'{}') from pg_proc p where p.pronamespace='public'::regnamespace and (p.proname like 'com\\_%' or p.proname like '\\_com\\_%') and has_function_privilege('authenticated',p.oid,'EXECUTE')`;
const conn=async db=>{const c=new pg.Client({host:'127.0.0.1',port:PORT,user:'postgres',password:PW,database:db}); await c.connect(); return c;};
const base=async c=>{for(const f of ['QA/base_setup.sql','QA/storage_stub.sql']) await c.query(pre(readFileSync(f,'utf8')));};
const AUX=['_com_admin()','_com_can_upload_source()','_com_module_open()'];   // N-V5-04: SOLO las auxiliares que evalúan las políticas de Storage (devuelven verdadero/falso)
const ADM='d0000000-0000-0000-0000-0000000000f1';   // Administrador PROPIO de la prueba (no choca con los de la suite base)
// fixture: un Administrador activo y un bucket OPERATIVO (representa firmas/evidencias) con su objeto y sus políticas de lectura y escritura
const fixture=async c=>{ await c.query(`insert into auth.users(id,email) values ('${ADM}','adm.inst@t') on conflict do nothing;
  select set_config('okd.sync','on',false); insert into public.profiles(id,full_name,email,role,status) values ('${ADM}','Admin Instalación','adm.inst@t','ADMIN','ACTIVO') on conflict (id) do nothing; select set_config('okd.sync','',false);
  insert into storage.buckets(id,name,public) values ('operativo','operativo',false) on conflict do nothing;
  insert into storage.objects(bucket_id,name,owner) values ('operativo','firmas/hoja-01/firma.png','${ADM}');
  create policy oper_sel on storage.objects for select to authenticated using (bucket_id = 'operativo');
  create policy oper_ins on storage.objects for insert to authenticated with check (bucket_id = 'operativo');`); };
// lo que ve un usuario AUTENTICADO en Storage: leer y escribir el bucket operativo, y si el módulo está abierto
const storage=async (c,tag)=>{ const r={}; const as=async q=>{ try{ await c.query('begin'); await c.query('set local role authenticated'); await c.query(`select set_config('request.jwt.claim.sub','${ADM}',true)`);
    const x=(await c.query(q)).rows[0]; await c.query('commit'); return x; }catch(e){ await c.query('rollback').catch(()=>{}); return {error:e.message}; } };
  const l=await as("select count(*)::int n from storage.objects where bucket_id='operativo'"); r.leer=l.error?('ERROR '+l.error):l.n;
  const w=await as(`insert into storage.objects(bucket_id,name) values ('operativo','evidencias/${tag}.jpg') returning 1 ok`); r.escribir=w.error?('ERROR '+w.error):'OK';
  const m=await as("select public._com_module_open() abierto"); r.modulo_abierto=m.error?('ERROR '+m.error):m.abierto; return r; };
const inerte=v=>v===false || /permission denied/.test(String(v));   // revertido: el módulo queda INERTE
const sinPol=async c=>(await c.query("select count(*)::int n from pg_policies where schemaname='storage' and policyname like 'com_sources%'")).rows[0].n===0;
const cronSim=async c=>{ await c.query(`create schema if not exists cron; create table if not exists cron.job(jobid serial primary key, jobname text unique, schedule text, command text, active boolean default true);
  insert into cron.job(jobname,schedule,command) values ('okd-com-alarma-escalamiento','* * * * *','select public.com_alarm_escalate_due()'),('okd-push-notificaciones','* * * * *','(simulado)') on conflict do nothing;`); };
const CONFIG=`select public._com_install_configure('{"alarm":{"initial_user":"${'d0000000-0000-0000-0000-0000000000f1'}","escalation_users":["${'d0000000-0000-0000-0000-0000000000f1'}"]}}'::jsonb)`;
const tryq=async (c,q)=>{ try{ await c.query(q); return 'SIN ERROR'; }catch(e){ await c.query('rollback').catch(()=>{}); return e.message; } };
let admin; try{
 await server.initialise(); await server.start(); admin=await conn('postgres');
 for(const db of ['okd_inst','okd_seq','okd_fail','okd_rev1','okd_rev2']) await admin.query('create database '+db);
 // ---- referencia: migraciones una por una ----
 const seq=await conn('okd_seq'); await base(seq); for(const f of MIG) await seq.query(pre(readFileSync(f,'utf8')));
 const S_seq=(await seq.query(EXEC)).rows[0].coalesce;
 // ---- instalación ÚNICA ----
 const inst=await conn('okd_inst'); await base(inst); await fixture(inst);
 const st0=await storage(inst,'antes');
 await inst.query(readFileSync('propuestas/comercial/INSTALAR_MODULO_COMERCIAL.sql','utf8'));
 const st1=await storage(inst,'cerrado');
 const closed=(await inst.query(EXEC)).rows[0].coalesce, kpi=(await inst.query("select kpi_mode from public.com_settings where id='DEFAULT'")).rows[0].kpi_mode;
 const pend=(await inst.query("select count(*)::int n from public.com_install_grants where grantee='authenticated'")).rows[0].n;
 res('IN-01 tras INSTALAR el módulo queda CERRADO: ninguna RPC comercial ejecutable (solo las 3 auxiliares de las políticas de Storage, N-V5-04); KPI DESHABILITADO; lista exacta de permisos pendientes (pendientes + auxiliares = total paso a paso)',
   JSON.stringify(closed)===JSON.stringify(AUX) && kpi==='DESHABILITADO' && pend+AUX.length===S_seq.length, `ejecutables=${closed.join(',')} · kpi=${kpi} · pendientes=${pend} · total=${S_seq.length}`);
 // un usuario autenticado NO puede llamar una RPC antes de activar
 let pre_call; try{ await inst.query("begin; set local role authenticated; select public.com_config(); commit;"); pre_call='EJECUTÓ'; }catch(e){ await inst.query('rollback').catch(()=>{}); pre_call=e.message; }
 res('IN-02 ANTES de activar, una llamada directa de un usuario autenticado a una RPC comercial se rechaza por permisos', /permission denied/.test(pre_call), pre_call);
 // N-V5-01 / configuración: ACTIVAR sin configurar y sin tareas → rechazo con la lista; configurado sin tareas → rechazo; con todo → activa
 const ACT=readFileSync('propuestas/comercial/ACTIVAR_MODULO_COMERCIAL.sql','utf8');
 const a1=await tryq(inst,ACT); await inst.query(CONFIG); const a2=await tryq(inst,ACT); await cronSim(inst);
 const g_before=(await inst.query(EXEC)).rows[0].coalesce;
 res('IN-09 ACTIVAR exige la CONFIGURACIÓN privilegiada y las DOS tareas automáticas: sin configurar → rechazo que lista destinatarios y tareas; configurado sin tareas → rechazo por las tareas; en ambos casos sin otorgar nada',
   /NO_LISTO/.test(a1) && /DESTINATARIO_INICIAL_VALIDO/.test(a1) && /TAREA_ESCALAMIENTO_PROGRAMADA/.test(a1) && /NO_LISTO/.test(a2) && !/DESTINATARIO/.test(a2) && /TAREA_PUSH_PROGRAMADA/.test(a2) && JSON.stringify(g_before)===JSON.stringify(AUX),   // nada más que las 3 auxiliares de Storage
   `sin_config=${a1.slice(0,140)} · sin_tareas=${a2.slice(0,110)}`);
 // activar dos veces: la segunda se detiene
 await inst.query(ACT);
 const S_inst=(await inst.query(EXEC)).rows[0].coalesce;
 const st2=await storage(inst,'activo');
 let again; try{ await inst.query(ACT); again='SIN ERROR'; }catch(e){ await inst.query('rollback').catch(()=>{}); again=e.message; }
 res('IN-03 ACTIVAR habilita EXACTAMENTE el mismo conjunto de funciones que la instalación paso a paso; queda auditado; una segunda activación se detiene sin cambios',
   JSON.stringify(S_inst)===JSON.stringify(S_seq) && S_inst.length>30 && /ESTADO_INVALIDO/.test(again) && (await inst.query("select count(*)::int n from public.audit_log where action='COM_MODULE_ACTIVATED'")).rows[0].n===1, `instalada=${S_inst.length} · secuencial=${S_seq.length} · iguales=${JSON.stringify(S_inst)===JSON.stringify(S_seq)} · solo_inst=${S_inst.filter(x=>!S_seq.includes(x)).join(',')} · solo_seq=${S_seq.filter(x=>!S_inst.includes(x)).join(',')} · auditoria=${(await inst.query("select count(*)::int n from public.audit_log where action='COM_MODULE_ACTIVATED'")).rows[0].n} · 2.ª=${again.slice(0,40)}`);
 // la suite base del módulo corre IGUAL sobre la base instalada (con la activación explícita de PROVISORIO solo para probar el cálculo, como el ejecutor principal)
 await inst.query("update public.com_settings set kpi_mode='PROVISORIO' where id='DEFAULT'");
 await inst.query(pre(readFileSync('propuestas/comercial/comercial_test.sql','utf8')));
 const rr=(await inst.query('select name,ok from tst.results')).rows;
 res('IN-04 la suite base del módulo (comercial_test) pasa COMPLETA sobre la base instalada con el instalador único', rr.length>=80 && rr.every(x=>x.ok), `${rr.filter(x=>x.ok).length} / ${rr.length}`);
 // ---- instalación con un ERROR inyectado a mitad: no debe quedar NADA ----
 const fail=await conn('okd_fail'); await base(fail);
 const txt=readFileSync('propuestas/comercial/INSTALAR_MODULO_COMERCIAL.sql','utf8'), cut=txt.indexOf('-- 20261201000500_');
 let ferr; try{ await fail.query(txt.slice(0,cut)+"\nselect 1/0;   -- ERROR INYECTADO por la prueba\n"+txt.slice(cut)); ferr='SIN ERROR'; }catch(e){ await fail.query('rollback').catch(()=>{}); ferr=e.message; }
 const left=(await fail.query("select count(*)::int n from pg_class where relnamespace='public'::regnamespace and relname like 'com\\_%'")).rows[0].n,
       fns=(await fail.query("select count(*)::int n from pg_proc where pronamespace='public'::regnamespace and (proname like 'com\\_%' or proname like '\\_com\\_%')")).rows[0].n,
       mods=(await fail.query("select pg_get_constraintdef(oid) d from pg_constraint where conname='profiles_disabled_modules_valid'")).rows[0].d;
 res('IN-05 ATOMICIDAD: con un error inyectado a mitad (después de 000400), la instalación no deja NINGUNA tabla ni función del módulo y la restricción de módulos queda como estaba',
   /division by zero/.test(ferr) && left===0 && fns===0 && !/COMERCIAL/.test(mods), `error=${ferr.slice(0,40)} · tablas=${left} · funciones=${fns}`);
 // ---- N-V5-05 · INSTALAR → REVERTIR → ACTIVAR: rechazo SIN permisos ----
 const REV=readFileSync('propuestas/comercial/REVERSION_MODULO_COMERCIAL.sql','utf8');
 const r1=await conn('okd_rev1'); await base(r1); await fixture(r1); await r1.query(readFileSync('propuestas/comercial/INSTALAR_MODULO_COMERCIAL.sql','utf8'));
 await r1.query(CONFIG); await cronSim(r1); await r1.query(REV);
 const r1act=await tryq(r1,ACT), r1ex=(await r1.query(EXEC)).rows[0].coalesce.length, r1st=(await r1.query("select status from public.com_install_state")).rows[0].status,
       r1log=(await r1.query("select string_agg(status,'>' order by id) s from public.com_install_log")).rows[0].s, r1sto=await storage(r1,'revertido1');
 res('IN-07 (N-V5-05) INSTALAR → REVERTIR → ACTIVAR: la activación se RECHAZA (estado REVERTIDO) sin otorgar ningún permiso; el historial conserva cada paso; Storage operativo intacto',
   /ESTADO_INVALIDO/.test(r1act) && r1ex===0 && r1st==='REVERTIDO' && r1log.startsWith('INSTALADO_CERRADO') && r1log.endsWith('REVERTIDO') && r1sto.leer===1 && r1sto.escribir==='OK' && inerte(r1sto.modulo_abierto) && await sinPol(r1),
   `activar=${r1act.slice(0,70)} · ejecutables=${r1ex} · historial=${r1log} · storage=${JSON.stringify(r1sto)}`);
 // ---- N-V5-05 · INSTALAR → ACTIVAR → REVERTIR → ACTIVAR: también se rechaza ----
 const r2=await conn('okd_rev2'); await base(r2); await fixture(r2); await r2.query(readFileSync('propuestas/comercial/INSTALAR_MODULO_COMERCIAL.sql','utf8'));
 await r2.query(CONFIG); await cronSim(r2); await r2.query(ACT); const r2on=(await r2.query(EXEC)).rows[0].coalesce.length; await r2.query(REV);
 const r2act=await tryq(r2,ACT), r2ex=(await r2.query(EXEC)).rows[0].coalesce.length, r2log=(await r2.query("select string_agg(status,'>' order by id) s from public.com_install_log")).rows[0].s, r2sto=await storage(r2,'revertido2');
 res('IN-08 (N-V5-05) INSTALAR → ACTIVAR → REVERTIR → ACTIVAR: tras revertir no queda nada ejecutable y una nueva activación se RECHAZA; historial completo; Storage operativo intacto',
   r2on>30 && /ESTADO_INVALIDO/.test(r2act) && r2ex===0 && /ACTIVO>REVERTIDO$/.test(r2log) && r2sto.leer===1 && r2sto.escribir==='OK' && inerte(r2sto.modulo_abierto) && await sinPol(r2),
   `activo=${r2on} · reactivar=${r2act.slice(0,60)} · ejecutables=${r2ex} · historial=${r2log}`);
 res('IN-06 (N-V5-04) STORAGE operativo (firmas/evidencias) en TODAS las fases: lee y escribe ANTES de instalar, con el módulo CERRADO, ACTIVO y REVERTIDO; los originales comerciales solo se abren con el módulo ACTIVO',
   [st0,st1,st2].every(x=>x.leer>=1 && x.escribir==='OK') && st1.modulo_abierto===false && st2.modulo_abierto===true && r1sto.leer===1 && r2sto.escribir==='OK',
   `antes=${JSON.stringify(st0)} · cerrado=${JSON.stringify(st1)} · activo=${JSON.stringify(st2)}`);
 await seq.end(); await inst.end(); await fail.end(); await r1.end(); await r2.end();
}catch(e){ console.error(e); res('IN-ERROR '+e.message,false,''); }
finally{ if(admin) await admin.end().catch(()=>{}); await server.stop().catch(()=>{}); }
console.log('INSTALACIÓN', R.filter(x=>x.ok).length, '/', R.length); writeFileSync('QA/results/instalacion.json', JSON.stringify(R,null,2));
process.exit(R.every(x=>x.ok)?0:1);
