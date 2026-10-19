// Guardián de publicación: el directorio que se sube a GitHub Pages DEBE ser el build de PRODUCCIÓN y nunca el demo.
// Verifica el MODO EFECTIVO del artefacto, no solo que aparezca el hostname:
//  1) estático: el entorno compilado trae VITE_SUPABASE_URL (host esperado) y VITE_SUPABASE_ANON_KEY, ambos NO vacíos
//     (la app usa `url && key ? SupabaseApi : DemoApi`: con cualquiera vacío arranca en DEMO);
//  2) efectivo: abre el build en Chromium sin conexión a Supabase y exige window.OKD_ONLINE.api.mode === 'online'.
// Sale con código distinto de cero si algo no cumple. Uso: node scripts/verify_production_build.mjs [dir=dist] [url esperada]
import { readFileSync, readdirSync, statSync, existsSync } from 'node:fs';
import { join, resolve, extname } from 'node:path';
import { createServer } from 'node:http';
const dir = resolve(process.argv[2] || 'dist');
const expected = process.argv[3] || process.env.VITE_SUPABASE_URL || 'https://uqwilzzeyfuatlmwzxna.supabase.co';
const fail = m => { console.error('BUILD NO PUBLICABLE: ' + m); process.exit(1); };
if (!existsSync(join(dir, 'index.html'))) fail('no existe ' + dir + '/index.html');
const files = []; const walk = d => readdirSync(d).forEach(f => { const p = join(d, f); statSync(p).isDirectory() ? walk(p) : files.push(p); }); walk(dir);
if (files.some(f => /EVIDENCIA_USUARIO|captura_0\d_/i.test(f))) fail('el build contiene evidencia privada');
const js = files.filter(f => f.endsWith('.js')).map(f => readFileSync(f, 'utf8'));
// --- 1) estático: valores del entorno compilado
const val = k => { for (const s of js) { const m = s.match(new RegExp(k + ':"([^"]*)"')); if (m) return m[1]; } return null; };
const url = val('VITE_SUPABASE_URL'), key = val('VITE_SUPABASE_ANON_KEY');
if (!url) fail('VITE_SUPABASE_URL vacía o ausente en el build (la app arrancaría en MODO DEMO)');
if (!key) fail('VITE_SUPABASE_ANON_KEY vacía o ausente en el build (la app arrancaría en MODO DEMO)');
let host; try { host = new URL(url).host; } catch (e) { fail('VITE_SUPABASE_URL inválida: ' + url); }
if (host !== new URL(expected).host) fail('el build apunta a ' + host + ' y se esperaba ' + new URL(expected).host);
// --- 2) efectivo: qué API instancia realmente el artefacto
let chromium; try { ({ chromium } = await import('playwright')); } catch (e) { fail('no se puede verificar el modo efectivo: falta el paquete playwright'); }
const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.webmanifest': 'application/manifest+json', '.svg': 'image/svg+xml', '.png': 'image/png', '.webp': 'image/webp' };
const server = createServer((req, res) => {
  let p = resolve(dir, '.' + decodeURIComponent(new URL(req.url, 'http://x').pathname)); if (!p.startsWith(dir)) { res.writeHead(403); return res.end(); }
  if (!existsSync(p) || statSync(p).isDirectory()) p = join(dir, 'index.html');
  res.writeHead(200, { 'content-type': types[extname(p)] || 'application/octet-stream' }); res.end(readFileSync(p));
});
await new Promise(r => server.listen(0, '127.0.0.1', r));
let browser, mode = null;
try {
  browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();
  await page.route('**/*.supabase.co/**', r => r.abort());   // sin tocar Supabase
  await page.goto('http://127.0.0.1:' + server.address().port + '/');
  await page.waitForFunction(() => window.OKD_ONLINE && window.OKD_ONLINE.api, null, { timeout: 15000 });
  mode = await page.evaluate(() => window.OKD_ONLINE.api.mode);
} catch (e) { fail('no se pudo verificar el modo efectivo: ' + e.message); }
finally { if (browser) await browser.close().catch(() => null); server.close(); }
if (mode !== 'online') fail('el artefacto arranca en modo "' + mode + '" (no es producción)');
console.log('OK build de producción: ' + dir + ' · Supabase ' + host + ' · clave pública presente · modo efectivo: online');
