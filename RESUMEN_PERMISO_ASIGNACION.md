# "Permitir asignación de hojas de ruta" + "⇄ Cambiar rol" (base: commit 992abd0)

## Qué hace
- **Permiso por persona:** se habilita a cualquier usuario existente (Admin, Superior, Operario Depósito o Solo Lectura) con el editor de permisos actual. **Ningún rol lo trae por defecto**: el Admin no lo recibe implícito. Cada usuario conserva su rol y sus permisos. No se crean usuarios, transportistas ni numeración.
- **Con el permiso:** aparece como chofer disponible del **Transporte Interno** y realiza **solo sus** hojas con el recorrido vigente del Transportista Interno: llegada, entregas comerciales, sucursales con nombre y firma, TAREA y segunda visita, sin cobranza.
- **⇄ Cambiar rol:**
  - **Dónde:** "ESTÁS COMO: …" siempre visible. En computadora, en el **menú lateral** debajo del nombre; en celular, **debajo del nombre** en el encabezado. Solo para usuarios habilitados.
  - **Opciones:** el perfil habitual (con su nombre real de rol) o **Transportista** ("Mis rutas", solo sus hojas). Misma cuenta, sin cerrar sesión.
  - **Alcance:** solo cambia la **vista**, no el rol ni los permisos; todo lo valida el servidor, también entrando por URL directa.
  - **Sin perder trabajo:** antes de cambiar se guarda el borrador con el mecanismo existente (`RouteStore.flush`). Si hay una ventana con trabajo abierto, se **advierte**. Nunca se publica nada.
- **Al quitar el permiso** (incluso con la app abierta):
  - el servidor rechaza nuevas asignaciones y cualquier acción como chofer;
  - la app vuelve al perfil habitual con un aviso;
  - entregas, firmas e historial se conservan;
  - el administrador ve sus **hojas pendientes** en el editor de permisos para reasignarlas con el flujo existente (no se reasignan solas).

## Archivos
- **App:**
  - `supabase/functions/_shared/rules.js`: permiso, elegibilidad, regla de hoja propia, Admin sin el permiso implícito;
  - `src/online/role-view.js` (nuevo): selector y guardado previo;
  - `src/main.js`: arranque por vista, `#/mis-rutas`;
  - `src/online/rc4-ui.js`, `admin-ui.js`, `driver-ui.js`: selector debajo del nombre, título "MIS RUTAS", vuelta al perfil si el servidor rechaza, y corrección de "Agregar parada";
  - `src/online/users-ui.js`, `supabase-admin.js`, `demo-admin.js`: hojas pendientes al quitar el permiso;
  - `src/online/demo-api.js`, `demo-rc4.js`: demo igual que el servidor;
  - `src/styles/online.css`.
- **Servidor (separado, NO aplicado):** `propuestas/permiso_asignacion_hojas/` (migración, prueba SQL, script e `INSTRUCCIONES.md`).

## Pruebas ejecutadas (datos y usuarios ficticios)

| Prueba | Resultado | Exit |
|---|---|---|
| Servidor: `run_permiso_tests.sh` (Postgres local, orden real + migración) | **91/91** | 0 |
| `tests/e2e/run_cambiar_rol.py` (computadora 1366 y celular 390) | **16/16** | 0 |
| `tests/unit/permiso-asignacion.test.js` | **6/6** | 0 |
| Regresión `run_driver_perfiles.py` (chofer actual) | **16/16** | 0 |
| `tests/e2e/run_agregar_parada_refresco.py` (nueva) | **4/4** | 0 |
| Regresión `run_e2e_g2.py` (constructor y chofer), código final | **23/23** ×2 | 0 |
| Build de producción + guardián | OK | 0 |

- **Servidor:**
  - sin permiso no es candidato ni recibe hojas; con el permiso habilitado sí, y realiza su hoja;
  - el Admin no queda habilitado por su rol;
  - no opera ni ve hojas ajenas por el permiso;
  - conserva sus permisos (Operario, Admin y Solo Lectura);
  - no aplica a transportistas externos;
  - al quitarlo: rechazo inmediato (también al Admin), registros conservados y nueva asignación rechazada;
  - el Transportista Interno actual, sin cambios.
- **E2E:**
  - habilitar con el editor real;
  - cambio de vista ida y vuelta en **ambos tamaños** (Operario), Admin en computadora y Solo Lectura en celular;
  - solo sus rutas, que realiza; las ajenas se rechazan;
  - el trabajo **sin guardar** se conserva al volver;
  - URL directa sin permiso → acceso no autorizado;
  - revocación con la app abierta;
  - aviso de hojas pendientes al administrador;
  - Gabriel sin selector y sin cambios;
  - sin duplicados.

## Falla intermitente de "Agregar parada" (investigada y corregida)
- **Causa (preexistente, también en el commit publicado 992abd0):** la pantalla del chofer se redibuja sola con cada aviso automático (Supabase en tiempo real; en la demo, cada 5 s) y al terminar la carga inicial.
  - La protección existente ("no redibujar si el chofer está escribiendo") **no contemplaba el formulario "+ AGREGAR PARADA"** y no se aplicaba al fin de la carga inicial.
  - Si el aviso llegaba con ese formulario abierto, **se cerraba y se borraba lo escrito**. El chofer podía perder datos, y G2 fallaba cuando el aviso caía entre abrir y guardar.
