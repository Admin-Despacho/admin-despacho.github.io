#!/usr/bin/env bash
# REPORT PDF: genera los PDF reales y verifica su contenido (pdftotext).
set -uo pipefail
cd "$(dirname "$0")/../.."
OUT=tests/out/pdf; mkdir -p "$OUT"
${DENO:-deno} run --allow-read --allow-write --config supabase/functions/deno.json tests/pdf/make_pdf.js "$OUT" >/dev/null 2>&1 || { echo "FAIL | PDF-00 No se pudo generar el PDF"; exit 1; }
W="$(pdftotext -layout "$OUT/Informe_Cristian_Torres_Semanal_2026-10-10.pdf" -)"; M="$(pdftotext -layout "$OUT/Informe_Cristian_Torres_Mensual_2026-09.pdf" -)"
fail=0; chk(){ if grep -q -- "$3" <<< "$2"; then echo "PASS | $1"; else echo "FAIL | $1 (falta: $3)"; fail=1; fi; }
chk "PDF-01 Encabezado OK ACCESORIOS · INFORME CRISTIAN TORRES · SEMANAL" "$W" "INFORME CRISTIAN TORRES · SEMANAL"
chk "PDF-02 Período" "$W" "1. PERÍODO"
chk "PDF-03 Completados / no entregados / reprogramados" "$W" "ENVÍOS COMPLETADOS:"
chk "PDF-04 Zona Este separada" "$W" "Zona Este"
chk "PDF-05 Alrededores separado" "$W" "Alrededores"
chk "PDF-06 Centro separado" "$W" "Centro"
chk "PDF-07 Total general" "$W" "TOTAL GENERAL"
chk "PDF-08 Costo del período" "$W" "Costo Cristian del período"
chk "PDF-09 Resultado CUBRE / NO CUBRE" "$W" "CUBRE EL COSTO"
chk "PDF-10 Mejores clientes" "$W" "9. MEJORES CLIENTES"
chk "PDF-11 Clientes a recuperar" "$W" "10. CLIENTES A RECUPERAR"
chk "PDF-12 Zonas a reforzar" "$W" "11. ZONAS A REFORZAR"
chk "PDF-13 Decisiones sugeridas" "$W" "12. DECISIONES SUGERIDAS"
chk "PDF-14 / WEEK-04 Ventana real en el PDF" "$W" "Ventana analizada: 03/10/2026 15:00 al 10/10/2026 15:00"
chk "PDF-15 Mensual = mes calendario" "$M" "01/09/2026 al 30/09/2026"
chk "PDF-16 Mensual: costo del mes completo" "$M" "1.600.000"
if grep -qi "alrededores + centro" <<< "$W$M"; then echo "FAIL | PDF-17 Nunca agrupa Alrededores + Centro"; fail=1; else echo "PASS | PDF-17 Nunca agrupa Alrededores + Centro"; fi
SZ=$(stat -c%s "$OUT/Informe_Cristian_Torres_Semanal_2026-10-10.pdf"); if [ "$SZ" -lt 150000 ]; then echo "PASS | PDF-18 PDF liviano ($SZ bytes, sin mapas)"; else echo "FAIL | PDF-18 PDF pesado ($SZ bytes)"; fail=1; fi
# PDF final de hoja (Fase 2B.3)
${DENO:-deno} run --allow-read --allow-write --config supabase/functions/deno.json tests/pdf/make_route_pdf.js "$OUT/Hoja_03-000007.pdf" >/dev/null 2>&1 || { echo "FAIL | RPDF-00 No se pudo generar"; exit 1; }
T="$(pdftotext -layout "$OUT/Hoja_03-000007.pdf" -)"
chk "RPDF-01 Ruta publicada original" "$T" "RUTA PUBLICADA ORIGINAL"
chk "RPDF-02 Ruta real ejecutada con parada agregada y movida" "$T" "PARADA AGREGADA"
chk "RPDF-03 Resultados, incidencias y bultos" "$T" "INCIDENCIA: NO ENTREGADO"
chk "RPDF-04 Vehículo y km" "$T" "Km final 50085"
chk "RPDF-05 Estado / aprobación" "$T" "PENDIENTE DE APROBACIÓN"
chk "RPDF-06 Historial con cambios offline" "$T" "(sin conexión)"
if grep -qiE "20123456786|CUIL|DNI|-32\.9|firma" <<< "$T"; then echo "FAIL | RPDF-07 Sin DNI/CUIL/GPS/firma"; fail=1; else echo "PASS | RPDF-07 Sin DNI/CUIL/GPS/firma"; fi
exit $fail
