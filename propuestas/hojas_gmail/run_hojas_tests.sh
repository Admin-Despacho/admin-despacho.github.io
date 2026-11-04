#!/usr/bin/env bash
# Pruebas de la PROPUESTA "correo de hojas por Gmail" en Postgres LOCAL (nunca producción). Copia temporal del repositorio +
# migración al final del orden real, con privilegios por defecto equivalentes a producción (solo pruebas). Corre además la prueba
# completa de Comunicaciones como regresión (se redefinen comm_check, comm_create_run y la unicidad de comm_runs).
set -u; HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"; MIG="20261113000100_hojas_por_gmail.sql"
D="$(mktemp -d /tmp/okd_hojas_XXXX)"; (cd "$ROOT" && tar --exclude=./node_modules --exclude=./dist --exclude=./dist-demo --exclude=./.git -cf - .) | tar -xf - -C "$D"
cat "$ROOT/propuestas/comunicaciones/privilegios_produccion_solo_pruebas.sql" "$HERE/$MIG" > "$D/supabase/migrations/$MIG"
printf '%s\n' "$MIG" >> "$D/tests/sql/migration_order.txt"
cp "$ROOT/propuestas/comunicaciones/comms_test.sql" "$HERE/hojas_gmail_test.sql" "$D/tests/sql/"
SQL_TESTS="g2_revision_test comms_test hojas_gmail_test" SKIP_CONCURRENCY=1 bash "$D/tests/sql/run.sh"; X=$?; rm -rf "$D"; exit $X
