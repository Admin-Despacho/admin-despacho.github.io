import { defineConfig } from 'vite';
import swPrecache from './scripts/sw_precache_plugin.mjs';
// BASE_PATH permite publicar en GitHub Pages de proyecto ("/<repo>/"); por defecto "/" (Cloudflare o sitio de usuario).
export default defineConfig({
  base: process.env.BASE_PATH || '/',
  plugins: [swPrecache()],   // RC2.1d: el service worker precarga el shell real generado por el build
  build: { outDir: 'dist', sourcemap: false, chunkSizeWarningLimit: 900 },
  test: { environment: 'node', include: ['tests/unit/**/*.test.js'] }
});
