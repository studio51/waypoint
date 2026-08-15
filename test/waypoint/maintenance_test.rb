require "test_helper"

# The cron pass that keeps the sync audit honest.
#
class Waypoint::MaintenanceTest < ActiveSupport::TestCase
  def waypoint!(status:, started_at: Time.current, **counters)
    Waypoint::Run.create!(
      operation: :achievements, network: :xbox, status:, started_at:,
      finished_at: (status == :running ? nil : started_at),
      **counters,
    )
  end

  test "settles runs whose items never reported back" do
    abandoned = waypoint!(status: :running, started_at: (Waypoint.config.stall_after + 1.hour).ago, found: 10, enqueued: 10)

    result = Waypoint::Maintenance.new.perform

    assert_equal 1, result[:reaped]
    assert_predicate abandoned.reload, :stalled?
  end

  test "prunes past retention" do
    old_ok = waypoint!(status: :ok, started_at: 45.days.ago, found: 1, synced: 1)

    result = Waypoint::Maintenance.new.perform

    assert_equal 1, result[:pruned][:settled]
    assert_not Waypoint::Run.exists?(old_ok.id)
  end

  # A run reaped in this same pass has to be prunable by its own retention rule.
  # Left `running` it would match no rule at all and accumulate forever, which is
  # why reaping goes first.
  #
  test "a run reaped long ago is prunable" do
    stale = waypoint!(status: :running, started_at: 120.days.ago, found: 5, enqueued: 5)

    Waypoint::Maintenance.new.perform

    assert_not Waypoint::Run.exists?(stale.id), "a four-month-old abandoned run should not still be here"
  end

  test "leaves healthy recent runs alone" do
    fresh = waypoint!(status: :running, found: 5, enqueued: 5)
    recent_ok = waypoint!(status: :ok, started_at: 2.days.ago, found: 1, synced: 1)

    Waypoint::Maintenance.new.perform

    assert_predicate fresh.reload, :running?
    assert Waypoint::Run.exists?(recent_ok.id)
  end
end
