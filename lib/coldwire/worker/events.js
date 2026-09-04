self.addEventListener("install", (event) => {
  event.waitUntil(Promise.all([ self.skipWaiting(), cacheOfflinePage() ]))
})

// The offline page is the one page that has to render when nothing else can, and Hotwire
// Native rejects any page where window.Turbo never appears — so it carries an importmap and
// imports Turbo. Those assets are digested, which means a deploy changes their URLs and the
// cache filled by the previous deploy does not have the new ones.
//
// Left to a sync, the fallback is broken for exactly as long as nobody has been online since
// the deploy — which is to say, broken precisely when it is needed. Fetching them as the
// worker installs is the moment the new URLs first become known.
async function cacheOfflinePage() {
  try {
    const cache = await caches.open(CACHE_NAME)
    const urls = urlsFromHtml(OFFLINE_PAGE, self.location.origin + "/")

    await runPool(urls, SYNC_CONCURRENCY, async (href) => {
      // One at a time and forgiving: a worker that refuses to install because a stylesheet
      // was briefly unavailable is worse than one whose fallback is missing a stylesheet.
      try {
        await fetchAndCache(cache, href)
      } catch {}
    })
  } catch {
    // Installing must not fail over this. A worker with an imperfect fallback still caches
    // pages, still syncs, and still beats no worker at all.
  }
}

self.addEventListener("activate", (event) => {
  event.waitUntil(self.clients.claim())
})

self.addEventListener("fetch", (event) => {
  if (!shouldHandle(event.request)) return

  if (event.request.headers.has("Range")) {
    event.respondWith(handleRange(event.request))
    return
  }

  event.respondWith(handleFetch(event.request))
})

self.addEventListener("message", (event) => {
  const type = event.data?.type
  const reply = (promise) => {
    event.waitUntil(
      Promise.resolve(promise)
        .then((result) => event.ports[0]?.postMessage(result))
        .catch((error) => event.ports[0]?.postMessage({ ok: false, error: error.message }))
    )
  }

  if (type === "clearCache") return reply(clearCaches())
  if (type === "forget") return reply(forgetUrl(event.data.url, event.data.cache))
  if (type === "listCache") return reply(listCaches())
  if (type === "getForcedOffline") return reply({ ok: true, forcedOffline })
  if (type === "setForcedOffline") {
    forcedOffline = Boolean(event.data.value)
    return reply({ ok: true, forcedOffline })
  }
  // One way to fill the cache, whether a page load asked for it on a timer or somebody
  // pressed the button. Progress goes out on the broadcast, not this port, so every open
  // page sees the run and not just whoever started it.
  if (type === "sync") return reply(syncManifest())

  // What a page missed by not listening yet, and whether it is still going on.
  if (type === "syncState") return reply({ ok: true, running: Boolean(syncing), last: lastSyncMessage })

  if (type === "archiveStatus") return reply(archiveStatus(event.data.url))
  if (type === "archiveDownload") return reply(downloadArchive(event.data.url))
  if (type === "archiveRemove") return reply(removeArchive(event.data.url))
})
