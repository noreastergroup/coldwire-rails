(function () {
  if (window.coldwireStore) return

  var memory = {}

  window.coldwireStore = {
    keys: {
      identity: "coldwire-identity",
      forced: "coldwire-forced",
      syncedAt: "coldwire-synced-at",
      claim: "coldwire-sync-claim",
      // Set only when somebody turns automatic syncing off, so an unset store — a
      // fresh device, a cleared one — means on, which is what the app configured.
      syncOff: "coldwire-sync-off",
      // "1" or "0" once somebody has used the Offline support switch. Unset follows
      // COLDWIRE.cachingEnabledByDefault, so a fresh device gets the app's default.
      caching: "coldwire-caching",
      // The URL list on the settings page. Closed unless they have opened it.
      inspect: "coldwire-inspect",
      // When the cache was last swept. Only written when a sweep actually ran, so a run
      // skipped for want of a connection leaves the next page still due.
      collectedAt: "coldwire-collected-at",
      // How much this device is willing to give the cache, in bytes, or "none" for no
      // ceiling. Set only from the offline settings page; unset follows COLDWIRE.maxSize,
      // which is what the app configured.
      maxSize: "coldwire-max-size"
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
    },

    // The ceiling the next sweep works to, in bytes, or null for none. Same shape as the
    // switch above: a choice made on this device beats the app's default, and no choice yet
    // means the default. A stored value that is not a positive number is a storage somebody
    // has edited by hand, and "no ceiling" is not a safe reading of nonsense — fall back.
    maxSize: function () {
      var configured = window.COLDWIRE.maxSize
      var stored = this.get(this.keys.maxSize)
      if (stored === null) return configured === undefined ? null : configured
      if (stored === "none") return null

      var bytes = Number(stored)

      return Number.isFinite(bytes) && bytes > 0 ? bytes : configured || null
    },

    // The Offline support switch: an explicit choice beats the configured default, and no
    // choice yet means the default.
    cachingOn: function () {
      var stored = this.get(this.keys.caching)
      if (stored === null) return window.COLDWIRE.cachingEnabledByDefault !== false

      return stored === "1"
    }
  }
})();
