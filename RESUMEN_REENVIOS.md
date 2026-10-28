# Reenvíos sin duplicar el informe de Cristian (base: commit 992abd0)

## Modelo investigado
- **`order_reservations`:** tiene **una reserva por pedido** (`order_id` es la clave). Al publicar queda PUBLICADA para siempre, así que un pedido con cliente ausente o reprogramado **no se podía volver a cargar**. El constructor no tiene un bloqueo propio: muestra el rechazo del servidor (`PEDIDO_YA_EN_OTRA_HOJA`).
- **Pedidos en la parada:** cada parada publicada guarda **todos** sus pedidos en `route_stops.order_numbers` (text[]). El constructor reserva el de mercadería **y** el de envío, y una parada puede agrupar varios pedidos.
- **Revisión de una hoja:** reemplaza sus paradas. Las versiones no generan intentos.

## Cambios
- **Constructor (servidor, propuesta separada):** `propuestas/reenvios/` permite volver a cargar un pedido **NO ENTREGADO o REPROGRAMADO**, o de una hoja cancelada.
  - Conserva la hoja anterior y deja un historial.
  - El pendiente en otra hoja activa y el entregado **no** se liberan.
  - La demo (`src/online/demo-api.js`: `_retryable`, `_reserve`) refleja lo mismo.
- **Informe** (`supabase/functions/_shared/report-engine.js`, criterio V3):
  - **Clave del envío:** el número de pedido comercial **completo** (`order_numbers`). Nunca la parada, la hoja ni el cliente.
  - **Origen antes del período:** se recorre todo el historial válido (sin borradores ni canceladas, con fecha de publicación) **en orden de publicación** antes de filtrar.
  - **Cuándo cuenta:** el envío se cuenta **una vez**, en su **primera publicación** (Mendoza), con la zona, el importe, el cliente y la mercadería de esa parada.
  - **Intentos:** una parada cuyos pedidos ya salieron antes es un **intento**: no suma cantidad, importe, compras ni promedio.
  - **Agrupación:** una parada que trae un pedido nuevo es el origen de **ese** envío, así que ningún pedido distinto se pierde ni se fusiona.
  - **Resultado:** **uno** solo, el del último intento. Todos los intentos se conservan (hoja, fecha y resultado) en `inputs.retries`.
  - **Paradas sin número de pedido** (datos anteriores): clave hoja + parada, como antes.
- **Trazabilidad visible:**
  - **Pantalla:** `#rpRetries`.
  - **Excel:** nota en "Resumen" y hoja **"Reintentos"**.
  - **PDF:** línea de reenvíos.
  - **Contenido del correo:** sin activar ningún envío.
  - **Informes guardados:** se conservan como se generaron.
- **Datos ficticios de la demo** (`report-demo-data.js`): varias hojas de ejemplo compartían el pedido ficticio `99999`; ahora cada una tiene el suyo, porque con el criterio nuevo eran reintentos.

## Pruebas ejecutadas (datos ficticios)

| Prueba | Resultado | Exit |
|---|---|---|
| `tests/unit/report-reenvios.test.js` (nueva) | **9/9** | 0 |
| Servidor `propuestas/reenvios/run_reenvios_tests.sh` (G2 + reenvíos) | **74/74** | 0 |
| `tests/e2e/run_reenvios.py` (demo) | **7/7** | 0 |
| Regresión `run_informe_cristian_publicadas.py` | **5/5** | 0 |
| Unitarias del informe en conjunto | **73/74** | — |
| Deno `commercial-reports` | **10/11** | — |
| `deno check index.ts` | sin errores | 0 |
| Build de producción + guardián | OK | 0 |

- **`report-reenvios`:**
  - mismo pedido en dos hojas → 1 envío, 1 importe, 1 resultado, 1 compra;
  - cuenta el lunes, no el martes;
  - reintento en otro período: no vuelve a sumar;
  - dos pedidos del mismo cliente: no se fusionan;
  - agrupación y cambio de zona: [A+B] y C nuevo dan 22.000 y nunca 29.000;
  - primera hoja cancelada y borrador;
  - trazabilidad;
  - la misma hoja cargada dos veces;
  - PDF y correo.
