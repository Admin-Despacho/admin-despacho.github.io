# Informe Cristian Torres · criterio de HOJAS PUBLICADAS (base: commit 894a5f7)

## Causa
El informe no se limitaba solo por un texto: **los datos y los cálculos** exigían hojas finalizadas.
- **Carga en el servidor:** la Edge Function `commercial-reports` (`index.ts`) traía de la base **solo** hojas con `operational_status = 'COMPLETADA'`.
- **Motor compartido** (`_shared/report-engine.js`, que usan la pantalla, el Excel, el PDF y el correo):
  - descartaba toda hoja no COMPLETADA y filtraba por `completed_at` (fecha de finalización);
  - sumaba importe solo de entregas ENTREGADO o PARCIAL.
- **Resultado:** una hoja publicada no aparecía hasta que Cristian la terminaba, y caía en el período en que la terminó.

## Cambios
- **`supabase/functions/_shared/report-engine.js`**
  - **Hojas incluidas:** PUBLICADAS (pendientes, en curso o finalizadas), sin borradores ni canceladas, también las antiguas, sin corte.
  - **Fecha que manda:** la publicación, en hora de Mendoza. Se toma de `published_at`; en tercerizados, de `dispatched_at`; si falta, del registro histórico `ROUTE_PUBLISHED` de `audit_log`. **Nunca** se inventa ni se usa la finalización: la hoja sin fecha confiable queda fuera y se lista en `inputs.missing_publication`, que también se muestra en pantalla, Excel y PDF.
  - **Un envío = hoja + parada:** sin duplicados por reapertura, recarga o versiones. La revisión de una hoja reemplaza sus paradas, y TAREA no cuenta como envío.
  - **Cantidades e importes:** todos los envíos cuentan, con el importe de envío **guardado** en la hoja (no mercadería ni cobranza). El estado (pendiente, entregado, no entregado, reprogramado) se informa aparte y **no cambia los totales**: completar después una entrega no suma ni mueve de período.
  - **Promedios:** importe ÷ envíos con importe. Un envío provisorio sin confirmar se cuenta, pero no suma importe (regla anterior conservada).
  - **Identificación:** `criterion: 'HOJAS_PUBLICADAS'` en cada informe nuevo.
- **`supabase/functions/commercial-reports/index.ts`**: carga las hojas de Cristian que no son borrador ni cancelada, con sus fechas de publicación y despacho, más el respaldo histórico desde `audit_log`. **Sin SQL ni cambios de permisos.**
- **`src/online/reports-ui.js`** (pantalla y Excel), **`_shared/report-pdf.js`**, **`_shared/report-email.js`** (solo el contenido; el envío no se tocó):
  - **Rótulos nuevos:** "Hojas publicadas", "Envíos incluidos", "Importe de envío informado (no es dinero cobrado)" y el estado de los envíos (pendientes nunca como entregados).
  - **Historial conservado:** los informes guardados antes (sin `criterion`) se muestran, exportan y reimprimen como se generaron.
- **`src/online/demo-api.js`**: la demo carga las hojas del informe igual que el servidor.

## Pruebas ejecutadas (datos ficticios)

| Prueba | Resultado |
|---|---|
| `tests/unit/report-cristian-publicadas.test.js` (nueva) | **10/10** |
| `tests/unit/report-cristian-pdf.test.js` (nueva; texto del PDF con `pdftotext`) | **2/2** |
| `tests/unit/report-engine.test.js` (actualizada a la regla nueva) | **39/40** de su archivo |
| `tests/e2e/run_informe_cristian_publicadas.py` (demo, Chromium) | **5/5** |
| Build de producción + guardián | OK |

- **`report-cristian-publicadas`:**
  - hoja publicada con **todas** las entregas pendientes → 3 envíos, $33.000, 3 pendientes y 0 entregados;
  - hoja **antigua** de 2025;
  - completar después: mismos totales y mismo período;
  - borrador y cancelada excluidas; sin duplicados;
  - importe de envío y no mercadería;
  - límites 23:59 / 00:00 de Mendoza;
  - 7 días, 15 días, mes y libre;
  - fecha histórica desde `audit_log` y hoja sin fecha excluida e informada;
  - contenido del correo con los mismos números.
- **`report-cristian-pdf`:** el PDF nuevo trae el criterio, los envíos con su estado y el mismo total; un informe guardado antes se reimprime igual.
- **`report-engine`:** de las 41 pruebas, la única que falla es REPORT-MAIL-12, que **ya fallaba igual en el commit publicado** (programación mensual, fuera de alcance; verificado corriendo las pruebas originales).
- **E2E:**
  - hoja de Cristian recién publicada con todo pendiente → **+3 envíos y +$33.000** en pantalla;
  - criterio y estados explicados;
  - **Excel descargado = pantalla** (30 envíos, $320.000);
  - informe generado guardado con el criterio nuevo y los mismos números;
  - completar luego entregas no cambia los totales.

