if ("serviceWorker" in navigator) {
  navigator.serviceWorker
    .register(COLDWIRE.workerPath, { scope: COLDWIRE.workerScope })
    .catch(function (error) { console.warn("[coldwire] registration failed", error) })
}
