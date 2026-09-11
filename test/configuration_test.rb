# frozen_string_literal: true

require "minitest/autorun"
require "coldwire/configuration"

class ConfigurationTest < Minitest::Test
  def config
    @config ||= Coldwire::Configuration.new
  end

  def test_storing_is_wide_open_until_narrowed
    assert_equal [ "/*" ], config.cache_as_you_go
    assert_empty config.never_cache
  end

  def test_caching_enabled_by_default_starts_on
    assert config.caching_enabled_by_default

    config.caching_enabled_by_default = false

    refute config.caching_enabled_by_default
  end

  def test_patterns_are_checked_at_boot
    error = assert_raises(ArgumentError) { config.cache_as_you_go = [ /\A\/map/ ] }

    assert_match(/cache_as_you_go/, error.message)
  end

  def test_naming_a_list_replaces_it
    config.cache_as_you_go = [ "/sites", "/sites/:id" ]
    config.never_cache = [ "/users/:id/edit" ]

    assert_equal [ "/sites", "/sites/:id" ], config.cache_as_you_go
    assert_equal [ "/users/:id/edit" ], config.never_cache
  end

  # On by default, unlike syncing: a sweep costs no data, and the alternative is a cache that
  # grows on somebody's phone forever.
  def test_collection_is_on_by_default_with_a_timeframe
    assert config.garbage_collection.enabled
    assert_equal 60 * 24 * 60 * 60, config.garbage_collection.max_age
    assert_equal 24 * 60 * 60, config.garbage_collection.interval
  end

  # A ceiling as well as a deadline: a device that browses far more than it revisits never
  # trips the age rule, and its cache grows until the browser evicts the lot.
  def test_collection_has_a_ceiling_by_default
    assert_equal 250 * 1024 * 1024, config.garbage_collection.max_size
  end

  def test_a_max_size_of_nil_is_no_ceiling
    config.garbage_collection { |gc| gc.max_size = nil }

    assert_nil config.garbage_collection.max_size
  end

  # Bytes, and a figure that reads like megabytes is a unit mistake rather than a tiny cache.
  def test_a_max_size_under_a_megabyte_is_refused
    error = assert_raises(ArgumentError) { config.garbage_collection { |gc| gc.max_size = 250 } }

    assert_match(/max_size/, error.message)
  end

  # The settings page offers a ladder. Whatever the app configured has to be on it, or nobody
  # who picks another rung can get back to the app's own answer.
  def test_the_offered_sizes_include_the_configured_one
    config.garbage_collection { |gc| gc.max_size = 300 * 1024 * 1024 }
    choices = config.garbage_collection.size_choices

    assert_includes choices, 300 * 1024 * 1024
    assert_equal choices.sort, choices
    assert_equal choices.uniq, choices
  end

  def test_no_ceiling_still_offers_the_ladder
    config.garbage_collection { |gc| gc.max_size = nil }

    assert_includes config.garbage_collection.size_choices, 250 * 1024 * 1024
  end

  # Renewal has to be frequent enough that nothing in use drifts into collection range, and
  # rare enough that a navigation is not rewriting every asset the page names.
  def test_renewal_leaves_headroom_before_collection
    gc = config.garbage_collection

    assert_operator gc.renew_after, :<, gc.max_age
    assert_equal gc.max_age / 4, gc.renew_after
  end

  def test_nothing_is_renewed_or_collected_when_it_is_off
    config.garbage_collection { |gc| gc.enabled = false }

    assert_nil config.garbage_collection.renew_after
  end

  def test_a_max_age_of_nil_collects_nothing
    config.garbage_collection { |gc| gc.max_age = nil }

    assert_nil config.garbage_collection.renew_after
  end

  # A sweep must never take a manifest page before the sync that keeps it fresh comes round,
  # or the two settings quietly fight and the manifest is refetched over and over.
  def test_the_default_sweep_outlives_the_default_refetch
    assert_operator config.auto_sync.max_age, :<, config.garbage_collection.max_age
  end

  def test_domains_are_bare
    config.cache_domains = [ "tiles.example.com", "localhost:3001" ]

    assert_equal [ "tiles.example.com", "localhost:3001" ], config.cache_domains
  end

  # A scheme is what everybody will type, having pasted a URL. Dropped rather than refused:
  # a worker only runs on a secure page, and a secure page cannot fetch http, so there was
  # never a second scheme to tell apart.
  def test_a_scheme_is_dropped_rather_than_refused
    config.cache_domains = [ "https://tiles.example.com", "http://localhost:3001/" ]

    assert_equal [ "tiles.example.com", "localhost:3001" ], config.cache_domains
  end

  def test_domains_are_compared_as_written_so_case_does_not_matter
    config.cache_domains = [ "Tiles.Example.COM" ]

    assert_equal [ "tiles.example.com" ], config.cache_domains
  end

  # Anything with a path would never match: the worker compares a URL's host, which has none.
  def test_a_path_is_refused_rather_than_silently_ignored
    error = assert_raises(ArgumentError) { config.cache_domains = [ "tiles.example.com/maps" ] }

    assert_match(/bare domains/, error.message)
  end

  def test_nonsense_is_refused
    assert_raises(ArgumentError) { config.cache_domains = [ "not a domain" ] }
    assert_raises(ArgumentError) { config.cache_domains = [ "" ] }
  end
end
