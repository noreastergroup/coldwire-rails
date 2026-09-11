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
    assert_includes body, "cache.match(request, MATCH_OPTIONS)"
    assert_includes body, "cachedPageResponse(cache, request, cached)"
    assert_includes body, "offlineResponse(request)"
  end

  # The whole point of the list being about pages: browsing to one stores what it needs to
  # render, whether or not those files match anything the app listed. Without this a page is
  # stored on its own, and the first rebuild leaves it asking for a stylesheet nobody kept.
  def test_a_stored_page_brings_what_it_asks_for
    body = worker[/async function storeResponse\(cache, request, response\) \{(.*?)\n\}/m, 1]

    refute_nil body
    assert_includes body, "putFresh(cache, cacheKey(request), response.clone())"
    assert_includes body, "urlsFromHtml(await response.text(), request.url)"
    assert_includes body, "storeSubresource"
    assert_includes body, 'if (!type.includes("text/html")) return'
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
