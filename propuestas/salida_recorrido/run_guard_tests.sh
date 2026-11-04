#!/usr/bin/env bash
# Protección y recuperación de la V4.24 en Postgres LOCAL con los MISMOS scripts que en producción.
set -u; HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"; M24="$HERE/20261118000100_v4_24_salidas.sql"
M21="$ROOT/propuestas/firma_cuil_sin_dni/20261116000100_v4_21_entrega_sin_dni_email_opcional.sql"; M23="$ROOT/propuestas/g2_diamante_emails/20261117000100_v4_23_g2_diamante_emails.sql"
PGBIN=$(ls -d /usr/lib/postgresql/*/bin | tail -1); D=$(mktemp -d /tmp/okd_g24_XXXX); chown -R postgres "$D"
runuser -u postgres -- "$PGBIN/initdb" -D "$D/db" -A trust -U postgres >/dev/null && runuser -u postgres -- "$PGBIN/pg_ctl" -D "$D/db" -o "-p 55491 -k /tmp" -l "$D/log" -w start >/dev/null
P="$PGBIN/psql -h /tmp -p 55491 -U postgres -q -At -d okd"; $PGBIN/psql -h /tmp -p 55491 -U postgres -q -c "create database okd" >/dev/null
$P -f "$ROOT/tests/sql/supabase_stub.sql" >/dev/null 2>&1; $P -f "$ROOT/tests/sql/prod_drift_stubs.sql" >/dev/null 2>&1
for m in $(cat "$ROOT/tests/sql/migration_order.txt"); do $P -f "$ROOT/supabase/migrations/$m" >/dev/null 2>&1; done
F() { $P -c "select (to_regprocedure('public.record_route_departure(uuid,jsonb,text)') is not null)::int + (to_regprocedure('public.depart_internal_location(uuid,jsonb,text)') is not null)::int"; }
C() { $P -c "select count(*) from information_schema.columns where table_name in ('routes','route_stops') and column_name in ('start_location','location_departed_at')"; }
ok=0; fail=0; chk() { if [ "$2" = "1" ]; then echo "PASS | $1"; ok=$((ok+1)); else echo "FAIL | $1 | $3"; fail=$((fail+1)); fi; }
$P -v ON_ERROR_STOP=1 -f "$M24" >/dev/null 2>"$D/e1"; r=$?
chk "G24-01 SIN la V4.23: se DETIENE y no crea nada" $([ $r != 0 ] && grep -q "falta la V4.23" "$D/e1" && [ "$(F)" = 0 ] && [ "$(C)" = 0 ] && echo 1 || echo 0) "$(head -c 160 $D/e1)"
$P -v ON_ERROR_STOP=1 -f "$M21" >/dev/null 2>&1; $P -v ON_ERROR_STOP=1 -f "$M23" >/dev/null 2>&1; $P -v ON_ERROR_STOP=1 -f "$M24" >/dev/null 2>"$D/e2"; r=$?
chk "G24-02 con V4.21 y V4.23 aplicadas, la V4.24 se aplica (2 funciones + columnas)" $([ $r = 0 ] && [ "$(F)" = 2 ] && [ "$(C)" = 2 ] && echo 1 || echo 0) "$(head -c 160 $D/e2)"
$P -v ON_ERROR_STOP=1 -f "$M24" >/dev/null 2>"$D/e3"; r=$?
chk "G24-03 aplicada OTRA VEZ: se DETIENE (YA_APLICADA) sin cambiar nada" $([ $r != 0 ] && grep -q YA_APLICADA "$D/e3" && [ "$(F)" = 2 ] && echo 1 || echo 0) "$(head -c 160 $D/e3)"
$P -v ON_ERROR_STOP=1 -f "$HERE/RECUPERACION_V4_24.sql" >/dev/null 2>"$D/e4"; r=$?
chk "G24-04 RECUPERACIÓN: quita las 2 funciones y CONSERVA columnas y datos" $([ $r = 0 ] && [ "$(F)" = 0 ] && [ "$(C)" = 2 ] && echo 1 || echo 0) "$(head -c 160 $D/e4)"
$P -v ON_ERROR_STOP=1 -f "$M24" >/dev/null 2>"$D/e5"; r=$?
chk "G24-05 después de recuperar, la V4.24 se puede volver a aplicar" $([ $r = 0 ] && [ "$(F)" = 2 ] && echo 1 || echo 0) "$(head -c 160 $D/e5)"
runuser -u postgres -- "$PGBIN/pg_ctl" -D "$D/db" -m fast stop >/dev/null 2>&1; rm -rf "$D"
echo "TOTAL $ok PASS / $fail FAIL"; [ $fail = 0 ]
