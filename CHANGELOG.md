# Changelog

## [Unreleased]

- Try again on the offline page carries a refresh icon. It keeps its empty `href` and
  `data-turbo="false"`, which are what make it reload the URL the page was served for, and the
  page still ships no script of its own.

- The debug page says "Offline is off for this device" and shows nothing else when
  `register_if` returns false. No worker was registered, so there is no cache to list, no
  clock to count down and nothing for force offline to force — an empty cache and a running
  countdown read as a broken page rather than a switched-off one.

- Clarified what this is for. Coldwire reads as a Hotwire Native library and is not one: the
  worker, the precaching, the sync and the offline fallback are plain service worker and Cache
  API work, and serve a plain Hotwire app or an installed PWA equally.

  Hotwire Native is the strictest target rather than the only one — of the six problems the
  README describes, four bite you in any browser and two are Native's extra rules. Meeting all
  six costs a browser nothing, which is why one cache covers all three. Said plainly too that
  a PWA needs a web app manifest, icons and an install prompt, and that Coldwire supplies none
  of them.

- Automatic syncing is configured as a block, because these four only mean anything together —
  a manifest with no interval is never fetched, and an interval with no manifest has nothing to
  fetch:

  ```ruby
  config.auto_sync do |sync|
    sync.enabled = true          # off by default
    sync.precache_urls = -> { ... }
    sync.interval = 6.hours
    sync.max_age = 7.days
    sync.concurrency = 4
  end
  ```

  `auto_sync` was a boolean and `precache_urls`, `sync_interval`, `refetch_after` and
  `sync_concurrency` were loose beside it. `max_age` keeps its name now that it sits next to
  the interval it is measured against; `refetch_after` was a worse answer to the same problem.
  `enabled` defaults to **false**: background fetching is a decision about somebody's data
  plan, not something to inherit.

- `register_if` takes `->() { }`, `-> { }`, or `->(request) { }`. A block that declares a
  parameter is handed the request, so caring only about headers stays a one-liner.

- `register_if` is evaluated in the view and decides everything. It receives no argument now;
  `request` and `current_user` are both in scope, so one gate can say "the native app, signed
  in" — and a page that does not register does not cache, sync, or run anything. `auto_sync_if`
  is gone: it was a second gate answering a question this one already answers.

- Config names that say what they are:

  | was | now |
  | --- | --- |
  | `scope` | `worker_scope` |
  | `excluded_paths` | `never_intercept` |
  | `max_age` | `refetch_after` |
  | `offline_marker` | `mark_cached_pages` |
  | `offline_entry_point` | `offline_import` |

- `config.auto_sync_if` — a block deciding whether *this page* may start a sync, on top of the
  `auto_sync` switch. Evaluated in the view, so `current_user` and `controller` are available:

  ```ruby
  config.auto_sync_if = -> { current_user.present? && controller.class.module_parent_name == "App" }
  ```

  The answer rides in a `coldwire-auto-sync` meta rather than being baked into the head script,
  because that script runs once per document and Turbo visits reuse it — a page that may not
  sync has to be able to say so on arrival, not only on a cold boot. A page that says nothing
  may sync, so a missing meta cannot silently stop it. The debug page reports the per-page
  answer, so it says automatic sync is off rather than counting down to something that will
  never happen; "Sync now" is unaffected, since asking by hand is not automatic syncing.

- Dropped the offline page's dark palette too, so the gem now ships no theme queries at all.
  The reduced-motion query stays: that is an accessibility preference, not a theme.

- Precaching follows subresources onto any origin in `cache_origins`, not just your own. It
  used to drop every cross-origin `<script>`, `<link>` and image, so a page whose map library
  comes off a CDN precached perfectly and then could not boot offline: the library was never
  stored, nothing constructed the map, and the tiles sat in the cache with nothing able to
  read them.

- `config.cache_origins` — origins besides your own that the worker may cache. Empty by
  default: a worker sees every request a page makes, and hoarding third-party responses
  uninvited is not its business. The origin has to send CORS headers naming your app, or the
  response arrives opaque and there is nothing worth storing.

- `config.cache_ranges` — URLs whose Range requests are cached piece by piece, keyed by the
  range. For a large immutable archive read a slice at a time — a PMTiles basemap — this is the
  difference between an offline map and nothing: the file may be hundreds of megabytes while
  the slices behind the area you actually looked at are a rounding error next to it.

  `cache.put` refuses a 206, so a range is stored as a 200 under a key naming the range and
  answered with a 206 the worker builds. Cache-first, because a byte range of an archive is
  immutable for as long as the archive is. A range nobody nominated streams straight to the
  network, so media is untouched; a range asked for offline and never fetched gets a 504, not
  an HTML offline page it would only fail to parse.

