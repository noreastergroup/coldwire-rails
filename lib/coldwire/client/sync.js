(function () {
  // Turbo copies head scripts it does not recognise, and a per-request CSP nonce makes this
  // one look new on every visit — without the guard each visit leaves another timer behind.
  if (window.__coldwireAutoSync) return
  window.__coldwireAutoSync = true

  var store = window.coldwireStore
  var keys = store.keys
  var fallbackInterval = COLDWIRE.syncInterval

  // setTimeout holds its delay in a signed 32-bit integer and fires immediately on anything
  // larger — about 24.8 days. A longer wait wakes early and schedules the remainder.
  var maxDelay = 2147483647
  // How long a started run may go quiet before it is presumed dead.
  var silence = 30000
  // A native app is several web views at once, all reading the same deadline. Only the
  // visible one holds a timer, and whoever gets there first claims the run for this long.
  var claimLife = 10000
  var timer = null

  function interval() {
    // The last meta, not the first: Turbo appends what a visit brought and clears the old
    // head elements after, so mid-merge querySelector hands back the previous page's value.
    var metas = document.querySelectorAll('meta[name="coldwire-sync-interval"]')
    var meta = metas.length ? metas[metas.length - 1] : null
    var seconds = meta ? Number(meta.getAttribute("content")) : NaN

    return Number.isFinite(seconds) && seconds > 0 ? seconds * 1000 : fallbackInterval
  }

  // Zero — never synced — is in the past, which is the right answer.
  function dueAt() {
    var last = store.number(keys.syncedAt)

    return last ? last + interval() : 0
  }

  function schedule(delay) {
    window.clearTimeout(timer)
    timer = null
    if (document.hidden) return
    if (store.on(keys.syncOff)) return

    if (typeof delay !== "number") delay = Math.max(0, dueAt() - Date.now())
    timer = window.setTimeout(fire, Math.min(delay, maxDelay))
  }

  // Expiry rather than release: a page closed mid-sync must not lock the others out.
  function claim() {
    var held = store.number(keys.claim)
    if (held && Date.now() - held < claimLife) return false

    store.set(keys.claim, Date.now())

    return true
  }

  function fire() {
    // The debug page draws a countdown and drives its own sync. Two clocks on one page
    // cannot be kept honest, so stand down.
    if (window.__coldwireSyncOwnedByPage) return schedule(interval())
    if (document.hidden) return
    if (store.on(keys.syncOff)) return
    if (store.on(keys.forced)) return schedule(interval())
    // Another page may have synced while this one slept, or the wait may have been clamped.
    if (Date.now() < dueAt()) return schedule()
    if (!("serviceWorker" in navigator)) return
    if (!claim()) return schedule(interval())

    // A run that never reports back must not park this page forever.
    schedule(silence)

    navigator.serviceWorker.ready.then(function (registration) {
      var worker = registration.active || navigator.serviceWorker.controller
      if (!worker) return

      // On a port this page owns, so the outcome cannot be missed the way a broadcast can.
      // A page that navigates away mid-run records nothing, which is honest: the stamp stays
      // old and the next page picks the work up from what is actually in the cache.
      var channel = new MessageChannel()
      channel.port1.onmessage = function (event) { settle(event.data) }
      worker.postMessage({ type: "sync" }, [ channel.port2 ])
    })
  }

  function settle(result) {
    // Nothing was attempted — no connection, or force offline. Leave the clock alone so it
    // keeps saying when the cache was last actually brought up to date.
    if (result && result.offline) return schedule(interval())

    // Record the pass even if some of the manifest would not fetch. Requiring every URL to
    // succeed let one bad entry stop the clock for good: the app said "never synced" and
    // retried as fast as it could, because a deadline in the past is always due.
    store.set(keys.syncedAt, (result && result.finishedAt) || Date.now())
    schedule()
  }

  if ("serviceWorker" in navigator) {
    // A ServiceWorkerContainer starts with its message queue disabled, and addEventListener
    // alone does not enable it. Without this a page never hears a word the worker says.
    if (navigator.serviceWorker.startMessages) navigator.serviceWorker.startMessages()

    // Keeps the retry at bay while a run is visibly working; the clock is settled by the
    // reply above.
    navigator.serviceWorker.addEventListener("message", function (event) {
      var data = event.data
      if (!data || data.type !== "coldwire:sync") return
      if (data.state !== "finished") schedule(silence)
    })
  }

  // Deliberately not gated on navigator.onLine: a web view reports it unreliably, and a
  // false negative there would mean syncing never happens at all.
  document.addEventListener("turbo:load", function () { schedule() })
  window.addEventListener("online", function () { schedule() })
  // A backgrounded web view freezes its timers, so recompute on the way back — and cancel on
  // the way out, so a hidden tab holds nothing.
  document.addEventListener("visibilitychange", function () { schedule() })

  schedule()
})();
