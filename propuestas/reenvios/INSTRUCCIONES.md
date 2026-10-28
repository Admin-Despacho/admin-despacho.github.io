# Reenvíos · cambio de servidor (NO aplicado)

`20261111000100_reenvios_reintento_pedido.sql`:
- **Reintento en `reserve_orders`:** la reserva publicada de un pedido pasa a la hoja nueva **solo** si en su hoja anterior todas las paradas que lo contienen quedaron NO_ENTREGADO o REPROGRAMAR, o si esa hoja fue CANCELADA.
- **Historial:** la reserva anterior queda en `order_reservation_history` (hoja, motivo y destino). La hoja anterior y sus resultados no se tocan.
- **Siguen bloqueados:** pendiente o en curso en otra hoja activa, ENTREGADO o ENTREGA PARCIAL, y borradores ajenos. Nada se libera solo.
- **Sin cambios de permisos:** `reserve_orders` sigue exigiendo `routes.create`.

## Orden
1. **Copiar la migración** a `supabase/migrations/` y agregarla al **final** de `tests/sql/migration_order.txt`. Es independiente de la del permiso de asignación (`20261110…`): pueden aplicarse en cualquier orden.
2. **Probar en un entorno de prueba:** `bash propuestas/reenvios/run_reenvios_tests.sh`. Esperado: **74/74, exit 0**.
3. **Aplicar** en producción con autorización y **después** publicar la app.
   - **Sin la migración:** la app funciona igual que hoy; el reintento sigue bloqueado.
   - **El informe** no depende de la migración: el criterio de envío único por pedido rige al generar o regenerar informes.

## Reversión
Restaurar la definición anterior de `reserve_orders` (`20261019000100_rc2_cierre_funcional.sql`). El historial no afecta a nada más.
