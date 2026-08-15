# frozen_string_literal: true

# The dashboard's templates are Slim, so the engine requires it rather than
# assuming the host already has. Bundler resolves a transitive dependency but
# never requires it, so a host that does not use Slim itself would otherwise get
# `MissingExactTemplate` on every Waypoint page.
#
require "slim"

module Waypoint

  # Mounts Waypoint into a host Rails application.
  #
  # The engine owns its migrations rather than installing them: adding them to
  # the host's migration paths means `db:migrate` picks them up wherever the gem
  # lives, and an upgrade is a `bundle update` rather than a rake task plus a
  # diff review.
  #
  class Engine < ::Rails::Engine
    isolate_namespace Waypoint

    config.waypoint = Waypoint.config

    initializer "waypoint.migrations" do |app|
      next if app.root.to_s == root.to_s

      config.paths["db/migrate"].expanded.each do |path|
        app.config.paths["db/migrate"] << path
      end
    end
  end
end
