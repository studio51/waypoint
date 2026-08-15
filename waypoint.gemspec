# frozen_string_literal: true

require_relative "lib/waypoint/version"

Gem::Specification.new do |spec|
  spec.name        = "waypoint"
  spec.version     = Waypoint::VERSION
  spec.authors     = [ "Vlad Radulescu" ]
  spec.email       = [ "vlad@studio51.solutions" ]
  spec.homepage    = "https://github.com/studio51/waypoint"
  spec.summary     = "Did the sync actually finish? Fan-out/fan-in accounting for Rails background work."
  spec.description = <<~TEXT.freeze
    A sync is usually called done when its jobs were enqueued, not when the data
    arrived. Waypoint records what upstream offered, what was enqueued, what
    landed and what failed, so a run that accepted work and silently lost some of
    it is visible rather than indistinguishable from a clean one. Failures are
    classified by who has to act — the account holder, the provider, or you — and
    runs whose items never report back are settled as stalled rather than left
    running forever.
  TEXT
  spec.license = "Apache-2.0"

  spec.required_ruby_version = ">= 3.2"

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"]   = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.files = Dir[
    "{app,config,db,lib}/**/*",
    "LICENSE",
    "NOTICE",
    "README.md",
    "CHANGELOG.md",
  ]

  # Waypoint is a Rails engine and its dashboard templates are Slim. Nothing else
  # is required: the job runner, the HTTP client and the error vocabulary are all
  # the host's, reached through configuration rather than a dependency.
  #
  spec.add_dependency "rails", ">= 7.1", "< 9"
  spec.add_dependency "slim", ">= 5.0"
end
