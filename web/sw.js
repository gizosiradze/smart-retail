// Retired: the installable app now lives in /app/ (app/sw.js). This file only removes the earlier
// root-level service worker from browsers that still have it.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys().then(ks => Promise.all(ks.map(k => caches.delete(k))))
      .then(() => self.registration.unregister())
  );
});
