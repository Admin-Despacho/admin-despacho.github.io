// Regenera DELIVERY_MANIFEST.json (correr al FINAL de la entrega): node scripts/build_manifest.mjs "<estado>"
import { writeFileSync } from 'node:fs';
import { buildManifest } from './manifest_lib.mjs';
const m = buildManifest(process.cwd(), { status: process.argv[2] || '' });
writeFileSync('DELIVERY_MANIFEST.json', JSON.stringify(m, null, 1) + '\n');
console.log('manifest:', m.version, Object.keys(m.files).length, 'archivos,', m.migrations.length, 'migraciones,', m.edge_functions.length, 'Edge Functions');
