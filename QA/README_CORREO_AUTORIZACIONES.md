# QA local · Correos de autorizaciones con detalle

Solo pruebas locales. No usa red, ni el proyecto Supabase, ni SMTP real.

```bash
npm --prefix QA/tooling install pg@8                 # cliente PostgreSQL para node
bash QA/pg_local_correo_autorizaciones.sh            # PostgreSQL 16 temporal en 127.0.0.1:55447 (requiere binarios en /usr/lib/postgresql/16)
node QA/build_base_correo_autorizaciones.mjs         # base equivalente a producción: módulo comercial 000100-001300 + PANEL_SOLO + INSTALL del correo
node QA/run_correo_autorizaciones.mjs                # migración + funciones reales + trabajador real + SMTP simulado (67 casos)
npx vitest run tests/unit/commercial-decision-template.test.js tests/unit/commercial-decision-retry.test.js tests/unit/com-mail-panel.test.js
```
