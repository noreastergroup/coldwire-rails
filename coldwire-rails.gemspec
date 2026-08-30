# frozen_string_literal: true

require_relative "lib/coldwire/version"

Gem::Specification.new do |spec|
  spec.name        = "coldwire-rails"
  spec.version     = Coldwire::VERSION
  spec.authors     = [ "Stuart Yamartino" ]
  spec.email       = [ "stuart@noreastergroup.com" ]

  spec.summary     = "Offline page caching for Hotwire Native apps."
  spec.description = "When your Hotwire wires go cold. A Rails engine that serves a " \
                     "Cache API service worker, precaches the pages you nominate, and " \
                     "falls back to an offline view Turbo and Hotwire Native will render."
  spec.homepage    = "https://github.com/stuyam/coldwire-rails"
  spec.license     = "MIT"

  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.files = Dir[
    "app/**/*",
    "config/**/*",
    "lib/**/*",
    "LICENSE",
    "README.md",
    "CHANGELOG.md"
  ]

  spec.add_dependency "rails", ">= 7.1"
end
