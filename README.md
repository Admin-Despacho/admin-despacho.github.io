# OK Despacho Online — Fase 2A (0.2.0-fase2a)

**Estado: FASE 2A — NO LISTO PARA PUBLICAR.** Novedades en `CAMBIOS_FASE2A.md` (informe comercial de Cristian Torres + email) y `CAMBIOS_FASE1_1.md`. Es la base del sistema online. La publicación de hojas en vivo, el celular del transportista, el transporte interno, las cobranzas, los PDFs del servidor y los emails son fases siguientes.

OK Despacho es **independiente de MAGIC**: tiene su propio repositorio, su propio proyecto Supabase, su propia autenticación, sus propias tablas, Storage, Edge Functions y políticas RLS, y su propio deploy. No reutilizar credenciales ni bases de MAGIC.

## Qué incluye la Fase 1
- **Acceso** con email y contraseña. Los usuarios nuevos se crean **por invitación**: reciben un email y crean su contraseña en `/#/crear-contrasena`.
- **Panel del Operario = versión offline v15 sin cambios de lógica**: cálculo de montos, comprobantes, envíos, Cobrado, PDF, Excel y rendición. Se carga recién con una sesión válida y con permiso `routes.create`.
- **Administración → USUARIOS** (permiso `users.view`; acciones con `users.manage`):
  - listado con nombre, email, teléfono, rol, transportista/empresa, estado, último acceso y fecha de creación;
  - nuevo usuario por invitación, cambio de rol, carriers, deshabilitar y reactivar;
  - **eliminar definitivamente** solo si no tiene historial; si lo tiene, se **archiva**;
  - nadie cambia su propio rol, el último administrador activo está protegido y todo queda en auditoría.
- **Seguridad de usuarios (1.1)**:
  - EDITAR (con rol y transportista/empresa en el mismo flujo);
  - RESTABLECER CONTRASEÑA por link al email;
  - CERRAR SESIONES ABIERTAS;
  - REENVIAR y CANCELAR INVITACIÓN;
  - buscador y filtros;
  - último acceso real;
  - protección de hojas activas, con reasignación;
  - MI CUENTA, para cambiar la propia contraseña.
- **Base para aprobar cambios de rutas internas (1.1)**: permiso `can_approve_internal_route_changes`, superior configurable por usuario, estado operativo separado del estado de aprobación y solicitudes de aprobación idempotentes. La parte móvil es Fase 2.
- **Permisos granulares** en la base: `users.*`, `routes.*`, `deliveries.*`, `internal_routes.*`, `locations.*`, `signatures.view`, `audit.view`, `settings.manage`.
- **Regla de RESPONSABLE compatible, validada en el servidor:**
  - TRANSPORTE INTERNO → solo usuarios ACTIVOS con rol `TRANSPORTISTA_INTERNO`;
  - carrier externo (por ejemplo CRISTIAN TORRES - ESTE o ALREDEDORES) → solo usuarios ACTIVOS vinculados a ese carrier;
  - se aplica con la función `responsables_disponibles` (la lista que usa el selector) y con un trigger en `routes` que rechaza cualquier asignación incompatible aunque la pantalla se saltee.
- **Modo demo**: sin variables de Supabase, la app arranca sin servidor, con usuarios de prueba (contraseña `demo`) y las mismas reglas. Se usa para la aceptación visual y para las pruebas E2E.

## Informe comercial de Cristian Torres (Fase 2A)
Botón **Informes**, con permiso `can_view_commercial_transport_reports`. Tiene tres pestañas: INFORME (6 bloques en el orden aprobado), HISTORIAL y CONFIGURACIÓN.
- Envío automático: sábados a las 15:00 y cierre de mes (hora de Mendoza).
- Email HTML con PDF adjunto, idempotente.

Guías: `docs/GUIA_EMAIL_PROVEEDOR.md` y `docs/GUIA_VARIABLES.md`.

## Estructura
```
index.html                       panel offline v15 + acceso + usuarios
src/main.js                      sesión, permisos y carga del panel v15
src/online/                      api (Supabase / demo), acceso, usuarios
src/styles/offline.css           estilos de la v15 (sin cambios)
src/styles/online.css            agregados con las mismas variables visuales
public/legacy/                   lógica y librerías de la v15 (sin cambios de lógica)
supabase/migrations/             tablas, funciones, triggers y RLS
supabase/functions/admin-users/  Edge Function de usuarios (handler.js + index.ts + pruebas)
supabase/functions/_shared/      reglas compartidas (roles, permisos, responsables)
tests/unit  tests/sql  tests/e2e pruebas
docs/                            guías, capturas y prototipo V16 aprobado
```

## Correr en una computadora
```bash
npm install
npm run dev            # MODO DEMO si no hay .env
npm run build          # build de producción en dist/
```
Para el modo online real, copiar `.env.example` a `.env` con la URL y la anon key del proyecto Supabase de OK Despacho.

## Pruebas
```bash
npm test                         # unitarias (vitest)
deno test --allow-read supabase/functions
bash tests/sql/run.sh            # migración + RLS en PostgreSQL local (requiere postgresql instalado)
npm run build && python3 tests/e2e/run_e2e.py   # E2E en Chromium (requiere playwright de Python)
bash tests/run_all.sh            # todo junto, resumen en tests/out/summary.txt
```
Ver `TEST_RESULTS.md` para lo que se ejecutó y lo que quedó **NOT RUN**.

## Publicar
Ver `docs/GUIA_SUPABASE.md`, `docs/GUIA_CLOUDFLARE.md` y `GUIA_PARA_PUBLICAR_CON_CHATGPT.md`.

## Datos del Operario en la Fase 1
El panel del Operario sigue guardando archivos y hoja **en el navegador** (IndexedDB), igual que la offline. La hoja pasa al servidor en la Fase 2, con la publicación en vivo.

## Cerrar sesiones abiertas: qué hace y qué no
Supabase no permite invalidar un token (JWT) ya emitido antes de que venza. Por eso la estrategia es:
1. **Borrar las sesiones del usuario en Auth** (`auth.sessions`): no puede renovar su token, así que cuando venza tiene que volver a iniciar sesión.
2. **Dejar sin permisos los tokens ya emitidos**: `profiles.sessions_revoked_at` + `auth_has_perm()` comparan la hora de emisión del token (`iat`) y desde ese momento el token viejo no tiene ningún permiso en tablas ni funciones protegidas por RLS. La app detecta la marca y vuelve al acceso con el aviso.

**Límite:** hasta que vence (por defecto 1 hora en Supabase), el token viejo sigue siendo criptográficamente válido para endpoints que no consultan nuestras políticas, por ejemplo leer su propio perfil o `auth.getUser`. No puede leer ni modificar datos de operación. Se recomienda bajar la duración del JWT a 15 minutos en Authentication → Settings.
