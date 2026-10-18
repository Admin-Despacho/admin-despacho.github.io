-- SOLO PARA EL ARNÉS LOCAL. Objetos que existen en el proyecto Supabase real pero que NO crea ninguna migración del repo
-- (drift detectado al aplicar desde cero). No se despliega. Cada entrada debería resolverse con una migración que lo cree/documente.
-- 1) public.rls_auto_enable(): la referencia 20261030000100_rc4_1_2_revoke_internal_function_execute.sql (REVOKE EXECUTE).
create or replace function public.rls_auto_enable() returns event_trigger language plpgsql as $$ begin null; end $$;

