#!/usr/bin/env bash
# Pruebas de la PROPUESTA V4.23 en Postgres LOCAL (nunca producción), simulando PRODUCCIÓN: orden real completo (con la V4.17)
# + V4.21 + V4.23, con privilegios por defecto equivalentes a producción para los objetos nuevos.
set -u; HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
D="$(mktemp -d /tmp/okd_v423_XXXX)"; (cd "$ROOT" && tar --exclude=./node_modules --exclude=./dist --exclude=./dist-demo --exclude=./.git -cf - .) | tar -xf - -C "$D"
M21="20261116000100_v4_21_entrega_sin_dni_email_opcional.sql"; M23="20261117000100_v4_23_g2_diamante_emails.sql"
cp "$ROOT/propuestas/firma_cuil_sin_dni/$M21" "$D/supabase/migrations/"
cat "$ROOT/propuestas/comunicaciones/privilegios_produccion_solo_pruebas.sql" "$HERE/$M23" > "$D/supabase/migrations/$M23"
printf '%s\n%s\n' "$M21" "$M23" >> "$D/tests/sql/migration_order.txt"
cp "$HERE/v4_23_test.sql" "$D/tests/sql/"
SQL_TESTS="g2_revision_test v4_23_test" SKIP_CONCURRENCY=1 bash "$D/tests/sql/run.sh"; X=$?; rm -rf "$D"; exit $X
