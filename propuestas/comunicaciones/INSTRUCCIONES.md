# Comunicaciones internas · servidor y OAuth (NO aplicado)

Nada de esto se ejecutó en producción. Hacerlo **en este orden**, primero en un entorno de prueba.

## 0. Antes de empezar
- **Cuenta:** una cuenta **@gmail.com personal gratuita** dedicada (por ejemplo `comunicados.okaccesorios@gmail.com`), independiente de GitHub. Despacho **nunca** pide su contraseña.
- **Límites y costos:** leer `LIMITES_Y_COSTOS.md`. El riesgo de pausa del proyecto Supabase en plan gratuito afecta a la programación.

## 1. Google Cloud (gratuito)
1. **Proyecto:** crear uno en <https://console.cloud.google.com/> con la cuenta Gmail dedicada.
2. **API:** en **APIs y servicios → Biblioteca**, habilitar **Gmail API**.
3. **Pantalla de consentimiento** (*Google Auth Platform*):
   - **Tipo de usuario:** **Externo**.
   - **Datos de la app:** nombre "OK Despacho · Comunicaciones" y correo de soporte (la cuenta dedicada).
   - **Permisos:** `https://www.googleapis.com/auth/gmail.send`, `openid` y `email`. **Nada más**: no se lee el buzón.
4. **Estado de publicación:** **"En producción"**, sin pedir verificación, porque es uso personal: una sola cuenta.
   - **No dejarla en "Testing":** ahí el token **vence a los 7 días** y los envíos se cortarían cada semana.
   - **Advertencia esperada:** al conectar aparece "Google no verificó esta app". Quien conecta (el dueño de la cuenta) elige *Avanzado → Ir a OK Despacho*.
5. **Credenciales:** *ID de cliente OAuth* → **Aplicación web**.
   - **URI de redireccionamiento autorizado (exacta, sin parámetros):** `https://<PROJECT_REF>.supabase.co/functions/v1/comm-gmail-oauth/callback`.
   - **Guardar el ID y el secreto:** **no** van al repositorio, al ZIP ni a chats; solo a los secretos de Supabase (paso 2).

## 2. Secretos de Supabase (Edge Functions → Secrets)
- **De Google:** `GOOGLE_CLIENT_ID` y `GOOGLE_CLIENT_SECRET`.
- **`COMM_OAUTH_REDIRECT_URI`:** la misma URI del paso 1.5.
- **De la app:**
  - **`COMM_APP_URL`:** URL pública de la app, por ejemplo `https://admin-despacho.github.io/`.
  - **`COMM_APP_ORIGIN`:** el origen de la app, por ejemplo `https://admin-despacho.github.io`.
- **`COMM_CRON_SECRET`:** un valor largo y aleatorio, el mismo que se guarda en Vault en el paso 5.
- **Opcionales:** `COMM_DAILY_CAP` (400 por defecto, por debajo del límite de 500 de Gmail; **no** cuenta correos enviados por fuera del módulo), `COMM_BATCH` (25) y `COMM_SEND_WINDOW_HOURS` (6: lo que no salió en ese plazo queda VENCIDO para revisión), y `COMM_GMAIL_UNITS_PER_MIN` (6000) y `COMM_GMAIL_UNITS_PER_SEC` (200) para el limitador compartido de velocidad (ver `LIMITES_Y_COSTOS.md`).

## 3. Base de datos
1. **Probar en el entorno de prueba:** `bash propuestas/comunicaciones/run_comms_tests.sh`. Esperado: **127/127, exit 0**. Usa Vault **simulado** y los **privilegios por defecto equivalentes a producción**, solo local.
2. **Migración:** copiar `20261112000100_comunicaciones.sql` a `supabase/migrations/`, agregarla al final de `tests/sql/migration_order.txt` y aplicarla con autorización.
   - **Qué crea:** permisos, tablas con RLS, el bucket privado `comm-attachments` y las funciones.
   - **Vault:** usa el **Vault real** de Supabase, ya instalado. **No** aplicar `vault_stub_solo_pruebas.sql` ni `privilegios_produccion_solo_pruebas.sql` en Supabase.
   - **Privilegios:** revoca **todo** lo heredado sobre sus tablas, secuencias y funciones nuevas y concede solo lo necesario. No cambia los privilegios globales ni los de otros módulos.
3. **Verificar los privilegios después de aplicar.** Esperado: `authenticated` solo SELECT en 8 tablas y `anon` en ninguna:
   ```sql
   select c.relname, r.rol, p.priv from pg_class c cross join (values ('anon'),('authenticated')) r(rol)
     cross join (values ('SELECT'),('INSERT'),('UPDATE'),('DELETE'),('TRUNCATE'),('REFERENCES'),('TRIGGER')) p(priv)
    where c.relnamespace = 'public'::regnamespace and c.relkind = 'r' and c.relname like 'comm\_%' and has_table_privilege(r.rol, 'public.' || c.relname, p.priv);
   ```

## 4. Funciones
- **Desplegar:** `supabase functions deploy comm-gmail-oauth`, `supabase functions deploy comm-dispatcher` y `supabase functions deploy comm-attachments`.
- **`comm-attachments`:** es el **único** camino para registrar adjuntos (valida contenido, tamaño y hash en el servidor). Lleva `verify_jwt = true`.
- **`verify_jwt = false` en las dos** (ya figura en `supabase/config.toml`):
  - **OAuth:** las acciones de usuario validan la sesión y el permiso adentro.
  - **Despachador:** exige el encabezado secreto.

## 5. Programador (propio; no toca otros correos)
- **Extensiones:** habilitar `pg_cron` y `pg_net` (Database → Extensions).
- **Secreto:** `select vault.create_secret('<mismo valor que COMM_CRON_SECRET>', 'comm_cron_secret', 'Comunicaciones');`
- **Trabajo programado:** ejecutar `01_programador_comunicaciones.sql` reemplazando `<PROJECT_REF>`. Corre cada 5 minutos.
- **Verificación:** en *Comunicaciones → Conexión Gmail*, "Automatización" pasa a **Operativa** recién cuando el programador registra una ejecución reciente.

## 6. App
- **Publicar** el build que incluye el módulo.
- **Permisos:** el **Admin** tiene los seis `comms.*` por rol. A otros usuarios se les otorgan **individualmente** en *Usuarios → PERMISOS → Comunicaciones*.
- **Conectar Gmail:** con el permiso "administrar la conexión Gmail", en *Comunicaciones → Conexión Gmail → CONECTAR GMAIL*. Se elige la cuenta dedicada en Google.

## 7. Prueba real acotada
Seguir `PRUEBA_REAL_ACOTADA.md`. **No** programar comunicaciones reales hasta aprobar contenido, destinatarios y horarios.

## Reversión
- `select cron.unschedule('okd-comunicaciones-despachador');` detiene los envíos automáticos.
- **DESCONECTAR** en la app revoca el permiso en Google y borra el token de Vault.
- Quitar los permisos `comms.*` oculta el módulo. Los datos y el historial quedan.