- `window.Coldwire` — `isOffline()`, `isForcedOffline()`, `cachedAt()` and `onChange()`. The
  page already knows through the `<html>` attribute and the `offline:` CSS variant, but a map
  deciding whether to reach for a remote tile source has to ask in JavaScript, and has to hear
  about it changing. `onChange` fires on every Turbo visit and when force offline is toggled.

- Cached entries with no `Content-Length` are measured from their body rather than reported as
  0 bytes. `headers.get` answers null for a header that is not there, and `Number(null)` is 0,
  which passed the "is it a sane number" guard and skipped the fallback that was already
  written for exactly this case. Active Storage proxies blobs with `send_stream`, so it sends
  no `Content-Length`, and every proxied image showed as empty.

  Listing the cache now reads entries in lanes rather than one at a time, since measuring a
  body is real I/O and this makes it actually happen.

- Allowlist and blocklist strings are route patterns rather than prefixes. `"/sites"` now
  matches `/sites` and nothing beneath it; `"/sites/:id"` takes exactly one segment; `"/sites/*"`
  restores the old greedy behaviour where it is really wanted.

  **This changes what an existing string means.** A prefix reads as "this section of the app",
  but it quietly took everything underneath — search results, `new` and `edit` forms, nested
  collections — and with `ignore_query_params` a single `/sites/search` entry answered every
  search. Anything relying on the old behaviour needs a trailing `*`.

  Malformed patterns raise at boot: a bare `sites` with no leading slash, a `*` that is not
  last, a segment like `:1`. They all used to fail the same silent way, by never matching.

- Renamed `prefetch_urls` to `precache_urls`. The rest of the library already called this the
  precache manifest, and the debug page has said "precache" throughout; the config was the odd
  one out. No alias: nothing is released yet, so a host app just renames the setting.

- Tapping a row in the cached list opens the whole URL in a dialog, wrapped rather than
  ellipsised, with its size, age, and a Delete button. The row's text is a real button, so it
  is reachable from a keyboard and announced as a control.

  The dialog centres itself rather than leaving it to the browser. A modal `<dialog>` is
  centred by the UA's `margin: auto`, and a host reset that zeroes margin on everything —
  Tailwind's preflight does exactly that — drops it into the top left corner. Escape is
  handled explicitly too, rather than resting the only way out of a modal on the browser
  firing `cancel`.

- Each row in the cached list has a trash button that removes just that entry. No confirmation:
  Clear cache asks because it throws away everything the app has to work with offline, whereas
  one entry is a small, self-repairing loss — anything the manifest lists returns on the next
  sync — and a prompt per row would be noise. The row carries the cache it came from, so a
  page holding more than one cache removes from the right one.

- Dropped the debug page's dark palette. It is a settings surface styled with plain CSS and no
  framework, and a second set of colours to keep in step with every change was not worth its
  weight. The page renders light whatever the device is set to. The reduced-motion query
  stays — that is an accessibility preference, not a theme.

- The cached list has a filter box and a sort: most recent (the default), largest first, or
  A–Z. Both work on the entries already read rather than re-inspecting the cache, which means
  asking every entry for its headers and is far too slow to repeat on each keystroke. Within
  equal timestamps the order falls back to the path, so a sync that stamped everything in the
  same second does not produce a list that reshuffles itself between renders.

- The debug page records a finished sync from the reply to its own request, not from the
  broadcast. It drives its own sync, so the head snippet stands down there — which meant that
  when a broadcast went missing, nothing recorded the outcome at all: the page read "Never
  synced" indefinitely and re-synced on every tick, because a deadline in the past is always
  due. The snippet had already been fixed this way; the page had not.

- A sync records that it ran as soon as it has been through the whole manifest, whether or not
  every URL came back. It used to require a perfect pass, so a single bad entry among hundreds
  stopped the clock for good: the app read "Never synced" for as long as that URL stayed
  broken, and re-synced constantly, because a deadline in the past is always due. What failed
  stays missing from the cache, so the next pass finds it and tries again.

  A run that was refused outright — no connection, or force offline — still does not count. It
  leaves the clock alone and waits an interval, so "Synced N ago" keeps meaning when the cache
  was genuinely last brought up to date.

- Removed `sync_max_attempts`, and the attempt counter and backoff behind it. They existed to
  stop an unfinishable manifest retrying forever; now that every retry waits an interval and a
  partial pass counts, they no longer decided anything.

