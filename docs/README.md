# Coldwire docs

Setup and configuration for [Coldwire](../README.md): the mountable Rails engine that
caches pages for Hotwire, PWAs, and Hotwire Native.

<p align="center">
  <img src="images/offline-settings.png" alt="Offline settings: status, force offline, the storage limit, auto sync, and downloads" width="280">
  <img src="images/offline-settings-cached.png" alt="Offline settings: every cached entry, with search, sort, and delete" width="280">
</p>

| | |
|---|---|
| [Setup](setup.md) | Install the gem, mount the engine, register the controller, add the layout tag |
| [Configuration](configuration.md) | Every option, its default, and what changing it does |
| [How it works](how-it-works.md) | Why a naive cache fails in Hotwire, and what Coldwire does about it |

Everything is set in `config/initializers/coldwire.rb` through `Coldwire.configure`.
`bin/rails coldwire:install` writes that file with every default. Only `auto_sync` really
needs your attention on a first install; `cache_identity` already uses `current_user` or
`Current.user` when either is in scope.
