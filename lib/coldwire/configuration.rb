# frozen_string_literal: true

require "uri"

module Coldwire
  # Host apps tune Coldwire through `Coldwire.configure`. Everything here has a working
  # default except `precache_urls`, which only the host app can know.
  class Configuration
    # Name of the Cache API cache. Bump it to invalidate everything at once.
    attr_accessor :cache_name

    # Scope the worker claims. The worker is served from the engine mount point, so the
    # response also sends `Service-Worker-Allowed` to widen it past that directory.
    attr_accessor :worker_scope

    # Markup for the offline page's <head>, evaluated in the view.
    #
    # This exists for one reason: Turbo refuses to render a page whose `data-turbo-track`
    # elements differ from the current page's, and instead invalidates. Hotwire Native answers
    # an invalidation by showing a spinner and reloading — survivable going forward, but going
    # *back* it runs while the visit stack is mid-pop and can leave the spinner up for good.
    #
    # So the offline page has to carry the same tracked elements as your real pages, in the
    # same order. Whatever your layout tracks, put it here:
    #
    #   config.offline_head = -> { stylesheet_link_tag "application", "data-turbo-track": "reload" }
    #
    # Coldwire's own importmap tag is emitted after this, matching the usual layout order of
    # stylesheets before scripts.
    attr_writer :offline_head

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
    attr_accessor :offline_import

    # Mark HTML served from cache because the network was unavailable, so the page can say
    # so. Adds `data-coldwire-offline` and `data-coldwire-cached-at` (unix seconds) to <html>,
    # plus a matching <meta> that survives Turbo's head merge. Costs a body rewrite, but only
    # on the offline path.
    attr_accessor :mark_cached_pages

    # Treat "/map" and "/map?lat=1&zoom=9" as the same cached page, both when matching and
    # when storing. Blunt on purpose for now: it also collapses query strings that genuinely
    # select content, like `/search?q=`, so a cached result set can be served for a different
    # query. Set false if your app leans on query strings for anything you cache.
    attr_accessor :ignore_query_params

    # Path the debug page pings to tell online from offline.
    #
    # navigator.onLine only reports whether a network interface is up — in a web view it is
    # true whenever wifi is on, so a stopped server still reads as online. The page has to
    # actually reach something. Rails' health check is the cheapest thing that exists: no
    # authentication, no database, and almost no response.
    #
    # Always excluded from interception. A probe answered by the worker resolves even when
    # the network is down, which is precisely backwards.
    attr_accessor :probe_path

    # Paths the worker must never intercept, as prefix strings. Health checks and anything
    # streaming belong here. The engine's own paths are added automatically.
    #
    # Use this sparingly. An unintercepted request goes straight to the network, so offline
    # it fails outright — in Hotwire Native that means the SDK's own error screen, not your
    # offline page. If you only want to keep something out of the cache, use `cache_blocklist`.
    attr_accessor :never_intercept

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
    # Decides whether a page registers the worker at all — and so whether it caches, syncs,
    # or does anything. Evaluated in the view, so both `request` and `current_user` are
    # available:
    #
    #   config.register_if = lambda do
    #     request.user_agent.to_s.include?("Hotwire Native") && current_user.present?
    #   end
    #
    # This is the one gate worth narrowing. Offline caching is for people using the app: a
    # browser session has no need of it, and a signed-out visitor's cache is dropped the
    # moment anyone signs in, so anything cached now is thrown away.
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

    # Origins besides your own that the worker may cache. Empty by default: a service worker
    # sees every request a page makes, and quietly hoarding third-party responses is not a
    # thing to do without being asked.
    #
    # The origin has to send CORS headers that name your app, or the response arrives opaque —
    # status 0, no headers, no readable body — and there is nothing useful to store. For ranged
    # sources it also has to expose Content-Range.
    attr_reader :cache_origins

    def cache_origins=(origins)
      @cache_origins = Array(origins).map { |origin| validate_origin(origin) }
    end

    # URLs whose Range requests are cached piece by piece, keyed by the range.
    #
    # For a large immutable archive read a slice at a time — a PMTiles basemap, say — this is
    # the difference between an offline map and nothing at all: the file itself may be hundreds
    # of megabytes, while the slices actually read for the area you looked at are a rounding
    # error next to it. Same patterns as the allowlist: route shapes or Regexps.
    attr_reader :cache_ranges

    def cache_ranges=(patterns)
      @cache_ranges = validate_patterns(patterns, :cache_ranges) || Array(patterns)
    end

    # Refetch a manifest page once its cached copy is older than this. Set nil to only ever
    # fetch pages that are missing.
    attr_accessor :refetch_after

    # How many fetches a sync runs at once.
    #
    # A sync works through the whole manifest in one pass. Sequential would take as many round
    # trips as there are URLs, and all-at-once would open a connection per URL and stall the
    # app's own requests behind them — so a fixed number of lanes pull from one queue.
    attr_accessor :sync_concurrency

    # Returns the list of paths to precache. Evaluated in the controller, so route helpers
    # and the current user are both available.
    attr_accessor :precache_urls

    def initialize
      @cache_name = "coldwire"
      @worker_scope = "/"
      @probe_path = "/up"
      @never_intercept = [ "/up" ]
      @cache_allowlist = []
      @cache_blocklist = []
      @mark_cached_pages = true
      @offline_import = "@hotwired/turbo-rails"
      @offline_head = nil
      @ignore_query_params = true
      @register_if = -> { true }
      @cache_identity = -> { nil }
      @precache_urls = -> { [] }
      @auto_sync = false
      @sync_interval = 6 * 60 * 60
      @cache_origins = []
      @cache_ranges = []
      @refetch_after = 7 * 24 * 60 * 60
      @sync_concurrency = 4
    end

    # `view` is the view context, so a host can ask about the request and the session alike.
    def register?(view)
      view.instance_exec(&@register_if) ? true : false
    end

    # `view` is the view context, so a host can write `-> { current_user&.id }`.
    def cache_identity(view)
      view.instance_exec(&@cache_identity).to_s
    end

    def offline_head(view)
      return if @offline_head.nil?

      view.instance_exec(&@offline_head)
    end

    private

    # Fail here rather than when the worker script is rendered, so a bad pattern surfaces at
    # boot instead of as a 500 that quietly takes caching down with it.
    def validate_patterns(patterns, setting)
      Array(patterns).each do |pattern|
        next validate_path_pattern(pattern, setting) unless pattern.is_a?(Regexp)

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

    # An origin and nothing more: no path, no trailing slash. Anything else silently fails to
    # match a request's origin, which is the same quiet failure as a malformed path pattern.
    def validate_origin(origin)
      value = origin.to_s

      begin
        uri = URI.parse(value)
      rescue URI::InvalidURIError
        uri = nil
      end

      unless uri&.scheme && uri.host && uri.path.to_s.empty? && uri.query.nil?
        raise ArgumentError,
              "Coldwire cache_origins takes bare origins like " \
              "\"https://tiles.example.com\": #{origin.inspect}"
      end

      value
    end

    # Path patterns are route-shaped: literal segments, ":name" for exactly one segment, and a
    # trailing "*" for the rest. Checked here because every mistake in this shape fails the
    # same silent way — the rule simply never matches, and you find out when something you
    # expected to be there offline is not.
    def validate_path_pattern(pattern, setting)
      path = pattern.to_s

      unless path.start_with?("/")
        raise ArgumentError,
              "Coldwire #{setting} paths are matched from the root, so they start with a " \
              "slash: #{pattern.inspect}"
      end

      parts = path.split("/").reject(&:empty?)

      parts.each_with_index do |part, index|
        next if part == "*" && index == parts.length - 1

        if part == "*"
          raise ArgumentError,
                "Coldwire #{setting} \"*\" matches everything remaining, so it can only be " \
                "the last segment: #{pattern.inspect}"
        end

        next if part.match?(/\A:[A-Za-z_]\w*\z/)
        next if part.match?(/\A[^:*]+\z/)

        raise ArgumentError,
              "Coldwire #{setting} segment #{part.inspect} is not a literal, a \":name\", or " \
              "a trailing \"*\": #{pattern.inspect}"
      end
    end
  end
end
