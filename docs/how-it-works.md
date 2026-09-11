# How it works

Six things break a naive offline cache in a Hotwire app. Four bite you in any browser; two
are Hotwire Native holding you to a stricter standard. Coldwire handles all six, which is
what lets one cache serve a plain Hotwire web app, a PWA, and Hotwire Native.

When a visit has no cached copy and no network, people see this — a `200` that boots
Turbo — rather than a native error screen:

<p align="center">
  <img src="images/offline-fallback.png" alt="The offline fallback: You're offline. This page isn't available offline. Reconnect and try again." width="280">
</p>

1. **`Vary: Accept` silently defeats precaching.** Rails answers HTML with `Vary: Accept`
   and `cache.match()` honors it. Precaching fetches with `Accept: */*`; Turbo asks for
   `text/html`. So a precached page only ever matches *another precache*, never a real
   visit — and it looks like it works, because caching pages as you visit them still does.
   Coldwire matches with `{ ignoreVary: true }`.
2. **A non-2xx offline page is never shown.** *(Native.)* Its adapter posts
   `visitRequestFailed` with a location, an identifier and a status — the response body
   never crosses into Swift, so no iOS override can render a `503`. Coldwire's fallback is
   a `200`.
3. **Turbo Frames need a frame.** A frame request discards any response without a matching
   `<turbo-frame>`, leaving the frame loading forever. Coldwire reads the `Turbo-Frame`
   header and answers with one.
4. **A followed redirect poisons the cache.** A signed-out request to `/` gets a `302` that
   `fetch` follows; the result looks fine and `cache.put()` stores it without complaint.
   Now `/` holds the sign-in page and keeps `redirected: true` — and serving a redirected
   response for a navigation is a network error by spec, so the app fails to cold launch
   offline. Coldwire refuses to store one.
5. **The offline page itself must boot Turbo.** *(Native.)* Its adapter waits for
   `window.Turbo` and reports *"The page could not be loaded because Turbo is not present"*
   if it never appears. Plain-HTML offline pages are not renderable in the app at all.
6. **Assets must not receive HTML.** A stylesheet handed an HTML offline page is just a
   broken asset. Coldwire serves the fallback only to requests that want HTML, and
   everything else an empty `504`.

The Cache API also ignores HTTP freshness headers entirely, and WebKit drops `Date` from
`match()`. So Coldwire stamps unix seconds onto the *request key* it stores under —
`keys()` hands it back, and URL matching still finds the entry. That is what the cached
list's "2 hours ago" reads.

While the network answers, every request goes to it. Coldwire's job starts when the
network stops: then the stored copy answers, or the offline page does.

## What the cache looks like to your server

A request carries the user agent of whoever makes it, and a service worker is not the
page. On Android that is the difference between the app and a browser: Hotwire Native sets
the agent on the web view, and `android.webkit.ServiceWorkerWebSettings` has no such
setting, so nothing the app configures reaches a worker's fetches. They cannot set one
either: Chromium drops a `User-Agent` given to `fetch`. WebKit has no such split, which is
why only Android is affected.

Left alone, an Android app's cache fills with pages rendered for a browser: navigation
chrome the app hides, and none of the markup that depends on knowing it is the app.

A cookie is the one thing the browser attaches by itself to every same-origin request,
whoever makes it. So each page writes its own user agent into `coldwire-user-agent`, and a
middleware reads it back before anything else in the stack runs. `hotwire_native_app?`,
your layout and `register_if` then see the client the request actually came from.

Nothing to configure. The user agent was always the client's to state, and a cookie is as
much the client's as the header is.
