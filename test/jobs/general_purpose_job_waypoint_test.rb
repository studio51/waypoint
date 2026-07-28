require "test_helper"

# Item jobs reporting back into the run that fanned them out.
#
# This is the crux of the whole thing. The pipeline fans out: a sync discovers N
# items, enqueues a job each and finishes — the items land later, in other
# processes. So the run that *found* the work can never see what became of it. It
# only becomes observable because the run's id travels with each job and each job
# reports its outcome back.
#
# A stand-in service.
#
# The shape is dictated by how GeneralPurposeJob resolves a path: each `_`
# separated segment becomes a namespace, so "probe_service#run" is
# `Probe::Service#run` — the same convention that turns
# "network_xbox_user_activity" into `Network::XBOX::User::Activity`. Top-level,
# because it is resolved with `constantize` from the root.
#
module Probe
  class Service < ApplicationService
    class << self
      attr_accessor :behaviour
    end

    def initialize(*) = nil

    def run(_data)
      case self.class.behaviour
      when :raise        then raise RuntimeError, "kaboom"
      when :record_error then record_error(403, message_code: :achievements_not_permitted_by_access_control)
      else :ok
      end
    end
  end
end

class GeneralPurposeJobWaypointTest < ActiveSupport::TestCase
  setup do
    Waypoint.current = nil
    @waypoint = Waypoint.create!(operation: :achievements, network: :xbox, status: :running, started_at: Time.current)
    @waypoint.enqueued!(2)
  end

  teardown { Waypoint.current = nil }

  def dispatch(behaviour, waypoint_id: @waypoint.id)
    Probe::Service.behaviour = behaviour

    GeneralPurposeJob.new.perform("probe_service#run", nil, nil, waypoint_id)
  end

  test "a successful item counts towards the run" do
    dispatch(:ok)

    assert_equal 1, @waypoint.reload.synced
    assert_equal 0, @waypoint.failed
  end

  test "a failed item is counted and attributed, and still raises for Sidekiq to retry" do
    assert_raises(RuntimeError) { dispatch(:raise) }

    @waypoint.reload

    assert_equal 1, @waypoint.failed
    assert_equal "our_bug", @waypoint.faults.sole.fault
  end

  # The service knows *why* it failed — the `message_code`. By the time the
  # exception reaches the job's rescue that detail is gone, flattened into a
  # string. So the service's own attribution has to win, and the generic one must
  # stand down rather than counting the same failure twice with the vaguer reason.
  #
  test "the service's own classification wins and is not double counted" do
    assert_raises(Network::Error) { dispatch(:record_error) }

    @waypoint.reload

    assert_equal 1, @waypoint.failed, "the failure was counted once, not twice"
    assert_equal "privacy_blocked", @waypoint.faults.sole.fault
    assert_equal :member, @waypoint.faults.sole.party
  end

  test "the last item to land settles the run" do
    dispatch(:ok)

    assert_predicate @waypoint.reload, :running?, "still one item outstanding"

    dispatch(:ok)

    assert_predicate @waypoint.reload, :ok?, "the final item settles it"
  end

  test "settles as partial when one of the items failed" do
    dispatch(:ok)
    assert_raises(RuntimeError) { dispatch(:raise) }

    assert_predicate @waypoint.reload, :partial?
  end

  # Jobs enqueued before this existed, and stragglers sitting in the retry set,
  # carry three arguments. They must still dispatch.
  #
  test "dispatches an item with no run attached" do
    assert_nothing_raised { dispatch(:ok, waypoint_id: nil) }
  end

  # A run pruned between fan-out and delivery must not fail the item — the work
  # matters more than the bookkeeping.
  #
  test "an item whose run has gone still does its work" do
    assert_nothing_raised { dispatch(:ok, waypoint_id: 999_999_999) }
  end

  # Nothing may leak into the next job on a reused Sidekiq thread.
  #
  test "clears the current run afterwards" do
    dispatch(:ok)

    assert_nil Waypoint.current
  end
end
