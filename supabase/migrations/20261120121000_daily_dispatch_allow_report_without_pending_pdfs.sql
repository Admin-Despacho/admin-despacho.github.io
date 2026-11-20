CREATE OR REPLACE FUNCTION public.daily_dispatch_prepare()
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare c public.daily_dispatch_control; s public.notification_settings; b public.daily_dispatch_batches; d date; cutoff_at timestamptz;
 recipients_now text[]; expected_count int; ready_count int; routes_json jsonb;
begin
 perform pg_advisory_xact_lock(hashtext('okd_daily_dispatch_batch'));
 select * into c from public.daily_dispatch_control where id='DEFAULT';
 select * into s from public.notification_settings where id='DEFAULT';
 d := (now() at time zone 'America/Argentina/Mendoza')::date;
 if not coalesce(c.enabled,false) or c.cutover_day is null or d<c.cutover_day or not coalesce(s.sheet_email_enabled,false) then
  return jsonb_build_object('state','DISABLED');
 end if;
 -- No se crea un segundo informe si un corte anterior todavía no está sellado.
 select * into b from public.daily_dispatch_batches where state in ('WAIT_PDF','READY','BLOCKED') order by report_day limit 1 for update;
 if found and b.state='BLOCKED' then return jsonb_build_object('state','BLOCKED','id',b.id); end if;
 if b.id is null then
  cutoff_at := ((d::text||' '||s.sheet_email_time)::timestamp at time zone 'America/Argentina/Mendoza');
  if now()<cutoff_at then return jsonb_build_object('state','BEFORE_CUTOFF'); end if;
  if exists(select 1 from public.daily_dispatch_batches where report_day=d) then return jsonb_build_object('state','ALREADY_CREATED'); end if;
  recipients_now:=public.daily_dispatch_addresses(s.sheet_email_recipients);
  if cardinality(recipients_now)=0 or cardinality(recipients_now)>100 or exists(select 1 from unnest(recipients_now) a where a is null or a !~ '^[^[:space:]@,;<>]+@[^[:space:]@,;<>]+\.[^[:space:]@,;<>]+$') then
   return jsonb_build_object('state','DESTINATARIOS_INVALIDOS');
  end if;
  insert into public.daily_dispatch_batches(report_day,cutoff,report_time,recipients,state) values(d,cutoff_at,s.sheet_email_time,recipients_now,'WAIT_PDF') returning * into b;
  insert into public.daily_dispatch_batch_routes(batch_id,route_id,route_version,route_number,data)
  select b.id,r.id,r.version,r.number,jsonb_build_object('number',r.number,'version',r.version,'carrier_name',k.name,
   'carrier_kind',k.kind,'dispatch_mode',r.dispatch_mode,'operational_status',r.operational_status,
   'dispatch_day',(t.sent_at at time zone 'America/Argentina/Mendoza')::date,
   'sheet_snapshot',public.daily_dispatch_project(r.sheet_snapshot))
  from public.routes r left join public.carriers k on k.id=r.carrier_id
  cross join lateral(select case when r.dispatch_mode='EXTERNAL' then r.dispatched_at else r.published_at end sent_at) t
  where public._comm_sheet_eligible(r)
   and t.sent_at >= (c.cutover_day::timestamp at time zone 'America/Argentina/Mendoza') and t.sent_at<=b.cutoff
   and not exists(select 1 from public.daily_dispatch_batch_routes x where x.route_id=r.id and x.route_version=r.version)
   -- Guardas contra cualquier trabajo entre canales, incluidos trabajos todavía en cola.
   and not exists(select 1 from public.sheet_email_jobs j where j.route_id=r.id and j.route_version=r.version)
   and not exists(select 1 from public.comm_runs q where q.source_key='HOJA|'||r.id||'|'||r.version);
 end if;
 if public.daily_dispatch_addresses(s.sheet_email_recipients) is distinct from b.recipients then
  update public.daily_dispatch_batches set state='BLOCKED',last_error='CONFIGURATION_CHANGED' where id=b.id;
  return jsonb_build_object('state','BLOCKED','id',b.id);
 end if;
 if now()<b.cutoff+interval '5 minutes' and exists(select 1 from public.daily_dispatch_batch_routes x where x.batch_id=b.id and not exists(select 1 from public.route_pdfs p where p.route_id=x.route_id and p.route_version=x.route_version and p.status='OK')) then
  return jsonb_build_object('state','WAIT_PDF','id',b.id);
 end if;
 select jsonb_agg(x.data||jsonb_build_object('file_name',p.file_name,'storage_path',p.storage_path) order by x.route_number) into routes_json
 from public.daily_dispatch_batch_routes x left join public.route_pdfs p on p.route_id=x.route_id and p.route_version=x.route_version and p.status='OK'
 where x.batch_id=b.id;
 update public.daily_dispatch_batches set state='READY',last_error=null where id=b.id;
 return jsonb_build_object('state','READY','id',b.id,'day',b.report_day,'time',b.report_time,'recipients',b.recipients,'routes',coalesce(routes_json,'[]'::jsonb));
