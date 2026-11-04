#!/usr/bin/env bash
# Pruebas de la PROPUESTA V4.21 en Postgres LOCAL (nunca producción), simulando PRODUCCIÓN: el orden real COMPLETO (incluida la V4.17,
# aplicada en producción el 22/10/2026) + la V4.21. Antes de aplicarla se capturan permisos y seguridad de la función para compararlos.
# Después: (a) la prueba funcional; (b) re-aplicar la V4.21 → la verificación de huella la detiene SIN cambiar nada; (c) recuperación a V4.17.
set -u; HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"; MIG="20261116000100_v4_21_entrega_sin_dni_email_opcional.sql"
D="$(mktemp -d /tmp/okd_v421_XXXX)"; (cd "$ROOT" && tar --exclude=./node_modules --exclude=./dist --exclude=./dist-demo --exclude=./.git -cf - .) | tar -xf - -C "$D"
{ cat <<'SQL'
create table if not exists public.qa_priv_before as
  select md5(p.prosrc) huella, has_function_privilege('anon', p.oid, 'EXECUTE') anon_x, has_function_privilege('authenticated', p.oid, 'EXECUTE') auth_x,
         has_function_privilege('service_role', p.oid, 'EXECUTE') srv_x, p.prosecdef sd, p.proconfig cfg, pg_get_userbyid(p.proowner) duenio
    from pg_proc p where p.proname = 'set_stop_outcome' and p.pronamespace = 'public'::regnamespace;
SQL
  cat "$HERE/$MIG"; } > "$D/supabase/migrations/$MIG"
printf '%s\n' "$MIG" >> "$D/tests/sql/migration_order.txt"
cp "$HERE/entrega_sin_foto_dni_test.sql" "$D/tests/sql/"
SQL_TESTS="g2_revision_test entrega_sin_foto_dni_test" SKIP_CONCURRENCY=1 bash "$D/tests/sql/run.sh"; X=$?
rm -rf "$D"; exit $X
