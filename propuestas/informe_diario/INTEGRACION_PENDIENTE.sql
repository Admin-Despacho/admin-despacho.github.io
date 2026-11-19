-- PROPUESTA DE INTEGRACIÓN. NO EJECUTAR SIN AUDITORÍA Y AUTORIZACIÓN.
-- Instalación inerte: cutover_day NULL, enabled=false. No altera la configuración anterior.
begin;
set local lock_timeout='5s';
set local statement_timeout='60s';
do $guard$
begin
 if md5(pg_get_functiondef('public.queue_sheet_emails(date)'::regprocedure)) <> '04e16abe23239587bba717144b87ff62'
 or md5(pg_get_functiondef('public.comm_enqueue_sheet_pdfs(timestamp with time zone)'::regprocedure)) <> '85d94662d94b0f4e8a5dbcd001d74977'
 then raise exception 'BASE_DE_ENVIO_INCOMPATIBLE'; end if;
end $guard$;

create table public.daily_dispatch_control(
 id text primary key check(id='DEFAULT'),
 cutover_day date,
 enabled boolean not null default false,
 max_mime_bytes integer check(max_mime_bytes between 1024 and 30000000),
 changed_at timestamptz not null default now(),
 check(not enabled or (cutover_day is not null and max_mime_bytes is not null))
);
insert into public.daily_dispatch_control(id) values('DEFAULT');
create table public.daily_dispatch_batches(
 id uuid primary key default gen_random_uuid(),
 report_day date not null unique,
 cutoff timestamptz not null,
 report_time text not null,
 recipients text[] not null,
 state text not null check(state in ('WAIT_PDF','READY','SEALED','EMPTY','BLOCKED')),
 snapshot jsonb,
 last_error text,
 created_at timestamptz not null default now(),
 sealed_at timestamptz,
 check((state='SEALED')=(snapshot is not null))
);
create table public.daily_dispatch_batch_routes(
 batch_id uuid not null references public.daily_dispatch_batches(id),
 route_id uuid not null,
 route_version integer not null,
 route_number text not null,
 data jsonb not null,
 primary key(route_id,route_version),
 unique(batch_id,route_number)
);
create index daily_dispatch_routes_batch on public.daily_dispatch_batch_routes(batch_id);
create table public.daily_dispatch_recipients(
 id uuid primary key default gen_random_uuid(),
 batch_id uuid not null references public.daily_dispatch_batches(id),
 recipient text not null,
 state text not null default 'PENDING' check(state in ('PENDING','PROCESSING','SENT','HELD')),
 token uuid,
 claimed_at timestamptz,
 next_at timestamptz not null default now(),
 attempts integer not null default 0,
 sent_at timestamptz,
 provider_id text,
 last_error text,
 unique(batch_id,recipient),
 check((state='PROCESSING')=(token is not null))
);
create index daily_dispatch_recipients_due on public.daily_dispatch_recipients(state,next_at);
alter table public.daily_dispatch_control enable row level security;
alter table public.daily_dispatch_batches enable row level security;
alter table public.daily_dispatch_batch_routes enable row level security;
alter table public.daily_dispatch_recipients enable row level security;
revoke all on public.daily_dispatch_control,public.daily_dispatch_batches,public.daily_dispatch_batch_routes,public.daily_dispatch_recipients from public,anon,authenticated;
grant select,insert,update on public.daily_dispatch_control,public.daily_dispatch_batches,public.daily_dispatch_batch_routes,public.daily_dispatch_recipients to service_role;

-- Normalización ordenada; mismo orden en todas las cabeceras.
create function public.daily_dispatch_addresses(p_addresses text[]) returns text[]
language sql immutable security invoker set search_path=public,pg_temp as $$
 select coalesce(array_agg(e order by first_pos),'{}'::text[])
 from (select lower(btrim(x)) e,min(pos) first_pos from unnest(p_addresses) with ordinality t(x,pos) group by 1) a
