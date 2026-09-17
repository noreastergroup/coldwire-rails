# frozen_string_literal: true

require "active_support/core_ext/object/blank"
require "active_support/core_ext/array/wrap"

module Coldwire
  class << self
    # The precache manifest, as the worker needs it. A bare URL is a page; a Hash can also name
    # the Turbo frame it is loaded into, or the format it is fetched as, which are the two
    # things a URL alone cannot say:
    #
    #   sync.precache_urls = -> {
    #     Feature.published.map { |f| { url: feature_path(f), frame: "map_feature_popup" } } +
    #     Report.all.map { |r| { url: report_path(r), format: :json } }
    #   }
    #
    # Listing one URL twice is how you ask for both the page and the frame, so nothing here
    # collapses them.
    def precache_entries(list)
      Array.wrap(list).map { |entry| precache_entry(entry) }
    end

    private

    def precache_entry(entry)
      return { url: entry.to_s } unless entry.is_a?(Hash)

      entry = entry.transform_keys(&:to_sym)
      url = entry[:url].to_s
      raise ArgumentError, "Coldwire precache_urls entries need a url: #{entry.inspect}" if url.empty?

      { url: url, frame: entry[:frame].presence&.to_s, accept: precache_accept(entry) }.compact
    end

    # A format becomes the Accept header the worker asks with, resolved here rather than in the
    # worker because Rails already knows what every registered format means — including any the
    # app registered itself.
    #
    # `format: :json` is the friendly way to say it and `accept:` is the way out when a media
    # type has no registered name. Naming a format that is not registered is a typo worth
    # refusing: it would otherwise be fetched as HTML and cached as the page.
    def precache_accept(entry)
      return entry[:accept].to_s if entry[:accept].present?
      return nil if entry[:format].blank?

      mime = Mime[entry[:format]]
      unless mime
        raise ArgumentError,
              "Coldwire precache_urls format #{entry[:format].inspect} is not a registered Mime " \
              "type. Register it with `Mime::Type.register`, or give `accept:` instead."
      end

      mime.to_s
    end
  end
end
