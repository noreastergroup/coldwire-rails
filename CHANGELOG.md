# Changelog

## [Unreleased]

First release. The API may still change before 1.0.

- **Service worker and offline fallback.** A mountable engine serves the worker; when there is
  no cached copy and no network, a full page or a `<turbo-frame>` — both overridable — stands
  in. Built to satisfy Hotwire Native, which is stricter than a browser.
- **Precaching.** `auto_sync.precache_urls` is a list of URLs computed in Ruby, fetched along
  with the subresources those pages reference.
- **Automatic syncing** on an interval, refetching anything older than `max_age`, resuming
  across page loads when a run is cut short.
- **Debug page** at the mount point: connection status, force offline, sync with a countdown
  and live progress, and every cached entry with search, sort, and per-row delete.
- **Nothing served from the cache is `data-turbo-track="reload"`.** Turbo will not render a
  page whose tracked elements differ from the current page's; it reloads instead, which
  offline buys nothing and which Hotwire Native can hang on. Asset digests change with every
  deploy, so any page cached before the current one was built disagrees with it — no
  configuration could have reconciled that. This replaced the `offline_head` setting, whose
  whole job was keeping the fallback's tracked elements in step with the layout by hand.
- **Allow and block lists** written as route patterns (`"/sites/:id/card"`) or Regexps.
- **Cache identity.** The cache is dropped when the signed-in user changes.
- **Cross-origin caching** for origins you nominate, and **`Range` caching** for tiles and
  media that would otherwise be uncacheable.
- **Downloadable archives.** Large files somebody can choose to keep, fetched in chunks so an
  interrupted download resumes.
- **`window.Coldwire`** — `isOffline()`, `isForcedOffline()`, `cachedAt()`, `onChange()` — plus
  `data-coldwire-offline` on any HTML served from cache.
