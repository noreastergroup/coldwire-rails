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
