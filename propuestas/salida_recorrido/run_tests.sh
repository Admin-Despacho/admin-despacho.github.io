#!/usr/bin/env bash
# Pruebas de la PROPUESTA V4.24 en Postgres LOCAL (nunca producción): orden real completo (con V4.17) + V4.21 + V4.23 + V4.24.
set -u; HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
D="$(mktemp -d /tmp/okd_v424_XXXX)"; (cd "$ROOT" && tar --exclude=./node_modules --exclude=./dist --exclude=./dist-demo --exclude=./.git -cf - .) | tar -xf - -C "$D"
M21=20261116000100_v4_21_entrega_sin_dni_email_opcional.sql; M23=20261117000100_v4_23_g2_diamante_emails.sql; M24=20261118000100_v4_24_salidas.sql
cp "$ROOT/propuestas/firma_cuil_sin_dni/$M21" "$D/supabase/migrations/"
cat "$ROOT/propuestas/comunicaciones/privilegios_produccion_solo_pruebas.sql" "$ROOT/propuestas/g2_diamante_emails/$M23" > "$D/supabase/migrations/$M23"
cat "$ROOT/propuestas/comunicaciones/privilegios_produccion_solo_pruebas.sql" "$HERE/$M24" > "$D/supabase/migrations/$M24"
printf '%s\n%s\n%s\n' "$M21" "$M23" "$M24" >> "$D/tests/sql/migration_order.txt"
cp "$HERE/v4_24_test.sql" "$D/tests/sql/"
SQL_TESTS="g2_revision_test v4_24_test" SKIP_CONCURRENCY=1 bash "$D/tests/sql/run.sh"; X=$?; rm -rf "$D"; exit $X
