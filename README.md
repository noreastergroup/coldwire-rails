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

Six things break a naive Hotwire Native offline cache. Coldwire handles all six.

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

**5. The offline page itself must boot Turbo.** Hotwire Native's adapter waits for
`window.Turbo` and, if it never appears, reports *"The page could not be loaded because Turbo
is not present"* — its own error screen again, no matter how good your fallback HTML is. A
plain-HTML offline page is not renderable in the app at all. Coldwire's fallback loads Turbo
through your importmap.

**6. Assets must not receive HTML.** A stylesheet or `<img>` handed an HTML offline page is
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

  # Must match the data-turbo-track elements in your layout, or Turbo invalidates instead of
  # rendering and Hotwire Native sticks on a spinner going back.
  config.offline_head = -> { stylesheet_link_tag "application", "data-turbo-track": "reload" }

  # The importmap module the offline page loads. Hotwire Native rejects any page without
  # window.Turbo, so the fallback has to boot Turbo like a real page. Set to nil if you are
  # not on importmap-rails, and load Turbo your own way in the template.
  config.offline_entry_point = "@hotwired/turbo-rails"

  # Mark HTML served from cache so the page can say it is stale. On by default.
  config.offline_marker = true

  # Treat "/map" and "/map?lat=1&zoom=9" as the same cached page. On by default.
  config.ignore_query_params = true

  # Never intercept these path prefixes — they go straight to the network and fail outright
  # when it is down. Coldwire's own routes are excluded automatically.
  config.excluded_paths = [ "/up", "/cable" ]

  # What automatic caching may and may not store. Strings match a path segment prefix,
  # Regexps are tested against the path. An empty allowlist allows everything; the
  # blocklist always wins. Neither applies to the precache manifest.
  config.cache_allowlist = []
  config.cache_blocklist = [ "/users", %r{^/admin(/|$)} ]

  # Keep the manifest current on its own, instead of only when the button is pressed.
  config.auto_sync = true
  config.sync_interval = 6.hours
  config.max_age = 7.days
  config.sync_batch_limit = 25
  config.sync_max_attempts = 25

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
are plain markup — no request context, no helpers that need a current user.

### Match your layout's tracked elements

**Set `offline_head`.** Turbo will not render a page whose `data-turbo-track="reload"`
elements differ from the current page's — it invalidates instead. Hotwire Native answers an
invalidation by showing a spinner and reloading, which survives going forward but can leave
the spinner up for good when it happens mid-pop on a back navigation.

So the offline page has to carry the same tracked elements as your real pages, in the same
order. Whatever your layout tracks goes here:

```ruby
config.offline_head = -> { stylesheet_link_tag "application", "data-turbo-track": "reload" }
```

Coldwire emits its importmap after this, matching the usual stylesheets-then-scripts order.
Note that this pulls your stylesheet into the offline page, so a CSS reset there applies to
it — Coldwire's own styles state everything explicitly rather than relying on UA defaults,
and yours should too if you override the template.

### Overriding the templates

Three things to keep if you override the page template:

- **CSS in the body, scoped.** Turbo's head merge copies new `<style>` elements into the app
  and never removes them, so a `<style>` in the head — or any unscoped selector — outlives the
  offline page and restyles everything after it until a full reload.

- **The Turbo import.** Hotwire Native shows its own error screen for any page where
  `window.Turbo` never appears. Import Turbo alone rather than your app entry point — offline,
  every module in that graph would have to be cached for it to evaluate, and one miss means
  no Turbo.
- **`<meta name="turbo-cache-control" content="no-cache">`.** Without it Turbo snapshots the
  offline page and can restore it after you are back online.

The frame template needs neither: a frame response is a fragment inserted into a page that
already has Turbo running.

Both templates ship a **Try again** link, and each retries differently because a template
baked at worker-build time cannot know the URL it will stand in for:

