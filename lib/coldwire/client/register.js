if ("serviceWorker" in navigator) {
  window.coldwireRegister = function () {
    return navigator.serviceWorker
      .register(COLDWIRE.workerPath, { scope: COLDWIRE.workerScope })
      .catch(function (error) { console.warn("[coldwire] registration failed", error) })
  }

  window.coldwireUnregister = function () {
    return navigator.serviceWorker.getRegistration(COLDWIRE.workerScope).then(function (registration) {
      if (registration) return registration.unregister()
    }).catch(function (error) { console.warn("[coldwire] unregister failed", error) })
  }

  if (window.coldwireStore.cachingOn()) {
    window.coldwireRegister()
  } else {
    window.coldwireUnregister()
  }
}
