// Deleting is the one thing here with no way back. Everything else a worker gets wrong costs
// a round trip; a collection that runs on a dead connection costs pages that cannot be
// fetched again until one returns. So a sweep proves the network first, and only then takes
// what nothing has asked for in a long time — and, if the cache is still over its ceiling,
// whatever has gone longest unread until it fits.
//
// Somebody choosing a ceiling on the settings page is the exception, and applyCeiling() below
// is where it is made.
let collecting = null

// One pass over the cache at a time. Two of them deleting at once would each be measuring a
// total the other is still taking from, and both would stop early.
function track(run) {
  collecting = run
  run.catch(() => {}).then(() => { if (collecting === run) collecting = null })

  return run
}

// The ceiling is a per-device choice, so it arrives with the request rather than being baked
// into the worker. Undefined is a page that has nothing to say about it — an older client, or
// one that never loaded the collector — and falls back to what the app configured.
function collectGarbage({ maxSize } = {}) {
  const limit = maxSize === undefined ? COLLECT_MAX_SIZE : maxSize
  // A sweep already running is the answer to this one too: it is doing the same automatic
  // work, and a sweep is cheap to be late.
  return collecting || track(runCollection(limit))
}

// Somebody has just set the ceiling and is watching the number under it. Two things separate
// this from a sweep:
//
// It does not prove the connection first. The probe is there because nothing asked for an
// automatic sweep, so the cost of getting it wrong falls on somebody who never requested it.
// This was requested: it is the same deliberate instruction Clear cache is, and that has
// never waited for a network to agree. Refusing until the connection returns would answer a
// question nobody asked.
//
// It never joins a run already in flight. That run is working to the ceiling this call
// replaces, so its answer is the answer to the old question — the very thing that made the
// setting look like it did nothing. It queues behind instead.
function applyCeiling(maxSize) {
  const queued = collecting ? collecting.catch(() => {}) : Promise.resolve()

  return track(queued.then(() => runTrim(maxSize)))
}

// Only the ceiling. Age collection stays behind the probe, because nothing has asked for it.
async function runTrim(maxSize) {
  if (maxSize === undefined || maxSize === null) return { ok: true, evicted: 0, trimmed: false }

  const cache = await caches.open(CACHE_NAME)
  const { evicted, bytes } = await trimToSize(cache, await collectable(cache), maxSize)

  return { ok: true, evicted, bytes, trimmed: true, finishedAt: Date.now() }
}

// Everything a sweep is allowed to take, with the stamp it sorts by.
async function collectable(cache) {
  const spared = offlinePageAssets()

  return (await cache.keys())
    .filter((key) => !isSpared(key, spared))
    .map((key) => ({ key, at: unixTimestamp(key.headers.get(TIMESTAMP_HEADER)) }))
}

// The URLs a sweep may never take, for the settings page.
//
// The page has to add up the same bytes the worker does or its bar lies: counting files the
// worker is not allowed to touch shows an overage that no amount of trimming will ever bring
// down, and the setting reads as broken when it is working exactly as told. The page knows
// about downloads by their query, but the offline page's own assets it cannot know, because
// working them out means parsing the offline page — which only the worker holds.
//
// The list, rather than the total: the page has already read every entry and its size to draw
// the list, so this is all it is missing, and one message beats a second pass over the cache.
async function sparedUrls() {
  return { ok: true, urls: [ ...offlinePageAssets() ] }
}

async function runCollection(maxSize) {
  if (COLLECT_MAX_AGE === null && maxSize === null) return { ok: true, collected: 0, skipped: "disabled" }
  if (forcedOffline) return { ok: true, offline: true }
  if (!(await reachable())) return { ok: true, offline: true }

  const cache = await caches.open(CACHE_NAME)
  const keys = await cache.keys()
  const spared = offlinePageAssets()
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
  // Put it back where it was. Rebuilt from the URL alone, a frame entry would lose the frame
  // it names and land on its page's key, which is the collision this all exists to avoid.
  const params = new URL(key.url).searchParams
  const frame = params.get(FRAME_PARAM)
  const format = params.get(FORMAT_PARAM)
  await putFresh(cache, cacheKey(new Request(key.url, { method: "GET" }), { managed, frame, format }), response)
}
