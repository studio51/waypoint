require "test_helper"

# Sync observability. The gap this closes: a sync was "done" once its jobs were
# enqueued, so nothing could tell a member missing 3 trophies out of 900 from one
# missing none.
#
class WaypointTest < ActiveSupport::TestCase
  setup { Waypoint.current = nil }
  teardown { Waypoint.current = nil }

  # Opens a run and returns *the run*.
  #
  # `Waypoint.record` deliberately returns whatever the block returned, because
  # that is what a service needs from it — so these capture the run on the way
  # through rather than relying on the return value.
  #
  def record(**options)
    captured = nil

    Waypoint.record(operation: :achievements, network: :xbox, **options) do |run|
      captured = run

      yield(run) if block_given?
    end

    captured
  end

  # --- Opening and settling ---

  test "settles a self-contained run as ok" do
    waypoint = record { |run| run.found!(3) and 3.times { run.synced! } }

    assert_predicate waypoint.reload, :ok?
    assert_equal 3, waypoint.synced
    assert_not_nil waypoint.finished_at
    assert_not_nil waypoint.duration_ms
  end

  test "settles as partial when some items failed" do
    waypoint = record do |run|
      run.found!(3)
      run.synced!
      run.synced!
      run.failed!("nope")
    end

    assert_predicate waypoint.reload, :partial?
    assert_equal 1, waypoint.failed
  end

  test "settles as partial when items are simply missing" do
    waypoint = record { |run| run.found!(3) and run.synced! }

    assert_predicate waypoint.reload, :partial?
  end

  test "settles as failed when nothing synced" do
    waypoint = record { |run| run.found!(2) and 2.times { run.failed!("nope") } }

    assert_predicate waypoint.reload, :failed?
  end

  test "a run that found nothing is ok, not failed" do
    waypoint = record { |_run| nil }

    assert_predicate waypoint.reload, :ok?
  end

  # --- Exceptions ---

  test "records an exception as our bug and re-raises it" do
    waypoint = nil

    assert_raises(ArgumentError) do
      record do |run|
        waypoint = run

        raise ArgumentError, "boom"
      end
    end

    waypoint.reload

    assert_predicate waypoint, :failed?
    assert_equal "our_bug", waypoint.faults.sole.fault
    assert_equal :us, waypoint.faults.sole.party
  end

  # A run killed by a Sidekiq shutdown is exactly the disappearance this exists to
  # make visible, so it must not slip past on being outside StandardError.
  #
  test "records a non-StandardError exception too" do
    assert_raises(SignalException) { record { raise SignalException, "SIGTERM" } }

    assert_predicate Waypoint.last, :failed?
  end

  # --- Fan-out ---

  test "stays running while enqueued items have not reported back" do
    waypoint = record { |run| run.found!(10) and run.enqueued!(10) }

    assert_predicate waypoint.reload, :running?, "a fanned-out run waits for its items"
  end

  test "absorbs item outcomes reported after the run returned" do
    waypoint = record { |run| run.found!(3) and run.enqueued!(3) }

    2.times { waypoint.absorb(:synced) }
    waypoint.absorb(:failed, Network::Error.new(503, "gateway"))

    waypoint.reload

    assert_equal 2, waypoint.synced
    assert_equal 1, waypoint.failed
    assert_equal "network_unavailable", waypoint.faults.sole.fault
  end

  # `found` counts what the store offered; `enqueued` counts units of work, which
  # a fan-out can multiply. Completeness has to measure the latter or a routine
  # Xbox refresh (finds 1000, deliberately takes 3) reads as 997 losses.
  #
  test "measures completeness against work enqueued, not items found" do
    waypoint = record { |run| run.found!(1000) and run.enqueued!(3) }

    3.times { waypoint.absorb(:synced) }
    waypoint.reload.settle!

    assert_predicate waypoint.reload, :ok?
    assert_in_delta 1.0, waypoint.completeness
  end

  test "counters are atomic so concurrent workers do not lose increments" do
    waypoint = record { |run| run.found!(5) and run.enqueued!(5) }

    5.times { Waypoint.find(waypoint.id).absorb(:synced) }

    assert_equal 5, waypoint.reload.synced
  end

  # --- The reaper ---

  test "reaps a run whose items never reported back" do
    waypoint = record { |run| run.found!(10) and run.enqueued!(10) }
    waypoint.update_columns(started_at: (Waypoint::STALL_AFTER + 1.hour).ago)

    assert_equal 1, Waypoint.reap!
    assert_predicate waypoint.reload, :stalled?
  end

  test "leaves a recently opened run alone" do
    waypoint = record { |run| run.found!(10) and run.enqueued!(10) }

    assert_equal 0, Waypoint.reap!
    assert_predicate waypoint.reload, :running?
  end

  test "incomplete finds settled runs that lost work" do
    lost = record { |run| run.found!(5) and run.enqueued!(5) and run.synced! }
    lost.update_columns(started_at: (Waypoint::STALL_AFTER + 1.hour).ago)
    Waypoint.reap!

    fine = record { |run| run.found!(1) and run.synced! }

    assert_includes Waypoint.incomplete, lost.reload
    assert_not_includes Waypoint.incomplete, fine.reload
  end

  # --- Retention ---

  test "prunes old successes sooner than old failures" do
    old_ok     = record { |run| run.found!(1) and run.synced! }
    old_failed = record { |run| run.found!(1) and run.failed!("nope") }

    old_ok.update_columns(started_at: 45.days.ago)
    old_failed.update_columns(started_at: 45.days.ago)

    Waypoint.prune!

    assert_not Waypoint.exists?(old_ok.id), "a month-old success is noise"
    assert Waypoint.exists?(old_failed.id), "failures are kept for the pattern"
  end

  test "pruning a run takes its faults with it" do
    waypoint = record { |run| run.found!(1) and run.failed!("nope") }
    waypoint.update_columns(started_at: 120.days.ago)

    assert_difference("Waypoint::Fault.count", -1) { Waypoint.prune! }
  end

  # --- Nesting ---

  # The Xbox achievements walk recurses (`platform: :all` calls itself twice), so
  # re-entering must not open a second run.
  #
  test "exposes the open run to nested code and restores the previous one" do
    outer = record do |run|
      assert_equal run, Waypoint.current

      inner = Waypoint.record(operation: :inner) { Waypoint.current }

      assert_equal run, Waypoint.current, "the outer run is restored"
      assert_not_equal run, inner

      run
    end

    assert_nil Waypoint.current
    assert_predicate outer.reload, :ok?
  end
end
