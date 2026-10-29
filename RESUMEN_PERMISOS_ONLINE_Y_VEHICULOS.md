# Permisos online y vehículos (base: commit 870b22e, último de `main`)

## Causa
1. **`SupabaseApi.me()`** (`src/online/supabase-api.js`) cargaba el perfil y los transportistas, pero **no los permisos individuales**. `hasPerm()` los buscaba en `permission_overrides`, que el usuario online no trae. Por eso los permisos otorgados a una persona (vehículos, kilometraje, service, `routes.receive_internal`) **no llegaban a la pantalla**. La demo sí los traía, y por eso las pruebas simuladas pasaban.
2. **`openVehicles()`** (`src/online/rc4-ui.js`):
   - ocultaba los vehículos inactivos (`active !== false`);
   - no tenía alta;
   - convertía los errores de carga en listas vacías ("Sin vehículos", "Sin alertas").

## Cambios
- **Permisos efectivos del servidor:**
  - `me()` llama a `user_effective_permissions(p_user)`, el mecanismo existente que combina rol, permisos otorgados y revocados, y módulos restringidos, y los guarda en `effective_permissions`.
  - `hasPerm()` (`supabase/functions/_shared/rules.js`) usa **solo** esa lista cuando existe: nunca la amplía con los permisos por rol de la app.
  - Se aplica a menús, pantallas, botones y "Cambiar rol". La demo sigue con su mecanismo.
- **Si falla la consulta de permisos:** `me()` lanza `PERMISSIONS_UNAVAILABLE`. `main.js` muestra "No se pudieron cargar tus permisos" con **REINTENTAR** (misma sesión) y no abre ningún panel ni habilita acciones.
- **Permisos que cambian con la sesión abierta** (`role-view.js`, vigilante existente):
  - **Qué hace:** ahora detecta **cualquier** cambio de permisos efectivos, actualiza el usuario y vuelve a dibujar la pantalla del módulo, sin recargar (el borrador del constructor no se toca).
  - **Si la consulta falla:** se conserva lo ya confirmado y no se amplía nada.
  - **Revocación del permiso de asignación:** mantiene sus protecciones y la cola sin conexión.
- **Vehículos** (`openVehicles`):
  - **Filtro ACTIVOS (n) / INACTIVOS (m).** Sin activos se lee "No hay vehículos activos", indicando cuántos inactivos hay.
  - **Con `vehicles.manage`:** **+ NUEVO VEHÍCULO** y **EDITAR** con formulario en pantalla (`upsert_vehicle`, existente), más **ACTIVAR / DESACTIVAR** con confirmación. Editar no cambia el estado y **nada se activa solo**.
  - **Vehículo inactivo:** sin CARGAR KM, service ni corrección; la publicación ya ofrece solo vehículos activos (sin cambios).
  - **Permisos por acción:** kilometraje, reglas, alertas y service siguen con su propio permiso.
  - **Errores de carga:** de vehículos o alertas se muestran con **REINTENTAR**, distinguibles de una lista vacía.
- **Demo:**
  - el alta guarda marca, modelo, tipo y año, como el servidor;
  - gancho **solo de prueba** `okd_demo_fail_perms` para simular el fallo de permisos.
- **Sin cambios de servidor:** se reutilizaron `user_effective_permissions` y `upsert_vehicle`.

## Pruebas ejecutadas (datos ficticios)

| Prueba | Resultado | Exit |
|---|---|---|
| `tests/unit/online-permisos.test.js` (adaptador ONLINE con cliente Supabase **simulado**) | **6/6** | 0 |
| La misma prueba con el adaptador ORIGINAL (falla como esperado: reproduce el caso real) | 1/6 | 1 |
| `tests/e2e/run_vehiculos_permisos.py` (computadora y celular, controles reales) | **13/13** | 0 |
| `tests/unit/permiso-asignacion.test.js` | **7/7** | 0 |
| Regresión `run_cambiar_rol_revision.py` | **11/11** | 0 |
| Build de producción + guardián | OK | 0 |

