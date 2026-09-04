(function () {
  if (window.Coldwire) return

  var root = document.documentElement

  window.Coldwire = {
    // True when the page you are looking at did not come from the network: either it
    // was served out of the cache, or force offline is on. Not `navigator.onLine`,
    // which a web view reports unreliably in both directions.
    isOffline: function () {
      return root.hasAttribute("data-coldwire-offline") || this.isForcedOffline()
    },

    // The switch on the debug page. Separate because it is a choice rather than a
    // condition: worth telling a user apart from having no signal.
    isForcedOffline: function () {
      return window.coldwireStore.on(window.coldwireStore.keys.forced)
    },

    // When the page in front of you was cached, or null if it came from the network.
    cachedAt: function () {
      var at = root.getAttribute("data-coldwire-cached-at")
      var seconds = at ? Number(at) : NaN

      return Number.isFinite(seconds) && seconds > 0 ? new Date(seconds * 1000) : null
    },

    // Fires on every Turbo visit and whenever force offline is toggled, so a map can
    // put its remote sources back without the page being reloaded. Returns the
    // unsubscribe, because a Stimulus controller that disconnects needs one.
    onChange: function (handler) {
      var listener = function (event) { handler(event.detail) }
      document.addEventListener("coldwire:change", listener)

      return function () { document.removeEventListener("coldwire:change", listener) }
    }
  }
})();
