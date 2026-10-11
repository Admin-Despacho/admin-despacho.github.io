import { defineConfig } from 'vite';
export default defineConfig({
  build: { outDir: 'dist', sourcemap: false, chunkSizeWarningLimit: 900 },
  test: { environment: 'node', include: ['tests/unit/**/*.test.js'] }
});
