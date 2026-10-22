# Revisión en celular (19/10/2026)

Recorrido emulado en Chromium a 390×844, en modo demo, de **todos los ítems del menú del Administrador** y de las pantallas de inicio de Transportista Interno y Externo. No es un celular físico.

## Corregido
1. **Menú del panel en celular** (`src/online/rc4-ui.js`, `src/main.js`, `src/styles/online.css`). Por debajo de 1000 px el menú completo quedaba arriba y había que bajar en cada ítem. Ahora es una **barra compacta con "MENÚ"**: se abre al tocarla y, al elegir un ítem, se cierra y el contenido queda arriba.
   - El panel es una capa fija con su propio scroll, así que lo que se vuelve arriba es esa capa, no solo la ventana.
   - Aplica al menú del panel y al del constructor. En escritorio no cambia nada.
2. **La barra no se estira** en pantallas con poco contenido (Borradores, Backup): filas de la grilla `auto 1fr`.
3. **Aviso "Entrá más rápido con huella o Face ID"** (Transportista): en celular el texto quedaba una palabra por renglón. Ahora se apila arriba del botón hasta 520 px.

## Pruebas (código de salida)
| Prueba | Resultado | Exit |
|---|---|---|
| **`tests/e2e/run_admin_mobile_menu.py` (nueva)** sobre el build demo nuevo | 17/17 | 0 |
| La misma prueba sobre la base original (sin botón MENÚ) | — | 2 |
| Build de producción | OK | 0 |
| Guardián del build | OK | 0 |
| `run_login_visual.py` | 21/21 | 0 |
| `checkpoint36-login.mjs` | 4/4 | 0 |
| `run_invite_access.py` | 8/8 | 0 |
| Unitarias relacionadas | 20/20 | 0 |
| Cola offline del chofer | 2/2 | 0 |

## Mejoras aprobadas (V4.3)
4. **Usuario y "Cerrar sesión" dentro del MENÚ** en celular. Arriba de cada pantalla queda solo el título (y "+ NUEVA HOJA" cuando corresponde). En escritorio no cambia.
5. **Filtros de Hojas publicadas** en grilla pareja de 2 columnas: textos a todo el ancho, Estado/Aprobación y fechas de a dos, BUSCAR a lo ancho, todos de 44 px. El estilo base fijaba `min-width: 260px`, y eso los sacaba de la pantalla.
6. **Casillas:** en pantallas táctiles toda la fila es tocable (44 px) y la casilla es de 22 px. Se corrige también que dos casillas de Configuración quedaban en un mismo renglón.
7. **Logo unificado:** el cuadrito blanco con el OK negro (el ícono nuevo) en los encabezados oscuros de Transportista, Informes, Aprobaciones, Usuarios y la pantalla sin acceso. Reemplaza al logo cian.

**Pruebas (código de salida):**
- `run_admin_mobile_menu.py`: **20/20**, exit 0. Suma usuario en el menú, filtros dentro de la pantalla y casillas de 44 px.
- `run_login_visual.py`: 21/21, exit 0.
- `checkpoint36-login.mjs`: 4/4, exit 0.
- `run_invite_access.py`: 8/8, exit 0.
- Unitarias relacionadas: 20/20, exit 0.
- Cola offline del chofer: 2/2, exit 0.
- Build de producción y guardián: exit 0.

## Pendiente
- Los usuarios de la demo usan el rol DESPACHO, eliminado en producción. Por eso las vistas de Superior Despacho y Operario Depósito no se pudieron recorrer en la demo.

## Sin revisar
- Celular físico.
- Vistas de Superior y Operario.
- Flujos internos completos de cada pantalla: formularios, modales, constructor paso a paso.

