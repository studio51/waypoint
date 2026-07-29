# frozen_string_literal: true

# The sync audit — what happens behind the scenes, and where it goes wrong.
#
# Reads {Waypoints::Audit}: every figure is an aggregate over a window, so the
# page never counts a live table or walks a run's items.
#
class Admin::WaypointsController < Admin::ApplicationController

  # How many runs a page of the list holds.
  #
  PER_PAGE = 50

  # The audit dashboard: how syncing is going, whose fault the failures are, and
  # what is still owed.
  #
  # @return [void]
  #
  def index
    @title = "Sync Audit"

    @audit = audit
    @pagy, @runs = pagy(@audit.runs.includes(:subject), limit: PER_PAGE)

    add_breadcrumb(@title)
  end

  # One run in full: its narrative, its counters, and every fault inside it.
  #
  # @return [void]
  #
  def show
    @waypoint = Waypoint.includes(:subject).find(params[:id])
    @title    = "#{ @waypoint.operation.humanize } · #{ @waypoint.network || 'platform' }"
    @faults   = @waypoint.faults.includes(:faultable).recent

    add_breadcrumb("Sync Audit", admin_waypoints_path)

    add_breadcrumb(@title)
  end

private

  # The audit for the current filters.
  #
  # @return [Waypoints::Audit]
  #
  def audit
    @audit ||= Waypoints::Audit.new(
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
