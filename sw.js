const CACHE_NAME = 'voltfriq-shell-v20260529-admin-cache-bypass';
const APP_SHELL = [
  '/offline.html',
  '/manifest.json',
  '/assets/favicon.ico',
  '/assets/apple-touch-icon.png',
  '/assets/icon-192.png',
  '/assets/icon-512.png'
];
const INLINE_OFFLINE_HTML = '<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="theme-color" content="#07111d"><title>VoltFriq Offline</title><style>html,body{margin:0;min-height:100%;font-family:Inter,system-ui,sans-serif;background:#070b14;color:#f8fbff}body{display:grid;place-items:center;padding:24px}main{max-width:520px;padding:32px;border:1px solid rgba(255,255,255,.1);border-radius:24px;background:linear-gradient(180deg,rgba(11,22,38,.9),rgba(5,11,21,.96));box-shadow:0 24px 64px rgba(0,0,0,.36)}h1{margin:0 0 12px;font-size:clamp(2rem,9vw,3rem);line-height:1.05}p{margin:0 0 24px;color:rgba(232,240,252,.68);line-height:1.6}button{width:100%;min-height:56px;border:0;border-radius:18px;background:#ffb800;color:#07111d;font:inherit;font-weight:850}</style></head><body><main><h1>You’re offline</h1><p>VoltFriq needs a connection for live booking, payment, and tracking updates. Reconnect, then try again.</p><button onclick="location.reload()">Try Again</button></main></body></html>';

function offlineResponse() {
  return caches.match('/offline.html').then((cached) => cached || new Response(INLINE_OFFLINE_HTML, {
    headers: { 'Content-Type': 'text/html; charset=utf-8' }
  }));
}

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then((cache) => Promise.all(APP_SHELL.map((url) => cache.add(url).catch(() => null))))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys
        .filter((key) => key !== CACHE_NAME)
        .map((key) => caches.delete(key))))
      .then(() => self.clients.claim())
      .then(() => self.clients.matchAll({ type: 'window', includeUncontrolled: true }))
      .then((clients) => Promise.all(clients.map((client) => {
        const url = new URL(client.url);
        if (!isAdminRequest(url) || typeof client.navigate !== 'function') return null;
        return client.navigate(client.url).catch(() => null);
      })))
  );
});

self.addEventListener('fetch', (event) => {
  const request = event.request;
  if (request.method !== 'GET') return;

  const url = new URL(request.url);
  if (url.origin === self.location.origin && isAdminRequest(url)) {
    event.respondWith(fetch(request));
    return;
  }

  if (request.mode === 'navigate') {
    event.respondWith(
      fetch(request)
        .then((response) => {
          const copy = response.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put(request, copy));
          return response;
        })
        .catch(() => caches.match(request).then((cached) => cached || offlineResponse()))
    );
    return;
  }

  if (url.origin !== self.location.origin) return;

  event.respondWith(
    fetch(request)
      .then((response) => {
        const copy = response.clone();
        caches.open(CACHE_NAME).then((cache) => cache.put(request, copy));
        return response;
      })
      .catch(() => caches.match(request))
  );
});

function isAdminRequest(url) {
  return url.pathname === '/admin' ||
    url.pathname === '/admin.html' ||
    url.pathname.startsWith('/admin/') ||
    url.pathname.startsWith('/assets/admin-') ||
    url.pathname === '/css/admin.css';
}
