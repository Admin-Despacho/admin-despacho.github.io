# Comunicaciones internas · resumen

- **Base:** commit **`b15c06f`** (último de `main`, confirmado el 29/10/2026; incluye la corrección final de permisos y vehículos). Se integró por combinación de tres vías **sin conflictos**, y se conservan las correcciones publicadas de `tests/unit/invite-access.test.js` y `tests/unit/supabase-api.test.js`, idénticas a las publicadas y en verde.
- **Nada publicado:** no se ejecutó nada en producción, no se contrató ningún servicio y no se envió ninguna comunicación real.
- **Datos ficticios:** todos los datos de prueba lo son, y el proveedor de Gmail está **simulado** en las pruebas y en la demo.

## Qué incluye
- **Menú y permisos:**
  - **Menú:** "Comunicaciones" en el lateral y en el de celular, para quien tenga `comms.view`.
  - **Seis permisos propios:** `comms.view`, `comms.collaborators_manage`, `comms.compose` (redactar y compartir), `comms.schedule` (programar, pausar y cancelar), `comms.test_send` y `comms.gmail_manage`.
  - **Asignación:** el Admin los tiene por rol; a otros usuarios se otorgan o revocan individualmente.
  - **Validación:** la app usa los **permisos efectivos del servidor** y el servidor valida cada operación.
- **Colaboradores:** nombre, correo, celular, sucursal, sector y activo. No necesitan cuenta en Despacho.
- **Destinatarios:** individuales, por sucursal, por sector o todos los activos. Sin duplicados, los inactivos fuera con su motivo, y lista final visible antes de programar.
- **Comunicados:**
  - **Contenido:** nombre interno, asunto y texto con formato **sanitizado** (también en el servidor).
  - **Adjuntos (imágenes o PDF):** validados por su contenido real; límites visibles de 8 MB por archivo, 15 MB y 6 archivos por comunicado, y el tamaño final estimado frente a los 25 MB de Gmail.
  - **Herramientas:** borrador, duplicar, vista previa aislada y envío de prueba a una dirección elegida.
  - **Envío:** un correo **individual** por destinatario, sin CC ni CCO.
- **Ejecuciones:** cada una guarda una **copia** de destinatarios, contenido y adjuntos (con su huella), y los reintentos usan esa copia. Editar no cambia lo ya enviado. Un cambio en un comunicado programado muestra el impacto y pide confirmación.
- **Programación:**
  - **Tipos:** única, diaria, semanal con días, y mensual con regla explícita para fechas inexistentes ("último día del mes" u "omitir ese mes").
  - **Hora:** America/Argentina/Buenos_Aires, con las próximas ejecuciones visibles antes de confirmar.
  - **Pausa y reanudación:** reanudar no envía lo vencido.
  - **Ejecuciones perdidas:** quedan para revisión, sin envío masivo.
  - **Funcionamiento:** corre en el servidor con la app cerrada, con un **programador propio**, sin tocar ni activar los otros correos de Despacho.
- **Cola:**
  - **Reserva atómica:** `FOR UPDATE SKIP LOCKED`, con **clave única por ejecución y destinatario**.
  - **Antes de enviar:** se verifica la cancelación y la pausa **antes de procesar y justo antes de enviar**.
  - **Reintentos:** limitados (4), con espera creciente, y un tope diario de seguridad de 400.
  - **Resultado:** se guarda el **id que devuelve Gmail**.
  - **Respuesta perdida o trabajador caído:** queda **"Por verificar"**, sin reenvío automático. Solo se reintenta por decisión manual.
  - **Error de autorización:** muestra "hay que reconectar" y no se reintenta.
- **Gmail personal (@gmail.com):**
  - **Conexión:** OAuth oficial y Gmail API, con permisos mínimos `gmail.send` + `openid email`, sin pedir la contraseña.
  - **Token:** en **Vault** del servidor; nunca en el navegador, el repositorio, el ZIP ni los registros.
  - **Gestión:** conexión, estado, reconexión y desconexión (que revoca en Google), con acceso restringido.
  - **Requisito:** la app de OAuth debe quedar "En producción", porque en "Testing" el token vence a los 7 días. Ver `propuestas/comunicaciones/LIMITES_Y_COSTOS.md`.
