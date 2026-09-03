# Coldwire

**When your Hotwire wires go cold.**

Offline caching for Rails. A mountable engine serves a
[Cache API](https://developer.mozilla.org/en-US/docs/Web/API/Cache) service worker, precaches
the pages you nominate, and — when there is nothing cached and no network — falls back to an
offline view Turbo will actually render.

Works the same in a plain Hotwire app, an installed PWA, or Hotwire Native. If you are
building a PWA, this is the offline layer and not the whole of it: no web app manifest, no
install prompt, no icons.

> **Status: early.** Extracted from a production app but young as a library. The API may
> change before 1.0.

---

## What you get

| | |
|---|---|
| **Precaching** | A list of URLs you compute in Ruby, fetched with the subresources those pages reference |
| **Automatic sync** | Kept current on an interval, resuming where it left off when a run is cut short |
| **Offline fallback** | A page and a `<turbo-frame>`, both overridable, that Turbo renders rather than rejects |
| **A debug page** | Status, force offline, sync with a countdown and progress, and every cached entry with search, sort and delete |
| **Allow and block lists** | Route patterns — `"/sites/:id/card"` — or Regexps |
| **Cache identity** | The cache is dropped when the signed-in user changes |
| **Cross-origin and `Range`** | Nominate other origins, and cache tiles and media the Cache API otherwise refuses |
| **Downloadable archives** | Large files somebody can opt into, fetched in chunks so an interrupted download resumes |
| **A JS API** | `Coldwire.isOffline()` and friends, plus `data-coldwire-offline` on anything served from cache |

---

## Installation

```ruby
# Gemfile
gem "coldwire-rails"
```

The gem is `coldwire-rails`; everything in it lives under `Coldwire`, the way `turbo-rails`
provides `Turbo`. Mount the engine, register the Stimulus controller, and add the tag to your
layout:

```ruby
# config/routes.rb
mount Coldwire::Engine => "/coldwire"
```

```js
// app/javascript/controllers/index.js
import ColdwireCacheController from "coldwire"
application.register("coldwire-cache", ColdwireCacheController)
```

```erb
<%# app/views/layouts/application.html.erb, inside <head> %>
<%= coldwire_service_worker_tag %>
```

Coldwire pins `"coldwire"` into your importmap itself, so there is nothing to add to
`config/importmap.rb`. The worker is served from the mount point, but sends
`Service-Worker-Allowed: /` and registers at `/`, so it controls the whole origin wherever you
mount it — narrow that with `config.worker_scope`.

---

## Configuration

Everything, with its default. Only `auto_sync` really needs your attention.

```ruby
# config/initializers/coldwire.rb
Coldwire.configure do |config|
  # What to precache and how often. Evaluated against your app's URL helpers.
  config.auto_sync do |sync|
    sync.enabled = false          # off by default: background fetching is somebody's data plan
    sync.precache_urls = -> { [] }
    sync.interval = 6.hours       # leave this long between syncs
    sync.max_age = 7.days         # refetch a cached page once its copy is older than this
    sync.concurrency = 4          # fetches in flight at once
  end

  # Who the cache belongs to. Evaluated in the view. When it changes, the cache is dropped —
  # which is what makes signing out, and switching accounts, safe.
  config.cache_identity = -> { nil }

  # Where the worker registers at all. Evaluated in the view, so `request` and `current_user`
  # are both in scope. A page that does not register does not cache or sync.
  config.register_if = -> { true }

  # The importmap module the offline page loads to boot Turbo. nil if you are not on
  # importmap-rails; load Turbo your own way in the template instead.
  config.offline_import = "@hotwired/turbo-rails"

  # What automatic caching may store. Strings are route patterns, Regexps are tested against
  # the path. An empty allowlist allows everything; the blocklist always wins.
  config.cache_allowlist = []
  config.cache_blocklist = []

  # Never intercepted, so these fail outright offline. Coldwire's own routes are added for you.
  config.never_intercept = [ "/up" ]  # probe_path is added for you

  # Origins besides your own the worker may cache, and URLs whose Range requests it caches.
  config.cache_origins = []
  config.cache_ranges = []

  # Large files somebody can download for offline use. See "Large files" below.
  config.cache_archives = []

  config.probe_path = "/up"          # pinged to tell online from offline
  config.mark_cached_pages = true    # stamp HTML served from cache
  config.ignore_query_params = true  # treat "/map" and "/map?zoom=9" as one page
  config.cache_name = "coldwire"     # bump to invalidate every entry at once
  config.worker_scope = "/"
end
```

`precache_urls` and `cache_identity` are evaluated where your helpers are, so `article_path`
means your route rather than one of Coldwire's. Give `precache_urls` an argument and it
receives the controller:

```ruby
sync.precache_urls = ->(controller) { controller.current_user.articles.map { |a| article_path(a) } }
```

`register_if` takes no argument, or the request:

```ruby
config.register_if = -> { request.user_agent.to_s.include?("Hotwire Native") && current_user.present? }
```

---

## What gets cached

| Request | Behavior |
|---|---|
| HTML page | Network-first. Recached on every view; falls back to cache when the network fails |
| Assets (CSS, JS, images) | Cache-first |
| Cross-origin | Passed through, unless the origin is in `cache_origins` |
| `Range` (tiles, media) | Passed through, unless the URL matches `cache_ranges` |
| Non-GET | Passed through |
| Redirected response | Never stored |
| Blocklisted, or not allowlisted | Not stored automatically; still cacheable via the manifest |
| Query strings | Ignored by default, when matching *and* when storing |

### Allow and block lists

```ruby
config.cache_allowlist = [ "/sites", "/sites/:id", "/sites/:id/card" ]
config.cache_blocklist = [ "/users/:id/edit", %r{^/admin(/|$)} ]
```

A **string** is a route pattern, and matches that shape and nothing else:

| Pattern | Matches | Does not match |
| --- | --- | --- |
| `/sites` | `/sites` | `/sites/1`, `/sites/search` |
| `/sites/:id` | `/sites/1` | `/sites`, `/sites/1/card` |
| `/sites/:id/card` | `/sites/1/card` | `/sites/1/notices` |
| `/sites/*` | `/sites/1`, `/sites/1/card` | `/sites` |

`:name` is exactly one segment; `*` takes everything remaining and may only be last. Coldwire
raises at boot on anything else, because every mistake of this shape fails the same silent way
— the rule never matches, and you find out when a page you expected offline is not there.

Prefer the explicit shapes over `*`. A prefix reads as "this section of the app" but takes
everything underneath with it, and with `ignore_query_params` on a single `/sites/search`
entry ends up answering every search.

A **Regexp** is tested against the path by JavaScript's `RegExp`, so write JS syntax — `^` and
`$`, not `\A` and `\z`. Coldwire raises on `\A`/`\z`/`\Z` and the `x`/`m` flags rather than
letting a rule silently never match.

An **empty allowlist allows everything**. A non-empty one means *only* these. The **blocklist
always wins**. Neither applies to the precache manifest: listing a URL there is an explicit
instruction, and quietly declining it would mean precaching 84 pages and silently getting 60.

### Query strings

With `ignore_query_params` on, `/map` and `/map?lat=44.1&zoom=9` are one cached page — the
query is dropped both when matching and in the key an entry is stored under. Matching alone
would still let a map that rewrites `lat`/`lng`/`zoom` on every pan write hundreds of
near-duplicate entries.

> This is blunt, deliberately. It also collapses query strings that genuinely select content:
> `/search?q=otters` and `/search?q=puffins` become one entry. Set
> `config.ignore_query_params = false` if your app caches pages whose content depends on the
> query.

---

## Syncing

Turn on `auto_sync.enabled` and Coldwire keeps the manifest current on its own. Each pass:

| | |
|---|---|
| **Fetches what is missing** | a newly published record with no cached copy |
| **Refetches what is old** | a cached copy older than `max_age` |
| **Skips what is fine** | anything younger than `max_age` costs nothing |
| **Retires what left the manifest** | an unpublished record is dropped from the cache |

Retiring only touches entries the manifest owns. Assets, and pages you cached by visiting
them, are never retired.

**There is no true background scheduling to use.** WebKit ships neither Background Sync,
Periodic Background Sync, nor Background Fetch, so nothing can wake a worker in a Hotwire
Native web view. What a page load *can* do is hand work to the worker, which then runs
independently of the page that started it. So an open page works out when a sync is next owed
and sleeps exactly that long — five seconds or five weeks — rather than polling.

A sync outlives the page that started it, but not necessarily the browser's patience. So the
clock is restarted only when the worker reports a full pass; anything short of that leaves no
stamp and the next page load carries on. Resuming needs no bookmark — each pass recomputes
what is missing from what is actually in the cache, so an interruption costs only the requests
that were in flight.

---

## Large files

Some things are too big to cache as a matter of course but worth keeping if somebody asks — a
tile archive, an audio guide, a reference PDF:

```ruby
config.cache_archives = [
  { url: "https://tiles.example.com/basemap.pmtiles",
    title: "Offline map",
    description: "The whole coast, rather than only the places you have opened." }
]
```

A bare URL string works too, and the filename becomes the title.

**Nothing downloads on its own.** Hundreds of megabytes over somebody's connection is their
decision, so this only makes a file offerable — the debug page shows Download, then **Download
again** and **Delete** once it is on the device, or **Resume** where a download stopped part
way.

Files arrive in 8 MB chunks, which is what makes a dropped connection cost seconds instead of
the whole download. Serving from them is cheap too: a `Range` request is answered by slicing
the chunks and stitching across boundaries, and a Blob slice references bytes rather than
copying them, so reading a tile out of a downloaded 300 MB archive costs about what reading it
out of a single stored range does.

This pairs with `cache_ranges`, which caches the slices actually read — so the places you have
already opened work offline, and downloading the archive is how the rest does.

---

## Telling the page it is offline

With `mark_cached_pages` on, any HTML the worker serves from cache *because the network was
unavailable* is stamped before it reaches the page:

```html
<html data-coldwire-offline data-coldwire-cached-at="1756400000">
```

Two markers, because they are read at different moments: the `<html>` attributes are there for
the first paint of a cold boot, before any JS runs, and a `<meta name="coldwire-offline">` for
Turbo visits, since Turbo merges the head but never copies `<html>` attributes.
`coldwire_service_worker_tag` mirrors the meta onto `<html>` on each `turbo:load`.

Any CSS can key off the attribute. With Tailwind v4, two custom variants give you `offline:`
and `online:`:

```css
@custom-variant offline (html[data-coldwire-offline] &);
@custom-variant online (html:not([data-coldwire-offline]) &);
```

From JavaScript, `window.Coldwire`:

```js
Coldwire.isOffline()        // this page did not come from the network
Coldwire.isForcedOffline()  // …because the switch is on, rather than for want of a signal
Coldwire.cachedAt()         // a Date, or null if it came from the network
Coldwire.onChange((state) => { … })  // fires on every Turbo visit and on toggling force
                                     // offline; returns its own unsubscribe
```

`isOffline()` reads the marker rather than `navigator.onLine`, which a web view reports
unreliably in both directions. `onChange` is what lets a map put its remote sources back
without a reload.

---

## Signed in and signed out

Cached pages contain whatever the session that fetched them could see.

**Set `cache_identity`.** It is recorded in `localStorage`, and the cache is dropped whenever
it changes — so signing out clears the previous user's pages, and signing in as someone else
does not inherit them. Leave it unset and the cache persists across sessions: fine for a
single-user or fully public app, wrong for anything else.

**Put auth paths in `cache_blocklist`, not `never_intercept`.** The two fail very differently
offline. `never_intercept` means *never intercept*, so the request goes to a dead network and
Hotwire Native shows its own error screen. `cache_blocklist` means *intercept but never store
automatically*, so the request still reaches your offline view.

**Your cold-boot URL must be cacheable.** This is the one that will bite you. Whatever URL
your app loads at launch has to be something the cache can hold, and a login path usually is
not: signed in, it is a `302` to the app root, and a redirect is never cached. A cold launch
offline then has nothing to serve — even though the page it would have redirected to is
sitting in the cache. Boot into a real page instead; signed out it still redirects to your
login, so nothing about the online flow changes.

---

## The debug page

Mounted at the engine root — `/coldwire` with the mount above. It inherits your
`ApplicationController`, so it picks up your layout, authentication and helpers, and is styled
with plain CSS assuming no framework. Put it behind whatever authentication you use by
wrapping the route, or override `app/views/coldwire/caches/show.html.erb`.

- **Status** — a light and a word for the connection, how much is cached, when it last synced.
  Decided by pinging `probe_path`, never by `navigator.onLine`.
- **Force offline** — serve only from cache even with a connection. Holds across the app: the
  flag lives in a worker variable and browsers terminate idle workers, so every page load
  re-asserts it from `localStorage`.
- **Sync** — whether automatic sync is on and how often, a live countdown, and progress.
  **Sync now** runs that same pass immediately rather than waiting out the countdown.
- **Downloads** — anything in `cache_archives`.
- **Cached** — every entry with size and age, a filter box, and a sort. Tapping a row shows
  the whole URL; each row has a trash icon.

To reach it offline, allowlist it like any other page. The worker script and the manifest are
never intercepted, so **Sync now** will fail while offline; the inspector, **Clear cache** and
**Force offline** are client-side and keep working.

---

## The offline page

The offline page carries its own styles and needs no configuration. It deliberately does not
pull in your stylesheet: everything it needs would then have to be cached for it to render,
and a fallback that depends on the cache being healthy is a fallback that fails when it is
needed. Override the template if you want it to look like the rest of the app.

**`data-turbo-track="reload"` is stripped from everything served offline** — the offline page,
and every page answered from the cache. Turbo refuses to render a page whose tracked elements
differ from the current page's, and does a full reload instead to pick up the new assets;
Hotwire Native shows that as a spinner, which going back can leave up for good. Offline there
are no new assets to pick up and the reload is answered from the same cache, so the mismatch
costs a document load and buys nothing.

Configuration could not have fixed this. Asset digests change with every deploy, so a page
cached before the current one was built disagrees with it no matter what the fallback carries.
A live page keeps its tracked elements, so the first fresh page after the connection returns
still mismatches — which is the reload you wanted, at the one moment it can succeed.

Override either template by creating it in your own app:

| Path | Renders |
|---|---|
| `app/views/coldwire/service_worker/offline_page.html.erb` | The full-page fallback |
| `app/views/coldwire/service_worker/offline_frame.html.erb` | The inside of the fallback `<turbo-frame>` |

Both are rendered at worker-build time and embedded in the script, so they are plain markup —
no request context, no helpers that need a current user. Three things to keep in the page:

- **CSS in the body, scoped.** Turbo's head merge copies new `<style>` elements into the app
  and never removes them, so a `<style>` in the head outlives the offline page and restyles
  everything after it.
- **The Turbo import**, alone rather than your app entry point — offline, every module in that
  graph would have to be cached for it to evaluate, and one miss means no Turbo.
- **`<meta name="turbo-cache-control" content="no-cache">`**, or Turbo snapshots the offline
  page and can restore it after you are back online.

Each template's **Try again** retries differently, because a template baked at build time
cannot know the URL it stands in for. The page uses `href=""` plus `data-turbo="false"`; the
frame uses `href="coldwire:retry-url"`, which the worker substitutes with the frame's own URL.

---

## Why this is harder than it looks

Six things break a naive offline cache in a Hotwire app. Four bite you in any browser; two are
Hotwire Native holding you to a stricter standard. Coldwire handles all six, which is what
lets one cache serve all three targets — and none of them cost a browser anything.

1. **`Vary: Accept` silently defeats precaching.** Rails answers HTML with `Vary: Accept` and
   `cache.match()` honors it. Precaching fetches with `Accept: */*`; Turbo asks for
   `text/html`. So a precached page only ever matches *another precache*, never a real visit —
   and it looks like it works, because caching pages as you visit them still does. Coldwire
   matches with `{ ignoreVary: true }`.
2. **A non-2xx offline page is never shown.** *(Native.)* Its adapter posts
   `visitRequestFailed` with a location, an identifier and a status — the response body never
   crosses into Swift, so no iOS override can render a `503`. Coldwire's fallback is a `200`.
3. **Turbo Frames need a frame.** A frame request discards any response without a matching
   `<turbo-frame>`, leaving the frame loading forever. Coldwire reads the `Turbo-Frame` header
   and answers with one.
4. **A followed redirect poisons the cache.** A signed-out request to `/` gets a `302` that
   `fetch` follows; the result looks fine and `cache.put()` stores it without complaint. Now
   `/` holds the sign-in page and keeps `redirected: true` — and serving a redirected response
   for a navigation is a network error by spec, so the app fails to cold launch offline.
   Coldwire refuses to store one.
5. **The offline page itself must boot Turbo.** *(Native.)* Its adapter waits for
   `window.Turbo` and reports *"The page could not be loaded because Turbo is not present"* if
   it never appears. Plain-HTML offline pages are not renderable in the app at all.
6. **Assets must not receive HTML.** A stylesheet handed an HTML offline page is just a broken
   asset. Coldwire serves the fallback only to requests that want HTML, and everything else an
   empty `504`.

The Cache API also ignores HTTP freshness headers entirely, and WebKit drops `Date` from
`match()`. So Coldwire stamps unix seconds onto the *request key* it stores under — `keys()`
hands it back, and URL matching still finds the entry. That is what the inspector's "2 hours
ago" reads.

---

## Requirements

- Rails 7.1+
- Turbo — a plain Hotwire app, a PWA, or Hotwire Native
- Service workers, and HTTPS (or localhost). They are same-origin, so the engine has to be
  mounted on the app's own domain
- Hotwire Native is optional. Nothing here requires it
- On iOS, service workers only run in `WKWebView` when navigation is limited to app-bound
  domains:

  ```swift
  Hotwire.config.makeCustomWebView = { config in
      config.limitsNavigationsToAppBoundDomains = true
      return WKWebView(frame: .zero, configuration: config)
  }
  ```

  with every domain you navigate to listed under `WKAppBoundDomains` in `Info.plist`. **Apple
  caps that list at 10 entries**, and an eleventh is silently dropped — which disables
  app-bound mode and takes service workers with it.

---

## License

MIT. See [LICENSE](LICENSE).
