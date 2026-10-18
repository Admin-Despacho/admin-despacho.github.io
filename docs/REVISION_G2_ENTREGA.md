# Corrección INFORME_REVISION_CLAUDE · G2, traslado interno, TAREA, push y responsive

- **Rama local:** `fix/revision-claude-g2-tareas`, sobre `3346637`.
- **No se desplegó nada.** No se tocó Supabase de producción ni GitHub (no hay push), y no se aplicó ninguna migración en ningún entorno real.
- **Constructor:** se modificó solo `public/legacy/despacho-v15.js`. No se recrearon `legacy/` ni `docs/legacy/`.

Términos usados en este documento:
- **TEST AUTOMÁTICO PASS:** una prueba automática lo verificó.
- **VERIFICADO EN CHROMIUM:** ejecutado en Chromium real, con viewports o CDP; no es un celular.
- **REQUIERE PRUEBA REAL EN CELULAR:** no se pudo probar en un dispositivo.

## Confirmaciones pedidas
| Afirmación | Estado | Evidencia |
|---|---|---|
| Montecaseros con varios pedidos = UNA parada | TEST AUTOMÁTICO PASS | LOC-01 (SQL), LOC-UI-01, PUB-UI-01 (E2E) |
| Los pedidos quedan agrupados (incluido pedido + envío) | TEST AUTOMÁTICO PASS | LOC-01, LOC-08, LOC-UI-03/04, DRV-UI-01 |
| La observación llega al chofer | TEST AUTOMÁTICO PASS + VERIFICADO EN CHROMIUM | LOC-03, OBS-UI-01, DRV-UI-01 + capturas |
| La recepción interna exige firma | TEST AUTOMÁTICO PASS | REC-01..04 (SQL), REC-UI-01/02 (E2E) |
| No se genera entrega comercial | TEST AUTOMÁTICO PASS | LOC-04, LOC-07, TAR-02, KPI-01, REC-UI-01, TAR-UI-02 |
| Operario puede usar G2 (leer y usar, no administrar) | TEST AUTOMÁTICO PASS | G2-01..05 (SQL), G2-ROL-01, LOC-UI-* (E2E como Operario) |
| Transportista puede agregar TAREA dinámica futura | TEST AUTOMÁTICO PASS | DRV-01..06 (SQL), DRV-UI-02 (E2E) |
| Push revisado | Revisado de punta a punta; 3 problemas corregidos | sección A.9; falta el celular real (sección D) |
| Responsive móvil revisado | VERIFICADO EN CHROMIUM (viewports emulados) | 25/25 + capturas; **no** en celular real |
| No se tocó producción | Confirmado | sin acceso a Supabase ni a producción desde este entorno; sin push |

## A. CORREGIDO
1. **Una ubicación interna = una sola parada** (`openInternalLocationComposer`).
   - Resuelve y valida todos los pedidos, reserva todos en **una sola llamada** (`reserve_orders`, atómica) y crea **una** fila `UBICACION_INTERNA` con todos los pedidos.
   - Si un pedido tiene envío asociado, conserva el par en la misma parada.
   - La observación va en `instructions` y la clave G2 en `internal_location_key`.
   - Ya no crea filas PEDIDO sueltas.
2. **Sin duplicados:** si la ubicación ya está en la hoja, se abre la misma parada para sumar o quitar pedidos y editar la observación. Quitar un pedido libera su reserva (y la del envío).
   - En el servidor, un índice único `(route_id, internal_location_key)` para `UBICACION_INTERNA`.
   - "Segunda visita": **no implementada**, como se pidió.
3. **Reservas:** `publish_route` y `dispatch_external_route` marcan PUBLICADA **solo** las reservas de pedidos presentes en las paradas.
   - Si el borrador tiene reservas huérfanas, la publicación se **rechaza** (`ORPHAN_RESERVATIONS: <pedidos>`).
   - El constructor ofrece "LIBERARLOS Y REINTENTAR" de forma explícita.
   - Los borradores de la versión anterior (pedidos sueltos de una ubicación) quedan bloqueados para publicar con un mensaje claro.
