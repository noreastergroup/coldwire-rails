# frozen_string_literal: true

# One endpoint, three answers: a page, a JSON body, and a Turbo Frame. This is the shape the
# worker has to keep apart, and the shape a URL-keyed cache cannot.
#
# It is a Rails test on purpose. What the server actually sends — the `Vary` on each response,
# the `Accept` each client sends — is the input to that decision, and guessing at it is how you
# end up with a cache that matches in theory. Nothing here touches the Cache API; this pins the
# contract the worker is written against.

require "minitest/autorun"
require "tmpdir"
require "rails"
require "action_controller/railtie"

# What turbo-rails registers on load. Written out rather than depended on, so the test needs
# only Rails to describe the formats a Hotwire app answers in.
Mime::Type.register "text/vnd.turbo-stream.html", :turbo_stream unless Mime[:turbo_stream]

module VariantResponses
  # Rooted in an empty directory: pointed at the gem it would load Coldwire's own routes file,
  # which is a different test entirely.
  class Application < Rails::Application
    config.root = Dir.mktmpdir("coldwire-variants")
    config.eager_load = false
    config.logger = Logger.new(IO::NULL)
    config.secret_key_base = "coldwire" * 8
    config.hosts.clear
  end

  # A resource controller shaped the way a real one is: a `respond_to` block, a frame branch, an
  # export through `send_data`, and a stream. The bodies are inline only so the test needs no
  # view files; everything about how Rails answers is real.
  class ArticlesController < ActionController::Base
    PAGE = "<html><head><title>Article</title></head><body><turbo-frame id=\"comments\">…</turbo-frame></body></html>"
    COMMENTS = '<turbo-frame id="comments"><ol><li>First</li></ol></turbo-frame>'
    STREAM = '<turbo-stream action="append" target="comments"><template><li>New</li></template></turbo-stream>'

    def show
      respond_to do |format|
        format.html do
          # The idiomatic branch: a frame request renders only the frame, without the layout.
          render html: (turbo_frame_request? ? COMMENTS : PAGE).html_safe, layout: false
        end
        format.json { render json: { id: params[:id], title: "Hello" } }
        format.csv { send_data "id,title\n1,Hello\n", type: "text/csv", filename: "articles.csv" }
        format.turbo_stream { render plain: STREAM, content_type: "text/vnd.turbo-stream.html" }
      end
    end

    # Conditional GET, as any cache-aware action does it.
    def cached
      return unless stale?(etag: "v1", public: true)

      render html: "<html><body>cached</body></html>".html_safe, layout: false
    end

    # The shape Active Storage and any legacy route use, and the one that poisons a cache when
    # it is followed and stored.
    def legacy
      redirect_to "/articles/1"
    end

    private

    def turbo_frame_request?
      request.headers["Turbo-Frame"].present?
    end
  end

  # Exactly what turbo-rails' `turbo_frame_request?` does, written out so the test does not
  # need the gem to describe the request Turbo makes.
  class MessagesController < ActionController::Base
    PAGE = "<html><head><title>Messages</title></head><body>page</body></html>"
    FRAME = '<turbo-frame id="list">frame</turbo-frame>'

    def show
      respond_to do |format|
        format.html { render html: (turbo_frame_request? ? FRAME : PAGE).html_safe }
        format.json { render json: { body: "json" } }
        format.csv { render plain: "a,b,c" }
        format.xml { render xml: "<report/>" }
        format.text { render plain: "plain" }
      end
    end

    private

    def turbo_frame_request?
      request.headers["Turbo-Frame"].present?
    end
  end
end

VariantResponses::Application.initialize!
VariantResponses::Application.routes.draw do
  get "/messages", to: "variant_responses/messages#show"
  # `(.:format)` is Rails' own default, which is what makes /articles/1.json work.
  get "/articles/:id", to: "variant_responses/articles#show"
  get "/cached", to: "variant_responses/articles#cached"
  get "/legacy", to: "variant_responses/articles#legacy"
end

