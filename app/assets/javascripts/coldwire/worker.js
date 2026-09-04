// Talking to the service worker: one request, one reply, on a port this page owns.

export async function sendToWorker(type, payload, timeoutMs) {
  if (!("serviceWorker" in navigator)) {
    throw new Error("Service workers are not available in this web view")
  }

  // `ready` is a promise for a registration that may never exist, not a check — with nothing
  // registered for this scope it simply never settles. Unbounded, it hangs whatever awaited
  // it: the debug page sat on "Checking…" with an empty list, because the refresh never got
  // past its first question to the worker.
  const registration = await deadline(
    navigator.serviceWorker.ready, timeoutMs, "No service worker is registered for this page"
  )

  if (!registration.active) {
    throw new Error("Service worker is not active yet. Reload and try again.")
  }

  return deadline(new Promise((resolve) => {
    const { port1, port2 } = new MessageChannel()
    port1.onmessage = (event) => resolve(event.data)
    registration.active.postMessage({ type, ...payload }, [ port2 ])
  }), timeoutMs, "Timed out")
}

// A worker torn down mid-job answers nobody, so every wait on one needs a way out.
function deadline(promise, timeoutMs, message) {
  let timer = null

  return Promise.race([
    promise.finally(() => window.clearTimeout(timer)),
    new Promise((_, reject) => { timer = window.setTimeout(() => reject(new Error(message)), timeoutMs) })
  ])
}
