# Changelog

## [Unreleased]

- **A Turbo Frame is cached apart from its page.** Turbo sends `Turbo-Frame` on a frame
  navigation, and an app answering it with `turbo_frame_request?` returns just the frame.
  Keyed on the URL alone, that body took the slot its page occupied, so a later cold visit was
  served a fragment as a whole document: a blank screen, and in Hotwire Native a page where
  `window.Turbo` never appears. `Vary` cannot separate the two, since a frame and its page are
  both `text/html` answering the same `Accept` and Rails does not name `Turbo-Frame` in `Vary`,
  so the frame is named in the key as `__coldwire_frame`. A frame request takes its own entry
  first and the page second, because Turbo pulls a frame out of a document exactly as it does
  online; an ordinary visit never takes the reverse trade.
- **Every `respond_to` format is cached apart from the page.** One URL answering a visit, a
  `fetch`, a CSV export and an RSS feed held one of the four. The format is now named in the
  key as `__coldwire_format`, worked out from the request's `Accept` because the same name has
  to be produced again when the entry is looked for. A path that already names its format
  keeps a clean key, so `/report.json`, `/app.css` and `/logo.png` are untouched and only
  `/report` is told apart. A request asking for data gets data or nothing, never the page.
- **A Turbo Stream is never stored.** It is a list of changes to make to a page rather than a
  page, and replaying a stale one applies yesterday's mutations to today's DOM.

## [0.4.0]

- Updated the offline page to restructure storage and downloads.
- Updated the storage so when you change storage size it triggers a garbage collection.

## [0.3.0]

- **`cache_origins` is `cacheable_hosts`**, and takes bare hosts: `"tiles.example.com"` rather
  than `"https://tiles.example.com"`. The scheme was never carrying information — a worker
  runs only on a secure page, and a secure page cannot fetch `http` — so it was a required
  prefix with exactly one possible value. Requests are matched on a URL's `host`, so a port
  belongs where it is not the default and `localhost:3001` matches that port and no other.
  A scheme raises at boot, naming what to write instead.

## [0.2.0]

- **Garbage collection** is on by default. `config.garbage_collection` periodically sweeps the cache, deleting entries that haven't been accessed for `max_age` (default: 60 days), and if the cache grows over `max_size` (default: 250 MB), it continues pruning the least recently accessed until the cache fits. Sweeps run only when confirmed online by pinging `probe_path`, since deletions are irreversible. Cached archives and offline page assets are never collected, and the age of an entry is renewed anytime it or its referenced subresources are accessed or stored. The size ceiling can be adjusted in the offline settings page and is remembered per device.
- The garbage collector runs safely and automatically; you generally do not need to configure it. But you can tune `max_age`, `max_size`, and `interval` to fit your app's needs.


## [0.1.0]

First release. The API may still change before 1.0.

- **`bin/rails coldwire:install`.** Mounts the engine at `/offline`, writes an initializer
  with every option and its default, registers the Stimulus controller, and tags the
  layout. Safe to run twice.
- **Garbage collection.** `config.garbage_collection` sweeps entries nothing has used in
  `max_age` (30 days by default), so a cache that fills as people browse does not fill
  forever. On by default, unlike syncing: it spends no data. A sweep runs only with a
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
