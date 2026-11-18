// SOLO PRUEBAS LOCALES · CORREO CORPORATIVO (puerto 26 STARTTLS) · PostgreSQL embebido; INSTALL.sql + TEST_QA.sql de Work + aserciones; TODO en ROLLBACK.
// SOLO PRUEBAS LOCALES (no toca QA/run.mjs de Work). Aplica la base de Work + la migración de CUOTAS y RESPALDO, y separa resultados:
// PAQUETE (pruebas del módulo) · CONCURRENCIA · WORK (casos de la auditoría, SIN modificar) · CORRECCIONES (cuotas y respaldo).
import EmbeddedPostgres from './tooling/node_modules/embedded-postgres/dist/index.js';
import pg from './tooling/node_modules/pg/lib/index.js';
import {readFileSync,writeFileSync,mkdirSync,rmSync} from 'node:fs';
mkdirSync('QA/results',{recursive:true});
const server=new EmbeddedPostgres({databaseDir:'/tmp/okd-correo',port:55447,user:'postgres',password:'local-correo-qa',persistent:false,postgresFlags:['-c','unix_socket_directories=','-c','listen_addresses=127.0.0.1'],initdbFlags:['--locale=C','--encoding=UTF8']});
const vars={};
const pre=s=>s.split('\n').map(l=>{if(l.startsWith('\\set ')){const m=l.match(/^\\set\s+(\w+)\s+(.+)$/);if(m)vars[m[1]]=m[2].trim().replace(/^'|'$/g,'');return ''}if(l.startsWith('\\'))throw Error('Metacomando '+l);return l}).join('\n').replace(/:'([A-Za-z0-9_]+)'/g,(_,k)=>"'"+vars[k].replaceAll("'","''")+"'");
let c, rows=[];
try{
 rmSync('/tmp/okd-correo',{recursive:true,force:true});
 await server.initialise();await server.start();c=new pg.Client({host:'127.0.0.1',port:55447,user:'postgres',password:'local-correo-qa',database:'postgres'});await c.connect();const avisos=[];c.on('notice',n=>avisos.push(n.message));
 for(const f of ['QA/base_setup.sql','QA/storage_stub.sql','propuestas/comercial/20261201000100_comercial_autorizaciones.sql','propuestas/comercial/20261201000200_comercial_cuotas_respaldo.sql','propuestas/comercial/20261201000300_comercial_consultar_aprobacion.sql','propuestas/comercial/20261201000400_comercial_alarma_urgente.sql','propuestas/comercial/20261201000500_comercial_admin_sesion_vigente.sql','propuestas/comercial/20261201000600_comercial_modulo_historial.sql','propuestas/comercial/20261201000700_comercial_sesion_vigente_total.sql','propuestas/comercial/20261201000800_comercial_v4_alarma_escala_push.sql','propuestas/comercial/20261201000900_comercial_v5_permisos_kpi_fechas.sql','propuestas/comercial/20261201001000_comercial_v6_push_instalacion.sql','propuestas/comercial/20261201001100_comercial_kpi_facturacion.sql','propuestas/comercial/20261201001200_comercial_cuotas_calendario.sql','propuestas/comercial/20261201001300_comercial_alarma_solicitud.sql']) await c.query(pre(readFileSync(f,'utf8')));
 // SOLO esta base local temporal: la simulación de Vault de base_setup.sql no tiene updated_at; se completa como el Vault real (versión del secreto)
 await c.query(`alter table vault.secrets add column if not exists created_at timestamptz not null default now(), add column if not exists updated_at timestamptz not null default now();
   create or replace function vault.update_secret(secret_id uuid, new_secret text default null, new_name text default null, new_description text default null) returns void language sql as $f$
     update vault.secrets set secret = coalesce(new_secret, secret), name = coalesce(new_name, name), description = coalesce(new_description, description), updated_at = clock_timestamp() where id = secret_id $f$;
   create or replace view vault.decrypted_secrets as select id, name, description, secret as decrypted_secret, created_at, updated_at from vault.secrets;
   alter table auth.sessions add column if not exists not_after timestamptz;
   -- como el Auth real de Supabase: el usuario y el rol se leen de request.jwt.claim.* O de request.jwt.claims (la prueba de Work usa el segundo)
   create or replace function auth.uid() returns uuid language sql stable as $f$ select coalesce(nullif(current_setting('request.jwt.claim.sub', true), ''), nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')::uuid $f$;
   create or replace function auth.role() returns text language sql stable as $f$ select coalesce(nullif(current_setting('request.jwt.claim.role', true), ''), nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role') $f$;`);
 const inst=readFileSync('propuestas/correo_corporativo/INSTALL.sql','utf8'); const k=inst.lastIndexOf('COMMIT;'); if(k<0) throw Error('INSTALL sin COMMIT');
 const test=readFileSync('propuestas/correo_corporativo/TEST_QA.sql','utf8');
 const extra=`DO $x$ DECLARE r jsonb; BEGIN
   r := public.comm_smtp_credentials();
   IF r->>'host' <> 'mail.okaccesorios.com' OR (r->>'port')::int <> 26 OR r->>'user' <> 'fgutierrez@okaccesorios.com' OR r->>'from' <> 'fgutierrez@okaccesorios.com' THEN RAISE EXCEPTION 'CONFIG_NO_CERTIFICADA %', r - 'password'; END IF;
   IF has_function_privilege('authenticated','public.comm_smtp_credentials()','EXECUTE') OR has_function_privilege('anon','public.comm_smtp_credentials()','EXECUTE') THEN RAISE EXCEPTION 'CREDENCIALES_EXPUESTAS'; END IF;
 END $x$;`;
 await c.query('BEGIN');
 await c.query(inst.slice(0,k).replace(/^\s*BEGIN;/m,''));
 // la preparación de datos de TEST_QA cambia perfiles por SQL (servidor): igual que las demás suites (pg_temp.as_sync), con okd.sync en la sesión
 await c.query("select set_config('okd.sync','on',false)");
 await c.query(extra);   // aserciones propias DENTRO de la transacción, antes de la prueba de Work (que termina con su propio ROLLBACK)
 await c.query(test);
 const pase=avisos.find(m=>/^SMTP_SQL_CONTRACT_PASS/.test(m));
 rows.push({name:'CO-01 INSTALL.sql (servidor mail.okaccesorios.com:26) + TEST_QA.sql de Work COMPLETO: aviso SMTP_SQL_CONTRACT_PASS recibido',ok:!!pase,detail:pase?pase.slice(0,260):'sin aviso de PASS de la prueba de Work'});
 rows.push({name:'CO-02 credenciales operativas = configuración CERTIFICADA (mail.okaccesorios.com · 26 · fgutierrez@okaccesorios.com) y SOLO service_role puede leerlas',ok:true});
 await c.query('ROLLBACK').catch(()=>{});   // ya deshecho por TEST_QA; por las dudas
}catch(e){ rows.push({name:'CO-XX ERROR',ok:false,detail:String(e.message).slice(0,200)+' · DÓNDE: '+String(e.where||'').replace(/\s+/g,' ').slice(0,400)}); try{await c.query('ROLLBACK');}catch{} }
finally{ try{await c.end();}catch{} await server.stop(); }
for(const r of rows)console.log((r.ok?'PASS':'FAIL')+' | '+r.name+(r.detail?' | '+r.detail:''));
console.log('CORREO',rows.filter(r=>r.ok).length,'/',rows.length); process.exit(rows.every(r=>r.ok)?0:1);
