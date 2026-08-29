# frozen_string_literal: true

require "coldwire/version"
require "coldwire/configuration"
require "coldwire/engine"

module Coldwire
  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield config
    end

    # Paths the worker never intercepts: whatever the host excluded, plus Coldwire's own
    # endpoints. Caching the worker or the prefetch manifest would strand the app on a
    # stale copy of the very thing meant to refresh it.
    def excluded_paths(mount_path)
      normalize(config.excluded_paths + [ mount_path ])
    end

    # Serializes a mixed list of strings and Regexps into something the worker can rebuild.
    # Ruby's `i` is the only flag with a safe JavaScript equivalent; the others are rejected
    # when the list is assigned.
    def cache_rules(patterns)
      Array(patterns).filter_map do |pattern|
        if pattern.is_a?(Regexp)
          { type: "regexp", source: pattern.source,
            flags: pattern.options.anybits?(Regexp::IGNORECASE) ? "i" : "" }
        else
          # Trim a trailing slash so "/sites/" and "/sites" behave alike, but not from "/"
          # itself — chomping that leaves an empty string and the rule vanishes, which is a
          # silent way to lose the root path.
          path = pattern.to_s
          path = path.chomp("/") unless path == "/"
          { type: "path", value: path } unless path.empty?
        end
      end
    end

    private

    def normalize(paths)
      paths.map { |path| path.to_s.chomp("/") }.reject(&:empty?).uniq
    end
  end
end
