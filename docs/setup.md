# Setup

The gem is `coldwire-rails`; everything in it lives under `Coldwire`, the way `turbo-rails`
provides `Turbo`. Add the gem, then let the installer wire the rest.

## Requirements

- Rails 7.1+
- Turbo — a plain Hotwire web app, a PWA, or Hotwire Native
- Service workers, and HTTPS (or localhost). They are same-origin, so the engine has to be
  mounted on the app's own domain
- Hotwire Native is optional. Nothing here requires it

On iOS, service workers only run in `WKWebView` when navigation is limited to app-bound
domains. See [Hotwire Native on iOS](#hotwire-native-on-ios).

## 1. Add the gem

```ruby
# Gemfile
gem "coldwire-rails"
```

Then `bundle install` and:

```bash
bin/rails coldwire:install
```

That does four things, and skips any it finds already done:

1. Mounts the engine at `/offline` in `config/routes.rb`
2. Writes `config/initializers/coldwire.rb` with every option and its default
3. Registers the Stimulus controller in `app/javascript/controllers/index.js`
4. Adds `<%= coldwire_service_worker_tag %>` inside `<head>` in your application layout

Visit `/offline` to see what's cached. What to set after that is below.

## By hand

The installer does the next four steps. Do them yourself if you would rather.

## 2. Mount the engine

```ruby
# config/routes.rb
mount Coldwire::Engine => "/offline"
```

The worker is served from the mount point, but sends `Service-Worker-Allowed: /` and
registers at `/`, so it controls the whole origin wherever you mount it. Narrow that with
[`config.worker_scope`](configuration.md#worker_scope) if you need to.

The mount also exposes:

| Path | What |
|---|---|
| `/offline` | The [offline settings page](#the-offline-settings-page) |
| `/offline/service-worker.js` | The worker script |
| `/offline/pack` | The precache manifest JSON |

The worker script and the manifest are never intercepted — caching either would strand the
app on a stale copy of the thing meant to refresh it. The offline settings page is ordinary HTML; list
it in `cache_as_you_go` if you want it reachable offline.

## 3. Register the Stimulus controller

```js
// app/javascript/controllers/index.js
import ColdwireCacheController from "coldwire"
application.register("coldwire-cache", ColdwireCacheController)
```

Coldwire pins `"coldwire"` into your importmap itself, so there is nothing to add to
`config/importmap.rb`.

## 4. Add the tag to your layout

```erb
<%# app/views/layouts/application.html.erb, inside <head> %>
<%= coldwire_service_worker_tag %>
```

This is what registers the worker. A page without the tag does not cache or sync. The helper
honours [`config.register_if`](configuration.md#register_if), so you can keep the tag in the
layout and still skip registration for some requests.

## 5. Create an initializer

```ruby
# config/initializers/coldwire.rb
Coldwire.configure do |config|
  config.auto_sync do |sync|
    sync.enabled = false
    sync.precache_urls = -> { [] }
  end
end
```

Every option has a working default. The full list, and what each one does, is in
[Configuration](configuration.md).

## What to set first

**`cache_identity`**, if the signed-in user is not `current_user` or `Current.user`. Cached
pages hold whatever the session that fetched them could see. The installer already uses
those two when they are in scope; override it if yours lives somewhere else.

```ruby
config.cache_identity = -> { current_user&.id }
```

**`auto_sync`**, if there are pages worth having before anyone visits them. Off by default,
because background fetching is somebody's data plan.

```ruby
config.auto_sync do |sync|
  sync.enabled = true
  sync.precache_urls = -> { Article.published.map { |a| article_path(a) } }
end
```

**`never_cache`**, for auth and admin. Put those paths here, not in `never_intercept` — they
are not the same setting, and they fail very differently offline. See
[`never_cache`](configuration.md#never_cache) and
[`never_intercept`](configuration.md#never_intercept).

**Your cold-boot URL must be cacheable.** Whatever URL the app loads at launch has to be
something the cache can hold. A login path usually is not: signed in, it is a `302` to the
app root, and a redirect is never cached. Boot into a real page instead; signed out it still
redirects to login, so nothing about the online flow changes.

## The offline settings page

Mounted at the engine root — `/offline` with the mount above. It inherits your
`ApplicationController`, so it picks up your layout, authentication, and helpers.

This is the page people use to turn offline support on or off, see connection status, download
archives, turn auto-sync off for this device, set how much storage the cache may use, force
offline, and manage what is cached.
Turning offline support off asks first, then deletes what is stored and hides the rest of the
page. It sets `content_for :title` to `"Offline settings"` — yield that in your layout's
`<title>` (and any native title bar that reads it) rather than expecting an on-page heading.
Put it behind whatever authentication you use by wrapping the route, or override
`app/views/coldwire/caches/show.html.erb`.

<p align="center">
  <img src="images/offline-settings.png" alt="Offline settings: status, force offline, auto sync, and downloads" width="280">
  <img src="images/offline-settings-cached.png" alt="Offline settings: every cached entry, with search, sort, and delete" width="280">
</p>

To reach it offline, list it in `cache_as_you_go` like any other page. **Sync now** talks to
the manifest, which is never intercepted, so that button fails while offline; **Inspect cache**,
**Clear cache**, and **Force offline** are client-side and keep working. **Keep at most** —
the storage ceiling, from
[`garbage_collection.max_size`](configuration.md#garbage_collectionmax_size) — is remembered
straight away, but the sweep it triggers needs a connection like any other, so a lowered
ceiling applies once there is one. The URL list lives
under Inspect cache, closed until you open it.

## Hotwire Native on iOS

Service workers only run in `WKWebView` when navigation is limited to app-bound domains:

```swift
Hotwire.config.makeCustomWebView = { config in
    config.limitsNavigationsToAppBoundDomains = true
    return WKWebView(frame: .zero, configuration: config)
}
```

with every domain you navigate to listed under `WKAppBoundDomains` in `Info.plist`. **Apple
caps that list at 10 entries**, and an eleventh is silently dropped — which disables
app-bound mode and takes service workers with it.

## Optional next steps

- Restrict what browsing stores with [`cache_as_you_go`](configuration.md#cache_as_you_go)
- Nominate other origins or `Range` URLs with [`cache_origins`](configuration.md#cache_origins)
  and [`cache_ranges`](configuration.md#cache_ranges)
- Offer large files for download with [`cache_archives`](configuration.md#cache_archives)
- Override the offline fallback by creating
  `app/views/coldwire/service_worker/offline_page.html.erb` (and
  `offline_frame.html.erb` for frames) in your app. See
  [The offline page](#the-offline-page) for what those templates have to keep.

## The offline page

When the network is down and there is no cached copy of the page, Coldwire serves this
fallback instead of letting the request fail. It is a `200` that boots Turbo, which is
what lets Hotwire Native render it at all — a `503` or a plain-HTML page would show the
SDK's error screen instead.

<p align="center">
  <img src="images/offline-fallback.png" alt="The offline fallback: You're offline. This page isn't available offline. Reconnect and try again." width="280">
</p>

It carries its own styles and needs no configuration. It deliberately does not pull in
your stylesheet: a fallback that depends on the cache being healthy is a fallback that
fails when it is needed. Cached pages still look like your app; this is only for URLs
nobody has, or that `never_cache` refused to store.

**Try again** retries the URL this page stood in for. The template is baked when the
worker is built, so it cannot know that URL — the page uses `href=""` plus
`data-turbo="false"` so the browser navigates to wherever it is being shown.

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
