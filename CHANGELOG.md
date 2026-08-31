# Changelog

## [Unreleased]

- The debug page starts its own sync when its countdown runs out, through the same path as
  its button — spinner, progress bar and all. It used to only *display* a deadline that a
  separate head snippet was responsible for acting on, and whenever those two clocks
  disagreed the page sat on "due now" with nothing scheduled and no way to tell which half
  had failed. The snippet still drives every other page in the app.

- The manifest is fetched with `cache: "no-store"`. A heuristically-cached copy had a sync
  faithfully fetching an old list, missing exactly the newly published pages auto-sync exists
  to pick up.

- Automatic sync actually happens while you sit on a page. It used to fire only on load and
  on a Turbo visit, so a page left open sat past its interval indefinitely and nothing synced
  until you navigated. On load the snippet now works out when a sync is next owed and sleeps
  exactly that long — no polling, and an overdue deadline runs immediately. It re-arms on
  returning to the foreground too, since a backgrounded web view freezes its timers. The
  debug page shows a live countdown to the next one.

- The debug page asks the worker what it missed when it connects. A sync starts while the
  page is still parsing, so a short run could begin and end before the page was listening,
  leaving it on "Idle" through a sync it had caused itself.

- A sync that keeps failing backs off for an interval instead of retrying every second, and
  it no longer does that by writing the success stamp. "Synced 2 minutes ago" now only ever
  describes a run that completed.

- There is one way to fill the cache. "Precache" was a second path that fetched the manifest
  in the page and cached every URL regardless of age; it is gone, and "Sync now" runs the same
  pass the background sync runs, just without waiting for the interval. The `prefetch` worker
  message went with it. To rebuild from nothing, clear the cache and sync.

- The debug page shows a live progress bar for *any* sync, not just one started by its own
  button — the automatic one is the one that usually runs, and it used to move nothing but a
  line of text. The "finished" broadcast is authoritative, so a worker that restarts mid-run
  cannot leave the page spinning forever.

- Debug page is titled "Offline settings" and shows a status light beside the network row:
  green online, amber forced offline, red no connection.

- A sync now works through the whole manifest in one pass, through a bounded concurrent pool
  (`sync_concurrency`, default 4), retrying each URL once. Replaces `sync_batch_limit`, which
  spread a first run across page loads and made syncing feel like it had stalled.

- Renamed the gem to `coldwire-rails`, following turbo-rails and importmap-rails. The module
  is still `Coldwire`, so nothing in an app's own code changes — only the Gemfile line.

- `auto_sync`: the worker keeps the precache manifest current on its own. Fetches newly
  listed URLs, refetches copies older than `max_age`, retires URLs the manifest dropped, and
  stops at `sync_batch_limit` per run. Triggered on page load and throttled, because WebKit
  has no Background Sync to schedule against. An interrupted sync resumes on the next page
  load — the clock only restarts once the manifest is fully in sync, and each pass recomputes
  what is missing from the cache rather than tracking progress. The debug page shows sync
  state live — including syncs it did not start — and offers a "Sync now" button. Retiring only touches entries the manifest
  owns, so assets and casually-browsed pages are left alone.

- `cache_allowlist` and `cache_blocklist` govern automatic caching, and take strings
  (segment-prefix) or Regexps. The precache manifest ignores both: listing a URL there is an
  explicit instruction. Replaces `uncached_paths`, which also blocked precaching.
  A list entry of `"/"` now survives instead of being chomped to an empty string and
  silently dropped, so the root path can be listed.
  Patterns are validated on assignment — `\A`/`\z`/`\Z` and the `x`/`m` flags are rejected
  rather than silently never matching once JavaScript evaluates them.

- Offline page and frame each offer a "Try again" link. The page retries the URL it was
  served for; the frame retries just that frame via the `coldwire:retry-url` token.
- Plainer copy on both fallbacks — no more talk of the cache.
- The offline page respects safe-area insets on all four sides, with `viewport-fit=cover`
  so they resolve at all. Hotwire Native apps often run the web view edge to edge.
- The offline page paints its own background and adapts to dark mode. It had none, so a
  dark-mode device rendered dark text on the UA's dark default.

- `offline_entry_point`: the offline page now boots Turbo through the host's importmap.
  Hotwire Native rejects any page where `window.Turbo` never appears, so the previous
  plain-HTML fallback could never render in the app — it reported "Turbo is not present"
  and showed the SDK's error screen instead.

