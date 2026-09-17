// One entry per URL. cache.put() replaces an entry only where the two agree about Vary, and
// Rails answers HTML with `Vary: Accept` — so precaching (`*/*`) and a Turbo visit
// (`text/html`) are two records of one page, which WebKit keeps and Chrome collapses.
//
// Not ignoreSearch: range and chunk entries share the path with their own query, and a page
// write must never take a downloaded archive with it.
async function putFresh(cache, key, response) {
  await cache.delete(key, { ignoreVary: true })
  await cache.put(key, response)
}

async function fetchAndCache(cache, href, { managed = false, frame = null, accept = null } = {}) {
  const headers = {}
  // A manifest listing that names a frame or a format is asking for the body a request like
  // that would get, so the request has to look like one.
  if (frame) headers["Turbo-Frame"] = frame
  if (accept) headers.Accept = accept

  const request = new Request(href, { credentials: "same-origin", headers })
  // Skipped rather than failed: the app asked for this URL never to be stored, and a manifest
  // that also names it is a contradiction to resolve quietly in favour of not storing.
  if (isNeverCached(new URL(request.url))) return []

  const response = await fetch(request)
  if (!isCacheable(request, response)) {
    throw new Error(response.redirected ? `Redirected to ${response.url}` : `HTTP ${response.status}`)
  }

  const key = managed
    ? cacheKey(request, { managed, frame })
    : await bodyKey(cache, request, response)
  await putFresh(cache, key, response.clone())

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
        if (!cacheableHost(url)) return
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

// The network answers whenever it can, and the cache is what is left when it cannot. Nothing
// here second-guesses the browser about what it already holds: an asset is served from the
// browser's own cache without a request either way, and a worker sitting in front of that can
// only get it wrong.
//
// So the cache is not even consulted until the network has failed. There is no lookup on the
// path where everything is working.
async function handleFetch(request, event) {
  const cache = await caches.open(CACHE_NAME)

  if (forcedOffline) return offlineFallback(cache, request)

  try {
    const response = await fetch(request)
    if (isCacheable(request, response) && isAutoCacheable(request)) {
      // waitUntil rather than a promise left running: a worker can be stopped the moment it
      // has answered, and a page stored without the stylesheet it names is worse offline than
      // a page not stored at all.
      const stored = storeResponse(cache, request, response.clone())
      if (event) event.waitUntil(stored)
    }
    return response
  } catch {
    return offlineFallback(cache, request)
  }
}

async function offlineFallback(cache, request) {
  const key = await matchStored(cache, request)
  const cached = key ? await cache.match(key) : undefined

  return (await cachedPageResponse(request, key, cached)) || offlineResponse(request)
}

// Which stored entry answers this request. One URL can hold the page and a frame of the same
// name, so this asks for the kind of body the request wants rather than taking whatever the
// URL turns up — and with ignoreSearch on, what it turns up might be a frame, a byte range, or
// a chunk of an archive.
//
// A frame takes its own entry first and a whole page second: an app that answers frame
// requests with the full document stores one of those, and Turbo pulls the frame out of it
// exactly as it does online. The trade never runs the other way. A fragment served to an
// ordinary visit is a document with no <html>, which is a blank screen, and in Hotwire Native
// a page where window.Turbo never appears.
async function matchStored(cache, request) {
  const frame = request.headers.get("Turbo-Frame")

  if (frame) {
    // Asked for by name rather than found by scanning. With ignore_query_params off the search
    // has to match exactly, and a request carrying no query would never turn up the key that
    // carries the frame in its own.
    const [ own ] = await cache.keys(variantUrl(request.url, { frame }), { ignoreVary: true })
    if (own) return own
  }

  // Asked for by name, for the same reason the frame is.
  const format = formatOf(request)
  if (format !== "page") {
    const [ named ] = await cache.keys(variantUrl(request.url, { format }), { ignoreVary: true })
    if (named) return named
  }

  const keys = await cache.keys(request, MATCH_OPTIONS)
  const page = keys.find((candidate) => variantOf(candidate) === "page")
  if (!page) return undefined

  // The unnamed entry is the right answer for anything cached before formats were named, and
  // for every asset a precache stored without an Accept to go on. It is the wrong answer for a
  // fetch that asked for data and would be handed a page, which is the mistake that gives a
  // stylesheet an HTML body. So ask what it holds before handing it over.
  if (format === "page") return page

  const held = await cache.match(page)

  return (held && !(held.headers.get("Content-Type") || "").includes("text/html")) ? page : undefined
}

// Where a body that is not a page goes: named by the format the request asked for, unless this
// URL already holds something that is not a page.
//
// That exception is the whole reason this is a function. A precache carries no Accept and lands
// on the unnamed key; the browser then asks for the same stylesheet as `text/css` and would
// write a second copy beside it. Two of every stylesheet and every image is not a rounding
// error on a phone.
//
// The lookup is only paid where a name would be written at all, so `*/*` requests — scripts,
// fonts, and precaching itself — cost nothing extra.
async function bodyKey(cache, request, response) {
  if (formatOf(request) !== "page") {
    const [ plain ] = await cache.keys(variantUrl(request.url, {}), { ignoreVary: true })
    const held = plain ? await cache.match(plain) : null
    if (held && !(held.headers.get("Content-Type") || "").includes("text/html")) {
      return cacheKey(request, { frame: null, format: "page" })
    }

    return cacheKey(request, { frame: null })
  }

  // A URL that names its own format is the same key from every direction, so there is nothing
  // another request could have named differently and nothing to look for.
  if (extensionFormat(request.url) !== "page") return cacheKey(request, { frame: null })

  // And the other way round: this request named nothing, but the browser may already have
  // stored the same file under the format it asked for. Work that name out from what came
  // back, rather than writing a second copy beside it.
  const guess = formatFromType(response)
  if (guess !== "page") {
    const [ named ] = await cache.keys(variantUrl(request.url, { format: guess }), { ignoreVary: true })
    if (named) return cacheKey(request, { frame: null, format: guess })
  }

  return cacheKey(request, { frame: null })
}

// What a browser's Accept would have produced for a body like this. Only the two families a
// browser asks for by type: a script or a font arrives on `*/*` and is unnamed on both sides,
// so neither pays for this lookup.
function formatFromType(response) {
  const type = (response.headers.get("Content-Type") || "").split(";")[0].trim().toLowerCase()
  if (type.startsWith("text/css")) return "css"
  if (type.startsWith("image/")) return "image"

  return "page"
}

// A page is stored with whatever it asks for. The lists say which pages are worth keeping as
// you browse; what one needs in order to render is not a second question, and a page held
// without its stylesheet is the offline equivalent of not holding it at all.
async function storeResponse(cache, request, response) {
  const type = response.headers.get("Content-Type") || ""
  if (!type.includes("text/html")) {
    await putFresh(cache, await bodyKey(cache, request, response), response.clone())
    return
  }

  // Read before writing, because what this is decides where it goes. Cloning twice is free:
  // each clone tees the stream, so consuming one leaves the other whole.
  const body = await response.clone().text()
  // A frame request the app answered with the entire document is a page like any other, and
  // Turbo will find the frame inside it. Storing that under a frame key would hold the same
  // bytes twice and leave the next ordinary visit unable to find them.
  const frame = /<html\b/i.test(body) ? null : request.headers.get("Turbo-Frame")

  await putFresh(cache, cacheKey(request, { frame }), response.clone())

  const urls = urlsFromHtml(body, request.url)
  await Promise.all(urls.map((href) => storeSubresource(cache, href)))
}

// Only what is missing is fetched. What is already held is renewed instead, so an asset every
// page names does not sit on the stamp of the first page that ever pulled it in and get
// collected while the whole app is still using it.
async function storeSubresource(cache, href) {
  if (isNeverCached(new URL(href))) return

  // Any body for this URL that is not a frame of it and not a piece of a download. Asking only
  // for the unnamed one would refetch a stylesheet the browser has already stored under its
  // own format, and land a second copy of it here.
  const key = (await cache.keys(href, MATCH_OPTIONS)).find((held) => {
    const variant = variantOf(held)

    return variant !== "download" && !variant.startsWith("frame:")
  })
  if (key) return renew(cache, key)

  try {
    await fetchAndCache(cache, href)
  } catch {
    // One subresource that will not fetch is no reason to lose the page.
  }
}

// Turbo will not render a page whose data-turbo-track="reload" elements differ from the
// current page's; it reloads instead, to pick up the new assets. Offline there are none to
// pick up and the reload is answered from this same cache, so it costs a document load that
// Hotwire Native can hang on.
//
// Asset digests change with every deploy, so any page cached before the current one was built
// disagrees with it — nothing served from this cache is tracked. A live page still is, so the
// first fresh page after the connection returns still reloads, which is what was wanted.
function untrack(html) {
  return html.replace(/\sdata-turbo-track\s*=\s*(?:"reload"|'reload'|reload)(?=[\s>/])/gi, "")
}

// Everything answered from the cache: untracked always, marked when mark_cached_pages is on.
//
// Two markers, read at different moments. The <html> attributes are for the first paint of a
// cold boot, before any JS runs. The <meta> is for Turbo visits, which merge the head but
// never copy <html> attributes.
async function cachedPageResponse(request, key, cached) {
  if (!cached || !wantsHtml(request)) return cached

  const type = cached.headers.get("Content-Type") || ""
  if (!type.includes("text/html")) return cached

  const html = await cached.clone().text()
  if (!/<html\b/i.test(html)) return cached

  let body = untrack(html)

  if (MARK_CACHED_PAGES) {
    // The timestamp rides on the stored key, which the caller has already had to find: asking
    // the cache again could pick a different entry for the same URL than the one being served.
    const cachedAt = key ? key.headers.get(TIMESTAMP_HEADER) : null
    const stamp = cachedAt ? ` ${CACHED_AT_ATTRIBUTE}="${escapeHtml(cachedAt)}"` : ""

    body = body
      .replace(/<html\b([^>]*)>/i, `<html$1 ${OFFLINE_ATTRIBUTE}${stamp}>`)
      .replace(/<head\b([^>]*)>/i, `<head$1><meta name="coldwire-offline" content="${escapeHtml(cachedAt || "")}">`)
  }

  // Rewriting changed the length, so the stored Content-Length no longer describes the
  // body — carrying it over invites the consumer to truncate the page. Drop it and let the
  // response report its own length.
  const headers = new Headers(cached.headers)
  headers.delete("Content-Length")

  return new Response(body, {
    status: cached.status,
    statusText: cached.statusText,
    headers
  })
}

// Turbo Drive visits and frame loads ask for HTML; assets and JSON do not. Handing an HTML
// body to a stylesheet or an <img> just produces a broken asset, so those fail instead.
function wantsHtml(request) {
  if (request.mode === "navigate" || request.destination === "document") return true

  return (request.headers.get("Accept") || "").includes("text/html")
}

function offlineResponse(request) {
  if (!wantsHtml(request)) {
    return new Response("", { status: 504, statusText: "Offline" })
  }

  // A frame request only ever renders a matching <turbo-frame>; the full page would be
  // discarded and the frame would sit on its loading state forever.
  const frame = request.headers.get("Turbo-Frame")

  return new Response(frame ? offlineFrame(frame, request.url) : OFFLINE_PAGE, {
    // 200 on purpose. Hotwire Native treats a non-2xx visit as a failed request and shows
    // its own native error screen, so an error-status body is never rendered.
    status: 200,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store"
    }
  })
}

// The frame template is baked when the worker is built, so it cannot know which URL it will
// stand in for. Substitute it here: a retry link inside a frame has to point at the frame's
// own URL, since an empty href would resolve to the page and load the whole document into
// the card.
function offlineFrame(id, url) {
  const content = OFFLINE_FRAME_CONTENT.split(RETRY_URL_TOKEN).join(escapeHtml(url))

  return `<turbo-frame id="${escapeHtml(id)}">${content}</turbo-frame>`
}

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, (character) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;"
  })[character])
}
