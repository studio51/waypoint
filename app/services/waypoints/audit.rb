# frozen_string_literal: true

module Waypoints

  # The read side of the sync audit: everything the dashboard needs to answer
  # "what is happening behind the scenes, and where is it going wrong?".
  #
  # Every figure here is deliberately scoped to a window rather than all time.
  # The useful question is "is syncing healthy *now*", and an all-time average
  # buries a live problem under months of history.
  #
  # Aggregates only — no per-row work — so the dashboard stays cheap enough to
  # load without a cache in front of it. The counters and fault classes are
  # indexed for exactly these queries (see the CreateWaypoints migration).
  #
  class Audit

    # How far back the dashboard looks by default. A day is the shortest window
    # that still spans a full cycle of the slower crons.
    #
    DEFAULT_WINDOW = 24.hours

    # The windows offered on the dashboard.
    #
    WINDOWS = {
      "1h"  => 1.hour,
      "24h" => 24.hours,
      "7d"  => 7.days,
      "30d" => 30.days,
    }.freeze

    attr_reader :window, :network, :operation, :status

    # @param window [String, nil] a key of {WINDOWS}.
    # @param network [String, nil] restrict to one platform.
    # @param operation [String, nil] restrict to one sync step.
    # @param status [String, nil] restrict to one run status.
    #
    def initialize(window: nil, network: nil, operation: nil, status: nil)
      @window    = WINDOWS.key?(window) ? window : "24h"
      @network   = network.presence
      @operation = operation.presence
      @status    = status.presence_in(Waypoint.statuses.keys)
    end

    # The runs the current filters select, newest first.
    #
    # @return [ActiveRecord::Relation<Waypoint>]
    #
    def runs
      scope = Waypoint.where(started_at: since..).recent
      scope = scope.where(network: network)     if network
      scope = scope.where(operation: operation) if operation
      scope = scope.where(status: status)       if status

      scope
    end

    # --- Headline ---

    # How the window's runs came out, by status.
    #
    # @return [Hash{String => Integer}]
    #
    def statuses
      @statuses ||= Waypoint.statuses.keys.index_with(0).merge(
        base.group(:status).count.transform_keys { |value| Waypoint.statuses.key(value) || value.to_s },
      )
    end

    def total_runs = statuses.values.sum

    # Runs that did not come out clean.
    #
    # @return [Integer]
    #
    def troubled_runs = statuses.values_at("partial", "failed", "stalled").compact.sum

    # Runs that were accepted and then never fully reported back — the case that
    # had no representation before Waypoint. The single most useful number here.
    #
    # @return [Integer]
    #
    def incomplete_runs
      @incomplete_runs ||= base.merge(Waypoint.incomplete).count
    end

    # The share of work that actually landed, across the window.
    #
    # Measured on `enqueued` where a run fanned out and `found` where it didn't
    # (see Waypoint::EXPECTED_SQL) — otherwise a routine Xbox refresh that finds
    # 1000 and deliberately takes 3 would read as a 99.7% failure.
    #
    # @return [Float, nil] 0.0-1.0, or nil when nothing ran.
    #
    def completeness
      totals = base.pick(Arel.sql("SUM(synced), SUM(#{ Waypoint::EXPECTED_SQL })"))
      synced, expected = totals&.map(&:to_i)

      return nil if expected.nil? || expected.zero?

      (synced.to_f / expected).clamp(0.0, 1.0)
    end

    # --- Faults ---

    # How many faults fall to each party, richest first.
    #
    # This is the question the whole taxonomy exists to answer: is the backlog of
    # problems ours, the stores', or the members' to act on?
    #
    # @return [Hash{Symbol => Integer}]
    #
    def faults_by_party
      counts = faults_by_kind

      Waypoint::Fault::PARTIES.transform_values do |kinds|
        kinds.sum { |kind| counts[kind.to_s].to_i }
      end
    end

    # How many faults of each kind, most frequent first.
    #
    # @return [Hash{String => Integer}]
    #
    def faults_by_kind
      @faults_by_kind ||= faults
        .group(:fault).count
        .transform_keys { |value| Waypoint::Fault.faults.key(value) || value.to_s }
        .sort_by { |_, count| -count }
        .to_h
    end

    # The faults themselves, newest first, for the list.
    #
    # @param limit [Integer] how many to show.
    #
    # @return [ActiveRecord::Relation<Waypoint::Fault>]
    #
    def recent_faults(limit: 50)
      faults.includes(:waypoint).recent.limit(limit)
    end

    def total_faults = faults_by_kind.values.sum

    # --- Attachments ---
    #
    # Missing images are part of the same picture — they fail for the same reasons
    # and are classified with the same vocabulary — so the audit reports them
    # alongside the syncs rather than on a page of their own.

    # How many images are still owed, by fault.
    #
    # Not windowed: an image missing since last month is still missing, and that
    # is precisely the backlog worth seeing.
    #
    # @return [Hash{String => Integer}]
    #
    def attachments_by_fault
      @attachments_by_fault ||= AttachmentIntent.unresolved
        .group(:fault).count
        .transform_keys { |value| value.nil? ? "pending" : (AttachmentIntent.faults.key(value) || value.to_s) }
        .sort_by { |_, count| -count }
        .to_h
    end

    # Which sync is producing the missing images — the fastest way to find the
    # pipeline at fault.
    #
    # @param limit [Integer] how many sources to list.
    #
    # @return [Hash{String => Integer}]
    #
    def attachments_by_source(limit: 10)
      AttachmentIntent.unresolved
        .where.not(called_from: nil)
        .group(:called_from).order(Arel.sql("COUNT(*) DESC")).limit(limit).count
    end

    def outstanding_attachments = attachments_by_fault.values.sum
    def abandoned_attachments   = @abandoned_attachments ||= AttachmentIntent.abandoned.count

    # --- Filter options ---

    # The networks that have actually run in the window, for the filter.
    #
    # Read from the data rather than a hardcoded list, so a new network appears
    # here the moment it syncs anything.
    #
    # @return [Array<String>]
    #
    def networks = @networks ||= Waypoint.where(started_at: since..).distinct.where.not(network: nil).pluck(:network).sort

    # @return [Array<String>]
    #
    def operations = @operations ||= Waypoint.where(started_at: since..).distinct.pluck(:operation).compact.sort

    # When the window starts.
    #
    # @return [ActiveSupport::TimeWithZone]
    #
    def since = @since ||= WINDOWS.fetch(window).ago

  private

    # Every run in the window, ignoring the status filter.
    #
    # The headline tiles describe the whole window on purpose — filtering them by
    # the status you clicked would make the tiles agree with themselves and tell
    # you nothing.
    #
    # @return [ActiveRecord::Relation<Waypoint>]
    #
    def base
      scope = Waypoint.where(started_at: since..)
      scope = scope.where(network: network)     if network
      scope = scope.where(operation: operation) if operation

      scope
    end

    # The faults belonging to the window's runs.
    #
    # @return [ActiveRecord::Relation<Waypoint::Fault>]
    #
    def faults
      Waypoint::Fault.where(waypoint_id: base.select(:id))
    end
  end
end