$$;
-- Se conserva sólo la información del snapshot publicada necesaria para el cálculo.
create function public.daily_dispatch_project(p jsonb) returns jsonb
language sql immutable security invoker set search_path=public,pg_temp as $$
 select jsonb_build_object(
 'stops',case when jsonb_typeof(p->'stops')='array' then
  (select coalesce(jsonb_agg(jsonb_build_object('stop_type',s->'stop_type','internal_location_key',s->'internal_location_key','order_numbers',s->'order_numbers') order by pos),'[]'::jsonb)
   from jsonb_array_elements(p->'stops') with ordinality t(s,pos)) end,
 'pdf_model',jsonb_build_object('total',p->'pdf_model'->'total','items',
  case when jsonb_typeof(p->'pdf_model'->'items')='array' then
  (select coalesce(jsonb_agg(jsonb_build_object('type',i->'type','r', case when jsonb_typeof(i->'r')='object' then jsonb_build_object(
   'id',i->'r'->'id','stopType',i->'r'->'stopType','mainOrder',i->'r'->'mainOrder',
   'internalLocationKey',i->'r'->'internalLocationKey','monto',i->'r'->'monto','bultos',i->'r'->'bultos',
   'locationOrders',case when jsonb_typeof(i->'r'->'locationOrders')='array' then
    (select coalesce(jsonb_agg(jsonb_build_object('main',o->'main') order by op),'[]'::jsonb)
     from jsonb_array_elements(i->'r'->'locationOrders') with ordinality q(o,op))
    else i->'r'->'locationOrders' end) end) order by pos),'[]'::jsonb)
   from jsonb_array_elements(p->'pdf_model'->'items') with ordinality t(i,pos)) end))
$$;
create function public.daily_dispatch_config() returns jsonb
language sql stable security invoker set search_path=public,pg_temp as $$
 select jsonb_build_object('active',c.enabled and c.cutover_day <= (now() at time zone 'America/Argentina/Mendoza')::date and s.sheet_email_enabled,
 'max_mime_bytes',c.max_mime_bytes) from public.daily_dispatch_control c join public.notification_settings s on s.id='DEFAULT' where c.id='DEFAULT'
$$;
-- El corte fija la lista y las versiones, aun si falta algún PDF. Nunca manda una lista parcial.
create function public.daily_dispatch_prepare() returns jsonb
language plpgsql security invoker set search_path=public,pg_temp as $$
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
  if not found then update public.daily_dispatch_batches set state='EMPTY' where id=b.id;return jsonb_build_object('state','EMPTY','id',b.id);end if;
 end if;
 if public.daily_dispatch_addresses(s.sheet_email_recipients) is distinct from b.recipients then
  update public.daily_dispatch_batches set state='BLOCKED',last_error='CONFIGURATION_CHANGED' where id=b.id;
  return jsonb_build_object('state','BLOCKED','id',b.id);
 end if;
 select count(*),count(p.id) into expected_count,ready_count from public.daily_dispatch_batch_routes x
 left join public.route_pdfs p on p.route_id=x.route_id and p.route_version=x.route_version and p.status='OK' and p.storage_path is not null and p.file_name is not null
 where x.batch_id=b.id;
 if expected_count<>ready_count then
  update public.daily_dispatch_batches set state='WAIT_PDF',last_error='PDF_PENDIENTE' where id=b.id;
  return jsonb_build_object('state','WAIT_PDF','id',b.id,'expected',expected_count,'ready',ready_count);
 end if;
 select jsonb_agg(x.data||jsonb_build_object('file_name',p.file_name,'storage_path',p.storage_path) order by x.route_number) into routes_json
 from public.daily_dispatch_batch_routes x join public.route_pdfs p on p.route_id=x.route_id and p.route_version=x.route_version
 where x.batch_id=b.id;
 update public.daily_dispatch_batches set state='READY',last_error=null where id=b.id;
 return jsonb_build_object('state','READY','id',b.id,'day',b.report_day,'time',b.report_time,'recipients',b.recipients,'routes',routes_json);
end $$;
create function public.daily_dispatch_seal(p_id uuid,p_snapshot jsonb) returns boolean
language plpgsql security invoker set search_path=public,pg_temp as $$
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
 if n=0 or jsonb_array_length(p_snapshot->'files')<>n then return false;end if;
 if exists(select 1 from public.daily_dispatch_batch_routes x where x.batch_id=p_id and
  not exists(select 1 from public.route_pdfs p cross join jsonb_array_elements(p_snapshot->'files') f
   where p.route_id=x.route_id and p.route_version=x.route_version and p.status='OK' and p.storage_path=f->>'storage_path' and p.file_name=f->>'name' and f->>'sha256'~'^[0-9a-f]{64}$')) then return false;end if;
 update public.daily_dispatch_batches set snapshot=p_snapshot,state='SEALED',last_error=null,sealed_at=now() where id=p_id;
 insert into public.daily_dispatch_recipients(batch_id,recipient) select p_id,e from unnest(b.recipients) e;
 return true;
end $$;
create function public.daily_dispatch_incident(p_id uuid,p_error text) returns boolean
language plpgsql security invoker set search_path=public,pg_temp as $$
begin
 update public.daily_dispatch_batches set last_error=left(p_error,160),
 state=case when p_error='PDF_NO_DISPONIBLE' then 'READY' else 'BLOCKED' end
 where id=p_id and state in ('WAIT_PDF','READY');
 return found;