- **Servidor:**
  - no entregado se puede volver a cargar, con historial y la hoja anterior intacta;
  - pendiente, entregado y otra parada pendiente: bloqueados;
  - hoja cancelada: se puede volver a cargar;
  - dos hojas activas: bloqueado;
  - publicado el reintento, la reserva pasa a la hoja nueva.
- **E2E:**
  - el constructor reserva con su misma función;
  - el reintento (otro día, otra zona y otro importe) no suma;
  - la pantalla muestra los intentos y el Excel coincide con la pantalla.
- **Fallas preexistentes** (iguales en el commit original, programación mensual): REPORT-MAIL-12 en las unitarias y REPORT-MAIL-12b en Deno.

**Aclaración:** en el E2E, el caso de "Mejores clientes" pasa porque ese cliente no entra en el ranking visible. La compra única la verifica RE-01 (unidad).

## Correcciones posteriores (revisión de Codex)
1. **Reagrupación A+B → B+C** (`report-engine.js`):
   - **Pedidos:** el envío nuevo lleva **solo** sus pedidos nuevos (C). Los reintentados (B) quedan como intento de su envío original, con trazabilidad.
   - **Limitación de datos:** cada parada guarda **un** importe de mercadería y **un** envío (no por pedido). Si una parada junta pedidos ya contados con nuevos, el envío nuevo **se cuenta**, pero su mercadería y su envío **no se suman** y quedan listados como **"importe no separable"** (pantalla, Excel, PDF y correo), con el monto de la parada y los pedidos. No se inventa un prorrateo.
   - **Caso de Codex:** A+B y B+C a $100 por pedido → el ranking muestra **$200** (no $400) y la parada B+C queda señalada.
   - **Estado de un grupo dividido:** sale del **último resultado de cada pedido**. Todos entregados → entregado; alguno pendiente → pendiente; parte entregada y resto no → entrega parcial. El detalle queda por pedido.
2. **Prueba del constructor con controles reales** (`tests/e2e/run_reenvios_constructor.py`):
   - importar informes ficticios con el selector de archivos;
   - `#ids` + BUSCAR;
   - **PUBLICAR HOJA** resolviendo REVISAR con sus casillas, importes y forma de pago;
   - **+ NUEVA HOJA** → volver a cargar el **no entregado** → publicar;
   - informe sin duplicar;
   - el **pendiente** y el **entregado** siguen bloqueados, con el aviso "No se duplica".

| Prueba (código final) | Resultado | Exit |
|---|---|---|
| `tests/unit/report-reenvios.test.js` (incluye RE-10 de Codex y RE-11 grupo dividido; estado leído del motor) | **11/11** | 0 |
| `tests/e2e/run_reenvios_constructor.py` (controles reales) | **7/7** | 0 |
| `tests/e2e/run_reenvios.py` | **7/7** | 0 |
| `run_informe_cristian_publicadas.py` | **5/5** | 0 |
| Unitarias del informe en conjunto | **76/77** | — |
| Deno `commercial-reports` | **10/11** | — |
| `deno check` | sin errores | 0 |
| Build + guardián | OK | 0 |

- **Unitarias y Deno:** la única falla en cada caso es la programación mensual preexistente (REPORT-MAIL-12 y 12b), igual en el commit original.
- **`run_reenvios.py`:** una primera corrida en paralelo con las unitarias se cortó por tiempo de espera, sin ejecutar casos; sola dio 7/7.
- **Importes en `run_reenvios_constructor.py`:** con el informe sintético de esa prueba, el importe de envío es $0 (no trae pedidos de envío). El control de importe lo verifican `run_reenvios.py` ($13.000) y las pruebas de unidad.

## Pendientes
- **Aplicar la migración** según `INSTRUCCIONES.md`; sin ella el reintento sigue bloqueado.
- **Entrega parcial:** queda **bloqueada** para reintento (se considera entregada). Si se necesita reenviar el resto, es un caso a definir.
- **Sin probar** contra producción.
