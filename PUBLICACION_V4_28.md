# Publicación V4.28

Base: 91d76edd0054ae3e2deff881e184cf72415592e7. Paquete auditado SHA-256: 43fda67bb619836158767c0c07e347630b6ea5a5e09d5f213fb0f980bbf0b8fc.

Migración registrada: 20261110124238_v4_28_ver_hoja_pendientes_receptor.sql. SQL autorizado con lock_timeout de 5 segundos y statement_timeout de 30 segundos dentro de la transacción. No repetir la propuesta con fecha futura.

Auditoría independiente: SQL 102/102, AUD-00 a AUD-04 5/5; compatibilidad V4.27/V4.28 7/7. Tres fallas unitarias heredadas sin regresiones nuevas. Navegación, Usuarios Android, documentos, firmas, aprobaciones y actualización PWA aprobados en entorno aislado.

Cambian únicamente las funciones existentes set_stop_outcome, delivery_identity_lookup y search_deliveries; diez funciones y tres tablas nuevas. finalize_route, políticas existentes, Inspecciones y aprobaciones V4.27 intactas. Respaldo verificable fuera del repositorio. Sin correos reales.

Transición: guardar Constructor y KM antes de actualizar. Entregas abiertas y recorridos existentes compatibles. Validar cada teléfono físico antes de habilitar sus operaciones críticas; no reinstalar, borrar datos, cerrar sesión ni vaciar colas. Validación física pendiente.

Recuperación: detener cambios posteriores ante un bloqueo. No ejecutar RECUPERACION_V4_28.sql automáticamente ni restaurar datos sobre operaciones nuevas; requiere evaluación y autorización específica.
