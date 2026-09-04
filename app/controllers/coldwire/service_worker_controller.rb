# frozen_string_literal: true

module Coldwire
  # Serves the worker script. Deliberately not the host's ApplicationController: the worker
  # must be fetchable before anyone signs in, and an authentication filter would break
  # registration.
  class ServiceWorkerController < ActionController::Base
    # The worker carries no user data and is fetched by the browser's worker loader, not an
    # XHR, so Rails' cross-origin script guard only rejects legitimate registrations.
    skip_forgery_protection

    def show
      # A worker's scope is capped by the directory it is served from, so an engine mounted at
      # /coldwire would only control /coldwire/*. This lifts the cap.
      response.headers["Service-Worker-Allowed"] = Coldwire.config.worker_scope
      response.headers["Cache-Control"] = "no-cache"

      render(
        template: "coldwire/service_worker/show",
        formats: :js,
        layout: false,
        content_type: "text/javascript"
      )
    end
  end
end
