// V4.26 · Los íconos PWA son los del DISEÑO APROBADO (public/icons, generados una vez desde Icono_PWA_APROBADO.png con
// tools/generar_iconos_aprobados.py). Este paso del build ya NO dibuja el monograma anterior: solo VERIFICA que estén los 7 íconos
// aprobados con su tamaño exacto (lee el encabezado PNG). Si falta alguno o cambió de tamaño, detiene el build.
import fs from 'node:fs';
const want = { 'icon-16.png': 16, 'icon-32.png': 32, 'apple-touch-icon.png': 180, 'icon-192.png': 192, 'icon-512.png': 512, 'icon-maskable-192.png': 192, 'icon-maskable-512.png': 512 };
const bad = [];
for (const [f, s] of Object.entries(want)) {
  const p = 'public/icons/' + f; if (!fs.existsSync(p)) { bad.push(f + ': falta'); continue; }
  const b = fs.readFileSync(p); const w = b.readUInt32BE(16), h = b.readUInt32BE(20);
  if (b.toString('ascii', 1, 4) !== 'PNG' || w !== s || h !== s) bad.push(f + ': ' + w + 'x' + h + ' (se esperaba ' + s + 'x' + s + ')');
}
if (bad.length) { console.error('ÍCONOS PWA NO VÁLIDOS:\n  ' + bad.join('\n  ')); process.exit(1); }
console.log('Íconos PWA aprobados verificados (7): favicon 16/32, Apple 180, PWA 192/512 y maskable 192/512.');
