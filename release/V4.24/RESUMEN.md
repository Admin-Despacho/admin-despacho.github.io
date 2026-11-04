# OK Despacho · entrega acumulativa V4.24 (base `99ffd09`; incluye V4.21, V4.22 y V4.23)
**Nada publicado, ningún SQL aplicado y producción sin modificar.** La inspección de vehículos **no** está en el código: está preparada en `PLAN_V4_25_INSPECCIONES/`.

## Qué agrega V4.24
- **VER ENTREGA:**
  - **Acceso:** Superior Despacho (hojas de su equipo; permiso existente `signatures.view`).
  - **Diseño nuevo:** pestañas por ubicación, línea de tiempo con GPS, precisión y mapa, y SIN REGISTRO.
  - **Solo lectura.**
- **SALIDA Y RECORRIDO:** módulo independiente.
- **Recorrido interno:** SALÍ DEL DEPÓSITO (GPS) y **SALÍ DE <SUCURSAL>** después de TERMINÉ, sin conexión y sin duplicar.
- **Formulario de entrega:** etiquetas fijas, CUIL *, email OPCIONAL y error debajo del campo.
- **Gmail de hojas:** integrado con Comunicaciones (canal GMAIL/RESEND; activación pendiente de autorización).
- **SESIÓN BLOQUEADA:** fondo nuevo; corregido además un botón cortado en Android.
- **Ícono PWA:** solo propuesta (`PROPUESTA_ICONO_PARA_APROBAR/`).

## Defectos encontrados y corregidos en el camino
- **SALIDA Y RECORRIDO:** el detalle se abría al final de la lista. Ahora usa pestañas.
- **Demo:** VER ENTREGA no respetaba el equipo del Superior.
- **SESIÓN BLOQUEADA en Android:** el botón "INGRESAR CON CONTRASEÑA" quedaba fuera de pantalla.
- **Prueba de Comunicaciones:** tenía fechas fijas y fallaba también en `99ffd09`.
- **Parche:** el parche de texto omitía archivos binarios. Ahora se genera con `--binary` y está verificado.

## Pruebas EJECUTADAS (registros en `RESULTADOS/`)
| Área | Resultado |
|---|---|
| Recorrido interno (SALÍ, LLEGUÉ/TERMINÉ/SALÍ, Diamante, sin conexión) | 11/11 |
| VER ENTREGA y SALIDA Y RECORRIDO (roles y Android) | 9/9 |
| Cristian sin DNI (hoja antigua, parcial, reprogramación con segunda visita, nueva) | 4/4 |
| Firma, CUIL y email · perfiles del chofer (inicio, cierre, sin conexión) | 12/12 · 16/16 |
| G2 · pantallas G2 · Cambiar rol · revisión · agregar parada | 23/23 · 30/30 · 16/16 · 11/11 · 4/4 |
| Vehículos y service · vehículos y permisos | 7/7 · 13/13 |
| REVISAR · notas (reparto, decimales, robustez) · reenvíos · informe de Cristian | 16/16 · 8/8 · 8/8 · 8/8 · 7/7 · 5/5 |
| Navegación · **auditoría Android** · emails de clientes · Comunicaciones | 10/10 · 9/9 · 11/11 · 22/22 |
| Sesión bloqueada (login y recuperación idénticos) · privacidad | 5/5 · 5/5 |
| SQL: V4.24 · protección V4.24 · Comunicaciones + hojas por Gmail | 71/71 · 5/5 · 149/149 |
| Gmail: unitarias · envíos y reintentos | 54/54 · 16/16 |
| Unitarias generales | 242/245: las **3 fallas son las mismas que en `99ffd09`** (comparadas por nombre); **0 nuevas** |
| Build OFICIAL + guardián · secretos 0 · íconos 7/7 · privacidad idéntica | OK |

**De V4.23, sin cambios en V4.24:** SQL V4.21 79/79 · SQL V4.23 88/88, con sus protecciones 5/5.

**No ejecutadas:**
- **Alertas de service por email:** sin prueba automática; se verifican en producción.
- **Pruebas viejas rotas** (también en `99ffd09`): fases 2B, RC4 y borrador antiguo.

## Pendientes reales
1. **Para publicar:** consultas de solo lectura en producción, la elección de Diamante si hay varias, la corrección de la Kangoo y la autorización. Ver `PUBLICACION_SEGURA.md`.
2. **Activación de Gmail de hojas:** con autorización.
3. **Aprobación de la propuesta del ícono.**
4. **V4.25 (inspecciones):** resolver las 3 decisiones de `PLAN_V4_25_INSPECCIONES/01…` (SI/NO del Excel frente a BIEN/MAL/NO APLICA, firma sin imagen, autoaprobación).