- **Reproducción determinista:** abrir el formulario, escribir y esperar más de 5 s → cerrado y vacío, **en esta versión y en el commit original**.
- **Corrección** (`src/online/driver-ui.js`, `load()`): la protección también contempla `#drvAdd` y la carga inicial. Los datos se actualizan igual; solo se posterga el redibujo hasta guardar o cerrar el formulario.
- **Prueba nueva** `tests/e2e/run_agregar_parada_refresco.py`: **4/4**. Con el código original **falla** con el mismo síntoma del corte de G2.
  - "Agregar parada" y el formulario de resultado se mantienen con lo escrito durante dos actualizaciones automáticas;
  - al guardar, la parada aparece;
  - sin formulario abierto, una hoja nueva aparece sola.
- **G2 sobre el código final:** 23/23 en **dos corridas seguidas**. Historial completo en `RESULTADOS/regresion_g2.txt`.

## Decisión de ubicación (confirmada)
- "⇄ Cambiar rol" queda en el **encabezado de "Mis rutas"** en computadora y en el **menú lateral del panel habitual**.
- No se agrega un menú lateral nuevo.
- Siempre muestra el perfil activo y permite volver sin cerrar sesión ni perder trabajo.

## Revisión posterior (tres casos)
1. **Cambiar de vista sin perder trabajo** (`role-view.js`, `driverPending`): antes de cambiar se revisa la pantalla del chofer. Si hay pendientes, se **advierte** y se puede **cancelar**:
   - "+ AGREGAR PARADA" con datos o con una ubicación elegida;
   - una entrega con datos, **firma** o **foto del DNI** (cargada o procesándose);
   - kilometraje escrito.

   Las operaciones guardadas sin conexión no se tocan.
2. **Solo Lectura y las ubicaciones internas** (`driver_internal_locations`, propuesta y demo): con el permiso, y **solo mientras tenga una hoja propia del Transporte Interno pendiente o en curso**, consulta las ubicaciones activas (nombre, dirección y radio) para agregar una visita. No recibe permisos de administración. Agregar la parada sigue validando la hoja propia.
3. **Permiso quitado con la sesión abierta:** el vigilante `watchRevocation` revisa cada 30 s, al volver a la app, al recuperar el foco y al recuperar la conexión.
   - **En "Mis rutas":** vuelve al perfil.
   - **En el panel:** quita el selector sin recargar.
   - **Sincronización sin conexión:** un rechazo **conserva** la operación en la cola (no se borra ni se marca enviada) y avisa cuántas quedan.
   - **Servidor:** sigue rechazando.
   - **Demo:** `me()` ahora relee el estado, igual que el servidor.

| Prueba | Resultado | Exit |
|---|---|---|
| `tests/e2e/run_cambiar_rol_revision.py` (Operario, Admin y Solo Lectura; computadora y celular) | **11/11** | 0 |
| Servidor (con ubicaciones para Solo Lectura) | **96/96** | 0 |
| Regresiones: `run_cambiar_rol.py` / `run_agregar_parada_refresco.py` / `run_driver_perfiles.py` | **16/16** · **4/4** · **16/16** | 0 |

## Corrección posterior (revisión de Codex): revocación del Admin
- **Antes:** `canOperateAssigned` (app y demo) aceptaba una hoja **interna** propia con `routes.view_assigned`, que el Admin tiene por su rol, aunque le hubieran quitado el permiso. El servidor (`_my_route`) la rechazaba.
- **Ahora**, igual que el servidor:
  - **Transporte Interno:** solo un Transportista Interno o alguien con el permiso habilitado;
  - **transportistas externos:** sin cambios.
  - El Admin conserva todos sus permisos administrativos.

| Prueba | Resultado | Exit |
|---|---|---|
| `tests/e2e/run_revocacion_admin.py` (demo, operación real tras revocar) | **4/4** | 0 |
| Misma prueba con el build ANTERIOR (falla como esperado: entrega aceptada tras revocar) | 2/4 | 1 |
| Servidor: PERM-24 (registrar entrega) + **PERM-31** nuevo (iniciar otra hoja) tras revocar al Admin | **97/97** | 0 |
| `tests/unit/permiso-asignacion.test.js` (PA-07 nuevo) | **7/7** | 0 |
| Regresiones `run_cambiar_rol.py` / `run_cambiar_rol_revision.py` | **16/16** · **11/11** | 0 |

## Pendientes
- **Aplicación:** migración + publicación según `INSTRUCCIONES.md`. **No publicar todavía.**
- **Usuario solicitado:** **Guillermo Castillo**. **No habilitar todavía el permiso a ninguna cuenta real.**
- **Diferencia previa, no tocada:** el Operario Depósito, en el servidor, ve todas las hojas por su rol, mientras que la lista de permisos del rol en la app difiere.
- **Sin probar** en producción ni en un celular físico.