end $$;
create function public.daily_dispatch_claim() returns jsonb
language plpgsql security invoker set search_path=public,pg_temp as $$
declare j public.daily_dispatch_recipients; s jsonb;
begin
 if not coalesce((public.daily_dispatch_config()->>'active')::boolean,false) then return jsonb_build_object('state','DISABLED');end if;
 select q.* into j from public.daily_dispatch_recipients q join public.daily_dispatch_batches b on b.id=q.batch_id
 where b.state='SEALED' and ((q.state='PENDING' and q.next_at<=now()) or (q.state='PROCESSING' and q.claimed_at<now()-interval '10 minutes'))
 order by b.report_day,q.next_at,q.id limit 1 for update of q skip locked;
 if not found then return jsonb_build_object('state','NO_PENDING');end if;
 update public.daily_dispatch_recipients set state='PROCESSING',token=gen_random_uuid(),claimed_at=now(),attempts=attempts+1 where id=j.id returning * into j;
 select snapshot into s from public.daily_dispatch_batches where id=j.batch_id;
 return jsonb_build_object('state','CLAIMED','id',j.id,'token',j.token,'batch_id',j.batch_id,'recipient',j.recipient,'snapshot',s);
end $$;
create function public.daily_dispatch_guard(p_id uuid,p_token uuid) returns boolean
language sql stable security invoker set search_path=public,pg_temp as $$
 select coalesce((public.daily_dispatch_config()->>'active')::boolean,false) and exists(
 select 1 from public.daily_dispatch_recipients j join public.daily_dispatch_batches b on b.id=j.batch_id
 join public.notification_settings s on s.id='DEFAULT'
 where j.id=p_id and j.token=p_token and j.state='PROCESSING' and b.state='SEALED'
 and s.sheet_email_enabled and public.daily_dispatch_addresses(s.sheet_email_recipients)=b.recipients and j.recipient=any(b.recipients))
$$;
create function public.daily_dispatch_finish(p_id uuid,p_token uuid,p_state text,p_reference text,p_error text) returns boolean
language plpgsql security invoker set search_path=public,pg_temp as $$
begin
 if p_state not in ('PENDING','SENT','HELD') or (p_state='SENT' and coalesce(p_reference,'')='') then return false;end if;
 update public.daily_dispatch_recipients set state=p_state,token=null,
 sent_at=case when p_state='SENT' then now() else null end,
 provider_id=case when p_state='SENT' then p_reference else null end,
 next_at=now()+interval '2 minutes',last_error=left(p_error,160)
 where id=p_id and state='PROCESSING' and token=p_token;
 return found;
end $$;

-- Las RPC nuevas sólo son utilizables por la función Edge, nunca desde una sesión cliente.
do $acl$
declare f record;
begin
 for f in select oid::regprocedure name from pg_proc where pronamespace='public'::regnamespace and proname in
 ('daily_dispatch_addresses','daily_dispatch_project','daily_dispatch_config','daily_dispatch_prepare','daily_dispatch_seal','daily_dispatch_incident','daily_dispatch_claim','daily_dispatch_guard','daily_dispatch_finish')
 loop
  execute 'revoke all on function '||f.name||' from public,anon,authenticated';
  execute 'grant execute on function '||f.name||' to service_role';
 end loop;
end $acl$;

-- Desactivar la creación de envíos individuales a partir del corte acordado; mantiene el circuito previo intacto al instalar.
-- No utilizar "enabled" para reactivar el legado: si se pausa el consolidado, no se duplican hojas ya informadas.
do $patch$
declare src text; patched text;
begin
 src:=pg_get_functiondef('public.queue_sheet_emails(date)'::regprocedure);
 patched:=replace(src,'if not s.sheet_email_enabled then return 0; end if;',
 'if exists(select 1 from public.daily_dispatch_control where id=''DEFAULT'' and cutover_day is not null and p_day>=cutover_day) then return 0; end if;'||chr(10)||'  if not s.sheet_email_enabled then return 0; end if;');
 if patched=src then raise exception 'PATCH_QUEUE_NO_APLICADO';end if;
 execute patched;
 src:=pg_get_functiondef('public.comm_enqueue_sheet_pdfs(timestamp with time zone)'::regprocedure);
 patched:=replace(src,'where public._comm_sheet_eligible(r)',
 'where public._comm_sheet_eligible(r) and not exists(select 1 from public.daily_dispatch_control c where c.id=''DEFAULT'' and c.cutover_day is not null and x.sheet_day>=c.cutover_day)');
 if patched=src then raise exception 'PATCH_COMM_NO_APLICADO';end if;
 execute patched;
end $patch$;
commit;