- **WhatsApp (solo manual):**
  - **Compartir:** "Compartir por WhatsApp" usa la función nativa de compartir **según lo que el dispositivo realmente permite**: texto y adjuntos juntos, o por separado con su explicación. Siempre ofrece **copiar mensaje**, **descargar adjuntos**, abrir WhatsApp con el texto e instrucciones.
  - **Lo que Despacho no hace:** no crea grupos ni listas, no elige el grupo y no envía nada solo.
  - **Registro:** "Registrar como compartido por WhatsApp" es manual, con confirmación, usuario y fecha. No confirma recepción y queda separado de los correos.
- **Historial:**
  - **Envíos:** próximos envíos y resultados por destinatario (Pendiente, Procesando, Enviado — aceptado por Gmail, Error, Por verificar, Cancelado u Omitido con motivo), con intentos, errores comprensibles e id de Gmail.
  - **Registros:** auditoría (quién creó, modificó, programó, pausó o canceló) y registros de WhatsApp.
  - **Automatización:** estado de Gmail y de la automatización, sin presentarla como operativa si el programador no corrió.
- **Ejemplo:** "EJEMPLO · Normas de cobro (semanal)", los lunes a las 9:00, con una infografía **ficticia** y colaboradores **ficticios**. Queda **en borrador**.

## Archivos
- **Nuevos:**
  - `src/online/comms-ui.js`, `src/online/comms-api.js`;
  - `supabase/functions/_shared/comms-core.js`, `supabase/functions/_shared/comms-memory-store.js`;
  - `supabase/functions/comm-dispatcher/` (`handler.js`, `adapters.js`, `index.ts`) y `supabase/functions/comm-gmail-oauth/` (`handler.js`, `index.ts`);
  - las pruebas y `propuestas/comunicaciones/`.
- **Modificados (acotado):**
  - `src/main.js`: ruta `#/comunicaciones`;
  - `src/online/api.js`: extensión de adaptadores, que **nunca pisa** un método existente;
  - `src/online/rc4-ui.js`: menú y nombres de permisos;
  - `src/styles/online.css`;
  - `supabase/functions/_shared/rules.js`: los seis permisos;
  - `supabase/config.toml`: las dos funciones;
  - `supabase/functions/deno.lock`: lo actualizó Deno al resolver la dependencia de las funciones nuevas.
- **Servidor (separado, NO aplicado):** `propuestas/comunicaciones/` contiene la migración, el programador, las pruebas e `INSTRUCCIONES.md` con el orden de aplicación.

## Revisión de Codex (7 puntos): causa → corrección → prueba que lo reproduce
1. **Base publicada:**
   - **Causa:** el ZIP anterior traía versiones viejas de dos pruebas.
   - **Corrección:** se integró `b15c06f`; las dos pruebas son las publicadas.
   - **Prueba:** **18/18** (incluye las comprobaciones de `user_effective_permissions`).
2. **Duplicación después de que Gmail aceptó** (`comm-dispatcher/handler.js`):
   - **Causa:** el envío y el registro estaban en el mismo `try`.
   - **Corrección:**
     - el error del proveedor y el error al registrar van **separados**;
     - si Gmail aceptó, se reintenta **solo el registro**;
     - si no se logra, queda reservado → **"Por verificar"**, nunca se reenvía, y el id de Gmail queda en el resumen;
     - un registro tardío se acepta con su id (`stale_token`).
   - **Pruebas:** **D-16** (falla una vez), **D-17** (falla siempre) y **D-18** (el proceso se cae entre la aceptación y el registro), además de **CS-18** en SQL.
