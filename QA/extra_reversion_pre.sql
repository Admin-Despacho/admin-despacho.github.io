-- SOLO PRUEBAS LOCALES · REVERSIÓN del módulo (al FINAL de toda la suite, sobre la base con datos de todas las pruebas)
create temp table rv_checks(name text, ok boolean, detail text);
create temp table rv_antes as select (select count(*) from public.com_requests) sol, (select count(*) from public.com_alarms) alr, (select count(*) from public.com_alarm_events) ev;
-- (a) con un usuario que tiene COMERCIAL restringido: se DETIENE sin cambios
select set_config('okd.sync', 'on', false); update public.profiles set disabled_modules = array['COMERCIAL'] where id = 'c0000000-0000-0000-0000-0000000000c1'; select set_config('okd.sync', '', false);
create temp table rv_a(err text);