## V4.4: pruebas de G2 / TAREA / traslados / push sobre esta versión
**Corregido:**
- **Botones de resultado del chofer en 360 px** ("RECEPCIÓN PARCIAL", "REPROGRAMAR"): en una corrida empujaron 2 px fuera de la pantalla. Ahora las columnas pueden achicarse y el texto pasa a dos renglones (`src/styles/online.css`).
  - Al repetir la prueba sin la corrección no volvió a aparecer: es **intermitente**, probablemente por el momento en que carga la fuente. La corrección elimina la causa igual.
- **Salida estricta (0 / 1 / 2)** en `run_responsive_g2.py`, `run_e2e_g2.py` y `run_push_sw.py`: antes terminaban en 0 aunque hubiera FAIL.
  - Verificado en push con una falla controlada (exit 1, archivo restaurado).

| Prueba | Resultado | Exit |
|---|---|---|
| SQL `g2_revision_test` (base desde cero, todas las migraciones; incluye concurrencia de push y doble toque del chofer) | 64/64 | 0 |
| `run_e2e_g2.py` (informes sintéticos) | 23/23 | 0 |
| `run_responsive_g2.py` (4 celulares + 4 escritorios × 3 zooms) | 30/30 | 0 |
| `run_push_sw.py` | 3/3 | 0 (falla controlada → 1) |
| `test_driver_offline_queue.mjs` | 2/2 | 0 |
| Build de producción + guardián | OK | 0 |

## V4.5: QA del login en GitHub y menú móvil por rol
1. **`.github/workflows/checkpoint36-login-qa.yml`:** exigía `desktop_detail_92.webp` y `truck_detail_92.webp`, eliminados desde la V4. Ahora comprueba `login-notebook.webp` y `login-android.webp` con los mismos controles: archivo presente y no vacío, referenciado en `auth-ui.js`, cortes 800/799 px y cabecera WebP (`RIFF`).
   - Ejecutado localmente: el paso viejo da **exit 1** (como en GitHub) y el nuevo **exit 0**. Build `npm run build` exit 0; unitarias del workflow 6/6, exit 0.
2. **`tests/e2e/run_admin_mobile_menu.py`:** antes aprobaba con 5 resultados. Ahora exige la **lista exacta** de ítems de cada rol (texto, orden y destino) y **exactamente 50** comprobaciones; si se ejecutan más o menos, exit 2.
   - Detecta opciones faltantes: con un menú sin Transportistas/Vehículos/Emails/Backup, ADMIN-02 falla y las lista.
3. **Superior Despacho y Operario Depósito** con usuarios **sintéticos** (`@example.invalid`, creados solo en la demo, sin cambiar permisos). Por rol: barra compacta, abrir/cerrar menú, cada ítem va a su destino con el contenido arriba, acceso al constructor y "Cerrar sesión" desde el menú.
   - **Resultado:** 49 PASS / 1 FAIL de 50, **exit 1**. Admin y Superior completos.

**Defecto encontrado (preexistente, NO corregido, requiere decisión):** el Operario ve "Transportistas" en el menú (tiene `carriers.manage`) y al tocarlo recibe **403 · ACCESO NO AUTORIZADO**.
- `admin-ui.js` ya habilita la sección Transportistas con `carriers.manage`, pero la regla de rutas de `src/main.js` (`'#/configuracion'`) solo admite `settings.manage` o `vehicles.manage`.
- **Opciones:** (a) sumar `carriers.manage` a esa regla (una línea), o (b) quitar "Transportistas" del menú del Operario. No se aplicó porque cambia quién accede a una pantalla.
- Esa pantalla 403 conserva el logo cian anterior: se omitió al unificar encabezados en la V4.3. Tampoco se tocó.

**Cambios NO aprobados que se encontraron en la copia de trabajo y se REVIRTIERON a la V4.4:**
- La quita de los ítems repetidos del menú del Admin (pausada por pedido del usuario).
- Los 7 íconos de `public/icons/`, que quedaron otra vez idénticos al lock de marca.
- El cambio pausado se guarda aparte en `NO_APLICADO/` dentro del ZIP de entrega, sin aplicar.

