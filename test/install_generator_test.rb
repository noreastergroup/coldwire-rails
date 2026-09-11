# frozen_string_literal: true

# The generated files are UTF-8 and Rails' assert_file reads with the default external
# encoding, which is US-ASCII when the shell has no locale set.
Encoding.default_external = Encoding::UTF_8

require "minitest/autorun"
require "fileutils"
require "rails/generators"
require "rails/generators/test_case"
require "generators/coldwire/install/install_generator"

class InstallGeneratorTest < Rails::Generators::TestCase
  tests Coldwire::Generators::InstallGenerator
  destination File.expand_path("../tmp/generators", __dir__)

  def setup
    prepare_destination
    stub_app_files
  end

  def test_installs_route_initializer_layout_tag_and_stimulus
    run_generator

    assert_file "config/routes.rb" do |content|
      assert_match %r{mount Coldwire::Engine => "/offline"}, content
    end

    assert_file "config/initializers/coldwire.rb" do |content|
      assert_match "Coldwire.configure do |config|", content
      assert_match "sync.enabled = false", content
      assert_match "config.cache_identity = -> { nil }", content
      assert_match "config.caching_enabled_by_default = true", content
      assert_match 'config.cache_as_you_go = [ "/*" ]', content
      assert_match 'config.worker_scope = "/"', content
    end

    assert_file "app/views/layouts/application.html.erb" do |content|
      assert_includes content, "<%= coldwire_service_worker_tag %>"
      assert_match %r{<%= coldwire_service_worker_tag %>\s*</head>}m, content
    end

    assert_file "app/javascript/controllers/index.js" do |content|
      assert_includes content, 'import ColdwireCacheController from "coldwire"'
      assert_includes content, 'application.register("coldwire-cache", ColdwireCacheController)'
    end
  end

  def test_running_twice_does_not_duplicate
    run_generator
    run_generator

    assert_equal 1, File.read(File.join(destination_root, "config/routes.rb")).scan("Coldwire::Engine").size
    assert_equal 1, File.read(File.join(destination_root, "app/views/layouts/application.html.erb")).scan("coldwire_service_worker_tag").size
    assert_equal 1, File.read(File.join(destination_root, "app/javascript/controllers/index.js")).scan("coldwire-cache").size
  end

  def test_skips_missing_optional_files_without_raising
    FileUtils.rm_rf File.join(destination_root, "app")

    run_generator

    assert_file "config/initializers/coldwire.rb"
    assert_file "config/routes.rb" do |content|
      assert_match "Coldwire::Engine", content
    end
  end

  private

  def stub_app_files
    FileUtils.mkdir_p File.join(destination_root, "config")
    File.write File.join(destination_root, "config/routes.rb"), <<~RUBY
      Rails.application.routes.draw do
        root "home#index"
      end
    RUBY

    FileUtils.mkdir_p File.join(destination_root, "app/views/layouts")
    File.write File.join(destination_root, "app/views/layouts/application.html.erb"), <<~ERB
      <!DOCTYPE html>
      <html>
        <head>
          <title>App</title>
        </head>
        <body>
        </body>
      </html>
    ERB

    FileUtils.mkdir_p File.join(destination_root, "app/javascript/controllers")
    File.write File.join(destination_root, "app/javascript/controllers/index.js"), <<~JS
      import { application } from "controllers/application"
      import { eagerLoadControllersFrom } from "@hotwired/stimulus-loading"
      eagerLoadControllersFrom("controllers", application)
    JS
  end
end
