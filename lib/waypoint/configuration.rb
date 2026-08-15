# frozen_string_literal: true

# The retention defaults below are Durations, and configuration is read while
# the gem loads — before Rails has necessarily pulled in its core extensions.
#
require "active_support/core_ext/numeric/time"

module Waypoint

  # Everything about Waypoint a host gets to decide.
  #
  # The defaults are the ones that need no knowledge of the application: the
  # fault taxonomy, the exception and HTTP-status mappings, and the retention
  # windows. The one thing Waypoint cannot guess is the application's own
  # vocabulary for why something failed — see {#message_codes}.
  #
  class Configuration

    # --- Classification ---

    # The application's own failure vocabulary, mapped onto faults.
    #
    # This is the highest-confidence signal there is, because the service that
    # reported the code knew exactly what happened, and it is the one mapping
    # that cannot ship with the gem: `:authenticator_expired_or_invalid` means
    # nothing outside the application that raised it.
    #
    # Empty by default, which is not a failure state — an application with no
    # such vocabulary classifies on exception class and HTTP status alone.
    #
    # @return [Hash{Symbol => Symbol}] message code => a key of {Fault::FAULTS}.
    #
    attr_accessor :message_codes

    # Exception class name => fault, merged over {Classifier::EXCEPTIONS}.
    #
    # Matched on the name rather than the constant so an application can classify
    # an exception from a gem it does not load in every process.
    #
    # @return [Hash{String => Symbol}]
    #
    attr_accessor :exceptions

    # HTTP status => fault, merged over {Classifier::STATUSES}.
    #
    # @return [Hash{Integer => Symbol}]
    #
    attr_accessor :statuses

    # Faults worth trying again. The member's and our own are not — retrying an
    # expired token, or a bug, just burns worker time.
    #
    # @return [Array<Symbol>]
    #
    attr_accessor :retryable_faults

    # --- Lifecycle ---

    attr_accessor :stall_after    # how long a run may stay open before it is presumed lost
    attr_accessor :keep_settled   # retention for runs that ended cleanly
    attr_accessor :keep_failed    # retention for runs that did not

    # Path fragment identifying application code, used to name the service that
    # opened a run when it did not say. Nil disables the guess.
    #
    # @return [String, nil]
    #
    attr_accessor :service_path_marker

    # --- Dashboard ---

    attr_accessor :parent_controller  # the host controller the dashboard inherits from, by name
    attr_accessor :back_link_path     # host path the dashboard links back to; nil renders no link
    attr_accessor :back_link_label    # the label for that link

    def initialize
      @message_codes    = {}
      @exceptions       = {}
      @statuses         = {}
      @retryable_faults = %i[network_unavailable network_rate_limited network_empty]

      # Generous on purpose: a full history walk against a paginated API
      # legitimately takes a while to drain, and calling that stalled would be
      # the monitoring inventing a problem.
      #
      @stall_after  = 6.hours
      @keep_settled = 30.days
      @keep_failed  = 90.days

      @service_path_marker = "/app/services/".freeze

      # Deliberately the bare Rails base. The dashboard shows what every sync did
      # for every subject, so getting a reachable one should take an explicit
      # decision by the host.
      #
      @parent_controller = "ActionController::Base".freeze
      @back_link_path    = nil
      @back_link_label   = "← Back"
    end
  end
end
