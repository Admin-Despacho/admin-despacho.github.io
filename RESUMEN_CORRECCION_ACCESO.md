# Corrección sobre CHECKPOINT 36 (`ac2cd73`): pantalla de acceso, acceso del usuario invitado y bloqueo de publicación

**Restricciones respetadas:**
- Supabase sin modificar: sin migraciones ni despliegue de funciones.
- Sin push ni deploy.
- Sin credenciales reales, sin envío de correos ni cambios de contraseñas.
- Las capturas privadas, la evidencia del incidente y los correos de usuarios reales **no** están en el proyecto. El documento de traspaso, que tenía el correo, se dejó fuera.

## 1. Archivos modificados y nuevos (respecto de `ac2cd73`)
| Archivo | Cambio |
|---|---|
| `src/styles/login-brand.css` | Escritorio (800 px o más): la tarjeta deja siempre 12 px a cada lado. |
| `src/online/supabase-api.js` | `setPassword`: `same_password` = contraseña ya guardada → continúa con la activación. Cualquier otro error se informa. `completePasswordReset`: intenta activar la invitación pendiente y **devuelve el estado real** (`pendingInvite`, `activated`, `activationError`). `signIn`: distingue email sin confirmar y exceso de intentos; credenciales inválidas siguen con el mensaje genérico. |
| `src/main.js` | Invitado pendiente que acaba de entrar con su contraseña o passkey → se activa la invitación; si falla, error visible y "Reintentar activación". Tras "NUEVA CONTRASEÑA", el aviso dice la verdad: si la activación falló, **no** se presenta como activada. |
| `src/online/auth-ui.js` | `renderSetPassword(..., opts)` puede abrir directamente "Reintentar activación". `renderNewPassword` pasa el resultado real a la pantalla. |
| `src/online/demo-api.js` | La demo replica al servidor: el login no activa, la sesión del pendiente es válida sin permisos, `acceptInvite` / `setPassword` / `completePasswordReset` con estado real, más un interruptor **solo de pruebas** para simular la falla de activación. |
| `.github/workflows/deploy-pages.yml` | Pruebas **bloqueantes** antes de publicar; build demo separado (`dist-demo`, nunca se publica); guardián de build de producción; se sube **solo** `dist`. |
| `scripts/verify_production_build.mjs` | **Nuevo.** Falla si el artefacto no es el build de producción. Detecta el build demo por contenido, no por nombre. |
| `.gitignore` | `dist-demo/` y `tests/e2e/out/`. |
| `tests/unit/invite-access.test.js` | **Nuevo:** 14 pruebas. |
| `tests/e2e/run_invite_access.py` | **Nuevo:** 8 comprobaciones; código de salida estricto. |
| `tests/e2e/run_login_visual.py` | **Nuevo:** 21 comprobaciones; código de salida estricto. |

## 2. Pruebas E2E con código de salida real
Ambos scripts devuelven:
- **0:** se ejecutaron todos los casos esperados y todos pasaron.
- **1:** falló alguna comprobación.
- **2:** excepción, error de preparación (por ejemplo, falta el build o el servidor no responde) o se ejecutaron menos casos de los esperados.

Navegador y servidor se cierran en `finally`. El resumen se imprime igual.

**Demostración con fallas controladas,** restaurando los archivos después:
| Caso | Código de salida |
|---|---|
| A · comprobación alterada para fallar (INV-UI-01) | **1** |
| B · build inexistente | **2** |
| C · más casos esperados que ejecutados | **2** |
| D · login visual contra la base sin corregir (6 FAIL) | **1** |
| E · login visual con build inexistente | **2** |
| Restaurado: invitación / login visual | **0 / 0** |

Después de cada corrida los puertos quedaron libres y no quedó ningún proceso de Chromium.