class VariantResponsesTest < ActionDispatch::IntegrationTest
  HTML_ACCEPT = "text/html, application/xhtml+xml"
  # What Turbo actually sends on a form submission, stream type first.
  STREAM_ACCEPT = "text/vnd.turbo-stream.html, text/html, application/xhtml+xml"

  def app
    VariantResponses::Application
  end

  # The three responses this is all about, from one URL.
  def test_one_endpoint_answers_three_ways
    get "/messages", headers: { "Accept" => HTML_ACCEPT }
    page = response.body
    page_type = response.media_type

    get "/messages", headers: { "Accept" => "application/json" }
    json = response.body
    json_type = response.media_type

    get "/messages", headers: { "Accept" => HTML_ACCEPT, "Turbo-Frame" => "list" }
    frame = response.body
    frame_type = response.media_type

    assert_equal "text/html", page_type
    assert_equal "application/json", json_type
    assert_equal "text/html", frame_type

    assert_includes page, "<html"
    assert_includes json, "json"
    assert_includes frame, "<turbo-frame"

    # Three bodies for one URL. A cache keyed on the URL alone holds one of them.
    assert_equal 3, [ page, json, frame ].uniq.length
  end

  # The frame and the page are both text/html, both answer the same Accept, and differ only by
  # a request header. Whatever tells them apart cannot be the URL, the status, or the type.
  def test_a_frame_and_a_page_differ_only_by_a_request_header
    get "/messages", headers: { "Accept" => HTML_ACCEPT }
    page = response.body
    page_vary = response.headers["Vary"]

    get "/messages", headers: { "Accept" => HTML_ACCEPT, "Turbo-Frame" => "list" }
    frame = response.body
    frame_vary = response.headers["Vary"]

    refute_equal page, frame
    assert_equal page_vary, frame_vary,
                 "Rails does not name Turbo-Frame in Vary, so Vary cannot separate these"
  end

  # What Rails actually puts in Vary, which is what a cache honouring Vary would match on.
  # Written as an assertion rather than a comment because it is the premise of the design.
  def test_what_rails_varies_on
    get "/messages", headers: { "Accept" => HTML_ACCEPT }
    html_vary = (response.headers["Vary"] || "").split(",").map { |part| part.strip.downcase }

    get "/messages", headers: { "Accept" => "application/json" }
    json_vary = (response.headers["Vary"] || "").split(",").map { |part| part.strip.downcase }

    assert_includes html_vary, "accept", "respond_to varies on Accept"
    assert_includes json_vary, "accept"
    refute_includes html_vary, "turbo-frame"
  end

  # A precache fetches with `*/*` and gets the page. A real visit asks for text/html and gets
  # the same page — but the two requests carry different Accept strings, which is the whole
  # reason matching on Vary: Accept cannot see them as the same entry.
  def test_a_precache_and_a_visit_ask_for_the_same_page_differently
    get "/messages", headers: { "Accept" => "*/*" }
    precached = response.body

    get "/messages", headers: { "Accept" => HTML_ACCEPT }

    assert_equal precached, response.body, "same page"
    assert_equal "text/html", response.media_type
  end

  # Every format a `respond_to` block offers is another body at the same URL, and the worker
  # keys each of them apart. This is the server half of that list.
  def test_every_format_is_a_different_body_at_the_same_url
    bodies = {}

    {
      "text/html, application/xhtml+xml" => "text/html",
      "application/json" => "application/json",
      "text/csv" => "text/csv",
      "application/xml" => "application/xml",
      "text/plain" => "text/plain"
    }.each do |accept, expected_type|
      get "/messages", headers: { "Accept" => accept }

      assert_equal expected_type, response.media_type, "asked for #{accept}"
      bodies[accept] = response.body
    end

    assert_equal bodies.size, bodies.values.uniq.size, "every format is its own body"
  end

  # The real controller, exercised the way Turbo, a browser and a fetch each exercise it.
  def test_a_resource_controller_answers_every_shape_it_is_asked
    get "/articles/1", headers: { "Accept" => HTML_ACCEPT }

    assert_equal "text/html", response.media_type
    assert_includes response.body, "<html"

    get "/articles/1", headers: { "Accept" => HTML_ACCEPT, "Turbo-Frame" => "comments" }

    assert_equal "text/html", response.media_type
    assert_includes response.body, "<turbo-frame"
    refute_includes response.body, "<html", "a frame request renders the frame, not the page"

    get "/articles/1", headers: { "Accept" => "application/json" }

    assert_equal "application/json", response.media_type

    get "/articles/1", headers: { "Accept" => "text/csv" }

    assert_equal "text/csv", response.media_type
    assert_includes response.headers["Content-Disposition"].to_s, "articles.csv"

    get "/articles/1", headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_equal "text/vnd.turbo-stream.html", response.media_type
  end

  # The format in the path wins over Accept, which is what makes `/articles/1.json` answer JSON
  # to a fetch that set no Accept at all. Those URLs need no cache key of their own: the path
  # already says what they are.
  def test_a_format_in_the_path_decides_without_an_accept_header
    get "/articles/1.json", headers: { "Accept" => "*/*" }

    assert_equal "application/json", response.media_type

    get "/articles/1.json", headers: { "Accept" => HTML_ACCEPT }

    assert_equal "application/json", response.media_type, "the path wins over Accept"

    get "/articles/1.csv"

    assert_equal "text/csv", response.media_type
  end

  # A conditional GET answers 304 with no body. Nothing to cache, and the worker declines it
  # for the same reason it declines anything that is not 2xx.
  def test_a_conditional_get_answers_304_with_no_body
    get "/cached"

    assert_equal 200, response.status
    etag = response.headers["ETag"]

    assert etag.present?, "the action sets an ETag"

    get "/cached", headers: { "If-None-Match" => etag }

    assert_equal 304, response.status
    assert_empty response.body
  end

  # The trap the worker has always guarded: a redirect followed and stored puts the wrong body
  # under the right URL.
  def test_a_redirect_is_a_redirect
    get "/legacy"

    assert_equal 302, response.status
    # Absolute, as Rails writes it. The worker never reads this: a followed redirect is caught
    # by `response.redirected`, which is true whatever the Location says.
    assert_equal "http://www.example.com/articles/1", response.headers["Location"]
  end

  # A GET form submission carries the stream type ahead of text/html. Rails answers a page
  # here, since nothing rendered a stream, but the Accept string is a third distinct value for
  # a body identical to the plain visit's.
  def test_a_get_form_submission_asks_with_the_stream_type_first
    get "/messages", headers: { "Accept" => STREAM_ACCEPT }

    assert_equal "text/html", response.media_type
    assert_includes response.body, "<html"
  end
end
