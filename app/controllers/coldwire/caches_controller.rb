# frozen_string_literal: true

module Coldwire
  # The debug surface: inspect what is cached, precache the manifest, force offline.
  class CachesController < Coldwire::ApplicationController
    def show
    end

    # The precache manifest. Internal JSON consumed by the Stimulus controller, not a
    # page — the list can be long and is not meant to be rendered.
    def pack
      render json: { urls: Array(instance_exec(&Coldwire.config.prefetch_urls)) }
    end
  end
end
