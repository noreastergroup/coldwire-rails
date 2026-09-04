(function () {
  try {
    var name = COLDWIRE.userAgentCookie
    var value = encodeURIComponent(navigator.userAgent)
    // Rewritten only when it has changed — an app update, or a first run.
    if (document.cookie.indexOf(name + "=" + value) !== -1) return

    document.cookie = name + "=" + value + "; path=/; max-age=31536000; samesite=lax"
  } catch (error) {
    // Cookies refused. The worker's requests will look like a browser's, which is
    // where this started.
  }
})();
