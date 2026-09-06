# frozen_string_literal: true

require "pathname"

module Coldwire
  # JavaScript and CSS that ship as files and are assembled when they are rendered, so none of
  # it has to be written inside a Ruby string.
  module Source
    ROOT = Pathname.new(__dir__)

    # The worker is served as one script but written as several. Concatenated rather than
    # imported, so the browser still fetches one file and function declarations hoist across
    # the whole of it.
    WORKER = %w[rules serve ranges archives inspect sync events].freeze

    class << self
      def worker
        assemble(WORKER.map { |part| read("worker/#{part}.js") })
      end

      # The page-side script: the values it cannot know, then whichever parts this page needs.
      #
      # A property rather than a const. Turbo copies head scripts it does not recognise, and a
      # per-request CSP nonce makes this one look new on every visit — a second `const COLDWIRE`
      # in the same document is a SyntaxError, and the whole script dies with it.
      def client(config, parts)
        assemble([ "window.COLDWIRE = #{config.to_json};" ] + parts.map { |part| read("client/#{part}.js") })
      end

      def debug_css
        read("debug.css")
      end

      private

      def read(path)
        ROOT.join(path).read
      end

      # Each fragment is self-terminated. `})()` followed by `(function` reads as one call
      # expression rather than two statements, and ASI does not save you.
      def assemble(parts)
        parts.join("\n")
      end
    end
  end
end
