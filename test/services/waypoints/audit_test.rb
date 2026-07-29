require "test_helper"

# The read side of the sync audit.
#
class Waypoints::AuditTest < ActiveSupport::TestCase
  setup { Waypoint.current = nil }
  teardown { Waypoint.current = nil }

  def run!(status: :ok, network: "xbox", operation: "achievements", started_at: 1.hour.ago, **counters)
    Waypoint.create!(
      network:, operation:, status:, started_at:,
      finished_at: (status == :running ? nil : started_at),
      **{ found: 0, enqueued: 0, synced: 0, failed: 0 }.merge(counters),
    )
  end

  def fault!(waypoint, kind, label: nil)
    waypoint.faults.create!(fault: kind, message: "because", label:)
  end

  # --- Windowing ---

  # An all-time average buries a live problem under months of history, so every
  # figure is windowed.
  #
  test "only counts runs inside the window" do
    run!(started_at: 30.minutes.ago)
    run!(started_at: 3.days.ago)

    assert_equal 1, Waypoints::Audit.new(window: "1h").total_runs
    assert_equal 2, Waypoints::Audit.new(window: "7d").total_runs
  end

  test "falls back to a sane window for a bad one" do
    assert_equal "24h", Waypoints::Audit.new(window: "nonsense").window
  end

  # --- Headline ---

  test "counts runs by status" do
    run!(status: :ok)
    run!(status: :partial)
    run!(status: :failed)
    run!(status: :stalled)

    audit = Waypoints::Audit.new

    assert_equal 4, audit.total_runs
    assert_equal 3, audit.troubled_runs, "partial, failed and stalled are all not-clean"
    assert_equal 1, audit.statuses["ok"]
  end

  # Measured on work accepted, not items found: a routine Xbox refresh finds a
  # page of 1000 and deliberately takes 3, which is not a 99.7% failure.
  #
  test "completeness measures work accepted rather than items found" do
    run!(status: :ok, found: 1000, enqueued: 3, synced: 3)

    assert_in_delta 1.0, Waypoints::Audit.new.completeness
  end

  test "completeness reflects work that did not land" do
    run!(status: :partial, found: 10, enqueued: 10, synced: 8, failed: 2)

    assert_in_delta 0.8, Waypoints::Audit.new.completeness
  end

  test "completeness is nil when nothing ran" do
    assert_nil Waypoints::Audit.new.completeness
  end

  # The figure that had no representation before Waypoint.
  #
  test "counts runs whose work was accepted and never reported back" do
    run!(status: :stalled, found: 10, enqueued: 10, synced: 4, failed: 1)
    run!(status: :ok, found: 5, enqueued: 5, synced: 5)

    assert_equal 1, Waypoints::Audit.new.incomplete_runs
  end

  # --- Faults ---

  test "groups faults by who has to act" do
    waypoint = run!(status: :partial, found: 4, synced: 1, failed: 3)

    fault!(waypoint, :credentials_expired)
    fault!(waypoint, :network_unavailable)
    fault!(waypoint, :our_bug)

    parties = Waypoints::Audit.new.faults_by_party

    assert_equal 1, parties[:member]
    assert_equal 1, parties[:network]
    assert_equal 1, parties[:us]
  end

  test "orders fault kinds by how often they happen" do
    waypoint = run!(status: :failed, found: 4, failed: 4)

    3.times { fault!(waypoint, :network_unavailable) }
    fault!(waypoint, :our_bug)

    assert_equal [ "network_unavailable", "our_bug" ], Waypoints::Audit.new.faults_by_kind.keys
    assert_equal 4, Waypoints::Audit.new.total_faults
  end

  test "ignores faults from runs outside the window" do
    old = run!(status: :failed, started_at: 10.days.ago, found: 1, failed: 1)
    fault!(old, :our_bug)

    assert_equal 0, Waypoints::Audit.new(window: "1h").total_faults
    assert_equal 1, Waypoints::Audit.new(window: "30d").total_faults
  end

  # --- Filters ---

  test "filters by network and operation" do
    run!(network: "xbox", operation: "achievements")
    run!(network: "play_station", operation: "trophies")

    assert_equal 1, Waypoints::Audit.new(network: "xbox").runs.count
    assert_equal 1, Waypoints::Audit.new(operation: "trophies").runs.count
    assert_equal 0, Waypoints::Audit.new(network: "xbox", operation: "trophies").runs.count
  end

  test "filters the run list by status but not the headline" do
    run!(status: :ok)
    run!(status: :failed)

    audit = Waypoints::Audit.new(status: "failed")

    assert_equal 1, audit.runs.count
    assert_equal 2, audit.total_runs, "the tiles describe the window, not the status you clicked"
  end

  test "ignores a status that is not a real one" do
    assert_nil Waypoints::Audit.new(status: "banana").status
  end

  # Read from the data, so a new network appears the moment it syncs anything.
  #
  test "offers the networks and operations that actually ran" do
    run!(network: "xbox", operation: "achievements")
    run!(network: "steam", operation: "games")

    audit = Waypoints::Audit.new

    assert_equal %w[steam xbox], audit.networks
    assert_equal %w[achievements games], audit.operations
  end

  # --- Attachments ---

  test "reports images still owed, by fault" do
    trophy = Game.create!(name: "Audit Game")

    pending_intent = AttachmentIntent.declare(record: trophy, name: :cover, url: "https://x.test/a.png")
    assert_predicate pending_intent, :pending?

    failed = AttachmentIntent.declare(record: Game.create!(name: "Other"), name: :cover, url: "https://x.test/b.png")
    failed.failed!(Network::Error.new(503, "down"))

    grouped = Waypoints::Audit.new.attachments_by_fault

    assert_equal 1, grouped["pending"], "an intent with no attempt yet has no fault"
    assert_equal 1, grouped["network_unavailable"]
    assert_equal 2, Waypoints::Audit.new.outstanding_attachments
  end

  # Not windowed: an image missing since last month is still missing, and that
  # backlog is the point.
  #
  test "counts images owed regardless of the window" do
    intent = AttachmentIntent.declare(record: Game.create!(name: "Old"), name: :cover, url: "https://x.test/c.png")
    intent.update!(created_at: 90.days.ago, updated_at: 90.days.ago)

    assert_equal 1, Waypoints::Audit.new(window: "1h").outstanding_attachments
  end

  test "reports which sync asked for the images that are missing" do
    AttachmentIntent.declare(record: Game.create!(name: "Sourced"), name: :cover, url: "https://x.test/d.png", called_from: "network_xbox_game_achievement#perform")

    assert_equal 1, Waypoints::Audit.new.attachments_by_source["network_xbox_game_achievement#perform"]
  end
end