- `probe_path` (default `/up`): what the debug page pings to tell online from offline. Always
  excluded from interception, since a probe the worker answers resolves even with the network
  down.

### Fixed

- The debug page could report Offline without ever checking. It short-circuited on
  `navigator.onLine`, which a web view reports unreliably in **both** directions. The probe
  is now the only source of truth. Automatic sync was gated on it too, so a false negative
  there meant syncing never ran at all.

- The debug page's Refresh gave no sign it had run and abandoned the rest of a refresh
  silently if any one step failed. It now spins while working and reports what went wrong.
  Listing the cache also reads sizes from `Content-Length` instead of pulling every response
  body into a blob.

- Forced offline switched itself off mid-session. The worker holds the flag in a variable and
  browsers shut idle workers down, so it is now re-asserted from `localStorage` on every page
  load and holds across the whole app.

- The debug page reported "Online" while the server was unreachable. It read
  `navigator.onLine`, which only says whether a network interface is up — true whenever wifi
  is on, including with the server stopped. It now probes the server and distinguishes
  "Offline" from "Offline · server unreachable".

- The debug page can now be cached. Coldwire excluded its whole mount point from
  interception, which also made the debug page unreachable offline — exactly when you want
  to look at the cache. Only the worker script and the manifest are excluded now; allowlist
  the page like any other to have it offline.

- The offline page's stylesheet no longer leaks into the app. Turbo's head merge copies new
  `<style>` elements in and never removes them, so visiting the offline page installed its
  `body { padding: … }` rule for the rest of the session and every later page rendered with
  the wrong spacing until a full reload. The CSS now lives in the body, scoped to
  `.coldwire-offline`.

- `offline_head`: the offline page can now carry the host's `data-turbo-track` elements.
  Without them Turbo refused to render it and invalidated instead, and Hotwire Native answers
  an invalidation by showing a spinner and reloading — which sticks when it happens mid-pop
  on a back navigation, leaving the app frozen until it is quit.

- The cache identity check wiped the whole cache whenever `localStorage` was empty.
  `getItem` returns null when nothing is stored, and localStorage and the cache store are
  evicted independently, so a browser that had simply lost its localStorage discarded a
  complete cache on the next page load — a cold launch would then open to the offline page
  with everything it needed already downloaded. A missing value now just gets recorded. The
  cache is also never discarded while offline, when it cannot be refilled.

- The registration snippet threw before reaching `navigator.serviceWorker.register`,
  disabling caching entirely. `})()` followed by `(function` on the next line parses as one
  call expression — ASI does not separate them — so the joined fragments needed terminating
  semicolons.
- Drop `Content-Length` when rewriting a cached body for the offline marker. The injected
  attributes make the body longer, so the stored value understated it and invited the
  consumer to truncate the page.

- `offline_marker` (default on): HTML served from cache because the network was unavailable
  is stamped with `data-coldwire-offline` and `data-coldwire-cached-at` on `<html>`, plus a
  matching head `<meta>` so the marker survives Turbo visits. Lets a page say it is stale
  and how stale.

- `uncached_paths`: intercepted but never stored. `excluded_paths` means never intercepted,
  which offline fails as a network error rather than reaching the offline fallback — the
  wrong tool for sign-in pages.

- `ignore_query_params` (default on): treat `/map` and `/map?lat=1&zoom=9` as one cached
  page, both when matching and when storing. Blunt for now — it also collapses query
  strings that select content, like `/search?q=`.

- Never cache a followed redirect. A signed-out request stored the sign-in page under the
  original URL, and the `redirected` flag survived the cache, which made a navigation served
  from cache a network error — an offline cold launch failed instead of showing the page.
- `cache_identity` config: drops the cache when the signed-in user changes, so signing out
  or switching accounts does not leave the previous session's pages readable offline.
- The debug page reports "Signed out" instead of a JSON parse error when the precache
  manifest request is redirected to a login page.

## [0.1.0]

Initial extraction from the Mita app.

- Cache API service worker served by a mountable Rails engine
- Precache manifest supplied by the host app, with streamed progress
- Offline fallback that Turbo and Hotwire Native actually render (200, frame-aware)
- Debug page: cache inspector, precache, clear, force offline
