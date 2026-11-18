// Construye la base "equivalente a producción" en una BD plantilla local (okd_base). SOLO PRUEBAS LOCALES.
import pg from './tooling/node_modules/pg/lib/index.js';
import {readFileSync} from 'node:fs';
const R=new URL('..', import.meta.url).pathname;
const vars={};
const pre=s=>s.split('\n').map(l=>{if(l.startsWith('\\set ')){const m=l.match(/^\\set\s+(\w+)\s+(.+)$/);if(m)vars[m[1]]=m[2].trim().replace(/^'|'$/g,'');return ''}if(l.startsWith('\\'))throw Error('Metacomando '+l);return l}).join('\n').replace(/:'([A-Za-z0-9_]+)'/g,(_,k)=>"'"+vars[k].replaceAll("'","''")+"'");
const admin=new pg.Client({host:'127.0.0.1',port:55447,user:'postgres',database:'postgres'});await admin.connect();
await admin.query('drop database if exists okd_base');await admin.query("create database okd_base template template0 encoding 'UTF8' lc_collate 'C' lc_ctype 'C'");await admin.end();
const c=new pg.Client({host:'127.0.0.1',port:55447,user:'postgres',database:'okd_base'});await c.connect();
const files=['QA/base_setup.sql','QA/storage_stub.sql',...['000100_comercial_autorizaciones','000200_comercial_cuotas_respaldo','000300_comercial_consultar_aprobacion','000400_comercial_alarma_urgente','000500_comercial_admin_sesion_vigente','000600_comercial_modulo_historial','000700_comercial_sesion_vigente_total','000800_comercial_v4_alarma_escala_push','000900_comercial_v5_permisos_kpi_fechas','001000_comercial_v6_push_instalacion','001100_comercial_kpi_facturacion','001200_comercial_cuotas_calendario','001300_comercial_alarma_solicitud'].map(x=>'propuestas/comercial/20261201'+x+'.sql')];
for(const f of files){try{await c.query(pre(readFileSync(R+f,'utf8')));}catch(e){console.error('FALLO',f,e.message,e.where);process.exit(1);}}
await c.query(`alter table vault.secrets add column if not exists created_at timestamptz not null default now(), add column if not exists updated_at timestamptz not null default now();
 create or replace function vault.update_secret(secret_id uuid, new_secret text default null, new_name text default null, new_description text default null) returns void language sql as $f$
   update vault.secrets set secret = coalesce(new_secret, secret), name = coalesce(new_name, name), description = coalesce(new_description, description), updated_at = clock_timestamp() where id = secret_id $f$;
 create or replace view vault.decrypted_secrets as select id, name, description, secret as decrypted_secret, created_at, updated_at from vault.secrets;
 alter table auth.sessions add column if not exists not_after timestamptz;
 create or replace function auth.uid() returns uuid language sql stable as $f$ select coalesce(nullif(current_setting('request.jwt.claim.sub', true), ''), nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')::uuid $f$;
 create or replace function auth.role() returns text language sql stable as $f$ select coalesce(nullif(current_setting('request.jwt.claim.role', true), ''), nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role') $f$;`);
// Producción: 20261116220910 commercial_mail_panel_settings_only (PANEL_SOLO) y luego 20261118112054 corporate_mail_starttls_install (INSTALL)
for(const f of ['propuestas/correo_corporativo/PANEL_SOLO.sql','propuestas/correo_corporativo/INSTALL.sql']){try{await c.query(readFileSync(R+f,'utf8'));}catch(e){console.error('FALLO',f,e.message,e.where);process.exit(1);}}
console.log('BASE OK');await c.end();
