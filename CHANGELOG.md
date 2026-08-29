# Changelog

## [Unreleased]

- Offline page and frame each offer a "Try again" link. The page retries the URL it was
  served for; the frame retries just that frame via the `coldwire:retry-url` token.
- Plainer copy on both fallbacks — no more talk of the cache.
- The offline page paints its own background and adapts to dark mode. It had none, so a
  dark-mode device rendered dark text on the UA's dark default.

- `offline_entry_point`: the offline page now boots Turbo through the host's importmap.
  Hotwire Native rejects any page where `window.Turbo` never appears, so the previous
  plain-HTML fallback could never render in the app — it reported "Turbo is not present"
  and showed the SDK's error screen instead.

### Fixed

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
