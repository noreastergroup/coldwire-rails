# frozen_string_literal: true

module Coldwire
  # Host apps tune Coldwire through `Coldwire.configure`. Everything here has a working
  # default except `prefetch_urls`, which only the host app can know.
  class Configuration
    # Name of the Cache API cache. Bump it to invalidate everything at once.
    attr_accessor :cache_name

    # Scope the worker claims. The worker is served from the engine mount point, so the
    # response also sends `Service-Worker-Allowed` to widen it past that directory.
    attr_accessor :scope

    # The importmap module the offline page loads.
    #
    # Hotwire Native rejects any page where `window.Turbo` never appears — its adapter waits,
    # times out, and reports "Turbo is not present". So the fallback cannot be plain HTML; it
    # has to boot Turbo like a real page. Importing the whole app entry point would work but
    # is fragile offline: if any module in that graph is uncached the graph fails to evaluate
    # and Turbo never lands. Importing Turbo alone keeps the dependency to one file.
    #
    # Set to nil if you are not on importmap-rails, and override the offline page template to
    # load Turbo whatever way your bundler does.
    attr_accessor :offline_entry_point

    # Mark HTML served from cache because the network was unavailable, so the page can say
    # so. Adds `data-coldwire-offline` and `data-coldwire-cached-at` (unix seconds) to <html>,
    # plus a matching <meta> that survives Turbo's head merge. Costs a body rewrite, but only
    # on the offline path.
    attr_accessor :offline_marker

    # Treat "/map" and "/map?lat=1&zoom=9" as the same cached page, both when matching and
    # when storing. Blunt on purpose for now: it also collapses query strings that genuinely
    # select content, like `/search?q=`, so a cached result set can be served for a different
    # query. Set false if your app leans on query strings for anything you cache.
    attr_accessor :ignore_query_params

    # Paths the worker must never intercept, as prefix strings. Health checks and anything
    # streaming belong here. The engine's own paths are added automatically.
    #
    # Use this sparingly. An unintercepted request goes straight to the network, so offline
    # it fails outright — in Hotwire Native that means the SDK's own error screen, not your
    # offline page. If you only want to keep something out of the cache, use `uncached_paths`.
    attr_accessor :excluded_paths

    # Paths the worker intercepts but never stores. Sign-in and sign-up pages belong here:
    # serving them stale is wrong, but they should still reach the offline fallback rather
    # than dying as a network error.
    attr_accessor :uncached_paths

    # Decides whether a given request should register the worker at all. Receives the
    # ActionDispatch::Request. Defaults to registering everywhere; a Hotwire Native app
    # typically narrows this to the native user agent so browser tests stay uncached.
    attr_writer :register_if

    # Identifies who the cache belongs to — typically the signed-in user's id. Evaluated in
    # the view, so `current_user` is available. When the value changes between page loads the
    # cache is dropped, which is what makes signing out (or switching accounts) safe: cached
    # pages hold whatever the previous session could see.
    attr_writer :cache_identity

    # Returns the list of paths to precache. Evaluated in the controller, so route helpers
    # and the current user are both available.
    attr_accessor :prefetch_urls

    def initialize
      @cache_name = "coldwire"
      @scope = "/"
      @excluded_paths = [ "/up" ]
      @uncached_paths = []
      @offline_marker = true
      @offline_entry_point = "@hotwired/turbo-rails"
      @ignore_query_params = true
      @register_if = ->(_request) { true }
      @cache_identity = -> { nil }
      @prefetch_urls = -> { [] }
    end

    def register?(request)
      @register_if.call(request)
    end

    # `view` is the view context, so a host can write `-> { current_user&.id }`.
    def cache_identity(view)
      view.instance_exec(&@cache_identity).to_s
    end
  end
end
