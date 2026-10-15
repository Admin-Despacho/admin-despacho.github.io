import { existsSync, readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';

const distMode = process.argv.includes('--dist');
const fail = msg => { console.error('PRODUCTION_CARRIER_FLOW_FAIL:', msg); process.exitCode = 1; };
const mustContain = (s, needle, label) => { if (!s.includes(needle)) fail(label + ' missing: ' + needle); };
const mustNotContain = (s, needle, label) => { if (s.includes(needle)) fail(label + ' still contains forbidden legacy pattern: ' + needle); };
const sha = p => createHash('sha256').update(readFileSync(p)).digest('hex');

if (!distMode) {
  const canonical = 'public/legacy/despacho-v15.js';
  if (!existsSync(canonical)) fail('canonical production constructor missing: ' + canonical);
  if (existsSync('legacy/despacho-v15.js')) fail('duplicate constructor exists at legacy/despacho-v15.js');
  if (existsSync('docs/legacy/despacho-v15.js')) fail('stale duplicate constructor exists at docs/legacy/despacho-v15.js');

  const legacy = readFileSync(canonical, 'utf8');
  mustContain(legacy, 'type="radio" name="route_carrier"', 'single carrier selector');
  mustNotContain(legacy, '<label class="carrier"><input type="checkbox"', 'carrier selector');
  mustContain(legacy, 'DESPACHAR E IMPRIMIR', 'external carrier action');
  mustContain(legacy, 'dispatchExternal(pl)', 'external dispatch RPC');
  mustContain(legacy, "carrier.kind === 'EXTERNO'", 'external classification');
  mustContain(legacy, "carrier.report_group !== 'CRISTIAN_TORRES'", 'Cristian special-case');

  const main = readFileSync('src/main.js', 'utf8');
  mustContain(main, 'Date.now()', 'fresh constructor cache-buster');
  mustContain(main, 'despacho-v15', 'constructor loader');

  const html = readFileSync('index.html', 'utf8');
  mustContain(html, 'id="btnPrint" type="button" hidden', 'standalone print hidden');
  mustContain(html, 'id="btnPdf" type="button" hidden', 'standalone PDF hidden');
  console.log('PRODUCTION_CARRIER_FLOW_SOURCE_PASS');
} else {
  const src = 'public/legacy/despacho-v15.js';
  const built = 'dist/legacy/despacho-v15.js';
  if (!existsSync(built)) fail('built constructor missing: ' + built);
  if (existsSync(src) && sha(src) !== sha(built)) fail('dist constructor differs from canonical public constructor');

  const legacy = readFileSync(built, 'utf8');
  mustContain(legacy, 'type="radio" name="route_carrier"', 'built single carrier selector');
  mustContain(legacy, 'DESPACHAR E IMPRIMIR', 'built external carrier action');
  mustContain(legacy, 'dispatchExternal(pl)', 'built external dispatch RPC');

  const sw = readFileSync('dist/sw.js', 'utf8');
  mustContain(sw, '/legacy/despacho-v15.js', 'service-worker precache');

  const html = readFileSync('dist/index.html', 'utf8');
  mustContain(html, 'id="btnPrint" type="button" hidden', 'built standalone print hidden');
  mustContain(html, 'id="btnPdf" type="button" hidden', 'built standalone PDF hidden');
  console.log('PRODUCTION_CARRIER_FLOW_DIST_PASS');
}

if (process.exitCode) process.exit(process.exitCode);
