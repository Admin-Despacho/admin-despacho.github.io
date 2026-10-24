# V4.18.1 — Transportistas, sin actualización de correos

Publicación parcial sobre 4374b9a. El constructor carga el catálogo del servidor y muestra los transportistas activos recién creados por Operario sin volver a iniciar sesión o importar archivos. Conserva selección por ID, refleja renombrados, excluye inactivos en hojas nuevas y permite reintentar una carga fallida.

Se incluyen las correcciones de demo para crear transportistas y despachar externos, y la prueba E2E de ocho comprobaciones como requisito del despliegue.

No se incluyen cambios del envío diario de correos, su panel de estado, Edge Functions, migraciones ni programación. El envío automático sigue pendiente de configuración. Se conserva la base V4.17 y sus correcciones anteriores.

Validación local: build de producción y demo, control del flujo del transportista y 20 pruebas unitarias aprobados. Chromium local no pudo iniciar por restricciones del entorno; el workflow ejecuta la prueba de transportistas, invitación, login visual y control efectivo del build antes de publicar.
