# frozen_string_literal: true

module Coldwire
  # Emits everything Coldwire needs in a page's <head>: a meta carrying the sync interval, and
  # one script that registers the worker and keeps the few things a worker cannot remember.
  #
  # The script itself lives in lib/coldwire/client as ordinary JavaScript. Only the values it
  # cannot know are passed in, as a `COLDWIRE` object it reads.
  module ServiceWorkerHelper
    USER_AGENT_COOKIE = "coldwire-user-agent"

    def coldwire_service_worker_tag
      return unless Coldwire.config.register?(self)

      safe_join([ coldwire_sync_interval_meta, coldwire_client_tag ].compact, "\n")
    end

    def coldwire_debug_styles
      tag.style(Coldwire::Source.debug_css.html_safe)
    end

    private

    def coldwire_client_tag
      javascript_tag(nonce: true) do
        Coldwire::Source.client(coldwire_client_config, coldwire_client_parts).html_safe
      end
    end

    def coldwire_client_config
      {
        cacheName: Coldwire.config.cache_name,
        identity: Coldwire.config.cache_identity(self),
        workerPath: coldwire.service_worker_path,
        workerScope: Coldwire.config.worker_scope,
        syncInterval: Coldwire.config.auto_sync.interval.to_i * 1000,
        userAgentCookie: USER_AGENT_COOKIE
      }
    end

    # Order matters: the store before anything that reads it, the registration last.
    def coldwire_client_parts
      parts = %w[store api identity]
      parts << "marker" if Coldwire.config.mark_cached_pages
      parts += %w[cookie forced]
      parts << "sync" if Coldwire.config.auto_sync.enabled
      parts << "register"
    end

    # Read on every use rather than baked into the script, so a document that outlives a config
    # change follows the new interval rather than the one it was born with.
    def coldwire_sync_interval_meta
      return unless Coldwire.config.auto_sync.enabled

      tag.meta(name: "coldwire-sync-interval", content: Coldwire.config.auto_sync.interval.to_i)
    end
  end
end
