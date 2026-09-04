// Bringing the cache in line with the manifest, without refetching what is already good.
//
// Only one runs at a time: the page triggers this on load, and a slow sync must not have a
// second one pile in behind it.
let syncing = null

function syncManifest() {
  if (!syncing) {
    syncing = runSync().finally(() => { syncing = null })
  }

  return syncing
}

async function runSync() {
  // Force offline is a request to use no network at all. A sync is nothing but network, and
  // the worker's own fetches do not pass through its fetch handler — so without this it would
  // quietly go to the network anyway, which is the one thing the switch exists to prevent.
  if (forcedOffline) {
    const paused = { ok: false, offline: true, reason: "forced", complete: false,
                     cached: 0, retired: 0, remaining: 0, failed: [], finishedAt: Date.now() }
    await notifyClients({ type: SYNC_MESSAGE, state: "finished", ...paused })

    return paused
  }

  const cache = await caches.open(CACHE_NAME)

  let manifest
  try {
    manifest = await fetchManifest()
  } catch (error) {
    // No connection is not the manifest misbehaving, and retrying sooner cannot help. Said
    // plainly so a page waits for the network instead of counting it as a failed attempt.
    const failure = { ok: false, error: error.message, offline: Boolean(error.offline),
                      complete: false, cached: 0, retired: 0, remaining: 0, failed: [],
                      finishedAt: Date.now() }
    await notifyClients({ type: SYNC_MESSAGE, state: "finished", ...failure })

    return failure
  }

  const wanted = new Set(manifest.map((value) => cacheUrl(new URL(value, self.location.origin).href)))

  // Retire what the manifest dropped — an unpublished site, say. Only entries the manifest
  // owns, so assets and ordinary browsing are left alone.
  const retired = await retireUnlisted(cache, wanted)

  // Fetch what is missing (a new site) or past its age (a stale one). Everything else is
  // already good and costs nothing.
  const now = Date.now() / 1000
  const pending = []
  for (const href of wanted) {
    const [ key ] = await cache.keys(new Request(href), MATCH_OPTIONS)
    const at = key ? unixTimestamp(key.headers.get(TIMESTAMP_HEADER)) : null

    if (!key || !at || (REFETCH_AFTER !== null && now - at > REFETCH_AFTER)) pending.push(href)
  }

  // Every open page hears about this, not just the one that asked. A sync outlives the page
  // that triggered it, so by the time it lands the user is usually somewhere else — and the
  // page that started it can no longer record that it finished, or show it happening.
  notifyClients({ type: SYNC_MESSAGE, state: "started", pending: pending.length, retired })

  const result = await precacheUrls(pending, (progress) => {
    notifyClients({ type: SYNC_MESSAGE, state: "progress", ...progress })
  })

  // The whole manifest was attempted, so what is left is what would not fetch. Those stay
  // missing from the cache, so the next sync finds them pending again and tries once more.
  const remaining = result.pageFailures
  const complete = remaining === 0
  // When the run actually ended, decided here rather than by whoever hears about it. A page
  // that opens later and asks what it missed must be able to say "synced four minutes ago",
  // not re-date the run to the moment it happened to look.
  const finished = { ...result, retired, synced: pending.length - remaining, remaining, complete,
                     finishedAt: Date.now() }

  await notifyClients({ type: SYNC_MESSAGE, state: "finished", ...finished })

  return finished
}

// Kept so a page can ask what it missed. The head snippet starts a sync while the page is
// still parsing, so a short run can begin and end before any Stimulus controller has
// connected to hear it — without this the debug page would sit on "Idle" through a sync it
// caused itself.
let lastSyncMessage = null

async function notifyClients(message) {
  lastSyncMessage = message

  const clients = await self.clients.matchAll({ includeUncontrolled: true, type: "window" })
  clients.forEach((client) => client.postMessage(message))
}

async function fetchManifest() {
  let response

  try {
    response = await fetch(PACK_PATH, {
      credentials: "same-origin",
      // The manifest has to describe the server as it is now. Left to the HTTP cache a
      // browser may serve a heuristically-fresh copy without asking, and a sync would then
      // faithfully fetch an old list, missing the pages it exists to pick up.
      cache: "no-store",
      headers: { Accept: "application/json" }
    })
  } catch (error) {
    // The fetch never completed at all: no connection, rather than a server saying no.
    const offline = new Error("No connection")
    offline.offline = true
    throw offline
  }

  // Signed out, this follows a redirect to the login page and arrives as a perfectly ok 200
  // of HTML, which would fail as an opaque JSON parse error.
  if (response.redirected) throw new Error("Signed out")
  if (!response.ok) throw new Error(`HTTP ${response.status}`)

  const pack = await response.json()

  return Array.isArray(pack.urls) ? pack.urls : []
}

async function retireUnlisted(cache, wanted) {
  const keys = await cache.keys()
  let retired = 0

  for (const key of keys) {
    if (key.headers.get(MANAGED_HEADER) !== "1") continue
    if (wanted.has(cacheUrl(key.url))) continue

    await cache.delete(key)
    retired++
  }

  return retired
}

