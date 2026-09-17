# frozen_string_literal: true

# The precache manifest is a list of URLs, and a URL is one field short of naming a body: the
# same path answers a visit, a frame and a `respond_to` format with three different things.
# A listing can say which of them it means, and this is where that is normalized for the worker.

require "minitest/autorun"
# Mime, and nothing else: requiring the whole gem would register the engine, and a later test
# booting a Rails application would then run its initializers against an app that never mounted
# it.
require "action_dispatch/http/mime_type"
require "coldwire/precache"

class PrecacheEntriesTest < Minitest::Test
  def entries(list)
    Coldwire.precache_entries(list)
  end

  # What every manifest looked like before this existed, and what most still look like.
  def test_a_bare_url_is_a_page
    assert_equal [ { url: "/sites/1" } ], entries([ "/sites/1" ])
  end

  def test_a_single_entry_does_not_have_to_be_wrapped
    assert_equal [ { url: "/sites/1" } ], entries("/sites/1")
    assert_equal [ { url: "/sites/1", frame: "map" } ], entries({ url: "/sites/1", frame: "map" })
  end

  # The frame is the id Turbo puts in the header, which is the frame tag's own id.
  def test_a_listing_can_name_a_frame
    assert_equal [ { url: "/features/12", frame: "map_feature_popup" } ],
                 entries([ { url: "/features/12", frame: "map_feature_popup" } ])
  end

  # A format becomes the Accept header the worker asks with. Rails already knows what every
  # registered format means, so the worker never has to.
  def test_a_format_becomes_an_accept_header
    assert_equal [ { url: "/reports/1", accept: "application/json" } ],
                 entries([ { url: "/reports/1", format: :json } ])
    assert_equal [ { url: "/reports/1", accept: "text/csv" } ],
                 entries([ { url: "/reports/1", format: "csv" } ])
  end

  # Including one the app registered itself, which is how `format: :turbo_stream` works at all.
  def test_a_format_the_app_registered_works_too
    Mime::Type.register "application/geo+json", :geojson unless Mime[:geojson]

    assert_equal [ { url: "/map", accept: "application/geo+json" } ],
                 entries([ { url: "/map", format: :geojson } ])
  end

  # A typo here would otherwise be fetched as HTML and cached as the page, which is the exact
  # confusion the format is there to prevent.
  def test_an_unregistered_format_is_refused
    error = assert_raises(ArgumentError) { entries([ { url: "/x", format: :nonsense } ]) }

    assert_match(/not a registered Mime type/, error.message)
  end

  # The way out for a media type with no registered name.
  def test_accept_can_be_given_outright
    assert_equal [ { url: "/x", accept: "application/vnd.api+json" } ],
                 entries([ { url: "/x", accept: "application/vnd.api+json" } ])
  end

  def test_a_frame_and_a_format_together
    listing = { url: "/features/12", frame: "map_feature_popup", format: :json }

    assert_equal [ { url: "/features/12", frame: "map_feature_popup", accept: "application/json" } ],
                 entries([ listing ])
  end

  def test_string_keys_work_the_same
    assert_equal [ { url: "/x", frame: "f" } ], entries([ { "url" => "/x", "frame" => "f" } ])
  end

  def test_an_entry_without_a_url_is_refused
    error = assert_raises(ArgumentError) { entries([ { frame: "map" } ]) }

    assert_match(/need a url/, error.message)
  end

  # Listing one URL more than once is how you ask for both the page and the frame, so nothing
  # here collapses them.
  def test_the_same_url_can_be_listed_more_than_once
    listed = entries([ "/features/12", { url: "/features/12", frame: "map_feature_popup" } ])

    assert_equal 2, listed.length
    assert_equal [ nil, "map_feature_popup" ], listed.map { |entry| entry[:frame] }
  end
end
