# frozen_string_literal: true

Waypoint::Engine.routes.draw do
  root to: "runs#index"

  resources :runs, only: [ :index, :show ]
end
