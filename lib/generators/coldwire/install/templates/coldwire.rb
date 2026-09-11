# frozen_string_literal: true

# Offline caching. Only `auto_sync` really needs your attention; the rest has a working
# default. See docs/configuration.md in the coldwire-rails gem for every option.
Coldwire.configure do |config|
  # What to precache and how often. Evaluated against your app's URL helpers.
  config.auto_sync do |sync|
    sync.enabled = false          # off by default: background fetching is somebody's data plan
    sync.precache_urls = -> { [] }
    # sync.precache_urls = -> { Article.published.map { |a| article_path(a) } }
    sync.interval = 1.day
    sync.max_age = 30.days
    sync.concurrency = 4
  end

  # Taking back what nothing has used lately, so the cache does not grow forever. Runs only
  # with a connection, and never takes the offline page's assets or a downloaded archive.
  # Anything a stored page still loads is renewed, so age means disuse rather than age.
  config.garbage_collection do |gc|
    gc.enabled = true
    gc.max_age = 60.days          # keep comfortably longer than auto_sync.max_age
    gc.max_size = 250.megabytes   # over this the least recently read go first; nil for no ceiling
    gc.interval = 1.day
  end

  # Who the cache belongs to. Evaluated in the view. When it changes, the cache is dropped —
  # which is what makes signing out, and switching accounts, safe. Uses current_user or
  # Current.user when either is around; otherwise nobody, and the cache stays put.
  config.cache_identity = -> {
    if respond_to?(:current_user)
      current_user&.id
    elsif defined?(Current) && Current.respond_to?(:user)
      Current.user&.id
    end
  }

  # Where the worker registers at all. Evaluated in the view, so `request` and `current_user`
  # are both in scope. A page that does not register does not cache or sync.
  config.register_if = -> { true }

  # Default for the Offline support switch on the offline settings page. People can turn
  # it off there, which deletes what is stored. A fresh device follows this.
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

  # Domains besides your own the worker may cache, and URLs whose Range requests it caches.
  # Bare domains — "tiles.example.com" — with a port only where it is not the default.
  config.cache_domains = []
  config.cache_ranges = []

  # Large files somebody can download for offline use. Nothing downloads on its own.
  config.cache_archives = []

  config.probe_path = "/up"          # pinged to tell online from offline
  config.mark_cached_pages = true    # stamp HTML served from cache
  config.ignore_query_params = true  # treat "/map" and "/map?zoom=9" as one page
  config.cache_name = "coldwire"     # bump to invalidate every entry at once
  config.worker_scope = "/"
end
