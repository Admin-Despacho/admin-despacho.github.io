#!/usr/bin/env bash
# Pruebas de la PROPUESTA del permiso en Postgres LOCAL (nunca producción): copia temporal + migración al final del orden real.
set -u; HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"; MIG="20261110000100_permiso_asignacion_hojas.sql"
D="$(mktemp -d /tmp/okd_perm_XXXX)"; (cd "$ROOT" && tar --exclude=./node_modules --exclude=./dist --exclude=./dist-demo --exclude=./.git -cf - .) | tar -xf - -C "$D"
cp "$HERE/$MIG" "$D/supabase/migrations/"; echo "$MIG" >> "$D/tests/sql/migration_order.txt"; cp "$HERE/permiso_asignacion_test.sql" "$D/tests/sql/"
SQL_TESTS="g2_revision_test permiso_asignacion_test" SKIP_CONCURRENCY=1 bash "$D/tests/sql/run.sh"; X=$?; rm -rf "$D"; exit $X
