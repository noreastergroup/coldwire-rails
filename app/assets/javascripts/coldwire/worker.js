// Talking to the service worker: one request, one reply, on a port this page owns.

export async function sendToWorker(type, payload, timeoutMs) {
  if (!("serviceWorker" in navigator)) {
    throw new Error("Service workers are not available in this web view")
  }

  const registration = await navigator.serviceWorker.ready
  if (!registration.active) {
    throw new Error("Service worker is not active yet. Reload and try again.")
  }

  return new Promise((resolve, reject) => {
    const { port1, port2 } = new MessageChannel()
    // A worker torn down mid-job answers nobody, so every send needs a way out. For a sync
    // that is a backstop only: the run reports itself over the broadcast either way.
    const timeout = window.setTimeout(() => reject(new Error("Timed out")), timeoutMs)

    port1.onmessage = (event) => {
      window.clearTimeout(timeout)
      resolve(event.data)
    }

    registration.active.postMessage({ type, ...payload }, [ port2 ])
  })
}
