// Genera dist/sw.js con el precache REAL del build (index, bundles JS/CSS de Vite, scripts legacy, manifest, íconos, splash, logo)
// y un nombre de caché derivado del contenido: cada build distinto instala un shell nuevo completo.
import { readdirSync, statSync, readFileSync, writeFileSync } from 'node:fs';
import { join, relative } from 'node:path';
import { createHash } from 'node:crypto';
const SKIP = [/^sw\.js$/, /\.map$/, /^splash\.png$/]; // splash.png no se usa (la app usa splash.webp)
export function listDist(dir, root = dir, out = []) {
  for (const n of readdirSync(dir).sort()) { const p = join(dir, n), rel = relative(root, p).split('\\').join('/');
    if (statSync(p).isDirectory()) listDist(p, root, out); else if (!SKIP.some(r => r.test(rel))) out.push(rel); }
  return out;
}
export function buildServiceWorker(distDir) {
  const files = listDist(distDir), h = createHash('sha256');
  files.forEach(f => { h.update(f); h.update(readFileSync(join(distDir, f))); });
  const version = h.digest('hex').slice(0, 12);
  const precache = ['/', ...files.map(f => '/' + f)];
  const tpl = readFileSync(join(distDir, 'sw.js'), 'utf8');
  if (!tpl.includes('/*__OKD_PRECACHE__*/') || !tpl.includes('__OKD_SW_VERSION__')) return { version: null, precache: [] }; // ya generado
  writeFileSync(join(distDir, 'sw.js'), tpl.replace('/*__OKD_PRECACHE__*/[]', JSON.stringify(precache)).replace('__OKD_SW_VERSION__', version));
  return { version, precache };
}
export default function swPrecache() {
  let outDir = 'dist';
  return { name: 'okd-sw-precache', apply: 'build', configResolved(c) { outDir = c.build.outDir; }, closeBundle() { buildServiceWorker(join(process.cwd(), outDir)); } };
}
