# Permiso "Permitir asignación de hojas de ruta" · cambio de servidor (NO aplicado)

## Qué hace
- **Catálogo:** agrega el permiso `routes.receive_internal`. **No se asigna a ningún rol** y vale solo si se habilita a la persona (excepción GRANT con el editor de permisos existente), también para un Admin.
- **Elegibilidad:** `can_be_responsable`. Para el Transporte Interno, Transportista Interno **o** el permiso habilitado. Externos, sin cambios.
- **Operar la hoja:** `_my_route`. Solo la hoja **propia**; en el Transporte Interno exige ser Transportista Interno o tener el permiso habilitado. Al quitar el permiso se corta el acceso aunque el rol tenga otros permisos.
- **Ver la hoja:** `can_view_route_row`. Se agrega solo su hoja interna asignada; el resto queda igual.
- **Foto del DNI:** la política `identity_docs_upload` también permite subirla con el permiso. Vincularla sigue exigiendo la hoja propia.
- **Lo que no cambia:** roles, otros permisos, RLS de otras tablas, usuarios, transportistas y numeración.

## Orden de aplicación
1. **Copiar la migración:** `20261110000100_permiso_asignacion_hojas.sql` a `supabase/migrations/`, y su nombre al **final** de `tests/sql/migration_order.txt`.
2. **Probar en un entorno de prueba:** `bash propuestas/permiso_asignacion_hojas/run_permiso_tests.sh`. Esperado: **91/91, exit 0** (64 de G2 + 27 del permiso).
3. **Aplicar** en producción con autorización.
4. **Publicar la app** (este ZIP). La app sin la migración no permite asignar a nadie con el permiso, porque el servidor lo rechaza, y no rompe nada.
5. **Habilitar** a una persona (cuando se decida): Usuarios → PERMISOS → Hojas → "Permitir asignación de hojas de ruta" → GUARDAR PERMISOS. **Todavía no habilitarlo a usuarios reales.**

## Reversión
- **Quitar el permiso a la persona:** queda sin acceso al instante; sus registros se conservan y el administrador ve sus hojas pendientes.
- **Desactivarlo para todos:** `delete from public.user_permission_overrides where permission_code = 'routes.receive_internal';`
