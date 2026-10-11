# VISUAL_PARITY_CHECK — Fase 1.1

Regla: la versión online debe verse como la evolución directa de la offline v15. **MISMA APP + ONLINE + NUEVAS FUNCIONES.**

| Elemento | Offline v15 | Online Fase 1 | Resultado |
|---|---|---|---|
| Cabecera oscura `#000E18` con línea cyan `#00E6FE` | sí | sí, mismos valores medidos en el navegador (E20) | PASS |
| Fondo claro `#F2F5F7` | sí | sí (E20) | PASS |
| Panel del Operario: pasos 1–4, tarjetas, tabla negra con línea cyan, botones | sí | es el mismo código y la misma hoja de estilos (`src/styles/offline.css`) | PASS |
| Nuevos elementos (usuario, Usuarios, Cerrar sesión) | — | con los mismos botones `tbtn` de la cabecera offline | PASS |
| Acceso y Usuarios | — | misma cabecera, tarjetas blancas, tabla negra con línea cyan | revisión visual del usuario |

Capturas en `docs/capturas/`:
- `offline_v15.png`: la v15 offline aprobada.
- `online_operario.png`: el mismo panel dentro de la versión online.
- `online_hoja.png`: hoja con los archivos reales (Hernández, Godoy, Mansur).
- `online_usuarios.png`: Administración → Usuarios.
- `prototipo_v16_selector.png`: prototipo V16 con el selector de responsable corregido.

## Fase 1.1
Sin cambios visuales en la cabecera, los colores, el cyan, los botones ni el panel del Operario: E20 vuelve a medir los mismos colores que la offline. Lo nuevo de USUARIOS (filtros, EDITAR, acciones de seguridad) y MI CUENTA usa las mismas formas: inputs con borde gris, tabla negra con línea cyan, modales con cabecera oscura y botones `soft`/`dark`/`go` de la offline.

## Fase 2A — Informes
- La pantalla INFORMES usa los mismos pasos numerados (círculo oscuro con número cyan), tarjetas blancas, tabla negra con línea cyan y botones de la offline. Capturas: `docs/capturas/online_informe.png` y `online_email.png`.
- El email usa encabezado oscuro, línea cyan, fondo claro y tablas simples, con un ancho máximo de 700 px.
- PDF de ejemplo con datos de demostración: `docs/capturas/ejemplo_Informe_Cristian_Torres_Semanal_2026-10-10_DEMO.pdf`.
- **Pendiente**: comparar con `MODELO_INFORME_CRISTIAN_FILTROS_CLIENTES_ZONAS_V8.html`, que no llegó en los archivos.
