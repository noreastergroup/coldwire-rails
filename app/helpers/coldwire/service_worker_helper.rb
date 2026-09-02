# frozen_string_literal: true

module Coldwire
  module ServiceWorkerHelper
    OFFLINE_ATTRIBUTE = "data-coldwire-offline"
    CACHED_AT_ATTRIBUTE = "data-coldwire-cached-at"
    CHANGE_EVENT = "coldwire:change"

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
        [ coldwire_store_script, coldwire_api_script, coldwire_identity_script,
          coldwire_offline_marker_script,
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

      safe_join([
        tag.meta(name: "coldwire-sync-interval", content: Coldwire.config.sync_interval.to_i),
        # Whether this page in particular may start a sync. A meta for the same reason as the
        # interval: the script runs once per document, and Turbo reuses it across pages that
        # may not agree.
        tag.meta(name: "coldwire-auto-sync", content: Coldwire.config.auto_sync?(self) ? "on" : "off")
      ], "\n")
    end

    # What the host app is allowed to ask. Small on purpose: the page already knows whether it
    # came out of the cache — that is what `data-coldwire-offline` on <html> is for, and it is
    # what the `offline:` CSS variant reads — but a map deciding whether to reach for a remote
    # tile source needs to ask that in JavaScript, and needs to hear about it changing.
    def coldwire_api_script
      <<~JS
        (function () {
          if (window.Coldwire) return

          var root = document.documentElement

          window.Coldwire = {
            // True when the page you are looking at did not come from the network: either it
            // was served out of the cache, or force offline is on. Not `navigator.onLine`,
            // which a web view reports unreliably in both directions.
            isOffline: function () {
              return root.hasAttribute("#{OFFLINE_ATTRIBUTE}") || this.isForcedOffline()
            },

            // The switch on the debug page. Separate because it is a choice rather than a
            // condition: worth telling a user apart from having no signal.
            isForcedOffline: function () {
              return window.coldwireStore.on(window.coldwireStore.keys.forced)
            },

            // When the page in front of you was cached, or null if it came from the network.
            cachedAt: function () {
              var at = root.getAttribute("#{CACHED_AT_ATTRIBUTE}")
              var seconds = at ? Number(at) : NaN

              return Number.isFinite(seconds) && seconds > 0 ? new Date(seconds * 1000) : null
            },

            // Fires on every Turbo visit and whenever force offline is toggled, so a map can
            // put its remote sources back without the page being reloaded. Returns the
            // unsubscribe, because a Stimulus controller that disconnects needs one.
            onChange: function (handler) {
              var listener = function (event) { handler(event.detail) }
              document.addEventListener("#{CHANGE_EVENT}", listener)

              return function () { document.removeEventListener("#{CHANGE_EVENT}", listener) }
            }
          }
        })();
      JS
    end

    # Every piece of Coldwire that remembers anything goes through this: the head fragments
    # below, and the debug page's Stimulus controller, which reads it off `window`. One
    # implementation means one set of key names, one try/catch, and no chance of two parts of
    # the library disagreeing about where something is kept.
    #
    # localStorage throws rather than returning null in a private window, and can be evicted
    # whole, so every write is mirrored in memory and read back from there when the store has
    # nothing. Without that a browser refusing to persist would leave the sync clock reading
    # zero, and every finished sync would be due again the instant it ended — a hot loop.
    def coldwire_store_script
      <<~JS
        (function () {
          if (window.coldwireStore) return

          var memory = {}

          window.coldwireStore = {
            keys: {
              identity: "coldwire-identity",
              forced: "coldwire-forced",
              syncedAt: "coldwire-synced-at",
              claim: "coldwire-sync-claim"
            },

            get: function (key) {
              try {
                var value = window.localStorage.getItem(key)
                if (value !== null) return value
              } catch (error) {
                // Private mode and the like. Fall through to what this page remembers.
              }

              return key in memory ? memory[key] : null
            },

            set: function (key, value) {
              memory[key] = String(value)

              try {
                window.localStorage.setItem(key, String(value))
              } catch (error) {
                // Nothing to do. The value is still in memory for as long as this page lives.
              }
            },

            // A timestamp or a counter, and zero for anything missing or nonsensical — which
            // for a deadline means "in the past", and that is the right answer for one that
            // was never recorded.
            number: function (key) {
              var value = Number(this.get(key))

              return Number.isFinite(value) && value > 0 ? value : 0
            },

            on: function (key) {
              return this.get(key) === "1"
            },

            toggle: function (key, value) {
              this.set(key, value ? "1" : "0")
            }
          }
        })();
      JS
    end

    def coldwire_identity_script
      <<~JS
        (function () {
          var identity = #{Coldwire.config.cache_identity(self).to_json}
          var store = window.coldwireStore
          try {
            var key = store.keys.identity
            var previous = store.get(key)
            if (previous === identity) return

            // No stored identity is not a change of identity — it is a browser that has not
            // been told yet. localStorage and the cache store are evicted independently, so
            // treating null as "somebody else" would destroy a perfectly good cache the first
            // time localStorage came back empty.
            if (previous === null) {
              store.set(key, identity)
              return
            }

            // A real change, but never discard the cache while it is the only thing holding
            // the app up. Leave the stored identity alone too, so the mismatch is still there
            // to act on once there is a connection to refill from.
            if (!navigator.onLine) return

            store.set(key, identity)
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
          // Anything watching Coldwire.onChange hears about it here, after the attributes are
          // in step with the page that was just rendered.
          function announce() {
            document.dispatchEvent(new CustomEvent(#{CHANGE_EVENT.to_json}, {
              detail: {
                offline: window.Coldwire ? window.Coldwire.isOffline() : false,
                forced: window.Coldwire ? window.Coldwire.isForcedOffline() : false,
                cachedAt: window.Coldwire ? window.Coldwire.cachedAt() : null
              }
            }))
          }

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

            announce()
          }

          document.addEventListener("turbo:load", sync)
          announce()
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

          var store = window.coldwireStore
          var keys = store.keys
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

          // setTimeout holds its delay in a signed 32-bit integer and fires *immediately* on
          // anything larger — about 24.8 days. A longer wait wakes early and schedules the
          // remainder, which costs nothing.
          var maxDelay = 2147483647

          // How long a started run may go quiet before it is presumed dead and tried again.
          var silence = 30000

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
          var claimLife = 10000

          var timer = null

          function forced() {
            return store.on(keys.forced)
          }

          // Absent, the answer is yes: a page that says nothing is a page the host app never
          // narrowed, and the alternative is syncing silently stopping when a meta goes
          // missing. Last one wins, for the same mid-merge reason as the interval.
          function syncAllowed() {
            var metas = document.querySelectorAll('meta[name="coldwire-auto-sync"]')
            if (!metas.length) return true

            return metas[metas.length - 1].getAttribute("content") !== "off"
          }

          // When a sync is next owed: an interval after the last one that ran. Zero — never
          // synced — is in the past, which is exactly right.
          function dueAt() {
            var last = store.number(keys.syncedAt)

            return last ? last + interval() : 0
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
            var held = store.number(keys.claim)
            if (held && Date.now() - held < claimLife) return false

            store.set(keys.claim, Date.now())

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

            // This page may not be one that syncs — signed out, or somewhere the app does not
            // want the cache filled from. Keep the timer so arriving somewhere that does sync
            // picks straight up, without waiting for a reload.
            if (!syncAllowed()) return schedule(interval())

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
            // Nothing was attempted: no connection, or force offline is on. Leave the clock
            // untouched so it keeps saying when the cache was last actually brought up to
            // date, and wait out an interval — the `online` listener brings that forward if a
            // connection turns up sooner.
            if (result && result.offline) return schedule(interval())

            // A pass happened, so record it — even if some of the manifest would not fetch.
            // Requiring every single URL to succeed meant one bad entry among hundreds stopped
            // the clock permanently: the app said "never synced" for as long as that URL was
            // broken, and tried again as fast as it could because a deadline in the past is
            // always due. What failed simply stays missing from the cache, so the next pass
            // finds it and tries once more.
            store.set(keys.syncedAt, (result && result.finishedAt) || Date.now())
            schedule()
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
            if (!window.coldwireStore.on(window.coldwireStore.keys.forced)) return

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
