# frozen_string_literal: true

module Coldwire
  # A service worker's own fetches do not carry the user agent an app set on its web view.
  # On Android they arrive as a plain browser, so everything the worker precaches comes back
  # rendered for the wrong client — navigation chrome a native app hides, and none of the
  # markup that depends on knowing it is the app. `fetch` cannot set User-Agent (Chromium
  # drops it), so the worker sends what the page told it in a header of its own and this puts
  # it back where Rails looks.
  #
  # No new trust: the user agent was always the client's to state, and this only lets a client
  # state its own by another name.
  class ClientUserAgent
    HEADER = "HTTP_COLDWIRE_USER_AGENT"

    def initialize(app)
      @app = app
    end

    def call(env)
      claimed = env[HEADER]
      env["HTTP_USER_AGENT"] = claimed if claimed.present?

      @app.call(env)
    end
  end
end
