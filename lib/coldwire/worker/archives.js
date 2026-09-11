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

function bareHref(url) {
  const bare = new URL(url)
  bare.search = ""

  return bare.href
}

function archiveSet(url) {
  return ARCHIVE_SETS.find((archive) => archive.url === url) || null
}

// Whether a file of an archive is stored in pieces or whole. Not a question of what the
// server will serve — these hosts answer Range for a stylesheet as readily as for a 300 MB
// archive — but of what could ever be read back. handleRange only stitches chunks for a
// cache_ranges URL, and every other request is looked up under its own address, so chunking
// anything else would write a download nothing can read.
function isChunked(url) {
  return matchesRules(new URL(url), CACHE_RANGES)
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

function chunksStored(keys, member) {
  const prefix = bareHref(member)
  const found = { chunks: 0, bytes: 0, total: null, cachedAt: null }

  for (const key of keys) {
    const keyUrl = new URL(key.url)
    if (bareHref(key.url) !== prefix) continue
    if (!keyUrl.searchParams.has(CHUNK_PARAM)) continue

    found.chunks += 1
    const size = Number(key.headers.get("coldwire-chunk-size"))
    if (Number.isFinite(size)) found.bytes += size
    const declared = Number(key.headers.get("coldwire-archive-total"))
    if (Number.isFinite(declared) && declared > 0) found.total = declared
    // The newest piece: when this last got any of itself, which for a finished download is
    // when it finished. Pieces already held are skipped on a later pass, so an older one
    // would date the archive from an attempt that may have stopped in the first megabyte.
    const stamp = unixTimestamp(key.headers.get(TIMESTAMP_HEADER))
    if (stamp && (!found.cachedAt || stamp > found.cachedAt)) found.cachedAt = stamp
  }

  return found
}

async function companionStored(cache, member) {
  const [ key ] = await cache.keys(member, MATCH_OPTIONS)
  if (!key) return null

  const response = await cache.match(key)
  const bytes = response ? (await response.blob()).size : 0

  return { bytes, cachedAt: unixTimestamp(key.headers.get(TIMESTAMP_HEADER)) }
}

// Counted from what is actually stored rather than from a note written when the download ran.
// A cache can be evicted piecemeal, and a status that disagrees with the cache is worse than
// no status at all.
async function archiveStatus(url) {
  const archive = archiveSet(url)
  if (!archive) return { ok: false, error: "Not a listed archive" }

  const cache = await caches.open(CACHE_NAME)
  const stored = await cache.keys()

  let pieces = 0
  let expected = 0
  let bytes = 0
  let total = 0
  let cachedAt = null
  let sized = true

  const seen = (stamp) => { if (stamp && (!cachedAt || stamp > cachedAt)) cachedAt = stamp }

  for (const member of archive.urls) {
    if (isChunked(member)) {
      const found = chunksStored(stored, member)
      pieces += found.chunks
      bytes += found.bytes
      seen(found.cachedAt)
      // Size is only known once a piece of it is held: the total is written on the chunks.
      if (found.total) {
        total += found.total
        expected += chunkCount(found.total)
      } else {
        sized = false
      }
    } else {
      expected += 1
      const found = await companionStored(cache, member)
      if (found) {
        pieces += 1
        bytes += found.bytes
        total += found.bytes
        seen(found.cachedAt)
      }
    }
  }

  return {
    ok: true,
    url,
    chunks: pieces,
    bytes,
    total: total || null,
    cachedAt,
    expected: sized ? expected : null,
    complete: sized && pieces === expected
  }
}

async function storeChunk(cache, member, index, total) {
  const start = index * ARCHIVE_CHUNK
  const end = Math.min(start + ARCHIVE_CHUNK, total) - 1

  const response = await fetch(member, { headers: { Range: `bytes=${start}-${end}` } })
  if (response.status !== 206) throw new Error(`HTTP ${response.status}`)

  const body = await response.arrayBuffer()
  const headers = new Headers()
  headers.set("Content-Type", response.headers.get("Content-Type") || "application/octet-stream")
  // On the response as well, because serving a range reads the total from here.
  headers.set("coldwire-archive-total", String(total))

  await cache.put(chunkKey(member, index, { total, size: body.byteLength }),
                  new Response(body, { status: 200, headers }))
}

// Resumable by construction: every chunk already stored is skipped, so an interrupted download
// picks up where it stopped rather than starting again. Sequential on purpose — this is a
// large download over somebody's connection, and running it in parallel lanes would take the
// bandwidth the app itself is using.
//
// The small files are fetched every time rather than skipped. They cost a few hundred KB
// against hundreds of megabytes, and it makes Download again mean something: a style that
// changed is picked up without making anybody remove the archive and pull it all down.
async function downloadArchive(url) {
  const archive = archiveSet(url)
  if (!archive) return { ok: false, error: "Not a listed archive" }
  if (forcedOffline) return { ok: false, offline: true, reason: "forced" }

  const cache = await caches.open(CACHE_NAME)

  // Planned in full before anything is fetched, so progress counts the whole download rather
  // than restarting at each file.
  const plan = []
  for (const member of archive.urls) {
    if (!isChunked(member)) {
      plan.push({ member, chunked: false })
      continue
    }

    let total
    try {
      total = await archiveTotal(member)
    } catch (error) {
      return { ok: false, offline: true, error: error.message }
    }

    for (let index = 0; index < chunkCount(total); index++) {
      plan.push({ member, chunked: true, index, total })
    }
  }

  const count = plan.length
  let stored = 0

  for (const step of plan) {
    try {
      if (!step.chunked) {
        await fetchAndCache(cache, step.member)
      } else if (!(await cache.match(chunkKey(step.member, step.index)))) {
        await storeChunk(cache, step.member, step.index, step.total)
      }
    } catch (error) {
      // Everything already stored stays stored, so asking again resumes from here.
      const failure = { ok: false, url, error: error.message, done: stored, total: count }
      await notifyClients({ type: ARCHIVE_MESSAGE, state: "finished", ...failure })

      return failure
    }

    stored += 1
    notifyClients({ type: ARCHIVE_MESSAGE, url, state: "progress", done: stored, total: count })
  }

  const finished = { ok: true, url, done: stored, total: count, complete: true }
  await notifyClients({ type: ARCHIVE_MESSAGE, state: "finished", ...finished })

  return finished
}

async function removeArchive(url) {
  const archive = archiveSet(url)
  if (!archive) return { ok: false, error: "Not a listed archive" }

  const cache = await caches.open(CACHE_NAME)
  const members = new Set(archive.urls.map(bareHref))
  let removed = 0

  for (const key of await cache.keys()) {
    if (!members.has(bareHref(key.url))) continue
    if (await cache.delete(key)) removed += 1
  }

  return { ok: true, url, removed }
}
