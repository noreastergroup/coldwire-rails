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

  # A map is an archive plus the style that describes it and the sprite sheet it draws with.
  # All or nothing from somebody's point of view, so it is offered and counted as one thing.
  def test_an_archive_may_be_several_files
    config.cache_archives = [ {
      urls: [ "https://cdn.example.com/map.pmtiles",
              "https://cdn.example.com/style.json",
              "https://cdn.example.com/sprite.png" ],
      title: "Offline map"
    } ]
    archive = config.cache_archives.first

    assert_equal 3, archive[:urls].size
    assert_equal "Offline map", archive[:title]
  end

  # The first URL is what the download button, the progress messages and the Remove button are
  # all keyed on, so reordering the list renames the download.
  def test_the_first_url_is_the_archives_identity
    config.cache_archives = [ { urls: [ "https://cdn.example.com/map.pmtiles",
                                        "https://cdn.example.com/style.json" ] } ]

    assert_equal "https://cdn.example.com/map.pmtiles", config.cache_archives.first[:url]
  end

  def test_a_single_url_still_works_either_way_round
    config.cache_archives = [ { url: "https://cdn.example.com/map.pmtiles" },
                              "https://cdn.example.com/other.pmtiles" ]

    assert_equal [ "https://cdn.example.com/map.pmtiles" ], config.cache_archives.first[:urls]
    assert_equal [ "https://cdn.example.com/other.pmtiles" ], config.cache_archives.last[:urls]
  end

  # The flat list is what a sweep is forbidden to touch, so every file has to appear in it —
  # a companion left out is one a collection may take, leaving a download that cannot draw.
  def test_every_file_is_listed_for_sparing
    config.cache_archives = [ { urls: [ "https://cdn.example.com/map.pmtiles",
                                        "https://cdn.example.com/style.json" ] },
                              { url: "https://cdn.example.com/other.pmtiles" } ]

    assert_equal [ "https://cdn.example.com/map.pmtiles",
                   "https://cdn.example.com/style.json",
                   "https://cdn.example.com/other.pmtiles" ], config.cache_archive_urls
  end

  def test_every_url_has_to_be_absolute
    error = assert_raises(ArgumentError) do
      config.cache_archives = [ { urls: [ "https://cdn.example.com/map.pmtiles", "/style.json" ] } ]
    end

    assert_match(/absolute url/, error.message)
  end

  def test_an_archive_needs_at_least_one_url
    assert_raises(ArgumentError) { config.cache_archives = [ { title: "Nothing" } ] }
  end

  def test_the_title_falls_back_to_the_first_files_name
    config.cache_archives = [ { urls: [ "https://cdn.example.com/map.pmtiles",
                                        "https://cdn.example.com/style.json" ] } ]

    assert_equal "map.pmtiles", config.cache_archives.first[:title]
  end
end
