# frozen_string_literal: true

require "test_helper"

# Item jobs reporting back into the run that fanned them out.
#
# This is the crux of the whole thing. The pipeline fans out: a sync discovers N
# items, enqueues a job each and finishes — the items land later, in other
# processes. So the run that *found* the work can never see what became of it. It
# only becomes observable because the run's id travels with each job and each job
# reports its outcome back.
#
# The runner below is deliberately the smallest thing that includes
# {Waypoint::Absorbing}: whatever dispatches jobs in a host application, this is
# the whole of what it has to learn.
#
class AbsorptionTest < ActiveSupport::TestCase

  # An error carrying the two things a host's own error type usually carries: a
  # status, and its own vocabulary for what went wrong.
  #
  class ProviderError < StandardError
    attr_reader :code, :message_code

    def initialize(code, message_code)
      @code         = code
      @message_code = message_code

      super("provider said #{ code }")
    end
  end

  class Runner
    include Waypoint::Absorbing

    def perform(run_id, behaviour)
      absorb_into(run_id) do
        case behaviour
        when :raise
          raise "kaboom"
        when :attributed
          # What a service does when it knows exactly why it failed: it records
          # the specific fault itself, then raises.
          error = ProviderError.new(403, :access_denied)

          Waypoint.current&.failed!(error, fault: Waypoint::Classifier.for_record_error(error.code, error.message_code))
          Waypoint.attributed!

          raise error
        else
          :ok
        end
      end
    end
  end

  setup do
    @run = Waypoint::Run.create!(operation: :achievements, network: :xbox, status: :running, started_at: Time.current)
    @run.enqueued!(2)
  end

  def dispatch(behaviour, run_id: @run.id) = Runner.new.perform(run_id, behaviour)

  test "a successful item counts towards the run" do
    dispatch(:ok)

    assert_equal 1, @run.reload.synced
    assert_equal 0, @run.failed
  end

  test "a failed item is counted and attributed, and still raises for the queue to retry" do
    assert_raises(RuntimeError) { dispatch(:raise) }

    @run.reload

    assert_equal 1, @run.failed
    assert_equal "our_bug", @run.faults.sole.fault
  end

  # The service knows *why* it failed — its own `message_code`. By the time the
  # exception reaches the runner's rescue that detail is gone, flattened into a
  # string. So the service's own attribution has to win, and the generic one must
  # stand down rather than counting the same failure twice with the vaguer reason.
  #
  test "the service's own classification wins and is not double counted" do
    assert_raises(ProviderError) { dispatch(:attributed) }

    @run.reload

    assert_equal 1, @run.failed, "the failure was counted once, not twice"
    assert_equal "privacy_blocked", @run.faults.sole.fault
    assert_equal :member, @run.faults.sole.party
  end

  test "the last item to land settles the run" do
    dispatch(:ok)

    assert_predicate @run.reload, :running?, "still one item outstanding"

    dispatch(:ok)

    assert_predicate @run.reload, :ok?, "the final item settles it"
  end

  test "settles as partial when one of the items failed" do
    dispatch(:ok)
    assert_raises(RuntimeError) { dispatch(:raise) }

    assert_predicate @run.reload, :partial?
  end

  # Jobs enqueued before a host adopted Waypoint, and stragglers sitting in the
  # retry set, carry no run id. They must still dispatch.
  #
  test "dispatches an item with no run attached" do
    assert_nothing_raised { dispatch(:ok, run_id: nil) }
  end

  # A run pruned between fan-out and delivery must not fail the item — the work
  # matters more than the bookkeeping.
  #
  test "an item whose run has gone still does its work" do
    assert_nothing_raised { dispatch(:ok, run_id: 999_999_999) }
  end

  # Nothing may leak into the next job on a reused worker thread.
  #
  test "clears the current run afterwards" do
    dispatch(:ok)

    assert_nil Waypoint.current
  end
end
