# Límites y costos (documentación oficial consultada el 29/10/2026)

Los límites de los proveedores pueden cambiar sin aviso: **revisarlos antes de activar**.

## Google OAuth y verificación
- **Modo "Testing":** en *Testing* los tokens de actualización **vencen a los 7 días**; en *In production* en general no vencen salvo revocación o unos 6 meses sin uso. Fuente: documentación de Google para desarrolladores (configuración de OAuth y comportamiento de los tokens).
- **`gmail.send`:** es un permiso **sensible**. Una app sin verificar que lo usa muestra la **pantalla de "app no verificada"** y queda sujeta a un **tope de 100 usuarios nuevos**. Fuente: https://support.google.com/cloud/answer/13463817
- **Excepción de uso personal (con condiciones):** Google indica que las apps de **uso personal** (menos de 100 usuarios) pueden seguir usándose **sin verificación**, y que los usuarios aceptan la advertencia de "app no verificada". Fuente: https://support.google.com/cloud/answer/13464323
  - **Condiciones:** esto **no** es una exención automática por conectar una sola cuenta. Se aplica mientras la app sea de uso personal y limitado y cumpla la **Política de datos de usuario de los servicios de API de Google**, que rige estén o no verificadas.
  - **Google puede cambiar el criterio.** Si la app crece o Google lo requiere, habrá que pedir la verificación (marca, justificación de permisos y, para permisos sensibles, el proceso de revisión).
- **Este módulo:** pide solo `gmail.send` + `openid email` y conecta **una** cuenta propia. Quien conecta es el dueño de esa cuenta y acepta la advertencia.

## Gmail: volumen y velocidad
- **Límite de envío de la cuenta (Gmail gratuito):** al superar **500 correos en un día**, o 500 destinatarios en un correo, Gmail bloquea el envío entre 1 y 24 h. Fuente: https://support.google.com/mail/answer/22839
- **Cuota de Gmail API** (actualizada el 1/5/2026). Fuente: https://developers.google.com/workspace/gmail/api/reference/quota
  - **Proyectos creados desde el 1/5/2026:** **6.000 unidades por minuto por usuario por proyecto** y 1.200.000 por minuto por proyecto. `messages.send` consume **100 unidades**, o sea **hasta 60 envíos por minuto** con una cuenta.
  - **Proyectos anteriores:** los que usaron la API entre noviembre de 2025 y abril de 2026 **conservan sus cuotas anteriores**, que se expresaban por segundo (250 unidades por usuario por segundo).
  - **Umbral diario de facturación:** 80.000.000 unidades por día por proyecto. Google anunció que superar las cuotas podrá generar cargos más adelante en 2026, con aviso previo; el uso de este módulo queda muy por debajo.
  - **Destinatarios:** la API admite hasta 500 destinatarios por mensaje. El módulo envía **uno** por correo.
- **Tamaño:** **25 MB por correo**, incluidos los adjuntos codificados (base64, alrededor de un 33 % más). Fuente: ayuda de Gmail sobre adjuntos.

## Cómo los respeta el módulo
- **Velocidad:** **limitador COMPARTIDO en la base de datos** (`comm_rate_acquire`) para la cuenta conectada.
  - **Ventanas:** dos a la vez: **6.000 unidades en 60 s** (60 envíos por minuto) y **200 unidades en 1 s** (2 envíos por segundo). La segunda respeta también el criterio por segundo de los proyectos anteriores.
  - **Alcance:** vale para **todos los trabajadores a la vez** y para las **pruebas**. Se pide cupo antes de **cada** llamada real a `messages.send`, incluida la que se repite tras renovar el token.
  - **Configuración:** `COMM_GMAIL_UNITS_PER_MIN` y `COMM_GMAIL_UNITS_PER_SEC`. Si la consola de Google muestra una cuota menor para el proyecto, ajustar esos valores.
  - **Sin pausa fija:** ya no hay una pausa por trabajador, porque una pausa independiente no garantiza el límite conjunto.
  - **Orden de cada llamada real:** **1) token** (obtener o renovar) → **2) cupo compartido** → **3) verificación final** (cancelación, pausa, conexión y destinatario) → **4) llamada**, sin esperas en el medio.
  - **Por qué ese orden:** el cupo se reserva **después** del token, así la reserva representa el momento real del envío. Si la espera por cupo deja el token por vencer, el cupo se **devuelve**, se renueva el token y se vuelve a reservar.
