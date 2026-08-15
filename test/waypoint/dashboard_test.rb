# frozen_string_literal: true

require "test_helper"

# The audit dashboard, rendered.
#
# These are deliberately end-to-end rather than unit tests: the failure mode a
# dashboard actually has is a page that raises on real data — a nil where a
# number was expected, a route helper that only the original host had, a view
# component that did not come with the gem. Only rendering the whole thing
# catches that.
#
# The dummy application mounts the engine without a gate, because Waypoint ships
# no authentication of its own — who may see the audit is the host's decision,
# made by whatever `config.parent_controller` points at.
#
class DashboardTest < ActionDispatch::IntegrationTest

  test "the index renders with no runs at all" do
    # The empty state matters: a fresh install must not 500 before it has
    # recorded anything.
    get "/waypoint"

    assert_response :success
  end

  test "the index renders runs, their counters and the fault breakdown" do
    run = Waypoint::Run.create!(
      operation: "achievements", network: "xbox", status: :partial,
      started_at: 10.minutes.ago, finished_at: 9.minutes.ago,
      found: 900, enqueued: 900, synced: 897, failed: 3,
    )
    run.faults.create!(fault: :privacy_blocked, retryable: false, message: "profile is private")
    run.faults.create!(fault: :network_rate_limited, retryable: true, message: "429")

    get "/waypoint"

    assert_response :success
    assert_match(/achievements/, response.body)
  end

  test "a run detail page renders its narrative and every fault inside it" do
    run = Waypoint::Run.create!(
      operation: "trophies", network: "playstation", status: :failed,
      started_at: 5.minutes.ago, finished_at: 4.minutes.ago,
      found: 10, enqueued: 10, synced: 0, failed: 10,
    )
    run.faults.create!(fault: :credentials_expired, retryable: false, message: "token expired", label: "Warthog Jump")

    get "/waypoint/runs/#{ run.id }"

    assert_response :success
    assert_match(/Trophies/, response.body)
    assert_match(/Warthog Jump/, response.body, "the label names the item that failed")
    assert_match(/reconnect the account/, response.body, "a fault carries its remedy, not just its name")
  end

  test "the window and status filters narrow the list" do
    get "/waypoint", params: { window: "1h", status: "failed" }

    assert_response :success
  end

  # Pagination is the gem's own, precisely so a host is not made to adopt a
  # pagination library to see its own sync history.
  #
  test "paginates without dragging in a pagination gem" do
    12.times do |index|
      Waypoint::Run.create!(operation: "games", network: "steam", status: :ok,
                            started_at: index.minutes.ago, finished_at: index.minutes.ago,
                            found: 1, synced: 1)
    end

    get "/waypoint", params: { page: 2 }

    assert_response :success
  end
end