## V4.6: Operario sin 403 en Transportistas
- **`src/main.js`:** la ruta `#/configuracion` admite `carriers.manage` **solo** para `sec=transportistas` (o sin sección). Cualquier otra sección por URL directa sigue en 403. No se agregaron permisos al rol.
- **`src/online/admin-ui.js`:** `openConfig(..., { only })`. Quien entra solo por `carriers.manage` ve únicamente la pestaña Transportistas. Sin esto le habría aparecido también Vehículos, por su permiso `vehicles.view`.
- **`show403()`:** usa el ícono aprobado (`/icons/icon-192.png`) en lugar del logo cian.
- **Prueba nueva `tests/e2e/run_config_access.py`** (12 casos, salida estricta):
  - Admin conserva todas las secciones.
  - Operario abre Transportistas y ve solo esa pestaña; Emails, Vehículos y Reglas financieras por URL → 403; Usuarios → 403.
  - La pantalla 403 muestra el ícono aprobado.
  - Superior (sin `carriers.manage`) → 403 en Configuración, Transportistas y Emails por URL directa.

| Prueba | Resultado | Exit |
|---|---|---|
| `run_config_access.py` | 12/12 | 0 |
| `run_admin_mobile_menu.py` | 50/50 | 0 |
| Build de producción + guardián | OK | 0 |

No se aplicó el parche del menú sin repetidos ni se cambiaron íconos (coinciden con el lock de marca).

## V4.7: menú aprobado (celular agrupado + Configuración agrupada)
- **Celular** (alternativa 1 aprobada): el botón MENÚ abre los grupos plegables **Inicio · Hojas de ruta · Solicitudes · Control · Administración** (Superior y Operario: **Operación**). Abre el grupo de la pantalla actual y al final van el usuario y "Cerrar sesión". Vale para el panel y para el constructor.
- **Computadora:** el menú lateral de siempre, **sin rediseño**. En el Admin, Transportistas, Vehículos / Service, Emails y Backup / Archivo pasan a ser **subopciones de Configuración**, como Despacho y Borradores dentro de Hojas de ruta. Así no se repiten sueltos y no se pierde el acceso. Resaltado (mismo criterio que "Hojas de ruta"): en Transportistas, Vehículos, Emails y Backup se marca **la subopción**, no el padre; en las secciones sin subopción propia (Plantillas, Reglas, etc.) se marca **"Configuración"**. *(Corregido en V4.8: el texto anterior decía que "Configuración" quedaba marcada en todas sus secciones, y no era exacto.)*
- Menús de Superior y Operario: mismas opciones que antes, solo agrupadas en el celular. **Permisos sin cambios.**
- Archivos: `src/online/rc4-ui.js` (`roleNav`, `mobileNav`, marcado de Configuración), `src/main.js` (menú agrupado también en el constructor), `src/styles/online.css`, `tests/e2e/run_admin_mobile_menu.py`.

| Prueba | Resultado | Exit |
|---|---|---|
| `run_admin_mobile_menu.py`: listas exactas de celular y computadora por rol, navegación, constructor, cerrar sesión | 52/52 | 0 |
| `run_config_access.py` | 12/12 | 0 |
| Build de producción + guardián | OK | 0 |

El parche anterior "menú sin repetidos" (que quitaba las opciones) queda reemplazado por esta agrupación aprobada; ya no se incluye.

## V4.8: prueba de escritorio real (sin cambios en la app)
`tests/e2e/run_admin_mobile_menu.py` agrega una ejecución **real a 1366×768**, porque la comprobación de "computadora" anterior leía `.nav` dentro del viewport de celular.
- **Admin:**
  - menú lateral visible con su lista exacta; menú del celular y botón MENÚ ocultos;
  - las 4 subopciones de Configuración navegan a su destino y marcan **la subopción**;
  - Plantillas marca **"Configuración"**;
  - el padre "Configuración" abre Configuración (con la primera sección, Transportistas, marcada);
  - **constructor:** menú lateral visible, menú del celular oculto, misma lista con Configuración agrupada, y desde ahí "Emails" navega a Configuración.