4. **Observación = `instructions`** (fuente única; ya no se usa `obsPago`). Se ve en:
   - el constructor (editable antes de publicar);
   - el payload, el snapshot y `route_stops`;
   - la app del chofer ("OBSERVACIÓN");
   - el historial;
   - PDF y Excel, en la celda de la parada, nunca en "Observaciones de pago";
   - la auditoría.
5. **Recepción interna de traslado.** Una `UBICACION_INTERNA` exige receptor y firma para cerrar.
   - Se guarda en `stop_evidence` con `evidence_kind = 'RECEPCION_INTERNA'`, distinto del Recibido Conforme comercial.
   - `audit_log` registra `INTERNAL_TRANSFER_RECEIVED` con sucursal, domicilio, pedidos, quién recibió, quién trasladó, hoja, fecha y GPS real + esperado + radio + distancia.
   - Sin email, sin comprobante comercial, sin cobranza, sin perfil de identidad y fuera de los KPI comerciales.
   - En el chofer los botones dicen "RECIBIDO EN SUCURSAL / RECEPCIÓN PARCIAL / NO RECIBIDO".
6. **TAREA.**
   - Resultados REALIZADO / REALIZADO PARCIAL / NO REALIZADO / REPROGRAMAR.
   - **Sin firma ni receptor obligatorios** (GPS + observación) y sin campo de email.
   - Sin email al cliente, Recibido Conforme, cobranza ni KPI comercial.
7. **G2:**
   - **Permisos:** lectura para `routes.create` / `locations.view` (Operario y Superior); escritura solo `settings.manage` / `locations.manage`, por RPC. Se audita el antes y el después, el radio está acotado (10 a 5000 m) y no se permiten nombres activos duplicados.
   - **Datos en la hoja:** nombre y domicilio vienen de G2 y son de **solo lectura**.
   - **Asociación:** solo por **clave explícita**; se eliminó la asociación por nombre o domicilio.
   - **Búsqueda en el constructor:** con varias coincidencias se elige de una lista, no la primera a ciegas. Si G2 no devuelve nada por permisos, el mensaje es distinto de "no encontrada".
8. **GPS con snapshot al publicar** (`expected_lat/lon/radius_m`, `internal_location_updated_at`).
   - `_loc` valida contra ese snapshot: editar o desactivar G2 después no cambia la hoja.
   - La llegada y el cierre guardan lat/lon reales y esperadas, radio, distancia, `outside_m`, fuente y clave.
   - Las hojas publicadas o en curso con clave explícita reciben un snapshot inicial con el punto actual al migrar.
9. **Web Push.**
   - **Duplicados:** la toma de trabajos es atómica (`claim_push_jobs`, `FOR UPDATE SKIP LOCKED`). Antes, dos ejecuciones simultáneas podían enviar la misma notificación dos veces.
   - **Reintentos:** ERROR con espera creciente hasta 5 intentos y recuperación de envíos trabados. Antes no había reintentos.
   - **Envío programado opcional:** con `x-cron-secret`, para no depender de que alguien tenga la app abierta.
   - **Cerrar sesión da de baja el dispositivo:** antes un celular compartido seguía recibiendo los avisos del usuario anterior.
10. **Transportista externo:** el servidor rechaza `TAREA` y `UBICACION_INTERNA` si el transportista no es INTERNO. En el constructor esas filas ya no tienen selector de transportista.
11. **Parada agregada por el chofer:** se fuerza `stop_type = 'TAREA'`, con instrucciones, contacto y teléfono.
    - Ya tenía `provenance = 'DRIVER'`, `added_by`, `added_at`, versión y auditoría; se ubica al final y la tarjeta muestra "AGREGADA".
    - Ignora pedidos o clave G2 aunque el celular los mande.
    - No hay RPC que edite paradas existentes y `route_stops` no admite escritura directa (RLS).