**Publicación** (`deploy-pages.yml`): cualquier código distinto de 0 corta el job `build`, y `deploy` depende de él. Orden:
1. Unitarias de acceso.
2. Build demo en `dist-demo` → E2E de invitación.
3. Build de producción en `dist` → huella del build → verificación del flujo del transportista.
4. **Guardián de producción.**
5. Login (prueba existente en Node + login visual).
6. Subida de `./dist`.

El guardián se probó con `dist` (0), `dist-demo` (1) y **una copia del build demo con otro nombre (1)**.

## 3. Recorte visual
**Corregido y verificado (emulación):** la tarjeta de escritorio quedaba pegada a los bordes entre 800 y ~924 px de ancho.
- `run_login_visual.py`: 21/21 (código 0) en notebook 1366×768, 1280×720 y 1920×1080 con zoom 100/125/150 %; 800, 799, 820, 900 y 1024 px de ancho.
- Android emulado: 360×800, 393×851, 412×915 y 360×640; teclado abierto; PWA (393×780); apaisado.
- Sobre la base original: 6 FAIL (código 1).

**Imágenes con bordes y fragmentos ajenos:** **no** se da por resuelto. Se preparó una **propuesta de recorte mínimo, separada del proyecto y sin aplicar** (carpeta `PROPUESTA_VISUAL/` de la entrega, con antes/después y el parche).
- **Camión (Android):** se ocultan 6 px arriba (el "APP DESPACHO" cortado), 4 px a la izquierda y 10 px a la derecha (franjas oscuras) y 9 px abajo (fragmento blanco de otra interfaz). El camión, el logo y la ruta quedan completos.
- **Computadora (notebook):** se ocultan 8 px arriba y 15 px a la derecha (franjas negras) y 1 px abajo. **Límite:** la laptop y las cajas ya vienen cortadas en el borde derecho del dibujo; ese contenido no existe en el archivo.
- **Imagen fuente necesaria** para resolverlo del todo: la ilustración de computadora sin recortar (laptop y cajas completas, sin franjas negras), idealmente de **754×1076 px o más**. Opcional: el camión sin texto ni interfaz superpuestos, de 806×604 px o más.
- **Si se aprueba:** hay que actualizar la prueba existente `checkpoint36-login.mjs`, que hoy exige `object-fit: contain`.

## 4. Acceso del usuario invitado
**Defecto reproducido en el código.** El caso real **sigue pendiente de verificar** (no hay acceso a Auth ni a logs).
1. "Reenviar invitación" de un usuario que ya existe en Auth manda un **enlace de recuperación** (`resend_invite` → `sendPasswordReset`).
2. "NUEVA CONTRASEÑA" guardaba la contraseña pero **no aceptaba la invitación**.
3. Al ingresar, el perfil seguía pendiente y el ruteo volvía a "CREAR CONTRASEÑA".
4. Con la misma contraseña, Supabase responde `same_password` y `setPassword` cortaba antes de activar: el usuario quedaba atrapado.

El mismo bloqueo aparece si el primer intento guardó la contraseña y falló la activación. La demo no lo reproducía porque activaba en lugares donde el servidor no lo hace.

**Sobre la captura de "Email o contraseña incorrectos":** sin acceso a los logs no se puede saber si fue una contraseña distinta u otro error de Supabase que antes se mostraba con ese mismo texto. Ahora "email sin confirmar" y "demasiados intentos" tienen su propio mensaje.

**Activación fallida tras la recuperación:** ya **no** se ignora.
- `completePasswordReset` devuelve `activated: false` y el motivo.
- La pantalla de acceso dice "Tu contraseña se guardó, pero tu usuario todavía no se activó… Ingresá con tu nueva contraseña: la activación se va a reintentar".
- Al ingresar se reintenta; si vuelve a fallar, se muestra el error con **"Reintentar activación"**.
- Probado de punta a punta en INV-UI-05 e INV-UI-06.

