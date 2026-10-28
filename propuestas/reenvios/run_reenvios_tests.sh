#!/usr/bin/env bash
# Pruebas de la PROPUESTA de reenvíos en Postgres LOCAL (nunca producción): copia temporal + migración al final del orden real.
set -u; HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"; MIG="20261111000100_reenvios_reintento_pedido.sql"
D="$(mktemp -d /tmp/okd_reenv_XXXX)"; (cd "$ROOT" && tar --exclude=./node_modules --exclude=./dist --exclude=./dist-demo --exclude=./.git -cf - .) | tar -xf - -C "$D"
cp "$HERE/$MIG" "$D/supabase/migrations/"; echo "$MIG" >> "$D/tests/sql/migration_order.txt"; cp "$HERE/reenvios_test.sql" "$D/tests/sql/"
SQL_TESTS="g2_revision_test reenvios_test" SKIP_CONCURRENCY=1 bash "$D/tests/sql/run.sh"; X=$?; rm -rf "$D"; exit $X
