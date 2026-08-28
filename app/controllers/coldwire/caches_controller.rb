# frozen_string_literal: true

module Coldwire
  # The debug surface: inspect what is cached, precache the manifest, force offline.
  class CachesController < Coldwire::ApplicationController
    def show
    end

    # The precache manifest. Internal JSON consumed by the Stimulus controller, not a
    # page — the list can be long and is not meant to be rendered.
    def pack
      render json: { urls: Array(prefetch_urls) }
    end

    private

    # Evaluated against the host application's URL helpers, so `config.prefetch_urls` can
    # say `site_path(site)` and mean the host's route rather than one of Coldwire's. A
    # lambda that takes an argument is handed this controller, for `current_user` and the
    # like.
    def prefetch_urls
      manifest = Coldwire.config.prefetch_urls
      helpers = ::Rails.application.routes.url_helpers

      if manifest.arity.zero?
        helpers.instance_exec(&manifest)
      else
        helpers.instance_exec(self, &manifest)
      end
    end
  end
end
