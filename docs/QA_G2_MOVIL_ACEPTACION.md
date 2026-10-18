# OK Despacho Online — Acta de aceptación móvil G2

**Estado:** PENDIENTE DE PRUEBAS FÍSICAS. Documento de control, NO autorización de despliegue.

**Referencia de código:** rama `fix/g2-chatgpt-final-review`; QA automatizado G2 Security `39149487998`: 61 PASS / 0 FAIL. QA visual previo `39146471001`: 30 PASS / 0 FAIL. Push SW previo: 3 PASS / 0 FAIL.

## Reglas de seguridad para ejecución
- No crear pedidos ficticios, hojas ficticias, cobros, notas de crédito o recibos en Supabase producción.
- Ejecutar recorridos completos solo con una hoja real autorizada por Operaciones, o con un entorno de ensayo aislado sin cargos y sin conexión a producción.
- Prohibido aplicar migraciones, `db push`, hacer merge a `main` o desplegar por el solo hecho de completar este documento.
- La migración `20261018174637_20261018180000_g2_revoke_anon_admin_rpc.sql` permanece pendiente en producción hasta autorización específica.

## Registro de dispositivos
| Campo | Android | iPhone (si disponible) |
|---|---|---|
| Dispositivo / modelo | PENDIENTE | PENDIENTE |
| SO / versión | PENDIENTE | PENDIENTE |
| Navegador / PWA instalada | PENDIENTE | PENDIENTE |
| Fecha / responsable | PENDIENTE | PENDIENTE |

## Matriz de aceptación física
| Caso | Procedimiento | Aprobación | Resultado |
|---|---|---|---|
| M-01 | Abrir sesión del chofer y desplazarse por la hoja | Sin desborde horizontal, solapamientos o campos cortados | PENDIENTE |
| M-02 | Abrir + AGREGAR PARADA y alternar TAREA / UBICACIÓN INTERNA | Selector usable con el dedo; búsqueda G2 legible; no se editan pedidos ni maestro | PENDIENTE |
| M-03 | En una hoja real autorizada, abrir recepción G2 y usar firma con el dedo | Firma captura trazos y GUARDAR no queda oculto por footer o teclado | PENDIENTE |
| M-04 | Control negativo de recepción G2, solo en base temporal | Sin receptor/firma debe rechazar; incluso si no hay pedidos | PENDIENTE |
| M-05 | Validar precisión/permisos GPS con consentimiento en recorrido autorizado | Ubicación real, mensaje claro ante GPS denegado o inexacto, se respeta snapshot | PENDIENTE |
| M-06 | Entrar en campo observaciones con teclado móvil | El teclado no tapa entrada, firma ni botón GUARDAR | PENDIENTE |
| M-07 | Perder y recuperar conexión durante operación de prueba aislada | No duplica paradas ni comprobantes; estado e idempotencia consistentes | PENDIENTE |
| M-08 | Push con PWA cerrada, usando un aviso real autorizado | Llega un único aviso, abrir lleva a hoja correcta; registrar diferencias SO | PENDIENTE |
| M-09 | Validar visualización de hoja interna | PARADA/PARADAS en avisos y contadores generales; sin mensajes comerciales | PENDIENTE |
| M-10 | Validar segunda visita explícita a una misma G2 en ensayo aislado | Dos paradas diferenciadas, firma y snapshot independientes | PENDIENTE |

## Criterios de cierre
- **APROBADO MÓVIL:** todos los casos aplicables PASS, evidencia fechada y sin defectos críticos.
- **BLOQUEADO:** error en firma, GPS obligatorio, idempotencia, permisos, envíos comerciales de G2, desbordes que impiden operar o push requerido que no llega.
- **NO PROBADO:** no equivale a PASS. Una prueba sobre Chromium no reemplaza dispositivo físico.

## Decisiones de publicación
1. Separar el resultado móvil del QA automatizado ya cerrado.
2. Revisar el diff de la migración de seguridad y el historial real antes de aplicar cualquier cambio.
3. Confirmar rollback, respaldo y ventana de publicación con el responsable operativo.
4. Registrar fecha, responsable y resultado final en esta acta antes de autorizar producción.
