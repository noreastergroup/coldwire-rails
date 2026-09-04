(function () {
  var identity = COLDWIRE.identity
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
    if ("caches" in window) caches.delete(COLDWIRE.cacheName)
  } catch (error) {
    console.warn("[coldwire] could not reconcile cache identity", error)
  }
})();
