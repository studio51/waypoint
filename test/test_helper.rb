# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"

require_relative "dummy/config/environment"

# Build the schema by running the migrations rather than loading a checked-in
# dump. The engine contributes its own migration path to the host application
# (see {Waypoint::Engine}), so this also asserts that the mechanism works: a
# migration the engine fails to hand over is a failing suite, not silent drift.
#
# This has to happen before `rails/test_help`, which checks for pending
# migrations as it loads, and the paths are expanded explicitly because
# `ActiveRecord::Migrator` holds them relative ("db/migrate") and resolves them
# against the working directory — the gem root here, not the dummy application's.
#
ActiveRecord::Migration.verbose = false
ActiveRecord::Migrator.migrations_paths = Rails.application.config.paths["db/migrate"].expanded

ActiveRecord::Tasks::DatabaseTasks.migrate

require "rails/test_help"
require_relative "support/provider_error"

class ActiveSupport::TestCase
  self.fixture_paths = [ File.expand_path("fixtures", __dir__) ]

  fixtures :all

  # Runs and faults are written by almost every test here, and the thread-local
  # current run outlives an example that raised partway through.
  #
  teardown do
    Waypoint.current = nil

    Waypoint::Fault.delete_all
    Waypoint::Run.delete_all
  end
end
