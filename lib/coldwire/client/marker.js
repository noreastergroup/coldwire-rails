(function () {
  // Anything watching Coldwire.onChange hears about it here, after the attributes are
  // in step with the page that was just rendered.
  function announce() {
    document.dispatchEvent(new CustomEvent("coldwire:change", {
      detail: {
        offline: window.Coldwire ? window.Coldwire.isOffline() : false,
        forced: window.Coldwire ? window.Coldwire.isForcedOffline() : false,
        cachedAt: window.Coldwire ? window.Coldwire.cachedAt() : null
      }
    }))
  }

  function sync() {
    var meta = document.querySelector('meta[name="coldwire-offline"]')
    var root = document.documentElement
    if (meta) {
      root.setAttribute("data-coldwire-offline", "")
      var at = meta.getAttribute("content")
      if (at) {
        root.setAttribute("data-coldwire-cached-at", at)
      } else {
        root.removeAttribute("data-coldwire-cached-at")
      }
    } else {
      root.removeAttribute("data-coldwire-offline")
      root.removeAttribute("data-coldwire-cached-at")
    }

    announce()
  }

  document.addEventListener("turbo:load", sync)
  announce()
})();
