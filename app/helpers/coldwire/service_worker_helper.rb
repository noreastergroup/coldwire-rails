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
          coldwire_forced_offline_script, coldwire_auto_sync_script, coldwire_register_script ]
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
            var previous = window.localStorage.getItem(key)
            if (previous === identity) return

            // No stored identity is not a change of identity — it is a browser that has not
            // been told yet. localStorage and the cache store are evicted independently, so
            // treating null as "somebody else" would destroy a perfectly good cache the first
            // time localStorage came back empty.
            if (previous === null) {
              window.localStorage.setItem(key, identity)
              return
            }

            // A real change, but never discard the cache while it is the only thing holding
            // the app up. Leave the stored identity alone too, so the mismatch is still there
            // to act on once there is a connection to refill from.
            if (!navigator.onLine) return

            window.localStorage.setItem(key, identity)
            if ("caches" in window) caches.delete(#{Coldwire.config.cache_name.to_json})
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

    # Hands the manifest to the worker and steps back. WebKit has no Background Sync, so an
    # open page is the only clock there is — it checks on load, on each Turbo visit, on
    # coming back to the foreground, and on a one-second tick for the case nobody navigates
    # at all. The work itself runs in the worker, which keeps going after this page is gone.
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
          // Turbo copies head scripts it does not already recognise, and a per-request CSP
          // nonce makes this one look new on every visit. Without this guard each visit would
          // leave another ticker behind, all of them asking at once.
          if (window.__coldwireAutoSync) return
          window.__coldwireAutoSync = true

          var stampKey = "coldwire-synced-at"
          var attemptsKey = "coldwire-sync-attempts"
          var backoffKey = "coldwire-sync-backoff"
          var interval = #{(Coldwire.config.sync_interval.to_i * 1000).to_json}
          var maxAttempts = #{Coldwire.config.sync_max_attempts.to_i.to_json}

          // How often the open page asks itself whether a sync is owed. Cheap — two
          // localStorage reads and a comparison — and it is the only clock there is.
          var checkEvery = 1000

          // A run reports itself as it works. While those reports keep coming there is
          // nothing to start; after this much silence — a worker shut down mid-sync — the
          // field is clear again and the next check may start a fresh one.
          var silence = 30000
          var activeUntil = 0

          function read(key) {
            try { return Number(window.localStorage.getItem(key)) } catch (error) { return NaN }
          }

          function write(key, value) {
            try { window.localStorage.setItem(key, String(value)) } catch (error) {}
          }

          function stale(key) {
            var at = read(key)
            return !Number.isFinite(at) || at <= 0
          }

          function due() {
            var backoff = read(backoffKey)
            if (Number.isFinite(backoff) && Date.now() < backoff) return false

            return stale(stampKey) || (Date.now() - read(stampKey)) > interval
          }

          if ("serviceWorker" in navigator) {
            navigator.serviceWorker.addEventListener("message", function (event) {
              var data = event.data
              if (!data || data.type !== "coldwire:sync") return

              if (data.state !== "finished") {
                activeUntil = Date.now() + silence
                return
              }

              activeUntil = 0

              // Only a run that got through the whole manifest restarts the clock.
              if (data.complete) {
                write(stampKey, Date.now())
                write(attemptsKey, 0)
                write(backoffKey, 0)
                return
              }

              // Count finished-but-incomplete runs, not messages sent. A manifest holding a
              // URL that will never fetch would otherwise be retried for the life of the
              // session; past the limit, wait out an interval before trying again.
              //
              // Backing off is deliberately not the same as syncing: the stamp keeps saying
              // when the cache was actually brought up to date, however long ago that was.
              var attempts = read(attemptsKey)
              attempts = Number.isFinite(attempts) && attempts > 0 ? attempts : 0
              attempts += 1

              if (attempts >= maxAttempts) {
                write(attemptsKey, 0)
                write(backoffKey, Date.now() + interval)
              } else {
                write(attemptsKey, attempts)
              }
            })
          }

          function sync() {
            // Deliberately not gated on navigator.onLine. A web view reports it unreliably,
            // and a false negative there means syncing never happens at all. A sync with no
            // connection fails harmlessly and leaves the stamp alone, so it is retried.
            if (!due()) return
            if (Date.now() < activeUntil) return
            if (!("serviceWorker" in navigator)) return

            navigator.serviceWorker.ready.then(function (registration) {
              // The worker hands back the run already in flight rather than starting a
              // second, so an extra nudge here costs nothing.
              if (registration.active) registration.active.postMessage({ type: "sync" })
            })
          }

          document.addEventListener("turbo:load", sync)
          window.addEventListener("online", sync)

          // A backgrounded web view freezes its timers, so the interval below cannot be
          // trusted to have kept counting. Coming back to the app is its own moment to check.
          document.addEventListener("visibilitychange", function () {
            if (!document.hidden) sync()
          })

          // The open page is not just a trigger, it is the clock. WebKit has no Background
          // Sync to schedule against, so nothing else can wake this up — and a page left open
          // past the interval has to notice by itself rather than waiting for a navigation
          // that may never come.
          window.setInterval(sync, checkEvery)
          sync()
        })();
      JS
    end

    # Re-asserts "force offline" on every page load.
    #
    # The worker keeps that flag in a variable, and the browser shuts idle workers down — so
    # left alone it silently switches itself off, which makes the one control you use to test
    # offline behaviour untrustworthy. localStorage remembers; each page load reminds the
    # worker.
    #
    # Only the on state is re-sent. Off is what a restarted worker already believes, and
    # broadcasting it would fight the debug page's own toggle.
    def coldwire_forced_offline_script
      <<~JS
        (function () {
          if (!("serviceWorker" in navigator)) return

          function apply() {
            try {
              if (window.localStorage.getItem("coldwire-forced") !== "1") return
            } catch (error) {
              return
            }

            navigator.serviceWorker.ready.then(function (registration) {
              if (registration.active) {
                registration.active.postMessage({ type: "setForcedOffline", value: true })
              }
            })
          }

          document.addEventListener("turbo:load", apply)
          apply()
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
