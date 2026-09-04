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

    # The importmap module the offline page loads. Hotwire Native reports "Turbo is not
    # present" for any page where `window.Turbo` never appears, so the fallback has to boot
    # Turbo — and Turbo alone, since one uncached module would fail the whole graph. nil if
    # you are not on importmap-rails; load it yourself in the template instead.
    attr_accessor :offline_import

    # Stamp HTML served from cache with `data-coldwire-offline` and `data-coldwire-cached-at`,
    # plus a <meta> that survives Turbo's head merge, so a page can say it is stale.
    attr_accessor :mark_cached_pages

    # Treat "/map" and "/map?zoom=9" as one cached page, matching and storing. Blunt: it also
    # collapses `/search?q=`, so a cached result set can answer a different query.
    attr_accessor :ignore_query_params

    # What the debug page pings to tell online from offline, because navigator.onLine only
    # reports whether an interface is up. Never intercepted — a probe answered from the cache
    # would resolve with the network down, which is precisely backwards.
    attr_accessor :probe_path

    # Paths the worker never intercepts, as prefix strings; the engine's own are added for
    # you. Sparingly: these go straight to the network and so fail outright offline, showing
    # the SDK's error screen rather than your offline page. To keep something merely out of
    # the cache, use `cache_blocklist`.
    attr_accessor :never_intercept

    # What automatic caching may and may not store. Strings are route patterns — "/sites/:id"
    # matches that shape and nothing beneath it — and Regexps are tested against the path by
    # JavaScript's RegExp, so write `^`/`$` rather than `\A`/`\z`.
    #
    # An empty allowlist allows everything; the blocklist always wins. Neither governs the
    # precache manifest: listing a URL there is an explicit instruction.
    attr_reader :cache_allowlist, :cache_blocklist

    def cache_allowlist=(patterns)
      @cache_allowlist = validate_patterns(patterns, :cache_allowlist)
    end

    def cache_blocklist=(patterns)
      @cache_blocklist = validate_patterns(patterns, :cache_blocklist)
    end

    # Whether a page registers the worker at all — and so whether it caches or syncs anything.
    # Evaluated in the view, so `request` and `current_user` are both in scope:
    #
    #   config.register_if = -> { hotwire_native_app? && current_user.present? }
    attr_writer :register_if

    # Who the cache belongs to, usually the signed-in user's id. When it changes between page
    # loads the cache is dropped, which is what makes signing out and switching accounts safe:
    # cached pages hold whatever the previous session could see.
    attr_writer :cache_identity

    # Origins besides your own that the worker may cache. Each has to send CORS headers naming
    # your app, or the response arrives opaque — status 0, no headers, no readable body — and
    # there is nothing worth storing. Ranged sources must also expose Content-Range.
    attr_reader :cache_origins

    def cache_origins=(origins)
      @cache_origins = Array(origins).map { |origin| validate_origin(origin) }
    end

    # URLs whose Range requests are cached piece by piece, keyed by the range — for a large
    # immutable archive read a slice at a time, the slices you actually read are a rounding
    # error next to the file. Same patterns as the allowlist.
    attr_reader :cache_ranges

    def cache_ranges=(patterns)
      @cache_ranges = validate_patterns(patterns, :cache_ranges) || Array(patterns)
    end

    # Large files somebody can choose to keep, each described well enough for the debug page
    # to offer it without knowing what it is:
    #
    #   config.cache_archives = [
    #     { url: "https://tiles.example.com/basemap.pmtiles", title: "Offline map",
    #       description: "The whole coast, rather than only the places you have opened." }
    #   ]
    #
    # A bare URL works too, with the filename as the title. Nothing downloads on its own:
    # hundreds of megabytes over somebody's connection is their decision.
    attr_reader :cache_archives

    def cache_archives=(archives)
      @cache_archives = Array(archives).map { |archive| normalize_archive(archive) }
    end

    # Just the URLs, for the worker — it downloads and serves; the words are the page's job.
    def cache_archive_urls
      cache_archives.map { |archive| archive[:url] }
    end

    # Keeping the cache current on its own. Grouped because these only mean anything together:
    # a manifest with no interval is never fetched, an interval with no manifest has nothing
    # to fetch.
    #
    #   config.auto_sync do |sync|
    #     sync.enabled = true
    #     sync.precache_urls = -> { Site.published.map { |site| site_path(site) } }
    #   end
    def auto_sync
      @auto_sync ||= AutoSync.new
      yield(@auto_sync) if block_given?

      @auto_sync
    end

    # WebKit has no Background Sync, Periodic Background Sync or Background Fetch, so nothing
    # can wake a worker. What a page load can do is hand work to one, which then runs on
    # without it — so syncing is triggered by an open page and paced, not scheduled.
    class AutoSync
      # Off unless asked for. Background fetching is a decision about somebody's data plan.
      attr_accessor :enabled

      # The pages to keep cached, evaluated in the controller so route helpers and the current
      # user are both available.
      attr_accessor :precache_urls

      # How long to leave between syncs.
      attr_accessor :interval

      # Refetch a manifest page once its copy is older than this. nil fetches only what is
      # missing, so pages already cached are never noticed to have changed.
      attr_accessor :max_age

      # Lanes sharing a queue: sequential would take a round trip per URL, and all at once
      # would stall the app's own requests behind hundreds of connections.
      attr_accessor :concurrency

      def initialize
        @enabled = false
        @precache_urls = -> { [] }
        @interval = 6 * 60 * 60
        @max_age = 7 * 24 * 60 * 60
        @concurrency = 4
      end
    end

    def initialize
      @cache_name = "coldwire"
      @worker_scope = "/"
      @probe_path = "/up"
      @never_intercept = [ "/up" ]
      @cache_allowlist = []
      @cache_blocklist = []
      @mark_cached_pages = true
      @offline_import = "@hotwired/turbo-rails"
      @ignore_query_params = true
      @register_if = -> { true }
      @cache_identity = -> { nil }
      @cache_origins = []
      @cache_ranges = []
      @cache_archives = []
    end

    # Evaluated in the view, so `request` and `current_user` are both in scope. A block that
    # declares a parameter is handed the request as well, which keeps `->(request) { ... }`
    # working for anyone who only cares about the headers.
    def register?(view)
      result = if @register_if.arity.zero?
        view.instance_exec(&@register_if)
      else
        view.instance_exec(view.request, &@register_if)
      end

      result ? true : false
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

    # A Hash with a url, or a bare URL string. Title falls back to the filename, which is a
    # poor title but a better one than a blank card.
    def normalize_archive(archive)
      archive = { url: archive } unless archive.is_a?(Hash)
      archive = archive.transform_keys(&:to_sym)
      url = archive[:url].to_s

      begin
        uri = URI.parse(url)
      rescue URI::InvalidURIError
        uri = nil
      end

      unless uri&.scheme && uri.host
        raise ArgumentError,
              "Coldwire cache_archives needs an absolute url for each entry: #{archive.inspect}"
      end

      {
        url: url,
        title: archive[:title].presence || File.basename(uri.path.to_s).presence || url,
        description: archive[:description].presence
      }
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