12. **Geocodificación.**
    - **Acceso:** sesión obligatoria y permiso de administrar G2, `verify_jwt` explícito, límite de 10 búsquedas por minuto por usuario y caché de 24 h.
    - **Consulta:** usa Mendoza, Argentina como contexto, limitada a la provincia ("San Juan" = calle de Mendoza) y no antepone el nombre del punto.
    - **Resultados:** hasta 5 candidatos con precisión (altura / calle / zona) y puntaje. Si hay ambigüedad o el resultado es impreciso, la persona elige; se guardan `geocode_source` y `geocode_display_name`.
13. **Dashboard y KPI:** las incidencias de entrega cuentan solo paradas PEDIDO. El aviso "en camino" se envía solo para pedidos comerciales.
14. **Responsive** (detectado en la revisión visual):
    - Los botones de enlace del chofer ("← Mis hojas", "Borrar firma") eran menores de 30 px: se les dio área táctil mínima sin cambiar el aspecto.
    - El pie fijo (KM FINAL / FINALIZAR) tapaba la firma y GUARDAR con una parada abierta: ahora deja de estar fijo mientras hay un formulario abierto. Un control negativo comprobó que la prueba detecta el problema.
15. **Modo demo** con las mismas reglas que el servidor: G2, traslado, TAREA, recepción interna, huérfanas, snapshot y parada DRIVER.

## B. TEST AUTOMÁTICO PASS
| Suite | Resultado | Notas |
|---|---|---|
| SQL nueva `g2_revision_test` (base desde cero, orden real) | **44 PASS / 0 FAIL** | incluye PUSH-CONC-01 con 2 sesiones PostgreSQL reales |
| E2E nueva `run_e2e_g2.py` (modo demo, Chromium) | **18 PASS / 0 FAIL** (2 corridas iguales) | con pedidos reales del informe |
| Push del service worker `run_push_sw.py` (Chromium + CDP) | **3 PASS / 0 FAIL** | |
| Responsive `run_responsive_g2.py` | **25 PASS / 0 FAIL** | |
| Deno geocode-location | **8 PASS / 0 FAIL** | |
| Deno, todas las funciones | 103 PASS / **3 FAIL previas** | el HEAD original tenía 95 PASS / 3 FAIL, las mismas 3 (admin-users F06 y F1.1-10, commercial-reports 12b) |
| Unitarias (vitest) | 91 PASS / **3 FAIL previas** | idénticas en el HEAD original (D07, REPORT-MAIL-12, U17) |
| Chequeo de tipos | 8 de 9 funciones OK | `password-recovery` **ya fallaba** en el HEAD original y no se tocó |
| Build de producción | OK | |

Las pruebas obligatorias 1 a 13 están cubiertas:
1. LOC-01, LOC-UI-01
2. DUP-01, DUP-UI-01
3. LOC-03, OBS-UI-01, PUB-UI-01, DRV-UI-01
4. RES-01/02, RES-UI-02, RES-04/05
5. G2-01..05, G2-ROL-01
6. GPS-01, GPS-UI-01
7. TAR-01/02, KPI-01, TAR-UI-02
8. LOC-04/07
9. REC-01..04, REC-UI-01/02
10. DRV-01..06, DRV-UI-02
11. EXT-01/02
12. Responsive (25)
13. PUSH-01..05, PUSH-CONC-01, PUSH-SW-01..03

## C. VERIFICADO EN CHROMIUM
- **Celulares** 360×800, 390×844, 412×915 y 430×932 (viewport móvil con touch):
  - Pantallas recorridas: Mis hojas, hoja con KM inicial, tarjeta de traslado con 6 pedidos y observación larga, recepción interna con firma, + AGREGAR PARADA.
  - Resultado: sin scroll horizontal, nada más ancho que la pantalla, sin controles afuera, sin texto cortado, botones de 30 px o más y el pie sin tapar la firma.
