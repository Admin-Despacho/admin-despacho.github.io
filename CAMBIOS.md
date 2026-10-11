# CAMBIOS 0.6.3-rc1 (hotfix staging · admin-users)
- Causa: la función respondía CORS solo con `authorization, content-type` (supabase-js también envía `apikey` y `x-client-info`), y las excepciones del `catch` salían sin CORS → el navegador mostraba "Failed to send a request…" y `accept_invite` nunca llegaba (perfil quedaba `INVITACION_PENDIENTE`). Además `getProfile` tragaba errores de consulta y devolvía `null` → el admin recibía 403, y el permiso se calculaba en JS en lugar de la base.
- `admin-users`: CORS completo (`authorization, apikey, x-client-info, content-type`) en OPTIONS, 2xx, 4xx y 500; toda excepción → `{ error, code: "SERVER_ERROR" }` legible; validación de `SUPABASE_URL` / `SUPABASE_SERVICE_ROLE_KEY` (→ `CONFIG_ERROR`); cada consulta que falla informa qué falló.
- Permisos desde una única fuente: `public.user_has_perm(p_user, p_perm)` (`users.view` para listar, `users.manage` para administrar).
- `accept_invite` idempotente: si el perfil ya está ACTIVO responde 200 con el usuario (sirve para REINTENTAR ACTIVACIÓN).
- Frontend: mensaje claro si no se puede conectar con la función. Sin cambios de migraciones ni de otros módulos.
- Prueba ajustada explícitamente: F18 (segundo accept_invite) ahora espera 200 idempotente.
