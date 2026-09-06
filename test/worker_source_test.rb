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

  # The guard that decides whether a stored copy answers. Cached HTML must leave through
  # cachedPageResponse whichever branch it takes: returned as it is, it would still carry
  # data-turbo-track="reload", and offline that reload is answered from this same cache.
  def test_a_cached_copy_answers_only_where_the_address_is_digested
    guard = worker[/^\s*if \(cached &&.*$/]

    refute_nil guard, "handleFetch must still short-circuit to the cached copy"
    assert_includes guard, "isCacheFirst(request)"
    assert_includes guard, "cachedPageResponse(cache, request, cached)"
    refute_match(/return cached\s*$/, guard, "the raw cached response must not be returned")
  end

  # An empty list means "store anything", and reading that as "answer anything from cache" is
  # how every stylesheet in a default app ends up behind a network round trip.
  def test_cache_first_does_not_borrow_the_storage_rules
    body = worker[/function isCacheFirst\(request\) \{(.*?)\n\}/m, 1]

    refute_nil body
    assert_includes body, "matchesRules(url, CACHE_FIRST)"
    refute_includes body, "CACHE_AS_YOU_GO"
    refute_includes body, "length === 0"
  end

  # And the reverse: storing is not decided by freshness either. Subresources are what keep a
  # page's assets in the cache now, so the two questions stay separate.
  def test_storing_does_not_borrow_the_freshness_rules
    refute_includes worker[/function isAutoCacheable\(request\) \{(.*?)\n\}/m, 1], "CACHE_FIRST"
  end

  # A nominated origin is opted into wholesale, and a CDN names its versions in the path.
  # Refetching those would mean a round trip per glyph and tile.
  def test_other_origins_are_answered_from_the_cache
    body = worker[/function isCacheFirst\(request\) \{(.*?)\n\}/m, 1]

    assert_includes body, "if (url.origin !== self.location.origin) return true"
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
end
