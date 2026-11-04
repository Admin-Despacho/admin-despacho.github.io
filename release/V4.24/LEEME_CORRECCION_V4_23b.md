# Corrección para desbloquear la publicación · V4.23 → **V4.23b** (y ajuste de la V4.24)
**Nada ejecutado en producción.** Reemplaza **solo** las carpetas `2_V4_23/` y `3_V4_24/` de `OK_DESPACHO_ACUMULADO_V4_24.zip`.
**No cambian:** V4.21, la pantalla (`cambios_acumulados_V4_24.patch`) y el SQL de hojas por Gmail.

## Investigación: por qué `finalize_route` tiene otra huella en producción
- **Repositorio (`99ffd09`, que sigue siendo `main`):** `finalize_route` se define en tres migraciones (fase2b1, fase2b2 y fase2b3; con una variante de firma en fase2b1), con copias idénticas en `./migrations/`.
  - **Resultado del orden completo:** `c5bc9e2f…` (la base que usó la V4.23).
  - **Resto de las definiciones:** ninguna da la huella de producción (calculé `c5bc9e2f…`, `e79c08b2…` y `8de4d2aa…`).
- **Producción:** `5bdf85adab176a36ec9b55ceb1af3179`. **No corresponde a ninguna versión del repositorio:** la función se modificó **directamente en el servidor** (o con un SQL que no se versionó).
  - **Desde acá no puedo ver su contenido:** para conocerlo hace falta `select pg_get_functiondef('public.finalize_route(uuid, numeric)'::regprocedure);` en producción (solo lectura).
- **Riesgo de la V4.23 original:** **reemplazaba** `finalize_route` con el texto del repositorio. En producción habría **borrado** las reglas que tenga esa versión no versionada. Su protección por huella lo detectó y frenó, como estaba previsto.

## Corrección (V4.23b): `finalize_route` NO se toca
- **"LLEGUÉ A DIAMANTE" obligatorio:** se exige con un **trigger** en `routes` (`routes_zz_depot_required`), no reemplazando la función.
- **Cuándo bloquea:** solo cuando una hoja pasa a COMPLETADA y se cumplen las cuatro condiciones:
  - es del **Transportista Interno**;
  - **no** tiene llegada al depósito;
  - se **inició después** de aplicar la migración (las hojas en curso no se bloquean);
  - la cierra el **propio chofer**, como en `finalize_route`.
  - Los cierres administrativos o de sistema no cambian.
- **Protección previa:** exige la V4.21 y que la V4.23 no esté aplicada. **No exige** una huella de `finalize_route`: **anota la que tenga** producción.
- **Verificación final, dentro de la misma transacción:** `finalize_route` tiene que quedar **idéntica** a la anotada (en producción, hoy `5bdf85ad…`); si no, se deshace todo. También verifica que exista el trigger.
- **Resto de la V4.23, sin cambios:** TERMINÉ EN, llegada al depósito, configuración del depósito y padrón de emails.
- **Depósito Diamante:** producción tiene **una sola** ubicación activa con clave `DIAMANTE`. La V4.23b la toma **sola**, sin clave inventada y **sin** pasos manuales.
- **Recuperación:** `RECUPERACION_FINALIZE_ROUTE.sql` ahora **solo quita el trigger**. `finalize_route` nunca se modificó y no hay datos que borrar.
- **V4.24:** su protección ya no busca la huella `779f1959…` (la de la V4.23 vieja); exige la V4.23b (llegada al depósito y trigger). Sin otros cambios.

## Pruebas (resultados en `RESULTADOS/`)
| Prueba | Resultado |
|---|---|
| SQL V4.23b sobre producción **simulada con una `finalize_route` DISTINTA** (con una regla propia) | **89/89**, incluido **G23b-03**: la regla propia sigue activa y además se exige Diamante |
| Protección y recuperación V4.23b (sin V4.21 se detiene · se aplica dejando `finalize_route` **exacta** · re-aplicar se detiene · recuperar quita solo el trigger) | **4/4** |
| SQL V4.24 · protección V4.24 | 71/71 · 5/5 |
| Interfaz: recorrido interno (Diamante, KM final, FINALIZAR, sin conexión) · perfiles del chofer (inicio, cierre, km, interno y externo) | 11/11 · 16/16 |

## Orden de publicación (reemplaza los pasos 0 a 5 de `PUBLICACION_SEGURA.md`)
1. **Solo lectura:**
   - **Consultas:** `2_V4_23b/VERIFICAR_PRODUCCION_SOLO_LECTURA.sql` (y la de V4.21).
   - **Resultados esperados:** `set_stop_outcome` = V4.17 (`5e4bf784…`) · **anotar** la huella de `finalize_route` (hoy `5bdf85ad…`) · Diamante con una sola activa (`DIAMANTE`) · dependencias en true.
   - **Recomendado (solo lectura):** guardar `pg_get_functiondef` de `finalize_route` como respaldo y para versionarla en el repositorio.
2. **V4.21:** verificación `5d26e5af…`.
3. **V4.23b:** `2_V4_23b/20261117000100_v4_23_g2_diamante_emails.sql`.
   - **Verificación después:** `finalize_route` con la **misma** huella anotada en el paso 1, y `routes_zz_depot_required` presente.
4. **V4.24:** `3_V4_24/20261118000100_v4_24_salidas.sql` (verificación: las 2 funciones existen).
5. **Hojas por Gmail y pantalla:** como en `PUBLICACION_SEGURA.md`, pasos 4, 6 y 7. Pasos 2 a 6 juntos, fuera del horario de reparto.

**Recuperación (orden inverso):**
- **Primero:** la pantalla.
- **Después, en este orden:** `3_V4_24/RECUPERACION_V4_24.sql` → `2_V4_23b/RECUPERACION_FINALIZE_ROUTE.sql` (solo el trigger) → `RECUPERACION_VOLVER_A_V4_17.sql` (V4.21).
