# frozen_string_literal: true

require "minitest/autorun"
require "coldwire/source"

# The worker is JavaScript, and nothing here runs it. These are the few facts about its text
# that are worth pinning: the ones where a plausible-looking edit changes what the cache does.
class WorkerSourceTest < Minitest::Test
  def worker
    @worker ||= Coldwire::Source.worker
  end

  def collection
    @collection ||= worker[/async function runCollection\(maxSize\) \{(.*?)\n\}/m, 1]
  end

  def test_the_parts_are_concatenated_in_order
    rules = worker.index("function matchesRules")
    serve = worker.index("async function handleFetch")

    refute_nil rules
    refute_nil serve
    assert rules < serve, "rules must come before the code that calls them"
  end

  def test_a_disabled_worker_stands_aside
    body = worker[/function shouldHandle\(request\) \{(.*?)\n\}/m, 1]

    refute_nil body
    assert_includes body, "if (!cachingEnabled) return false"
  end

  # Nothing is answered from the cache while the network is answering, so the cache is not
  # even looked in until a fetch has failed. A lookup on the working path would be pure cost,
  # and the browser already holds what it holds.
  def test_the_cache_is_only_consulted_once_the_network_has_failed
    body = worker[/async function handleFetch\(request, event\) \{(.*?)\n\}/m, 1]

    refute_nil body
    assert_includes body, "if (forcedOffline) return offlineFallback(cache, request)"
    assert_includes body, "return offlineFallback(cache, request)"
    refute_includes body, "cache.match", "the working path must not look in the cache"
  end

  # Cached HTML leaves through cachedPageResponse, or it still carries data-turbo-track and
  # offline that reload is answered from this same cache.
  def test_a_cached_page_is_untracked_on_the_way_out
    body = worker[/async function offlineFallback\(cache, request\) \{(.*?)\n\}/m, 1]

    refute_nil body
    assert_includes body, "matchStored(cache, request)"
    assert_includes body, "cachedPageResponse(request, key, cached)"
    assert_includes body, "offlineResponse(request)"
  end

  # The whole point of the list being about pages: browsing to one stores what it needs to
  # render, whether or not those files match anything the app listed. Without this a page is
  # stored on its own, and the first rebuild leaves it asking for a stylesheet nobody kept.
  def test_a_stored_page_brings_what_it_asks_for
    body = worker[/async function storeResponse\(cache, request, response\) \{(.*?)\n\}/m, 1]

    refute_nil body
    assert_includes body, "bodyKey(cache, request, response)"
    assert_includes body, "urlsFromHtml(body, request.url)"
    assert_includes body, "storeSubresource"
    assert_includes body, 'if (!type.includes("text/html")) {'
  end

  # In waitUntil, not left running: a worker can be stopped as soon as it has answered.
  def test_storing_outlives_the_response
    guard = worker[/^\s*const stored = storeResponse.*\n\s*if \(event\).*$/]

    refute_nil guard
    assert_includes guard, "event.waitUntil(stored)"
  end

  # Only what is missing is fetched, or every navigation refetches every asset on the page.
  # What is held is renewed instead, which is what keeps the collector off an asset the whole
  # app is using but nothing ever refetches.
  def test_a_subresource_already_held_is_renewed_rather_than_refetched
    body = worker[/async function storeSubresource\(cache, href\) \{(.*?)\n\}/m, 1]

    refute_nil body
    assert_includes body, "await cache.keys(href, MATCH_OPTIONS)"
    assert_includes body, "if (key) return renew(cache, key)"
    assert_includes body, "if (isNeverCached(new URL(href))) return"
    refute_includes body, "fetch(", "a held subresource must not go back to the network"
  end

  # Renewal rewrites from the cache, and only past RENEW_AFTER: doing it on every navigation
  # would rewrite every asset every page names, which is the cost this exists to avoid.
  def test_renewal_costs_a_lookup_until_the_entry_is_actually_old
    body = worker[/async function renew\(cache, key\) \{(.*?)\n\}/m, 1]

    refute_nil body
    assert_includes body, "if (RENEW_AFTER === null) return"
    assert_includes body, "< RENEW_AFTER) return"
    assert_includes body, "cache.match(key)"
    refute_includes body, "fetch(", "renewal must not refetch"
    assert_includes body, "MANAGED_HEADER", "a renewed manifest entry must stay a manifest entry"
  end

  # Turbo sends `Turbo-Frame` on a frame navigation and an app may answer it with just the
  # frame. Keyed on the URL alone, that body lands in the slot the page occupies, and a later
  # cold visit is served a fragment as a document: no <html>, a blank screen, and in Hotwire
  # Native a page where window.Turbo never appears. Vary is not available to us — matching is
  # URL-only by design, so precached `*/*` responses match real `text/html` visits — so the
  # frame goes in the key.
  def test_a_frame_body_is_keyed_apart_from_its_page
    body = worker[/\nfunction cacheKey\(request,(.*?)\n\}/m, 1]

    refute_nil body
    assert_includes body, "variantUrl(request.url, { frame, format })"
    # The early return keeps an untouched URL untouched, which naming a frame cannot do.
    assert_includes body, "if (!IGNORE_SEARCH && !named) return new Request(request, { headers })"

    # One place builds that URL, because the other half of the job is looking for it again.
    built = worker[/\nfunction variantUrl\(url,(.*?)\n\}/m, 1]
    refute_nil built
    assert_includes built, "target.searchParams.set(FRAME_PARAM, frame)"
  end

  # What the response turned out to be, not what the request asked for. An app that ignores the
  # header and returns the whole document would otherwise store those bytes twice, and leave
  # the next ordinary visit unable to find them.
  def test_a_frame_request_answered_with_a_document_is_stored_as_the_page
    body = worker[/async function storeResponse\(cache, request, response\) \{(.*?)\n\}/m, 1]

    refute_nil body
    assert_includes body, 'const frame = /<html\b/i.test(body) ? null : request.headers.get("Turbo-Frame")'
    assert_includes body, "putFresh(cache, cacheKey(request, { frame }), response.clone())"
    assert body.index("response.clone().text()") < body.index("cacheKey(request, { frame })"),
           "what it is has to be known before there is anywhere to put it"
  end

  # A frame takes a page when it has no entry of its own, because Turbo pulls the frame out of
  # a document exactly as it does online. A document never takes a frame.
  def test_matching_asks_for_the_kind_of_body_the_request_wants
    body = worker[/async function matchStored\(cache, request\) \{(.*?)\n\}/m, 1]

    refute_nil body
    assert_includes body, 'const frame = request.headers.get("Turbo-Frame")'
    assert_includes body, "cache.keys(variantUrl(request.url, { frame }), { ignoreVary: true })"
    assert_includes body, 'keys.find((candidate) => variantOf(candidate) === "page")'
    assert_includes body, "cache.keys(variantUrl(request.url, { format }), { ignoreVary: true })"

    variant = worker[/function variantOf\(key\) \{(.*?)\n\}/m, 1]
    refute_nil variant
    assert_includes variant, "CHUNK_PARAM", "ignoreSearch would otherwise let a chunk answer a page"
    assert_includes variant, "if (frame) return `frame:${frame}`"
    assert_includes variant, 'params.get(FORMAT_PARAM) || "page"'
  end

  # One URL, three bodies: the page a visit gets, the frame a frame navigation gets, and the
  # JSON a fetch gets. The Rails side of this is pinned in variant_responses_test.rb; this is
  # the half that has to keep them apart.
  def test_a_format_is_keyed_apart_from_the_page
    body = worker[/\nfunction variantUrl\(url,(.*?)\n\}/m, 1]

    refute_nil body
    assert_includes body, "target.searchParams.set(FORMAT_PARAM, format)"
    # The page is the default and writes nothing, which is what leaves every entry stored
    # before formats existed exactly where it was, assets included.
    assert_includes body, 'if (format && format !== "page")'
  end

  # Read off the request, not the response, and not by choice: the same derivation has to run
  # when the entry is looked for again, and there is no response to read at that moment. A name
  # the request cannot produce is a name nothing ever finds.
  def test_a_format_is_read_off_the_request
    body = worker[/\nfunction negotiatedFormat\(request\)(.*?)\n\}/m, 1]

    refute_nil body
    assert_includes body, 'request.headers.get("Accept")'
    # Nothing definite asked for keeps the key it has always had.
    assert_includes body, 'if (!accept || accept === "*/*" || accept.includes("html")) return "page"'
    # image/avif and image/webp are one question asked two ways.
    assert_includes body, 'if (top && top !== "text" && top !== "application") return top'
    # "application/vnd.api+json" is JSON.
    assert_includes body, "parts.length > 1 ? parts[parts.length - 1] : parts[0]"
  end

  # A path that names its own format needs no param saying it again: "/report.json" is JSON and
  # nothing else. "/report" is a page, a JSON body and a CSV depending on who asks, and that is
  # the one that needs telling apart.
  def test_a_path_that_names_its_format_keeps_a_clean_key
    body = worker[/\nfunction formatOf\(request\)(.*?)\n\}/m, 1]

    refute_nil body
    assert_includes body, 'return extensionFormat(request.url) === token ? "page" : token'

    # Only where the extension agrees with what was asked for: "/sites/acme.com" is a page whose
    # last segment merely contains a dot, and it still needs its param.
    lookup = worker[/function extensionFormat\(url\) \{(.*?)\n\}/m, 1]
    refute_nil lookup
    assert_includes lookup, "EXTENSION_FORMATS[name.slice(dot + 1).toLowerCase()]"
    assert_includes lookup, 'if (dot < 1) return "page"'
    # An unknown extension says nothing and keeps its param, which is never wrong.
    assert_includes worker, '|| "page"'
  end

  # One entry per file. A precache carries no Accept and lands unnamed; the browser then asks
  # for the same stylesheet by type. Left alone, that is two of every stylesheet and image.
  def test_one_body_per_url_whichever_asked_first
    body = worker[/async function bodyKey\(cache, request, response\) \{(.*?)\n\}/m, 1]

    refute_nil body
    assert_includes body, "cache.keys(variantUrl(request.url, {}), { ignoreVary: true })"
    assert_includes body, "formatFromType(response)"
    assert_includes body, "cache.keys(variantUrl(request.url, { format: guess })"
  end

  # A fetch asking for data gets data or nothing. Handing it the page is the mistake that gives
  # a stylesheet an HTML body, so the unnamed entry is only taken once it says what it holds.
  def test_a_data_request_is_never_handed_a_page
    body = worker[/async function matchStored\(cache, request\) \{(.*?)\n\}/m, 1]

    refute_nil body
    assert_includes body, 'if (format === "page") return page'
    assert_includes body, 'held.headers.get("Content-Type") || "").includes("text/html")'
  end

  # A stream is a list of changes to make to a page, not a page. Stored, it would take the
  # page's slot and be replayed later against a DOM it was never written for.
  def test_a_turbo_stream_is_never_stored
    body = worker[/function isCacheable\(request, response\) \{(.*?)\n\}/m, 1]

    refute_nil body
    assert_includes body, "STREAM_TYPE"
  end

  # Renewal rebuilds the key from the URL, and a frame entry that lost its param on the way
  # would land on its own page's key: the collision this exists to prevent, caused by the
  # thing meant to preserve it.
  def test_renewing_a_frame_entry_puts_it_back_where_it_was
    body = worker[/async function renew\(cache, key\) \{(.*?)\n\}/m, 1]

    refute_nil body
    assert_includes body, "params.get(FRAME_PARAM)"
    assert_includes body, "{ managed, frame, format }"
  end

  # Deleting is the one operation with no way back, so a sweep proves the connection first —
  # for the size pass as much as the age pass, which is why trimming is reached from inside
  # runCollection rather than from the message handler.
  def test_a_sweep_will_not_run_without_a_connection
    body = collection

    refute_nil body
    assert_includes body, "if (forcedOffline) return"
    assert_includes body, "if (!(await reachable())) return"
    assert body.index("reachable()") < body.index("cache.delete"),
           "the connection has to be proven before anything is deleted"
    assert body.index("reachable()") < body.index("trimToSize"),
           "the connection has to be proven before the ceiling is applied"
  end

  def test_the_probe_is_a_real_request
    body = worker[/async function reachable\(\) \{(.*?)\n\}/m, 1]

    refute_nil body
    assert_includes body, "PROBE_PATH"
    assert_includes body, 'cache: "no-store"'
  end

  # An entry with no stamp is from an older worker. Age unknown is not age exceeded.
  def test_an_unstamped_entry_is_kept
    assert_includes collection, "at === null || now - at <= COLLECT_MAX_AGE"
  end

  # The ceiling is the device's, not the build's: it lives in localStorage, which a worker
  # cannot read, so it arrives with the request. A page that says nothing about it — an older
  # client — must get the app's default rather than no ceiling at all.
  def test_the_ceiling_comes_from_the_page_and_falls_back_to_the_configured_one
    body = worker[/function collectGarbage\(\{ maxSize \} = \{\}\) \{(.*?)\n\}/m, 1]

    refute_nil body
    assert_includes body, "maxSize === undefined ? COLLECT_MAX_SIZE : maxSize"
    assert_includes body, "runCollection(limit)"
  end

  # Choosing a ceiling is a deliberate instruction about somebody's own storage, the same kind
  # Clear cache is, and that has never waited for a network to agree. Standing down here left
  # the setting looking like it did nothing.
  def test_applying_a_chosen_ceiling_does_not_wait_for_a_connection
    body = worker[/async function runTrim\(maxSize\) \{(.*?)\n\}/m, 1]

    refute_nil body
    refute_includes body, "reachable()", "an explicit ceiling must not wait on the probe"
    refute_includes body, "forcedOffline", "force offline is not a reason to refuse it"
    assert_includes body, "trimToSize(cache, await collectable(cache), maxSize)"
    # What it may take comes from one place, so an explicit trim spares what a sweep spares.
    assert_includes worker[/async function collectable\(cache\) \{(.*?)\n\}/m, 1],
                    "filter((key) => !isSpared(key, spared))"
  end

  # The age pass keeps its probe: nothing asked for it, so the cost of getting it wrong falls
  # on somebody who never requested it.
  def test_the_automatic_sweep_still_proves_the_connection
    assert_includes collection, "if (!(await reachable())) return"
  end

  # A sweep in flight is working to the ceiling this call replaces, so joining it would answer
  # the old question — which is exactly what made a changed setting look inert.
  def test_an_explicit_ceiling_queues_behind_a_sweep_rather_than_joining_it
    body = worker[/function applyCeiling\(maxSize\) \{(.*?)\n\}/m, 1]

    refute_nil body
    assert_includes body, "collecting ? collecting.catch"
    assert_includes body, "queued.then(() => runTrim(maxSize))"
    refute_includes body, "return collecting", "it must not hand back the run already going"
  end

  # Number(null) is 0, and 0 is finite and not negative, so a missing Content-Length used to
  # sail through the guard and report the entry as weighing nothing. Rails sends much of its
  # HTML chunked, with no Content-Length at all, so that was most pages: the collector measured
  # a cache of hundreds of megabytes at zero, never reached its ceiling, deleted nothing, and
  # reported success every time.
  def test_an_entry_with_no_content_length_is_weighed_not_assumed_empty
    body = worker[/async function entrySize\(response\) \{(.*?)\n\}/m, 1]

    refute_nil body
    refute_includes body, "Number(response.headers.get",
                    "Number(null) is 0, which reports a chunked response as empty"
    assert_includes body, "declared === null ? NaN : Number(declared)"
    assert_includes body, "blob()).size", "an undeclared body has to be read to be measured"
  end

  # Only what the age pass left, because an entry it already deleted cannot be evicted again —
  # and only after the measurement, since a cache under its ceiling must cost no deletions.
  def test_the_oldest_go_first_and_only_while_the_cache_is_over
    body = worker[/async function trimToSize\(cache, entries, maxSize\) \{(.*?)\n\}/m, 1]

    refute_nil body
    assert_includes body, "if (maxSize === null || entries.length === 0) return"
    assert_includes body, "if (total <= maxSize) return { evicted: 0, bytes: total }"
    assert_includes body, "sized.sort((a, b) => (a.at || 0) - (b.at || 0))"
    assert_includes body, "if (total <= maxSize) break"
    refute_includes body, "fetch(", "the ceiling only ever deletes"
  end

  # An age of nil with a ceiling set still has work to do, and the survivors of the age pass
  # are exactly what the ceiling may take from.
  def test_a_ceiling_alone_still_sweeps
    assert_includes collection, "if (COLLECT_MAX_AGE === null && maxSize === null) return"
    assert_includes collection, "survivors.push({ key, at })"
    assert_includes collection, "trimToSize(cache, survivors, maxSize)"
  end

  # Two things no amount of disuse makes safe to take: what the offline page needs, which
  # browsing never touches, and archives somebody spent a data plan downloading.
  def test_the_offline_page_and_downloaded_archives_are_spared
    body = worker[/function isSpared\(key, spared\) \{(.*?)\n\}/m, 1]

    refute_nil body
    assert_includes body, "CHUNK_PARAM"
    assert_includes body, "RANGE_PARAM"
    assert_includes body, "spared.has(url.href)"
    assert_includes worker[/function offlinePageAssets\(\) \{(.*?)\n\}/m, 1], "OFFLINE_PAGE"
  end

  # One veto, and it has to hold on every route in — browsing, a page that references it, and
  # the manifest — or "never" is not what the name says.
  def test_never_cache_stops_every_route_in
    assert_includes worker[/function isAutoCacheable\(request\) \{(.*?)\n\}/m, 1], "if (isNeverCached(url)) return false"
    assert_includes worker[/async function storeSubresource\(cache, href\) \{(.*?)\n\}/m, 1], "isNeverCached"
    assert_includes worker[/async function fetchAndCache\(cache, href.*?\n\}/m], "isNeverCached"
  end

  def test_nominated_origins_still_bypass_the_path_lists
    body = worker[/function isAutoCacheable\(request\) \{(.*?)\n\}/m, 1]

    refute_nil body
    assert_includes body, "CACHEABLE_HOSTS.includes(url.host)"
  end

  # An empty list used to mean "store everything". That made [] and ["/*"] the same, and
  # left no way to turn browsing-cache off. The list is now the list: empty stores nothing
  # by browsing, "/*" is the catch-all default.
  def test_browsing_stores_only_what_the_list_names
    body = worker[/function isAutoCacheable\(request\) \{(.*?)\n\}/m, 1]

    refute_nil body
    refute_includes body, "CACHE_AS_YOU_GO.length === 0"
    assert_includes body, "return matchesRules(url, CACHE_AS_YOU_GO)"
  end

  def test_a_lone_star_matches_every_path_including_root
    body = worker[/function matchesPattern\(path, pattern\) \{(.*?)\n\}/m, 1]

    refute_nil body
    assert_includes body, "index === 0 && pattern.length === 1"
  end
end
