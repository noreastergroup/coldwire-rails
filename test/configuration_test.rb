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
    assert_equal 30 * 24 * 60 * 60, config.garbage_collection.max_age
    assert_equal 24 * 60 * 60, config.garbage_collection.interval
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
end
