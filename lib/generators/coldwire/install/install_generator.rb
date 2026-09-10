# frozen_string_literal: true

require "rails/generators"

module Coldwire
  module Generators
    # `bin/rails coldwire:install` / `bin/rails generate coldwire:install`
    #
    # Mounts the engine, writes the initializer, registers the Stimulus controller, and
    # drops the service worker tag into the layout. Each step is skipped if it is already
    # done, so running it twice is safe.
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Install Coldwire into this application"

      LAYOUTS = [
        "app/views/layouts/application.html.erb"
      ].freeze

      STIMULUS_INDEXES = [
        "app/javascript/controllers/index.js",
        "app/javascript/controllers/index.ts"
      ].freeze

      STIMULUS_REGISTRATION = <<~JS

        import ColdwireCacheController from "coldwire"
        application.register("coldwire-cache", ColdwireCacheController)
      JS

      def add_route
        if file_contains?("config/routes.rb", "Coldwire::Engine")
          say "Coldwire is already mounted in config/routes.rb, skipping"
          return
        end

        route 'mount Coldwire::Engine => "/offline"'
      end

      def copy_initializer
        if file_exists?("config/initializers/coldwire.rb")
          say "config/initializers/coldwire.rb already exists, skipping"
          return
        end

        copy_file "coldwire.rb", "config/initializers/coldwire.rb"
      end

      def add_layout_tag
        layout = first_existing(LAYOUTS)
        unless layout
          say "Could not find app/views/layouts/application.html.erb. " \
              "Add <%= coldwire_service_worker_tag %> inside <head>.", :yellow
          return
        end

        if file_contains?(layout, "coldwire_service_worker_tag")
          say "#{layout} already includes coldwire_service_worker_tag, skipping"
          return
        end

        unless file_contains?(layout, "</head>")
          say "Could not find </head> in #{layout}. " \
              "Add <%= coldwire_service_worker_tag %> inside <head>.", :yellow
          return
        end

        insert_into_file layout, "    <%= coldwire_service_worker_tag %>\n", before: "</head>"
      end

      def register_stimulus
        index = first_existing(STIMULUS_INDEXES)
        unless index
          say "Could not find app/javascript/controllers/index.js. Register the controller with:", :yellow
          say STIMULUS_REGISTRATION
          return
        end

        if file_contains?(index, "coldwire-cache") || file_contains?(index, 'from "coldwire"')
          say "#{index} already registers Coldwire, skipping"
          return
        end

        append_to_file index, STIMULUS_REGISTRATION
      end

      def next_steps
        say ""
        say "Coldwire is mounted at /offline.", :green
        say "Set config.cache_identity if anyone signs in."
        say "Turn on config.auto_sync to precache pages."
      end

      private

      def first_existing(paths)
        paths.find { |path| file_exists?(path) }
      end

      def file_exists?(relative)
        File.exist?(File.join(destination_root, relative))
      end

      def file_contains?(relative, snippet)
        file_exists?(relative) && File.read(File.join(destination_root, relative)).include?(snippet)
      end
    end
  end
end
