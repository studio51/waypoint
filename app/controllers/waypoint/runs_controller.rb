# frozen_string_literal: true

module Waypoint

  # The sync audit — what happens behind the scenes, and where it goes wrong.
  #
  # Reads {Waypoint::Audit}: every figure is an aggregate over a window, so the
  # page never counts a live table or walks a run's items.
  #
  class RunsController < Waypoint.parent_controller

    # How many runs a page of the list holds.
    #
    PER_PAGE = 50

    # The audit dashboard: how syncing is going, whose fault the failures are, and
    # what is still owed.
    #
    # @return [void]
    #
    def index
      @title = t(".title")
      @audit = audit
      @page  = [ params[:page].to_i, 1 ].max

      scope = @audit.runs.includes(:subject)

      @total = scope.count(:all)
      @pages = [ (@total / PER_PAGE.to_f).ceil, 1 ].max
      @runs  = scope.offset((@page - 1) * PER_PAGE).limit(PER_PAGE)
    end

    # One run in full: its narrative, its counters, and every fault inside it.
    #
    # @return [void]
    #
    def show
      @run    = Run.includes(:subject).find(params[:id])
      @title  = "#{ @run.operation.humanize } · #{ @run.network || 'platform' }"
      @faults = @run.faults.includes(:faultable).recent
    end

  private

    # The audit for the current filters.
    #
    # @return [Waypoint::Audit]
    #
    def audit
      @audit ||= Audit.new(
        window: params[:window],
        network: params[:network],
        operation: params[:operation],
        status: params[:status],
      )
    end

    # The current filters, for carrying through links and pagination.
    #
    # @return [Hash]
    #
    def audit_filters
      params.permit(:window, :network, :operation, :status).to_h.reject { |_, value| value.blank? }
    end

    helper_method :audit_filters
  end
end
