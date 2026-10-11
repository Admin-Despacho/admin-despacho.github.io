#!/usr/bin/env bash
# Corre TODA la batería de la Fase 1 y deja el resumen en tests/out/summary.txt
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p tests/out; S=tests/out/summary.txt; : > "$S"
step(){ echo "== $1" | tee -a "$S"; }
step "BUILD (vite build)";            npx vite build >tests/out/build.log 2>&1 && echo "BUILD PASS" | tee -a "$S" || echo "BUILD FAIL" | tee -a "$S"
step "UNIT (vitest)";                 npx vitest run >tests/out/unit.log 2>&1; grep -E "Tests " tests/out/unit.log | tee -a "$S"
step "EDGE FUNCTION (deno test)";     ${DENO:-deno} test --allow-read --config supabase/functions/deno.json supabase/functions >tests/out/deno.log 2>&1; grep -E "passed|failed" tests/out/deno.log | tail -1 | sed 's/\x1b\[[0-9;]*m//g' | tee -a "$S"
step "EDGE FUNCTION (deno check)";    ${DENO:-deno} check --config supabase/functions/deno.json supabase/functions/*/index.ts >tests/out/deno_check.log 2>&1 && echo "TYPECHECK PASS" | tee -a "$S" || echo "TYPECHECK FAIL" | tee -a "$S"
step "PDF REAL (pdf-lib + pdftotext)"; DENO=${DENO:-deno} bash tests/pdf/check_pdf.sh >tests/out/pdf.log 2>&1; echo "$(grep -c "^PASS" tests/out/pdf.log) PASS / $(grep -c "^FAIL" tests/out/pdf.log) FAIL" | tee -a "$S"
step "SQL + RLS (PostgreSQL local)";  bash tests/sql/run.sh >tests/out/sql.log 2>&1; tail -1 tests/out/sql.log | tee -a "$S"
step "E2E (Chromium, build)";         python3 tests/e2e/run_e2e.py >tests/out/e2e.log 2>&1; tail -1 tests/out/e2e.log | tee -a "$S"
step "E2E FASE 2A.1 (archivos reales Elisa)"; python3 tests/e2e/run_e2e_fase2a1.py >tests/out/e2e_2a1.log 2>&1; tail -1 tests/out/e2e_2a1.log | tee -a "$S"
step "E2E FASE 2B.1 (publicar → finalizar)"; python3 tests/e2e/run_e2e_fase2b1.py >tests/out/e2e_2b1.log 2>&1; tail -1 tests/out/e2e_2b1.log | tee -a "$S"
step "E2E FASE 2B.2"; python3 tests/e2e/run_e2e_fase2b2.py >tests/out/e2e_2b2.log 2>&1; tail -1 tests/out/e2e_2b2.log | tee -a "$S"
step "E2E FASE 2B.3"; python3 tests/e2e/run_e2e_fase2b3.py >tests/out/e2e_2b3.log 2>&1; tail -1 tests/out/e2e_2b3.log | tee -a "$S"
step "E2E RC1.1 usuarios"; python3 tests/e2e/run_e2e_rc11.py >tests/out/e2e_rc11.log 2>&1; tail -1 tests/out/e2e_rc11.log | tee -a "$S"
step "E2E RC1.2 PDF"; python3 tests/e2e/run_e2e_rc12.py >tests/out/e2e_rc12.log 2>&1; tail -1 tests/out/e2e_rc12.log | tee -a "$S"