- **Escritorio** 1920×1080, 1440×900, 1366×768 y 1280×720 × zoom 100/125/150 % (viewport CSS reducido con densidad equivalente): constructor y composer de ubicación sin desborde.
- **Service worker:** activo, recibe el push (CDP), muestra la notificación con título, texto y URL, y la misma etiqueta no se duplica.

## D. REQUIERE PRUEBA REAL EN CELULAR
- **Android, PWA instalada:**
  - recibir push con la app cerrada, en segundo plano y abierta;
  - permiso rechazado y revocado; endpoint vencido (410 → baja automática); dos dispositivos;
  - logout (deja de recibir); sesión expirada; offline y reconexión;
  - clic en la notificación abre la hoja; ícono y badge.
- **iPhone, PWA instalada (iOS 16.4 o superior):** todo lo anterior. Push en iOS solo funciona con la PWA agregada a la pantalla de inicio.
- **Firma táctil, GPS real, teclado virtual** sobre los formularios (receptor, firma, + AGREGAR PARADA) y KM final.
- **Push programado:** si se activa, verificar que la tarea programada llame a la función con `x-cron-secret`.

## E. NO VERIFICADO / PENDIENTE
- **Suites heredadas ya rotas antes de esta corrección**, sin reescribir (fuera de alcance):
  - SQL histórica: sus fixtures usan el rol DESPACHO, eliminado en `20261031000100`;
  - E2E general: busca `#btnUsers`, que ya no existe;
  - las 3 unitarias y 3 de Deno listadas en B.
- **Envío real de push** con las claves VAPID de producción.
- **Geocodificación real:** Nominatim y ArcGIS en vivo. Se probó con respuestas simuladas.
- **Ubicación interna SIN pedidos:** sigue exigiendo firma, como antes. La regla nueva solo define el caso con pedidos. **Necesita decisión.**
- **Parada agregada por el chofer hacia una ubicación G2** (por ejemplo, "volver a Montecaseros"): hoy queda como TAREA sin GPS de G2. No se inventó una regla. **Necesita decisión.**

## F. MIGRACIONES
- **Archivo:** `supabase/migrations/20261108000100_g2_tareas_traslados_revision.sql` (forward-only, sin borrar datos; **NO aplicada**).
- **Orden:** va después de todas, tanto por número como por fecha real. No se renombró ninguna migración.

**Drift detectado contra el historial real de producción:**
| Producción | Repo |
|---|---|
| `20261014202304` web_push_notifications | `20261014202300_web_push_notifications.sql` (otro número) |
| `20261015115110` carriers_authenticated_read | `20261015085000_carriers_authenticated_read.sql` (otro número) |
| `20261015115301` carrier_dispatch_mode_rpc | **no existe en el repo** |
| `20261015132132` password_recovery_rate_limits | `20261015132000_…` (otro número) |
| `20261015153841` internal_route_task_metadata | **no existe**; el repo tiene `20261015153500_internal_route_tasks.sql` |
| — | `public.rls_auto_enable()` existe en producción pero ninguna migración la crea |

Por eso la migración es **defensiva**: crea las columnas de TAREA solo si faltan y redefine el trigger de metadata, sin depender del contenido de `internal_route_task_metadata`.

**Riesgos de la migración:**
1. Redefine `set_stop_outcome`, `_loc`, `publish_route`, `dispatch_external_route`, `add_internal_stop`, `_queue_on_the_way`, `dashboard_admin` y `dashboard_supervisor` a partir de su **versión del repo**. Si producción tiene una versión distinta (por el drift), esa diferencia se pisaría. Comparar antes de aplicar:
   ```sql
   select proname, md5(pg_get_functiondef(oid)) from pg_proc where pronamespace='public'::regnamespace and proname in (...);
   ```
2. Agrega un índice único `(route_id, internal_location_key)` para `UBICACION_INTERNA`. Si ya hay duplicados por el error anterior, **falla**. Verificar antes:
   ```sql
   select route_id, internal_location_key, count(*) from route_stops where stop_type='UBICACION_INTERNA' group by 1,2 having count(*)>1;
   ```
