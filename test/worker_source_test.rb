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

  # An empty `cacheable` means "store anything", and reading that as "answer anything from
  # cache" is how every stylesheet in a default app ends up behind a network round trip.
  def test_cache_first_does_not_borrow_the_storage_rules
    body = worker[/function isCacheFirst\(request\) \{(.*?)\n\}/m, 1]

    refute_nil body
    assert_includes body, "matchesRules(url, CACHE_FIRST)"
    refute_includes body, "CACHEABLE"
    refute_includes body, "length === 0"
  end

  # A nominated origin is opted into wholesale, and a CDN names its versions in the path.
  # Refetching those would mean a round trip per glyph and tile.
  def test_other_origins_are_answered_from_the_cache
    body = worker[/function isCacheFirst\(request\) \{(.*?)\n\}/m, 1]

    assert_includes body, "if (url.origin !== self.location.origin) return true"
  end

  def test_nominated_origins_still_bypass_the_path_lists
    body = worker[/function isAutoCacheable\(request\) \{(.*?)\n\}/m, 1]

    refute_nil body
    assert_includes body, "CACHE_ORIGINS.includes(url.origin)"
  end
end
