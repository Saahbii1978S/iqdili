const CACHE_NAME = "ahla-tounsa-shell-v161";
const APP_ROOT = "/iqdili/";
const INDEX_URL = APP_ROOT + "index.html";
const APP_SHELL = [APP_ROOT, INDEX_URL, APP_ROOT + "app-icon.svg", APP_ROOT + "app-icon-180.png", APP_ROOT + "app-icon-192.png", APP_ROOT + "app-icon-512.png", APP_ROOT + "home-youthful-palette.css?v=2", APP_ROOT + "manifest.webmanifest", APP_ROOT + "privacy.html", APP_ROOT + "delete-account.html", APP_ROOT + "terms.html", APP_ROOT + "404.html"];

self.addEventListener("install", event => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then(cache => cache.addAll(APP_SHELL))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", event => {
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(key => key.startsWith("ahla-tounsa-shell-") && key !== CACHE_NAME).map(key => caches.delete(key))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", event => {
  const request = event.request;
  if (request.method !== "GET") return;

  const url = new URL(request.url);
  if (url.origin !== self.location.origin || !url.pathname.startsWith(APP_ROOT)) return;

  const isHomeDocument =
    url.pathname === APP_ROOT ||
    url.pathname === INDEX_URL;
  const isNavigation = request.mode === "navigate" || isHomeDocument;

  if (isNavigation) {
    event.respondWith(
      fetch(request)
        .then(response => {
          if (response && response.ok && response.type === "basic") {
            const copy = response.clone();
            event.waitUntil(
              caches.open(CACHE_NAME).then(async cache => {
                if (isHomeDocument) {
                  await cache.put(APP_ROOT, copy.clone());
                  await cache.put(INDEX_URL, copy);
                } else {
                  await cache.put(request, copy);
                }
              })
            );
          }
          return response;
        })
        .catch(async () => {
          const cached = await caches.match(request) ||
            await caches.match(APP_ROOT) ||
            await caches.match(INDEX_URL);
          return cached || Response.error();
        })
    );
    return;
  }

  // Stale-while-revalidate for same-origin static app assets only.
  const refresh = fetch(request).then(response => {
    if (response && response.ok && response.type === "basic") {
      const copy = response.clone();
      event.waitUntil(caches.open(CACHE_NAME).then(cache => cache.put(request, copy)));
    }
    return response;
  });

  event.respondWith(
    caches.match(request).then(cached => {
      if (cached) {
        event.waitUntil(refresh.then(() => undefined).catch(() => undefined));
        return cached;
      }
      return refresh;
    })
  );
});
