# frozen_string_literal: true

require "waypoint/version"
require "waypoint/configuration"
require "waypoint/absorbing"

# Did the sync actually finish?
#
# A sync is usually called "done" when its jobs were *enqueued*, not when the
# data arrived. Nothing records what upstream offered, what actually landed, or
# why the difference — so "is this subject fully synced?" has no answer, and a
# subject missing 3 items out of 900 looks identical to one missing none.
#
# Waypoint records a run, what it found, what it enqueued, and what came back:
#
#   Waypoint.record(network: :xbox, operation: :achievements, subject: identity) do |run|
#     run.found(remote_achievements.size)
#     ...
#   end
#
# The items land later, in other processes, and report back through
# {Waypoint::Run#absorb}. `found > synced + failed` on a settled run is then a
# real number: work that was accepted and then silently vanished.
#
module Waypoint
  class << self

    # @return [Waypoint::Configuration]
    #
    def config
      @config ||= Configuration.new
    end

    # @yieldparam config [Waypoint::Configuration]
    #
    # @return [Waypoint::Configuration]
    #
    def configure
      yield(config) if block_given?

      config
    end

    # Records a sync run around `block`. See {Waypoint::Run.record}.
    #
    # @return [Object] whatever the block returned.
    #
    def record(...) = Run.record(...)

    # The run open on this thread, if any.
    #
    # Lets a service deep in a call stack report a fault without the entry point
    # having to pass the run down through every layer — which is what makes
    # hooking an application's own error reporting possible, and with it every
    # existing service at once.
    #
    # @return [Waypoint::Run, nil]
    #
    def current = Thread.current[:waypoint]

    def current=(run)
      Thread.current[:waypoint] = run
    end

    # Whether the failure being handled on this thread has already been recorded
    # with a real classification.
    #
    # A service reporting a `message_code` knows *why* it failed. By the time the
    # exception reaches an outer rescue that detail is gone, flattened into a
    # string. So the specific attribution wins and the outer generic one stands
    # down, rather than one failure being counted twice with the vaguer reason.
    #
    # @return [Boolean]
    #
    def attributed? = Thread.current[:waypoint_attributed].present?

    # Runs `block` with a clean attribution slate.
    #
    # @yield the work whose failures are being attributed.
    #
    # @return [Object] the block's value.
    #
    def attributing
      previous = Thread.current[:waypoint_attributed]
      Thread.current[:waypoint_attributed] = false

      yield
    ensure
      Thread.current[:waypoint_attributed] = previous
    end

    # Marks the current failure as already attributed.
    #
    # @return [void]
    #
    def attributed!
      Thread.current[:waypoint_attributed] = true
    end

    # Where Waypoint's own diagnostics go.
    #
    # @return [Logger, nil]
    #
    def logger
      defined?(::Rails) && ::Rails.respond_to?(:logger) ? ::Rails.logger : nil
    end

    # The controller class the dashboard inherits from.
    #
    # Resolved lazily and never cached, because in development the host's
    # controller is reloadable and holding a reference to a stale class is how an
    # engine ends up serving a page from the previous edit.
    #
    # @return [Class]
    #
    def parent_controller
      config.parent_controller.to_s.constantize
    end

    # Where the dashboard's one outward link points, if the host set one.
    #
    # Accepts a path or a callable, because the useful destination is usually a
    # route helper the engine cannot name.
    #
    # @return [String, nil] the path, or nil to render no link at all.
    #
    def back_link_path
      value = config.back_link_path

      value.respond_to?(:call) ? value.call : value
    end
  end
end

# Required last: the engine reads `Waypoint.config` while its class body runs, so
# the module's own API has to exist first.
#
require "waypoint/engine" if defined?(::Rails::Engine)
