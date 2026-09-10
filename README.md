# Coldwire

**When your Hotwire wires go cold.**

Offline caching for Rails. Add a gem, mount it, drop a tag in your layout — pages start
working without a network. A service worker precaches what you nominate, keeps pages as
people browse, and falls back to a view [Turbo](https://turbo.hotwired.dev) will actually
render.

Works the same in a plain Hotwire app, an installed PWA, or Hotwire Native.

> **Status: early.** Extracted from a production app but young as a library. The API may
> change before 1.0.

> [!TIP]
> **Need help going offline?** Coldwire is built by [Noreaster Group](https://noreastergroup.com).
> If you want a hand adding offline to your Hotwire or Hotwire Native app,
> [talk to us](https://noreastergroup.com).

## What you get

- **Minutes to wire.** Gem, mount, Stimulus controller, layout tag. The rest has working defaults.
- **Precaching in Ruby.** Nominate URLs with your own route helpers; assets come with them.
- **Cache as you go.** Pages someone visits are kept, with the styles, scripts, and images
  they need to render.
- **An offline fallback** Turbo — and Hotwire Native — will actually show.
- **Offline settings** at `/offline`: status, force offline, sync, downloads, what's cached.
- **Safe when people sign in.** The cache drops when the user changes.

<p align="center">
  <img src="docs/images/offline-settings.png" alt="Offline settings: status, force offline, auto sync, and downloads" width="280">
  <img src="docs/images/offline-settings-cached.png" alt="Offline settings: every cached entry, with search, sort, and delete" width="280">
</p>

<p align="center"><em>The offline settings page that ships with it.</em></p>

<p align="center">
  <img src="docs/images/offline-fallback.png" alt="The offline fallback: You're offline. This page isn't available offline. Reconnect and try again." width="280">
</p>

<p align="center"><em>When a page isn't cached and there's no network, this is what people see — not a blank screen or a native error. Override it to match your app.</em></p>

## Quick start

```ruby
# Gemfile
gem "coldwire-rails"
```

```ruby
# config/routes.rb
mount Coldwire::Engine => "/offline"
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

That's the wiring. Visit `/offline` to see what's cached.

For signed-in apps, set `cache_identity`. To have pages ready before anyone visits them,
turn on `auto_sync`. Both are in the [configuration reference](docs/configuration.md).

## Docs

- [Setup](docs/setup.md) — install, requirements, Hotwire Native on iOS
- [Configuration](docs/configuration.md) — every option and what it does
- [How it works](docs/how-it-works.md) — why a naive cache fails in Hotwire

## License

MIT. See [LICENSE](LICENSE).
