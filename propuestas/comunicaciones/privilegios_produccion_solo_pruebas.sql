-- SOLO PARA PRUEBAS LOCALES: reproduce los privilegios POR DEFECTO observados en producción (consulta de solo lectura):
-- todo objeto nuevo de postgres en "public" hereda ALL para anon/authenticated (tablas: arwdDxtm; secuencias; funciones).
alter default privileges for role postgres in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges for role postgres in schema public grant all on sequences to anon, authenticated, service_role;
alter default privileges for role postgres in schema public grant all on functions to anon, authenticated, service_role;
