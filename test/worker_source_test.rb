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

  # The guard that decides cache-first. Everything with an address that changes with its
  # contents belongs on the cached side of it, which is nearly everything: an asset's digest
  # means a cached copy is already the current one.
  def test_a_cached_copy_answers_unless_the_app_asked_otherwise
    guard = worker[/^\s*if \(cached &&.*$/]

    refute_nil guard, "handleFetch must still short-circuit to the cached copy"
    assert_includes guard, "!wantsHtml("
    assert_includes guard, "!mustRevalidate("
  end

  # The whole point of the opt-in: an app that names nothing must behave exactly as before,
  # or every asset it holds becomes a network round trip and a bad response loses the page
  # its stylesheet.
  def test_revalidation_is_off_until_asked_for
    body = worker[/function mustRevalidate\(request\) \{(.*?)\n\}/m, 1]

    refute_nil body
    assert_includes body, "if (CACHE_REVALIDATE.length === 0) return false"
    assert_includes body, "url.origin !== self.location.origin"
  end

  # An empty allowlist means "store anything", which must never be read as "revalidate
  # everything" — that is the same mistake wearing a different hat.
  def test_revalidation_does_not_borrow_the_allowlists_empty_means_all_rule
    body = worker[/function mustRevalidate\(request\) \{(.*?)\n\}/m, 1]

    refute_includes body, "CACHE_ALLOWLIST"
    refute_includes body, "length === 0) return true"
  end

  def test_nominated_origins_still_bypass_the_path_lists
    body = worker[/function isAutoCacheable\(request\) \{(.*?)\n\}/m, 1]

    refute_nil body
    assert_includes body, "CACHE_ORIGINS.includes(url.origin)"
  end
end
