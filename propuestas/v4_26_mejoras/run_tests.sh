#!/usr/bin/env bash
# Pruebas de la PROPUESTA V4.26 en Postgres LOCAL (nunca producción): orden real del repositorio publicado + V4.25 (propuesta) + V4.26.
set -u; HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
D="$(mktemp -d /tmp/okd_v426_XXXX)"; (cd "$ROOT" && tar --exclude=./node_modules --exclude=./dist --exclude=./dist-demo --exclude=./.git -cf - .) | tar -xf - -C "$D"
# PRODUCCIÓN (ae80ee3): V4.25 (propuesta aplicada) → acceso completo del Administrador en Inspecciones (Work, ya aplicada) → SOLO la V4.26 nueva
for m in "$ROOT/propuestas/inspecciones/20261119000100_v4_25_inspecciones.sql" "$ROOT/supabase/migrations/20261105203928_inspections_admin_full_access.sql" "$HERE/20261120000100_v4_26_mejoras.sql"; do
  b=$(basename "$m"); cat "$ROOT/propuestas/comunicaciones/privilegios_produccion_solo_pruebas.sql" "$m" > "$D/supabase/migrations/$b"; printf '%s\n' "$b" >> "$D/tests/sql/migration_order.txt"; done
cp "$HERE/v4_26_test.sql" "$D/tests/sql/"; cp "$ROOT/tests/sql/inspections_admin_access_test.sql" "$D/tests/sql/" 2>/dev/null || true
# La migración de Work verifica que finalize_route sea la de PRODUCCIÓN (5bdf85ad…), cuya fuente no está en el repositorio (ver V4.23b).
# SOLO en esta copia de prueba se quita ESA verificación (las demás —todas las funciones de V4.25 y los 30 controles— se mantienen y se cumplen).
sed -i "/PRECONDITION_FAILED: finalize_route/d; /PROTECTED_FUNCTION_CHANGED: finalize_route/d" "$D/supabase/migrations/20261105203928_inspections_admin_full_access.sql"
# (la migración de Work NO se agrega dos veces: se quita del orden base si estuviera)
sed -i "/20261105203928_inspections_admin_full_access.sql/d" "$D/tests/sql/migration_order.txt"; printf "%s\n" 20261119000100_v4_25_inspecciones.sql 20261105203928_inspections_admin_full_access.sql 20261120000100_v4_26_mejoras.sql | while read b; do grep -qx "$b" "$D/tests/sql/migration_order.txt" || echo "$b" >> "$D/tests/sql/migration_order.txt"; done
# la base de prueba en UTF8, COMO PRODUCCIÓN (Supabase): la normalización de nombres con acentos lo requiere (el ejecutor compartido usa SQL_ASCII)
sed -i "s/create database okd\"/create database okd encoding 'UTF8' template template0 lc_collate 'C' lc_ctype 'C'\"/" "$D/tests/sql/run.sh"; grep -q "encoding 'UTF8'" "$D/tests/sql/run.sh" || { echo 'no se pudo forzar UTF8'; exit 2; }
SQL_TESTS="${SQL_TESTS_EXTRA:-} g2_revision_test v4_26_test" SKIP_CONCURRENCY=1 bash "$D/tests/sql/run.sh"; X=$?; rm -rf "$D"; exit $X
