-- Código asignado en servidor; nunca reutilizar prefijos históricos.
create or replace function public.upsert_carrier(p jsonb)
returns public.carriers
language plpgsql security definer set search_path = public
as $$
declare
 c public.carriers;
 cid text := upper(trim(p->>'id'));
 code text;
 n integer;
begin
 if not (public.auth_has_perm('settings.manage') or public.auth_has_perm('carriers.manage')) then
   raise exception 'FORBIDDEN' using errcode='42501';
 end if;
 if cid = '' or coalesce(trim(p->>'name'),'') = '' then
   raise exception 'BAD_CARRIER: id y nombre obligatorios' using errcode='23514';
 end if;
 -- Serializa creaciones concurrentes; evita que dos transportistas reciban el mismo número.
 perform pg_advisory_xact_lock(871410, 2026);
 select * into c from public.carriers where id=cid for update;
 if found then
   code := c.sequence_code;
   if nullif(p->>'sequence_code','') is not null and p->>'sequence_code' <> code then
     raise exception 'IMMUTABLE_CODE: el correlativo histórico no se puede modificar' using errcode='23514';
   end if;
 else
   select coalesce(max(v),0)+1 into n from (
     select sequence_code::integer as v from public.carriers where sequence_code ~ '^[0-9]{2}$'
     union all
     select rs.code::integer from public.route_sequences rs where rs.code ~ '^[0-9]{2}$'
   ) all_codes;
   if n > 99 then raise exception 'NO_SEQUENCE_CODE: límite de 99 códigos alcanzado' using errcode='23514'; end if;
   code := lpad(n::text,2,'0');
 end if;
 insert into public.carriers(id,name,kind,active,sequence_code,report_group,emails,notes)
 values(cid,upper(p->>'name'),coalesce(p->>'kind','EXTERNO'),coalesce((p->>'active')::boolean,true),code,
        nullif(p->>'report_group',''),
        coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(p->'emails','[]'::jsonb)) x),'{}'),p->>'notes')
 on conflict(id) do update set name=excluded.name,kind=excluded.kind,active=excluded.active,
   report_group=excluded.report_group,emails=excluded.emails,notes=excluded.notes
 returning * into c;
 insert into public.audit_log(actor_id,action,target_type,target_id,after)
 values(auth.uid(),'CARRIER_SAVED','carrier',c.id,to_jsonb(c));
 return c;
end; $$;
