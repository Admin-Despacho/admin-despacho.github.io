# Guía para revisar y publicar con otra herramienta (ChatGPT u otra)

Este proyecto se entiende solo con este repositorio, sin depender de la conversación en la que se creó.

## Estado
- **Fase 2A entregada (0.2.0-fase2a): informe comercial de Cristian Torres + email. NO está lista para publicar en producción.** Ver `CAMBIOS_FASE2A.md`.
- Pendiente: Fase 2B (publicación en vivo, celular del transportista, FINALIZAR HOJA, rutas internas con aprobación). Sin esa fase, el informe no tiene datos reales.
- Aprobado por el usuario: prototipo V16 (en vivo + notificaciones), en `docs/prototipo/`. Es la referencia de comportamiento para la Fase 2.
- Regla de imagen: la app online debe verse como la versión offline v15 (cabecera oscura, cyan, fondo claro). El panel del Operario ES la v15.

## Orden sugerido
1. Leer `README.md` y `TEST_RESULTS.md`.
2. Correr `bash tests/run_all.sh` (requiere Node 20, Deno 2, PostgreSQL 16 y Playwright de Python).
3. Crear el proyecto Supabase propio de OK Despacho siguiendo `docs/GUIA_SUPABASE.md` y repetir las pruebas marcadas NOT RUN en un proyecto real.
4. Publicar en Cloudflare con `docs/GUIA_CLOUDFLARE.md`, primero en un entorno de prueba.

## No hacer
- No usar el proyecto Supabase, las tablas ni las credenciales de MAGIC.
- No poner la `service_role` en el frontend ni en el repositorio.
- No cambiar la lógica financiera de `public/legacy/despacho-v15.js` sin repetir la batería completa de la v15.
