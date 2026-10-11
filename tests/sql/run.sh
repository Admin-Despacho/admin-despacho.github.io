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
for f in "$ROOT"/supabase/migrations/*.sql; do $PSQL -d okd -f "$f" >/dev/null; done
$PSQL -d okd -f "$HERE/post_migration_grants.sql" >/dev/null
for t in fase1_test fase1_1_test fase2a_test fase2a1_test fase2b1_test fase2b11_test fase2b2_test fase2b3_test rc1_test rc11_test rc12_test; do $PSQL -d okd -f "$HERE/$t.sql" >/dev/null; done
bash "$HERE/concurrency.sh" "$PSQL"
OUT="$($PSQL -d okd -f "$HERE/zz_summary.sql")"
echo "$OUT" | grep -E "^(PASS|FAIL|TOTAL)"
echo "$OUT" | grep -q "^FAIL" && exit 1 || exit 0
