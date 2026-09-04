# frozen_string_literal: true

module Coldwire
  # Putting the app's user agent back on the requests its own service worker makes.
  #
  # A request carries the agent of whoever makes it, and a worker is not the page. On Android
  # that is the difference between the app and a browser: Hotwire Native sets the agent on the
  # web view, and `android.webkit.ServiceWorkerWebSettings` has no equivalent, so nothing the
  # app configures reaches a worker's fetches — and `fetch` cannot set one, because Chromium
  # drops a User-Agent given to it. Left alone, everything the cache holds comes back rendered
  # for a browser: navigation chrome a native app hides, and none of the markup that depends on
  # knowing it is the app.
  #
  # A cookie is the one thing the browser attaches by itself to every same-origin request,
  # whoever makes it. The page writes this web view's own agent into one, and this reads it
  # back before anything else in the stack runs.
  #
  # No new trust: the user agent was always the client's to state, and a cookie is as much the
  # client's as the header is. It is written by a page in the same browser profile, which is
  # the same client the request comes from.
  class ClientUserAgent
    COOKIE = "coldwire-user-agent"

    def initialize(app)
      @app = app
    end

    def call(env)
      claimed = claimed_user_agent(env)
      env["HTTP_USER_AGENT"] = claimed if claimed.present?

      @app.call(env)
    end

    private

    def claimed_user_agent(env)
      cookie = env["HTTP_COOKIE"]
      return if cookie.blank?

      value = Rack::Utils.parse_cookies_header(cookie)[COOKIE]
      return if value.blank?

      # A user agent is a header value: anything that cannot be one is not one.
      value.match?(/\A[[:print:]]{1,512}\z/) ? value : nil
    end
  end
end
