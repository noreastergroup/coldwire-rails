function shouldHandle(request) {
  if (request.method !== "GET") return false

  const url = new URL(request.url)
  if (!cacheableOrigin(url)) return false

  // A Range request cannot be stored as it arrives — cache.put refuses a 206 — so it is
  // stored as a 200 under a key naming the range, and answered with a 206 built here. Only
  // for URLs nominated for it: everything else streams straight to the network, which is what
  // you want for media, and leaves ordinary requests exactly as they were.
  if (request.headers.has("Range")) return matchesRules(url, CACHE_RANGES)

  return !matchesPath(url, NEVER_INTERCEPT)
}

// Our own origin, plus any the host app has nominated. A worker sees every request a page
// makes, and caching other people's responses uninvited is not its business.
function cacheableOrigin(url) {
  return url.origin === self.location.origin || CACHE_ORIGINS.includes(url.origin)
}

function matchesPath(url, paths) {
  return paths.some((path) => url.pathname === path || url.pathname.startsWith(`${path}/`))
}

// Rules arrive as plain objects so a Regexp survives the trip through JSON.
function compileRules(rules) {
  return rules.map((rule) =>
    rule.type === "regexp" ? new RegExp(rule.source, rule.flags) : segments(rule.value))
}

function segments(value) {
  return value.split("/").filter(Boolean)
}

// Strings are route-shaped and match nothing beyond their own shape: "/sites" is /sites and
// not /sites/1, ":id" is exactly one segment, and a trailing "*" takes the rest. A Regexp is
// tested against the whole path.
//
// Deliberately strict. A prefix rule reads as "this section of the app", but it quietly takes
// everything underneath — search results, new/edit forms, nested collections — and with
// `ignore_query_params` a single "/sites/search" entry ends up answering every search.
function matchesRules(url, rules) {
  return rules.some((rule) =>
    rule instanceof RegExp
      ? rule.test(url.pathname)
      : matchesPattern(segments(url.pathname), rule)
  )
}

function matchesPattern(path, pattern) {
  for (let index = 0; index < pattern.length; index++) {
    const part = pattern[index]

    // "*" is only ever the last segment — the Ruby side refuses it anywhere else — and takes
    // everything remaining, so there has to be something remaining.
    if (part === "*") return path.length > index
    if (index >= path.length) return false
    if (part.charAt(0) === ":") continue
    if (part !== path[index]) return false
  }

  return path.length === pattern.length
}

// Whether *automatic* caching may store this. The precache manifest deliberately skips this
// check: listing a URL there is an explicit instruction, and quietly declining it would make
// the manifest unpredictable.
// The one veto. Nothing stores a response for a URL named here — not browsing, not a page
// that references it, not the precache manifest. Meaningful only for our own paths: another
// origin's URLs are not ours to describe.
function isNeverCacheable(url) {
  return url.origin === self.location.origin && matchesRules(url, NEVER_CACHEABLE)
}

// Whether *browsing* to this stores it. Says nothing about the subresources of what it stores:
// a page comes with what it needs to render, which is not a second decision. The precache
// manifest skips this check entirely — listing a URL there is an explicit instruction.
function isAutoCacheable(request) {
  const url = new URL(request.url)

  // A nominated origin is the opt-in; the path lists describe this app's own surfaces and say
  // nothing useful about somebody else's.
  if (url.origin !== self.location.origin) return CACHE_ORIGINS.includes(url.origin)

  if (isNeverCacheable(url)) return false
  if (CACHE_AS_YOU_GO.length === 0) return true

  return matchesRules(url, CACHE_AS_YOU_GO)
}

// Whether a stored copy may answer without asking the network. Says nothing about what may be
// stored — only about how long a stored thing is allowed to speak for.
//
// The test is whether the address outlives the contents. A digest in the URL means it does
// not, so the copy in hand is the current one and fetching again could only return it a
// second time. Anything else is fetched fresh with the cache behind it.
//
// Another origin is nominated wholesale and its URLs are not ours to describe — a CDN names
// its versions in the path, and the alternative is a network round trip for every glyph and
// tile a map asks for.
function isCacheFirst(request) {
  const url = new URL(request.url)
  if (url.origin !== self.location.origin) return true

  return matchesRules(url, CACHE_FIRST)
}

// A followed redirect is the trap that breaks a signed-out cold launch. `cache.put()`
// stores one happily — it does NOT reject — so "/" ends up holding the sign-in page body,
// and the stored response keeps `redirected: true`. Serving that for a navigation is a
// network error by spec, so the app fails to launch offline rather than showing the
// cached page. Never store one.
function isCacheable(request, response) {
  return request.method === "GET" && response.ok && !response.redirected
}
