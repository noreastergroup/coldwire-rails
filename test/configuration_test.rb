# frozen_string_literal: true

require "minitest/autorun"
require "coldwire/configuration"

class ConfigurationTest < Minitest::Test
  def config
    @config ||= Coldwire::Configuration.new
  end

  def test_storing_is_wide_open_until_narrowed
    assert_empty config.cache_as_you_go
    assert_empty config.never_cache
  end

  # Where Rails puts digested files. An app that says nothing still gets its assets answered
  # from the cache rather than refetched on every page.
  def test_digested_paths_are_cache_first_by_default
    assert_includes config.cache_first, "/assets/*"
    assert_includes config.cache_first, "/rails/active_storage/*"
  end

  def test_patterns_are_checked_at_boot_like_the_other_lists
    error = assert_raises(ArgumentError) { config.cache_first = [ /\A\/map/ ] }

    assert_match(/cache_first/, error.message)
  end

  def test_the_defaults_are_patterns_the_worker_will_accept
    config.cache_first = Coldwire::Configuration.new.cache_first

    assert_equal [ "/assets/*", "/packs/*", "/vite/*", "/rails/active_storage/*" ], config.cache_first
  end

  def test_naming_a_list_replaces_it
    config.cache_as_you_go = [ "/sites", "/sites/:id" ]
    config.never_cache = [ "/users/:id/edit" ]

    assert_equal [ "/sites", "/sites/:id" ], config.cache_as_you_go
    assert_equal [ "/users/:id/edit" ], config.never_cache
  end
end
