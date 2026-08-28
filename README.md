# Coldwire

**When your Hotwire wires go cold.**

Offline page caching for Hotwire Native apps. Coldwire is a mountable Rails engine that
serves a [Cache API](https://developer.mozilla.org/en-US/docs/Web/API/Cache) service worker,
precaches the pages you nominate, and — when there's nothing cached and no network — falls
back to an offline view that Turbo and Hotwire Native will actually render.

That last part is most of the work. A service worker that returns a sensible-looking `503`
gets you a native error screen, not your offline page. Coldwire gets the details right.

> **Status: early.** Extracted from a production app but young as a library. The API may
> change before 1.0.

---

## Why this is harder than it looks

Five things break a naive Hotwire Native offline cache. Coldwire handles all five.

**1. `Vary: Accept` silently defeats precaching.** Rails answers HTML with `Vary: Accept`,
and `cache.match()` honors `Vary` by default. Precaching fetches with `Accept: */*`, but
Turbo Drive and Turbo Frames request `Accept: text/html, application/xhtml+xml`. A
precached page therefore only ever matches *another precache* — never a real visit. It
looks like it works, because on-demand caching of visited pages still does. Coldwire matches
with `{ ignoreVary: true }`.

**2. A non-2xx offline page is never shown.** Hotwire Native treats any non-2xx visit as a
failed request. Its adapter posts `visitRequestFailed` to the native side with only a
location, an identifier, and a status code — **the response body never crosses into Swift**.
So there is no iOS override that can render a `503` body. Coldwire's fallback is a `200`.

**3. Turbo Frames need a frame.** A frame request discards any response that doesn't contain
a matching `<turbo-frame>`, leaving the frame on its loading state forever. Coldwire reads
the `Turbo-Frame` request header and answers with a matching frame.

**4. A followed redirect poisons the cache.** When a signed-out request hits `/`, Rails
answers `302 -> /users/sign_in` and `fetch` follows it. The result looks fine — `ok: true`,
`status: 200` — and **`cache.put()` stores it without complaint**. Now `/` holds the sign-in
page, and the stored response keeps `redirected: true`. Serving a redirected response for a
navigation is a network error by spec, so the app fails to cold launch offline instead of
showing the cached page. Coldwire refuses to store a redirected response at all.

**5. Assets must not receive HTML.** A stylesheet or `<img>` handed an HTML offline page is
just a broken asset. Coldwire serves the HTML fallback only to requests that want HTML, and
gives everything else an empty `504`.

---

## Installation

```ruby
# Gemfile
gem "coldwire"
```

Mount the engine:

```ruby
# config/routes.rb
mount Coldwire::Engine => "/coldwire"
```

Register the Stimulus controller. Coldwire pins `"coldwire"` into your importmap itself, so
there is nothing to add to `config/importmap.rb`:

```js
// app/javascript/controllers/index.js
import ColdwireCacheController from "coldwire"
application.register("coldwire-cache", ColdwireCacheController)
```

Register the worker from your layout:

```erb
<%# app/views/layouts/application.html.erb, inside <head> %>
<%= coldwire_service_worker_tag %>
```

### Scope

The worker is served from the engine's mount point, so its default scope would be
`/coldwire/`. Coldwire sends `Service-Worker-Allowed: /` and registers with a matching
scope, so a worker mounted anywhere still controls the whole origin. Narrow it with
`config.scope` if you'd rather it didn't.

---

## Configuration

```ruby
# config/initializers/coldwire.rb
Coldwire.configure do |config|
  # Which pages to precache. Evaluated against your app's URL helpers, so `article_path`
  # means your route rather than one of Coldwire's.
  config.prefetch_urls = -> {
    Article.published.flat_map { |article| [ article_path(article), card_article_path(article) ] }
  }

  # Give the lambda an argument and it receives the controller, for `current_user` and
  # anything else request-scoped:
  #
  #   config.prefetch_urls = ->(controller) {
  #     controller.current_user.articles.map { |article| article_path(article) }
  #   }

  # Who the cache belongs to. Evaluated in the view, so `current_user` is available. When
  # this changes between page loads Coldwire drops the cache — which is what makes signing
  # out, and switching accounts, safe.
  config.cache_identity = -> { current_user&.id }

  # Only register the worker where you want caching. A Hotwire Native app usually
  # limits it to the native user agent so browser tests stay uncached.
  config.register_if = ->(request) { request.user_agent.to_s.include?("Hotwire Native") }

  # Treat "/map" and "/map?lat=1&zoom=9" as the same cached page. On by default.
  config.ignore_query_params = true

  # Never intercept these path prefixes — they go straight to the network and fail outright
  # when it is down. Coldwire's own routes are excluded automatically.
  config.excluded_paths = [ "/up", "/cable" ]

  # Intercepted but never stored. Sign-in pages belong here, not above: they must not be
  # served stale, but they should still reach the offline fallback.
  config.uncached_paths = [ "/users" ]

  # Bump to invalidate every cached entry at once.
  config.cache_name = "coldwire"

  config.scope = "/"
end
```

### Rendering inside your layout

The debug page inherits your `ApplicationController`, so it picks up your layout,
authentication, and helpers. The engine is namespace-isolated, which would normally point
bare route helpers in that layout at Coldwire's routes — so Coldwire re-exposes your app's
URL helpers to anything it renders. A layout calling `root_path` keeps working.

### Overriding the offline views

Create either file in your own app to replace Coldwire's:

| Path | Renders |
|---|---|
| `app/views/coldwire/service_worker/offline_page.html.erb` | The full-page fallback |
| `app/views/coldwire/service_worker/offline_frame.html.erb` | The inside of the fallback `<turbo-frame>` |
| `app/views/coldwire/caches/show.html.erb` | The debug page |

Both offline templates are rendered at worker-build time and embedded in the script, so they
are plain markup — no request context, no helpers that need a current user. Keep the
`<meta name="turbo-cache-control" content="no-cache">` in the page template: without it, Turbo
snapshots the offline page and can restore it after you're back online.

---

## The debug page

Mounted at the engine root — `/coldwire` with the mount above. It gives you:

- **Cache inspector** — every cached URL with size and how long ago it was stored
- **Precache** — runs the manifest with a live progress bar (`Pages 47 of 84`, then assets)
- **Clear cache**
- **Force offline** — serve only from cache even with a connection

It's styled with plain CSS and assumes no framework. Put it behind whatever authentication
your app uses by wrapping the route, or override the template.

> **Force offline is a convenience, not a test harness.** The flag lives in a worker
> variable, and browsers terminate idle service workers — on restart it silently resets to
> off. Airplane mode is the trustworthy test.

---

## Signed-in and signed-out

Cached pages contain whatever the session that fetched them could see, so authentication
needs handling on two fronts.

**Set `cache_identity`.** Coldwire records it in `localStorage` and drops the cache whenever
it changes, so signing out clears the previous user's pages and signing in as someone else
does not inherit them. Leave it unset and the cache persists across sessions — fine for a
single-user or fully public app, wrong for anything else.

**Put your auth paths in `uncached_paths`, not `excluded_paths`.** Sign-in pages redirect on
session state and must never be served stale — but the two settings fail very differently
offline. `excluded_paths` means *never intercept*, so the request goes straight to a dead
network and Hotwire Native shows its own error screen. `uncached_paths` means *intercept but
never store*, so the request still reaches your offline view.

### Your cold-boot URL must be cacheable

This is the one that will bite you. Whatever URL your app loads at launch has to be
something the cache can actually hold, and a login path usually is not: signed in, it is a
`302` to the app root, and a redirect is never cached. A cold launch offline then has
nothing to serve and falls through to the SDK's error screen — even though the page it would
have redirected to is sitting in the cache.

Boot into a real page instead. Signed out it still redirects to your login, so nothing about
the online flow changes.

---

## How caching behaves

| Request | Behavior |
|---|---|
| HTML page | Network-first. Recaches on every view so the copy stays fresh; falls back to cache when the network fails. |
| Assets (CSS, JS, images) | Cache-first. |
| `Range` requests (map tiles, media) | Never intercepted — the Cache API can't serve `206`. |
| Cross-origin | Never intercepted. |
| Non-GET | Never intercepted. |
| Redirected response | Never stored — see #4 above. |
| Query strings | Ignored by default, when matching *and* when storing. See below. |

### Query strings

With `ignore_query_params` on (the default), `/map` and `/map?lat=44.1&zoom=9` are one
cached page. The query is dropped both in `cache.match()` and in the key an entry is stored
under — matching alone would still let a map that rewrites `lat`/`lng`/`zoom` on every pan
write hundreds of near-duplicate entries for the same page.

> **This is blunt, and deliberately so for now.** It also collapses query strings that
> genuinely select content: `/search?q=otters` and `/search?q=puffins` become one entry, and
> whichever was cached last is what you get offline. If your app caches pages whose content
> depends on the query, set `config.ignore_query_params = false` and cache the distinct URLs
> instead. A finer-grained rule — ignoring only nominated params — is the obvious next step.

Precaching walks each manifest URL, then the same-origin subresources those pages
reference — stylesheets, scripts, images, `srcset` candidates, and importmap entries. It
deliberately does **not** follow `<a href>`, which would turn it into a site crawler.

### Cache timestamps

The Cache API ignores HTTP freshness headers entirely, and WebKit drops `Date` from
`match()`. So Coldwire stamps unix seconds onto the *request key* it stores under —
`keys()` hands it back, and URL matching still finds the entry. That's what the inspector's
"2 hours ago" is reading.

---

## Requirements

- Rails 7.1+
- Turbo / Hotwire Native (works in any browser with service workers, but the offline
  fallback details are tuned for Hotwire Native)
- On iOS, service workers only run in `WKWebView` when navigation is limited to app-bound
  domains:

```swift
Hotwire.config.makeCustomWebView = { config in
    config.limitsNavigationsToAppBoundDomains = true
    return WKWebView(frame: .zero, configuration: config)
}
```

with every domain you navigate to listed under `WKAppBoundDomains` in `Info.plist`. **Apple
caps that list at 10 entries**, and an eleventh is silently dropped — which disables app-bound
mode and takes service workers with it.

---

## License

MIT. See [LICENSE](LICENSE).
