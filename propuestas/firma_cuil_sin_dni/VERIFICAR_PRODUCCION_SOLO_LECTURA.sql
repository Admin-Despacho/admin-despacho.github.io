-- SOLO LECTURA (no modifica nada). Ejecutar en el SQL Editor de Supabase de PRODUCCIÓN.
-- ANTES de aplicar: debe decir V4.17. DESPUÉS de aplicar: debe decir V4.21.
select md5(p.prosrc) as huella,
       case md5(p.prosrc)
         when '5e4bf78470b993100851b6dde6ae7f74' then 'V4.17 · base esperada: se puede aplicar la V4.21'
         when '5d26e5af27a068596cc6875bd6ee8bbf' then 'V4.21 · ya aplicada'
         else 'DESCONOCIDA · NO aplicar; enviar el resultado de pg_get_functiondef'
       end as version,
       pg_get_function_identity_arguments(p.oid) as argumentos,
       p.prosecdef as security_definer, p.proconfig as configuracion, pg_get_userbyid(p.proowner) as duenio,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') as ejecuta_authenticated,
       has_function_privilege('anon', p.oid, 'EXECUTE') as ejecuta_anon
  from pg_proc p where p.proname = 'set_stop_outcome' and p.pronamespace = 'public'::regnamespace;
