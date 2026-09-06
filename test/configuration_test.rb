# frozen_string_literal: true

require "minitest/autorun"
require "coldwire/configuration"

class ConfigurationTest < Minitest::Test
  def config
    @config ||= Coldwire::Configuration.new
  end

  def test_nothing_is_revalidated_by_default
    assert_empty config.cache_revalidate
  end

  def test_patterns_are_checked_at_boot_like_the_other_lists
    error = assert_raises(ArgumentError) { config.cache_revalidate = [ /\A\/map/ ] }

    assert_match(/cache_revalidate/, error.message)
  end

  def test_paths_are_kept_as_given
    config.cache_revalidate = [ "/map/:kind" ]

    assert_equal [ "/map/:kind" ], config.cache_revalidate
  end
end
