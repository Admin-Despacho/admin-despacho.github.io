# Inicio de sesión V4: referencias definitivas del 19/10/2026 (solo presentación, imágenes e ícono)

Base: V3. No se tocaron Supabase, permisos, migraciones ni lógica de autenticación. No se publicó.

**Archivos modificados**
| Archivo | Cambio |
|---|---|
| `src/online/auth-ui.js` | Solo el HTML del login: logo + "OK ACCESORIOS" + "APP DESPACHO", ilustración y el formulario real en un panel. Se agrega el botón para mostrar la contraseña. Ids y flujo sin cambios. |
| `src/styles/login-brand.css` | Diseño notebook (formulario a la izquierda, ilustración a toda altura contra el borde derecho) y Android (logo y títulos, camión a todo el ancho, formulario superpuesto). Aplica solo a la pantalla de login (`:has(#loginForm)`). |
| `public/branding/` | **Nuevos:** `login-notebook.webp` (535×709), `login-android.webp` (669×478) y `ok-logo.png` (728×453, con transparencia), extraídos de las referencias a resolución nativa. **Quitados:** los WEBP chicos anteriores, sin uso. |
| `public/icons/*` | Ícono PWA desde el logo de referencia: "any" con el logo al 66 %, "maskable" al 56 % (diagonal del 66 %, dentro del área segura del 80 %), Apple 180 y favicon 16/32. |
| `public/manifest.webmanifest`, `index.html` | Íconos con `?v=20261019` para que el navegador y la PWA tomen el nuevo. |
| `tests/brand/branding.lock.json` | Hashes actualizados **solo** del ícono y el manifest. El logo de emails no cambia. |
| `tests/e2e/checkpoint36-login.mjs` | Nombres de las imágenes nuevas. |
| `tests/e2e/run_login_visual.py` | Los controles tapados se detectan por el elemento que queda encima (el formulario se superpone a propósito en Android). El margen lateral se mide sobre el formulario. |

**Ilustraciones:** se extrajeron solo las zonas sin texto ni formulario: computadora y cajas a la derecha de la notebook; camión entre el título y el formulario del teléfono. Los bordes que cortaban la diagonal turquesa se funden con el fondo blanco. No hay deformación y nunca se recortan.

**Resultados (código de salida)**
| Prueba | Resultado | Exit |
|---|---|---|
| Build de producción | OK | 0 |
| Build demo | OK | 0 |
| Guardián del build | OK | 0 |
| Flujo del transportista | OK | 0 |
| `run_login_visual.py` (21 casos) | 21/21 | 0 |
| `checkpoint36-login.mjs` | 4/4 | 0 |
| `run_invite_access.py` | 8/8 | 0 |
| Unitarias relacionadas | 20/20 | 0 |
| Ícono PWA (manifest leído por Chromium vía CDP; 4 íconos HTTP 200 e idénticos a los nuevos; favicon y Apple versionados) | OK | 0 |

**Verificado por emulación en Chromium:**
- Notebook 1366×768 con zoom 100/125/150 %.
- Android vertical 393×851, horizontal 851×393 y con teclado abierto 393×430.
- Los demás tamaños de `run_login_visual.py`.

**Sin verificar:** Android físico, PWA instalada real (actualización del ícono en la pantalla de inicio, que Android puede tardar en refrescar), notebook física y el acceso real del usuario afectado, que sigue pendiente después de publicar.

## V4.1: prueba visual más estricta (solo `tests/e2e/run_login_visual.py`)
- **Controles tapados:** cuenta como visible solo si en el centro del control queda él mismo o un descendiente suyo. Se eliminaron la comparación `closest('label')` (con `null === null` podía aprobar una superposición) y la aceptación de ancestros.
- **Recorte:** se eliminó la tolerancia del 17 % por la izquierda. La ilustración debe entrar completa en su contenedor por los cuatro lados, y el contenedor dentro de la ventana.

| Prueba | Exit |
|---|---|
| `run_login_visual.py` con las reglas estrictas: 21/21 | 0 |
| Con superposición temporal sobre INGRESAR: 20/21, "control tapado: loginBtn" | **1** |
| Restaurado: 21/21 | 0 |
| `checkpoint36-login.mjs`: 4/4 | 0 |

No hizo falta cambiar el CSS: las ilustraciones ya entraban completas. App, autenticación, imágenes y diseño sin cambios; no se recompiló.