- **Tope diario de seguridad:** **400** (`COMM_DAILY_CAP`).
  - **Atómico:** se reserva en la base de datos dentro de la misma reserva de envíos.
  - **Qué cuenta:** enviados, **en curso** y **inciertos** (por verificar) de las últimas 24 h, incluidas las pruebas.
  - **Concurrencia:** probado con dos trabajadores simultáneos.
- **Lo que NO cuenta:** los correos que esa cuenta envíe **por fuera del módulo**, como mails manuales o de otras apps. Google aplica su límite a **todo** lo que envía la cuenta. Por eso se recomienda una cuenta **dedicada** solo a comunicados.
- **Ventana de envío:** 6 h desde el horario programado (`COMM_SEND_WINDOW_HOURS`). Lo que no salió dentro de la ventana (pausa, desconexión o interrupción) queda **VENCIDO** para revisión, sin envío automático.
- **Adjuntos:**
  - **Límites:** 8 MB por archivo, 15 MB y 6 archivos por comunicado.
  - **Validación en el servidor:** contenido real, tamaño real y totales, con bloqueo.
  - **Tamaño del correo:** se estima y se muestra.

## Adjuntos sin referencias (huérfanos)
- **Sin limpieza automática:** los archivos subidos que nunca se registraron (por ejemplo, una carga interrumpida o un registro rechazado) **se conservan** en el bucket privado.
- **Por qué:** listar los huérfanos y borrarlos después no excluye que, en el medio, otro proceso registre ese mismo archivo. Es preferible conservar archivos de más que arriesgar un adjunto válido.
- **Diagnóstico:** `comm_orphan_objects(horas, límite)` (solo lectura, solo servidor) lista los objetos sin referencias y antiguos para revisarlos.
- **Borrado inmediato:** solo un archivo de **contenido inválido** que la base **confirma** como no registrado. Ese contenido nunca podría registrarse, porque el servidor lo rechaza siempre.
- **Costo:** acotado. Cada archivo pesa como máximo 8 MB y el bucket es privado. Una limpieza automática requerirá coordinar el registro y el borrado (por ejemplo, una marca de "en eliminación" verificada por el registro) y probarla con concurrencia real.

## Supabase
- **Pausa por inactividad:** "Supabase pausa los proyectos del plan gratuito que muestran poca actividad durante 7 días"; los proyectos pagos **no** se pausan. Un proyecto gratuito se considera inactivo si no recibe **suficiente actividad de base de datos de usuarios** en la semana. Fuente: https://supabase.com/docs/guides/platform/free-project-pausing
  - **Consecuencia:** si el proyecto se pausa, **la programación se detiene**. Lo vencido queda identificado como VENCIDO o PERDIDO al volver, sin envío masivo.
  - **Lo que no se sabe:** **no está garantizado** que las ejecuciones del programador cuenten como "actividad de usuarios". El uso diario de Despacho normalmente alcanza.
- **Funciones del plan gratuito:** incluye `pg_cron`, `pg_net`, Edge Functions y Storage. Confirmar las cuotas vigentes en https://supabase.com/pricing antes de activar.

## Costos
- **Google Cloud, Gmail API y OAuth:** USD 0 para este uso. No hace falta Google Workspace.
- **WhatsApp:** USD 0. Solo se comparte manualmente, sin WhatsApp API.
- **Supabase:** el plan actual alcanza si Despacho se usa a diario. Para eliminar el riesgo de pausa, el plan **Pro** (actualmente USD 25 por mes; confirmar en la página de precios). **No se activó nada pago.**

**No se promete gratuidad ilimitada.**
