# Dos cambios independientes en este proyecto (base: commit 992abd0)

| | CAMBIO 1 · Permiso de asignación + "⇄ Cambiar rol" | CAMBIO 2 · Reenvíos sin duplicar el informe |
|---|---|---|
| Resumen | `RESUMEN_PERMISO_ASIGNACION.md` | `RESUMEN_REENVIOS.md` |
| Servidor (NO aplicado) | `propuestas/permiso_asignacion_hojas/` (`20261110000100_…`) | `propuestas/reenvios/` (`20261111000100_…`) |
| App | `supabase/functions/_shared/rules.js`, `src/online/role-view.js` (nuevo), `src/main.js`, `src/online/rc4-ui.js`, `admin-ui.js`, `users-ui.js`, `supabase-admin.js`, `demo-admin.js`, `demo-rc4.js`, `driver-ui.js` (incluye la corrección de "Agregar parada"), `src/styles/online.css` | `supabase/functions/_shared/report-engine.js`, `report-pdf.js`, `report-email.js`, `report-demo-data.js`, `src/online/reports-ui.js` |
| Archivo compartido | `src/online/demo-api.js`: `_mine`, `driverInternalLocations`, `me()` | `src/online/demo-api.js`: `_retryable`, `_reserve`, `_liveForReport` (pedidos de cada parada) |
| Pruebas | `tests/unit/permiso-asignacion.test.js`, `tests/e2e/run_cambiar_rol.py`, `run_cambiar_rol_revision.py`, `run_agregar_parada_refresco.py`, `run_revocacion_admin.py` | `tests/unit/report-reenvios.test.js`, `tests/e2e/run_reenvios.py`, `run_reenvios_constructor.py` |

- **Independencia:** los dos cambios no dependen entre sí; las migraciones pueden aplicarse en cualquier orden.
- **Estado:** no se publicó nada, no se ejecutó SQL en producción, no se habilitó el permiso a ninguna cuenta real (usuario previsto: **Guillermo Castillo**) y no se envían correos.
