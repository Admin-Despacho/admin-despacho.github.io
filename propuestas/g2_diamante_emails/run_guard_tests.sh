#!/usr/bin/env bash
# Protección por huella y recuperación de la V4.23 en Postgres LOCAL (nunca producción), con los MISMOS scripts que en producción.
set -u; HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
M21="$ROOT/propuestas/firma_cuil_sin_dni/20261116000100_v4_21_entrega_sin_dni_email_opcional.sql"; M23="$HERE/20261117000100_v4_23_g2_diamante_emails.sql"
PGBIN=$(ls -d /usr/lib/postgresql/*/bin | tail -1); D=$(mktemp -d /tmp/okd_g23_XXXX); chown -R postgres "$D"
runuser -u postgres -- "$PGBIN/initdb" -D "$D/db" -A trust -U postgres >/dev/null && runuser -u postgres -- "$PGBIN/pg_ctl" -D "$D/db" -o "-p 55492 -k /tmp" -l "$D/log" -w start >/dev/null
P="$PGBIN/psql -h /tmp -p 55492 -U postgres -q -At -d okd"; $PGBIN/psql -h /tmp -p 55492 -U postgres -q -c "create database okd" >/dev/null
$P -f "$ROOT/tests/sql/supabase_stub.sql" >/dev/null 2>&1; $P -f "$ROOT/tests/sql/prod_drift_stubs.sql" >/dev/null 2>&1
for m in $(cat "$ROOT/tests/sql/migration_order.txt"); do $P -f "$ROOT/supabase/migrations/$m" >/dev/null 2>&1; done
F() { $P -c "select md5(prosrc) from pg_proc where proname='finalize_route'"; }; T() { $P -c "select count(*) from pg_class where relname='client_emails'"; }
ok=0; fail=0; chk() { if [ "$2" = "1" ]; then echo "PASS | $1"; ok=$((ok+1)); else echo "FAIL | $1 | $3"; fail=$((fail+1)); fi; }
f0=$(F); $P -v ON_ERROR_STOP=1 -f "$M23" >/dev/null 2>"$D/e1"; r=$?
chk "G23-01 SIN la V4.21: se DETIENE (HUELLA_INESPERADA) y no crea ni cambia nada" $([ $r != 0 ] && grep -q "aplicá primero la V4.21" "$D/e1" && [ "$(F)" = "$f0" ] && [ "$(T)" = 0 ] && echo 1 || echo 0) "$(head -c 200 $D/e1)"
$P -v ON_ERROR_STOP=1 -f "$M21" >/dev/null 2>&1; $P -v ON_ERROR_STOP=1 -f "$M23" >/dev/null 2>"$D/e2"; r=$?; f2=$(F)
chk "G23-02 con la V4.21 aplicada, la V4.23 se aplica (finalize_route 779f1959…)" $([ $r = 0 ] && [ "$f2" = 779f1959bf9f5084088fa3c817f3ab1c ] && [ "$(T)" = 1 ] && echo 1 || echo 0) "$(head -c 200 $D/e2)"
$P -v ON_ERROR_STOP=1 -f "$M23" >/dev/null 2>"$D/e3"; r=$?
chk "G23-03 aplicada OTRA VEZ: se DETIENE y no cambia nada" $([ $r != 0 ] && grep -q HUELLA_INESPERADA "$D/e3" && [ "$(F)" = "$f2" ] && echo 1 || echo 0) "$(head -c 200 $D/e3)"
$P -v ON_ERROR_STOP=1 -f "$HERE/RECUPERACION_FINALIZE_ROUTE.sql" >/dev/null 2>"$D/e4"; r=$?
chk "G23-04 RECUPERACIÓN: finalize_route vuelve EXACTA a la anterior (c5bc9e2f…); columnas y tablas quedan (sin borrar datos)" $([ $r = 0 ] && [ "$(F)" = c5bc9e2f98853281bebfeb6151b7d119 ] && [ "$(T)" = 1 ] && echo 1 || echo 0) "$(head -c 200 $D/e4)"
$P -v ON_ERROR_STOP=1 -f "$M23" >/dev/null 2>"$D/e5"; r=$?
chk "G23-05 después de recuperar, la V4.23 se puede volver a aplicar" $([ $r = 0 ] && [ "$(F)" = 779f1959bf9f5084088fa3c817f3ab1c ] && echo 1 || echo 0) "$(head -c 200 $D/e5)"
runuser -u postgres -- "$PGBIN/pg_ctl" -D "$D/db" -m fast stop >/dev/null 2>&1; rm -rf "$D"
echo "TOTAL $ok PASS / $fail FAIL"; [ $fail = 0 ]
