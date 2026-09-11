# Changelog

## [Unreleased]

- **An archive can be several files.** `cache_archives` entries take `urls` as well as `url`,
  and the set is offered, counted, resumed and deleted as one download — a tile archive plus
  the style and sprite sheet that make it draw. Files matching `cache_ranges` are stored in
  chunks as before; everything else is stored whole under its own address, which is the only
  form an ordinary request can read back. Every file of an archive is exempt from collection,
  the small ones included.

## [0.1.0]

First release. The API may still change before 1.0.

- **`bin/rails coldwire:install`.** Mounts the engine at `/offline`, writes an initializer
  with every option and its default, registers the Stimulus controller, and tags the
  layout. Safe to run twice.
- **Garbage collection.** `config.garbage_collection` sweeps entries nothing has used in
  `max_age` (60 days by default) and, once the cache is over `max_size` (250 MB by default),
  the least recently read of what is left until it fits — so a cache that fills as people
  browse does not fill forever, on a device that revisits nothing as much as on one that
  revisits everything. The ceiling is offered as a ladder of sizes on the offline settings
  page and remembered per device, since how much of a phone to spend is not something an app
  can know. It measures only what a sweep may take: downloaded archives are an opt-in spend
  of somebody's data plan, so they are neither counted nor evicted.
  On by default, unlike syncing: it spends no data. A sweep runs only with a
  connection it has confirmed by pinging `probe_path`, because deleting is the one cache
  operation with no way back. Age is measured from last use, not from when an entry was
  fetched — storing a page renews everything it names, so the stylesheet every page loads
  keeps a fresh date even though nothing ever refetches it. The offline page's own assets and
  downloaded archives are never collected.
- **Offline support switch** in the status header on the offline settings page. Off deletes
  what is stored, unregisters the worker, and hides the rest of the page.
  `config.caching_enabled_by_default` is the starting position of the switch (on). A device
  remembers the choice.
- **Service worker and offline fallback.** A mountable engine serves the worker; when there is
  no cached copy and no network, a full page or a `<turbo-frame>` — both overridable — stands
  in. Built to satisfy Hotwire Native, which is stricter than a browser.
- **Precaching.** `auto_sync.precache_urls` is a list of URLs computed in Ruby, fetched along
  with the subresources those pages reference.
- **The cache's requests carry the app's user agent**, by way of a cookie. A worker's own
  fetches cannot: Hotwire Native sets the agent on the web view, `ServiceWorkerWebSettings` has
  no equivalent, and `fetch` may not set one — so on Android everything precached came back
  rendered for a browser. Each page writes its agent into `coldwire-user-agent`, which the
  browser attaches to every same-origin request, and a middleware puts it back.
- **`cache_as_you_go`** names the pages kept as somebody browses — default `["/*"]`, every
  path. An empty list stores nothing by browsing. **A stored page brings what it asks for**
  — its stylesheets, scripts and images are stored with it whatever the lists say, because
  a page held without them is the offline equivalent of not holding it. **`never_cache`**
  is the one veto over storing anything, by any route in; it is not `never_intercept`,
  which stops the worker touching a request at all and so fails outright offline.
- **Automatic syncing** on an interval, refetching anything older than `max_age`, resuming
  across page loads when a run is cut short.
- **Offline settings page** at the mount point: connection status, force offline, an Auto Sync switch
  with a countdown and live progress. The list of every cached URL is under **Inspect cache**,
  closed until you open it and remembered after that.
- **Nothing served from the cache is `data-turbo-track="reload"`.** Turbo will not render a
  page whose tracked elements differ from the current page's; it reloads instead, which
  offline buys nothing and which Hotwire Native can hang on. Asset digests change with every
  deploy, so any page cached before the current one was built disagrees with it — no
  configuration could have reconciled that. This replaced the `offline_head` setting, whose
  whole job was keeping the fallback's tracked elements in step with the layout by hand.
- **One cache entry per URL.** `cache.put()` replaces an entry only where the two agree about
  `Vary`, and Rails answers HTML with `Vary: Accept` — so a page fetched by precaching
  (`*/*`) and the same page visited by Turbo (`text/html`) are kept as two records, and the
  list grows a copy per distinct Accept. Writing a page now retires the URL first. Range and
  chunk entries, which share a path with their own query, are left alone.
- **Allow and block lists** written as route patterns (`"/sites/:id/card"`) or Regexps.
- **Cache identity.** The cache is dropped when the signed-in user changes.
- **Cross-origin caching** for origins you nominate, and **`Range` caching** for tiles and
  media that would otherwise be uncacheable.
- **Downloadable archives.** Large files somebody can choose to keep, fetched in chunks so an
  interrupted download resumes.
- **`window.Coldwire`** — `isOffline()`, `isForcedOffline()`, `cachedAt()`, `onChange()` — plus
  `data-coldwire-offline` on any HTML served from cache.
