# frozen_string_literal: true

# Defines Coldwire::VERSION by reading the VERSION file, so the number lives in exactly one
# place. VERSION has to ship in spec.files below, or requiring this in an installed gem fails.
require_relative "lib/coldwire/version"

Gem::Specification.new do |spec|
  spec.name        = "coldwire-rails"
  spec.version     = Coldwire::VERSION
  spec.authors     = [ "Noreaster Group" ]
  spec.email       = [ "stuart@noreastergroup.com" ]

  spec.summary     = "Offline page caching for Hotwire, PWA, and Hotwire Native Rails apps."
  spec.description = "When your Hotwire wires go cold. A Rails engine that serves a " \
                     "Cache API service worker, precaches the pages you nominate, and " \
                     "falls back to an offline view Turbo will actually render. Built " \
                     "against Hotwire Native's rules, which are stricter than a browser's, " \
                     "so the same cache works in a plain Hotwire app and an installed PWA."
  spec.homepage    = "https://github.com/noreastergroup/coldwire-rails"
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
    "VERSION",
    "README.md",
    "CHANGELOG.md"
  ]

  spec.add_dependency "rails", ">= 7.1"
end