3. **Reanudación sin enviar vencidos:**
   - **Causa:** la ventana solo se aplicaba a ejecuciones nuevas.
   - **Corrección:** una **ventana de envío** (6 h) también para pendientes y reintentos ya encolados, dentro de la reserva. Lo vencido queda **VENCIDO**, visible en el historial con motivo, y solo se envía por decisión manual.
   - **Pruebas:** **D-19** (el caso del 2/11 reanudado el 17/11: **0 llamadas** a Gmail), **D-20**, **D-21**, **CS-17** y **CM-20**.
4. **Cupo con varios trabajadores:**
   - **Causa:** `sentLast24h` y `claim` eran dos pasos separados.
   - **Corrección:** el cupo se reserva **dentro de la reserva atómica**, con un candado transaccional que la serializa, contando enviados, en curso e inciertos, incluidas las pruebas.
   - **Pruebas:** **D-22** y **CS-14a/b** (**dos conexiones reales simultáneas**, cupo 1 → un solo envío, y la prueba bloqueada por el cupo).
   - **Velocidad:** en aquella entrega quedó una pausa fija por trabajador (600 ms), que **no** garantizaba el límite conjunto; se reemplazó por un limitador compartido (ver la revisión siguiente). Se aclaró que el tope **no cuenta** los correos enviados por fuera del módulo.
5. **Adjuntos validados por el servidor:**
   - **Causa:** el SQL confiaba en el tipo, el tamaño y el hash que mandaba el navegador.
   - **Corrección:**
     - **Función nueva `comm-attachments`:** descarga el archivo, mide el **tamaño real**, detecta el **formato por contenido** (la extensión debe coincidir) y calcula el hash.
     - **SQL de servidor:** valida bajo **bloqueo de fila** (cargas simultáneas no superan límites) y verifica el tamaño del almacenamiento.
     - **Despachador:** vuelve a verificar el contenido antes de enviar.
     - **Comunicado activo o pausado:** agregar o quitar un adjunto exige confirmación, sube la versión y queda auditado, con las copias históricas intactas.
   - **Pruebas:** **D-23** (MZ declarado PDF con hash coincidente: **0 llamadas** a Gmail), **AT-01 a AT-06**, **CS-12c-f**, **CS-15** (dos cargas simultáneas) y **CS-16**, además de **CM-19**.
6. **Privilegios de las tablas nuevas:**
   - **Causa:** solo se concedía SELECT, sin revocar lo heredado.
   - **Corrección:** se revoca **todo** sobre tablas, secuencias y funciones **nuevas**, y se concede lo mínimo. No se tocan privilegios globales ni de otros módulos.
   - **Pruebas:** **CS-13a-d**, con privilegios por defecto equivalentes a producción. Con la migración anterior quedaban INSERT, UPDATE, DELETE, **TRUNCATE**, REFERENCES y TRIGGER para `anon` y `authenticated`; con la nueva, ninguno (ver `RESULTADOS/privilegios_comparacion.txt`).
7. **Documentación:**
   - **Fuentes:** `LIMITES_Y_COSTOS.md` con fuentes oficiales (Google OAuth y verificación, Gmail, cuota de la API y pausa de Supabase).
   - **Verificación:** se aclara que **no** hay exención automática por conectar una sola cuenta y se detallan las condiciones de uso personal.
   - **Instrucciones:** `INSTRUCCIONES.md` actualizado.

**Pruebas que fallan con el código anterior:**
- **Despachador:** con el despachador y el almacenamiento anteriores fallan **9 de 23** (D-09 extendida y D-16 a D-23); con la corrección, 23/23.
- **Privilegios:** la comparación de privilegios reproduce el punto 6.