// Compare URLs the same way they are stored, or every entry looks unlisted the moment a
// query string is involved.
function cacheUrl(href) {
  const url = new URL(href)
  if (IGNORE_SEARCH) url.search = ""

  return url.href
}

// A fixed number of lanes pulling from one queue.
//
// One at a time takes as many round trips as there are URLs — minutes for a real manifest.
// Promise.all over the lot opens a connection per URL and leaves the app's own requests
// queued behind its own precaching, which is worse than slow.
async function runPool(items, concurrency, handler) {
  const queue = items.slice()
  const lanes = Math.max(1, Math.min(concurrency, queue.length))

  await Promise.all(Array.from({ length: lanes }, async () => {
    while (queue.length) {
      try {
        await handler(queue.shift())
      } catch {
        // A lane has to outlive its work. Callers record their own failures, so this is a
        // backstop — but without it one unexpected throw kills that lane, rejects the
        // Promise.all, and abandons every URL still queued behind it.
      }
    }
  }))
}

// One retry, because a sync runs for a while on a phone and a single dropped request should
// not leave a page missing until the next interval comes round.
async function fetchWithRetry(cache, href, options) {
  try {
    return await fetchAndCache(cache, href, options)
  } catch {
    await new Promise((resolve) => setTimeout(resolve, 500))

    return fetchAndCache(cache, href, options)
  }
}

async function precacheUrls(inputUrls, onProgress = () => {}) {
  const cache = await caches.open(CACHE_NAME)
  // A Set, not an array: lanes finish out of order and an array turns the "already have it"
  // check into a scan per asset.
  const cached = new Set()
  const failed = []
  const pageFailures = []
  const assets = new Set()

  let done = 0
  onProgress({ phase: "pages", done, total: inputUrls.length })

  await runPool(inputUrls, SYNC_CONCURRENCY, async (value) => {
    try {
      const href = new URL(value, self.location.origin).href
      const extra = await fetchWithRetry(cache, href, { managed: true })
      cached.add(href)
      extra.forEach((url) => assets.add(url))
    } catch {
      failed.push(String(value))
      pageFailures.push(String(value))
    }
    onProgress({ phase: "pages", done: ++done, total: inputUrls.length })
  })

  // Assets are only known once the pages are parsed, so they get their own count.
  const pending = [...assets].filter((href) => !cached.has(href))
  done = 0
  onProgress({ phase: "assets", done, total: pending.length })

  await runPool(pending, SYNC_CONCURRENCY, async (href) => {
    try {
      await fetchWithRetry(cache, href)
      cached.add(href)
    } catch {
      failed.push(href)
    }
    onProgress({ phase: "assets", done: ++done, total: pending.length })
  })

  return { ok: failed.length === 0, cached: cached.size, failed, pageFailures: pageFailures.length }
}

async function fetchAndCache(cache, href, { managed = false } = {}) {
  const request = new Request(href, { credentials: "same-origin" })
  const response = await fetch(request)
  if (!isCacheable(request, response)) {
    throw new Error(response.redirected ? `Redirected to ${response.url}` : `HTTP ${response.status}`)
  }

  await putFresh(cache, cacheKey(request, { managed }), response.clone())

  const contentType = response.headers.get("Content-Type") || ""
  if (!contentType.includes("text/html")) return []

  return urlsFromHtml(await response.text(), href)
}

// Subresources only — do not follow <a href> or this becomes a site crawler.
function urlsFromHtml(html, pageUrl) {
  const urls = new Set()
  const base = new URL(pageUrl)

  const add = (raw) => {
    if (!raw) return
    raw.split(",").forEach((part) => {
      const token = part.trim().split(/\s+/)[0]
      if (!token || token.startsWith("data:")) return
      try {
        const url = new URL(token, base)
        // Any origin we are allowed to cache, not just our own. A page whose map library
        // comes off a CDN is not offline-ready without it: precaching the page and skipping
        // the script it cannot run without leaves a blank screen and a full cache.
        if (!cacheableOrigin(url)) return
        if (matchesPath(url, NEVER_INTERCEPT)) return
        urls.add(url.href)
      } catch {}
    })
  }

  for (const match of html.matchAll(/<link\b[^>]*\bhref=["']([^"']+)["']/gi)) add(match[1])
  for (const match of html.matchAll(/<(?:script|img|source)\b[^>]*\bsrc=["']([^"']+)["']/gi)) add(match[1])
  for (const match of html.matchAll(/\bsrcset=["']([^"']+)["']/gi)) add(match[1])

  const importmap = html.match(/<script[^>]*type=["']importmap["'][^>]*>([\s\S]*?)<\/script>/i)
  if (importmap) {
    try {
      const json = JSON.parse(importmap[1])
      Object.values(json.imports || {}).forEach(add)
      Object.values(json.scopes || {}).forEach((map) => Object.values(map).forEach(add))
    } catch {}
  }

  return [...urls]
}
