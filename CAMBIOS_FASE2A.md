# CAMBIOS — Fase 2A (0.2.0-fase2a): Informe comercial de Cristian Torres + email

Base: Fase 1.1 aprobada (sin cambios en su lógica ni en su imagen). Estado: **NO LISTO PARA PUBLICAR**.

## Qué se agregó
- **INFORMES → CRISTIAN TORRES** (botón "Informes" en la cabecera, solo con permiso). Orden aprobado:
  1. PERÍODO A ANALIZAR: 7 DÍAS · 15 DÍAS · MES (mes calendario a elección) · LIBRE (desde/hasta, muestra los días).
  2. CUANTIFICACIÓN POR ZONA · ENVÍOS + INGRESOS: Zona Este, Alrededores y Centro **siempre separados**, más TOTAL GENERAL.
  3. ¿EL TRANSPORTE SE PAGA SOLO?: ingreso por zona, total, costo, diferencia, ¿cubre? → CUBRE / NO CUBRE · Sobran / Faltan.
  4. MEJORES CLIENTES: compras, frecuencia promedio, última compra y facturación, sin inventar margen.
  5. CLIENTES A RECUPERAR: prioridad contra la frecuencia propia de cada cliente; estados CONTACTAR HOY / RECUPERAR / ATRASADO / SEGUIMIENTO; alertas +30/+60/+90 días.
  6. ZONAS A REFORZAR: REFORZAR REPARTO / RECUPERAR COMERCIALMENTE / MANTENER, siempre con el "por qué" en números.
- **HISTORIAL**: filtros Semanal / Mensual / Manual, período y enviado / no enviado. Acciones VER, DESCARGAR PDF, ENVIAR / REENVIAR EMAIL y REINTENTAR.
- **CONFIGURACIÓN**:
  - costo mensual con vigencias (inicial ARS 1.600.000);
  - destinatarios y hora del mensual (default 23:30);
  - exigir PDF adjunto;
  - en modo demo, además: simulación del envío programado y bandeja de salida con vista del email.

## Reglas implementadas
- **Hojas que cuentan:**
  - solo las FINALIZADAS (`operational_status = COMPLETADA`); PUBLICADA y EN CURSO no suman;
  - fecha que manda: `completed_at`, la finalización real, en hora de America/Argentina/Mendoza.
- **Envíos completados:**
  - ENTREGADO y ENTREGA PARCIAL son completados y suman ingreso de envío;
  - NO ENTREGADO y REPROGRAMAR no son completados y no suman ingreso.
- **Ingreso:** es exclusivamente el servicio de envío, con la `shipping_fee` congelada en la parada al publicar. La mercadería y las cobranzas nunca suman.
- **Costo:**
  - prorrateo por día: cada día vale (costo mensual vigente) / (días de ese mes);
  - un mes completo es exactamente el costo mensual;
  - el semanal toma 7 días.
- **Informe semanal:** se envía el sábado a las 15:00 (Mendoza). La ventana va del sábado anterior 15:00 a ese sábado 15:00: no tiene huecos ni duplicados, y una hoja que se finaliza después de las 15:00 entra en el informe siguiente. El asunto muestra lunes a sábado ("05 al 10/10/2026") y el cuerpo aclara la ventana exacta.
- **Informe mensual:** mes calendario, generado el último día a la hora configurada.
- **Idempotencia:**
  - clave `tipo|desde|hasta|destinatario|vN`; un cron repetido, un reintento, un refresh o un redeploy no duplican;
  - REENVIAR desde Admin es explícito (`|reenvio-n`);
  - se guarda `queued_at`, `sent_at`, `provider_id`, `status`, `error` y `retry_count`.
- **Si falla el PDF:** el informe queda en `PDF_ERROR`, no se envía un informe incompleto y se puede reintentar desde Admin; el PDF se rehace desde el snapshot.
- **Histórico:**
  - el snapshot es inmutable (trigger en la base); los cambios futuros de costo o tarifa no modifican el informe ni el PDF guardados;
  - corregir un período = generar una versión nueva.
- **Permisos:**
  - `can_view_commercial_transport_reports` permite ver; `can_manage_commercial_transport_reports` permite generar, enviar y configurar (por defecto, solo ADMIN);
  - Cristian ve las paradas de sus hojas, pero no costos, rankings ni emails.

## Técnico
- Migración incremental `20261010000100_fase2a_informe_cristian.sql`:
  - `route_stops` con resultado, tarifa congelada, mercadería y cobranza separadas;
  - `transport_cost_settings` más `set_transport_cost()`;
  - `report_settings`, `commercial_reports` (snapshot inmutable) y `report_emails` (clave única);
  - permisos y RLS.
- Edge Function `commercial-reports`, con las acciones preview, history, get, pdf, generate, send, resend, retry, settings y cost, más `scheduled` para el cron con `x-cron-secret`.
- Motor único `_shared/report-engine.js`, compartido por la pantalla, la Edge Function, el email y el PDF.
- Email HTML compatible (`_shared/report-email.js`): tablas, estilos en línea, sin JavaScript ni fuentes externas, máximo 700 px. Incluye versión en texto plano.
- PDF liviano con pdf-lib (`_shared/report-pdf.js`), con las 12 secciones pedidas y unos 9 KB.
- Cron: `supabase/sql/cron_commercial_reports.sql` (pg_cron + pg_net cada 15 min; la función decide si corresponde).

## Pendiente / a confirmar
- **Modelo visual V8**: `MODELO_INFORME_CRISTIAN_FILTROS_CLIENTES_ZONAS_V8.html` **no llegó en los archivos**. La pantalla se armó desde la especificación escrita y con la estética de la offline. Cuando lo subas, ajusto la paridad visual.
- **Origen real de los datos**: las paradas con resultado las va a cargar el recorrido de Cristian (FINALIZAR HOJA), que es la Fase 2B. Hasta entonces el informe online no tiene datos reales; el modo demo usa datos de demostración.
- **Fase 2 del plan original** (publicación en vivo, celular del transportista, notificaciones, rutas internas con aprobación): sigue pendiente (Fase 2B).