## Segunda revisión de Codex (3 puntos): causa → corrección → prueba que lo reproduce
1. **No borrar adjuntos ya registrados** (`comm-attachments/handler.js` y SQL):
   - **Causa:** cualquier error de registro, salvo la falta de confirmación, borraba el archivo, incluso cuando la ruta ya estaba registrada.
   - **Corrección:**
     - **Registro idempotente:** repetir una solicitud válida devuelve el adjunto existente, sin duplicar, sin cambiar la versión ni volver a auditar. Las solicitudes simultáneas se serializan por bloqueo.
     - **Resultado incierto** (error sin código, corte o respuesta perdida): se responde "reintentar" y el archivo se **conserva**. La app reintenta automáticamente.
     - **Error definitivo:** se informa sin borrar.
     - **Borrado inmediato:** solo un archivo de contenido inválido y **confirmado** como no registrado.
     - **Limpieza de huérfanos:** aparte, limitada a objetos de más de 24 h **sin ninguna referencia** (ni adjunto, ni quitado, ni copia, ni historial).
   - **Pruebas:**
     - **AT-07b** (el caso de Codex: la repetición choca con la restricción única), **AT-07** a **AT-10**;
     - **AT-11:** el archivo sigue descargándose y se **envía** después;
     - **CS-20a-c:** repetición, otro hash en la misma ruta y dos solicitudes **simultáneas**;
     - **CS-21:** solo huérfanos reales.
2. **Cupo tras confirmar manualmente un envío:**
   - **Causa:** confirmar dejaba la hora de envío vacía y el correo dejaba de contar en el cupo.
   - **Corrección:**
     - **Hora de envío:** al confirmar se conserva la **hora estimada** con el inicio del intento, rotulada "Envío estimado (inicio del intento)"; no se inventa la hora exacta de aceptación.
     - **Confirmación:** se registra **aparte** (quién y cuándo).
     - **Cupo:** el correo sigue contando en las 24 h. Servidor y demo hacen lo mismo.
   - **Pruebas:** **D-24** (el recorrido de Codex con cupo 1, también con dos trabajadores; el cupo se libera a las 24 h), **CS-19a-b** (con dos conexiones **simultáneas**) y **CM-21** (interfaz).
3. **Cuota y velocidad real:**
   - **Causa:** una pausa fija por trabajador, con la cuota anterior.
   - **Corrección:** limitador **compartido por cuenta en la base** (`comm_rate_acquire`) según la página oficial vigente.
     - **Ventanas:** 6.000 unidades en 60 s y 200 unidades en 1 s.
     - **Alcance:** antes de **cada** llamada real a `messages.send`, incluido el reintento interno tras un 401, para todos los trabajadores y las pruebas.
     - **Pausa fija:** eliminada.
     - **Documentación y comentarios:** actualizados.
   - **Pruebas:**
     - **D-25:** dos trabajadores y pruebas, con 79 envíos; ninguna ventana de 60 s supera 60 ni una de 1 s supera 2.
     - **GP-06:** el reintento tras un 401 también pide cupo.
     - **CS-22a-c:** dos conexiones **simultáneas**, con 60 por minuto, 2 por segundo y sin acceso para usuarios.

**Con el código anterior:** fallan 7 de las pruebas nuevas de unidad (D-24, D-25, GP-06 y AT-08 a AT-11), y AT-07b falla con la función de adjuntos anterior.

## Tercera revisión de Codex (2 puntos)
1. **Cancelación durante la espera por cupo:**
   - **Causa:** se verificaba antes de esperar el cupo y el token, y después no se volvía a verificar.
   - **Corrección:** el despachador orquesta **cada** llamada real a Gmail, incluido el segundo intento tras un 401, en este orden:
     1. **cupo de velocidad** (puede esperar);
     2. **token** (obtener o renovar; puede tardar);
     3. **verificación final** de cancelación, pausa, conexión y destinatario activo;
     4. **llamada**, sin esperas en el medio.
   - **Interrupción:** **no** es error de Gmail.
     - **Estado:** cancelado, pendiente sin gastar intento, u omitido con motivo.
     - **Cupo de velocidad:** lo reservado **se devuelve** (`comm_rate_refund`).
     - **Espera de cupo demasiado larga:** también vuelve a pendiente sin gastar intento.
   - **Pruebas:** `tests/unit/comms-dispatch-cancel.test.js`, con el **proveedor Gmail real** y `fetch` simulado, contando las solicitudes a `messages.send`.
     - **R-01:** el caso de Codex.
     - **R-02 a R-06:** pausa durante la espera, cancelación durante la renovación del token, pausa en el segundo intento tras un 401, destinatario desactivado y Gmail desconectado.
     - **R-07:** espera excedida.
     - **R-08:** orden token → verificación → envío.
     - **CS-23:** devolución exacta del cupo.
   - **Con el código anterior:** la reproducción equivalente falla (salieron 1, 1 y 2 envíos donde debía ser 0, 0 y 1). Ver `RESULTADOS/cancelacion_con_codigo_ANTERIOR.log`.
