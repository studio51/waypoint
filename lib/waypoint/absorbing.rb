# frozen_string_literal: true

module Waypoint

  # The job-runner half of the contract.
  #
  # This is the crux of the whole thing. The pipeline fans out: a run discovers N
  # items, enqueues a job each, and finishes — so the run that *found* the work
  # can never see what became of it. It only becomes observable because the run's
  # id travels with each job and each job reports its outcome back.
  #
  # Mix this into whatever dispatches those jobs, thread the run id through the
  # job's arguments, and wrap the call:
  #
  #   class ItemJob
  #     include Waypoint::Absorbing
  #
  #     def perform(payload, run_id = nil)
  #       absorb_into(run_id) { DoTheWork.call(payload) }
  #     end
  #   end
  #
  # Waypoint ships no job runner of its own on purpose: yours already exists, and
  # the only thing it needs to learn is this.
  #
  module Absorbing

    # Runs the block as one item of `run_id`'s fan-out, reporting the outcome back.
    #
    # The item is the unit of success: one achievement, one product, one image. A
    # failure is attributed and **re-raised**, so the queue still retries it — the
    # run's `failed` count is what this attempt looked like, and a later retry
    # that succeeds increments `synced`. That is the honest record of a flaky sync.
    #
    # The run is published as {Waypoint.current} for the duration, which is what
    # lets a service deep in the stack attribute its own failure with the code it
    # knows, rather than this rescue guessing from a flattened exception. When it
    # does, the generic record here stands down.
    #
    # @param run_id [Integer, String, nil] the run that fanned this item out.
    #
    # @yield the item's work.
    #
    # @return [Object] whatever the block returned.
    #
    def absorb_into(run_id)
      run      = Waypoint::Absorbing.run_for(run_id)
      previous = Waypoint.current

      Waypoint.current = run

      Waypoint.attributing do
        result = yield

        run&.absorb(:synced)

        result
      rescue Exception => e # rubocop:disable Lint/RescueException
        # Exception, not StandardError: an item killed by a worker shutdown or a
        # timeout is exactly the disappearance this exists to make visible.
        #
        run&.absorb(:failed, e) unless Waypoint.attributed?

        raise
      end
    ensure
      Waypoint.current = previous
    end

    # The run an item belongs to, if it is still there.
    #
    # A run pruned or rolled back between fan-out and delivery is not an error
    # worth failing an item over — the work matters more than the bookkeeping.
    #
    # @param id [Integer, String, nil]
    #
    # @return [Waypoint::Run, nil]
    #
    def self.run_for(id)
      return nil if id.blank?

      Waypoint::Run.find_by(id: id)
    rescue StandardError => e
      Waypoint.logger&.error("[waypoint] could not load run #{ id }: #{ e.class }: #{ e.message }")

      nil
    end
  end
end
