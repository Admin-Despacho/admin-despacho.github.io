# Parche incremental G2 · "+ AGREGAR PARADA" con ubicación interna, segunda visita y terminología

- **Base:** la entrega anterior (`1aeaccb`, rama `fix/revision-claude-g2-tareas`).
- **No se tocó producción.** Sin push, sin deploy y sin migraciones aplicadas.

## A. Archivos modificados
| Archivo | Cambio |
|---|---|
| `supabase/migrations/20261018165341_g2_driver_location_stops.sql` | **NUEVA** (no se modificó la `…000100`) |
| `src/online/driver-ui.js` | "+ AGREGAR PARADA" con TIPO DE PARADA (TAREA / UBICACIÓN INTERNA), búsqueda G2 de solo lectura y contadores "paradas" en hojas internas |
| `src/online/supabase-api.js` | `driverInternalLocations()` |
| `src/online/demo-api.js` | mismas reglas en la demo: G2 elegida por el chofer, snapshot al agregar, "paradas" en avisos internos |
| `src/styles/online.css` | selector y lista G2 cómodos en celular (botones de 44 px o más) |
| `tests/sql/g2_revision_test.sql`, `tests/sql/push_concurrency.sh`, `tests/sql/migration_order.txt` | pruebas nuevas y orden de la migración nueva |
| `tests/e2e/run_e2e_g2.py`, `tests/e2e/run_responsive_g2.py` | pruebas nuevas |
| `docs/PARCHE_G2_PARADAS_DRIVER.md` | este documento |

## B. Commit
Ver `git log 1aeaccb..HEAD`. El parche va en `patches_incremental/`.

## C. Migración nueva: `20261018165341_g2_driver_location_stops.sql`
Forward-only, sin borrar datos, **NO aplicada**. Va después de `20261018165305`.

1. Reemplaza el índice único (ver G).
2. `driver_internal_locations()`: el chofer ve las G2 activas (clave, nombre, domicilio, radio), **sin coordenadas**. No puede leer ni modificar la tabla `internal_locations`.
3. `add_internal_stop` acepta `stop_type = 'UBICACION_INTERNA'` + `internal_location_key`:
   - exige que la G2 exista y esté activa;
   - nombre y domicilio salen de G2 y el **snapshot GPS** (lat, lon, radio, versión) se toma **al agregarla** (trigger `_stop_type_rules`);
   - los **pedidos se ignoran** (`order_numbers = '{}'`), igual que los montos y el email;
   - se mantienen `provenance = 'DRIVER'`, `added_by`, `added_at`, nueva versión, evento e idempotencia por `client_op_id` y auditoría.
4. Trigger `trg_notification_internal_wording`: en hojas de Transporte Interno, los avisos "nueva hoja / hoja corregida" dicen "N paradas". Los externos siguen diciendo "entregas".

**Firma:** `set_stop_outcome` ya exigía receptor y firma para toda `UBICACION_INTERNA`, con o sin pedidos. Se confirma con pruebas (DRVLOC-07, DRVLOC-UI-04).

## D. Tests agregados
- **SQL:**
  - WORD-01: avisos internos con "paradas".
  - DRVLOC-00..09: lista G2 para el chofer, segunda visita, snapshot al agregar, pedidos ignorados, mismo `client_op_id` → una parada, original intacta, firma sin pedidos, GPS contra su snapshot, recepción interna sin email.
  - UNIQ-02: unicidad solo administrativa.
  - **DRVLOC-CONC-01:** doble toque simultáneo con dos sesiones PostgreSQL reales → una sola parada.
- **E2E (Chromium, demo):**
  - WORD-UI-01: "N paradas" y "Faltan N paradas por resolver".
  - DRVLOC-UI-01..04: el chofer elige Montecaseros desde el celular, la original no cambia, un reintento no duplica y la firma es obligatoria sin pedidos.
- **Responsive:** RESP-ADD-360/390/412/430 (selector nuevo) y 2 pantallas más por celular.

Prueba adaptada por **cambio de requisito**: DRV-01. Antes mandaba una G2 para comprobar que el chofer *no* podía usarla; ahora prueba la TAREA libre (y que se ignoran pedidos colados).