2. **Limpieza de adjuntos con registro simultáneo:**
   - **Decisión:** se **desactivó la limpieza automática**. El despachador y el adaptador ya no borran objetos. Los huérfanos se conservan y `comm_orphan_objects` queda solo para diagnóstico.
   - **Por qué:** coordinar listado y borrado con un registro simultáneo requiere un mecanismo adicional. Es preferible conservar archivos que arriesgar adjuntos válidos (ver `LIMITES_Y_COSTOS.md`).
   - **Prueba:** **CL-01**.

## Cuarta revisión de Codex: orden y vigencia del cupo de velocidad
- **Causa:** el cupo se reservaba **antes** de obtener o renovar el token. Si el token tardaba, la reserva envejecía y varios trabajadores llamaban a Gmail en el mismo segundo (3 envíos con límite 2).
- **Corrección** (`comm-dispatcher/handler.js`, proveedor en `adapters.js`): antes de **cada** llamada real, incluido el segundo intento tras un 401, el orden es:
  1. **token;**
  2. **cupo compartido;**
  3. si la espera dejó el token por vencer (`tokenFresh`): **se devuelve el cupo** y se repite el ciclo;
  4. **verificación final;**
  5. **llamada.**
- **Sin pausa por trabajador.** Se conservan las protecciones de cancelación, pausa, duplicados y adjuntos.
- **Pruebas** (`tests/unit/comms-rate-order.test.js`, reloj **virtual** compartido; se miden los **momentos de las solicitudes reales** a `messages.send`):
  - **Varios trabajadores con token demorado:** **T-01** (proveedores separados) y **T-01b** (el caso exacto de Codex, con caché de token compartida).
  - **Límites:** **T-02** (90 envíos: ≤ 2 por segundo y ≤ 60 por minuto).
  - **Vencimiento:** **T-03**, el token vence durante la espera y ningún envío usa un token sin margen.
  - **Cancelación y pausa:** **T-04** (cancelación durante la espera por cupo) y **T-05** (pausa durante la obtención del token).
  - **Segundo intento:** **T-06**, tras un 401 con renovación demorada.
  - **Repetidas:** las de cancelación y pausa en ambas esperas (R-01 a R-08).
- **Con el código anterior:** fallan **4 de 7** (T-01b, T-02, T-03 y T-06: 3 o 4 solicitudes en un mismo segundo). Ver `RESULTADOS/orden_cupo_con_codigo_ANTERIOR.log`.
- **SQL:** sin cambios en esta ronda (127/127 de la ronda anterior sigue vigente).

## Pruebas (resultados reales)

| Prueba | Resultado | Exit |
|---|---|---|
| Unitarias: módulo (núcleo, despachador, cancelación, **orden del cupo**, servidor, adaptador online, adjuntos) + permisos + **las 2 publicadas** | **108/108** | 0 |
| — orden del cupo con el código ANTERIOR (reproduce el problema) | 4 de 7 fallan | 1 |
| SQL en Postgres local (sin cambios en esta ronda; resultado vigente) | 127/127 | 0 |
| `deno check` de las 3 funciones | sin errores | 0 |
| `tests/e2e/run_comunicaciones.py` (computadora y **Android emulado**) | **21/21** | 0 |
| Build de producción + guardián; búsqueda de secretos | OK; 0 archivos | 0 |

**Regresiones de interfaz no repetidas** (`run_cambiar_rol.py` 16/16 y `run_vehiculos_permisos.py` 13/13 en la entrega anterior): en esta revisión no cambió ningún archivo compartido. `main.js`, `api.js`, `rc4-ui.js`, `rules.js` y los estilos son idénticos a la entrega anterior; solo cambiaron archivos del módulo y la base publicada (dos pruebas de unidad, que se corrieron).

