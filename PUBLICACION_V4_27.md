# Publicación V4.27

Base: `292e15325174294bbbf877648bb182bea9d6a4f4`.
Paquete autorizado SHA-256: `900aca350a051b1b52d9a7b759537ce588b08008e3ed8eba29f81a0157d5bb4b`.

La integración conserva V4.26. Incluye navegación temporal, cabeceras fijas, solicitudes internas en PARA RESOLVER y campana no bloqueante. Se ajustó el ancho de la tabla a 1024 px sin ocultar acciones. La campana exige perfil activo y rol autorizado. Las decisiones de rutas internas no despachan la cola general de correo.

## Servidor

Aplicada exclusivamente `20261108161109_v4_27_aprobaciones_ruta_interna.sql`, con transacción y verificación de las dos fuentes originales normalizando CRLF. Se corrigió la condición de solicitudes sin Superior para reutilizar `_is_general_admin()`: tener `users.manage` por delegación no alcanza. La prohibición de autoaprobación comprende al Administrador. No se modifican RLS ni permisos globales.

Después del SQL se compararon las 244 funciones públicas y sus ACL, todas las políticas RLS, perfiles, catálogo de 30 controles, configuración de notificaciones, padrón y asociaciones. Solo cambiaron las dos funciones previstas; sus ACL permanecen iguales. Las dos hojas protegidas, sus paradas, la solicitud pendiente y los avisos existentes conservaron sus huellas. `finalize_route` conserva `5bdf85adab176a36ec9b55ceb1af3179`.

Leonardo y Administrador: comprobación de lectura bajo rol authenticated y contexto individual en producción, con transacciones de solo lectura. Ambos ven la solicitud, hoja, tres paradas y aviso, y tienen permiso de revisión. No se resolvió ni modificó la solicitud real.

## Pruebas previas

- Navegación: 23/23.
- Usuarios V3 Android: 6/6.
- Buscar entrega: 7/7.
- Aprobaciones y campana en navegador: 12/12.
- PostgreSQL local con funciones reales: 13/13, incluidas autoaprobación, otro equipo, perfil deshabilitado y delegación users.manage.
- Adaptador online: 4/4 comprobaciones.
- Menú y acceso de Administrador: 18 destinos conservados.
- PWA Chromium real, HTTP y service worker nativos: 2/2; actualización V4.26 a V4.27, PIN bloqueado y desbloqueado, sesión conservada, IndexedDB conservada y cola offline sincronizada exactamente una vez. No se borraron almacenes para actualizar.
- Unitarias: 243/246; las tres fallas son idénticas a la base 242/245 (D07 responsables, REPORT-MAIL-12 mensual y U17 email duplicado). Sin fallas nuevas.
- Build de producción: modo efectivo online y proyecto Supabase correcto. Íconos, manifest, privacidad, service worker, PIN, Inspecciones y Edge Functions conservados.

El primer arnés PWA mediante un enlace de directorio volvió a servir el build anterior y produjo un resultado inválido. La comprobación aceptada utiliza raíz HTTP explícita dentro del proceso, perfiles aislados y exige versión V4.27 estable en ambos escenarios. No simula la actualización ni sustituye service workers o cachés.

## Recuperación y habilitación

Se conserva respaldo privado previo de código y definiciones reales. No ejecutar automáticamente `RECUPERACION_V4_27.sql`: restaura protecciones antiguas; cualquier recuperación SQL necesita revisión y autorización específica. No borrar datos, cachés, IndexedDB ni colas offline para recuperar.

Los nuevos correos automáticos permanecen desactivados y no se enviaron correos de prueba. La aprobación u observación de modificaciones internas no genera avisos ni correo al transportista.

La publicación del frontend debe confirmarse con el workflow oficial de Pages y su build-info. La pausa operativa se mantiene hasta comprobar V4.27, inicio de sesión/PIN, pantallas operativas y comunicación con Supabase en cada teléfono físico. Las pruebas de navegador móvil no sustituyen esa validación.
