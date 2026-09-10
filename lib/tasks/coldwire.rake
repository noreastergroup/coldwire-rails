# frozen_string_literal: true

namespace :coldwire do
  desc "Install Coldwire: mount the engine, add the initializer, register the Stimulus controller, and tag the layout"
  task :install do
    Rails::Command.invoke :generate, [ "coldwire:install" ]
  end
end