- **Superior y Operario:** menú lateral visible con su lista exacta y el menú del celular oculto.

| Prueba | Resultado | Exit |
|---|---|---|
| `run_admin_mobile_menu.py` (celular 390×844 + escritorio 1366×768) | 63/63 | 0 |

No se encontró ninguna falla en la app, así que no se modificó su código. Solo cambió la prueba, y este informe corrige la descripción del resaltado.

## V4.9: pedidos bloqueados "en otra hoja" y fecha automática (caso del Operario, 20/10)
**Causa (reproducida):** el constructor guarda las hojas locales en el navegador (IndexedDB) y las **comparte entre todos los usuarios de esa computadora**.
- Al entrar, el Operario quedaba trabajando en la hoja de otro usuario (la "Hoja 1").
- Una hoja **cerrada con la "×"** seguía bloqueando sus pedidos en silencio ("PEDIDO YA AGREGADO A OTRA HOJA (Hoja 1)").
- Se agregaba un **ERROR falso** ("el pedido tiene mercadería y no quedó en la hoja").
- Desde Admin funcionaba porque era su propia hoja.

**Corrección** (`public/legacy/despacho-v15.js`, sin cambiar diseño ni permisos):
1. **Hojas por usuario:** cada usuario ve y usa solo sus hojas en esa computadora. *(V4.10: las hojas viejas sin dueño ya NO se asignan al primero que entra.)*
2. **El bloqueo local cuenta solo hojas abiertas y propias** *(criterio de "propia" corregido en V4.10)*. La protección real sigue siendo la reserva del servidor, que avisa en qué borrador y de qué operador está el pedido, con "IR AL BORRADOR" y "ELIMINAR BORRADOR Y LIBERAR PEDIDOS".
3. **Sin ERROR falso:** los pedidos ya avisados (en esta hoja, en otra hoja abierta o reservados) no se repiten como ERROR. El ERROR sigue apareciendo si un pedido se pierde sin explicación.
4. **Fecha automática:** una hoja **no publicada** con fecha anterior a hoy pasa a **hoy** al abrir el constructor, al cambiar de hoja y si la app quedó abierta de un día para el otro. También se actualizan las fechas de sus pedidos y se recalcula la antigüedad de créditos, con un aviso. Una fecha **futura** puesta a propósito se respeta.

**Prueba nueva** `tests/e2e/run_builder_orders_date.py` (10 casos; Operario de prueba y informes sintéticos; misma computadora compartida):

| Prueba | Resultado | Exit |
|---|---|---|
| `run_builder_orders_date.py` | 10/10 | 0 |
| La misma prueba sobre la V4.8, sin corrección: reproduce los síntomas (hoja del Admin, bloqueo silencioso, ERROR falso) | — | 2 |
| `run_e2e_g2.py` (constructor + chofer) | 23/23 | 0 |
| Build de producción + guardián | OK | 0 |

**Nota sobre los archivos recibidos:** *(corregida en V4.10)* el diagnóstico de esta sección era incorrecto; ver V4.10.

**En la computadora del Operario:** la "Hoja 1" que bloqueaba sigue guardada en ese navegador. Con esta versión deja de bloquear y de verse para el Operario. Si los pedidos siguieran reservados en un borrador, el aviso nuevo muestra cuál y permite liberarlo.

## V4.10: diagnóstico corregido, transición de hojas sin dueño y fecha
### 1. Diagnóstico corregido
- **Error del informe V4.9:** decía que `informe_pedidos (1) (3).xlsx` no era un informe de pedidos. **Es incorrecto.** El archivo tiene dos pestañas y la primera, **"pedidos"** (7.296 líneas), contiene los cinco pedidos de la incidencia. El error vino de leer solo la pestaña activa ("resumen_productos").
- **Importación contrastada con los archivos reales** (cargados en una carpeta temporal, **fuera del proyecto**; ningún dato de esos archivos quedó en el repositorio): el constructor reconoce la pestaña "pedidos" (1.000 pedidos) y toma los otros dos archivos como saldo de comprobantes y saldo de cuenta corriente. Los cinco pedidos aparecen ("Facturado ZONA ESTE") y **en una hoja limpia entran los cinco sin errores**.

