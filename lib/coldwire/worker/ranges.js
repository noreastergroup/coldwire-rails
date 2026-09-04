// Stitched out of whatever chunks are stored. Blob slices reference bytes rather than copying
// them, so answering a tile request out of a 300 MB archive costs about as much as answering
// it out of a single stored range.
async function rangeFromChunks(cache, request, spec) {
  const bare = new URL(request.url)
  bare.search = ""
  if (!CACHE_ARCHIVES.includes(bare.href)) return null

  const first = Math.floor(spec.start / ARCHIVE_CHUNK)
  const parts = []
  let total = null
  let index = first
  let wanted = spec.end === null ? Infinity : spec.end - spec.start + 1
  let taken = 0

  while (taken < wanted) {
    const stored = await cache.match(chunkKey(bare.href, index))
    // A gap: fall back rather than answer with a hole in the middle.
    if (!stored) return null

    total = total || Number(stored.headers.get("coldwire-archive-total")) || null
    const blob = await stored.blob()
    const offset = index * ARCHIVE_CHUNK
    const from = Math.max(spec.start - offset, 0)
    const to = wanted === Infinity ? blob.size : Math.min(from + (wanted - taken), blob.size)

    parts.push(blob.slice(from, to))
    taken += to - from
    index += 1

    // Ran off the end of the archive, which is a legitimate end to an open-ended range.
    if (total && offset + blob.size >= total) break
    if (to < blob.size) break
  }

  if (!parts.length) return null

  const body = new Blob(parts)
  const headers = new Headers()
  const type = "application/octet-stream"
  headers.set("Content-Type", type)
  headers.set("Content-Length", String(body.size))
  headers.set("Content-Range", `bytes ${spec.start}-${spec.start + body.size - 1}/${total || "*"}`)
  headers.set("Accept-Ranges", "bytes")

  return new Response(body, { status: 206, statusText: "Partial Content", headers })
}

// Cache first, always. A byte range of an archive is immutable for as long as the archive is,
// and the entire point of caching one is to stop asking for it.
async function handleRange(request) {
  const spec = parseRange(request.headers.get("Range"))
  // A single closed range is what a tile archive asks for. Multipart, or anything unparseable,
  // is not something to take apart and reassemble — send it and store nothing.
  if (!spec) return fetch(request)

  const cache = await caches.open(CACHE_NAME)

  // A fully downloaded archive answers everything, so try it before anything else.
  const fromChunks = await rangeFromChunks(cache, request, spec)
  if (fromChunks) return fromChunks

  const key = rangeKey(request, spec)
  // Deliberately not MATCH_OPTIONS: `ignore_query_params` would collapse every range of a
  // file onto one entry, since the range lives in the query.
  const stored = await cache.match(key, { ignoreVary: true })

  if (stored) return partialResponse(stored, spec)
  if (forcedOffline) return rangeUnavailable()

  try {
    const response = await fetch(request)
    if (response.status !== 206) return response

    // Clone before reading: the body is needed twice, once to store and once to return.
    const body = await response.clone().arrayBuffer()
    const headers = new Headers()
    const type = response.headers.get("Content-Type")
    if (type) headers.set("Content-Type", type)
    headers.set(RANGE_TOTAL_HEADER, String(rangeTotal(response.headers.get("Content-Range")) ?? ""))
    headers.set(TIMESTAMP_HEADER, String(Math.floor(Date.now() / 1000)))

    cache.put(key, new Response(body, { status: 200, headers }))

    return response
  } catch {
    return rangeUnavailable()
  }
}

// The stored body *is* the range that was asked for, so this is only about the headers a
// partial response has to carry.
async function partialResponse(stored, spec) {
  const body = await stored.arrayBuffer()
  const total = stored.headers.get(RANGE_TOTAL_HEADER) || "*"
  const headers = new Headers()
  const type = stored.headers.get("Content-Type")
  if (type) headers.set("Content-Type", type)
  headers.set("Content-Length", String(body.byteLength))
  headers.set("Content-Range", `bytes ${spec.start}-${spec.start + body.byteLength - 1}/${total}`)
  headers.set("Accept-Ranges", "bytes")

  return new Response(body, { status: 206, statusText: "Partial Content", headers })
}

// 504 rather than the offline page: whatever asked for a byte range wants bytes, and handing
// it HTML would be answered with a parse error instead of a failure it can report.
function rangeUnavailable() {
  return new Response(null, { status: 504, statusText: "Offline" })
}

function parseRange(value) {
  const match = /^bytes=(\d+)-(\d*)$/.exec(String(value || "").trim())
  if (!match) return null

  const start = Number(match[1])
  const end = match[2] === "" ? null : Number(match[2])
  if (end !== null && end < start) return null

  return { start, end }
}

function rangeTotal(contentRange) {
  const match = /\/(\d+)\s*$/.exec(String(contentRange || ""))

  return match ? Number(match[1]) : null
}

// The range goes in the query so it is part of the cache key, and the request is never sent
// anywhere, so the extra parameter cannot confuse a server.
function rangeKey(request, spec) {
  const url = new URL(request.url)
  url.searchParams.set(RANGE_PARAM, `${spec.start}-${spec.end ?? ""}`)

  return new Request(url.href, { method: "GET" })
}
