# V4.26 — integración y publicación controlada

Base revisada: `ae80ee36ade9597df37a86f90ab33a98a05917c6`.
Paquete: `OK_DESPACHO_MEJORAS_UNIFICADAS_FINAL.zip`, SHA-256 `45a815ce202606bdd92d3594a3fd899de3c74f9b35289821d461780ad6d24e45`.

## Correcciones de integración

- Usuarios V3: columnas con mínimo cero, acciones en una columna en Android y texto ajustable, sin recortes ni contenedor horizontal. El scroll descuenta la cabecera y el buscador fijo. Las seis acciones se prueban por visibilidad real (incluida oclusión) y uso. Jerarquía, RPC y permisos anteriores conservados.
- BUSCAR ENTREGA reutiliza por hoja `okd_delivery_security.may_read`, además del alcance de rutas. Un Superior con `routes.view_all` no recibe receptor, CUIL, firma ni número de comprobante de otro equipo; un permiso extra de firmas no habilita a Operario ni transportistas.
- Padrón: documentos normalizados antes de detectar ambigüedad; repetición de una clave idéntica coherente entre vista previa y aplicación. Nunca sobrescribe correos existentes.
- Avisos de salida nuevos: `departure_notice_enabled=false`, `departure_notice_active_since=NULL`. El trigger exige ambos controles, configuración existente y salida posterior al corte. Una clave por hoja/parada y todos sus pedidos; no se reprocesan salidas históricas. No se modifica el programador ni los productores anteriores de correo. Su activación requiere autorización independiente y validar el proveedor; la configuración heredada no se migra automáticamente.
- Edge `internal-approvals`: conservar los archivos de la versión productiva y reemplazar únicamente `_shared/customer-email.js` (asunto/texto de «en camino»). Gmail de Inspecciones, autenticación, permisos y JWT permanecen iguales.

## Causa y comprobación PWA

No se cambió el service worker ni la lógica de actualización, PIN o colas.
El build base de QA tenía sw.js de las 17:07:32 UTC y el nuevo de las 17:06:59 UTC. `SimpleHTTPRequestHandler` podía contestar 304 por Last-Modified pese a cambiar el contenido. El servidor de prueba ahora utiliza ETag de contenido, con Cache-Control max-age=600. La prueba de PIN también intentaba usar localStorage desde about:blank: ahora navega antes. La sesión DEMO es por pestaña; no representa la persistencia de una sesión Supabase al cerrar un contexto.

Pruebas con Chromium y service workers reales, builds compilados y HTTP (sin mocks del worker ni de cachés): actualización normal, página vieja en caché, arranque offline y espera del PIN. Prueba adicional `run_v426_pwa_upgrade.py`: operación offline creada por la UI real en datos QA locales, preservación de IndexedDB y PIN PBKDF2 original, sincronización de exactamente una operación sin duplicados; actualización con PIN vencido y desbloqueo con el PIN válido, sin autenticarse otra vez. No se borra almacenamiento para actualizar.

El hash del shell cambia al corregir CSS: no debe fijarse al antiguo `a4c25f1f8c3d`; se compara con el SW del build exacto probado/publicado. Se conservan los shells anteriores conforme a los siete días del mecanismo vigente.

## Controles conservados

SQL local 92/92; Deno 46/46; BUSCAR ENTREGA 7/7; padrón 4/4; operaciones y ambos Excel de Inspecciones Admin aprobados. Unitarias de base y entrega: 242/245, mismas fallas heredadas D07, REPORT-MAIL-12 y U17. No se rehacen módulos ajenos.

Los siete iconos nuevos coinciden byte por byte con los aprobados. El build solo verifica, no regenera. Privacidad, fuente de Inspecciones, driver, PIN y SW idénticos a la base. `finalize_route` debe conservar `5bdf85adab176a36ec9b55ceb1af3179`; hoja 03-000007, sus paradas, los 47 correos y jerarquía existentes se comparan antes/después.

## Migración y recuperación

La propuesta lógica `20261120000100_v4_26_mejoras.sql` se registra con el timestamp real de aplicación en `supabase/migrations`. No ejecutar db push ni repetir la propuesta. El SQL es aditivo y compatible con el frontend anterior, con el nuevo productor de correo apagado. El respaldo privado conserva código base, funciones/ACL, configuración, correos y filas protegidas.

Recuperación funcional: apagar la puerta nueva, retirar solo su trigger y RPC nuevas siguiendo `propuestas/v4_26_mejoras/RECUPERACION_V4_26.sql`. Conservar correos, auditoría y tablas importadas. Evaluar consumidores antes de retirar RPC. No sobrescribir filas históricas, ejecutar reversiones destructivas ni volver automáticamente a un commit antiguo.

La pausa operativa se mantiene hasta comprobar V4.26 instalada en cada teléfono físico. La emulación Android y los perfiles persistentes Chromium no sustituyen esa validación. No se incluyen NOC/REC, Tesorería, PDF de Inspecciones ni centralización general de correos.