**Causas CONFIRMADAS** (reproducidas con la V4.8 y corregidas):
- Las hojas locales del constructor eran compartidas entre los usuarios de una misma computadora.
- Una hoja cerrada con la "×" seguía bloqueando sus pedidos con "PEDIDO YA AGREGADO A OTRA HOJA (Hoja N)".
- La protección agregaba el "ERROR … no quedó en la hoja" para pedidos que ya tenían su aviso.
- Los mismos archivos importan bien: el bloqueo no vino de la importación.

**HIPÓTESIS (no verificable desde acá):**
- Quién creó la "Hoja 1" que estaba en el navegador del Operario el 20/10 (otro usuario de esa computadora o una hoja propia vieja) y por qué tenía esos pedidos. Haría falta el almacenamiento de ese navegador.
- Que el Admin haya podido porque la hoja era suya o porque trabajó en otro navegador. Es compatible con lo reproducido, pero no se puede confirmar.

### 2. Transición de hojas creadas antes de V4.9 (sin dueño)
- **Ya no se asignan automáticamente** al usuario que entra: se eliminó la asignación en `touch()` y "propia" ahora exige un dueño igual al usuario actual.
- **Dueño recuperado desde el servidor** (`list_drafts`) cuando el usuario puede ver ese borrador.
- **Borrador de otro usuario no visible** para el usuario actual (`draft_content` → `FORBIDDEN_DRAFT`): no se le asigna ni se le ofrece; queda para su dueño, que la recupera al entrar.
- **Dueño indeterminable** (sin borrador en el servidor): la hoja queda **guardada y separada**, sin cambios. No se ve como pestaña ni bloquea, y el usuario trabaja en una hoja **nueva propia**. Se puede **recuperar a mano** desde "Reabrir borrador… → Hojas anteriores sin dueño", con confirmación.
- Se agregó `drafts.list` al puente del constructor (`src/main.js`), usando la API existente `listDrafts`. **Permisos sin cambios.**

### 3. Fecha automática (verificada)
- Hoja **publicada:** no se modifica.
- **Al abrir el constructor:** se actualiza.
- **Al cambiar de pestaña:** se actualiza.
- **Al pasar la medianoche con la app abierta:** se actualiza.
- Fecha **futura:** se respeta.

### Pruebas (código de salida)
| Prueba | Resultado | Exit |
|---|---|---|
| `run_builder_legacy_owner.py` (almacenamiento real generado por **V4.8** → Operario en V4.10, mismo navegador) | 8/8 | 0 |
| `run_builder_orders_date.py` (bloqueos + fecha: publicada, pestaña, medianoche simulada, futura) | 13/13 | 0 |
| `run_e2e_g2.py` (constructor + chofer) | 23/23 | 0 |
| Build de producción + guardián | OK | 0 |

`run_builder_legacy_owner.py` necesita el build demo de la versión anterior en `OKD_PREV_DIST`.

## V4.11: importe manual = saldo revisado, panel REVISAR, NOC automática y bultos opcionales
**Caso reproducido** con los Excel recibidos (cargados en una carpeta temporal, fuera del proyecto): los pedidos están en la pestaña "pedidos" del informe, pero sus comprobantes no figuran en el detalle de cuenta corriente, porque se exportó antes de facturarlos.
- Uno quedaba en "SALDO NO ENCONTRADO".
- El otro en "SIN COMPROBANTE EN INFORME", más dos motivos independientes del saldo: "ENVÍO NO ENCONTRADO" y "Forma de pago a revisar". Por eso el bloqueo continuaba después de cargar el importe.