- Everything Coldwire remembers goes through one small `window.coldwireStore` wrapper, defined
  once in the head: one set of key names, one try/catch, and no chance of the head snippet and
  the debug page disagreeing about where something is kept. It replaces three different idioms
  across two files — including the cookie the last-synced time briefly used, which is back in
  localStorage with everything else.

  localStorage throws rather than returning null in a private window and can be evicted whole,
  so every write is mirrored in memory and read back from there when the store has nothing.
  That guard used to protect only the sync clock; it now covers every key.

- Syncing stops while force offline is on. The switch asks for no network at all, but the
  worker's own fetches never pass through its fetch handler, so a sync went to the network
  regardless. The page checks before asking and the worker refuses when asked — both, because
  a restarted worker loses the flag and a long-lived page can be out of date. The debug page
  says "paused, force offline is on" instead of counting down to nothing.

- No connection is treated as a wait rather than a failed attempt. It counts against nothing
  and the next try is one interval away, brought forward if a connection turns up sooner.

- Only the visible page holds a sync timer, and only one page claims a run. A Hotwire Native
  app is several web views at once, each running the head snippet; left alone they all held a
  timer against the same shared deadline and woke together, turning one app into a burst of
  identical requests. Hidden web views now hold nothing and re-arm when they come back, and
  whoever gets there first claims the run for ten seconds. The claim expires rather than being
  released, so a page closed mid-sync cannot lock the others out.

- A page that draws a countdown is the only clock on that page. The debug page schedules its
  own sync, and the head snippet was scheduling one too — two clocks, each with its own idea
  of the interval. Whichever fired first won, so the page could sync part way through a
  countdown that still showed time remaining. The snippet now stands down where the page is
  driving, and keeps its timer everywhere else.

- The interval is read from the *last* matching meta rather than the first. Turbo appends what
  a visit brought and clears the old provisional head elements afterwards; caught mid-merge,
  `querySelector` returns the previous page's value — which is how a document ends up syncing
  on an interval nobody configured.

- A failed sync waits a full interval before trying again, exactly like a successful one. It
  used to back off on a 2s, 4s, 6s ladder, so a manifest holding a single URL that would not
  fetch synced several times a minute while the page faithfully displayed the interval it was
  configured with. The interval is the interval, whatever the outcome.

- A run records when *it* finished, not when a page happened to hear about it. The debug page
  asks the worker what it missed on every load, and that replay re-dated the last sync to the
  moment of asking — so refreshing the page reset "synced N ago" to zero every time.

- That timestamp now lives in a cookie with a year's expiry rather than localStorage, which a
  web view may clear from under it. The scheduling scratch stays in localStorage: losing it
  costs nothing, and there is no reason to send it to the server. If the cookie cannot be
  stored at all, the page keeps it in memory — otherwise the clock would read zero and every
  finished sync would be instantly due again, which is a hot loop against the network.

- The sync interval is read from a `coldwire-sync-interval` meta rather than only baked into
  the head script. A head script runs once per document and Turbo visits reuse the document,
  so a page opened before the interval changed kept the old one for as long as it stayed
  open — the markup would say five minutes while the timer under it still fired every fifteen
  seconds. Turbo replaces head metas, so the next visit now picks up the new value.

- Automatic sync works on every page, not just the debug page. Both the head snippet and the
  debug page listen for the worker with `addEventListener`, and a `ServiceWorkerContainer`'s
  message queue starts *disabled* — setting `onmessage` enables it, `addEventListener` does
  not. So they listened faithfully and heard nothing: no progress, no counts, and a clock
  that never advanced, which is why a sync never appeared to have happened while you were on
  another page. Both now call `startMessages()`.

- The sync clock no longer depends on broadcasts arriving at all. The head snippet asks for a
  run over a `MessageChannel` it owns and settles the clock from the reply on that port.
  Leaving a page mid-sync drops that port and records nothing — which is the honest result:
  the stamp stays old, and the next page joins the run still in flight and records it when it
  finishes.

- The debug page starts its own sync when its countdown runs out, through the same path as
  its button — spinner, progress bar and all. It used to only *display* a deadline that a
  separate head snippet was responsible for acting on, and whenever those two clocks
  disagreed the page sat on "due now" with nothing scheduled and no way to tell which half
  had failed. The snippet still drives every other page in the app.

- The manifest is fetched with `cache: "no-store"`, and served with `Cache-Control: no-store,
  private`. A heuristically-cached copy had a sync faithfully fetching an old list, missing
  exactly the newly published pages auto-sync exists to pick up — and it is built from what
  the signed-in user can see, so no shared cache should hold it either. (The worker never
  intercepts it in the first place: the engine adds the manifest, the worker script and
  `probe_path` to `excluded_paths` itself.)

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
