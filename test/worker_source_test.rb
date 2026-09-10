# frozen_string_literal: true

require "minitest/autorun"
require "coldwire/source"

# The worker is JavaScript, and nothing here runs it. These are the few facts about its text
# that are worth pinning: the ones where a plausible-looking edit changes what the cache does.
class WorkerSourceTest < Minitest::Test
  def worker
    @worker ||= Coldwire::Source.worker
  end

  def test_the_parts_are_concatenated_in_order
    rules = worker.index("function matchesRules")
    serve = worker.index("async function handleFetch")

    refute_nil rules
    refute_nil serve
    assert rules < serve, "rules must come before the code that calls them"
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

  # Only what is missing, or every navigation refetches every asset on the page.
  def test_a_subresource_already_held_is_not_fetched_again
    body = worker[/async function storeSubresource\(cache, href\) \{(.*?)\n\}/m, 1]

    refute_nil body
    assert_includes body, "if (await cache.match(href, MATCH_OPTIONS)) return"
    assert_includes body, "if (isNeverCached(new URL(href))) return"
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
    assert_includes body, "CACHE_ORIGINS.includes(url.origin)"
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