## E. Resultados
| Suite | Resultado |
|---|---|
| SQL `g2_revision_test` + concurrencia | **57 PASS / 0 FAIL** |
| E2E `run_e2e_g2.py` | **23 PASS / 0 FAIL** (2 corridas iguales) |
| Responsive `run_responsive_g2.py` | **29 PASS / 0 FAIL** |
| Push del service worker | 3 PASS / 0 FAIL |
| Unitarias / Deno | 91/94 y 103/106: las **mismas 3 + 3 fallas previas** del commit original, sin cambios |

## F. Screenshots responsive nuevas
En `screenshots/` (360×800, 390×844, 412×915 y 430×932):
- `movil_*_6_agregar_parada_tipo_y_busqueda_g2.png`
- `movil_*_7_agregar_parada_g2_elegida.png`

Además, el resto de las capturas regeneradas.

## G. Unicidad: constructor administrativo vs. segunda visita del chofer
- **Antes** (`…000100`): `unique (route_id, internal_location_key) where stop_type = 'UBICACION_INTERNA'`. Con la regla nueva, **impedía** que el chofer volviera a Montecaseros. Conflicto detectado y corregido.
- **Ahora** (`…000200`): se reemplaza por `route_stops_one_admin_internal_location_per_route` = `unique (route_id, internal_location_key) where stop_type = 'UBICACION_INTERNA' and provenance is distinct from 'DRIVER'`.
  - **Constructor, publicación y revisión** (paradas no DRIVER): siguen sin duplicados. En el cliente se abre la parada existente para editarla; en el servidor, el índice rechaza un duplicado accidental (DUP-01).
  - **Chofer durante la hoja en curso** (`provenance = 'DRIVER'`): puede agregar explícitamente una visita nueva a una G2 ya visitada (Montecaseros → clientes → banco → Montecaseros).
  - **Doble toque / reintento:** no lo frena el índice sino la idempotencia. `route_change_events.client_op_id` es UNIQUE y el celular manda además el id de la parada. Probado de forma secuencial (DRVLOC-04, DRVLOC-UI-03) y **simultánea** (DRVLOC-CONC-01).
- **Si `…000100` ya se aplicó en algún entorno:** `…000200` hace `drop index if exists` del índice anterior y crea el nuevo. Si no se aplicó, ambas se aplican en orden con el mismo resultado.

## H. Confirmaciones
| Afirmación | Estado | Evidencia |
|---|---|---|
| El chofer puede elegir Montecaseros desde + AGREGAR PARADA | TEST PASS + VERIFICADO EN CHROMIUM | DRVLOC-UI-01, RESP-ADD-*, capturas 6 y 7 |
| Usa el GPS y el radio de G2 (snapshot al agregarla) | TEST PASS | DRVLOC-02, DRVLOC-08, DRVLOC-UI-01 |
| Exige firma aunque no tenga pedidos | TEST PASS | DRVLOC-07, DRVLOC-UI-04 |
| Puede volver explícitamente a una G2 ya visitada | TEST PASS | DRVLOC-01, DRVLOC-UI-01 |
| No puede modificar pedidos | TEST PASS | DRVLOC-03, DRVLOC-05, DRVLOC-UI-01/02 |
| Un reintento no duplica la parada | TEST PASS | DRVLOC-04, DRVLOC-UI-03, DRVLOC-CONC-01 |
| Los contadores generales dicen PARADAS y no ENTREGAS | TEST PASS + VERIFICADO EN CHROMIUM | WORD-01, WORD-UI-01, capturas |

Sin cambios en lo ya aprobado: G2 administrativo con varios pedidos = una parada, reservas atómicas, observación, recepción interna, TAREA, push, transportistas externos y responsive previo. Todas esas pruebas siguen en PASS.

## Pendiente / requiere celular real
- Probar en Android e iPhone: el selector nuevo con teclado virtual abierto y la firma.
- Sin conexión, la lista G2 no se puede cargar: el formulario lo avisa. Para una TAREA libre no hace falta.

