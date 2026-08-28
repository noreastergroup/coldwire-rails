# frozen_string_literal: true

module Coldwire
  module ServiceWorkerHelper
    # Drop this in your layout's <head>. Emits nothing when `register_if` says this request
    # should not be caching — that check happens server side so no dead JS ships at all.
    #
    # Besides registering the worker, this:
    #
    # * compares the current cache identity against the last one seen in this browser and
    #   drops the cache when it changes. Cached pages hold whatever the previous session
    #   could see, so signing out — or signing in as someone else — has to invalidate them.
    # * keeps the offline marker on <html> in step with the page Turbo just rendered.
    def coldwire_service_worker_tag
      return unless Coldwire.config.register?(request)

      # Each fragment is a self-terminated statement. `})()` followed by `(function` on the
      # next line is a single call expression, not two statements — ASI does not save you —
      # so a missing semicolon here throws and takes the registration down with it.
      javascript_tag(nonce: true) do
        [ coldwire_identity_script, coldwire_offline_marker_script, coldwire_register_script ]
          .compact
          .join("\n")
          .html_safe
      end
    end

    private

    def coldwire_identity_script
      <<~JS
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
        })();
      JS
    end

    # The worker stamps <html> so the very first paint is already correct, but Turbo swaps
    # the body and merges the head without ever copying <html> attributes — so after a Turbo
    # visit the marker would still describe the *previous* page. Turbo does replace head
    # metas, so mirror from the meta after each render.
    def coldwire_offline_marker_script
      return unless Coldwire.config.offline_marker

      <<~JS
        (function () {
          function sync() {
            var meta = document.querySelector('meta[name="coldwire-offline"]')
            var root = document.documentElement
            if (meta) {
              root.setAttribute("data-coldwire-offline", "")
              var at = meta.getAttribute("content")
              if (at) {
                root.setAttribute("data-coldwire-cached-at", at)
              } else {
                root.removeAttribute("data-coldwire-cached-at")
              }
            } else {
              root.removeAttribute("data-coldwire-offline")
              root.removeAttribute("data-coldwire-cached-at")
            }
          }

          document.addEventListener("turbo:load", sync)
        })();
      JS
    end

    def coldwire_register_script
      <<~JS
        if ("serviceWorker" in navigator) {
          navigator.serviceWorker
            .register(#{coldwire.service_worker_path.to_json}, { scope: #{Coldwire.config.scope.to_json} })
            .catch(function (error) { console.warn("[coldwire] registration failed", error) })
        }
      JS
    end
  end
end
