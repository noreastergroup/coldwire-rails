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
        [ coldwire_identity_script, coldwire_offline_marker_script,
          coldwire_auto_sync_script, coldwire_register_script ]
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

    # Hands the manifest to the worker and steps back. WebKit has no Background Sync, so a
    # page load is the only moment anything can be kicked off — but the work itself runs in
    # the worker, which keeps going after this page is gone.
    #
    # The stamp is written only when the worker reports the manifest fully in sync, and by
    # whichever page is open at that moment rather than the one that started it. So a sync cut
    # short — worker shut down, app backgrounded, signal lost — leaves no stamp, and the next
    # page load picks up where it left off: the worker recomputes what is missing from what is
    # actually in the cache, so resuming needs no bookmark.
    #
    # localStorage rather than the worker, because a worker global does not survive being
    # shut down, which is precisely the case this has to withstand.
    def coldwire_auto_sync_script
      return unless Coldwire.config.auto_sync

      <<~JS
        (function () {
          var stampKey = "coldwire-synced-at"
          var attemptsKey = "coldwire-sync-attempts"
          var interval = #{(Coldwire.config.sync_interval.to_i * 1000).to_json}
          var maxAttempts = #{Coldwire.config.sync_max_attempts.to_i.to_json}

          function read(key) {
            try { return Number(window.localStorage.getItem(key)) } catch (error) { return NaN }
          }

          function write(key, value) {
            try { window.localStorage.setItem(key, String(value)) } catch (error) {}
          }

          function due() {
            var last = read(stampKey)
            return !Number.isFinite(last) || last <= 0 || (Date.now() - last) > interval
          }

          // Only a finished sync sets the clock running again.
          function settle() {
            write(stampKey, Date.now())
            write(attemptsKey, 0)
          }

          if ("serviceWorker" in navigator) {
            navigator.serviceWorker.addEventListener("message", function (event) {
              if (event.data && event.data.type === "coldwire:synced") settle()
            })
          }

          function sync() {
            if (!navigator.onLine || !due()) return
            if (!("serviceWorker" in navigator)) return

            var attempts = read(attemptsKey)
            attempts = Number.isFinite(attempts) && attempts > 0 ? attempts : 0

            // A manifest that can never finish would otherwise fetch on every navigation for
            // the rest of the session. Give up and wait for the next interval instead.
            if (attempts >= maxAttempts) return settle()
            write(attemptsKey, attempts + 1)

            navigator.serviceWorker.ready.then(function (registration) {
              // The worker ignores this if a sync is already running, so navigating during a
              // long sync nudges it rather than starting a second one.
              if (registration.active) registration.active.postMessage({ type: "sync" })
            })
          }

          document.addEventListener("turbo:load", sync)
          window.addEventListener("online", sync)
          sync()
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
