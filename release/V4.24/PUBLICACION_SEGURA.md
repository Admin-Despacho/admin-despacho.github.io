# Publicación segura · V4.21 → V4.23 → V4.24 → Gmail de hojas (para cuando la autorices)
**Nada de esto se ejecutó.** Cada script se ejecuta **completo** en el SQL Editor de producción: es una transacción con verificación previa y posterior, y si algo no coincide, se detiene **sin modificar nada**.

## 0. Antes de empezar (solo lectura)
- **V4.21** (`1_V4_21/VERIFICAR_PRODUCCION_SOLO_LECTURA.sql`): `set_stop_outcome` = **V4.17** (`5e4bf784…`). Anotar permisos y dueño.
- **V4.23** (`2_V4_23/VERIFICAR_PRODUCCION_SOLO_LECTURA.sql`):
  - `finalize_route` = `c5bc9e2f…`.
  - **Depósito Diamante:** clave real, coordenadas, radio y estado. Una activa: se usa sola; varias: elegirla en el paso 5.
  - **Dependencias:** todas en true.
  - **Hojas internas EN CURSO:** no se bloquean.
- **Gmail de hojas:** confirmar que las tablas de Comunicaciones (`comm_*`) existen en producción (migración `20261112000100_comunicaciones.sql`).
- **Kangoo II · AD629SA** (`consultas_vehiculos/DETECTAR_INTERVALOS_SOLO_LECTURA.sql`): si sigue con el intervalo imposible, corregirlo desde Configuración → C → EDITAR con el intervalo real (sin SQL de escritura).

## Orden obligatorio: el servidor completo PRIMERO y la pantalla nueva ENSEGUIDA, fuera del horario de reparto
| Paso | Script | Verificación posterior |
|---|---|---|
| 1 | `1_V4_21/20261116000100_v4_21_entrega_sin_dni_email_opcional.sql` | huella `5d26e5af…`, permisos iguales |
| 2 | `2_V4_23/20261117000100_v4_23_g2_diamante_emails.sql` | `finalize_route` = `779f1959…`; Diamante resuelto |
| 3 | `3_V4_24/20261118000100_v4_24_salidas.sql` | `3_V4_24/VERIFICAR…`: las 2 funciones existen |
| 4 | `4_HOJAS_GMAIL/20261113000100_hojas_por_gmail.sql` | el canal sigue en **RESEND** hasta habilitar Gmail |
| 5 | Si hubo varias "Diamante": `select public.set_return_depot('<clave>');` (Administrador General) | `select public.return_depot_status();` |
| 6 | **Pantalla:** `git apply cambios_acumulados_V4_24.patch` sobre `99ffd09` y publicar (solo con autorización) | Prueba controlada en producción: entrega sin DNI, con y sin email; SALÍ → LLEGUÉ/TERMINÉ/SALÍ → LLEGUÉ A DIAMANTE → KM → FINALIZAR; VER ENTREGA (Superior); SESIÓN BLOQUEADA |
| 7 | **Habilitar Gmail de hojas:** Comunicaciones → Conexión Gmail (cuenta autorizada) y Configuración → F → canal **GMAIL** | Prueba real acotada a destinatarios autorizados (`propuestas/comunicaciones/PRUEBA_REAL_ACOTADA.md`) |

## Compatibilidad pantalla ↔ servidor
- **Pantalla actual (`99ffd09`) con el servidor V4.21 a V4.24:** funciona.
  - **Única excepción:** las hojas internas **iniciadas después del paso 2** necesitan LLEGUÉ A DIAMANTE, que la pantalla actual no tiene.
  - **Por eso:** los pasos 2 a 6 van juntos, fuera del horario de reparto.
- **Pantalla nueva con el servidor sin V4.21:** rechaza las entregas (DNI/email).
- **Pantalla nueva sin V4.24:** fallan SALÍ DEL DEPÓSITO (GPS) y SALÍ DE la sucursal.

## Recuperación (en orden inverso; nunca dejar la pantalla nueva con un servidor viejo)
- **Primero, la pantalla:** volver a publicar `99ffd09`, si ya se publicó la nueva.
- **Gmail de hojas:** volver el canal a RESEND en Configuración → F. No requiere SQL.
- **V4.24:** `3_V4_24/RECUPERACION_V4_24.sql` (quita las 2 funciones y conserva columnas y datos).
- **V4.23:** `2_V4_23/RECUPERACION_FINALIZE_ROUTE.sql` (`finalize_route` exacta).
- **V4.21:** `1_V4_21/RECUPERACION_VOLVER_A_V4_17.sql`.

**Limitaciones:**
- **No se borran datos:** padrón, llegadas, salidas y terminés registrados se conservan.
- **Lo confirmado no se revierte:** las entregas ya confirmadas sin DNI o sin email quedan así.
- **Cola sin conexión:** las operaciones pendientes en un celular (`locfinish`, `locdepart`, `depot`, `departure`) no las envía la pantalla vieja; revertir **después** de que los choferes sincronicen.

## Alertas de service por email
La lógica del servidor no cambió en V4.24. **No existe prueba automática**, así que su comprobación **requiere producción**: después de corregir el intervalo de la Kangoo, verificar en Configuración → E que llegue el aviso de "service próximo" a los destinatarios configurados.
