# frozen_string_literal: true

# Offline caching. Only `auto_sync` really needs your attention; the rest has a working
# default. See docs/configuration.md in the coldwire-rails gem for every option.
Coldwire.configure do |config|
  # What to precache and how often. Evaluated against your app's URL helpers.
  config.auto_sync do |sync|
    sync.enabled = false          # off by default: background fetching is somebody's data plan
    sync.precache_urls = -> { [] }
    # sync.precache_urls = -> { Article.published.map { |a| article_path(a) } }
    sync.interval = 6.hours
    sync.max_age = 7.days
    sync.concurrency = 4
  end

  # Who the cache belongs to. Evaluated in the view. When it changes, the cache is dropped —
  # which is what makes signing out, and switching accounts, safe.
  config.cache_identity = -> { nil }
  # config.cache_identity = -> { current_user&.id }

  # Where the worker registers at all. Evaluated in the view, so `request` and `current_user`
  # are both in scope. A page that does not register does not cache or sync.
  config.register_if = -> { true }

  # Default for the Caching switch on the offline settings page. People can turn it off
  # there, which deletes what is stored. A fresh device follows this.
  config.caching_enabled_by_default = true

  # The importmap module the offline page loads to boot Turbo. nil if you are not on
  # importmap-rails; load Turbo your own way in the template instead.
  config.offline_import = "@hotwired/turbo-rails"

  # Which pages are kept as somebody browses. What one needs to render comes with it.
  # "/*" is everything; `never_cache` always wins. An empty list stores nothing by browsing.
  config.cache_as_you_go = [ "/*" ]
  config.never_cache = []

  # Never intercepted, so these fail outright offline. Coldwire's own routes are added for you.
  config.never_intercept = [ "/up" ]  # probe_path is added for you

  # Origins besides your own the worker may cache, and URLs whose Range requests it caches.
  config.cache_origins = []
  config.cache_ranges = []

  # Large files somebody can download for offline use. Nothing downloads on its own.
  config.cache_archives = []

  config.probe_path = "/up"          # pinged to tell online from offline
  config.mark_cached_pages = true    # stamp HTML served from cache
  config.ignore_query_params = true  # treat "/map" and "/map?zoom=9" as one page
  config.cache_name = "coldwire"     # bump to invalidate every entry at once
  config.worker_scope = "/"
end
