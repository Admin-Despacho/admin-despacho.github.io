#!/usr/bin/env bash
# O-W03 · DRIFT de Edge Functions ANTES de cualquier despliegue (NO despliega nada). Lo ejecuta quien tenga acceso autorizado al proyecto.
# 1) descarga lo DESPLEGADO hoy · 2) lo compara con la base publicada (1925c44) y con este paquete · 3) guarda la copia EXACTA para la reversión.
# Uso: SUPABASE_ACCESS_TOKEN=… ./tools/edge_drift_check.sh <project-ref> <carpeta-base-1925c44> [funciones…]
set -euo pipefail
REF="${1:?project-ref}"; BASE="${2:?carpeta con la fuente de 1925c44}"; shift 2
FUNCS=("${@:-admin-users push-notifications}"); [ $# -eq 0 ] && FUNCS=(admin-users push-notifications)
OUT="edge_respaldo_$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$OUT"
for f in "${FUNCS[@]}"; do
  echo "== $f"; mkdir -p "$OUT/$f"
  ( cd "$OUT/$f" && supabase functions download "$f" --project-ref "$REF" >/dev/null )   # copia EXACTA de lo desplegado (rollback)
  find "$OUT/$f" -type f -print0 | sort -z | xargs -0 sha256sum > "$OUT/$f.sha256"
  for side in base paquete; do
    src=$([ $side = base ] && echo "$BASE/supabase/functions" || echo "supabase/functions")
    echo "-- desplegado vs $side"; diff -ru "$src/$f" "$OUT/$f/supabase/functions/$f" || true
    echo "-- _shared desplegado vs $side"; diff -ru "$src/_shared" "$OUT/$f/supabase/functions/_shared" || true
  done
done
echo "Copia exacta para la reversión en: $OUT (con huellas SHA-256). Si lo desplegado NO coincide con la base ni con el paquete: DETENERSE y revisar el diff completo."