3. Las hojas ya publicadas o en curso con pedidos sueltos de una ubicación (versión anterior) se validan contra el snapshot del punto actual.

**Aplicación (NO ejecutada).** En **staging** primero:
1. Backup.
2. Ejecutar las dos verificaciones anteriores.
3. Revisar el SQL.
4. Aplicarlo con el editor SQL o con `supabase migration up` **solo** sobre esta migración. Sin `db push` y sin `--include-all`.
5. Registrar la versión `20261108000100` en `supabase_migrations.schema_migrations` si se aplicó a mano.
6. Desplegar las Edge Functions `geocode-location` y `push-notifications`.
7. Opcional: programar `push-notifications` con `x-cron-secret`.

En el repo, alinear el drift con `migration repair` (decisión de quien administra el proyecto).

## G. COMMITS (rama `fix/revision-claude-g2-tareas`)
- `673af68` Servidor: G2, traslados, TAREA, reservas, snapshot, permisos, arnés SQL.
- `b23b6d2` Recepción interna con firma y evidencia propia; migración defensiva frente al drift.
- `93102fe` geocode-location.
- `8a66178` Constructor, chofer, historial, PDF y Excel.
- `8dfd772` Modo demo y E2E de G2.
- `fd88029` Web Push.
- `fabffe0` Responsive y pruebas de responsive y push del service worker.
- Último commit: reversión de `deno.lock`.

## H. ARCHIVOS MODIFICADOS
- **Constructor:** `public/legacy/despacho-v15.js`.
- **App:** `src/main.js`, `src/online/admin-ui.js`, `src/online/demo-api.js`, `src/online/driver-ui.js`, `src/online/push-notifications.js`, `src/online/supabase-admin.js`, `src/styles/online.css`.
- **Supabase:** `supabase/config.toml`, `supabase/functions/geocode-location/{index.ts, handler.js, handler.test.js}`, `supabase/functions/push-notifications/index.ts`, `supabase/migrations/20261108000100_g2_tareas_traslados_revision.sql`.
- **Pruebas:** `tests/sql/{g2_revision_test.sql, migration_order.txt, prod_drift_stubs.sql, push_concurrency.sh, run.sh}`, `tests/e2e/{run_e2e_g2.py, run_push_sw.py, run_responsive_g2.py}`.
- **Documentación:** `docs/REVISION_G2_ENTREGA.md`.

## I. RIESGOS RESTANTES
1. **Drift de producción** (sección F): mientras no se alinee, ningún entorno nuevo se puede crear desde el repo sin el orden manual.
2. **Clave VAPID:** la privada está en la tabla `push_vapid_config`. Si el backup incluye esa tabla, la clave sale en el ZIP. Conviene moverla a un secreto de la Edge Function.
3. **Badge de Android:** usa el ícono a color. Android recomienda un badge monocromo; no se tocó (branding).
4. **`pushsubscriptionchange`** no está implementado. Si el navegador rota la suscripción, se vuelve a registrar recién en el próximo inicio de sesión.
5. **Selector de transportista con varios elegidos:** las filas de ubicación y tarea muestran "TRANSPORTE INTERNO" fijo. El servidor igual bloquea otro transportista.

## J. SCREENSHOTS RESPONSIVE
En `tests/e2e/out/responsive/` (incluidas en el bundle):
- 4 celulares × 5 pantallas;
- 4 escritorios × 3 zooms del constructor con el composer de ubicación.

## K. PARCHE GIT
`patches/*.patch` (`git format-patch 3346637..HEAD`). Aplicar con `git am patches/*.patch` sobre `3346637`.

## L. BUNDLE
`OK_DESPACHO_G2_REVISION.bundle` (`git bundle` de la rama). Uso: `git fetch OK_DESPACHO_G2_REVISION.bundle fix/revision-claude-g2-tareas:fix/revision-claude-g2-tareas`.

