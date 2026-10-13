// DELIVERY_MANIFEST.json: archivos reales con SHA-256, versión, migraciones, Edge Functions y tests.
import { readFileSync, readdirSync, statSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join, relative } from 'node:path';
const SKIP = new Set(['node_modules', 'dist', '.git', 'out']);
const SELF = 'DELIVERY_MANIFEST.json';
export function listFiles(root, dir = root, out = []) {
  for (const n of readdirSync(dir).sort()) {
    const p = join(dir, n), rel = relative(root, p).split('\\').join('/');
    if (SKIP.has(n) || rel === SELF) continue;
    if (statSync(p).isDirectory()) listFiles(root, p, out); else out.push(rel);
  }
  return out;
}
export const sha256File = p => createHash('sha256').update(readFileSync(p)).digest('hex');
export function buildManifest(root, extra = {}) {
  const pkg = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'));
  const files = listFiles(root);
  return {
    name: 'OK_DESPACHO_ONLINE', version: pkg.version, generated_at: extra.generated_at || new Date().toISOString(), status: extra.status || '',
    migrations: files.filter(f => /^supabase\/migrations\/.+\.sql$/.test(f)),
    edge_functions: [...new Set(files.filter(f => /^supabase\/functions\/[^_][^/]*\/index\.ts$/.test(f)).map(f => f.split('/')[2]))],
    tests: files.filter(f => /^tests\/.+\.(sql|js|mjs|py|sh)$/.test(f)),
    documents: files.filter(f => /\.md$/.test(f) && !f.includes('/')).concat(files.filter(f => /^docs\//.test(f))),
    files: Object.fromEntries(files.map(f => [f, sha256File(join(root, f))]))
  };
}
export function verifyManifest(root) {
  const problems = [];
  if (!existsSync(join(root, SELF))) return { ok: false, problems: ['falta ' + SELF] };
  const m = JSON.parse(readFileSync(join(root, SELF), 'utf8')), pkg = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'));
  if (m.version !== pkg.version) problems.push('versión distinta: manifest ' + m.version + ' / package ' + pkg.version);
  for (const [f, h] of Object.entries(m.files || {})) {
    if (!existsSync(join(root, f))) { problems.push('archivo listado inexistente: ' + f); continue; }
    if (sha256File(join(root, f)) !== h) problems.push('hash distinto: ' + f);
  }
  for (const f of [...(m.migrations || []), ...(m.tests || []), ...(m.documents || [])]) if (!existsSync(join(root, f))) problems.push('referencia inexistente: ' + f);
  for (const fn of m.edge_functions || []) if (!existsSync(join(root, 'supabase/functions', fn, 'index.ts'))) problems.push('Edge Function inexistente: ' + fn);
  const real = listFiles(root).filter(f => !(f in (m.files || {})));
  if (real.length) problems.push('archivos no listados: ' + real.slice(0, 5).join(', ') + (real.length > 5 ? '…' : ''));
  return { ok: problems.length === 0, problems, files: Object.keys(m.files || {}).length };
}
