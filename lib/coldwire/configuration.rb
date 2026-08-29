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
    # offline page. If you only want to keep something out of the cache, use `cache_blocklist`.
    attr_accessor :excluded_paths

    # Which URLs automatic caching is allowed to store, and which it must not.
    #
    # Both accept strings and Regexps. A string matches the path as a segment prefix, so
    # "/users" covers "/users" and "/users/sign_in" but not "/username". A Regexp is tested
    # against the path, and is evaluated by JavaScript's RegExp — write JS-compatible syntax
    # (`^`/`$`, not `\A`/`\z`).
    #
    # An empty allowlist means "everything is allowed"; a non-empty one means "only these".
    # The blocklist always wins.
    #
    # **These govern automatic caching only.** Anything in the precache manifest is stored
    # regardless: listing a URL there is an explicit instruction, and quietly declining it
    # would make the manifest unpredictable.
    attr_reader :cache_allowlist, :cache_blocklist

    def cache_allowlist=(patterns)
      @cache_allowlist = validate_patterns(patterns, :cache_allowlist)
    end

    def cache_blocklist=(patterns)
      @cache_blocklist = validate_patterns(patterns, :cache_blocklist)
    end

    # Decides whether a given request should register the worker at all. Receives the
    # ActionDispatch::Request. Defaults to registering everywhere; a Hotwire Native app
    # typically narrows this to the native user agent so browser tests stay uncached.
    attr_writer :register_if

    # Identifies who the cache belongs to — typically the signed-in user's id. Evaluated in
    # the view, so `current_user` is available. When the value changes between page loads the
    # cache is dropped, which is what makes signing out (or switching accounts) safe: cached
    # pages hold whatever the previous session could see.
    attr_writer :cache_identity

    # Keep the precache manifest current on its own, rather than only when someone presses
    # the button.
    #
    # WebKit has no Background Sync, Periodic Background Sync, or Background Fetch, so there
    # is no true "wake up later" primitive in a Hotwire Native web view. What there is: a page
    # load can hand work to the service worker, which then runs independently of that page.
    # So sync is triggered on page load and throttled, rather than scheduled.
    attr_accessor :auto_sync

    # How long to leave between syncs. Checked against a localStorage stamp on the page,
    # because a worker global does not survive the worker being shut down.
    attr_accessor :sync_interval

    # Refetch a manifest page once its cached copy is older than this. Set nil to only ever
    # fetch pages that are missing.
    attr_accessor :max_age

    # How many page loads may attempt an unfinished sync before it gives up and waits for the
    # next interval. A circuit breaker, not a tuning knob: without it, a manifest listing a
    # URL that can never be fetched would try again on every single navigation, forever.
    attr_accessor :sync_max_attempts

    # Most pages one sync will fetch, so a first run on a cellular connection does not pull
    # the whole manifest at once. The rest are picked up by later syncs. 0 means no limit.
    attr_accessor :sync_batch_limit

    # Returns the list of paths to precache. Evaluated in the controller, so route helpers
    # and the current user are both available.
    attr_accessor :prefetch_urls

    def initialize
      @cache_name = "coldwire"
      @scope = "/"
      @excluded_paths = [ "/up" ]
      @cache_allowlist = []
      @cache_blocklist = []
      @offline_marker = true
      @offline_entry_point = "@hotwired/turbo-rails"
      @ignore_query_params = true
      @register_if = ->(_request) { true }
      @cache_identity = -> { nil }
      @prefetch_urls = -> { [] }
      @auto_sync = false
      @sync_interval = 6 * 60 * 60
      @max_age = 7 * 24 * 60 * 60
      @sync_batch_limit = 25
      @sync_max_attempts = 25
    end

    def register?(request)
      @register_if.call(request)
    end

    # `view` is the view context, so a host can write `-> { current_user&.id }`.
    def cache_identity(view)
      view.instance_exec(&@cache_identity).to_s
    end

    private

    # Fail here rather than when the worker script is rendered, so a bad pattern surfaces at
    # boot instead of as a 500 that quietly takes caching down with it.
    def validate_patterns(patterns, setting)
      Array(patterns).each do |pattern|
        next unless pattern.is_a?(Regexp)

        # `\A` and friends are reflex for a Ruby developer, and JavaScript reads them as
        # identity escapes — `\A` quietly becomes a literal "A" and the rule never matches.
        if pattern.source.match?(/(?<!\\)\\[AzZ]/)
          raise ArgumentError,
                "Coldwire evaluates #{setting} patterns with JavaScript's RegExp, which reads " \
                "\\A, \\z and \\Z as literal letters. Use ^ and $ instead: #{pattern.inspect}"
        end

        unsupported = []
        unsupported << "x (extended)" if pattern.options.anybits?(Regexp::EXTENDED)
        unsupported << "m (multiline)" if pattern.options.anybits?(Regexp::MULTILINE)
        next if unsupported.empty?

        raise ArgumentError,
              "Coldwire evaluates #{setting} patterns with JavaScript's RegExp, which has no " \
              "equivalent for #{unsupported.join(' and ')}: #{pattern.inspect}"
      end
    end
  end
end
