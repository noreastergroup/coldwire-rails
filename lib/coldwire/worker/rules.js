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
function isAutoCacheable(request) {
  const url = new URL(request.url)

  // A nominated origin is the opt-in; the path lists describe this app's own surfaces and say
  // nothing useful about somebody else's.
  if (url.origin !== self.location.origin) return CACHE_ORIGINS.includes(url.origin)

  if (matchesRules(url, CACHE_BLOCKLIST)) return false
  if (CACHE_ALLOWLIST.length === 0) return true

  return matchesRules(url, CACHE_ALLOWLIST)
}

// A followed redirect is the trap that breaks a signed-out cold launch. `cache.put()`
// stores one happily — it does NOT reject — so "/" ends up holding the sign-in page body,
// and the stored response keeps `redirected: true`. Serving that for a navigation is a
// network error by spec, so the app fails to launch offline rather than showing the
// cached page. Never store one.
function isCacheable(request, response) {
  return request.method === "GET" && response.ok && !response.redirected
}
