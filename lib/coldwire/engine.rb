# frozen_string_literal: true

module Coldwire
  class Engine < ::Rails::Engine
    isolate_namespace Coldwire

    # Let host apps `pin "coldwire", to: "coldwire/cache_controller.js"` without knowing
    # where the gem lives.
    initializer "coldwire.importmap", before: "importmap" do |app|
      if app.config.respond_to?(:importmap)
        app.config.importmap.paths << root.join("config/importmap.rb")
        app.config.importmap.cache_sweepers << root.join("app/assets/javascripts")
      end
    end

    initializer "coldwire.assets" do |app|
      if app.config.respond_to?(:assets)
        app.config.assets.paths << root.join("app/assets/javascripts")
      end
    end

    initializer "coldwire.helpers" do
      ActiveSupport.on_load(:action_controller_base) do
        helper Coldwire::ServiceWorkerHelper
      end
    end
  end
end