**Lectura de solo consulta para verificar el caso real** (sin modificar nada; reemplazar `<email>`):
```sql
select id, email_confirmed_at, last_sign_in_at, updated_at from auth.users where email = '<email>';
select id, status, role from public.profiles where email = '<email>';
select action, created_at from public.audit_log where target_id = '<id>' order by created_at desc limit 20;
```
Un perfil `INVITACION_PENDIENTE` con `last_sign_in_at` cargado es **evidencia compatible** con este bloqueo, **no** una confirmación de toda la causa. También conviene revisar los logs de Auth (errores de inicio de sesión y `same_password`) y la auditoría de invitaciones y reenvíos.

## 5. Resultados reales (código de salida)
| # | Comando | Exit | Resultado |
|---|---|---|---|
| 01 | build de producción | 0 | OK |
| 02 | guardián sobre `dist` | 0 | OK build de producción |
| 03 | build demo (`dist-demo`) | 0 | OK |
| 04 | guardián sobre `dist-demo` (debe rechazar) | **1** | rechazado, como se espera |
| 05 | unitarias relacionadas (invite-access, supabase-api, driver-offline) | 0 | 20/20 |
| 06 | **suite unitaria completa** | **1** | **107 PASS / 3 FAIL**. Las 3 son las **preexistentes** de la base (U17, D07, REPORT-MAIL-12); +14 pruebas nuevas en verde. **No** está toda la suite aprobada. |
| 07 | `run_invite_access.py` | 0 | 8/8 |
| 08 | `run_login_visual.py` | 0 | 21/21 |
| 09 | `checkpoint36-login.mjs` (existente) | 0 | 4/4 |
| 10 | `test_driver_offline_queue.mjs` (existente) | 0 | 2/2 |
| 11 | `verify_production_carrier_flow --dist` | 1 → **0** | falló al correrlo sin la huella del build (orden manual); con `write_build_info.mjs` antes, como en el workflow, da 0 |

Base de comparación: 103 PASS / 3 FAIL (las mismas 3).

## 6. Sigue SIN verificarse
- **Teléfono Android físico, PWA instalada real y teclado real.** Todo lo visual fue **emulación de Chromium**.
- **Notebook física** con el zoom real de Windows.
- **Acceso real del usuario afectado:** no se probó contra Supabase ni con su cuenta. **No está resuelto** hasta comprobarlo después de publicar.
- **Estado real en Auth, perfil y auditoría** de esa cuenta (consultas de solo lectura en la sección 4).
- **Ejecución real del workflow en GitHub Actions:** se validó la sintaxis YAML y cada comando por separado, pero no se ejecutó en Actions.
- **Propuesta visual:** pendiente de aprobación; no está aplicada.

## 7. Corrección del control de publicación (V3)
**Defecto:** con `VITE_SUPABASE_URL` configurada y `VITE_SUPABASE_ANON_KEY` vacía, la app arranca con DemoApi, pero el verificador lo aceptaba porque solo buscaba el hostname.

**Cambios:**
- `.github/workflows/deploy-pages.yml`: nuevo paso que **rechaza URL o clave pública vacías antes del build de producción**. Se sigue compilando `dist-demo` aparte y se publica solo `./dist`.
- `scripts/verify_production_build.mjs`:
  - **Estático:** el entorno compilado debe traer URL (con el host esperado) **y** clave, ambas no vacías.
  - **Modo efectivo:** abre el artefacto en Chromium (sin red a Supabase) y exige `window.OKD_ONLINE.api.mode === 'online'`.

| Prueba | Exit |
|---|---|
| 1 · URL + clave (producción) | 0 |
| 2 · solo URL | 1 |
| 3 · solo clave | 1 |
| 4 · sin ambas | 1 |
| 5 · build demo copiado con otro nombre | 1 |
| Extra · demo con texto que imita el entorno (engaña al chequeo estático) | 1, rechazado por el modo efectivo |
| Paso previo del workflow (URL+clave / solo URL / solo clave / sin ambas / solo espacios) | 0 / 1 / 1 / 1 / 1 |

No se volvieron a correr la suite completa ni las pruebas visuales: el cambio afecta solo al control de publicación.
