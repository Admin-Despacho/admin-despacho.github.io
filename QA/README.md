# Exclusivamente pruebas locales

Estado esperado: NO APTO, WORK-K02 falla. No son instrucciones de despliegue.

Desde la raíz PROYECTO, crear `QA/tooling`, copiar `QA/package-tooling.json` a `QA/tooling/package.json` y ejecutar `npm install` dentro de QA/tooling. Se fijan versiones exactas de paquetes del registro npm oficial. Luego, desde PROYECTO, ejecutar `node QA/run.mjs`.

El runner arranca PostgreSQL desechable en 127.0.0.1:55449. No recibe URL ni claves de Supabase. No se conecta a producción y no envía correos. El fixture base contiene únicamente definiciones y datos sintéticos de G2; conserva los fines de línea de las funciones protegidas para respetar sus guardas. No editar el fixture mediante herramientas que normalicen esos fines de línea.

Salida esperada: PAQUETE 83/83, dos comprobaciones de concurrencia PASS, WORK 10/11. Código de salida 1 por el bloqueo financiero, no por preparación fallida. Ver resultados en QA/results. No eliminar ni alterar el caso fallido para conseguir una salida verde.

No ejecutar base_setup.sql, extra.sql ni ningún script QA en Supabase. El fixture incluye además una guarda que rechaza puertos distintos de los locales de pruebas. No desactivar esa protección.
