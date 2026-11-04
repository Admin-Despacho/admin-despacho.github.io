-- SOLO LECTURA (no modifica nada). Ejecutar en el SQL Editor de PRODUCCIÓN antes y después de aplicar la V4.23.
-- 1) Versiones de las funciones (antes: set_stop_outcome = V4.21 y finalize_route = c5bc9e2f98853281bebfeb6151b7d119; después: finalize_route = 779f1959bf9f5084088fa3c817f3ab1c)
select p.proname, md5(p.prosrc) as huella,
       case md5(p.prosrc) when '5d26e5af27a068596cc6875bd6ee8bbf' then 'V4.21' when '5e4bf78470b993100851b6dde6ae7f74' then 'V4.17 (aplicar primero la V4.21)'
                          when 'c5bc9e2f98853281bebfeb6151b7d119' then 'finalize_route anterior (base esperada)' when '779f1959bf9f5084088fa3c817f3ab1c' then 'finalize_route V4.23 (ya aplicada)' else 'DESCONOCIDA' end as version
  from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('set_stop_outcome','finalize_route','arrive_stop','_loc');
-- 2) DEPÓSITO DIAMANTE: ubicaciones existentes que podrían serlo (clave real, nombre, coordenadas, radio GPS, activa)
select location_key, name, address, lat, lon, radius_m, active, updated_at
  from public.internal_locations
 where name ilike '%diamante%' or location_key ilike '%diamante%' or address ilike '%diamante%'
 order by active desc, name;
-- Si devuelve UNA sola fila activa, la V4.23 la usa sola. Si devuelve VARIAS, un administrador elige la correcta en
-- Configuración → G2 · Ubicaciones (o con set_return_depot('<location_key>')). Si NO devuelve ninguna, revisar el nombre cargado.
-- 3) Todas las ubicaciones internas (para comparar si Diamante figura con otro nombre)
select location_key, name, radius_m, active from public.internal_locations order by name;
-- 4) DEPENDENCIAS que la V4.23 usa en el servidor real (todas deben dar true; si alguna da false, NO aplicar y avisar)
select 'funcion _loc(jsonb, route_stops)' as requisito, to_regprocedure('public._loc(jsonb, public.route_stops)') is not null as existe
union all select 'funcion _my_route(uuid)', to_regprocedure('public._my_route(uuid)') is not null
union all select 'funcion auth_has_perm(text)', to_regprocedure('public.auth_has_perm(text)') is not null
union all select 'funcion is_valid_email(text)', to_regprocedure('public.is_valid_email(text)') is not null
union all select 'tabla audit_log', to_regclass('public.audit_log') is not null
union all select 'internal_locations(location_key, name, lat, lon, radius_m, active)', (select count(*) = 6 from information_schema.columns where table_schema = 'public' and table_name = 'internal_locations' and column_name in ('location_key','name','lat','lon','radius_m','active'))
union all select 'carriers.kind', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'carriers' and column_name = 'kind')
union all select 'routes.started_at', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'routes' and column_name = 'started_at')
union all select 'route_stops(client_key, customer_email, expected_lat, expected_lon, expected_radius_m)', (select count(*) = 5 from information_schema.columns where table_schema = 'public' and table_name = 'route_stops' and column_name in ('client_key','customer_email','expected_lat','expected_lon','expected_radius_m'))
union all select 'profiles(role, status)', (select count(*) = 2 from information_schema.columns where table_schema = 'public' and table_name = 'profiles' and column_name in ('role','status'))
union all select 'NO existen todavía los objetos nuevos (client_emails, return_depot_settings)', to_regclass('public.client_emails') is null and to_regclass('public.return_depot_settings') is null;
-- 5) Hojas del Transportista Interno EN CURSO en este momento (no se bloquean: la exigencia rige solo para las iniciadas después de aplicar)
select r.number, r.started_at, r.operational_status from public.routes r join public.carriers c on c.id = r.carrier_id
 where c.kind = 'INTERNO' and r.operational_status = 'EN_CURSO' order by r.started_at;
