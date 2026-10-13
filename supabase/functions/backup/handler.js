// Edge Function "backup": exporta datos + configuración + manifest con hashes + listado de Storage + README de restauración.
// Solo con settings.manage. No borra nada. La restauración se hace PRIMERO en un proyecto de prueba (ver README del backup).
import { json, withCors } from '../_shared/http.js';
import { BACKUP_TABLES } from './inventory.js';
export { BACKUP_TABLES };
export const RESTORE_README = [
  'OK Despacho · Backup', '',
  '1. Restaurar SIEMPRE primero en un proyecto Supabase de PRUEBA (nunca sobre producción). Requiere el proyecto con las migraciones aplicadas.',
  '2. Verificar el backup: node scripts/restore_backup.mjs <carpeta> --verify (hashes de tablas y archivos).',
  '3. Identidades: profiles.id referencia auth.users(id). El script recrea los usuarios de Auth (auth_users.json, SIN contraseñas) con su UUID original;',
  '   si la API no conserva el UUID, mapea UUID viejo → nuevo en TODAS las columnas que referencian usuarios antes de cargar. Los usuarios definen contraseña con un enlace de recuperación.',
  '4. Luego carga las tablas de public en el orden del manifest y por último los archivos de Storage.',
  '5. Storage: los archivos están en la carpeta storage/<bucket>/ del ZIP, con su SHA-256 en manifest.json. Subirlos con: node scripts/restore_backup.mjs <carpeta> (solo a un proyecto de PRUEBA).',
  '6. Validar login, hojas, PDFs e informes en prueba antes de cualquier decisión sobre producción.'
].join('\n');
async function sha256(text) { const b = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text)); return [...new Uint8Array(b)].map(x => x.toString(16).padStart(2, '0')).join(''); }
/** deps: { getUserFromJwt, userHasPerm(id, perm), dumpTable(name) → rows, listStorage() → { bucket: [names] }, audit(e), now() } */
export const BUCKETS = ['identity-docs', 'route-pdfs', 'commercial-reports'];
async function sha256Bytes(u8) { const b = await crypto.subtle.digest('SHA-256', u8); return [...new Uint8Array(b)].map(x => x.toString(16).padStart(2, '0')).join(''); }
function toB64(u8) { let t = ''; for (let i = 0; i < u8.length; i += 0x8000) t += String.fromCharCode(...u8.subarray(i, i + 0x8000)); return btoa(t); }
async function handleRaw(req, deps) {
  let body = {}; try { body = await req.clone().json(); } catch (e) { body = {}; }
  if (req.method !== 'POST') return json(405, { error: 'Método no permitido', code: 'METHOD' });
  const auth = req.headers.get('authorization') || '';
  const who = auth.startsWith('Bearer ') ? await deps.getUserFromJwt(auth.slice(7)) : null;
  if (!who) return json(401, { error: 'Sesión inválida.', code: 'NO_AUTH' });
  if (!(await deps.userHasPerm(who.id, 'settings.manage'))) return json(403, { error: 'Solo Administración genera backups.', code: 'FORBIDDEN' });
  // Archivo de Storage (uno por llamada): el cliente arma el ZIP con datos + archivos + manifest
  if (body && body.action === 'storage_file') {
    if (!BUCKETS.includes(body.bucket) || !body.name || String(body.name).includes('..')) return json(400, { error: 'Archivo inválido.', code: 'BAD_FILE' });
    const bytes = await deps.downloadObject(body.bucket, body.name);
    return json(200, { bucket: body.bucket, name: body.name, size: bytes.length, sha256: await sha256Bytes(bytes), base64: toB64(bytes) });
  }
  const data = {}, tables = {};
  for (const t of BACKUP_TABLES) { const rows = await deps.dumpTable(t); data[t] = rows; tables[t] = { rows: rows.length, sha256: await sha256(JSON.stringify(rows)) }; }
  const storage = await deps.listStorage();
  const authUsers = deps.listAuthUsers ? await deps.listAuthUsers() : []; // id, email, teléfono y confirmación: NUNCA contraseñas
  const manifest = { app: 'OK Despacho', created_at: new Date(deps.now ? deps.now() : Date.now()).toISOString(), created_by: who.id, order: BACKUP_TABLES, tables,
    storage: Object.fromEntries(Object.entries(storage).map(([b, list]) => [b, { objects: list.length, names: list }])) };
  manifest.auth_users = { count: authUsers.length, sha256: await sha256(JSON.stringify(authUsers)) };
  manifest.sha256 = await sha256(JSON.stringify(manifest.tables));
  await deps.audit({ actor_id: who.id, action: 'BACKUP_CREATED', target_type: 'backup', target_id: manifest.created_at, after: { tables: Object.keys(tables).length } });
  return json(200, { manifest, data, auth_users: authUsers, readme: RESTORE_README });
}
export const handle = withCors(handleRaw);

// Listado COMPLETO de un bucket: recorre carpetas y pagina cada prefijo con offset hasta agotar resultados (limit 1000 por página).
// listFn(bucket, prefix, { limit, offset }) → [{ name, id? }] (id nulo = carpeta)
export async function listAllObjects(listFn, bucket, prefix = '', pageSize = 1000) {
  const out = [];
  for (let offset = 0; ; offset += pageSize) {
    const page = await listFn(bucket, prefix, { limit: pageSize, offset, sortBy: { column: 'name', order: 'asc' } });
    for (const x of page) { const p = prefix ? prefix + '/' + x.name : x.name; if (x.id) out.push(p); else out.push(...await listAllObjects(listFn, bucket, p, pageSize)); }
    if (page.length < pageSize) break;
  }
  return out;
}
// Usuarios de Auth sin secretos (para recrear identidades en la restauración)
export function safeAuthUser(u) { return { id: u.id, email: u.email || null, phone: u.phone || null, email_confirmed_at: u.email_confirmed_at || null, created_at: u.created_at || null }; }
