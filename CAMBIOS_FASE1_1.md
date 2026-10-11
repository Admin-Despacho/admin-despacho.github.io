# CAMBIOS — Fase 1.1 (0.1.1-fase1)

Corrección funcional y de seguridad sobre la Fase 1. **Sin cambios visuales**: misma cabecera, colores, cyan, botones y tabla. El panel del Operario sigue siendo la v15 sin cambios de lógica.

## Base de datos
Migración **incremental** `supabase/migrations/20261009000100_fase1_1_seguridad_y_aprobaciones.sql`. La migración de Fase 1 no se reescribió.

| # | Cambio |
|---|---|
| 3 | **Último acceso real**: un trigger en `auth.users` copia `last_sign_in_at` a `profiles` cuando Supabase Auth registra el inicio de sesión. |
| 4 | **Email consistente**: el mismo trigger copia el email de Auth a `profiles`, así nunca quedan distintos. |
| 2 | **Cerrar sesiones**: `revoke_user_sessions()` borra las sesiones del usuario en `auth.sessions` (no puede renovar su token) y marca `profiles.sessions_revoked_at`. `auth_has_perm()` ahora ignora los tokens emitidos antes de esa marca: el token viejo deja de tener permisos en todas las tablas y funciones protegidas, aunque todavía no haya vencido. |
| 5 | **TRANSPORTISTA siempre con carrier**: un trigger diferido rechaza, al confirmar la transacción, cualquier TRANSPORTISTA sin carrier externo, venga de donde venga. |
| 6 | **Carriers atómicos**: `set_user_carriers()` y `admin_update_profile()` hacen todo en una transacción; si algo falla quedan los carriers anteriores. |
| 7 | **Alta atómica**: `admin_create_profile()` crea perfil y carriers en una transacción. |
| 10 | **Hojas activas**: no se puede deshabilitar ni archivar a un usuario con hojas BORRADOR/PUBLICADA/EN CURSO (trigger). `user_active_routes()` las lista y `reassign_active_routes()` las reasigna validando el responsable compatible. |
| 17 | **Base de aprobación de rutas internas**: permiso `can_approve_internal_route_changes`; `profiles.supervisor_user_id`, configurable y validado; `routes.operational_status` separado de `routes.approval_status` (más `version`, `completed_at`, `completed_by`, `has_driver_modifications`, `modification_count`); tablas `route_change_events` y `route_approval_requests` (una por hoja y versión) con RLS; funciones `request_route_approval()` (idempotente, auto-cierre sin cambios, aviso si falta superior) y `review_route_approval()` (aprobar u observar con motivo, sin tocar evidencia). |

`routes.status` queda marcado como OBSOLETO, reemplazado por `operational_status` + `approval_status`.

## Edge Function `admin-users`
- Acciones nuevas:
  - `edit`: nombre, email, teléfono, rol, carriers y superior en un solo paso;
  - `reset_password`: link de recuperación al email del usuario; el Admin nunca ve contraseñas;
  - `revoke_sessions`;
  - `resend_invite`, que no crea otro usuario;
  - `cancel_invite`;
  - `reassign_routes`.
- **Alta con compensación**: si falla el perfil después de invitar, se borra el usuario recién creado en Auth y se audita `USER_CREATE_FAILED` (nunca `USER_CREATED`).
- **Borrado**: se audita `USER_DELETED` solo después de que el borrado terminó. Si falla, se registra `USER_DELETE_FAILED`.
- **Cambio de email**: primero en Auth y después el perfil. Si el perfil falla, Auth vuelve al email anterior.
- **Deshabilitar, archivar y cancelar invitación** cierran también las sesiones abiertas.
- **Auditoría** con nombres claros: `USER_CREATED`, `USER_UPDATED`, `USER_ROLE_CHANGED`, `USER_CARRIERS_CHANGED`, `USER_DISABLED`, `USER_REACTIVATED`, `USER_ARCHIVED`, `USER_DELETED`, `USER_DELETE_FAILED`, `USER_CREATE_FAILED`, `PASSWORD_RESET_REQUESTED` (con resultado), `SESSIONS_REVOKED`, `INVITE_RESENT`, `INVITE_CANCELLED`, `INVITE_ACCEPTED`, `ROUTES_REASSIGNED`.

## Pantallas
- **USUARIOS**:
  - buscador por nombre o email y filtros por rol, estado y transportista;
  - **EDITAR** (rol y transportista/empresa en el mismo flujo, más el superior para internos);
  - **RESTABLECER CONTRASEÑA**, **CERRAR SESIONES ABIERTAS**, **REENVIAR INVITACIÓN** y **CANCELAR INVITACIÓN**;
  - aviso **ESTE USUARIO TIENE HOJAS ACTIVAS** con la lista de hojas y la opción de reasignarlas a un usuario compatible antes de deshabilitar o archivar.
- **MI CUENTA** (tocando el nombre en la cabecera): cambiar la propia contraseña y cerrar sesión. No permite cambiar rol, permisos, carriers ni superior.
- **Crear contraseña (invitación)**: si la contraseña se guarda pero la activación falla, se muestra el error con **Reintentar activación** y **Cerrar sesión**. Ya no se ignora el error.
- **Sesión cerrada por Administración**: la app vuelve al acceso con el aviso "Tu sesión fue cerrada por Administración".

## Pendiente para Fase 2
Recorrido móvil del transportista interno, cierre FINALIZAR Y ENVIAR, pantalla del superior con ruta original vs. ejecutada, notificaciones de aprobación y observación, offline, PDF de la ruta ejecutada y backup. La base de datos ya quedó preparada; las pruebas F2-INT-01 a F2-INT-20 se ejecutan en la Fase 2 (ver `docs/FASE2_PENDIENTES.md`).
