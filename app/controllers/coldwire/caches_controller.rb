# frozen_string_literal: true

module Coldwire
  # The debug surface: inspect what is cached, precache the manifest, force offline.
  class CachesController < Coldwire::ApplicationController
    def show
    end

    # The precache manifest. Never stored by anything: the worker asks with `cache: "no-store"`,
    # but that binds only the one caller, and a browser serving a heuristically-fresh copy had
    # syncs faithfully fetching yesterday's list.
    def pack
      response.headers["Cache-Control"] = "no-store, private"

      render json: { urls: Array(precache_urls) }
    end

    private

    # Evaluated against the host's URL helpers, so `site_path(site)` means the host's route
    # rather than one of Coldwire's. A lambda that takes an argument is handed this controller.
    def precache_urls
      manifest = Coldwire.config.auto_sync.precache_urls
      helpers = ::Rails.application.routes.url_helpers

      if manifest.arity.zero?
        helpers.instance_exec(&manifest)
      else
        helpers.instance_exec(self, &manifest)
      end
    end
  end
end
