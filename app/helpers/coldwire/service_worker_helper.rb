# frozen_string_literal: true

module Coldwire
  module ServiceWorkerHelper
    # Drop this in your layout's <head>. Emits nothing when `register_if` says this request
    # should not be caching — that check happens server side so no dead JS ships at all.
    def coldwire_service_worker_tag
      return unless Coldwire.config.register?(request)

      javascript_tag(nonce: true) do
        <<~JS.html_safe
          if ("serviceWorker" in navigator) {
            navigator.serviceWorker
              .register(#{coldwire.service_worker_path.to_json}, { scope: #{Coldwire.config.scope.to_json} })
              .catch((error) => console.warn("[coldwire] registration failed", error))
          }
        JS
      end
    end
  end
end
