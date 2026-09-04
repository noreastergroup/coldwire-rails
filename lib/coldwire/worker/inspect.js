// Drop one entry. Matched with the same options everything else uses, or a URL that was
// stored with a query string would refuse to be found by the one shown in the list.
async function forgetUrl(url, name) {
  if (!url) return { ok: false, error: "No URL given" }

  const cache = await caches.open(name || CACHE_NAME)
  const deleted = await cache.delete(new Request(url), MATCH_OPTIONS)

  return { ok: deleted, deleted }
}

async function clearCaches() {
  const names = await caches.keys()
  await Promise.all(names.map((name) => caches.delete(name)))
  return { ok: true, cleared: names.length }
}

async function listCaches() {
  const names = await caches.keys()
  const result = []

  for (const name of names) {
    const cache = await caches.open(name)
    const requests = await cache.keys()
    const entries = []
    for (const request of requests) {
      entries.push(await describeCached(request, await cache.match(request, MATCH_OPTIONS)))
    }
    result.push({ name, entries })
  }

  return { ok: true, caches: result }
}

async function describeCached(request, response) {
  return {
    url: request.url,
    size: await entrySize(response),
    timestamp: unixTimestamp(request.headers.get(TIMESTAMP_HEADER))
  }
}

// Ask the headers before reading the body. Listing a real cache means hundreds of entries and
// tens of megabytes, and blob() on every one of them is a multi-second job for a number that
// Content-Length already carries.
async function entrySize(response) {
  if (!response) return 0

  const declared = Number(response.headers.get("Content-Length"))
  if (Number.isFinite(declared) && declared >= 0) return declared

  return (await response.clone().blob()).size
}

// The key an entry is stored under.
//
// Cache does not honor HTTP freshness headers, and WebKit drops Date on match(). Stamp unix
// seconds on the request key — keys() returns it, and URL matching still finds the entry.
//
// When ignoring query params, drop the search here too, not just in MATCH_OPTIONS. Matching
// would find the entry either way, but every distinct query string would still write its own
// copy — a map that rewrites lat/lng/zoom on each pan would bury the cache in near-duplicates
// of one page.
function cacheKey(request, { managed = false } = {}) {
  const headers = new Headers(request.headers)
  headers.set(TIMESTAMP_HEADER, String(Math.floor(Date.now() / 1000)))
  if (managed) headers.set(MANAGED_HEADER, "1")

  // `new Request(request, init)` downgrades a navigation request's mode for us; rebuilding
  // from a URL string needs the method stated explicitly.
  if (!IGNORE_SEARCH) return new Request(request, { headers })

  const url = new URL(request.url)
  url.search = ""
  return new Request(url.href, { method: "GET", headers })
}

function unixTimestamp(value) {
  const seconds = Number(value)
  return Number.isFinite(seconds) && seconds > 0 ? seconds : null
}