- **`online-permisos`:**
  - Operario con permisos individuales: acciones habilitadas;
  - mismo rol sin ellos o revocados: restringidas, sin ampliar por rol;
  - fallo de la consulta, o respuesta inválida: error;
  - "Cambiar rol" con y sin `routes.receive_internal`;
  - usuario no activo;
  - cambio con la sesión abierta.
- **`vehiculos-permisos`:**
  - inactivo visible sin activarse solo;
  - alta, edición, reactivación y desactivación con el formulario y los botones;
  - error de carga con REINTENTAR y recuperación;
  - "No hay vehículos activos";
  - mismo rol sin permisos y con "cargar km" revocado;
  - permiso otorgado y revocado con la sesión abierta, sin recargar;
  - fallo de permisos al entrar y REINTENTAR;
  - "Cambiar rol" que desaparece al revocar;
  - celular: alta, filtro y sin desbordes.

## Corrección posterior (dos puntos)
1. **Cambio de permisos sin perder trabajo.**
   - **Antes:** el redibujo reconstruía la pantalla de vehículos y **borraba** el formulario abierto y lo escrito.
   - **Vehículos ahora:** antes de redibujar se capturan la pestaña, el formulario abierto y **todo lo escrito** (formulario, km de cada vehículo y resolución de cada alerta), y se restaura.
   - **Si la acción quedó revocada:** lo escrito se ve, el botón queda deshabilitado con un aviso y `GUARDAR` vuelve a verificar el permiso antes de enviar. **Nada se borra.**
   - **Otras pantallas:** ya no se reconstruyen solas. Aparece **"Tus permisos cambiaron… ACTUALIZAR PANTALLA"** y la persona decide cuándo. El servidor rechaza igual lo no autorizado.
   - Archivos: `src/online/rc4-ui.js` (`openVehicles`, `captureVehInputs`), `src/main.js` (`OKD_ON_PERMS_CHANGED`), `src/styles/online.css`.
2. **Edición compatible con el servidor.**
   - **El problema:** `upsert_vehicle` en producción **no** actualiza marca, modelo, tipo ni año en la edición.
   - **Al EDITAR:** esos campos se muestran de **solo lectura**, con una aclaración, y no se envían. El mensaje de éxito nombra solo lo que se guarda (nombre, patente, intervalo y observaciones).
   - **En el ALTA:** siguen disponibles.
   - **Demo** (`demo-admin.js` → `saveVehicle`): ignora esos campos en la edición, igual que producción.
   - Sin cambios de servidor.

| Prueba | Resultado | Exit |
|---|---|---|
| `tests/e2e/run_vehiculos_conservar.py` (datos escritos en NUEVO VEHÍCULO y EDITAR; computadora y celular) | **10/10** | 0 |
| La misma prueba con la versión ANTERIOR (falla como esperado: el formulario se pierde) | 0/2 + corte | 2 |
| Regresión `run_vehiculos_permisos.py` | **13/13** | 0 |
| Build de producción + guardián | OK | 0 |

`run_vehiculos_conservar` cubre:
- todos los campos de NUEVO VEHÍCULO conservados ante un cambio de permisos;
- administración revocada con el formulario abierto: lo escrito se ve y no se guarda, ni forzando el botón;
- al volver a otorgarlo, el mismo formulario se guarda;
- EDITAR conserva lo escrito, con marca, modelo, tipo y año de solo lectura;
- al cerrar y reabrir (y recargar) persiste lo guardado;
- la demo ignora marca y año en la edición;
- km y resolución de alerta escritos se conservan al revocar "cargar km";
- en otra pantalla aparece el aviso para actualizar sin reconstruirla;
- celular.

