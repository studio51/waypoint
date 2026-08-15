# frozen_string_literal: true

# One run of one sync step, and how it went.
#
# The problem this exists to solve: a sync was "done" when its jobs were
# *enqueued*, not when the data arrived. Nothing recorded what upstream offered,
# what actually landed, or why the difference — so "is this member fully synced?"
# had no answer, and a member missing 3 trophies out of 900 looked identical to
# one missing none.
#
#   Waypoint.record(network: :xbox, operation: :achievements, subject: identity) do |run|
#     run.found(remote_achievements.size)
#     ...
#   end
#
# ## Runs and items
#
# The pipeline fans out: a run discovers N items and enqueues a job each, then
# finishes. The items land later, in other processes. So a run is opened with what
# it `found` and `enqueued`, and the item jobs report back into it — see
# {#absorb}, which {GeneralPurposeJob} calls by threading the run's id through the
# job arguments.
#
# That is what makes `found > synced + failed` on a settled run meaningful: it is
# work that was accepted and then silently vanished, which is precisely the
# failure mode that has been invisible. {.reap!} closes those out as `stalled`
# rather than leaving them `running` forever.
#
# Successes are counted, never recorded row-by-row: volume tracks the trouble, not
# the traffic. Failures get a {Waypoint::Fault} each.
#
class Waypoint::Run < ActiveRecord::Base

  self.table_name = "waypoints"

  # running  — open; items may still be reporting in
  # ok       — everything found was synced
  # partial  — some synced, some failed
  # failed   — nothing synced, or the run itself blew up
  # stalled  — settled by the reaper; items never all reported back
  #
  STATUSES = %i[running ok partial failed stalled].freeze

  enum :status, STATUSES

  # How long a run may stay open before the reaper calls it stalled, and how long
  # settled runs are kept, are both host decisions — a full history walk against
  # a paginated API legitimately takes a while to drain, and how much audit trail
  # is worth keeping is an operational judgement, not a fact about syncing.
  #
  # See {Waypoint::Configuration#stall_after}, `#keep_settled` and `#keep_failed`.

  # How many outcomes a run should end up with.
  #
  # `enqueued` when it fanned work out, `found` when it did the work itself. The
  # two differ on purpose — see {#enqueued!} — so a run that found 1000 and
  # deliberately took 3 isn't reported as having lost 997.
  #
  EXPECTED_SQL = "CASE WHEN enqueued > 0 THEN enqueued ELSE found END"

  # Associations
  #
  belongs_to :subject, polymorphic: true, optional: true

  # The column stayed `waypoint_id` when the model became `Waypoint::Run`: it is
  # the host's data, and renaming a column to match a Ruby constant is not worth
  # a migration. Rails would otherwise infer `run_id` from the class name.
  #
  has_many :faults, class_name: "Waypoint::Fault", foreign_key: :waypoint_id, inverse_of: :run, dependent: :delete_all

  # Scopes
  #
  scope :recent,   -> { order(started_at: :desc) }
  scope :settled,  -> { where.not(status: statuses[:running]) }
  scope :troubled, -> { where(status: [ statuses[:partial], statuses[:failed], statuses[:stalled] ]) }

  # Runs open long enough to be presumed lost.
  #
  scope :stalling, -> { running.where(started_at: ..Waypoint.config.stall_after.ago) }

  # Runs whose items didn't all report back, even though the run is settled. The
  # "we think we synced you but we didn't" case.
  #
  # Measured against {EXPECTED_SQL}, not against `found`: a routine Xbox refresh
  # legitimately finds a page of 1000 and enqueues 3, and that is not 997 losses.
  #
  scope :incomplete, -> { settled.where("synced + failed < #{ EXPECTED_SQL }") }

  class << self

    # Records a sync run around `block`.
    #
    # The run is opened before the block and settled after it, whatever happens.
    # An exception escaping the block is recorded as an `our_bug` fault and
    # re-raised — Waypoint observes, it never swallows. A run that fanned out is
    # left `running` for its items to report into; one that did all its own work
    # settles immediately.
    #
    # @param operation [Symbol, String] the step, e.g. :achievements.
    # @param network [Symbol, String, nil] the platform, e.g. :xbox.
    # @param subject [ActiveRecord::Base, nil] who/what it ran for.
    # @param service [String, nil] the class doing the work, for the audit trail.
    # @param jid [String, nil] the Sidekiq job id, for queue correlation.
    #
    # @yieldparam waypoint [Waypoint] the open run, to report counts into.
    #
    # @return [Object] whatever the block returned.
    #
    def record(operation:, network: nil, subject: nil, service: nil, jid: nil)
      waypoint = create!(
        operation: operation.to_s,
        network: network&.to_s,
        service: service || caller_service,
        subject: subject,
        jid: jid,
        status: :running,
        started_at: Time.current,
      )

      previous = Waypoint.current
      Waypoint.current = waypoint

      begin
        result = yield(waypoint)

        waypoint.settle!

        result
      rescue Exception => e # rubocop:disable Lint/RescueException
        # Exception, not StandardError: a run killed by a Sidekiq shutdown or a
        # timeout is exactly the kind of disappearance this is here to make
        # visible. It is re-raised immediately either way.
        #
        waypoint.fail!(e)

        raise
      ensure
        Waypoint.current = previous
      end
    end

    # Settles runs that have been open too long. Their items were accepted and
    # never came back, so the honest status is `stalled`, not `running`.
    #
    # @return [Integer] how many runs were reaped.
    #
    def reap!
      stalling.in_batches.sum do |batch|
        batch.filter_map { |waypoint| waypoint.stall! }.size
      end
    end

    # Drops history past its retention window.
    #
    # Faults go first: `delete_all` is a single DELETE that skips
    # `dependent: :delete_all`, so leaving them would trip the foreign key.
    #
    # @return [Hash{Symbol => Integer}] rows deleted per bucket.
    #
    def prune!
      {
        settled: purge(where(status: statuses[:ok]).where(started_at: ..Waypoint.config.keep_settled.ago)),
        failed:  purge(troubled.where(started_at: ..Waypoint.config.keep_failed.ago)),
      }
    end

  private

    # Deletes a set of runs and the faults hanging off them.
    #
    # @param scope [ActiveRecord::Relation<Waypoint>]
    #
    # @return [Integer] runs deleted.
    #
    def purge(scope)
      Waypoint::Fault.where(waypoint_id: scope.select(:id)).delete_all

      scope.delete_all
    end

    # Best-effort name of the service that opened the run, when it didn't say.
    #
    # @return [String, nil]
    #
    def caller_service
      marker = Waypoint.config.service_path_marker

      return nil if marker.blank?

      frame = caller_locations(2, 8)&.find { |location| location.path.include?(marker) }

      frame && File.basename(frame.path, ".rb").camelize
    end
  end

  # --- Reporting, from inside a run ---

  # Adds to how many items upstream offered.
  #
  # Accumulates rather than sets, because the paginated syncs discover a page at a
  # time — an Xbox achievement walk calls this once per page, and the run's total
  # is the sum.
  #
  # @param count [Integer]
  #
  # @return [void]
  #
  def found!(count)
    self.class.update_counters(id, found: count.to_i, touch: true)
  end

  # Adds to how many items were accepted for processing.
  #
  # Normally tracks `found`, and deliberately separate when we skip some: Xbox
  # stops at the first already-synced achievement on a routine refresh, so it
  # finds a page of 1000 and enqueues 3. Without both numbers that looks like 997
  # lost items.
  #
  # @param count [Integer]
  #
  # @return [void]
  #
  def enqueued!(count)
    self.class.update_counters(id, enqueued: count.to_i, touch: true)
  end

  # Counts items that landed. Atomic, because the item jobs reporting in run
  # concurrently across workers.
  #
  # @param count [Integer]
  #
  # @return [void]
  #
  def synced!(count = 1)
    self.class.update_counters(id, synced: count, touch: true)
  end

  # Records something that went wrong, classified.
  #
  # @param error [Exception, String] what happened.
  # @param faultable [ActiveRecord::Base, nil] the item it happened to.
  # @param label [String, nil] a name for the item when there's no record yet.
  # @param fault [Symbol, nil] override the classification.
  # @param context [Hash, nil] anything else worth keeping.
  #
  # @return [Waypoint::Fault]
  #
  def failed!(error, faultable: nil, label: nil, fault: nil, context: nil)
    classified = fault || Waypoint::Classifier.classify(error)

    Waypoint.attributed!
    self.class.update_counters(id, failed: 1, touch: true)

    faults.create!(
      fault: classified,
      faultable: faultable,
      label: label || faultable.try(:name),
      message: error.respond_to?(:message) ? error.message : error.to_s,
      code: error.try(:code),
      retryable: Waypoint::Classifier.retryable?(classified),
      context: context,
    )
  end

  # Reports an item job's outcome back into the run that enqueued it.
  #
  # The last item to land settles the run. Without that a fanned-out run would sit
  # `running` until the reaper got to it hours later, which is the opposite of
  # useful for the question being asked ("is this member synced *now*?").
  #
  # Two workers can both see the final outcome and both settle; {#finish!} is a
  # plain column write, so the second is harmless.
  #
  # @param outcome [Symbol] :synced or :failed.
  # @param error [Exception, String, nil] required for :failed.
  # @param options [Hash] forwarded to {#failed!}.
  #
  # @return [void]
  #
  def absorb(outcome, error = nil, **options)
    outcome.to_sym == :synced ? synced!(1) : failed!(error, **options)

    reload

    settle! if running? && !awaiting_items?
  end

  # --- Settling ---

  # Closes the run, deriving its status from the counters.
  #
  # A run that fanned out work to other jobs stays `running` so those items can
  # report in; the last item to land settles it (see {#absorb}), and the reaper
  # settles it if they never do. A run that did its own work settles now.
  #
  # Reloads first: the counters are written with `update_counters` so concurrent
  # workers don't lose increments, which means this object's copy of them is stale
  # by definition. Deciding without reloading read zeros and called every run `ok`.
  #
  # @return [Boolean]
  #
  def settle!
    reload

    return true if awaiting_items?

    finish!(resolved_status)
  end

  # Closes the run as failed, recording the cause.
  #
  # @param error [Exception, String] what killed it.
  #
  # @return [Boolean]
  #
  def fail!(error)
    failed!(error) if error

    finish!(:failed)
  end

  # Closes an abandoned run.
  #
  # @return [Boolean, nil] nil when it settled on its own in the meantime.
  #
  def stall!
    return unless running?

    finish!(:stalled)
  end

  # Whether the run handed work to other jobs that haven't all reported yet.
  #
  # @return [Boolean]
  #
  def awaiting_items?
    enqueued.positive? && (synced + failed) < enqueued
  end

  # How many outcomes this run should end up with — the Ruby side of
  # {EXPECTED_SQL}.
  #
  # @return [Integer]
  #
  def expected = enqueued.positive? ? enqueued : found

  # How complete the run actually was, 0.0-1.0.
  #
  # @return [Float]
  #
  def completeness
    return 1.0 if expected.zero?

    (synced.to_f / expected).clamp(0.0, 1.0)
  end

  # The one-line narrative the dashboard reads, Sentinel-style.
  #
  # @return [String]
  #
  def narrative
    I18n.t("waypoint.narrative",
      operation: operation.humanize,
      found: found,
      expected: expected,
      synced: synced,
      failed: failed,)
  end

private

  # The status the counters imply for a settled run.
  #
  # @return [Symbol]
  #
  def resolved_status
    return :ok     if failed.zero? && synced >= expected
    return :failed if synced.zero? && failed.positive?

    failed.positive? || synced < expected ? :partial : :ok
  end

  # Stamps the run closed.
  #
  # @param status [Symbol]
  #
  # @return [Boolean]
  #
  def finish!(status)
    finished = Time.current

    update_columns(
      status: self.class.statuses[status],
      finished_at: finished,
      duration_ms: ((finished - started_at) * 1000).round,
      updated_at: finished,
    )
  end
end
