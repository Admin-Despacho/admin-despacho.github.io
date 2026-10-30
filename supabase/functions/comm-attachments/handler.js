// =====================================================================================================================
// COMUNICACIONES · registro de adjuntos validado EN EL SERVIDOR. El navegador solo sube el archivo al bucket privado; acá se descarga
// con credenciales de servidor y se valida: tamaño REAL, formato por CONTENIDO (no por extensión ni tipo declarado) y hash propio.
// Límites acumulados y confirmación (comunicado activo/pausado) los aplica la función SQL bajo bloqueo de la fila del comunicado.
// =====================================================================================================================
import { sniffType, ATTACH } from '../_shared/comms-core.js';
const EXT = { 'image/png': 'png', 'image/jpeg': 'jpg', 'image/webp': 'webp', 'image/gif': 'gif', 'application/pdf': 'pdf' };
const json = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } });
const hex = async b => [...new Uint8Array(await crypto.subtle.digest('SHA-256', b))].map(x => x.toString(16).padStart(2, '0')).join('');

export async function handle(req, deps) {
  if (req.method !== 'POST') return json({ error: 'METODO' }, 405);
  let body = {}; try { body = await req.json(); } catch (e) { return json({ error: 'JSON_INVALIDO' }, 400); }
  const user = deps.userClient(req.headers.get('Authorization') || ''), svc = deps.serviceClient();
  const { data: can } = await user.rpc('comm_can', { p_perm: 'comms.compose' });
  if (!can) return json({ error: 'FORBIDDEN' }, 403);
  const { data: u } = await user.auth.getUser(); const actor = u && u.user && u.user.id;
  const mid = String(body.message_id || ''), path = String(body.path || ''), name = String(body.file_name || 'adjunto').slice(0, 180);
  const m = path.match(new RegExp('^messages/' + mid.replace(/[^0-9a-f-]/gi, '') + '/[0-9a-f-]{36}\\.(png|jpg|webp|gif|pdf)$'));
  if (!mid || !m) return json({ error: 'RUTA_INVALIDA' }, 400);
  const bucket = svc.storage.from('comm-attachments');
  // se borra SOLO si la base CONFIRMA que la ruta no está referenciada (ni adjunto, ni copia, ni historial). Ante cualquier duda, se conserva.
  const dropIfUnregistered = async () => {
    try { const { data, error } = await svc.rpc('comm_attachment_registered', { p_path: path }); if (error || data !== false) return false;
      await bucket.remove([path]); return true; } catch (e) { return false; } };
  const { data: blob, error: de } = await bucket.download(path);
  if (de || !blob) return json({ error: 'ARCHIVO_NO_SUBIDO' }, 400);
  const bytes = new Uint8Array(await blob.arrayBuffer());
  if (!bytes.length || bytes.length > ATTACH.maxFileBytes) { await dropIfUnregistered(); return json({ error: 'TAMANIO_NO_PERMITIDO', max: ATTACH.maxFileBytes }, 400); }
  const real = sniffType(bytes);
  if (!real || EXT[real] !== m[1]) { await dropIfUnregistered(); return json({ error: 'CONTENIDO_NO_PERMITIDO', detalle: 'El archivo no es una imagen PNG/JPG/WEBP/GIF ni un PDF válido (o la extensión no coincide con su contenido).' }, 400); }
  // registro IDEMPOTENTE: repetir devuelve el adjunto existente
  let res;
  try { res = await svc.rpc('comm_register_attachment_srv', { p_message: mid, p_path: path, p_name: name, p_mime: real, p_size: bytes.length, p_sha: await hex(bytes), p_actor: actor, p_confirm: !!body.confirm }); }
  catch (e) { res = { error: { message: String(e && e.message || e), code: '' } }; }
  const { data, error } = res;
  if (!error) return json({ attachment: data });
  // error DEFINITIVO de la base (tiene código SQL): el registro no ocurrió → se informa; el objeto queda y la limpieza de huérfanos (> 24 h) decide
  // error SIN código (corte, tiempo agotado): INCIERTO, el registro pudo confirmarse y perderse la respuesta → se conserva y se pide reintentar
  if (!/^[0-9A-Z]{5}$/.test(String(error.code || ''))) return json({ error: 'RESULTADO_INCIERTO', detalle: 'No se pudo confirmar el registro. El archivo se conservó: reintentá (no se duplica).' }, 503);
  const code = (String(error.message).match(/^[A-Z_]+/) || ['ERROR'])[0];
  return json({ error: code, detalle: String(error.message).slice(0, 200) }, code === 'FORBIDDEN' ? 403 : 400);
}
