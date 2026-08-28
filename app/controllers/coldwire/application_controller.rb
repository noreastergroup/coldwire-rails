# frozen_string_literal: true

module Coldwire
  # Inherits the host's ApplicationController so the debug page picks up its layout,
  # authentication, and helpers.
  class ApplicationController < ::ApplicationController
    # The engine is isolated, so bare route helpers inside it resolve against the engine's
    # own routes. The host's layout calls its own helpers (`root_path`, `sites_path`, …),
    # which would otherwise raise. Coldwire's own views still say `coldwire.pack_path`.
    helper ::Rails.application.routes.url_helpers
  end
end