**Cambios** (`public/legacy/despacho-v15.js`, `src/styles/online.css`):
1. **Importe manual válido** (escrito por el operador, número ≥ 0) → la revisión de saldo queda hecha automáticamente.
   - Desaparecen **solo** los avisos que nacen del saldo ausente (`SALDO NO ENCONTRADO`, `SALDO NO INFORMADO — REVISAR`, `SIN COMPROBANTE EN INFORME / NO ENCONTRADO / NO FACTURADO`), y también en el estado que usa la publicación (`problems()`).
   - Envíos, forma de pago, financiación, NOC y comprobante distinto **siguen** detectándose.
   - Un campo vacío o inválido **no** queda aprobado.
   - Se conserva al recalcular, cambiar de hoja, guardar, reabrir y recargar (`saldoRevisado` en la fila).
2. **Panel REVISAR:** al tocar el recuadro REVISAR del modal de publicación aparecen los pedidos pendientes con su motivo.
   - Permite cargar el importe (marca solo la revisión de saldo), completar la forma de pago y tildar "Revisado" en cada aviso independiente.
   - "Revisado" queda guardado por aviso y texto: si el aviso cambia, vuelve a pedirse.
   - Lo que se resuelve en la tabla trae un botón "VER EN LA TABLA".
   - Al resolver se actualizan el contador y los avisos y se habilita continuar.
3. **Bultos opcionales:**
   - Se quitó el aviso "entregas con 0 bultos".
   - La validación final acepta casillas vacías (antes exigía un número y **bloqueaba**).
   - La casilla arranca vacía, no se completa un 0 ficticio, el PDF/Excel deja la celda vacía y una cantidad informada se conserva.
4. **Notas de crédito automáticas**, con la regla existente: "los créditos vigentes ya están reflejados en la cuenta corriente".
   - Si el tope de cuenta corriente ya redujo el pedido en al menos la NOC: **"YA CONTEMPLADA EN EL SALDO"**, no se aplica de nuevo.
   - Si no lo redujo: **se aplica sola**, por el mismo camino del servidor que "APLICAR AL PEDIDO ACTUAL" (idempotente por hoja y comprobante).
   - Casos ambiguos (reducción parcial, varias entregas del cliente, financiación propia, importe manual): quedan para revisión con los botones de siempre.
   - El importe manual no borra ni duplica una NOC ya aplicada.

**Pruebas** (datos **sintéticos**: `tests/e2e/generate_synthetic_saldo_noc.py`, misma forma que el caso real, sin datos reales):

| Prueba | Resultado | Exit |
|---|---|---|
| `run_saldo_revisar_noc.py` (nueva) | 14/14 | 0 |
| `run_builder_orders_date.py` | 13/13 | 0 |
| `run_builder_legacy_owner.py` | 8/8 | 0 |
| `run_e2e_g2.py` | 23/23 | 0 |
| Build de producción + guardián | OK | 0 |

`run_saldo_revisar_noc.py` cubre:
- saldo ausente → importe manual → revisado;
- conservación al reabrir;
- vacío o inválido no aprobado;
- otros errores siguen;
- PUBLICAR → REVISAR → resolver → continuar;
- decisiones guardadas;
- NOC automática una vez (1000 − 300 = 700) y la ya contemplada no;
- publicación con bultos vacíos y uno informado conservado.

**Pendiente / no verificado:**
- Con datos reales en Supabase: la aplicación automática de NOC usa la misma RPC `apply_credit_note`; se probó en modo demo, que replica su idempotencia.
- En la computadora del operador.

No se tocaron Supabase, permisos ni migraciones, y no se publicó.

## V4.12: NOC automática con importe exacto, espera antes de publicar y reintento
Cambios solo en `public/legacy/despacho-v15.js`:
1. **Importe exacto.**
   - **Antes:** el campo de la NOC mostraba el número en formato JavaScript ("300.5") y el botón le quitaba los puntos, así que $300,50 se enviaba como **3005**. Pasaba en la aplicación automática y también en la manual.
   - **Ahora:** el campo se muestra en formato argentino ("300,50", "1.234,56") y se lee con el mismo lector de importes de la app (`parseMoney`). En la aplicación automática se envía el número exacto mientras el operador no cambie el campo.
