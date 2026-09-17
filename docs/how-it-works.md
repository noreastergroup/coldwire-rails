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

   **And a frame is not the page it came from.** Turbo sends that header on every frame
   navigation, and an app answering it with `turbo_frame_request?` returns just the frame.
   Keyed on the URL alone, that body lands in the slot the page occupies: a later cold visit
   is then served a fragment as a whole document, which is a blank screen, and in Hotwire
   Native a page where `window.Turbo` never appears. Whichever was cached last wins, so it
   also happens in reverse. `Vary` cannot fix this, because matching is URL-only by design
   (see 1), so Coldwire puts the frame in the key instead. A frame takes its own entry first
   and the page second, since Turbo pulls a frame out of a document exactly as it does
   online. An ordinary visit never takes the reverse trade.

   **And neither is any other format.** The same URL answers a `respond_to` block in as many
   formats as the app defines: `/report` is a page to Turbo, JSON to a `fetch`, a CSV to an
   export link and an RSS feed to a reader. Coldwire names the format in the key too, with the
   page left unnamed so anything cached before this keeps the key it had. The name is worked
   out from the request's `Accept`, not the response's type, because the same name has to be
   produced again when the entry is looked for, and there is no response to read then. A
   request asking for data gets data or nothing, since handing it a page is the mistake in 6
   wearing a different hat. A path that names its own format is left alone: `/report.json` is
   JSON and nothing else, so only `/report` needs telling apart. A Turbo Stream is never stored at all: it is a list of changes to
   make to a page, and replaying a stale one applies yesterday's mutations to today's DOM.
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
