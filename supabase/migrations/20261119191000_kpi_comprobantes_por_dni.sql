-- Usar la identidad documental del padrón solo para el cruce comercial de comprobantes.
do $migration$
declare f regprocedure; src text; old_line text; new_line text;
begin
  select oid::regprocedure into strict f from pg_proc where pronamespace='public'::regnamespace and proname='com_ingest' and md5(prosrc)='b77fde594edf251164201fe498430690';
  src:=pg_get_functiondef(f);
  old_line:='if not public._cuit_valid(cu) then skip_cuit := skip_cuit + 1; continue; end if;            -- sin CUIT verificable: no se cruza';
  new_line:=$body$if not public._cuit_valid(cu) then
      if cu ~ '^[0-9]{7,8}$' and (select count(*)=1 and bool_and(c0.status='ACTIVO' and c0.doc_valid and c0.cuit is null)
            from public.com_clients c0 where c0.doc_type='DNI' and c0.doc_number=cu and c0.status<>'BAJA') then
        cu := 'DNI:' || cu;
      else
        skip_cuit := skip_cuit + 1; continue;
      end if;
    end if;$body$;
  if strpos(src,old_line)=0 then raise exception 'Ingesta incompatible'; end if;
  src:=replace(src,old_line,new_line);
  old_line:='where cuit = r->>''cuit'' and status <> ''BAJA'' order by status limit 1';
  if strpos(src,old_line)=0 then raise exception 'Conciliación incompatible'; end if;
  execute replace(src,old_line,$body$where (cuit = r->>'cuit' or (cuit is null and doc_type='DNI' and doc_valid and 'DNI:'||doc_number=r->>'cuit')) and status <> 'BAJA' order by status limit 1$body$);

  select oid::regprocedure into strict f from pg_proc where pronamespace='public'::regnamespace and proname='_com_kpi_raw' and md5(prosrc)='bbf21b409489ce8fc27281eb7faf276f';
  src:=pg_get_functiondef(f);
  old_line:='  if c.cuit is null then return';
  new_line:=$body$  if c.cuit is null and c.doc_type='DNI' and c.doc_valid and c.doc_number ~ '^[0-9]{7,8}$' and c.status='ACTIVO' then
    if exists(select 1 from public.com_clients c0 where c0.id<>c.id and c0.status<>'BAJA' and c0.doc_type='DNI' and c0.doc_number=c.doc_number) then
      return jsonb_build_object('status','SIN_HISTORIAL','detail','DNI compartido por más de un registro del padrón. Revisar el cruce antes de calcular el KPI.','months_cfg',s.kpi_months,'last_update',last_sc);
    end if;
    c.cuit := 'DNI:' || c.doc_number; -- variable local, sin alterar el CUIT del cliente
    if not exists(select 1 from public.com_sc_documents d0 where d0.cuit=c.cuit) then
      return jsonb_build_object('status','SIN_HISTORIAL','detail','Sin comprobantes vinculados todavía al DNI '||c.doc_number||'. Podés continuar con la solicitud.','months_cfg',s.kpi_months,'last_update',last_sc);
    end if;
  end if;
  if c.cuit is null then return$body$;
  if strpos(src,old_line)=0 then raise exception 'KPI incompatible'; end if;
  execute replace(src,old_line,new_line);
end $migration$;
