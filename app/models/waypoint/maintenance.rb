# frozen_string_literal: true

module Waypoint

  # Keeps the sync audit honest and bounded, on a cron.
  #
  # Two jobs, both of which the audit is useless without:
  #
  # **Reaping.** A run that fanned work out stays `running` until its items report
  # back. When they never do — a worker died, a job was lost, a queue was purged —
  # the run would sit open forever and quietly read as "in progress". Reaping
  # settles those as `stalled`, which is the single most useful state on the
  # dashboard: it is the "we thought this member was synced and they weren't" case
  # that had no representation at all before.
  #
  # **Pruning.** Successful runs are noise after a month; failures are worth a
  # quarter, because a pattern over weeks is how an intermittent integration
  # problem shows itself.
  #
  class Maintenance

    # Runs both passes.
    #
    # Ordered deliberately: reap first, so a run that has just been settled as
    # stalled is eligible for pruning by its own retention rule rather than
    # lingering as `running` forever (which no retention rule covers).
    #
    # @return [Hash{Symbol => Object}] what the pass did, for the log.
    #
    def self.call = new.perform

    # @return [Hash{Symbol => Object}] what the pass did, for the log.
    #
    def perform
      reaped = Waypoint::Run.reap!
      pruned = Waypoint::Run.prune!

      { reaped:, pruned: }.tap do |result|
        Waypoint.logger&.info(
          "[waypoint] reaped #{ result[:reaped] } stalled run(s); " \
          "pruned #{ result[:pruned][:settled] } settled and #{ result[:pruned][:failed] } failed",
        )
      end
    end
  end
end
