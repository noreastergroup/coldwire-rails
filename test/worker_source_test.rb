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
    first = worker.index("function matchesRules")
    later = worker.index("async function handleFetch")

    refute_nil first
    refute_nil later
    assert first < later, "rules must come before the code that calls them"
  end

  # Freshness follows the allowlist, not the content type. An allowlisted path keeps its
  # address while its contents change — a page, and equally a URL serving JSON — so a cached
  # copy is only as good as its age and has to be refetched while there is a network. An
  # asset's address changes with its contents, so a cached one is already the current one.
  def test_the_apps_own_surfaces_are_not_served_from_cache_while_there_is_a_network
    guard = worker[/^\s*if \(cached &&.*$/]

    refute_nil guard, "handleFetch must still short-circuit to the cached copy for something"
    assert_includes guard, "!isOwnSurface(", "an allowlisted URL must not be answered cache-first"
    assert_includes guard, "!wantsHtml(", "HTML must not be answered cache-first either"
  end

  def test_own_surfaces_are_same_origin_only
    body = worker[/function isOwnSurface\(url\) \{(.*?)\n\}/m, 1]

    refute_nil body
    assert_includes body, "url.origin !== self.location.origin"
    assert_includes body, "CACHE_BLOCKLIST"
    assert_includes body, "CACHE_ALLOWLIST"
  end

  # A nominated origin opts in wholesale, and must not be dragged through the path lists.
  def test_nominated_origins_still_bypass_the_path_lists
    body = worker[/function isAutoCacheable\(request\) \{(.*?)\n\}/m, 1]

    refute_nil body
    assert_includes body, "CACHE_ORIGINS.includes(url.origin)"
  end
end