- **The page** uses `href=""`, which resolves to whatever URL it was served for, plus
  `data-turbo="false"` — a Turbo visit to the identical URL can be treated as same-page and
  do nothing at all.
- **The frame** uses `href="coldwire:retry-url"`, which the worker substitutes with the
  frame's own URL. An empty href here would resolve to the *page* and load the whole document
  into the card. A link inside a frame targets that frame, so this reloads just the card.

---

## The debug page

Mounted at the engine root — `/coldwire` with the mount above. It gives you:

- **Automatic sync** — whether it is on, when the last full sync finished, and what a sync
  is doing right now. It listens for the worker's broadcasts, so it shows syncs it did not
  start — including one already running when you opened the page. **Sync now** forces one
  regardless of the interval.
- **Cache inspector** — every cached URL with size and how long ago it was stored
- **Precache** — runs the manifest with a live progress bar (`Pages 47 of 84`, then assets)
- **Clear cache**
- **Force offline** — serve only from cache even with a connection

It's styled with plain CSS and assumes no framework. Put it behind whatever authentication
your app uses by wrapping the route, or override the template.

To reach it offline, allowlist it like any other page — `config.cache_allowlist = [ "/coldwire" ]`
alongside your own paths. The worker script and the manifest are never cached, so **Precache**
will fail while offline; the inspector, **Clear cache**, and **Force offline** are client-side
and keep working.

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

**Put your auth paths in `cache_blocklist`, not `excluded_paths`.** Sign-in pages redirect on
session state and must never be served stale — but the two settings fail very differently
offline. `excluded_paths` means *never intercept*, so the request goes straight to a dead
network and Hotwire Native shows its own error screen. `cache_blocklist` means *intercept but
never store automatically*, so the request still reaches your offline view.

### Your cold-boot URL must be cacheable

This is the one that will bite you. Whatever URL your app loads at launch has to be
something the cache can actually hold, and a login path usually is not: signed in, it is a
`302` to the app root, and a redirect is never cached. A cold launch offline then has
nothing to serve and falls through to the SDK's error screen — even though the page it would
have redirected to is sitting in the cache.

Boot into a real page instead. Signed out it still redirects to your login, so nothing about
the online flow changes.

---

## Telling the page it is offline

With `offline_marker` on (the default), any HTML the worker serves from cache *because the
network was unavailable* is stamped before it reaches the page:

```html
<html data-coldwire-offline data-coldwire-cached-at="1756400000">
  <head><meta name="coldwire-offline" content="1756400000">
```

`data-coldwire-cached-at` is unix seconds — when that copy was stored. A page served fresh
carries none of this, so the marker is a reliable "you are looking at cached content".

Two markers rather than one, because they are read at different moments. The `<html>`
attributes are there for the first paint of a cold boot, before any JS runs, so a banner
does not flash in. The `<meta>` is for Turbo visits: Turbo swaps the body and merges the
head but **never copies `<html>` attributes**, so on its own the attribute would still
describe the previous page. `coldwire_service_worker_tag` mirrors the meta onto `<html>` on
each `turbo:load`.

### Styling against it

Any CSS can key off the attribute. With Tailwind v4, two custom variants give you
`offline:` and `online:`:

```css
@custom-variant offline (html[data-coldwire-offline] &);
@custom-variant online (html:not([data-coldwire-offline]) &);
```

```erb
<div class="hidden offline:block">
  You're offline. This information may be out of date.
</div>
```

Rendering the age needs the client, since only it knows the timestamp — read
`document.documentElement.dataset.coldwireCachedAt` and format it with
`Intl.RelativeTimeFormat`.

---

## Choosing what gets cached

Automatic caching — anything the worker sees you visit — is governed by two lists:

```ruby
config.cache_allowlist = [ "/sites", %r{^/stories} ]
config.cache_blocklist = [ "/users", %r{^/admin(/|$)} ]
```

Both take **strings or Regexps**:

- A **string** matches the path as a segment prefix. `"/users"` covers `/users` and
  `/users/sign_in`, but not `/username`.
