#!/usr/bin/env bash
# Pruebas de la PROPUESTA V4.25 en Postgres LOCAL (nunca producción): orden real completo del repositorio + V4.25. Usuarios ficticios de G2.
set -u; HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="${OKD_ROOT:-$(cd "$HERE/../.." && pwd)}"; M=20261119000100_v4_25_inspecciones.sql
D="$(mktemp -d /tmp/okd_v425_XXXX)"; (cd "$ROOT" && tar --exclude=./node_modules --exclude=./dist --exclude=./dist-demo --exclude=./.git -cf - .) | tar -xf - -C "$D"
cat "$ROOT/propuestas/comunicaciones/privilegios_produccion_solo_pruebas.sql" "$HERE/$M" > "$D/supabase/migrations/$M"; printf '%s\n' "$M" >> "$D/tests/sql/migration_order.txt"
cp "$HERE/v4_25_test.sql" "$D/tests/sql/"; cp "$HERE/../controles_excel.json" "$D/tests/sql/" 2>/dev/null
SQL_TESTS="g2_revision_test v4_25_test" SKIP_CONCURRENCY=1 bash "$D/tests/sql/run.sh"; X=$?; rm -rf "$D"; exit $X
