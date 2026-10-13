// Restauración de un backup de OK Despacho (ZIP descomprimido en una carpeta). Se ejecuta en la PC del administrador, nunca en el navegador.
//   Verificar (no escribe nada):           node scripts/restore_backup.mjs <carpeta> --verify
//   Restaurar en un proyecto de PRUEBA:     RESTORE_TARGET=PRUEBA SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... node scripts/restore_backup.mjs <carpeta> --restore
// Requisitos: proyecto de PRUEBA con TODAS las migraciones aplicadas. No borra nada (solo inserta/actualiza).
// Orden: 1) identidades de Auth (sin contraseñas)  2) tablas de public (orden del manifest)  3) archivos de Storage.
// Identidades: profiles.id → auth.users(id). Se intenta crear cada usuario con su UUID original (Admin Auth API, campo id).
// Si el proyecto devuelve otro UUID, se arma un mapa viejo → nuevo y se reemplaza ese UUID en TODOS los datos antes de cargarlos
// (reemplazo de valores exactos en todas las tablas), para que FKs e historial sigan apuntando a la persona correcta.
// Las contraseñas NUNCA se exportan ni se copian: cada usuario define la suya con un enlace de recuperación (--send-reset).
import { readFileSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join } from 'node:path';

const sha = b => createHash('sha256').update(b).digest('hex');
const readJson = (dir, f) => JSON.parse(readFileSync(join(dir, f), 'utf8'));
export function verifyBackup(dir) {
  const m = readJson(dir, 'manifest.json'), data = readJson(dir, 'data.json');
  const problems = [];
  for (const [t, info] of Object.entries(m.tables || {})) {
    if (!(t in data)) { problems.push('falta la tabla ' + t); continue; }
    if (sha(JSON.stringify(data[t] ?? null)) !== info.sha256) problems.push('hash distinto en la tabla ' + t);
  }
  if (m.auth_users) {
    if (!existsSync(join(dir, 'auth_users.json'))) problems.push('falta auth_users.json');
    else if (sha(JSON.stringify(readJson(dir, 'auth_users.json'))) !== m.auth_users.sha256) problems.push('hash distinto en auth_users.json');
  }
  let files = 0;
  for (const [bucket, list] of Object.entries(m.storage_files || {})) for (const f of list) {
    const p = join(dir, 'storage', bucket, f.name); files++;
    if (!existsSync(p)) { problems.push('falta el archivo ' + bucket + '/' + f.name); continue; }
    if (sha(readFileSync(p)) !== f.sha256) problems.push('hash distinto en ' + bucket + '/' + f.name);
  }
  return { ok: problems.length === 0, problems, tables: Object.keys(m.tables || {}).length, files, order: m.order || Object.keys(m.tables || {}) };
}
export function remapIds(value, map) {
  if (!map.size) return value;
  if (typeof value === 'string') return map.has(value) ? map.get(value) : value;
  if (Array.isArray(value)) return value.map(v => remapIds(v, map));
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, remapIds(v, map)]));
  return value;
}
export async function restoreIdentities(admin, users) {
  const map = new Map(), report = { created: 0, kept: 0, existing: 0, remapped: 0 };
  for (const u of users) {
    const attrs = { id: u.id, email: u.email || undefined, phone: u.phone || undefined, email_confirm: !!u.email_confirmed_at };
    const r = await admin.auth.admin.createUser(attrs);
    if (r.error) {
      if (!/already|exists|registered/i.test(r.error.message)) throw new Error('auth ' + u.email + ': ' + r.error.message);
      const found = await findUserByEmail(admin, u.email); if (!found) throw new Error('auth ' + u.email + ': existe pero no se encuentra');
      report.existing++; if (found.id !== u.id) { map.set(u.id, found.id); report.remapped++; }
      continue;
    }
    report.created++;
    if (r.data.user.id !== u.id) { map.set(u.id, r.data.user.id); report.remapped++; } else report.kept++;
  }
  return { map, report };
}
async function findUserByEmail(admin, email) {
  for (let page = 1; ; page++) {
    const r = await admin.auth.admin.listUsers({ page, perPage: 1000 });
    if (r.error) throw new Error(r.error.message);
    const f = r.data.users.find(x => (x.email || '').toLowerCase() === (email || '').toLowerCase());
    if (f) return f;
    if (r.data.users.length < 1000) return null;
  }
}
export async function restore(dir, admin, opts = {}) {
  if (process.env.RESTORE_TARGET !== 'PRUEBA') throw new Error('Por seguridad: definí RESTORE_TARGET=PRUEBA (restaurar primero en un proyecto de prueba).');
  const v = verifyBackup(dir); if (!v.ok) throw new Error('El backup no pasa la verificación: ' + v.problems.join('; '));
  const m = readJson(dir, 'manifest.json'), data = readJson(dir, 'data.json');
  const users = existsSync(join(dir, 'auth_users.json')) ? readJson(dir, 'auth_users.json') : [];
  const { map, report } = await restoreIdentities(admin, users);
  for (const t of v.order) {
    const rows = remapIds(data[t], map);
    if (!Array.isArray(rows) || !rows.length) continue;
    for (let i = 0; i < rows.length; i += 500) {
      const r = await admin.from(t).upsert(rows.slice(i, i + 500));
      if (r.error) throw new Error(t + ': ' + r.error.message);
    }
  }
  for (const [bucket, list] of Object.entries(m.storage_files || {})) for (const f of list) {
    const r = await admin.storage.from(bucket).upload(f.name, readFileSync(join(dir, 'storage', bucket, f.name)), { upsert: false });
    if (r.error && !/exists/i.test(r.error.message)) throw new Error(bucket + '/' + f.name + ': ' + r.error.message);
  }
  if (opts.sendReset) for (const u of users) if (u.email) await admin.auth.resetPasswordForEmail(u.email);
  return report;
}
if (process.argv[1] && process.argv[1].endsWith('restore_backup.mjs')) {
  const [dir, mode, extra] = process.argv.slice(2);
  if (!dir) { console.error('Uso: node scripts/restore_backup.mjs <carpeta> --verify | --restore [--send-reset]'); process.exit(2); }
  if (mode === '--restore') {
    (async () => {
      if (process.env.RESTORE_TARGET !== 'PRUEBA') throw new Error('Por seguridad: definí RESTORE_TARGET=PRUEBA (restaurar primero en un proyecto de prueba).');
      const { createClient } = await import('@supabase/supabase-js');
      const admin = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });
      console.log(JSON.stringify(await restore(dir, admin, { sendReset: extra === '--send-reset' })));
      console.log('Restauración terminada en el proyecto de PRUEBA. Validá login, hojas, PDF e informes antes de cualquier decisión sobre producción.');
    })().catch(e => { console.error(e.message); process.exit(1); });
  } else {
    const v = verifyBackup(dir); console.log(JSON.stringify(v, null, 1)); process.exit(v.ok ? 0 : 1);
  }
}
