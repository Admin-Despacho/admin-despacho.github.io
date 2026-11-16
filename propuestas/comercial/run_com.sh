set -u;   # AUD=1 agrega los casos de Work (auditoria_extra.sql) en la MISMA sesión que v4_28_test.sql
 ROOT=/tmp/com/OK; D="$(mktemp -d /tmp/okd_com_XXXX)"; (cd "$ROOT" && tar --exclude=./node_modules --exclude=./dist --exclude=./dist-demo --exclude=./.git -cf - .) | tar -xf - -C "$D"
P="$ROOT/propuestas/comunicaciones/privilegios_produccion_solo_pruebas.sql"
# PRODUCCIÓN 91d76ed: orden del repo + V4.25 + acceso del Administrador + V4.27 (Work) + DEFINICIONES REALES DE PRODUCCIÓN (consulta de solo lectura de Work: may_read, dependencias, 7 funciones, 6 políticas RLS) [+ V4.28]. La V4.26 publicada exige un objeto solo de producción y no toca este circuito.
for m in "$ROOT/propuestas/inspecciones/20261119000100_v4_25_inspecciones.sql" "$ROOT/supabase/migrations/20261105203928_inspections_admin_full_access.sql" "$ROOT/supabase/migrations/20261108161109_v4_27_aprobaciones_ruta_interna.sql" "/tmp/apr429/produccion_real_1_dependencias.sql" "$ROOT/supabase/migrations/20261106182306_v4_26_mejoras.sql" "/tmp/apr429/produccion_real_2_funciones.sql" "$ROOT/supabase/migrations/20261110124238_v4_28_ver_hoja_pendientes_receptor.sql" "$ROOT/propuestas/comercial/20261201000100_comercial_autorizaciones.sql"; do
  b=$(basename "$m"); cat "$P" "$m" > "$D/supabase/migrations/$b"; grep -qx "$b" "$D/tests/sql/migration_order.txt" || echo "$b" >> "$D/tests/sql/migration_order.txt"; done
sed -i "/PRECONDITION_FAILED: finalize_route/d; /PROTECTED_FUNCTION_CHANGED: finalize_route/d" "$D/supabase/migrations/20261105203928_inspections_admin_full_access.sql"
# V4.26 publicada: se aplica en el lazo, DESPUÉS de las definiciones reales (necesita may_read)
sed -i "s/create database okd\"/create database okd encoding 'UTF8' template template0 lc_collate 'C' lc_ctype 'C'\"/" "$D/tests/sql/run.sh"
cp /tmp/comtest/*_test.sql "$D/tests/sql/";  SQL_TESTS="${SQL_TESTS:-g2_revision_test comercial_test}" SKIP_CONCURRENCY=1 bash "$D/tests/sql/run.sh"; X=$?; rm -rf "$D"; exit $X