## Corrección posterior: se revoca TODO el acceso a Vehículos con un formulario abierto
- **Causa:** `OKD_ON_PERMS_CHANGED` llamaba a `openRoute()`. Sin acceso, `show403()` se ejecutaba **antes** de `openVehicles()`, así que `captureVehInputs()` nunca corría y el formulario se perdía.
- **Ahora** (`src/main.js`, `src/online/rc4-ui.js`):
  1. **Antes de evaluar la ruta,** `stashVehDraft(uid)` guarda lo escrito: formulario (alta o edición con el id del vehículo), km y resoluciones. Va en `sessionStorage` de esa pestaña, con **clave por usuario** (`okd_veh_draft:<id>`), y solo si hay algo escrito.
  2. **Sin acceso:** aviso "SE QUITÓ TU ACCESO A VEHÍCULOS", sin tabla, formulario ni datos de vehículos. Guardar es imposible (el formulario no existe y el servidor rechaza con FORBIDDEN).
  3. **Al restituir el acceso** (mismo vigilante o al volver a entrar a Vehículos), `openVehicles` recupera el formulario **intacto**. En EDITAR busca el mismo vehículo y mantiene marca, modelo, tipo y año de solo lectura. Después borra lo guardado.
  4. **Aislamiento:** `logout()` borra lo guardado. Además, cada usuario lee solo su propia clave, así que otro usuario de la misma computadora nunca lo ve.

| Prueba (controles reales) | Resultado | Exit |
|---|---|---|
| `tests/e2e/run_vehiculos_bloqueo.py` | **9/9** | 0 |
| La misma prueba con la versión ANTERIOR (falla como esperado: formulario vacío al restituir) | 1/4 + corte | 2 |
| Regresión `run_vehiculos_conservar.py` | **10/10** | 0 |
| Regresión `run_vehiculos_permisos.py` | **13/13** | 0 |
| Build de producción + guardián | OK | 0 |

`run_vehiculos_bloqueo` sigue estos pasos:
1. NUEVO VEHÍCULO con todos los campos escritos;
2. se revocan `vehicle_mileage.view`, `vehicles.view` y `vehicles.manage`: bloqueo sin datos;
3. guardar es imposible, ni forzando ni llamando directo;
4. al restituir, el formulario vuelve intacto y se guarda;
5. EDITAR, lo mismo;
6. cerrar sesión borra lo guardado;
7. otro usuario no ve nada, ni siquiera con un borrador del anterior en la pestaña;
8. el otro usuario conserva su acceso normal.

## Corrección posterior: restauración parcial (falla solo la consulta de alertas)
- **Causa:** al restaurar, `if (!vErr)` descartaba **todo** el respaldo apenas cargaban los vehículos. Una resolución de alerta que no llegó a mostrarse, porque falló esa consulta, se perdía al tocar REINTENTAR.
- **Dos defectos relacionados encontrados al probar:**
  - **Redibujos internos:** cualquier redibujo de la pantalla (abrir NUEVO VEHÍCULO, cambiar de pestaña, REINTENTAR, guardar otra cosa) **borraba** los km y las resoluciones escritas en otras filas.
  - **`stashVehDraft`:** pisaba el respaldo con lo visible, perdiendo lo pendiente.
- **Ahora** (`src/online/rc4-ui.js`):
  - **Respaldo por partes:** cada parte (formulario, km por vehículo, resolución por alerta) se descarta **solo si quedó a la vista con su valor**. Lo pendiente sigue en memoria y en el respaldo del usuario.
  - **Redibujos:** **todos** conservan lo escrito en pantalla, que tiene prioridad sobre el respaldo, así que REINTENTAR no sobrescribe lo que el usuario siguió escribiendo. Solo se descarta lo que una acción **acaba de guardar con éxito** (el km de ese vehículo, la resolución de esa alerta).
  - **`stashVehDraft`:** combina el respaldo existente con lo visible.
  - Se mantienen el aislamiento por usuario y la limpieza al cerrar sesión.

