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

async function handleFetch(request) {
  const cache = await caches.open(CACHE_NAME)
  const cached = await cache.match(request, MATCH_OPTIONS)

  if (forcedOffline) return (await cachedPageResponse(cache, request, cached)) || offlineResponse(request)

  // Pages recache on every view so the copy stays fresh; assets stay cache-first, or every
  // stylesheet would bury the page in the inspector's recent list.
  if (cached && !wantsHtml(request)) return cached

  try {
    const response = await fetch(request)
    if (isCacheable(request, response) && isAutoCacheable(request)) {
      putFresh(cache, cacheKey(request), response.clone())
    }
    return response
  } catch {
    return (await cachedPageResponse(cache, request, cached)) || offlineResponse(request)
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