Qué cubre cada una:
- **`comms-core`:** hora argentina y cambio de fecha; semanal, mensual (día 31 con último día u omitir), diaria con fin y única; destinatarios sin duplicados; XSS; MIME individual; tamaño final; tipo real de archivo; errores de Gmail.
- **`comms-dispatcher`:**
  - **Envíos:** lunes 9:00 con un correo por persona e id de Gmail, y la copia en los reintentos.
  - **Destinatarios:** un colaborador desactivado antes del envío queda omitido con motivo.
  - **Concurrencia:** dos trabajadores sin duplicar.
  - **Errores:** reintentos limitados, respuesta ambigua "Por verificar" y error de autorización.
  - **Cancelación y pausa:** cancelación durante la preparación con 0 llamadas a Gmail; pausa sin gastar intentos y reanudación sin enviar lo vencido.
  - **Interrupciones:** ejecución perdida y trabajador caído.
  - **Límites y seguridad:** tope diario, adjunto alterado y prueba.
  - **Lo enviado** no cambia al editar.
- **`comms-server`:** OAuth con permiso validado en el servidor, permisos mínimos y un estado de un solo uso. El token nunca aparece en respuestas, y si en Google se destilda el permiso de envío, no se conecta. Desconexión con revocación. Proveedor Gmail: renovación de token, un 401 reintentado una sola vez, corte de red después de enviar como ambiguo, 429 e `invalid_grant`.
- **`comms-online`:** adaptador **online** con cliente Supabase simulado: permisos efectivos y menú, rechazos del servidor, adjunto validado antes de subir, y OAuth por la función del servidor.
- **SQL:**
  - **Permisos:** rechazo de cada acción sin permiso; permisos individuales otorgados y revocados; funciones del servidor y Vault inaccesibles para usuarios.
  - **Gmail:** el token no se expone.
  - **Cola:** idempotencia y clave única; **dos conexiones simultáneas** con reservas disjuntas; verificación previa, reintentos, ambiguos, pausa, cancelación, autorización e interrumpidos.
  - **Edición y registros:** confirmación al editar un comunicado programado, con la copia intacta; WhatsApp separado.
  - **Adjuntos:** almacenamiento privado y límites.
- **E2E:**
  - **Contenido:** ejemplo en borrador; colaboradores; lista final; próximas ejecuciones; sanitización; adjuntos; vista previa.
  - **Envíos:** prueba sin y con Gmail (simulado); programar con lista final; envío de los lunes; historial; edición con impacto; pausa, reanudación y cancelación.
  - **WhatsApp:** en computadora (copiar y descargar, registro manual) y en Android (texto y archivos juntos, o por separado).
  - **Permisos:** sin permiso y con solo consulta.

## Probado localmente, simulado y pendiente en producción
- **Probado localmente:** la lógica, el despachador, la base de datos (Postgres local, con Vault **simulado**), las funciones del servidor (con Google y Supabase **simulados**), la interfaz en computadora y Android **emulado**, y el build.
- **Simulado:** Gmail (envíos e ids), la conexión OAuth en la demo, el programador (en la demo se ejecuta con un botón y en las pruebas se avanza un reloj de prueba) y las capacidades de compartir de Android.
- **Pendiente en producción (no ejecutado):**
  - **Google Cloud:** crear el proyecto y la app OAuth "En producción", con su ID y secreto.
  - **Supabase:** cargar los secretos, aplicar la migración y desplegar las funciones, el programador `pg_cron` y el Vault real.
  - **Conexión:** conectar la cuenta Gmail.
  - **Prueba real acotada:** `PRUEBA_REAL_ACOTADA.md`, con la app cerrada.
  - **WhatsApp:** probar el compartir en un Android y una computadora reales.
  - **Plan de Supabase:** confirmarlo por el riesgo de pausa por inactividad del plan gratuito.

**Todas las comunicaciones reales quedan en borrador** hasta aprobar contenido, destinatarios y horarios.
