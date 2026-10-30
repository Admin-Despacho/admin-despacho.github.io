#!/usr/bin/env bash
# Pruebas de la PROPUESTA de Comunicaciones en Postgres LOCAL (nunca producción). Copia temporal + privilegios por defecto como en
# producción (solo pruebas) + Vault simulado (solo pruebas) + migración al final del orden real.
set -u; HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"; MIG="20261112000100_comunicaciones.sql"
D="$(mktemp -d /tmp/okd_comms_XXXX)"; (cd "$ROOT" && tar --exclude=./node_modules --exclude=./dist --exclude=./dist-demo --exclude=./.git -cf - .) | tar -xf - -C "$D"
cat "$HERE/privilegios_produccion_solo_pruebas.sql" "$HERE/vault_stub_solo_pruebas.sql" "$HERE/$MIG" > "$D/supabase/migrations/$MIG"
printf '%s\n' "$MIG" >> "$D/tests/sql/migration_order.txt"
cp "$HERE/comms_test.sql" "$D/tests/sql/"
SQL_TESTS="g2_revision_test comms_test" SKIP_CONCURRENCY=1 bash "$D/tests/sql/run.sh"; X=$?; rm -rf "$D"; exit $X
