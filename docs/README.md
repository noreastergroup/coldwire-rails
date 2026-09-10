# Coldwire docs

Setup and configuration for [Coldwire](../README.md): the mountable Rails engine that
caches pages for Hotwire, PWAs, and Hotwire Native.

The [project README](../README.md) is the narrative — what Coldwire does, how the cache
behaves, and why a naive one fails in a Hotwire app. These pages are the reference for
putting it in an app and tuning it.

| | |
|---|---|
| [Setup](setup.md) | Install the gem, mount the engine, register the controller, add the layout tag |
| [Configuration](configuration.md) | Every option, its default, and what changing it does |

Everything is set in `config/initializers/coldwire.rb` through `Coldwire.configure`. Only
`auto_sync` really needs your attention on a first install; `cache_identity` needs it if
anyone signs in.
