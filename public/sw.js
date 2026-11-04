// Service worker (V4.24.1). En el build se reemplazan PRECACHE y VERSION con el shell REAL generado (scripts/sw_precache_plugin.mjs).
// - Instala COMPLETO el shell nuevo (addAll atómico): si algo falla, la instalación falla y sigue vigente el service worker anterior.
// - V4.24.1: NO borra el shell anterior al activarse: lo conserva 7 días (una página vieja todavía abierta puede cargar sus módulos).
// - V4.24.1: la PÁGINA se pide siempre revalidada (nunca un index.html viejo con archivos nuevos o al revés); sin conexión, la copia guardada.
// - V4.24.1: si un archivo propio da 404/5xx o falla la red, se busca en las cachés (incluida la de la versión anterior).
// - V4.24.1: nunca fuerza la navegación de una pantalla abierta (cada página se recarga una vez con su propio controllerchange).
// - Nunca toca IndexedDB ni localStorage. Nunca cachea API/Supabase ni otros orígenes.
const PRECACHE = /*__OKD_PRECACHE__*/[];
const CACHE = 'okd-shell-__OKD_SW_VERSION__';
const META = 'okd-sw-meta', KEEP_DAYS = 7;
self.addEventListener('install', e => { e.waitUntil(caches.open(CACHE).then(c => c.addAll(PRECACHE.map(u => new Request(u, { cache: 'reload' }))))
  .then(() => self.skipWaiting(), err => caches.delete(CACHE).then(() => { throw err; }))); });
async function retireOldShells() {   // conserva los shells anteriores KEEP_DAYS días (registro en la caché okd-sw-meta) y luego los borra
  const meta = await caches.open(META), prev = await meta.match('/__retired__').then(r => r ? r.json() : {}).catch(() => ({})), now = Date.now(), next = {};
  for (const k of (await caches.keys()).filter(k => k.startsWith('okd-shell') && k !== CACHE)) {
    const at = prev[k] || now;
    if (now - at > KEEP_DAYS * 864e5) await caches.delete(k); else next[k] = at;
  }
  await meta.put('/__retired__', new Response(JSON.stringify(next), { headers: { 'Content-Type': 'application/json' } }));
}
// V4.24.1 (final): SIN rescate desde el service worker. Una página que no responde NO está necesariamente bloqueada (las versiones viejas no
// conocen ningún protocolo) y forzar su navegación podía superponerse con su propia recarga. Cada página se recarga UNA vez con su propio
// controllerchange (las viejas, como siempre; las V4.24.1, esperando que no haya PIN, entrega, firma ni sincronización en curso).
// Los shells anteriores se retiran SOLO al activarse una versión nueva y recién después de KEEP_DAYS días: la versión que estaba en uso
// queda fechada en ese momento y se conserva, así una página que todavía la usa puede seguir cargando sus archivos.
self.addEventListener('activate', e => { e.waitUntil(retireOldShells().catch(() => null).then(() => self.clients.claim())); });

const fromCaches = req => caches.match(req, { cacheName: CACHE, ignoreSearch: true }).then(r => r || caches.match(req, { ignoreSearch: true }));
self.addEventListener('fetch', e => {
  const u = new URL(e.request.url);
  if (e.request.method !== 'GET' || u.origin !== location.origin) return; // API/Supabase y terceros: siempre red, nunca caché
  if (e.request.mode === 'navigate') {   // página: SIEMPRE revalidada con el servidor; sin conexión, la copia guardada
    // (una solicitud de NAVEGACIÓN no admite opciones: se pide su DIRECCIÓN revalidada; si no hay red, la copia guardada; nunca queda sin respuesta)
    e.respondWith(fetch(e.request.url, { cache: 'no-cache', credentials: 'same-origin' })
      .catch(() => caches.match('/index.html', { cacheName: CACHE }).then(r => r || caches.match('/index.html')).then(r => r || caches.match('/')))
      .then(r => r || fetch(e.request)));
    return;
  }
  // archivos propios: red primero; si la red falla O responde 404/5xx, la copia en caché (también de la versión anterior)
  e.respondWith(fetch(e.request).then(res => {
    if (res.ok) { if (PRECACHE.includes(u.pathname)) { const cp = res.clone(); caches.open(CACHE).then(c => c.put(e.request, cp)); } return res; }
    return fromCaches(e.request).then(r => r || res);
  }).catch(() => fromCaches(e.request)));
});

self.addEventListener('push', e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (_) { d = { title: 'OK Despacho', body: e.data ? e.data.text() : '' }; }
  const title = d.title || 'OK Despacho';
  const opts = {
    body: d.body || '',
    icon: d.icon || '/icons/icon-192.png',
    badge: d.badge || '/icons/icon-192.png',
    tag: d.tag || 'okd-notification',
    renotify: true,
    data: d.data || { url: '/' }
  };
  e.waitUntil(self.registration.showNotification(title, opts));
});
self.addEventListener('notificationclick', e => {
  e.notification.close();
  const target = (e.notification.data && e.notification.data.url) || '/';
  e.waitUntil(clients.matchAll({ type: 'window', includeUncontrolled: true }).then(list => {
    for (const c of list) {
      if ('focus' in c) {
        c.navigate(target).catch(() => null);
        return c.focus();
      }
    }
    return clients.openWindow ? clients.openWindow(target) : null;
  }));
});
