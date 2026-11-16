-- Solo PostgreSQL temporal de pruebas. Del esquema QA/base_setup.sql.
-- En Supabase, service_role ya tiene estos privilegios. Acá se otorgan para la prueba local.
grant usage on schema public to service_role;
grant all on all tables in schema public to service_role;
grant all on all sequences in schema public to service_role;
grant execute on all functions in schema public to service_role;

;
-- SOLO PARA PRUEBAS LOCALES: reproduce los privilegios POR DEFECTO observados en producción (consulta de solo lectura):
-- todo objeto nuevo de postgres en "public" hereda ALL para anon/authenticated (tablas: arwdDxtm; secuencias; funciones).
alter default privileges for role postgres in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges for role postgres in schema public grant all on sequences to anon, authenticated, service_role;
alter default privileges for role postgres in schema public grant all on functions to anon, authenticated, service_role;
