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
      safe_join([ coldwire_sync_interval_meta, javascript_tag(nonce: true) do
        [ coldwire_identity_script, coldwire_offline_marker_script,
          coldwire_forced_offline_script, coldwire_auto_sync_script, coldwire_register_script ]
          .compact
          .join("\n")
          .html_safe
      end ].compact, "\n")
    end

    private

    # The interval as a meta rather than only a constant in the script above.
    #
    # A head script runs once per document. Turbo visits reuse the document, so a page opened
    # before the interval changed would keep the old one for as long as it stayed open — the
    # markup would say five minutes while the timer underneath it still fired every fifteen
    # seconds. Turbo *does* replace head metas on every visit, so reading it back from here
    # each time a sync is scheduled means the next navigation picks up the new value.
    def coldwire_sync_interval_meta
      return unless Coldwire.config.auto_sync

      tag.meta(name: "coldwire-sync-interval", content: Coldwire.config.sync_interval.to_i)
    end

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
    # open page is the only clock there is: on load it works out when a sync is next owed and
    # sleeps exactly that long — five seconds or five weeks — rather than waking up to ask.
    # The work itself runs in the worker, which keeps going after this page is gone.
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
          // leave another timer behind, all of them firing at once.
          if (window.__coldwireAutoSync) return
          window.__coldwireAutoSync = true

          var stampKey = "coldwire-synced-at"
          var attemptsKey = "coldwire-sync-attempts"
          var backoffKey = "coldwire-sync-backoff"
          // Only the starting value. Read back from the meta on every use, so a document that
          // outlives a config change follows the new interval rather than the one it was
          // born with.
          var fallbackInterval = #{(Coldwire.config.sync_interval.to_i * 1000).to_json}

          function interval() {
            // The last one, not the first. Turbo appends what a visit brought and clears the
            // old provisional head elements after; catch it mid-merge and querySelector hands
            // back the previous page's value, which is how a document ends up syncing on an
            // interval nobody configured.
            var metas = document.querySelectorAll('meta[name="coldwire-sync-interval"]')
            var meta = metas.length ? metas[metas.length - 1] : null
            var seconds = meta ? Number(meta.getAttribute("content")) : NaN

            return Number.isFinite(seconds) && seconds > 0 ? seconds * 1000 : fallbackInterval
          }
          var maxAttempts = #{Coldwire.config.sync_max_attempts.to_i.to_json}

          // setTimeout holds its delay in a signed 32-bit integer and fires *immediately* on
          // anything larger — about 24.8 days. A longer wait wakes early and schedules the
          // remainder, which costs nothing.
          var maxDelay = 2147483647

          // How long a started run may go quiet before it is presumed dead and tried again.
          var silence = 30000

          // A year. Long enough that the clock is never lost to expiry, and the value is
          // rewritten on every completed sync anyway.
          var stampLife = 31536000

          // A Hotwire Native app is several web views at once — one per tab — and every one of
          // them runs this. Left alone they all hold a timer against the same shared deadline
          // and all wake together, so one app becomes a small burst of identical requests.
          // Two rules keep that from happening:
          //
          //   1. Only the visible page holds a timer. A hidden web view cancels its own and
          //      re-arms when it comes back, so the tabs behind you are doing nothing at all.
          //   2. Whoever gets there first claims the run for a few seconds. Anyone else
          //      arriving in that window leaves it alone rather than asking for the same work.
          //
          // The worker also hands back the run already in flight, so a duplicate would be
          // harmless — but not asking at all is better than being harmless.
          var claimKey = "coldwire-sync-claim"
          var claimLife = 10000

          var timer = null
          var lastFinished = 0

          function read(key) {
            // Fall back to what this page last saw. If the cookie cannot be stored — blocked,
            // full, a private window — the clock would read zero forever, every completed sync
            // would be due again the instant it ended, and the result is a hot loop against
            // the network. Remembering it here keeps the pacing right even when nothing sticks.
            if (key === stampKey) return Math.max(readCookie(key) || 0, lastFinished)

            try { return Number(window.localStorage.getItem(key)) } catch (error) { return NaN }
          }

          function write(key, value) {
            if (key === stampKey) {
              lastFinished = Number(value) || 0
              return writeCookie(key, value)
            }

            try { window.localStorage.setItem(key, String(value)) } catch (error) {}
          }

          // When the cache was last brought up to date is the one fact here worth keeping
          // properly. A cookie with an explicit expiry outlives the site data a web view may
          // clear out from under localStorage, and it is a single number, so the cost of
          // carrying it on requests is a dozen bytes.
          function readCookie(key) {
            try {
              var match = document.cookie.match(new RegExp("(?:^|; )" + key + "=([^;]*)"))
              return match ? Number(decodeURIComponent(match[1])) : NaN
            } catch (error) {
              return NaN
            }
          }

          function writeCookie(key, value) {
            try {
              var secure = document.location.protocol === "https:" ? "; secure" : ""
              document.cookie = key + "=" + encodeURIComponent(String(value)) +
                "; path=/; max-age=" + stampLife + "; samesite=lax" + secure
            } catch (error) {}
          }

          function forced() {
            try {
              return window.localStorage.getItem("coldwire-forced") === "1"
            } catch (error) {
              return false
            }
          }

          function stamp(key) {
            var at = read(key)
            return Number.isFinite(at) && at > 0 ? at : 0
          }

          // When a sync is next owed: an interval after the last completed one, pushed later
          // if a string of failures set a backoff past that. Zero — never synced — is in the
          // past, which is exactly right.
          function dueAt() {
            var last = stamp(stampKey)
            return Math.max(last ? last + interval() : 0, stamp(backoffKey))
          }

          // Sleep exactly as long as is owed rather than waking up to ask. An overdue
          // deadline is a delay of zero, so a page that loads late syncs as soon as it can.
          function schedule(delay) {
            window.clearTimeout(timer)
            timer = null

            // Nothing pending while out of sight. Coming back re-arms, and recomputes from
            // the shared clock rather than resuming a countdown that stopped meaning anything
            // the moment the web view was frozen.
            if (document.hidden) return

            if (typeof delay !== "number") delay = Math.max(0, dueAt() - Date.now())
            timer = window.setTimeout(fire, Math.min(delay, maxDelay))
          }

          // A claim only one page can hold, and only briefly. Expiry rather than release: a
          // page that is closed mid-sync must not lock the others out.
          function claim() {
            var held = stamp(claimKey)
            if (held && Date.now() - held < claimLife) return false

            write(claimKey, Date.now())

            return true
          }

          function fire() {
            // A page that shows a countdown drives its own sync, and two clocks on one page
            // cannot be kept honest: whichever fires first wins, and the display is left
            // describing the other one. Stand down and let it schedule.
            if (window.__coldwireSyncOwnedByPage) return schedule(interval())

            // Out of sight, out of the running. The timer should already be cleared; this is
            // the belt to that braces.
            if (document.hidden) return

            // Force offline asks for no network. Syncing is only network, so there is nothing
            // to do but come back at the usual cadence and see whether it is still on.
            if (forced()) return schedule(interval())

            // A page cannot assume it is the only one. Another may have synced while this one
            // slept, or the wait may have been clamped, in which case sleep out the rest.
            if (Date.now() < dueAt()) return schedule()
            if (!("serviceWorker" in navigator)) return

            // Somebody else got here first. They will record the outcome for everyone.
            if (!claim()) return schedule(interval())

            // A run that never reports back — no worker, no answer — must not park this page
            // forever. Anything the run does say replaces this.
            schedule(silence)

            navigator.serviceWorker.ready.then(function (registration) {
              // The worker hands back the run already in flight rather than starting a
              // second, so asking twice costs nothing.
              var worker = registration.active || navigator.serviceWorker.controller
              if (!worker) return

              // Ask over a channel this page owns, and hear the outcome on it. A page that
              // navigates away mid-run takes its port with it and records nothing — which is
              // the honest result: the stamp stays old, and the next page picks the work up
              // where the cache left off.
              var channel = new MessageChannel()
              channel.port1.onmessage = function (event) { settle(event.data) }
              worker.postMessage({ type: "sync" }, [ channel.port2 ])
            })
          }

          // What a finished run means for the clock. Reached from the run's own reply, so
          // this does not depend on broadcasts arriving.
          function settle(result) {
            // Nothing was attempted, so nothing counts against the manifest: no connection, or
            // force offline is on. Wait out an interval; the `online` listener below brings it
            // forward if a connection turns up sooner.
            if (result && result.offline) return schedule(interval())

            // Only a run that got through the whole manifest restarts the clock.
            if (result && result.complete) {
              write(stampKey, result.finishedAt || Date.now())
              write(attemptsKey, 0)
              write(backoffKey, 0)
              return schedule()
            }

            // Count finished-but-incomplete runs, not messages sent. A manifest holding a
            // URL that will never fetch would otherwise be retried for the life of the
            // session; past the limit, wait out an interval before trying again.
            //
            // Backing off is deliberately not the same as syncing: the stamp keeps saying
            // when the cache was actually brought up to date, however long ago that was.
            var attempts = stamp(attemptsKey) + 1

            if (attempts >= maxAttempts) {
              write(attemptsKey, 0)
              write(backoffKey, Date.now() + interval())
              return schedule()
            }

            write(attemptsKey, attempts)
            // A retry waits exactly as long as a success does. Backing off faster than the
            // interval — which this used to do, on a 2s, 4s, 6s ladder — meant a manifest with
            // one URL that would not fetch synced several times a minute while the page
            // faithfully displayed the interval it was configured with. The interval is the
            // interval, whatever the outcome. Scheduling off the deadline alone cannot work
            // here: a failed run leaves it in the past, so this must be an explicit wait.
            schedule(interval())
          }

          if ("serviceWorker" in navigator) {
            // A ServiceWorkerContainer starts with its message queue disabled. Setting
            // onmessage enables it; addEventListener alone does not, and this call is the
            // documented way to enable it for a listener registered this way. Without it a
            // page can sit and never hear a word the worker says.
            if (navigator.serviceWorker.startMessages) navigator.serviceWorker.startMessages()

            // Broadcasts are for keeping the retry at bay while a run is visibly working.
            // The clock itself is settled by the reply, below, which arrives on a port this
            // page opened and so cannot be missed the way a broadcast can.
            navigator.serviceWorker.addEventListener("message", function (event) {
              var data = event.data
              if (!data || data.type !== "coldwire:sync") return
              if (data.state !== "finished") schedule(silence)
            })
          }

          // Deliberately not gated on navigator.onLine. A web view reports it unreliably, and
          // a false negative there means syncing never happens at all. A sync with no
          // connection fails harmlessly and leaves the stamp alone, so it is retried.
          document.addEventListener("turbo:load", function () { schedule() })
          window.addEventListener("online", function () { schedule() })

          // A backgrounded web view freezes its timers, so a wait that should have elapsed
          // may simply not have. Recomputing on the way back fires at once when overdue.
          // Both directions matter now: coming back arms a timer and fires at once if the
          // deadline has passed, and going away cancels it so a backgrounded tab holds nothing.
          document.addEventListener("visibilitychange", function () {
            schedule()
          })

          schedule()
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
