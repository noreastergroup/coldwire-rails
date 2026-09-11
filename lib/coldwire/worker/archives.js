// The facts about a chunk go on the key, not only on the response. cache.keys() hands back
// Requests, so anything read while counting up what is stored has to live there — the same
// reason the timestamp does. Matching ignores headers, so a lookup built without them still
// finds the entry.
function chunkKey(url, index, facts = null) {
  const target = new URL(url)
  target.searchParams.set(CHUNK_PARAM, String(index))
  if (!facts) return new Request(target.href, { method: "GET" })

  const headers = new Headers()
  headers.set("coldwire-archive-total", String(facts.total))
  headers.set("coldwire-chunk-size", String(facts.size))
  headers.set(TIMESTAMP_HEADER, String(Math.floor(Date.now() / 1000)))

  return new Request(target.href, { method: "GET", headers })
}

function chunkCount(total) {
  return Math.ceil(total / ARCHIVE_CHUNK)
}

// How big the thing is, asked for in the cheapest way there is: one byte, and read the total
// off the Content-Range that comes back.
async function archiveTotal(url) {
  const response = await fetch(url, { headers: { Range: "bytes=0-0" } })
  if (response.status !== 206) throw new Error(`HTTP ${response.status}`)

  const total = rangeTotal(response.headers.get("Content-Range"))
  if (!total) throw new Error("No Content-Range")

  return total
}

// Counted from what is actually stored rather than from a note written when the download ran.
// A cache can be evicted piecemeal, and a status that disagrees with the cache is worse than
// no status at all.
async function archiveStatus(url) {
  if (!CACHE_ARCHIVES.includes(url)) return { ok: false, error: "Not a listed archive" }

  const cache = await caches.open(CACHE_NAME)
  const stored = await cache.keys()
  const prefix = new URL(url)
  prefix.search = ""

  let bytes = 0
  let chunks = 0
  let total = null
  // The newest chunk: when this last got any of itself, which for a finished download is
  // when it finished. Chunks already held are skipped on a later pass, so an older one
  // would date the archive from an attempt that may have stopped in the first megabyte.
  let cachedAt = null

  for (const key of stored) {
    const keyUrl = new URL(key.url)
    keyUrl.search = ""
    if (keyUrl.href !== prefix.href) continue
    if (!new URL(key.url).searchParams.has(CHUNK_PARAM)) continue

    chunks += 1
    const size = Number(key.headers.get("coldwire-chunk-size"))
    if (Number.isFinite(size)) bytes += size
    const declared = Number(key.headers.get("coldwire-archive-total"))
    if (Number.isFinite(declared) && declared > 0) total = declared
    const stamp = unixTimestamp(key.headers.get(TIMESTAMP_HEADER))
    if (stamp && (!cachedAt || stamp > cachedAt)) cachedAt = stamp
  }

  return {
    ok: true,
    url,
    chunks,
    bytes,
    total,
    cachedAt,
    expected: total ? chunkCount(total) : null,
    complete: Boolean(total) && chunks === chunkCount(total)
  }
}

// Resumable by construction: every chunk already stored is skipped, so an interrupted download
// picks up where it stopped rather than starting again. Sequential on purpose — this is a
// large download over somebody's connection, and running it in parallel lanes would take the
// bandwidth the app itself is using.
async function downloadArchive(url) {
  if (!CACHE_ARCHIVES.includes(url)) return { ok: false, error: "Not a listed archive" }
  if (forcedOffline) return { ok: false, offline: true, reason: "forced" }

  const cache = await caches.open(CACHE_NAME)

  let total
  try {
    total = await archiveTotal(url)
  } catch (error) {
    return { ok: false, offline: true, error: error.message }
  }

  const count = chunkCount(total)
  let stored = 0

  for (let index = 0; index < count; index++) {
    const key = chunkKey(url, index)

    if (await cache.match(key)) {
      stored += 1
      notifyClients({ type: ARCHIVE_MESSAGE, url, state: "progress", done: stored, total: count })
      continue
    }

    const start = index * ARCHIVE_CHUNK
    const end = Math.min(start + ARCHIVE_CHUNK, total) - 1

    try {
      const response = await fetch(url, { headers: { Range: `bytes=${start}-${end}` } })
      if (response.status !== 206) throw new Error(`HTTP ${response.status}`)

      const body = await response.arrayBuffer()
      const headers = new Headers()
      headers.set("Content-Type", response.headers.get("Content-Type") || "application/octet-stream")
      // On the response as well, because serving a range reads the total from here.
      headers.set("coldwire-archive-total", String(total))

      await cache.put(chunkKey(url, index, { total, size: body.byteLength }),
                      new Response(body, { status: 200, headers }))
    } catch (error) {
      // Everything already stored stays stored, so asking again resumes from here.
      const failure = { ok: false, url, error: error.message, done: stored, total: count }
      await notifyClients({ type: ARCHIVE_MESSAGE, state: "finished", ...failure })

      return failure
    }

    stored += 1
    notifyClients({ type: ARCHIVE_MESSAGE, url, state: "progress", done: stored, total: count })
  }

  const finished = { ok: true, url, done: stored, total: count, bytes: total, complete: true }
  await notifyClients({ type: ARCHIVE_MESSAGE, state: "finished", ...finished })

  return finished
}

async function removeArchive(url) {
  const cache = await caches.open(CACHE_NAME)
  const prefix = new URL(url)
  prefix.search = ""

  let removed = 0
  for (const key of await cache.keys()) {
    const keyUrl = new URL(key.url)
    const bare = new URL(key.url)
    bare.search = ""
    if (bare.href !== prefix.href) continue
    if (!keyUrl.searchParams.has(CHUNK_PARAM)) continue
    if (await cache.delete(key)) removed += 1
  }

  return { ok: true, url, removed }
}