2. **Espera y reintento.**
   - Cada NOC automática tiene estado: aplicándose, aplicada o con error. **PUBLICAR queda bloqueado** mientras alguna esté aplicándose o con error, con un aviso.
   - Un intento de publicar en ese momento **espera** el resultado y no publica si queda algo sin resolver.
   - Si falla (por ejemplo, un error de red), la fila queda **PENDIENTE** con **REINTENTAR**, y "APLICAR AL PEDIDO ACTUAL" y "NO APLICAR" siguen disponibles. Ya no se deshabilitan todos los controles sin importar el resultado.
   - El reintento usa el mismo identificador de operación, así que el servidor no la aplica dos veces.
3. **Textos:** el recuadro dice "se aplican automáticamente cuando no hay duda" (antes: "solo si las aceptás").

**Pruebas** (sintéticas; `generate_synthetic_saldo_noc.py --decimales`):

| Prueba | Resultado | Exit |
|---|---|---|
| `run_noc_decimales.py` (nueva) | 8/8 | 0 |
| La misma prueba sobre la V4.11 (sin corrección): PUBLICAR habilitado con la NOC fallida, campo "300.5", sin reintento | detecta | 2 |
| `run_saldo_revisar_noc.py` (importe manual, REVISAR, NOC, bultos) | 14/14 | 0 |
| Build de producción + guardián | OK | 0 |

`run_noc_decimales.py` cubre:
- NOC de $300,50 y $1.234,56 con el importe enviado exacto;
- error de red → pendiente y reintento;
- respuesta demorada con intento de publicar, sin publicar hasta resolver;
- importe escrito a mano "1.234,56" → 1234.56;
- reapertura sin doble descuento (una aplicación por NOC);
- hoja publicada con 699,50 y 765,44.

Sin cambios en Supabase, permisos ni migraciones; no se publicó. Se conservan el importe manual revisado, el panel REVISAR y los bultos opcionales.

## V4.13: NOC automática, solicitudes en curso y rechazos definitivos
Cambios solo en `bindNoc` (`public/legacy/despacho-v15.js`):
1. **Solicitudes en curso.**
   - Cada llamada al servidor (automática, reintento, manual y a financiación) se registra (`m._nocInflight`).
   - Mientras está en curso, la fila **bloquea todas sus acciones**: NO APLICAR, APLICAR, financiación, plan, importe y REINTENTAR. Además, NO APLICAR ignora la llamada aunque se fuerce.
   - **PUBLICAR** queda bloqueado y el intento de publicar **espera todas** las solicitudes, reintentos incluidos, antes de decidir.
   - El bloqueo depende del registro real y no del estado visual.
2. **Errores diferenciados.**
   - **Rechazo definitivo:** `ok: false` (`NOC_CONSUMED`, `NOC_RESERVED_ELSEWHERE`, `NOC_BLOCKED`, `NOC_UNDER_REVIEW`, `NOC_DESTINATION_LOCKED`) o errores con código `NOC_*`. Se muestra **"NO SE APLICA EN ESTA HOJA · causa"**, sin REINTENTAR y sin borrar el importe (queda deshabilitado), y **no bloquea** la publicación.
   - **Error recuperable** (red, tiempo de espera, servidor): la fila queda **PENDIENTE**, con el importe conservado, REINTENTAR y NO APLICAR.

**Pruebas** (sintéticas, `--decimales`):

| Prueba | Resultado | Exit |
|---|---|---|
| `run_noc_robustez.py` (nueva) | 8/8 | 0 |
| La misma prueba sobre la V4.12: NO APLICAR habilitado durante la solicitud; ok:false con reintento imposible y publicación bloqueada | detecta | 2 |
| `run_noc_decimales.py` (V4.12) | 8/8 | 0 |
| Build de producción + guardián | OK | 0 |

