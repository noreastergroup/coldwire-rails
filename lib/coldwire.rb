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
      (config.excluded_paths + [ mount_path ]).map { |path| path.to_s.chomp("/") }.uniq
    end
  end
end
