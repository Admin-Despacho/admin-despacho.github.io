# QA local · Correos de autorizaciones V3

Solo pruebas locales. No usa red, ni el proyecto Supabase, ni SMTP real.

```bash
npm --prefix QA/tooling install pg@8                 # cliente PostgreSQL para node
bash QA/pg_local_correo_autorizaciones.sh            # PostgreSQL 16 temporal en 127.0.0.1:55447 (binarios en /usr/lib/postgresql/16)
node QA/build_base_correo_autorizaciones.mjs         # base equivalente a producción: módulo comercial 000100-001300 + PANEL_SOLO + INSTALL del correo
node QA/run_correo_autorizaciones.mjs                # V3: migración + funciones reales + trabajador V3 y PUBLICADO (2a8e65b) + SMTP simulado
npx vitest run tests/unit/commercial-decision-template.test.js tests/unit/commercial-decision-retry.test.js tests/unit/commercial-mail-delivery.test.js tests/unit/com-mail-panel.test.js
```

Contrato SQL publicado del correo corporativo, adaptado SOLO en la autorización expresa de la copia (cambio de V2/V3):
`QA/correo_v3/TEST_QA_V3_REGRESION.sql` (aplicar INSTALL.sql + la migración V3; termina en ROLLBACK).
- `tests/e2e/run_com_alarma_avisos.py dist-demo`: avisos emergentes de alarmas (confirmación de 5 s, X, sin historial trabado).
