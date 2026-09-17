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

  // `get` answers null for a missing header, and Number(null) is 0 — which is finite, and not
  // negative, so it sails through the guard and reports the entry as weighing nothing. Rails
  // sends a great deal of HTML chunked, with no Content-Length at all, so this is not an edge
  // case: it is most pages. A collector measuring them at zero never reaches its ceiling and
  // quietly deletes nothing, reporting success the whole time.
  const declared = response.headers.get("Content-Length")
  const bytes = declared === null ? NaN : Number(declared)
  if (Number.isFinite(bytes) && bytes >= 0) return bytes

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
// `frame` names the Turbo frame this response is a body for, and is what keeps a frame out of
// the slot its page occupies. Defaults to whatever the request asked for; passed explicitly
// where the caller knows better — a frame request answered with a whole document is a page,
// and renewing an entry has to put it back where it already was.
function cacheKey(request, { managed = false, frame = request.headers.get("Turbo-Frame"), format = formatOf(request) } = {}) {
  const headers = new Headers(request.headers)
  headers.set(TIMESTAMP_HEADER, String(Math.floor(Date.now() / 1000)))
  if (managed) headers.set(MANAGED_HEADER, "1")

  // `new Request(request, init)` downgrades a navigation request's mode for us; rebuilding
  // from a URL string needs the method stated explicitly. Only available while the URL is
  // being kept as it is, which naming a variant is not: taking this path with a format to
  // write stored a JSON body under the page's own key, which is the whole bug in miniature.
  const named = Boolean(frame) || (format && format !== "page")
  if (!IGNORE_SEARCH && !named) return new Request(request, { headers })

  return new Request(variantUrl(request.url, { frame, format }), { method: "GET", headers })
}

// Where a body of this kind lives. Built in one place because it is written by cacheKey and
// looked for by matchStored, and a frame stored under a URL nothing asks for is a frame that
// never answers.
function variantUrl(url, { frame = null, format = null } = {}) {
  const target = new URL(url)
  if (IGNORE_SEARCH) target.search = ""
  if (frame) target.searchParams.set(FRAME_PARAM, frame)
  // A page is the default and says nothing, which is what leaves every entry stored before
  // formats existed exactly where it was.
  if (format && format !== "page") target.searchParams.set(FORMAT_PARAM, format)

  return target.href
}

// The format a request negotiated for, as a short token.
//
// Read from the request rather than from the response, which is the opposite of what it should
// be and is forced: the same derivation has to run when the entry is looked for again, and at
// that moment there is no response to read. With ignore_query_params off a named key can only
// be found by building its name, so a name the request cannot produce is a name nothing ever
// finds.
//
// A page is the default and is left unnamed, which is what leaves every entry cached before
// formats existed exactly where it was.
function formatOf(request) {
  const token = negotiatedFormat(request)
  if (token === "page") return "page"

  // A URL that already names its format has nothing to disambiguate. "/report.json" is JSON and
  // nothing else, where "/report" is a page, a JSON body and a CSV depending on who asks, so the
  // param there would be a second way of saying what the path already said.
  //
  // Only where the extension agrees with what was asked for. "/sites/acme.com" is a page whose
  // last segment happens to contain a dot, and ".com" says nothing about a format — so that one
  // keeps its param and stays apart from the JSON at the same URL.
  return extensionFormat(request.url) === token ? "page" : token
}

// What the path itself declares, if anything. Unknown extensions say nothing and keep their
// param, which is noisier than it needs to be and never wrong.
const EXTENSION_FORMATS = {
  json: "json", geojson: "json", css: "css", xml: "xml", rss: "xml", atom: "xml",
  csv: "csv", ics: "calendar", pdf: "pdf", txt: "plain", md: "markdown",
  png: "image", jpg: "image", jpeg: "image", gif: "image", webp: "image", avif: "image",
  svg: "image", ico: "image"
}

function extensionFormat(url) {
  const name = new URL(url).pathname.split("/").pop() || ""
  const dot = name.lastIndexOf(".")
  if (dot < 1) return "page"

  return EXTENSION_FORMATS[name.slice(dot + 1).toLowerCase()] || "page"
}

function negotiatedFormat(request) {
  const accept = (request.headers.get("Accept") || "").split(",")[0].split(";")[0].trim().toLowerCase()

  // Nothing definite asked for. A precache, a fetch that set no Accept, a browser asking for a
  // script or a font: all of them get the unnamed key, as they always have.
  if (!accept || accept === "*/*" || accept.includes("html")) return "page"

  const [ top, sub = "" ] = accept.split("/")
  // image/avif and image/webp are one question asked two ways, and which one a browser puts
  // first is not a distinction worth a second copy. The family is the answer.
  if (top && top !== "text" && top !== "application") return top

  // "application/vnd.api+json" is JSON. "text/csv" is csv.
  const parts = sub.split("+")
  const token = (parts.length > 1 ? parts[parts.length - 1] : parts[0]) || ""

  return token.replace(/[^a-z0-9.-]/g, "") || "page"
}

// What kind of body an entry holds, read back off its key. Documents have none of these
// params and answer to null, which is what an ordinary visit asks for.
function variantOf(key) {
  const params = new URL(key.url).searchParams
  // Downloads are their own thing entirely and must never answer a page request, which
  // ignoreSearch would otherwise let them do.
  if (params.has(CHUNK_PARAM) || params.has(RANGE_PARAM)) return "download"

  const frame = params.get(FRAME_PARAM)
  if (frame) return `frame:${frame}`

  return params.get(FORMAT_PARAM) || "page"
}

function unixTimestamp(value) {
  const seconds = Number(value)
  return Number.isFinite(seconds) && seconds > 0 ? seconds : null
}
