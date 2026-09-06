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

async function fetchAndCache(cache, href, { managed = false } = {}) {
  const request = new Request(href, { credentials: "same-origin" })
  // Skipped rather than failed: the app asked for this URL never to be stored, and a manifest
  // that also names it is a contradiction to resolve quietly in favour of not storing.
  if (isNeverCacheable(new URL(request.url))) return []

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

async function handleFetch(request, event) {
  const cache = await caches.open(CACHE_NAME)
  const cached = await cache.match(request, MATCH_OPTIONS)

  if (forcedOffline) return (await cachedPageResponse(cache, request, cached)) || offlineResponse(request)

  // A digested address is answered from the cache; everything else is refetched so the copy
  // stays as good as the network allows. Through cachedPageResponse rather than returned as
  // it is, so cached HTML is untracked and marked whichever branch it leaves by.
  if (cached && isCacheFirst(request)) return cachedPageResponse(cache, request, cached)

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
    return (await cachedPageResponse(cache, request, cached)) || offlineResponse(request)
  }
}

// A page is stored with whatever it asks for. The lists say which pages are worth keeping as
// you browse; what one needs in order to render is not a second question, and a page held
// without its stylesheet is the offline equivalent of not holding it at all.
async function storeResponse(cache, request, response) {
  await putFresh(cache, cacheKey(request), response.clone())

  const type = response.headers.get("Content-Type") || ""
  if (!type.includes("text/html")) return

  const urls = urlsFromHtml(await response.text(), request.url)
  await Promise.all(urls.map((href) => storeSubresource(cache, href)))
}

// Only what is missing. A digested address is stored once and then named by every page that
// uses it, so after the first visit this settles down to a lookup and nothing else.
async function storeSubresource(cache, href) {
  if (isNeverCacheable(new URL(href))) return
  if (await cache.match(href, MATCH_OPTIONS)) return

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
async function cachedPageResponse(cache, request, cached) {
  if (!cached || !wantsHtml(request)) return cached

  const type = cached.headers.get("Content-Type") || ""
  if (!type.includes("text/html")) return cached

  const html = await cached.clone().text()
  if (!/<html\b/i.test(html)) return cached

  let body = untrack(html)

  if (MARK_CACHED_PAGES) {
    // The timestamp rides on the stored key, so ask the cache for the key that matched.
    const [ key ] = await cache.keys(request, MATCH_OPTIONS)
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
