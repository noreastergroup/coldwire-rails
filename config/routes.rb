# frozen_string_literal: true

Coldwire::Engine.routes.draw do
  # `format: false` keeps the literal ".js" in the path instead of parsing it as a format.
  get "service-worker.js", to: "service_worker#show", as: :service_worker, format: false
  get "pack", to: "caches#pack", as: :pack
  root "caches#show"
end
