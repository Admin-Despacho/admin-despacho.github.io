-- SOLO LECTURA. Antes de la V4.24: finalize_route debe ser la V4.23 (779f1959…) y record_route_departure NO debe existir.
select md5(prosrc) = '779f1959bf9f5084088fa3c817f3ab1c' as v4_23_aplicada from pg_proc where proname = 'finalize_route' and pronamespace = 'public'::regnamespace;
select to_regprocedure('public.record_route_departure(uuid, jsonb, text)') is not null as salida_deposito_aplicada,
       to_regprocedure('public.depart_internal_location(uuid, jsonb, text)') is not null as salida_sucursal_aplicada,
       exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'routes' and column_name = 'start_location') as columna_start_location;
