# frozen_string_literal: true

module Coldwire
  # Inherits the host's ApplicationController so the debug page picks up its layout,
  # authentication, and helpers.
  class ApplicationController < ::ApplicationController
    # The engine is isolated, so bare route helpers inside it resolve against the engine's
    # own routes. The host's layout calls its own helpers (`root_path`, `sites_path`, …),
    # which would otherwise raise. Coldwire's own views still say `coldwire.pack_path`.
    helper ::Rails.application.routes.url_helpers

    # Those helpers still build on the request's SCRIPT_NAME, which inside a mounted engine is
    # the mount point — so a host layout asking for `sites_path` got "/offline/sites", a URL
    # the app does not serve. Clear it: the host's helpers describe the host's routes, which
    # begin at the root whatever Coldwire is mounted under. Coldwire's own views say
    # `coldwire.pack_path`, and that proxy supplies the mount itself.
    def url_options
      super.merge(script_name: "")
    end
  end
end
