// Smart Retail service worker: app shell (so the till opens without internet) and product photos.
// Data requests (Supabase API) are never cached: the app keeps its own offline copy in IndexedDB (js/sr.js).
const CACHE = 'sr-app-v11', IMG = 'sr-img-v1', IMG_MAX = 400, NET_WAIT_MS = 2000;
const SHELL = ['./', '../config.js', '../js/sr.js', '../js/sr-notify.js', 'manifest.webmanifest', '../icons/icon-192-v2.png', '../icons/icon-512-v2.png'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys()
      .then(ks => Promise.all(ks.filter(k => k !== CACHE && k !== IMG).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

// Network first (always the latest version online); the cache answers when offline or when the network
// does not answer within a few seconds (a connection that is "on" but dead must not freeze the till).
const timeout = ms => new Promise((_, no) => setTimeout(() => no(new Error('slow')), ms));
const cached = r => caches.match(r, { ignoreSearch: true }).then(m => m || caches.match('./'));

self.addEventListener('fetch', e => {
  const r = e.request, u = new URL(r.url);
  if (r.method !== 'GET') return;
  // product photos (Supabase Storage, public): cache first, so they still show offline
  if (u.pathname.startsWith('/storage/v1/object/public/product-images/')) {
    e.respondWith(caches.open(IMG).then(async c => {
      const hit = await c.match(r);
      if (hit) return hit;
      try {
        const res = await fetch(r);
        if (res.ok || res.type === 'opaque') {
          await c.put(r, res.clone());
          const ks = await c.keys(); if (ks.length > IMG_MAX) await c.delete(ks[0]);
        }
        return res;
      } catch (err) { return Response.error() }
    }));
    return;
  }
  if (u.origin !== location.origin || u.pathname.includes('/superadmin/')) return;
  e.respondWith(
    Promise.race([fetch(r), timeout(NET_WAIT_MS)]).then(res => {
      if (res.ok) { const copy = res.clone(); caches.open(CACHE).then(c => c.put(r, copy)); }
      return res;
    }).catch(() => cached(r))
  );
});

// Web Push: a sale was recorded (sent by the push-notify Edge Function).
self.addEventListener('push', e => {
  let d = {};
  try { d = e.data ? e.data.json() : {} } catch (_) { d = { body: e.data && e.data.text() } }
  e.waitUntil(self.registration.showNotification(d.title || 'Smart Retail', {
    body: d.body || '', tag: d.tag, icon: '../icons/icon-192-v2.png', badge: '../icons/icon-192-v2.png',
    data: { url: d.url || './' }
  }));
});

self.addEventListener('notificationclick', e => {
  e.notification.close();
  const target = new URL((e.notification.data && e.notification.data.url) || './', self.registration.scope);
  const tag = (target.hash.match(/^#n=(.+)/) || [])[1];
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(cs => {
    const c = cs.find(x => x.url.startsWith(self.registration.scope));
    if (!c) return self.clients.openWindow(target.href);
    if (tag) c.postMessage({ sr: 'push-go', tag: decodeURIComponent(tag) });
    return c.focus();
  }));
});
