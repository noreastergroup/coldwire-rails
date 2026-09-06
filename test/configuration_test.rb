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
end
