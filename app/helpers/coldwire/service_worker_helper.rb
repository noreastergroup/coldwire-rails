# frozen_string_literal: true

module Coldwire
  module ServiceWorkerHelper
    # Drop this in your layout's <head>. Emits nothing when `register_if` says this request
    # should not be caching — that check happens server side so no dead JS ships at all.
    #
    # Besides registering the worker, this compares the current cache identity against the
    # last one seen in this browser and drops the cache when it changes. Cached pages hold
    # whatever the previous session could see, so signing out — or signing in as someone
    # else — has to invalidate them.
    def coldwire_service_worker_tag
      return unless Coldwire.config.register?(request)

      javascript_tag(nonce: true) do
        <<~JS.html_safe
          (function () {
            var identity = #{Coldwire.config.cache_identity(self).to_json}
            try {
              var key = "coldwire-identity"
              if (window.localStorage.getItem(key) !== identity) {
                window.localStorage.setItem(key, identity)
                if ("caches" in window) caches.delete(#{Coldwire.config.cache_name.to_json})
              }
            } catch (error) {
              console.warn("[coldwire] could not reconcile cache identity", error)
            }

            if ("serviceWorker" in navigator) {
              navigator.serviceWorker
                .register(#{coldwire.service_worker_path.to_json}, { scope: #{Coldwire.config.scope.to_json} })
                .catch(function (error) { console.warn("[coldwire] registration failed", error) })
            }
          })()
        JS
      end
    end
  end
end
