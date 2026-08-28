# frozen_string_literal: true

module Coldwire
  # Serves the worker script itself. Deliberately does NOT inherit from the host's
  # ApplicationController: the worker must be fetchable before anyone signs in, and any
  # authentication filter here would break registration.
  class ServiceWorkerController < ActionController::Base
    def show
      # A worker's scope is capped by the directory it is served from, so an engine mounted
      # at /coldwire would only ever control /coldwire/*. This header lifts that cap; the
      # registration snippet asks for the matching scope.
      response.headers["Service-Worker-Allowed"] = Coldwire.config.scope
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
