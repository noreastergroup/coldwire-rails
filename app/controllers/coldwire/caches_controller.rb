# frozen_string_literal: true

module Coldwire
  # The debug surface: inspect what is cached, precache the manifest, force offline.
  class CachesController < Coldwire::ApplicationController
    def show
    end

    # The precache manifest. Internal JSON consumed by the Stimulus controller, not a
    # page — the list can be long and is not meant to be rendered.
    def pack
      # Never stored, by anything. The worker asks for it with `cache: "no-store"`, but that
      # only binds the one caller — a browser left to its own heuristics served a copy without
      # asking, and a sync then faithfully fetched an old list, missing exactly the newly
      # published pages it exists to pick up. `private` because this is built from what the
      # signed-in user can see and belongs to nobody else.
      response.headers["Cache-Control"] = "no-store, private"

      render json: { urls: Array(precache_urls) }
    end

    private

    # Evaluated against the host application's URL helpers, so `config.precache_urls` can
    # say `site_path(site)` and mean the host's route rather than one of Coldwire's. A
    # lambda that takes an argument is handed this controller, for `current_user` and the
    # like.
    def precache_urls
      manifest = Coldwire.config.precache_urls
      helpers = ::Rails.application.routes.url_helpers

      if manifest.arity.zero?
        helpers.instance_exec(&manifest)
      else
        helpers.instance_exec(self, &manifest)
      end
    end
  end
end