| Prueba | Resultado | Exit |
|---|---|---|
| `tests/e2e/run_vehiculos_alerta_parcial.py` (nueva) | **7/7** | 0 |
| La misma prueba con la versión ANTERIOR (falla como esperado: resolución perdida) | 1/6 | 1 |
| Regresiones `run_vehiculos_bloqueo.py` / `run_vehiculos_conservar.py` / `run_vehiculos_permisos.py` | **9/9** · **10/10** · **13/13** | 0 |
| Build de producción + guardián | OK | 0 |

`run_vehiculos_alerta_parcial`:
1. resolución escrita (y un formulario abierto);
2. se revoca todo el acceso;
3. se restituye con falla **solo** de alertas: la resolución sigue respaldada;
4. otro cambio de permisos no la pierde, y el usuario sigue escribiendo;
5. REINTENTAR: la resolución vuelve **intacta**, lo escrito después **no** se sobrescribe y recién ahí se limpia el respaldo;
6. la resolución se puede guardar;
7. CARGAR KM vacía solo ese campo y conserva el de otro vehículo.

## Corrección posterior: el formulario no se transfiere entre vehículos
- **Regresión:** el respaldo del formulario no tenía contexto. EDITAR A → escribir → EDITAR B → GUARDAR enviaba **id=B con los datos de A**, y el alta heredaba datos de una edición.
- **Ahora** (`src/online/rc4-ui.js`):
  - **Contexto:** cada formulario lleva su contexto (`new` o `edit:<id>`, en `data-ctx`). El respaldo lo guarda junto con lo escrito y solo lo aplica al **mismo** contexto, nunca a otro vehículo ni a un alta. Se mantiene por usuario.
  - **Refresco del mismo contexto** (cambio de permisos, REINTENTAR, recuperación tras bloqueo): sigue conservando lo escrito.
  - **Cambios pendientes:** cada campo recuerda su valor original (`data-orig`). Antes de pasar a otro vehículo, a NUEVO VEHÍCULO, a otra pestaña o de CANCELAR, se **avisa** y se puede cancelar. Aceptar descarta esos cambios de forma explícita, y nunca se transfieren. Sin cambios pendientes no hay aviso.
  - **Sin cambios:** km y resoluciones siguen separados por su identificador, y se mantienen la recuperación ante fallas parciales y la edición compatible con el servidor.

| Prueba | Resultado | Exit |
|---|---|---|
| `tests/e2e/run_vehiculos_contexto.py` (nueva; verifica el CONTENIDO enviado a `saveVehicle`) | **8/8** | 0 |
| La misma prueba con la versión ANTERIOR (reproduce la regresión: envía id=B con datos de A) | 1/8 | 1 |
| Regresiones de conservación: `run_vehiculos_conservar.py` / `run_vehiculos_bloqueo.py` / `run_vehiculos_alerta_parcial.py` | **10/10** · **9/9** · **7/7** | 0 |
| Build de producción + guardián | OK | 0 |

`run_vehiculos_contexto`:
1. EDITAR A con cambios → EDITAR B → aviso; CANCELAR conserva lo escrito en A;
2. al aceptar, B muestra sus datos y GUARDAR envía id=B con los datos de B (A sin cambios);
3. EDITAR con cambios → NUEVO VEHÍCULO → aviso; el alta abre vacía y envía solo sus datos, sin id;
4. un refresco del mismo vehículo conserva lo escrito y se envía con su id;
5. sin cambios no hay aviso;
6. km y resolución quedan en su fila.

## Pendientes
- **Producción:** verificar con la cuenta real de Guillermo Castillo **después de publicar** (no se tocaron usuarios, roles ni permisos reales, ni el vehículo inactivo). Debería ver "Administrás vehículos", + NUEVO VEHÍCULO y su vehículo en INACTIVOS, sin activarse.
- **Cada 30 s** el vigilante consulta los permisos (perfil + `user_effective_permissions`). Es una consulta liviana; si se prefiere, se puede espaciar.
- **Sin probar** contra Supabase real ni en un celular físico (el adaptador se probó con un cliente simulado).