## Pendientes
- **Pruebas de Deno** (`npm run test:functions`, incluye `commercial-reports/handler.test.js`) y verificación de tipos de `index.ts`: Deno no está disponible en este entorno. Correrlas en el CI o con Codex.
- **Sin probar contra Supabase real.** En particular, cuántas hojas antiguas quedan sin `published_at` ni registro `ROUTE_PUBLISHED`: si las hay, aparecen listadas como "sin fecha de publicación" y no se incluyen.
- **Decisión de criterio a confirmar:** los envíos NO ENTREGADOS y REPROGRAMADOS de hojas publicadas **se cuentan** (con su importe informado) y se muestran aparte, para que el total no cambie según lo que marque el chofer. Si preferís excluirlos del importe, es un cambio puntual en `zoneTotals`.
- **"Mejores clientes":** ahora cuenta una compra por envío publicado; el ranking puede diferir de los informes anteriores.


---
# Corrección posterior (mismo ZIP)

## Qué estaba mal
1. **`tests/unit/report-cristian-pdf.test.js`:** un comentario dejaba el objeto incompleto, así que el archivo no compilaba y **sus 2 pruebas no se ejecutaban**. La entrega anterior las informó como 2/2 por error: esa corrida era anterior al último cambio.
2. **PDF, rótulo largo:** "Importe de envíos informado (no es dinero cobrado)" invadía el importe.
   - Al renderizar con importes grandes aparecieron además **textos largos que se salían de la página** y una **tabla por zona más ancha que la página**.
3. **`commercial-reports/index.ts`:** la consulta no tenía paginación, así que podía omitir hojas por el límite de filas del servidor.

## Cambios
- **PDF** (`_shared/report-pdf.js`):
  - en "Costo y resultado", el rótulo usa solo el ancho libre a la izquierda del importe y pasa a otra línea;
  - `text()` parte las líneas largas dentro del ancho útil;
  - las columnas de la tabla por zona suman exactamente el ancho útil (515 pt).
- **Carga completa** (`_shared/report-loader.js`, nuevo; lo usa `index.ts`):
  - **cursor:** paginación por id (`id > último`, orden estable), no por desplazamiento; el cursor toma el mayor id de cada página;
  - **sin cortes por límite:** el bucle sigue hasta recibir una página vacía, aunque el servidor devuelva menos filas que las pedidas;
  - **paradas y fechas históricas** (`audit_log` ROUTE_PUBLISHED, la primera publicación) con la misma técnica, por lotes;
  - **sin duplicados** de hojas ni paradas.
- **Criterio aprobado sin cambios:** se cuenta desde la publicación en hora de Mendoza, con las hojas antiguas incluidas. Pendientes, no entregados y reprogramados cuentan con su importe y se muestran aparte. Sin borradores ni canceladas. Los informes históricos se conservan como se generaron.

## Pruebas (código final; registros en `RESULTADOS/`)

**Ejecutadas y aprobadas:**

| Prueba | Resultado |
|---|---|
| `tests/unit/report-cristian-pdf.test.js` | **3/3** |
| `tests/unit/report-loader.test.js` (nueva) | **5/5** |
| `tests/unit/report-cristian-publicadas.test.js` | **10/10** |
| `tests/unit/report-engine.test.js` | **40/41** |
| Deno · `supabase/functions/commercial-reports` (Deno 2.9.6 instalado desde npm, solo en el entorno) | **10/11** |
| `deno check commercial-reports/index.ts` | sin errores de tipos |
| Build de producción + guardián | OK |

- **`report-cristian-pdf`:**
  - PDF-03 nuevo: con importes grandes, **ninguna palabra se superpone** con otra ni se sale del margen (cajas de `pdftotext -bbox`);
  - con el dibujo anterior, la prueba **falla** y detecta "cobrado) × $";
  - imagen renderizada: `RESULTADOS/pdf_importes_grandes.png`.
- **`report-loader`:** 50 hojas válidas y 265 paradas, con páginas de 7 y un servidor que devuelve como máximo 5:
  - sin pérdidas ni duplicados;
  - orden estable;
  - primera publicación desde `audit_log`;
  - una hoja borrada durante la carga no hace saltear otra;
  - las filas repetidas por el servidor no se duplican.
- **Deno:** se actualizó R-SCH-01, que esperaba el rótulo viejo "ENVÍOS COMPLETADOS" en el texto del correo; ahora exige "ENVÍOS INCLUIDOS (hojas publicadas)".

**Fallidas (preexistentes, no causadas por este cambio):**
- **REPORT-MAIL-12** (vitest) y **REPORT-MAIL-12b** (Deno), programación del informe mensual: fallan igual en el commit publicado 894a5f7.
- Registros: `report_engine_commit_original.log` y `deno_commercial_reports_commit_original.log`.
- Fuera de alcance; no se tocaron.

**No ejecutadas:** ninguna prueba contra Supabase real, por lo que no se verificó el límite real de filas ni la cantidad de hojas antiguas sin fecha.

## Pendientes
- **Probar en un entorno de staging** con la base real: tiempos de la carga completa y hojas sin `published_at` ni registro ROUTE_PUBLISHED, que se listan y no se incluyen.
- **Programación mensual** (REPORT-MAIL-12/12b): falla preexistente, para revisar aparte.