`run_noc_robustez.py` cubre:
- error transitorio → pendiente con el importe conservado;
- reintento demorado con intento de NO APLICAR, cambio del estado visual e intento de publicar: nada tiene efecto y no se publica;
- reintento exitoso con $300,50 exactos;
- rechazo ok:false con la causa, sin reintento y sin bloquear;
- reapertura sin doble aplicación;
- publicación con 699,50 y 2.000;
- importes enviados siempre exactos.

Se conservan los cambios anteriores. Sin cambios en Supabase ni permisos; no se publicó.

## V4.14: "saldo no encontrado" del caso real (Hoja 21)
**Causa encontrada** (reproducida con un borrador hecho con el constructor anterior y reabierto con V4.13, también con los Excel reales en una carpeta temporal):
1. **Borradores anteriores a V4.11:** el importe manual quedaba guardado (`montoManual`) pero **sin la marca `saldoRevisado`**, que recién existe desde V4.11.
   - Al reabrir con V4.13 el pedido seguía en "saldo no encontrado" o "sin comprobante", aunque el importe se viera en el campo.
   - Entrar al campo y salir sin tipear no lo guardaba de nuevo.
2. **Ventana de publicación:** aunque el saldo quedara resuelto, el operador no podía terminar ahí.
   - El panel REVISAR arrancaba **plegado**.
   - El resumen mostraba el mensaje **genérico** ("montos/documentos, financiación o NOC").
   - Al guardar, la ventana se **cerraba y volvía a abrir**.
   - Además, el pedido tenía **otros motivos independientes** (envío no encontrado y forma de pago) que no se veían.

No era caché ni falta de publicación: ocurre con V4.13 publicada.

**Corrección** (`public/legacy/despacho-v15.js`):
- **Borradores anteriores:** al cargar cualquier borrador (inicio, cambio de pestaña, ABRIR BORRADOR o reapertura), un importe manual **explícito y válido** sin la marca se reconoce como saldo revisado. Queda con su origen y en el historial. Vacío o inválido: no se aprueba.
- **Panel REVISAR desplegado** al intentar publicar, con el campo del importe actual y GUARDAR IMPORTE en "saldo no encontrado".
- **Actualización en el lugar** (sin cerrar la ventana) del resumen, los motivos, el contador, el mensaje de bloqueo y PUBLICAR.
- **Motivos concretos** por pedido ("saldo no encontrado: cargá el importe", "envío no encontrado: revisalo y marcá Revisado", "forma de pago a completar") en lugar del mensaje genérico.
- **Tabla y panel** usan la misma función (`setManualAmount`): mismo resultado.

**Pruebas** (sintéticas, solo clics y campos reales; sin asignar `saldoRevisado`):

| Prueba | Resultado | Exit |
|---|---|---|
| `run_saldo_borrador_antiguo.py` (nueva) | 11/11 | 0 |
| La misma prueba sobre V4.13: importe antiguo no reconocido, panel plegado, mensaje genérico | detecta | 2 |
| `run_saldo_revisar_noc.py` (REV-01 actualizado: el panel ahora arranca desplegado) | 14/14 | 0 |
| `run_noc_decimales.py` | 8/8 | 0 |
| `run_noc_robustez.py` | 8/8 | 0 |
| Build de producción + guardián | OK | 0 |

`run_saldo_borrador_antiguo.py` cubre:
- borrador antiguo → PUBLICAR → saldo no encontrado → GUARDAR IMPORTE en REVISAR (el inválido se rechaza) → motivo y contador quitados en la misma ventana → resolver lo independiente → PUBLICAR;
- edición desde la tabla con el mismo resultado (vacío no se aprueba);
- persistencia al reabrir.

Se requiere `OKD_PREV_DIST` (build demo anterior a V4.11). Bultos opcionales y correcciones de NOC sin cambios. Sin cambios en Supabase, permisos ni migraciones; no se publicó.
