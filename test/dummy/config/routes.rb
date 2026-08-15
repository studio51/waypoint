# frozen_string_literal: true

Rails.application.routes.draw do
  root to: "home#index"

  resources :users, only: [ :show ]

  mount(Waypoint::Engine, at: "/waypoint", as: :waypoint)
end
