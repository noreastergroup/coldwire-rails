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
      syncOff: "coldwire-sync-off"
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
    }
  }
})();
