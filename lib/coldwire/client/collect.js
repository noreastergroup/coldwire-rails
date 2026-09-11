(function () {
  // Turbo copies head scripts it does not recognise, and a per-request CSP nonce makes this
  // one look new on every visit — without the guard each visit wires another listener.
  if (window.__coldwireCollect) return
  window.__coldwireCollect = true

  var store = window.coldwireStore
  var keys = store.keys
  var interval = COLDWIRE.collectInterval

  // Nothing like the sync scheduler here on purpose. A sweep is quick, takes no network worth
  // pacing, and two of them at once is harmless — so there is no claim to hold, no countdown
  // to draw, and no progress to report. A stamp and a check are the whole clock.
  function due() {
    var last = store.number(keys.collectedAt)

    return !last || Date.now() - last >= interval
  }

  function run() {
    if (!due()) return
    if (store.on(keys.forced)) return
    if (!store.cachingOn()) return
    if (!("serviceWorker" in navigator)) return

    navigator.serviceWorker.ready.then(function (registration) {
      var worker = registration.active || navigator.serviceWorker.controller
      if (!worker) return

      var channel = new MessageChannel()
      channel.port1.onmessage = function (event) {
        var result = event.data
        // No connection, or force offline: nothing was swept, so leave the clock alone and
        // let the next page find it still due.
        if (!result || result.offline) return

        store.set(keys.collectedAt, Date.now())
      }
      // The ceiling travels with the request: it lives in localStorage, which a worker
      // cannot read, and it is a choice this device made rather than one the app baked in.
      worker.postMessage({ type: "collect", maxSize: store.maxSize() }, [ channel.port2 ])
    })
  }

  document.addEventListener("turbo:load", run)
  window.addEventListener("online", run)

  run()
})();