end $function$
;
CREATE OR REPLACE FUNCTION public.daily_dispatch_seal(p_id uuid, p_snapshot jsonb)
 RETURNS boolean
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare b public.daily_dispatch_batches; dist text[]; n int;
begin
 select * into b from public.daily_dispatch_batches where id=p_id for update;
 if not found then return false;end if;
 if b.state='SEALED' then return b.snapshot=p_snapshot;end if;
 if b.state<>'READY' then return false;end if;
 if not (p_snapshot ?& array['to','cc','subject','html','text','files','fingerprint','messageId']) then return false;end if;
 if jsonb_typeof(p_snapshot->'to') is distinct from 'array' or jsonb_typeof(p_snapshot->'cc') is distinct from 'array' or jsonb_typeof(p_snapshot->'files') is distinct from 'array' then return false;end if;
 if coalesce(p_snapshot->>'fingerprint','') !~ '^[0-9a-f]{64}$' or coalesce(p_snapshot->>'messageId','') !~ '^okd-daily-[0-9a-f]{32}@okaccesorios\.com$' then return false;end if;
 select array_agg(v order by o) into dist from jsonb_array_elements_text((p_snapshot->'to')||(p_snapshot->'cc')) with ordinality x(v,o);
 if dist is distinct from b.recipients then return false;end if;
 if not exists(select 1 from public.notification_settings where id='DEFAULT' and sheet_email_enabled and public.daily_dispatch_addresses(sheet_email_recipients)=dist) then return false;end if;
 select count(*) into n from public.daily_dispatch_batch_routes where batch_id=p_id;
 if jsonb_typeof(coalesce(p_snapshot->'missing','[]')) <> 'array' or jsonb_array_length(p_snapshot->'files')+jsonb_array_length(coalesce(p_snapshot->'missing','[]'))<>n then return false;end if;
 if exists(select 1 from public.daily_dispatch_batch_routes x where x.batch_id=p_id and not exists(select 1 from jsonb_array_elements(coalesce(p_snapshot->'missing','[]')) m where m->>'number'=x.route_number and m->>'version'=x.route_version::text) and
  not exists(select 1 from public.route_pdfs p cross join jsonb_array_elements(p_snapshot->'files') f
   where p.route_id=x.route_id and p.route_version=x.route_version and p.status='OK' and p.storage_path=f->>'storage_path' and p.file_name=f->>'name' and f->>'sha256'~'^[0-9a-f]{64}$')) then return false;end if;
 update public.daily_dispatch_batches set snapshot=p_snapshot,state='SEALED',last_error=null,sealed_at=now() where id=p_id;
 insert into public.daily_dispatch_recipients(batch_id,recipient) select p_id,e from unnest(b.recipients) e;
 return true;
end $function$
;
