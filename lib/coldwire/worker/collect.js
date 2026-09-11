// Deleting is the one thing here with no way back. Everything else a worker gets wrong costs
// a round trip; a collection that runs on a dead connection costs pages that cannot be
// fetched again until one returns. So a sweep proves the network first, and only then takes
// what nothing has asked for in a long time — and, if the cache is still over its ceiling,
// whatever has gone longest unread until it fits.
let collecting = null

// The ceiling is a per-device choice, so it arrives with the request rather than being baked
// into the worker. Undefined is a page that has nothing to say about it — an older client, or
// one that never loaded the collector — and falls back to what the app configured.
function collectGarbage({ maxSize } = {}) {
  const limit = maxSize === undefined ? COLLECT_MAX_SIZE : maxSize
  // A sweep already running is the answer to this one too. It may be working to a ceiling
  // that has just changed; the next sweep uses the new one, and a sweep is cheap to be late.
  collecting = collecting || runCollection(limit).finally(() => { collecting = null })

  return collecting
}

async function runCollection(maxSize) {
  if (COLLECT_MAX_AGE === null && maxSize === null) return { ok: true, collected: 0, skipped: "disabled" }
  if (forcedOffline) return { ok: true, offline: true }
  if (!(await reachable())) return { ok: true, offline: true }

  const cache = await caches.open(CACHE_NAME)
  const keys = await cache.keys()
  const spared = neverCollected()
  const now = Date.now() / 1000

  let collected = 0
  let kept = 0
  // What the age pass left, which is exactly what the size pass may take from.
  const survivors = []

  for (const key of keys) {
    if (isSpared(key, spared)) { kept += 1; continue }

    const at = unixTimestamp(key.headers.get(TIMESTAMP_HEADER))
    // No stamp at all is an entry from an older worker. Age unknown is not age exceeded, so
    // it stays; the next time its page is stored it gets one.
    if (COLLECT_MAX_AGE === null || at === null || now - at <= COLLECT_MAX_AGE) {
      survivors.push({ key, at })
      continue
    }

    if (await cache.delete(key)) collected += 1
  }

  const { evicted, bytes } = await trimToSize(cache, survivors, maxSize)

  return { ok: true, collected, evicted, bytes, kept: kept + survivors.length - evicted, finishedAt: Date.now() }
}

// The ceiling. Age says when something has gone stale; this says how much of somebody's phone
// the cache may have, which on a device that browses far more than it revisits is the only one
// of the two that ever binds.
//
// Oldest read out first, until what is left fits. Last used is the closest thing the cache has
// to "least likely to be wanted back", and it is the same clock the age pass works from — an
// entry renewed because a page still loads it is young here too, so the thing being used is
// the last thing to go.
async function trimToSize(cache, entries, maxSize) {
  if (maxSize === null || entries.length === 0) return { evicted: 0, bytes: 0 }

  // One match per entry, and a body read for anything without a Content-Length. Affordable
  // because a sweep runs on `interval` rather than on navigation — but only worth paying at
  // all when there is a ceiling to measure against, which is why it sits behind the guard.
  const sized = []
  let total = 0

  for (const entry of entries) {
    // ignoreVary, as the settings page does when it lists the same entries: Rails answers
    // HTML with `Vary: Accept`, and a measurement that quietly missed would read as an entry
    // costing nothing and so never worth evicting.
    const size = await entrySize(await cache.match(entry.key, { ignoreVary: true }))
    total += size
    sized.push({ key: entry.key, at: entry.at, size })
  }

  if (total <= maxSize) return { evicted: 0, bytes: total }

  // An entry with no stamp is from an older worker, and has no place in an ordering by last
  // use. Treated as the oldest thing here: it is the one entry we can say nothing has touched
  // since this worker started stamping them.
  sized.sort((a, b) => (a.at || 0) - (b.at || 0))

  let evicted = 0

  for (const entry of sized) {
    if (total <= maxSize) break
    if (!(await cache.delete(entry.key))) continue

    total -= entry.size
    evicted += 1
  }

  return { evicted, bytes: total }
}

// Never collected, whatever their age — and never counted against the ceiling either, since
// the ceiling has to measure the same thing a sweep can act on. A 300 MB archive counted in
// would empty everything else to make room for a file nothing is allowed to take:
//
//   - what the offline page itself needs, which browsing never touches because nobody visits
//     the offline page on purpose, and which is wanted precisely when there is no network
//   - downloaded archives and the ranges of them, which somebody chose to spend a data plan
//     on and which no amount of disuse makes safe to throw away
//   - the small files an archive comes with, a map's style and its sprite sheet. Those are
//     stored under their own addresses rather than as chunks, so nothing about the entry says
//     it belongs to a download — and taking one leaves 300 MB on the device that cannot draw
function isSpared(key, spared) {
  const url = new URL(key.url)
  if (url.searchParams.has(CHUNK_PARAM) || url.searchParams.has(RANGE_PARAM)) return true

  return spared.has(bareHref(url.href))
}

function neverCollected() {
  // Bare, because an archive may be configured with a query — a style asked for as
  // `style.json?v=1` is stored under `style.json` whenever query params are ignored.
  const spared = new Set(CACHE_ARCHIVES.map(bareHref))

  try {
    for (const href of urlsFromHtml(OFFLINE_PAGE, self.location.origin + "/")) {
      spared.add(bareHref(href))
    }
  } catch {
    // An offline page that will not parse is no reason to sweep nothing.
  }

  return spared
}

// navigator.onLine reports whether an interface is up, which a web view answers wrongly often
// enough to be worthless here. The probe is never intercepted, so this is a real request over
// a real connection or it is nothing.
async function reachable() {
  try {
    const response = await fetch(PROBE_PATH, { cache: "no-store", credentials: "same-origin" })

    return response.ok
  } catch {
    return false
  }
}

// An asset every page names is never refetched once held, so its stamp would date from the
// first page that pulled it in — and the collector would take the stylesheet the whole app is
// using. Renewing it on the way past is what keeps "untouched" meaning untouched.
//
// Rewritten from the cache rather than refetched, and only once it has aged, so an ordinary
// navigation costs a lookup and nothing more.
async function renew(cache, key) {
  if (RENEW_AFTER === null) return

  const at = unixTimestamp(key.headers.get(TIMESTAMP_HEADER))
  if (at !== null && Date.now() / 1000 - at < RENEW_AFTER) return

  const response = await cache.match(key)
  if (!response) return

  const managed = key.headers.get(MANAGED_HEADER) === "1"
  await putFresh(cache, cacheKey(new Request(key.url, { method: "GET" }), { managed }), response)
}
