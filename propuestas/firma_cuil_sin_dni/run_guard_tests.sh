#!/usr/bin/env bash
# Protección por huella y recuperación de la V4.21, en Postgres LOCAL (nunca producción): se aplican los MISMOS scripts que en producción.
set -u; HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"; MIG="$HERE/20261116000100_v4_21_entrega_sin_dni_email_opcional.sql"
PGBIN=$(ls -d /usr/lib/postgresql/*/bin | tail -1); D=$(mktemp -d /tmp/okd_guard_XXXX); chown -R postgres "$D"
runuser -u postgres -- "$PGBIN/initdb" -D "$D/db" -A trust -U postgres >/dev/null && runuser -u postgres -- "$PGBIN/pg_ctl" -D "$D/db" -o "-p 55494 -k /tmp" -l "$D/log" -w start >/dev/null
P="$PGBIN/psql -h /tmp -p 55494 -U postgres -q -At -d okd"; $PGBIN/psql -h /tmp -p 55494 -U postgres -q -c "create database okd" >/dev/null
$P -f "$ROOT/tests/sql/supabase_stub.sql" >/dev/null 2>&1; $P -f "$ROOT/tests/sql/prod_drift_stubs.sql" >/dev/null 2>&1
for m in $(cat "$ROOT/tests/sql/migration_order.txt"); do $P -f "$ROOT/supabase/migrations/$m" >/dev/null 2>&1; done
H() { $P -c "select md5(prosrc) from pg_proc where proname='set_stop_outcome'"; }
ok=0; fail=0; chk() { if [ "$2" = "1" ]; then echo "PASS | $1"; ok=$((ok+1)); else echo "FAIL | $1 | $3"; fail=$((fail+1)); fi; }
h0=$(H); $P -v ON_ERROR_STOP=1 -f "$MIG" >/dev/null 2>"$D/e1"; r1=$?; h1=$(H)
chk "G-01 sobre la V4.17 ($h0) la V4.21 se aplica y queda la huella esperada" $([ "$h0" = 5e4bf78470b993100851b6dde6ae7f74 ] && [ $r1 = 0 ] && [ "$h1" = 5d26e5af27a068596cc6875bd6ee8bbf ] && echo 1 || echo 0) "$(cat $D/e1)"
$P -v ON_ERROR_STOP=1 -f "$MIG" >/dev/null 2>"$D/e2"; r2=$?; h2=$(H)
chk "G-02 aplicada OTRA VEZ: se DETIENE (HUELLA_INESPERADA) y no cambia nada" $([ $r2 != 0 ] && grep -q HUELLA_INESPERADA "$D/e2" && [ "$h2" = "$h1" ] && echo 1 || echo 0) "$(head -c 200 $D/e2)"
$P -f "$ROOT/supabase/migrations/20261018191924_20261018201000_cristian_email_dni_required.sql" >/dev/null 2>&1; hc=$(H)
$P -v ON_ERROR_STOP=1 -f "$MIG" >/dev/null 2>"$D/e3"; r3=$?; h3=$(H)
chk "G-03 sobre OTRA versión (Cristian, $hc): se DETIENE y no cambia nada" $([ $r3 != 0 ] && grep -q HUELLA_INESPERADA "$D/e3" && [ "$h3" = "$hc" ] && echo 1 || echo 0) "$(head -c 200 $D/e3)"
$P -f "$ROOT/supabase/migrations/20261108000100_v4_17_set_stop_outcome.sql" >/dev/null 2>&1; $P -v ON_ERROR_STOP=1 -f "$MIG" >/dev/null 2>&1
$P -v ON_ERROR_STOP=1 -f "$HERE/RECUPERACION_VOLVER_A_V4_17.sql" >/dev/null 2>"$D/e4"; r4=$?; h4=$(H)
chk "G-04 RECUPERACIÓN: desde la V4.21 vuelve a la V4.17 EXACTA (5e4bf784…)" $([ $r4 = 0 ] && [ "$h4" = 5e4bf78470b993100851b6dde6ae7f74 ] && echo 1 || echo 0) "$(head -c 200 $D/e4)"
$P -v ON_ERROR_STOP=1 -f "$MIG" >/dev/null 2>"$D/e5"; r5=$?; h5=$(H)
chk "G-05 después de recuperar, la V4.21 se puede volver a aplicar" $([ $r5 = 0 ] && [ "$h5" = 5d26e5af27a068596cc6875bd6ee8bbf ] && echo 1 || echo 0) "$(head -c 200 $D/e5)"
runuser -u postgres -- "$PGBIN/pg_ctl" -D "$D/db" -m fast stop >/dev/null 2>&1; rm -rf "$D"
echo "TOTAL $ok PASS / $fail FAIL"; [ $fail = 0 ]
