#!/usr/bin/env bash
# Prueba la migración de Fase 1 y sus políticas RLS en un PostgreSQL 16 local temporal.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$HERE/../.."
PGBIN="${PGBIN:-$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | tail -1)}"
DATA="$(mktemp -d /tmp/okd_pg_XXXX)"; PORT="${PGPORT_TEST:-55432}"
RUNUSER=""; if [ "$(id -u)" = "0" ]; then RUNUSER="runuser -u postgres --"; chown -R postgres "$DATA"; fi
$RUNUSER "$PGBIN/initdb" -D "$DATA" -A trust -U postgres >/dev/null
$RUNUSER "$PGBIN/pg_ctl" -D "$DATA" -o "-p $PORT -k /tmp" -l "$DATA/log" -w start >/dev/null
trap '$RUNUSER "$PGBIN/pg_ctl" -D "$DATA" -m fast stop >/dev/null 2>&1 || true' EXIT
PSQL="$PGBIN/psql -h /tmp -p $PORT -U postgres -v ON_ERROR_STOP=1 -q"
$PSQL -c "create database okd" >/dev/null
$PSQL -d okd -f "$HERE/supabase_stub.sql" >/dev/null
# Orden REAL de aplicación (tests/sql/migration_order.txt, según el historial de git): varias migraciones se crearon con la hora real
# (2026101419…/2026101515…) DESPUÉS de las RC numeradas a futuro (…20261107…), así que el orden alfabético no es el orden aplicado
# y desde cero falla (p. ej. 20261014194713 usa el rol OPERARIO_DEPOSITO que crea 20261026000100). Toda migración debe estar listada.
ORDER="$HERE/migration_order.txt"
for f in "$ROOT"/supabase/migrations/*.sql; do grep -qx "$(basename "$f")" "$ORDER" || { echo "MIGRACIÓN SIN ORDEN: $(basename "$f") (agregala a tests/sql/migration_order.txt)"; exit 2; }; done
$PSQL -d okd -f "$HERE/prod_drift_stubs.sql" >/dev/null   # drift de producción conocido (ver el archivo)
while read -r m; do [ -n "$m" ] && $PSQL -d okd -f "$ROOT/supabase/migrations/$m" >/dev/null; done < "$ORDER"
$PSQL -d okd -f "$HERE/post_migration_grants.sql" >/dev/null
# SQL_TESTS permite elegir archivos (p. ej. SQL_TESTS="g2_revision_test" para las pruebas autónomas de G2/TAREA/traslados).
TESTS="${SQL_TESTS:-fase1_test fase1_1_test fase2a_test fase2a1_test fase2b1_test fase2b11_test fase2b2_test fase2b3_test rc1_test rc11_test rc12_test}"
for t in $TESTS; do $PSQL -d okd -f "$HERE/$t.sql" >/dev/null; done
[ -n "${SKIP_CONCURRENCY:-}" ] || bash "$HERE/concurrency.sh" "$PSQL"
OUT="$($PSQL -d okd -f "$HERE/zz_summary.sql")"
echo "$OUT" | grep -E "^(PASS|FAIL|TOTAL)"
echo "$OUT" | grep -q "^FAIL" && exit 1 || exit 0
