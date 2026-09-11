// Deleting is the one thing here with no way back. Everything else a worker gets wrong costs
// a round trip; a collection that runs on a dead connection costs pages that cannot be
// fetched again until one returns. So a sweep proves the network first, and only then takes
// what nothing has asked for in a long time.
let collecting = null

function collectGarbage() {
  collecting = collecting || runCollection().finally(() => { collecting = null })

  return collecting
}

async function runCollection() {
  if (COLLECT_MAX_AGE === null) return { ok: true, collected: 0, skipped: "disabled" }
  if (forcedOffline) return { ok: true, offline: true }
  if (!(await reachable())) return { ok: true, offline: true }

  const cache = await caches.open(CACHE_NAME)
  const keys = await cache.keys()
  const spared = offlinePageAssets()
  const now = Date.now() / 1000

  let collected = 0
  let kept = 0

  for (const key of keys) {
    if (isSpared(key, spared)) { kept += 1; continue }

    const at = unixTimestamp(key.headers.get(TIMESTAMP_HEADER))
    // No stamp at all is an entry from an older worker. Age unknown is not age exceeded, so
    // it stays; the next time its page is stored it gets one.
    if (at === null || now - at <= COLLECT_MAX_AGE) { kept += 1; continue }

    if (await cache.delete(key)) collected += 1
  }

  return { ok: true, collected, kept, finishedAt: Date.now() }
}

// Never collected, whatever their age:
//
//   - what the offline page itself needs, which browsing never touches because nobody visits
//     the offline page on purpose, and which is wanted precisely when there is no network
//   - downloaded archives and the ranges of them, which somebody chose to spend a data plan
//     on and which no amount of disuse makes safe to throw away
function isSpared(key, spared) {
  const url = new URL(key.url)
  if (url.searchParams.has(CHUNK_PARAM) || url.searchParams.has(RANGE_PARAM)) return true

  return spared.has(url.href)
}

function offlinePageAssets() {
  try {
    return new Set(urlsFromHtml(OFFLINE_PAGE, self.location.origin + "/"))
  } catch {
    return new Set()
  }
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
