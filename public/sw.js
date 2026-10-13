// Service worker (RC2.1d). En el build se reemplazan PRECACHE y VERSION con el shell REAL generado (scripts/sw_precache_plugin.mjs).
// - Instala COMPLETO el shell nuevo (addAll es atómico): si algo falla, la instalación falla y sigue vigente el service worker/caché anterior.
// - Solo al activarse (con el shell completo ya guardado) borra los caches de shell anteriores (okd-shell-*). Nunca toca IndexedDB/localStorage.
// - Nunca cachea API/Supabase ni otros orígenes: solo archivos estáticos propios.
const PRECACHE = /*__OKD_PRECACHE__*/[];
const CACHE = 'okd-shell-__OKD_SW_VERSION__';
// cache:'reload' → cada archivo se baja del servidor (no del caché HTTP del navegador): el shell instalado es exactamente el publicado
// Si falla, se borra el caché a medio llenar y la instalación se rechaza: queda vigente el service worker anterior con su shell completo
self.addEventListener('install', e => { e.waitUntil(caches.open(CACHE).then(c => c.addAll(PRECACHE.map(u => new Request(u, { cache: 'reload' }))))
  .then(() => self.skipWaiting(), err => caches.delete(CACHE).then(() => { throw err; }))); });
self.addEventListener('activate', e => { e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k.startsWith('okd-shell') && k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim())); });
self.addEventListener('fetch', e => {
  const u = new URL(e.request.url);
  if (e.request.method !== 'GET' || u.origin !== location.origin) return; // API/Supabase y terceros: siempre red, nunca caché
  if (e.request.mode === 'navigate') { e.respondWith(fetch(e.request).catch(() => caches.match('/index.html', { cacheName: CACHE }).then(r => r || caches.match('/')))); return; }
  // red primero (siempre la versión publicada); el shell precargado cubre la falta de conexión
  e.respondWith(fetch(e.request).then(res => { if (res.ok && PRECACHE.includes(u.pathname)) { const cp = res.clone(); caches.open(CACHE).then(c => c.put(e.request, cp)); } return res; })
    .catch(() => caches.match(e.request, { ignoreSearch: true })));
});