- A **Regexp** is tested against the path. It is evaluated by JavaScript's `RegExp`, so write
  JS-compatible syntax: `^` and `$`, not `\A` and `\z`. Coldwire raises at boot if you use
  `\A`/`\z`/`\Z` or the `x`/`m` flags, rather than letting a rule silently never match.
  The `i` flag works.

An **empty allowlist means everything is allowed** — that's the default. A non-empty one
means *only* these. The **blocklist always wins**.

### Keeping the manifest current

By default the manifest is only fetched when something asks for it — the button on the debug
page. Turn on `auto_sync` and Coldwire keeps it current on its own:

```ruby
config.auto_sync = true
config.sync_interval = 6.hours    # leave this long between syncs
config.max_age = 7.days           # refetch a page once its copy is older than this
config.sync_batch_limit = 25      # most pages one sync will fetch; 0 for no limit
config.sync_max_attempts = 25     # give up on an unfinishable sync after this many loads
```

**There is no true background scheduling to use.** WebKit ships neither Background Sync,
Periodic Background Sync, nor Background Fetch, so nothing can wake a worker in a Hotwire
Native web view. What a page load *can* do is hand work to the worker, which then runs
independently of the page that started it. So sync is triggered on load and throttled — the
stamp lives in `localStorage`, because a worker global does not survive the browser shutting
the worker down.

Each sync:

| | |
|---|---|
| **Fetches what is missing** | a newly published record shows up in the manifest and has no cached copy |
| **Refetches what is old** | a cached copy older than `max_age` |
| **Skips what is fine** | anything cached and younger than `max_age` costs nothing |
| **Retires what left the manifest** | an unpublished record is dropped from the cache |
| **Stops at the batch limit** | the rest is picked up by the next sync |

### Interrupted syncs resume

A sync outlives the page that started it, but not necessarily the browser's patience — the
worker can be shut down mid-run, the app backgrounded, the signal lost. So the clock is only
restarted when the worker reports the manifest **fully** in sync. Anything short of that
leaves no stamp, and the next page load carries on.

Resuming needs no bookmark. Each pass recomputes what is missing from what is actually in the
cache, so an interruption costs only the requests that were in flight:

```
page 1   84 pending   fetched 25             59 remaining
page 2   59 pending   fetched 7, cut short   (worker shut down)
page 3   52 pending   fetched 25             27 remaining     <- picked up the 7
page 4   27 pending   fetched 25              2 remaining
page 5    2 pending   fetched 2               done -> stamped
```

Completion is announced to **every open page**, not just the one that asked, because by then
the user is usually somewhere else and that page can no longer record anything. Navigating
during a sync nudges the worker rather than starting a second one.

If a manifest can never finish — it lists a URL that always fails — `sync_max_attempts` stops
it after that many page loads and waits for the next interval, rather than fetching on every
navigation for the rest of the session.

Retiring only touches entries the manifest owns — they are marked when stored. Assets, and
pages you cached by simply visiting them, are never retired by a sync, because the manifest
page that happened to reference an asset is not its owner.

A sync also skips itself when `navigator.onLine` is false, and only one runs at a time.

### The precache manifest ignores both

`prefetch_urls` stores whatever you list, blocklist or not. Putting a URL in the manifest is
an explicit instruction, and quietly declining it would make the manifest unpredictable — you
would precache 84 pages and silently get 60. The same goes for the subresources a manifest
page references.

So the lists answer "what should we pick up as the user wanders around", not "what is allowed
in the cache at all". `excluded_paths` is still the setting for the latter, and it is stronger
than either: those URLs are never intercepted, so they also never reach the offline fallback.

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
| Blocklisted / not allowlisted | Not stored automatically; still cacheable via the manifest. |
| Query strings | Ignored by default, when matching *and* when storing. See below. |
| HTML served from cache offline | Stamped with `data-coldwire-offline`. See above. |

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
